// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {ISettlementWindowRule} from 'interfaces/ISettlementWindowRule.sol';

import {SettlementWindowRule} from 'contracts/hooks/rules/SettlementWindowRule.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockStatefulToken} from 'contracts/test/MockStatefulToken.sol';

contract SettlementWindowRuleUnitTest is Helpers {
  bytes32 internal constant _ADMIN_ROLE = 0x00;
  /// @dev Mon 2026-10-12 00:00 UTC; verified against the calendar and the rule's weekday formula
  uint256 internal constant _MONDAY = 1_791_763_200;
  uint32 internal constant _NINE = 9 hours;
  uint32 internal constant _FIVE_PM = 17 hours;
  uint32 internal constant _TEN_PM = 22 hours;
  uint32 internal constant _TWO_AM = 2 hours;
  uint8 internal constant _MON_TO_FRI = 0x1F;

  SettlementWindowRule internal _rule;
  address internal _token;
  address internal _admin = makeAddr('timelock');
  address internal _stranger = makeAddr('stranger');

  function setUp() public virtual {
    _token = _mockContract('token');
    _role(_token, _admin, true);
    _role(_token, _stranger, false);
    _rule = new SettlementWindowRule();
  }

  function _role(
    address _forToken,
    address _account,
    bool _has
  ) internal {
    vm.mockCall(_forToken, abi.encodeCall(IAccessControl.hasRole, (_ADMIN_ROLE, _account)), abi.encode(_has));
  }

  function _window(
    uint32 _open,
    uint32 _close,
    uint8 _mask
  ) internal {
    vm.prank(_admin);
    _rule.setWindow(_token, _open, _close, _mask);
  }

  /// @dev Timestamp of day `_day` (0 = Monday of the anchor week) at `_second` of the day
  function _at(
    uint256 _day,
    uint256 _second
  ) internal pure returns (uint256 _ts) {
    _ts = _MONDAY + _day * 1 days + _second;
  }

  function _ctx(
    IPolicyHook.TransferKind _kind
  ) internal view returns (IPolicyHook.TransferContext memory _context) {
    _context = IPolicyHook.TransferContext({
      token: _token,
      from: address(0xF0),
      to: address(0x70),
      id: 0,
      amount: 1,
      operator: address(0xE0),
      kind: _kind,
      ref: bytes32('ref'),
      deadline: type(uint256).max,
      extra: ''
    });
  }

  function _executedAt(
    uint256 _ts
  ) internal returns (bytes32 _reason) {
    vm.warp(_ts);
    _reason = _rule.check(_ctx(IPolicyHook.TransferKind.EXECUTED));
  }
}

