// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC8473} from 'interfaces/IERC8473.sol';
import {IOrderSettlement} from 'interfaces/IOrderSettlement.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {Quals} from 'interfaces/Quals.sol';

import {OrderSettlement} from 'contracts/intents/OrderSettlement.sol';
import {Gated1155} from 'contracts/tokens/Gated1155.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';
import {IntentTokenAsCashTest} from 'contracts/tokens/IntentTokenAsCash.t.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';

/// @notice A token that keeps a tenth of every transfer, which no settlement here may accept
contract OrderSettlementFeeToken is ERC20 {
  constructor() ERC20('Fee', 'FEE') {}

  function mint(
    address _to,
    uint256 _amount
  ) external {
    _mint(_to, _amount);
  }

  function _update(
    address _from,
    address _to,
    uint256 _value
  ) internal override {
    if (_from != address(0) && _to != address(0)) {
      super._update(_from, address(0xdead), _value / 10);
      _value -= _value / 10;
    }
    super._update(_from, _to, _value);
  }
}

/// @notice A token that calls back into the executor while it is being moved
contract OrderSettlementReenteringToken is ERC20 {
  IOrderSettlement public immutable VENUE;

  constructor(
    IOrderSettlement _venue
  ) ERC20('Reenter', 'RE') {
    VENUE = _venue;
  }

  function mint(
    address _to,
    uint256 _amount
  ) external {
    _mint(_to, _amount);
  }

  function _update(
    address _from,
    address _to,
    uint256 _value
  ) internal override {
    if (_from != address(0)) VENUE.settle(new IOrderSettlement.Fill[](0));
    super._update(_from, _to, _value);
  }
}

/**
 * @notice The real executor on real tokens: a security and the cash token of `IntentTokenAsCashTest`, behind the real
 *         credential registry, rule and hook. The seller holds 100 of the security and sells for cash; the investor
 *         holds cash and buys. Both gave the executor an allowance
 */
contract OrderSettlementTest is IntentTokenAsCashTest {
  uint256 internal constant _UNIT = 1 ether;
  uint256 internal constant _PRICE = 50e6; // cash for one unit of the security

  OrderSettlement internal _venue;
  IntentToken internal _security;
  address internal _recovery = makeAddr('recoveryTimelock');

  function setUp() public virtual override {
    super.setUp();
    _venue = new OrderSettlement(address(this), _guardian);
    _venue.grantRole(_venue.OPERATOR_ROLE(), _relayer);
    _venue.grantRole(_venue.RECOVERY_ROLE(), _recovery);
    _security = _intentToken('SEC', 18, false);
    _security.grantRole(_security.MINTER_ROLE(), _minter);
    vm.prank(_minter);
    _security.mint(_seller, 100 * _UNIT);
    vm.prank(_seller);
    _security.approve(address(_venue), type(uint256).max);
    vm.prank(_investor);
    _cash.approve(address(_venue), type(uint256).max);
  }

  /// @dev The seller's order: gives `_units` of the security for at least `_units × _PRICE` of cash
  function _sell(
    uint256 _units
  ) internal view returns (IOrderSettlement.Order memory _o) {
    _o = IOrderSettlement.Order({
      maker: _seller,
      giveToken: address(_security),
      giveId: 0,
      giveAmount: _units * _UNIT,
      takeToken: address(_cash),
      takeId: 0,
      takeAmount: _units * _PRICE,
      giveIs1155: false,
      takeIs1155: false,
      taker: address(0),
      allOrNothing: false,
      nonce: keccak256('sell'),
      validAfter: 0,
      deadline: block.timestamp + 1 days
    });
  }

  /// @dev The investor's order: gives `_units × _PRICE` of cash for at least `_units` of the security
  function _buy(
    uint256 _units
  ) internal view returns (IOrderSettlement.Order memory _o) {
    _o = IOrderSettlement.Order({
      maker: _investor,
      giveToken: address(_cash),
      giveId: 0,
      giveAmount: _units * _PRICE,
      takeToken: address(_security),
      takeId: 0,
      takeAmount: _units * _UNIT,
      giveIs1155: false,
      takeIs1155: false,
      taker: address(0),
      allOrNothing: false,
      nonce: keccak256('buy'),
      validAfter: 0,
      deadline: block.timestamp + 1 days
    });
  }

  function _signOrder(
    uint256 _key,
    IOrderSettlement.Order memory _o
  ) internal view returns (bytes memory _sig) {
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_key, _venue.orderHash(_o));
    _sig = abi.encodePacked(_r, _s, _v);
  }

  /// @dev A fill of the seller's order against the investor's, both signed by their makers
  function _fill(
    IOrderSettlement.Order memory _first,
    IOrderSettlement.Order memory _second,
    uint256 _firstGives,
    uint256 _secondGives
  ) internal view returns (IOrderSettlement.Fill memory _f) {
    _f = IOrderSettlement.Fill({
      first: _first,
      firstSig: _signOrder(_first.maker == _seller ? _sellerKey : _investorKey, _first),
      second: _second,
      secondSig: _signOrder(_second.maker == _seller ? _sellerKey : _investorKey, _second),
      firstGives: _firstGives,
      secondGives: _secondGives
    });
  }

  function _one(
    IOrderSettlement.Fill memory _f
  ) internal pure returns (IOrderSettlement.Fill[] memory _fills) {
    _fills = new IOrderSettlement.Fill[](1);
    _fills[0] = _f;
  }

  function _settle(
    IOrderSettlement.Fill memory _f
  ) internal {
    vm.prank(_relayer);
    _venue.settle(_one(_f));
  }

  function _refused(
    uint256 _index,
    IOrderSettlement.Refusal _refusal,
    bool _secondOrder
  ) internal pure returns (bytes memory _data) {
    _data =
      abi.encodeWithSelector(IOrderSettlement.OrderSettlement_FillRefused.selector, _index, _refusal, _secondOrder);
  }

  /// @dev The fill is refused by `settle` with this refusal, and `canFill` says the same
  function _expectRefused(
    IOrderSettlement.Fill memory _f,
    IOrderSettlement.Refusal _refusal,
    bool _secondOrder
  ) internal {
    (IOrderSettlement.Refusal _seen, bool _second,) = _venue.canFill(_f);
    assertEq(uint256(_seen), uint256(_refusal), 'canFill refusal');
    assertEq(_second, _secondOrder, 'canFill order');
    vm.expectRevert(_refused(0, _refusal, _secondOrder));
    vm.prank(_relayer);
    _venue.settle(_one(_f));
  }
}

