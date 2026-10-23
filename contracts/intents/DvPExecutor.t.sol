// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IDvPExecutor} from 'interfaces/IDvPExecutor.sol';
import {IERC3009} from 'interfaces/IERC3009.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {FundIntegrationTest} from 'contracts/fund/FundIntegration.t.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {RuleSetIntegrationTest} from 'contracts/hooks/rules/RuleSetIntegration.t.sol';
import {DvPExecutor} from 'contracts/intents/DvPExecutor.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockERC3009Token} from 'contracts/test/MockERC3009Token.sol';
import {MockFakeSecurityToken} from 'contracts/test/MockFakeSecurityToken.sol';
import {MockReentrantCashToken} from 'contracts/test/MockReentrantCashToken.sol';
import {MockReentrantGatedToken} from 'contracts/test/MockReentrantGatedToken.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';

/// @notice Unit: the executor against mocked tokens. Every external call is mocked, and the calls that matter to a
///         test are expected (or expected not to happen)
contract DvPExecutorUnitTest is Helpers {
  uint256 internal constant _SHARES = 10;
  uint256 internal constant _CASH = 500;
  bytes32 internal constant _SECURITIES_HASH = keccak256('securitiesHash');
  bytes32 internal constant _CASH_HASH = keccak256('cashHash');
  bytes internal constant _SIG_S = 'sigS';
  bytes internal constant _SIG_C = 'sigC';

  DvPExecutor internal _dvp;
  address internal _security;
  address internal _cash;
  address internal _admin = makeAddr('timelock');
  address internal _guardian = makeAddr('guardian');
  address internal _operator = makeAddr('operator');
  address internal _stranger = makeAddr('stranger');
  address internal _seller = makeAddr('seller');
  address internal _buyer = makeAddr('buyer');

  function setUp() public virtual {
    _security = _mockContract('security');
    _cash = _mockContract('cash');
    _dvp = new DvPExecutor(_admin, _guardian);
    bytes32 _operatorRole = _dvp.OPERATOR_ROLE();
    vm.prank(_admin);
    _dvp.grantRole(_operatorRole, _operator);
  }

  function _securitiesIntent() internal view returns (ITransferIntent.TransferIntent memory _i) {
    _i = ITransferIntent.TransferIntent({
      from: _seller,
      to: _buyer,
      amount: _SHARES,
      nonce: keccak256('sNonce'),
      deadline: 1000,
      ref: keccak256('sRef'),
      executor: address(_dvp),
      validAfter: 0,
      considerationToken: _cash,
      considerationAmount: _CASH
    });
  }

  function _cashIntent() internal view returns (ITransferIntent.TransferIntent memory _i) {
    _i = ITransferIntent.TransferIntent({
      from: _buyer,
      to: _seller,
      amount: _CASH,
      nonce: keccak256('cNonce'),
      deadline: 1000,
      ref: keccak256('cRef'),
      executor: address(_dvp),
      validAfter: 0,
      considerationToken: _security,
      considerationAmount: _SHARES
    });
  }

  function _authNonce() internal view returns (bytes32 _nonce) {
    _nonce = keccak256(abi.encode(_security, _SECURITIES_HASH));
  }

  function _authorization() internal view returns (IDvPExecutor.Authorization memory _a) {
    _a = IDvPExecutor.Authorization({
      from: _buyer, value: _CASH, validAfter: 10, validBefore: 2000, nonce: _authNonce(), signature: 'authSig'
    });
  }

  function _receiveCall() internal view returns (bytes memory _callData) {
    IDvPExecutor.Authorization memory _a = _authorization();
    _callData = abi.encodeCall(
      IERC3009.receiveWithAuthorization,
      (_a.from, address(_dvp), _a.value, _a.validAfter, _a.validBefore, _a.nonce, _a.signature)
    );
  }

  function _cashCall() internal view returns (bytes memory _callData) {
    _callData = abi.encodeCall(ITransferIntent.executeTransfer, (_cashIntent(), _SIG_C));
  }

  function _securitiesCall() internal view returns (bytes memory _callData) {
    _callData = abi.encodeCall(ITransferIntent.executeTransfer, (_securitiesIntent(), _SIG_S));
  }

  function _gatedLegsSettle() internal {
    _mockAndExpect(_cash, _cashCall(), abi.encode(_CASH_HASH));
    _mockAndExpect(_security, _securitiesCall(), abi.encode(_SECURITIES_HASH));
  }

  function _runGated() internal returns (bytes32 _hash) {
    vm.prank(_operator);
    _hash = _dvp.executeDvPGated(_security, _cash, _securitiesIntent(), _SIG_S, _cashIntent(), _SIG_C);
  }

  function _run3009() internal returns (bytes32 _hash) {
    vm.prank(_operator);
    _hash = _dvp.executeDvP3009(_security, _cash, _securitiesIntent(), _SIG_S, _authorization());
  }

  /// @dev Mocks everything the 3009 path calls; the executor holds 7 of the cash token before, the seller 100
  function _settle3009Mocks(
    uint256 _executorAfter,
    uint256 _sellerAfter
  ) internal {
    vm.mockCall(
      _security, abi.encodeCall(ITransferIntent.intentHash, (_securitiesIntent())), abi.encode(_SECURITIES_HASH)
    );
    _mockAndExpect(_cash, _receiveCall(), '');
    _mockAndExpect(_security, _securitiesCall(), abi.encode(_SECURITIES_HASH));
    _mockAndExpect(_cash, abi.encodeCall(IERC20.transfer, (_seller, _CASH)), abi.encode(true));

    bytes[] memory _executorBalances = new bytes[](2);
    _executorBalances[0] = abi.encode(uint256(7));
    _executorBalances[1] = abi.encode(_executorAfter);
    vm.mockCalls(_cash, abi.encodeCall(IERC20.balanceOf, (address(_dvp))), _executorBalances);
    bytes[] memory _sellerBalances = new bytes[](2);
    _sellerBalances[0] = abi.encode(uint256(100));
    _sellerBalances[1] = abi.encode(_sellerAfter);
    vm.mockCalls(_cash, abi.encodeCall(IERC20.balanceOf, (_seller)), _sellerBalances);
  }

  function _legFailed(
    IDvPExecutor.Leg _leg,
    bytes memory _reason
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IDvPExecutor.DvPExecutor_LegFailed.selector, _leg, _reason);
  }

  function _rejected(
    bytes32 _reason
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IPolicyGated.PolicyGated_TransferRejected.selector, _reason);
  }

  function _unauthorized(
    address _caller,
    bytes32 _role
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role);
  }
}

contract DvPExecutorUnit_Constructor is DvPExecutorUnitTest {
  function test_WhenAdminIsZero_ItReverts() external {
    vm.expectRevert(IDvPExecutor.DvPExecutor_ZeroAddress.selector);
    new DvPExecutor(address(0), _guardian);
  }

  function test_WhenGuardianIsZero_ItReverts() external {
    vm.expectRevert(IDvPExecutor.DvPExecutor_ZeroAddress.selector);
    new DvPExecutor(_admin, address(0));
  }

  function test_WhenValid_ItGrantsAdminAndGuardianOnly() external view {
    assertTrue(_dvp.hasRole(_dvp.DEFAULT_ADMIN_ROLE(), _admin));
    assertTrue(_dvp.hasRole(_dvp.GUARDIAN_ROLE(), _guardian));
    assertFalse(_dvp.hasRole(_dvp.OPERATOR_ROLE(), _admin));
    assertFalse(_dvp.paused());
  }

  function test_WhenQueried_ItSupportsItsInterfaceAndErc165() external view {
    assertTrue(_dvp.supportsInterface(type(IDvPExecutor).interfaceId));
    assertTrue(_dvp.supportsInterface(type(IERC165).interfaceId));
    assertFalse(_dvp.supportsInterface(0xffffffff));
  }
}

