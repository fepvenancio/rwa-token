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

  function test_ARateWithNobodyToPayIsRefused() external {
    vm.expectRevert(IFeeModel.FeeModel_ZeroRecipient.selector);
    new FeeModel(address(0), 1, 0, 0, false);
    vm.expectRevert(IFeeModel.FeeModel_ZeroRecipient.selector);
    new FeeModel(address(0), 0, 1, 0, false);
    new FeeModel(address(0), 0, 0, 100, false);
  }
}

contract FeeModel_Management is FeeModelTest {
  function test_ItIsTheGrossTimesTheRateTimesTheAge() external {
    (uint256 _fee, uint256 _newMark, bool _moved) = _model(200, 0, 0, false).quote(_GROSS, _SUPPLY, _MARK, 0, _YEAR);
    assertEq(_fee, 20e18);
    assertEq(_newMark, _MARK);
    assertFalse(_moved);
  }

  function test_ForHalfAYearItIsHalf() external {
    (uint256 _fee,,) = _model(200, 0, 0, false).quote(_GROSS, _SUPPLY, _MARK, 0, _YEAR / 2);
    assertEq(_fee, 10e18);
  }

  function test_WithNoTimeThereIsNone() external {
    (uint256 _fee,,) = _model(200, 0, 0, false).quote(_GROSS, _SUPPLY, _MARK, 0, 0);
    assertEq(_fee, 0);
  }

  function test_TheAgeIsCappedAtTheWholeValueAtTheCeiling() external {
    FeeModel _m = _model(500, 0, 0, false);
    (uint256 _at20,,) = _m.quote(_GROSS, _SUPPLY, _MARK, 0, 20 * _YEAR);
    (uint256 _at200,,) = _m.quote(_GROSS, _SUPPLY, _MARK, 0, 200 * _YEAR);
    assertEq(_at20, _GROSS);
    assertEq(_at200, _GROSS);
  }
}

contract FeeModel_Performance is FeeModelTest {
  function test_BelowTheMarkThereIsNone() external {
    (uint256 _fee, uint256 _newMark, bool _moved) = _model(0, 2000, 0, false).quote(900e18, _SUPPLY, _MARK, 0, 0);
    assertEq(_fee, 0);
    assertEq(_newMark, _MARK);
    assertFalse(_moved);
  }

  function test_AtExactlyTheMarkThereIsNone() external {
    (uint256 _fee,, bool _moved) = _model(0, 2000, 0, false).quote(_GROSS, _SUPPLY, _MARK, 0, 0);
    assertEq(_fee, 0);
    assertFalse(_moved);
  }

  function test_AboveTheMarkItChargesTheRateOnTheGainAndMovesTheMark() external {
    (uint256 _fee, uint256 _newMark, bool _moved) = _model(0, 2000, 0, false).quote(1100e18, _SUPPLY, _MARK, 0, 0);
    assertEq(_fee, 20e18);
    assertEq(_newMark, 1.08e18);
    assertTrue(_moved);
  }

  function test_AtTheHurdleThereIsNone() external {
    (uint256 _fee, uint256 _newMark, bool _moved) =
      _model(0, 2000, 1000, false).quote(1100e18, _SUPPLY, _MARK, _YEAR, 0);
    assertEq(_fee, 0);
    assertEq(_newMark, _MARK);
    assertFalse(_moved);
  }

  function test_AHardHurdleChargesOnlyWhatIsAboveIt() external {
    // A 10% hurdle after a year, and a 21% gain.
    (uint256 _fee, uint256 _newMark,) = _model(0, 2000, 1000, false).quote(1210e18, _SUPPLY, _MARK, _YEAR, 0);
    assertEq(_fee, 22e18);
    assertEq(_newMark, 1.188e18);
  }

  function test_ASoftHurdleCatchesUpToTheRateOnTheWholeGain() external {
    // Well above the hurdle, it is the rate on the whole gain.
    (uint256 _fee, uint256 _newMark,) = _model(0, 2000, 1000, true).quote(1500e18, _SUPPLY, _MARK, _YEAR, 0);
    assertEq(_fee, 100e18);
    assertEq(_newMark, 1.4e18);
  }

  function test_JustAboveAHardOrSoftHurdle_TheyDiffer() external {
    // Value 1.11: 0.01 above a hurdle of 1.10. Hard takes 20% of that; soft takes all of it, as catching up.
    (uint256 _hard,,) = _model(0, 2000, 1000, false).quote(1110e18, _SUPPLY, _MARK, _YEAR, 0);
    (uint256 _soft,,) = _model(0, 2000, 1000, true).quote(1110e18, _SUPPLY, _MARK, _YEAR, 0);
    assertEq(_hard, 2e18);
    assertEq(_soft, 10e18);
  }

  function test_TheMarkNeverLandsBelowTheHurdle() external {
    (, uint256 _newMark,) = _model(0, 2000, 1000, true).quote(1110e18, _SUPPLY, _MARK, _YEAR, 0);
    assertEq(_newMark, 1.1e18);
  }

  function test_ThePerformanceFeeAddsToTheManagementFee() external {
    // 2% of 1,200 is 24, leaving 1.176 a share; 20% of the 0.176 gain is 35.2 on 1,000 shares.
    (uint256 _fee, uint256 _newMark,) = _model(200, 2000, 0, false).quote(1200e18, _SUPPLY, _MARK, 0, _YEAR);
    assertEq(_fee, 59.2e18);
    assertEq(_newMark, 1.1408e18);
  }

  function test_ThePriceIsMeasuredAfterTheManagementFee() external {
    // A 2% management fee takes a 2% gain below the mark, so no performance fee.
    (uint256 _fee, uint256 _newMark, bool _moved) = _model(200, 2000, 0, false).quote(1020e18, _SUPPLY, _MARK, 0, _YEAR);
    assertEq(_fee, 20.4e18);
    assertEq(_newMark, _MARK);
    assertFalse(_moved);
  }

  function test_WithARateOfZeroTheMarkDoesNotMove() external {
    (uint256 _fee, uint256 _newMark, bool _moved) = _model(0, 0, 0, false).quote(2000e18, _SUPPLY, _MARK, 0, 0);
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
      (uint256 _fee, uint256 _newMark, bool _moved) = _m.quote(_gross, _SUPPLY, _mark, _now - _markMovedAt, 0);
      assertEq(_fee, 0);
      assertFalse(_moved);
      _mark = _newMark;
    }
  }
}

