// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC4626Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol';
import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {Initializable} from '@openzeppelin/contracts/proxy/utils/Initializable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IGated4626Vault} from 'interfaces/IGated4626Vault.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {HolderRestrictionRule} from 'contracts/hooks/rules/HolderRestrictionRule.sol';
import {IdentityRule} from 'contracts/hooks/rules/IdentityRule.sol';
import {MaxHoldersRule} from 'contracts/hooks/rules/MaxHoldersRule.sol';
import {MinPositionRule} from 'contracts/hooks/rules/MinPositionRule.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {MockIdentityRegistry} from 'contracts/test/MockIdentityRegistry.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';
import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';

contract Gated4626VaultUnitTest is Helpers {
  uint256 internal constant _FUNDS = 1e18; // 1e12 whole units of a 6-decimals asset

  Gated4626Vault internal _vault;
  MockAsset internal _asset;
  address internal _registry;
  address internal _hook;
  address internal _admin = makeAddr('timelock');
  address internal _guardian = makeAddr('guardian');
  address internal _agent = makeAddr('agent');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');

  function setUp() public virtual {
    _asset = new MockAsset(6);
    _registry = _mockContract('registry');
    _hook = _mockContract('hook');
    vm.mockCall(
      _registry, abi.encodeCall(IPolicyRegistry.isAttested, (_hook, IPolicyRegistry.AttestKind.HOOK)), abi.encode(true)
    );
    vm.mockCall(_hook, abi.encodeCall(IComplianceHook.REGISTRY, ()), abi.encode(_registry));
    _hookDecides(Reasons.TRANSFER_OK);
    vm.mockCall(_hook, abi.encodeCall(IPolicyHook.wantsAfter, ()), abi.encode(false));

    Gated4626Vault _impl = new Gated4626Vault();
    _vault = Gated4626Vault(
      address(
        new ERC1967Proxy(
          address(_impl),
          abi.encodeCall(
            Gated4626Vault.initialize,
            (
              IERC20(address(_asset)),
              'Gated Fund',
              'gFUND',
              _admin,
              _guardian,
              _registry,
              _hook,
              new IComplianceRule[](0)
            )
          )
        )
      )
    );
    vm.startPrank(_admin);
    _vault.grantRole(_vault.AGENT_ROLE(), _agent);
    vm.stopPrank();

    _fund(_alice);
    _fund(_bob);
  }

  function _fund(
    address _account
  ) internal {
    _asset.mint(_account, _FUNDS);
    vm.prank(_account);
    _asset.approve(address(_vault), type(uint256).max);
  }

  function _hookDecides(
    bytes32 _reason
  ) internal {
    vm.mockCall(_hook, abi.encodeWithSelector(IPolicyHook.beforeTransfer.selector), abi.encode(_reason));
    // The `max*` and eligibility probes ask the account-level question, so the stub answers it the same way.
    vm.mockCall(_hook, abi.encodeWithSelector(IPolicyHook.checkReceive.selector), abi.encode(_reason));
  }

  function _deposit(
    address _account,
    uint256 _assets
  ) internal returns (uint256 _shares) {
    vm.prank(_account);
    _shares = _vault.deposit(_assets, _account);
  }

  function _ctx(
    IPolicyHook.TransferKind _kind,
    address _from,
    address _to,
    uint256 _amount,
    address _operator
  ) internal view returns (IPolicyHook.TransferContext memory _context) {
    _context = IPolicyHook.TransferContext({
      token: address(_vault),
      from: _from,
      to: _to,
      id: 0,
      amount: _amount,
      operator: _operator,
      kind: _kind,
      extra: abi.encode(
        _from == address(0) ? 0 : _vault.balanceOf(_from), _to == address(0) ? 0 : _vault.balanceOf(_to)
      )
    });
  }
}

