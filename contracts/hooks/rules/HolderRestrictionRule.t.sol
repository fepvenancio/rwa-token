// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IHolderRestrictionRule} from 'interfaces/IHolderRestrictionRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {HolderRestrictionRule} from 'contracts/hooks/rules/HolderRestrictionRule.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockStatefulToken} from 'contracts/test/MockStatefulToken.sol';

contract HolderRestrictionRuleUnitTest is Helpers {
  bytes32 internal constant _AGENT_ROLE = keccak256('AGENT_ROLE');
  bytes32 internal constant _BURNER_ROLE = keccak256('BURNER_ROLE');
  uint256 internal constant _NOW = 1_792_198_800; // Sat 2026-10-17 01:00 UTC

  HolderRestrictionRule internal _rule;
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
    _rule = new HolderRestrictionRule();
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

  function _freeze(
    address _account,
    bool _frozen
  ) internal {
    vm.prank(_agent);
    _rule.setFrozen(_token, _account, _frozen);
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

contract HolderRestrictionRuleUnit_SetLockup is HolderRestrictionRuleUnitTest {
  function test_WhenCallerIsNotTheTokensAgent_ItReverts() external {
    vm.expectRevert(
      abi.encodeWithSelector(IHolderRestrictionRule.HolderRestrictionRule_OnlyTokenAgent.selector, _token, _stranger)
    );
    vm.prank(_stranger);
    _rule.setLockup(_token, _holder, _NOW + 1);
  }

  function test_WhenHolderIsZero_ItReverts() external {
    vm.expectRevert(IHolderRestrictionRule.HolderRestrictionRule_ZeroAddress.selector);
    vm.prank(_agent);
    _rule.setLockup(_token, address(0), _NOW + 1);
  }

  function test_WhenTheTimeIsInTheFuture_ItStoresAndEmits(
    uint256 _until
  ) external {
    _until = bound(_until, _NOW + 1, type(uint64).max);
    vm.expectEmit(address(_rule));
    emit IHolderRestrictionRule.LockupSet(_token, _holder, _until);
    _lock(_holder, _until);
    assertEq(_rule.unlockTime(_token, _holder), _until);
  }

  /// @dev The time is stored in 64 bits next to the freeze flag, so a larger one is refused, not truncated
  function test_WhenTheTimeDoesNotFitIn64Bits_ItReverts(
    uint256 _until
  ) external {
    _until = bound(_until, uint256(type(uint64).max) + 1, type(uint256).max);
    vm.expectRevert(
      abi.encodeWithSelector(IHolderRestrictionRule.HolderRestrictionRule_UnlockTimeTooLarge.selector, _until)
    );
    vm.prank(_agent);
    _rule.setLockup(_token, _holder, _until);
  }

  function test_WhenTheTimeIsTheLargestThatFits_ItStores() external {
    _lock(_holder, type(uint64).max);
    assertEq(_rule.unlockTime(_token, _holder), type(uint64).max);
  }

  function test_WhenTheTimeIsNowOrPast_ItClearsTheLockupAndEmitsZero(
    uint256 _until
  ) external {
    _lock(_holder, _NOW + 30 days);
    _until = bound(_until, 0, _NOW);
    vm.expectEmit(address(_rule));
    emit IHolderRestrictionRule.LockupSet(_token, _holder, 0);
    _lock(_holder, _until);
    assertEq(_rule.unlockTime(_token, _holder), 0);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER)), Reasons.TRANSFER_OK);
  }

  /// @dev A time far in the past or at zero never reaches the 64-bit check: it is a clear, not a store
  function test_WhenClearing_TheTimeIsNotRangeChecked() external {
    _lock(_holder, 0);
    assertEq(_rule.unlockTime(_token, _holder), 0);
  }

  function test_WhenAHolderIsFrozen_SettingOrClearingTheLockupLeavesTheFreeze() external {
    _freeze(_holder, true);
    _lock(_holder, _NOW + 30 days);
    assertTrue(_rule.isFrozen(_token, _holder));
    _lock(_holder, 0);
    assertTrue(_rule.isFrozen(_token, _holder));
    assertEq(_rule.unlockTime(_token, _holder), 0);
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

contract HolderRestrictionRuleUnit_SetFrozen is HolderRestrictionRuleUnitTest {
  function test_WhenCallerIsNotTheTokensAgent_ItReverts() external {
    vm.expectRevert(
      abi.encodeWithSelector(IHolderRestrictionRule.HolderRestrictionRule_OnlyTokenAgent.selector, _token, _stranger)
    );
    vm.prank(_stranger);
    _rule.setFrozen(_token, _holder, true);
  }

  function test_WhenHolderIsZero_ItReverts() external {
    vm.expectRevert(IHolderRestrictionRule.HolderRestrictionRule_ZeroAddress.selector);
    vm.prank(_agent);
    _rule.setFrozen(_token, address(0), true);
  }

  function test_WhenSet_ItStoresAndEmits(
    bool _frozen
  ) external {
    vm.expectEmit(address(_rule));
    emit IHolderRestrictionRule.HolderFrozenSet(_token, _holder, _frozen);
    _freeze(_holder, _frozen);
    assertEq(_rule.isFrozen(_token, _holder), _frozen);
  }

  function test_WhenAHolderIsLocked_FreezingOrUnfreezingLeavesTheLockup() external {
    _lock(_holder, _NOW + 30 days);
    _freeze(_holder, true);
    assertEq(_rule.unlockTime(_token, _holder), _NOW + 30 days);
    _freeze(_holder, false);
    assertEq(_rule.unlockTime(_token, _holder), _NOW + 30 days);
  }

  /// @dev The two settings share one storage word, so a movement pays one read per side
  function test_WhenBothAreSet_TheyShareOneStorageWord() external {
    _lock(_holder, _NOW + 30 days);
    _freeze(_holder, true);
    // `_restrictions` is the rule's only variable, so it sits at slot 0: unlock time in the low 64 bits, flag above.
    bytes32 _slot = keccak256(abi.encode(_holder, keccak256(abi.encode(_token, uint256(0)))));
    assertEq(uint256(vm.load(address(_rule), _slot)), (uint256(1) << 64) | (_NOW + 30 days));
  }

  function test_WhenAFakeTokenAuthorisesAnAttacker_OnlyTheFakeTokensKeyChanges() external {
    address _fakeToken = _mockContract('fakeToken');
    address _attacker = makeAddr('attacker');
    _role(_fakeToken, _attacker, true);

    vm.prank(_attacker);
    _rule.setFrozen(_fakeToken, _holder, true);

    assertTrue(_rule.isFrozen(_fakeToken, _holder));
    assertFalse(_rule.isFrozen(_token, _holder));
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER)), Reasons.TRANSFER_OK);
  }
}

