// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {ILockupRule} from 'interfaces/ILockupRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {LockupRule} from 'contracts/hooks/rules/LockupRule.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockStatefulToken} from 'contracts/test/MockStatefulToken.sol';

contract LockupRuleUnitTest is Helpers {
  bytes32 internal constant _AGENT_ROLE = keccak256('AGENT_ROLE');
  bytes32 internal constant _BURNER_ROLE = keccak256('BURNER_ROLE');
  uint256 internal constant _NOW = 1_792_198_800; // Sat 2026-10-17 01:00 UTC

  LockupRule internal _rule;
  address internal _token;
  address internal _agent = makeAddr('agent');
  address internal _stranger = makeAddr('stranger');
  address internal _holder = makeAddr('holder');
  address internal _to = makeAddr('to');
  address internal _burner = makeAddr('burner');

  function setUp() public virtual {
    vm.warp(_NOW);
    _token = _mockContract('token');
    _role(_token, _agent, true);
    _role(_token, _stranger, false);
    vm.mockCall(_token, abi.encodeCall(IAccessControl.hasRole, (_BURNER_ROLE, _burner)), abi.encode(true));
    vm.mockCall(_token, abi.encodeCall(IAccessControl.hasRole, (_BURNER_ROLE, _holder)), abi.encode(false));
    _rule = new LockupRule();
  }

  function _role(
    address _forToken,
    address _account,
    bool _has
  ) internal {
    vm.mockCall(_forToken, abi.encodeCall(IAccessControl.hasRole, (_AGENT_ROLE, _account)), abi.encode(_has));
  }

  function _lock(
    address _account,
    uint256 _until
  ) internal {
    vm.prank(_agent);
    _rule.setLockup(_token, _account, _until);
  }

  function _ctx(
    IPolicyHook.TransferKind _kind
  ) internal view returns (IPolicyHook.TransferContext memory _context) {
    _context = IPolicyHook.TransferContext({
      token: _token,
      from: _kind == IPolicyHook.TransferKind.MINT ? address(0) : _holder,
      to: _kind == IPolicyHook.TransferKind.BURN ? address(0) : _to,
      id: 0,
      amount: 1,
      operator: _holder,
      kind: _kind,
      extra: abi.encode(uint256(0), uint256(0))
    });
  }

  /// @dev Maps a fuzzed seed onto TRANSFER or EXECUTED, the kinds a lockup restricts
  function _restrictedKind(
    uint8 _seed
  ) internal pure returns (IPolicyHook.TransferKind _kind) {
    _kind = IPolicyHook.TransferKind(bound(_seed, 0, 1));
  }
}

contract LockupRuleUnit_SetLockup is LockupRuleUnitTest {
  function test_WhenCallerIsNotTheTokensAgent_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(ILockupRule.LockupRule_OnlyTokenAgent.selector, _token, _stranger));
    vm.prank(_stranger);
    _rule.setLockup(_token, _holder, _NOW + 1);
  }

  function test_WhenHolderIsZero_ItReverts() external {
    vm.expectRevert(ILockupRule.LockupRule_ZeroAddress.selector);
    vm.prank(_agent);
    _rule.setLockup(_token, address(0), _NOW + 1);
  }

  function test_WhenTheTimeIsInTheFuture_ItStoresAndEmits(
    uint256 _until
  ) external {
    _until = bound(_until, _NOW + 1, type(uint64).max);
    vm.expectEmit(address(_rule));
    emit ILockupRule.LockupSet(_token, _holder, _until);
    _lock(_holder, _until);
    assertEq(_rule.unlockTime(_token, _holder), _until);
  }

  function test_WhenTheTimeIsNowOrPast_ItClearsTheLockupAndEmitsZero(
    uint256 _until
  ) external {
    _lock(_holder, _NOW + 30 days);
    _until = bound(_until, 0, _NOW);
    vm.expectEmit(address(_rule));
    emit ILockupRule.LockupSet(_token, _holder, 0);
    _lock(_holder, _until);
    assertEq(_rule.unlockTime(_token, _holder), 0);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER)), Reasons.TRANSFER_OK);
  }

  /// @dev Sound because state is keyed by token: a fake token can only authorise writes to its own key
  function test_WhenAFakeTokenAuthorisesAnAttacker_OnlyTheFakeTokensKeyChanges() external {
    address _fakeToken = _mockContract('fakeToken');
    address _attacker = makeAddr('attacker');
    _role(_fakeToken, _attacker, true);

    vm.prank(_attacker);
    _rule.setLockup(_fakeToken, _holder, _NOW + 365 days);

    assertEq(_rule.unlockTime(_fakeToken, _holder), _NOW + 365 days);
    assertEq(_rule.unlockTime(_token, _holder), 0);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER)), Reasons.TRANSFER_OK);
  }
}

