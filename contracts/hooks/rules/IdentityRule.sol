// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IIdentityRule} from 'interfaces/IIdentityRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {BaseRule} from 'contracts/hooks/BaseRule.sol';

/**
 * @title IdentityRule
 * @notice Requires verified identities on both legs of a movement, with the exemptions in `IIdentityRule`
 */
contract IdentityRule is BaseRule, IIdentityRule {
  /// @inheritdoc IIdentityRule
  IIdentityRegistry public immutable IDENTITY;

  /**
   * @notice Deploys the rule
   * @param _hook The hook allowed to call `after_`
   * @param _identity The identity registry
   */
  constructor(
    address _hook,
    IIdentityRegistry _identity
  ) BaseRule(_hook) {
    if (address(_identity) == address(0)) revert IdentityRule_ZeroAddress();
    IDENTITY = _identity;
  }

  /// @inheritdoc IComplianceRule
  function check(
    IPolicyHook.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    // A forced transfer must be able to claw back from a de-verified holder; its receiver is still checked below.
    bool _checksSender = _ctx.kind != IPolicyHook.TransferKind.MINT && _ctx.kind != IPolicyHook.TransferKind.FORCED;
    if (_checksSender && !IDENTITY.isVerified(_ctx.from)) {
      return Reasons.SENDER_NOT_VERIFIED;
    }
    if (_ctx.kind != IPolicyHook.TransferKind.BURN && !IDENTITY.isVerified(_ctx.to)) {
      return Reasons.RECEIVER_NOT_VERIFIED;
    }
    _reason = Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IComplianceRule
  function ruleId() external pure returns (bytes32 _ruleId) {
    _ruleId = keccak256('IdentityRule.v1');
  }
}
