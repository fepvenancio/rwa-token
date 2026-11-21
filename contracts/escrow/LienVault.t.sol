// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {ICredentialRegistry} from 'interfaces/ICredentialRegistry.sol';
import {IERC8473} from 'interfaces/IERC8473.sol';
import {ILienVault} from 'interfaces/ILienVault.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {Quals} from 'interfaces/Quals.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {LienVault} from 'contracts/escrow/LienVault.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {CredentialRule} from 'contracts/hooks/rules/CredentialRule.sol';
import {HolderRestrictionRule} from 'contracts/hooks/rules/HolderRestrictionRule.sol';
import {CredentialRegistry} from 'contracts/identity/CredentialRegistry.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {GatedToken} from 'contracts/tokens/GatedToken.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';

/// @notice A token that keeps one unit of every transfer
contract FeeToken is ERC20 {
  constructor() ERC20('Fee', 'FEE') {
    _mint(msg.sender, 1e18);
  }

  function _update(
    address _from,
    address _to,
    uint256 _value
  ) internal override {
    if (_from != address(0) && _to != address(0)) {
      super._update(_from, address(0xdead), 1);
      --_value;
    }
    super._update(_from, _to, _value);
  }
}

/// @notice A token that calls back into whoever it is told to, in the middle of a transfer
contract CallbackToken is ERC20 {
  address public target;
  bytes public callData;

  constructor() ERC20('Callback', 'CB') {
    _mint(msg.sender, 1e18);
  }

  function arm(
    address _target,
    bytes calldata _callData
  ) external {
    target = _target;
    callData = _callData;
  }

  /// @notice Calls `_target` as this token, and reverts with its reason
  function poke(
    address _target,
    bytes calldata _callData
  ) external {
    (bool _ok, bytes memory _returned) = _target.call(_callData);
    if (!_ok) {
      assembly ('memory-safe') {
        revert(add(_returned, 0x20), mload(_returned))
      }
    }
  }

  function _update(
    address _from,
    address _to,
    uint256 _value
  ) internal override {
    address _armed = target;
    if (_armed != address(0)) {
      target = address(0);
      (bool _ok, bytes memory _returned) = _armed.call(callData);
      if (!_ok) {
        assembly ('memory-safe') {
          revert(add(_returned, 0x20), mload(_returned))
        }
      }
    }
    super._update(_from, _to, _value);
  }
}

/**
 * @notice The escrow on a real token: a `GatedToken` behind the real credential registry, `CredentialRule`,
 *         `HolderRestrictionRule` and hook. This test contract is the token's admin and the attester
 */
