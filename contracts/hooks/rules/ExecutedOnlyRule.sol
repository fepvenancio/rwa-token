// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IExecutedOnlyRule} from 'interfaces/IExecutedOnlyRule.sol';
import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';

import {BaseRule} from 'contracts/hooks/BaseRule.sol';

/**
 * @title ExecutedOnlyRule
 * @notice Refuses a plain transfer, as specified in `IExecutedOnlyRule`
 */
contract ExecutedOnlyRule is BaseRule, IExecutedOnlyRule {
  /// @inheritdoc IComplianceRule
  function check(
    IERC8473Policy.TransferContext calldata _ctx
  ) external pure returns (bytes32 _reason) {
    _reason = _ctx.kind == IERC8473Policy.TransferKind.TRANSFER ? Reasons.KIND_NOT_ALLOWED : Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IComplianceRule
  function ruleId() external pure returns (bytes32 _id) {
    _id = keccak256('ExecutedOnlyRule.v1');
  }
}
