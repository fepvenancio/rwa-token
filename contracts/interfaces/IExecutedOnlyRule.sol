// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';

/**
 * @title IExecutedOnlyRule
 * @notice Refuses a plain transfer, so every movement between holders is a signed intent with its `ref` (the hash of the
 *         issuer's message) and goes through an executor. A plain transfer is rejected with `Reasons.KIND_NOT_ALLOWED`
 * @dev Judges TRANSFER only: mints, burns, forced moves and executed intents pass. For an `IntentToken`: a vault's escrow is a
 *      plain transfer, so a vault must not list it. It has no storage and no account-level opinion. Originator and beneficiary
 *      data stay off-chain, in the issuer's own message
 */
interface IExecutedOnlyRule is IComplianceRule {}
