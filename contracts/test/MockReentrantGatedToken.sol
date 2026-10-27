// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

/**
 * @title MockReentrantGatedToken
 * @notice A gated token whose `executeTransfer` calls a target once and bubbles up the target's revert, to show that
 *         the executor's reentrancy guard holds on the gated path
 */
contract MockReentrantGatedToken {
  /// @notice The contract to call
  address public target;
  /// @notice The calldata to call it with
  bytes public callData;

  /**
   * @notice Arms the next `executeTransfer`
   * @param _target The contract to call
   * @param _callData The calldata
   */
  function arm(
    address _target,
    bytes calldata _callData
  ) external {
    target = _target;
    callData = _callData;
  }

  /**
   * @notice Calls the armed target, bubbling up its revert, and reports a zero hash
   * @return _hash Zero
   */
  function executeTransfer(
    ITransferIntent.TransferIntent calldata,
    bytes calldata
  ) external returns (bytes32 _hash) {
    address _armed = target;
    target = address(0); // one call back: without a guard the nested call would otherwise recurse until out of gas
    (bool _ok, bytes memory _returned) = _armed.call(callData);
    if (!_ok) {
      assembly ('memory-safe') {
        revert(add(_returned, 0x20), mload(_returned))
      }
    }
    _hash = bytes32(0);
  }
}