contract DvPExecutorUnit_Gated is DvPExecutorUnitTest {
  function test_WhenCallerIsNotOperator_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _dvp.OPERATOR_ROLE()));
    vm.prank(_stranger);
    _dvp.executeDvPGated(_security, _cash, _securitiesIntent(), _SIG_S, _cashIntent(), _SIG_C);
  }

  function test_WhenPaused_ItReverts() external {
    vm.prank(_guardian);
    _dvp.pause();
    vm.expectRevert(Pausable.EnforcedPause.selector);
    _runGated();
  }

  function test_WhenTheLegsMirror_ItExecutesBothAndEmits() external {
    _gatedLegsSettle();
    vm.expectEmit(address(_dvp));
    emit IDvPExecutor.DvPSettled(_SECURITIES_HASH, _seller, _buyer, _security, _cash, _SHARES, _CASH, _operator);
    assertEq(_runGated(), _SECURITIES_HASH);
  }

  function test_WhenAnyMirroredFieldDiffers_ItRevertsBeforeTouchingAToken(
    uint8 _which
  ) external {
    _which = uint8(bound(_which, 0, 5));
    ITransferIntent.TransferIntent memory _s = _securitiesIntent();
    ITransferIntent.TransferIntent memory _c = _cashIntent();
    if (_which == 0) _s.from = _stranger;
    if (_which == 1) _s.to = _stranger;
    if (_which == 2) _s.amount = _SHARES + 1;
    if (_which == 3) _c.amount = _CASH + 1;
    if (_which == 4) _s.considerationToken = _stranger;
    if (_which == 5) _c.considerationToken = _stranger;

    vm.expectCall(_cash, abi.encodeWithSelector(ITransferIntent.executeTransfer.selector), 0);
    vm.expectCall(_security, abi.encodeWithSelector(ITransferIntent.executeTransfer.selector), 0);
    vm.expectRevert(IDvPExecutor.DvPExecutor_LegsDoNotMatch.selector);
    vm.prank(_operator);
    _dvp.executeDvPGated(_security, _cash, _s, _SIG_S, _c, _SIG_C);
  }

  function test_WhenTheTwoTokensAreTheSame_ItReverts() external {
    ITransferIntent.TransferIntent memory _s = _securitiesIntent();
    ITransferIntent.TransferIntent memory _c = _cashIntent();
    _s.considerationToken = _security;
    vm.expectRevert(IDvPExecutor.DvPExecutor_LegsDoNotMatch.selector);
    vm.prank(_operator);
    _dvp.executeDvPGated(_security, _security, _s, _SIG_S, _c, _SIG_C);
  }

  function test_WhenTheCashLegFails_ItReportsTheCashLegAndNeverRunsTheSecuritiesLeg(
    bytes32 _reason
  ) external {
    vm.mockCallRevert(_cash, _cashCall(), _rejected(_reason));
    vm.expectCall(_security, abi.encodeWithSelector(ITransferIntent.executeTransfer.selector), 0);
    vm.expectRevert(_legFailed(IDvPExecutor.Leg.CASH, _rejected(_reason)));
    _runGated();
  }

  function test_WhenTheSecuritiesLegFails_ItReportsTheSecuritiesLeg(
    bytes32 _reason
  ) external {
    vm.mockCall(_cash, _cashCall(), abi.encode(_CASH_HASH));
    vm.mockCallRevert(_security, _securitiesCall(), _rejected(_reason));
    vm.expectRevert(_legFailed(IDvPExecutor.Leg.SECURITIES, _rejected(_reason)));
    _runGated();
  }

  function test_WhenBothLegsFail_TheCashLegIsReportedBecauseItRunsFirst() external {
    vm.mockCallRevert(_cash, _cashCall(), _rejected(Reasons.INSUFFICIENT_UNFROZEN));
    vm.mockCallRevert(_security, _securitiesCall(), _rejected(Reasons.LOCKED));
    vm.expectRevert(_legFailed(IDvPExecutor.Leg.CASH, _rejected(Reasons.INSUFFICIENT_UNFROZEN)));
    _runGated();
  }

  function test_WhenTheSecurityTokenHasNoCode_ItRevertsAfterTheCashLegRan() external {
    address _noCode = makeAddr('noCode');
    ITransferIntent.TransferIntent memory _c = _cashIntent();
    _c.considerationToken = _noCode; // the legs still mirror
    _mockAndExpect(_cash, abi.encodeCall(ITransferIntent.executeTransfer, (_c, _SIG_C)), abi.encode(_CASH_HASH));
    vm.expectRevert(bytes(''));
    vm.prank(_operator);
    _dvp.executeDvPGated(_noCode, _cash, _securitiesIntent(), _SIG_S, _c, _SIG_C);
  }

  function test_WhenTheCashTokenHasNoCode_ItReverts() external {
    address _noCode = makeAddr('noCode');
    ITransferIntent.TransferIntent memory _s = _securitiesIntent();
    _s.considerationToken = _noCode; // the legs still mirror
    vm.expectCall(_security, abi.encodeWithSelector(ITransferIntent.executeTransfer.selector), 0);
    vm.expectRevert(bytes(''));
    vm.prank(_operator);
    _dvp.executeDvPGated(_security, _noCode, _s, _SIG_S, _cashIntent(), _SIG_C);
  }
}

contract DvPExecutorUnit_Authorization is DvPExecutorUnitTest {
  function test_WhenCallerIsNotOperator_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _dvp.OPERATOR_ROLE()));
    vm.prank(_stranger);
    _dvp.executeDvP3009(_security, _cash, _securitiesIntent(), _SIG_S, _authorization());
  }

  function test_WhenPaused_ItReverts() external {
    vm.prank(_guardian);
    _dvp.pause();
    vm.expectRevert(Pausable.EnforcedPause.selector);
    _run3009();
  }

  function test_WhenTheAuthorizationMatches_ItPullsDeliversPaysAndEmits() external {
    _settle3009Mocks(7, 600);
    vm.expectEmit(address(_dvp));
    emit IDvPExecutor.DvPSettled(_SECURITIES_HASH, _seller, _buyer, _security, _cash, _SHARES, _CASH, _operator);
    assertEq(_run3009(), _SECURITIES_HASH);
  }

  function test_WhenAnythingTheAuthorizationMustMatchDiffers_ItRevertsBeforeMovingCash(
    uint8 _which
  ) external {
    _which = uint8(bound(_which, 0, 3));
    vm.mockCall(
      _security, abi.encodeCall(ITransferIntent.intentHash, (_securitiesIntent())), abi.encode(_SECURITIES_HASH)
    );
    ITransferIntent.TransferIntent memory _s = _securitiesIntent();
    IDvPExecutor.Authorization memory _a = _authorization();
    if (_which == 0) _a.from = _stranger;
    if (_which == 1) _a.value = _CASH + 1;
    if (_which == 2) _s.considerationToken = _stranger;
    if (_which == 3) _a.nonce = _SECURITIES_HASH; // the bare intent hash, without the token address
    if (_which == 2) {
      vm.mockCall(_security, abi.encodeCall(ITransferIntent.intentHash, (_s)), abi.encode(_SECURITIES_HASH));
    }

    vm.expectCall(_cash, abi.encodeWithSelector(IERC3009.receiveWithAuthorization.selector), 0);
    vm.expectRevert(IDvPExecutor.DvPExecutor_LegsDoNotMatch.selector);
    vm.prank(_operator);
    _dvp.executeDvP3009(_security, _cash, _s, _SIG_S, _a);
  }

  function test_WhenTheTwoTokensAreTheSame_ItReverts() external {
    ITransferIntent.TransferIntent memory _s = _securitiesIntent();
    _s.considerationToken = _security;
    IDvPExecutor.Authorization memory _a = _authorization();
    _a.nonce = keccak256(abi.encode(_security, _SECURITIES_HASH));
    vm.mockCall(_security, abi.encodeCall(ITransferIntent.intentHash, (_s)), abi.encode(_SECURITIES_HASH));
    vm.expectRevert(IDvPExecutor.DvPExecutor_LegsDoNotMatch.selector);
    vm.prank(_operator);
    _dvp.executeDvP3009(_security, _security, _s, _SIG_S, _a);
  }

  function test_WhenTheSecurityTokenHasNoCode_ItReverts() external {
    vm.expectRevert(bytes(''));
    vm.prank(_operator);
    _dvp.executeDvP3009(makeAddr('noCode'), _cash, _securitiesIntent(), _SIG_S, _authorization());
  }

  function test_WhenTheExecutorEndsWithMoreOrLessCash_ItReverts(
    uint256 _after
  ) external {
    if (_after == 7) _after = 8;
    _settle3009Mocks(_after, 600);
    vm.expectRevert(
      abi.encodeWithSelector(IDvPExecutor.DvPExecutor_CashNotConserved.selector, address(_dvp), 7, _after)
    );
    _run3009();
  }

  function test_WhenTheSellerReceivesAnythingButTheCashAmount_ItReverts(
    uint256 _after
  ) external {
    if (_after == 600) _after = 601;
    _settle3009Mocks(7, _after);
    vm.expectRevert(abi.encodeWithSelector(IDvPExecutor.DvPExecutor_CashNotConserved.selector, _seller, 600, _after));
    _run3009();
  }

  function test_WhenTheCashPullFails_ItReportsTheCashLegAndNeverRunsTheSecuritiesLeg() external {
    vm.mockCall(
      _security, abi.encodeCall(ITransferIntent.intentHash, (_securitiesIntent())), abi.encode(_SECURITIES_HASH)
    );
    vm.mockCall(_cash, abi.encodeCall(IERC20.balanceOf, (address(_dvp))), abi.encode(uint256(7)));
    vm.mockCall(_cash, abi.encodeCall(IERC20.balanceOf, (_seller)), abi.encode(uint256(100)));
    bytes memory _error = abi.encodeWithSignature('Error(string)', 'authorization is used');
    vm.mockCallRevert(_cash, _receiveCall(), _error);
    vm.expectCall(_security, abi.encodeWithSelector(ITransferIntent.executeTransfer.selector), 0);
    vm.expectRevert(_legFailed(IDvPExecutor.Leg.CASH, _error));
    _run3009();
  }

  function test_WhenTheSecuritiesLegFails_ItReportsTheSecuritiesLegAndNeverPaysTheSeller(
    bytes32 _reason
  ) external {
    vm.mockCall(
      _security, abi.encodeCall(ITransferIntent.intentHash, (_securitiesIntent())), abi.encode(_SECURITIES_HASH)
    );
    vm.mockCall(_cash, abi.encodeCall(IERC20.balanceOf, (address(_dvp))), abi.encode(uint256(7)));
    vm.mockCall(_cash, abi.encodeCall(IERC20.balanceOf, (_seller)), abi.encode(uint256(100)));
    vm.mockCall(_cash, _receiveCall(), '');
    vm.mockCallRevert(_security, _securitiesCall(), _rejected(_reason));
    vm.expectCall(_cash, abi.encodeCall(IERC20.transfer, (_seller, _CASH)), 0);
    vm.expectRevert(_legFailed(IDvPExecutor.Leg.SECURITIES, _rejected(_reason)));
    _run3009();
  }
}

