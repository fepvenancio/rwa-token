// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IERC4626Adapter} from 'interfaces/IERC4626Adapter.sol';

import {ERC4626Adapter} from 'contracts/portfolio/ERC4626Adapter.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {MockERC4626Target} from 'contracts/test/MockERC4626Target.sol';

contract ERC4626AdapterUnitTest is Helpers {
  bytes32 internal constant _SHARED = keccak256('one custodian');

  address internal _portfolio = makeAddr('portfolio');
  MockAsset internal _asset;
  MockERC4626Target internal _target;
  ERC4626Adapter internal _adapter;

  function setUp() public virtual {
    _asset = new MockAsset(6);
    _target = new MockERC4626Target(IERC20(address(_asset)));
    _adapter = new ERC4626Adapter(_portfolio, _target, _SHARED);
  }

  function _allocate(
    uint256 _assets
  ) internal {
    _asset.mint(address(_adapter), _assets);
    vm.prank(_portfolio);
    _adapter.allocate(_assets);
  }
}

contract ERC4626AdapterUnit_Constructor is ERC4626AdapterUnitTest {
  function test_ItStoresItsSettings() external view {
    assertEq(_adapter.PORTFOLIO(), _portfolio);
    assertEq(address(_adapter.TARGET()), address(_target));
    assertEq(_adapter.asset(), address(_asset));
    assertEq(_adapter.SHARED_RISK_ID(), _SHARED);
    assertEq(_adapter.RISK_ID(), keccak256(abi.encode('ERC4626Adapter', address(_target))));
    assertFalse(_adapter.reported());
  }

  function test_WhenThePortfolioIsZero_ItReverts() external {
    vm.expectRevert(IERC4626Adapter.ERC4626Adapter_ZeroAddress.selector);
    new ERC4626Adapter(address(0), _target, _SHARED);
  }

  function test_WhenTheTargetIsZero_ItReverts() external {
    vm.expectRevert(IERC4626Adapter.ERC4626Adapter_ZeroAddress.selector);
    new ERC4626Adapter(_portfolio, IERC4626(address(0)), _SHARED);
  }

  function test_ItNamesTwoRisksWhenOneIsShared() external view {
    bytes32[] memory _ids = _adapter.riskIds();
    assertEq(_ids.length, 2);
    assertEq(_ids[0], _adapter.RISK_ID());
    assertEq(_ids[1], _SHARED);
  }

  function test_ItNamesOneRiskWhenNoneIsShared() external {
    ERC4626Adapter _alone = new ERC4626Adapter(_portfolio, _target, bytes32(0));
    bytes32[] memory _ids = _alone.riskIds();
    assertEq(_ids.length, 1);
    assertEq(_ids[0], _alone.RISK_ID());
  }

  function test_TheCodehashCoversTheSettings() external {
    ERC4626Adapter _sameSettings = new ERC4626Adapter(_portfolio, _target, _SHARED);
    ERC4626Adapter _otherShared = new ERC4626Adapter(_portfolio, _target, keccak256('another custodian'));
    ERC4626Adapter _otherPortfolio = new ERC4626Adapter(makeAddr('another portfolio'), _target, _SHARED);
    MockERC4626Target _otherTarget = new MockERC4626Target(IERC20(address(_asset)));
    ERC4626Adapter _otherAdapter = new ERC4626Adapter(_portfolio, _otherTarget, _SHARED);
    assertEq(address(_sameSettings).codehash, address(_adapter).codehash);
    assertNotEq(address(_otherShared).codehash, address(_adapter).codehash);
    assertNotEq(address(_otherPortfolio).codehash, address(_adapter).codehash);
    assertNotEq(address(_otherAdapter).codehash, address(_adapter).codehash);
  }
}

contract ERC4626AdapterUnit_Moves is ERC4626AdapterUnitTest {
  function test_OnlyThePortfolioCanMoveMoney() external {
    vm.expectRevert(abi.encodeWithSelector(IERC4626Adapter.ERC4626Adapter_OnlyPortfolio.selector, address(this)));
    _adapter.allocate(1);
    vm.expectRevert(abi.encodeWithSelector(IERC4626Adapter.ERC4626Adapter_OnlyPortfolio.selector, address(this)));
    _adapter.deallocate(1);
  }

  function test_AllocatingDepositsWhatItWasSentAndLeavesNoAllowance() external {
    _allocate(100e6);
    assertEq(_asset.balanceOf(address(_target)), 100e6);
    assertEq(_asset.balanceOf(address(_adapter)), 0);
    assertEq(_target.balanceOf(address(_adapter)), 100e6);
    assertEq(_asset.allowance(address(_adapter), address(_target)), 0);
    assertEq(_adapter.value(), 100e6);
  }

  function test_DeallocatingPaysOnlyThePortfolio() external {
    _allocate(100e6);
    vm.prank(_portfolio);
    _adapter.deallocate(40e6);
    assertEq(_asset.balanceOf(_portfolio), 40e6);
    assertEq(_adapter.value(), 60e6);
  }
}

contract ERC4626AdapterUnit_Reads is ERC4626AdapterUnitTest {
  function test_ItValuesThePositionAtTheTargetsPrice() external {
    _allocate(100e6);
    _asset.mint(address(_target), 50e6);
    assertApproxEqAbs(_adapter.value(), 150e6, 1);
    assertTrue(_adapter.fresh());
  }

  function test_AnEmptyPositionIsWorthNothingAndFresh() external view {
    assertEq(_adapter.value(), 0);
    assertTrue(_adapter.fresh());
  }

  function test_AFailedReadIsZeroAndNotFresh() external {
    _allocate(100e6);
    _target.setBroken(true);
    assertEq(_adapter.value(), 0);
    assertFalse(_adapter.fresh());
    assertEq(_adapter.liquid(), 0);
  }

  /// @dev A `try` does not catch a target with no code, which a bad upgrade of the target's proxy can leave
  function test_ATargetWithNoCodeIsZeroAndNotFresh() external {
    _allocate(100e6);
    vm.etch(address(_target), '');
    assertEq(_adapter.value(), 0);
    assertFalse(_adapter.fresh());
    assertEq(_adapter.liquid(), 0);
  }

  /// @dev Nor does it catch a target that answers with too little: 31 bytes here
  function test_ATargetThatReturnsTooLittleIsZeroAndNotFresh() external {
    _allocate(100e6);
    vm.etch(address(_target), hex'601f6000f3');
    assertEq(_adapter.value(), 0);
    assertFalse(_adapter.fresh());
    assertEq(_adapter.liquid(), 0);
  }

  /// @dev A target that cannot name the balance has no position to price, even if it can price nothing
  function test_ATargetThatCannotNameTheBalanceIsZeroAndNotFresh() external {
    _allocate(100e6);
    vm.mockCallRevert(address(_target), abi.encodeCall(IERC20.balanceOf, (address(_adapter))), 'outage');
    assertEq(_adapter.value(), 0);
    assertFalse(_adapter.fresh());
  }

  /// @dev A target that answers with one word of zero has answered: an empty position is not an outage
  function test_ATargetThatReturnsOneWordIsFresh() external {
    _allocate(100e6);
    vm.etch(address(_target), hex'60206000f3');
    assertEq(_adapter.value(), 0);
    assertTrue(_adapter.fresh());
  }

  function test_LiquidReadsTheTargetsLimit() external {
    _allocate(100e6);
    assertEq(_adapter.liquid(), 100e6);
    _target.setReportsNoLiquidity(true);
    assertEq(_adapter.liquid(), 0);
    assertTrue(_adapter.fresh(), 'a target that reports no liquidity can still be priced');
  }
}