abstract contract LienVaultTest is Test {
  uint64 internal constant _FOREVER = type(uint64).max;
  bytes32 internal constant _AGENT_ROLE = keccak256('AGENT_ROLE');
  bytes32 internal constant _MINTER_ROLE = keccak256('MINTER_ROLE');
  uint256 internal constant _HELD = 1000e18;

  PolicyRegistry internal _registry;
  CredentialRegistry internal _creds;
  CredentialRule internal _rule;
  HolderRestrictionRule internal _restriction;
  ComplianceHook internal _hook;
  ProxyDeployer internal _deployer;
  GatedToken internal _token;
  LienVault internal _vault;
  IComplianceRule[] internal _rules;

  address internal _guardian = makeAddr('guardian');
  address internal _agent = makeAddr('agent');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');
  address internal _lenderOne = makeAddr('lenderOne');
  address internal _lenderTwo = makeAddr('lenderTwo');
  address internal _quarantine = makeAddr('quarantine');
  address internal _stranger = makeAddr('stranger');

  function setUp() public virtual {
    _registry = new PolicyRegistry(address(this), address(this));
    _creds = new CredentialRegistry(address(this), _guardian);
    _creds.addAttester(address(this), type(uint32).max);
    _rule = new CredentialRule(_creds);
    _restriction = new HolderRestrictionRule();
    _registry.attest(address(_rule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_restriction).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _hook = new ComplianceHook(_registry);
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _deployer = new ProxyDeployer(address(this), _registry);
    _rules.push(_rule);
    _rules.push(_restriction);

    address _impl = address(new GatedToken());
    _registry.attest(_impl.codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _token = GatedToken(
      _deployer.deploy(
        'gBOND',
        _impl,
        abi.encodeCall(
          GatedToken.initialize,
          ('Bond', 'gBOND', 18, address(this), _guardian, address(_registry), address(_hook), _rules)
        ),
        address(_hook),
        _rules
      )
    );
    _rule.setPolicy(address(_token), Quals.KYC, 0, 0, 1);
    _token.grantRole(_AGENT_ROLE, _agent);
    _token.grantRole(_MINTER_ROLE, address(this));

    _vault = new LienVault();
    address[6] memory _admitted = [address(_vault), _alice, _bob, _lenderOne, _lenderTwo, _quarantine];
    for (uint256 _i; _i < _admitted.length; ++_i) {
      _creds.set(_admitted[_i], _FOREVER, Quals.KYC, 0);
    }
    _token.mint(_alice, _HELD);
    vm.prank(_alice);
    _token.approve(address(_vault), type(uint256).max);
  }

  function _pledge(
    address _beneficiary,
    uint256 _amount
  ) internal returns (uint256 _lienId) {
    vm.prank(_alice);
    _lienId = _vault.pledge(address(_token), _amount, _beneficiary);
  }

  function _rejected(
    bytes32 _reason
  ) internal pure returns (bytes memory _error) {
    _error = abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, _reason);
  }

  function _unauthorized(
    address _caller
  ) internal pure returns (bytes memory _error) {
    _error = abi.encodeWithSelector(ILienVault.LienVault_Unauthorized.selector, _caller);
  }
}

contract LienVault_Pledge is LienVaultTest {
  function test_APledgeMovesTheTokensAndOpensALien() public {
    vm.expectEmit(address(_vault));
    emit ILienVault.LienOpened(1, address(_token), _alice, _lenderOne, 400e18);
    uint256 _lienId = _pledge(_lenderOne, 400e18);

    assertEq(_lienId, 1);
    assertEq(_vault.lienCount(), 1);
    assertEq(_token.balanceOf(_alice), 600e18);
    assertEq(_token.balanceOf(address(_vault)), 400e18);
    ILienVault.Lien memory _lien = _vault.lienOf(1);
    assertEq(_lien.token, address(_token));
    assertEq(_lien.pledgor, _alice);
    assertEq(_lien.beneficiary, _lenderOne);
    assertEq(_lien.amount, 400e18);
    assertEq(_vault.pledgedOf(address(_token), _alice), 400e18);
    assertEq(_vault.totalPledged(address(_token)), 400e18);
  }

  function test_TheHolderCannotMoveWhatItPledgedAndCanMoveTheRest() public {
    _pledge(_lenderOne, 400e18);
    vm.startPrank(_alice);
    vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, _alice, 600e18, 600e18 + 1));
    _token.transfer(_bob, 600e18 + 1);
    _token.transfer(_bob, 600e18);
    vm.stopPrank();
    assertEq(_token.balanceOf(_bob), 600e18);
  }

  function test_TheHolderCannotReleaseSeizeOrAssignItsOwnLien() public {
    uint256 _lienId = _pledge(_lenderOne, 400e18);
    vm.startPrank(_alice);
    vm.expectRevert(_unauthorized(_alice));
    _vault.release(_lienId, 1);
    vm.expectRevert(_unauthorized(_alice));
    _vault.seize(_lienId, 1);
    vm.expectRevert(_unauthorized(_alice));
    _vault.assign(_lienId, _alice);
    vm.expectRevert(_unauthorized(_alice));
    _vault.recover(_lienId, _alice);
    vm.stopPrank();
  }

  function test_OnlyThePledgorAddsToALien() public {
    uint256 _lienId = _pledge(_lenderOne, 400e18);
    vm.expectRevert(_unauthorized(_lenderOne));
    vm.prank(_lenderOne);
    _vault.increase(_lienId, 1);

    vm.expectEmit(address(_vault));
    emit ILienVault.LienIncreased(_lienId, 100e18);
    vm.prank(_alice);
    _vault.increase(_lienId, 100e18);
    assertEq(_vault.lienOf(_lienId).amount, 500e18);
    assertEq(_vault.pledgedOf(address(_token), _alice), 500e18);
    assertEq(_vault.totalPledged(address(_token)), 500e18);
    assertEq(_token.balanceOf(address(_vault)), 500e18);
  }

  function test_AHolderInsideItsLockupCannotPledge() public {
    vm.prank(_agent);
    _restriction.setLockup(address(_token), _alice, block.timestamp + 30 days);
    vm.expectRevert(_rejected(Reasons.LOCKED_UP));
    vm.prank(_alice);
    _vault.pledge(address(_token), 1e18, _lenderOne);
  }

  function test_AZeroValueIsRefusedEverywhere() public {
    uint256 _lienId = _pledge(_lenderOne, 400e18);
    bytes4 _invalid = ILienVault.LienVault_InvalidValue.selector;
    vm.startPrank(_alice);
    vm.expectRevert(_invalid);
    _vault.pledge(address(0), 1, _lenderOne);
    vm.expectRevert(_invalid);
    _vault.pledge(address(_token), 0, _lenderOne);
    vm.expectRevert(_invalid);
    _vault.pledge(address(_token), 1, address(0));
    vm.expectRevert(_invalid);
    _vault.pledge(address(_token), 1, address(_vault));
    vm.expectRevert(_invalid);
    _vault.increase(_lienId, 0);
    vm.stopPrank();

    vm.startPrank(_lenderOne);
    vm.expectRevert(_invalid);
    _vault.release(_lienId, 0);
    vm.expectRevert(_invalid);
    _vault.seize(_lienId, 0);
    vm.expectRevert(_invalid);
    _vault.assign(_lienId, address(0));
    vm.expectRevert(_invalid);
    _vault.assign(_lienId, address(_vault));
    vm.stopPrank();

    vm.startPrank(_agent);
    vm.expectRevert(_invalid);
    _vault.recover(_lienId, address(0));
    vm.expectRevert(_invalid);
    _vault.recover(_lienId, address(_vault));
    vm.stopPrank();
  }

  function test_ATokenThatKeepsAFeeIsRefused() public {
    FeeToken _fee = new FeeToken();
    _fee.approve(address(_vault), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(ILienVault.LienVault_WrongAmountReceived.selector, 100, 99));
    _vault.pledge(address(_fee), 100, _lenderOne);
  }

  function test_ABeneficiaryCannotReenterFromTheTokensCallback() public {
    CallbackToken _callback = new CallbackToken();
    _callback.approve(address(_vault), type(uint256).max);
    // The token is the lien's beneficiary, so its call from inside a transfer is one the vault would otherwise accept.
    uint256 _lienId = _vault.pledge(address(_callback), 100, address(_callback));

    _callback.arm(address(_vault), abi.encodeCall(ILienVault.seize, (_lienId, 50)));
    vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    _callback.poke(address(_vault), abi.encodeCall(ILienVault.seize, (_lienId, 50)));
    assertEq(_vault.lienOf(_lienId).amount, 100);
  }
}