contract DvPExecutorUnit_PreflightGated is DvPExecutorUnitTest {
  function _canGated() internal view returns (bool _ok, bytes32 _reason) {
    (_ok, _reason) = _dvp.canExecuteDvPGated(_security, _cash, _securitiesIntent(), _SIG_S, _cashIntent(), _SIG_C);
  }

  function _legsCan(
    bytes32 _cashReason,
    bytes32 _securitiesReason
  ) internal {
    vm.mockCall(
      _cash,
      abi.encodeCall(ITransferIntent.canExecute, (_cashIntent(), _SIG_C)),
      abi.encode(_cashReason == Reasons.TRANSFER_OK, _cashReason)
    );
    vm.mockCall(
      _security,
      abi.encodeCall(ITransferIntent.canExecute, (_securitiesIntent(), _SIG_S)),
      abi.encode(_securitiesReason == Reasons.TRANSFER_OK, _securitiesReason)
    );
  }

  function test_WhenEverythingPasses_ItReturnsOkAndAsksBothTokensFromTheExecutor() external {
    _mockAndExpect(
      _cash, abi.encodeCall(ITransferIntent.canExecute, (_cashIntent(), _SIG_C)), abi.encode(true, Reasons.TRANSFER_OK)
    );
    _mockAndExpect(
      _security,
      abi.encodeCall(ITransferIntent.canExecute, (_securitiesIntent(), _SIG_S)),
      abi.encode(true, Reasons.TRANSFER_OK)
    );
    (bool _ok, bytes32 _reason) = _canGated();
    assertTrue(_ok);
    assertEq(_reason, Reasons.TRANSFER_OK);
  }

  function test_WhenPaused_ItReturnsPaused() external {
    _legsCan(Reasons.TRANSFER_OK, Reasons.TRANSFER_OK);
    vm.prank(_guardian);
    _dvp.pause();
    (bool _ok, bytes32 _reason) = _canGated();
    assertFalse(_ok);
    assertEq(_reason, Reasons.PAUSED);
  }

  function test_WhenTheLegsDoNotMirror_ItReturnsLegsDoNotMatch() external view {
    ITransferIntent.TransferIntent memory _c = _cashIntent();
    _c.amount = _CASH + 1;
    (bool _ok, bytes32 _reason) = _dvp.canExecuteDvPGated(_security, _cash, _securitiesIntent(), _SIG_S, _c, _SIG_C);
    assertFalse(_ok);
    assertEq(_reason, Reasons.LEGS_DO_NOT_MATCH);
  }

  function test_WhenALegIsRefused_ItReturnsThatLegsReason(
    bytes32 _cashReason,
    bytes32 _securitiesReason
  ) external {
    if (_cashReason == Reasons.TRANSFER_OK) _cashReason = Reasons.LOCKED;
    if (_securitiesReason == Reasons.TRANSFER_OK) _securitiesReason = Reasons.MAX_HOLDERS;

    _legsCan(Reasons.TRANSFER_OK, _securitiesReason);
    (bool _ok, bytes32 _reason) = _canGated();
    assertFalse(_ok);
    assertEq(_reason, _securitiesReason);

    // Both refuse: the cash leg is reported, as it is when the trade runs.
    _legsCan(_cashReason, _securitiesReason);
    (_ok, _reason) = _canGated();
    assertFalse(_ok);
    assertEq(_reason, _cashReason);
  }
}

contract DvPExecutorUnit_Preflight3009 is DvPExecutorUnitTest {
  function setUp() public override {
    super.setUp();
    vm.warp(500);
    vm.mockCall(
      _security, abi.encodeCall(ITransferIntent.intentHash, (_securitiesIntent())), abi.encode(_SECURITIES_HASH)
    );
    _securitiesCan(Reasons.TRANSFER_OK);
    _authorizationIs(false, _CASH);
  }

  function _securitiesCan(
    bytes32 _reason
  ) internal {
    vm.mockCall(
      _security,
      abi.encodeCall(ITransferIntent.canExecute, (_securitiesIntent(), _SIG_S)),
      abi.encode(_reason == Reasons.TRANSFER_OK, _reason)
    );
  }

  function _authorizationIs(
    bool _used,
    uint256 _buyerBalance
  ) internal {
    vm.mockCall(_cash, abi.encodeCall(IERC3009.authorizationState, (_buyer, _authNonce())), abi.encode(_used));
    vm.mockCall(_cash, abi.encodeCall(IERC20.balanceOf, (_buyer)), abi.encode(_buyerBalance));
  }

  function _can() internal view returns (bool _ok, bytes32 _reason) {
    (_ok, _reason) = _dvp.canExecuteDvP3009(_security, _cash, _securitiesIntent(), _SIG_S, _authorization());
  }

  function test_WhenEverythingPasses_ItReturnsOk() external view {
    (bool _ok, bytes32 _reason) = _can();
    assertTrue(_ok);
    assertEq(_reason, Reasons.TRANSFER_OK);
  }

  function test_WhenPaused_ItReturnsPaused() external {
    vm.prank(_guardian);
    _dvp.pause();
    (bool _ok, bytes32 _reason) = _can();
    assertFalse(_ok);
    assertEq(_reason, Reasons.PAUSED);
  }

  function test_WhenTheAuthorizationDoesNotMatch_ItReturnsLegsDoNotMatch() external view {
    IDvPExecutor.Authorization memory _a = _authorization();
    _a.value = _CASH + 1;
    (bool _ok, bytes32 _reason) = _dvp.canExecuteDvP3009(_security, _cash, _securitiesIntent(), _SIG_S, _a);
    assertFalse(_ok);
    assertEq(_reason, Reasons.LEGS_DO_NOT_MATCH);
  }

  function test_WhenTheAuthorizationWindowIsNotOpen_ItReturnsTheWindowReasonWithStrictEdges() external {
    // Circle's rule: valid only for validAfter < now < validBefore, both ends exclusive.
    vm.warp(10);
    (bool _ok, bytes32 _reason) = _can();
    assertFalse(_ok);
    assertEq(_reason, Reasons.INTENT_NOT_YET_VALID);

    vm.warp(11);
    (_ok, _reason) = _can();
    assertTrue(_ok);

    vm.warp(1999);
    (_ok, _reason) = _can();
    assertTrue(_ok);

    vm.warp(2000);
    (_ok, _reason) = _can();
    assertFalse(_ok);
    assertEq(_reason, Reasons.INTENT_EXPIRED);
  }

  function test_WhenTheAuthorizationIsUsed_ItReturnsNonceUsed() external {
    _authorizationIs(true, _CASH);
    (bool _ok, bytes32 _reason) = _can();
    assertFalse(_ok);
    assertEq(_reason, Reasons.NONCE_USED);
  }

  function test_WhenTheBuyerCannotCoverTheValue_ItReturnsInsufficientUnfrozen() external {
    _authorizationIs(false, _CASH - 1);
    (bool _ok, bytes32 _reason) = _can();
    assertFalse(_ok);
    assertEq(_reason, Reasons.INSUFFICIENT_UNFROZEN);
  }

  function test_WhenTheSecuritiesLegIsRefused_ItReturnsItsReason(
    bytes32 _securitiesReason
  ) external {
    if (_securitiesReason == Reasons.TRANSFER_OK) _securitiesReason = Reasons.LOCKED;
    _securitiesCan(_securitiesReason);
    (bool _ok, bytes32 _reason) = _can();
    assertFalse(_ok);
    assertEq(_reason, _securitiesReason);
  }

  function test_WhenTheAuthorizationAndTheSecuritiesLegBothFail_TheAuthorizationIsReportedFirst() external {
    _authorizationIs(true, _CASH);
    _securitiesCan(Reasons.LOCKED);
    (bool _ok, bytes32 _reason) = _can();
    assertFalse(_ok);
    assertEq(_reason, Reasons.NONCE_USED);
  }
}

