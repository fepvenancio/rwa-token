// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title ITransferIntent
 * @notice Executor-settled transfers: the holder signs an EIP-712 `TransferIntent`, EXECUTOR_ROLE executes it.
 *         Settlement finality is at execution, not at signing
 * @dev Rejections revert with `IPolicyGated.PolicyGated_TransferRejected` carrying a reason code
 */
interface ITransferIntent {
  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Holder-signed transfer instruction
   * @param from The holder and signer
   * @param to The receiver
   * @param amount The amount
   * @param nonce Random, single-use per signer (ERC-3009 style)
   * @param deadline Last valid unix timestamp, inclusive
   * @param ref Off-chain reference (ISO 20022 msgId hash / bizId)
   * @param executor The only account allowed to execute the intent; zero means any EXECUTOR_ROLE holder
   * @param validAfter First valid unix timestamp, inclusive; zero means no lower bound
   * @param considerationToken What the signer is to receive for this leg: the token. Signed, and never enforced by
   *        the token: only the executor named in `executor` enforces the payment
   * @param considerationAmount What the signer is to receive for this leg: the amount, in `considerationToken` units
   */
  struct TransferIntent {
    address from;
    address to;
    uint256 amount;
    bytes32 nonce;
    uint256 deadline;
    bytes32 ref;
    address executor;
    uint256 validAfter;
    address considerationToken;
    uint256 considerationAmount;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when an intent is executed
   * @param _intentHash The EIP-712 digest of the intent
   * @param _from The holder
   * @param _to The receiver
   * @param _amount The amount
   * @param _executor The EXECUTOR_ROLE account that executed it
   * @param _ref The intent's off-chain reference
   */
  event IntentExecuted(
    bytes32 indexed _intentHash,
    address indexed _from,
    address indexed _to,
    uint256 _amount,
    address _executor,
    bytes32 _ref
  );

  /**
   * @notice Emitted when a signer cancels a nonce
   * @param _from The signer
   * @param _nonce The cancelled nonce
   */
  event IntentCancelled(address indexed _from, bytes32 indexed _nonce);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Marks a nonce as used, so no intent signed with it can execute
   * @param _nonce The nonce to cancel for the caller
   */
  function cancelIntent(
    bytes32 _nonce
  ) external;

  /**
   * @notice Executes a signed intent
   * @dev Only EXECUTOR_ROLE. Checks the deadline, the nonce, the consideration, the executor and the window, then the
   *      signature (ECDSA or ERC-1271), then moves the tokens as EXECUTED through the policy hook. The executor cannot
   *      alter the intent. Reverts with `PolicyGated_TransferRejected` carrying the reason `canExecute` returns
   * @param _intent The intent
   * @param _sig The holder's signature over `intentHash(_intent)`
   * @return _intentHash The EIP-712 digest of the intent
   */
  function executeTransfer(
    TransferIntent calldata _intent,
    bytes calldata _sig
  ) external returns (bytes32 _intentHash);

  /**
   * @notice Pre-flight for `executeTransfer`
   * @dev Runs the same checks in the same order as `executeTransfer`, minus the write: the deadline, the nonce, the
   *      consideration, the executor, the window, the signature, then the mechanical and hook checks. The caller is the
   *      operator in the context and the account compared with `executor`, so an intent that names an executor passes
   *      only from that address
   * @param _intent The intent
   * @param _sig The signer's signature over `intentHash(_intent)`
   * @return _ok True if the intent would execute
   * @return _reason The reason code; `Reasons.TRANSFER_OK` when `_ok`
   */
  function canExecute(
    TransferIntent calldata _intent,
    bytes calldata _sig
  ) external view returns (bool _ok, bytes32 _reason);

  /**
   * @notice The EIP-712 digest a holder signs
   * @dev Domain: name = token name, version "1", chainId, verifyingContract = the token
   * @param _intent The intent
   * @return _intentHash The digest
   */
  function intentHash(
    TransferIntent calldata _intent
  ) external view returns (bytes32 _intentHash);

  /**
   * @notice Whether a signer's nonce was used or cancelled
   * @param _signer The signer
   * @param _nonce The nonce
   * @return _used True if used or cancelled
   */
  function nonceUsed(
    address _signer,
    bytes32 _nonce
  ) external view returns (bool _used);
}
