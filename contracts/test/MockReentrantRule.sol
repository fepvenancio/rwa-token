// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {BaseRule} from 'contracts/hooks/BaseRule.sol';

/**
 * @title MockReentrantRule
 * @notice Rule that tries to re-enter the token from `after_`; the token's reentrancy guard must block it
 */
contract MockReentrantRule is BaseRule {
  /**
   * @notice Deploys the rule
   * @param _hook The hook allowed to call `after_`
   */
  constructor(
    address _hook
  ) BaseRule(_hook) {}

  /// @inheritdoc IComplianceRule
  function after_(
    IPolicyHook.TransferContext calldata _ctx
  ) external override onlyHook {
    IERC20(_ctx.token).transfer(_ctx.to, 0);
  }

  /// @inheritdoc IComplianceRule
  function check(
    IPolicyHook.TransferContext calldata
  ) external pure returns (bytes32 _reason) {
    _reason = Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IComplianceRule
  function ruleId() external pure returns (bytes32 _ruleId) {
    _ruleId = keccak256('MockReentrantRule');
  }

  /// @inheritdoc BaseRule
  function wantsAfter() public pure override returns (bool _wantsAfter) {
    _wantsAfter = true;
  }
}
