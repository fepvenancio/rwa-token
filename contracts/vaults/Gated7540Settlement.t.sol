// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol';
import {Multicall} from '@openzeppelin/contracts/utils/Multicall.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IERC7540Deposit} from 'interfaces/IERC7540Deposit.sol';
import {IERC7540Redeem} from 'interfaces/IERC7540Redeem.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';

import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';
import {Gated7540VaultUnitTest} from 'contracts/vaults/Gated7540Vault.t.sol';

/// @notice The vault names one fixed second contract, and every implementation creates its own
contract Gated7540SettlementUnit_Wiring is Gated7540VaultUnitTest {
  function test_WhenQueried_TheVaultNamesContractCode() external view {
    address _logic = _vault.SETTLEMENT_LOGIC();
    assertGt(_logic.code.length, 0);
    assertNotEq(_logic, address(_vault));
  }

  function test_WhenTwoImplementationsAreDeployed_EachCreatesItsOwn() external {
    assertNotEq(new Gated7540Vault().SETTLEMENT_LOGIC(), new Gated7540Vault().SETTLEMENT_LOGIC());
  }
}

/// @notice Reached directly, the second contract has its own empty storage: nobody holds a role, and nothing can be done
contract Gated7540SettlementUnit_DirectCalls is Gated7540VaultUnitTest {
  Gated7540Vault internal _logic;

  function setUp() public override {
    super.setUp();
    _logic = Gated7540Vault(_vault.SETTLEMENT_LOGIC());
  }

  function test_WhenTheSettlerClosesAPeriodOnIt_ItReverts() external {
    vm.expectRevert(_noRole(_settler, _vault.SETTLER_ROLE()));
    vm.prank(_settler);
    _logic.closePeriod();
  }

  function test_WhenTheSettlerSettlesOnIt_ItReverts() external {
    vm.expectRevert(_noRole(_settler, _vault.SETTLER_ROLE()));
    vm.prank(_settler);
    _logic.settlePeriod(0, 0, _cash, address(0), type(uint256).max);
  }

  function test_WhenTheAgentRecoversClaimableOnIt_ItReverts() external {
    vm.expectRevert(_noRole(_agent, _vault.AGENT_ROLE()));
    vm.prank(_agent);
    _logic.recoverClaimable(_alice, _bob);
  }

  function test_WhenTheAgentRejectsOnIt_NothingIsPending() external {
    vm.startPrank(_agent);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _logic.rejectDepositRequest(_alice);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _logic.rejectRedeemRequest(_alice);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _logic.recoverRedeemRequest(_alice, _bob);
    vm.stopPrank();
  }

  function test_WhenTheVaultsAdminGrantsARoleOnIt_ItReverts() external {
    bytes32 _settlerRole = _vault.SETTLER_ROLE();
    vm.expectRevert(_noRole(_admin, bytes32(0)));
    vm.prank(_admin);
    _logic.grantRole(_settlerRole, _admin);
  }

  function test_WhenUpgradedDirectly_ItReverts() external {
    vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
    vm.prank(_admin);
    _logic.upgradeToAndCall(address(_vault), '');
  }

  function test_WhenAnInvestorCallsIt_TheFunctionIsNotThere() external {
    (bool _deposited,) = address(_logic).call(abi.encodeCall(IERC7540Deposit.requestDeposit, (1, _alice, _alice)));
    (bool _redeemed,) = address(_logic).call(abi.encodeCall(IERC7540Redeem.requestRedeem, (1, _alice, _alice)));
    assertFalse(_deposited);
    assertFalse(_redeemed);
  }
}

