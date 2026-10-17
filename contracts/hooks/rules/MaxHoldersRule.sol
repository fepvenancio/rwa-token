// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IMaxHoldersRule} from 'interfaces/IMaxHoldersRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {BaseRule} from 'contracts/hooks/BaseRule.sol';

/**
 * @title MaxHoldersRule
 * @notice Per-token holder cap with a holder count maintained after every movement, as specified in `IMaxHoldersRule`
 */
contract MaxHoldersRule is BaseRule, IMaxHoldersRule {
  /// @notice The token role allowed to set the cap and seed the count (OZ DEFAULT_ADMIN_ROLE)
  bytes32 private constant _DEFAULT_ADMIN_ROLE = 0x00;

  /// @notice The cap per token; 0 when not configured
  mapping(address _token => uint256 _cap) internal _caps;

  /// @notice The tracked holder count per token
  mapping(address _token => uint256 _count) internal _counts;

  /// @notice Accounts that never count and never trigger the cap, per token
  mapping(address _token => mapping(address _account => bool _exempt)) internal _exempts;

  /**
   * @notice Restricts a function to the token's DEFAULT_ADMIN_ROLE
   * @param _token The token
   */
  modifier onlyTokenAdmin(
    address _token
  ) {
    if (!IAccessControl(_token).hasRole(_DEFAULT_ADMIN_ROLE, msg.sender)) {
      revert MaxHoldersRule_OnlyTokenAdmin(_token, msg.sender);
    }
    _;
  }

  /**
   * @inheritdoc IComplianceRule
   * @dev Uses post-transfer balances. Checked arithmetic: with a wrong count, an exit below zero reverts
   */
  function after_(
    IPolicyHook.TransferContext calldata _ctx
  ) external override(BaseRule, IComplianceRule) onlyHook(_ctx) {
    if (_ctx.amount == 0 || _ctx.from == _ctx.to) return;
    IERC20 _token = IERC20(_ctx.token);
    uint256 _count = _counts[_ctx.token];
    uint256 _newCount = _count;
    // Exact equalities are the holder definition (post-move balance == amount <=> was 0). They are read inside the
    // token's guarded _update, where only the token moves balances.
    // slither-disable-start incorrect-equality
    // View interface: compiled to STATICCALL, so the token cannot change any state (test: *_TokenCallsAreStatic).
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (_ctx.to != address(0) && !_exempts[_ctx.token][_ctx.to] && _token.balanceOf(_ctx.to) == _ctx.amount) {
      _newCount += 1;
    }
    // View interface: compiled to STATICCALL, as above.
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (_ctx.from != address(0) && !_exempts[_ctx.token][_ctx.from] && _token.balanceOf(_ctx.from) == 0) {
      _newCount -= 1;
    }
    // slither-disable-end incorrect-equality
    if (_newCount != _count) {
      _counts[_ctx.token] = _newCount;
      emit HolderCountUpdated(_ctx.token, _newCount);
    }
  }

  /// @inheritdoc IMaxHoldersRule
  function seedHolderCount(
    address _token,
    uint256 _count
  ) external onlyTokenAdmin(_token) {
    uint256 _oldCount = _counts[_token];
    _counts[_token] = _count;
    emit HolderCountSeeded(_token, _oldCount, _count);
  }

  /// @inheritdoc IMaxHoldersRule
  function setExemptHolder(
    address _token,
    address _account,
    bool _exempt
  ) external onlyTokenAdmin(_token) {
    if (_account == address(0)) revert MaxHoldersRule_ZeroAddress();
    if (_exempts[_token][_account] == _exempt) return;
    _exempts[_token][_account] = _exempt;
    emit HolderExemptionSet(_token, _account, _exempt);
    // A current holder enters or leaves the count with its exemption. Checked: a wrong count fails closed.
    // View interface: compiled to STATICCALL, so the token cannot change any state (test: *_TokenCallsAreStatic).
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (IERC20(_token).balanceOf(_account) > 0) {
      uint256 _count = _exempt ? _counts[_token] - 1 : _counts[_token] + 1;
      _counts[_token] = _count;
      emit HolderCountUpdated(_token, _count);
    }
  }

  /// @inheritdoc IMaxHoldersRule
  function setCap(
    address _token,
    uint256 _cap
  ) external onlyTokenAdmin(_token) {
    uint256 _oldCap = _caps[_token];
    _caps[_token] = _cap;
    emit CapSet(_token, _oldCap, _cap);
  }

  /**
   * @inheritdoc IComplianceRule
   * @dev Uses pre-transfer balances
   */
  function check(
    IPolicyHook.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    if (_ctx.amount == 0 || _ctx.from == _ctx.to || _ctx.to == address(0)) return Reasons.TRANSFER_OK;
    // An exempt receiver never adds a holder (e.g. an empty escrow vault at a full cap).
    if (_exempts[_ctx.token][_ctx.to]) return Reasons.TRANSFER_OK;
    IERC20 _token = IERC20(_ctx.token);
    // An existing holder never adds to the count, so a lowered cap never blocks it.
    if (_token.balanceOf(_ctx.to) > 0) return Reasons.TRANSFER_OK;
    // FORCED is exempt from the cap (it is still counted in after_).
    if (_ctx.kind == IPolicyHook.TransferKind.FORCED) return Reasons.TRANSFER_OK;
    // An exempt sender was never counted, so emptying it frees no slot. The exact equality is the definition of
    // "sender leaves" (balance == amount); see after_.
    // slither-disable-start incorrect-equality
    bool _senderLeaves =
      _ctx.from != address(0) && !_exempts[_ctx.token][_ctx.from] && _token.balanceOf(_ctx.from) == _ctx.amount;
    // slither-disable-end incorrect-equality
    uint256 _cap = _caps[_ctx.token];
    if (_cap == 0 || _counts[_ctx.token] + (_senderLeaves ? 0 : 1) > _cap) return Reasons.MAX_HOLDERS;
    _reason = Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IMaxHoldersRule
  function capOf(
    address _token
  ) external view returns (uint256 _cap) {
    _cap = _caps[_token];
  }

  /// @inheritdoc IMaxHoldersRule
  function isExemptHolder(
    address _token,
    address _account
  ) external view returns (bool _exempt) {
    _exempt = _exempts[_token][_account];
  }

  /// @inheritdoc IMaxHoldersRule
  function holderCount(
    address _token
  ) external view returns (uint256 _count) {
    _count = _counts[_token];
  }

  /// @inheritdoc IComplianceRule
  function ruleId() external pure returns (bytes32 _ruleId) {
    _ruleId = keccak256('MaxHoldersRule.v1');
  }

  /// @inheritdoc BaseRule
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(IMaxHoldersRule).interfaceId || super.supportsInterface(_interfaceId);
  }

  /// @inheritdoc BaseRule
  function wantsAfter() public pure override(BaseRule, IComplianceRule) returns (bool _wantsAfter) {
    _wantsAfter = true;
  }
}
