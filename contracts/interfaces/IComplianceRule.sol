// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';

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
    IERC8473Policy.TransferContext calldata _ctx
  ) external;

  /**
   * @notice Called by the hook when a token installs it, for every rule in that token's list
   * @dev A rule that keeps state derived from the token's movements must confirm here that the state is current, or
   *      revert, which undoes the installation (ERC-8473, policy requirement 16). `BaseRule` does nothing. A rule that
   *      writes state here must accept only the token's installed policy as the caller
   * @param _token The token installing the policy
   * @param _previousPolicy The policy the token consulted until now; address(0) on the first installation
   */
  function onInstall(
    address _token,
    address _previousPolicy
  ) external;

  /**
   * @notice Policy decision for a balance movement
   * @dev MUST be view. MUST NOT revert on a policy decision, nor for an `amount` above the sender's balance in `data`:
   *      the write does not offer the hook such an amount, but `canTransfer` does. Compare before you subtract
   * @param _ctx The movement context
   * @return _reason `Reasons.TRANSFER_OK` to allow, any other reason code to reject
   */
  function check(
    IERC8473Policy.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason);

  /**
   * @notice Account-level decision on receiving: whether `_account` may receive tokens of `_token` at all
   * @dev MUST be view and MUST NOT revert on a policy decision. A rule that has no account-level decision returns
   *      `Reasons.TRANSFER_OK` (the default in `BaseRule`). It MUST agree with `check`: if it rejects an account, `check`
   *      rejects every movement to that account of a kind this rule does not exempt from the receiver side. It MUST NOT
   *      depend on an amount or encode a quantitative rule (a holder count, a balance, a limit): ERC-7943 says the account
   *      questions must not encode quantitative rules, so those belong to `check`
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
   *      rejects every movement from that account of a kind this rule does not exempt from the sender side. It MUST NOT
   *      depend on an amount or encode a quantitative rule, as for `checkReceive`
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
