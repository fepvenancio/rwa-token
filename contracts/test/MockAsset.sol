// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/**
 * @title MockAsset
 * @notice Freely mintable ERC-20 with configurable decimals, used as a vault asset in tests
 */
contract MockAsset is ERC20 {
  /// @notice The token decimals
  uint8 internal immutable _DECIMALS;

  /**
   * @notice Deploys the asset
   * @param _decimalsValue The decimals, e.g. 6 for a USDC-like asset
   */
  constructor(
    uint8 _decimalsValue
  ) ERC20('Mock USD', 'mUSD') {
    _DECIMALS = _decimalsValue;
  }

  /**
   * @notice Mints tokens to an account
   * @param _to The receiver
   * @param _amount The amount
   */
  function mint(
    address _to,
    uint256 _amount
  ) external {
    _mint(_to, _amount);
  }

  /// @inheritdoc ERC20
  function decimals() public view override returns (uint8 _decimalsValue) {
    _decimalsValue = _DECIMALS;
  }
}