contract OrderSettlement_Settle is OrderSettlementTest {
  function test_TwoOrdersThatCrossSettleInFull() external {
    IOrderSettlement.Order memory _s = _sell(10);
    IOrderSettlement.Order memory _b = _buy(10);
    IOrderSettlement.Fill memory _f = _fill(_s, _b, 10 * _UNIT, 10 * _PRICE);
    uint256 _cashBefore = _cash.balanceOf(_investor);
    (IOrderSettlement.Refusal _pre,,) = _venue.canFill(_f);
    assertEq(uint256(_pre), uint256(IOrderSettlement.Refusal.NONE));

    vm.expectEmit(address(_venue));
    emit IOrderSettlement.OrderFilled(_venue.orderHash(_s), _seller, _investor, 10 * _UNIT, 10 * _PRICE);
    vm.expectEmit(address(_venue));
    emit IOrderSettlement.OrderFilled(_venue.orderHash(_b), _investor, _seller, 10 * _PRICE, 10 * _UNIT);
    _settle(_f);

    assertEq(_security.balanceOf(_investor), 10 * _UNIT);
    assertEq(_security.balanceOf(_seller), 90 * _UNIT);
    assertEq(_cash.balanceOf(_seller), 10 * _PRICE);
    assertEq(_cash.balanceOf(_investor), _cashBefore - 10 * _PRICE);
    assertEq(_venue.filled(_venue.orderHash(_s)), 10 * _UNIT);
    assertEq(_venue.filled(_venue.orderHash(_b)), 10 * _PRICE);
    assertEq(_security.balanceOf(address(_venue)), 0);
    assertEq(_cash.balanceOf(address(_venue)), 0);
  }

  function test_AnOrderFillsInPartsUpToItsAmountAndNeverPastIt() external {
    IOrderSettlement.Order memory _s = _sell(10);
    IOrderSettlement.Order memory _b = _buy(10);
    _settle(_fill(_s, _b, 4 * _UNIT, 4 * _PRICE));
    _settle(_fill(_s, _b, 6 * _UNIT, 6 * _PRICE));
    assertEq(_venue.filled(_venue.orderHash(_s)), 10 * _UNIT);
    assertEq(_security.balanceOf(_investor), 10 * _UNIT);
    _expectRefused(_fill(_s, _b, 1, 1), IOrderSettlement.Refusal.OVERFILLED, false);
  }

  /// @dev A buy order larger than the sell order meets it and stays open for the rest
  function test_ALargerOrderStaysOpenForTheRest() external {
    IOrderSettlement.Order memory _s = _sell(4);
    IOrderSettlement.Order memory _b = _buy(10);
    _settle(_fill(_s, _b, 4 * _UNIT, 4 * _PRICE));
    assertEq(_venue.filled(_venue.orderHash(_b)), 4 * _PRICE);
    _expectRefused(_fill(_s, _b, 1 * _UNIT, 1 * _PRICE), IOrderSettlement.Refusal.OVERFILLED, false);
    IOrderSettlement.Order memory _more = _sell(6);
    _more.nonce = keccak256('sell again');
    _settle(_fill(_more, _b, 6 * _UNIT, 6 * _PRICE));
    assertEq(_venue.filled(_venue.orderHash(_b)), 10 * _PRICE);
  }

  /// @dev The operator picks a price between the two limits: the seller takes at least 50, the buyer pays at most 60
  function test_TheOperatorChoosesAPriceBetweenTheTwoLimitsAndNoneOutsideThem() external {
    IOrderSettlement.Order memory _s = _sell(10);
    IOrderSettlement.Order memory _b = _buy(10);
    _b.giveAmount = 10 * 60e6;
    _settle(_fill(_s, _b, 2 * _UNIT, 2 * 55e6));
    assertEq(_cash.balanceOf(_seller), 2 * 55e6);
    assertEq(_security.balanceOf(_investor), 2 * _UNIT);

    _expectRefused(_fill(_s, _b, 2 * _UNIT, 2 * 50e6 - 1), IOrderSettlement.Refusal.BELOW_LIMIT, false);
    _expectRefused(_fill(_s, _b, 2 * _UNIT, 2 * 60e6 + 1), IOrderSettlement.Refusal.BELOW_LIMIT, true);
    _settle(_fill(_s, _b, 2 * _UNIT, 2 * 50e6));
    _settle(_fill(_s, _b, 2 * _UNIT, 2 * 60e6));
  }

  /// @dev A limit that does not divide evenly is rounded against the counterparty: 3 units for 10 cash is 3.33.. each,
  ///      so one unit costs at least 4
  function test_TheLimitIsRoundedAgainstTheCounterparty() external {
    IOrderSettlement.Order memory _s = _sell(1);
    (_s.giveAmount, _s.takeAmount) = (3, 10);
    IOrderSettlement.Order memory _b = _buy(1);
    (_b.giveAmount, _b.takeAmount) = (12, 3);
    _expectRefused(_fill(_s, _b, 1, 3), IOrderSettlement.Refusal.BELOW_LIMIT, false);
    _settle(_fill(_s, _b, 1, 4));
    assertEq(_cash.balanceOf(_seller), 4);
  }

  function test_AnAllOrNothingOrderFillsWholeOrNotAtAll() external {
    IOrderSettlement.Order memory _s = _sell(10);
    _s.allOrNothing = true;
    IOrderSettlement.Order memory _b = _buy(10);
    _expectRefused(_fill(_s, _b, 9 * _UNIT, 9 * _PRICE), IOrderSettlement.Refusal.NOT_WHOLE, false);
    _settle(_fill(_s, _b, 10 * _UNIT, 10 * _PRICE));
  }

  function test_AnOrderThatNamesItsTakerFillsOnlyAgainstIt() external {
    IOrderSettlement.Order memory _s = _sell(10);
    _s.taker = _custody;
    _expectRefused(_fill(_s, _buy(10), _UNIT, _PRICE), IOrderSettlement.Refusal.WRONG_TAKER, false);
    _s.taker = _investor;
    _settle(_fill(_s, _buy(10), _UNIT, _PRICE));
  }

  function test_BeforeItsWindowAndAfterItsDeadlineAnOrderIsRefused() external {
    IOrderSettlement.Order memory _b = _buy(10);
    _b.validAfter = block.timestamp + 10;
    _expectRefused(_fill(_sell(10), _b, _UNIT, _PRICE), IOrderSettlement.Refusal.NOT_YET_VALID, true);
    IOrderSettlement.Order memory _s = _sell(10);
    _s.deadline = block.timestamp + 5;
    vm.warp(block.timestamp + 6);
    _expectRefused(_fill(_s, _buy(10), _UNIT, _PRICE), IOrderSettlement.Refusal.EXPIRED, false);
    vm.warp(_s.deadline);
    _settle(_fill(_s, _buy(10), _UNIT, _PRICE));
  }

  /// @dev Whoever submits can change nothing a maker signed
  function test_AnOrderChangedAfterSigningIsRefused() external {
    IOrderSettlement.Fill memory _f = _fill(_sell(10), _buy(10), _UNIT, _PRICE);
    _f.first.takeAmount = 1;
    _expectRefused(_f, IOrderSettlement.Refusal.BAD_SIGNATURE, false);
    _f = _fill(_sell(10), _buy(10), _UNIT, _PRICE);
    _f.second.giveAmount = 1000 * _PRICE;
    _expectRefused(_f, IOrderSettlement.Refusal.BAD_SIGNATURE, true);
  }
}

