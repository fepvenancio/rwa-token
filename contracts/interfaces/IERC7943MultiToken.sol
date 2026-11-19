// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/**
 * @title IERC7943MultiToken
 * @notice The multi-token (ERC-1155) interface of ERC-7943 (uRWA) in its Final text. A token that implements it answers
 *         `supportsInterface(0x41c4fbad)`
 * @dev The id is the XOR of the six selectors below and does not depend on parameter names, which follow the
 *      project's `_camelCase`. A frozen amount belongs to an account and a token id, and may exceed the balance.
 *      `canSend` and `canReceive` are account-level and take no token id
 */
interface IERC7943MultiToken is IERC165 {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted by `forcedTransfer`, after the token's own transfer event
   * @param _from The account the tokens were taken from
   * @param _to The account that received them
   * @param _tokenId The token id moved
   * @param _amount The amount moved
   */
  event ForcedTransfer(address indexed _from, address indexed _to, uint256 indexed _tokenId, uint256 _amount);

  /**
   * @notice Emitted when the frozen amount of a token id for an account changes, before the transfer event of the
   *         action that caused it
   * @param _account The account
   * @param _tokenId The token id
   * @param _amount The frozen amount after the change
   */
  event Frozen(address indexed _account, uint256 indexed _tokenId, uint256 _amount);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice General revert for an account that may not send
   * @dev Declared by the ERC-7943 interface text, whose general errors are optional (MAY); the token rejects with
   *      `ERC8473PolicyRejected`
   * @param _account The sender
   */
  error ERC7943CannotSend(address _account);

  /**
   * @notice General revert for an account that may not receive
   * @dev Declared by the ERC-7943 interface text, whose general errors are optional (MAY); the token rejects with
   *      `ERC8473PolicyRejected`
   * @param _account The receiver
   */
  error ERC7943CannotReceive(address _account);

  /**
   * @notice General revert for a transfer that `canTransfer` would refuse
   * @dev Declared by the ERC-7943 interface text, whose general errors are optional (MAY); the token rejects with
   *      `ERC8473PolicyRejected`
   * @param _from The sender
   * @param _to The receiver
   * @param _tokenId The token id
   * @param _amount The amount
   */
  error ERC7943CannotTransfer(address _from, address _to, uint256 _tokenId, uint256 _amount);

  /**
   * @notice Revert for an amount within the balance of a token id but above its unfrozen part
   * @param _account The sender
   * @param _tokenId The token id
   * @param _amount The amount it tried to move
   * @param _unfrozen The amount it can move
   */
  error ERC7943InsufficientUnfrozenBalance(address _account, uint256 _tokenId, uint256 _amount, uint256 _unfrozen);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Moves tokens by enforcement, bypassing the holder's consent
   * @dev Access-restricted. Still checks the receiver. Frozen tokens are unfrozen as needed, with `Frozen` emitted
   *      before the token's transfer event
   * @param _from The holder
   * @param _to The receiver
   * @param _tokenId The token id
   * @param _amount The amount
   * @return _result True on success
   */
  function forcedTransfer(
    address _from,
    address _to,
    uint256 _tokenId,
    uint256 _amount
  ) external returns (bool _result);

  /**
   * @notice Sets the frozen amount of a token id for an account, overwriting the previous one
   * @dev Access-restricted. The amount may exceed the balance
   * @param _account The account
   * @param _tokenId The token id
   * @param _amount The frozen amount
   * @return _result True on success
   */
  function setFrozenTokens(
    address _account,
    uint256 _tokenId,
    uint256 _amount
  ) external returns (bool _result);

  /**
   * @notice Whether an account may send at all; account-level, with no token id and no amount
   * @param _account The account
   * @return _allowed True if it may
   */
  function canSend(
    address _account
  ) external view returns (bool _allowed);

  /**
   * @notice Whether an account may receive at all; account-level, with no token id and no amount
   * @param _account The account
   * @return _allowed True if it may
   */
  function canReceive(
    address _account
  ) external view returns (bool _allowed);

  /**
   * @notice The frozen amount of a token id for an account
   * @dev May exceed the balance
   * @param _account The account
   * @param _tokenId The token id
   * @return _amount The frozen amount
   */
  function getFrozenTokens(
    address _account,
    uint256 _tokenId
  ) external view returns (uint256 _amount);

  /**
   * @notice Whether a transfer of an amount of a token id would pass the permissioned checks
   * @dev False for an amount above the unfrozen balance while part of the balance is frozen, and for any policy
   *      rejection. Never false for a balance or an approval, which are ERC-1155's checks
   * @param _from The sender
   * @param _to The receiver
   * @param _tokenId The token id
   * @param _amount The amount
   * @return _allowed True if allowed
   */
  function canTransfer(
    address _from,
    address _to,
    uint256 _tokenId,
    uint256 _amount
  ) external view returns (bool _allowed);
}
