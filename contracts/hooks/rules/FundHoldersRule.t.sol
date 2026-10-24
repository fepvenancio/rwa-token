// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import {Vm} from 'forge-std/Vm.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IFund} from 'interfaces/IFund.sol';
import {IFundHoldersRule} from 'interfaces/IFundHoldersRule.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {Fund} from 'contracts/fund/Fund.sol';
import {FundHoldersRule} from 'contracts/hooks/rules/FundHoldersRule.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockStatefulFund} from 'contracts/test/MockStatefulFund.sol';
import {MockStatefulToken} from 'contracts/test/MockStatefulToken.sol';

contract FundHoldersRuleUnitTest is Helpers {
  /// @dev The class number of `_token` in these tests, so its bit in a class mask is `_BIT`
  uint256 internal constant _INDEX = 2;
  uint256 internal constant _BIT = 2;
  uint256 internal constant _OTHER_BIT = 1;

  FundHoldersRule internal _rule;
  address internal _fund;
  address internal _token;
  address internal _hook = makeAddr('hook');
  address internal _from = makeAddr('from');
  address internal _to = makeAddr('to');
  address internal _stranger = makeAddr('stranger');

  function setUp() public virtual {
    _fund = _mockContract('fund');
    _token = _mockContract('token');
    vm.etch(_hook, hex'01');
    vm.mockCall(_token, abi.encodeCall(IPolicyGated.policyHook, ()), abi.encode(_hook));
    _rule = new FundHoldersRule(IFund(_fund));
  }

  /// @dev What the fund reports for `_token` and an account
  function _admit(
    address _account,
    uint256 _held,
    bool _exempt,
    uint256 _count,
    uint256 _cap
  ) internal {
    vm.mockCall(
      _fund,
      abi.encodeCall(IFund.admission, (_token, _account)),
      abi.encode(_INDEX, _held, _exempt, _count, _cap, address(_rule))
    );
  }

  /// @dev A receiver that is a new investor in a fund holding `_count` of `_cap`
  function _newReceiver(
    uint256 _count,
    uint256 _cap
  ) internal {
    _admit(_to, 0, false, _count, _cap);
  }

  /// @dev The balance an account holds before the movement, which the token puts in `extra`
  mapping(address _account => uint256 _amount) internal _pre;

  function _bal(
    address _account,
    uint256 _amount
  ) internal {
    _pre[_account] = _amount;
  }

  function _ctx(
    IPolicyHook.TransferKind _kind,
    address _sender,
    address _receiver,
    uint256 _amount
  ) internal view returns (IPolicyHook.TransferContext memory _context) {
    _context = IPolicyHook.TransferContext({
      token: _token,
      from: _sender,
      to: _receiver,
      id: 0,
      amount: _amount,
      operator: _sender,
      kind: _kind,
      extra: abi.encode(_pre[_sender], _pre[_receiver])
    });
  }

  function _check(
    IPolicyHook.TransferKind _kind,
    address _sender,
    address _receiver,
    uint256 _amount
  ) internal view returns (bytes32 _reason) {
    _reason = _rule.check(_ctx(_kind, _sender, _receiver, _amount));
  }

  function _after(
    IPolicyHook.TransferContext memory _context
  ) internal {
    vm.prank(_hook);
    _rule.after_(_context);
  }

  /// @dev Maps a fuzzed seed onto the movement kinds that can add an investor: not FORCED
  function _capped(
    uint8 _seedValue
  ) internal pure returns (IPolicyHook.TransferKind _kind) {
    uint256 _pick = bound(_seedValue, 0, 3);
    if (_pick == 0) return IPolicyHook.TransferKind.TRANSFER;
    if (_pick == 1) return IPolicyHook.TransferKind.EXECUTED;
    if (_pick == 2) return IPolicyHook.TransferKind.MINT;
    return IPolicyHook.TransferKind.BURN;
  }
}

