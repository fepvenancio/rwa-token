// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IMinPositionRule} from 'interfaces/IMinPositionRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {MinPositionRule} from 'contracts/hooks/rules/MinPositionRule.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockStatefulToken} from 'contracts/test/MockStatefulToken.sol';

contract MinPositionRuleUnitTest is Helpers {
  bytes32 internal constant _DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 internal constant _BURNER_ROLE = keccak256('BURNER_ROLE');
  uint256 internal constant _MIN = 100 ether;

  MinPositionRule internal _rule;
  address internal _token;
  address internal _admin = makeAddr('admin');
  address internal _stranger = makeAddr('stranger');
  address internal _from = makeAddr('from');
  address internal _to = makeAddr('to');
  address internal _burner = makeAddr('burner');

  function setUp() public virtual {
    _token = _mockContract('token');
    vm.mockCall(_token, abi.encodeCall(IAccessControl.hasRole, (_DEFAULT_ADMIN_ROLE, _admin)), abi.encode(true));
    vm.mockCall(_token, abi.encodeCall(IAccessControl.hasRole, (_DEFAULT_ADMIN_ROLE, _stranger)), abi.encode(false));
    vm.mockCall(_token, abi.encodeCall(IAccessControl.hasRole, (_BURNER_ROLE, _burner)), abi.encode(true));
    vm.mockCall(_token, abi.encodeCall(IAccessControl.hasRole, (_BURNER_ROLE, _from)), abi.encode(false));
    _rule = new MinPositionRule();
  }

  function _setMin(
    uint256 _amount
  ) internal {
    vm.prank(_admin);
    _rule.setMinPosition(_token, _amount);
  }

  function _setExempt(
    address _account,
    bool _exempt
  ) internal {
    vm.prank(_admin);
    _rule.setExempt(_token, _account, _exempt);
  }

  /// @dev Context of a movement with the balances before it, as the token builds it
  function _ctx(
    IPolicyHook.TransferKind _kind,
    address _sender,
    address _receiver,
    uint256 _amount,
    uint256 _fromBalance,
    uint256 _toBalance
  ) internal view returns (IPolicyHook.TransferContext memory _context) {
    _context = IPolicyHook.TransferContext({
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

  function _transfer(
    uint256 _amount,
    uint256 _fromBalance,
    uint256 _toBalance
  ) internal view returns (bytes32 _reason) {
    _reason = _rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, _amount, _fromBalance, _toBalance));
  }
}

contract MinPositionRuleUnit_SetMinPosition is MinPositionRuleUnitTest {
  function test_WhenCallerIsNotTheTokensAdmin_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IMinPositionRule.MinPositionRule_OnlyTokenAdmin.selector, _token, _stranger));
    vm.prank(_stranger);
    _rule.setMinPosition(_token, _MIN);
  }

  function test_WhenCallerIsTheTokensAdmin_ItStoresAndEmitsTheOldAndNewValue(
    uint256 _first,
    uint256 _second
  ) external {
    vm.expectEmit(address(_rule));
    emit IMinPositionRule.MinPositionSet(_token, 0, _first);
    _setMin(_first);
    assertEq(_rule.minPosition(_token), _first);

    vm.expectEmit(address(_rule));
    emit IMinPositionRule.MinPositionSet(_token, _first, _second);
    _setMin(_second);
    assertEq(_rule.minPosition(_token), _second);
  }

  function test_WhenSetToZero_TheRuleIsOffForTheToken(
    uint8 _kindSeed
  ) external {
    _setMin(_MIN);
    _setMin(0);
    IPolicyHook.TransferKind _kind = IPolicyHook.TransferKind(bound(_kindSeed, 0, 4));
    assertEq(_rule.check(_ctx(_kind, _from, _to, 1, 5, 0)), Reasons.TRANSFER_OK);
  }

  /// @dev Sound because state is keyed by token: a fake token can only authorise writes to its own key
  function test_WhenAFakeTokenAuthorisesAnAttacker_OnlyTheFakeTokensKeyChanges() external {
    address _fakeToken = _mockContract('fakeToken');
    address _attacker = makeAddr('attacker');
    vm.mockCall(_fakeToken, abi.encodeCall(IAccessControl.hasRole, (_DEFAULT_ADMIN_ROLE, _attacker)), abi.encode(true));

    vm.prank(_attacker);
    _rule.setMinPosition(_fakeToken, _MIN);

    assertEq(_rule.minPosition(_fakeToken), _MIN);
    assertEq(_rule.minPosition(_token), 0);
    assertEq(_transfer(1, 5, 0), Reasons.TRANSFER_OK);
  }
}

