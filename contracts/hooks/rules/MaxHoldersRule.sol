// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IMaxHoldersRule} from 'interfaces/IMaxHoldersRule.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
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
   * @notice Restricts a seed to while this rule is not in the token's rule list, so a live count is never overwritten
   * @param _token The token
   */
  modifier onlyWhileInactive(
    address _token
  ) {
    if (_isListed(_token, address(this))) revert MaxHoldersRule_RuleActive(_token);
    _;
  }

  /**
   * @inheritdoc IComplianceRule
   * @dev Reads the balances before the move from `_ctx.extra` and derives the ones after from `amount`. Checked
   *      arithmetic: with a wrong count, an exit below zero reverts
   */
  function after_(
    IPolicyHook.TransferContext calldata _ctx
  ) external override(BaseRule, IComplianceRule) onlyHook(_ctx) {
    if (_ctx.amount == 0 || _ctx.from == _ctx.to) return;
    (uint256 _fromBalance, uint256 _toBalance) = abi.decode(_ctx.extra, (uint256, uint256));
    uint256 _count = _counts[_ctx.token];
    uint256 _newCount = _count;
    // Exact equalities are the holder definition: the receiver was not a holder if its balance before the move was 0,
    // and the sender leaves if the move takes its whole balance (balance after == 0).
    // slither-disable-start incorrect-equality
    if (_ctx.to != address(0) && !_exempts[_ctx.token][_ctx.to] && _toBalance == 0) {
      _newCount += 1;
    }
    if (_ctx.from != address(0) && !_exempts[_ctx.token][_ctx.from] && _fromBalance == _ctx.amount) {
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
  ) external onlyTokenAdmin(_token) onlyWhileInactive(_token) {
    _seed(_token, _count);
  }

  /**
   * @inheritdoc IMaxHoldersRule
   * @dev Each listed account costs a cold read of its balance, and one that holds tokens also a cold read of its
   *      exemption. Measured 2026-10-22 on `IntentToken` through `GovernanceTimelock`, with `setRules` in the same batch:
   *      about 6,900 gas per account that holds tokens and 4,500 per empty entry. With no empty entries, 2,400 holders
   *      fit under the per-transaction gas cap of 16,777,216 (EIP-7825) and 2,410 did not
   */
  function seedHolderCountFromHolders(
    address _token,
    address[] calldata _holders
  ) external onlyTokenAdmin(_token) onlyWhileInactive(_token) {
    IERC20 _erc20 = IERC20(_token);
    // The sum, the count and the previous address start at zero by design.
    // slither-disable-start uninitialized-local
    uint256 _sum;
    uint256 _count;
    address _previous;
    // slither-disable-end uninitialized-local
    uint256 _length = _holders.length;
    // An unsorted list or a duplicate must revert the whole seed (fail closed).
    // aderyn-ignore-next-line(require-revert-in-loop)
    for (uint256 _i; _i < _length; ++_i) {
      address _holder = _holders[_i];
      if (_holder <= _previous) revert MaxHoldersRule_HoldersNotAscending(_i);
      _previous = _holder;
      // View interface: compiled to STATICCALL, so the token cannot change any state (test: *_TokenCallsAreStatic).
      // aderyn-ignore-next-line(reentrancy-state-change)
      uint256 _balance = _erc20.balanceOf(_holder);
      if (_balance > 0) {
        _sum += _balance;
        if (!_exempts[_token][_holder]) ++_count;
      }
    }
    // View interface: compiled to STATICCALL, as above.
    // aderyn-ignore-next-line(reentrancy-state-change)
    uint256 _supply = _erc20.totalSupply();
    if (_sum != _supply) revert MaxHoldersRule_HoldersIncomplete(_sum, _supply);
    _seed(_token, _count);
  }

  /// @inheritdoc IMaxHoldersRule
  function seedHolderCountFromRule(
    address _token,
    IMaxHoldersRule _previousRule
  ) external onlyTokenAdmin(_token) onlyWhileInactive(_token) {
    if (!_isListed(_token, address(_previousRule))) {
      revert MaxHoldersRule_PreviousRuleNotActive(_token, address(_previousRule));
    }
    _seed(_token, _previousRule.holderCount(_token));
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
    // A current holder enters or leaves a live count with its exemption. Checked: a wrong count fails closed. While
    // the rule is out of the list the count is not live, and the next seed sets it.
    // View interface: compiled to STATICCALL, so the token cannot change any state (test: *_TokenCallsAreStatic).
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (IERC20(_token).balanceOf(_account) > 0 && _isListed(_token, address(this))) {
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
   * @dev Uses the balances before the move, from `_ctx.extra`
   */
  function check(
    IPolicyHook.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    if (_ctx.amount == 0 || _ctx.from == _ctx.to || _ctx.to == address(0)) return Reasons.TRANSFER_OK;
    // An exempt receiver never adds a holder (e.g. an empty escrow vault at a full cap).
    if (_exempts[_ctx.token][_ctx.to]) return Reasons.TRANSFER_OK;
    (uint256 _fromBalance, uint256 _toBalance) = abi.decode(_ctx.extra, (uint256, uint256));
    // An existing holder never adds to the count, so a lowered cap never blocks it.
    if (_toBalance > 0) return Reasons.TRANSFER_OK;
    // FORCED is exempt from the cap (it is still counted in after_).
    if (_ctx.kind == IPolicyHook.TransferKind.FORCED) return Reasons.TRANSFER_OK;
    // An exempt sender was never counted, so emptying it frees no slot. The exact equality is the definition of
    // "sender leaves" (balance == amount); see after_.
    // slither-disable-start incorrect-equality
    bool _senderLeaves = _ctx.from != address(0) && !_exempts[_ctx.token][_ctx.from] && _fromBalance == _ctx.amount;
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

  /**
   * @notice Overwrites a token's holder count
   * @param _token The token
   * @param _count The new count
   */
  function _seed(
    address _token,
    uint256 _count
  ) internal {
    uint256 _oldCount = _counts[_token];
    _counts[_token] = _count;
    emit HolderCountSeeded(_token, _oldCount, _count);
  }

  /**
   * @notice Whether a rule is in the rule list of the token's current hook
   * @dev Reverts if the hook has no `rules(token)`
   * @param _token The token
   * @param _rule The rule
   * @return _listed True if listed
   */
  function _isListed(
    address _token,
    address _rule
  ) internal view returns (bool _listed) {
    IComplianceRule[] memory _rules = IComplianceHook(IPolicyGated(_token).policyHook()).rules(_token);
    uint256 _length = _rules.length;
    for (uint256 _i; _i < _length; ++_i) {
      if (address(_rules[_i]) == _rule) return true;
    }
  }
}
