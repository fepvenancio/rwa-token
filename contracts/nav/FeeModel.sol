// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IFeeModel} from 'interfaces/IFeeModel.sol';

/**
 * @title FeeModel
 * @notice Computes a period's fee, as specified in `IFeeModel`
 * @dev Immutable, attested as FEE_MODEL
 */
contract FeeModel is IFeeModel {
  /// @notice The ceiling on the yearly management rate
  uint256 private constant _MAX_MANAGEMENT_BPS = 500;

  /// @notice The ceiling on the performance rate and the yearly hurdle rate
  uint256 private constant _MAX_RATE_BPS = 5000;

  /// @notice One hundred percent
  uint256 private constant _BPS = 1e4;

  /// @notice The seconds in a year
  uint256 private constant _YEAR = 365 days;

  /// @notice The longest age counted: at the management ceiling, the whole gross value, so a fee never exceeds it
  uint256 private constant _MAX_AGE = 20 * _YEAR;

  /// @notice A price's scale: assets per this many share units
  uint256 private constant _PRICE_SCALE = 1e18;

  /// @notice Above this a figure cannot be real, and gets no fee rather than a revert
  uint256 private constant _MAX_FIGURE = type(uint128).max;

  /// @inheritdoc IFeeModel
  address public immutable RECIPIENT;

  /// @inheritdoc IFeeModel
  uint256 public immutable MANAGEMENT_BPS;

  /// @inheritdoc IFeeModel
  uint256 public immutable PERFORMANCE_BPS;

  /// @inheritdoc IFeeModel
  uint256 public immutable HURDLE_BPS;

  /// @inheritdoc IFeeModel
  bool public immutable SOFT_HURDLE;

  /**
   * @notice Deploys the model
   * @param _recipient Who is paid; not zero, even with no rate, as a swap to this model must still pay what is owed
   * @param _managementBps The yearly management rate
   * @param _performanceBps The performance rate
   * @param _hurdleBps The yearly hurdle rate
   * @param _softHurdle True for a soft hurdle with a full catch-up
   */
  constructor(
    address _recipient,
    uint256 _managementBps,
    uint256 _performanceBps,
    uint256 _hurdleBps,
    bool _softHurdle
  ) {
    if (_managementBps > _MAX_MANAGEMENT_BPS || _performanceBps > _MAX_RATE_BPS || _hurdleBps > _MAX_RATE_BPS) {
      revert FeeModel_RateTooHigh();
    }
    if (_recipient == address(0)) revert FeeModel_ZeroRecipient();
    RECIPIENT = _recipient;
    MANAGEMENT_BPS = _managementBps;
    PERFORMANCE_BPS = _performanceBps;
    HURDLE_BPS = _hurdleBps;
    SOFT_HURDLE = _softHurdle;
  }

  /// @inheritdoc IFeeModel
  function quote(
    uint256 _gross,
    uint256 _supply,
    uint256 _mark,
    uint256 _markAge,
    uint256 _feeAge,
    uint256 _paidSince
  ) external view returns (uint256 _fee, uint256 _newMark, bool _markMoved, uint256 _newPaidSince) {
    _newMark = _mark;
    _newPaidSince = _paidSince;
    if (
      _supply == 0 || _supply > _MAX_FIGURE || _gross > _MAX_FIGURE || _mark > _MAX_FIGURE || _paidSince > _MAX_FIGURE
    ) return (0, _mark, false, _paidSince);

    _fee = Math.mulDiv(_gross, MANAGEMENT_BPS * Math.min(_feeAge, _MAX_AGE), _BPS * _YEAR);
    uint256 _paid;
    (_paid, _newMark, _markMoved, _newPaidSince) =
      _performanceFee(Math.mulDiv(_gross - _fee, _PRICE_SCALE, _supply), _supply, _mark, _markAge, _paidSince);
    _fee += _paid;
  }

  /**
   * @notice The performance fee this count pays, and where it leaves the mark
   * @param _price The price after the management fee: assets per `_PRICE_SCALE` share units
   * @param _supply All shares
   * @param _mark The high-water mark
   * @param _markAge The seconds since the mark last moved
   * @param _paidSince The performance fee paid since the mark last moved, per `_PRICE_SCALE` share units
   * @return _paid The fee, in assets
   * @return _newMark The mark after this fee
   * @return _markMoved Whether the mark moved
   * @return _newPaidSince The performance fee paid since the mark last moved, after this fee
   */
  function _performanceFee(
    uint256 _price,
    uint256 _supply,
    uint256 _mark,
    uint256 _markAge,
    uint256 _paidSince
  ) private view returns (uint256 _paid, uint256 _newMark, bool _markMoved, uint256 _newPaidSince) {
    _newMark = _mark;
    _newPaidSince = _paidSince;
    uint256 _hurdled = _mark + Math.mulDiv(_mark, HURDLE_BPS * Math.min(_markAge, _MAX_AGE), _BPS * _YEAR);
    // What the price would be had nothing been paid since the mark moved.
    uint256 _before = _price + _paidSince;
    if (_before <= _hurdled) return (0, _mark, false, _paidSince);
    (uint256 _due, bool _caughtUp) = _dueSinceTheMark(_before, _mark, _hurdled);
    if (_due <= _paidSince) return (0, _mark, false, _paidSince);
    _paid = Math.mulDiv(_due - _paidSince, _supply, _PRICE_SCALE);
    uint256 _paidPerUnit = Math.mulDiv(_paid, _PRICE_SCALE, _supply);
    // Inside a soft hurdle's catch-up the mark and its clock wait, and what is paid is carried.
    if (!_caughtUp) return (_paid, _mark, false, _paidSince + _paidPerUnit);
    // The price after what is actually paid, never below the hurdle: what is charged never exceeds what is above it. A
    // charge that rounds down stays in the price, and a mark below that would be charged on the next investor's principal.
    _newMark = _price - _paidPerUnit;
    _markMoved = true;
    _newPaidSince = 0;
  }

  /**
   * @notice The performance fee due since the mark moved, per `_PRICE_SCALE` share units
   * @dev A soft hurdle is still catching up while the rate on the whole gain exceeds what is above the hurdle: then all of
   *      that is due, and the mark waits. A hard hurdle has no catch-up
   * @param _before The price after the management fee, with what was paid since the mark moved added back
   * @param _mark The high-water mark
   * @param _hurdled The mark with the hurdle added
   * @return _due The fee due since the mark moved, in assets per `_PRICE_SCALE` share units
   * @return _caughtUp Whether the catch-up is complete, so the mark moves
   */
  function _dueSinceTheMark(
    uint256 _before,
    uint256 _mark,
    uint256 _hurdled
  ) private view returns (uint256 _due, bool _caughtUp) {
    uint256 _above = _before - _hurdled;
    if (!SOFT_HURDLE) return (Math.mulDiv(_above, PERFORMANCE_BPS, _BPS), true);
    uint256 _onTheWholeGain = Math.mulDiv(_before - _mark, PERFORMANCE_BPS, _BPS);
    _caughtUp = _onTheWholeGain <= _above;
    _due = _caughtUp ? _onTheWholeGain : _above;
  }
}