contract LienVault_Beneficiary is LienVaultTest {
  uint256 internal _one;
  uint256 internal _two;

  function setUp() public override {
    super.setUp();
    _one = _pledge(_lenderOne, 400e18);
    _two = _pledge(_lenderTwo, 300e18);
  }

  function test_TwoLendersHoldLiensOnOneHolderAndNeitherTouchesTheOthers() public {
    assertEq(_vault.pledgedOf(address(_token), _alice), 700e18);
    vm.startPrank(_lenderOne);
    vm.expectRevert(_unauthorized(_lenderOne));
    _vault.release(_two, 1);
    vm.expectRevert(_unauthorized(_lenderOne));
    _vault.seize(_two, 1);
    vm.expectRevert(_unauthorized(_lenderOne));
    _vault.assign(_two, _lenderOne);
    vm.stopPrank();

    vm.prank(_lenderOne);
    _vault.seize(_one, 400e18);
    assertEq(_vault.lienOf(_two).amount, 300e18);
    assertEq(_token.balanceOf(address(_vault)), 300e18);
  }

  function test_AReleaseInPartsGoesToThePledgorAndNeverPastTheAmount() public {
    vm.startPrank(_lenderOne);
    vm.expectEmit(address(_vault));
    emit ILienVault.LienReleased(_one, 150e18);
    _vault.release(_one, 150e18);
    assertEq(_token.balanceOf(_alice), 450e18);
    assertEq(_vault.lienOf(_one).amount, 250e18);

    vm.expectRevert(abi.encodeWithSelector(ILienVault.LienVault_ExceedsLien.selector, _one, 250e18 + 1, 250e18));
    _vault.release(_one, 250e18 + 1);
    _vault.release(_one, 250e18);
    vm.stopPrank();

    // A lien that holds nothing is closed.
    assertEq(_vault.lienOf(_one).pledgor, address(0));
    assertEq(_vault.pledgedOf(address(_token), _alice), 300e18);
    assertEq(_vault.totalPledged(address(_token)), 300e18);
    vm.expectRevert(abi.encodeWithSelector(ILienVault.LienVault_NoLien.selector, _one));
    vm.prank(_lenderOne);
    _vault.release(_one, 1);
  }

  function test_ASeizureInPartsGoesToTheBeneficiaryAndNeverPastTheAmount() public {
    vm.startPrank(_lenderTwo);
    vm.expectEmit(address(_vault));
    emit ILienVault.LienSeized(_two, _lenderTwo, 100e18);
    _vault.seize(_two, 100e18);
    assertEq(_token.balanceOf(_lenderTwo), 100e18);

    vm.expectRevert(abi.encodeWithSelector(ILienVault.LienVault_ExceedsLien.selector, _two, 200e18 + 1, 200e18));
    _vault.seize(_two, 200e18 + 1);
    _vault.seize(_two, 200e18);
    vm.stopPrank();
    assertEq(_token.balanceOf(_lenderTwo), 300e18);
    assertEq(_token.balanceOf(_alice), 300e18);
    assertEq(_vault.totalPledged(address(_token)), 400e18);
  }

  function test_APaymentFromTheHolderToItsLenderLeavesTheLienAsItWas() public {
    vm.prank(_alice);
    _token.transfer(_lenderOne, 50e18);
    assertEq(_vault.lienOf(_one).amount, 400e18);
    assertEq(_token.balanceOf(address(_vault)), 700e18);
  }

  function test_ABeneficiaryThePolicyRefusesCannotSeizeAndCanAfterAssigning() public {
    _creds.setStatus(_lenderOne, ICredentialRegistry.Status.BLOCKED);
    vm.startPrank(_lenderOne);
    vm.expectRevert();
    _vault.seize(_one, 400e18);

    vm.expectEmit(address(_vault));
    emit ILienVault.LienAssigned(_one, _lenderOne, _lenderTwo);
    _vault.assign(_one, _lenderTwo);
    vm.expectRevert(_unauthorized(_lenderOne));
    _vault.seize(_one, 1);
    vm.stopPrank();

    vm.prank(_lenderTwo);
    _vault.seize(_one, 400e18);
    assertEq(_token.balanceOf(_lenderTwo), 400e18);
  }

  function test_AReleaseToAFrozenPledgorIsRefusedAndTheTokensStay() public {
    vm.prank(_agent);
    _restriction.setFrozen(address(_token), _alice, true);
    vm.expectRevert(_rejected(Reasons.RECEIVER_FROZEN));
    vm.prank(_lenderOne);
    _vault.release(_one, 400e18);
    assertEq(_vault.lienOf(_one).amount, 400e18);
    assertEq(_token.balanceOf(address(_vault)), 700e18);
  }

  function test_NothingLeavesWhileTheTokenIsPaused() public {
    vm.prank(_guardian);
    _token.pause();
    vm.expectRevert(_rejected(Reasons.PAUSED));
    vm.prank(_lenderOne);
    _vault.seize(_one, 1);
    vm.expectRevert(_rejected(Reasons.PAUSED));
    vm.prank(_agent);
    _vault.recover(_one, _quarantine);
  }
}

