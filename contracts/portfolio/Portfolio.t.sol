// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {Test} from 'forge-std/Test.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {IPortfolio} from 'interfaces/IPortfolio.sol';

import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {ERC4626Adapter} from 'contracts/portfolio/ERC4626Adapter.sol';
import {Portfolio} from 'contracts/portfolio/Portfolio.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockAdapter} from 'contracts/test/MockAdapter.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {MockERC4626Target} from 'contracts/test/MockERC4626Target.sol';
import {MockPortfolioVault} from 'contracts/test/MockPortfolioVault.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';

contract PortfolioUnitTest is Helpers {
  uint256 internal constant _IDLE = 1000e6;
  uint256 internal constant _NO_RELATIVE_LIMIT = 10_000;
  bytes32 internal constant _DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 internal constant _GUARDIAN_ROLE = keccak256('GUARDIAN_ROLE');
  bytes32 internal constant _ALLOCATOR_ROLE = keccak256('ALLOCATOR_ROLE');
  bytes32 internal constant _PRICED_ID = keccak256('priced');
  bytes32 internal constant _REPORTED_ID = keccak256('reported');
  bytes32 internal constant _SHARED_ID = keccak256('shared');

  Portfolio internal _portfolio;
  MockAsset internal _asset;
  MockPortfolioVault internal _vault;
  address internal _registry;
  MockAdapter internal _priced;
  MockAdapter internal _reported;
  address internal _admin = makeAddr('timelock');
  address internal _allocator = makeAddr('allocator');
  address internal _guardian = makeAddr('guardian');
  address internal _stranger = makeAddr('stranger');

  function setUp() public virtual {
    _asset = new MockAsset(6);
    _registry = _mockContract('registry');
    _vault = new MockPortfolioVault(_registry);
    _vault.setRole(_DEFAULT_ADMIN_ROLE, _admin, true);
    _vault.setRole(_ALLOCATOR_ROLE, _allocator, true);
    _vault.setRole(_GUARDIAN_ROLE, _guardian, true);
    _portfolio = new Portfolio(address(_vault), IERC20(address(_asset)), true);
    _priced = _newAdapter(false, _PRICED_ID);
    _reported = _newAdapter(true, _REPORTED_ID);
    _asset.mint(address(_portfolio), _IDLE);

    vm.startPrank(_admin);
    _portfolio.setCaps(_PRICED_ID, type(uint120).max, _NO_RELATIVE_LIMIT);
    _portfolio.setCaps(_REPORTED_ID, type(uint120).max, _NO_RELATIVE_LIMIT);
    _portfolio.setCaps(_SHARED_ID, type(uint120).max, _NO_RELATIVE_LIMIT);
    _attest(address(_priced), true);
    _portfolio.addAdapter(address(_priced));
    _attest(address(_reported), true);
    _portfolio.addAdapter(address(_reported));
    vm.stopPrank();
  }

  function _newAdapter(
    bool _isReported,
    bytes32 _id
  ) internal returns (MockAdapter _adapter) {
    bytes32[] memory _ids = new bytes32[](2);
    _ids[0] = _id;
    _ids[1] = _SHARED_ID;
    _adapter = new MockAdapter(address(_portfolio), address(_asset), _isReported, _ids);
  }

  function _attest(
    address _adapter,
    bool _attested
  ) internal {
    vm.mockCall(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (_adapter, IPolicyRegistry.AttestKind.ADAPTER)),
      abi.encode(_attested)
    );
  }

  function _allocate(
    MockAdapter _adapter,
    uint256 _assets
  ) internal {
    vm.prank(_allocator);
    _portfolio.allocate(address(_adapter), _assets, 0);
  }
}

/// @dev An adapter whose reads try to write, once it is told to
contract WritingAdapter {
  address public immutable PORTFOLIO;
  address public immutable asset;
  bool public writes;
  uint256 public touched;

  constructor(
    address _portfolio,
    address _asset
  ) {
    PORTFOLIO = _portfolio;
    asset = _asset;
  }

  function setWrites(
    bool _writes
  ) external {
    writes = _writes;
  }

  function reported() external returns (bool _reported) {
    if (writes) ++touched;
    _reported = false;
  }

  function fresh() external returns (bool _fresh) {
    if (writes) ++touched;
    _fresh = !writes;
  }

  function value() external returns (uint256 _value) {
    if (writes) ++touched;
    _value = 0;
  }

  function riskIds() external pure returns (bytes32[] memory _ids) {
    _ids = new bytes32[](1);
    _ids[0] = keccak256('writing');
  }
}

contract PortfolioUnit_Constructor is PortfolioUnitTest {
  function test_ItStoresItsSettingsAndLetsTheVaultPullTheIdleMoney() external view {
    assertEq(_portfolio.VAULT(), address(_vault));
    assertEq(address(_portfolio.ASSET()), address(_asset));
    assertTrue(_portfolio.ACCEPTS_REPORTED());
    assertEq(_portfolio.ALLOCATOR_ROLE(), _ALLOCATOR_ROLE);
    assertEq(_portfolio.MAX_ADAPTERS(), 8);
    assertEq(_asset.allowance(address(_portfolio), address(_vault)), type(uint256).max);
  }

  function test_WhenTheVaultIsZero_ItReverts() external {
    vm.expectRevert(IPortfolio.Portfolio_ZeroAddress.selector);
    new Portfolio(address(0), IERC20(address(_asset)), true);
  }

  function test_WhenTheAssetIsZero_ItReverts() external {
    vm.expectRevert(IPortfolio.Portfolio_ZeroAddress.selector);
    new Portfolio(address(_vault), IERC20(address(0)), true);
  }
}

contract PortfolioUnit_Gates is PortfolioUnitTest {
  function _expectUnauthorized(
    address _caller
  ) internal {
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_Unauthorized.selector, _caller));
    vm.prank(_caller);
  }

  function test_OnlyTheVaultsAdminCanAddAnAdapter() external {
    address[3] memory _callers = [_allocator, _guardian, _stranger];
    for (uint256 _i; _i < 3; ++_i) {
      _expectUnauthorized(_callers[_i]);
      _portfolio.addAdapter(address(_priced));
    }
  }

  function test_OnlyTheVaultsAdminCanRemoveAnAdapter() external {
    address[3] memory _callers = [_allocator, _guardian, _stranger];
    for (uint256 _i; _i < 3; ++_i) {
      _expectUnauthorized(_callers[_i]);
      _portfolio.removeAdapter(address(_priced));
    }
  }

  function test_OnlyTheVaultsAdminCanWriteOffAnAdapter() external {
    address[3] memory _callers = [_allocator, _guardian, _stranger];
    for (uint256 _i; _i < 3; ++_i) {
      _expectUnauthorized(_callers[_i]);
      _portfolio.writeOffAdapter(address(_priced));
    }
  }

  function test_OnlyTheVaultsAdminCanMigrate() external {
    address[3] memory _callers = [_allocator, _guardian, _stranger];
    for (uint256 _i; _i < 3; ++_i) {
      _expectUnauthorized(_callers[_i]);
      _portfolio.migrateTo(address(1));
    }
  }

  function test_OnlyTheAllocatorCanAllocate() external {
    address[3] memory _callers = [_admin, _guardian, _stranger];
    for (uint256 _i; _i < 3; ++_i) {
      _expectUnauthorized(_callers[_i]);
      _portfolio.allocate(address(_priced), 1, 0);
    }
  }

  function test_OnlyTheAllocatorOrGuardianCanDeallocate() external {
    address[2] memory _callers = [_admin, _stranger];
    for (uint256 _i; _i < 2; ++_i) {
      _expectUnauthorized(_callers[_i]);
      _portfolio.deallocate(address(_priced), 1);
    }
  }

  function test_OnlyTheAllocatorCanSetTheLiquidityAdapter() external {
    address[3] memory _callers = [_admin, _guardian, _stranger];
    for (uint256 _i; _i < 3; ++_i) {
      _expectUnauthorized(_callers[_i]);
      _portfolio.setLiquidityAdapter(address(_priced));
    }
  }

  function test_OnlyTheVaultCanRaise() external {
    address[4] memory _callers = [_admin, _allocator, _guardian, _stranger];
    for (uint256 _i; _i < 4; ++_i) {
      _expectUnauthorized(_callers[_i]);
      _portfolio.raise(1);
    }
  }

  function test_OnlyTheAdminOrGuardianCanSetCaps() external {
    address[2] memory _callers = [_allocator, _stranger];
    for (uint256 _i; _i < 2; ++_i) {
      _expectUnauthorized(_callers[_i]);
      _portfolio.setCaps(_PRICED_ID, 0, 0);
    }
  }

  function test_ARevokedRoleStopsWorkingAtOnce() external {
    _vault.setRole(_ALLOCATOR_ROLE, _allocator, false);
    _expectUnauthorized(_allocator);
    _portfolio.allocate(address(_priced), 1, 0);

    _vault.setRole(_GUARDIAN_ROLE, _guardian, false);
    _expectUnauthorized(_guardian);
    _portfolio.setCaps(_PRICED_ID, 0, 0);
    _expectUnauthorized(_guardian);
    _portfolio.deallocate(address(_priced), 1);

    _vault.setRole(_DEFAULT_ADMIN_ROLE, _admin, false);
    _expectUnauthorized(_admin);
    _portfolio.removeAdapter(address(_priced));
  }

  function test_ANewlyGrantedRoleWorksAtOnce() external {
    _vault.setRole(_ALLOCATOR_ROLE, _stranger, true);
    vm.prank(_stranger);
    _portfolio.allocate(address(_priced), 1, 0);
    assertEq(_portfolio.allocationOf(address(_priced)), 1);
  }
}

