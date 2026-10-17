// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IERC7575
 * @notice ERC-7575 vault interface (ERC-165 id 0x2f0a18c5): every ERC-4626 vault function plus `share()`. Declared for
 *         its interface id; ERC-7540 vaults MUST advertise it
 */
interface IERC7575 {
  /**
   * @notice Deposits assets
   * @param _assets The assets
   * @param _receiver The receiver
   * @return _shares The shares
   */
  function deposit(
    uint256 _assets,
    address _receiver
  ) external returns (uint256 _shares);

  /**
   * @notice Mints shares
   * @param _shares The shares
   * @param _receiver The receiver
   * @return _assets The assets
   */
  function mint(
    uint256 _shares,
    address _receiver
  ) external returns (uint256 _assets);

  /**
   * @notice Withdraws assets
   * @param _assets The assets
   * @param _receiver The receiver
   * @param _owner The owner
   * @return _shares The shares
   */
  function withdraw(
    uint256 _assets,
    address _receiver,
    address _owner
  ) external returns (uint256 _shares);

  /**
   * @notice Redeems shares
   * @param _shares The shares
   * @param _receiver The receiver
   * @param _owner The owner
   * @return _assets The assets
   */
  function redeem(
    uint256 _shares,
    address _receiver,
    address _owner
  ) external returns (uint256 _assets);
  /**
   * @notice The share token
   * @return _shareTokenAddress The share token
   */
  function share() external view returns (address _shareTokenAddress);

  /**
   * @notice The underlying asset
   * @return _assetTokenAddress The asset
   */
  function asset() external view returns (address _assetTokenAddress);

  /**
   * @notice Total assets managed by the vault
   * @return _totalManagedAssets The assets
   */
  function totalAssets() external view returns (uint256 _totalManagedAssets);

  /**
   * @notice Shares for an amount of assets
   * @param _assets The assets
   * @return _shares The shares
   */
  function convertToShares(
    uint256 _assets
  ) external view returns (uint256 _shares);

  /**
   * @notice Assets for an amount of shares
   * @param _shares The shares
   * @return _assets The assets
   */
  function convertToAssets(
    uint256 _shares
  ) external view returns (uint256 _assets);

  /**
   * @notice Maximum assets depositable for a receiver
   * @param _receiver The receiver
   * @return _maxAssets The maximum
   */
  function maxDeposit(
    address _receiver
  ) external view returns (uint256 _maxAssets);

  /**
   * @notice Shares a deposit would mint
   * @param _assets The assets
   * @return _shares The shares
   */
  function previewDeposit(
    uint256 _assets
  ) external view returns (uint256 _shares);

  /**
   * @notice Maximum shares mintable for a receiver
   * @param _receiver The receiver
   * @return _maxShares The maximum
   */
  function maxMint(
    address _receiver
  ) external view returns (uint256 _maxShares);

  /**
   * @notice Assets a mint would take
   * @param _shares The shares
   * @return _assets The assets
   */
  function previewMint(
    uint256 _shares
  ) external view returns (uint256 _assets);

  /**
   * @notice Maximum assets withdrawable by an owner
   * @param _owner The owner
   * @return _maxAssets The maximum
   */
  function maxWithdraw(
    address _owner
  ) external view returns (uint256 _maxAssets);

  /**
   * @notice Shares a withdrawal would burn
   * @param _assets The assets
   * @return _shares The shares
   */
  function previewWithdraw(
    uint256 _assets
  ) external view returns (uint256 _shares);

  /**
   * @notice Maximum shares redeemable by an owner
   * @param _owner The owner
   * @return _maxShares The maximum
   */
  function maxRedeem(
    address _owner
  ) external view returns (uint256 _maxShares);

  /**
   * @notice Assets a redemption would pay
   * @param _shares The shares
   * @return _assets The assets
   */
  function previewRedeem(
    uint256 _shares
  ) external view returns (uint256 _assets);
}