contract SettlementWindowRuleUnit_SetWindow is SettlementWindowRuleUnitTest {
  function test_WhenCallerIsNotTheTokensAdmin_ItReverts() external {
    vm.expectRevert(
      abi.encodeWithSelector(ISettlementWindowRule.SettlementWindowRule_OnlyTokenAdmin.selector, _token, _stranger)
    );
    vm.prank(_stranger);
    _rule.setWindow(_token, _NINE, _FIVE_PM, _MON_TO_FRI);
  }

  function test_WhenOpenIsNotASecondOfTheDay_ItReverts(
    uint32 _open
  ) external {
    _open = uint32(bound(_open, 1 days, type(uint32).max));
    vm.expectRevert(ISettlementWindowRule.SettlementWindowRule_InvalidWindow.selector);
    _window(_open, _FIVE_PM, _MON_TO_FRI);
  }

  function test_WhenCloseIsNotASecondOfTheDay_ItReverts(
    uint32 _close
  ) external {
    _close = uint32(bound(_close, 1 days, type(uint32).max));
    vm.expectRevert(ISettlementWindowRule.SettlementWindowRule_InvalidWindow.selector);
    _window(_NINE, _close, _MON_TO_FRI);
  }

  function test_WhenOpenEqualsClose_ItReverts(
    uint32 _second
  ) external {
    _second = uint32(bound(_second, 0, 1 days - 1));
    vm.expectRevert(ISettlementWindowRule.SettlementWindowRule_InvalidWindow.selector);
    _window(_second, _second, _MON_TO_FRI);
  }

  function test_WhenTheDayMaskIsEmpty_ItReverts() external {
    vm.expectRevert(ISettlementWindowRule.SettlementWindowRule_InvalidWindow.selector);
    _window(_NINE, _FIVE_PM, 0);
  }

  function test_WhenTheDayMaskHasAnEighthBit_ItReverts(
    uint8 _mask
  ) external {
    _mask = uint8(bound(_mask, 0x80, 0xFF));
    vm.expectRevert(ISettlementWindowRule.SettlementWindowRule_InvalidWindow.selector);
    _window(_NINE, _FIVE_PM, _mask);
  }

  function test_WhenValid_ItStoresAndEmits() external {
    vm.expectEmit(address(_rule));
    emit ISettlementWindowRule.WindowSet(_token, _TEN_PM, _TWO_AM, _MON_TO_FRI);
    _window(_TEN_PM, _TWO_AM, _MON_TO_FRI);
    ISettlementWindowRule.Window memory _w = _rule.windowOf(_token);
    assertEq(_w.open, _TEN_PM);
    assertEq(_w.close, _TWO_AM);
    assertEq(_w.dayMask, _MON_TO_FRI);
  }

  function test_WhenAFakeTokenAuthorisesAnAttacker_OnlyTheFakeTokensKeyChanges() external {
    _window(_NINE, _FIVE_PM, _MON_TO_FRI);
    address _fakeToken = _mockContract('fakeToken');
    address _attacker = makeAddr('attacker');
    _role(_fakeToken, _attacker, true);
    vm.prank(_attacker);
    _rule.setWindow(_fakeToken, 0, 1 days - 1, 0x7F);
    assertEq(_rule.windowOf(_token).open, _NINE);
    assertEq(_rule.windowOf(_token).dayMask, _MON_TO_FRI);
  }
}