contract HolderRestrictionRuleUnit_CheckLockup is HolderRestrictionRuleUnitTest {
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

  /// @dev The lock is on the sender's side only: a locked receiver can be paid
  function test_WhenOnlyTheReceiverIsLocked_ItReturnsOk(
    uint8 _seed
  ) external {
    _lock(_to, _NOW + 30 days);
    assertEq(_rule.check(_ctx(_restrictedKind(_seed))), Reasons.TRANSFER_OK);
  }

  function test_WhenCalledWithStaticcall_ItDoesNotWrite() external {
    _lock(_holder, _NOW + 1 days);
    (bool _ok, bytes memory _out) =
      address(_rule).staticcall(abi.encodeCall(IComplianceRule.check, (_ctx(IPolicyHook.TransferKind.TRANSFER))));
    assertTrue(_ok);
    assertEq(abi.decode(_out, (bytes32)), Reasons.LOCKED);
  }
}

contract HolderRestrictionRuleUnit_CheckFreeze is HolderRestrictionRuleUnitTest {
  /// @dev A frozen sender cannot move tokens in any kind but FORCED; a mint has no sender
  function test_WhenTheSenderIsFrozen_EveryHolderDrivenKindIsRejected(
    uint8 _seed
  ) external {
    _freeze(_holder, true);
    IPolicyHook.TransferKind _kind = IPolicyHook.TransferKind(bound(_seed, 0, 1));
    assertEq(_rule.check(_ctx(_kind)), Reasons.SENDER_FROZEN);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.BURN)), Reasons.SENDER_FROZEN);
  }

  /// @dev RD4: the enforcement route out of a frozen account is a forced transfer, not a burn
  function test_WhenTheSenderIsFrozen_AnEnforcementBurnIsRejectedToo() external {
    _freeze(_holder, true);
    IPolicyHook.TransferContext memory _burnCtx = _ctx(IPolicyHook.TransferKind.BURN);
    _burnCtx.operator = _burner;
    assertEq(_rule.check(_burnCtx), Reasons.SENDER_FROZEN);
  }

  function test_WhenTheSenderIsFrozen_ForcedIsExempt() external {
    _freeze(_holder, true);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.FORCED)), Reasons.TRANSFER_OK);
  }

  /// @dev A frozen address in the sender slot of a mint means nothing: the sender is the zero address
  function test_WhenTheSenderIsFrozen_AMintToAnotherAccountIsOk() external {
    _freeze(_holder, true);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.MINT)), Reasons.TRANSFER_OK);
  }

  /// @dev RD4, confirmed by the owner: the freeze on the receiver applies to mint and to forced transfers
  function test_WhenTheReceiverIsFrozen_EveryKindButBurnIsRejected(
    uint8 _seed
  ) external {
    _freeze(_to, true);
    IPolicyHook.TransferKind _kind = IPolicyHook.TransferKind(bound(_seed, 0, 3));
    assertEq(_rule.check(_ctx(_kind)), Reasons.RECEIVER_FROZEN);
  }

  function test_WhenTheReceiverIsFrozen_AnEnforcementMintIsRejected() external {
    _freeze(_to, true);
    IPolicyHook.TransferContext memory _context = _ctx(IPolicyHook.TransferKind.FORCED);
    _context.from = address(0);
    assertEq(_rule.check(_context), Reasons.RECEIVER_FROZEN);
  }

  function test_WhenTheSenderIsFrozen_ABurnNeverAsksTheTokenForRoles() external {
    _freeze(_holder, true);
    vm.expectCall(_token, abi.encodeWithSelector(IAccessControl.hasRole.selector), 0);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.BURN)), Reasons.SENDER_FROZEN);
  }

  /// @dev The sender is judged first: a frozen and locked sender reads as frozen
  function test_WhenTheSenderIsFrozenAndLocked_ItReturnsFrozen() external {
    _freeze(_holder, true);
    _lock(_holder, _NOW + 30 days);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER)), Reasons.SENDER_FROZEN);
  }

  function test_WhenTheSenderIsLockedAndTheReceiverFrozen_ItReturnsLocked() external {
    _freeze(_to, true);
    _lock(_holder, _NOW + 30 days);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER)), Reasons.LOCKED);
  }

  function test_WhenUnfrozen_ItReturnsOkAgain(
    uint8 _seed
  ) external {
    _freeze(_holder, true);
    _freeze(_to, true);
    _freeze(_holder, false);
    _freeze(_to, false);
    assertEq(_rule.check(_ctx(_restrictedKind(_seed))), Reasons.TRANSFER_OK);
  }

  function test_WhenFrozenOnAnotherToken_ItReturnsOk() external {
    address _otherToken = _mockContract('otherToken');
    _role(_otherToken, _agent, true);
    vm.prank(_agent);
    _rule.setFrozen(_otherToken, _holder, true);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER)), Reasons.TRANSFER_OK);
  }

  function test_WhenCalledWithStaticcall_ItDoesNotWrite() external {
    _freeze(_holder, true);
    (bool _ok, bytes memory _out) =
      address(_rule).staticcall(abi.encodeCall(IComplianceRule.check, (_ctx(IPolicyHook.TransferKind.TRANSFER))));
    assertTrue(_ok);
    assertEq(abi.decode(_out, (bytes32)), Reasons.SENDER_FROZEN);
  }
}

