// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IMinPositionRule} from 'interfaces/IMinPositionRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {BaseRule} from 'contracts/hooks/BaseRule.sol';

/**
 * @title MinPositionRule
 * @notice Per-token minimum position: no account is left holding a balance above zero and below the minimum, as
 *         specified in `IMinPositionRule`
 * @dev Reads the balances before the move from `TransferContext.extra` and judges the balances after it, so it makes no
 *      call back into the token on the usual path. It holds no per-holder state and needs no `after_`
 */
contract MinPositionRule is BaseRule, IMinPositionRule {
  /// @notice The token role allowed to set the minimum and the exemptions (OZ DEFAULT_ADMIN_ROLE)
  bytes32 private constant _DEFAULT_ADMIN_ROLE = 0x00;

  /// @notice The token role whose burns are enforcement actions, exempt from the minimum
  bytes32 private constant _BURNER_ROLE = keccak256('BURNER_ROLE');

  /// @notice The minimum position per token; 0 when off
  mapping(address _token => uint256 _amount) internal _minPositions;

  /// @notice Accounts the token's admin exempted from the minimum, per token
  mapping(address _token => mapping(address _account => bool _exempt)) internal _exempts;

  /**
   * @notice Restricts a function to the token's DEFAULT_ADMIN_ROLE
   * @param _token The token
   */
  modifier onlyTokenAdmin(
    address _token
  ) {
    // View interface: compiled to STATICCALL, so the token cannot change any state (test: *_TokenCallsAreStatic).
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (!IAccessControl(_token).hasRole(_DEFAULT_ADMIN_ROLE, msg.sender)) {
      revert MinPositionRule_OnlyTokenAdmin(_token, msg.sender);
    }
    _;
  }

  /// @inheritdoc IMinPositionRule
  function setMinPosition(
    address _token,
    uint256 _amount
  ) external onlyTokenAdmin(_token) {
    uint256 _oldAmount = _minPositions[_token];
    _minPositions[_token] = _amount;
    emit MinPositionSet(_token, _oldAmount, _amount);
  }

  /// @inheritdoc IMinPositionRule
  function setExempt(
    address _token,
    address _account,
    bool _exempt
  ) external onlyTokenAdmin(_token) {
    if (_account == address(0)) revert MinPositionRule_ZeroAddress();
    _exempts[_token][_account] = _exempt;
    emit MinPositionExemptionSet(_token, _account, _exempt);
  }

  /**
   * @inheritdoc IComplianceRule
   * @dev The receiver ends with `toBalance + amount`, which is above zero, so it breaches when that is below the
   *      minimum. The sender ends with `fromBalance - amount`, which breaches when it is above zero and below the
   *      minimum. Neither sum is computed where it could overflow or underflow: a sender that holds less than the amount
   *      is the token's own balance check to refuse, before the hook is asked. The exemptions and the role are read only
   *      once a position would breach
   */
  function check(
    IPolicyHook.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    uint256 _min = _minPositions[_ctx.token];
    if (_min == 0 || _ctx.amount == 0 || _ctx.from == _ctx.to || _ctx.kind == IPolicyHook.TransferKind.FORCED) {
      return Reasons.TRANSFER_OK;
    }
    (uint256 _fromBalance, uint256 _toBalance) = abi.decode(_ctx.extra, (uint256, uint256));

    if (
      _ctx.to != address(0) && _ctx.amount < _min && _toBalance < _min - _ctx.amount && !_isExempt(_ctx.token, _ctx.to)
    ) return Reasons.BELOW_MIN_POSITION;

    if (
      _ctx.from != address(0) && _fromBalance > _ctx.amount && _fromBalance - _ctx.amount < _min
        && !_isExempt(_ctx.token, _ctx.from) && !_isEnforcementBurn(_ctx)
    ) return Reasons.BELOW_MIN_POSITION;

    _reason = Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IMinPositionRule
  function isExempt(
    address _token,
    address _account
  ) external view returns (bool _exempt) {
    _exempt = _isExempt(_token, _account);
  }

  /// @inheritdoc IMinPositionRule
  function minPosition(
    address _token
  ) external view returns (uint256 _amount) {
    _amount = _minPositions[_token];
  }

  /// @inheritdoc IComplianceRule
  function ruleId() external pure returns (bytes32 _ruleId) {
    _ruleId = keccak256('MinPositionRule.v1');
  }

  /// @inheritdoc BaseRule
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(IMinPositionRule).interfaceId || super.supportsInterface(_interfaceId);
  }

  /**
   * @notice Whether an account is exempt from the minimum on a token: the token itself, or a listed account
   * @param _token The token
   * @param _account The account
   * @return _exempt True if exempt
   */
  function _isExempt(
    address _token,
    address _account
  ) internal view returns (bool _exempt) {
    _exempt = _account == _token || _exempts[_token][_account];
  }

  /**
   * @notice Whether the movement is a burn driven by an account holding the token's BURNER_ROLE
   * @dev A holder-initiated burn (e.g. an ERC-4626 redeem) is not an enforcement action and is judged like any other
   * @param _ctx The movement context
   * @return _enforcement True for a burn by a BURNER_ROLE holder
   */
  function _isEnforcementBurn(
    IPolicyHook.TransferContext calldata _ctx
  ) internal view returns (bool _enforcement) {
    _enforcement =
      _ctx.kind == IPolicyHook.TransferKind.BURN && IAccessControl(_ctx.token).hasRole(_BURNER_ROLE, _ctx.operator);
  }
}