contract OrderSettlement_DegenerateFills is OrderSettlementTest {
  function test_AFillOfNothingIsRefused() external {
    _expectRefused(_fill(_sell(10), _buy(10), 0, _PRICE), IOrderSettlement.Refusal.ZERO_AMOUNT, false);
    _expectRefused(_fill(_sell(10), _buy(10), _UNIT, 0), IOrderSettlement.Refusal.ZERO_AMOUNT, false);
  }

  function test_AnOrderThatGivesOrTakesNothingIsRefused() external {
    IOrderSettlement.Order memory _s = _sell(10);
    _s.takeAmount = 0;
    _expectRefused(_fill(_s, _buy(10), _UNIT, _PRICE), IOrderSettlement.Refusal.EMPTY_ORDER, false);
    IOrderSettlement.Order memory _b = _buy(10);
    _b.giveAmount = 0;
    _expectRefused(_fill(_sell(10), _b, _UNIT, _PRICE), IOrderSettlement.Refusal.EMPTY_ORDER, true);
  }

  function test_ATokenIdOnAnErc20SideIsRefused() external {
    IOrderSettlement.Order memory _s = _sell(10);
    _s.giveId = 7;
    _expectRefused(_fill(_s, _buy(10), _UNIT, _PRICE), IOrderSettlement.Refusal.ID_ON_ERC20, false);
  }

  function test_AnOrderThatGivesAndTakesTheSameAssetIsRefused() external {
    IOrderSettlement.Order memory _s = _sell(10);
    _s.takeToken = address(_security);
    _expectRefused(_fill(_s, _buy(10), _UNIT, _PRICE), IOrderSettlement.Refusal.SAME_ASSET, false);
  }

  /// @dev Refused here, and not later on the balance check with a misleading error
  function test_TwoOrdersOfOneMakerAreRefused() external {
    IOrderSettlement.Order memory _b = _buy(10);
    _b.maker = _seller;
    _expectRefused(_fill(_sell(10), _b, _UNIT, _PRICE), IOrderSettlement.Refusal.SELF_FILL, false);
  }

  function test_TwoOrdersThatDoNotNameEachOthersTokensAreRefused() external {
    IOrderSettlement.Order memory _b = _buy(10);
    _b.takeToken = address(_asset7());
    _expectRefused(_fill(_sell(10), _b, _UNIT, _PRICE), IOrderSettlement.Refusal.DO_NOT_CROSS, false);
    _b = _buy(10);
    (_b.takeIs1155, _b.takeId) = (true, 3);
    _expectRefused(_fill(_sell(10), _b, _UNIT, _PRICE), IOrderSettlement.Refusal.DO_NOT_CROSS, false);
  }

  function _asset7() internal returns (address _other) {
    _other = address(_intentToken('OTH', 18, false));
  }
}