contract FeeModel_Properties is FeeModelTest {
  function testFuzz_ItNeverRevertsAndAFeeNeverExceedsTheGross(
    uint256 _gross,
    uint256 _supply,
    uint256 _mark,
    uint256 _markAge,
    uint256 _feeAge,
    bool _soft
  ) external {
    FeeModel _m = _model(500, 5000, 5000, _soft);
    (uint256 _fee,,) = _m.quote(_gross, _supply, _mark, _markAge, _feeAge);
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
    (uint256 _fee,,) = _model(500, 5000, 5000, _soft).quote(_gross, _supply, _mark, _markAge, _feeAge);
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
    (uint256 _feeLow,,) = _m.quote(_low, _SUPPLY, _MARK, _YEAR, 0);
    (uint256 _feeHigh,,) = _m.quote(_low + _rise, _SUPPLY, _MARK, _YEAR, 0);
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
    (, uint256 _newMark, bool _moved) = _m.quote(_gross, _SUPPLY, _MARK, _YEAR, 0);
    if (_moved) assertGe(_newMark, _MARK + Math.mulDiv(_MARK, _hurdleBps, 10_000));
  }

  function test_WithNoSharesThereIsNoFeeAndTheMarkStaysEvenWithValuePresent() external {
    (uint256 _fee, uint256 _newMark, bool _moved) = _model(500, 5000, 0, false).quote(_GROSS, 0, _MARK, _YEAR, _YEAR);
    assertEq(_fee, 0);
    assertEq(_newMark, _MARK);
    assertFalse(_moved);
  }

  function test_AFigureTooLargeToBeRealGetsNoFee() external {
    FeeModel _m = _model(500, 5000, 0, false);
    uint256 _tooLarge = uint256(type(uint128).max) + 1;
    (uint256 _a,,) = _m.quote(_tooLarge, _SUPPLY, _MARK, _YEAR, _YEAR);
    (uint256 _b,,) = _m.quote(_GROSS, _tooLarge, _MARK, _YEAR, _YEAR);
    (uint256 _c,,) = _m.quote(_GROSS, _SUPPLY, _tooLarge, _YEAR, _YEAR);
    assertEq(_a + _b + _c, 0);
  }

  function test_AtTheLargestRealFiguresItDoesNotRevert() external {
    uint256 _largest = type(uint128).max;
    (uint256 _fee,,) = _model(500, 5000, 5000, true).quote(_largest, 1, _largest, 20 * _YEAR, 20 * _YEAR);
    assertLe(_fee, _largest);
  }
}
