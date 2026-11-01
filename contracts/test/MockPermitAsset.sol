// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {ERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol';

/**
 * @title MockPermitAsset
 * @notice Freely mintable ERC-20 of 6 decimals with ERC-2612 `permit`, used as a vault asset in tests
 */
contract MockPermitAsset is ERC20Permit {
  constructor() ERC20('Mock Permit USD', 'pUSD') ERC20Permit('Mock Permit USD') {}

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
  function decimals() public pure override returns (uint8 _decimalsValue) {
    _decimalsValue = 6;
  }
}
