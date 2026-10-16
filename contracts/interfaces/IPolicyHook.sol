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
   * @param ref `intent.ref` for EXECUTED, otherwise 0
   * @param deadline `intent.deadline` for EXECUTED, otherwise 0
   * @param extra Reserved for future context; empty today
   */
  struct TransferContext {
    address token;
    address from;
    address to;
    uint256 id;
    uint256 amount;
    address operator;
    TransferKind kind;
    bytes32 ref;
    uint256 deadline;
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
   * @notice Whether the token should call `afterTransfer`
   * @return _wantsAfter True if `afterTransfer` must be called after each movement
   */
  function wantsAfter() external view returns (bool _wantsAfter);
}