/// @notice Through the vault, a moved function acts on the vault: its storage, its events, its caller, its errors
contract Gated7540SettlementUnit_HandOff is Gated7540VaultUnitTest {
  function test_WhenAMovedFunctionRuns_TheEventComesFromTheVault() external {
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.PeriodClosed(1);
    vm.prank(_settler);
    _vault.closePeriod();
  }

  function test_WhenAMovedFunctionRuns_ItWritesTheVaultsStorage() external {
    vm.prank(_settler);
    _vault.closePeriod();
    (uint64 _open,,) = _vault.dealingState();
    assertEq(_open, 2);
  }

  function test_WhenCalledWithoutTheRole_TheErrorNamesTheCaller() external {
    vm.expectRevert(_noRole(_stranger, _vault.SETTLER_ROLE()));
    vm.prank(_stranger);
    _vault.closePeriod();
  }

  function test_WhenAMovedFunctionReverts_TheTypedErrorComesBack() external {
    vm.startPrank(_settler);
    _vault.closePeriod();
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_PeriodUnsettled.selector, 1));
    _vault.closePeriod();
    vm.stopPrank();
  }

  function test_WhenBatched_MovedFunctionsKeepTheCaller() external {
    _requestDeposit(_alice, 100);
    bytes[] memory _calls = new bytes[](2);
    _calls[0] = abi.encodeCall(IGated7540Vault.closePeriod, ());
    _calls[1] = abi.encodeCall(IGated7540Vault.settlePeriod, (0, 0, _cash, address(0), type(uint256).max));
    vm.prank(_settler);
    Multicall(address(_vault)).multicall(_calls);
    (, uint64 _settled,) = _vault.dealingState();
    assertEq(_settled, 1);
    assertEq(_vault.maxMint(_alice), 100 * _PAR);
  }

  function test_WhenASelectorIsUnknown_ItReverts() external {
    (bool _ok,) = address(_vault).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
    assertFalse(_ok);
  }
}

/// @notice An upgrade brings the new implementation's second contract and keeps the proxy's state
contract Gated7540SettlementUnit_Upgrade is Gated7540VaultUnitTest {
  /// @dev The ERC-7201 location of the vault's storage, and `books`' place in it
  uint256 internal constant _BOOKS_SLOT = 0x2cc225a2bfbd5a47b58fbfec984f4f856b2fa5e8b68081e6d3300ec76f5f3900 + 8;

  /// @dev A book written before `carried` existed has nothing in that word. A full fill writes nothing there either, so the
  ///      two read alike, and an upgrade in place cannot pay a settled redemption twice
  function test_WhenAPeriodIsFilledInFull_NothingIsWrittenAsCarried() external {
    _holdShares(_alice, 100);
    _requestRedeem(_alice, 100 * _PAR);
    _settleAtPar();
    (, uint64 _period,) = _vault.dealingState();
    bytes32 _book = keccak256(abi.encode(false, keccak256(abi.encode(uint256(_period), _BOOKS_SLOT))));
    assertEq(vm.load(address(_vault), bytes32(uint256(_book) + 1)), bytes32(0));
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);
    assertEq(_vault.maxRedeem(_alice), 100 * _PAR);
  }

  function test_WhenUpgradedOntoTheSecondContract_ItIsRefused() external {
    address _logic = _vault.SETTLEMENT_LOGIC();
    vm.mockCall(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (_logic, IPolicyRegistry.AttestKind.IMPLEMENTATION)),
      abi.encode(true)
    );
    vm.startPrank(_admin);
    _vault.grantRole(_vault.UPGRADER_ROLE(), _admin);
    vm.expectRevert(
      abi.encodeWithSelector(
        ITemplated.Templated_WrongTemplate.selector,
        _logic,
        keccak256('Gated7540Vault'),
        keccak256('Gated7540Settlement')
      )
    );
    _vault.upgradeToAndCall(_logic, '');
    vm.stopPrank();
  }

  function test_WhenUpgraded_TheNewLogicActsOnTheOldState() external {
    _requestDeposit(_alice, 100);
    _settleAtPar();
    address _before = _vault.SETTLEMENT_LOGIC();

    Gated7540Vault _impl = new Gated7540Vault();
    vm.mockCall(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (address(_impl), IPolicyRegistry.AttestKind.IMPLEMENTATION)),
      abi.encode(true)
    );
    vm.startPrank(_admin);
    _vault.grantRole(_vault.UPGRADER_ROLE(), _admin);
    _vault.upgradeToAndCall(address(_impl), '');
    vm.stopPrank();

    assertEq(_vault.SETTLEMENT_LOGIC(), _impl.SETTLEMENT_LOGIC());
    assertNotEq(_vault.SETTLEMENT_LOGIC(), _before);
    assertEq(_vault.maxMint(_alice), 100 * _PAR);

    _requestDeposit(_bob, 50);
    _settleAtPar();
    (, uint64 _settled,) = _vault.dealingState();
    assertEq(_settled, 2);
    assertEq(_vault.maxMint(_bob), 50 * _PAR);
    assertTrue(IAccessControl(address(_vault)).hasRole(_vault.SETTLER_ROLE(), _settler));
  }
}

