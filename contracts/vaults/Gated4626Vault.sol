// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import {ERC4626Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IGated4626Vault} from 'interfaces/IGated4626Vault.sol';
// Needed by the compiler to resolve `@inheritdoc IPolicyGated`; solhint does not see NatSpec usage.
// solhint-disable-next-line no-unused-vars
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';

import {PolicyGatedERC20Upgradeable} from 'contracts/base/PolicyGatedERC20Upgradeable.sol';

/**
 * @title Gated4626Vault
 * @notice ERC-4626 vault whose shares are a policy-gated token, as specified in `IGated4626Vault`
 * @dev Deployed behind a UUPS proxy. Virtual shares with a decimals offset of 6 make first-depositor donation attacks
 *      unprofitable
 */
// No receive or payable function, and upgradeToAndCall rejects value: no ETH can enter (tests: *_Ether).
// aderyn-ignore-next-line(contract-locks-ether)
contract Gated4626Vault is ERC4626Upgradeable, PolicyGatedERC20Upgradeable, IGated4626Vault {
  /**
   * @notice Locks the implementation; only proxies can be initialized
   * @custom:oz-upgrades-unsafe-allow constructor
   */
  constructor() {
    _disableInitializers();
  }

  /// @inheritdoc IGated4626Vault
  function initialize(
    IERC20 _asset,
    string calldata _name,
    string calldata _symbol,
    address _admin,
    address _guardian,
    address _registry,
    address _hook,
    IComplianceRule[] memory _initialRules
  ) external initializer {
    // Parent initializers in linearized order (OZ upgrades-core): the base's composite init is expanded around ERC4626.
    __ERC20_init(_name, _symbol);
    __ERC4626_init(_asset);
    __ERC20Permit_init(_name);
    __AccessControl_init();
    __Pausable_init();
    __Multicall_init();
    __PolicyGatedERC20_init_unchained(_admin, _guardian, _registry, _hook, _initialRules);
  }

  /**
   * @inheritdoc IPolicyGated
   * @dev Always reverts: vault shares are minted only by deposits
   */
  function mint(
    address,
    uint256
  ) external pure override {
    revert Gated4626Vault_Unsupported();
  }

  /**
   * @inheritdoc IPolicyGated
   * @dev Always reverts: vault shares are burned only by redemptions
   */
  function burn(
    address,
    uint256
  ) external pure override {
    revert Gated4626Vault_Unsupported();
  }

  /// @inheritdoc ERC4626Upgradeable
  function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8 _decimals) {
    _decimals = super.decimals();
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev 0 when paused or when the policy would reject a mint to `_receiver`
   */
  function maxDeposit(
    address _receiver
  ) public view override returns (uint256 _maxAssets) {
    if (_canTransfer(address(0), _receiver, 1) != Reasons.TRANSFER_OK) return 0;
    _maxAssets = super.maxDeposit(_receiver);
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev 0 when paused or when the policy would reject a mint to `_receiver`
   */
  function maxMint(
    address _receiver
  ) public view override returns (uint256 _maxShares) {
    if (_canTransfer(address(0), _receiver, 1) != Reasons.TRANSFER_OK) return 0;
    _maxShares = super.maxMint(_receiver);
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev The unfrozen balance; 0 when paused or when the policy would reject a burn from `_owner`
   */
  function maxRedeem(
    address _owner
  ) public view override returns (uint256 _maxShares) {
    if (_canTransfer(_owner, address(0), 1) != Reasons.TRANSFER_OK) return 0;
    _maxShares = _unfrozenBalance(_owner);
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev Derived from `maxRedeem` rounding down, so it never promises more than `withdraw` can burn
   */
  function maxWithdraw(
    address _owner
  ) public view override returns (uint256 _maxAssets) {
    _maxAssets = _convertToAssets(maxRedeem(_owner), Math.Rounding.Floor);
  }

  /// @inheritdoc PolicyGatedERC20Upgradeable
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(IERC4626).interfaceId || super.supportsInterface(_interfaceId);
  }

  /// @inheritdoc ITemplated
  function templateId() public pure override returns (bytes32 _id) {
    _id = keccak256('Gated4626Vault');
  }

  /**
   * @notice Routes every share movement through the policy hook
   * @param _from The sender, or address(0) on deposit
   * @param _to The receiver, or address(0) on redemption
   * @param _value The share amount
   */
  function _update(
    address _from,
    address _to,
    uint256 _value
  ) internal override(ERC20Upgradeable, PolicyGatedERC20Upgradeable) {
    super._update(_from, _to, _value);
  }

  /**
   * @notice Virtual shares offset (V5)
   * @return _offset 6
   */
  function _decimalsOffset() internal pure override returns (uint8 _offset) {
    _offset = 6;
  }
}