contract PortfolioUnit_AddAdapter is PortfolioUnitTest {
  function test_ItInstallsAnAttestedAdapter() external {
    MockAdapter _adapter = _newAdapter(false, keccak256('new'));
    _attest(address(_adapter), true);
    vm.expectEmit(address(_portfolio));
    emit IPortfolio.AdapterAdded(address(_adapter), 0);
    vm.prank(_admin);
    _portfolio.addAdapter(address(_adapter));
    assertEq(_portfolio.adapters().length, 3);
    assertEq(_portfolio.adapters()[2], address(_adapter));
  }

  function test_APositionItAlreadyHoldsCountsAgainstItsCapsAtOnce() external {
    bytes32 _id = keccak256('funded');
    MockAdapter _adapter = _newAdapter(false, _id);
    _adapter.setValue(300e6);
    _attest(address(_adapter), true);
    vm.startPrank(_admin);
    _portfolio.setCaps(_id, 300e6, _NO_RELATIVE_LIMIT);
    vm.expectEmit(address(_portfolio));
    emit IPortfolio.AdapterAdded(address(_adapter), 300e6);
    _portfolio.addAdapter(address(_adapter));
    vm.stopPrank();
    assertEq(_portfolio.allocationOf(address(_adapter)), 300e6);
    assertEq(_portfolio.riskOf(_id).allocation, 300e6);
    assertEq(_portfolio.riskOf(_SHARED_ID).allocation, 300e6);
  }

  function test_WhenAPositionItHoldsIsAboveItsAbsoluteCap_ItReverts() external {
    bytes32 _id = keccak256('funded');
    MockAdapter _adapter = _newAdapter(false, _id);
    _adapter.setValue(300e6);
    _attest(address(_adapter), true);
    vm.startPrank(_admin);
    _portfolio.setCaps(_id, 300e6 - 1, _NO_RELATIVE_LIMIT);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_CapExceeded.selector, _id, 300e6, 300e6 - 1));
    _portfolio.addAdapter(address(_adapter));
    vm.stopPrank();
    assertEq(_portfolio.adapters().length, 2, 'nothing was installed');
  }

  function test_WhenAPositionItHoldsIsAboveItsRelativeCap_ItReverts() external {
    bytes32 _id = keccak256('funded');
    MockAdapter _adapter = _newAdapter(false, _id);
    _adapter.setValue(300e6);
    _attest(address(_adapter), true);
    _vault.setTotalAssets(1000e6);
    vm.startPrank(_admin);
    _portfolio.setCaps(_id, type(uint120).max, 2999);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_CapExceeded.selector, _id, 300e6, 299.9e6));
    _portfolio.addAdapter(address(_adapter));
    vm.stopPrank();
  }

  function test_APricedAdapterThatCannotBeReadIsNotInstalled() external {
    MockAdapter _adapter = _newAdapter(false, keccak256('new'));
    _adapter.setFresh(false);
    _attest(address(_adapter), true);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_StalePrice.selector, address(_adapter)));
    vm.prank(_admin);
    _portfolio.addAdapter(address(_adapter));
  }

  function test_AReportedAdapterStartsAtZeroWhateverItHolds() external {
    MockAdapter _adapter = _newAdapter(true, keccak256('new'));
    _adapter.setFresh(false);
    _adapter.setValue(300e6);
    _asset.mint(address(_adapter), 300e6);
    _attest(address(_adapter), true);
    vm.expectEmit(address(_portfolio));
    emit IPortfolio.AdapterAdded(address(_adapter), 0);
    vm.prank(_admin);
    _portfolio.addAdapter(address(_adapter));
    assertEq(_portfolio.allocationOf(address(_adapter)), 0);
  }

  function test_ItAsksTheVaultsRegistryForAnAdapterAttestation() external {
    MockAdapter _adapter = _newAdapter(false, keccak256('new'));
    _mockAndExpect(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (address(_adapter), IPolicyRegistry.AttestKind.ADAPTER)),
      abi.encode(true)
    );
    vm.prank(_admin);
    _portfolio.addAdapter(address(_adapter));
  }

  function test_WhenNotAttested_ItReverts() external {
    MockAdapter _adapter = _newAdapter(false, keccak256('new'));
    _attest(address(_adapter), false);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_NotAttested.selector, address(_adapter)));
    vm.prank(_admin);
    _portfolio.addAdapter(address(_adapter));
  }

  function test_WhenItServesAnotherPortfolio_ItReverts() external {
    bytes32[] memory _ids = new bytes32[](1);
    _ids[0] = _PRICED_ID;
    MockAdapter _adapter = new MockAdapter(address(1), address(_asset), false, _ids);
    _attest(address(_adapter), true);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_WrongPortfolio.selector, address(_adapter)));
    vm.prank(_admin);
    _portfolio.addAdapter(address(_adapter));
  }

  function test_WhenItUsesAnotherAsset_ItReverts() external {
    bytes32[] memory _ids = new bytes32[](1);
    _ids[0] = _PRICED_ID;
    MockAdapter _adapter = new MockAdapter(address(_portfolio), address(1), false, _ids);
    _attest(address(_adapter), true);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_WrongAsset.selector, address(_adapter)));
    vm.prank(_admin);
    _portfolio.addAdapter(address(_adapter));
  }

  function test_WhenItNamesNoRisk_ItReverts() external {
    MockAdapter _adapter = new MockAdapter(address(_portfolio), address(_asset), false, new bytes32[](0));
    _attest(address(_adapter), true);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_NoRiskIds.selector, address(_adapter)));
    vm.prank(_admin);
    _portfolio.addAdapter(address(_adapter));
  }

  function test_WhenReportedAndNotAccepted_ItReverts() external {
    Portfolio _onChainOnly = new Portfolio(address(_vault), IERC20(address(_asset)), false);
    bytes32[] memory _ids = new bytes32[](1);
    _ids[0] = _REPORTED_ID;
    MockAdapter _adapter = new MockAdapter(address(_onChainOnly), address(_asset), true, _ids);
    _attest(address(_adapter), true);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_ReportedNotAccepted.selector, address(_adapter)));
    vm.prank(_admin);
    _onChainOnly.addAdapter(address(_adapter));
  }

  function test_WhenInstalledTwice_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_AdapterExists.selector, address(_priced)));
    vm.prank(_admin);
    _portfolio.addAdapter(address(_priced));
  }

  function test_WhenTheListIsFull_ItReverts() external {
    for (uint256 _i; _i < 6; ++_i) {
      MockAdapter _adapter = _newAdapter(false, keccak256(abi.encode(_i)));
      _attest(address(_adapter), true);
      vm.prank(_admin);
      _portfolio.addAdapter(address(_adapter));
    }
    assertEq(_portfolio.adapters().length, 8);
    MockAdapter _ninth = _newAdapter(false, keccak256('ninth'));
    _attest(address(_ninth), true);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_TooManyAdapters.selector, 8));
    vm.prank(_admin);
    _portfolio.addAdapter(address(_ninth));
  }
}