/// @notice Two holders at par, 300 and 100 asset units' worth, whose redemptions a settlement takes only part of. Periods 1
///         and 2 made the holdings, so period 3 is the first to deal with redemptions
abstract contract Gated7540GateTest is Gated7540VaultUnitTest {
  uint256 internal constant _NO_LIMIT = type(uint256).max;

  function setUp() public virtual override {
    super.setUp();
    _holdShares(_alice, 300);
    _holdShares(_bob, 100);
  }

  /// @dev Closes the open period and settles it at par, taking at most `_limit`
  function _settleWithLimit(
    uint256 _limit
  ) internal {
    _settleAtValue(_supply() / _PAR, _limit);
  }

  function _settleAtValue(
    uint256 _nav,
    uint256 _limit
  ) internal {
    vm.startPrank(_settler);
    _vault.closePeriod();
    _vault.settlePeriod(_nav, 0, _cash, address(0), _limit);
    vm.stopPrank();
  }

  function _redeemAll(
    address _who
  ) internal {
    uint256 _shares = _vault.maxRedeem(_who);
    vm.prank(_who);
    _vault.redeem(_shares, _who, _who);
  }

  function _redemptionsPaid(
    uint256 _period
  ) internal view returns (uint256 _paid) {
    (_paid,,) = _vault.periodBook(_period, false);
  }
}

/// @notice A limit fills every request at one fraction, and only the part taken leaves
contract Gated7540SettlementUnit_PartFill is Gated7540GateTest {
  function setUp() public override {
    super.setUp();
    _requestRedeem(_alice, 300 * _PAR);
    _requestRedeem(_bob, 100 * _PAR);
  }

  function test_WhenLimited_EveryRequestFillsAtOneFraction() external {
    _settleWithLimit(100 * _PAR);
    assertEq(_vault.claimableRedeemRequest(0, _alice), 75 * _PAR);
    assertEq(_vault.claimableRedeemRequest(0, _bob), 25 * _PAR);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 225 * _PAR);
    assertEq(_vault.pendingRedeemRequest(0, _bob), 75 * _PAR);
    assertEq(_vault.maxRedeem(_alice), 75 * _PAR);
    assertEq(_vault.maxWithdraw(_alice), 75);
    assertEq(_vault.maxWithdraw(_bob), 25);
  }

  function test_WhenLimited_OnlyThePartTakenBurnsAndIsPaid() external {
    uint256 _before = _asset.balanceOf(_cash);
    _settleWithLimit(100 * _PAR);
    assertEq(_vault.totalSupply(), 300 * _PAR);
    assertEq(_vault.balanceOf(address(_vault)), 300 * _PAR);
    assertEq(_before - _asset.balanceOf(_cash), 100);
  }

  function test_WhenLimited_TheEventSaysWhatWasAskedAndWhatWasTaken() external {
    vm.startPrank(_settler);
    _vault.closePeriod();
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.PeriodSettled(3, 400, 400 * _PAR, 0, 0, 400 * _PAR, 100 * _PAR, 100, 0);
    _vault.settlePeriod(400, 0, _cash, address(0), 100 * _PAR);
    vm.stopPrank();
  }

  function test_WhenLimited_TheBooksSayWhatWasTakenAndWhatCarried() external {
    _settleWithLimit(100 * _PAR);
    (uint256 _paid, uint256 _owed, uint256 _carried) = _vault.periodBook(3, false);
    assertEq(_paid, 400 * _PAR);
    assertEq(_owed, 100);
    assertEq(_carried, 300 * _PAR);
    (_paid, _owed, _carried) = _vault.periodBook(4, false);
    assertEq(_paid, 300 * _PAR);
    assertEq(_owed, 0);
    assertEq(_carried, 0);
  }

  function test_WhenLimited_TheCarriedSharesStayOutOfAForcedTransfersReach() external {
    _settleWithLimit(100 * _PAR);
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ExceedsSurplus.selector, 1, 0));
    vm.prank(_agent);
    _vault.forcedTransfer(address(_vault), _alice, 1);
  }

  /// @dev The carried shares count in the next price, so they share the rise in value
  function test_TheCarriedPartDealsAtTheNextPeriodsPrice() external {
    _settleWithLimit(100 * _PAR);
    _settleAtValue(600, _NO_LIMIT);
    uint256 _second = Math.mulDiv(300 * _PAR, 601, 300 * _PAR + 1e6);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);
    assertEq(_vault.maxWithdraw(_alice), 75 + Math.mulDiv(225 * _PAR, _second, 300 * _PAR));
    assertEq(_vault.maxWithdraw(_bob), 25 + Math.mulDiv(75 * _PAR, _second, 300 * _PAR));
    assertEq(_vault.totalSupply(), 0);
  }

  function test_WhenTheLimitIsZero_NothingLeavesAndEverythingCarries() external {
    uint256 _before = _asset.balanceOf(_cash);
    _settleWithLimit(0);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 300 * _PAR);
    assertEq(_vault.claimableRedeemRequest(0, _alice), 0);
    assertEq(_vault.maxWithdraw(_alice), 0);
    assertEq(_vault.totalSupply(), 400 * _PAR);
    assertEq(_asset.balanceOf(_cash), _before);
    assertEq(_redemptionsPaid(4), 400 * _PAR);
  }

  function testFuzz_WhenTheLimitCoversTheBook_EveryRequestIsFilled(
    uint256 _limit
  ) external {
    _settleWithLimit(bound(_limit, 400 * _PAR, type(uint256).max));
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);
    assertEq(_vault.maxRedeem(_alice), 300 * _PAR);
    assertEq(_vault.maxRedeem(_bob), 100 * _PAR);
    assertEq(_vault.totalSupply(), 0);
    assertEq(_redemptionsPaid(4), 0);
    (,, uint256 _carried) = _vault.periodBook(3, false);
    assertEq(_carried, 0);
  }

  function test_WhenACarriedPartIsClaimedInStages_TheClaimsAddUp() external {
    _settleWithLimit(100 * _PAR);
    vm.prank(_alice);
    _vault.redeem(75 * _PAR, _alice, _alice);
    _settleWithLimit(100 * _PAR);
    _redeemAll(_alice);
    _settleWithLimit(_NO_LIMIT);
    _redeemAll(_alice);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);
    assertEq(_vault.maxRedeem(_alice), 0);
    assertEq(_asset.balanceOf(_alice), _FUNDS);
  }
}

