// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC8473} from 'interfaces/IERC8473.sol';
import {IPolicyGatedCore} from 'interfaces/IPolicyGatedCore.sol';
import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ISupplyCapRule} from 'interfaces/ISupplyCapRule.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {SupplyCapRule} from 'contracts/hooks/rules/SupplyCapRule.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {GatedToken} from 'contracts/tokens/GatedToken.sol';

contract SupplyCapRuleUnitTest is Helpers {
  bytes32 internal constant _DEFAULT_ADMIN_ROLE = 0x00;
  uint256 internal constant _CAP = 1000;

  SupplyCapRule internal _rule;
  address internal _token;
  address internal _admin = makeAddr('admin');
  address internal _stranger = makeAddr('stranger');
  address internal _to = makeAddr('to');

  function setUp() public {
    _rule = new SupplyCapRule();
    _token = _mockContract('token');
    vm.mockCall(_token, abi.encodeCall(IAccessControl.hasRole, (_DEFAULT_ADMIN_ROLE, _admin)), abi.encode(true));
    vm.mockCall(_token, abi.encodeCall(IAccessControl.hasRole, (_DEFAULT_ADMIN_ROLE, _stranger)), abi.encode(false));
    _supply(0);
    vm.prank(_admin);
    _rule.setSupplyCap(_token, _CAP);
  }

  function _supply(
    uint256 _amount
  ) internal {
    vm.mockCall(_token, abi.encodeCall(IERC20.totalSupply, ()), abi.encode(_amount));
  }

  function _ctx(
    IERC8473Policy.TransferKind _kind,
    uint256 _amount
  ) internal view returns (IERC8473Policy.TransferContext memory _context) {
    _context = IERC8473Policy.TransferContext({
      token: _token, from: address(0), to: _to, tokenId: 0, amount: _amount, operator: _admin, kind: _kind, data: ''
    });
  }
}

contract SupplyCapRuleUnit_Set is SupplyCapRuleUnitTest {
  function test_ItAnswersForItsInterfaces() external view {
    assertTrue(_rule.supportsInterface(type(ISupplyCapRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(IComplianceRule).interfaceId));
    assertFalse(_rule.supportsInterface(0xdeadbeef));
  }

  function test_TheAdminSetsItAndItEmits() external {
    vm.expectEmit(address(_rule));
    emit ISupplyCapRule.SupplyCapSet(_token, _CAP, 7);
    vm.prank(_admin);
    _rule.setSupplyCap(_token, 7);
    assertEq(_rule.supplyCap(_token), 7);
  }

  function test_NobodyElseSetsIt() external {
    vm.expectRevert(abi.encodeWithSelector(ISupplyCapRule.SupplyCapRule_OnlyTokenAdmin.selector, _token, _stranger));
    vm.prank(_stranger);
    _rule.setSupplyCap(_token, 7);
  }
}

contract SupplyCapRuleUnit_Check is SupplyCapRuleUnitTest {
  function test_UpToTheCapPasses() external view {
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.MINT, _CAP)), Reasons.TRANSFER_OK);
  }

  function test_OneAboveTheCapIsRefused() external view {
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.MINT, _CAP + 1)), Reasons.ABOVE_SUPPLY_CAP);
  }

  function testFuzz_ItCountsWhatIsAlreadyThere(
    uint256 _existing,
    uint256 _amount
  ) external {
    _existing = bound(_existing, 0, 2 * _CAP);
    _amount = bound(_amount, 0, type(uint256).max);
    _supply(_existing);
    bool _fits = _existing <= _CAP && _amount <= _CAP - _existing;
    assertEq(
      _rule.check(_ctx(IERC8473Policy.TransferKind.MINT, _amount)), _fits ? Reasons.TRANSFER_OK : Reasons.ABOVE_SUPPLY_CAP
    );
  }

  /// @dev Lowering a cap below the supply stops further mints and does not revert
  function test_AboveALoweredCapAMintIsRefusedAndNothingReverts() external {
    _supply(_CAP + 500);
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.MINT, 1)), Reasons.ABOVE_SUPPLY_CAP);
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.MINT, 0)), Reasons.ABOVE_SUPPLY_CAP);
  }

  function test_WithNoCapSetItFailsClosed() external {
    address _unset = _mockContract('unset');
    vm.mockCall(_unset, abi.encodeCall(IERC20.totalSupply, ()), abi.encode(uint256(0)));
    IERC8473Policy.TransferContext memory _c = _ctx(IERC8473Policy.TransferKind.MINT, 1);
    _c.token = _unset;
    assertEq(_rule.check(_c), Reasons.ABOVE_SUPPLY_CAP);
  }

  function testFuzz_EveryOtherKindPasses(
    uint8 _kindSeed,
    uint256 _amount
  ) external {
    IERC8473Policy.TransferKind _kind = IERC8473Policy.TransferKind(bound(_kindSeed, 0, 4));
    if (_kind == IERC8473Policy.TransferKind.MINT) _kind = IERC8473Policy.TransferKind.FORCED;
    _supply(_CAP);
    assertEq(_rule.check(_ctx(_kind, _amount)), Reasons.TRANSFER_OK);
  }

  function test_ItAsksNothingAboutAnotherKind() external {
    vm.expectCall(_token, abi.encodeCall(IERC20.totalSupply, ()), 0);
    _rule.check(_ctx(IERC8473Policy.TransferKind.TRANSFER, 1));
  }

  function test_ItHasNoAccountLevelOpinion() external view {
    assertEq(_rule.checkSend(_token, _to), Reasons.TRANSFER_OK);
    assertEq(_rule.checkReceive(_token, _to), Reasons.TRANSFER_OK);
    assertFalse(_rule.wantsAfter());
    assertEq(_rule.ruleId(), keccak256('SupplyCapRule.v1'));
    assertTrue(_rule.supportsInterface(type(IComplianceRule).interfaceId));
  }

  function test_CheckIsAView() external {
    vm.record();
    _rule.check(_ctx(IERC8473Policy.TransferKind.MINT, 1));
    (, bytes32[] memory _writes) = vm.accesses(address(_rule));
    assertEq(_writes.length, 0);
  }
}