contract FundHoldersRuleUnit_Metadata is FundHoldersRuleUnitTest {
  function test_WhenTheFundIsZero_Reverts() external {
    vm.expectRevert(IFundHoldersRule.FundHoldersRule_ZeroAddress.selector);
    new FundHoldersRule(IFund(address(0)));
  }

  function test_WhenDeployed_ItNamesTheFundAndAsksForAfter() external view {
    assertEq(address(_rule.FUND()), _fund);
    assertEq(_rule.ruleId(), keccak256('FundHoldersRule.v1'));
    assertTrue(_rule.wantsAfter());
  }

  function test_WhenAskedForInterfaces_RuleAndErc165AreSupported() external view {
    assertTrue(_rule.supportsInterface(type(IFundHoldersRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(IComplianceRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(IERC165).interfaceId));
    assertFalse(_rule.supportsInterface(bytes4(0xffffffff)));
  }
}

contract FundHoldersRuleUnit_Check is FundHoldersRuleUnitTest {
  function testFuzz_WhenTheTokenIsNotAClass_EveryMovementIsRejected(
    uint8 _kindSeed,
    uint256 _amount,
    bool _burn
  ) external {
    IPolicyHook.TransferKind _kind = IPolicyHook.TransferKind(bound(_kindSeed, 0, 4));
    address _receiver = _burn ? address(0) : _to;
    vm.mockCall(
      _fund, abi.encodeCall(IFund.admission, (_token, _receiver)), abi.encode(0, 0, false, 0, 5, address(_rule))
    );
    assertEq(_check(_kind, _from, _receiver, _amount), Reasons.NOT_FUND_CLASS);
  }

  function test_WhenTheTokenIsNotAClass_AZeroAmountIsStillRejectedSoAProbeFailsClosed() external {
    vm.mockCall(_fund, abi.encodeCall(IFund.admission, (_token, _to)), abi.encode(0, 0, false, 0, 5, address(_rule)));
    assertEq(_check(IPolicyHook.TransferKind.MINT, address(0), _to, 0), Reasons.NOT_FUND_CLASS);
  }

  function testFuzz_WhenTheRuleIsNotTheFundsInstalledOne_EveryMovementIsRejected(
    uint8 _kindSeed,
    uint256 _amount,
    bool _burn,
    address _installed
  ) external {
    vm.assume(_installed != address(_rule));
    IPolicyHook.TransferKind _kind = IPolicyHook.TransferKind(bound(_kindSeed, 0, 4));
    address _receiver = _burn ? address(0) : _to;
    // A registered class, an uncapped fund and a receiver who already holds a class: only the retired rule is wrong.
    vm.mockCall(
      _fund,
      abi.encodeCall(IFund.admission, (_token, _receiver)),
      abi.encode(_INDEX, _OTHER_BIT, false, 0, 5, _installed)
    );
    assertEq(_check(_kind, _from, _receiver, _amount), Reasons.NOT_FUND_CLASS);
  }

  function test_WhenTheRuleIsNotTheFundsInstalledOne_AZeroAmountProbeIsRejectedToo() external {
    vm.mockCall(
      _fund, abi.encodeCall(IFund.admission, (_token, _to)), abi.encode(_INDEX, 0, false, 0, 5, makeAddr('newRule'))
    );
    assertEq(_check(IPolicyHook.TransferKind.MINT, address(0), _to, 0), Reasons.NOT_FUND_CLASS);
  }

  function test_WhenTheAmountIsZero_ItIsOkEvenAtAFullCap() external {
    _newReceiver(3, 3);
    assertEq(_check(IPolicyHook.TransferKind.TRANSFER, _from, _to, 0), Reasons.TRANSFER_OK);
  }

  function test_WhenTheTransferIsToSelf_ItIsOkEvenAtAFullCap() external {
    _admit(_to, 0, false, 3, 3);
    assertEq(_check(IPolicyHook.TransferKind.TRANSFER, _to, _to, 1), Reasons.TRANSFER_OK);
  }

  function test_WhenTheMovementIsABurn_ItIsOkEvenAtAFullCap() external {
    _admit(address(0), 0, false, 3, 3);
    assertEq(_check(IPolicyHook.TransferKind.BURN, _from, address(0), 1), Reasons.TRANSFER_OK);
  }

  function test_WhenTheMovementIsForced_ItIsOkAtAFullCapAndAtCapZero() external {
    _newReceiver(3, 3);
    assertEq(_check(IPolicyHook.TransferKind.FORCED, _from, _to, 1), Reasons.TRANSFER_OK);
    _newReceiver(0, 0);
    assertEq(_check(IPolicyHook.TransferKind.FORCED, _from, _to, 1), Reasons.TRANSFER_OK);
    _newReceiver(9, 3);
    assertEq(_check(IPolicyHook.TransferKind.FORCED, address(0), _to, 1), Reasons.TRANSFER_OK);
  }

  function test_WhenTheReceiverIsTheClassItself_ItIsOkAtAFullCap() external {
    vm.mockCall(
      _fund, abi.encodeCall(IFund.admission, (_token, _token)), abi.encode(_INDEX, 0, false, 3, 3, address(_rule))
    );
    assertEq(_check(IPolicyHook.TransferKind.TRANSFER, _from, _token, 1), Reasons.TRANSFER_OK);
  }

  function test_WhenTheReceiverIsExempt_ItIsOkAtAFullCap() external {
    _admit(_to, 0, true, 3, 3);
    assertEq(_check(IPolicyHook.TransferKind.TRANSFER, _from, _to, 1), Reasons.TRANSFER_OK);
  }

  function test_WhenTheReceiverAlreadyHoldsAnotherClass_ItIsOkAtAFullCap() external {
    _admit(_to, _OTHER_BIT, false, 3, 3);
    assertEq(_check(IPolicyHook.TransferKind.TRANSFER, _from, _to, 1), Reasons.TRANSFER_OK);
  }

  function test_WhenTheReceiverAlreadyHoldsThisClass_ItIsOkAtAFullCap() external {
    _admit(_to, _BIT, false, 3, 3);
    assertEq(_check(IPolicyHook.TransferKind.TRANSFER, _from, _to, 1), Reasons.TRANSFER_OK);
  }

  function test_WhenTheCapIsZero_ANewInvestorIsRejected() external {
    _newReceiver(0, 0);
    assertEq(_check(IPolicyHook.TransferKind.TRANSFER, _from, _to, 1), Reasons.MAX_HOLDERS);
  }

  function testFuzz_WhenTheCountIsBelowTheCap_ANewInvestorIsAdmitted(
    uint8 _kindSeed,
    uint256 _cap,
    uint256 _count
  ) external {
    _cap = bound(_cap, 1, type(uint128).max);
    _count = bound(_count, 0, _cap - 1);
    _newReceiver(_count, _cap);
    IPolicyHook.TransferKind _kind = _capped(_kindSeed);
    if (_kind == IPolicyHook.TransferKind.BURN) return;
    address _sender = _kind == IPolicyHook.TransferKind.MINT ? address(0) : _from;
    assertEq(_check(_kind, _sender, _to, 1), Reasons.TRANSFER_OK);
  }

  function testFuzz_WhenTheCountIsAtOrAboveTheCap_ANewInvestorIsRejected(
    uint8 _kindSeed,
    uint256 _cap,
    uint256 _excess
  ) external {
    _cap = bound(_cap, 1, type(uint128).max - 1);
    _excess = bound(_excess, 0, type(uint128).max - _cap);
    _newReceiver(_cap + _excess, _cap);
    IPolicyHook.TransferKind _kind = _capped(_kindSeed);
    if (_kind == IPolicyHook.TransferKind.BURN) return;
    // A sender that keeps a balance never frees a slot; mints have no sender.
    address _sender = _kind == IPolicyHook.TransferKind.MINT ? address(0) : _from;
    _admit(_from, _BIT, false, _cap + _excess, _cap);
    _bal(_from, 10);
    assertEq(_check(_kind, _sender, _to, 1), Reasons.MAX_HOLDERS);
  }

  function test_WhenTheSenderLeavesTheFundAtAFullCap_TheMoveIsNetZeroAndAdmitted() external {
    _newReceiver(3, 3);
    _admit(_from, _BIT, false, 3, 3);
    _bal(_from, 10);
    assertEq(_check(IPolicyHook.TransferKind.TRANSFER, _from, _to, 10), Reasons.TRANSFER_OK);
    assertEq(_check(IPolicyHook.TransferKind.EXECUTED, _from, _to, 10), Reasons.TRANSFER_OK);
  }

  function test_WhenTheSenderKeepsAnotherClass_TheNetZeroMoveIsRejectedAtAFullCap() external {
    _newReceiver(3, 3);
    _admit(_from, _BIT | _OTHER_BIT, false, 3, 3);
    _bal(_from, 10);
    assertEq(_check(IPolicyHook.TransferKind.TRANSFER, _from, _to, 10), Reasons.MAX_HOLDERS);
  }

  function test_WhenTheSenderKeepsABalanceInThisClass_TheMoveIsRejectedAtAFullCap() external {
    _newReceiver(3, 3);
    _admit(_from, _BIT, false, 3, 3);
    _bal(_from, 11);
    assertEq(_check(IPolicyHook.TransferKind.TRANSFER, _from, _to, 10), Reasons.MAX_HOLDERS);
  }

  function test_WhenTheSenderIsExempt_EmptyingItFreesNoSlot() external {
    _newReceiver(3, 3);
    _admit(_from, _BIT, true, 3, 3);
    _bal(_from, 10);
    assertEq(_check(IPolicyHook.TransferKind.TRANSFER, _from, _to, 10), Reasons.MAX_HOLDERS);
  }

  function test_WhenTheSenderIsTheClassItself_EmptyingItFreesNoSlot() external {
    _newReceiver(3, 3);
    vm.mockCall(
      _fund, abi.encodeCall(IFund.admission, (_token, _token)), abi.encode(_INDEX, _BIT, false, 3, 3, address(_rule))
    );
    _bal(_token, 10);
    assertEq(_check(IPolicyHook.TransferKind.TRANSFER, _token, _to, 10), Reasons.MAX_HOLDERS);
  }

  function test_WhenTheMovementIsAMintAtAFullCap_TheNewInvestorIsRejected() external {
    _newReceiver(3, 3);
    assertEq(_check(IPolicyHook.TransferKind.MINT, address(0), _to, 1), Reasons.MAX_HOLDERS);
  }

  function test_WhenTheCountIsAboveALoweredCap_ANetZeroMoveIsStillRejected() external {
    _newReceiver(4, 3);
    _admit(_from, _BIT, false, 4, 3);
    _bal(_from, 10);
    assertEq(_check(IPolicyHook.TransferKind.TRANSFER, _from, _to, 10), Reasons.MAX_HOLDERS);
  }

  function test_WhenTheCountIsBelowTheCap_TheSenderIsNotConsulted() external {
    _newReceiver(2, 3);
    vm.expectCall(_fund, abi.encodeCall(IFund.admission, (_token, _from)), 0);
    vm.expectCall(_token, abi.encodeCall(IERC20.balanceOf, (_from)), 0);
    assertEq(_check(IPolicyHook.TransferKind.TRANSFER, _from, _to, 10), Reasons.TRANSFER_OK);
  }

  function test_WhenTheReceiverIsDecided_TheFundIsReadOnce() external {
    _newReceiver(1, 3);
    vm.expectCall(_fund, abi.encodeCall(IFund.admission, (_token, _to)), 1);
    _check(IPolicyHook.TransferKind.TRANSFER, _from, _to, 1);
  }
}

contract FundHoldersRuleUnit_After is FundHoldersRuleUnitTest {
  function _expectJoin(
    address _account,
    uint64 _times
  ) internal {
    vm.mockCall(_fund, abi.encodeCall(IFund.join, (_token, _account)), '');
    vm.expectCall(_fund, abi.encodeCall(IFund.join, (_token, _account)), _times);
  }

  function _expectLeave(
    address _account,
    uint64 _times
  ) internal {
    vm.mockCall(_fund, abi.encodeCall(IFund.leave, (_token, _account)), '');
    vm.expectCall(_fund, abi.encodeCall(IFund.leave, (_token, _account)), _times);
  }

  function test_WhenCallerIsNotTheTokensHook_Reverts() external {
    vm.expectRevert(abi.encodeWithSelector(IComplianceRule.ComplianceRule_OnlyHook.selector, _stranger));
    vm.prank(_stranger);
    _rule.after_(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 1));
  }

  function test_WhenAMintGivesTheReceiverItsFirstBalance_ItJoins() external {
    _bal(_to, 0);
    _expectJoin(_to, 1);
    _after(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 5));
  }

  function test_WhenAMintAddsToAnExistingBalance_NothingIsRecorded() external {
    _bal(_to, 4);
    _expectJoin(_to, 0);
    _after(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 5));
  }

  function test_WhenABurnEmptiesTheSender_ItLeaves() external {
    _bal(_from, 5);
    _expectLeave(_from, 1);
    _after(_ctx(IPolicyHook.TransferKind.BURN, _from, address(0), 5));
  }

  function test_WhenABurnLeavesABalance_NothingIsRecorded() external {
    _bal(_from, 6);
    _expectLeave(_from, 0);
    _after(_ctx(IPolicyHook.TransferKind.BURN, _from, address(0), 5));
  }

  function test_WhenATransferMovesAWholeBalanceToANewHolder_BothSidesAreRecorded() external {
    _bal(_to, 0);
    _bal(_from, 5);
    _expectJoin(_to, 1);
    _expectLeave(_from, 1);
    _after(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, 5));
  }

  function test_WhenATransferIsBetweenExistingHoldersWhoStayHolders_NothingIsRecorded() external {
    _bal(_to, 3);
    _bal(_from, 8);
    _expectJoin(_to, 0);
    _expectLeave(_from, 0);
    _after(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, 5));
  }

  function test_WhenTheAmountIsZero_NothingIsReadOrRecorded() external {
    _expectJoin(_to, 0);
    _expectLeave(_from, 0);
    vm.expectCall(_token, abi.encodeCall(IERC20.balanceOf, (_to)), 0);
    vm.expectCall(_token, abi.encodeCall(IERC20.balanceOf, (_from)), 0);
    _after(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, 0));
  }

  function test_WhenTheTransferIsToSelf_NothingIsReadOrRecorded() external {
    _expectJoin(_to, 0);
    _expectLeave(_to, 0);
    vm.expectCall(_token, abi.encodeCall(IERC20.balanceOf, (_to)), 0);
    _after(_ctx(IPolicyHook.TransferKind.TRANSFER, _to, _to, 5));
  }

  function test_WhenTheReceiverIsTheClassItself_TheFundIsStillToldAndIgnoresIt() external {
    _bal(_token, 0);
    _bal(_from, 6);
    vm.mockCall(_fund, abi.encodeCall(IFund.join, (_token, _token)), '');
    vm.expectCall(_fund, abi.encodeCall(IFund.join, (_token, _token)), 1);
    _after(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _token, 5));
  }

  function test_WhenTheFundRejectsTheToken_TheMovementReverts() external {
    _bal(_to, 0);
    vm.mockCallRevert(
      _fund, abi.encodeCall(IFund.join, (_token, _to)), abi.encodeWithSelector(IFund.Fund_NotAClass.selector, _token)
    );
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_NotAClass.selector, _token));
    _after(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 5));
  }
}

