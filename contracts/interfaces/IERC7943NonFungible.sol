// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/**
 * @title IERC7943NonFungible
 * @notice The non-fungible (ERC-721) interface of ERC-7943 (uRWA) in its Final text. A token that implements it answers
 *         `supportsInterface(0xbf1ef5fe)`
 * @dev The id is the XOR of the six selectors below and does not depend on parameter names, which follow the
 *      project's `_camelCase`. A frozen status belongs to an account and a token id, and may be set for a token the
 *      account does not hold. `canSend` and `canReceive` are account-level; `canTransfer` checks the frozen status and
 *      leaves ownership and approval to ERC-721
 */
interface IERC7943NonFungible is IERC165 {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted by `forcedTransfer`, after the token's own `Transfer` event
   * @param _from The account the token was taken from
   * @param _to The account that received it
   * @param _tokenId The token moved
   */
  event ForcedTransfer(address indexed _from, address indexed _to, uint256 indexed _tokenId);

  /**
   * @notice Emitted when the frozen status of a token for an account changes, before the `Transfer` event of the action
   *         that caused it
   * @param _account The account
   * @param _tokenId The token
   * @param _frozenStatus The frozen status after the change
   */
  event Frozen(address indexed _account, uint256 indexed _tokenId, bool indexed _frozenStatus);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice General revert for an account that may not send
   * @param _account The sender
   */
  // Declared by the ERC-7943 interface text, whose errors are optional (MAY); the token rejects with `ERC8473PolicyRejected`.
  // aderyn-ignore-next-line(unused-error)
  error ERC7943CannotSend(address _account);

  /**
   * @notice General revert for an account that may not receive
   * @param _account The receiver
   */
  // Declared by the ERC-7943 interface text, whose errors are optional (MAY); the token rejects with `ERC8473PolicyRejected`.
  // aderyn-ignore-next-line(unused-error)
  error ERC7943CannotReceive(address _account);

  /**
   * @notice General revert for a transfer that `canTransfer` would refuse
   * @param _from The sender
   * @param _to The receiver
   * @param _tokenId The token
   */
  // Declared by the ERC-7943 interface text, whose errors are optional (MAY); the token rejects with `ERC8473PolicyRejected`.
  // aderyn-ignore-next-line(unused-error)
  error ERC7943CannotTransfer(address _from, address _to, uint256 _tokenId);

  /**
   * @notice Revert for a token that is frozen for the account moving it
   * @param _account The sender
   * @param _tokenId The frozen token
   */
  error ERC7943InsufficientUnfrozenBalance(address _account, uint256 _tokenId);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Moves a token by enforcement, bypassing the owner's consent
   * @dev Access-restricted. Still checks the receiver. A frozen token is unfrozen first, with `Frozen` emitted before
   *      the token's `Transfer`
   * @param _from The current owner
   * @param _to The receiver
   * @param _tokenId The token
   * @return _result True on success
   */
  function forcedTransfer(
    address _from,
    address _to,
    uint256 _tokenId
  ) external returns (bool _result);

  /**
   * @notice Sets the frozen status of a token for an account, overwriting the previous one
   * @dev Access-restricted. The account need not hold the token
   * @param _account The account
   * @param _tokenId The token
   * @param _frozenStatus True to freeze, false to unfreeze
   * @return _result True on success
   */
  function setFrozenTokens(
    address _account,
    uint256 _tokenId,
    bool _frozenStatus
  ) external returns (bool _result);

  /**
   * @notice Whether an account may send at all; account-level, with no token
   * @param _account The account
   * @return _allowed True if it may
   */
  function canSend(
    address _account
  ) external view returns (bool _allowed);

  /**
   * @notice Whether an account may receive at all; account-level, with no token
   * @param _account The account
   * @return _allowed True if it may
   */
  function canReceive(
    address _account
  ) external view returns (bool _allowed);

  /**
   * @notice The frozen status of a token for an account
   * @dev May be true for a token the account does not hold
   * @param _account The account
   * @param _tokenId The token
   * @return _frozenStatus True if frozen
   */
  function getFrozenTokens(
    address _account,
    uint256 _tokenId
  ) external view returns (bool _frozenStatus);

  /**
   * @notice Whether a transfer of a token would pass the permissioned checks
   * @dev False for a frozen token and for any policy rejection. Ownership and approval are ERC-721's checks, which it
   *      does not make
   * @param _from The sender
   * @param _to The receiver
   * @param _tokenId The token
   * @return _allowed True if allowed
   */
  function canTransfer(
    address _from,
    address _to,
    uint256 _tokenId
  ) external view returns (bool _allowed);
}
