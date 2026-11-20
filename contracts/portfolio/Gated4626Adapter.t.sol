// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';

import {IGated4626Vault} from 'interfaces/IGated4626Vault.sol';
import {IPortfolio} from 'interfaces/IPortfolio.sol';

import {ERC4626Adapter} from 'contracts/portfolio/ERC4626Adapter.sol';
import {Gated4626Adapter} from 'contracts/portfolio/Gated4626Adapter.sol';
import {Helpers} from 'contracts/test/Helpers.sol';

/// @notice The adapter alone, over a mocked `Gated4626Vault` and its mocked portfolio. `MasterFeeder.t.sol` runs it on real ones
contract Gated4626AdapterUnitTest is Helpers {
  address internal _portfolio = makeAddr('portfolio');
  address internal _asset = makeAddr('asset');
  address internal _target;
  address internal _targetPortfolio;
  Gated4626Adapter internal _adapter;

  function setUp() public virtual {
    _target = _mockContract('target');
    _targetPortfolio = _mockContract('targetPortfolio');
    vm.mockCall(_target, abi.encodeCall(IERC4626.asset, ()), abi.encode(_asset));
    _adapter = new Gated4626Adapter(_portfolio, IERC4626(_target), bytes32(0));
    // A position the target can price, and a target that deals.
    vm.mockCall(_target, abi.encodeCall(IERC20.balanceOf, (address(_adapter))), abi.encode(100e12));
    vm.mockCall(_target, abi.encodeWithSelector(IERC4626.previewRedeem.selector), abi.encode(100e6));
    _targetIs(false, _targetPortfolio, 1000e6, 1000e12, 5e6);
    _targetPortfolioIs(true, 1000e6);
  }

  function _targetIs(
    bool _paused,
    address _itsPortfolio,
    uint256 _lastCounted,
    uint256 _supply,
    uint256 _feesOwed
  ) internal {
    vm.mockCall(_target, abi.encodeCall(Pausable.paused, ()), abi.encode(_paused));
    vm.mockCall(_target, abi.encodeCall(IGated4626Vault.portfolio, ()), abi.encode(_itsPortfolio));
    vm.mockCall(_target, abi.encodeCall(IGated4626Vault.lastCounted, ()), abi.encode(_lastCounted));
    vm.mockCall(_target, abi.encodeCall(IERC20.totalSupply, ()), abi.encode(_supply));
    vm.mockCall(_target, abi.encodeCall(IGated4626Vault.feesOwed, ()), abi.encode(_feesOwed));
  }

  function _targetPortfolioIs(
    bool _fresh,
    uint256 _priced
  ) internal {
    vm.mockCall(_targetPortfolio, abi.encodeCall(IPortfolio.priceFresh, ()), abi.encode(_fresh));
    vm.mockCall(_targetPortfolio, abi.encodeCall(IPortfolio.pricedValue, ()), abi.encode(_priced));
  }
}

contract Gated4626AdapterUnit_Settings is Gated4626AdapterUnitTest {
  function test_ItIsAnERC4626AdapterInEverythingElse() external view {
    assertEq(_adapter.PORTFOLIO(), _portfolio);
    assertEq(address(_adapter.TARGET()), _target);
    assertEq(_adapter.asset(), _asset);
    assertEq(_adapter.RISK_ID(), keccak256(abi.encode('ERC4626Adapter', _target)));
    assertFalse(_adapter.reported());
    assertEq(_adapter.value(), 100e6);
  }

  function test_ItsCodeIsNotThePlainAdapters() external {
    ERC4626Adapter _plain = new ERC4626Adapter(_portfolio, IERC4626(_target), bytes32(0));
    assertNotEq(address(_plain).codehash, address(_adapter).codehash);
  }
}