/// @dev M-1: on this executor too, RECOVERY_ROLE can only unpause and revoke GUARDIAN_ROLE
contract DvPExecutorUnit_Roles is DvPExecutorUnitTest {
  address internal _recovery = makeAddr('recoveryTimelock');

  function setUp() public override {
    super.setUp();
    bytes32 _role = _dvp.RECOVERY_ROLE();
    vm.prank(_admin);
    _dvp.grantRole(_role, _recovery);
    vm.prank(_guardian);
    _dvp.pause();
  }

  function test_WhenTheGuardianPauses_OnlyTheGuardianCan() external {
    vm.expectRevert(_unauthorized(_stranger, _dvp.GUARDIAN_ROLE()));
    vm.prank(_stranger);
    _dvp.pause();
  }

  function test_WhenAdminOrRecoveryUnpauses_ItWorks() external {
    vm.prank(_admin);
    _dvp.unpause();
    assertFalse(_dvp.paused());
    vm.prank(_guardian);
    _dvp.pause();
    vm.prank(_recovery);
    _dvp.unpause();
    assertFalse(_dvp.paused());
  }

  function test_WhenAStrangerOrTheGuardianUnpauses_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _dvp.DEFAULT_ADMIN_ROLE()));
    vm.prank(_stranger);
    _dvp.unpause();
    vm.expectRevert(_unauthorized(_guardian, _dvp.DEFAULT_ADMIN_ROLE()));
    vm.prank(_guardian);
    _dvp.unpause();
  }

  function test_WhenRecoveryRevokesTheGuardian_ItWorks() external {
    bytes32 _guardianRole = _dvp.GUARDIAN_ROLE();
    vm.prank(_recovery);
    _dvp.revokeRole(_guardianRole, _guardian);
    assertFalse(_dvp.hasRole(_guardianRole, _guardian));
  }

  function test_WhenRecoveryTouchesAnyOtherRole_ItReverts() external {
    bytes32 _adminRole = _dvp.DEFAULT_ADMIN_ROLE();
    bytes32 _operatorRole = _dvp.OPERATOR_ROLE();
    bytes32 _guardianRole = _dvp.GUARDIAN_ROLE();
    vm.startPrank(_recovery);
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    _dvp.revokeRole(_operatorRole, _operator);
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    _dvp.grantRole(_guardianRole, _recovery);
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    _dvp.grantRole(_operatorRole, _recovery);
    vm.stopPrank();
  }
}

/**
 * @notice Integration: a real security token under identity, lockup, settlement window and holder cap, a real gated
 *         cash token, and a USDC-shaped ERC-3009 cash token, settled through the real executor
 */
contract DvPExecutorIntegrationTest is RuleSetIntegrationTest {
  uint256 internal constant _SHARES = 10 ether;
  uint256 internal constant _CASH = 500e6;

  DvPExecutor internal _dvp;
  IntentToken internal _cashToken;
  MockERC3009Token internal _usdc;
  address internal _operator = makeAddr('operator');
  address internal _buyer;
  uint256 internal _buyerPk;

  struct Trade {
    ITransferIntent.TransferIntent s;
    bytes sSig;
    ITransferIntent.TransferIntent c;
    bytes cSig;
  }

  function setUp() public virtual override {
    super.setUp(); // Monday 10:00; alice holds 1000 ether of the security under identity, lockup, window, cap
    (_buyer, _buyerPk) = makeAddrAndKey('buyer');
    _identity.set(_buyer, true);

    _deployCashToken();
    _usdc = new MockERC3009Token();
    _dvp = new DvPExecutor(_admin, _guardian);

    vm.startPrank(_admin);
    _dvp.grantRole(_dvp.OPERATOR_ROLE(), _operator);
    _token.grantRole(_token.EXECUTOR_ROLE(), address(_dvp));
    _cashToken.grantRole(_cashToken.EXECUTOR_ROLE(), address(_dvp));
    _cashToken.grantRole(_cashToken.MINTER_ROLE(), _minter);
    vm.stopPrank();

    vm.prank(_minter);
    _cashToken.mint(_buyer, 1000e6);
    _usdc.mint(_buyer, 1000e6);
  }

  /// @dev A second token, bound to its own identity-only hook, deployed as the first one is
  function _deployCashToken() internal {
    IntentToken _cashImpl = new IntentToken();
    vm.prank(_attester);
    _registry.attest(address(_cashImpl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    ProxyDeployer _proxyDeployer = new ProxyDeployer(address(this));
    address _predicted = _proxyDeployer.predict('GUSD', address(_cashImpl));
    ComplianceHook _cashHook = new ComplianceHook(_admin, _registry, _predicted, _one(_identityRule));
    vm.prank(_attester);
    _registry.attest(address(_cashHook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _cashToken = IntentToken(
      _proxyDeployer.deploy(
        'GUSD',
        address(_cashImpl),
        abi.encodeCall(
          IntentToken.initialize, ('Gated USD', 'GUSD', _admin, _guardian, address(_registry), address(_cashHook))
        ),
        address(_cashHook)
      )
    );
  }

  function _sign(
    uint256 _pk,
    bytes32 _digest
  ) internal pure returns (bytes memory _sig) {
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_pk, _digest);
    _sig = abi.encodePacked(_r, _s, _v);
  }

  function _securitiesIntent(
    uint256 _amount,
    uint256 _cashAmount,
    address _cashAddress,
    bytes32 _nonce
  ) internal view returns (ITransferIntent.TransferIntent memory _i, bytes memory _sig) {
    _i = ITransferIntent.TransferIntent({
      from: _alice,
      to: _buyer,
      amount: _amount,
      nonce: _nonce,
      deadline: block.timestamp + 30 days,
      ref: bytes32('ISO20022:SESE-1'),
      executor: address(_dvp),
      validAfter: 0,
      considerationToken: _cashAddress,
      considerationAmount: _cashAmount
    });
    _sig = _sign(_alicePk, _token.intentHash(_i));
  }

  function _cashIntent(
    uint256 _cashAmount,
    uint256 _amount,
    bytes32 _nonce
  ) internal view returns (ITransferIntent.TransferIntent memory _i, bytes memory _sig) {
    _i = ITransferIntent.TransferIntent({
      from: _buyer,
      to: _alice,
      amount: _cashAmount,
      nonce: _nonce,
      deadline: block.timestamp + 30 days,
      ref: bytes32('ISO20022:PACS-1'),
      executor: address(_dvp),
      validAfter: 0,
      considerationToken: address(_token),
      considerationAmount: _amount
    });
    _sig = _sign(_buyerPk, _cashToken.intentHash(_i));
  }

  function _gatedTrade(
    uint256 _amount,
    uint256 _cashAmount
  ) internal view returns (Trade memory _t) {
    (_t.s, _t.sSig) = _securitiesIntent(_amount, _cashAmount, address(_cashToken), keccak256('sNonce'));
    (_t.c, _t.cSig) = _cashIntent(_cashAmount, _amount, keccak256('cNonce'));
  }

  function _runGated(
    Trade memory _t
  ) internal returns (bytes32 _hash) {
    vm.prank(_operator);
    _hash = _dvp.executeDvPGated(address(_token), address(_cashToken), _t.s, _t.sSig, _t.c, _t.cSig);
  }

  function _legFailed(
    IDvPExecutor.Leg _leg,
    bytes32 _reason
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IDvPExecutor.DvPExecutor_LegFailed.selector, _leg, _rejected(_reason));
  }

  /// @dev Pre-flight and the real call must agree, and a refusal must name the right leg
  function _assertGatedParity(
    Trade memory _t,
    bytes32 _expected,
    IDvPExecutor.Leg _leg
  ) internal {
    (bool _ok, bytes32 _reason) =
      _dvp.canExecuteDvPGated(address(_token), address(_cashToken), _t.s, _t.sSig, _t.c, _t.cSig);
    assertEq(_reason, _expected, 'pre-flight reason');
    assertEq(_ok, _expected == Reasons.TRANSFER_OK);
    if (_expected != Reasons.TRANSFER_OK) vm.expectRevert(_legFailed(_leg, _expected));
    _runGated(_t);
  }

  // ---- ERC-3009 helpers --------------------------------------------------------------------------------------------

  function _authorization(
    ITransferIntent.TransferIntent memory _s,
    uint256 _value
  ) internal view returns (IDvPExecutor.Authorization memory _a) {
    _a = IDvPExecutor.Authorization({
      from: _buyer,
      value: _value,
      validAfter: 0,
      validBefore: block.timestamp + 1 days,
      nonce: keccak256(abi.encode(address(_token), _token.intentHash(_s))),
      signature: ''
    });
    _a.signature = _signAuthorization(_usdc, _a);
  }

  function _signAuthorization(
    MockERC3009Token _cashUsd,
    IDvPExecutor.Authorization memory _a
  ) internal view returns (bytes memory _sig) {
    _sig = _signAuthorizationAs(_buyerPk, _cashUsd, _a);
  }

  function _signAuthorizationAs(
    uint256 _pk,
    MockERC3009Token _cashUsd,
    IDvPExecutor.Authorization memory _a
  ) internal view returns (bytes memory _sig) {
    (, string memory _name, string memory _version, uint256 _chainId, address _verifying,,) = _cashUsd.eip712Domain();
    bytes32 _domain = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
        keccak256(bytes(_name)),
        keccak256(bytes(_version)),
        _chainId,
        _verifying
      )
    );
    bytes32 _struct = keccak256(
      abi.encode(
        _cashUsd.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
        _a.from,
        address(_dvp),
        _a.value,
        _a.validAfter,
        _a.validBefore,
        _a.nonce
      )
    );
    _sig = _sign(_pk, keccak256(abi.encodePacked('\x19\x01', _domain, _struct)));
  }

  function _run3009(
    ITransferIntent.TransferIntent memory _s,
    bytes memory _sSig,
    IDvPExecutor.Authorization memory _a
  ) internal returns (bytes32 _hash) {
    vm.prank(_operator);
    _hash = _dvp.executeDvP3009(address(_token), address(_usdc), _s, _sSig, _a);
  }

  function _lock(
    address _holder
  ) internal {
    vm.prank(_agent);
    _lockupRule.setLockup(address(_token), _holder, block.timestamp + 90 days);
  }
}

