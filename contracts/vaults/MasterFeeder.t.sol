// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IGatedVaultBase} from 'interfaces/IGatedVaultBase.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {Quals} from 'interfaces/Quals.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {CredentialRule} from 'contracts/hooks/rules/CredentialRule.sol';
import {CredentialRegistry} from 'contracts/identity/CredentialRegistry.sol';
import {FeeModel} from 'contracts/nav/FeeModel.sol';
import {ERC4626Adapter} from 'contracts/portfolio/ERC4626Adapter.sol';
import {Portfolio} from 'contracts/portfolio/Portfolio.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {MockERC4626Target} from 'contracts/test/MockERC4626Target.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';

/**
 * @notice A master fund and two feeder classes, from the parts that exist. The master is a `Gated4626Vault` whose
 *         portfolio invests in an outside vault. Each class is a `Gated4626Vault` whose portfolio holds one
 *         `ERC4626Adapter` into the master. This test contract is every vault's admin and the attester
 */
abstract contract MasterFeederTest is Test {
  struct Class {
    Gated4626Vault vault;
    Portfolio portfolio;
    ERC4626Adapter adapter;
  }

  uint256 internal constant _NOW = 1_792_198_800;
  uint256 internal constant _YEAR = 365 days;
  uint256 internal constant _RATE = 1000; // 10% a year
  uint256 internal constant _IN = 1000e6;
  uint256 internal constant _ONE_SHARE = 1e12;
  bytes32 internal constant _ALLOCATOR_ROLE = keccak256('ALLOCATOR_ROLE');
  uint64 internal constant _FOREVER = type(uint64).max;

  PolicyRegistry internal _registry;
  CredentialRegistry internal _creds;
  CredentialRule internal _rule;
  ComplianceHook internal _hook;
  ProxyDeployer internal _deployer;
  address internal _impl;
  MockAsset internal _asset;

  Gated4626Vault internal _master;
  Portfolio internal _masterPortfolio;
  ERC4626Adapter internal _masterAdapter;
  MockERC4626Target internal _target;
  Class internal _a;
  Class internal _b;

  address internal _guardian = makeAddr('guardian');
  address internal _allocator = makeAddr('allocator');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');
  address internal _recipientA = makeAddr('recipientA');
  address internal _recipientB = makeAddr('recipientB');

  function setUp() public virtual {
    vm.warp(_NOW);
    _registry = new PolicyRegistry(address(this), address(this));
    _creds = new CredentialRegistry(address(this), _guardian);
    _creds.addAttester(address(this), type(uint32).max);
    _rule = new CredentialRule(_creds);
    _registry.attest(address(_rule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _hook = new ComplianceHook(_registry);
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _impl = address(new Gated4626Vault());
    _registry.attest(_impl.codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _deployer = new ProxyDeployer(address(this), _registry);
    _asset = new MockAsset(6);

    // The master admits funds only: its holders are the classes' adapters.
    _target = new MockERC4626Target(IERC20(address(_asset)));
    (_master, _masterPortfolio, _masterAdapter) = _newVault('gMASTER', Quals.FUND, IERC4626(address(_target)));

    // Each class has its own policy: class A admits anyone identified, class B professionals only.
    _a = _newClass('gFEED-A', Quals.KYC);
    _b = _newClass('gFEED-B', Quals.KYC | Quals.PROFESSIONAL);
    _creds.set(_alice, _FOREVER, Quals.KYC, 0);
    _creds.set(_bob, _FOREVER, Quals.KYC | Quals.PROFESSIONAL, 0);

    address[2] memory _investors = [_alice, _bob];
    for (uint256 _i; _i < 2; ++_i) {
      _asset.mint(_investors[_i], 1e15);
      vm.startPrank(_investors[_i]);
      _asset.approve(address(_a.vault), type(uint256).max);
      _asset.approve(address(_b.vault), type(uint256).max);
      vm.stopPrank();
    }
  }

  /// @dev A vault with a portfolio plugged, holding one adapter into `_into`, which is also where exits are raised
  function _newVault(
    string memory _symbol,
    uint32 _requireAll,
    IERC4626 _into
  ) internal returns (Gated4626Vault _vault, Portfolio _portfolio, ERC4626Adapter _adapter) {
    IComplianceRule[] memory _rules = new IComplianceRule[](1);
    _rules[0] = _rule;
    _vault = Gated4626Vault(
      _deployer.deploy(
        _symbol,
        _impl,
        abi.encodeCall(
          Gated4626Vault.initialize,
          (
            IERC20(address(_asset)),
            _symbol,
            _symbol,
            address(this),
            _guardian,
            address(_registry),
            address(_hook),
            _rules
          )
        ),
        address(_hook),
        _rules
      )
    );
    _rule.setPolicy(address(_vault), _requireAll, 0, 0, 1);
    _vault.grantRole(_ALLOCATOR_ROLE, _allocator);

    _portfolio = new Portfolio(address(_vault), IERC20(address(_asset)), false);
    _registry.attest(address(_portfolio).codehash, IPolicyRegistry.AttestKind.PORTFOLIO, '');
    _vault.setPortfolio(address(_portfolio), _RATE);

    _adapter = new ERC4626Adapter(address(_portfolio), _into, bytes32(0));
    _registry.attest(address(_adapter).codehash, IPolicyRegistry.AttestKind.ADAPTER, '');
    _portfolio.addAdapter(address(_adapter));
    _portfolio.setCaps(_adapter.RISK_ID(), type(uint120).max, 10_000);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_adapter));
  }

  /// @dev A class over the master. Its adapter holds the master's shares and its portfolio receives the master's cash
  function _newClass(
    string memory _symbol,
    uint32 _requireAll
  ) internal returns (Class memory _class) {
    (_class.vault, _class.portfolio, _class.adapter) = _newVault(_symbol, _requireAll, IERC4626(address(_master)));
    _creds.set(address(_class.adapter), _FOREVER, Quals.FUND, 0);
    _creds.set(address(_class.portfolio), _FOREVER, Quals.FUND, 0);
  }

  function _deposit(
    Class storage _class,
    address _who,
    uint256 _assets
  ) internal returns (uint256 _shares) {
    vm.prank(_who);
    _shares = _class.vault.deposit(_assets, _who);
  }

  /// @dev Sends a class's idle money to the master, and the master's on to the outside vault
  function _feed(
    Class storage _class
  ) internal {
    uint256 _idle = _asset.balanceOf(address(_class.portfolio));
    vm.prank(_allocator);
    _class.portfolio.allocate(address(_class.adapter), _idle, 0);
    _invest();
  }

  function _invest() internal {
    uint256 _idle = _asset.balanceOf(address(_masterPortfolio));
    if (_idle == 0) return;
    vm.prank(_allocator);
    _masterPortfolio.allocate(address(_masterAdapter), _idle, 0);
  }

  /// @dev The outside vault earns: every holder of it, so the master, is worth more
  function _earn(
    uint256 _assets
  ) internal {
    _asset.mint(address(_target), _assets);
  }

  function _price(
    Gated4626Vault _vault
  ) internal view returns (uint256 _assetsPerShare) {
    _assetsPerShare = _vault.convertToAssets(_ONE_SHARE * 1e6);
  }

  function _model(
    address _recipient,
    uint256 _managementBps,
    uint256 _performanceBps
  ) internal returns (address _feeModel) {
    _feeModel = address(new FeeModel(_recipient, _managementBps, _performanceBps, 0, false));
    _registry.attest(_feeModel.codehash, IPolicyRegistry.AttestKind.FEE_MODEL, '');
  }
}

contract MasterFeeder_Money is MasterFeederTest {
  function test_TheMoneySitsInOnePlace() external {
    _deposit(_a, _alice, _IN);
    _deposit(_b, _bob, 3 * _IN);
    _feed(_a);
    _feed(_b);

    assertEq(_asset.balanceOf(address(_target)), 4 * _IN, 'all of it is in the outside vault');
    address[9] memory _empty = [
      address(_a.vault),
      address(_a.portfolio),
      address(_a.adapter),
      address(_b.vault),
      address(_b.portfolio),
      address(_b.adapter),
      address(_master),
      address(_masterPortfolio),
      address(_masterAdapter)
    ];
    for (uint256 _i; _i < _empty.length; ++_i) {
      assertEq(_asset.balanceOf(_empty[_i]), 0);
    }
    assertEq(
      _master.balanceOf(address(_a.adapter)) + _master.balanceOf(address(_b.adapter)),
      _master.totalSupply(),
      'the classes are the only holders of the master'
    );
    assertEq(_master.balanceOf(address(_b.adapter)), 3 * _master.balanceOf(address(_a.adapter)));
    assertApproxEqAbs(_a.vault.totalAssets(), _IN, 2);
    assertApproxEqAbs(_b.vault.totalAssets(), 3 * _IN, 2);
    assertApproxEqAbs(_master.totalAssets(), 4 * _IN, 2);
  }

  function test_EachClassAdmitsOnlyItsOwnInvestors() external view {
    assertEq(_a.vault.maxDeposit(_bob), type(uint256).max, 'a professional is also identified');
    assertEq(_b.vault.maxDeposit(_alice), 0);
    assertEq(_master.maxDeposit(_alice), 0, 'no investor enters the master directly');
    assertEq(_master.maxDeposit(_bob), 0);
    assertEq(_master.maxDeposit(address(_a.adapter)), type(uint256).max);
  }

  /// @dev The adapter is the holder of the master's shares, so the master's policy must admit it
  function test_AClassWhoseAdapterTheMasterDoesNotAdmitCannotInvest() external {
    _creds.set(address(_a.adapter), _FOREVER, 0, 0);
    _deposit(_a, _alice, _IN);
    vm.expectRevert();
    vm.prank(_allocator);
    _a.portfolio.allocate(address(_a.adapter), _IN, 0);
  }

  /// @dev The adapter withdraws to its portfolio, a receiver other than the owner, so the master judges the portfolio too
  function test_AClassWhosePortfolioTheMasterDoesNotAdmitCannotLeave() external {
    uint256 _shares = _deposit(_a, _alice, _IN);
    _feed(_a);
    _creds.set(address(_a.portfolio), _FOREVER, 0, 0);
    assertEq(_a.vault.maxRedeem(_alice), _shares, 'and the view cannot say so');
    vm.expectPartialRevert(IGatedVaultBase.GatedVault_ThirdPartyNotEligible.selector);
    vm.prank(_alice);
    _a.vault.redeem(_shares, _alice, _alice);
  }

  function test_AnInvestorLeavesThroughTheMasterInOneCall() external {
    uint256 _shares = _deposit(_a, _alice, _IN);
    _deposit(_b, _bob, 3 * _IN);
    _feed(_a);
    _feed(_b);
    uint256 _before = _asset.balanceOf(_alice);
    uint256 _max = _a.vault.maxRedeem(_alice);
    assertApproxEqRel(_max, _shares, 1e9, 'all but dust is liquid');
    vm.prank(_alice);
    _a.vault.redeem(_max, _alice, _alice);
    assertApproxEqAbs(_asset.balanceOf(_alice), _before + _IN, 3);
    assertApproxEqAbs(_asset.balanceOf(address(_target)), 3 * _IN, 3);
    assertApproxEqAbs(_b.vault.totalAssets(), 3 * _IN, 2, 'the other class is untouched');
  }

  function testFuzz_ARoundTripThroughTheMasterNeverProfits(
    uint256 _assets,
    uint256 _gain
  ) external {
    _assets = bound(_assets, 1, 1e13);
    _deposit(_b, _bob, 3 * _IN);
    _feed(_b);
    _earn(bound(_gain, 0, 3 * _IN));
    uint256 _before = _asset.balanceOf(_alice);
    uint256 _shares = _deposit(_a, _alice, _assets);
    _feed(_a);
    uint256 _max = _a.vault.maxRedeem(_alice);
    assertLe(_max, _shares);
    if (_max != 0) {
      vm.prank(_alice);
      _a.vault.redeem(_max, _alice, _alice);
    }
    assertLe(_asset.balanceOf(_alice), _before);
  }
}

contract MasterFeeder_Price is MasterFeederTest {
  function setUp() public override {
    super.setUp();
    _deposit(_a, _alice, _IN);
    _deposit(_b, _bob, 3 * _IN);
    _feed(_a);
    _feed(_b);
  }

  function test_AGainInTheMasterReachesBothPricesInProportion() external {
    uint256 _priceA = _price(_a.vault);
    uint256 _priceB = _price(_b.vault);
    _earn(200e6); // 5% of what the master holds
    assertEq(_price(_a.vault), _priceA, 'no gain counts in the block it arrives');
    vm.warp(block.timestamp + _YEAR);

    assertApproxEqRel(_master.totalAssets(), 4200e6, 1e12);
    assertApproxEqRel(_a.vault.totalAssets(), 1050e6, 1e12);
    assertApproxEqRel(_b.vault.totalAssets(), 3150e6, 1e12);
    assertApproxEqRel(_price(_a.vault), _priceA * 105 / 100, 1e12);
    assertApproxEqRel(_price(_b.vault), _priceB * 105 / 100, 1e12);
    assertLe(_a.vault.totalAssets() + _b.vault.totalAssets(), _master.totalAssets(), 'the classes never count more');
  }

  /// @dev Counted as often as the master, a class sees a gain when a direct holder of the master would
  function test_AGainAboveTheMastersLimitReachesAClassAsFastAsTheMasterCountsIt() external {
    _earn(1200e6); // 30%, three years of the limit
    for (uint256 _i = 1; _i <= 3; ++_i) {
      vm.warp(block.timestamp + _YEAR);
      _master.accrue();
      _a.vault.accrue();
      _b.vault.accrue();
      assertApproxEqRel(_a.vault.totalAssets() * 4, _master.totalAssets(), 1e12);
      assertApproxEqRel(_b.vault.totalAssets() * 4, _master.totalAssets() * 3, 1e12);
    }
    assertApproxEqRel(_master.totalAssets(), 5200e6, 1e12, 'all of it, in the third year');
  }

  /// @dev The limit grows from the last count without compounding, so a class counted less often than the master
  ///      trails it by the compounding, until the gain is all counted
  function test_AClassCountedLessOftenThanTheMasterTrailsItByTheCompounding() external {
    _earn(1200e6);
    vm.warp(block.timestamp + _YEAR);
    _master.accrue();
    vm.warp(block.timestamp + _YEAR);
    assertApproxEqRel(_master.totalAssets(), 4840e6, 1e12, '10% on 10%');
    assertApproxEqRel(_master.convertToAssets(_master.balanceOf(address(_b.adapter))), 3630e6, 1e12);
    assertApproxEqRel(_b.vault.totalAssets(), 3600e6, 1e12, '20% on the last count');
  }

  /// @dev A class has its own limit as well, so one with a lower limit trails the master
  function test_AClassWithALowerLimitOfItsOwnTrailsTheMaster() external {
    vm.prank(_guardian);
    _a.vault.setMaxRate(_RATE / 2);
    _earn(400e6); // 10%
    vm.warp(block.timestamp + _YEAR);
    assertApproxEqRel(_b.vault.totalAssets(), 3300e6, 1e12);
    assertApproxEqRel(_a.vault.totalAssets(), 1050e6, 1e12);
  }

  function test_ALossInTheMasterReachesBothAtOnce() external {
    _target.lose(400e6); // 10%
    assertApproxEqRel(_master.totalAssets(), 3600e6, 1e12);
    assertApproxEqRel(_a.vault.totalAssets(), 900e6, 1e12);
    assertApproxEqRel(_b.vault.totalAssets(), 2700e6, 1e12);
  }

  /// @dev A fall of more than half closes the master, and each class with it, on its own count
  function test_AFallThatClosesTheMasterClosesBothClasses() external {
    _target.lose(2400e6);
    assertTrue(_master.exitOnly());
    assertTrue(_a.vault.exitOnly());
    assertTrue(_b.vault.exitOnly());
    assertEq(_a.vault.maxDeposit(_alice), 0);
    uint256 _before = _asset.balanceOf(_alice);
    uint256 _max = _a.vault.maxRedeem(_alice);
    vm.prank(_alice);
    _a.vault.redeem(_max, _alice, _alice);
    assertApproxEqRel(_asset.balanceOf(_alice) - _before, 400e6, 1e12, 'and its holders still leave');
  }

  /// @dev The gap this test found. While the outside vault cannot be read the master holds its price and stops
  ///      dealing, but its `previewRedeem` still answers, so the class's adapter reads as fresh and the class goes on
  ///      dealing at a price the master itself will not deal at. Money that arrives is idle, and idle money is paid out
  function test_WhileTheMasterCannotPriceAClassStillDeals() external {
    _target.lose(2000e6); // half is lost, and then the outside vault cannot be read: nobody has counted the loss
    _target.setBroken(true);
    assertEq(_master.maxDeposit(address(_a.adapter)), 0, 'the master has stopped');
    assertEq(_master.maxRedeem(address(_a.adapter)), 0);
    assertTrue(_a.adapter.fresh());
    assertTrue(_a.portfolio.priceFresh());

    _creds.set(_bob, _FOREVER, Quals.KYC | Quals.PROFESSIONAL, 0);
    uint256 _before = _asset.balanceOf(_alice);
    _deposit(_a, _bob, _IN); // a newcomer, at the price before the loss
    uint256 _max = _a.vault.maxRedeem(_alice);
    vm.prank(_alice);
    _a.vault.redeem(_max, _alice, _alice);
    assertApproxEqAbs(_asset.balanceOf(_alice) - _before, _IN, 2, 'and an earlier holder leaves whole, on his money');

    _target.setBroken(false);
    assertApproxEqRel(_a.vault.convertToAssets(_a.vault.balanceOf(_bob)), 500e6, 1e12, 'who bears her loss');
  }
}

contract MasterFeeder_Fees is MasterFeederTest {
  function setUp() public override {
    super.setUp();
    _deposit(_a, _alice, _IN);
    _deposit(_b, _bob, 3 * _IN);
    _feed(_a);
    _feed(_b);
    _a.vault.setFeeModel(_model(_recipientA, 100, 0)); // 1% a year of the value
    _b.vault.setFeeModel(_model(_recipientB, 0, 2000)); // 20% of the gain
  }

  function test_EachClassChargesItsOwnFee() external {
    _earn(200e6); // 5%
    vm.warp(block.timestamp + _YEAR);
    _a.vault.accrue();
    _b.vault.accrue();

    assertApproxEqRel(_a.vault.feesOwed(), 10.5e6, 1e13, '1% of 1,050');
    assertApproxEqRel(_b.vault.feesOwed(), 30e6, 1e13, '20% of a gain of 150');
    assertApproxEqRel(_a.vault.totalAssets(), 1050e6 - 10.5e6, 1e13);
    assertApproxEqRel(_b.vault.totalAssets(), 3150e6 - 30e6, 1e13);
    assertEq(_master.feesOwed(), 0, 'the master charges nothing');
    assertApproxEqRel(_master.totalAssets(), 4200e6, 1e12, 'and its price is the same for both');
  }

  /// @dev A class holds no idle money, so its fee is paid once the allocator brings it back from the master
  function test_AFeeIsPaidFromMoneyBroughtBackFromTheMaster() external {
    _earn(200e6);
    vm.warp(block.timestamp + _YEAR);
    _b.vault.accrue();
    uint256 _owed = _b.vault.feesOwed();
    uint256 _priceB = _price(_b.vault);

    _b.vault.collectFees();
    assertEq(_asset.balanceOf(_recipientB), 0, 'nothing idle, nothing paid');
    assertEq(_b.vault.feesOwed(), _owed);

    vm.prank(_allocator);
    _b.portfolio.deallocate(address(_b.adapter), _owed);
    _b.vault.collectFees();
    assertEq(_asset.balanceOf(_recipientB), _owed);
    assertEq(_b.vault.feesOwed(), 0);
    assertApproxEqRel(_price(_b.vault), _priceB, 1e9, 'and the price does not move');
    assertEq(_asset.balanceOf(_recipientA), 0);
  }

  function test_OneClasssFeeDoesNotTouchTheOther() external {
    uint256 _priceA = _price(_a.vault);
    _earn(200e6);
    vm.warp(block.timestamp + _YEAR);
    _b.vault.accrue();
    uint256 _owed = _b.vault.feesOwed();
    vm.prank(_allocator);
    _b.portfolio.deallocate(address(_b.adapter), _owed);
    _b.vault.collectFees();
    // Class A: 5% up, less its own 1% of the value.
    assertApproxEqRel(_price(_a.vault), _priceA * 105 / 100 * 99 / 100, 1e13);
  }
}