/// @notice A class token whose `balanceOf` writes. Its `policyHook` does not, so `onlyHook` passes; the rule reads the
///         balances from the context, so `balanceOf` must never be reached
contract FundHoldersRuleStatefulBalanceToken {
  address public immutable HOOK;
  uint256 public writes;

  constructor(
    address _hook
  ) {
    HOOK = _hook;
  }

  function policyHook() external view returns (address _hook) {
    _hook = HOOK;
  }

  function balanceOf(
    address
  ) external returns (uint256 _balance) {
    ++writes;
    _balance = 10;
  }
}

/// @notice A fund at a full cap whose `admission` writes only when asked about `SENDER`, so the receiver read passes and
///         the sender read is the one under test. The class is number 1 and the sender holds only it
contract FundHoldersRuleFundWritingOnSender {
  address public immutable SENDER;
  bool public immutable WRITES;
  uint256 public writes;

  constructor(
    address _sender,
    bool _writes
  ) {
    SENDER = _sender;
    WRITES = _writes;
  }

  function admission(
    address,
    address _account
  ) external returns (uint256 _index, uint256 _held, bool _exempt, uint256 _count, uint256 _cap, address _rule) {
    if (_account == SENDER && WRITES) ++writes;
    (_index, _held, _exempt, _count, _cap, _rule) = (1, _account == SENDER ? 1 : 0, false, 1, 1, msg.sender);
  }
}

