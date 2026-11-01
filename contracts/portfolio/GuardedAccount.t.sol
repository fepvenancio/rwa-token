// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Address} from '@openzeppelin/contracts/utils/Address.sol';
import {Test} from 'forge-std/Test.sol';

import {IGuardedAccount} from 'interfaces/IGuardedAccount.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ERC20CallValidator} from 'contracts/portfolio/ERC20CallValidator.sol';
import {ERC4626CallValidator} from 'contracts/portfolio/ERC4626CallValidator.sol';
import {GuardedAccount} from 'contracts/portfolio/GuardedAccount.sol';
import {Portfolio} from 'contracts/portfolio/Portfolio.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {MockERC4626Target} from 'contracts/test/MockERC4626Target.sol';
import {MockPortfolioVault} from 'contracts/test/MockPortfolioVault.sol';

/// @notice A real portfolio and registry over a vault whose roles a test sets
contract GuardedAccountTest is Test {
  bytes32 internal constant _ALLOCATOR_ROLE = keccak256('ALLOCATOR_ROLE');
  bytes32 internal constant _GUARDIAN_ROLE = keccak256('GUARDIAN_ROLE');
  bytes32 internal constant _DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 internal constant _RISK = keccak256('this account');
  bytes32 internal constant _CUSTODIAN_RISK = keccak256('one custodian');
  uint256 internal constant _CAP = 1000e6;

  PolicyRegistry internal _registry;
  MockPortfolioVault internal _vault;
  MockAsset internal _asset;
  Portfolio internal _portfolio;
  GuardedAccount internal _account;
  ERC20CallValidator internal _toCustodian;

  address internal _admin = makeAddr('admin');
  address internal _guardian = makeAddr('guardian');
  address internal _allocator = makeAddr('allocator');
  address internal _custodian = makeAddr('custodian');
  address internal _stranger = makeAddr('stranger');

  function setUp() public virtual {
    _registry = new PolicyRegistry(address(this), address(this));
    _asset = new MockAsset(6);
    _vault = new MockPortfolioVault(address(_registry));
    _vault.setRole(_DEFAULT_ADMIN_ROLE, _admin, true);
    _vault.setRole(_GUARDIAN_ROLE, _guardian, true);
    _vault.setRole(_ALLOCATOR_ROLE, _allocator, true);
    _portfolio = new Portfolio(address(_vault), IERC20(address(_asset)), true);
    _account = new GuardedAccount(address(_portfolio), _RISK, _CUSTODIAN_RISK);
    _toCustodian = new ERC20CallValidator(_custodian, _CAP);
    _registry.attest(address(_toCustodian).codehash, IPolicyRegistry.AttestKind.VALIDATOR, '');
    _registry.attest(address(_account).codehash, IPolicyRegistry.AttestKind.ADAPTER, '');
  }

  function _permit() internal {
    vm.prank(_admin);
    _account.setPermission(address(_asset), IERC20.transfer.selector, address(_toCustodian));
  }

  function _calls(
    address _target,
    bytes memory _data
  ) internal pure returns (IGuardedAccount.Call[] memory _list) {
    _list = new IGuardedAccount.Call[](1);
    _list[0] = IGuardedAccount.Call({target: _target, data: _data});
  }

  function _pay(
    address _to,
    uint256 _amount
  ) internal view returns (IGuardedAccount.Call[] memory _list) {
    _list = _calls(address(_asset), abi.encodeCall(IERC20.transfer, (_to, _amount)));
  }

  function _refused(
    address _target,
    bytes4 _selector
  ) internal pure returns (bytes memory _data) {
    _data = abi.encodeWithSelector(IGuardedAccount.GuardedAccount_CallRefused.selector, _target, _selector);
  }

  function _unauthorized(
    address _caller
  ) internal pure returns (bytes memory _data) {
    _data = abi.encodeWithSelector(IGuardedAccount.GuardedAccount_Unauthorized.selector, _caller);
  }
}

