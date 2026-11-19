// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC4626Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';
import {Vm} from 'forge-std/Vm.sol';

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IGated4626Vault} from 'interfaces/IGated4626Vault.sol';
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

/// @notice A real vault, portfolio, adapter and outside vault. This test contract is the vault's admin and the attester
abstract contract Gated4626VaultPortfolioTest is Test {
  uint256 internal constant _NOW = 1_792_198_800;
  uint256 internal constant _YEAR = 365 days;
  uint256 internal constant _RATE = 1000; // 10% a year
  uint256 internal constant _MAX_RATE = 1e9;
  uint256 internal constant _IN = 1000e6;
  bytes32 internal constant _ALLOCATOR_ROLE = keccak256('ALLOCATOR_ROLE');
  bytes32 internal constant _SHARED = keccak256('the target');

  PolicyRegistry internal _registry;
  CredentialRegistry internal _creds;
  CredentialRule internal _rule;
  ComplianceHook internal _hook;
  MockAsset internal _asset;
  Gated4626Vault internal _vault;
  Portfolio internal _portfolio;
  MockERC4626Target internal _target;
  ERC4626Adapter internal _adapter;

  address internal _guardian = makeAddr('guardian');
  address internal _allocator = makeAddr('allocator');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');
  address internal _stranger = makeAddr('stranger');
  address internal _recipient = makeAddr('recipient');

  function setUp() public virtual {
    vm.warp(_NOW);
    _registry = new PolicyRegistry(address(this), address(this));
    _creds = new CredentialRegistry(address(this), _guardian);
    _creds.addAttester(address(this), type(uint32).max);
    _rule = new CredentialRule(_creds);
    _registry.attest(address(_rule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _hook = new ComplianceHook(_registry);
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _asset = new MockAsset(6);

    Gated4626Vault _impl = new Gated4626Vault();
    _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    IComplianceRule[] memory _rules = new IComplianceRule[](1);
    _rules[0] = _rule;
    ProxyDeployer _deployer = new ProxyDeployer(address(this), _registry);
    _vault = Gated4626Vault(
      _deployer.deploy(
        'gFUND',
        address(_impl),
        abi.encodeCall(
          Gated4626Vault.initialize,
          (
            IERC20(address(_asset)),
            'Gated Fund',
            'gFUND',
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
    _rule.setPolicy(address(_vault), Quals.KYC, 0, 0, 1);
    _vault.grantRole(_ALLOCATOR_ROLE, _allocator);
    _creds.set(_alice, uint64(block.timestamp + 3650 days), Quals.KYC, 0);
    _creds.set(_bob, uint64(block.timestamp + 3650 days), Quals.KYC, 0);

    address[2] memory _accounts = [_alice, _bob];
    for (uint256 _i; _i < 2; ++_i) {
      _asset.mint(_accounts[_i], 1e15);
      vm.prank(_accounts[_i]);
      _asset.approve(address(_vault), type(uint256).max);
    }

    _portfolio = _newPortfolio();
    _target = new MockERC4626Target(IERC20(address(_asset)));
    _adapter = new ERC4626Adapter(address(_portfolio), _target, _SHARED);
    _registry.attest(address(_adapter).codehash, IPolicyRegistry.AttestKind.ADAPTER, '');
  }

  function _newPortfolio() internal returns (Portfolio _new) {
    _new = new Portfolio(address(_vault), IERC20(address(_asset)), false);
    // Every portfolio of this vault and asset has one codehash.
    if (_registry.kindOf(address(_new).codehash) == IPolicyRegistry.AttestKind.NONE) {
      _registry.attest(address(_new).codehash, IPolicyRegistry.AttestKind.PORTFOLIO, '');
    }
  }

  function _plug() internal {
    _vault.setPortfolio(address(_portfolio), _RATE);
  }

  function _install() internal {
    _portfolio.addAdapter(address(_adapter));
    _portfolio.setCaps(_adapter.RISK_ID(), type(uint120).max, 10_000);
    _portfolio.setCaps(_SHARED, type(uint120).max, 10_000);
  }

  function _deposit(
    address _who,
    uint256 _assets
  ) internal returns (uint256 _shares) {
    vm.prank(_who);
    _shares = _vault.deposit(_assets, _who);
  }

  function _allocate(
    uint256 _assets
  ) internal {
    vm.prank(_allocator);
    _portfolio.allocate(address(_adapter), _assets, 0);
  }
}

contract Gated4626VaultPortfolio_None is Gated4626VaultPortfolioTest {
  function test_WithNonePluggedTheVaultKeepsItsOwnMoney() external {
    _deposit(_alice, _IN);
    assertEq(_vault.portfolio(), address(0));
    assertEq(_asset.balanceOf(address(_vault)), _IN);
    assertEq(_vault.totalAssets(), _IN);
    assertEq(_vault.lastCounted(), 0);
    vm.warp(block.timestamp + _YEAR);
    assertEq(_vault.totalAssets(), _IN);
  }

  function test_WithNonePluggedAFeeModelAndAnAccrualAreRefused() external {
    vm.expectRevert(IGated4626Vault.Gated4626Vault_NoPortfolio.selector);
    _vault.setFeeModel(address(1));
    vm.expectRevert(IGated4626Vault.Gated4626Vault_NoPortfolio.selector);
    _vault.accrue();
  }

  /// @dev A donation to a vault with none plugged moves its price at once, as any ERC-4626 with virtual shares
  function test_ItsPriceIsTheBalance() external {
    _deposit(_alice, _IN);
    _asset.mint(address(_vault), _IN);
    assertEq(_vault.totalAssets(), 2 * _IN);
  }
}

contract Gated4626VaultPortfolio_Plug is Gated4626VaultPortfolioTest {
  function testFuzz_OnlyTheAdminPlugs(
    address _caller
  ) external {
    if (_caller == address(this)) _caller = _stranger;
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, bytes32(0))
    );
    vm.prank(_caller);
    _vault.setPortfolio(address(_portfolio), _RATE);
  }

  function test_ItMustSetARate() external {
    vm.expectRevert(IGated4626Vault.Gated4626Vault_ZeroRate.selector);
    _vault.setPortfolio(address(_portfolio), 0);
  }

  function test_AnUnattestedPortfolioIsRefused() external {
    Portfolio _rogue = new Portfolio(address(_vault), IERC20(address(_asset)), true);
    vm.expectRevert(abi.encodeWithSelector(IGated4626Vault.Gated4626Vault_NotAttested.selector, address(_rogue)));
    _vault.setPortfolio(address(_rogue), _RATE);
  }

  function test_AnotherVaultsPortfolioIsRefused() external {
    Portfolio _other = new Portfolio(makeAddr('otherVault'), IERC20(address(_asset)), false);
    _registry.attest(address(_other).codehash, IPolicyRegistry.AttestKind.PORTFOLIO, '');
    vm.expectRevert(abi.encodeWithSelector(IGated4626Vault.Gated4626Vault_PortfolioRefused.selector, address(_other)));
    _vault.setPortfolio(address(_other), _RATE);
  }

  function test_APortfolioThatAcceptsReportedAdaptersIsRefused() external {
    Portfolio _reported = new Portfolio(address(_vault), IERC20(address(_asset)), true);
    _registry.attest(address(_reported).codehash, IPolicyRegistry.AttestKind.PORTFOLIO, '');
    vm.expectRevert(
      abi.encodeWithSelector(IGated4626Vault.Gated4626Vault_PortfolioRefused.selector, address(_reported))
    );
    _vault.setPortfolio(address(_reported), _RATE);
  }

  function test_APortfolioForAnotherAssetIsRefused() external {
    MockAsset _other = new MockAsset(6);
    Portfolio _wrong = new Portfolio(address(_vault), IERC20(address(_other)), false);
    _registry.attest(address(_wrong).codehash, IPolicyRegistry.AttestKind.PORTFOLIO, '');
    vm.expectRevert(abi.encodeWithSelector(IGated4626Vault.Gated4626Vault_PortfolioRefused.selector, address(_wrong)));
    _vault.setPortfolio(address(_wrong), _RATE);
  }

  function test_ARateAboveTheCeilingIsRefused() external {
    vm.expectRevert(abi.encodeWithSelector(IGated4626Vault.Gated4626Vault_RateTooHigh.selector, _MAX_RATE + 1));
    _vault.setPortfolio(address(_portfolio), _MAX_RATE + 1);
    _vault.setPortfolio(address(_portfolio), _MAX_RATE);
    assertEq(_vault.maxRate(), _MAX_RATE);
  }

  function test_AFirstPlugStartsFromTheMoneyTheVaultHeldAndKeepsThePrice() external {
    uint256 _shares = _deposit(_alice, _IN);
    uint256 _before = _vault.convertToAssets(_shares);
    vm.expectEmit(address(_vault));
    emit IGated4626Vault.PortfolioSet(address(_portfolio));
    vm.expectEmit(address(_vault));
    emit IGated4626Vault.MaxRateSet(_RATE);
    _plug();
    assertEq(_vault.portfolio(), address(_portfolio));
    assertEq(_vault.maxRate(), _RATE);
    assertEq(_vault.lastCounted(), _IN);
    assertEq(_asset.balanceOf(address(_vault)), 0);
    assertEq(_asset.balanceOf(address(_portfolio)), _IN);
    assertEq(_vault.convertToAssets(_shares), _before);
  }

  function test_APortfolioStillHoldingValueCannotBeReplaced() external {
    _deposit(_alice, _IN);
    _plug();
    Portfolio _next = _newPortfolio();
    vm.expectRevert(IGated4626Vault.Gated4626Vault_PortfolioNotEmpty.selector);
    _vault.setPortfolio(address(_next), _RATE);
  }

  function test_AReplacementKeepsThePrice() external {
    uint256 _shares = _deposit(_alice, _IN);
    _plug();
    uint256 _before = _vault.convertToAssets(_shares);
    Portfolio _next = _newPortfolio();
    _portfolio.migrateTo(address(_next));
    _vault.setPortfolio(address(_next), _RATE);
    assertEq(_vault.lastCounted(), _IN, 'the money was already counted');
    assertEq(_vault.convertToAssets(_shares), _before);
    assertEq(_asset.balanceOf(address(_next)), _IN);
  }

  /// @dev What the new portfolio holds above what was counted is a donation, and counts only under the limit
  function test_ADonationToTheNewPortfolioCountsOnlyUnderTheLimit() external {
    uint256 _shares = _deposit(_alice, _IN);
    _plug();
    Portfolio _next = _newPortfolio();
    _asset.mint(address(_next), _IN);
    _portfolio.migrateTo(address(_next));
    _vault.setPortfolio(address(_next), _RATE);
    assertApproxEqAbs(_vault.convertToAssets(_shares), _IN, 1);
  }
}

contract Gated4626VaultPortfolio_Replacement is Gated4626VaultPortfolioTest {
  uint256 internal _shares;
  Portfolio internal _next;

  function setUp() public override {
    super.setUp();
    _plug();
    _shares = _deposit(_alice, _IN);
    _next = _newPortfolio();
  }

  /// @dev A timelock batch has no gap, and nothing makes a timelock use one. Anyone can call `accrue` in a gap
  function test_InTheGapThePriceHoldsAndDealingStops() external {
    _portfolio.migrateTo(address(_next));
    assertEq(_vault.totalAssets(), _IN);
    vm.warp(block.timestamp + _YEAR);
    vm.prank(_stranger);
    _vault.accrue();
    assertEq(_vault.lastCounted(), _IN);
    assertEq(_vault.totalAssets(), _IN);
    assertEq(_vault.maxDeposit(_bob), 0);
    assertEq(_vault.maxMint(_bob), 0);
    assertEq(_vault.maxRedeem(_alice), 0);
    assertEq(_vault.maxWithdraw(_alice), 0);
    vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, _bob, 1, 0));
    vm.prank(_bob);
    _vault.deposit(1, _bob);

    _vault.setPortfolio(address(_next), _RATE);
    assertEq(_vault.totalAssets(), _IN);
    assertApproxEqRel(_deposit(_bob, _IN), _shares, 0.0001e18, 'the next investor pays the same price');
  }

  /// @dev Money sent to the outgoing portfolio in the gap cannot set the price, and follows the rest
  function test_ADonationInTheGapCannotSetThePrice() external {
    _portfolio.migrateTo(address(_next));
    _asset.mint(address(_portfolio), 1);
    _vault.accrue();
    assertEq(_vault.lastCounted(), _IN);
    vm.expectRevert(IGated4626Vault.Gated4626Vault_PortfolioNotEmpty.selector);
    _vault.setPortfolio(address(_next), _RATE);
    _portfolio.migrateTo(address(_next));
    _vault.setPortfolio(address(_next), _RATE);
    assertEq(_vault.totalAssets(), _IN);
    assertEq(_asset.balanceOf(address(_next)), _IN + 1);
  }

  /// @dev With the target out and nothing idle, `pricedValue()` is 0 and the position is still there
  function test_APortfolioWithAnAdapterOnItsListCannotBeReplaced() external {
    _install();
    _allocate(_IN);
    _target.setBroken(true);
    assertEq(_portfolio.pricedValue(), 0);
    vm.expectRevert(IGated4626Vault.Gated4626Vault_PortfolioNotEmpty.selector);
    _vault.setPortfolio(address(_next), _RATE);
  }

  /// @dev An adapter worth nothing still has to come off first, so a replacement never leaves one behind
  function test_AnEmptyAdapterComesOffFirst() external {
    _install();
    vm.prank(_alice);
    _vault.redeem(_shares, _alice, _alice);
    assertEq(_portfolio.pricedValue(), 0);
    vm.expectRevert(IGated4626Vault.Gated4626Vault_PortfolioNotEmpty.selector);
    _vault.setPortfolio(address(_next), _RATE);
    _portfolio.removeAdapter(address(_adapter));
    _vault.setPortfolio(address(_next), _RATE);
    assertEq(_vault.portfolio(), address(_next));
  }

  /// @dev Half a year at 10% with the money waiting. The next depositor would otherwise buy that gain cheap
  function test_AReplacementKeepsWhatTheLimitHadAllowed() external {
    _asset.mint(address(_portfolio), _IN);
    vm.warp(block.timestamp + _YEAR / 2);
    uint256 _due = _vault.totalAssets();
    assertEq(_due, _IN + _IN * _RATE / 10_000 / 2);
    _portfolio.migrateTo(address(_next));
    _vault.setPortfolio(address(_next), _RATE);
    assertEq(_vault.totalAssets(), _due);
    _vault.accrue();
    assertEq(_vault.lastCounted(), _due);
  }

  /// @dev A replacement is no reason to jump: what the limit had not allowed still waits for it
  function test_AReplacementKeepsTheRestUnderTheLimit() external {
    _asset.mint(address(_portfolio), _IN);
    _portfolio.migrateTo(address(_next));
    _vault.setPortfolio(address(_next), _RATE);
    assertEq(_vault.totalAssets(), _IN);
    vm.warp(block.timestamp + _YEAR);
    assertEq(_vault.totalAssets(), _IN + _IN * _RATE / 10_000);
  }

  /// @dev A plug naming the wrong portfolio writes nothing down, so the money can still follow it
  function test_APlugOfAnEmptyPortfolioStopsDealingUntilTheMoneyArrives() external {
    Portfolio _other = _newPortfolio();
    _portfolio.migrateTo(address(_next));
    _vault.setPortfolio(address(_other), _RATE);
    assertEq(_vault.totalAssets(), 0);
    _vault.accrue();
    assertEq(_vault.lastCounted(), _IN);
    assertEq(_vault.maxDeposit(_bob), 0);
    _next.migrateTo(address(_other));
    assertEq(_vault.totalAssets(), _IN);
    assertGt(_vault.maxDeposit(_bob), 0);
  }
}

contract Gated4626VaultPortfolio_Money is Gated4626VaultPortfolioTest {
  function setUp() public override {
    super.setUp();
    _plug();
    _install();
  }

  function test_ADepositGoesOnToThePortfolio() external {
    _deposit(_alice, _IN);
    assertEq(_asset.balanceOf(address(_vault)), 0);
    assertEq(_asset.balanceOf(address(_portfolio)), _IN);
    assertEq(_vault.lastCounted(), _IN);
    assertEq(_vault.totalAssets(), _IN);
  }

  function test_AWithdrawalFromIdleMoney() external {
    _deposit(_alice, _IN);
    uint256 _before = _asset.balanceOf(_alice);
    vm.prank(_alice);
    _vault.withdraw(400e6, _alice, _alice);
    assertEq(_asset.balanceOf(_alice), _before + 400e6);
    assertEq(_vault.lastCounted(), _IN - 400e6);
    assertEq(_asset.balanceOf(address(_vault)), 0);
  }

  function test_AWithdrawalAboveIdleUsesTheLiquidityAdapter() external {
    _deposit(_alice, _IN);
    _allocate(800e6);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_adapter));
    uint256 _before = _asset.balanceOf(_alice);
    vm.prank(_alice);
    _vault.withdraw(500e6, _alice, _alice);
    assertEq(_asset.balanceOf(_alice), _before + 500e6);
    assertEq(_asset.balanceOf(address(_vault)), 0);
    assertApproxEqAbs(_adapter.value(), 500e6, 2);
  }

  function test_RedeemingMaxRedeemSucceedsAndOneMoreReverts() external {
    uint256 _shares = _deposit(_alice, _IN);
    _allocate(800e6);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_adapter));
    uint256 _max = _vault.maxRedeem(_alice);
    assertEq(_max, _shares);
    vm.expectRevert(
      abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, _alice, _max + 1, _max)
    );
    vm.prank(_alice);
    _vault.redeem(_max + 1, _alice, _alice);
    vm.prank(_alice);
    _vault.redeem(_max, _alice, _alice);
    assertEq(_vault.balanceOf(_alice), 0);
  }

  function test_WithNoLiquidityAdapter_ExitIsLimitedToIdleMoney() external {
    uint256 _shares = _deposit(_alice, _IN);
    _allocate(800e6);
    assertApproxEqRel(_vault.maxWithdraw(_alice), 200e6, 0.001e18);
    assertLt(_vault.maxRedeem(_alice), _shares);
    uint256 _max = _vault.maxRedeem(_alice);
    vm.prank(_alice);
    _vault.redeem(_max, _alice, _alice);
    assertEq(_vault.maxRedeem(_alice), 0);
  }

  /// @dev Rounding the liquid assets down to shares must not strand dust when the holder's whole position is liquid
  function testFuzz_WhenAHoldersWholePositionIsLiquid_MaxRedeemIsAllOfIt(
    uint256 _assets
  ) external {
    uint256 _shares = _deposit(_alice, bound(_assets, 1, 1e13));
    assertEq(_vault.maxRedeem(_alice), _shares);
    vm.prank(_alice);
    _vault.redeem(_shares, _alice, _alice);
    assertEq(_vault.balanceOf(_alice), 0);
  }

  function test_WithATargetThatReportsNoLiquidity_ExitIsLimitedToIdleMoney() external {
    _deposit(_alice, _IN);
    _allocate(800e6);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_adapter));
    _target.setReportsNoLiquidity(true);
    assertApproxEqRel(_vault.maxWithdraw(_alice), 200e6, 0.001e18);
  }

  function test_RedeemingMaxRedeemInAPartLiquidVaultSucceeds() external {
    _deposit(_alice, _IN);
    _deposit(_bob, _IN);
    _allocate(1500e6);
    uint256 _max = _vault.maxRedeem(_alice);
    vm.prank(_alice);
    _vault.redeem(_max, _alice, _alice);
    assertLt(_asset.balanceOf(address(_portfolio)), 2);
  }

  /// @dev A round trip in one block never profits
  function testFuzz_ARoundTripInOneBlockNeverProfits(
    uint256 _first,
    uint256 _second,
    uint256 _donation
  ) external {
    _first = bound(_first, 1e6, 1e12);
    _second = bound(_second, 1, 1e12);
    _donation = bound(_donation, 0, 1e12);
    _deposit(_alice, _first);
    vm.warp(block.timestamp + 30 days);
    _asset.mint(address(_portfolio), _donation);

    uint256 _before = _asset.balanceOf(_bob);
    uint256 _shares = _deposit(_bob, _second);
    if (_shares == 0) return;
    vm.prank(_bob);
    _vault.redeem(_shares, _bob, _bob);
    assertLe(_asset.balanceOf(_bob), _before);
  }
}

