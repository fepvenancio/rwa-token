// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';

/**
 * @title IMinPositionRule
 * @notice Per-token minimum position: after a movement, each side that still holds tokens must hold at least the
 *         minimum, so no dust is left behind and no dust can open a holder slot. A breach is rejected with
 *         `Reasons.BELOW_MIN_POSITION`. A minimum of 0 switches the rule off for the token
 * @dev Applies to TRANSFER, EXECUTED, MINT and holder-initiated BURN. FORCED is exempt, and so are the token itself (the
 *      7540 escrow, which holds the shares of pending redemptions) and the accounts the token's admin lists. The
 *      post-move balances are derived from the balances in `TransferContext.extra` and the amount, so the rule makes
 *      no call back into the token. State is keyed by token and authorised live by the token's own DEFAULT_ADMIN_ROLE
 */
interface IMinPositionRule is IComplianceRule {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a token's minimum position changes
   * @param _token The token
   * @param _oldMin The previous minimum
   * @param _newMin The new minimum; 0 is off
   */
  event MinPositionSet(address indexed _token, uint256 _oldMin, uint256 _newMin);

  /**
   * @notice Emitted when an account is exempted from, or returned to, the minimum
   * @param _token The token
   * @param _account The account
   * @param _exempt True if the account is now exempt
   */
  event MinPositionExemptionSet(address indexed _token, address indexed _account, bool _exempt);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when the caller does not hold the token's DEFAULT_ADMIN_ROLE
   * @param _token The token
   * @param _caller The unauthorized caller
   */
  // Thrown by `MinPositionRule`, built in S3 of the review items plan; unused until then.
  // aderyn-ignore-next-line(unused-error)
  error MinPositionRule_OnlyTokenAdmin(address _token, address _caller);

  /// @notice Thrown when the account is the zero address
  // Thrown by `MinPositionRule`, built in S3 of the review items plan; unused until then.
  // aderyn-ignore-next-line(unused-error)
  error MinPositionRule_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Sets a token's minimum position
   * @dev Only the token's DEFAULT_ADMIN_ROLE. 0 switches the rule off for the token
   * @param _token The token
   * @param _amount The minimum, in token units
   */
  function setMinPosition(
    address _token,
    uint256 _amount
  ) external;

  /**
   * @notice Exempts an account from the minimum on a token, or returns it to the rule
   * @dev Only the token's DEFAULT_ADMIN_ROLE
   * @param _token The token
   * @param _account The account
   * @param _exempt True to exempt
   */
  function setExempt(
    address _token,
    address _account,
    bool _exempt
  ) external;

  /**
   * @notice A token's minimum position
   * @param _token The token
   * @return _amount The minimum; 0 when off
   */
  function minPosition(
    address _token
  ) external view returns (uint256 _amount);

  /**
   * @notice Whether an account is exempt from the minimum on a token
   * @param _token The token
   * @param _account The account
   * @return _exempt True if exempt
   */
  function isExempt(
    address _token,
    address _account
  ) external view returns (bool _exempt);
}