contract Gated4626VaultUnit_Initialize is Gated4626VaultUnitTest {
  function test_WhenInitialized_ItWiresAssetDecimalsAndRoles() external view {
    assertEq(_vault.asset(), address(_asset));
    assertEq(_vault.decimals(), 12); // asset 6 + offset 6
    assertTrue(_vault.hasRole(_vault.DEFAULT_ADMIN_ROLE(), _admin));
    assertTrue(_vault.hasRole(_vault.GUARDIAN_ROLE(), _guardian));
    assertEq(_vault.policyHook(), _hook);
  }

  function test_WhenCalledTwice_ItReverts() external {
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    _vault.initialize(IERC20(address(_asset)), 'X', 'X', _admin, _guardian, _registry, _hook, new IComplianceRule[](0));
  }

  function test_WhenCalledOnTheImplementation_ItReverts() external {
    Gated4626Vault _impl = new Gated4626Vault();
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    _impl.initialize(IERC20(address(_asset)), 'X', 'X', _admin, _guardian, _registry, _hook, new IComplianceRule[](0));
  }
}

contract Gated4626VaultUnit_IssuerPrimitives is Gated4626VaultUnitTest {
  /// @dev Q1: share supply moves only through deposits and redemptions, even for role holders
  function test_WhenEvenAMinterMints_ItReverts() external {
    bytes32 _minterRole = _vault.MINTER_ROLE();
    vm.prank(_admin);
    _vault.grantRole(_minterRole, _alice);
    vm.expectRevert(IGated4626Vault.Gated4626Vault_Unsupported.selector);
    vm.prank(_alice);
    _vault.mint(_bob, 1);
  }

  function test_WhenEvenABurnerBurns_ItReverts() external {
    _deposit(_alice, 1e6);
    bytes32 _burnerRole = _vault.BURNER_ROLE();
    vm.prank(_admin);
    _vault.grantRole(_burnerRole, _bob);
    vm.expectRevert(IGated4626Vault.Gated4626Vault_Unsupported.selector);
    vm.prank(_bob);
    _vault.burn(_alice, 1);
  }
}

contract Gated4626VaultUnit_Flows is Gated4626VaultUnitTest {
  function test_WhenDepositingForAReceiver_TheHookSeesAMintDrivenByTheCaller(
    uint256 _assets
  ) external {
    _assets = bound(_assets, 1, _FUNDS);
    uint256 _shares = _vault.previewDeposit(_assets);
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IPolicyHook.beforeTransfer, (_ctx(IPolicyHook.TransferKind.MINT, address(0), _bob, _shares, _alice))
      )
    );
    vm.prank(_alice);
    _vault.deposit(_assets, _bob);
    assertEq(_vault.balanceOf(_bob), _shares);
    assertEq(_asset.balanceOf(address(_vault)), _assets);
  }

  function test_WhenASpenderRedeems_TheHookSeesABurnFromTheOwnerDrivenByTheSpender() external {
    uint256 _shares = _deposit(_alice, 5e6);
    vm.prank(_alice);
    _vault.approve(_bob, _shares);
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IPolicyHook.beforeTransfer, (_ctx(IPolicyHook.TransferKind.BURN, _alice, address(0), _shares, _bob))
      )
    );
    vm.prank(_bob);
    _vault.redeem(_shares, _bob, _alice);
    assertEq(_asset.balanceOf(_bob), _FUNDS + 5e6);
  }

  function test_WhenTheHookRejects_DepositsAreRejected() external {
    _hookDecides(Reasons.RECEIVER_NOT_VERIFIED);
    vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, _bob, 1, 0));
    vm.prank(_alice);
    _vault.deposit(1, _bob);
  }
}

contract Gated4626VaultUnit_MaxDepositMint is Gated4626VaultUnitTest {
  function test_WhenAllowed_TheyAreUnlimited() external view {
    assertEq(_vault.maxDeposit(_bob), type(uint256).max);
    assertEq(_vault.maxMint(_bob), type(uint256).max);
  }

  function test_WhenTheHookRejectsTheReceiver_TheyAreZero(
    bytes32 _reason
  ) external {
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.MAX_HOLDERS;
    _hookDecides(_reason);
    assertEq(_vault.maxDeposit(_bob), 0);
    assertEq(_vault.maxMint(_bob), 0);
  }

  function test_WhenPaused_TheyAreZero() external {
    vm.prank(_guardian);
    _vault.pause();
    assertEq(_vault.maxDeposit(_bob), 0);
    assertEq(_vault.maxMint(_bob), 0);
  }

  /// @dev Brief §7, meaningful form: a blocked receiver gets 0 and the smallest deposit reverts
  function test_WhenBlocked_DepositingAboveMaxDepositReverts() external {
    _hookDecides(Reasons.RECEIVER_NOT_VERIFIED);
    uint256 _max = _vault.maxDeposit(_bob);
    vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, _bob, _max + 1, _max));
    vm.prank(_alice);
    _vault.deposit(_max + 1, _bob);
  }
}

