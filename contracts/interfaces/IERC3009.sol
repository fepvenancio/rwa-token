// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IERC3009
 * @notice The part of ERC-3009 (Draft) that `DvPExecutor` uses from a cash token such as USDC: pulling a payment the
 *         payer authorised by signature, where only the payee can submit it
 * @dev The signature is passed as `bytes`, the form that supports ERC-1271 wallets (Circle's FiatToken v2.2). The token
 *      rejects the call unless the caller is `to`, `validAfter < block.timestamp < validBefore`, the nonce is unused and
 *      the signature is valid
 */
interface IERC3009 {
  /**
   * @notice Moves `value` from `from` to `to` on the payer's signature; callable only by `to`
   * @param from The payer and signer
   * @param to The payee, which must be the caller
   * @param value The amount
   * @param validAfter The time after which the authorization is valid, exclusive
   * @param validBefore The time before which the authorization is valid, exclusive
   * @param nonce Random, single-use per payer
   * @param signature The payer's signature
   */
  function receiveWithAuthorization(
    address from,
    address to,
    uint256 value,
    uint256 validAfter,
    uint256 validBefore,
    bytes32 nonce,
    bytes calldata signature
  ) external;

  /**
   * @notice Whether a payer's authorization nonce was used or cancelled
   * @param authorizer The payer
   * @param nonce The nonce
   * @return used True if used or cancelled
   */
  function authorizationState(
    address authorizer,
    bytes32 nonce
  ) external view returns (bool used);
}