contract PortfolioUnit_SetCaps is PortfolioUnitTest {
  bytes32 internal constant _ID = keccak256('capped');

  function test_TheAdminCanRaiseAndLowerBothCaps() external {
    vm.expectEmit(address(_portfolio));
    emit IPortfolio.CapsSet(_ID, 500, 2000);
    vm.prank(_admin);
    _portfolio.setCaps(_ID, 500, 2000);
    IPortfolio.Risk memory _risk = _portfolio.riskOf(_ID);
    assertEq(_risk.absoluteCap, 500);
    assertEq(_risk.relativeCapBps, 2000);

    vm.prank(_admin);
    _portfolio.setCaps(_ID, 100, 100);
    assertEq(_portfolio.riskOf(_ID).absoluteCap, 100);
  }

  function test_TheGuardianCanLowerBothCaps() external {
    vm.prank(_admin);
    _portfolio.setCaps(_ID, 500, 2000);
    vm.prank(_guardian);
    _portfolio.setCaps(_ID, 400, 1000);
    assertEq(_portfolio.riskOf(_ID).absoluteCap, 400);
    assertEq(_portfolio.riskOf(_ID).relativeCapBps, 1000);
  }

  function test_TheGuardianCannotRaiseTheAbsoluteCap() external {
    vm.prank(_admin);
    _portfolio.setCaps(_ID, 500, 2000);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_Unauthorized.selector, _guardian));
    vm.prank(_guardian);
    _portfolio.setCaps(_ID, 501, 2000);
  }

  function test_TheGuardianCannotRaiseTheRelativeCap() external {
    vm.prank(_admin);
    _portfolio.setCaps(_ID, 500, 2000);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_Unauthorized.selector, _guardian));
    vm.prank(_guardian);
    _portfolio.setCaps(_ID, 500, 2001);
  }

  function test_WhenTheRelativeCapIsAboveEverything_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_InvalidCap.selector, 10_001));
    vm.prank(_admin);
    _portfolio.setCaps(_ID, 500, 10_001);
  }

  function test_WhenTheAbsoluteCapDoesNotFit_ItReverts() external {
    uint256 _tooBig = uint256(type(uint120).max) + 1;
    vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 120, _tooBig));
    vm.prank(_admin);
    _portfolio.setCaps(_ID, _tooBig, 10_000);
  }
}

contract PortfolioUnit_Allocate is PortfolioUnitTest {
  function test_ItSendsTheMoneyAndCountsTheChangeInValue() external {
    vm.expectEmit(address(_portfolio));
    emit IPortfolio.Allocated(address(_priced), 100e6, 100e6);
    _allocate(_priced, 100e6);
    assertEq(_asset.balanceOf(address(_priced)), 100e6);
    assertEq(_asset.balanceOf(address(_portfolio)), _IDLE - 100e6);
    assertEq(_portfolio.allocationOf(address(_priced)), 100e6);
    assertEq(_portfolio.riskOf(_PRICED_ID).allocation, 100e6);
    assertEq(_portfolio.riskOf(_SHARED_ID).allocation, 100e6);
    assertEq(_portfolio.moves(), 1);
  }

  function test_APricedAdapterThatTakesAFeeCountsWhatItIsWorth() external {
    _priced.setFee(1e6);
    vm.expectEmit(address(_portfolio));
    emit IPortfolio.Allocated(address(_priced), 100e6, 99e6);
    _allocate(_priced, 100e6);
    assertEq(_portfolio.allocationOf(address(_priced)), 99e6);
  }

  function test_AReportedAdapterCountsWhatWasSent() external {
    _allocate(_reported, 100e6);
    assertEq(_portfolio.allocationOf(address(_reported)), 100e6);
    assertEq(_portfolio.riskOf(_REPORTED_ID).allocation, 100e6);
  }

  function test_ASharedIdCountsEveryAdapterThatNamesIt() external {
    _allocate(_priced, 100e6);
    _allocate(_reported, 50e6);
    assertEq(_portfolio.riskOf(_SHARED_ID).allocation, 150e6);
    assertEq(_portfolio.riskOf(_PRICED_ID).allocation, 100e6);
    assertEq(_portfolio.riskOf(_REPORTED_ID).allocation, 50e6);
  }

  function test_TheAbsoluteCapHoldsAtTheExactBoundary() external {
    vm.prank(_admin);
    _portfolio.setCaps(_PRICED_ID, 100e6, _NO_RELATIVE_LIMIT);
    _allocate(_priced, 100e6);
    assertEq(_portfolio.allocationOf(address(_priced)), 100e6);

    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_CapExceeded.selector, _PRICED_ID, 100e6 + 1, 100e6));
    _allocate(_priced, 1);
  }

  function test_TheRelativeCapHoldsAtTheExactBoundary() external {
    _vault.setTotalAssets(1000e6);
    vm.prank(_admin);
    _portfolio.setCaps(_PRICED_ID, type(uint120).max, 2500);
    _allocate(_priced, 250e6);
    assertEq(_portfolio.allocationOf(address(_priced)), 250e6);

    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_CapExceeded.selector, _PRICED_ID, 250e6 + 1, 250e6));
    _allocate(_priced, 1);
  }

  function test_TheSharedCapStopsAnAdapterWhoseOwnCapHasRoom() external {
    vm.prank(_admin);
    _portfolio.setCaps(_SHARED_ID, 120e6, _NO_RELATIVE_LIMIT);
    _allocate(_priced, 100e6);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_CapExceeded.selector, _SHARED_ID, 121e6, 120e6));
    _allocate(_reported, 21e6);
    _allocate(_reported, 20e6);
    assertEq(_portfolio.riskOf(_SHARED_ID).allocation, 120e6);
  }

  function test_AnIdWithNoCapAllowsNothing() external {
    bytes32[] memory _ids = new bytes32[](1);
    bytes32 _uncapped = keccak256('no cap set');
    _ids[0] = _uncapped;
    MockAdapter _adapter = new MockAdapter(address(_portfolio), address(_asset), false, _ids);
    _attest(address(_adapter), true);
    vm.prank(_admin);
    _portfolio.addAdapter(address(_adapter));

    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_CapExceeded.selector, _uncapped, 1, 0));
    _allocate(_adapter, 1);
  }

  function test_NoRelativeLimitMeansTheTotalAssetsDoNotMatter() external {
    _vault.setTotalAssets(0);
    _allocate(_priced, _IDLE);
    assertEq(_portfolio.allocationOf(address(_priced)), _IDLE);
  }

  function test_WhenThePriceIsStaleBefore_ItReverts() external {
    _priced.setFresh(false);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_StalePrice.selector, address(_priced)));
    _allocate(_priced, 1);
  }

  function test_WhenThePriceIsStaleBeforeAndRecoversDuringTheCall_ItStillReverts() external {
    _priced.setFresh(false);
    _priced.setRecovers(true);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_StalePrice.selector, address(_priced)));
    _allocate(_priced, 1);
  }

  function test_WhenThePriceGoesStaleDuringTheCall_ItReverts() external {
    _priced.setGoesStale(true);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_StalePrice.selector, address(_priced)));
    _allocate(_priced, 1);
  }

  function test_AReportedAdapterNeedsNoFreshPrice() external {
    _reported.setFresh(false);
    _allocate(_reported, 1);
    assertEq(_portfolio.allocationOf(address(_reported)), 1);
  }

  function test_WhenTheAdapterIsNotInstalled_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_UnknownAdapter.selector, address(1)));
    vm.prank(_allocator);
    _portfolio.allocate(address(1), 1, 0);
  }

  function test_WhenTheAmountIsZero_ItReverts() external {
    vm.expectRevert(IPortfolio.Portfolio_ZeroAmount.selector);
    _allocate(_priced, 0);
  }

  function testFuzz_NoAllocationEverPassesItsAbsoluteCap(
    uint256 _cap,
    uint256 _assets
  ) external {
    _cap = bound(_cap, 0, _IDLE);
    _assets = bound(_assets, 1, _IDLE);
    vm.prank(_admin);
    _portfolio.setCaps(_PRICED_ID, _cap, _NO_RELATIVE_LIMIT);
    vm.prank(_allocator);
    try _portfolio.allocate(address(_priced), _assets, 0) {
      assertLe(_assets, _cap);
    } catch {
      assertGt(_assets, _cap);
    }
    assertLe(_portfolio.riskOf(_PRICED_ID).allocation, _cap);
  }
}

