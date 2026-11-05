// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Test} from 'forge-std/Test.sol';

import {IFeeModel} from 'interfaces/IFeeModel.sol';

import {FeeModel} from 'contracts/nav/FeeModel.sol';

contract FeeModelTest is Test {
  uint256 internal constant _YEAR = 365 days;
  uint256 internal constant _SUPPLY = 1000e18;
  /// @dev A price of 1.00: assets per 1e18 share units
  uint256 internal constant _MARK = 1e18;
  uint256 internal constant _GROSS = 1000e18;

  address internal _recipient = makeAddr('recipient');

  function _model(
    uint256 _management,
    uint256 _performance,
    uint256 _hurdle,
    bool _soft
  ) internal returns (FeeModel _deployed) {
    _deployed = new FeeModel(_recipient, _management, _performance, _hurdle, _soft);
  }
}

contract FeeModel_Construction is FeeModelTest {
  function test_ItKeepsItsTerms() external {
    FeeModel _m = _model(200, 2000, 500, true);
    assertEq(_m.RECIPIENT(), _recipient);
    assertEq(_m.MANAGEMENT_BPS(), 200);
    assertEq(_m.PERFORMANCE_BPS(), 2000);
    assertEq(_m.HURDLE_BPS(), 500);
    assertTrue(_m.SOFT_HURDLE());
  }

  function test_EachRateHasACeiling() external {
    _model(500, 5000, 5000, false);
    vm.expectRevert(IFeeModel.FeeModel_RateTooHigh.selector);
    new FeeModel(_recipient, 501, 0, 0, false);
    vm.expectRevert(IFeeModel.FeeModel_RateTooHigh.selector);
    new FeeModel(_recipient, 0, 5001, 0, false);
    vm.expectRevert(IFeeModel.FeeModel_RateTooHigh.selector);
    new FeeModel(_recipient, 0, 0, 5001, false);
  }

  /// @dev Even with no rate: a model swapped in with nobody to pay would strand what the last one left owed
  function test_NobodyToPayIsRefused() external {
    vm.expectRevert(IFeeModel.FeeModel_ZeroRecipient.selector);
    new FeeModel(address(0), 1, 0, 0, false);
    vm.expectRevert(IFeeModel.FeeModel_ZeroRecipient.selector);
    new FeeModel(address(0), 0, 1, 0, false);
    vm.expectRevert(IFeeModel.FeeModel_ZeroRecipient.selector);
    new FeeModel(address(0), 0, 0, 100, false);
    vm.expectRevert(IFeeModel.FeeModel_ZeroRecipient.selector);
    new FeeModel(address(0), 0, 0, 0, false);
    new FeeModel(_recipient, 0, 0, 0, false);
  }
}

contract FeeModel_Management is FeeModelTest {
  function test_ItIsTheGrossTimesTheRateTimesTheAge() external {
    (uint256 _fee, uint256 _newMark, bool _moved,) = _model(200, 0, 0, false).quote(_GROSS, _SUPPLY, _MARK, 0, _YEAR, 0);
    assertEq(_fee, 20e18);
    assertEq(_newMark, _MARK);
    assertFalse(_moved);
  }

  function test_ForHalfAYearItIsHalf() external {
    (uint256 _fee,,,) = _model(200, 0, 0, false).quote(_GROSS, _SUPPLY, _MARK, 0, _YEAR / 2, 0);
    assertEq(_fee, 10e18);
  }

  function test_WithNoTimeThereIsNone() external {
    (uint256 _fee,,,) = _model(200, 0, 0, false).quote(_GROSS, _SUPPLY, _MARK, 0, 0, 0);
    assertEq(_fee, 0);
  }

  function test_TheAgeIsCappedAtTheWholeValueAtTheCeiling() external {
    FeeModel _m = _model(500, 0, 0, false);
    (uint256 _at20,,,) = _m.quote(_GROSS, _SUPPLY, _MARK, 0, 20 * _YEAR, 0);
    (uint256 _at200,,,) = _m.quote(_GROSS, _SUPPLY, _MARK, 0, 200 * _YEAR, 0);
    assertEq(_at20, _GROSS);
    assertEq(_at200, _GROSS);
  }
}

