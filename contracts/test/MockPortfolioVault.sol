// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title MockPortfolioVault
 * @notice The four things a `Portfolio` asks its vault: who holds a role, which registry it uses, its total assets, and
 *         whether it is paused
 */
contract MockPortfolioVault {
  /// @notice The registry the vault names
  address public registry;

  /// @notice The total assets the vault reports
  uint256 public totalAssets;

  /// @notice Whether the vault is paused
  bool public paused;

  /// @notice Who holds which role
  mapping(bytes32 _role => mapping(address _account => bool _held)) public hasRole;

  /**
   * @notice Deploys the vault
   * @param _registry The registry it names
   */
  constructor(
    address _registry
  ) {
    registry = _registry;
  }

  /**
   * @notice Gives or takes a role
   * @param _role The role
   * @param _account The account
   * @param _held Whether it holds the role
   */
  function setRole(
    bytes32 _role,
    address _account,
    bool _held
  ) external {
    hasRole[_role][_account] = _held;
  }

  /**
   * @notice Sets the total assets
   * @param _totalAssets The total assets
   */
  function setTotalAssets(
    uint256 _totalAssets
  ) external {
    totalAssets = _totalAssets;
  }

  /**
   * @notice Pauses or unpauses
   * @param _paused Whether it is paused
   */
  function setPaused(
    bool _paused
  ) external {
    paused = _paused;
  }
}
