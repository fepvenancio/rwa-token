// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IGatedVaultBase
 * @notice What the two vault templates share: shares move only through the vault's own flows, and money does not reach
 *         or leave it through someone the token's policy would refuse
 * @dev The check is the zero-amount FORCED probe: who may receive under an enforcement move, with no pause, cap or
 *      frozen effect. It applies to a third party only. A holder paying itself is not judged, because a holder whose
 *      credential lapsed or whose attester was killed must still be able to leave, and a receiver paying for itself is
 *      judged by the mint
 */
interface IGatedVaultBase {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when a payer, or a receiver of redemption cash, or a named controller fails the token's policy
   * @param _account The third party
   * @param _reason The reason code from the probe
   */
  error GatedVault_ThirdPartyNotEligible(address _account, bytes32 _reason);

  /// @notice Thrown by what vault shares do not support: the issuer `mint` and `burn`, a frozen amount on the 7540 escrow
  error GatedVault_Unsupported();
}