contract FeeModel_Performance is FeeModelTest {
  function test_BelowTheMarkThereIsNone() external {
    (uint256 _fee, uint256 _newMark, bool _moved,) = _model(0, 2000, 0, false).quote(900e18, _SUPPLY, _MARK, 0, 0, 0);
    assertEq(_fee, 0);
    assertEq(_newMark, _MARK);
    assertFalse(_moved);
  }

  function test_AtExactlyTheMarkThereIsNone() external {
    (uint256 _fee,, bool _moved,) = _model(0, 2000, 0, false).quote(_GROSS, _SUPPLY, _MARK, 0, 0, 0);
    assertEq(_fee, 0);
    assertFalse(_moved);
  }

  function test_AboveTheMarkItChargesTheRateOnTheGainAndMovesTheMark() external {
    (uint256 _fee, uint256 _newMark, bool _moved,) = _model(0, 2000, 0, false).quote(1100e18, _SUPPLY, _MARK, 0, 0, 0);
    assertEq(_fee, 20e18);
    assertEq(_newMark, 1.08e18);
    assertTrue(_moved);
  }

  function test_AtTheHurdleThereIsNone() external {
    (uint256 _fee, uint256 _newMark, bool _moved,) =
      _model(0, 2000, 1000, false).quote(1100e18, _SUPPLY, _MARK, _YEAR, 0, 0);
    assertEq(_fee, 0);
    assertEq(_newMark, _MARK);
    assertFalse(_moved);
  }

  function test_AHardHurdleChargesOnlyWhatIsAboveIt() external {
    // A 10% hurdle after a year, and a 21% gain.
    (uint256 _fee, uint256 _newMark,,) = _model(0, 2000, 1000, false).quote(1210e18, _SUPPLY, _MARK, _YEAR, 0, 0);
    assertEq(_fee, 22e18);
    assertEq(_newMark, 1.188e18);
  }

  function test_ASoftHurdleCatchesUpToTheRateOnTheWholeGain() external {
    // Well above the hurdle, it is the rate on the whole gain.
    (uint256 _fee, uint256 _newMark,,) = _model(0, 2000, 1000, true).quote(1500e18, _SUPPLY, _MARK, _YEAR, 0, 0);
    assertEq(_fee, 100e18);
    assertEq(_newMark, 1.4e18);
  }

  function test_JustAboveAHardOrSoftHurdle_TheyDiffer() external {
    // Value 1.11: 0.01 above a hurdle of 1.10. Hard takes 20% of that; soft takes all of it, as catching up.
    (uint256 _hard,,,) = _model(0, 2000, 1000, false).quote(1110e18, _SUPPLY, _MARK, _YEAR, 0, 0);
    (uint256 _soft,,,) = _model(0, 2000, 1000, true).quote(1110e18, _SUPPLY, _MARK, _YEAR, 0, 0);
    assertEq(_hard, 2e18);
    assertEq(_soft, 10e18);
  }

  function test_TheMarkNeverLandsBelowTheHurdle() external {
    // A hard hurdle moves the mark to the price after its fee, above the hurdle.
    (, uint256 _newMark, bool _moved,) = _model(0, 2000, 1000, false).quote(1110e18, _SUPPLY, _MARK, _YEAR, 0, 0);
    assertTrue(_moved);
    assertEq(_newMark, 1.108e18);
    // A soft one inside its catch-up leaves the mark where it was.
    (, _newMark, _moved,) = _model(0, 2000, 1000, true).quote(1110e18, _SUPPLY, _MARK, _YEAR, 0, 0);
    assertFalse(_moved);
    assertEq(_newMark, _MARK);
  }

  function test_ThePerformanceFeeAddsToTheManagementFee() external {
    // 2% of 1,200 is 24, leaving 1.176 a share; 20% of the 0.176 gain is 35.2 on 1,000 shares.
    (uint256 _fee, uint256 _newMark,,) = _model(200, 2000, 0, false).quote(1200e18, _SUPPLY, _MARK, 0, _YEAR, 0);
    assertEq(_fee, 59.2e18);
    assertEq(_newMark, 1.1408e18);
  }

  function test_ThePriceIsMeasuredAfterTheManagementFee() external {
    // A 2% management fee takes a 2% gain below the mark, so no performance fee.
    (uint256 _fee, uint256 _newMark, bool _moved,) =
      _model(200, 2000, 0, false).quote(1020e18, _SUPPLY, _MARK, 0, _YEAR, 0);
    assertEq(_fee, 20.4e18);
    assertEq(_newMark, _MARK);
    assertFalse(_moved);
  }

  function test_WithARateOfZeroTheMarkDoesNotMove() external {
    (uint256 _fee, uint256 _newMark, bool _moved,) = _model(0, 0, 0, false).quote(2000e18, _SUPPLY, _MARK, 0, 0, 0);
    assertEq(_fee, 0);
    assertEq(_newMark, _MARK);
    assertFalse(_moved);
  }

  /// @dev A steady return below the hurdle pays no performance fee however many periods it is split into, because the
  ///      hurdle runs from when the mark last moved
  function testFuzz_ASteadyReturnBelowTheHurdlePaysNothingHoweverItIsSplit(
    uint8 _periods
  ) external {
    uint256 _count = bound(_periods, 1, 200);
    FeeModel _m = _model(0, 2000, 1000, true);
    uint256 _mark = _MARK;
    uint256 _markMovedAt;
    for (uint256 _i = 1; _i <= _count; ++_i) {
      uint256 _now = _YEAR * _i / _count;
      // 9% a year, simple, against a 10% hurdle.
      uint256 _gross = _GROSS + _GROSS * 9 * _now / (100 * _YEAR);
      (uint256 _fee, uint256 _newMark, bool _moved,) = _m.quote(_gross, _SUPPLY, _mark, _now - _markMovedAt, 0, 0);
      assertEq(_fee, 0);
      assertFalse(_moved);
      _mark = _newMark;
    }
  }
}