/// @notice In a real hook on a real token: the pre-flight agrees with the write
contract SupplyCapRuleIntegration is Helpers {
  uint256 internal constant _CAP = 1000;

  GatedToken internal _token;
  SupplyCapRule internal _rule;
  address internal _guardian = makeAddr('guardian');
  address internal _minter = makeAddr('minter');
  address internal _alice = makeAddr('alice');

  function setUp() public {
    PolicyRegistry _registry = new PolicyRegistry(address(this), address(this));
    _rule = new SupplyCapRule();
    _registry.attest(address(_rule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    ComplianceHook _hook = new ComplianceHook(_registry);
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    GatedToken _impl = new GatedToken();
    _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    IComplianceRule[] memory _rules = new IComplianceRule[](1);
    _rules[0] = _rule;
    ProxyDeployer _deployer = new ProxyDeployer(address(this), _registry);
    _token = GatedToken(
      _deployer.deploy(
        'CAP',
        address(_impl),
        abi.encodeCall(
          GatedToken.initialize,
          ('Capped', 'CAP', 18, address(this), _guardian, address(_registry), address(_hook), _rules)
        ),
        address(_hook),
        _rules
      )
    );
    _token.grantRole(_token.MINTER_ROLE(), _minter);
    _rule.setSupplyCap(address(_token), _CAP);
  }

  function test_AStolenMinterKeyStopsAtTheCap() external {
    vm.prank(_minter);
    _token.mint(_alice, _CAP);
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(address(0), _alice, 1);
    assertFalse(_ok);
    assertEq(_reason, Reasons.ABOVE_SUPPLY_CAP);
    vm.expectRevert(
      abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, Reasons.ABOVE_SUPPLY_CAP)
    );
    vm.prank(_minter);
    _token.mint(_alice, 1);
    assertEq(_token.totalSupply(), _CAP);
  }

  function test_AHolderKeepsMovingAtTheCap() external {
    vm.prank(_minter);
    _token.mint(_alice, _CAP);
    vm.prank(_alice);
    _token.transfer(_minter, 1);
    assertEq(_token.balanceOf(_minter), 1);
  }
}
