// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import {ERC4626Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IFeeModel} from 'interfaces/IFeeModel.sol';
import {IGated4626Vault} from 'interfaces/IGated4626Vault.sol';
import {IPortfolio} from 'interfaces/IPortfolio.sol';

import {PolicyGatedERC20Upgradeable} from 'contracts/base/PolicyGatedERC20Upgradeable.sol';
import {GatedVaultBase} from 'contracts/vaults/GatedVaultBase.sol';

/**
 * @title Gated4626Common
 * @notice What `Gated4626Vault` and `Gated4626Management` share: the storage they both act on and how the value is
 *         counted
 * @dev Its own contract, so that the two cannot disagree on the layout or on a count
 */
abstract contract Gated4626Common is ERC4626Upgradeable, GatedVaultBase {
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
  uint256 internal constant _RATE_DENOMINATOR = 1e4 * 365 days;

  /// @notice A price's scale: assets per this many share units
  uint256 internal constant _PRICE_SCALE = 1e18;

  /// @notice The virtual shares of the decimals offset: share units per unit of the asset at par. Fewer share units
  ///         than this count as no shares
  uint256 internal constant _VIRTUAL_SHARES = 1e6;

  /// @notice The mark at par, the lowest it can be: getting back to par recovers principal, and is no gain
  uint256 internal constant _PAR_MARK = _PRICE_SCALE / _VIRTUAL_SHARES;

  /// @notice keccak256(abi.encode(uint256(keccak256('gated.storage.Gated4626Vault')) - 1)) & ~bytes32(uint256(0xff))
  // Read in assembly by the ERC-7201 accessor (test: Gated4626VaultPortfolio_Storage).
  // aderyn-ignore-next-line(unused-state-variable)
  bytes32 private constant _GATED_4626_STORAGE_LOCATION =
    0xf7c5c9bdda2a603a74c9f186cabeac6180f7b0be68bbe7656cfbf1baf4988200;

  /// @inheritdoc ERC4626Upgradeable
  function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8 _decimals) {
    _decimals = super.decimals();
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

  /// @notice Brings the counted value up to date and charges any fee; does nothing with no portfolio or no usable price
  function _accrue() internal {
    Gated4626Storage storage $ = _getGated4626Storage();
    if ($.portfolio == address(0) || _dealingStopped()) return;
    (uint256 _counted, uint256 _fee, uint256 _newMark, bool _markMoved, uint256 _paidSince) = _counting();
    if (!$.exitOnly && _fellTooFar(_counted)) {
      $.exitOnly = true;
      emit IGated4626Vault.DepositsClosed(_counted, $.last);
    }
    $.last = _counted - _fee;
    $.lastAt = uint64(block.timestamp);
    emit IGated4626Vault.Accrued(_counted, _fee);
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
    internal
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
  ) internal view returns (bool _fresh) {
    _fresh = _portfolio.priceFresh();
  }

  /**
   * @notice The value a portfolio reports. One place for a read that several functions make
   * @param _portfolio The portfolio
   * @return _value The portfolio's `pricedValue()`
   */
  function _pricedValue(
    IPortfolio _portfolio
  ) internal view returns (uint256 _value) {
    _value = _portfolio.pricedValue();
  }

  /**
   * @notice Whether a portfolio has written off an adapter. One place for a read that two functions make
   * @param _portfolio The portfolio
   * @return _written The portfolio's `writtenOff()`
   */
  function _writtenOff(
    IPortfolio _portfolio
  ) internal view returns (bool _written) {
    _written = _portfolio.writtenOff();
  }

  /**
   * @notice Whether no price can be used, which stops deposits and withdrawals: it cannot be read, or the value net of
   *         fees reads nothing although holders have a value counted. Holders of fewer share units than
   *         `_VIRTUAL_SHARES` count as none, as in `_counting`. Nothing is written down, so the value can come back
   * @return _stopped True when none can
   */
  function _dealingStopped() internal view returns (bool _stopped) {
    Gated4626Storage storage $ = _getGated4626Storage();
    IPortfolio _portfolio = IPortfolio($.portfolio);
    if (address(_portfolio) == address(0)) return false;
    if (!_priceFresh(_portfolio)) return true;
    _stopped = $.last != 0 && totalSupply() >= _VIRTUAL_SHARES && _pricedValue(_portfolio) <= $.feesOwed;
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
  ) internal view returns (bool _fell) {
    _fell = _counted != 0 && _counted * 2 < _getGated4626Storage().last;
  }

  /**
   * @notice Virtual shares offset (V5)
   * @return _offset 6
   */
  function _decimalsOffset() internal pure override returns (uint8 _offset) {
    _offset = 6;
  }

  /**
   * @notice The ERC-7201 storage of the vault
   * @return $ The storage pointer
   */
  function _getGated4626Storage() internal pure returns (Gated4626Storage storage $) {
    assembly ('memory-safe') {
      $.slot := _GATED_4626_STORAGE_LOCATION
    }
  }
}