/// @notice A soft hurdle's catch-up is owed however the counts fall: what was paid inside the band is carried
contract FeeModel_CatchUp is FeeModelTest {
  /// @dev A count just above the hurdle, then one at 1.125, charge what one count at 1.125 does
  function test_ACountInsideTheBandDoesNotCostTheCatchUp() external {
    FeeModel _m = _model(0, 2000, 1000, true);
    (uint256 _once,,,) = _m.quote(1125e18, _SUPPLY, _MARK, _YEAR, 0, 0);
    assertEq(_once, 25e18);
    (uint256 _first, uint256 _mark1, bool _moved1, uint256 _paid1) = _m.quote(1100.1e18, _SUPPLY, _MARK, _YEAR, 0, 0);
    assertEq(_first, 0.1e18);
    assertEq(_mark1, _MARK);
    assertFalse(_moved1);
    assertEq(_paid1, 0.0001e18);
    (uint256 _second, uint256 _mark2, bool _moved2, uint256 _paid2) =
      _m.quote(1125e18 - _first, _SUPPLY, _mark1, _YEAR, 0, _paid1);
    assertEq(_first + _second, _once);
    assertTrue(_moved2);
    assertEq(_mark2, 1.1e18);
    assertEq(_paid2, 0);
  }

  function test_InsideTheBandTheMarkStaysAndWhatIsPaidIsCarried() external {
    (uint256 _fee, uint256 _newMark, bool _moved, uint256 _paid) =
      _model(0, 2000, 1000, true).quote(1110e18, _SUPPLY, _MARK, _YEAR, 0, 0);
    assertEq(_fee, 10e18);
    assertEq(_newMark, _MARK);
    assertFalse(_moved);
    assertEq(_paid, 0.01e18);
  }

  function test_AFallBackBelowTheHurdleKeepsWhatWasPaid() external {
    (uint256 _fee, uint256 _newMark, bool _moved, uint256 _paid) =
      _model(0, 2000, 1000, true).quote(1050e18, _SUPPLY, _MARK, _YEAR, 0, 0.01e18);
    assertEq(_fee, 0);
    assertEq(_newMark, _MARK);
    assertFalse(_moved);
    assertEq(_paid, 0.01e18);
  }

  /// @dev 0.02 was paid in the band; the hurdle has grown to 1.12, and the price after that fee reaches 1.13. Together
  ///      that is 1.15, whose catch-up is 0.03, so 0.01 is left to charge, and the catch-up is complete
  function test_ALaterRiseChargesOnlyTheRest() external {
    (uint256 _fee, uint256 _newMark, bool _moved, uint256 _paid) =
      _model(0, 2000, 1000, true).quote(1130e18, _SUPPLY, _MARK, _YEAR * 12 / 10, 0, 0.02e18);
    assertEq(_fee, 10e18);
    assertTrue(_moved);
    assertEq(_newMark, 1.12e18);
    assertEq(_paid, 0);
  }

  /// @dev What the hurdle's growth takes back is not charged again: a target below what was paid charges nothing
  function test_WhenTheHurdleOutgrowsWhatWasPaidNothingIsCharged() external {
    (uint256 _fee,, bool _moved, uint256 _paid) =
      _model(0, 2000, 1000, true).quote(1105e18, _SUPPLY, _MARK, _YEAR * 11 / 10, 0, 0.01e18);
    assertEq(_fee, 0);
    assertFalse(_moved);
    assertEq(_paid, 0.01e18);
  }

  function test_AChargeInsideTheBandThatRoundsToNothingChangesNothing() external {
    // 19m share units at about 1.105 against a hurdle of 1.10: about 0.005 a 1e18 units, a tenth of one unit in all.
    (uint256 _fee, uint256 _newMark, bool _moved, uint256 _paid) =
      _model(0, 5000, 1000, true).quote(21, 19e6, 1e12, _YEAR, 0, 0);
    assertEq(_fee, 0);
    assertEq(_newMark, 1e12);
    assertFalse(_moved);
    assertEq(_paid, 0);
  }

  function test_AHardHurdleCarriesNothing() external {
    FeeModel _m = _model(0, 2000, 1000, false);
    (uint256 _fee,, bool _moved, uint256 _paid) = _m.quote(1110e18, _SUPPLY, _MARK, _YEAR, 0, 0);
    assertEq(_fee, 2e18);
    assertTrue(_moved);
    assertEq(_paid, 0);
    // After a swap from a soft model inside its band, what was paid counts against what is due: 0.023 less 0.005.
    (_fee,, _moved, _paid) = _m.quote(1210e18, _SUPPLY, _MARK, _YEAR, 0, 5e15);
    assertEq(_fee, 18e18);
    assertTrue(_moved);
    assertEq(_paid, 0, 'a mark that moves clears it');
  }

  /// @dev Two counts, the first inside the band or below the hurdle, charge what one count at the second price does
  function testFuzz_SplitInTwoItChargesWhatOneCountDoes(
    uint256 _firstGross,
    uint256 _secondGross,
    uint256 _performance,
    uint256 _hurdle
  ) external {
    FeeModel _m = _model(0, bound(_performance, 1, 5000), bound(_hurdle, 1, 5000), true);
    _firstGross = bound(_firstGross, 900e18, 2000e18);
    (uint256 _first, uint256 _mark1, bool _moved1, uint256 _paid1) = _m.quote(_firstGross, _SUPPLY, _MARK, _YEAR, 0, 0);
    if (_moved1) return;
    _secondGross = bound(_secondGross, _firstGross, 3000e18);
    (uint256 _once,,,) = _m.quote(_secondGross, _SUPPLY, _MARK, _YEAR, 0, 0);
    (uint256 _second,,,) = _m.quote(_secondGross - _first, _SUPPLY, _mark1, _YEAR, 0, _paid1);
    // Each count rounds its price and its charge to whole units of 1e18 share units.
    assertApproxEqAbs(_first + _second, _once, 1e4);
  }

  /// @dev With what was paid fixed, net value still never falls as gross rises
  function testFuzz_NetValueNeverFallsAsGrossRisesWithSomethingPaid(
    uint256 _low,
    uint256 _rise,
    uint256 _paidSince
  ) external {
    FeeModel _m = _model(0, 2000, 1000, true);
    _low = bound(_low, 1e18, 1e30);
    _rise = bound(_rise, 1, 1e30);
    _paidSince = bound(_paidSince, 0, 1e18);
    (uint256 _feeLow,,,) = _m.quote(_low, _SUPPLY, _MARK, _YEAR, 0, _paidSince);
    (uint256 _feeHigh,,,) = _m.quote(_low + _rise, _SUPPLY, _MARK, _YEAR, 0, _paidSince);
    assertGe(_low + _rise - _feeHigh + 1e3, _low - _feeLow);
  }
}