/// @notice A controller that does nothing for several periods ends exactly where one that claims each time does
contract Gated7540SettlementUnit_Walk is Gated7540GateTest {
  function test_ADormantControllerEndsWhereAnActiveOneDoes() external {
    _requestRedeem(_alice, 100 * _PAR);
    _requestRedeem(_bob, 100 * _PAR);
    uint256 _before = _asset.balanceOf(_alice);

    _settleAtValue(431, 50 * _PAR);
    _redeemAll(_alice);
    assertEq(_vault.pendingRedeemRequest(0, _bob), _vault.pendingRedeemRequest(0, _alice));

    _settleAtValue(397, 40 * _PAR);
    _redeemAll(_alice);
    assertEq(_vault.pendingRedeemRequest(0, _bob), _vault.pendingRedeemRequest(0, _alice));

    _settleAtValue(413, _NO_LIMIT);
    _redeemAll(_alice);

    assertEq(_vault.pendingRedeemRequest(0, _bob), 0);
    assertEq(_vault.maxRedeem(_bob), 100 * _PAR);
    assertEq(_vault.maxWithdraw(_bob), _asset.balanceOf(_alice) - _before);
  }

  /// @dev Nothing written to storage between the settlements, so the views walk three periods
  function test_TheViewsSayWhatAWriteWouldStore() external {
    _requestRedeem(_alice, 100 * _PAR);
    _settleWithLimit(50 * _PAR);
    _settleWithLimit(25 * _PAR);
    _settleWithLimit(5 * _PAR);
    uint256 _pending = _vault.pendingRedeemRequest(0, _alice);
    uint256 _claimable = _vault.claimableRedeemRequest(0, _alice);
    assertEq(_pending, 20 * _PAR);
    assertEq(_claimable, 80 * _PAR);
    uint256 _assets = _vault.maxWithdraw(_alice);

    // The smallest write: claim one share unit's worth, then read again.
    vm.prank(_alice);
    uint256 _paid = _vault.withdraw(1, _alice, _alice);
    assertEq(_vault.pendingRedeemRequest(0, _alice), _pending);
    assertEq(_vault.claimableRedeemRequest(0, _alice), _claimable - _paid);
    assertEq(_vault.maxWithdraw(_alice), _assets - 1);
  }
}

