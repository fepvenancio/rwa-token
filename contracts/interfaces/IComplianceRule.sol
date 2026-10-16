// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

/**
 * @title IComplianceRule
 * @notice Unit of policy dispatched by a compliance hook. Rules are immutable contracts attested by codehash
 * @dev Rules that keep state MUST key it by `ctx.token` so one deployment can serve many tokens
 */
interface IComplianceRule {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when `after_` is called by an account other than the rule's hook
   * @param _caller The unauthorized caller
   */
  error ComplianceRule_OnlyHook(address _caller);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Post-movement bookkeeping, called by the hook after balances moved when `wantsAfter()` is true
   * @dev Only callable by the hook. MUST NOT call back into the token
   * @param _ctx The movement context
   */
  function after_(
    IPolicyHook.TransferContext calldata _ctx
  ) external;

  /**
   * @notice Policy decision for a balance movement
   * @dev MUST be view. MUST NOT revert on a policy decision
   * @param _ctx The movement context
   * @return _reason `Reasons.TRANSFER_OK` to allow, any other reason code to reject
   */
  function check(
    IPolicyHook.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason);

  /**
   * @notice Whether the hook should call `after_` for this rule
   * @dev The hook reads this once, when the rule set is installed. It MUST be constant for a deployed rule
   * @return _wantsAfter True if `after_` must be called after each movement
   */
  function wantsAfter() external view returns (bool _wantsAfter);

  /**
   * @notice Stable identifier of the rule's logic, emitted when rule sets change
   * @return _ruleId The rule identifier
   */
  function ruleId() external pure returns (bytes32 _ruleId);
}
