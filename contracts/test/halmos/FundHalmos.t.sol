// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IFund} from 'interfaces/IFund.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {Fund} from 'contracts/fund/Fund.sol';

/// @notice Registry stub that attests everything, so the symbolic run focuses on the fund
contract FundHalmosRegistry {
  function isAttested(
    address,
    IPolicyRegistry.AttestKind
  ) external pure returns (bool _attested) {
    _attested = true;
  }
}

/// @notice A class stub with everything `registerClass` reads: ERC-165 `IPolicyGated`, a hook, no supply
contract FundHalmosClass {
  address public immutable HOOK;

  constructor(
    address _hook
  ) {
    HOOK = _hook;
  }

  function supportsInterface(
    bytes4 _interfaceId
  ) external pure returns (bool _supported) {
    _supported = _interfaceId == 0x01ffc9a7 || _interfaceId == type(IPolicyGated).interfaceId;
  }

  function policyHook() external view returns (address _hook) {
    _hook = HOOK;
  }

  function totalSupply() external pure returns (uint256 _supply) {
    _supply = 0;
  }
}

/// @notice A hook stub whose rule list is the installed rule
contract FundHalmosHook {
  address public immutable RULE;

  constructor(
    address _rule
  ) {
    RULE = _rule;
  }

  function rules() external view returns (IComplianceRule[] memory _list) {
    _list = new IComplianceRule[](1);
    _list[0] = IComplianceRule(RULE);
  }
}

/**
 * @notice Halmos symbolic properties on the fund's shared state
 * @dev Run with `npm run test:halmos`. Hardhat compiles this file but does not run `check_` functions.
 *      Halmos discards reverting paths, so a property that must revert turns a success into `assert(false)` explicitly
 */
contract FundHalmos is Test {
  Fund internal _fund;
  address internal _rule = address(0x70);
  address internal _classA;
  address internal _classB;
  address internal _accountA = address(0xA1);
  address internal _accountB = address(0xA2);

  function setUp() public {
    _fund = new Fund(address(this), IPolicyRegistry(address(new FundHalmosRegistry())));
    _fund.setRule(_rule);
    _fund.setHolderCap(10);
    _classA = address(new FundHalmosClass(address(new FundHalmosHook(_rule))));
    _classB = address(new FundHalmosClass(address(new FundHalmosHook(_rule))));
    _fund.registerClass(_classA);
    _fund.registerClass(_classB);
  }

  /// @notice A token that is not a registered class never reaches the fund's state, whoever calls and whatever the account
  function check_unregisteredTokenNeverChangesState(
    address _token,
    address _account,
    address _caller,
    bool _isJoin
  ) public {
    vm.assume(_token != _classA && _token != _classB);
    uint256 _countBefore = _fund.holderCount();
    uint256 _maskBefore = _fund.heldClasses(_account);

    vm.prank(_caller);
    if (_isJoin) {
      try _fund.join(_token, _account) {
        assert(false);
      } catch {}
    } else {
      try _fund.leave(_token, _account) {
        assert(false);
      } catch {}
    }
    assert(_fund.holderCount() == _countBefore);
    assert(_fund.heldClasses(_account) == _maskBefore);
  }

  /// @notice Only the installed rule can join or leave, even for a registered class
  function check_onlyTheRuleWrites(
    address _caller,
    address _account,
    bool _isJoin
  ) public {
    vm.assume(_caller != _rule);
    vm.prank(_caller);
    if (_isJoin) {
      try _fund.join(_classA, _account) {
        assert(false);
      } catch {}
    } else {
      try _fund.leave(_classA, _account) {
        assert(false);
      } catch {}
    }
  }

  /// @notice After any two operations on two accounts the count is the number of non-exempt accounts that hold a class
  function check_countIsTheNumberOfNonExemptHoldersAfterTwoOperations(
    uint8 _op0,
    uint8 _who0,
    uint8 _class0,
    uint8 _op1,
    uint8 _who1,
    uint8 _class1
  ) public {
    _apply(_op0, _who0, _class0);
    _apply(_op1, _who1, _class1);
    _assertCountMatches();
  }

  /// @notice The same after any three operations on one account, which reaches sequences such as join, exempt, leave.
  ///         A second account is an investor from the start
  function check_countIsTheNumberOfNonExemptHoldersAfterThreeOperationsOnOneAccount(
    uint8 _op0,
    uint8 _class0,
    uint8 _op1,
    uint8 _class1,
    uint8 _op2,
    uint8 _class2
  ) public {
    // The other account is already an investor, so the count is above zero and a wrong decrement is visible.
    vm.prank(_rule);
    _fund.join(_classB, _accountB);
    _apply(_op0, 0, _class0);
    _apply(_op1, 0, _class1);
    _apply(_op2, 0, _class2);
    _assertCountMatches();
  }

  /// @notice A join followed by a leave of the same class restores an account's classes and the count
  function check_joinThenLeaveRestoresState(
    uint8 _op0,
    uint8 _who0,
    uint8 _class0,
    uint8 _who1,
    uint8 _class1
  ) public {
    _apply(_op0, _who0, _class0);
    address _account = _who1 % 2 == 0 ? _accountA : _accountB;
    address _token = _class1 % 2 == 0 ? _classA : _classB;
    uint256 _held = _fund.heldClasses(_account);
    uint256 _count = _fund.holderCount();
    vm.assume(_held & (_class1 % 2 == 0 ? 1 : 2) == 0);

    vm.startPrank(_rule);
    _fund.join(_token, _account);
    _fund.leave(_token, _account);
    vm.stopPrank();

    assert(_fund.heldClasses(_account) == _held);
    assert(_fund.holderCount() == _count);
  }

  function _assertCountMatches() internal view {
    uint256 _expected;
    if (_fund.heldClasses(_accountA) != 0 && !_fund.isExempt(_accountA)) ++_expected;
    if (_fund.heldClasses(_accountB) != 0 && !_fund.isExempt(_accountB)) ++_expected;
    assert(_fund.holderCount() == _expected);
  }

  /// @dev One of four operations: join, leave, exempt, unexempt. The class is read only where it matters, which keeps
  ///      the number of symbolic paths down
  function _apply(
    uint8 _op,
    uint8 _who,
    uint8 _class
  ) internal {
    address _account = _who % 2 == 0 ? _accountA : _accountB;
    uint8 _kind = _op % 4;
    if (_kind >= 2) {
      _fund.setExempt(_account, _kind == 2);
      return;
    }
    address _token = _class % 2 == 0 ? _classA : _classB;
    vm.prank(_rule);
    if (_kind == 0) _fund.join(_token, _account);
    else _fund.leave(_token, _account);
  }
}