contract OrderSettlement_Cancel is OrderSettlementTest {
  function test_ACancelledOrderFillsNoFurtherAndKeepsWhatItFilled() external {
    IOrderSettlement.Order memory _s = _sell(10);
    _settle(_fill(_s, _buy(10), 3 * _UNIT, 3 * _PRICE));
    vm.expectEmit(address(_venue));
    emit IOrderSettlement.OrderCancelled(_seller, _s.nonce);
    vm.prank(_seller);
    _venue.cancelOrder(_s.nonce);
    assertTrue(_venue.nonceCancelled(_seller, _s.nonce));
    _expectRefused(_fill(_s, _buy(10), _UNIT, _PRICE), IOrderSettlement.Refusal.CANCELLED, false);
    assertEq(_venue.filled(_venue.orderHash(_s)), 3 * _UNIT);
    assertEq(_security.balanceOf(_investor), 3 * _UNIT);
  }

  function test_OnlyTheMakerCancelsAndOnlyOnce() external {
    IOrderSettlement.Order memory _s = _sell(10);
    vm.prank(_stranger);
    _venue.cancelOrder(_s.nonce);
    assertFalse(_venue.nonceCancelled(_seller, _s.nonce));
    _settle(_fill(_s, _buy(10), _UNIT, _PRICE));

    vm.startPrank(_seller);
    _venue.cancelOrder(_s.nonce);
    vm.expectRevert(IOrderSettlement.OrderSettlement_NonceCancelled.selector);
    _venue.cancelOrder(_s.nonce);
    vm.stopPrank();
  }

  /// @dev What is filled is kept for each order's hash, and what is cancelled for each maker's nonce: two orders signed
  ///      with one nonce can both fill, and one cancel stops both
  function test_TwoOrdersWithOneNonceBothFillAndOneCancelStopsBoth() external {
    IOrderSettlement.Order memory _first = _sell(10);
    IOrderSettlement.Order memory _second = _sell(20);
    assertEq(_first.nonce, _second.nonce);
    _settle(_fill(_first, _buy(40), 10 * _UNIT, 10 * _PRICE));
    _settle(_fill(_second, _buy(40), 5 * _UNIT, 5 * _PRICE));
    assertEq(_venue.filled(_venue.orderHash(_first)), 10 * _UNIT);
    assertEq(_venue.filled(_venue.orderHash(_second)), 5 * _UNIT);

    vm.prank(_seller);
    _venue.cancelOrder(_first.nonce);
    _expectRefused(_fill(_second, _buy(40), _UNIT, _PRICE), IOrderSettlement.Refusal.CANCELLED, false);
  }

  function test_CancellingWorksWhilePaused() external {
    vm.prank(_guardian);
    _venue.pause();
    vm.prank(_seller);
    _venue.cancelOrder(keccak256('sell'));
    assertTrue(_venue.nonceCancelled(_seller, keccak256('sell')));
  }
}