contract LienVault_Recover is LienVaultTest {
  uint256 internal _one;

  function setUp() public override {
    super.setUp();
    _one = _pledge(_lenderOne, 400e18);
  }

  function test_TheTokensAgentRecoversALienWhenThePledgorAndTheBeneficiaryAreBothRefused() public {
    vm.prank(_agent);
    _restriction.setFrozen(address(_token), _alice, true);
    _creds.setStatus(_lenderOne, ICredentialRegistry.Status.BLOCKED);

    vm.expectEmit(address(_vault));
    emit ILienVault.LienRecovered(_one, _quarantine, 400e18, _agent);
    vm.prank(_agent);
    _vault.recover(_one, _quarantine);

    assertEq(_token.balanceOf(_quarantine), 400e18);
    assertEq(_vault.lienOf(_one).pledgor, address(0));
    assertEq(_vault.pledgedOf(address(_token), _alice), 0);
    assertEq(_vault.totalPledged(address(_token)), 0);
  }

  function test_NobodyElseRecovers() public {
    address[4] memory _callers = [_alice, _lenderOne, _stranger, address(this)];
    for (uint256 _i; _i < _callers.length; ++_i) {
      vm.expectRevert(_unauthorized(_callers[_i]));
      vm.prank(_callers[_i]);
      _vault.recover(_one, _quarantine);
    }
  }

  function test_ARecoveryToAnAccountThePolicyRefusesIsRefused() public {
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_agent);
    _vault.recover(_one, _stranger);
    assertEq(_vault.lienOf(_one).amount, 400e18);
  }

  function test_OnATokenWithNoRolesNobodyRecovers() public {
    MockAsset _plain = new MockAsset(6);
    _plain.mint(address(this), 100);
    _plain.approve(address(_vault), 100);
    uint256 _lienId = _vault.pledge(address(_plain), 100, _lenderOne);
    vm.expectRevert();
    _vault.recover(_lienId, _quarantine);
    assertEq(_vault.lienOf(_lienId).amount, 100);
  }

  function test_ALienThatNeverExistedIsNoLien() public {
    vm.expectRevert(abi.encodeWithSelector(ILienVault.LienVault_NoLien.selector, 99));
    vm.prank(_agent);
    _vault.recover(99, _quarantine);
    vm.expectRevert(abi.encodeWithSelector(ILienVault.LienVault_NoLien.selector, 99));
    _vault.increase(99, 1);
  }
}