contract Gated4626AdapterUnit_Fresh is Gated4626AdapterUnitTest {
  function test_WhenTheTargetDeals_ItIsFresh() external view {
    assertTrue(_adapter.fresh());
  }

  function test_WhenTheTargetsPortfolioGivesNoFreshPrice_ItIsNotFresh() external {
    _targetPortfolioIs(false, 1000e6);
    assertFalse(_adapter.fresh());
    assertEq(_adapter.value(), 100e6, 'the value is still the price the target holds');
  }

  function test_WhenTheTargetIsPaused_ItIsNotFresh() external {
    _targetIs(true, _targetPortfolio, 1000e6, 1000e12, 5e6);
    assertFalse(_adapter.fresh());
  }

  function test_WhenTheTargetIsPausedAndHasNoPortfolio_ItIsNotFresh() external {
    _targetIs(true, address(0), 0, 1000e12, 0);
    assertFalse(_adapter.fresh());
  }

  /// @dev A vault with no portfolio prices from its own balance and never stops for a price
  function test_WhenTheTargetHasNoPortfolio_ItIsFresh() external {
    _targetIs(false, address(0), 0, 1000e12, 0);
    vm.clearMockedCalls();
    vm.mockCall(_target, abi.encodeCall(IERC20.balanceOf, (address(_adapter))), abi.encode(100e12));
    vm.mockCall(_target, abi.encodeWithSelector(IERC4626.previewRedeem.selector), abi.encode(100e6));
    vm.mockCall(_target, abi.encodeCall(Pausable.paused, ()), abi.encode(false));
    vm.mockCall(_target, abi.encodeCall(IGated4626Vault.portfolio, ()), abi.encode(address(0)));
    assertTrue(_adapter.fresh(), 'and it asks for nothing more');
  }

  /// @dev The second arm of the vault's `_dealingStopped`: holders have a value counted and the portfolio reads no more than the fees owed
  function test_WhenTheTargetReadsNothing_ItIsNotFresh() external {
    _targetPortfolioIs(true, 5e6);
    assertFalse(_adapter.fresh(), 'the value equals the fees owed');
    _targetPortfolioIs(true, 0);
    assertFalse(_adapter.fresh());
    _targetPortfolioIs(true, 5e6 + 1);
    assertTrue(_adapter.fresh(), 'one unit above the fees owed is a value');
  }

  function test_AReadOfNothingWithNothingCountedIsFresh() external {
    _targetPortfolioIs(true, 0);
    _targetIs(false, _targetPortfolio, 0, 1000e12, 5e6);
    assertTrue(_adapter.fresh());
  }

  function test_AReadOfNothingWithFewerShareUnitsThanOneUnitBuysIsFresh() external {
    _targetPortfolioIs(true, 0);
    _targetIs(false, _targetPortfolio, 1000e6, 1e6 - 1, 5e6);
    assertTrue(_adapter.fresh());
    _targetIs(false, _targetPortfolio, 1000e6, 1e6, 5e6);
    assertFalse(_adapter.fresh());
  }

  function testFuzz_ItIsFreshExactlyWhenTheTargetDeals(
    bool _paused,
    bool _priceFresh,
    uint256 _last,
    uint256 _supply,
    uint256 _owed,
    uint256 _priced
  ) external {
    _last = bound(_last, 0, 2);
    _supply = bound(_supply, 1e6 - 2, 1e6 + 2);
    _owed = bound(_owed, 0, 3);
    _priced = bound(_priced, 0, 3);
    _targetIs(_paused, _targetPortfolio, _last, _supply, _owed);
    _targetPortfolioIs(_priceFresh, _priced);
    bool _stopped = _paused || !_priceFresh || (_last != 0 && _supply >= 1e6 && _priced <= _owed);
    assertEq(_adapter.fresh(), !_stopped);
  }

  /// @dev The target's portfolio is read on every call, so a target that replaces it takes the adapter with it
  function test_ItFollowsTheTargetToANewPortfolio() external {
    _targetPortfolioIs(false, 1000e6); // the old one, after `migrateTo`
    assertFalse(_adapter.fresh());
    address _next = _mockContract('nextPortfolio');
    vm.mockCall(_next, abi.encodeCall(IPortfolio.priceFresh, ()), abi.encode(true));
    vm.mockCall(_next, abi.encodeCall(IPortfolio.pricedValue, ()), abi.encode(1000e6));
    _targetIs(false, _next, 1000e6, 1000e12, 5e6);
    assertTrue(_adapter.fresh());
  }

  function test_WhenThePositionCannotBePriced_ItIsNotFresh() external {
    vm.mockCallRevert(_target, abi.encodeWithSelector(IERC4626.previewRedeem.selector), 'outage');
    assertFalse(_adapter.fresh());
    assertEq(_adapter.value(), 0);
  }
}

contract Gated4626AdapterUnit_FailedReads is Gated4626AdapterUnitTest {
  function _assertNotFreshAndNoRevert() internal view {
    assertFalse(_adapter.fresh());
  }

  function test_ATargetThatCannotSayWhetherItIsPausedIsNotFresh() external {
    vm.mockCallRevert(_target, abi.encodeCall(Pausable.paused, ()), 'outage');
    _assertNotFreshAndNoRevert();
  }

  function test_ATargetThatCannotNameItsPortfolioIsNotFresh() external {
    vm.mockCallRevert(_target, abi.encodeCall(IGated4626Vault.portfolio, ()), 'outage');
    _assertNotFreshAndNoRevert();
  }

  function test_APortfolioThatCannotSayWhetherItsPriceIsFreshIsNotFresh() external {
    vm.mockCallRevert(_targetPortfolio, abi.encodeCall(IPortfolio.priceFresh, ()), 'outage');
    _assertNotFreshAndNoRevert();
  }

  /// @dev `pricedValue` reverts in the middle of one of the portfolio's own moves
  function test_APortfolioThatCannotGiveItsValueIsNotFresh() external {
    vm.mockCallRevert(_targetPortfolio, abi.encodeCall(IPortfolio.pricedValue, ()), 'mid-move');
    _assertNotFreshAndNoRevert();
  }

  function test_ATargetThatCannotGiveWhatItCountedOwesOrIssuedIsNotFresh() external {
    bytes[3] memory _calls = [
      abi.encodeCall(IGated4626Vault.lastCounted, ()),
      abi.encodeCall(IERC20.totalSupply, ()),
      abi.encodeCall(IGated4626Vault.feesOwed, ())
    ];
    for (uint256 _i; _i < _calls.length; ++_i) {
      uint256 _snapshot = vm.snapshotState();
      vm.mockCallRevert(_target, _calls[_i], 'outage');
      _assertNotFreshAndNoRevert();
      vm.revertToState(_snapshot);
    }
  }

  /// @dev A portfolio with no code answers nothing, which a `try` would not catch
  function test_APortfolioWithNoCodeIsNotFresh() external {
    vm.clearMockedCalls();
    vm.etch(_targetPortfolio, '');
    vm.mockCall(_target, abi.encodeCall(IERC20.balanceOf, (address(_adapter))), abi.encode(100e12));
    vm.mockCall(_target, abi.encodeWithSelector(IERC4626.previewRedeem.selector), abi.encode(100e6));
    _targetIs(false, _targetPortfolio, 1000e6, 1000e12, 5e6);
    _assertNotFreshAndNoRevert();
  }
}