contract Gated4626VaultUnit_MaxRedeemWithdraw is Gated4626VaultUnitTest {
  function test_WhenFrozen_MaxRedeemIsTheUnfrozenBalance(
    uint256 _assets,
    uint256 _frozen
  ) external {
    _assets = bound(_assets, 1, _FUNDS);
    uint256 _shares = _deposit(_alice, _assets);
    _frozen = bound(_frozen, 0, _shares);
    vm.prank(_agent);
    _vault.setFrozenTokens(_alice, _frozen);
    assertEq(_vault.maxRedeem(_alice), _shares - _frozen);
  }

  /// @dev Brief §7, exact form for redemptions
  function test_WhenRedeemingMaxRedeem_ItSucceedsAndOneMoreReverts(
    uint256 _assets,
    uint256 _frozen
  ) external {
    _assets = bound(_assets, 1e6, _FUNDS);
    uint256 _shares = _deposit(_alice, _assets);
    _frozen = bound(_frozen, 0, _shares - 1);
    vm.prank(_agent);
    _vault.setFrozenTokens(_alice, _frozen);
    uint256 _max = _vault.maxRedeem(_alice);

    vm.expectRevert(
      abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, _alice, _max + 1, _max)
    );
    vm.prank(_alice);
    _vault.redeem(_max + 1, _alice, _alice);

    vm.prank(_alice);
    _vault.redeem(_max, _alice, _alice);
    assertEq(_vault.balanceOf(_alice), _frozen);
  }

  function test_WhenTheHookRejectsTheExit_TheyAreZero(
    bytes32 _reason
  ) external {
    _deposit(_alice, 5e6);
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.SENDER_NOT_VERIFIED;
    _hookDecides(_reason);
    assertEq(_vault.maxRedeem(_alice), 0);
    assertEq(_vault.maxWithdraw(_alice), 0);
  }

  function test_WhenPaused_TheyAreZero() external {
    _deposit(_alice, 5e6);
    vm.prank(_guardian);
    _vault.pause();
    assertEq(_vault.maxRedeem(_alice), 0);
    assertEq(_vault.maxWithdraw(_alice), 0);
  }

  /// @dev maxWithdraw = convertToAssets(maxRedeem, Floor): it never promises more than withdraw can burn
  function test_WhenThePriceMoves_WithdrawingMaxWithdrawAlwaysSucceeds(
    uint256 _assets,
    uint256 _donation,
    uint256 _frozen
  ) external {
    _assets = bound(_assets, 1, _FUNDS / 2);
    _donation = bound(_donation, 0, _FUNDS / 2);
    _deposit(_bob, 3e6); // a second holder, so rounding is shared
    uint256 _shares = _deposit(_alice, _assets);
    _asset.mint(address(_vault), _donation); // the share price rises
    _frozen = bound(_frozen, 0, _shares);
    vm.prank(_agent);
    _vault.setFrozenTokens(_alice, _frozen);

    uint256 _max = _vault.maxWithdraw(_alice);
    assertEq(_max, _vault.convertToAssets(_vault.maxRedeem(_alice)));
    vm.prank(_alice);
    _vault.withdraw(_max, _alice, _alice);
    assertGe(_vault.balanceOf(_alice), _frozen);
  }
}

contract Gated4626VaultUnit_Inflation is Gated4626VaultUnitTest {
  /// @dev V5: with a decimals offset of 6, a first-depositor donation attack loses the attacker money
  function test_WhenAnAttackerFrontRunsWithADonation_TheAttackerLosesAndTheVictimIsProtected(
    uint256 _donation,
    uint256 _victimAssets
  ) external {
    address _attacker = makeAddr('attacker');
    _fund(_attacker);
    _donation = bound(_donation, 1, _FUNDS / 2);
    _victimAssets = bound(_victimAssets, 1, _FUNDS / 2);

    uint256 _attackerShares = _deposit(_attacker, 1);
    vm.prank(_attacker);
    _asset.transfer(address(_vault), _donation);
    uint256 _victimShares = _deposit(_alice, _victimAssets);

    vm.prank(_attacker);
    uint256 _out = _vault.redeem(_attackerShares, _attacker, _attacker);
    assertLe(_out, 1 + _donation, 'attacker must not profit');

    // The offset also protects the victim: the loss is bounded by about one share's worth of rounding,
    // i.e. donation / 1e6. Without the offset, a victim depositing less than half the donation gets zero shares.
    vm.prank(_alice);
    uint256 _victimOut = _vault.redeem(_victimShares, _alice, _alice);
    assertGe(_victimOut + _donation / 1e6 + 3, _victimAssets, 'victim loss must stay within rounding');
  }
}

