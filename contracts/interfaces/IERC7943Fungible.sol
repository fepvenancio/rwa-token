// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/**
 * @title IERC7943Fungible
 * @notice The fungible interface of ERC-7943 (uRWA) in its Final text. A token that implements it answers
 *         `supportsInterface(0x3edbb4c4)`
 * @dev The id is the XOR of the six selectors below and does not depend on parameter names, which follow the
 *      project's `_camelCase`. `canSend` and `canReceive` are account-level and never revert; `canTransfer` also
 *      checks the unfrozen balance
 */
interface IERC7943Fungible is IERC165 {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted by `forcedTransfer`, after the token's own `Transfer` event
   * @param _from The account tokens were taken from
   * @param _to The account that received them
   * @param _amount The amount moved
   */
  event ForcedTransfer(address indexed _from, address indexed _to, uint256 _amount);

  /**
   * @notice Emitted when an account's frozen amount changes, before the `Transfer` event of the action that caused it
   * @param _account The account
   * @param _amount The frozen amount after the change
   */
  event Frozen(address indexed _account, uint256 _amount);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice General revert for an account that may not send
   * @param _account The sender
   */
  // Declared by the ERC-7943 interface text, whose errors are optional (MAY); the token rejects with `PolicyGated_TransferRejected`.
  // aderyn-ignore-next-line(unused-error)
  error ERC7943CannotSend(address _account);

  /**
   * @notice General revert for an account that may not receive
   * @param _account The receiver
   */
  // Declared by the ERC-7943 interface text, whose errors are optional (MAY); the token rejects with `PolicyGated_TransferRejected`.
  // aderyn-ignore-next-line(unused-error)
  error ERC7943CannotReceive(address _account);

  /**
   * @notice General revert for a transfer that `canTransfer` would refuse
   * @param _from The sender
   * @param _to The receiver
   * @param _amount The amount
   */
  // Declared by the ERC-7943 interface text, whose errors are optional (MAY); the token rejects with `PolicyGated_TransferRejected`.
  // aderyn-ignore-next-line(unused-error)
  error ERC7943CannotTransfer(address _from, address _to, uint256 _amount);

  /**
   * @notice Revert for an amount above the sender's unfrozen balance
   * @param _account The sender
   * @param _amount The amount requested
   * @param _unfrozen The unfrozen balance, the balance minus the frozen amount, zero when the frozen amount is larger
   */
  error ERC7943InsufficientUnfrozenBalance(address _account, uint256 _amount, uint256 _unfrozen);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Moves tokens by enforcement, bypassing the sender's consent
   * @dev Access-restricted. May skip the policy checks for the sender but still checks the receiver. When the moved
   *      amount includes frozen tokens it lowers the frozen amount first and emits `Frozen` before the base `Transfer`
   * @param _from The account tokens are taken from
   * @param _to The account that receives them
   * @param _amount The amount to move
   * @return _result True when the transfer executed; reverts otherwise
   */
  function forcedTransfer(
    address _from,
    address _to,
    uint256 _amount
  ) external returns (bool _result);

  /**
   * @notice Sets an account's frozen amount, overwriting the previous one
   * @dev Access-restricted. The amount may exceed the balance. Emits `Frozen`
   * @param _account The account
   * @param _amount The new frozen amount
   * @return _result True when the freeze was recorded; reverts otherwise
   */
  function setFrozenTokens(
    address _account,
    uint256 _amount
  ) external returns (bool _result);

  /**
   * @notice Whether an account may send tokens at all
   * @dev Account-level and independent of any amount or receiver. Never reverts
   * @param _account The account
   * @return _allowed True if the account may send
   */
  function canSend(
    address _account
  ) external view returns (bool _allowed);

  /**
   * @notice Whether an account may receive tokens at all
   * @dev Account-level and independent of any amount or sender. Never reverts
   * @param _account The account
   * @return _allowed True if the account may receive
   */
  function canReceive(
    address _account
  ) external view returns (bool _allowed);

  /**
   * @notice An account's frozen amount
   * @param _account The account
   * @return _amount The frozen amount, which may exceed the balance
   */
  function getFrozenTokens(
    address _account
  ) external view returns (uint256 _amount);

  /**
   * @notice Whether a transfer would succeed now
   * @dev Checks the sender and receiver and that `_amount` is within the unfrozen balance. A transfer must not succeed
   *      where this returns false
   * @param _from The sender
   * @param _to The receiver
   * @param _amount The amount
   * @return _allowed True if the transfer would succeed
   */
  function canTransfer(
    address _from,
    address _to,
    uint256 _amount
  ) external view returns (bool _allowed);
}