contract PortfolioUnit_AllocateMinimum is PortfolioUnitTest {
  function _allocateAtLeast(
    MockAdapter _adapter,
    uint256 _assets,
    uint256 _minAdded
  ) internal {
    vm.prank(_allocator);
    _portfolio.allocate(address(_adapter), _assets, _minAdded);
  }

  function test_WhenAPricedAdapterGrowsByLess_ItRevertsAndNothingMoves() external {
    _priced.setFee(1e6);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_ShortAllocation.selector, _priced, 100e6, 99e6));
    _allocateAtLeast(_priced, 100e6, 100e6);
    assertEq(_asset.balanceOf(address(_portfolio)), _IDLE);
    assertEq(_asset.balanceOf(address(_priced)), 0);
    assertEq(_portfolio.allocationOf(address(_priced)), 0);
    assertEq(_portfolio.moves(), 0);
  }

  function test_WhenAPricedAdapterGrowsByExactlyTheMinimum_ItPasses() external {
    _priced.setFee(1e6);
    _allocateAtLeast(_priced, 100e6, 99e6);
    assertEq(_portfolio.allocationOf(address(_priced)), 99e6);
  }

  function test_WhenAPricedAdapterKeepsEverything_AnyMinimumAboveZeroStopsIt() external {
    _priced.setFee(100e6);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_ShortAllocation.selector, _priced, 1, 0));
    _allocateAtLeast(_priced, 100e6, 1);
  }

  function test_ForAReportedAdapter_TheMinimumIsJudgedAgainstWhatWasSent() external {
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_ShortAllocation.selector, _reported, 100e6 + 1, 100e6));
    _allocateAtLeast(_reported, 100e6, 100e6 + 1);
    _allocateAtLeast(_reported, 100e6, 100e6);
    assertEq(_portfolio.allocationOf(address(_reported)), 100e6);
  }

  function testFuzz_ItPassesExactlyWhenTheValueGrowsEnough(
    uint256 _assets,
    uint256 _fee,
    uint256 _minAdded
  ) external {
    _assets = bound(_assets, 1, _IDLE);
    _fee = bound(_fee, 0, _assets);
    _minAdded = bound(_minAdded, 0, _assets);
    _priced.setFee(_fee);
    vm.prank(_allocator);
    try _portfolio.allocate(address(_priced), _assets, _minAdded) {
      assertGe(_assets - _fee, _minAdded);
      assertEq(_portfolio.allocationOf(address(_priced)), _assets - _fee);
    } catch {
      assertLt(_assets - _fee, _minAdded);
      assertEq(_portfolio.allocationOf(address(_priced)), 0);
    }
  }
}

contract PortfolioUnit_WhileThePauseHolds is PortfolioUnitTest {
  function setUp() public override {
    super.setUp();
    _allocate(_priced, 100e6);
    _vault.setPaused(true);
  }

  function test_AnAllocationRevertsAndNothingMoves() external {
    vm.expectRevert(IPortfolio.Portfolio_VaultPaused.selector);
    vm.prank(_allocator);
    _portfolio.allocate(address(_priced), 1e6, 0);
    assertEq(_portfolio.allocationOf(address(_priced)), 100e6);
    assertEq(_asset.balanceOf(address(_portfolio)), _IDLE - 100e6);
  }

  function test_AStrangerStillGetsTheRoleError() external {
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_Unauthorized.selector, _stranger));
    vm.prank(_stranger);
    _portfolio.allocate(address(_priced), 1e6, 0);
  }

  function test_TheGuardianAndTheAllocatorStillBringMoneyBack() external {
    vm.prank(_guardian);
    _portfolio.deallocate(address(_priced), 40e6);
    vm.prank(_allocator);
    _portfolio.deallocate(address(_priced), 60e6);
    assertEq(_asset.balanceOf(address(_portfolio)), _IDLE);
  }

  function test_TheGuardianStillLowersACap() external {
    vm.prank(_guardian);
    _portfolio.setCaps(_PRICED_ID, 0, 0);
    assertEq(_portfolio.riskOf(_PRICED_ID).absoluteCap, 0);
  }

  function test_WhenThePauseIsLifted_AnAllocationGoesThrough() external {
    _vault.setPaused(false);
    _allocate(_priced, 1e6);
    assertEq(_portfolio.allocationOf(address(_priced)), 101e6);
  }
}

