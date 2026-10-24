// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';

/**
 * @title IHolderRestrictionRule
 * @notice Per-(token, holder) restrictions set by the token's AGENT_ROLE: a lockup and an address freeze, packed in one
 *         storage word so a movement costs one read per side. Replaces `ILockupRule`
 * @dev Lockup: TRANSFER, EXECUTED and holder-initiated BURN (e.g. an ERC-4626 redeem) from a locked holder are rejected
 *      with `Reasons.LOCKED` until the unlock time; FORCED, MINT and BURN driven by the token's BURNER_ROLE are exempt.
 *      The lock covers the whole balance. It is kind-dependent, so it is part of `check` only, not of `checkSend`.
 *      Freeze: a frozen account can neither send nor receive. `checkSend` returns `Reasons.SENDER_FROZEN` and
 *      `checkReceive` returns `Reasons.RECEIVER_FROZEN`, and `check` applies the same to a movement: a frozen sender is
 *      rejected for every kind except FORCED, a frozen receiver for every kind except BURN, so a mint to a frozen
 *      account and a forced transfer into one are rejected. A quarantine account is therefore never frozen. State is keyed
 *      by token and authorised live by the token's own roles
 */
interface IHolderRestrictionRule is IComplianceRule {
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

  /**
   * @notice Emitted when a holder is frozen or unfrozen
   * @param _token The token
   * @param _holder The holder
   * @param _frozen True if the holder is now frozen
   */
  event HolderFrozenSet(address indexed _token, address indexed _holder, bool _frozen);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when the caller does not hold the token's AGENT_ROLE
   * @param _token The token
   * @param _caller The unauthorized caller
   */
  // Thrown by `HolderRestrictionRule`, built in S3 of the review items plan; unused until then.
  // aderyn-ignore-next-line(unused-error)
  error HolderRestrictionRule_OnlyTokenAgent(address _token, address _caller);

  /// @notice Thrown when the holder is the zero address
  // Thrown by `HolderRestrictionRule`, built in S3 of the review items plan; unused until then.
  // aderyn-ignore-next-line(unused-error)
  error HolderRestrictionRule_ZeroAddress();

  /**
   * @notice Thrown when an unlock time does not fit the 64 bits it is stored in
   * @param _unlockTime The unlock time given
   */
  // Thrown by `HolderRestrictionRule`, built in S3 of the review items plan; unused until then.
  // aderyn-ignore-next-line(unused-error)
  error HolderRestrictionRule_UnlockTimeTooLarge(uint256 _unlockTime);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Sets a holder's unlock time on a token
   * @dev Only the token's AGENT_ROLE. A time at or before `block.timestamp` clears the lockup (stored as 0). Leaves the
   *      freeze as it is
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
   * @notice Freezes or unfreezes a holder on a token
   * @dev Only the token's AGENT_ROLE. Leaves the lockup as it is
   * @param _token The token
   * @param _holder The holder
   * @param _frozen True to freeze
   */
  function setFrozen(
    address _token,
    address _holder,
    bool _frozen
  ) external;

  /**
   * @notice The token role allowed to set lockups and freezes
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

  /**
   * @notice Whether a holder is frozen on a token
   * @param _token The token
   * @param _holder The holder
   * @return _frozen True if frozen
   */
  function isFrozen(
    address _token,
    address _holder
  ) external view returns (bool _frozen);
}