contract Gated4626VaultUnit_SupportsInterface is Gated4626VaultUnitTest {
  function test_WhenQueried_ItAdvertisesTheVaultAndTheGatedToken() external view {
    assertTrue(_vault.supportsInterface(type(IERC4626).interfaceId));
    assertTrue(_vault.supportsInterface(type(IPolicyGated).interfaceId));
    assertTrue(_vault.supportsInterface(type(IAccessControl).interfaceId));
  }
}

/// @notice Integration: the vault behind a real ComplianceHook with Identity, HolderRestriction and MaxHolders
contract Gated4626VaultIntegrationTest is Test {
  Gated4626Vault internal _vault;
  MockAsset internal _asset;
  MockIdentityRegistry internal _identity;
  HolderRestrictionRule internal _restrictionRule;
  MaxHoldersRule internal _maxHoldersRule;
  address internal _guardian = makeAddr('guardian');
  address internal _agent = makeAddr('agent');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');
  address internal _carol = makeAddr('carol');
  address internal _eve = makeAddr('eve'); // never verified

  function setUp() public {
    // Configure, then hand over: this test is the vault admin while it configures, as the deploy module will be.
    PolicyRegistry _registry = new PolicyRegistry(address(this), address(this));
    _identity = new MockIdentityRegistry();
    IdentityRule _identityRule = new IdentityRule(IIdentityRegistry(address(_identity)));
    _restrictionRule = new HolderRestrictionRule();
    _maxHoldersRule = new MaxHoldersRule();
    _registry.attest(address(_identityRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_restrictionRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_maxHoldersRule).codehash, IPolicyRegistry.AttestKind.RULE, '');

    _asset = new MockAsset(6);
    Gated4626Vault _impl = new Gated4626Vault();
    IComplianceRule[] memory _rules = new IComplianceRule[](3);
    _rules[0] = _identityRule;
    _rules[1] = _restrictionRule;
    _rules[2] = _maxHoldersRule;
    // CREATE2 through ProxyDeployer, as in production: the address does not depend on this contract's nonce.
    ProxyDeployer _proxyDeployer = new ProxyDeployer(address(this));
    ComplianceHook _hook = new ComplianceHook(_registry);
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _vault = Gated4626Vault(
      address(
        _proxyDeployer.deploy(
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
      )
    );
    _vault.grantRole(_vault.AGENT_ROLE(), _agent);
    _maxHoldersRule.setCap(address(_vault), 2);

    _identity.set(_alice, true);
    _identity.set(_bob, true);
    _identity.set(_carol, true);
    address[4] memory _investors = [_alice, _bob, _carol, _eve];
    for (uint256 _i; _i < 4; ++_i) {
      _asset.mint(_investors[_i], 1e12);
      vm.prank(_investors[_i]);
      _asset.approve(address(_vault), type(uint256).max);
    }
  }

  function _deposit(
    address _account,
    uint256 _assets
  ) internal returns (uint256 _shares) {
    vm.prank(_account);
    _shares = _vault.deposit(_assets, _account);
  }
}

contract Gated4626VaultIntegration_Entry is Gated4626VaultIntegrationTest {
  function test_WhenTheReceiverIsUnverified_MaxDepositIsZeroAndDepositReverts() external {
    assertEq(_vault.maxDeposit(_eve), 0);
    vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, _eve, 1, 0));
    vm.prank(_eve);
    _vault.deposit(1, _eve);
  }

  function test_WhenTheCapIsFull_ANewInvestorIsBlockedButHoldersCanTopUp() external {
    _deposit(_alice, 1e6);
    _deposit(_bob, 1e6);
    assertEq(_maxHoldersRule.holderCount(address(_vault)), 2);

    assertEq(_vault.maxDeposit(_carol), 0);
    vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, _carol, 1, 0));
    vm.prank(_carol);
    _vault.deposit(1, _carol);

    assertEq(_vault.maxDeposit(_alice), type(uint256).max);
    _deposit(_alice, 1e6);
  }
}