contract FundHoldersRuleUnit_TokenAndFundCallsAreStatic is FundHoldersRuleUnitTest {
  function test_WhenTheFundTriesToWriteDuringCheck_CheckReverts() external {
    MockStatefulFund _stateful = new MockStatefulFund();
    FundHoldersRule _statefulRule = new FundHoldersRule(IFund(address(_stateful)));
    vm.expectRevert(bytes('')); // a write inside a STATICCALL reverts with empty data, bubbled by the rule
    _statefulRule.check(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, 1));
  }

  function test_WhenTheFundTriesToWriteDuringTheSenderRead_CheckReverts() external {
    // Control: the same path with a fund that does not write reaches the net-zero test and decides.
    FundHoldersRuleFundWritingOnSender _quiet = new FundHoldersRuleFundWritingOnSender(_from, false);
    FundHoldersRule _quietRule = new FundHoldersRule(IFund(address(_quiet)));
    _bal(_from, 10);
    assertEq(
      _quietRule.check(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, 10)),
      Reasons.TRANSFER_OK,
      'control: net zero'
    );

    FundHoldersRuleFundWritingOnSender _writing = new FundHoldersRuleFundWritingOnSender(_from, true);
    FundHoldersRule _writingRule = new FundHoldersRule(IFund(address(_writing)));
    vm.expectRevert(bytes('')); // a write inside a STATICCALL reverts with empty data, bubbled by the rule
    _writingRule.check(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, 10));
  }

  /// @dev The balances come in the context, so the rule never calls `balanceOf`; a token that writes there is not reached
  function test_WhenTheTokenWouldWriteOnABalanceRead_CheckNeverReadsIt() external {
    FundHoldersRuleFundWritingOnSender _quiet = new FundHoldersRuleFundWritingOnSender(_from, false);
    FundHoldersRule _quietRule = new FundHoldersRule(IFund(address(_quiet)));
    FundHoldersRuleStatefulBalanceToken _stateful = new FundHoldersRuleStatefulBalanceToken(_hook);
    _bal(_from, 10);
    IPolicyHook.TransferContext memory _context = _ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, 10);
    _context.token = address(_stateful);
    assertEq(_quietRule.check(_context), Reasons.TRANSFER_OK, 'net zero, decided from the context');
    assertEq(_stateful.writes(), 0);
  }

  function test_WhenTheTokenWouldWriteOnABalanceRead_AfterNeverReadsIt() external {
    // The token passes `onlyHook` (its `policyHook` does not write); `balanceOf` is never called.
    FundHoldersRuleStatefulBalanceToken _stateful = new FundHoldersRuleStatefulBalanceToken(_hook);
    _bal(_to, 0);
    IPolicyHook.TransferContext memory _context = _ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 10);
    _context.token = address(_stateful);
    vm.mockCall(_fund, abi.encodeCall(IFund.join, (address(_stateful), _to)), '');
    vm.expectCall(_fund, abi.encodeCall(IFund.join, (address(_stateful), _to)), 1);
    vm.prank(_hook);
    _rule.after_(_context);
    assertEq(_stateful.writes(), 0);
  }

  function test_WhenTheTokenTriesToWriteDuringTheHookLookup_AfterReverts() external {
    MockStatefulToken _stateful = new MockStatefulToken();
    IPolicyHook.TransferContext memory _context = _ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 1);
    _context.token = address(_stateful);
    vm.expectRevert(bytes('')); // a write inside a STATICCALL reverts with empty data, bubbled by the rule
    _rule.after_(_context);
  }
}

