// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';

import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

/**
 * @title PolicyRegistry
 * @notice Immutable allowlist of reviewed runtime codehashes. One per deployment
 * @dev ATTESTER_ROLE is the security council; DEFAULT_ADMIN_ROLE is the timelock and manages attesters
 */
contract PolicyRegistry is AccessControl, IPolicyRegistry {
  /// @notice Role allowed to attest and revoke codehashes
  bytes32 public constant ATTESTER_ROLE = keccak256('ATTESTER_ROLE');

  /// @notice Codehash of an existing account without code
  bytes32 private constant _EMPTY_CODEHASH = keccak256('');

  /// @notice The attested kind of each codehash
  mapping(bytes32 _codehash => AttestKind _kind) internal _kinds;

  /**
   * @notice Deploys the registry
   * @param _admin The timelock, granted DEFAULT_ADMIN_ROLE
   * @param _attester The security council, granted ATTESTER_ROLE
   */
  constructor(
    address _admin,
    address _attester
  ) {
    if (_admin == address(0) || _attester == address(0)) revert PolicyRegistry_ZeroAddress();
    // _grantRole returns false only if the role is already held; either way the account ends up holding it.
    // aderyn-ignore-next-line(unchecked-return)
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    // As above.
    // aderyn-ignore-next-line(unchecked-return)
    _grantRole(ATTESTER_ROLE, _attester);
  }

  /// @inheritdoc IPolicyRegistry
  function attest(
    bytes32 _codehash,
    AttestKind _kind,
    string calldata _uri
  ) external onlyRole(ATTESTER_ROLE) {
    if (_kind == AttestKind.NONE) revert PolicyRegistry_InvalidKind();
    if (_codehash == bytes32(0) || _codehash == _EMPTY_CODEHASH) revert PolicyRegistry_InvalidCodehash();
    if (_kinds[_codehash] != AttestKind.NONE) revert PolicyRegistry_AlreadyAttested(_codehash);
    _kinds[_codehash] = _kind;
    emit Attested(_codehash, _kind, msg.sender, _uri);
  }

  /// @inheritdoc IPolicyRegistry
  function revoke(
    bytes32 _codehash
  ) external onlyRole(ATTESTER_ROLE) {
    if (_kinds[_codehash] == AttestKind.NONE) revert PolicyRegistry_NotAttested(_codehash);
    delete _kinds[_codehash];
    emit AttestationRevoked(_codehash, msg.sender);
  }

  /// @inheritdoc IPolicyRegistry
  function isAttested(
    address _target,
    AttestKind _kind
  ) external view returns (bool _attested) {
    if (_kind == AttestKind.NONE) return false;
    // Accounts without code have codehash 0 or `_EMPTY_CODEHASH`, which `attest` refuses, so they never match.
    _attested = _kinds[_target.codehash] == _kind;
  }

  /// @inheritdoc IPolicyRegistry
  function kindOf(
    bytes32 _codehash
  ) external view returns (AttestKind _kind) {
    _kind = _kinds[_codehash];
  }

  /// @inheritdoc AccessControl
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(IPolicyRegistry).interfaceId || super.supportsInterface(_interfaceId);
  }
}