contract PortfolioUnit_Deallocate is PortfolioUnitTest {
  function setUp() public override {
    super.setUp();
    _allocate(_priced, 100e6);
    _allocate(_reported, 100e6);
  }

  function test_TheMoneyComesBackAndTheAllocationFalls() external {
    vm.expectEmit(address(_portfolio));
    emit IPortfolio.Deallocated(address(_priced), 40e6, 40e6);
    vm.prank(_allocator);
    _portfolio.deallocate(address(_priced), 40e6);
    assertEq(_asset.balanceOf(address(_portfolio)), _IDLE - 200e6 + 40e6);
    assertEq(_portfolio.allocationOf(address(_priced)), 60e6);
    assertEq(_portfolio.riskOf(_PRICED_ID).allocation, 60e6);
    assertEq(_portfolio.riskOf(_SHARED_ID).allocation, 160e6);
    assertEq(_portfolio.moves(), 3);
  }

  function test_TheGuardianCanPullMoneyBack() external {
    vm.prank(_guardian);
    _portfolio.deallocate(address(_reported), 100e6);
    assertEq(_portfolio.allocationOf(address(_reported)), 0);
  }

  function test_ItWorksAboveALoweredCap() external {
    vm.prank(_guardian);
    _portfolio.setCaps(_PRICED_ID, 0, 0);
    vm.prank(_allocator);
    _portfolio.deallocate(address(_priced), 40e6);
    assertEq(_portfolio.riskOf(_PRICED_ID).allocation, 60e6);
  }

  function test_AGainNeverTakesTheAllocationBelowZero() external {
    _priced.setValue(150e6);
    _asset.mint(address(_priced), 50e6);
    vm.prank(_allocator);
    _portfolio.deallocate(address(_priced), 150e6);
    assertEq(_portfolio.allocationOf(address(_priced)), 0);
    assertEq(_portfolio.riskOf(_PRICED_ID).allocation, 0);
    assertEq(_portfolio.riskOf(_SHARED_ID).allocation, 100e6);
  }

  function test_APricedAdapterThatChargesOnTheWayOutCountsTheChangeInValue() external {
    _priced.setExitFee(2e6);
    vm.expectEmit(address(_portfolio));
    emit IPortfolio.Deallocated(address(_priced), 40e6, 42e6);
    vm.prank(_allocator);
    _portfolio.deallocate(address(_priced), 40e6);
    assertEq(_portfolio.allocationOf(address(_priced)), 58e6);
    assertEq(_portfolio.riskOf(_PRICED_ID).allocation, 58e6);
  }

  function test_DuringAnOutageTheAllocationFallsByWhatCameBack() external {
    _priced.setFresh(false);
    vm.prank(_guardian);
    _portfolio.deallocate(address(_priced), 40e6);
    assertEq(_portfolio.allocationOf(address(_priced)), 60e6);
  }

  function test_WhenTheAdapterReturnsLess_ItReverts() external {
    _priced.setShortBy(1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_ShortReturn.selector, address(_priced), 40e6, 40e6 - 1));
    vm.prank(_allocator);
    _portfolio.deallocate(address(_priced), 40e6);
  }

  function test_WhenTheAdapterIsNotInstalled_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_UnknownAdapter.selector, address(1)));
    vm.prank(_allocator);
    _portfolio.deallocate(address(1), 1);
  }

  function test_WhenTheAmountIsZero_ItReverts() external {
    vm.expectRevert(IPortfolio.Portfolio_ZeroAmount.selector);
    vm.prank(_allocator);
    _portfolio.deallocate(address(_priced), 0);
  }

  function testFuzz_ARiskAlwaysEqualsTheSumOfItsAdapters(
    uint256[8] calldata _amounts,
    bool[8] calldata _toAdapter,
    bool[8] calldata _priceFirst
  ) external {
    for (uint256 _i; _i < 8; ++_i) {
      MockAdapter _adapter = _priceFirst[_i] ? _priced : _reported;
      if (_toAdapter[_i]) {
        uint256 _idle = _asset.balanceOf(address(_portfolio));
        if (_idle == 0) continue;
        _allocate(_adapter, bound(_amounts[_i], 1, _idle));
      } else {
        uint256 _held = _asset.balanceOf(address(_adapter));
        if (_held == 0) continue;
        vm.prank(_allocator);
        _portfolio.deallocate(address(_adapter), bound(_amounts[_i], 1, _held));
      }
      uint256 _ofPriced = _portfolio.allocationOf(address(_priced));
      uint256 _ofReported = _portfolio.allocationOf(address(_reported));
      assertEq(_portfolio.riskOf(_PRICED_ID).allocation, _ofPriced);
      assertEq(_portfolio.riskOf(_REPORTED_ID).allocation, _ofReported);
      assertEq(_portfolio.riskOf(_SHARED_ID).allocation, _ofPriced + _ofReported);
    }
  }
}

contract PortfolioUnit_Raise is PortfolioUnitTest {
  function setUp() public override {
    super.setUp();
    _allocate(_priced, 900e6);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_priced));
  }

  function test_WhenTheIdleMoneyCoversIt_NothingMoves() external {
    vm.prank(address(_vault));
    _portfolio.raise(100e6);
    assertEq(_portfolio.moves(), 1);
    assertEq(_asset.balanceOf(address(_portfolio)), 100e6);
  }

  function test_ItDrawsOnlyTheShortfallFromTheLiquidityAdapter() external {
    vm.prank(address(_vault));
    _portfolio.raise(150e6);
    assertEq(_asset.balanceOf(address(_portfolio)), 150e6);
    assertEq(_asset.balanceOf(address(_priced)), 850e6);
    assertEq(_portfolio.allocationOf(address(_priced)), 850e6);
    assertEq(_portfolio.moves(), 2);
  }

  function test_TheVaultCanThenPullTheMoney() external {
    vm.startPrank(address(_vault));
    _portfolio.raise(150e6);
    _asset.transferFrom(address(_portfolio), address(_vault), 150e6);
    vm.stopPrank();
    assertEq(_asset.balanceOf(address(_vault)), 150e6);
  }

  function test_WhenAShortfallHasNoLiquidityAdapter_ItReverts() external {
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(0));
    vm.expectRevert(IPortfolio.Portfolio_NoLiquidityAdapter.selector);
    vm.prank(address(_vault));
    _portfolio.raise(150e6);
  }

  function test_TheLiquidityAdapterMustBeInstalled() external {
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_UnknownAdapter.selector, address(1)));
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(1));
  }

  function test_SettingItEmitsAnEvent() external {
    vm.expectEmit(address(_portfolio));
    emit IPortfolio.LiquidityAdapterSet(address(_reported));
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_reported));
    assertEq(_portfolio.liquidityAdapter(), address(_reported));
  }
}

/// @dev A portfolio that refuses reported adapters skips asking each adapter, on the 4626's hot path
contract PortfolioUnit_OnChainOnly is Test {
  bytes32 internal constant _DEFAULT_ADMIN_ROLE = 0x00;
  uint256 internal constant _ADAPTERS = 8;

  /// @dev What a read costs, on a portfolio with eight priced adapters
  function _measure(
    bool _acceptsReported
  ) internal returns (uint256 _pricedValueGas, uint256 _priceFreshGas) {
    MockAsset _asset = new MockAsset(6);
    PolicyRegistry _registry = new PolicyRegistry(address(this), address(this));
    MockPortfolioVault _vault = new MockPortfolioVault(address(_registry));
    _vault.setRole(_DEFAULT_ADMIN_ROLE, address(this), true);
    Portfolio _portfolio = new Portfolio(address(_vault), IERC20(address(_asset)), _acceptsReported);
    bytes32 _attested;
    for (uint256 _i; _i < _ADAPTERS; ++_i) {
      bytes32[] memory _ids = new bytes32[](1);
      _ids[0] = keccak256(abi.encode(_i));
      MockAdapter _adapter = new MockAdapter(address(_portfolio), address(_asset), false, _ids);
      bytes32 _codehash = address(_adapter).codehash;
      if (_codehash != _attested) {
        _registry.attest(_codehash, IPolicyRegistry.AttestKind.ADAPTER, '');
        _attested = _codehash;
      }
      _portfolio.addAdapter(address(_adapter));
    }
    uint256 _before = gasleft();
    _portfolio.pricedValue();
    _pricedValueGas = _before - gasleft();
    _before = gasleft();
    _portfolio.priceFresh();
    _priceFreshGas = _before - gasleft();
  }

  function test_RefusingReportedAdaptersMakesTheReadsCheaper() external {
    (uint256 _valueWhenAccepting, uint256 _freshWhenAccepting) = _measure(true);
    (uint256 _valueWhenRefusing, uint256 _freshWhenRefusing) = _measure(false);
    emit log_named_uint('pricedValue accepting', _valueWhenAccepting);
    emit log_named_uint('pricedValue refusing', _valueWhenRefusing);
    assertLt(_valueWhenRefusing, _valueWhenAccepting);
    assertLt(_freshWhenRefusing, _freshWhenAccepting);
  }

  /// @dev It asks nothing about reported adapters, so a priced adapter still counts
  function test_APricedAdapterStillCountsAndStaleness() external {
    MockAsset _asset = new MockAsset(6);
    PolicyRegistry _registry = new PolicyRegistry(address(this), address(this));
    MockPortfolioVault _vault = new MockPortfolioVault(address(_registry));
    _vault.setRole(_DEFAULT_ADMIN_ROLE, address(this), true);
    Portfolio _portfolio = new Portfolio(address(_vault), IERC20(address(_asset)), false);
    bytes32[] memory _ids = new bytes32[](1);
    _ids[0] = keccak256('one');
    MockAdapter _adapter = new MockAdapter(address(_portfolio), address(_asset), false, _ids);
    _registry.attest(address(_adapter).codehash, IPolicyRegistry.AttestKind.ADAPTER, '');
    _portfolio.addAdapter(address(_adapter));
    _adapter.setValue(70);
    assertEq(_portfolio.pricedValue(), 70);
    assertTrue(_portfolio.priceFresh());
    _adapter.setFresh(false);
    assertFalse(_portfolio.priceFresh());
  }
}

