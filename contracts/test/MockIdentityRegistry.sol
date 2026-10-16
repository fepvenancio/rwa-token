// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';

/**
 * @title MockIdentityRegistry
 * @notice Settable identity registry for integration tests
 */
contract MockIdentityRegistry is IIdentityRegistry {
  /// @notice Whether each account is verified
  mapping(address _user => bool _verified) public verified;

  /**
   * @notice Sets an account's verification status
   * @param _user The account
   * @param _verified The status
   */
  function set(
    address _user,
    bool _verified
  ) external {
    verified[_user] = _verified;
  }

  /// @inheritdoc IIdentityRegistry
  function isVerified(
    address _user
  ) external view returns (bool _verified) {
    _verified = verified[_user];
  }
}
