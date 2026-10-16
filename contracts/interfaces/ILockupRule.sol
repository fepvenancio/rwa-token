// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';

/**
 * @title ILockupRule
 * @notice Per-(token, holder) lockup: TRANSFER, EXECUTED and holder-initiated BURN (e.g. an ERC-4626 redeem) from a
 *         holder are rejected with `Reasons.LOCKED` until its unlock time. FORCED, MINT, and BURN driven by the token's
 *         BURNER_ROLE (enforcement) are exempt. The lock covers the holder's whole balance
 * @dev Lockups are set by the token's own AGENT_ROLE, checked live; state is keyed by token
 */
interface ILockupRule is IComplianceRule {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a holder's lockup is set or cleared
   * @param _token The token
   * @param _holder The holder
   * @param _unlockTime The stored unlock time; 0 when cleared
   */
  event LockupSet(address indexed _token, address indexed _holder, uint256 _unlockTime);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when the caller does not hold the token's AGENT_ROLE
   * @param _token The token
   * @param _caller The unauthorized caller
   */
  error LockupRule_OnlyTokenAgent(address _token, address _caller);

  /// @notice Thrown when the holder is the zero address
  error LockupRule_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Sets a holder's unlock time on a token
   * @dev Only the token's AGENT_ROLE. A time at or before `block.timestamp` clears the lockup (stored as 0)
   * @param _token The token
   * @param _holder The holder
   * @param _unlockTime The first timestamp at which the holder may transfer again
   */
  function setLockup(
    address _token,
    address _holder,
    uint256 _unlockTime
  ) external;

  /**
   * @notice The token role allowed to set lockups
   * @return _role keccak256('AGENT_ROLE'), as in the token base
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function AGENT_ROLE() external view returns (bytes32 _role);

  /**
   * @notice A holder's unlock time on a token
   * @param _token The token
   * @param _holder The holder
   * @return _unlockTime The unlock time; 0 when not locked
   */
  function unlockTime(
    address _token,
    address _holder
  ) external view returns (uint256 _unlockTime);
}