contract DvPExecutorIntegration_Gated is DvPExecutorIntegrationTest {
  function test_WhenTheLegsMirror_SharesAndCashMoveInOneTransactionAndTheExecutorKeepsNothing() external {
    Trade memory _t = _gatedTrade(_SHARES, _CASH);
    _assertGatedParity(_t, Reasons.TRANSFER_OK, IDvPExecutor.Leg.CASH);

    assertEq(_token.balanceOf(_buyer), _SHARES);
    assertEq(_token.balanceOf(_alice), 1000 ether - _SHARES);
    assertEq(_cashToken.balanceOf(_alice), _CASH);
    assertEq(_cashToken.balanceOf(_buyer), 1000e6 - _CASH);
    assertEq(_token.balanceOf(address(_dvp)), 0);
    assertEq(_cashToken.balanceOf(address(_dvp)), 0);
    assertTrue(_token.nonceUsed(_alice, _t.s.nonce));
    assertTrue(_cashToken.nonceUsed(_buyer, _t.c.nonce));
  }

  function test_WhenTheSecuritiesLegIsLocked_NothingMovesAndNoNonceIsSpent() external {
    _lock(_alice);
    Trade memory _t = _gatedTrade(_SHARES, _CASH);
    _assertGatedParity(_t, Reasons.LOCKED, IDvPExecutor.Leg.SECURITIES);

    assertEq(_cashToken.balanceOf(_buyer), 1000e6, 'the cash leg ran first and was undone');
    assertEq(_cashToken.balanceOf(_alice), 0);
    assertEq(_token.balanceOf(_buyer), 0);
    assertFalse(_cashToken.nonceUsed(_buyer, _t.c.nonce));
    assertFalse(_token.nonceUsed(_alice, _t.s.nonce));
  }

  function test_WhenTheBuyerCannotPay_NoSharesMove() external {
    Trade memory _t = _gatedTrade(_SHARES, 1001e6);
    _assertGatedParity(_t, Reasons.INSUFFICIENT_UNFROZEN, IDvPExecutor.Leg.CASH);
    assertEq(_token.balanceOf(_alice), 1000 ether);
    assertEq(_token.balanceOf(_buyer), 0);
  }

  function test_WhenBothLegsWouldFail_TheCashLegIsReported() external {
    _lock(_alice);
    Trade memory _t = _gatedTrade(_SHARES, 1001e6);
    _assertGatedParity(_t, Reasons.INSUFFICIENT_UNFROZEN, IDvPExecutor.Leg.CASH);
  }

  function test_WhenOutsideTheSettlementWindow_TheTradeWaitsForTheNextOpening() external {
    vm.warp(_SATURDAY_10AM);
    Trade memory _t = _gatedTrade(_SHARES, _CASH);
    _assertGatedParity(_t, Reasons.OUTSIDE_SETTLEMENT_WINDOW, IDvPExecutor.Leg.SECURITIES);
    assertEq(_cashToken.balanceOf(_buyer), 1000e6);

    vm.warp(_MONDAY_10AM + 7 days);
    _assertGatedParity(_t, Reasons.TRANSFER_OK, IDvPExecutor.Leg.CASH);
    assertEq(_token.balanceOf(_buyer), _SHARES);
  }

  function test_WhenTheHolderCapIsFull_OnlyAWholeBalanceSaleToANewHolderIsAdmitted() external {
    vm.startPrank(_alice);
    _token.transfer(_treasury, 10 ether);
    _token.transfer(_carol, 10 ether);
    vm.stopPrank();
    assertEq(_maxHoldersRule.holderCount(address(_token)), 3);

    Trade memory _partial = _gatedTrade(_SHARES, _CASH);
    _assertGatedParity(_partial, Reasons.MAX_HOLDERS, IDvPExecutor.Leg.SECURITIES);

    // Alice sells everything she has: she leaves and the buyer joins, so the count does not grow.
    Trade memory _whole = _gatedTrade(_token.balanceOf(_alice), _CASH);
    _assertGatedParity(_whole, Reasons.TRANSFER_OK, IDvPExecutor.Leg.CASH);
    assertEq(_token.balanceOf(_alice), 0);
    assertEq(_maxHoldersRule.holderCount(address(_token)), 3);
  }

  /// @dev A trade between an account and itself passes the mirror: both legs are self-transfers, and both settle
  function test_WhenTheSellerIsAlsoTheBuyer_AGatedTradeSettlesToo() external {
    vm.prank(_minter);
    _cashToken.mint(_alice, _CASH);
    ITransferIntent.TransferIntent memory _s = ITransferIntent.TransferIntent({
      from: _alice,
      to: _alice,
      amount: _SHARES,
      nonce: keccak256('sNonce'),
      deadline: block.timestamp + 30 days,
      ref: bytes32(0),
      executor: address(_dvp),
      validAfter: 0,
      considerationToken: address(_cashToken),
      considerationAmount: _CASH
    });
    ITransferIntent.TransferIntent memory _c = ITransferIntent.TransferIntent({
      from: _alice,
      to: _alice,
      amount: _CASH,
      nonce: keccak256('cNonce'),
      deadline: block.timestamp + 30 days,
      ref: bytes32(0),
      executor: address(_dvp),
      validAfter: 0,
      considerationToken: address(_token),
      considerationAmount: _SHARES
    });
    Trade memory _t = Trade({
      s: _s, sSig: _sign(_alicePk, _token.intentHash(_s)), c: _c, cSig: _sign(_alicePk, _cashToken.intentHash(_c))
    });
    _assertGatedParity(_t, Reasons.TRANSFER_OK, IDvPExecutor.Leg.CASH);
    assertEq(_token.balanceOf(_alice), 1000 ether);
    assertEq(_cashToken.balanceOf(_alice), _CASH);
  }

  function test_WhenTheSellerCancels_TheTradeFailsAndTheBuyerKeepsTheCash() external {
    Trade memory _t = _gatedTrade(_SHARES, _CASH);
    vm.prank(_alice);
    _token.cancelIntent(_t.s.nonce);
    _assertGatedParity(_t, Reasons.NONCE_USED, IDvPExecutor.Leg.SECURITIES);
    assertEq(_cashToken.balanceOf(_buyer), 1000e6);
  }

  function test_WhenTheBuyerCancels_TheTradeFailsBeforeTheSharesMove() external {
    Trade memory _t = _gatedTrade(_SHARES, _CASH);
    vm.prank(_buyer);
    _cashToken.cancelIntent(_t.c.nonce);
    _assertGatedParity(_t, Reasons.NONCE_USED, IDvPExecutor.Leg.CASH);
    assertEq(_token.balanceOf(_alice), 1000 ether);
  }

  function test_WhenTheLegsDoNotMirror_ItRevertsWithoutMovingAnything() external {
    (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) =
      _securitiesIntent(_SHARES, _CASH, address(_cashToken), keccak256('sNonce'));
    // The buyer signed a lower price than the seller asks.
    (ITransferIntent.TransferIntent memory _c, bytes memory _cSig) = _cashIntent(400e6, _SHARES, keccak256('cNonce'));
    (bool _ok, bytes32 _reason) = _dvp.canExecuteDvPGated(address(_token), address(_cashToken), _s, _sSig, _c, _cSig);
    assertFalse(_ok);
    assertEq(_reason, Reasons.LEGS_DO_NOT_MATCH);
    vm.expectRevert(IDvPExecutor.DvPExecutor_LegsDoNotMatch.selector);
    vm.prank(_operator);
    _dvp.executeDvPGated(address(_token), address(_cashToken), _s, _sSig, _c, _cSig);
  }

  function test_WhenTheSecuritiesIntentNamesAnotherExecutor_TheTokenRefusesIt() external {
    Trade memory _t = _gatedTrade(_SHARES, _CASH);
    _t.s.executor = makeAddr('someOtherExecutor');
    _t.sSig = _sign(_alicePk, _token.intentHash(_t.s));
    _assertGatedParity(_t, Reasons.WRONG_EXECUTOR, IDvPExecutor.Leg.SECURITIES);
    assertEq(_cashToken.balanceOf(_buyer), 1000e6);
  }

  function test_WhenTheSecuritiesIntentStatesAPaymentButNamesNoExecutor_TheTokenRefusesIt() external {
    Trade memory _t = _gatedTrade(_SHARES, _CASH);
    _t.s.executor = address(0);
    _t.sSig = _sign(_alicePk, _token.intentHash(_t.s));
    _assertGatedParity(_t, Reasons.CONSIDERATION_NEEDS_EXECUTOR, IDvPExecutor.Leg.SECURITIES);
  }

  function test_WhenTheExecutorIsPaused_ItRevertsAndPreflightSaysPaused() external {
    Trade memory _t = _gatedTrade(_SHARES, _CASH);
    vm.prank(_guardian);
    _dvp.pause();
    (bool _ok, bytes32 _reason) =
      _dvp.canExecuteDvPGated(address(_token), address(_cashToken), _t.s, _t.sSig, _t.c, _t.cSig);
    assertFalse(_ok);
    assertEq(_reason, Reasons.PAUSED);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    _runGated(_t);
  }

  function test_WhenTheTradeSettled_ItCannotSettleTwice() external {
    Trade memory _t = _gatedTrade(_SHARES, _CASH);
    _runGated(_t);
    vm.expectRevert(_legFailed(IDvPExecutor.Leg.CASH, Reasons.NONCE_USED));
    _runGated(_t);
  }

  function test_WhenTheTokenRevokesTheExecutor_TheTradeFails() external {
    Trade memory _t = _gatedTrade(_SHARES, _CASH);
    bytes32 _role = _token.EXECUTOR_ROLE();
    vm.prank(_admin);
    _token.revokeRole(_role, address(_dvp));

    // Pre-flight does not check the executor's role on the tokens: the tokens' own `canExecute` does not either.
    (bool _ok, bytes32 _reason) =
      _dvp.canExecuteDvPGated(address(_token), address(_cashToken), _t.s, _t.sSig, _t.c, _t.cSig);
    assertTrue(_ok);
    assertEq(_reason, Reasons.TRANSFER_OK);

    vm.expectRevert(
      abi.encodeWithSelector(
        IDvPExecutor.DvPExecutor_LegFailed.selector,
        IDvPExecutor.Leg.SECURITIES,
        abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(_dvp), _role)
      )
    );
    _runGated(_t);
    assertEq(_cashToken.balanceOf(_buyer), 1000e6);
  }
}

