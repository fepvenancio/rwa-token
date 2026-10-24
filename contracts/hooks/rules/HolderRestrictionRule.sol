// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IHolderRestrictionRule} from 'interfaces/IHolderRestrictionRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {BaseRule} from 'contracts/hooks/BaseRule.sol';

/**
 * @title HolderRestrictionRule
 * @notice Per-(token, holder) lockup and address freeze set by the token's AGENT_ROLE, as specified in
 *         `IHolderRestrictionRule`
 * @dev Both settings live in one storage word, so a movement costs one read for the sender and one for the receiver. The
 *      sender's word answers the freeze and the lockup; the receiver's answers the freeze
 */
contract HolderRestrictionRule is BaseRule, IHolderRestrictionRule {
  /**
   * @notice A holder's restrictions on one token, packed in one storage word
   * @param unlockTime The first timestamp at which the holder may transfer again; 0 when not locked
   * @param frozen True if the holder can neither send nor receive
   */
  struct Restriction {
    uint64 unlockTime;
    bool frozen;
  }

  /// @inheritdoc IHolderRestrictionRule
  bytes32 public constant AGENT_ROLE = keccak256('AGENT_ROLE');

  /// @notice The token role whose burns are enforcement actions, exempt from lockups
  bytes32 private constant _BURNER_ROLE = keccak256('BURNER_ROLE');

  /// @notice The restrictions per token and holder
  mapping(address _token => mapping(address _holder => Restriction _restriction)) internal _restrictions;

  /**
   * @notice Restricts a function to the token's AGENT_ROLE
   * @param _token The token
   */
  modifier onlyTokenAgent(
    address _token
  ) {
    // View interface: compiled to STATICCALL, so the token cannot change any state (test: *_TokenCallsAreStatic).
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (!IAccessControl(_token).hasRole(AGENT_ROLE, msg.sender)) {
      revert HolderRestrictionRule_OnlyTokenAgent(_token, msg.sender);
    }
    _;
  }

  /// @inheritdoc IHolderRestrictionRule
  function setLockup(
    address _token,
    address _holder,
    uint256 _unlockTime
  ) external onlyTokenAgent(_token) {
    if (_holder == address(0)) revert HolderRestrictionRule_ZeroAddress();
    // A time at or before now clears the lockup, so only a future time has to fit the 64 bits it is stored in. Zero is the
    // stored value of a cleared lockup, so the variable keeps its default.
    // slither-disable-next-line uninitialized-local
    uint64 _stored;
    if (_unlockTime > block.timestamp) {
      if (_unlockTime > type(uint64).max) revert HolderRestrictionRule_UnlockTimeTooLarge(_unlockTime);
      // Checked on the line above.
      // aderyn-ignore-next-line(unsafe-casting)
      _stored = uint64(_unlockTime);
    }
    _restrictions[_token][_holder].unlockTime = _stored;
    emit LockupSet(_token, _holder, _stored);
  }

  /// @inheritdoc IHolderRestrictionRule
  function setFrozen(
    address _token,
    address _holder,
    bool _frozen
  ) external onlyTokenAgent(_token) {
    if (_holder == address(0)) revert HolderRestrictionRule_ZeroAddress();
    _restrictions[_token][_holder].frozen = _frozen;
    emit HolderFrozenSet(_token, _holder, _frozen);
  }

  /**
   * @inheritdoc IComplianceRule
   * @dev The sender is judged first, then the receiver. A forced transfer ignores the sender's freeze and lockup, and a
   *      mint has no sender; a burn has no receiver. The storage word is read before the token is asked for a role, and
   *      the role only while a lockup is active on a burn
   */
  function check(
    IPolicyHook.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    if (_ctx.kind != IPolicyHook.TransferKind.FORCED && _ctx.from != address(0)) {
      Restriction memory _sender = _restrictions[_ctx.token][_ctx.from];
      if (_sender.frozen) return Reasons.SENDER_FROZEN;
      if (block.timestamp < _sender.unlockTime && _lockApplies(_ctx)) return Reasons.LOCKED;
    }
    if (_ctx.to != address(0) && _restrictions[_ctx.token][_ctx.to].frozen) return Reasons.RECEIVER_FROZEN;
    _reason = Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IComplianceRule
  function checkReceive(
    address _token,
    address _account
  ) external view override(BaseRule, IComplianceRule) returns (bytes32 _reason) {
    _reason = _restrictions[_token][_account].frozen ? Reasons.RECEIVER_FROZEN : Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IComplianceRule
  function checkSend(
    address _token,
    address _account
  ) external view override(BaseRule, IComplianceRule) returns (bytes32 _reason) {
    _reason = _restrictions[_token][_account].frozen ? Reasons.SENDER_FROZEN : Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IHolderRestrictionRule
  function isFrozen(
    address _token,
    address _holder
  ) external view returns (bool _frozen) {
    _frozen = _restrictions[_token][_holder].frozen;
  }

  /// @inheritdoc IHolderRestrictionRule
  function unlockTime(
    address _token,
    address _holder
  ) external view returns (uint256 _unlockTime) {
    _unlockTime = _restrictions[_token][_holder].unlockTime;
  }

  /// @inheritdoc IComplianceRule
  function ruleId() external pure returns (bytes32 _ruleId) {
    _ruleId = keccak256('HolderRestrictionRule.v1');
  }

  /// @inheritdoc BaseRule
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(IHolderRestrictionRule).interfaceId || super.supportsInterface(_interfaceId);
  }

  /**
   * @notice Whether an active lockup stops this movement
   * @dev A transfer and an executed intent are stopped. A burn is an enforcement action only when the token's BURNER_ROLE
   *      drives it; a holder-initiated burn (e.g. an ERC-4626 redeem) is an exit and respects the lockup. Other kinds
   *      never reach here
   * @param _ctx The movement context
   * @return _applies True if the lockup stops the movement
   */
  function _lockApplies(
    IPolicyHook.TransferContext calldata _ctx
  ) private view returns (bool _applies) {
    if (_ctx.kind == IPolicyHook.TransferKind.TRANSFER || _ctx.kind == IPolicyHook.TransferKind.EXECUTED) return true;
    _applies =
      _ctx.kind == IPolicyHook.TransferKind.BURN && !IAccessControl(_ctx.token).hasRole(_BURNER_ROLE, _ctx.operator);
  }
}