/// @notice The freeze is an account-level decision, so `checkSend` and `checkReceive` answer it; the lockup depends on the
///         kind of movement, so they ignore it
contract HolderRestrictionRuleUnit_AccountChecks is HolderRestrictionRuleUnitTest {
  function test_WhenTheAccountIsNotFrozen_BothAccept() external view {
    assertEq(_rule.checkSend(_token, _holder), Reasons.TRANSFER_OK);
    assertEq(_rule.checkReceive(_token, _holder), Reasons.TRANSFER_OK);
  }

  function test_WhenTheAccountIsFrozen_SendReturnsSenderFrozenAndReceiveReceiverFrozen() external {
    _freeze(_holder, true);
    assertEq(_rule.checkSend(_token, _holder), Reasons.SENDER_FROZEN);
    assertEq(_rule.checkReceive(_token, _holder), Reasons.RECEIVER_FROZEN);
  }

  function test_WhenTheAccountIsLocked_BothStillAccept() external {
    _lock(_holder, block.timestamp + 1 days);
    assertEq(_rule.checkSend(_token, _holder), Reasons.TRANSFER_OK);
    assertEq(_rule.checkReceive(_token, _holder), Reasons.TRANSFER_OK);
  }

  /// @dev A rule's `check` and its account checks must agree for the kinds the account checks describe
  function testFuzz_ForAHolderDrivenTransfer_CheckAgreesWithTheAccountChecks(
    uint8 _seed,
    bool _senderFrozen,
    bool _receiverFrozen
  ) external {
    _freeze(_holder, _senderFrozen);
    _freeze(_to, _receiverFrozen);
    bytes32 _send = _rule.checkSend(_token, _holder);
    bytes32 _receive = _rule.checkReceive(_token, _to);
    assertEq(_send, _senderFrozen ? Reasons.SENDER_FROZEN : Reasons.TRANSFER_OK);
    assertEq(_receive, _receiverFrozen ? Reasons.RECEIVER_FROZEN : Reasons.TRANSFER_OK);

    bytes32 _expected = _send != Reasons.TRANSFER_OK ? _send : _receive;
    assertEq(_rule.check(_ctx(_restrictedKind(_seed))), _expected);
  }
}