contract Gated4626VaultIntegration_Exit is Gated4626VaultIntegrationTest {
  /// @dev V1: a locked holder can no longer exit through the vault
  function test_WhenTheHolderIsLocked_RedemptionIsBlockedWithParity() external {
    uint256 _shares = _deposit(_alice, 1e6);
    vm.prank(_agent);
    _restrictionRule.setLockup(address(_vault), _alice, block.timestamp + 30 days);

    (bool _ok, bytes32 _reason) = _vault.canTransferWithReason(_alice, address(0), 1);
    assertFalse(_ok);
    assertEq(_reason, Reasons.LOCKED);
    assertEq(_vault.maxRedeem(_alice), 0);
    vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, _alice, _shares, 0));
    vm.prank(_alice);
    _vault.redeem(_shares, _alice, _alice);

    vm.warp(block.timestamp + 30 days);
    vm.prank(_alice);
    _vault.redeem(_shares, _alice, _alice);
  }

  function test_WhenTheHolderIsDeverified_ExitIsGatedToo() external {
    _deposit(_alice, 1e6);
    _identity.set(_alice, false);
    assertEq(_vault.maxRedeem(_alice), 0);
  }

  function test_WhenAHolderFullyExits_TheHolderCountDrops() external {
    uint256 _shares = _deposit(_alice, 1e6);
    _deposit(_bob, 1e6);
    vm.prank(_alice);
    _vault.redeem(_shares, _alice, _alice);
    assertEq(_maxHoldersRule.holderCount(address(_vault)), 1);
    assertEq(_vault.maxDeposit(_carol), type(uint256).max); // a slot freed up
  }
}

/// @notice The vault with a minimum position (RD7). The `max*` answers must not read the minimum as "disabled": a
///         receiver that can take shares at all has `maxDeposit` of the full range, and a holder at the minimum can
///         redeem all of it. The minimum is in shares, and the vault's decimals offset of 6 makes one asset unit 1e6
///         shares at the first deposit
contract Gated4626VaultIntegration_MinPosition is Gated4626VaultIntegrationTest {
  uint256 internal constant _MIN_ASSETS = 1e6;
  uint256 internal constant _MIN_SHARES = 1e12;

  function _enableMinPosition() internal {
    MinPositionRule _minRule = new MinPositionRule();
    IPolicyRegistry(_vault.registry()).attest(address(_minRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    ComplianceHook _hook = ComplianceHook(_vault.policyHook());
    IComplianceRule[] memory _old = _hook.rules(address(_vault));
    IComplianceRule[] memory _list = new IComplianceRule[](_old.length + 1);
    _list[0] = _old[0]; // identity first, then the minimum, then the holder rules
    _list[1] = _minRule;
    for (uint256 _i = 1; _i < _old.length; ++_i) {
      _list[_i + 1] = _old[_i];
    }
    _hook.setRules(address(_vault), _list);
    _minRule.setMinPosition(address(_vault), _MIN_SHARES);
  }

  function test_WhenAMinimumIsSet_MaxDepositForAnEmptyReceiverIsStillTheFullRange() external {
    _enableMinPosition();
    assertEq(_vault.maxDeposit(_alice), type(uint256).max);
    assertEq(_vault.maxMint(_alice), type(uint256).max);
  }

  function test_WhenADepositWouldLeaveDust_ItRevertsWithTheReasonAndTheMinimumDepositWorks() external {
    _enableMinPosition();
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_TransferRejected.selector, Reasons.BELOW_MIN_POSITION)
    );
    vm.prank(_alice);
    _vault.deposit(_MIN_ASSETS - 1, _alice);

    assertEq(_deposit(_alice, _MIN_ASSETS), _MIN_SHARES);
    assertEq(_vault.balanceOf(_alice), _MIN_SHARES);
  }

  /// @dev A holder at exactly the minimum is the usual position, and a 1-share burn would leave dust
  function test_WhenAHolderSitsAtTheMinimum_MaxRedeemIsTheWholeBalanceAndRedeemWorks() external {
    _enableMinPosition();
    uint256 _shares = _deposit(_alice, _MIN_ASSETS);
    assertEq(_vault.maxRedeem(_alice), _shares);
    assertEq(_vault.maxWithdraw(_alice), _MIN_ASSETS);

    uint256 _max = _vault.maxRedeem(_alice);
    vm.prank(_alice);
    _vault.redeem(_max, _alice, _alice);
    assertEq(_vault.balanceOf(_alice), 0);
  }

  function test_WhenARedemptionWouldLeaveDust_ItRevertsWithTheReason() external {
    _enableMinPosition();
    _deposit(_alice, 2 * _MIN_ASSETS);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_TransferRejected.selector, Reasons.BELOW_MIN_POSITION)
    );
    vm.prank(_alice);
    _vault.redeem(_MIN_SHARES + 1, _alice, _alice);

    vm.prank(_alice);
    _vault.redeem(_MIN_SHARES, _alice, _alice);
    assertEq(_vault.balanceOf(_alice), _MIN_SHARES);
  }

  /// @dev The cap is still known to `maxDeposit`: a receiver that could not become a holder has none
  function test_WhenTheCapIsFull_MaxDepositIsStillZeroForANewInvestorWithAMinimumSet() external {
    _enableMinPosition();
    _deposit(_alice, _MIN_ASSETS);
    _deposit(_bob, _MIN_ASSETS);
    assertEq(_vault.maxDeposit(_carol), 0);
    assertEq(_vault.maxDeposit(_alice), type(uint256).max);
  }
}