contract GuardedAccount_Construction is GuardedAccountTest {
  function test_ItKnowsWhatItServes() external view {
    assertEq(_account.PORTFOLIO(), address(_portfolio));
    assertEq(_account.VAULT(), address(_vault));
    assertEq(_account.asset(), address(_asset));
    assertEq(_account.RISK_ID(), _RISK);
    assertEq(_account.SHARED_RISK_ID(), _CUSTODIAN_RISK);
    assertTrue(_account.reported());
    assertTrue(_account.fresh());
    assertEq(_account.value(), 0);
    bytes32[] memory _ids = _account.riskIds();
    assertEq(_ids.length, 2);
    assertEq(_ids[0], _RISK);
    assertEq(_ids[1], _CUSTODIAN_RISK);
  }

  function test_WithNoSharedRisk_ItNamesOne() external {
    GuardedAccount _alone = new GuardedAccount(address(_portfolio), _RISK, bytes32(0));
    bytes32[] memory _ids = _alone.riskIds();
    assertEq(_ids.length, 1);
    assertEq(_ids[0], _RISK);
  }

  function test_WithNoPortfolio_ItReverts() external {
    vm.expectRevert(IGuardedAccount.GuardedAccount_ZeroAddress.selector);
    new GuardedAccount(address(0), _RISK, bytes32(0));
  }

  function test_WithNoRisk_ItReverts() external {
    vm.expectRevert(IGuardedAccount.GuardedAccount_NoRiskId.selector);
    new GuardedAccount(address(_portfolio), bytes32(0), bytes32(0));
  }

  function test_AnOnChainOnlyPortfolioIsRefused() external {
    Portfolio _onChainOnly = new Portfolio(address(_vault), IERC20(address(_asset)), false);
    vm.expectRevert(IGuardedAccount.GuardedAccount_ReportedNotAccepted.selector);
    new GuardedAccount(address(_onChainOnly), _RISK, bytes32(0));
  }
}

contract GuardedAccount_Permissions is GuardedAccountTest {
  function testFuzz_OnlyTheAdminSetsAPermission(
    address _caller
  ) external {
    if (_caller == _admin) _caller = _stranger;
    vm.expectRevert(_unauthorized(_caller));
    vm.prank(_caller);
    _account.setPermission(address(_asset), IERC20.transfer.selector, address(_toCustodian));
  }

  function test_AnUnattestedValidatorIsRefused() external {
    ERC20CallValidator _rogue = new ERC20CallValidator(_stranger, type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(IGuardedAccount.GuardedAccount_NotAttested.selector, address(_rogue)));
    vm.prank(_admin);
    _account.setPermission(address(_asset), IERC20.transfer.selector, address(_rogue));
  }

  function test_AValidatorAttestedAsSomethingElseIsRefused() external {
    ERC4626CallValidator _other = new ERC4626CallValidator();
    _registry.attest(address(_other).codehash, IPolicyRegistry.AttestKind.RULE, '');
    vm.expectRevert(abi.encodeWithSelector(IGuardedAccount.GuardedAccount_NotAttested.selector, address(_other)));
    vm.prank(_admin);
    _account.setPermission(address(_asset), IERC20.transfer.selector, address(_other));
  }

  function test_ItsOwnPortfolioVaultAndSelfCannotBeNamed() external {
    address[3] memory _forbidden = [address(_portfolio), address(_vault), address(_account)];
    for (uint256 _i; _i < 3; ++_i) {
      vm.expectRevert(abi.encodeWithSelector(IGuardedAccount.GuardedAccount_ForbiddenTarget.selector, _forbidden[_i]));
      vm.prank(_admin);
      _account.setPermission(_forbidden[_i], IERC20.transfer.selector, address(_toCustodian));
    }
  }

  function test_ItRecordsAndEmits() external {
    vm.expectEmit(address(_account));
    emit IGuardedAccount.PermissionSet(address(_asset), IERC20.transfer.selector, address(_toCustodian));
    _permit();
    assertEq(_account.validatorOf(address(_asset), IERC20.transfer.selector), address(_toCustodian));
  }

  function test_TheAdminAndTheGuardianRevoke() external {
    address[2] memory _callers = [_admin, _guardian];
    for (uint256 _i; _i < 2; ++_i) {
      _permit();
      vm.expectEmit(address(_account));
      emit IGuardedAccount.PermissionRevoked(address(_asset), IERC20.transfer.selector);
      vm.prank(_callers[_i]);
      _account.revokePermission(address(_asset), IERC20.transfer.selector);
      assertEq(_account.validatorOf(address(_asset), IERC20.transfer.selector), address(0));
    }
  }

  function testFuzz_NobodyElseRevokes(
    address _caller
  ) external {
    if (_caller == _admin || _caller == _guardian) _caller = _stranger;
    _permit();
    vm.expectRevert(_unauthorized(_caller));
    vm.prank(_caller);
    _account.revokePermission(address(_asset), IERC20.transfer.selector);
  }

  function test_TheGuardianCannotGrant() external {
    vm.expectRevert(_unauthorized(_guardian));
    vm.prank(_guardian);
    _account.setPermission(address(_asset), IERC20.transfer.selector, address(_toCustodian));
  }
}