/// @notice A carried part behaves as any pending request: it can be added to, handed back and recovered
contract Gated7540SettlementUnit_CarriedPart is Gated7540GateTest {
  /// @dev Alice 100 of her 300 and Bob 100 of his 100, half taken in period 3, so each carries 50 into period 4
  function setUp() public override {
    super.setUp();
    _requestRedeem(_alice, 100 * _PAR);
    _requestRedeem(_bob, 100 * _PAR);
    _settleWithLimit(100 * _PAR);
  }

  function test_ANewRequestJoinsACarriedPartInTheOpenPeriod() external {
    _requestRedeem(_alice, 100 * _PAR);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 150 * _PAR);
    assertEq(_redemptionsPaid(4), 200 * _PAR);
  }

  function test_ANewRequestWaitsWhileTheCarriedPartSitsInAClosedPeriod() external {
    vm.prank(_settler);
    _vault.closePeriod();
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_EarlierRequestUnsettled.selector, 4));
    _requestRedeem(_alice, 1);
  }

  function test_TheAgentCanHandBackACarriedPartWhileItsPeriodIsOpen() external {
    uint256 _before = _vault.balanceOf(_alice);
    vm.prank(_agent);
    _vault.rejectRedeemRequest(_alice);
    assertEq(_vault.balanceOf(_alice), _before + 50 * _PAR);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);
    assertEq(_vault.claimableRedeemRequest(0, _alice), 50 * _PAR, 'the part taken stays claimable');
    assertEq(_redemptionsPaid(4), 50 * _PAR);
  }

  function test_OnceTheCarriedPartsPeriodCloses_OnlyTheSettlerCanHandItBack() external {
    vm.prank(_settler);
    _vault.closePeriod();
    vm.expectRevert(_noRole(_agent, _vault.SETTLER_ROLE()));
    vm.prank(_agent);
    _vault.rejectRedeemRequest(_alice);
    vm.prank(_settler);
    _vault.rejectRedeemRequest(_alice);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);
    assertEq(_redemptionsPaid(4), 50 * _PAR);
  }

  function test_TheAgentCanRecoverACarriedPart() external {
    vm.prank(_agent);
    _vault.recoverRedeemRequest(_alice, _stranger);
    assertEq(_vault.balanceOf(_stranger), 50 * _PAR);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);
    assertEq(_redemptionsPaid(4), 50 * _PAR);
  }

  function test_AHandBackAfterAWalkTakesWhatIsStillPending() external {
    _settleWithLimit(50 * _PAR);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 25 * _PAR);
    uint256 _before = _vault.balanceOf(_alice);
    vm.prank(_agent);
    _vault.rejectRedeemRequest(_alice);
    assertEq(_vault.balanceOf(_alice), _before + 25 * _PAR);
    assertEq(_redemptionsPaid(5), 25 * _PAR);
  }

  function test_RecoveringClaimableLeavesACarriedPartAlone() external {
    vm.prank(_agent);
    _vault.recoverClaimable(_alice, _stranger);
    assertEq(_asset.balanceOf(_stranger), 50);
    assertEq(_vault.claimableRedeemRequest(0, _alice), 0);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 50 * _PAR);
    _settleWithLimit(_NO_LIMIT);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);
    assertEq(_vault.claimableRedeemRequest(0, _alice), 50 * _PAR);
  }
}

