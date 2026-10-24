// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {MinPositionRule} from 'contracts/hooks/rules/MinPositionRule.sol';

/// @notice Token stub whose role check always says yes, so the symbolic run focuses on the rule's arithmetic
contract HalmosAdminToken {
  function hasRole(
    bytes32,
    address
  ) external pure returns (bool _has) {
    _has = true;
  }
}

/**
 * @notice Halmos symbolic properties of `MinPositionRule`: the decision is exactly "no position is left above zero and
 *         below the minimum", and it is taken for every input without reverting
 * @dev Run with `npm run test:halmos`. Hardhat compiles this file but does not run `check_` functions. Halmos discards
 *      reverting paths, so the no-revert property turns a revert into `assert(false)` explicitly. `vm.assume` is used here
 *      as a symbolic path constraint; the Wonderland "bound, not assume" rule targets fuzzing
 */
contract MinPositionRuleHalmos is Test {
  address internal _token;
  MinPositionRule internal _rule;
  address internal _sender = address(0x1111);
  address internal _receiver = address(0x2222);

  function setUp() public {
    _token = address(new HalmosAdminToken());
    _rule = new MinPositionRule();
  }

  /// @notice A holder-driven transfer is rejected exactly when a position would be left above zero and below the minimum
  function check_aTransferIsRejectedExactlyWhenAPositionWouldBeDust(
    uint256 _min,
    uint256 _fromBalance,
    uint256 _toBalance,
    uint256 _amount
  ) public {
    vm.assume(_min > 0 && _amount > 0 && _fromBalance >= _amount && _toBalance <= type(uint256).max - _amount);
    _rule.setMinPosition(_token, _min);

    bytes32 _reason = _rule.check(_context(IPolicyHook.TransferKind.TRANSFER, _fromBalance, _toBalance, _amount));

    uint256 _fromAfter = _fromBalance - _amount;
    uint256 _toAfter = _toBalance + _amount;
    bool _breach = (_fromAfter != 0 && _fromAfter < _min) || _toAfter < _min;
    assert(_reason == (_breach ? Reasons.BELOW_MIN_POSITION : Reasons.TRANSFER_OK));
  }

  /// @notice The rule answers every input of every kind: no overflow, no underflow, no revert
  function check_theRuleNeverReverts(
    uint256 _min,
    uint256 _fromBalance,
    uint256 _toBalance,
    uint256 _amount,
    uint8 _kind
  ) public {
    vm.assume(_kind < 5);
    _rule.setMinPosition(_token, _min);

    try _rule.check(_context(IPolicyHook.TransferKind(_kind), _fromBalance, _toBalance, _amount)) returns (
      bytes32 _reason
    ) {
      assert(_reason == Reasons.TRANSFER_OK || _reason == Reasons.BELOW_MIN_POSITION);
    } catch {
      assert(false);
    }
  }

  /// @notice A forced movement is never rejected, whatever the balances
  function check_aForcedMovementIsNeverRejected(
    uint256 _min,
    uint256 _fromBalance,
    uint256 _toBalance,
    uint256 _amount
  ) public {
    _rule.setMinPosition(_token, _min);
    assert(
      _rule.check(_context(IPolicyHook.TransferKind.FORCED, _fromBalance, _toBalance, _amount)) == Reasons.TRANSFER_OK
    );
  }

  function _context(
    IPolicyHook.TransferKind _kind,
    uint256 _fromBalance,
    uint256 _toBalance,
    uint256 _amount
  ) internal view returns (IPolicyHook.TransferContext memory _ctx) {
    _ctx = IPolicyHook.TransferContext({
      token: _token,
      from: _sender,
      to: _receiver,
      id: 0,
      amount: _amount,
      operator: _sender,
      kind: _kind,
      extra: abi.encode(_fromBalance, _toBalance)
    });
  }
}