contract LockupRuleUnit_Check is LockupRuleUnitTest {
  function test_WhenTheHolderIsNotLocked_ItReturnsOk(
    uint8 _seed
  ) external view {
    assertEq(_rule.check(_ctx(_restrictedKind(_seed))), Reasons.TRANSFER_OK);
  }

  function test_WhenLockedAndBeforeUnlock_ItReturnsLocked(
    uint8 _seed,
    uint256 _remaining
  ) external {
    _remaining = bound(_remaining, 1, 3650 days);
    _lock(_holder, _NOW + _remaining);
    assertEq(_rule.check(_ctx(_restrictedKind(_seed))), Reasons.LOCKED);
  }

  function test_WhenTheUnlockSecondArrives_ItReturnsOk(
    uint8 _seed,
    uint256 _remaining
  ) external {
    _remaining = bound(_remaining, 1, 3650 days);
    _lock(_holder, _NOW + _remaining);
    vm.warp(_NOW + _remaining - 1);
    assertEq(_rule.check(_ctx(_restrictedKind(_seed))), Reasons.LOCKED);
    vm.warp(_NOW + _remaining);
    assertEq(_rule.check(_ctx(_restrictedKind(_seed))), Reasons.TRANSFER_OK);
  }

  function test_WhenLocked_ForcedAndMintAreExempt() external {
    _lock(_holder, _NOW + 30 days);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.FORCED)), Reasons.TRANSFER_OK);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.MINT)), Reasons.TRANSFER_OK);
  }

  /// @dev V1 regression: a holder-initiated burn (e.g. an ERC-4626 redeem) let a locked holder exit
  function test_WhenLockedAndTheHolderBurns_ItReturnsLocked() external {
    _lock(_holder, _NOW + 30 days);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.BURN)), Reasons.LOCKED);
  }

  function test_WhenLockedAndAnEnforcementBurnerBurns_ItIsExempt() external {
    _lock(_holder, _NOW + 30 days);
    IPolicyHook.TransferContext memory _burnCtx = _ctx(IPolicyHook.TransferKind.BURN);
    _burnCtx.operator = _burner;
    assertEq(_rule.check(_burnCtx), Reasons.TRANSFER_OK);
  }

  function test_WhenNotLocked_ABurnNeverAsksTheTokenForRoles() external {
    vm.expectCall(_token, abi.encodeWithSelector(IAccessControl.hasRole.selector), 0);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.BURN)), Reasons.TRANSFER_OK);
  }

  function test_WhenCalledWithStaticcall_ItDoesNotWrite() external {
    _lock(_holder, _NOW + 1 days);
    (bool _ok, bytes memory _out) =
      address(_rule).staticcall(abi.encodeCall(IComplianceRule.check, (_ctx(IPolicyHook.TransferKind.TRANSFER))));
    assertTrue(_ok);
    assertEq(abi.decode(_out, (bytes32)), Reasons.LOCKED);
  }
}

contract LockupRuleUnit_Metadata is LockupRuleUnitTest {
  function test_WhenQueried_ItReturnsItsMetadata() external view {
    assertEq(_rule.ruleId(), keccak256('LockupRule.v1'));
    assertEq(_rule.AGENT_ROLE(), _AGENT_ROLE);
    assertFalse(_rule.wantsAfter());
    assertTrue(_rule.supportsInterface(type(IComplianceRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(ILockupRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(IERC165).interfaceId));
  }
}

/// @dev Aderyn `reentrancy-state-change` is a false positive: the token is read through STATICCALL
contract LockupRuleUnit_TokenCallsAreStatic is LockupRuleUnitTest {
  function test_WhenTheTokenTriesToWriteDuringTheRoleCheck_SetLockupReverts() external {
    MockStatefulToken _stateful = new MockStatefulToken();
    _stateful.hasRole(_AGENT_ROLE, _agent); // control: the same read writes when called with CALL
    assertEq(_stateful.writes(), 1);

    vm.expectRevert(bytes('')); // a write inside a STATICCALL reverts with empty data, bubbled by the rule
    vm.prank(_agent);
    _rule.setLockup(address(_stateful), _holder, _NOW + 1 days);
    assertEq(_rule.unlockTime(address(_stateful), _holder), 0);
  }
}

/// @dev Brief §5: FORCED with `from == address(0)` is an enforcement mint, exempt like any FORCED move
contract LockupRuleUnit_ForcedMint is LockupRuleUnitTest {
  function test_WhenAnEnforcementMintReachesALockedReceiver_ItIsOk() external {
    vm.prank(_agent);
    _rule.setLockup(_token, _to, _NOW + 365 days);
    IPolicyHook.TransferContext memory _context = _ctx(IPolicyHook.TransferKind.FORCED);
    _context.from = address(0);
    assertEq(_rule.check(_context), Reasons.TRANSFER_OK);
  }
}

/// @notice A lockup depends on the kind of movement, so the rule has no account-level opinion
contract LockupRuleUnit_AccountChecks is LockupRuleUnitTest {
  function test_WhenAskedAtAccountLevel_ItAccepts() external {
    _lock(_holder, block.timestamp + 1 days);
    assertEq(_rule.checkSend(_token, _holder), Reasons.TRANSFER_OK);
    assertEq(_rule.checkReceive(_token, _holder), Reasons.TRANSFER_OK);
  }
}
