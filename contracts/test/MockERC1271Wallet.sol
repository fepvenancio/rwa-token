// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC1271} from '@openzeppelin/contracts/interfaces/IERC1271.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

/**
 * @title MockERC1271Wallet
 * @notice A contract account that accepts the ECDSA signatures of one owner key, standing in for an HSM-backed or Safe
 *         attester in tests
 */
contract MockERC1271Wallet is IERC1271 {
  /// @notice The key whose signatures the wallet accepts
  address public immutable OWNER;

  /**
   * @notice Deploys the wallet
   * @param _owner The key whose signatures the wallet accepts
   */
  constructor(
    address _owner
  ) {
    OWNER = _owner;
  }

  /// @inheritdoc IERC1271
  function isValidSignature(
    bytes32 _hash,
    bytes calldata _signature
  ) external view returns (bytes4 _magic) {
    (address _recovered, ECDSA.RecoverError _error,) = ECDSA.tryRecover(_hash, _signature);
    _magic = _error == ECDSA.RecoverError.NoError && _recovered == OWNER
      ? IERC1271.isValidSignature.selector
      : bytes4(0xffffffff);
  }
}
