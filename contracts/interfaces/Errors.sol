// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title Reasons
 * @notice Frozen reason-code table (ERC-1594 style). Hooks and rules return these codes, and token rejections carry
 *         them in `IPolicyGated.PolicyGated_TransferRejected`
 * @dev Append only: never rename, reorder or change a value. Each value is the keccak256 of its name, so `TRANSFER_OK`
 *      is non-zero and a hook or rule that forgets to set its return value rejects instead of approving
 */
// public reason codes, read as `Reasons.X`; `internal` only so they inline
// solhint-disable private-vars-leading-underscore
library Reasons {
  /// @notice The movement is allowed
  bytes32 internal constant TRANSFER_OK = keccak256('TRANSFER_OK');
  /// @notice The token is paused and the movement is not a forced transfer
  bytes32 internal constant PAUSED = keccak256('PAUSED');
  /// @notice The sender's unfrozen balance is lower than the amount
  bytes32 internal constant INSUFFICIENT_UNFROZEN = keccak256('INSUFFICIENT_UNFROZEN');
  /// @notice The sender is not verified in the identity registry
  bytes32 internal constant SENDER_NOT_VERIFIED = keccak256('SENDER_NOT_VERIFIED');
  /// @notice The receiver is not verified in the identity registry
  bytes32 internal constant RECEIVER_NOT_VERIFIED = keccak256('RECEIVER_NOT_VERIFIED');
  /// @notice The movement happens outside the configured settlement window
  bytes32 internal constant OUTSIDE_SETTLEMENT_WINDOW = keccak256('OUTSIDE_SETTLEMENT_WINDOW');
  /// @notice The movement would exceed the maximum number of holders
  bytes32 internal constant MAX_HOLDERS = keccak256('MAX_HOLDERS');
  /// @notice The sender's tokens are still locked up
  bytes32 internal constant LOCKED = keccak256('LOCKED');
  /// @notice The transfer intent's deadline has passed
  bytes32 internal constant INTENT_EXPIRED = keccak256('INTENT_EXPIRED');
  /// @notice The transfer intent's nonce was already used or cancelled
  bytes32 internal constant NONCE_USED = keccak256('NONCE_USED');
  /// @notice The transfer intent's signature does not match its `from`
  bytes32 internal constant BAD_SIGNATURE = keccak256('BAD_SIGNATURE');
  /// @notice The token has no policy hook installed
  bytes32 internal constant NO_HOOK = keccak256('NO_HOOK');
  /// @notice The policy hook has an empty rule set; an unconfigured hook rejects everything
  bytes32 internal constant NO_RULES = keccak256('NO_RULES');
  /// @notice The token is not a registered class of the fund, or the fund rule in its hook is not the fund's installed
  ///         rule; every movement is rejected
  bytes32 internal constant NOT_FUND_CLASS = keccak256('NOT_FUND_CLASS');
  /// @notice The transfer intent names an executor and the caller is another account
  bytes32 internal constant WRONG_EXECUTOR = keccak256('WRONG_EXECUTOR');
  /// @notice The transfer intent's `validAfter` has not been reached
  bytes32 internal constant INTENT_NOT_YET_VALID = keccak256('INTENT_NOT_YET_VALID');
  /// @notice The transfer intent states a consideration but names no executor, so nothing could enforce it
  bytes32 internal constant CONSIDERATION_NEEDS_EXECUTOR = keccak256('CONSIDERATION_NEEDS_EXECUTOR');
}
// solhint-enable private-vars-leading-underscore
