// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {ICredentialRegistry} from 'interfaces/ICredentialRegistry.sol';
import {ICredentialRule} from 'interfaces/ICredentialRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

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
    IPolicyHook.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    IPolicyHook.TransferKind _kind = _ctx.kind;
    // The sender is checked on every kind except MINT (no sender) and FORCED (an enforcement move must be able to take
    // from a blocked holder). The receiver is checked on every kind except BURN (no receiver).
    if (_kind != IPolicyHook.TransferKind.MINT && _kind != IPolicyHook.TransferKind.FORCED) {
      _reason = _checkSender(_ctx);
      if (_reason != Reasons.TRANSFER_OK) return _reason;
    }
    _reason = _kind == IPolicyHook.TransferKind.BURN ? Reasons.TRANSFER_OK : _checkReceiver(_ctx);
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
   * @notice The sender must be able to leave: `ACTIVE`, `EXIT_ONLY` or `LAPSED`. A sender that is `NONE` or `BLOCKED`
   *         passes only on a BURN whose operator holds the token's BURNER_ROLE (enforcement), looked up only then
   * @param _ctx The movement context
   * @return _reason `TRANSFER_OK` or `SENDER_NOT_VERIFIED`
   */
  function _checkSender(
    IPolicyHook.TransferContext calldata _ctx
  ) internal view returns (bytes32 _reason) {
    // Only the standing decides here; the bits, country and attester matter for a receiver.
    // slither-disable-next-line unused-return
    (ICredentialRegistry.Status _status,,,) = REGISTRY.profileOf(_ctx.from);
    if (_status != ICredentialRegistry.Status.NONE && _status != ICredentialRegistry.Status.BLOCKED) {
      return Reasons.TRANSFER_OK;
    }
    // View interface: compiled to STATICCALL, so the token cannot change any state (test: *_TokenCallsAreStatic).
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (_ctx.kind == IPolicyHook.TransferKind.BURN && IAccessControl(_ctx.token).hasRole(_BURNER_ROLE, _ctx.operator)) {
      return Reasons.TRANSFER_OK;
    }
    _reason = Reasons.SENDER_NOT_VERIFIED;
  }

  /**
   * @notice The receiver must be `ACTIVE` and satisfy the token's policy. A token with no policy admits nobody. The
   *         policy is read first, so an unconfigured token reports that and not the receiver's standing
   * @param _ctx The movement context
   * @return _reason `TRANSFER_OK`, `RECEIVER_NOT_VERIFIED`, `CREDENTIAL_EXPIRED` or `RECEIVER_NOT_ELIGIBLE`
   */
  function _checkReceiver(
    IPolicyHook.TransferContext calldata _ctx
  ) internal view returns (bytes32 _reason) {
    Policy memory _policy = _policies[_ctx.token];
    if (_policy.attesters == 0) return Reasons.RECEIVER_NOT_ELIGIBLE;

    // The country is stored for later rules; no policy reads it yet.
    // slither-disable-next-line unused-return
    (ICredentialRegistry.Status _status, uint32 _quals,, uint8 _attester) = REGISTRY.profileOf(_ctx.to);
    if (_status == ICredentialRegistry.Status.LAPSED) return Reasons.CREDENTIAL_EXPIRED;
    if (_status != ICredentialRegistry.Status.ACTIVE) return Reasons.RECEIVER_NOT_VERIFIED;

    bool _eligible = (_policy.attesters >> _attester) & 1 == 1 && _quals & _policy.requireAll == _policy.requireAll
      && (_policy.requireAny == 0 || _quals & _policy.requireAny != 0) && _quals & _policy.forbidAny == 0;
    _reason = _eligible ? Reasons.TRANSFER_OK : Reasons.RECEIVER_NOT_ELIGIBLE;
  }
}
