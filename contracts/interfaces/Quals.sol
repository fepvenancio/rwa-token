// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title Quals
 * @notice Qualification bits shared by `ICredentialRegistry` records and `ICredentialRule` policies. The registry never
 *         interprets them: an attester sets the bits it vouches for, and each token's policy says which bits it needs.
 *         Bits 0 to 7 are named here, bits 8 to 15 are reserved for later shared meanings, and bits 16 to 31 are free
 *         for a deployment's own use
 * @dev What a bit means in law is for the attester and its counsel to define, and a bank should have the wording
 *      reviewed before relying on it. The names are conveniences, not legal categories
 */
// public bit values, read as `Quals.X`; `internal` only so they inline
// solhint-disable private-vars-leading-underscore
library Quals {
  /// @notice Identity verified by the attester
  uint32 internal constant KYC = 1 << 0;
  /// @notice Professional client or investor (for example MiFID II)
  uint32 internal constant PROFESSIONAL = 1 << 1;
  /// @notice Qualified or accredited investor (for example a US accredited investor or qualified purchaser)
  uint32 internal constant QUALIFIED = 1 << 2;
  /// @notice Institutional investor or eligible counterparty
  uint32 internal constant INSTITUTIONAL = 1 << 3;
  /// @notice A fund holding on its own account
  uint32 internal constant FUND = 1 << 4;
  /// @notice A regulated credit institution
  uint32 internal constant BANK = 1 << 5;
  /// @notice A customer of the bank that issues the token (the nominative relationship of a deposit token)
  uint32 internal constant CUSTOMER = 1 << 6;
  /// @notice Infrastructure: a vault, escrow, treasury or other address that holds tokens for the system
  uint32 internal constant INFRA = 1 << 7;
}
// solhint-enable private-vars-leading-underscore