contract OrderSettlement_Governance is OrderSettlementTest {
  function test_WithNoAdminOrNoGuardianItReverts() external {
    vm.expectRevert(IOrderSettlement.OrderSettlement_ZeroAddress.selector);
    new OrderSettlement(address(0), _guardian);
    vm.expectRevert(IOrderSettlement.OrderSettlement_ZeroAddress.selector);
    new OrderSettlement(address(this), address(0));
  }

  function testFuzz_OnlyAnOperatorSettles(
    address _caller
  ) external {
    if (_caller == _relayer) _caller = _stranger;
    IOrderSettlement.Fill[] memory _fills = _one(_fill(_sell(10), _buy(10), _UNIT, _PRICE));
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _venue.OPERATOR_ROLE())
    );
    vm.prank(_caller);
    _venue.settle(_fills);
  }

  function test_TheGuardianPausesAndCannotUnpauseAndTheTimelockOrRecoveryCan() external {
    IOrderSettlement.Fill[] memory _fills = _one(_fill(_sell(10), _buy(10), _UNIT, _PRICE));
    vm.prank(_guardian);
    _venue.pause();
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vm.prank(_relayer);
    _venue.settle(_fills);

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, _guardian, _venue.DEFAULT_ADMIN_ROLE()
      )
    );
    vm.prank(_guardian);
    _venue.unpause();

    vm.prank(_recovery);
    _venue.unpause();
    vm.prank(_guardian);
    _venue.pause();
    _venue.unpause();
    vm.prank(_relayer);
    _venue.settle(_fills);
  }

  function test_OnlyTheGuardianPauses() external {
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, _stranger, _venue.GUARDIAN_ROLE()
      )
    );
    vm.prank(_stranger);
    _venue.pause();
  }

  /// @dev The recovery timelock can take the guardian's role away and nothing else
  function test_RecoveryRevokesTheGuardianAndNoOtherRole() external {
    bytes32 _guardianRole = _venue.GUARDIAN_ROLE();
    bytes32 _operatorRole = _venue.OPERATOR_ROLE();
    vm.prank(_recovery);
    _venue.revokeRole(_guardianRole, _guardian);
    assertFalse(_venue.hasRole(_guardianRole, _guardian));
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, _recovery, _venue.DEFAULT_ADMIN_ROLE()
      )
    );
    vm.prank(_recovery);
    _venue.revokeRole(_operatorRole, _relayer);
  }

  function test_ItAnswersItsInterface() external view {
    assertTrue(_venue.supportsInterface(type(IOrderSettlement).interfaceId));
    assertTrue(_venue.supportsInterface(type(IAccessControl).interfaceId));
    assertFalse(_venue.supportsInterface(0xffffffff));
  }
}

