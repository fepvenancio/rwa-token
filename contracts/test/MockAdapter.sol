// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IAdapter} from 'interfaces/IAdapter.sol';

/**
 * @title MockAdapter
 * @notice An adapter whose price, freshness, liquidity and behaviour a test sets directly
 */
contract MockAdapter is IAdapter {
  /// @inheritdoc IAdapter
  address public immutable PORTFOLIO;

  /// @inheritdoc IAdapter
  address public immutable asset;

  /// @inheritdoc IAdapter
  bool public immutable reported;

  /// @notice The risk ids it names
  bytes32[] internal _ids;

  /// @inheritdoc IAdapter
  uint256 public value;

  /// @inheritdoc IAdapter
  uint256 public liquid;

  /// @inheritdoc IAdapter
  bool public fresh = true;

  /// @notice What `allocate` keeps as a fee, in assets
  uint256 public fee;

  /// @notice How much less `deallocate` returns than asked
  uint256 public shortBy;

  /// @notice Whether `allocate` leaves its value unreadable
  bool public goesStale;

  /// @notice Whether `allocate` makes an unreadable value readable again
  bool public recovers;

  /// @notice What `deallocate` costs the position on top of what it returns
  uint256 public exitFee;

  /**
   * @notice Deploys the adapter
   * @param _portfolio The portfolio it serves
   * @param _asset The asset it takes
   * @param _reported Whether its value comes from a report
   * @param _riskIds The risk ids it names
   */
  constructor(
    address _portfolio,
    address _asset,
    bool _reported,
    bytes32[] memory _riskIds
  ) {
    PORTFOLIO = _portfolio;
    asset = _asset;
    reported = _reported;
    _ids = _riskIds;
  }

  /**
   * @notice Sets the value it reads
   * @param _value The value
   */
  function setValue(
    uint256 _value
  ) external {
    value = _value;
  }

  /**
   * @notice Sets what it can return
   * @param _liquid The liquidity
   */
  function setLiquid(
    uint256 _liquid
  ) external {
    liquid = _liquid;
  }

  /**
   * @notice Sets whether its value can be read
   * @param _fresh The freshness
   */
  function setFresh(
    bool _fresh
  ) external {
    fresh = _fresh;
  }

  /**
   * @notice Sets the fee `allocate` keeps
   * @param _fee The fee in assets
   */
  function setFee(
    uint256 _fee
  ) external {
    fee = _fee;
  }

  /**
   * @notice Makes `deallocate` return less than asked
   * @param _shortBy How much less
   */
  function setShortBy(
    uint256 _shortBy
  ) external {
    shortBy = _shortBy;
  }

  /**
   * @notice Makes `allocate` leave the value unreadable
   * @param _goesStale Whether it does
   */
  function setGoesStale(
    bool _goesStale
  ) external {
    goesStale = _goesStale;
  }

  /**
   * @notice Makes `allocate` make the value readable again
   * @param _recovers Whether it does
   */
  function setRecovers(
    bool _recovers
  ) external {
    recovers = _recovers;
  }

  /**
   * @notice Sets what `deallocate` costs the position
   * @param _exitFee The cost in assets
   */
  function setExitFee(
    uint256 _exitFee
  ) external {
    exitFee = _exitFee;
  }

  /// @inheritdoc IAdapter
  function allocate(
    uint256 _assets
  ) external {
    if (!reported) value += _assets - fee;
    if (goesStale) fresh = false;
    if (recovers) fresh = true;
  }

  /// @inheritdoc IAdapter
  function deallocate(
    uint256 _assets
  ) external {
    if (!reported) value -= _assets + exitFee > value ? value : _assets + exitFee;
    IERC20(asset).transfer(PORTFOLIO, _assets - shortBy);
  }

  /// @inheritdoc IAdapter
  function riskIds() external view returns (bytes32[] memory _riskIds) {
    _riskIds = _ids;
  }
}
