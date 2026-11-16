// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC4626Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Address} from '@openzeppelin/contracts/utils/Address.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IGated4626Vault} from 'interfaces/IGated4626Vault.sol';
import {IPortfolio} from 'interfaces/IPortfolio.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';

// Needed by the compiler to resolve `@inheritdoc PolicyGatedERC20Upgradeable`; solhint does not see NatSpec usage.
// solhint-disable-next-line no-unused-vars
import {PolicyGatedERC20Upgradeable} from 'contracts/base/PolicyGatedERC20Upgradeable.sol';
import {Gated4626Common} from 'contracts/vaults/Gated4626Common.sol';
import {Gated4626Management} from 'contracts/vaults/Gated4626Management.sol';

/**
 * @title Gated4626Vault
 * @notice ERC-4626 vault whose shares are a policy-gated token, as specified in `IGated4626Vault`
 * @dev Deployed behind a UUPS proxy. Virtual shares with a decimals offset of 6 make first-depositor donation attacks
 *      unprofitable. Everything an investor calls runs here; plugging a portfolio, the rate limit, the fee model and
 *      paying fees are named here and run in `MANAGEMENT_LOGIC`
 */
// No receive or payable function, and upgradeToAndCall rejects value: no ETH can enter (tests: *_Ether).
// aderyn-ignore-next-line(contract-locks-ether)
contract Gated4626Vault is Gated4626Common, IGated4626Vault {
  using SafeERC20 for IERC20;

  /**
   * @inheritdoc IGated4626Vault
   * @custom:oz-upgrades-unsafe-allow state-variable-immutable
   */
  address public immutable MANAGEMENT_LOGIC;

  /**
   * @notice Creates the second contract and locks the implementation; only proxies can be initialized
   * @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable state-variable-assignment
   */
  constructor() {
    MANAGEMENT_LOGIC = address(new Gated4626Management());
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
    // Parent initializers in linearized order (OZ upgrades-core), with ERC4626's between ERC20's and ERC20Permit's.
    __ERC20_init(_name, _symbol);
    __ERC4626_init(_asset);
    __ERC20Permit_init(_name);
    __AccessControl_init();
    __Pausable_init();
    __Multicall_init();
    __PolicyGatedCore_init_unchained(_admin, _guardian, _registry, _hook, _initialRules);
  }

  /// @inheritdoc IGated4626Vault
  // The target is MANAGEMENT_LOGIC, an immutable this implementation's constructor creates: no caller chooses it.
  // aderyn-ignore-next-line(delegate-call-unchecked-address)
  function setPortfolio(
    address,
    uint256
  ) external {
    _toManagement();
  }

  /// @inheritdoc IGated4626Vault
  // The target is MANAGEMENT_LOGIC, an immutable this implementation's constructor creates: no caller chooses it.
  // aderyn-ignore-next-line(delegate-call-unchecked-address)
  function setMaxRate(
    uint256
  ) external {
    _toManagement();
  }

  /// @inheritdoc IGated4626Vault
  // The target is MANAGEMENT_LOGIC, an immutable this implementation's constructor creates: no caller chooses it.
  // aderyn-ignore-next-line(delegate-call-unchecked-address)
  function setFeeModel(
    address
  ) external {
    _toManagement();
  }

  /// @inheritdoc IGated4626Vault
  function accrue() external {
    if (_getGated4626Storage().portfolio == address(0)) revert Gated4626Vault_NoPortfolio();
    _accrue();
  }

  /// @inheritdoc IGated4626Vault
  // The target is MANAGEMENT_LOGIC, an immutable this implementation's constructor creates: no caller chooses it.
  // aderyn-ignore-next-line(delegate-call-unchecked-address)
  function collectFees() external {
    _toManagement();
  }

  /// @inheritdoc IGated4626Vault
  function portfolio() external view returns (address _portfolio) {
    _portfolio = _getGated4626Storage().portfolio;
  }

  /// @inheritdoc IGated4626Vault
  function feeModel() external view returns (address _feeModel) {
    _feeModel = _getGated4626Storage().feeModel;
  }

  /// @inheritdoc IGated4626Vault
  function maxRate() external view returns (uint256 _maxRateBps) {
    _maxRateBps = _getGated4626Storage().maxRateBps;
  }

  /// @inheritdoc IGated4626Vault
  function lastCounted() external view returns (uint256 _last) {
    _last = _getGated4626Storage().last;
  }

  /// @inheritdoc IGated4626Vault
  function feesOwed() external view returns (uint256 _assets) {
    _assets = _getGated4626Storage().feesOwed;
  }

  /// @inheritdoc IGated4626Vault
  function mark() external view returns (uint256 _mark) {
    _mark = _getGated4626Storage().mark;
  }

  /// @inheritdoc IGated4626Vault
  function paidSinceMark() external view returns (uint256 _paid) {
    _paid = _getGated4626Storage().paidSinceMark;
  }

  /// @inheritdoc IGated4626Vault
  function exitOnly() external view returns (bool _exitOnly) {
    _exitOnly = _closedForGood();
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev Counts the value first, so a price quoted from it is the price paid
   */
  function deposit(
    uint256 _assets,
    address _receiver
  ) public override(ERC4626Upgradeable) returns (uint256 _shares) {
    _accrue();
    _shares = super.deposit(_assets, _receiver);
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev Counts the value first, so a price quoted from it is the price paid
   */
  function mint(
    uint256 _shares,
    address _receiver
  ) public override(ERC4626Upgradeable) returns (uint256 _assets) {
    _accrue();
    _assets = super.mint(_shares, _receiver);
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev Counts the value first, so a price quoted from it is the price paid
   */
  function withdraw(
    uint256 _assets,
    address _receiver,
    address _owner
  ) public override(ERC4626Upgradeable) returns (uint256 _shares) {
    _accrue();
    _shares = super.withdraw(_assets, _receiver, _owner);
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev Counts the value first, so a price quoted from it is the price paid
   */
  function redeem(
    uint256 _shares,
    address _receiver,
    address _owner
  ) public override(ERC4626Upgradeable) returns (uint256 _assets) {
    _accrue();
    _assets = super.redeem(_shares, _receiver, _owner);
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev With a portfolio, the counted value net of any fee due now; it never reverts on a loss below the fees owed
   */
  function totalAssets() public view override returns (uint256 _total) {
    if (_getGated4626Storage().portfolio == address(0)) return super.totalAssets();
    (uint256 _counted, uint256 _fee,,,) = _counting();
    _total = _counted - _fee;
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev 0 when paused or when a mint of a very large amount to `_receiver` would be rejected (identity, freeze, the
   *      holder caps). The amount is above any minimum position up to `type(uint128).max`, so such a minimum does not read as a block
   */
  function maxDeposit(
    address _receiver
  ) public view override returns (uint256 _maxAssets) {
    if (_entryClosed(_receiver)) return 0;
    _maxAssets = super.maxDeposit(_receiver);
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev 0 when paused or when a mint to `_receiver` would be rejected, as `maxDeposit`
   */
  function maxMint(
    address _receiver
  ) public view override returns (uint256 _maxShares) {
    if (_entryClosed(_receiver)) return 0;
    _maxShares = super.maxMint(_receiver);
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev The unfrozen balance, up to what the portfolio can raise; 0 when paused, when a price cannot be read, or when the
   *      policy would reject a burn from `_owner` (identity, freeze, lockup). The probe burns nothing: one share would leave a
   *      remainder, which a minimum position rejects, and hide a holder who can redeem everything. The size of a real
   *      redemption is judged when it burns
   */
  function maxRedeem(
    address _owner
  ) public view override returns (uint256 _maxShares) {
    if (_canTransfer(_owner, address(0), 0) != Reasons.TRANSFER_OK || _dealingStopped()) return 0;
    _maxShares = _unfrozenBalance(_owner);
    address _portfolio = _getGated4626Storage().portfolio;
    if (_portfolio != address(0)) {
      uint256 _liquid = IPortfolio(_portfolio).liquidAssets();
      // Rounding the liquid assets down to shares would strand dust from a position that is wholly liquid.
      if (_convertToAssets(_maxShares, Math.Rounding.Floor) > _liquid) {
        _maxShares = _convertToShares(_liquid, Math.Rounding.Floor);
      }
    }
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
   * @inheritdoc ERC4626Upgradeable
   * @dev A payer other than the receiver must pass the token's policy (the receiver is judged by the mint). `maxDeposit`
   *      names only the receiver, so it cannot say this
   */
  function _deposit(
    address _caller,
    address _receiver,
    uint256 _assets,
    uint256 _shares
  ) internal override {
    _requireThirdPartyEligible(_caller, _receiver);
    Gated4626Storage storage $ = _getGated4626Storage();
    address _portfolio = $.portfolio;
    if (_portfolio != address(0)) $.last += _assets;
    super._deposit(_caller, _receiver, _assets, _shares);
    if (_portfolio != address(0)) IERC20(asset()).safeTransfer(_portfolio, _assets);
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev A receiver other than the owner must pass the token's policy. An owner paying itself is not judged here, so a
   *      lapsed holder can still leave. `maxWithdraw` and `maxRedeem` name only the owner, so they cannot say this
   */
  function _withdraw(
    address _caller,
    address _receiver,
    address _owner,
    uint256 _assets,
    uint256 _shares
  ) internal override {
    _requireThirdPartyEligible(_receiver, _owner);
    Gated4626Storage storage $ = _getGated4626Storage();
    address _portfolio = $.portfolio;
    if (_portfolio != address(0)) {
      $.last -= _assets;
      IPortfolio(_portfolio).raise(_assets);
      // The portfolio gave this vault an allowance at construction, for this.
      // slither-disable-next-line arbitrary-send-erc20
      IERC20(asset()).safeTransferFrom(_portfolio, address(this), _assets); // aderyn-ignore(arbitrary-transfer-from)
    }
    super._withdraw(_caller, _receiver, _owner, _assets, _shares);
  }

  /**
   * @notice Hands this call to the second contract, unchanged, and passes back a revert as it came
   * @custom:oz-upgrades-unsafe-allow-reachable delegatecall
   */
  function _toManagement() private {
    // The moved functions return nothing, and the target is this implementation's own immutable.
    // slither-disable-next-line unused-return
    Address.functionDelegateCall(MANAGEMENT_LOGIC, msg.data); // aderyn-ignore(unchecked-return)
  }

  /**
   * @notice Whether nothing can be deposited for a receiver: the policy refuses a mint to it, no price can be used, or
   *         the vault is exit-only
   * @param _receiver The receiver of the shares
   * @return _closed True when a deposit or a mint for it would revert
   */
  function _entryClosed(
    address _receiver
  ) private view returns (bool _closed) {
    _closed = _mintProbe(_receiver) != Reasons.TRANSFER_OK || _dealingStopped() || _closedForGood();
  }

  /**
   * @notice Whether deposits are closed: a portfolio, this one or an earlier one, wrote off an adapter, or a count found the
   *         value fallen by more than half, or one now would
   * @return _closed True when they are
   */
  function _closedForGood() private view returns (bool _closed) {
    Gated4626Storage storage $ = _getGated4626Storage();
    address _portfolio = $.portfolio;
    if ($.exitOnly) return true;
    if (_portfolio == address(0)) return false;
    if (_writtenOff(IPortfolio(_portfolio))) return true;
    (uint256 _counted,,,,) = _counting();
    _closed = _fellTooFar(_counted);
  }
}