contract OrderSettlement_Tokens is OrderSettlementTest {
  /// @dev The token's policy judges the two makers as on any transfer, and its own error comes back with the fill's
  ///      index and leg
  function test_AMakerThePolicyRefusesStopsTheFillWithTheTokensOwnError() external {
    IOrderSettlement.Fill memory _f = _fill(_sell(10), _buy(10), _UNIT, _PRICE);
    vm.prank(_guardian);
    _creds.blockSubject(_investor);

    (IOrderSettlement.Refusal _pre, bool _second, bytes32 _reason) = _venue.canFill(_f);
    assertEq(uint256(_pre), uint256(IOrderSettlement.Refusal.TOKEN_REFUSES));
    assertFalse(_second, 'the first leg, the security to the investor');
    assertEq(_reason, Reasons.RECEIVER_NOT_VERIFIED);

    vm.expectRevert(
      abi.encodeWithSelector(
        IOrderSettlement.OrderSettlement_TransferFailed.selector,
        0,
        false,
        abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, Reasons.RECEIVER_NOT_VERIFIED)
      )
    );
    vm.prank(_relayer);
    _venue.settle(_one(_f));
    assertEq(_venue.filled(_venue.orderHash(_f.first)), 0);
  }

  /// @dev The reasoned pre-flight counts the balance, which ERC-7943's plain one does not
  function test_AnAmountAboveTheMakersBalanceReadsRefusedInThePreflight() external {
    IOrderSettlement.Order memory _s = _sell(200);
    IOrderSettlement.Order memory _b = _buy(200);
    vm.prank(_minter);
    _cash.mint(_investor, 200 * _PRICE);
    (IOrderSettlement.Refusal _pre, bool _second, bytes32 _reason) =
      _venue.canFill(_fill(_s, _b, 200 * _UNIT, 200 * _PRICE));
    assertEq(uint256(_pre), uint256(IOrderSettlement.Refusal.TOKEN_REFUSES));
    assertFalse(_second);
    assertEq(_reason, Reasons.INSUFFICIENT_UNFROZEN);
  }

  function test_WithNoAllowanceTheTokenRefusesAndTheFillNamesTheLeg() external {
    vm.prank(_investor);
    _cash.approve(address(_venue), 0);
    IOrderSettlement.Fill[] memory _fills = _one(_fill(_sell(10), _buy(10), _UNIT, _PRICE));
    vm.expectRevert(
      abi.encodeWithSelector(
        IOrderSettlement.OrderSettlement_TransferFailed.selector,
        0,
        true,
        abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(_venue), 0, _PRICE)
      )
    );
    vm.prank(_relayer);
    _venue.settle(_fills);
    assertEq(_security.balanceOf(_investor), 0, 'the first leg is undone');
  }

  /// @dev A token that keeps part of a transfer cannot settle here: the maker would get less than its limit
  function test_ATokenThatKeepsAFeeIsRefused() external {
    OrderSettlementFeeToken _fee = new OrderSettlementFeeToken();
    _fee.mint(_investor, 1000);
    vm.prank(_investor);
    _fee.approve(address(_venue), 1000);
    IOrderSettlement.Order memory _s = _sell(1);
    (_s.takeToken, _s.takeAmount) = (address(_fee), 100);
    IOrderSettlement.Order memory _b = _buy(1);
    (_b.giveToken, _b.giveAmount) = (address(_fee), 100);
    IOrderSettlement.Fill[] memory _fills = _one(_fill(_s, _b, _UNIT, 100));
    vm.expectRevert(
      abi.encodeWithSelector(IOrderSettlement.OrderSettlement_WrongAmountReceived.selector, 0, true, 100, 90)
    );
    vm.prank(_relayer);
    _venue.settle(_fills);
  }

  /// @dev The entry point is guarded, and the guard comes before the role check: a token that calls back while it is
  ///      being moved is stopped, and its fill fails with the guard's error inside
  function test_ATokenThatCallsBackIsStoppedByTheGuard() external {
    OrderSettlementReenteringToken _hostile = new OrderSettlementReenteringToken(_venue);
    _hostile.mint(_investor, 100);
    vm.prank(_investor);
    _hostile.approve(address(_venue), 100);
    IOrderSettlement.Order memory _s = _sell(1);
    (_s.takeToken, _s.takeAmount) = (address(_hostile), 100);
    IOrderSettlement.Order memory _b = _buy(1);
    (_b.giveToken, _b.giveAmount) = (address(_hostile), 100);
    IOrderSettlement.Fill[] memory _fills = _one(_fill(_s, _b, _UNIT, 100));
    vm.expectRevert(
      abi.encodeWithSelector(
        IOrderSettlement.OrderSettlement_TransferFailed.selector,
        0,
        true,
        abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
      )
    );
    vm.prank(_relayer);
    _venue.settle(_fills);
  }

  /// @dev A vault's shares are an ERC-20 like any other: they trade against cash with no change to the vault
  function test_SharesOfA4626SettleAgainstCash() external {
    Gated4626Vault _vault = _vault4626(address(_cash));
    _credential(address(_vault));
    vm.prank(_minter);
    _cash.mint(_seller, _ASSETS);
    vm.startPrank(_seller);
    _cash.approve(address(_vault), _ASSETS);
    uint256 _shares = _vault.deposit(_ASSETS, _seller);
    _vault.approve(address(_venue), _shares);
    vm.stopPrank();

    IOrderSettlement.Order memory _s = _sell(1);
    (_s.giveToken, _s.giveAmount, _s.takeAmount) = (address(_vault), _shares, _ASSETS);
    IOrderSettlement.Order memory _b = _buy(1);
    (_b.takeToken, _b.takeAmount, _b.giveAmount) = (address(_vault), _shares, _ASSETS);
    _settle(_fill(_s, _b, _shares / 2, _ASSETS / 2));
    assertEq(_vault.balanceOf(_investor), _shares / 2);
    assertEq(_cash.balanceOf(_seller), _ASSETS / 2);
  }

  /// @dev A series of a multi-token is a leg: the id is in the order, and the maker approved the contract for all
  function test_ASeriesOfAGated1155SettlesAgainstCashInParts() external {
    Gated1155 _impl = new Gated1155();
    _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    IComplianceRule[] memory _list = new IComplianceRule[](1);
    _list[0] = _rule;
    Gated1155 _series = Gated1155(
      _deployer.deploy(
        'SER',
        address(_impl),
        abi.encodeCall(
          Gated1155.initialize, ('Series', 'SER', address(this), _guardian, address(_registry), address(_hook), _list)
        ),
        address(_hook),
        _list
      )
    );
    _rule.setPolicy(address(_series), Quals.KYC, 0, 0, 1);
    _series.grantRole(_series.MINTER_ROLE(), _minter);
    vm.prank(_minter);
    _series.mint(_seller, 2027, 100);
    vm.prank(_seller);
    _series.setApprovalForAll(address(_venue), true);

    IOrderSettlement.Order memory _s = _sell(1);
    (_s.giveToken, _s.giveIs1155, _s.giveId, _s.giveAmount, _s.takeAmount) =
    (address(_series), true, 2027, 100, 100 * _PRICE);
    IOrderSettlement.Order memory _b = _buy(1);
    (_b.takeToken, _b.takeIs1155, _b.takeId, _b.takeAmount, _b.giveAmount) =
    (address(_series), true, 2027, 100, 100 * _PRICE);

    IOrderSettlement.Fill memory _f = _fill(_s, _b, 40, 40 * _PRICE);
    (IOrderSettlement.Refusal _pre,,) = _venue.canFill(_f);
    assertEq(uint256(_pre), uint256(IOrderSettlement.Refusal.NONE));
    _settle(_f);
    _settle(_fill(_s, _b, 60, 60 * _PRICE));
    assertEq(_series.balanceOf(_investor, 2027), 100);
    assertEq(_cash.balanceOf(_seller), 100 * _PRICE);

    // Another id of the same contract is another asset: the orders no longer cross.
    IOrderSettlement.Order memory _otherId = _buy(1);
    (_otherId.takeToken, _otherId.takeIs1155, _otherId.takeId, _otherId.takeAmount, _otherId.giveAmount) =
    (address(_series), true, 2028, 100, 100 * _PRICE);
    _otherId.nonce = keccak256('another id');
    _s.nonce = keccak256('sell more');
    _expectRefused(_fill(_s, _otherId, 1, _PRICE), IOrderSettlement.Refusal.DO_NOT_CROSS, false);
  }
}