/// @notice Drives deposits, mints, withdrawals, redemptions, share transfers, freezes and donations
contract Gated4626Handler is Test {
  Gated4626Vault internal _vault;
  MockAsset internal _asset;
  address[3] internal _actors;
  uint256 public ghostAssetsIn;
  uint256 public ghostAssetsOut;

  constructor(
    Gated4626Vault _target,
    MockAsset _underlying
  ) {
    _vault = _target;
    _asset = _underlying;
    _actors = [makeAddr('actor0'), makeAddr('actor1'), makeAddr('actor2')];
    for (uint256 _i; _i < 3; ++_i) {
      vm.prank(_actors[_i]);
      _asset.approve(address(_vault), type(uint256).max);
    }
  }

  function actors() external view returns (address[3] memory _all) {
    _all = _actors;
  }

  function deposit(
    uint256 _seed,
    uint256 _assets
  ) external {
    address _actor = _actors[_seed % 3];
    _assets = bound(_assets, 0, 1e15);
    _asset.mint(_actor, _assets);
    vm.prank(_actor);
    _vault.deposit(_assets, _actor);
    ghostAssetsIn += _assets;
  }

  function mint(
    uint256 _seed,
    uint256 _shares
  ) external {
    address _actor = _actors[_seed % 3];
    _shares = bound(_shares, 0, 1e21);
    uint256 _assets = _vault.previewMint(_shares);
    _asset.mint(_actor, _assets);
    vm.prank(_actor);
    ghostAssetsIn += _vault.mint(_shares, _actor);
  }

  function redeem(
    uint256 _seed,
    uint256 _shares
  ) external {
    address _actor = _actors[_seed % 3];
    _shares = bound(_shares, 0, _vault.maxRedeem(_actor));
    vm.prank(_actor);
    ghostAssetsOut += _vault.redeem(_shares, _actor, _actor);
  }

  function withdraw(
    uint256 _seed,
    uint256 _assets
  ) external {
    address _actor = _actors[_seed % 3];
    _assets = bound(_assets, 0, _vault.maxWithdraw(_actor));
    vm.prank(_actor);
    _vault.withdraw(_assets, _actor, _actor);
    ghostAssetsOut += _assets;
  }

  function transfer(
    uint256 _from,
    uint256 _to,
    uint256 _shares
  ) external {
    address _sender = _actors[_from % 3];
    _shares = bound(_shares, 0, _vault.balanceOf(_sender) - _vault.getFrozenTokens(_sender));
    vm.prank(_sender);
    _vault.transfer(_actors[_to % 3], _shares);
  }

  function setFrozen(
    uint256 _seed,
    uint256 _amount
  ) external {
    address _actor = _actors[_seed % 3];
    _vault.setFrozenTokens(_actor, bound(_amount, 0, _vault.balanceOf(_actor)));
  }

  function donate(
    uint256 _assets
  ) external {
    _assets = bound(_assets, 0, 1e15);
    _asset.mint(address(_vault), _assets);
    ghostAssetsIn += _assets;
  }
}