contract FundHoldersRuleUnit_Fuzz is FundHoldersRuleUnitTest {
  /// @dev `check` is a policy decision: whatever the fund reports, it returns a reason and never reverts
  function testFuzz_WhenTheFundReportsAnything_CheckReturnsAReasonAndDoesNotRevert(
    uint8 _kindSeed,
    uint256 _index,
    uint256 _held,
    bool _exempt,
    uint128 _count,
    uint128 _cap,
    address _installed,
    uint256 _amount,
    uint256 _senderBalance
  ) external {
    IPolicyHook.TransferKind _kind = IPolicyHook.TransferKind(bound(_kindSeed, 0, 4));
    vm.mockCall(
      _fund,
      abi.encodeCall(IFund.admission, (_token, _to)),
      abi.encode(_index, _held, _exempt, _count, _cap, _installed)
    );
    vm.mockCall(
      _fund,
      abi.encodeCall(IFund.admission, (_token, _from)),
      abi.encode(_index, _held, _exempt, _count, _cap, _installed)
    );
    _bal(_from, _senderBalance);

    bytes32 _reason = _check(_kind, _from, _to, _amount);
    bool _known = _reason == Reasons.TRANSFER_OK || _reason == Reasons.MAX_HOLDERS || _reason == Reasons.NOT_FUND_CLASS;
    assertTrue(_known);
    // An unregistered token or a retired rule is the only source of NOT_FUND_CLASS.
    assertEq(_reason == Reasons.NOT_FUND_CLASS, _index == 0 || _installed != address(_rule));
  }
}