contract MinPositionRuleUnit_SetExempt is MinPositionRuleUnitTest {
  function test_WhenCallerIsNotTheTokensAdmin_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IMinPositionRule.MinPositionRule_OnlyTokenAdmin.selector, _token, _stranger));
    vm.prank(_stranger);
    _rule.setExempt(_token, _to, true);
  }

  function test_WhenTheAccountIsZero_ItReverts() external {
    vm.expectRevert(IMinPositionRule.MinPositionRule_ZeroAddress.selector);
    vm.prank(_admin);
    _rule.setExempt(_token, address(0), true);
  }

  function test_WhenSet_ItStoresAndEmits(
    bool _exempt
  ) external {
    vm.expectEmit(address(_rule));
    emit IMinPositionRule.MinPositionExemptionSet(_token, _to, _exempt);
    _setExempt(_to, _exempt);
    assertEq(_rule.isExempt(_token, _to), _exempt);
  }

  /// @dev The token itself is the 7540 escrow; it is exempt without being listed
  function test_WhenQueriedForTheTokenItself_ItIsExempt() external view {
    assertTrue(_rule.isExempt(_token, _token));
    assertFalse(_rule.isExempt(_token, _to));
  }

  function test_WhenAFakeTokenAuthorisesAnAttacker_OnlyTheFakeTokensKeyChanges() external {
    address _fakeToken = _mockContract('fakeToken');
    address _attacker = makeAddr('attacker');
    vm.mockCall(_fakeToken, abi.encodeCall(IAccessControl.hasRole, (_DEFAULT_ADMIN_ROLE, _attacker)), abi.encode(true));

    vm.prank(_attacker);
    _rule.setExempt(_fakeToken, _to, true);

    assertTrue(_rule.isExempt(_fakeToken, _to));
    assertFalse(_rule.isExempt(_token, _to));
  }
}

