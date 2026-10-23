// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IFund} from 'interfaces/IFund.sol';
import {IFundHoldersRule} from 'interfaces/IFundHoldersRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {BaseRule} from 'contracts/hooks/BaseRule.sol';

/**
 * @title FundHoldersRule
 * @notice Caps the number of distinct investors across the classes of one fund, as specified in `IFundHoldersRule`
 * @dev Holds no state of its own: every read and write goes to the fund, so replacing this rule keeps the count. A
 *      replaced rule rejects every movement until the classes' hooks list the new one.
 *      `check` reads the fund once, with `admission`, and reads it again for the sender only when the cap is already
 *      full. `after_` sees post-movement balances, as `MaxHoldersRule` does
 */
contract FundHoldersRule is BaseRule, IFundHoldersRule {
  /// @inheritdoc IFundHoldersRule
  IFund public immutable FUND;

  /**
   * @notice Deploys the rule
   * @param _fund The fund whose investors the rule counts
   */
  constructor(
    IFund _fund
  ) {
    if (address(_fund) == address(0)) revert FundHoldersRule_ZeroAddress();
    FUND = _fund;
  }

  /**
   * @inheritdoc IComplianceRule
   * @dev Joins a receiver whose class balance went from zero to positive, and leaves a sender whose balance reached
   *      zero. A movement to a holder of the class, or from one who keeps a balance, writes nothing. The fund ignores
   *      the class itself and reverts for a token that is not a registered class
   */
  function after_(
    IPolicyHook.TransferContext calldata _ctx
  ) external override(BaseRule, IComplianceRule) onlyHook(_ctx) {
    if (_ctx.amount == 0 || _ctx.from == _ctx.to) return;
    IERC20 _token = IERC20(_ctx.token);
    // Exact equalities are the holder definition (post-move balance == amount <=> was 0). They are read inside the
    // token's guarded _update, where only the token moves balances.
    // slither-disable-start incorrect-equality
    // View interface: compiled to STATICCALL, so the token cannot change any state (test: *_CallsAreStatic).
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (_ctx.to != address(0) && _token.balanceOf(_ctx.to) == _ctx.amount) FUND.join(_ctx.token, _ctx.to);
    // View interface: compiled to STATICCALL, as above.
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (_ctx.from != address(0) && _token.balanceOf(_ctx.from) == 0) FUND.leave(_ctx.token, _ctx.from);
    // slither-disable-end incorrect-equality
  }

  /**
   * @inheritdoc IComplianceRule
   * @dev Uses pre-movement balances. The cheap tests come first, and the sender is read only when the cap is full
   */
  function check(
    IPolicyHook.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    (uint256 _index, uint256 _held, bool _exempt, uint256 _count, uint256 _cap, address _installed) =
      FUND.admission(_ctx.token, _ctx.to);
    // An unregistered token, or a rule the fund has replaced: reject everything, so a retired rule never says yes in a
    // pre-flight while its `after_` would be refused.
    if (_index == 0 || _installed != address(this)) return Reasons.NOT_FUND_CLASS;

    // Not a new investor: nothing to count, or the receiver is already counted or never counted. FORCED is exempt from
    // the cap and still counted in `after_`. The class itself is the 7540 escrow.
    if (
      _ctx.amount == 0 || _ctx.from == _ctx.to || _ctx.to == address(0) || _ctx.kind == IPolicyHook.TransferKind.FORCED
        || _ctx.to == _ctx.token || _exempt || _held != 0
    ) return Reasons.TRANSFER_OK;

    if (_cap == 0) return Reasons.MAX_HOLDERS;
    if (_count < _cap) return Reasons.TRANSFER_OK;
    // At the cap a new investor needs a free slot. Above a lowered cap there is none, net zero or not.
    if (_count == _cap && _senderLeavesFund(_ctx, _index)) return Reasons.TRANSFER_OK;
    _reason = Reasons.MAX_HOLDERS;
  }

  /// @inheritdoc IComplianceRule
  function ruleId() external pure returns (bytes32 _ruleId) {
    _ruleId = keccak256('FundHoldersRule.v1');
  }

  /// @inheritdoc BaseRule
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(IFundHoldersRule).interfaceId || super.supportsInterface(_interfaceId);
  }

  /// @inheritdoc BaseRule
  function wantsAfter() public pure override(BaseRule, IComplianceRule) returns (bool _wantsAfter) {
    _wantsAfter = true;
  }

  /**
   * @notice Whether the movement empties the sender's only class, so the sender stops being an investor
   * @dev False for a mint (no sender), for the class itself, for an exempt sender (never counted, so it frees no slot),
   *      and for a sender who holds another class or keeps a balance in this one
   * @param _ctx The movement context
   * @param _index The class number of the token
   * @return _leaves True if the sender leaves the fund
   */
  function _senderLeavesFund(
    IPolicyHook.TransferContext calldata _ctx,
    uint256 _index
  ) internal view returns (bool _leaves) {
    if (_ctx.from == address(0) || _ctx.from == _ctx.token) return false;
    // Only the sender's classes and exemption are needed; the index, count and cap were read for the receiver.
    // slither-disable-next-line unused-return
    (, uint256 _fromHeld, bool _fromExempt,,,) = FUND.admission(_ctx.token, _ctx.from);
    if (_fromExempt || _fromHeld != 1 << (_index - 1)) return false;
    // The exact equality is the definition of "sender leaves" (balance == amount); see after_.
    // slither-disable-next-line incorrect-equality
    _leaves = IERC20(_ctx.token).balanceOf(_ctx.from) == _ctx.amount;
  }
}
