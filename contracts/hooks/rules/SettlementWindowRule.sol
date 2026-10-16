// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {ISettlementWindowRule} from 'interfaces/ISettlementWindowRule.sol';

import {BaseRule} from 'contracts/hooks/BaseRule.sol';

/**
 * @title SettlementWindowRule
 * @notice Daily UTC settlement window with a weekday mask for EXECUTED movements, as specified in
 *         `ISettlementWindowRule`
 */
contract SettlementWindowRule is BaseRule, ISettlementWindowRule {
  /// @inheritdoc ISettlementWindowRule
  uint8 public constant MON_TO_FRI = 0x1F;

  /// @notice The token role allowed to set windows (OZ DEFAULT_ADMIN_ROLE)
  bytes32 private constant _DEFAULT_ADMIN_ROLE = 0x00;

  /// @notice The window per token; `dayMask == 0` when not configured
  mapping(address _token => Window _window) internal _windows;

  /// @inheritdoc ISettlementWindowRule
  function setWindow(
    address _token,
    uint32 _open,
    uint32 _close,
    uint8 _dayMask
  ) external {
    if (!IAccessControl(_token).hasRole(_DEFAULT_ADMIN_ROLE, msg.sender)) {
      revert SettlementWindowRule_OnlyTokenAdmin(_token, msg.sender);
    }
    if (_open >= 1 days || _close >= 1 days || _open == _close || _dayMask == 0 || _dayMask >= 0x80) {
      revert SettlementWindowRule_InvalidWindow();
    }
    _windows[_token] = Window({open: _open, close: _close, dayMask: _dayMask});
    emit WindowSet(_token, _open, _close, _dayMask);
  }

  /// @inheritdoc IComplianceRule
  function check(
    IPolicyHook.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    if (_ctx.kind != IPolicyHook.TransferKind.EXECUTED) return Reasons.TRANSFER_OK;
    if (!_isOpen(_windows[_ctx.token], block.timestamp)) return Reasons.OUTSIDE_SETTLEMENT_WINDOW;
    _reason = Reasons.TRANSFER_OK;
  }

  /// @inheritdoc ISettlementWindowRule
  function isOpen(
    address _token,
    uint256 _timestamp
  ) external view returns (bool _open) {
    _open = _isOpen(_windows[_token], _timestamp);
  }

  /// @inheritdoc ISettlementWindowRule
  function windowOf(
    address _token
  ) external view returns (Window memory _window) {
    _window = _windows[_token];
  }

  /// @inheritdoc IComplianceRule
  function ruleId() external pure returns (bytes32 _ruleId) {
    _ruleId = keccak256('SettlementWindowRule.v1');
  }

  /// @inheritdoc BaseRule
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(ISettlementWindowRule).interfaceId || super.supportsInterface(_interfaceId);
  }

  /**
   * @notice Whether a window is open at a timestamp
   * @dev Weekday = ((ts / 1 days) + 3) % 7 with Monday = 0; yesterday = (weekday + 6) % 7. An overnight window
   *      (`open > close`) belongs to the day it opened
   * @param _window The window
   * @param _timestamp The unix timestamp
   * @return _open True if open; false when not configured
   */
  function _isOpen(
    Window memory _window,
    uint256 _timestamp
  ) internal pure returns (bool _open) {
    if (_window.dayMask == 0) return false;
    uint256 _day = _timestamp / 1 days;
    // Calendar arithmetic on the timestamp, not randomness.
    // slither-disable-start weak-prng
    uint256 _today = (_day + 3) % 7;
    uint256 _yesterday = (_today + 6) % 7;
    uint256 _second = _timestamp % 1 days;
    // slither-disable-end weak-prng
    bool _todayEnabled = _window.dayMask & (1 << _today) != 0;
    if (_window.open < _window.close) {
      return _todayEnabled && _second >= _window.open && _second < _window.close;
    }
    bool _yesterdayEnabled = _window.dayMask & (1 << _yesterday) != 0;
    _open = (_todayEnabled && _second >= _window.open) || (_yesterdayEnabled && _second < _window.close);
  }
}