contract FeeModel_RoundedCharges is FeeModelTest {
  /// @dev A charge too small to pay leaves the price where it was. On a dust position the next investor buys near that
  ///      price, and a mark left below it would be charged on their principal
  function test_WhenTheChargeRoundsToNoFeeTheMarkIsThePrice() external {
    (uint256 _fee, uint256 _newMark, bool _moved,) = _model(0, 5000, 0, false).quote(5, 3e6, 1e12, 0, 0, 0);
    assertEq(_fee, 0);
    assertEq(_newMark, uint256(5e18) / 3e6);
    assertTrue(_moved);
  }

  function test_TheMarkIsThePriceAfterWhatIsActuallyCharged() external {
    (uint256 _fee, uint256 _newMark, bool _moved,) = _model(0, 5000, 0, false).quote(7, 3e6, 1e12, 0, 0, 0);
    assertEq(_fee, 1);
    assertEq(_newMark, uint256(7e18) / 3e6 - uint256(1e18) / 3e6);
    assertTrue(_moved);
  }
}

contract FeeModel_Properties is FeeModelTest {
  function testFuzz_ItNeverRevertsAndAFeeNeverExceedsTheGross(
    uint256 _gross,
    uint256 _supply,
    uint256 _mark,
    uint256 _markAge,
    uint256 _feeAge,
    bool _soft,
    uint256 _paidSince
  ) external {
    FeeModel _m = _model(500, 5000, 5000, _soft);
    (uint256 _fee,,,) = _m.quote(_gross, _supply, _mark, _markAge, _feeAge, _paidSince);
    assertLe(_fee, _gross);
  }

  function testFuzz_InTheRealRangeAFeeNeverExceedsTheGross(
    uint256 _gross,
    uint256 _supply,
    uint256 _mark,
    uint256 _markAge,
    uint256 _feeAge,
    bool _soft
  ) external {
    _gross = bound(_gross, 1, 1e36);
    _supply = bound(_supply, 1, 1e36);
    _mark = bound(_mark, 1, 1e24);
    _markAge = bound(_markAge, 0, 50 * _YEAR);
    _feeAge = bound(_feeAge, 0, 50 * _YEAR);
    (uint256 _fee,,,) = _model(500, 5000, 5000, _soft).quote(_gross, _supply, _mark, _markAge, _feeAge, 0);
    assertLe(_fee, _gross);
  }

  /// @dev Net value never falls as gross rises, on either hurdle
  function testFuzz_NetValueNeverFallsAsGrossRises(
    uint256 _low,
    uint256 _rise,
    uint256 _performance,
    uint256 _hurdle,
    bool _soft
  ) external {
    _low = bound(_low, 1e18, 1e30);
    _rise = bound(_rise, 1, 1e30);
    FeeModel _m = _model(0, bound(_performance, 0, 5000), bound(_hurdle, 0, 5000), _soft);
    (uint256 _feeLow,,,) = _m.quote(_low, _SUPPLY, _MARK, _YEAR, 0, 0);
    (uint256 _feeHigh,,,) = _m.quote(_low + _rise, _SUPPLY, _MARK, _YEAR, 0, 0);
    // The fee is rounded to whole units from a rounded price, which can move a net by a little at this scale.
    assertGe(_low + _rise - _feeHigh + 1e3, _low - _feeLow);
  }

  function testFuzz_OnceAFeeIsChargedTheMarkIsNotBelowTheHurdle(
    uint256 _gross,
    uint256 _performance,
    uint256 _hurdle,
    bool _soft
  ) external {
    _gross = bound(_gross, 1e18, 1e30);
    uint256 _hurdleBps = bound(_hurdle, 0, 5000);
    FeeModel _m = _model(0, bound(_performance, 1, 5000), _hurdleBps, _soft);
    (, uint256 _newMark, bool _moved,) = _m.quote(_gross, _SUPPLY, _MARK, _YEAR, 0, 0);
    if (_moved) assertGe(_newMark, _MARK + Math.mulDiv(_MARK, _hurdleBps, 10_000));
  }

  function test_WithNoSharesThereIsNoFeeAndTheMarkStaysEvenWithValuePresent() external {
    (uint256 _fee, uint256 _newMark, bool _moved,) =
      _model(500, 5000, 0, false).quote(_GROSS, 0, _MARK, _YEAR, _YEAR, 0);
    assertEq(_fee, 0);
    assertEq(_newMark, _MARK);
    assertFalse(_moved);
  }

  function test_AFigureTooLargeToBeRealGetsNoFee() external {
    FeeModel _m = _model(500, 5000, 0, false);
    uint256 _tooLarge = uint256(type(uint128).max) + 1;
    (uint256 _a,,,) = _m.quote(_tooLarge, _SUPPLY, _MARK, _YEAR, _YEAR, 0);
    (uint256 _b,,,) = _m.quote(_GROSS, _tooLarge, _MARK, _YEAR, _YEAR, 0);
    (uint256 _c,,,) = _m.quote(_GROSS, _SUPPLY, _tooLarge, _YEAR, _YEAR, 0);
    (uint256 _d,,,) = _m.quote(_GROSS, _SUPPLY, _MARK, _YEAR, _YEAR, _tooLarge);
    assertEq(_a + _b + _c + _d, 0);
  }

  function test_AtTheLargestRealFiguresItDoesNotRevert() external {
    uint256 _largest = type(uint128).max;
    (uint256 _fee,,,) = _model(500, 5000, 5000, true).quote(_largest, 1, _largest, 20 * _YEAR, 20 * _YEAR, 0);
    assertLe(_fee, _largest);
  }
}