/**
 * @notice The registration gate with the real `Fund` and the real rule: a token that only names itself must not reach
 *         the fund's shared state
 */
contract FundHoldersRuleGate is Helpers {
  Fund internal _fund;
  FundHoldersRule internal _rule;
  address internal _realClass;
  address internal _realHook;
  address internal _fake;
  address internal _attacker = makeAddr('attacker');
  address internal _alice = makeAddr('alice');
  address internal _registry;

  function setUp() public {
    _registry = _mockContract('registry');
    _fund = new Fund(address(this), IPolicyRegistry(_registry));
    _rule = new FundHoldersRule(_fund);
    vm.mockCall(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (address(_rule), IPolicyRegistry.AttestKind.RULE)),
      abi.encode(true)
    );
    _fund.setRule(address(_rule));
    _fund.setHolderCap(5);

    // One real, registered class, mocked only where registration reads it.
    _realClass = _mockContract('realClass');
    _realHook = _mockContract('realHook');
    vm.mockCall(_realClass, abi.encodeCall(IERC165.supportsInterface, (type(IERC165).interfaceId)), abi.encode(true));
    vm.mockCall(_realClass, abi.encodeCall(IERC165.supportsInterface, (bytes4(0xffffffff))), abi.encode(false));
    vm.mockCall(
      _realClass, abi.encodeCall(IERC165.supportsInterface, (type(IPolicyGated).interfaceId)), abi.encode(true)
    );
    vm.mockCall(_realClass, abi.encodeCall(IPolicyGated.policyHook, ()), abi.encode(_realHook));
    vm.mockCall(_realClass, abi.encodeCall(IERC20.totalSupply, ()), abi.encode(0));
    IComplianceRule[] memory _list = new IComplianceRule[](1);
    _list[0] = _rule;
    vm.mockCall(_realHook, abi.encodeWithSelector(IComplianceHook.rules.selector), abi.encode(_list));
    _fund.registerClass(_realClass);

    // A token nobody registered, whose "hook" is the attacker.
    _fake = _mockContract('fake');
    vm.mockCall(_fake, abi.encodeCall(IPolicyGated.policyHook, ()), abi.encode(_attacker));
  }

  function _ctx(
    address _token,
    address _receiver
  ) internal view returns (IPolicyHook.TransferContext memory _context) {
    _context = IPolicyHook.TransferContext({
      token: _token,
      from: address(0),
      to: _receiver,
      id: 0,
      amount: 7,
      operator: _attacker,
      kind: IPolicyHook.TransferKind.MINT,
      extra: abi.encode(uint256(0), uint256(0))
    });
  }

  function test_WhenAFakeTokenNamesItselfAndItsHook_TheFundRejectsItAndNothingChanges() external {
    vm.recordLogs();
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_NotAClass.selector, _fake));
    vm.prank(_attacker);
    _rule.after_(_ctx(_fake, _alice));

    assertEq(vm.getRecordedLogs().length, 0);
    assertEq(_fund.holderCount(), 0);
    assertEq(_fund.heldClasses(_alice), 0);
  }

  function test_WhenAnAttackerNamesTheRealClass_TheHookCheckStopsIt() external {
    vm.expectRevert(abi.encodeWithSelector(IComplianceRule.ComplianceRule_OnlyHook.selector, _attacker));
    vm.prank(_attacker);
    _rule.after_(_ctx(_realClass, _alice));
    assertEq(_fund.holderCount(), 0);
  }

  function test_WhenAnyoneButTheRuleCallsTheFund_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_OnlyRule.selector, _attacker));
    vm.prank(_attacker);
    _fund.join(_realClass, _alice);

    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_OnlyRule.selector, _realHook));
    vm.prank(_realHook);
    _fund.join(_realClass, _alice);

    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_OnlyRule.selector, _realClass));
    vm.prank(_realClass);
    _fund.leave(_realClass, _alice);
    assertEq(_fund.holderCount(), 0);
  }

  function test_WhenTheRealHookReportsAMovementOfTheRealClass_TheFundRecordsIt() external {
    vm.prank(_realHook);
    _rule.after_(_ctx(_realClass, _alice));
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.heldClasses(_alice), 1);
  }

  function test_WhenAFakeTokenIsChecked_TheRuleRejectsItWithoutTouchingState() external {
    assertEq(_rule.check(_ctx(_fake, _alice)), Reasons.NOT_FUND_CLASS);
    assertEq(_fund.holderCount(), 0);
  }
}