/// @notice The rule's decision for each side of a holder-driven movement: the balance after the move is zero, or at
///         least the minimum
contract MinPositionRuleUnit_Check is MinPositionRuleUnitTest {
  function setUp() public override {
    super.setUp();
    _setMin(_MIN);
  }

  function test_WhenTheReceiverEndsAtOrAboveTheMinimum_ItReturnsOk() external view {
    assertEq(_transfer(_MIN, 500 ether, 0), Reasons.TRANSFER_OK); // a new holder, exactly the minimum
    assertEq(_transfer(_MIN + 1, 500 ether, 0), Reasons.TRANSFER_OK);
    assertEq(_transfer(1, 500 ether, _MIN), Reasons.TRANSFER_OK); // a holder at the minimum receives a wei
  }

  function test_WhenANewReceiverWouldHoldLessThanTheMinimum_ItReturnsBelowMinPosition() external view {
    assertEq(_transfer(1, 500 ether, 0), Reasons.BELOW_MIN_POSITION); // the dust that takes a holder slot
    assertEq(_transfer(_MIN - 1, 500 ether, 0), Reasons.BELOW_MIN_POSITION);
  }

  function test_WhenAnExistingDustReceiverStaysBelowTheMinimum_ItReturnsBelowMinPosition() external view {
    assertEq(_transfer(10, 500 ether, 20), Reasons.BELOW_MIN_POSITION);
    assertEq(_transfer(_MIN - 20, 500 ether, 20), Reasons.TRANSFER_OK); // topped up to exactly the minimum
    assertEq(_transfer(_MIN - 21, 500 ether, 20), Reasons.BELOW_MIN_POSITION);
  }

  function test_WhenTheSenderKeepsNothingOrAtLeastTheMinimum_ItReturnsOk() external view {
    assertEq(_transfer(500 ether, 500 ether, 0), Reasons.TRANSFER_OK); // everything leaves
    assertEq(_transfer(_MIN, 2 * _MIN, 0), Reasons.TRANSFER_OK); // exactly the minimum stays
    assertEq(_transfer(_MIN, 2 * _MIN + 5, 0), Reasons.TRANSFER_OK);
  }

  function test_WhenTheSenderWouldKeepDust_ItReturnsBelowMinPosition() external view {
    assertEq(_transfer(500 ether - 1, 500 ether, 0), Reasons.BELOW_MIN_POSITION);
    assertEq(_transfer(_MIN, 2 * _MIN - 1, 0), Reasons.BELOW_MIN_POSITION);
  }

  /// @dev The whole decision as a property over balances and amount, so no boundary hides between the examples
  function testFuzz_ForATransfer_ItRejectsExactlyWhenAPositionIsLeftBelowTheMinimum(
    uint256 _min,
    uint256 _fromBalance,
    uint256 _toBalance,
    uint256 _amount
  ) external {
    _min = bound(_min, 1, 1e30);
    _fromBalance = bound(_fromBalance, 1, 1e30);
    _amount = bound(_amount, 1, _fromBalance);
    _toBalance = bound(_toBalance, 0, 1e30);
    _setMin(_min);

    uint256 _fromAfter = _fromBalance - _amount;
    uint256 _toAfter = _toBalance + _amount;
    bool _breach = (_fromAfter != 0 && _fromAfter < _min) || _toAfter < _min;
    assertEq(_transfer(_amount, _fromBalance, _toBalance), _breach ? Reasons.BELOW_MIN_POSITION : Reasons.TRANSFER_OK);
  }

  /// @dev EXECUTED is a holder-driven transfer, and its context carries the reference and deadline after the balances
  function test_WhenTheKindIsExecuted_ItDecidesTheSameAndReadsTheLongerExtra() external view {
    IPolicyHook.TransferContext memory _context = _ctx(IPolicyHook.TransferKind.EXECUTED, _from, _to, 1, 500 ether, 0);
    _context.extra = abi.encode(uint256(500 ether), uint256(0), keccak256('ref'), block.timestamp + 1 days);
    assertEq(_rule.check(_context), Reasons.BELOW_MIN_POSITION);
    _context.amount = _MIN;
    assertEq(_rule.check(_context), Reasons.TRANSFER_OK);
  }

  function test_WhenMinting_OnlyTheReceiverIsJudged() external view {
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, _MIN, 0, 0)), Reasons.TRANSFER_OK);
    assertEq(
      _rule.check(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, _MIN - 1, 0, 0)), Reasons.BELOW_MIN_POSITION
    );
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 1, 0, _MIN)), Reasons.TRANSFER_OK);
  }

  function test_WhenAHolderBurns_OnlyTheRemainderIsJudged() external view {
    assertEq(
      _rule.check(_ctx(IPolicyHook.TransferKind.BURN, _from, address(0), 500 ether, 500 ether, 0)), Reasons.TRANSFER_OK
    );
    assertEq(
      _rule.check(_ctx(IPolicyHook.TransferKind.BURN, _from, address(0), 400 ether, 500 ether, 0)), Reasons.TRANSFER_OK
    );
    assertEq(
      _rule.check(_ctx(IPolicyHook.TransferKind.BURN, _from, address(0), 500 ether - 1, 500 ether, 0)),
      Reasons.BELOW_MIN_POSITION
    );
  }

  /// @dev Nothing moves, so nothing is left behind: a dust holder's zero-amount or self movement is not a new breach
  function test_WhenNothingChangesHands_ItReturnsOk() external view {
    assertEq(_transfer(0, 5, 3), Reasons.TRANSFER_OK);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _from, 2, 5, 5)), Reasons.TRANSFER_OK);
  }

  function test_WhenTheTokenHasNoMinimum_ItReturnsOkForDustAndNeverAsksTheTokenForRoles() external {
    address _other = _mockContract('other');
    vm.expectCall(_other, abi.encodeWithSelector(IAccessControl.hasRole.selector), 0);
    IPolicyHook.TransferContext memory _context = _ctx(IPolicyHook.TransferKind.BURN, _from, address(0), 1, 5, 0);
    _context.token = _other;
    assertEq(_rule.check(_context), Reasons.TRANSFER_OK);
  }

  /// @dev A check on a view path never reverts on arithmetic: huge amounts and impossible balances are answered
  function test_WhenTheNumbersAreExtreme_ItNeverReverts() external view {
    assertEq(
      _rule.check(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, type(uint256).max, 0, type(uint256).max / 2)),
      Reasons.TRANSFER_OK
    );
    assertEq(_transfer(type(uint256).max, type(uint256).max, type(uint256).max), Reasons.TRANSFER_OK);
    // The sender holds less than the amount: the token's own balance check refuses that before the hook is asked.
    assertEq(_transfer(200 ether, 150 ether, 0), Reasons.TRANSFER_OK);
  }

  function test_WhenCalledWithStaticcall_ItDoesNotWrite() external view {
    (bool _ok, bytes memory _out) = address(_rule)
      .staticcall(
        abi.encodeCall(IComplianceRule.check, (_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, 1, 5 ether, 0)))
      );
    assertTrue(_ok);
    assertEq(abi.decode(_out, (bytes32)), Reasons.BELOW_MIN_POSITION);
  }
}

