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
    uint256 _feeAge
  ) external view returns (uint256 _fee, uint256 _newMark, bool _markMoved) {
    _newMark = _mark;
    if (_supply == 0 || _supply > _MAX_FIGURE || _gross > _MAX_FIGURE || _mark > _MAX_FIGURE) return (0, _mark, false);

    _fee = Math.mulDiv(_gross, MANAGEMENT_BPS * Math.min(_feeAge, _MAX_AGE), _BPS * _YEAR);
    uint256 _price = Math.mulDiv(_gross - _fee, _PRICE_SCALE, _supply);
    uint256 _hurdled = _mark + Math.mulDiv(_mark, HURDLE_BPS * Math.min(_markAge, _MAX_AGE), _BPS * _YEAR);
    if (_price <= _hurdled) return (_fee, _mark, false);

    uint256 _charged = _performance(_price, _mark, _hurdled);
    if (_charged == 0) return (_fee, _mark, false);
    _fee += Math.mulDiv(_charged, _supply, _PRICE_SCALE);
    // Never below the hurdle: what is charged never exceeds what is above it.
    _newMark = _price - _charged;
    _markMoved = true;
  }

  /**
   * @notice The performance fee per `_PRICE_SCALE` share units
   * @param _price The price after the management fee
   * @param _mark The high-water mark
   * @param _hurdled The mark with the hurdle added
   * @return _charged The fee in assets per `_PRICE_SCALE` share units
   */
  function _performance(
    uint256 _price,
    uint256 _mark,
    uint256 _hurdled
  ) private view returns (uint256 _charged) {
    uint256 _above = _price - _hurdled;
    if (!SOFT_HURDLE) return Math.mulDiv(_above, PERFORMANCE_BPS, _BPS);
    _charged = Math.min(Math.mulDiv(_price - _mark, PERFORMANCE_BPS, _BPS), _above);
  }
}