contract Gated4626VaultPortfolio_Counting is Gated4626VaultPortfolioTest {
  uint256 internal _shares;

  function setUp() public override {
    super.setUp();
    _plug();
    _install();
    _shares = _deposit(_alice, _IN);
  }

  function test_ADonationCannotJumpThePrice() external {
    _asset.mint(address(_portfolio), _IN);
    assertEq(_vault.totalAssets(), _IN);
  }

  function test_ADonationCountsOnlyUnderTheLimit() external {
    _asset.mint(address(_portfolio), _IN);
    vm.warp(block.timestamp + _YEAR / 2);
    assertEq(_vault.totalAssets(), _IN + _IN * _RATE / 10_000 / 2);
    vm.warp(block.timestamp + 100 * _YEAR);
    assertEq(_vault.totalAssets(), 2 * _IN, 'never above the priced value');
  }

  function test_NoGainCountsAgainInTheSameBlock() external {
    _asset.mint(address(_portfolio), _IN);
    vm.warp(block.timestamp + _YEAR);
    _vault.accrue();
    uint256 _counted = _vault.lastCounted();
    assertEq(_counted, _IN + _IN * _RATE / 10_000);
    assertEq(_vault.totalAssets(), _counted);
    _vault.accrue();
    assertEq(_vault.lastCounted(), _counted);
  }

  function test_ALossCountsAtOnce() external {
    _allocate(_IN);
    _target.lose(100e6);
    assertApproxEqAbs(_vault.totalAssets(), 900e6, 2);
    _vault.accrue();
    assertApproxEqAbs(_vault.lastCounted(), 900e6, 2);
  }

  /// @dev A read of nothing writes nothing: a holder cannot sell for nothing, and nobody buys for nothing
  function test_AReadOfNothingIsNotWrittenDownAndDealingStops() external {
    _allocate(_IN);
    _target.lose(_IN);
    assertTrue(_portfolio.priceFresh());
    assertEq(_portfolio.pricedValue(), 0);
    assertEq(_vault.totalAssets(), 0);
    vm.prank(_stranger);
    _vault.accrue();
    assertEq(_vault.lastCounted(), _IN);
    assertEq(_vault.maxDeposit(_bob), 0);
    assertEq(_vault.maxMint(_bob), 0);
    assertEq(_vault.maxRedeem(_alice), 0);
    assertEq(_vault.maxWithdraw(_alice), 0);
    vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, _bob, 1, 0));
    vm.prank(_bob);
    _vault.deposit(1, _bob);
    vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, _alice, 1, 0));
    vm.prank(_alice);
    _vault.redeem(1, _alice, _alice);
  }

  function test_WhenTheValueReturnsThePriceIsWhatItWas() external {
    _allocate(_IN);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_adapter));
    _target.lose(_IN);
    _vault.accrue();
    vm.warp(block.timestamp + 30 days);
    _asset.mint(address(_target), _IN);
    assertApproxEqAbs(_vault.totalAssets(), _IN, 2);
    assertApproxEqRel(_vault.maxRedeem(_alice), _shares, 0.0001e18);
    assertGt(_vault.maxDeposit(_bob), 0);
  }

  /// @dev A value below what was counted, and not nothing, counts at once. Up to half of it leaves deposits open
  function test_ALowReadIsStillALoss() external {
    _allocate(_IN);
    _target.lose(_IN * 4 / 10);
    _vault.accrue();
    assertApproxEqAbs(_vault.lastCounted(), _IN * 6 / 10, 2);
    assertGt(_vault.maxDeposit(_bob), 0);
  }

  /// @dev With no shares there is nobody to protect, and a unit of rounding left in `last` must not close the vault
  function test_WithNoSharesAReadOfNothingDoesNotStopDeposits() external {
    _allocate(_IN);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_adapter));
    _asset.mint(address(_target), 1e6);
    vm.warp(block.timestamp + _YEAR);
    uint256 _all = _vault.balanceOf(_alice);
    vm.prank(_alice);
    _vault.redeem(_all, _alice, _alice);
    assertEq(_vault.totalSupply(), 0);
    assertGt(_vault.lastCounted(), 0);

    _target.lose(_asset.balanceOf(address(_target)));
    assertEq(_portfolio.pricedValue(), 0);
    assertGt(_vault.maxDeposit(_bob), 0);
    assertGt(_deposit(_bob, _IN), 0);
    assertEq(_vault.totalAssets(), _IN);
  }

  /// @dev Dust is not a holder to protect either: with less than a unit of shares left a read of nothing stops nothing
  function test_WithDustAReadOfNothingDoesNotStopDeposits() external {
    _allocate(_IN);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_adapter));
    _asset.mint(address(_target), 1e6);
    vm.warp(block.timestamp + _YEAR);
    vm.prank(_alice);
    _vault.redeem(_shares - 1, _alice, _alice);
    assertEq(_vault.totalSupply(), 1);
    assertGt(_vault.lastCounted(), 0);

    _target.lose(_asset.balanceOf(address(_target)));
    assertEq(_portfolio.pricedValue(), 0);
    assertGt(_vault.maxDeposit(_bob), 0);
    assertGt(_deposit(_bob, _IN), 0);
    assertEq(_vault.totalAssets(), _IN);
  }

  /// @dev A million share units are a holder: a read of nothing still stops dealing for them
  function test_WithAMillionShareUnitsAReadOfNothingStillStopsDealing() external {
    _allocate(_IN);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_adapter));
    vm.prank(_alice);
    _vault.redeem(_shares - 1e6, _alice, _alice);
    assertEq(_vault.totalSupply(), 1e6);
    assertGt(_vault.lastCounted(), 0);

    _target.lose(_asset.balanceOf(address(_target)));
    assertEq(_portfolio.pricedValue(), 0);
    assertEq(_vault.maxDeposit(_bob), 0);
    assertEq(_vault.maxRedeem(_alice), 0);
  }

  /// @dev Nothing counted is not a read of nothing: a holder who withdrew everything leaves dust shares behind
  function test_AVaultDrainedToDustSharesKeepsTakingDeposits() external {
    _allocate(_IN);
    _target.lose(100e6);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_adapter));
    uint256 _max = _vault.maxWithdraw(_alice);
    vm.prank(_alice);
    _vault.withdraw(_max, _alice, _alice);
    assertEq(_vault.lastCounted(), 0);
    assertGt(_vault.totalSupply(), 0);
    assertGt(_vault.maxDeposit(_bob), 0);
    assertGt(_deposit(_bob, _IN), 0);
    assertApproxEqAbs(_vault.totalAssets(), _IN, 2);
  }

  /// @dev A `try` does not catch a target with no code, which a bad upgrade of the target's proxy can leave
  function test_WhenTheTargetHasNoCodeThePriceHoldsAndItCanBeWrittenOff() external {
    _allocate(800e6);
    uint256 _held = _vault.totalAssets();
    vm.etch(address(_target), '');
    assertFalse(_portfolio.priceFresh());
    assertEq(_vault.totalAssets(), _held);
    assertEq(_vault.maxDeposit(_bob), 0);
    assertEq(_vault.maxRedeem(_alice), 0);
    _vault.accrue();
    assertEq(_vault.lastCounted(), _held);

    _portfolio.writeOffAdapter(address(_adapter));
    assertTrue(_vault.exitOnly());
    assertApproxEqAbs(_vault.totalAssets(), 200e6, 2);
    uint256 _max = _vault.maxRedeem(_alice);
    vm.prank(_alice);
    assertApproxEqAbs(_vault.redeem(_max, _alice, _alice), 200e6, 2);
  }

  function test_ARateAboveTheCeilingIsRefusedAndTheCeilingIsNot() external {
    vm.expectRevert(abi.encodeWithSelector(IGated4626Vault.Gated4626Vault_RateTooHigh.selector, _MAX_RATE + 1));
    _vault.setMaxRate(_MAX_RATE + 1);
    _vault.setMaxRate(_MAX_RATE);
    assertEq(_vault.maxRate(), _MAX_RATE);
  }

  function testFuzz_NoRateTheAdminCanSetJamsTheVault(
    uint256 _rate,
    uint256 _elapsed
  ) external {
    _vault.setMaxRate(bound(_rate, 0, _MAX_RATE));
    _asset.mint(address(_portfolio), _IN);
    vm.warp(block.timestamp + bound(_elapsed, 0, 1000 * _YEAR));
    _creds.set(_bob, uint64(block.timestamp + 3650 days), Quals.KYC, 0);
    _vault.totalAssets();
    _deposit(_bob, 1e6);
    vm.prank(_bob);
    _vault.withdraw(1e5, _bob, _bob);
    _vault.setMaxRate(1);
  }

  function test_DepositsAndWithdrawalsMoveLastByExactlyTheirAmount() external {
    vm.warp(block.timestamp + 1 days);
    _deposit(_bob, 300e6);
    assertEq(_vault.lastCounted(), _IN + 300e6);
    vm.prank(_bob);
    _vault.withdraw(100e6, _bob, _bob);
    assertEq(_vault.lastCounted(), _IN + 200e6);
  }

  function test_DuringATargetOutageThePriceHoldsAndDealingStops() external {
    _allocate(800e6);
    uint256 _held = _vault.totalAssets();
    _target.setBroken(true);
    assertFalse(_portfolio.priceFresh());
    assertEq(_vault.totalAssets(), _held);
    assertEq(_vault.maxDeposit(_bob), 0);
    assertEq(_vault.maxMint(_bob), 0);
    assertEq(_vault.maxRedeem(_alice), 0);
    assertEq(_vault.maxWithdraw(_alice), 0);
    vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, _bob, 1, 0));
    vm.prank(_bob);
    _vault.deposit(1, _bob);
    vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, _alice, 1, 0));
    vm.prank(_alice);
    _vault.redeem(1, _alice, _alice);

    vm.warp(block.timestamp + _YEAR);
    _vault.accrue(); // nothing to count, and the limit's clock runs on
    assertEq(_vault.lastCounted(), _held);
    _asset.mint(address(_portfolio), _IN);

    _target.setBroken(false);
    assertEq(_vault.totalAssets(), _held + _held * _RATE / 10_000, 'it counts under the limit from before the outage');
    assertGt(_vault.maxDeposit(_bob), 0);
  }

  function test_TheRateLimitIsRaisedByTheAdminAndLoweredByTheGuardian() external {
    vm.expectEmit(address(_vault));
    emit IGated4626Vault.MaxRateSet(2000);
    _vault.setMaxRate(2000);
    assertEq(_vault.maxRate(), 2000);
    vm.prank(_guardian);
    _vault.setMaxRate(500);
    assertEq(_vault.maxRate(), 500);
    vm.expectRevert(abi.encodeWithSelector(IGated4626Vault.Gated4626Vault_Unauthorized.selector, _guardian));
    vm.prank(_guardian);
    _vault.setMaxRate(501);
    vm.prank(_guardian);
    _vault.setMaxRate(500);
  }

  function testFuzz_NobodyElseChangesTheRate(
    address _caller
  ) external {
    if (_caller == address(this) || _caller == _guardian) _caller = _stranger;
    vm.expectRevert(abi.encodeWithSelector(IGated4626Vault.Gated4626Vault_Unauthorized.selector, _caller));
    vm.prank(_caller);
    _vault.setMaxRate(1);
  }

  function test_AfterAnOutageWithNoGainThePriceIsWhatItWas() external {
    _allocate(800e6);
    uint256 _held = _vault.totalAssets();
    _target.setBroken(true);
    assertEq(_vault.totalAssets(), _held);
    _target.setBroken(false);
    assertEq(_vault.totalAssets(), _held);
  }

  function test_ARateChangeCountsWhatTheOldRateAllowedFirst() external {
    _asset.mint(address(_portfolio), _IN);
    vm.warp(block.timestamp + _YEAR);
    _vault.setMaxRate(1);
    assertEq(_vault.lastCounted(), _IN + _IN * _RATE / 10_000);
  }
}