contract Gated4626VaultInvariantTest is Gated4626VaultUnitTest {
  Gated4626Handler internal _handler;

  function setUp() public override {
    super.setUp();
    _handler = new Gated4626Handler(_vault, _asset);
    bytes32 _agentRole = _vault.AGENT_ROLE(); // read first: an inline call would consume the prank
    vm.prank(_admin);
    _vault.grantRole(_agentRole, address(_handler));
    targetContract(address(_handler));
  }

  function invariant_SumOfShareBalancesEqualsTotalSupply() external view {
    address[3] memory _all = _handler.actors();
    uint256 _sum;
    for (uint256 _i; _i < 3; ++_i) {
      _sum += _vault.balanceOf(_all[_i]);
    }
    assertEq(_sum, _vault.totalSupply());
  }

  function invariant_FrozenNeverExceedsBalance() external view {
    address[3] memory _all = _handler.actors();
    for (uint256 _i; _i < 3; ++_i) {
      assertLe(_vault.getFrozenTokens(_all[_i]), _vault.balanceOf(_all[_i]));
    }
  }

  function invariant_AssetsAreConserved() external view {
    assertEq(_asset.balanceOf(address(_vault)), _handler.ghostAssetsIn() - _handler.ghostAssetsOut());
  }

  function invariant_SharesAreAlwaysBacked() external view {
    // Every outstanding share redeems for at most the assets the vault holds.
    assertLe(_vault.convertToAssets(_vault.totalSupply()), _asset.balanceOf(address(_vault)));
  }
}

/// @dev Aderyn `contract-locks-ether` is a false positive for this implementation: no path accepts ETH
contract Gated4626VaultUnit_Ether is Gated4626VaultUnitTest {
  function test_WhenEtherIsSentPlainly_ItReverts() external {
    vm.deal(_alice, 1 ether);
    vm.prank(_alice);
    (bool _ok,) = address(_vault).call{value: 1}('');
    assertFalse(_ok);
    assertEq(address(_vault).balance, 0);
  }
}

/// @notice A vault proxy cannot be moved onto another template's implementation, attested or not
contract Gated4626VaultUnit_Template is Gated4626VaultUnitTest {
  function _attestedImplementation(
    address _impl
  ) internal {
    vm.mockCall(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (_impl, IPolicyRegistry.AttestKind.IMPLEMENTATION)),
      abi.encode(true)
    );
    vm.startPrank(_admin);
    _vault.grantRole(_vault.UPGRADER_ROLE(), _admin);
    vm.stopPrank();
  }

  function test_WhenQueried_ItNamesItsTemplate() external view {
    assertEq(_vault.templateId(), keccak256('Gated4626Vault'));
  }

  function test_WhenUpgradedToTheTokenImplementation_ItIsRefused() external {
    address _impl = address(new IntentToken());
    _attestedImplementation(_impl);
    vm.expectRevert(
      abi.encodeWithSelector(
        ITemplated.Templated_WrongTemplate.selector, _impl, keccak256('Gated4626Vault'), keccak256('IntentToken')
      )
    );
    vm.prank(_admin);
    _vault.upgradeToAndCall(_impl, '');
  }

  function test_WhenUpgradedToTheOtherVaultImplementation_ItIsRefused() external {
    address _impl = address(new Gated7540Vault());
    _attestedImplementation(_impl);
    vm.expectRevert(
      abi.encodeWithSelector(
        ITemplated.Templated_WrongTemplate.selector, _impl, keccak256('Gated4626Vault'), keccak256('Gated7540Vault')
      )
    );
    vm.prank(_admin);
    _vault.upgradeToAndCall(_impl, '');
  }

  function test_WhenUpgradedToANewImplementationOfItself_ItUpgrades() external {
    address _impl = address(new Gated4626Vault());
    _attestedImplementation(_impl);
    vm.prank(_admin);
    _vault.upgradeToAndCall(_impl, '');
    assertEq(_vault.templateId(), keccak256('Gated4626Vault'));
  }
}
