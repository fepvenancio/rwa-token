// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IPolicyRegistry
 * @notice Allowlist of reviewed code. Hooks, rules and token implementations may only be installed if their runtime
 *         codehash is attested here. Checked at install time only
 * @dev A codehash covers runtime code including `immutable` values, but not storage. Components whose authority lives
 *      in storage can be cloned under the same codehash, so security-relevant configuration must be immutable
 */
interface IPolicyRegistry {
  /*///////////////////////////////////////////////////////////////
                            ENUMS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice What a codehash is attested as
   * @param NONE Not attested
   * @param HOOK A policy hook, installable with `IPolicyGated.setPolicyHook`
   * @param RULE A compliance rule, installable in a compliance hook
   * @param IMPLEMENTATION A token implementation, installable with a UUPS upgrade
   */
  enum AttestKind {
    NONE,
    HOOK,
    RULE,
    IMPLEMENTATION
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a codehash is attested
   * @param _codehash The attested runtime codehash
   * @param _kind What the codehash is attested as
   * @param _attester The account that attested it
   * @param _uri Pointer to the audit or review record
   */
  event Attested(bytes32 indexed _codehash, AttestKind _kind, address indexed _attester, string _uri);

  /**
   * @notice Emitted when an attestation is revoked
   * @param _codehash The revoked runtime codehash
   * @param _attester The account that revoked it
   */
  event AttestationRevoked(bytes32 indexed _codehash, address indexed _attester);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when attesting a codehash that is already attested
   * @param _codehash The codehash
   */
  error PolicyRegistry_AlreadyAttested(bytes32 _codehash);

  /// @notice Thrown when attesting the codehash of an empty account (zero or keccak256 of empty code)
  error PolicyRegistry_InvalidCodehash();

  /// @notice Thrown when attesting with `AttestKind.NONE`
  error PolicyRegistry_InvalidKind();

  /**
   * @notice Thrown when revoking a codehash that is not attested
   * @param _codehash The codehash
   */
  error PolicyRegistry_NotAttested(bytes32 _codehash);

  /// @notice Thrown when a constructor argument is the zero address
  error PolicyRegistry_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Attests a runtime codehash as `_kind`
   * @dev Only ATTESTER_ROLE. To change a codehash's kind, revoke it first
   * @param _codehash The runtime codehash
   * @param _kind What it is attested as; must not be NONE
   * @param _uri Pointer to the audit or review record
   */
  function attest(
    bytes32 _codehash,
    AttestKind _kind,
    string calldata _uri
  ) external;

  /**
   * @notice Revokes an attestation
   * @dev Only ATTESTER_ROLE. Does not affect components that are already installed
   * @param _codehash The runtime codehash
   */
  function revoke(
    bytes32 _codehash
  ) external;

  /**
   * @notice Whether `_target`'s current runtime codehash is attested as `_kind`
   * @param _target The deployed contract
   * @param _kind The required kind
   * @return _attested True if attested as `_kind`; always false for accounts without code and for NONE
   */
  function isAttested(
    address _target,
    AttestKind _kind
  ) external view returns (bool _attested);

  /**
   * @notice The kind a codehash is attested as
   * @param _codehash The runtime codehash
   * @return _kind The attested kind, or NONE
   */
  function kindOf(
    bytes32 _codehash
  ) external view returns (AttestKind _kind);
}
