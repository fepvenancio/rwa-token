// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {ICredentialRegistry} from 'interfaces/ICredentialRegistry.sol';
import {ICredentialRule} from 'interfaces/ICredentialRule.sol';
import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';

import {BaseRule} from 'contracts/hooks/BaseRule.sol';

/**
 * @title CredentialRule
 * @notice Applies a per-token policy to the records of a credential registry, as specified in `ICredentialRule`
 * @dev Keeps no running state and has no `after_`: the registry is the state, so a rule that is removed from a hook and
 *      added back misses nothing. State is keyed by token and set by the token's own DEFAULT_ADMIN_ROLE
 */
contract CredentialRule is BaseRule, ICredentialRule {
  /// @notice The token role allowed to set its policy (OZ DEFAULT_ADMIN_ROLE)
  bytes32 private constant _DEFAULT_ADMIN_ROLE = 0x00;

  /// @notice The token role whose burns are enforcement actions, exempt from the sender check
  bytes32 private constant _BURNER_ROLE = keccak256('BURNER_ROLE');

  /// @inheritdoc ICredentialRule
  ICredentialRegistry public immutable REGISTRY;

  /// @notice Each token's policy
  mapping(address _token => Policy _policy) internal _policies;

  /**
   * @notice Deploys the rule
   * @param _registry The credential registry
   */
  constructor(
    ICredentialRegistry _registry
  ) {
    if (address(_registry) == address(0)) revert CredentialRule_ZeroAddress();
    REGISTRY = _registry;
  }

  /// @inheritdoc ICredentialRule
  function setPolicy(
    address _token,
    uint32 _requireAll,
    uint32 _requireAny,
    uint32 _forbidAny,
    uint64 _attesters
  ) external {
    // View interface: compiled to STATICCALL, so the token cannot change any state (test: *_TokenCallsAreStatic).
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (!IAccessControl(_token).hasRole(_DEFAULT_ADMIN_ROLE, msg.sender)) {
      revert CredentialRule_OnlyTokenAdmin(_token, msg.sender);
    }
    _policies[_token] =
      Policy({requireAll: _requireAll, requireAny: _requireAny, forbidAny: _forbidAny, attesters: _attesters});
    emit PolicySet(_token, _requireAll, _requireAny, _forbidAny, _attesters);
  }

  /// @inheritdoc IComplianceRule
  function check(
    IERC8473Policy.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    IERC8473Policy.TransferKind _kind = _ctx.kind;
    // The sender is checked on every kind except MINT (no sender) and FORCED (an enforcement move must be able to take
    // from a blocked holder). The receiver is checked on every kind except BURN (no receiver).
    if (_kind != IERC8473Policy.TransferKind.MINT && _kind != IERC8473Policy.TransferKind.FORCED) {
      _reason = _checkSender(_ctx);
      if (_reason != Reasons.TRANSFER_OK) return _reason;
    }
    _reason = _kind == IERC8473Policy.TransferKind.BURN ? Reasons.TRANSFER_OK : _receiveReason(_ctx.token, _ctx.to);
  }

  /// @inheritdoc IComplianceRule
  function checkReceive(
    address _token,
    address _account
  ) external view override(BaseRule, IComplianceRule) returns (bytes32 _reason) {
    _reason = _receiveReason(_token, _account);
  }

  /// @inheritdoc IComplianceRule
  function checkSend(
    address _token,
    address _account
  ) external view override(BaseRule, IComplianceRule) returns (bytes32 _reason) {
    _reason = _sendReason(_token, _account);
  }

  /// @inheritdoc ICredentialRule
  function policyOf(
    address _token
  ) external view returns (Policy memory _policy) {
    _policy = _policies[_token];
  }

  /// @inheritdoc IComplianceRule
  function ruleId() external pure returns (bytes32 _ruleId) {
    _ruleId = keccak256('CredentialRule.v1');
  }

  /// @inheritdoc BaseRule
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(ICredentialRule).interfaceId || super.supportsInterface(_interfaceId);
  }

  /**
   * @notice The sender of a movement: the account must be able to leave, or the movement must be an enforcement burn
   * @dev The BURNER_ROLE lookup happens only when the account cannot leave
   * @param _ctx The movement context
   * @return _reason `TRANSFER_OK` or `SENDER_NOT_ELIGIBLE`
   */
  function _checkSender(
    IERC8473Policy.TransferContext calldata _ctx
  ) internal view returns (bytes32 _reason) {
    _reason = _sendReason(_ctx.token, _ctx.from);
    if (_reason == Reasons.TRANSFER_OK) return _reason;
    // View interface: compiled to STATICCALL, so the token cannot change any state (test: *_TokenCallsAreStatic).
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (_ctx.kind == IERC8473Policy.TransferKind.BURN && IAccessControl(_ctx.token).hasRole(_BURNER_ROLE, _ctx.operator)) {
      _reason = Reasons.TRANSFER_OK;
    }
  }

  /**
   * @notice Whether an account may send at all: `ACTIVE`, `EXIT_ONLY` or `LAPSED`. `NONE` and `BLOCKED` may not
   * @param _token The token
   * @param _account The prospective sender
   * @return _reason `TRANSFER_OK` or `SENDER_NOT_ELIGIBLE`
   */
  function _sendReason(
    address _token,
    address _account
  ) internal view returns (bytes32 _reason) {
    // The token's own address holds a 7540's escrow. A credential there could lapse and stop every redemption.
    if (_account == _token) return Reasons.TRANSFER_OK;
    // Only the standing decides here; the bits and attester matter for a receiver.
    // slither-disable-next-line unused-return
    (ICredentialRegistry.Status _status,,) = REGISTRY.profileOf(_account);
    _reason = _status != ICredentialRegistry.Status.NONE && _status != ICredentialRegistry.Status.BLOCKED
      ? Reasons.TRANSFER_OK
      : Reasons.SENDER_NOT_ELIGIBLE;
  }

  /**
   * @notice Whether an account may receive tokens of a token: `ACTIVE` and within the token's policy. A token with no
   *         policy admits nobody. The policy is read first, so an unconfigured token reports that and not the standing
   * @param _token The token
   * @param _account The prospective receiver
   * @return _reason `TRANSFER_OK`, `RECEIVER_NOT_VERIFIED`, `CREDENTIAL_EXPIRED` or `RECEIVER_NOT_ELIGIBLE`
   */
  function _receiveReason(
    address _token,
    address _account
  ) internal view returns (bytes32 _reason) {
    // See `_sendReason`.
    if (_account == _token) return Reasons.TRANSFER_OK;
    Policy memory _policy = _policies[_token];
    if (_policy.attesters == 0) return Reasons.RECEIVER_NOT_ELIGIBLE;

    (ICredentialRegistry.Status _status, uint32 _quals, uint8 _attester) = REGISTRY.profileOf(_account);
    if (_status == ICredentialRegistry.Status.LAPSED) return Reasons.CREDENTIAL_EXPIRED;
    if (_status != ICredentialRegistry.Status.ACTIVE) return Reasons.RECEIVER_NOT_VERIFIED;

    bool _eligible = (_policy.attesters >> _attester) & 1 == 1 && _quals & _policy.requireAll == _policy.requireAll
      && (_policy.requireAny == 0 || _quals & _policy.requireAny != 0) && _quals & _policy.forbidAny == 0;
    _reason = _eligible ? Reasons.TRANSFER_OK : Reasons.RECEIVER_NOT_ELIGIBLE;
  }
}