contract PortfolioUnit_Views is PortfolioUnitTest {
  function test_ThePricedValueIsTheIdleMoneyPlusPricedAdaptersOnly() external {
    _allocate(_priced, 100e6);
    _allocate(_reported, 200e6);
    assertEq(_portfolio.pricedValue(), _IDLE - 300e6 + 100e6);
    _priced.setValue(130e6);
    assertEq(_portfolio.pricedValue(), _IDLE - 300e6 + 130e6);
  }

  function test_AnOutageStopsThePriceAndRecoveryRestoresIt() external {
    _allocate(_priced, 100e6);
    uint256 _before = _portfolio.pricedValue();
    assertTrue(_portfolio.priceFresh());

    _priced.setFresh(false);
    assertFalse(_portfolio.priceFresh());

    _priced.setFresh(true);
    assertTrue(_portfolio.priceFresh());
    assertEq(_portfolio.pricedValue(), _before);
  }

  function test_AReportedAdapterNeverStopsThePrice() external {
    _reported.setFresh(false);
    assertTrue(_portfolio.priceFresh());
  }

  function test_LiquidAssetsAreTheIdleMoneyPlusTheLiquidityAdapter() external {
    _allocate(_priced, 100e6);
    _priced.setLiquid(30e6);
    assertEq(_portfolio.liquidAssets(), _IDLE - 100e6);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_priced));
    assertEq(_portfolio.liquidAssets(), _IDLE - 100e6 + 30e6);
  }
}

contract PortfolioUnit_Remove is PortfolioUnitTest {
  function test_AnEmptyPricedAdapterComesOff() external {
    vm.expectEmit(address(_portfolio));
    emit IPortfolio.AdapterRemoved(address(_priced));
    vm.prank(_admin);
    _portfolio.removeAdapter(address(_priced));
    assertEq(_portfolio.adapters().length, 1);
    assertEq(_portfolio.adapters()[0], address(_reported));
  }

  function test_AnAdapterThatLostEverythingComesOffAndItsAllocationClears() external {
    _allocate(_priced, 100e6);
    _priced.setValue(0);
    vm.prank(_admin);
    _portfolio.removeAdapter(address(_priced));
    assertEq(_portfolio.allocationOf(address(_priced)), 0);
    assertEq(_portfolio.riskOf(_PRICED_ID).allocation, 0);
    assertEq(_portfolio.riskOf(_SHARED_ID).allocation, 0);
  }

  function test_RemovingTheLiquidityAdapterClearsIt() external {
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_priced));
    vm.prank(_admin);
    _portfolio.removeAdapter(address(_priced));
    assertEq(_portfolio.liquidityAdapter(), address(0));
  }

  function test_APricedAdapterWithValueStaysOn() external {
    _allocate(_priced, 100e6);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_NotEmpty.selector, address(_priced)));
    vm.prank(_admin);
    _portfolio.removeAdapter(address(_priced));
  }

  function test_AnOutageCannotOrphanAPosition() external {
    _allocate(_priced, 100e6);
    _priced.setValue(0);
    _priced.setFresh(false);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_NotEmpty.selector, address(_priced)));
    vm.prank(_admin);
    _portfolio.removeAdapter(address(_priced));
  }

  function test_AReportedAdapterWithMoneyStaysOn() external {
    _asset.mint(address(_reported), 1);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_NotEmpty.selector, address(_reported)));
    vm.prank(_admin);
    _portfolio.removeAdapter(address(_reported));
  }

  function test_AReportedAdapterWithAnAllocationStaysOnEvenWithNoBalance() external {
    _allocate(_reported, 100e6);
    vm.prank(address(_reported));
    _asset.transfer(makeAddr('custodian'), 100e6);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_NotEmpty.selector, address(_reported)));
    vm.prank(_admin);
    _portfolio.removeAdapter(address(_reported));
  }

  function test_WhenNotInstalled_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_UnknownAdapter.selector, address(1)));
    vm.prank(_admin);
    _portfolio.removeAdapter(address(1));
  }
}

contract PortfolioUnit_WriteOff is PortfolioUnitTest {
  function test_APricedAdapterThatCanStillBeReadCannotBeWrittenOff() external {
    _allocate(_priced, 100e6);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_StillPriced.selector, address(_priced)));
    vm.prank(_admin);
    _portfolio.writeOffAdapter(address(_priced));
  }

  function test_AWriteOffCountsTheLossOnAPricedAdapter() external {
    _allocate(_priced, 100e6);
    uint256 _before = _portfolio.pricedValue();
    _priced.setFresh(false);
    vm.expectEmit(address(_portfolio));
    emit IPortfolio.AdapterWrittenOff(address(_priced), 100e6);
    vm.prank(_admin);
    _portfolio.writeOffAdapter(address(_priced));
    assertEq(_portfolio.pricedValue(), _before - 100e6);
    assertTrue(_portfolio.priceFresh());
    assertEq(_portfolio.riskOf(_PRICED_ID).allocation, 0);
    assertEq(_portfolio.riskOf(_SHARED_ID).allocation, 0);
    assertEq(_portfolio.adapters().length, 1);
  }

  function test_AWriteOffLeavesTheValueAloneOnAReportedAdapter() external {
    _allocate(_reported, 100e6);
    uint256 _before = _portfolio.pricedValue();
    vm.prank(_admin);
    _portfolio.writeOffAdapter(address(_reported));
    assertEq(_portfolio.pricedValue(), _before);
    assertEq(_portfolio.riskOf(_REPORTED_ID).allocation, 0);
    assertEq(_asset.balanceOf(address(_reported)), 100e6, 'the adapter keeps what it holds');
  }

  function test_AWrittenOffAdapterCanBeAddedBack() external {
    _allocate(_priced, 100e6);
    _priced.setFresh(false);
    vm.prank(_admin);
    _portfolio.writeOffAdapter(address(_priced));

    _priced.setFresh(true);
    vm.prank(_admin);
    _portfolio.addAdapter(address(_priced));
    assertEq(_portfolio.pricedValue(), _IDLE, 'the value counts again');
    assertEq(_portfolio.allocationOf(address(_priced)), 100e6, 'and so does its place against the caps');
    assertEq(_portfolio.riskOf(_PRICED_ID).allocation, 100e6);
    assertEq(_portfolio.riskOf(_SHARED_ID).allocation, 100e6);
  }

  function test_AddingAPositionBackCannotTakeExposurePastTheCap() external {
    vm.prank(_admin);
    _portfolio.setCaps(_PRICED_ID, 500e6, _NO_RELATIVE_LIMIT);
    _allocate(_priced, 400e6);
    _priced.setFresh(false);
    vm.prank(_admin);
    _portfolio.writeOffAdapter(address(_priced));
    _priced.setFresh(true);
    vm.prank(_admin);
    _portfolio.addAdapter(address(_priced));

    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_CapExceeded.selector, _PRICED_ID, 500e6 + 1, 500e6));
    _allocate(_priced, 100e6 + 1);
    _allocate(_priced, 100e6);
    assertEq(_priced.value(), 500e6);
  }

  function test_AWriteOffIsRememberedForGood() external {
    assertFalse(_portfolio.writtenOff());
    _allocate(_priced, 100e6);
    _priced.setFresh(false);
    vm.prank(_admin);
    _portfolio.writeOffAdapter(address(_priced));
    assertTrue(_portfolio.writtenOff());

    _priced.setFresh(true);
    vm.prank(_admin);
    _portfolio.addAdapter(address(_priced));
    assertTrue(_portfolio.writtenOff(), 'adding it back does not undo it');
  }

  function test_AReportedWriteOffIsRememberedToo() external {
    vm.prank(_admin);
    _portfolio.writeOffAdapter(address(_reported));
    assertTrue(_portfolio.writtenOff());
  }

  function test_RemovingAnEmptyAdapterIsNotAWriteOff() external {
    vm.prank(_admin);
    _portfolio.removeAdapter(address(_priced));
    assertFalse(_portfolio.writtenOff());
  }

  function test_AnAdapterThatWritesDuringARead_MakesTheCallRevert() external {
    WritingAdapter _adapter = new WritingAdapter(address(_portfolio), address(_asset));
    _attest(address(_adapter), true);
    vm.prank(_admin);
    _portfolio.addAdapter(address(_adapter));

    _adapter.setWrites(true);
    vm.expectRevert();
    vm.prank(_admin);
    _portfolio.writeOffAdapter(address(_adapter));
    assertEq(_adapter.touched(), 0);
    assertFalse(_portfolio.writtenOff());
  }

  function test_WritingOffTheLiquidityAdapterClearsIt() external {
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_reported));
    vm.prank(_admin);
    _portfolio.writeOffAdapter(address(_reported));
    assertEq(_portfolio.liquidityAdapter(), address(0));
  }

  function test_WhenNotInstalled_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_UnknownAdapter.selector, address(1)));
    vm.prank(_admin);
    _portfolio.writeOffAdapter(address(1));
  }
}