contract OrderSettlement_Batch is OrderSettlementTest {
  function test_ABatchSettlesEveryFillAndALaterFillSeesTheEarlierOnes() external {
    IOrderSettlement.Order memory _s = _sell(10);
    IOrderSettlement.Order memory _b = _buy(10);
    IOrderSettlement.Fill[] memory _fills = new IOrderSettlement.Fill[](3);
    _fills[0] = _fill(_s, _b, 4 * _UNIT, 4 * _PRICE);
    _fills[1] = _fill(_s, _b, 4 * _UNIT, 4 * _PRICE);
    _fills[2] = _fill(_s, _b, 2 * _UNIT, 2 * _PRICE);
    vm.prank(_relayer);
    _venue.settle(_fills);
    assertEq(_venue.filled(_venue.orderHash(_s)), 10 * _UNIT);
    assertEq(_security.balanceOf(_investor), 10 * _UNIT);
  }

  function test_OneFillThatFailsRevertsTheBatchAndNamesItsIndex() external {
    IOrderSettlement.Order memory _s = _sell(10);
    IOrderSettlement.Order memory _b = _buy(10);
    IOrderSettlement.Fill[] memory _fills = new IOrderSettlement.Fill[](3);
    _fills[0] = _fill(_s, _b, 6 * _UNIT, 6 * _PRICE);
    _fills[1] = _fill(_s, _b, 4 * _UNIT, 4 * _PRICE);
    _fills[2] = _fill(_s, _b, 1 * _UNIT, 1 * _PRICE);
    vm.expectRevert(_refused(2, IOrderSettlement.Refusal.OVERFILLED, false));
    vm.prank(_relayer);
    _venue.settle(_fills);
    assertEq(_venue.filled(_venue.orderHash(_s)), 0);
    assertEq(_security.balanceOf(_investor), 0);
  }

  function test_AnEmptyBatchDoesNothing() external {
    vm.prank(_relayer);
    _venue.settle(new IOrderSettlement.Fill[](0));
  }
}

