// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import {ERC4626Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IFeeModel} from 'interfaces/IFeeModel.sol';
import {IGated4626Vault} from 'interfaces/IGated4626Vault.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {IPortfolio} from 'interfaces/IPortfolio.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';

import {PolicyGatedERC20Upgradeable} from 'contracts/base/PolicyGatedERC20Upgradeable.sol';
import {GatedVaultBase} from 'contracts/vaults/GatedVaultBase.sol';

/**
 * @title Gated4626Vault
 * @notice ERC-4626 vault whose shares are a policy-gated token, as specified in `IGated4626Vault`
 * @dev Deployed behind a UUPS proxy. Virtual shares with a decimals offset of 6 make first-depositor donation attacks
 *      unprofitable
 */
// No receive or payable function, and upgradeToAndCall rejects value: no ETH can enter (tests: *_Ether).
// aderyn-ignore-next-line(contract-locks-ether)
contract Gated4626Vault is ERC4626Upgradeable, GatedVaultBase, IGated4626Vault {
  using SafeERC20 for IERC20;

  /**
   * @notice ERC-7201 namespaced storage of the vault. All of it is unused while no portfolio is plugged
   * @param portfolio The portfolio; zero while the vault keeps its own money
   * @param lastAt When `last` was counted
   * @param exitOnly Whether an earlier portfolio wrote off an adapter, or a count found the value fallen by more than half
   * @param feeModel The fee model, or zero for none
   * @param markMovedAt When the mark last moved
   * @param lastFeeAt When a fee was last charged
   * @param last The value last counted
   * @param maxRateBps The most the counted value may rise in a year
   * @param feesOwed Fees charged and not yet paid
   * @param mark The high-water mark
   * @custom:storage-location erc7201:gated.storage.Gated4626Vault
   */
  struct Gated4626Storage {
    address portfolio;
    uint64 lastAt;
    bool exitOnly;
    address feeModel;
    uint64 markMovedAt;
    uint64 lastFeeAt;
    uint256 last;
    uint256 maxRateBps;
    uint256 feesOwed;
    uint256 mark;
    uint256 paidSinceMark;
  }

  /// @notice A year's worth of the rate's denominator: basis points per year, in seconds
  uint256 private constant _RATE_DENOMINATOR = 1e4 * 365 days;

  /// @notice The ceiling on the limit, so the arithmetic cannot overflow. It leaves the timelock room to raise the limit
  uint256 private constant _MAX_RATE_BPS = 1e9;

  /// @notice A price's scale: assets per this many share units
  uint256 private constant _PRICE_SCALE = 1e18;

  /// @notice The virtual shares of the decimals offset: share units per unit of the asset at par. Fewer share units
  ///         than this count as no shares
  uint256 private constant _VIRTUAL_SHARES = 1e6;

  /// @notice The mark at par, the lowest it can be: getting back to par recovers principal, and is no gain
  uint256 private constant _PAR_MARK = _PRICE_SCALE / _VIRTUAL_SHARES;

  /// @notice keccak256(abi.encode(uint256(keccak256('gated.storage.Gated4626Vault')) - 1)) & ~bytes32(uint256(0xff))
  // Read in assembly by the ERC-7201 accessor (test: Gated4626VaultPortfolio_Storage).
  // aderyn-ignore-next-line(unused-state-variable)
  bytes32 private constant _GATED_4626_STORAGE_LOCATION =
    0xf7c5c9bdda2a603a74c9f186cabeac6180f7b0be68bbe7656cfbf1baf4988200;

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
    // Parent initializers in linearized order (OZ upgrades-core), with ERC4626's between ERC20's and ERC20Permit's.
    __ERC20_init(_name, _symbol);
    __ERC4626_init(_asset);
    __ERC20Permit_init(_name);
    __AccessControl_init();
    __Pausable_init();
    __Multicall_init();
    __ReentrancyGuard_init();
    __PolicyGatedCore_init_unchained(_admin, _guardian, _registry, _hook, _initialRules);
  }

  /// @inheritdoc IGated4626Vault
  function setPortfolio(
    address _portfolio,
    uint256 _maxRateBps
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_maxRateBps == 0) revert Gated4626Vault_ZeroRate();
    if (_maxRateBps > _MAX_RATE_BPS) revert Gated4626Vault_RateTooHigh(_maxRateBps);
    // View interfaces, compiled to STATICCALL: nothing re-enters before the writes below.
    // aderyn-ignore-next-line(reentrancy-state-change)
    _requireAttested(_portfolio, IPolicyRegistry.AttestKind.PORTFOLIO);
    IPortfolio _next = IPortfolio(_portfolio);
    // aderyn-ignore-next-line(reentrancy-state-change)
    IERC20 _asset = IERC20(asset());
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (_next.VAULT() != address(this) || _next.ASSET() != _asset || _next.ACCEPTS_REPORTED()) {
      revert Gated4626Vault_PortfolioRefused(_portfolio);
    }

    Gated4626Storage storage $ = _getGated4626Storage();
    address _old = $.portfolio;
    if (_old == address(0)) {
      $.lastAt = uint64(block.timestamp);
    } else {
      // An adapter on the list can hold a position that cannot be read now, which `pricedValue()` counts as nothing.
      // A replacement keeps the limit's clock, so the next count allows what it would have allowed anyway.
      // View interfaces, compiled to STATICCALL, and the portfolio is attested: nothing re-enters before these writes.
      // aderyn-ignore-next-line(reentrancy-state-change)
      if (_hasAdapters(_old) || _pricedValue(IPortfolio(_old)) != 0) {
        revert Gated4626Vault_PortfolioNotEmpty();
      }
      // aderyn-ignore-next-line(reentrancy-state-change)
      if (_writtenOff(IPortfolio(_old))) $.exitOnly = true;
    }
    // OpenZeppelin's own count is the asset balance the vault itself holds, which is what is forwarded.
    // aderyn-ignore-next-line(reentrancy-state-change)
    uint256 _held = super.totalAssets();
    $.portfolio = _portfolio;
    $.maxRateBps = _maxRateBps;
    $.last += _held;
    emit PortfolioSet(_portfolio);
    emit MaxRateSet(_maxRateBps);
    if (_held != 0) _asset.safeTransfer(_portfolio, _held);
  }

  /// @inheritdoc IGated4626Vault
  function setMaxRate(
    uint256 _maxRateBps
  ) external {
    Gated4626Storage storage $ = _getGated4626Storage();
    if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
      if (!hasRole(GUARDIAN_ROLE, _msgSender()) || _maxRateBps > $.maxRateBps) {
        revert Gated4626Vault_Unauthorized(_msgSender());
      }
    }
    if (_maxRateBps > _MAX_RATE_BPS) revert Gated4626Vault_RateTooHigh(_maxRateBps);
    // The old rate decides what has counted so far.
    _accrue();
    $.maxRateBps = _maxRateBps;
    emit MaxRateSet(_maxRateBps);
  }

  /// @inheritdoc IGated4626Vault
  function setFeeModel(
    address _feeModel
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    Gated4626Storage storage $ = _getGated4626Storage();
    if ($.portfolio == address(0)) revert Gated4626Vault_NoPortfolio();
    // A view interface, compiled to STATICCALL: nothing re-enters before the writes below.
    // aderyn-ignore-next-line(reentrancy-state-change)
    _requireAttested(_feeModel, IPolicyRegistry.AttestKind.FEE_MODEL);
    _accrue();
    if ($.feeModel == address(0)) {
      if ($.mark == 0) {
        // From what was counted, not from `totalAssets()`, which during a read of nothing would start the mark at nothing.
        $.mark = Math.max(Math.mulDiv(_PRICE_SCALE, $.last + 1, totalSupply() + _VIRTUAL_SHARES), _PAR_MARK);
        $.markMovedAt = uint64(block.timestamp);
      }
      $.lastFeeAt = uint64(block.timestamp);
    }
    $.feeModel = _feeModel;
    emit FeeModelSet(_feeModel);
  }

  /// @inheritdoc IGated4626Vault
  function accrue() external {
    if (_getGated4626Storage().portfolio == address(0)) revert Gated4626Vault_NoPortfolio();
    _accrue();
  }

  /// @inheritdoc IGated4626Vault
  function collectFees() external whenNotPaused {
    Gated4626Storage storage $ = _getGated4626Storage();
    address _feeModel = $.feeModel;
    if (_feeModel == address(0)) revert Gated4626Vault_NoFeeModel();
    _accrue();
    address _portfolio = $.portfolio;
    IERC20 _asset = IERC20(asset());
    // View interfaces, compiled to STATICCALL: nothing re-enters before the write below.
    // aderyn-ignore-next-line(reentrancy-state-change)
    uint256 _assets = Math.min($.feesOwed, _asset.balanceOf(_portfolio));
    // aderyn-ignore-next-line(reentrancy-state-change)
    address _recipient = IFeeModel(_feeModel).RECIPIENT();
    $.feesOwed -= _assets;
    emit FeesCollected(_recipient, _assets);
    // The portfolio gave this vault an allowance at construction; the recipient is the one the attested model names.
    // slither-disable-next-line arbitrary-send-erc20
    _asset.safeTransferFrom(_portfolio, _recipient, _assets); // aderyn-ignore(arbitrary-transfer-from)
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

  /// @inheritdoc ERC4626Upgradeable
  function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8 _decimals) {
    _decimals = super.decimals();
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
   * @notice Virtual shares offset (V5)
   * @return _offset 6
   */
  function _decimalsOffset() internal pure override returns (uint8 _offset) {
    _offset = 6;
  }

  /// @notice Brings the counted value up to date and charges any fee; does nothing with no portfolio or no usable price
  function _accrue() private {
    Gated4626Storage storage $ = _getGated4626Storage();
    if ($.portfolio == address(0) || _dealingStopped()) return;
    (uint256 _counted, uint256 _fee, uint256 _newMark, bool _markMoved, uint256 _paidSince) = _counting();
    if (!$.exitOnly && _fellTooFar(_counted)) {
      $.exitOnly = true;
      emit DepositsClosed(_counted, $.last);
    }
    $.last = _counted - _fee;
    $.lastAt = uint64(block.timestamp);
    emit Accrued(_counted, _fee);
    if ($.feeModel == address(0)) return;
    $.feesOwed += _fee;
    $.mark = _newMark;
    $.paidSinceMark = _paidSince;
    $.lastFeeAt = uint64(block.timestamp);
    if (_markMoved) $.markMovedAt = uint64(block.timestamp);
  }

  /**
   * @notice The value to count now, and the fee due on it
   * @return _counted The value: the priced value net of fees owed, up to the rate limit; the last counted while no price;
   *         zero with no shares, or fewer share units than `_VIRTUAL_SHARES`
   * @return _fee The fee due now
   * @return _newMark The mark after that fee
   * @return _markMoved Whether the mark moved
   * @return _paidSince The performance fee charged since the mark last moved, after that fee
   */
  function _counting()
    private
    view
    returns (uint256 _counted, uint256 _fee, uint256 _newMark, bool _markMoved, uint256 _paidSince)
  {
    Gated4626Storage storage $ = _getGated4626Storage();
    IPortfolio _portfolio = IPortfolio($.portfolio);
    _counted = $.last;
    _newMark = $.mark;
    _paidSince = $.paidSinceMark;
    if (!_priceFresh(_portfolio)) return (_counted, 0, _newMark, false, _paidSince);
    // With no shares nothing is anyone's. A price struck on what is left would be charged as a gain on the next
    // investor's principal, so they buy at par, and the mark starts there. What is left counts for them under the
    // limit. Fewer share units than one unit of the asset buys at par count as none: between them they own less than
    // that unit, and a count on a few of them could move the mark beyond any later gain.
    if (totalSupply() < _VIRTUAL_SHARES) return (0, 0, _PAR_MARK, true, 0);

    uint256 _priced = _pricedValue(_portfolio);
    uint256 _owed = $.feesOwed;
    uint256 _net = _priced > _owed ? _priced - _owed : 0;
    uint256 _limit = _counted + Math.mulDiv(_counted, $.maxRateBps * (block.timestamp - $.lastAt), _RATE_DENOMINATOR);
    _counted = Math.min(_net, _limit);
    address _feeModel = $.feeModel;
    if (_feeModel != address(0)) {
      (_fee, _newMark, _markMoved, _paidSince) = IFeeModel(_feeModel)
        .quote(
          _counted, totalSupply(), _newMark, block.timestamp - $.markMovedAt, block.timestamp - $.lastFeeAt, _paidSince
        );
    }
  }

  /**
   * @notice Whether a portfolio can give a price now. One place for a read that several functions make
   * @param _portfolio The portfolio
   * @return _fresh The portfolio's `priceFresh()`
   */
  function _priceFresh(
    IPortfolio _portfolio
  ) private view returns (bool _fresh) {
    _fresh = _portfolio.priceFresh();
  }

  /**
   * @notice The value a portfolio reports. One place for a read that several functions make
   * @param _portfolio The portfolio
   * @return _value The portfolio's `pricedValue()`
   */
  function _pricedValue(
    IPortfolio _portfolio
  ) private view returns (uint256 _value) {
    _value = _portfolio.pricedValue();
  }

  /**
   * @notice Whether a portfolio has written off an adapter. One place for a read that two functions make
   * @param _portfolio The portfolio
   * @return _written The portfolio's `writtenOff()`
   */
  function _writtenOff(
    IPortfolio _portfolio
  ) private view returns (bool _written) {
    _written = _portfolio.writtenOff();
  }

  /**
   * @notice Whether a portfolio still lists an adapter
   * @dev `adapters()` answers with an array, encoded as its offset and then its length. Only those two words are
   *      copied and the list itself is never decoded, which a call through the interface would do. A failed call or an
   *      answer too short to hold a length reverts
   * @param _portfolio The portfolio
   * @return _has True when its list is not empty
   */
  function _hasAdapters(
    address _portfolio
  ) private view returns (bool _has) {
    bytes4 _selector = IPortfolio.adapters.selector;
    assembly ('memory-safe') {
      mstore(0x00, _selector)
      let _success := staticcall(gas(), _portfolio, 0x00, 0x04, 0x00, 0x40)
      if or(iszero(_success), lt(returndatasize(), 0x40)) { revert(0x00, 0x00) }
      _has := iszero(iszero(mload(0x20)))
    }
  }

  /**
   * @notice Reverts unless a lego's code is attested as the given kind in the vault's registry
   * @param _target The lego
   * @param _kind The kind it must be attested as
   */
  function _requireAttested(
    address _target,
    IPolicyRegistry.AttestKind _kind
  ) private view {
    if (!IPolicyRegistry(registry()).isAttested(_target, _kind)) revert Gated4626Vault_NotAttested(_target);
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
   * @notice Whether no price can be used, which stops deposits and withdrawals: it cannot be read, or the value net of
   *         fees reads nothing although holders have a value counted. Holders of fewer share units than
   *         `_VIRTUAL_SHARES` count as none, as in `_counting`. Nothing is written down, so the value can come back
   * @return _stopped True when none can
   */
  function _dealingStopped() private view returns (bool _stopped) {
    Gated4626Storage storage $ = _getGated4626Storage();
    IPortfolio _portfolio = IPortfolio($.portfolio);
    if (address(_portfolio) == address(0)) return false;
    if (!_priceFresh(_portfolio)) return true;
    _stopped = $.last != 0 && totalSupply() >= _VIRTUAL_SHARES && _pricedValue(_portfolio) <= $.feesOwed;
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

  /**
   * @notice Whether a value counted now is less than half of the last, with holders who bore it. Someone depositing at that
   *         price would take part of any recovery from them, as after a write-off. Zero is no such value: it means no shares,
   *         which nobody bore, or a read of nothing, which a count does not write
   * @param _counted The value counted now
   * @return _fell True when it is
   */
  function _fellTooFar(
    uint256 _counted
  ) private view returns (bool _fell) {
    _fell = _counted != 0 && _counted * 2 < _getGated4626Storage().last;
  }

  /**
   * @notice The ERC-7201 storage of the vault
   * @return $ The storage pointer
   */
  function _getGated4626Storage() private pure returns (Gated4626Storage storage $) {
    assembly ('memory-safe') {
      $.slot := _GATED_4626_STORAGE_LOCATION
    }
  }
}
