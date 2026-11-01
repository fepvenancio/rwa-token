// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IExecutedOnlyRule} from 'interfaces/IExecutedOnlyRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {BaseRule} from 'contracts/hooks/BaseRule.sol';

/**
 * @title ExecutedOnlyRule
 * @notice Refuses a plain transfer, as specified in `IExecutedOnlyRule`
 */
contract ExecutedOnlyRule is BaseRule, IExecutedOnlyRule {
  /// @inheritdoc IComplianceRule
  function check(
    IPolicyHook.TransferContext calldata _ctx
  ) external pure returns (bytes32 _reason) {
    _reason = _ctx.kind == IPolicyHook.TransferKind.TRANSFER ? Reasons.TRANSFER_NOT_EXECUTED : Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IComplianceRule
  function ruleId() external pure returns (bytes32 _id) {
    _id = keccak256('ExecutedOnlyRule.v1');
  }
}
