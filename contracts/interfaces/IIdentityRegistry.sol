// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IIdentityRegistry
 * @notice Minimal view of a shared identity registry; an adapter over ERC-3643 `IIdentityRegistry.isVerified` or any
 *         equivalent
 */
interface IIdentityRegistry {
  /**
   * @notice Whether an account is verified
   * @param _user The account
   * @return _verified True if verified
   */
  function isVerified(
    address _user
  ) external view returns (bool _verified);
}
