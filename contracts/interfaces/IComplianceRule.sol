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
   * @notice Account-level decision on receiving: whether `_account` may receive tokens of `_token` at all
   * @dev MUST be view and MUST NOT revert on a policy decision. A rule that has no account-level decision returns
   *      `Reasons.TRANSFER_OK` (the default in `BaseRule`). It MUST agree with `check`: if it rejects an account, `check`
   *      rejects every movement to that account of a kind this rule does not exempt from the receiver side. The one
   *      allowed gap is a rule that can tell from the movement that it frees what the account would take: a holder cap
   *      answers for an account that is not yet a holder as `check` answers for a mint, and a transfer that empties its
   *      sender can still admit one. It MUST NOT depend on an amount, because integrators ask it to learn whether an
   *      account can take part at all
   * @param _token The token
   * @param _account The prospective receiver
   * @return _reason `Reasons.TRANSFER_OK` to allow, any other reason code to reject
   */
  function checkReceive(
    address _token,
    address _account
  ) external view returns (bytes32 _reason);

  /**
   * @notice Account-level decision on sending: whether `_account` may send tokens of `_token` at all
   * @dev MUST be view and MUST NOT revert on a policy decision. A rule that has no account-level decision returns
   *      `Reasons.TRANSFER_OK` (the default in `BaseRule`). It MUST agree with `check`: if it rejects an account, `check`
   *      rejects every movement from that account of a kind this rule does not exempt from the sender side
   * @param _token The token
   * @param _account The prospective sender
   * @return _reason `Reasons.TRANSFER_OK` to allow, any other reason code to reject
   */
  function checkSend(
    address _token,
    address _account
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
