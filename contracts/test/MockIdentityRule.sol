// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Reasons} from 'interfaces/Errors.sol';

import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';

import {BaseRule} from 'contracts/hooks/BaseRule.sol';

/**
 * @title MockIdentityRule
 * @notice Test rule: requires `from` to be verified in an identity registry, except on MINT and FORCED, and `to`, except
 *         on BURN. The deployed rule lists use `CredentialRule`; tests use this one where they need a plain identity gate
 */
contract MockIdentityRule is BaseRule {
  /// @notice The identity registry consulted by the rule
  IIdentityRegistry public immutable IDENTITY;

  /**
   * @notice Deploys the rule
   * @param _identity The identity registry
   */
  constructor(
    IIdentityRegistry _identity
  ) {
    IDENTITY = _identity;
  }

  /**
   * @notice Rejects an unverified sender (except on MINT and FORCED) or receiver (except on BURN)
   * @param _ctx The movement
   * @return _reason `TRANSFER_OK`, `SENDER_NOT_ELIGIBLE` or `RECEIVER_NOT_VERIFIED`
   */
  function check(
    IERC8473Policy.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    bool _checksSender = _ctx.kind != IERC8473Policy.TransferKind.MINT && _ctx.kind != IERC8473Policy.TransferKind.FORCED;
    if (_checksSender && !IDENTITY.isVerified(_ctx.from)) return Reasons.SENDER_NOT_ELIGIBLE;
    if (_ctx.kind != IERC8473Policy.TransferKind.BURN && !IDENTITY.isVerified(_ctx.to)) {
      return Reasons.RECEIVER_NOT_VERIFIED;
    }
    _reason = Reasons.TRANSFER_OK;
  }

  /**
   * @notice Whether the account is verified, as a receiver
   * @param _account The account
   * @return _reason `TRANSFER_OK` or `RECEIVER_NOT_VERIFIED`
   */
  function checkReceive(
    address,
    address _account
  ) external view override returns (bytes32 _reason) {
    _reason = IDENTITY.isVerified(_account) ? Reasons.TRANSFER_OK : Reasons.RECEIVER_NOT_VERIFIED;
  }

  /**
   * @notice Whether the account is verified, as a sender
   * @param _account The account
   * @return _reason `TRANSFER_OK` or `SENDER_NOT_ELIGIBLE`
   */
  function checkSend(
    address,
    address _account
  ) external view override returns (bytes32 _reason) {
    _reason = IDENTITY.isVerified(_account) ? Reasons.TRANSFER_OK : Reasons.SENDER_NOT_ELIGIBLE;
  }

  /**
   * @notice The rule type
   * @return _ruleId `keccak256('MockIdentityRule.v1')`
   */
  function ruleId() external pure returns (bytes32 _ruleId) {
    _ruleId = keccak256('MockIdentityRule.v1');
  }
}