contract SettlementWindowRuleUnit_Check is SettlementWindowRuleUnitTest {
  function test_WhenTheMovementIsNotExecuted_ItIsAlwaysOkEvenUnconfigured() external {
    vm.warp(_at(5, 3 hours)); // Saturday night
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER)), Reasons.TRANSFER_OK);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.FORCED)), Reasons.TRANSFER_OK);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.MINT)), Reasons.TRANSFER_OK);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.BURN)), Reasons.TRANSFER_OK);
  }

  function test_WhenUnconfigured_ExecutedFailsClosed(
    uint256 _ts
  ) external {
    _ts = bound(_ts, _MONDAY, _MONDAY + 52 weeks);
    assertEq(_executedAt(_ts), Reasons.OUTSIDE_SETTLEMENT_WINDOW);
    assertFalse(_rule.isOpen(_token, _ts));
  }

  function test_WhenSameDayWindow_ItIsOpenFromOpenInclusiveToCloseExclusive() external {
    _window(_NINE, _FIVE_PM, _MON_TO_FRI);
    assertEq(_executedAt(_at(0, _NINE - 1)), Reasons.OUTSIDE_SETTLEMENT_WINDOW);
    assertEq(_executedAt(_at(0, _NINE)), Reasons.TRANSFER_OK);
    assertEq(_executedAt(_at(0, _FIVE_PM - 1)), Reasons.TRANSFER_OK);
    assertEq(_executedAt(_at(0, _FIVE_PM)), Reasons.OUTSIDE_SETTLEMENT_WINDOW);
  }

  function test_WhenSameDayWindowOnAWeekday_InsideTimesAreOpen(
    uint256 _day,
    uint256 _second,
    uint256 _week
  ) external {
    _window(_NINE, _FIVE_PM, _MON_TO_FRI);
    _day = bound(_day, 0, 4);
    _second = bound(_second, _NINE, _FIVE_PM - 1);
    _week = bound(_week, 0, 520);
    assertEq(_executedAt(_at(_day + _week * 7, _second)), Reasons.TRANSFER_OK);
  }

  function test_WhenSameDayWindowAtTheWeekend_ItIsClosed(
    uint256 _day,
    uint256 _second,
    uint256 _week
  ) external {
    _window(_NINE, _FIVE_PM, _MON_TO_FRI);
    _day = bound(_day, 5, 6);
    _second = bound(_second, _NINE, _FIVE_PM - 1);
    _week = bound(_week, 0, 520);
    assertEq(_executedAt(_at(_day + _week * 7, _second)), Reasons.OUTSIDE_SETTLEMENT_WINDOW);
  }

  /// @dev Owner-specified cases: the overnight session belongs to the day it opened
  function test_WhenOvernightWindow_MondayOneAmIsClosedBecauseSundayIsDisabled() external {
    _window(_TEN_PM, _TWO_AM, _MON_TO_FRI);
    assertEq(_executedAt(1_791_766_800), Reasons.OUTSIDE_SETTLEMENT_WINDOW); // Mon 2026-10-12 01:00
  }

  function test_WhenOvernightWindow_SaturdayOneAmIsOpenBecauseFridayIsEnabled() external {
    _window(_TEN_PM, _TWO_AM, _MON_TO_FRI);
    assertEq(_executedAt(1_792_198_800), Reasons.TRANSFER_OK); // Sat 2026-10-17 01:00
  }

  function test_WhenOvernightWindow_TheEdgesAndTheDaytimeGapBehave() external {
    _window(_TEN_PM, _TWO_AM, _MON_TO_FRI);
    assertEq(_executedAt(_at(4, 23 hours)), Reasons.TRANSFER_OK); // Fri 23:00, opened today
    assertEq(_executedAt(_at(6, 23 hours)), Reasons.OUTSIDE_SETTLEMENT_WINDOW); // Sun 23:00
    assertEq(_executedAt(_at(0, _TEN_PM)), Reasons.TRANSFER_OK); // Mon 22:00, open is inclusive
    assertEq(_executedAt(_at(0, _TEN_PM - 1)), Reasons.OUTSIDE_SETTLEMENT_WINDOW);
    assertEq(_executedAt(_at(1, _TWO_AM - 1)), Reasons.TRANSFER_OK); // Tue 01:59:59, Monday's session
    assertEq(_executedAt(_at(1, _TWO_AM)), Reasons.OUTSIDE_SETTLEMENT_WINDOW); // close is exclusive
    assertEq(_executedAt(_at(1, 12 hours)), Reasons.OUTSIDE_SETTLEMENT_WINDOW); // daytime gap
  }

  function test_WhenQueried_IsOpenAgreesWithCheck(
    uint256 _ts,
    bool _overnight
  ) external {
    if (_overnight) _window(_TEN_PM, _TWO_AM, _MON_TO_FRI);
    else _window(_NINE, _FIVE_PM, _MON_TO_FRI);
    _ts = bound(_ts, _MONDAY, _MONDAY + 520 weeks);
    bool _open = _rule.isOpen(_token, _ts);
    assertEq(_executedAt(_ts), _open ? Reasons.TRANSFER_OK : Reasons.OUTSIDE_SETTLEMENT_WINDOW);
  }

  function test_WhenCalledWithStaticcall_ItDoesNotWrite() external {
    _window(_NINE, _FIVE_PM, _MON_TO_FRI);
    vm.warp(_at(0, 10 hours));
    (bool _ok, bytes memory _out) =
      address(_rule).staticcall(abi.encodeCall(IComplianceRule.check, (_ctx(IPolicyHook.TransferKind.EXECUTED))));
    assertTrue(_ok);
    assertEq(abi.decode(_out, (bytes32)), Reasons.TRANSFER_OK);
  }
}

contract SettlementWindowRuleUnit_Metadata is SettlementWindowRuleUnitTest {
  function test_WhenQueried_ItReturnsItsMetadata() external view {
    assertEq(_rule.ruleId(), keccak256('SettlementWindowRule.v1'));
    assertEq(_rule.MON_TO_FRI(), _MON_TO_FRI);
    assertFalse(_rule.wantsAfter());
    assertTrue(_rule.supportsInterface(type(IComplianceRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(ISettlementWindowRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(IERC165).interfaceId));
  }
}

/// @dev Aderyn `reentrancy-state-change` is a false positive: the token is read through STATICCALL
contract SettlementWindowRuleUnit_TokenCallsAreStatic is SettlementWindowRuleUnitTest {
  function test_WhenTheTokenTriesToWriteDuringTheRoleCheck_SetWindowReverts() external {
    MockStatefulToken _stateful = new MockStatefulToken();
    uint8 _days = _rule.MON_TO_FRI(); // read first: an external call would consume expectRevert and the prank
    vm.expectRevert();
    vm.prank(_admin);
    _rule.setWindow(address(_stateful), 9 hours, 17 hours, _days);
  }
}
