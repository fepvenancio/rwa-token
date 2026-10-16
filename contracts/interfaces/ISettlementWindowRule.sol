// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';

/**
 * @title ISettlementWindowRule
 * @notice Executor-settled transfers (EXECUTED) only settle inside a token's daily UTC window, on enabled weekdays;
 *         otherwise `Reasons.OUTSIDE_SETTLEMENT_WINDOW`. Other kinds are unaffected
 * @dev Weekday = ((timestamp / 1 days) + 3) % 7, with Monday = 0. A same-day window is `[open, close)`. When
 *      `open > close` the window runs overnight and belongs to the day it opened: it is open when today is enabled
 *      and `t >= open`, or when yesterday is enabled and `t < close`. A token with no window configured rejects every
 *      EXECUTED movement. The window is set by the token's own DEFAULT_ADMIN_ROLE, checked live
 */
interface ISettlementWindowRule is IComplianceRule {
  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice A token's settlement window
   * @param open Opening second of the UTC day, inclusive
   * @param close Closing second of the UTC day, exclusive
   * @param dayMask Enabled weekdays, bit 0 = Monday ... bit 6 = Sunday; 0 means not configured
   */
  struct Window {
    uint32 open;
    uint32 close;
    uint8 dayMask;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a token's window is set
   * @param _token The token
   * @param _open Opening second of the UTC day
   * @param _close Closing second of the UTC day
   * @param _dayMask Enabled weekdays
   */
  event WindowSet(address indexed _token, uint32 _open, uint32 _close, uint8 _dayMask);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when open or close is not a second of the day, open equals close, or the day mask is invalid
  error SettlementWindowRule_InvalidWindow();

  /**
   * @notice Thrown when the caller does not hold the token's DEFAULT_ADMIN_ROLE
   * @param _token The token
   * @param _caller The unauthorized caller
   */
  error SettlementWindowRule_OnlyTokenAdmin(address _token, address _caller);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Sets a token's settlement window
   * @dev Only the token's DEFAULT_ADMIN_ROLE. Requires `open, close < 1 days`, `open != close` and a non-zero 7-bit
   *      mask; pass `MON_TO_FRI` for the default trading week
   * @param _token The token
   * @param _open Opening second of the UTC day, inclusive
   * @param _close Closing second of the UTC day, exclusive
   * @param _dayMask Enabled weekdays, bit 0 = Monday
   */
  function setWindow(
    address _token,
    uint32 _open,
    uint32 _close,
    uint8 _dayMask
  ) external;

  /**
   * @notice Whether a token's window is open at a timestamp
   * @param _token The token
   * @param _timestamp The unix timestamp
   * @return _open True if an EXECUTED movement would be inside the window; false when not configured
   */
  function isOpen(
    address _token,
    uint256 _timestamp
  ) external view returns (bool _open);

  /**
   * @notice The default weekday mask, Monday to Friday
   * @return _mask 0x1F
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function MON_TO_FRI() external view returns (uint8 _mask);

  /**
   * @notice A token's window
   * @param _token The token
   * @return _window The window; `dayMask == 0` when not configured
   */
  function windowOf(
    address _token
  ) external view returns (Window memory _window);
}
