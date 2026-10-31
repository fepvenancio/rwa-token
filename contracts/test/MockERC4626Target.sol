// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';

import {IPortfolio} from 'interfaces/IPortfolio.sol';

/**
 * @title MockERC4626Target
 * @notice An outside ERC-4626 vault a test can break, shrink, hold shut or make call back
 */
contract MockERC4626Target is ERC4626 {
  /// @notice Whether its reads revert, as in an outage
  bool public broken;

  /// @notice Whether `maxWithdraw` always says 0 while `withdraw` still works
  bool public reportsNoLiquidity;

  /// @notice A portfolio to call back into during `deposit`, or zero
  address public reenterInto;

  /// @notice The adapter named in the call back
  address public reenterAdapter;

  /// @notice A portfolio to read the price of during `deposit` and `withdraw`, or zero
  address public readsPriceOf;

  /**
   * @notice Deploys the vault
   * @param _asset The asset
   */
  constructor(
    IERC20 _asset
  ) ERC20('Mock Target', 'mTGT') ERC4626(_asset) {}

  /**
   * @notice Breaks or mends its reads
   * @param _broken Whether they revert
   */
  function setBroken(
    bool _broken
  ) external {
    broken = _broken;
  }

  /**
   * @notice Makes `maxWithdraw` read 0
   * @param _reportsNoLiquidity Whether it does
   */
  function setReportsNoLiquidity(
    bool _reportsNoLiquidity
  ) external {
    reportsNoLiquidity = _reportsNoLiquidity;
  }

  /**
   * @notice Makes `deposit` call back into a portfolio
   * @param _portfolio The portfolio, or zero for none
   * @param _adapter The adapter to name
   */
  function setReenter(
    address _portfolio,
    address _adapter
  ) external {
    reenterInto = _portfolio;
    reenterAdapter = _adapter;
  }

  /**
   * @notice Makes `deposit` and `withdraw` read a portfolio's price mid-call
   * @param _portfolio The portfolio, or zero for none
   */
  function setReadsPriceOf(
    address _portfolio
  ) external {
    readsPriceOf = _portfolio;
  }

  /**
   * @notice Loses part of what it holds
   * @param _assets The assets lost
   */
  function lose(
    uint256 _assets
  ) external {
    IERC20(asset()).transfer(address(0xdead), _assets);
  }

  /// @inheritdoc ERC4626
  function previewRedeem(
    uint256 _shares
  ) public view override returns (uint256 _assets) {
    if (broken) revert('outage');
    _assets = super.previewRedeem(_shares);
  }

  /// @inheritdoc ERC4626
  function maxWithdraw(
    address _owner
  ) public view override returns (uint256 _assets) {
    if (broken) revert('outage');
    _assets = reportsNoLiquidity ? 0 : super.maxWithdraw(_owner);
  }

  /// @inheritdoc ERC4626
  function _deposit(
    address _caller,
    address _receiver,
    uint256 _assets,
    uint256 _shares
  ) internal override {
    address _reenterInto = reenterInto;
    if (_reenterInto != address(0)) {
      // Once, so a guard that is missing shows as a call that succeeds, not as endless recursion.
      reenterInto = address(0);
      IPortfolio(_reenterInto).allocate(reenterAdapter, 1, 0);
    }
    if (readsPriceOf != address(0)) IPortfolio(readsPriceOf).pricedValue();
    super._deposit(_caller, _receiver, _assets, _shares);
  }

  /// @inheritdoc ERC4626
  function _withdraw(
    address _caller,
    address _receiver,
    address _owner,
    uint256 _assets,
    uint256 _shares
  ) internal override {
    if (readsPriceOf != address(0)) IPortfolio(readsPriceOf).pricedValue();
    super._withdraw(_caller, _receiver, _owner, _assets, _shares);
  }
}
