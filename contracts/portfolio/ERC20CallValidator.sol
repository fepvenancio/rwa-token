// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {ICallValidator} from 'interfaces/ICallValidator.sol';
import {IERC20CallValidator} from 'interfaces/IERC20CallValidator.sol';

/**
 * @title ERC20CallValidator
 * @notice As specified in `IERC20CallValidator`
 * @dev Immutable, attested as VALIDATOR. All its settings are immutables, so the attested codehash covers them
 */
contract ERC20CallValidator is IERC20CallValidator {
  /// @notice The length of a call that names an address and an amount
  uint256 private constant _CALL_LENGTH = 68;

  /// @inheritdoc IERC20CallValidator
  address public immutable WHO;

  /// @inheritdoc IERC20CallValidator
  uint256 public immutable MAX_PER_CALL;

  /**
   * @notice Deploys the validator
   * @param _who The one address allowed
   * @param _maxPerCall The most one call may name
   */
  constructor(
    address _who,
    uint256 _maxPerCall
  ) {
    if (_who == address(0)) revert ERC20CallValidator_ZeroAddress();
    WHO = _who;
    MAX_PER_CALL = _maxPerCall;
  }

  /// @inheritdoc ICallValidator
  function validate(
    address,
    address,
    bytes calldata _data
  ) external view returns (bool _allowed) {
    if (_data.length != _CALL_LENGTH) return false;
    bytes4 _selector = bytes4(_data);
    // Only reads the selectors; this contract moves no tokens.
    // aderyn-ignore-next-line(unsafe-erc20-operation)
    if (_selector != IERC20.transfer.selector && _selector != IERC20.approve.selector) return false;
    (address _to, uint256 _amount) = abi.decode(_data[4:], (address, uint256));
    _allowed = _to == WHO && _amount <= MAX_PER_CALL;
  }
}