contract OrderSettlement_Limits is OrderSettlementTest {
  /// @dev Over any sequence of fills of one order, what the maker gave is at most its amount and what it received is
  ///      at least its limit for what it gave, whatever amounts the operator chose
  function testFuzz_AnOrderIsNeverFilledPastItsAmountOrBelowItsLimit(
    uint256 _give,
    uint256 _take,
    uint256[4] memory _parts,
    uint256[4] memory _extra
  ) external {
    _give = bound(_give, 1, 100 * _UNIT);
    _take = bound(_take, 1, 5000e6);
    IOrderSettlement.Order memory _s = _sell(1);
    (_s.giveAmount, _s.takeAmount) = (_give, _take);
    // The buyer accepts any price: one unit of cash for the whole amount at least.
    IOrderSettlement.Order memory _b = _buy(1);
    (_b.giveAmount, _b.takeAmount) = (type(uint128).max, 1);
    _capRule.setSupplyCap(address(_cash), type(uint256).max);

    uint256 _given;
    uint256 _received;
    for (uint256 _i; _i < 4; ++_i) {
      uint256 _x = bound(_parts[_i], 1, _give);
      uint256 _floor = Math.mulDiv(_x, _take, _give, Math.Rounding.Ceil);
      uint256 _y = _floor + bound(_extra[_i], 0, 3);
      if (_y == 0) _y = 1;
      IOrderSettlement.Fill memory _f = _fill(_s, _b, _x, _y);
      (IOrderSettlement.Refusal _pre,,) = _venue.canFill(_f);
      if (_cash.balanceOf(_investor) < _y) break;
      if (_pre != IOrderSettlement.Refusal.NONE) {
        assertTrue(
          _pre == IOrderSettlement.Refusal.OVERFILLED || _pre == IOrderSettlement.Refusal.BELOW_LIMIT, 'refusal'
        );
        continue;
      }
      _settle(_f);
      _given += _x;
      _received += _y;
    }
    assertLe(_given, _give);
    assertEq(_venue.filled(_venue.orderHash(_s)), _given);
    assertGe(_received, Math.mulDiv(_given, _take, _give, Math.Rounding.Ceil));
    assertEq(_security.balanceOf(_investor), _given);
  }

  /// @dev Amounts near the top of 256 bits do not overflow the limit check
  function test_VeryLargeAmountsDoNotOverflowTheLimit() external view {
    IOrderSettlement.Order memory _s = _sell(1);
    (_s.giveAmount, _s.takeAmount) = (type(uint256).max, type(uint256).max);
    IOrderSettlement.Order memory _b = _buy(1);
    (_b.giveAmount, _b.takeAmount) = (type(uint256).max, type(uint256).max);
    (IOrderSettlement.Refusal _pre,,) = _venue.canFill(_fill(_s, _b, type(uint256).max / 2, type(uint256).max / 2));
    // The contract's own checks pass; only the token, which holds no such balance, refuses.
    assertEq(uint256(_pre), uint256(IOrderSettlement.Refusal.TOKEN_REFUSES));
  }
}

contract OrderSettlement_Hash is OrderSettlementTest {
  function test_TheHashIsTheEip712DigestOfTheOrder() external view {
    IOrderSettlement.Order memory _o = _sell(10);
    bytes32 _structHash = keccak256(
      abi.encode(
        keccak256(
          'Order(address maker,address giveToken,uint256 giveId,uint256 giveAmount,address takeToken,uint256 takeId,uint256 takeAmount,bool giveIs1155,bool takeIs1155,address taker,bool allOrNothing,bytes32 nonce,uint256 validAfter,uint256 deadline)'
        ),
        _o
      )
    );
    bytes32 _domain = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
        keccak256('OrderSettlement'),
        keccak256('1'),
        block.chainid,
        address(_venue)
      )
    );
    assertEq(_venue.orderHash(_o), keccak256(abi.encodePacked('\x19\x01', _domain, _structHash)));
  }
}