contract GuardedAccount_Execute is GuardedAccountTest {
  function setUp() public override {
    super.setUp();
    _asset.mint(address(_account), 5000e6);
  }

  function testFuzz_OnlyTheAllocatorExecutes(
    address _caller
  ) external {
    if (_caller == _allocator) _caller = _stranger;
    _permit();
    IGuardedAccount.Call[] memory _list = _pay(_custodian, 1);
    vm.expectRevert(_unauthorized(_caller));
    vm.prank(_caller);
    _account.execute(_list);
  }

  function test_ARevokedAllocatorStopsAtOnce() external {
    _permit();
    _vault.setRole(_ALLOCATOR_ROLE, _allocator, false);
    IGuardedAccount.Call[] memory _list = _pay(_custodian, 1);
    vm.expectRevert(_unauthorized(_allocator));
    vm.prank(_allocator);
    _account.execute(_list);
  }

  function test_NoValidatorMeansRefused() external {
    IGuardedAccount.Call[] memory _list = _pay(_custodian, 1);
    vm.expectRevert(_refused(address(_asset), IERC20.transfer.selector));
    vm.prank(_allocator);
    _account.execute(_list);
  }

  function test_AnotherFunctionOfAPermittedContractIsRefused() external {
    _permit();
    IGuardedAccount.Call[] memory _list = _calls(address(_asset), abi.encodeCall(IERC20.approve, (_custodian, 1)));
    vm.expectRevert(_refused(address(_asset), IERC20.approve.selector));
    vm.prank(_allocator);
    _account.execute(_list);
  }

  function test_TheSameFunctionOfAnotherContractIsRefused() external {
    _permit();
    MockAsset _otherToken = new MockAsset(6);
    IGuardedAccount.Call[] memory _list = _calls(address(_otherToken), abi.encodeCall(IERC20.transfer, (_custodian, 1)));
    vm.expectRevert(_refused(address(_otherToken), IERC20.transfer.selector));
    vm.prank(_allocator);
    _account.execute(_list);
  }

  function test_WhenTheValidatorRefuses_SoDoesTheAccount() external {
    _permit();
    IGuardedAccount.Call[] memory _list = _pay(_stranger, 1);
    vm.expectRevert(_refused(address(_asset), IERC20.transfer.selector));
    vm.prank(_allocator);
    _account.execute(_list);
    assertEq(_asset.balanceOf(_stranger), 0);
  }

  function test_DataTooShortForASelectorIsRefused() external {
    IGuardedAccount.Call[] memory _list = _calls(address(_asset), hex'a905');
    vm.expectRevert(_refused(address(_asset), bytes4(0)));
    vm.prank(_allocator);
    _account.execute(_list);
  }

  function test_APermittedCallRunsAndEmits() external {
    _permit();
    bytes memory _data = abi.encodeCall(IERC20.transfer, (_custodian, 100e6));
    vm.expectEmit(address(_account));
    emit IGuardedAccount.CallMade(address(_asset), IERC20.transfer.selector, _data);
    vm.prank(_allocator);
    _account.execute(_calls(address(_asset), _data));
    assertEq(_asset.balanceOf(_custodian), 100e6);
  }

  function test_ARevokedPermissionRefusesAtOnce() external {
    _permit();
    vm.prank(_guardian);
    _account.revokePermission(address(_asset), IERC20.transfer.selector);
    IGuardedAccount.Call[] memory _list = _pay(_custodian, 1);
    vm.expectRevert(_refused(address(_asset), IERC20.transfer.selector));
    vm.prank(_allocator);
    _account.execute(_list);
  }

  function test_AllOrNothing() external {
    _permit();
    IGuardedAccount.Call[] memory _list = new IGuardedAccount.Call[](2);
    _list[0] = IGuardedAccount.Call({target: address(_asset), data: abi.encodeCall(IERC20.transfer, (_custodian, 1))});
    _list[1] = IGuardedAccount.Call({target: address(_asset), data: abi.encodeCall(IERC20.transfer, (_stranger, 1))});
    vm.expectRevert(_refused(address(_asset), IERC20.transfer.selector));
    vm.prank(_allocator);
    _account.execute(_list);
    assertEq(_asset.balanceOf(_custodian), 0);
  }

  function test_AFailingCallBubblesItsError() external {
    ERC20CallValidator _anyAmount = new ERC20CallValidator(_custodian, type(uint256).max);
    _registry.attest(address(_anyAmount).codehash, IPolicyRegistry.AttestKind.VALIDATOR, '');
    uint256 _tooMuch = _asset.balanceOf(address(_account)) + 1;
    vm.prank(_admin);
    _account.setPermission(address(_asset), IERC20.transfer.selector, address(_anyAmount));
    IGuardedAccount.Call[] memory _list = _pay(_custodian, _tooMuch);
    vm.expectRevert();
    vm.prank(_allocator);
    _account.execute(_list);
  }

  function test_ItCanCallANonExistentContractOnlyByFailing() external {
    address _nothing = makeAddr('nothing');
    vm.prank(_admin);
    _account.setPermission(_nothing, IERC20.transfer.selector, address(_toCustodian));
    IGuardedAccount.Call[] memory _list = _pay(_custodian, 1);
    _list[0].target = _nothing;
    vm.expectRevert(abi.encodeWithSelector(Address.AddressEmptyCode.selector, _nothing));
    vm.prank(_allocator);
    _account.execute(_list);
  }

  function test_ItRunsAStrategyThroughAnOutsideVaultAndKeepsTheShares() external {
    MockERC4626Target _target = new MockERC4626Target(IERC20(address(_asset)));
    ERC20CallValidator _approveTarget = new ERC20CallValidator(address(_target), _CAP);
    ERC4626CallValidator _entry = new ERC4626CallValidator();
    _registry.attest(address(_approveTarget).codehash, IPolicyRegistry.AttestKind.VALIDATOR, '');
    _registry.attest(address(_entry).codehash, IPolicyRegistry.AttestKind.VALIDATOR, '');
    vm.startPrank(_admin);
    _account.setPermission(address(_asset), IERC20.approve.selector, address(_approveTarget));
    _account.setPermission(address(_target), IERC4626.deposit.selector, address(_entry));
    _account.setPermission(address(_target), IERC4626.withdraw.selector, address(_entry));
    vm.stopPrank();

    IGuardedAccount.Call[] memory _list = new IGuardedAccount.Call[](2);
    _list[0] =
      IGuardedAccount.Call({target: address(_asset), data: abi.encodeCall(IERC20.approve, (address(_target), 100e6))});
    _list[1] = IGuardedAccount.Call({
      target: address(_target), data: abi.encodeWithSelector(IERC4626.deposit.selector, 100e6, address(_account))
    });
    vm.prank(_allocator);
    _account.execute(_list);
    assertGt(_target.balanceOf(address(_account)), 0);

    IGuardedAccount.Call[] memory _toStranger =
      _calls(address(_target), abi.encodeWithSelector(IERC4626.withdraw.selector, 1, _stranger, address(_account)));
    vm.expectRevert(_refused(address(_target), IERC4626.withdraw.selector));
    vm.prank(_allocator);
    _account.execute(_toStranger);
  }
}