contract Gated4626VaultPortfolio_WriteOff is Gated4626VaultPortfolioTest {
  uint256 internal _shares;

  function setUp() public override {
    super.setUp();
    _plug();
    _install();
    _shares = _deposit(_alice, _IN);
    _allocate(800e6);
    _target.setBroken(true);
    _portfolio.writeOffAdapter(address(_adapter));
  }

  function test_AfterAWriteOffTheVaultIsExitOnly() external {
    assertTrue(_vault.exitOnly());
    assertEq(_vault.maxDeposit(_bob), 0);
    assertEq(_vault.maxMint(_bob), 0);
    vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, _bob, 1, 0));
    vm.prank(_bob);
    _vault.deposit(1, _bob);
  }

  function test_TheLossCountsAndHoldersExit() external {
    assertApproxEqAbs(_vault.totalAssets(), 200e6, 2);
    uint256 _max = _vault.maxRedeem(_alice);
    assertEq(_max, _shares);
    vm.prank(_alice);
    _vault.redeem(_max, _alice, _alice);
    assertEq(_vault.balanceOf(_alice), 0);
  }

  function test_AReplacementKeepsTheExitOnlyState() external {
    Portfolio _next = _newPortfolio();
    _portfolio.migrateTo(address(_next));
    _vault.setPortfolio(address(_next), _RATE);
    assertFalse(_next.writtenOff());
    assertTrue(_vault.exitOnly());
    assertEq(_vault.maxDeposit(_bob), 0);
  }
}