/// @notice The exemptions of IMinPositionRule: FORCED, an enforcement burn, the token itself and the listed accounts
contract MinPositionRuleUnit_Exemptions is MinPositionRuleUnitTest {
  function setUp() public override {
    super.setUp();
    _setMin(_MIN);
  }

  function test_WhenForced_BothSidesAreExempt() external view {
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.FORCED, _from, _to, 1, 5, 0)), Reasons.TRANSFER_OK);
    assertEq(
      _rule.check(_ctx(IPolicyHook.TransferKind.FORCED, _from, _to, 500 ether - 1, 500 ether, 0)), Reasons.TRANSFER_OK
    );
  }

  /// @dev Brief §5: FORCED with `from == address(0)` is an enforcement mint, exempt like any FORCED move
  function test_WhenAnEnforcementMintLeavesDust_ItIsExempt() external view {
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.FORCED, address(0), _to, 1, 0, 0)), Reasons.TRANSFER_OK);
  }

  /// @dev The operator holds BURNER_ROLE, as the lockup rule and the token's frozen-balance check define it
  function test_WhenAnEnforcementBurnerLeavesDust_ItIsExempt() external {
    IPolicyHook.TransferContext memory _context =
      _ctx(IPolicyHook.TransferKind.BURN, _from, address(0), 450 ether, 500 ether, 0);
    _context.operator = _burner;
    vm.expectCall(_token, abi.encodeCall(IAccessControl.hasRole, (_BURNER_ROLE, _burner)), 1);
    assertEq(_rule.check(_context), Reasons.TRANSFER_OK);
  }

  function test_WhenAHolderBurnLeavesDust_TheRoleIsAskedAndTheBurnRejected() external {
    vm.expectCall(_token, abi.encodeCall(IAccessControl.hasRole, (_BURNER_ROLE, _from)), 1);
    assertEq(
      _rule.check(_ctx(IPolicyHook.TransferKind.BURN, _from, address(0), 450 ether, 500 ether, 0)),
      Reasons.BELOW_MIN_POSITION
    );
  }

  /// @dev The role is asked only when a burn would leave a balance below the minimum, so the usual burn pays nothing
  function test_WhenABurnLeavesNothingOrEnoughOrIsNotABurn_TheTokenIsNeverAskedForRoles() external {
    vm.expectCall(_token, abi.encodeWithSelector(IAccessControl.hasRole.selector), 0);
    IPolicyHook.TransferContext memory _context =
      _ctx(IPolicyHook.TransferKind.BURN, _from, address(0), 500 ether, 500 ether, 0);
    _context.operator = _burner;
    assertEq(_rule.check(_context), Reasons.TRANSFER_OK); // leaves nothing
    _context.amount = 400 ether;
    assertEq(_rule.check(_context), Reasons.TRANSFER_OK); // leaves exactly the minimum
    _context.kind = IPolicyHook.TransferKind.TRANSFER;
    _context.to = _to;
    _context.amount = _MIN;
    assertEq(_rule.check(_context), Reasons.TRANSFER_OK); // a transfer is judged on its own terms
  }

  /// @dev Only a BURN is an enforcement action: the role does not exempt a transfer
  function test_WhenAnEnforcementBurnerTransfersAndLeavesDust_ItIsRejected() external view {
    IPolicyHook.TransferContext memory _context =
      _ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, 450 ether, 500 ether, 0);
    _context.operator = _burner;
    assertEq(_rule.check(_context), Reasons.BELOW_MIN_POSITION);
  }

  /// @dev The 7540 escrow: a redeem request moves shares to the token below the minimum, and the fulfilment burns them
  function test_WhenTheTokenItselfReceivesOrSends_ItIsExempt() external view {
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _token, 1, 500 ether, 0)), Reasons.TRANSFER_OK);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER, _token, _to, _MIN, _MIN + 5, 0)), Reasons.TRANSFER_OK);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.BURN, _token, address(0), 7, 10, 0)), Reasons.TRANSFER_OK);
  }

  function test_WhenTheTokenSendsToADustReceiver_TheReceiverIsStillJudged() external view {
    assertEq(
      _rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER, _token, _to, 1, 500 ether, 0)), Reasons.BELOW_MIN_POSITION
    );
  }

  function test_WhenAListedAccountReceivesDust_ItIsExemptButTheSenderIsStillJudged() external {
    _setExempt(_to, true);
    assertEq(_transfer(1, 500 ether, 0), Reasons.TRANSFER_OK);
    assertEq(_transfer(500 ether - 1, 500 ether, 0), Reasons.BELOW_MIN_POSITION);
  }

  function test_WhenAListedAccountSendsAndKeepsDust_ItIsExemptButTheReceiverIsStillJudged() external {
    _setExempt(_from, true);
    assertEq(_transfer(500 ether - 1, 500 ether, 0), Reasons.TRANSFER_OK);
    assertEq(_transfer(1, 500 ether, 0), Reasons.BELOW_MIN_POSITION);
  }

  function test_WhenAnExemptionIsRemoved_TheAccountIsJudgedAgain() external {
    _setExempt(_to, true);
    _setExempt(_to, false);
    assertEq(_transfer(1, 500 ether, 0), Reasons.BELOW_MIN_POSITION);
  }

  function test_WhenAnotherTokenListsTheAccount_ThisTokenStillJudgesIt() external {
    address _otherToken = _mockContract('otherToken');
    vm.mockCall(_otherToken, abi.encodeCall(IAccessControl.hasRole, (_DEFAULT_ADMIN_ROLE, _admin)), abi.encode(true));
    vm.prank(_admin);
    _rule.setExempt(_otherToken, _to, true);
    assertEq(_transfer(1, 500 ether, 0), Reasons.BELOW_MIN_POSITION);
  }
}

