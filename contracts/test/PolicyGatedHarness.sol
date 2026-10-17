// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {PolicyGatedERC20Upgradeable} from 'contracts/base/PolicyGatedERC20Upgradeable.sol';

/**
 * @title PolicyGatedHarness
 * @notice Minimal concrete token over the abstract base, used to unit-test the base in isolation
 */
contract PolicyGatedHarness is PolicyGatedERC20Upgradeable {
  /**
   * @notice Locks the implementation
   * @custom:oz-upgrades-unsafe-allow constructor
   */
  constructor() {
    _disableInitializers();
  }

  /**
   * @notice Initializes a proxy
   * @param _name The token name
   * @param _symbol The token symbol
   * @param _admin The admin (timelock)
   * @param _guardian The guardian
   * @param _registry The policy registry
   * @param _hook The initial hook
   */
  function initialize(
    string calldata _name,
    string calldata _symbol,
    address _admin,
    address _guardian,
    address _registry,
    address _hook
  ) external initializer {
    __PolicyGatedERC20_init(_name, _symbol, _admin, _guardian, _registry, _hook);
  }

  /**
   * @notice Exposes the internal kind-announcing mint for unit tests
   * @param _to The receiver
   * @param _amount The amount
   * @param _kind The kind the hook sees
   */
  function mintAs(
    address _to,
    uint256 _amount,
    IPolicyHook.TransferKind _kind
  ) external {
    _mintAs(_to, _amount, _kind);
  }
}
