// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';

import {ICallValidator} from 'interfaces/ICallValidator.sol';

/**
 * @title ERC4626CallValidator
 * @notice Allows `deposit`, `mint`, `withdraw` and `redeem` on an ERC-4626 vault when the receiver and owner are the
 *         calling account, so money and shares can only come back to it
 * @dev Immutable, attested as VALIDATOR. It has no settings: the permission names the target
 */
contract ERC4626CallValidator is ICallValidator {
  /// @notice The length of a function selector
  // Slither does not see a constant used as a slice's bound.
  // slither-disable-next-line unused-state
  uint256 private constant _SELECTOR_LENGTH = 4;

  /// @notice The length of a `deposit` or `mint`
  uint256 private constant _ENTRY_LENGTH = 68;

  /// @notice The length of a `withdraw` or `redeem`
  uint256 private constant _EXIT_LENGTH = 100;

  /// @inheritdoc ICallValidator
  function validate(
    address _account,
    address,
    bytes calldata _data
  ) external pure returns (bool _allowed) {
    bytes4 _selector = bytes4(_data);
    if (_selector == IERC4626.deposit.selector || _selector == IERC4626.mint.selector) {
      if (_data.length != _ENTRY_LENGTH) return false;
      (, address _receiver) = abi.decode(_data[_SELECTOR_LENGTH:], (uint256, address));
      _allowed = _receiver == _account;
    } else if (_selector == IERC4626.withdraw.selector || _selector == IERC4626.redeem.selector) {
      if (_data.length != _EXIT_LENGTH) return false;
      (, address _receiver, address _owner) = abi.decode(_data[_SELECTOR_LENGTH:], (uint256, address, address));
      _allowed = _receiver == _account && _owner == _account;
    }
  }
}