/// @notice Someone depositing at the price after a large fall would take part of any recovery from the holders who bore it
contract Gated4626VaultPortfolio_LargeFall is Gated4626VaultPortfolioTest {
  uint256 internal _shares;

  function setUp() public override {
    super.setUp();
    _plug();
    _install();
    _shares = _deposit(_alice, _IN);
  }

  function _depositReverts() internal {
    vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, _bob, 1, 0));
    vm.prank(_bob);
    _vault.deposit(1, _bob);
  }

  function test_AFallOfMoreThanHalfClosesDepositsForGood() external {
    _allocate(_IN);
    _target.lose(_IN * 6 / 10);
    _vault.accrue();
    assertTrue(_vault.exitOnly());
    assertEq(_vault.maxDeposit(_bob), 0);
    assertEq(_vault.maxMint(_bob), 0);
    _depositReverts();

    // The money comes back, and deposits stay closed.
    _asset.mint(address(_target), _IN * 6 / 10);
    vm.warp(block.timestamp + 100 * _YEAR);
    _vault.accrue();
    assertApproxEqAbs(_vault.totalAssets(), _IN, 2);
    assertTrue(_vault.exitOnly());
    assertEq(_vault.maxDeposit(_bob), 0);
  }

  /// @dev Whether the last call emitted `DepositsClosed`, recorded since `vm.recordLogs`
  function _closingWasAnnounced() internal returns (bool _announced) {
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    for (uint256 _i; _i < _logs.length; ++_i) {
      if (_logs[_i].topics[0] == IGated4626Vault.DepositsClosed.selector) _announced = true;
    }
  }

  function test_WhenAFallClosesDeposits_TheCountAnnouncesItOnce() external {
    _allocate(_IN);
    _target.lose(_IN * 6 / 10);
    vm.expectEmit(address(_vault));
    emit IGated4626Vault.DepositsClosed(_portfolio.pricedValue(), _IN);
    _vault.accrue();

    // A further fall of more than half changes nothing that was not already said.
    _target.lose(_portfolio.pricedValue() * 6 / 10);
    vm.recordLogs();
    _vault.accrue();
    assertFalse(_closingWasAnnounced());
    assertTrue(_vault.exitOnly());
  }

  function test_AFallOfExactlyHalfIsNotAnnounced() external {
    _allocate(_IN / 2);
    _target.lose(_asset.balanceOf(address(_target)));
    vm.recordLogs();
    _vault.accrue();
    assertFalse(_closingWasAnnounced());
  }

  /// @dev Half is not more than half, and one unit more is
  function test_AFallOfExactlyHalfLeavesDepositsOpen() external {
    _allocate(_IN / 2);
    _target.lose(_asset.balanceOf(address(_target)));
    assertEq(_portfolio.pricedValue(), _IN / 2);
    _vault.accrue();
    assertFalse(_vault.exitOnly());
    assertGt(_vault.maxDeposit(_bob), 0);
  }

  function test_AFallOfOneUnitMoreThanHalfClosesDeposits() external {
    _allocate(_IN / 2 + 1);
    _target.lose(_asset.balanceOf(address(_target)));
    assertEq(_portfolio.pricedValue(), _IN / 2 - 1);
    _vault.accrue();
    assertTrue(_vault.exitOnly());
  }

  /// @dev In a read of nothing a stranger's unit reopened deposits at a price of about nothing, ahead of any recovery
  function test_AStrangersUnitDuringAReadOfNothingOpensNothing() external {
    _allocate(_IN);
    _target.lose(_IN);
    _asset.mint(address(_portfolio), 1);
    assertEq(_vault.maxDeposit(_bob), 0, 'before it is counted');
    vm.prank(_stranger);
    _vault.accrue();
    assertEq(_vault.lastCounted(), 1);
    assertTrue(_vault.exitOnly());
    assertEq(_vault.maxDeposit(_bob), 0);
    assertEq(_vault.maxMint(_bob), 0);
    _depositReverts();
  }

  /// @dev The views say so before a count, and a deposit's revert writes nothing, so a glitch nobody counts closes nothing
  function test_AFallNobodyCountedClosesNothing() external {
    _allocate(_IN);
    _target.lose(_IN * 6 / 10);
    assertTrue(_vault.exitOnly());
    assertEq(_vault.maxDeposit(_bob), 0);
    assertEq(_vault.maxMint(_bob), 0);
    _depositReverts();
    assertEq(_vault.lastCounted(), _IN);

    _asset.mint(address(_target), _IN * 6 / 10);
    assertFalse(_vault.exitOnly());
    assertGt(_vault.maxDeposit(_bob), 0);
  }

  /// @dev A read of nothing is not counted, so it closes nothing and does not read as closed. Dealing stops through it anyway
  function test_AReadOfNothingDoesNotReadAsClosed() external {
    _allocate(_IN);
    _target.lose(_IN);
    assertFalse(_vault.exitOnly());
    assertEq(_vault.maxDeposit(_bob), 0);
    assertEq(_vault.maxMint(_bob), 0);
    _vault.accrue();
    assertEq(_vault.lastCounted(), _IN);
    assertFalse(_vault.exitOnly());

    _asset.mint(address(_target), _IN);
    assertFalse(_vault.exitOnly());
    assertGt(_vault.maxDeposit(_bob), 0);
  }

  /// @dev What has closed stays closed through a read of nothing
  function test_AClosedVaultStillReadsClosedThroughAReadOfNothing() external {
    _allocate(_IN);
    _target.lose(_IN * 6 / 10);
    _vault.accrue();
    _target.lose(_asset.balanceOf(address(_target)));
    assertEq(_portfolio.pricedValue(), 0);
    assertTrue(_vault.exitOnly());
  }

  /// @dev A write-off that leaves nothing is a read of nothing, and a write-off is for good
  function test_AWriteOffThatLeavesNothingStillReadsClosed() external {
    _allocate(_IN);
    _target.setBroken(true);
    _portfolio.writeOffAdapter(address(_adapter));
    assertEq(_portfolio.pricedValue(), 0);
    assertTrue(_vault.exitOnly());
  }

  /// @dev The view answers what a count would do, whatever the fall: with the value back, only what was counted is left
  function testFuzz_TheViewSaysWhatACountDoes(
    uint256 _tenths
  ) external {
    _allocate(_IN);
    uint256 _lost = _IN * bound(_tenths, 0, 10) / 10;
    _target.lose(_lost);
    bool _said = _vault.exitOnly();
    _vault.accrue();
    _asset.mint(address(_target), _lost);
    assertEq(_vault.exitOnly(), _said);
  }

  /// @dev A holder can still leave at the price the fall left, and that count is what closes deposits
  function test_AHolderLeavingAfterAFallCountsItAndPaysThatPrice() external {
    _allocate(_IN);
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_adapter));
    _target.lose(_IN * 6 / 10);
    uint256 _max = _vault.maxRedeem(_alice);
    vm.prank(_alice);
    uint256 _paid = _vault.redeem(_max, _alice, _alice);
    assertApproxEqAbs(_paid, _IN * 4 / 10, 2);
    assertTrue(_vault.exitOnly());
  }

  /// @dev Money leaving moves the count by exactly what left, so no exit reads as a fall
  function test_AHolderLeavingIsNotAFall() external {
    vm.prank(_alice);
    _vault.withdraw(_IN * 9 / 10, _alice, _alice);
    _vault.accrue();
    assertFalse(_vault.exitOnly());
    assertGt(_vault.maxDeposit(_bob), 0);
  }

  /// @dev With no shares nothing counts, and that is no fall either
  function test_TheLastHolderLeavingIsNotAFall() external {
    _asset.mint(address(_portfolio), 100e6);
    vm.warp(block.timestamp + _YEAR);
    _vault.accrue();
    vm.prank(_alice);
    _vault.redeem(_shares, _alice, _alice);
    assertGt(_vault.lastCounted(), 0, 'the dust');
    assertFalse(_vault.exitOnly());
    _vault.accrue();
    assertFalse(_vault.exitOnly());
    assertGt(_deposit(_bob, _IN), 0);
  }

  /// @dev A write-off closes deposits whatever its size
  function test_AWriteOffOfLessThanHalfStillClosesDeposits() external {
    _allocate(_IN / 10);
    _target.setBroken(true);
    _portfolio.writeOffAdapter(address(_adapter));
    assertEq(_portfolio.pricedValue(), _IN - _IN / 10);
    assertTrue(_vault.exitOnly());
    assertEq(_vault.maxDeposit(_bob), 0);
  }

  /// @dev The limit is on one count: two smaller falls do not add up
  function test_TwoSmallerFallsLeaveDepositsOpen() external {
    _allocate(_IN);
    _target.lose(_IN * 4 / 10);
    _vault.accrue();
    _target.lose(_IN * 3 / 10);
    _vault.accrue();
    assertApproxEqAbs(_vault.lastCounted(), _IN * 3 / 10, 2);
    assertFalse(_vault.exitOnly());
    assertGt(_vault.maxDeposit(_bob), 0);
  }

  function test_AReplacementKeepsItClosed() external {
    _allocate(_IN);
    _target.lose(_IN * 6 / 10);
    _vault.accrue();
    uint256 _back = _adapter.liquid();
    vm.prank(_allocator);
    _portfolio.deallocate(address(_adapter), _back);
    _target.lose(_asset.balanceOf(address(_target)));
    _portfolio.removeAdapter(address(_adapter));
    Portfolio _next = _newPortfolio();
    _portfolio.migrateTo(address(_next));
    _vault.setPortfolio(address(_next), _RATE);
    assertFalse(_next.writtenOff());
    assertTrue(_vault.exitOnly());
    assertEq(_vault.maxDeposit(_bob), 0);
  }
}