/// @notice The account-level answers behind `canSend`, `canReceive` and the vaults' `max*`. A class that is not the
///         fund's, or a rule the fund has replaced, rejects every movement, so no account may send or receive. The cap
///         is about who may become an investor, which does not depend on the amount: an account that is not yet an
///         investor cannot receive while the fund is full, as a mint to it would be refused
contract FundHoldersRuleUnit_AccountChecks is FundHoldersRuleUnitTest {
  function test_WhenTheTokenIsARegisteredClassWithThisRule_BothAccept() external {
    _admit(_to, 0, false, 2, 3);
    assertEq(_rule.checkSend(_token, _to), Reasons.TRANSFER_OK);
    assertEq(_rule.checkReceive(_token, _to), Reasons.TRANSFER_OK);
  }

  function test_WhenTheFundIsFull_ANewInvestorCannotReceiveButAnySenderCanSend() external {
    _admit(_to, 0, false, 3, 3);
    assertEq(_rule.checkReceive(_token, _to), Reasons.MAX_HOLDERS);
    assertEq(_rule.checkSend(_token, _to), Reasons.TRANSFER_OK);
  }

  function test_WhenTheFundIsAboveALoweredCap_ANewInvestorCannotReceive() external {
    _admit(_to, 0, false, 5, 3);
    assertEq(_rule.checkReceive(_token, _to), Reasons.MAX_HOLDERS);
  }

  function test_WhenTheFundHasRoom_ANewInvestorCanReceive() external {
    _admit(_to, 0, false, 2, 3);
    assertEq(_rule.checkReceive(_token, _to), Reasons.TRANSFER_OK);
  }

  function test_WhenTheCapIsZero_ANewInvestorCannotReceive() external {
    _admit(_to, 0, false, 0, 0);
    assertEq(_rule.checkReceive(_token, _to), Reasons.MAX_HOLDERS);
  }

  /// @dev Who is not a new investor is never capped: an investor in any class, an exempt account, the class itself
  function test_WhenTheFundIsFull_AnExistingInvestorAnExemptAccountAndTheClassCanReceive() external {
    _admit(_to, _OTHER_BIT, false, 3, 3);
    assertEq(_rule.checkReceive(_token, _to), Reasons.TRANSFER_OK);
    _admit(_to, _BIT, false, 3, 3);
    assertEq(_rule.checkReceive(_token, _to), Reasons.TRANSFER_OK);
    _admit(_to, 0, true, 3, 3);
    assertEq(_rule.checkReceive(_token, _to), Reasons.TRANSFER_OK);
    _admit(_token, 0, false, 3, 3);
    assertEq(_rule.checkReceive(_token, _token), Reasons.TRANSFER_OK);
  }

  /// @dev The account answer is the decision `check` takes for a mint, which adds no sender and so frees no slot
  function testFuzz_ForAMint_CheckReceiveAgreesWithCheck(
    uint8 _heldSeed,
    bool _exempt,
    uint256 _count,
    uint256 _cap
  ) external {
    uint256 _held = bound(_heldSeed, 0, 2) == 0 ? 0 : (bound(_heldSeed, 0, 2) == 1 ? _BIT : _OTHER_BIT);
    _count = bound(_count, 0, 6);
    _cap = bound(_cap, 0, 5);
    _admit(_to, _held, _exempt, _count, _cap);
    assertEq(_rule.checkReceive(_token, _to), _check(IPolicyHook.TransferKind.MINT, address(0), _to, 1));
  }

  function test_WhenTheTokenIsNotAClass_BothReturnNotFundClass() external {
    vm.mockCall(_fund, abi.encodeCall(IFund.admission, (_token, _to)), abi.encode(0, 0, false, 0, 5, address(_rule)));
    assertEq(_rule.checkSend(_token, _to), Reasons.NOT_FUND_CLASS);
    assertEq(_rule.checkReceive(_token, _to), Reasons.NOT_FUND_CLASS);
  }

  function testFuzz_WhenTheRuleIsNotTheFundsInstalledOne_BothReturnNotFundClass(
    address _installed
  ) external {
    vm.assume(_installed != address(_rule));
    vm.mockCall(_fund, abi.encodeCall(IFund.admission, (_token, _to)), abi.encode(_INDEX, 0, false, 0, 5, _installed));
    assertEq(_rule.checkSend(_token, _to), Reasons.NOT_FUND_CLASS);
    assertEq(_rule.checkReceive(_token, _to), Reasons.NOT_FUND_CLASS);
  }

  /// @dev When the account checks reject, `check` rejects every movement that touches the account, for every kind
  function testFuzz_WhenTheAccountChecksReject_CheckRejectsToo(
    uint8 _kindSeed,
    uint256 _amount
  ) external {
    IPolicyHook.TransferKind _kind = IPolicyHook.TransferKind(bound(_kindSeed, 0, 4));
    vm.mockCall(_fund, abi.encodeCall(IFund.admission, (_token, _to)), abi.encode(0, 0, false, 0, 5, address(_rule)));
    assertEq(_rule.checkReceive(_token, _to), Reasons.NOT_FUND_CLASS);
    assertEq(_check(_kind, _from, _to, _amount), Reasons.NOT_FUND_CLASS);
  }
}
