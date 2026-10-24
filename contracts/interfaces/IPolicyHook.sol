// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IPolicyHook
 * @notice Single policy entry point bound to a token. The token builds a `TransferContext` for every balance movement,
 *         asks `beforeTransfer` for a decision, moves balances, then calls `afterTransfer` if `wantsAfter()`
 */
interface IPolicyHook {
  /*///////////////////////////////////////////////////////////////
                            ENUMS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Classification of a balance movement as seen by the policy hook
   * @param TRANSFER `transfer` / `transferFrom` by the holder or a spender
   * @param EXECUTED Executor-settled, holder-signed transfer intent
   * @param FORCED AGENT_ROLE forced transfer (clawback / recovery)
   * @param MINT Issuance; `from` is address(0)
   * @param BURN Redemption or destruction; `to` is address(0)
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
   * @notice Everything a policy rule may need to decide. Built by the token, never by callers
   * @param token The token whose balances move
   * @param from The sender; address(0) on MINT
   * @param to The receiver; address(0) on BURN
   * @param id 0 for fungibles; the token id for future ERC-721 / ERC-1155 templates
   * @param amount The amount moved
   * @param operator The account driving the movement: holder, spender, agent, minter or executor
   * @param kind The movement classification
   * @param extra Context the token adds. For every kind it starts with the balances before the move,
   *        `abi.encode(uint256 fromBalance, uint256 toBalance)`, each zero for the zero address. For EXECUTED it
   *        continues with `bytes32 ref, uint256 deadline` (the intent's reference and deadline), so EXECUTED carries
   *        four words and every other kind two. A rule reads the balances with `abi.decode(extra, (uint256, uint256))`,
   *        which ignores the EXECUTED tail, and derives the balances after the move from `amount`, so it never calls
   *        back into the token. The token builds `extra` with the same code for the write and for every pre-flight
   */
  struct TransferContext {
    address token;
    address from;
    address to;
    uint256 id;
    uint256 amount;
    address operator;
    TransferKind kind;
    bytes extra;
  }

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Called by the token after balances moved, only if `wantsAfter()` is true
   * @dev Runs inside the token's reentrancy guard, so it MUST NOT call back into the token
   * @param _ctx The movement context
   */
  function afterTransfer(
    TransferContext calldata _ctx
  ) external;

  /**
   * @notice Policy decision for a balance movement
   * @dev MUST be view; the token calls it with staticcall semantics. MUST NOT revert on a policy decision
   * @param _ctx The movement context
   * @return _reason `Reasons.TRANSFER_OK` to allow, any other reason code to reject
   */
  function beforeTransfer(
    TransferContext calldata _ctx
  ) external view returns (bytes32 _reason);

  /**
   * @notice Account-level decision on receiving: whether `_account` may receive tokens of `_token` at all
   * @dev MUST be view and MUST NOT revert on a policy decision. Independent of any amount or sender. It serves
   *      `canReceive`; `beforeTransfer` already applies the same decision to a movement, per kind
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
   * @dev MUST be view and MUST NOT revert on a policy decision. Independent of any amount or receiver. It serves
   *      `canSend`; `beforeTransfer` already applies the same decision to a movement, per kind
   * @param _token The token
   * @param _account The prospective sender
   * @return _reason `Reasons.TRANSFER_OK` to allow, any other reason code to reject
   */
  function checkSend(
    address _token,
    address _account
  ) external view returns (bytes32 _reason);

  /**
   * @notice Whether the calling token should call `afterTransfer`
   * @dev Answers for `msg.sender`, so a hook shared by several tokens answers for the token that asks
   * @return _wantsAfter True if `afterTransfer` must be called after each movement
   */
  function wantsAfter() external view returns (bool _wantsAfter);
}
