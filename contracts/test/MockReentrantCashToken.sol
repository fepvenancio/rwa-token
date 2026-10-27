// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {MockERC3009Token} from 'contracts/test/MockERC3009Token.sol';

/**
 * @title MockReentrantCashToken
 * @notice A `MockERC3009Token` that, once armed, calls a target during its next balance update and bubbles up the
 *         target's revert. Tests arm it with a call back into the executor, to show the reentrancy guard holds
 */
contract MockReentrantCashToken is MockERC3009Token {
  /// @notice The contract to call, or zero when not armed
  address public target;
  /// @notice The calldata to call it with
  bytes public callData;
  /// @notice How many balance updates to let through before calling the target
  uint256 public skip;

  /**
   * @notice Arms the next balance update
   * @param _target The contract to call
   * @param _callData The calldata
   * @param _skip The number of balance updates to let through first
   */
  function arm(
    address _target,
    bytes calldata _callData,
    uint256 _skip
  ) external {
    target = _target;
    callData = _callData;
    skip = _skip;
  }

  /// @inheritdoc MockERC3009Token
  function _update(
    address _from,
    address _to,
    uint256 _value
  ) internal override {
    address _armed = target;
    if (_armed != address(0) && skip > 0) {
      --skip;
    } else if (_armed != address(0)) {
      target = address(0);
      (bool _ok, bytes memory _returned) = _armed.call(callData);
      if (!_ok) {
        assembly ('memory-safe') {
          revert(add(_returned, 0x20), mload(_returned))
        }
      }
    }
    super._update(_from, _to, _value);
  }
}