contract DvPExecutorIntegration_Authorization is DvPExecutorIntegrationTest {
  function _trade3009() internal view returns (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) {
    (_s, _sSig) = _securitiesIntent(_SHARES, _CASH, address(_usdc), keccak256('sNonce'));
  }

  /// @dev A seller who is also the buyer: the cash leaves the account and returns to it. Pre-flight says yes, so the
  ///      trade has to settle
  function test_WhenTheSellerIsAlsoTheBuyer_PreflightSaysYesAndTheTradeSettles() external {
    _usdc.mint(_alice, _CASH);
    (ITransferIntent.TransferIntent memory _s,) = _trade3009();
    _s.to = _alice;
    bytes memory _sSig = _sign(_alicePk, _token.intentHash(_s));
    IDvPExecutor.Authorization memory _a = IDvPExecutor.Authorization({
      from: _alice,
      value: _CASH,
      validAfter: 0,
      validBefore: block.timestamp + 1 days,
      nonce: keccak256(abi.encode(address(_token), _token.intentHash(_s))),
      signature: ''
    });
    _a.signature = _signAuthorizationAs(_alicePk, _usdc, _a);

    (bool _ok, bytes32 _reason) = _dvp.canExecuteDvP3009(address(_token), address(_usdc), _s, _sSig, _a);
    assertTrue(_ok);
    assertEq(_reason, Reasons.TRANSFER_OK);

    _run3009(_s, _sSig, _a);
    assertEq(_usdc.balanceOf(_alice), _CASH, 'the cash went out and came back');
    assertEq(_token.balanceOf(_alice), 1000 ether);
    assertEq(_usdc.balanceOf(address(_dvp)), 0);
    assertTrue(_usdc.authorizationState(_alice, _a.nonce));
  }

  function test_WhenTheAuthorizationMatches_SharesAndCashMoveAndTheExecutorKeepsNothing() external {
    (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) = _trade3009();
    IDvPExecutor.Authorization memory _a = _authorization(_s, _CASH);

    (bool _ok, bytes32 _reason) = _dvp.canExecuteDvP3009(address(_token), address(_usdc), _s, _sSig, _a);
    assertTrue(_ok);
    assertEq(_reason, Reasons.TRANSFER_OK);

    assertEq(_run3009(_s, _sSig, _a), _token.intentHash(_s));
    assertEq(_token.balanceOf(_buyer), _SHARES);
    assertEq(_usdc.balanceOf(_alice), _CASH);
    assertEq(_usdc.balanceOf(_buyer), 1000e6 - _CASH);
    assertEq(_usdc.balanceOf(address(_dvp)), 0);
    assertTrue(_usdc.authorizationState(_buyer, _a.nonce));
  }

  function test_WhenTheSecuritiesLegIsLocked_NothingMovesAndTheAuthorizationStaysUnused() external {
    _lock(_alice);
    (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) = _trade3009();
    IDvPExecutor.Authorization memory _a = _authorization(_s, _CASH);

    (bool _ok, bytes32 _reason) = _dvp.canExecuteDvP3009(address(_token), address(_usdc), _s, _sSig, _a);
    assertFalse(_ok);
    assertEq(_reason, Reasons.LOCKED);

    vm.expectRevert(_legFailed(IDvPExecutor.Leg.SECURITIES, Reasons.LOCKED));
    _run3009(_s, _sSig, _a);
    assertEq(_usdc.balanceOf(_buyer), 1000e6);
    assertFalse(_usdc.authorizationState(_buyer, _a.nonce));
  }

  function test_WhenTheAuthorizationBelongsToAnotherIntent_ItRevertsWithoutMovingCash() external {
    (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) = _trade3009();
    (ITransferIntent.TransferIntent memory _other,) =
      _securitiesIntent(_SHARES, _CASH, address(_usdc), keccak256('anotherNonce'));
    IDvPExecutor.Authorization memory _a = _authorization(_other, _CASH);

    vm.expectRevert(IDvPExecutor.DvPExecutor_LegsDoNotMatch.selector);
    _run3009(_s, _sSig, _a);
    assertEq(_usdc.balanceOf(_buyer), 1000e6);
  }

  function test_WhenTheAuthorizationPaysLessThanTheStatedConsideration_ItRevertsWithoutMovingCash() external {
    (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) = _trade3009();
    IDvPExecutor.Authorization memory _a = _authorization(_s, _CASH - 1);
    vm.expectRevert(IDvPExecutor.DvPExecutor_LegsDoNotMatch.selector);
    _run3009(_s, _sSig, _a);
    assertEq(_usdc.balanceOf(_buyer), 1000e6);
  }

  /// @dev The attack this nonce form closes. Were the nonce the bare intent hash, an operator could pair the buyer's
  ///      genuine authorization with a counterfeit security token that reports that hash and delivers nothing, and pay
  ///      the buyer's cash to an account of its own
  function test_WhenAnOperatorSubstitutesACounterfeitSecurityToken_TheAuthorizationIsRefused() external {
    (ITransferIntent.TransferIntent memory _s,) = _trade3009();
    // What the buyer would have signed if the nonce were the bare intent hash.
    IDvPExecutor.Authorization memory _a = _authorization(_s, _CASH);
    _a.nonce = _token.intentHash(_s);
    _a.signature = _signAuthorization(_usdc, _a);

    MockFakeSecurityToken _fake = new MockFakeSecurityToken();
    _fake.setHash(_token.intentHash(_s)); // the genuine hash, which anyone can compute

    // The operator's own account takes the seller's place and receives the cash.
    ITransferIntent.TransferIntent memory _own = _s;
    _own.from = _operator;
    vm.expectRevert(IDvPExecutor.DvPExecutor_LegsDoNotMatch.selector);
    vm.prank(_operator);
    _dvp.executeDvP3009(address(_fake), address(_usdc), _own, '', _a);
    assertEq(_usdc.balanceOf(_buyer), 1000e6);
    assertEq(_usdc.balanceOf(_operator), 0);
  }

  function test_WhenTheAuthorizationWasAlreadyUsed_TheTradeFails() external {
    (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) = _trade3009();
    IDvPExecutor.Authorization memory _a = _authorization(_s, _CASH);
    _run3009(_s, _sSig, _a);

    (bool _ok, bytes32 _reason) = _dvp.canExecuteDvP3009(address(_token), address(_usdc), _s, _sSig, _a);
    assertFalse(_ok);
    assertEq(_reason, Reasons.NONCE_USED, 'pre-flight sees the used authorization');
    vm.expectRevert();
    _run3009(_s, _sSig, _a);
  }

  /// @dev The intent's deadline is inclusive and Circle's `validBefore` is exclusive. A buyer who signs the authorization
  ///      with `validBefore` equal to the intent's deadline loses the intent's last second: the trade reverts as a whole
  function test_WhenTheAuthorizationEndsOnTheIntentDeadline_TheIntentsLastSecondIsLost() external {
    uint256 _deadline = block.timestamp + 100;
    (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) = _trade3009();
    _s.deadline = _deadline;
    _sSig = _sign(_alicePk, _token.intentHash(_s));
    IDvPExecutor.Authorization memory _a = _authorization(_s, _CASH);
    _a.validBefore = _deadline;
    _a.signature = _signAuthorization(_usdc, _a);

    vm.warp(_deadline);
    assertEq(_token.nonceUsed(_alice, _s.nonce), false);
    (bool _ok, bytes32 _reason) = _dvp.canExecuteDvP3009(address(_token), address(_usdc), _s, _sSig, _a);
    assertFalse(_ok);
    assertEq(_reason, Reasons.INTENT_EXPIRED, 'the authorization has ended while the intent is still valid');
    vm.expectRevert(
      abi.encodeWithSelector(
        IDvPExecutor.DvPExecutor_LegFailed.selector,
        IDvPExecutor.Leg.CASH,
        abi.encodeWithSignature('Error(string)', 'MockERC3009: authorization is expired')
      )
    );
    _run3009(_s, _sSig, _a);
    assertEq(_token.balanceOf(_buyer), 0);

    vm.warp(_deadline - 1);
    _run3009(_s, _sSig, _a);
    assertEq(_token.balanceOf(_buyer), _SHARES);
  }

  function test_WhenTheAuthorizationEndsOneSecondAfterTheIntentDeadline_TheTradeSettlesOnTheDeadline() external {
    uint256 _deadline = block.timestamp + 100;
    (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) = _trade3009();
    _s.deadline = _deadline;
    _sSig = _sign(_alicePk, _token.intentHash(_s));
    IDvPExecutor.Authorization memory _a = _authorization(_s, _CASH);
    _a.validBefore = _deadline + 1;
    _a.signature = _signAuthorization(_usdc, _a);

    vm.warp(_deadline);
    (bool _ok,) = _dvp.canExecuteDvP3009(address(_token), address(_usdc), _s, _sSig, _a);
    assertTrue(_ok);
    _run3009(_s, _sSig, _a);
    assertEq(_token.balanceOf(_buyer), _SHARES);
  }

  function test_WhenTheCashTokenTakesAFee_TheTradeRevertsAndKeepsEverything() external {
    (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) = _trade3009();
    IDvPExecutor.Authorization memory _a = _authorization(_s, _CASH);
    _usdc.setFeeBps(100);
    // The pull delivers 495e6 after the fee. The payout burns its own 5e6 fee first, leaving 490e6 for a 495e6 transfer.
    vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(_dvp), 490e6, 495e6));
    _run3009(_s, _sSig, _a);
    assertEq(_token.balanceOf(_buyer), 0);
  }

  function test_WhenAStrayBalanceHidesTheShortfall_TheConservationCheckStillCatchesTheFee() external {
    (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) = _trade3009();
    IDvPExecutor.Authorization memory _a = _authorization(_s, _CASH);
    _usdc.mint(address(_dvp), 10e6); // a donation lets the payout succeed
    _usdc.setFeeBps(100);
    // The executor receives 495e6 and pays 500e6 out, so it ends 5e6 short of the 10e6 it started with.
    vm.expectRevert(
      abi.encodeWithSelector(IDvPExecutor.DvPExecutor_CashNotConserved.selector, address(_dvp), 10e6, 5e6)
    );
    _run3009(_s, _sSig, _a);
  }

  function test_WhenTheTradeSettles_TheExecutorBalanceIsExactlyWhatWasDonated(
    uint256 _value,
    uint256 _donation
  ) external {
    _value = bound(_value, 1, 1000e6);
    _donation = bound(_donation, 0, 1e9);
    _usdc.mint(address(_dvp), _donation);
    (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) =
      _securitiesIntent(_SHARES, _value, address(_usdc), keccak256('sNonce'));
    IDvPExecutor.Authorization memory _a = _authorization(_s, _value);

    _run3009(_s, _sSig, _a);
    assertEq(_usdc.balanceOf(address(_dvp)), _donation);
    assertEq(_usdc.balanceOf(_alice), _value);
    assertEq(_token.balanceOf(address(_dvp)), 0);
  }
}

