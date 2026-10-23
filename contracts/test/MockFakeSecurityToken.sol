// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

/**
 * @title MockFakeSecurityToken
 * @notice A counterfeit security token for tests: it reports whatever intent hash it is told to, and its
 *         `executeTransfer` moves nothing. It stands for a token an operator might substitute for the real one
 */
contract MockFakeSecurityToken {
  /// @notice The hash `intentHash` and `executeTransfer` report
  bytes32 public hashToReturn;

  /**
   * @notice Sets the hash to report
   * @param _hash The hash
   */
  function setHash(
    bytes32 _hash
  ) external {
    hashToReturn = _hash;
  }

  /**
   * @notice Reports the configured hash
   * @return _hash The configured hash
   */
  function intentHash(
    ITransferIntent.TransferIntent calldata
  ) external view returns (bytes32 _hash) {
    _hash = hashToReturn;
  }

  /**
   * @notice Pretends to execute: moves nothing and reports the configured hash
   * @return _hash The configured hash
   */
  function executeTransfer(
    ITransferIntent.TransferIntent calldata,
    bytes calldata
  ) external view returns (bytes32 _hash) {
    _hash = hashToReturn;
  }
}
