// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title MockSafe
 * @notice The one thing the hand-over check asks a multisig: how many signers it takes
 */
contract MockSafe {
  /// @notice The signers it takes
  uint256 public immutable THRESHOLD;

  /**
   * @notice Deploys the mock
   * @param _threshold The signers it takes
   */
  constructor(
    uint256 _threshold
  ) {
    THRESHOLD = _threshold;
  }

  /**
   * @notice The signers it takes, as a Safe answers it
   * @return _threshold The signers
   */
  function getThreshold() external view returns (uint256 _threshold) {
    _threshold = THRESHOLD;
  }
}
