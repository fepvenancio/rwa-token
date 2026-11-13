// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/**
 * @title IERC8473Policy
 * @notice ERC-8473 (uRWA Policy, draft): decides whether an account may send or receive an ERC-7943 token, and whether
 *         a movement of it may happen. The token builds a `TransferContext` for every movement, asks `checkTransfer`
 *         before any balance changes, moves balances, then calls `afterTransfer` if `wantsAfterTransfer()`
 * @dev ERC-165 id `0x9cb56a99`, the XOR of the six selectors. A check permits when it returns `Reasons.TRANSFER_OK` and
 *      rejects when it returns anything else, zero included
 */
interface IERC8473Policy is IERC165 {
  /*///////////////////////////////////////////////////////////////
                            ENUMS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The authority under which a movement happens. The set is closed
   * @param TRANSFER Any other movement between two accounts, typically one the holder directed
   * @param EXECUTED A signed holder instruction the token verified, executed by an account the token authorises
   * @param FORCED The token's enforcement authority, which does not depend on the holder directing the movement: a
   *        forced transfer, an enforcement mint (`from` is address(0)) or an enforcement burn (`to` is address(0))
   * @param MINT Issuance under the token's ordinary issuance rules; `from` is address(0)
   * @param BURN Destruction the holder directed; `to` is address(0)
   */
  enum TransferKind {
    TRANSFER,
    EXECUTED,
    FORCED,
    MINT,
    BURN
  }

  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice One movement, as the token describes it to its policy. Built by the token, never by callers
   * @param token The token whose balance or ownership changes
   * @param from The account whose position decreases; address(0) when the movement creates the position
   * @param to The account whose position increases; address(0) when the movement destroys the position
   * @param tokenId 0 for fungibles; the token id on an ERC-721, whose amount is then 1
   * @param amount The quantity moved
   * @param operator The account that called the token to cause the movement: holder, spender, agent, minter or executor
   * @param kind The authority under which the movement happens
   * @param data Context the token adds. For every kind it starts with the balances before the move,
   *        `abi.encode(uint256 fromBalance, uint256 toBalance)`, each zero for the zero address, which the token
   *        derives from its own state. For EXECUTED it continues with `bytes32 ref, uint256 deadline` (the intent's
   *        reference and deadline), so EXECUTED carries four words and every other kind two. A rule reads the balances
   *        with `abi.decode(data, (uint256, uint256))`, which ignores the EXECUTED tail, and derives the balances after
   *        the move from `amount`, so it never calls back into the token. The token builds `data` with the same code
   *        for the write and for every pre-flight
   */
  struct TransferContext {
    address token;
    address from;
    address to;
    uint256 tokenId;
    uint256 amount;
    address operator;
    TransferKind kind;
    bytes data;
  }

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Records a movement after balances changed, in the same transaction
   * @dev Only the token named in the context may call it. Runs inside the token's reentrancy guard, so it cannot
   *      start another movement
   * @param _context The context the token passed to `checkTransfer` for this movement
   */
  function afterTransfer(
    TransferContext calldata _context
  ) external;

  /**
   * @notice Initialises the policy for a token that installs it
   * @dev Called by the token on every installation, once its `policy()` returns this policy. Only `_token` may call it
   * @param _token The token installing the policy
   * @param _previousPolicy The policy the token consulted until now; address(0) on the first installation
   * @param _data Data from the account that installs the policy, passed on unchanged
   */
  function onInstall(
    address _token,
    address _previousPolicy,
    bytes calldata _data
  ) external;

  /**
   * @notice Account-level eligibility to receive `_token`; backs the token's ERC-7943 `canReceive`
   * @dev MUST be view and MUST NOT revert on a policy decision. Independent of any amount or sender
   * @param _token The token
   * @param _account The account
   * @return _reason `Reasons.TRANSFER_OK` to permit, any other value to reject
   */
  function checkReceive(
    address _token,
    address _account
  ) external view returns (bytes32 _reason);

  /**
   * @notice Account-level eligibility to send `_token`; backs the token's ERC-7943 `canSend`
   * @dev MUST be view and MUST NOT revert on a policy decision. Independent of any amount or receiver
   * @param _token The token
   * @param _account The account
   * @return _reason `Reasons.TRANSFER_OK` to permit, any other value to reject
   */
  function checkSend(
    address _token,
    address _account
  ) external view returns (bytes32 _reason);

  /**
   * @notice Decides one movement
   * @dev Called by the token before balances change, and by anyone to simulate. MUST be view; the token calls it with
   *      staticcall semantics. MUST NOT revert on a policy decision
   * @param _context The movement
   * @return _reason `Reasons.TRANSFER_OK` to permit, any other value to reject
   */
  function checkTransfer(
    TransferContext calldata _context
  ) external view returns (bytes32 _reason);

  /**
   * @notice Whether the token must call `afterTransfer` after each movement
   * @dev MUST NOT depend on the caller, so a policy shared by several tokens answers for all of them
   * @return _wantsAfter True if the token must call `afterTransfer`
   */
  function wantsAfterTransfer() external view returns (bool _wantsAfter);
}
