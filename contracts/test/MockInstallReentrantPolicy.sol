// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title MockInstallReentrantPolicy
 * @notice A policy that tries to start a movement on the token from `onInstall`; the token's reentrancy guard must
 *         block it, since no movement may begin while an installation runs
 */
contract MockInstallReentrantPolicy {
  /// @notice The registry the policy names, which a token requires to be its own
  address public immutable REGISTRY;

  /**
   * @notice Deploys the mock
   * @param _registry The registry to name
   */
  constructor(
    address _registry
  ) {
    REGISTRY = _registry;
  }

  /**
   * @notice Tries to move tokens while the installation runs
   * @param _token The token installing this policy
   */
  function onInstall(
    address _token,
    address,
    bytes calldata
  ) external {
    IERC20(_token).transfer(address(this), 0);
  }

  /**
   * @notice Answers every interface id, the ERC-8473 policy id included
   * @return _supported Always true
   */
  function supportsInterface(
    bytes4
  ) external pure returns (bool _supported) {
    _supported = true;
  }
}