/// @notice The rule has no account-level opinion: a position limit depends on the amount, so the account checks accept
contract MinPositionRuleUnit_AccountChecks is MinPositionRuleUnitTest {
  function test_WhenAsked_BothAccept() external {
    _setMin(_MIN);
    assertEq(_rule.checkSend(_token, _from), Reasons.TRANSFER_OK);
    assertEq(_rule.checkReceive(_token, _to), Reasons.TRANSFER_OK);
  }
}

contract MinPositionRuleUnit_Metadata is MinPositionRuleUnitTest {
  function test_WhenQueried_ItReturnsItsMetadata() external view {
    assertEq(_rule.ruleId(), keccak256('MinPositionRule.v1'));
    assertFalse(_rule.wantsAfter());
    assertTrue(_rule.supportsInterface(type(IComplianceRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(IMinPositionRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(IERC165).interfaceId));
  }
}

/// @dev Aderyn `reentrancy-state-change` is a false positive: the token is read through STATICCALL
contract MinPositionRuleUnit_TokenCallsAreStatic is MinPositionRuleUnitTest {
  function test_WhenTheTokenTriesToWriteDuringTheRoleCheck_TheSettersRevert() external {
    MockStatefulToken _stateful = new MockStatefulToken();
    _stateful.hasRole(_DEFAULT_ADMIN_ROLE, _admin); // control: the same read writes when called with CALL
    assertEq(_stateful.writes(), 1);

    vm.expectRevert(bytes('')); // a write inside a STATICCALL reverts with empty data, bubbled by the rule
    vm.prank(_admin);
    _rule.setMinPosition(address(_stateful), _MIN);
    assertEq(_rule.minPosition(address(_stateful)), 0);

    vm.expectRevert(bytes(''));
    vm.prank(_admin);
    _rule.setExempt(address(_stateful), _to, true);
    assertFalse(_rule.isExempt(address(_stateful), _to));
  }
}