contract PortfolioUnit_Migrate is PortfolioUnitTest {
  Portfolio internal _successor;

  function setUp() public override {
    super.setUp();
    _successor = new Portfolio(address(_vault), IERC20(address(_asset)), true);
    vm.mockCall(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (address(_successor), IPolicyRegistry.AttestKind.PORTFOLIO)),
      abi.encode(true)
    );
  }

  function _removeAdapters() internal {
    vm.startPrank(_admin);
    _portfolio.removeAdapter(address(_priced));
    _portfolio.removeAdapter(address(_reported));
    vm.stopPrank();
  }

  function test_ItMovesTheIdleMoneyToAnAttestedSuccessor() external {
    _removeAdapters();
    vm.expectEmit(address(_portfolio));
    emit IPortfolio.Migrated(address(_successor), _IDLE);
    vm.prank(_admin);
    _portfolio.migrateTo(address(_successor));
    assertEq(_asset.balanceOf(address(_successor)), _IDLE);
    assertEq(_asset.balanceOf(address(_portfolio)), 0);
  }

  function test_WhileAnAdapterIsInstalled_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_AdaptersInstalled.selector, 2));
    vm.prank(_admin);
    _portfolio.migrateTo(address(_successor));
  }

  function test_WhenTheSuccessorIsNotAttested_ItReverts() external {
    _removeAdapters();
    vm.mockCall(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (address(_successor), IPolicyRegistry.AttestKind.PORTFOLIO)),
      abi.encode(false)
    );
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_NotAttested.selector, address(_successor)));
    vm.prank(_admin);
    _portfolio.migrateTo(address(_successor));
  }

  function test_WhenTheSuccessorServesAnotherVault_ItReverts() external {
    _removeAdapters();
    Portfolio _other = new Portfolio(address(1), IERC20(address(_asset)), true);
    vm.mockCall(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (address(_other), IPolicyRegistry.AttestKind.PORTFOLIO)),
      abi.encode(true)
    );
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_WrongVault.selector, address(_other)));
    vm.prank(_admin);
    _portfolio.migrateTo(address(_other));
  }

  function test_WhenTheSuccessorUsesAnotherAsset_ItReverts() external {
    _removeAdapters();
    MockAsset _otherAsset = new MockAsset(6);
    Portfolio _other = new Portfolio(address(_vault), IERC20(address(_otherAsset)), true);
    vm.mockCall(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (address(_other), IPolicyRegistry.AttestKind.PORTFOLIO)),
      abi.encode(true)
    );
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_WrongAsset.selector, address(_other)));
    vm.prank(_admin);
    _portfolio.migrateTo(address(_other));
  }
}