contract HolderRestrictionRuleUnit_Metadata is HolderRestrictionRuleUnitTest {
  function test_WhenQueried_ItReturnsItsMetadata() external view {
    assertEq(_rule.ruleId(), keccak256('HolderRestrictionRule.v1'));
    assertEq(_rule.AGENT_ROLE(), _AGENT_ROLE);
    assertFalse(_rule.wantsAfter());
    assertTrue(_rule.supportsInterface(type(IComplianceRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(IHolderRestrictionRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(IERC165).interfaceId));
  }
}

/// @dev Aderyn `reentrancy-state-change` is a false positive: the token is read through STATICCALL
contract HolderRestrictionRuleUnit_TokenCallsAreStatic is HolderRestrictionRuleUnitTest {
  function test_WhenTheTokenTriesToWriteDuringTheRoleCheck_SetLockupReverts() external {
    MockStatefulToken _stateful = new MockStatefulToken();
    _stateful.hasRole(_AGENT_ROLE, _agent); // control: the same read writes when called with CALL
    assertEq(_stateful.writes(), 1);

    vm.expectRevert(bytes('')); // a write inside a STATICCALL reverts with empty data, bubbled by the rule
    vm.prank(_agent);
    _rule.setLockup(address(_stateful), _holder, _NOW + 1 days);
    assertEq(_rule.unlockTime(address(_stateful), _holder), 0);
  }

  function test_WhenTheTokenTriesToWriteDuringTheRoleCheck_SetFrozenReverts() external {
    MockStatefulToken _stateful = new MockStatefulToken();

    vm.expectRevert(bytes(''));
    vm.prank(_agent);
    _rule.setFrozen(address(_stateful), _holder, true);
    assertFalse(_rule.isFrozen(address(_stateful), _holder));
  }
}

/// @dev Brief §5: FORCED with `from == address(0)` is an enforcement mint, exempt from the lockup like any FORCED move
contract HolderRestrictionRuleUnit_ForcedMint is HolderRestrictionRuleUnitTest {
  function test_WhenAnEnforcementMintReachesALockedReceiver_ItIsOk() external {
    vm.prank(_agent);
    _rule.setLockup(_token, _to, _NOW + 365 days);
    IPolicyHook.TransferContext memory _context = _ctx(IPolicyHook.TransferKind.FORCED);
    _context.from = address(0);
    assertEq(_rule.check(_context), Reasons.TRANSFER_OK);
  }
}