contract LienVault_VaultShares is LienVaultTest {
  Gated4626Vault internal _fund;
  MockAsset internal _asset;

  function setUp() public override {
    super.setUp();
    _asset = new MockAsset(6);
    address _impl = address(new Gated4626Vault());
    _registry.attest(_impl.codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _fund = Gated4626Vault(
      _deployer.deploy(
        'gFUND',
        _impl,
        abi.encodeCall(
          Gated4626Vault.initialize,
          (
            IERC20(address(_asset)),
            'Fund',
            'gFUND',
            address(this),
            _guardian,
            address(_registry),
            address(_hook),
            _rules
          )
        ),
        address(_hook),
        _rules
      )
    );
    _rule.setPolicy(address(_fund), Quals.KYC, 0, 0, 1);
    _asset.mint(_alice, 1000e6);
    vm.startPrank(_alice);
    _asset.approve(address(_fund), type(uint256).max);
    _fund.deposit(1000e6, _alice);
    _fund.approve(address(_vault), type(uint256).max);
    vm.stopPrank();
  }

  function test_PledgedSharesAreNotRedeemableAndMaxRedeemIsExact() public {
    uint256 _shares = _fund.balanceOf(_alice);
    vm.prank(_alice);
    uint256 _lienId = _vault.pledge(address(_fund), _shares / 4, _lenderOne);

    uint256 _max = _fund.maxRedeem(_alice);
    assertEq(_max, _shares - _shares / 4);
    vm.startPrank(_alice);
    vm.expectRevert();
    _fund.redeem(_max + 1, _alice, _alice);
    _fund.redeem(_max, _alice, _alice);
    vm.stopPrank();
    assertEq(_asset.balanceOf(_alice), 750e6);

    // The lender takes the shares and redeems them itself.
    vm.startPrank(_lenderOne);
    _vault.seize(_lienId, _shares / 4);
    _fund.redeem(_shares / 4, _lenderOne, _lenderOne);
    vm.stopPrank();
    assertEq(_asset.balanceOf(_lenderOne), 250e6);
  }
}

/// @notice Calls the escrow at random, as a holder, two lenders and the agent
contract LienVaultHandler is Test {
  LienVault internal immutable _VAULT;
  GatedToken internal immutable _TOKEN;
  address internal immutable _AGENT;
  address[3] internal _actors;

  constructor(
    LienVault _vault,
    GatedToken _token,
    address _agent,
    address[3] memory _allActors
  ) {
    _VAULT = _vault;
    _TOKEN = _token;
    _AGENT = _agent;
    _actors = _allActors;
  }

  function pledge(
    uint256 _who,
    uint256 _to,
    uint256 _amount
  ) external {
    address _pledgor = _actors[_who % 3];
    _amount = bound(_amount, 0, _TOKEN.balanceOf(_pledgor));
    vm.prank(_pledgor);
    try _VAULT.pledge(address(_TOKEN), _amount, _actors[_to % 3]) {} catch {}
  }

  function increase(
    uint256 _lienId,
    uint256 _amount
  ) external {
    ILienVault.Lien memory _lien = _lienAt(_lienId);
    vm.prank(_lien.pledgor);
    try _VAULT.increase(_idAt(_lienId), bound(_amount, 0, _TOKEN.balanceOf(_lien.pledgor))) {} catch {}
  }

  function release(
    uint256 _lienId,
    uint256 _amount
  ) external {
    ILienVault.Lien memory _lien = _lienAt(_lienId);
    vm.prank(_lien.beneficiary);
    try _VAULT.release(_idAt(_lienId), bound(_amount, 0, _lien.amount + 1)) {} catch {}
  }

  function seize(
    uint256 _lienId,
    uint256 _amount
  ) external {
    ILienVault.Lien memory _lien = _lienAt(_lienId);
    vm.prank(_lien.beneficiary);
    try _VAULT.seize(_idAt(_lienId), bound(_amount, 0, _lien.amount + 1)) {} catch {}
  }

  function assign(
    uint256 _lienId,
    uint256 _to
  ) external {
    vm.prank(_lienAt(_lienId).beneficiary);
    try _VAULT.assign(_idAt(_lienId), _actors[_to % 3]) {} catch {}
  }

  function recover(
    uint256 _lienId,
    uint256 _to
  ) external {
    vm.prank(_AGENT);
    try _VAULT.recover(_idAt(_lienId), _actors[_to % 3]) {} catch {}
  }

  function _idAt(
    uint256 _seed
  ) internal view returns (uint256 _lienId) {
    _lienId = bound(_seed, 0, _VAULT.lienCount() + 1);
  }

  function _lienAt(
    uint256 _seed
  ) internal view returns (ILienVault.Lien memory _lien) {
    _lien = _VAULT.lienOf(_idAt(_seed));
  }
}

contract LienVault_Invariant is LienVaultTest {
  address[3] internal _actors;

  function setUp() public override {
    super.setUp();
    _actors = [_alice, _lenderOne, _lenderTwo];
    for (uint256 _i = 1; _i < 3; ++_i) {
      _token.mint(_actors[_i], _HELD);
      vm.prank(_actors[_i]);
      _token.approve(address(_vault), type(uint256).max);
    }
    targetContract(address(new LienVaultHandler(_vault, _token, _agent, _actors)));
  }

  function invariant_TheBalanceCoversTheLiensAndTheSumsAgree() public view {
    uint256 _sum;
    uint256[3] memory _perPledgor;
    for (uint256 _id = 1; _id <= _vault.lienCount(); ++_id) {
      ILienVault.Lien memory _lien = _vault.lienOf(_id);
      _sum += _lien.amount;
      for (uint256 _i; _i < 3; ++_i) {
        if (_lien.pledgor == _actors[_i]) _perPledgor[_i] += _lien.amount;
      }
    }
    assertEq(_vault.totalPledged(address(_token)), _sum);
    assertEq(_token.balanceOf(address(_vault)), _sum);
    for (uint256 _i; _i < 3; ++_i) {
      assertEq(_vault.pledgedOf(address(_token), _actors[_i]), _perPledgor[_i]);
    }
    assertEq(_token.totalSupply(), 3 * _HELD);
  }
}