/// @dev With nothing mocked: a real vault answers the roles, a real registry answers the attestations, and the money goes
///      into a real ERC-4626 vault
contract PortfolioIntegrationTest is Helpers {
  bytes32 internal constant _GUARDIAN_ROLE = keccak256('GUARDIAN_ROLE');
  bytes32 internal constant _ALLOCATOR_ROLE = keccak256('ALLOCATOR_ROLE');
  uint256 internal constant _IDLE = 1000e6;

  address internal _timelock = makeAddr('timelock');
  address internal _council = makeAddr('council');
  address internal _guardian = makeAddr('guardian');
  address internal _allocator = makeAddr('allocator');

  MockAsset internal _asset;
  PolicyRegistry internal _registry;
  Gated4626Vault internal _vault;
  Portfolio internal _portfolio;
  MockERC4626Target internal _target;
  ERC4626Adapter internal _adapter;

  function setUp() public {
    _asset = new MockAsset(6);
    _registry = new PolicyRegistry(_timelock, _council);
    ComplianceHook _hook = new ComplianceHook(_registry);
    _attest(address(_hook), IPolicyRegistry.AttestKind.HOOK);
    _vault = Gated4626Vault(
      address(
        new ERC1967Proxy(
          address(new Gated4626Vault()),
          abi.encodeCall(
            Gated4626Vault.initialize,
            (
              IERC20(address(_asset)),
              'Gated Fund',
              'gFUND',
              _timelock,
              _guardian,
              address(_registry),
              address(_hook),
              new IComplianceRule[](0)
            )
          )
        )
      )
    );
    vm.prank(_timelock);
    _vault.grantRole(_ALLOCATOR_ROLE, _allocator);

    _portfolio = new Portfolio(address(_vault), IERC20(address(_asset)), false);
    _target = new MockERC4626Target(IERC20(address(_asset)));
    _adapter = new ERC4626Adapter(address(_portfolio), _target, bytes32(0));
    _attest(address(_adapter), IPolicyRegistry.AttestKind.ADAPTER);
    vm.startPrank(_timelock);
    _portfolio.setCaps(_adapter.RISK_ID(), 500e6, 10_000);
    _portfolio.addAdapter(address(_adapter));
    vm.stopPrank();
    _asset.mint(address(_portfolio), _IDLE);
  }

  function _attest(
    address _contract,
    IPolicyRegistry.AttestKind _kind
  ) internal {
    vm.prank(_council);
    _registry.attest(_contract.codehash, _kind, 'ipfs://review');
  }

  function _allocate(
    uint256 _assets
  ) internal {
    vm.prank(_allocator);
    _portfolio.allocate(address(_adapter), _assets, 0);
  }

  function test_WhenTheGuardianPausesTheVault_TheAllocatorSendsNothingAndTheGuardianPullsBack() external {
    _allocate(100e6);
    vm.prank(_guardian);
    _vault.pause();

    vm.expectRevert(IPortfolio.Portfolio_VaultPaused.selector);
    vm.prank(_allocator);
    _portfolio.allocate(address(_adapter), 1e6, 0);

    vm.prank(_guardian);
    _portfolio.deallocate(address(_adapter), 100e6);
    assertEq(_asset.balanceOf(address(_portfolio)), _IDLE);
  }

  function test_TheMoneyGoesInGrowsAndComesBack() external {
    _allocate(400e6);
    assertEq(_asset.balanceOf(address(_portfolio)), 600e6);
    assertEq(_asset.balanceOf(address(_target)), 400e6);
    assertApproxEqAbs(_portfolio.pricedValue(), _IDLE, 1);
    assertEq(_portfolio.allocationOf(address(_adapter)), _portfolio.riskOf(_adapter.RISK_ID()).allocation);

    _asset.mint(address(_target), 40e6); // the target earns 10%
    assertApproxEqAbs(_portfolio.pricedValue(), _IDLE + 40e6, 1);

    uint256 _all = _target.maxWithdraw(address(_adapter));
    vm.prank(_allocator);
    _portfolio.deallocate(address(_adapter), _all);
    assertApproxEqAbs(_asset.balanceOf(address(_portfolio)), _IDLE + 40e6, 1);
    assertEq(_portfolio.allocationOf(address(_adapter)), 0, 'a gain leaves nothing against the cap');
  }

  function test_ALossShowsAtOnceAndKeepsItsPlaceAgainstTheCap() external {
    _allocate(400e6);
    _target.lose(100e6);
    assertApproxEqAbs(_portfolio.pricedValue(), _IDLE - 100e6, 1);
    assertTrue(_portfolio.priceFresh());
    assertApproxEqAbs(_portfolio.allocationOf(address(_adapter)), 400e6, 1);
  }

  function test_TheCapHoldsAgainstARealTarget() external {
    _allocate(500e6);
    vm.expectRevert(
      abi.encodeWithSelector(IPortfolio.Portfolio_CapExceeded.selector, _adapter.RISK_ID(), 500e6 + 1, 500e6)
    );
    _allocate(1);
  }

  function test_RolesAreTheVaultsOwnAndARevocationStopsThemAtOnce() external {
    _allocate(100e6);
    vm.prank(_guardian);
    _portfolio.deallocate(address(_adapter), 10e6);

    vm.prank(_timelock);
    _vault.revokeRole(_GUARDIAN_ROLE, _guardian);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_Unauthorized.selector, _guardian));
    vm.prank(_guardian);
    _portfolio.deallocate(address(_adapter), 10e6);

    vm.prank(_timelock);
    _vault.revokeRole(_ALLOCATOR_ROLE, _allocator);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_Unauthorized.selector, _allocator));
    _allocate(1);
  }

  function test_TheVaultsRegistryDecidesAndTheKindMustMatch() external {
    ERC4626Adapter _unattested = new ERC4626Adapter(address(_portfolio), _target, keccak256('shared'));
    vm.startPrank(_timelock);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_NotAttested.selector, address(_unattested)));
    _portfolio.addAdapter(address(_unattested));
    vm.stopPrank();

    _attest(address(_unattested), IPolicyRegistry.AttestKind.RULE);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_NotAttested.selector, address(_unattested)));
    vm.prank(_timelock);
    _portfolio.addAdapter(address(_unattested));
  }

  function test_AnOutageHoldsThePriceAndCannotOrphanThePosition() external {
    _allocate(400e6);
    uint256 _before = _portfolio.pricedValue();

    _target.setBroken(true);
    assertFalse(_portfolio.priceFresh());
    assertEq(_adapter.value(), 0);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_NotEmpty.selector, address(_adapter)));
    vm.prank(_timelock);
    _portfolio.removeAdapter(address(_adapter));
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_StalePrice.selector, address(_adapter)));
    _allocate(1);

    _target.setBroken(false);
    assertTrue(_portfolio.priceFresh());
    assertEq(_portfolio.pricedValue(), _before);
  }

  function test_AWriteOffDuringAnOutageAndAddingItBackAfter() external {
    _allocate(400e6);
    _target.setBroken(true);
    vm.prank(_timelock);
    _portfolio.writeOffAdapter(address(_adapter));
    assertEq(_portfolio.pricedValue(), 600e6);
    assertTrue(_portfolio.priceFresh());

    _target.setBroken(false);
    vm.prank(_timelock);
    _portfolio.addAdapter(address(_adapter));
    assertApproxEqAbs(_portfolio.pricedValue(), _IDLE, 1);
    assertTrue(_portfolio.writtenOff());
    assertApproxEqAbs(_portfolio.riskOf(_adapter.RISK_ID()).allocation, 400e6, 1, 'back against the cap');
    vm.expectRevert();
    _allocate(100e6 + 2);
  }

  function test_AnAdapterThatCannotBeReadCannotBeInstalled() external {
    MockERC4626Target _outage = new MockERC4626Target(IERC20(address(_asset)));
    ERC4626Adapter _plug = new ERC4626Adapter(address(_portfolio), _outage, bytes32(0));
    _attest(address(_plug), IPolicyRegistry.AttestKind.ADAPTER);
    _outage.setBroken(true);
    vm.expectRevert(abi.encodeWithSelector(IPortfolio.Portfolio_StalePrice.selector, address(_plug)));
    vm.prank(_timelock);
    _portfolio.addAdapter(address(_plug));
  }

  function test_AReentrantTargetCannotAllocateAgainMidCall() external {
    vm.prank(_timelock);
    _vault.grantRole(_ALLOCATOR_ROLE, address(_target)); // so only the guard can stop it
    _target.setReenter(address(_portfolio), address(_adapter));
    vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    _allocate(100e6);
  }

  function test_NothingCanReadThePriceDuringAnAllocation() external {
    _target.setReadsPriceOf(address(_portfolio));
    vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    _allocate(100e6);
  }

  function test_NothingCanReadThePriceDuringADeallocation() external {
    _allocate(100e6);
    _target.setReadsPriceOf(address(_portfolio));
    vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    vm.prank(_allocator);
    _portfolio.deallocate(address(_adapter), 10e6);
  }

  function test_RaisingDrawsOnARealTargetAndTheVaultPulls() external {
    _allocate(500e6);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_adapter));
    assertApproxEqAbs(_portfolio.liquidAssets(), _IDLE, 1);

    vm.startPrank(address(_vault));
    _portfolio.raise(700e6);
    _asset.transferFrom(address(_portfolio), address(_vault), 700e6);
    vm.stopPrank();
    assertEq(_asset.balanceOf(address(_vault)), 700e6);
  }

  function test_ATargetThatReportsNoLiquidityLeavesOnlyTheIdleMoneyToExit() external {
    _allocate(400e6);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_adapter));
    _target.setReportsNoLiquidity(true);
    assertEq(_portfolio.liquidAssets(), 600e6);
  }

  function test_NothingLeavesExceptAlongTheListedPaths() external {
    address _outsider = makeAddr('outsider');
    _allocate(400e6);
    vm.prank(_allocator);
    _portfolio.deallocate(address(_adapter), 100e6);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_adapter));
    vm.prank(address(_vault));
    _portfolio.raise(800e6);
    assertEq(_asset.balanceOf(_outsider), 0);
    assertEq(_asset.allowance(address(_portfolio), _outsider), 0);
    assertEq(_asset.allowance(address(_portfolio), address(_adapter)), 0);
    assertEq(_asset.allowance(address(_adapter), address(_target)), 0);
  }
}
