// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title ITemplated
 * @notice Names the template a token implementation belongs to, so a UUPS upgrade cannot move a proxy from one template
 *         to another (an `IntentToken` proxy onto a vault implementation, for instance)
 * @dev The id is `keccak256` of the template's name, without a version, so a bug-fix implementation of the same template
 *      stays upgradeable. The registry's `AttestKind` is unchanged: the attestation says the code was reviewed, this
 *      says what it is for
 */
interface ITemplated {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when an upgrade targets an implementation of another template
   * @param _newImplementation The implementation the upgrade targeted
   * @param _expected The template id of the proxy's current implementation
   * @param _actual The template id the target reports
   */
  // Thrown by the base's `_authorizeUpgrade` from S2 of the review items plan; unused until then.
  // aderyn-ignore-next-line(unused-error)
  error Templated_WrongTemplate(address _newImplementation, bytes32 _expected, bytes32 _actual);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The template this implementation belongs to
   * @return _id `keccak256('IntentToken')`, `keccak256('Gated4626Vault')` or `keccak256('Gated7540Vault')`
   */
  function templateId() external pure returns (bytes32 _id);
}