contract Gated4626VaultPortfolio_Fees is Gated4626VaultPortfolioTest {
  FeeModel internal _model;
  uint256 internal _shares;

  function setUp() public override {
    super.setUp();
    _plug();
    _install();
    _shares = _deposit(_alice, _IN);
    _model = new FeeModel(_recipient, 200, 2000, 0, false);
    _registry.attest(address(_model).codehash, IPolicyRegistry.AttestKind.FEE_MODEL, '');
  }

  function _charge() internal {
    _vault.setFeeModel(address(_model));
  }

  function testFuzz_OnlyTheAdminPlugsAModel(
    address _caller
  ) external {
    if (_caller == address(this)) _caller = _stranger;
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, bytes32(0))
    );
    vm.prank(_caller);
    _vault.setFeeModel(address(_model));
  }

  function test_AnUnattestedModelIsRefused() external {
    FeeModel _rogue = new FeeModel(_stranger, 500, 5000, 0, false);
    vm.expectRevert(abi.encodeWithSelector(IGated4626Vault.Gated4626Vault_NotAttested.selector, address(_rogue)));
    _vault.setFeeModel(address(_rogue));
  }

  function test_TheFirstPlugStartsTheMarkAtTheCurrentPrice() external {
    vm.expectEmit(address(_vault));
    emit IGated4626Vault.FeeModelSet(address(_model));
    _charge();
    assertEq(_vault.feeModel(), address(_model));
    assertApproxEqRel(_vault.mark(), 1e12, 0.0001e18);
  }

  /// @dev Above par the mark starts at the price, so a gain made before the plug pays nothing
  function test_AFirstPlugAboveParStartsTheMarkAtThePrice() external {
    _asset.mint(address(_portfolio), _IN);
    vm.warp(block.timestamp + _YEAR);
    _charge();
    assertGt(_vault.mark(), 1e12);
    assertEq(_vault.mark(), _vault.convertToAssets(1e18));
  }

  /// @dev Plugged during a read of nothing, a mark taken from `totalAssets()` would charge a performance fee on principal
  function test_AFirstPlugDuringAReadOfNothingStartsTheMarkAtTheLastPrice() external {
    _asset.mint(address(_portfolio), _IN);
    vm.warp(block.timestamp + _YEAR);
    _vault.accrue();
    uint256 _price = _vault.convertToAssets(1e18);
    assertGt(_price, 1e12);
    _allocate(_asset.balanceOf(address(_portfolio)));
    _target.lose(_asset.balanceOf(address(_target)));
    assertEq(_vault.totalAssets(), 0);
    _charge();
    assertEq(_vault.mark(), _price);
  }

  function test_TheManagementFeeAccruesWithTime() external {
    _charge();
    vm.warp(block.timestamp + _YEAR);
    assertEq(_vault.totalAssets(), _IN - 20e6);
    _vault.accrue();
    assertEq(_vault.feesOwed(), 20e6);
    assertEq(_vault.lastCounted(), _IN - 20e6);
    assertEq(_vault.totalAssets(), _IN - 20e6, 'and it charges once');
  }

  /// @dev Fees are charged only on gains that have passed the rate limit
  function test_ADonationDoesNotPayAPerformanceFeeUntilItCounts() external {
    FeeModel _performanceOnly = new FeeModel(_recipient, 0, 2000, 0, false);
    _registry.attest(address(_performanceOnly).codehash, IPolicyRegistry.AttestKind.FEE_MODEL, '');
    _vault.setFeeModel(address(_performanceOnly));
    _asset.mint(address(_portfolio), _IN);
    _vault.accrue();
    assertEq(_vault.feesOwed(), 0);

    vm.warp(block.timestamp + _YEAR);
    _vault.accrue();
    // 10% counted, and 20% of that charged.
    assertApproxEqRel(_vault.feesOwed(), 20e6, 0.001e18);
  }

  /// @dev A soft hurdle: a count inside its catch-up keeps the mark and carries what it charged, and the count that
  ///      completes it charges what one count would have
  function test_ASoftHurdleCarriesItsCatchUpAcrossCounts() external {
    FeeModel _soft = new FeeModel(_recipient, 0, 2000, 1000, true);
    _registry.attest(address(_soft).codehash, IPolicyRegistry.AttestKind.FEE_MODEL, '');
    _vault.setMaxRate(_MAX_RATE);
    _vault.setFeeModel(address(_soft));
    uint256 _mark = _vault.mark();
    uint256 _movedAt = block.timestamp;
    uint256 _supply = _vault.totalSupply();

    // A year on, 10.01% more: just above a 10% hurdle.
    vm.warp(block.timestamp + _YEAR);
    _asset.mint(address(_portfolio), _IN * 1001 / 10_000);
    _vault.accrue();
    uint256 _first = _vault.feesOwed();
    assertGt(_first, 0);
    assertEq(_vault.mark(), _mark, 'the mark waits');
    assertEq(_vault.paidSinceMark(), Math.mulDiv(_first, 1e18, _supply));

    // A day on, 20% in all: the catch-up completes.
    vm.warp(block.timestamp + 1 days);
    _asset.mint(address(_portfolio), _IN * 999 / 10_000);
    (uint256 _once,,,) = _soft.quote(_portfolio.pricedValue(), _supply, _mark, block.timestamp - _movedAt, 0, 0);
    _vault.accrue();
    assertApproxEqAbs(_vault.feesOwed(), _once, 1);
    assertGt(_vault.mark(), _mark);
    assertEq(_vault.paidSinceMark(), 0);
  }

  /// @dev Once everyone has left, what was paid into the catch-up is nobody's, and the next investor must not pay catch-up
  ///      on their principal
  function test_WhenEveryoneHasLeftWhatWasPaidRestarts() external {
    FeeModel _soft = new FeeModel(_recipient, 0, 2000, 1000, true);
    _registry.attest(address(_soft).codehash, IPolicyRegistry.AttestKind.FEE_MODEL, '');
    _vault.setMaxRate(_MAX_RATE);
    _vault.setFeeModel(address(_soft));
    vm.warp(block.timestamp + _YEAR);
    _asset.mint(address(_portfolio), _IN * 1001 / 10_000);
    _vault.accrue();
    assertGt(_vault.paidSinceMark(), 0);
    vm.prank(_alice);
    _vault.redeem(_shares, _alice, _alice);
    assertEq(_vault.totalSupply(), 0);
    _vault.accrue();
    assertEq(_vault.paidSinceMark(), 0);
  }

  function test_ASteadyReturnBelowTheHurdlePaysNoPerformanceFeeHoweverManyCalls() external {
    FeeModel _hurdled = new FeeModel(_recipient, 0, 2000, 2000, true);
    _registry.attest(address(_hurdled).codehash, IPolicyRegistry.AttestKind.FEE_MODEL, '');
    _vault.setFeeModel(address(_hurdled));
    _asset.mint(address(_portfolio), _IN);
    for (uint256 _i; _i < 12; ++_i) {
      vm.warp(block.timestamp + _YEAR / 12);
      _vault.accrue();
    }
    assertEq(_vault.feesOwed(), 0);
  }

  function test_AChargedPerformanceFeeMovesTheMark() external {
    FeeModel _performanceOnly = new FeeModel(_recipient, 0, 2000, 0, false);
    _registry.attest(address(_performanceOnly).codehash, IPolicyRegistry.AttestKind.FEE_MODEL, '');
    _vault.setFeeModel(address(_performanceOnly));
    uint256 _start = _vault.mark();
    _asset.mint(address(_portfolio), _IN);
    vm.warp(block.timestamp + _YEAR);
    vm.expectEmit(false, false, false, false, address(_vault));
    emit IGated4626Vault.Accrued(0, 0);
    _vault.accrue();
    uint256 _moved = _vault.mark();
    assertGt(_moved, _start);

    // The same value does not pay twice.
    uint256 _owed = _vault.feesOwed();
    _vault.accrue();
    assertEq(_vault.feesOwed(), _owed);
    assertEq(_vault.mark(), _moved);
  }

  /// @dev With no shares both clocks restart, so a hurdle runs from when the first investors arrived
  function test_WithNoSharesTheHurdleRestarts() external {
    FeeModel _hurdled = new FeeModel(_recipient, 0, 2000, 500, false);
    _registry.attest(address(_hurdled).codehash, IPolicyRegistry.AttestKind.FEE_MODEL, '');
    vm.prank(_alice);
    _vault.redeem(_shares, _alice, _alice);
    _vault.setFeeModel(address(_hurdled));
    vm.warp(block.timestamp + _YEAR);
    _deposit(_bob, _IN); // counts with no shares, and restarts the clocks

    _asset.mint(address(_portfolio), _IN);
    vm.warp(block.timestamp + 30 days);
    _vault.accrue();
    // 30 days at the 10% limit passes 30 days of a 5% hurdle. A hurdle running for 395 days would not be passed.
    assertGt(_vault.feesOwed(), 0);
  }

  function _performanceOnly() internal {
    FeeModel _onlyPerformance = new FeeModel(_recipient, 0, 2000, 0, false);
    _registry.attest(address(_onlyPerformance).codehash, IPolicyRegistry.AttestKind.FEE_MODEL, '');
    _vault.setFeeModel(address(_onlyPerformance));
  }

  /// @dev After a gain the last holder's redemption rounds down and leaves a unit counted, with no shares
  function _lastHolderLeavesDust() internal {
    _performanceOnly();
    _asset.mint(address(_portfolio), 100e6);
    vm.warp(block.timestamp + _YEAR);
    _vault.accrue();
    vm.prank(_alice);
    _vault.redeem(_shares, _alice, _alice);
    assertEq(_vault.totalSupply(), 0);
    assertGt(_vault.lastCounted(), 0, 'the dust');
    _vault.collectFees();
  }

  /// @dev Priced on that unit the next investor would buy at twice par and pay a performance fee on principal
  function test_WhenTheLastHolderLeavesDustTheNextInvestorPaysNoFeeOnPrincipal() external {
    _lastHolderLeavesDust();
    uint256 _owed = _vault.feesOwed();
    uint256 _bought = _deposit(_bob, _IN);
    assertEq(_bought, _IN * 1e6, 'at par');
    assertEq(_vault.mark(), 1e12);
    vm.warp(block.timestamp + 1 days);
    _vault.accrue();
    assertEq(_vault.feesOwed(), _owed);
    assertApproxEqAbs(_vault.convertToAssets(_bought), _IN, 2);
  }

  function test_WithNoSharesNothingCounts() external {
    _lastHolderLeavesDust();
    assertEq(_vault.totalAssets(), 0);
    _vault.accrue();
    assertEq(_vault.lastCounted(), 0);
    assertEq(_vault.mark(), 1e12);
  }

  /// @dev Whatever is left, and however it got there, the next investor buys at par, and it counts for them under the limit
  function testFuzz_WithNoSharesAnythingLeftStillStrikesAtPar(
    uint256 _left
  ) external {
    _lastHolderLeavesDust();
    _left = bound(_left, 0, 1e15);
    _asset.mint(address(_portfolio), _left);
    uint256 _bought = _deposit(_bob, _IN);
    assertEq(_bought, _IN * 1e6);
    assertEq(_vault.totalAssets(), _IN);
    vm.warp(block.timestamp + _YEAR);
    uint256 _net = _asset.balanceOf(address(_portfolio)) - _vault.feesOwed();
    assertLe(_vault.totalAssets(), _net);
    assertLe(_vault.totalAssets(), _IN + _IN * _RATE / 10_000);
    assertGe(_vault.totalAssets(), _IN);
  }

  /// @dev Getting back to par is a recovery of principal, not a gain
  function test_AFirstPlugBelowParStartsTheMarkAtPar() external {
    _allocate(_IN);
    _target.lose(_IN / 2);
    _vault.accrue();
    assertLt(_vault.convertToAssets(1e18), 1e12);
    _performanceOnly();
    assertEq(_vault.mark(), 1e12);
    _asset.mint(address(_target), _IN / 2);
    vm.warp(block.timestamp + 10 * _YEAR);
    _vault.accrue();
    assertEq(_vault.feesOwed(), 0);
  }

  /// @dev A dust share left after a loss, of up to half as more closes deposits: the next investor buys at about par,
  ///      which a mark below par would charge
  function testFuzz_DustSharesAfterALossDoNotChargeTheNextInvestorOnPrincipal(
    uint256 _lost,
    uint256 _sharesLeft
  ) external {
    _allocate(_IN);
    _target.lose(bound(_lost, 1, _IN / 2 - 2));
    _vault.accrue();
    _performanceOnly();
    vm.prank(_allocator);
    _portfolio.setLiquidityAdapter(address(_adapter));
    uint256 _out = _shares - bound(_sharesLeft, 1, 1e9);
    uint256 _max = _vault.maxRedeem(_alice);
    vm.prank(_alice);
    _vault.redeem(_out < _max ? _out : _max, _alice, _alice);
    _deposit(_bob, _IN);
    vm.warp(block.timestamp + 1 days);
    _vault.accrue();
    assertLe(_vault.feesOwed(), _IN / 1e6);
  }

  /// @dev Shares left behind are not the empty case. A count before the entry lifts the mark above the price the next
  ///      investor buys at, so that investor is not charged on principal either
  function testFuzz_DustSharesDoNotChargeTheNextInvestorOnPrincipal(
    uint256 _sharesLeft
  ) external {
    _performanceOnly();
    _asset.mint(address(_portfolio), 100e6);
    vm.warp(block.timestamp + _YEAR);
    _vault.accrue();
    _sharesLeft = bound(_sharesLeft, 1, 1e9);
    vm.prank(_alice);
    _vault.redeem(_shares - _sharesLeft, _alice, _alice);
    assertEq(_vault.totalSupply(), _sharesLeft);
    _vault.collectFees();
    _deposit(_bob, _IN);
    uint256 _owed = _vault.feesOwed();
    vm.warp(block.timestamp + 1 days);
    _vault.accrue();
    assertLe(_vault.feesOwed() - _owed, _IN / 1e6);
  }

  /// @dev What is already owed is not value to count again
  function test_FeesOwedAreNotCountedAgain() external {
    _charge();
    vm.warp(block.timestamp + _YEAR);
    _vault.accrue();
    assertEq(_vault.totalAssets(), 980e6);
    vm.warp(block.timestamp + _YEAR);
    // A second year's 2% on 980, not on the 1,000 still in the portfolio.
    assertEq(_vault.totalAssets(), 980e6 - 19.6e6);
  }

  function test_FeesArePaidFromIdleMoneyAndThePriceDoesNotMove() external {
    _charge();
    vm.warp(block.timestamp + _YEAR);
    _vault.accrue();
    uint256 _before = _vault.totalAssets();
    vm.expectEmit(address(_vault));
    emit IGated4626Vault.FeesCollected(_recipient, 20e6);
    _vault.collectFees();
    assertEq(_asset.balanceOf(_recipient), 20e6);
    assertEq(_vault.feesOwed(), 0);
    assertEq(_vault.totalAssets(), _before);
  }

  function test_FeesPayOnlyWhatIdleMoneyAllows() external {
    _charge();
    _allocate(_IN - 5e6);
    vm.warp(block.timestamp + _YEAR);
    _vault.collectFees();
    assertEq(_asset.balanceOf(_recipient), 5e6);
    assertApproxEqAbs(_vault.feesOwed(), 15e6, 1);
  }

  function test_WithNoModelNothingIsCollected() external {
    vm.expectRevert(IGated4626Vault.Gated4626Vault_NoFeeModel.selector);
    _vault.collectFees();
  }

  /// @dev After a near-total loss the fees owed can exceed the value, and ERC-4626 says `totalAssets` must not revert.
  ///      Net of the fees that is a read of nothing, so nothing is written down and dealing stops
  function test_ALossBelowTheFeesOwedReadsAsZeroAndNothingReverts() external {
    _charge();
    _allocate(_IN);
    vm.warp(block.timestamp + _YEAR);
    _vault.accrue();
    uint256 _counted = _vault.lastCounted();
    assertGt(_vault.feesOwed(), 0);
    _target.lose(_IN);
    assertEq(_vault.totalAssets(), 0);
    assertEq(_vault.maxRedeem(_alice), 0);
    assertEq(_vault.maxWithdraw(_alice), 0);
    assertEq(_vault.maxDeposit(_bob), 0);
    _vault.convertToAssets(_shares);
    _vault.accrue();
    assertEq(_vault.lastCounted(), _counted);
  }

  /// @dev Idle money below the fees owed: there is cash, and all of it is owed
  function test_AValueBelowTheFeesOwedIsAlsoAReadOfNothing() external {
    _charge();
    _allocate(_IN);
    vm.warp(block.timestamp + _YEAR);
    _vault.accrue();
    uint256 _owed = _vault.feesOwed();
    uint256 _counted = _vault.lastCounted();
    _target.lose(_IN);
    _asset.mint(address(_portfolio), _owed);
    assertEq(_vault.totalAssets(), 0);
    _vault.accrue();
    assertEq(_vault.lastCounted(), _counted);
    assertEq(_vault.maxDeposit(_bob), 0);
    assertFalse(_vault.exitOnly());
    _asset.mint(address(_portfolio), 1);
    assertEq(_vault.totalAssets(), 1);
    assertEq(_vault.maxDeposit(_bob), 0, 'one unit above the fees is a fall of more than half');
    assertTrue(_vault.exitOnly());
    assertGt(_vault.maxRedeem(_alice), 0);
  }

  function test_FeesAreNotPaidWhilePaused() external {
    _charge();
    vm.warp(block.timestamp + _YEAR);
    _vault.accrue();
    vm.prank(_guardian);
    _vault.pause();
    vm.expectRevert(Pausable.EnforcedPause.selector);
    _vault.collectFees();
    assertEq(_asset.balanceOf(_recipient), 0);
  }

  function test_WithNoSharesTheFirstInvestorsDoNotPayForTimeBeforeThey() external {
    vm.prank(_alice);
    _vault.redeem(_shares, _alice, _alice);
    _charge();
    vm.warp(block.timestamp + _YEAR);
    _vault.accrue();
    assertEq(_vault.feesOwed(), 0);

    uint256 _bought = _deposit(_bob, _IN);
    assertEq(_vault.convertToAssets(_bought) + 2, _IN + 2);
  }

  function test_AFeeIsChargedBeforeADepositPrices() external {
    _charge();
    vm.warp(block.timestamp + _YEAR);
    uint256 _preview = _vault.previewDeposit(_IN);
    uint256 _bought = _deposit(_bob, _IN);
    assertEq(_bought, _preview);
    assertEq(_vault.feesOwed(), 20e6);
  }

  function _managementOnly() internal {
    FeeModel _onlyManagement = new FeeModel(_recipient, 100, 0, 0, false);
    _registry.attest(address(_onlyManagement).codehash, IPolicyRegistry.AttestKind.FEE_MODEL, '');
    _vault.setFeeModel(address(_onlyManagement));
  }

  /// @dev A holder alone leaves one share unit. Priced on it, the mark would go a million times above par, and no later
  ///      gain would reach it
  function test_WhenAHolderAloneLeavesOneShareUnitTheMarkStaysAtPar() external {
    _performanceOnly();
    vm.prank(_alice);
    _vault.redeem(_shares - 1, _alice, _alice);
    assertEq(_vault.totalSupply(), 1);
    assertGt(_vault.lastCounted(), 0);
    vm.warp(block.timestamp + 12);
    _vault.accrue();
    assertEq(_vault.lastCounted(), 0);
    assertEq(_vault.mark(), 1e12);

    assertEq(_deposit(_bob, _IN), _IN * (1e6 + 1));
    _asset.mint(address(_portfolio), 2 * _IN);
    vm.warp(block.timestamp + 100 * _YEAR);
    _vault.accrue();
    assertApproxEqRel(_vault.feesOwed(), 400e6, 0.001e18, 'a fifth of a gain of 2,000');
  }

  /// @dev One raw unit buys a million share units at par: fewer is less than a unit between all holders
  function test_FewerThanAMillionShareUnitsCountAsNoShares() external {
    vm.prank(_alice);
    _vault.redeem(_shares - (1e6 - 1), _alice, _alice);
    _vault.accrue();
    assertEq(_vault.totalAssets(), 0);
    assertEq(_vault.lastCounted(), 0);
  }

  function test_AMillionShareUnitsStillCount() external {
    vm.prank(_alice);
    _vault.redeem(_shares - 1e6, _alice, _alice);
    uint256 _left = _vault.lastCounted();
    assertGt(_left, 0);
    _vault.accrue();
    assertEq(_vault.lastCounted(), _left);
    assertEq(_vault.totalAssets(), _left);
  }

  function test_TheLastShareUnitsCanStillBeRedeemed() external {
    vm.prank(_alice);
    _vault.redeem(_shares - 1, _alice, _alice);
    _vault.accrue();
    vm.prank(_alice);
    assertEq(_vault.redeem(1, _alice, _alice), 0);
    assertEq(_vault.totalSupply(), 0);
  }

  /// @dev Whatever dust is left below a million units, and whatever sits in the portfolio, the next investor buys at
  ///      par or below, is not charged on principal, and pays the performance fee on a real gain
  function testFuzz_DustBelowAMillionUnitsKeepsThePrincipalAndTheFee(
    uint256 _dustLeft,
    uint256 _left
  ) external {
    _performanceOnly();
    vm.prank(_alice);
    _vault.redeem(_shares - bound(_dustLeft, 1, 1e6 - 1), _alice, _alice);
    _asset.mint(address(_portfolio), bound(_left, 0, 1e9));
    vm.warp(block.timestamp + 12);
    _vault.accrue();
    assertEq(_vault.mark(), 1e12);
    uint256 _bought = _deposit(_bob, _IN);
    assertGe(_bought, _IN * 1e6);
    vm.warp(block.timestamp + 1 days);
    _vault.accrue();
    assertGe(_vault.convertToAssets(_bought) + 2, _IN);
    _asset.mint(address(_portfolio), 2 * _IN);
    vm.warp(block.timestamp + 100 * _YEAR);
    _vault.accrue();
    assertGt(_vault.feesOwed(), 0);
  }

  /// @dev A count that rounds to no fee restarts the clock. Holding it instead would charge that time to whoever
  ///      arrives next: here 1,000 raw units quiet for 30 days at 1% a year, then 1e13 arriving
  function test_NewMoneyDoesNotPayForTimeBeforeItArrived() external {
    vm.prank(_alice);
    _vault.redeem(_shares - 1e9, _alice, _alice);
    _managementOnly();
    vm.warp(block.timestamp + 30 days);
    _vault.accrue();
    assertEq(_vault.feesOwed(), 0);
    _deposit(_bob, 1e13);
    vm.warp(block.timestamp + 12);
    _vault.accrue();
    assertLe(_vault.feesOwed(), uint256(1e13 + 1e3) * 100 * 12 / (1e4 * 365 days) + 1);
  }

  /// @dev The cost of restarting it: a fee too small to pay a unit at each count is not paid. Here 1e8 raw units at 1%
  ///      a year, counted every 12 seconds for an hour, against one count at the end
  function test_ACountThatRoundsToNoFeeStillRestartsTheClock() external {
    vm.prank(_alice);
    _vault.redeem(_shares - 1e14, _alice, _alice);
    assertEq(_vault.lastCounted(), 1e8);
    _managementOnly();
    uint256 _snapshot = vm.snapshotState();
    vm.warp(block.timestamp + 1 hours);
    _vault.accrue();
    assertEq(_vault.feesOwed(), uint256(1e8) * 100 * 1 hours / (1e4 * 365 days));
    vm.revertToState(_snapshot);
    for (uint256 _i; _i < 300; ++_i) {
      vm.warp(block.timestamp + 12);
      _vault.accrue();
    }
    assertEq(_vault.feesOwed(), 0);
  }
}

contract Gated4626VaultPortfolio_Storage is Gated4626VaultPortfolioTest {
  function test_TheErc7201LocationHoldsThePortfolio() external {
    _plug();
    bytes32 _location =
      keccak256(abi.encode(uint256(keccak256('gated.storage.Gated4626Vault')) - 1)) & ~bytes32(uint256(0xff));
    assertEq(_location, 0xf7c5c9bdda2a603a74c9f186cabeac6180f7b0be68bbe7656cfbf1baf4988200);
    assertEq(address(uint160(uint256(vm.load(address(_vault), _location)))), address(_portfolio));
  }
}