/// @notice Rounding: what is taken rounds up and what is owed rounds down, so no book and no cash balance can fall short
contract Gated7540SettlementUnit_Rounding is Gated7540VaultUnitTest {
  address[3] internal _controllers;

  function setUp() public override {
    super.setUp();
    _fund(_stranger);
    _controllers = [_alice, _bob, _stranger];
  }

  /// @dev Three holders at par, each asking to redeem a fuzzed amount of what it holds
  function _queue(
    uint256[3] memory _seeds
  ) internal returns (uint256 _book) {
    for (uint256 _i; _i < 3; ++_i) {
      _holdShares(_controllers[_i], 1_000_000);
    }
    for (uint256 _i; _i < 3; ++_i) {
      uint256 _shares = bound(_seeds[_i], 1, _vault.balanceOf(_controllers[_i]));
      _requestRedeem(_controllers[_i], _shares);
      _book += _shares;
    }
  }

  function _settleLimited(
    uint256 _nav,
    uint256 _limit
  ) internal returns (uint64 _period) {
    vm.startPrank(_settler);
    _vault.closePeriod();
    _vault.settlePeriod(_nav, 0, _cash, address(0), _limit);
    vm.stopPrank();
    (, _period,) = _vault.dealingState();
  }

  function _sums() internal view returns (uint256 _pending, uint256 _claimable, uint256 _owed) {
    for (uint256 _i; _i < 3; ++_i) {
      _pending += _vault.pendingRedeemRequest(0, _controllers[_i]);
      _claimable += _vault.claimableRedeemRequest(0, _controllers[_i]);
      _owed += _vault.maxWithdraw(_controllers[_i]);
    }
  }

  function _assertTheBooksHold(
    uint64 _period,
    uint256 _book,
    uint256 _taken
  ) internal view {
    (uint256 _pending, uint256 _claimable, uint256 _owed) = _sums();
    (uint256 _paid, uint256 _totalOwed, uint256 _bookCarried) = _vault.periodBook(_period, false);
    (uint256 _next,,) = _vault.periodBook(_period + 1, false);
    assertEq(_paid, _book);
    assertEq(_bookCarried, _book - _taken);
    assertEq(_next, _book - _taken);
    assertLe(_pending, _next);
    assertLe(_next - _pending, 2, 'at most one unit per controller after the first');
    assertGe(_claimable, _taken);
    assertLe(_claimable - _taken, 2);
    assertLe(_owed, _totalOwed);
  }

  function testFuzz_TheCarriedPartsNeverExceedTheNextBook(
    uint256[3] memory _seeds,
    uint256 _limit,
    uint256 _navSeed
  ) external {
    uint256 _book = _queue(_seeds);
    uint256 _nav = bound(_navSeed, _supply() / _PAR / 2, _supply() / _PAR * 2);
    uint256 _taken = bound(_limit, 0, _book);
    uint64 _period = _settleLimited(_nav, _taken);
    _assertTheBooksHold(_period, _book, _taken);
  }

  function testFuzz_ASecondRoundShrinksTheQueueByWhatItTakes(
    uint256[3] memory _seeds,
    uint256 _firstLimit,
    uint256 _secondLimit
  ) external {
    uint256 _book = _queue(_seeds);
    uint256 _nav = _supply() / _PAR;
    uint64 _period = _settleLimited(_nav, bound(_firstLimit, 0, _book));
    (uint256 _next,,) = _vault.periodBook(_period + 1, false);
    (uint256 _pendingBefore,,) = _sums();
    uint256 _taken = bound(_secondLimit, 0, _next);
    _period = _settleLimited(_nav, _taken);
    (uint256 _pending,,) = _sums();
    (uint256 _after,,) = _vault.periodBook(_period + 1, false);
    assertEq(_after, _next - _taken);
    assertLe(_pending, _after);
    assertLe(_pending, _pendingBefore);
  }

  function testFuzz_EveryCarriedPartCanBeHandedBack(
    uint256[3] memory _seeds,
    uint256 _limit
  ) external {
    uint256 _book = _queue(_seeds);
    uint64 _period = _settleLimited(_supply() / _PAR, bound(_limit, 0, _book));
    for (uint256 _i; _i < 3; ++_i) {
      if (_vault.pendingRedeemRequest(0, _controllers[_i]) == 0) continue;
      vm.prank(_agent);
      _vault.rejectRedeemRequest(_controllers[_i]);
    }
    (uint256 _left,,) = _vault.periodBook(_period + 1, false);
    assertLe(_left, 2, 'only what no controller owns');
    assertEq(_vault.balanceOf(address(_vault)), _left);
  }

  function testFuzz_TheVaultCanPayEveryClaimAfterAGate(
    uint256[3] memory _seeds,
    uint256 _firstLimit,
    uint256 _secondLimit,
    uint256 _navSeed
  ) external {
    uint256 _book = _queue(_seeds);
    uint256 _nav = bound(_navSeed, _supply() / _PAR / 2, _supply() / _PAR * 2);
    _settleLimited(_nav, bound(_firstLimit, 0, _book));
    _settleLimited(_nav, bound(_secondLimit, 0, _book));
    _settleLimited(_nav, type(uint256).max);
    for (uint256 _i; _i < 3; ++_i) {
      address _controller = _controllers[_i];
      assertEq(_vault.pendingRedeemRequest(0, _controller), 0);
      uint256 _shares = _vault.maxRedeem(_controller);
      if (_vault.maxWithdraw(_controller) == 0) continue;
      vm.prank(_controller);
      _vault.redeem(_shares, _controller, _controller);
      assertEq(_vault.maxRedeem(_controller), 0);
    }
  }
}