contract DvPExecutorIntegration_Reentrancy is DvPExecutorIntegrationTest {
  MockReentrantCashToken internal _evil;

  function setUp() public override {
    super.setUp();
    _evil = new MockReentrantCashToken();
    _evil.mint(_buyer, 1000e6);
    // The cash token may call back as an operator, so only the reentrancy guard stands in the way.
    bytes32 _role = _dvp.OPERATOR_ROLE();
    vm.prank(_admin);
    _dvp.grantRole(_role, address(_evil));
  }

  function _setup3009() internal returns (bytes memory _call) {
    (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) =
      _securitiesIntent(_SHARES, _CASH, address(_evil), keccak256('sNonce'));
    IDvPExecutor.Authorization memory _a = _authorization(_s, _CASH);
    _a.signature = _signAuthorization(_evil, _a);
    _call = abi.encodeCall(IDvPExecutor.executeDvP3009, (address(_token), address(_evil), _s, _sSig, _a));
  }

  /// @dev A low-level call with `vm.expectRevert` does not compare the revert data, so the data is compared here
  function _callAsOperator(
    bytes memory _call
  ) internal returns (bool _ok, bytes memory _returned) {
    vm.prank(_operator);
    (_ok, _returned) = address(_dvp).call(_call);
  }

  function test_WhenTheCashTokenReentersWhilePayingTheSeller_TheGuardStopsIt() external {
    bytes memory _call = _setup3009();
    // Let the pull through, call back during the payout.
    _evil.arm(address(_dvp), _call, 1);
    (bool _ok, bytes memory _returned) = _callAsOperator(_call);
    assertFalse(_ok);
    assertEq(_returned, abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));
    assertEq(_token.balanceOf(_buyer), 0, 'nothing settled');
  }

  function test_WhenTheCashTokenReentersWhilePullingTheCash_TheCashLegReportsTheGuard() external {
    bytes memory _call = _setup3009();
    _evil.arm(address(_dvp), _call, 0);
    (bool _ok, bytes memory _returned) = _callAsOperator(_call);
    assertFalse(_ok);
    assertEq(
      _returned,
      abi.encodeWithSelector(
        IDvPExecutor.DvPExecutor_LegFailed.selector,
        IDvPExecutor.Leg.CASH,
        abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
      )
    );
  }
}

contract DvPExecutorIntegration_ReentrancyGated is DvPExecutorIntegrationTest {
  function test_WhenAGatedCashTokenReentersTheExecutor_TheGuardStopsIt() external {
    MockReentrantGatedToken _evil = new MockReentrantGatedToken();
    bytes32 _role = _dvp.OPERATOR_ROLE();
    vm.prank(_admin);
    _dvp.grantRole(_role, address(_evil)); // only the reentrancy guard stands in the way

    (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) =
      _securitiesIntent(_SHARES, _CASH, address(_evil), keccak256('sNonce'));
    ITransferIntent.TransferIntent memory _c = ITransferIntent.TransferIntent({
      from: _buyer,
      to: _alice,
      amount: _CASH,
      nonce: keccak256('cNonce'),
      deadline: block.timestamp + 30 days,
      ref: bytes32(0),
      executor: address(_dvp),
      validAfter: 0,
      considerationToken: address(_token),
      considerationAmount: _SHARES
    });
    bytes memory _call =
      abi.encodeCall(IDvPExecutor.executeDvPGated, (address(_token), address(_evil), _s, _sSig, _c, ''));
    _evil.arm(address(_dvp), _call);

    vm.prank(_operator);
    (bool _ok, bytes memory _returned) = address(_dvp).call(_call);
    assertFalse(_ok);
    assertEq(
      _returned,
      abi.encodeWithSelector(
        IDvPExecutor.DvPExecutor_LegFailed.selector,
        IDvPExecutor.Leg.CASH,
        abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
      )
    );
  }
}