/// @notice As an adapter of a real portfolio
contract GuardedAccount_AsAnAdapter is GuardedAccountTest {
  function setUp() public override {
    super.setUp();
    _asset.mint(address(_portfolio), 500e6);
    vm.startPrank(_admin);
    _portfolio.addAdapter(address(_account));
    _portfolio.setCaps(_RISK, type(uint120).max, 10_000);
    _portfolio.setCaps(_CUSTODIAN_RISK, type(uint120).max, 10_000);
    vm.stopPrank();
  }

  function test_OnlyThePortfolioAllocates() external {
    vm.expectRevert(_unauthorized(_stranger));
    vm.prank(_stranger);
    _account.allocate(1);
  }

  function test_OnlyThePortfolioDeallocates() external {
    vm.expectRevert(_unauthorized(_stranger));
    vm.prank(_stranger);
    _account.deallocate(1);
  }

  function test_CustodyOutAndBack() external {
    _permit();
    vm.prank(_allocator);
    _portfolio.allocate(address(_account), 400e6, 0);
    assertEq(_asset.balanceOf(address(_account)), 400e6);
    assertEq(_portfolio.allocationOf(address(_account)), 400e6);
    assertEq(_portfolio.pricedValue(), 100e6, 'reported money is not in the price');
    assertEq(_account.liquid(), 400e6);

    vm.prank(_allocator);
    _account.execute(_pay(_custodian, 300e6));
    assertEq(_account.liquid(), 100e6);

    // The custodian returns money by sending it to the account.
    vm.prank(_custodian);
    _asset.transfer(address(_account), 300e6);

    vm.prank(_allocator);
    _portfolio.deallocate(address(_account), 400e6);
    assertEq(_asset.balanceOf(address(_portfolio)), 500e6);
    assertEq(_asset.balanceOf(address(_account)), 0);
    assertEq(_portfolio.allocationOf(address(_account)), 0);
  }

  /// @dev It pays only from its own balance, and only to its portfolio
  function test_MoneyAtTheCustodianCannotBeDeallocated() external {
    _permit();
    vm.prank(_allocator);
    _portfolio.allocate(address(_account), 400e6, 0);
    vm.prank(_allocator);
    _account.execute(_pay(_custodian, 300e6));
    vm.expectRevert();
    vm.prank(_allocator);
    _portfolio.deallocate(address(_account), 200e6);
  }

  function test_ItCountsAgainstBothRisks() external {
    vm.prank(_allocator);
    _portfolio.allocate(address(_account), 400e6, 0);
    assertEq(_portfolio.riskOf(_RISK).allocation, 400e6);
    assertEq(_portfolio.riskOf(_CUSTODIAN_RISK).allocation, 400e6);
  }
}