/// @notice The fund layer: the securities leg is EXECUTED, so the fund-wide investor cap applies to it unchanged
contract DvPExecutorFundIntegrationTest is FundIntegrationTest {
  uint256 internal constant _CASH = 500e6;

  DvPExecutor internal _dvp;
  IntentToken internal _cashToken;
  address internal _operator = makeAddr('operator');
  address internal _seller;
  uint256 internal _sellerPk;
  address internal _buyer;
  uint256 internal _buyerPk;

  function setUp() public virtual override {
    super.setUp();
    (_seller, _sellerPk) = makeAddrAndKey('seller');
    (_buyer, _buyerPk) = makeAddrAndKey('buyer');
    _identity.set(_seller, true);
    _identity.set(_buyer, true);

    _deployCashToken();
    _dvp = new DvPExecutor(address(this), _guardian);
    _dvp.grantRole(_dvp.OPERATOR_ROLE(), _operator);
    _token.grantRole(_token.EXECUTOR_ROLE(), address(_dvp));
    _cashToken.grantRole(_cashToken.EXECUTOR_ROLE(), address(_dvp));
    _cashToken.grantRole(_cashToken.MINTER_ROLE(), _minter);
    vm.prank(_minter);
    _cashToken.mint(_buyer, 1000e6);

    // The fund holds three investors, which is its cap: the seller, carol and dave.
    _mintToken(_seller, 10 ether);
    _mintToken(_carol, 1 ether);
    _mintToken(_dave, 1 ether);
    assertEq(_fund.holderCount(), 3);
    assertEq(_fund.holderCap(), 3);
  }

  function _deployCashToken() internal {
    address _cashImpl = address(new IntentToken());
    address _predicted = _deployer.predict('GUSD', _cashImpl);
    IComplianceRule[] memory _list = new IComplianceRule[](1);
    _list[0] = _identityRule;
    ComplianceHook _cashHook = new ComplianceHook(address(this), _registry, _predicted, _list);
    _registry.attest(address(_cashHook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _cashToken = IntentToken(
      _deployer.deploy(
        'GUSD',
        _cashImpl,
        abi.encodeCall(
          IntentToken.initialize,
          ('Gated USD', 'GUSD', address(this), _guardian, address(_registry), address(_cashHook))
        ),
        address(_cashHook)
      )
    );
  }

  function _sign(
    uint256 _pk,
    bytes32 _digest
  ) internal pure returns (bytes memory _sig) {
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_pk, _digest);
    _sig = abi.encodePacked(_r, _s, _v);
  }

  function _trade(
    address _to,
    uint256 _pkTo,
    uint256 _amount
  ) internal view returns (DvPExecutorIntegrationTest.Trade memory _t) {
    _t.s = ITransferIntent.TransferIntent({
      from: _seller,
      to: _to,
      amount: _amount,
      nonce: keccak256('sNonce'),
      deadline: block.timestamp + 30 days,
      ref: bytes32('ISO20022:SESE-1'),
      executor: address(_dvp),
      validAfter: 0,
      considerationToken: address(_cashToken),
      considerationAmount: _CASH
    });
    _t.sSig = _sign(_sellerPk, _token.intentHash(_t.s));
    _t.c = ITransferIntent.TransferIntent({
      from: _to,
      to: _seller,
      amount: _CASH,
      nonce: keccak256('cNonce'),
      deadline: block.timestamp + 30 days,
      ref: bytes32('ISO20022:PACS-1'),
      executor: address(_dvp),
      validAfter: 0,
      considerationToken: address(_token),
      considerationAmount: _amount
    });
    _t.cSig = _sign(_pkTo, _cashToken.intentHash(_t.c));
  }

  function _run(
    DvPExecutorIntegrationTest.Trade memory _t
  ) internal {
    vm.prank(_operator);
    _dvp.executeDvPGated(address(_token), address(_cashToken), _t.s, _t.sSig, _t.c, _t.cSig);
  }

  function _preflight(
    DvPExecutorIntegrationTest.Trade memory _t
  ) internal view returns (bytes32 _reason) {
    (, _reason) = _dvp.canExecuteDvPGated(address(_token), address(_cashToken), _t.s, _t.sSig, _t.c, _t.cSig);
  }
}

/// @notice Two intent-capable classes of one fund traded against each other, after the fund's cap was lowered below its
///         investor count. The first leg's movement changes the second leg's answer, which pre-flight cannot see
contract DvPExecutorFundIntegration_TwoClasses is DvPExecutorFundIntegrationTest {
  IntentToken internal _classTwo;

  function setUp() public override {
    super.setUp();
    address _impl = address(new IntentToken());
    address _predicted = _deployer.predict('gCLS2', _impl);
    IComplianceRule[] memory _list = new IComplianceRule[](2);
    _list[0] = _identityRule;
    _list[1] = _fundRule;
    ComplianceHook _hook = new ComplianceHook(address(this), _registry, _predicted, _list);
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _classTwo = IntentToken(
      _deployer.deploy(
        'gCLS2',
        _impl,
        abi.encodeCall(
          IntentToken.initialize, ('Class Two', 'gCLS2', address(this), _guardian, address(_registry), address(_hook))
        ),
        address(_hook)
      )
    );
    _fund.registerClass(address(_classTwo));
    _classTwo.grantRole(_classTwo.EXECUTOR_ROLE(), address(_dvp));
    _classTwo.grantRole(_classTwo.MINTER_ROLE(), _minter);
  }

  function test_WhenTheFundIsAboveItsLoweredCap_ASwapOfTwoClassesPassesPreflightAndFailsOnTheSecondLeg() external {
    // Five investors under a cap of five, then the cap is lowered to three: the fund can only shrink.
    _fund.setHolderCap(5);
    _mintToken(_buyer, 1 ether); // the buyer holds one class only, class 1
    _mintToken(_treasury, 1 ether);
    vm.prank(_minter);
    _classTwo.mint(_seller, 10 ether);
    assertEq(_fund.holderCount(), 5, 'seller, carol, dave, buyer and treasury');
    _fund.setHolderCap(3);

    // The buyer pays its whole class-1 position for the seller's class-2 shares: two legs, two classes.
    ITransferIntent.TransferIntent memory _s = ITransferIntent.TransferIntent({
      from: _seller,
      to: _buyer,
      amount: 10 ether,
      nonce: keccak256('sNonce'),
      deadline: block.timestamp + 30 days,
      ref: bytes32(0),
      executor: address(_dvp),
      validAfter: 0,
      considerationToken: address(_token),
      considerationAmount: 1 ether
    });
    ITransferIntent.TransferIntent memory _c = ITransferIntent.TransferIntent({
      from: _buyer,
      to: _seller,
      amount: 1 ether,
      nonce: keccak256('cNonce'),
      deadline: block.timestamp + 30 days,
      ref: bytes32(0),
      executor: address(_dvp),
      validAfter: 0,
      considerationToken: address(_classTwo),
      considerationAmount: 10 ether
    });
    bytes memory _sSig = _sign(_sellerPk, _classTwo.intentHash(_s));
    bytes memory _cSig = _sign(_buyerPk, _token.intentHash(_c));

    (bool _ok, bytes32 _reason) = _dvp.canExecuteDvPGated(address(_classTwo), address(_token), _s, _sSig, _c, _cSig);
    assertTrue(_ok, 'pre-flight asks each leg against the state before either has run');
    assertEq(_reason, Reasons.TRANSFER_OK);

    vm.expectRevert(
      abi.encodeWithSelector(
        IDvPExecutor.DvPExecutor_LegFailed.selector, IDvPExecutor.Leg.SECURITIES, _rejected(Reasons.MAX_HOLDERS)
      )
    );
    vm.prank(_operator);
    _dvp.executeDvPGated(address(_classTwo), address(_token), _s, _sSig, _c, _cSig);
    assertEq(_token.balanceOf(_buyer), 1 ether, 'the whole trade was undone');
  }
}

contract DvPExecutorFundIntegration_Cap is DvPExecutorFundIntegrationTest {
  function test_WhenTheFundIsFull_APartialSaleToANewInvestorIsRefusedAtTheSecuritiesLeg() external {
    DvPExecutorIntegrationTest.Trade memory _t = _trade(_buyer, _buyerPk, 4 ether);
    assertEq(_preflight(_t), Reasons.MAX_HOLDERS);
    vm.expectRevert(
      abi.encodeWithSelector(
        IDvPExecutor.DvPExecutor_LegFailed.selector, IDvPExecutor.Leg.SECURITIES, _rejected(Reasons.MAX_HOLDERS)
      )
    );
    _run(_t);
    assertEq(_cashToken.balanceOf(_buyer), 1000e6, 'the cash leg was undone');
    assertEq(_fund.holderCount(), 3);
  }

  function test_WhenTheFundIsFull_AWholeBalanceSaleToANewInvestorIsAdmittedBecauseTheCountDoesNotGrow() external {
    DvPExecutorIntegrationTest.Trade memory _t = _trade(_buyer, _buyerPk, 10 ether);
    assertEq(_preflight(_t), Reasons.TRANSFER_OK);
    _run(_t);
    assertEq(_token.balanceOf(_seller), 0);
    assertEq(_token.balanceOf(_buyer), 10 ether);
    assertEq(_cashToken.balanceOf(_seller), _CASH);
    assertEq(_fund.holderCount(), 3, 'the seller left and the buyer joined');
  }

  function test_WhenTheBuyerAlreadyInvests_APartialSaleIsAdmittedAtAFullFund() external {
    // Free a slot, then let the buyer in with a small position: the fund is full again, with the buyer among its own.
    vm.prank(_burner);
    _token.burn(_carol, 1 ether);
    _mintToken(_buyer, 1 ether);
    assertEq(_fund.holderCount(), 3);

    DvPExecutorIntegrationTest.Trade memory _t = _trade(_buyer, _buyerPk, 4 ether);
    assertEq(_preflight(_t), Reasons.TRANSFER_OK);
    _run(_t);
    assertEq(_token.balanceOf(_seller), 6 ether);
    assertEq(_token.balanceOf(_buyer), 5 ether);
    assertEq(_fund.holderCount(), 3);
  }
}
