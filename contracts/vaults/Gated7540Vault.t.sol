// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {Initializable} from '@openzeppelin/contracts/proxy/utils/Initializable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC7540Deposit} from 'interfaces/IERC7540Deposit.sol';
import {IERC7540Operator} from 'interfaces/IERC7540Operator.sol';
import {IERC7540Redeem} from 'interfaces/IERC7540Redeem.sol';
import {IERC7575} from 'interfaces/IERC7575.sol';
import {IERC7943Fungible} from 'interfaces/IERC7943Fungible.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {IGatedVaultBase} from 'interfaces/IGatedVaultBase.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyGatedCore} from 'interfaces/IPolicyGatedCore.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {Fund} from 'contracts/fund/Fund.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {FundHoldersRule} from 'contracts/hooks/rules/FundHoldersRule.sol';
import {HolderRestrictionRule} from 'contracts/hooks/rules/HolderRestrictionRule.sol';
import {MinPositionRule} from 'contracts/hooks/rules/MinPositionRule.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {MockIdentityRegistry} from 'contracts/test/MockIdentityRegistry.sol';
import {MockIdentityRule} from 'contracts/test/MockIdentityRule.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';
import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';

contract Gated7540VaultUnitTest is Helpers {
  uint256 internal constant _FUNDS = 1e18;
  /// @dev Shares per asset unit at par: an asset of 6 decimals, shares of 12
  uint256 internal constant _PAR = 1e6;

  Gated7540Vault internal _vault;
  MockAsset internal _asset;
  address internal _registry;
  address internal _hook;
  address internal _admin = makeAddr('timelock');
  address internal _guardian = makeAddr('guardian');
  address internal _settler = makeAddr('settler');
  address internal _agent = makeAddr('agent');
  address internal _cash = makeAddr('cash');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');
  address internal _stranger = makeAddr('stranger');
  address internal _seed = makeAddr('seed');

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
    _vault = _deployVault(_asset);
    vm.startPrank(_admin);
    _vault.grantRole(_vault.SETTLER_ROLE(), _settler);
    _vault.grantRole(_vault.AGENT_ROLE(), _agent);
    vm.stopPrank();

    _fund(_alice);
    _fund(_bob);
    _fund(_cash);
    _fund(_seed);
  }

  function _deployVault(
    MockAsset _underlying
  ) internal returns (Gated7540Vault _deployed) {
    Gated7540Vault _impl = new Gated7540Vault();
    _deployed = Gated7540Vault(
      address(
        new ERC1967Proxy(
          address(_impl),
          abi.encodeCall(
            Gated7540Vault.initialize,
            (
              IERC20(address(_underlying)),
              'Gated Async Fund',
              'gASYNC',
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
  }

  function _requestDeposit(
    address _account,
    uint256 _assets
  ) internal {
    vm.prank(_account);
    _vault.requestDeposit(_assets, _account, _account);
  }

  /// @dev Closes the open period and settles it at `_nav`
  function _settleAt(
    uint256 _nav
  ) internal {
    vm.startPrank(_settler);
    _vault.closePeriod();
    _vault.settlePeriod(_nav, 0, _cash, address(0), type(uint256).max);
    vm.stopPrank();
  }

  /// @dev All shares, unclaimed included
  function _supply() internal view returns (uint256 _all) {
    (,, uint256 _unclaimed) = _vault.dealingState();
    _all = _vault.totalSupply() + _unclaimed;
  }

  /// @dev Closes and settles at the value that keeps one asset unit worth exactly `_PAR` shares
  function _settleAtPar() internal {
    _settleAt(_supply() / _PAR);
  }

  /// @dev Full deposit lifecycle at par, leaving `_account` holding `_assets * _PAR` shares
  function _holdShares(
    address _account,
    uint256 _assets
  ) internal {
    _requestDeposit(_account, _assets);
    _settleAtPar();
    uint256 _shares = _vault.maxMint(_account);
    vm.prank(_account);
    _vault.mint(_shares, _account, _account);
  }

  function _requestRedeem(
    address _account,
    uint256 _shares
  ) internal {
    vm.prank(_account);
    _vault.requestRedeem(_shares, _account, _account);
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

  function _unauthorized(
    address _caller
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_Unauthorized.selector, _caller);
  }

  function _noRole(
    address _caller,
    bytes32 _role
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role);
  }
}

contract Gated7540VaultUnit_Initialize is Gated7540VaultUnitTest {
  function test_WhenInitialized_ItWiresTheVault() external view {
    assertEq(_vault.asset(), address(_asset));
    assertEq(_vault.share(), address(_vault));
    assertEq(_vault.decimals(), 12);
    assertEq(_vault.policyHook(), _hook);
    (uint64 _open, uint64 _settled, uint256 _unclaimed) = _vault.dealingState();
    assertEq(_open, 1);
    assertEq(_settled, 0);
    assertEq(_unclaimed, 0);
  }

  function testFuzz_TheSharesTakeTheAssetsDecimalsPlusSix(
    uint8 _decimals
  ) external {
    _decimals = uint8(bound(_decimals, 0, 36));
    assertEq(_deployVault(new MockAsset(_decimals)).decimals(), _decimals + 6);
  }

  function test_WhenCalledTwice_ItReverts() external {
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    _vault.initialize(IERC20(address(_asset)), 'X', 'X', _admin, _guardian, _registry, _hook, new IComplianceRule[](0));
  }

  function test_WhenTheAssetIsZero_ItReverts() external {
    Gated7540Vault _impl = new Gated7540Vault();
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAddress.selector);
    new ERC1967Proxy(
      address(_impl),
      abi.encodeCall(
        Gated7540Vault.initialize,
        (IERC20(address(0)), 'X', 'X', _admin, _guardian, _registry, _hook, new IComplianceRule[](0))
      )
    );
  }

  /// @dev The four ERC-165 ids ERC-7540 requires, as literal values from the spec
  function test_WhenQueried_ItAdvertisesTheSpecInterfaceIds() external view {
    assertEq(type(IERC7540Operator).interfaceId, bytes4(0xe3bc4e65));
    assertEq(type(IERC7540Deposit).interfaceId, bytes4(0xce3bbe50));
    assertEq(type(IERC7540Redeem).interfaceId, bytes4(0x620ee8e4));
    assertEq(type(IERC7575).interfaceId, bytes4(0x2f0a18c5));
    assertTrue(_vault.supportsInterface(0xe3bc4e65));
    assertTrue(_vault.supportsInterface(0xce3bbe50));
    assertTrue(_vault.supportsInterface(0x620ee8e4));
    assertTrue(_vault.supportsInterface(0x2f0a18c5));
    assertTrue(_vault.supportsInterface(type(IPolicyGated).interfaceId));
  }
}

contract Gated7540VaultUnit_IssuerPrimitives is Gated7540VaultUnitTest {
  function test_WhenEvenAMinterMints_ItReverts() external {
    bytes32 _minterRole = _vault.MINTER_ROLE();
    vm.prank(_admin);
    _vault.grantRole(_minterRole, _alice);
    vm.expectRevert(IGatedVaultBase.GatedVault_Unsupported.selector);
    vm.prank(_alice);
    _vault.mint(_bob, 1);
  }

  function test_WhenEvenABurnerBurns_ItReverts() external {
    bytes32 _burnerRole = _vault.BURNER_ROLE();
    vm.prank(_admin);
    _vault.grantRole(_burnerRole, _alice);
    vm.expectRevert(IGatedVaultBase.GatedVault_Unsupported.selector);
    vm.prank(_alice);
    _vault.burn(_bob, 1);
  }
}

contract Gated7540VaultUnit_Operators is Gated7540VaultUnitTest {
  function test_WhenAControllerSetsAnOperator_ItIsRecordedAndEmitted() external {
    vm.expectEmit(address(_vault));
    emit IERC7540Operator.OperatorSet(_alice, _bob, true);
    vm.prank(_alice);
    assertTrue(_vault.setOperator(_bob, true));
    assertTrue(_vault.isOperator(_alice, _bob));
    vm.prank(_alice);
    _vault.setOperator(_bob, false);
    assertFalse(_vault.isOperator(_alice, _bob));
  }
}

contract Gated7540VaultUnit_RequestDeposit is Gated7540VaultUnitTest {
  function test_WhenTheControllerIsZero_ItReverts() external {
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAddress.selector);
    vm.prank(_alice);
    _vault.requestDeposit(100, address(0), _alice);
    assertEq(_asset.balanceOf(address(_vault)), 0);
  }

  function test_WhenTheOwnerRequests_ItTakesTheAssetsAndEmits(
    uint256 _assets
  ) external {
    _assets = bound(_assets, 1, _FUNDS);
    vm.expectEmit(address(_vault));
    emit IERC7540Deposit.DepositRequest(_bob, _alice, 0, _alice, _assets);
    vm.prank(_alice);
    assertEq(_vault.requestDeposit(_assets, _bob, _alice), 0);
    assertEq(_vault.pendingDepositRequest(0, _bob), _assets);
    assertEq(_asset.balanceOf(address(_vault)), _assets);
  }

  function test_WhenAnOperatorRequestsForTheOwner_ItSucceeds() external {
    vm.prank(_alice);
    _vault.setOperator(_bob, true);
    vm.prank(_bob);
    _vault.requestDeposit(5, _alice, _alice);
    assertEq(_vault.pendingDepositRequest(0, _alice), 5);
  }

  /// @dev L-5 (owner decision): ERC-7540 operators are full delegates. An approved operator can open requests that pull
  ///      the owner's assets or shares under ANY controller, its own included. Pinned so nobody narrows it to claims
  function test_WhenAnOperatorRequestsUnderItsOwnController_ItIsAFullDelegatePerErc7540() external {
    _holdShares(_alice, 100);
    vm.prank(_alice);
    _vault.setOperator(_bob, true);
    uint256 _assetsBefore = _asset.balanceOf(_alice);
    vm.startPrank(_bob);
    _vault.requestDeposit(25, _bob, _alice); // alice pays, bob controls
    _vault.requestRedeem(40, _bob, _alice); // alice's shares escrowed, bob controls
    vm.stopPrank();
    assertEq(_asset.balanceOf(_alice), _assetsBefore - 25);
    assertEq(_vault.balanceOf(_alice), 100 * _PAR - 40);
    assertEq(_vault.pendingDepositRequest(0, _bob), 25);
    assertEq(_vault.pendingRedeemRequest(0, _bob), 40);
    assertEq(_vault.pendingDepositRequest(0, _alice) + _vault.pendingRedeemRequest(0, _alice), 0);
  }

  /// @dev Backs the `arbitrary-send-erc20` suppression: a non-operator cannot pull a victim's approved assets
  function test_WhenANonOperatorRequestsWithAVictimAsOwner_ItRevertsAndMovesNothing(
    uint256 _assets
  ) external {
    _assets = bound(_assets, 1, _FUNDS);
    assertEq(_asset.allowance(_alice, address(_vault)), type(uint256).max); // the victim has approved the vault

    vm.expectRevert(_unauthorized(_stranger));
    vm.prank(_stranger);
    _vault.requestDeposit(_assets, _stranger, _alice);

    assertEq(_asset.balanceOf(_alice), _FUNDS);
    assertEq(_asset.balanceOf(address(_vault)), 0);
    assertEq(_vault.pendingDepositRequest(0, _stranger), 0);
    assertEq(_vault.pendingDepositRequest(0, _alice), 0);
  }

  function test_WhenARevokedOperatorRequestsForTheOwner_ItReverts() external {
    vm.startPrank(_alice);
    _vault.setOperator(_stranger, true);
    _vault.setOperator(_stranger, false);
    vm.stopPrank();
    vm.expectRevert(_unauthorized(_stranger));
    vm.prank(_stranger);
    _vault.requestDeposit(5, _stranger, _alice);
  }

  function test_WhenTheAmountIsZero_ItReverts() external {
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAmount.selector);
    _requestDeposit(_alice, 0);
  }

  function test_WhenTheAmountDoesNotFitABook_ItReverts() external {
    uint256 _tooMuch = uint256(type(uint128).max) + 1;
    _asset.mint(_alice, _tooMuch);
    vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, _tooMuch));
    _requestDeposit(_alice, _tooMuch);
  }

  /// @dev Q2: without cancellation, an ineligible controller's assets would otherwise be stuck
  function test_WhenTheControllerCouldNotHoldShares_ItReverts(
    bytes32 _reason
  ) external {
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.RECEIVER_NOT_VERIFIED;
    _hookDecides(_reason);
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ControllerNotEligible.selector, _reason));
    _requestDeposit(_alice, 5);
  }

  function test_WhenPaused_ItReverts() external {
    vm.prank(_guardian);
    _vault.pause();
    vm.expectRevert(
      abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ControllerNotEligible.selector, Reasons.PAUSED)
    );
    _requestDeposit(_alice, 5);
  }
}

contract Gated7540VaultUnit_Periods is Gated7540VaultUnitTest {
  function _dealing() internal view returns (uint64 _open, uint64 _settled) {
    (_open, _settled,) = _vault.dealingState();
  }

  function test_WhenSomeoneWithoutTheRoleClosesOrSettles_ItReverts(
    address _caller
  ) external {
    bytes32 _role = _vault.SETTLER_ROLE();
    if (_vault.hasRole(_role, _caller)) _caller = _stranger;
    vm.expectRevert(_noRole(_caller, _role));
    vm.prank(_caller);
    _vault.closePeriod();
    vm.expectRevert(_noRole(_caller, _role));
    vm.prank(_caller);
    _vault.settlePeriod(0, 0, _cash, address(0), type(uint256).max);
  }

  function test_WhenThePeriodCloses_TheNextOpensAndItEmits() external {
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.PeriodClosed(1);
    vm.prank(_settler);
    _vault.closePeriod();
    (uint64 _open, uint64 _settled) = _dealing();
    assertEq(_open, 2);
    assertEq(_settled, 0);
  }

  function test_WhenAClosedPeriodIsUnsettled_ClosingAgainReverts() external {
    vm.startPrank(_settler);
    _vault.closePeriod();
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_PeriodUnsettled.selector, 1));
    _vault.closePeriod();
    vm.stopPrank();
  }

  function test_WhenNoPeriodIsClosed_SettlingReverts() external {
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NoClosedPeriod.selector);
    vm.prank(_settler);
    _vault.settlePeriod(0, 0, _cash, address(0), type(uint256).max);
  }

  function test_WhenPaused_SettlingReverts() external {
    vm.prank(_settler);
    _vault.closePeriod();
    vm.prank(_guardian);
    _vault.pause();
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vm.prank(_settler);
    _vault.settlePeriod(0, 0, _cash, address(0), type(uint256).max);
  }

  function test_AWholeCycle() external {
    _requestDeposit(_alice, 1000);
    assertEq(_vault.claimableDepositRequest(0, _alice), 0);
    vm.prank(_settler);
    _vault.closePeriod();
    assertEq(_vault.pendingDepositRequest(0, _alice), 1000); // still pending until it is priced

    vm.expectEmit(address(_vault));
    emit IGated7540Vault.PeriodSettled(1, 0, 0, 1000, 1000 * _PAR, 0, 0, 0, 0);
    vm.prank(_settler);
    _vault.settlePeriod(0, 0, _cash, address(0), type(uint256).max);

    (, uint64 _settled) = _dealing();
    assertEq(_settled, 1);
    assertEq(_vault.pendingDepositRequest(0, _alice), 0);
    assertEq(_vault.claimableDepositRequest(0, _alice), 1000);
    assertEq(_vault.maxMint(_alice), 1000 * _PAR);
    assertEq(_asset.balanceOf(_cash), _FUNDS + 1000);
    assertEq(_asset.balanceOf(address(_vault)), 0);

    vm.prank(_alice);
    _vault.mint(1000 * _PAR, _alice, _alice);
    assertEq(_vault.balanceOf(_alice), 1000 * _PAR);
    (,, uint256 _unclaimed) = _vault.dealingState();
    assertEq(_unclaimed, 0);

    _requestRedeem(_alice, 1000 * _PAR);
    assertEq(_vault.balanceOf(address(_vault)), 1000 * _PAR);
    _settleAt(1100); // the value rose 10%
    assertEq(_vault.totalSupply(), 0);
    uint256 _owed = _vault.maxWithdraw(_alice);
    assertEq(_owed, Math.mulDiv(1000 * _PAR, 1101, 1000 * _PAR + _PAR));
    vm.prank(_alice);
    _vault.redeem(1000 * _PAR, _alice, _alice);
    assertEq(_asset.balanceOf(_alice), _FUNDS - 1000 + _owed);
  }

  function test_TwoInvestorsInOnePeriodGetOnePrice() external {
    _holdShares(_seed, 1);
    _requestDeposit(_alice, 300);
    _requestDeposit(_bob, 900);
    _settleAt(3); // a unit of the fund is now worth 1.5 of what it cost: value 3 on supply of 1 asset's shares at 2
    uint256 _aliceShares = _vault.maxMint(_alice);
    uint256 _bobShares = _vault.maxMint(_bob);
    assertApproxEqAbs(_bobShares, 3 * _aliceShares, 3);
  }

  function test_InvestorsInDifferentPeriodsGetTheirOwnPrice() external {
    _holdShares(_seed, 1000);
    _requestDeposit(_alice, 100);
    _settleAtPar();
    _requestDeposit(_bob, 100);
    _settleAt(2 * (_supply() / _PAR)); // the value doubled
    assertEq(_vault.maxMint(_alice), 100 * _PAR);
    assertApproxEqRel(_vault.maxMint(_bob), 50 * _PAR, 0.001e18);
  }

  function test_ARequestAfterTheCutOffJoinsTheNextPeriod() external {
    _requestDeposit(_alice, 100);
    vm.prank(_settler);
    _vault.closePeriod();
    _requestDeposit(_bob, 200);

    vm.expectEmit(address(_vault));
    emit IGated7540Vault.PeriodSettled(1, 0, 0, 100, 100 * _PAR, 0, 0, 0, 0);
    vm.prank(_settler);
    _vault.settlePeriod(0, 0, _cash, address(0), type(uint256).max);

    assertEq(_vault.claimableDepositRequest(0, _alice), 100);
    assertEq(_vault.pendingDepositRequest(0, _bob), 200);
    assertEq(_asset.balanceOf(address(_vault)), 200);
  }

  function test_AControllerWaitsWhileAnEarlierRequestIsUnsettled() external {
    _requestDeposit(_alice, 100);
    vm.prank(_settler);
    _vault.closePeriod();
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_EarlierRequestUnsettled.selector, 1));
    _requestDeposit(_alice, 50);

    vm.prank(_settler);
    _vault.settlePeriod(0, 0, _cash, address(0), type(uint256).max);
    _requestDeposit(_alice, 50);
    assertEq(_vault.pendingDepositRequest(0, _alice), 50);
    assertEq(_vault.claimableDepositRequest(0, _alice), 100);
  }

  function test_TheRedeemSideWaitsToo() external {
    _holdShares(_alice, 100);
    _requestRedeem(_alice, 10);
    vm.prank(_settler);
    _vault.closePeriod();
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_EarlierRequestUnsettled.selector, 2));
    _requestRedeem(_alice, 10);
  }

  function test_TwoRequestsInTheOpenPeriodAdd() external {
    _requestDeposit(_alice, 100);
    _requestDeposit(_alice, 50);
    assertEq(_vault.pendingDepositRequest(0, _alice), 150);
    _settleAtPar();
    assertEq(_vault.maxMint(_alice), 150 * _PAR);
  }

  function test_ASettledRequestRollsIntoTheClaimableAmountsAtTheNextRequest() external {
    _requestDeposit(_alice, 100);
    _settleAtPar();
    _requestDeposit(_alice, 40);
    assertEq(_vault.claimableDepositRequest(0, _alice), 100);
    assertEq(_vault.maxMint(_alice), 100 * _PAR);
    _settleAtPar();
    assertEq(_vault.claimableDepositRequest(0, _alice), 140);
    assertEq(_vault.maxMint(_alice), 140 * _PAR);
  }

  function test_AnEmptyPeriodSettlesAndChangesNothing() external {
    uint256 _cashBefore = _asset.balanceOf(_cash);
    _settleAt(5);
    (uint64 _open, uint64 _settled) = _dealing();
    assertEq(_open, 2);
    assertEq(_settled, 1);
    assertEq(_asset.balanceOf(_cash), _cashBefore);
  }
}

contract Gated7540VaultUnit_Netting is Gated7540VaultUnitTest {
  uint256 internal _cashBefore;

  function setUp() public override {
    super.setUp();
    _holdShares(_seed, 1000);
    _holdShares(_bob, 1000);
    _cashBefore = _asset.balanceOf(_cash);
  }

  function test_WhenDepositsExceedRedemptions_OnlyTheDifferenceGoesToTheCashAccount() external {
    _requestDeposit(_alice, 500);
    _requestRedeem(_bob, 200 * _PAR);
    _settleAtPar();
    assertEq(_asset.balanceOf(_cash), _cashBefore + 300);
    assertEq(_asset.balanceOf(address(_vault)), 200);
  }

  function test_WhenRedemptionsExceedDeposits_OnlyTheDifferenceComesFromTheCashAccount() external {
    _requestDeposit(_alice, 200);
    _requestRedeem(_bob, 500 * _PAR);
    _settleAtPar();
    assertEq(_asset.balanceOf(_cash), _cashBefore - 300);
    assertEq(_asset.balanceOf(address(_vault)), 500);
  }

  function test_WhenTheyAreEqual_NothingMoves() external {
    _requestDeposit(_alice, 500);
    _requestRedeem(_bob, 500 * _PAR);
    vm.expectCall(address(_asset), abi.encodeWithSelector(IERC20.transfer.selector), 0);
    vm.expectCall(address(_asset), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
    _settleAtPar();
    assertEq(_asset.balanceOf(_cash), _cashBefore);
    assertEq(_asset.balanceOf(address(_vault)), 500);
  }

  function test_TheFeeIsPaidOutOfTheNetting() external {
    address _recipient = makeAddr('recipient');
    _requestDeposit(_alice, 500);
    uint256 _nav = _supply() / _PAR;
    vm.startPrank(_settler);
    _vault.closePeriod();
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.PeriodSettled(3, _nav, _supply(), 500, 500 * _PAR, 0, 0, 0, 7);
    _vault.settlePeriod(_nav, 7, _cash, _recipient, type(uint256).max);
    vm.stopPrank();
    assertEq(_asset.balanceOf(_recipient), 7);
    assertEq(_asset.balanceOf(_cash), _cashBefore + 493);
    assertEq(_asset.balanceOf(address(_vault)), 0);
  }

  function test_AFeeAboveTheDepositsComesFromTheCashAccount() external {
    address _recipient = makeAddr('recipient');
    _requestDeposit(_alice, 5);
    uint256 _nav = _supply() / _PAR;
    vm.startPrank(_settler);
    _vault.closePeriod();
    _vault.settlePeriod(_nav, 7, _cash, _recipient, type(uint256).max);
    vm.stopPrank();
    assertEq(_asset.balanceOf(_recipient), 7);
    assertEq(_asset.balanceOf(_cash), _cashBefore - 2);
  }

  function test_WhenTheCashAccountIsShort_SettlementReverts() external {
    _requestRedeem(_bob, 500 * _PAR);
    uint256 _all = _asset.balanceOf(_cash);
    vm.prank(_cash);
    _asset.transfer(_stranger, _all);
    uint256 _nav = _supply() / _PAR;
    vm.prank(_settler);
    _vault.closePeriod();
    vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, _cash, 0, 500));
    vm.prank(_settler);
    _vault.settlePeriod(_nav, 0, _cash, address(0), type(uint256).max);
    assertEq(_vault.pendingRedeemRequest(0, _bob), 500 * _PAR);
  }

  function test_WhenTheCashAccountHasNotApproved_SettlementReverts() external {
    _requestRedeem(_bob, 500 * _PAR);
    vm.prank(_cash);
    _asset.approve(address(_vault), 0);
    uint256 _nav = _supply() / _PAR;
    vm.prank(_settler);
    _vault.closePeriod();
    vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(_vault), 0, 500));
    vm.prank(_settler);
    _vault.settlePeriod(_nav, 0, _cash, address(0), type(uint256).max);
  }

  /// @dev An asset that delivers less than it was asked to, or a balance read that falls short: settlement refuses
  function test_WhenMoneyIsMissingAfterwards_TheBalanceAuditFires() external {
    _requestDeposit(_alice, 500);
    vm.prank(_settler);
    _vault.closePeriod();
    _requestDeposit(_bob, 40); // the vault must still hold this after settling
    uint256 _nav = _supply() / _PAR;
    vm.mockCall(address(_asset), abi.encodeCall(IERC20.balanceOf, (address(_vault))), abi.encode(uint256(39)));
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_BalanceAudit.selector, 39, 40));
    vm.prank(_settler);
    _vault.settlePeriod(_nav, 0, _cash, address(0), type(uint256).max);
  }

  function test_AtExactlyWhatItOwes_TheBalanceAuditPasses() external {
    _requestDeposit(_alice, 500);
    vm.prank(_settler);
    _vault.closePeriod();
    _requestDeposit(_bob, 40);
    uint256 _nav = _supply() / _PAR;
    vm.mockCall(address(_asset), abi.encodeCall(IERC20.balanceOf, (address(_vault))), abi.encode(uint256(40)));
    vm.prank(_settler);
    _vault.settlePeriod(_nav, 0, _cash, address(0), type(uint256).max);
    vm.clearMockedCalls();
  }

  function test_TheEscrowIsBurnedThroughTheHook() external {
    _requestRedeem(_bob, 500 * _PAR);
    vm.prank(_settler);
    _vault.closePeriod();
    uint256 _nav = _supply() / _PAR;
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IPolicyHook.beforeTransfer,
        (_ctx(IPolicyHook.TransferKind.BURN, address(_vault), address(0), 500 * _PAR, _settler))
      )
    );
    vm.prank(_settler);
    _vault.settlePeriod(_nav, 0, _cash, address(0), type(uint256).max);
    assertEq(_vault.balanceOf(address(_vault)), 0);
  }
}

/// @notice The price takes the 4626's form: the virtual amounts stop a donation inflating it, and the extra decimals keep
///         them from moving an honest one
contract Gated7540VaultUnit_Price is Gated7540VaultUnitTest {
  function _valueOfAllShares(
    uint256 _supplyNow,
    uint256 _nav
  ) internal pure returns (uint256 _value) {
    _value = Math.mulDiv(_supplyNow, _nav + 1, _supplyNow + _PAR);
  }

  /// @dev All of `supply` valued at the period's price stays within `|price − 1| + 1` smallest asset units of `nav`
  function testFuzz_AtAnyPriceAndDecimalsTheVirtualAmountsMoveTheValueByAtMostThePrice(
    uint256 _nav,
    uint256 _wholeShares,
    uint8 _decimalsSeed
  ) external pure {
    uint8[3] memory _options = [2, 6, 18];
    uint256 _assetUnit = 10 ** _options[_decimalsSeed % 3];
    uint256 _shareUnit = _assetUnit * _PAR;
    _wholeShares = bound(_wholeShares, 1, 1e12);
    _nav = bound(_nav, 1, 1e15 * _assetUnit);
    uint256 _supplyNow = _wholeShares * _shareUnit;
    // Assets per whole share, rounded up, is the most one smallest share unit's worth of rounding can move.
    uint256 _price = Math.mulDiv(_nav, _shareUnit, _supplyNow, Math.Rounding.Ceil);
    uint256 _bound = (_price > 1 ? _price - 1 : 1 - _price) + 1;
    assertApproxEqAbs(_valueOfAllShares(_supplyNow, _nav), _nav, _bound);
  }

  function test_AtTwoDecimalsAndAPriceOfTenTheFundLosesNineCents() external pure {
    uint256 _shareUnit = 1e8; // an asset of 2 decimals
    uint256 _nav = 1000 * 100; // $1,000
    uint256 _supplyNow = 100 * _shareUnit; // 100 shares at 10.00
    assertEq(_nav - _valueOfAllShares(_supplyNow, _nav), 9);
  }

  function test_TheFirstPeriodNeedsNoSpecialCase() external {
    _requestDeposit(_alice, 1000);
    _settleAt(0);
    assertEq(_vault.maxMint(_alice), 1000 * _PAR);
    assertEq(_vault.convertToShares(1000), 1000 * _PAR);
    assertEq(_vault.convertToAssets(1000 * _PAR), 1000);
  }

  /// @dev A 1-unit first investor donates $1,000 to the value before a victim's $1,000 period
  function test_TheInflationAttackFails() external {
    uint256 _thousand = 1000e6;
    _holdShares(_seed, 1);
    _requestDeposit(_alice, _thousand);
    _settleAt(1 + _thousand); // the donation counts in the value
    uint256 _victim = _vault.maxMint(_alice);
    vm.prank(_alice);
    _vault.mint(_victim, _alice, _alice);

    uint256 _totalValue = 1 + 2 * _thousand;
    uint256 _victimValue = Math.mulDiv(_victim, _totalValue, _vault.totalSupply());
    assertGe(_victimValue, _thousand * 9998 / 10_000, 'the victim keeps its value');
    uint256 _attackerValue = _totalValue - _victimValue;
    assertLe(_attackerValue, _thousand * 67 / 100, 'the attacker loses at least a third of the donation');
  }

  function test_ConvertToAndTotalAssetsUseTheLastSettlementCountingUnclaimedShares() external {
    assertEq(_vault.totalAssets(), 0);
    assertEq(_vault.convertToShares(5), 5 * _PAR); // par before any settlement
    _holdShares(_alice, 300_000);
    _requestDeposit(_bob, 300_000);
    _settleAt(2 * (_supply() / _PAR)); // the value doubled; bob's shares are unclaimed
    assertApproxEqRel(_vault.convertToAssets(10_000 * _PAR), 20_000, 0.01e18);
    (,, uint256 _unclaimed) = _vault.dealingState();
    assertGt(_unclaimed, 0);
    assertEq(_vault.totalAssets(), _vault.convertToAssets(_vault.totalSupply() + _unclaimed));
    assertApproxEqRel(_vault.totalAssets(), 900_000, 0.01e18);
  }

  /// @dev 1,000 investors dealing daily for 10 years leave 3.65m units against 100m shares at 12 decimals
  function test_TheUnclaimableRoundingIsNegligible() external pure {
    uint256 _dust = 1000 * 365 * 10;
    uint256 _hundredMillionShares = 100_000_000 * 1e12;
    assertLt(Math.mulDiv(_dust, 1e9 * 10_000, _hundredMillionShares), 1, 'under a billionth of a basis point');
  }

  /// @dev A controller's own claim rounds down, and a whole period's shares stay booked
  function testFuzz_TheSumOfClaimsNeverExceedsTheBookAndFallsShortByAtMostOneUnitEach(
    uint256 _nav,
    uint256[4] memory _deposits
  ) external {
    address[4] memory _who = [_alice, _bob, makeAddr('c'), makeAddr('d')];
    for (uint256 _i; _i < 4; ++_i) {
      _deposits[_i] = bound(_deposits[_i], 1, 1e15);
      if (_i > 1) _fund(_who[_i]);
      _requestDeposit(_who[_i], _deposits[_i]);
    }
    _nav = bound(_nav, 0, 1e18);
    _settleAt(_nav);
    (,, uint256 _booked) = _vault.dealingState();

    uint256 _sum;
    for (uint256 _i; _i < 4; ++_i) {
      uint256 _shares = _vault.maxMint(_who[_i]);
      if (_shares == 0) continue;
      _sum += _shares;
      vm.prank(_who[_i]);
      _vault.mint(_shares, _who[_i], _who[_i]);
    }
    assertLe(_sum, _booked);
    assertLe(_booked - _sum, 4);
    (,, uint256 _left) = _vault.dealingState();
    assertEq(_left, _booked - _sum);
  }

  function testFuzz_TheCashClaimsNeverExceedTheBookAndTheVaultCanPayThem(
    uint256 _nav,
    uint256 _a,
    uint256 _b
  ) external {
    _a = bound(_a, 1, 1e9);
    _b = bound(_b, 1, 1e9);
    _holdShares(_alice, _a);
    _holdShares(_bob, _b);
    _requestRedeem(_alice, _vault.balanceOf(_alice));
    _requestRedeem(_bob, _vault.balanceOf(_bob));
    _settleAt(bound(_nav, 0, 1e12));
    uint256 _alicePaid = _vault.maxWithdraw(_alice);
    uint256 _bobPaid = _vault.maxWithdraw(_bob);
    uint256 _held = _asset.balanceOf(address(_vault));
    assertLe(_alicePaid + _bobPaid, _held);
    assertLe(_held - _alicePaid - _bobPaid, 2);
  }

  /// @dev Settlement is one write per side: the cost does not grow with the number of investors
  function test_SettlementCostsTheSameFor1InvestorAnd200() external {
    uint256 _one = _gasToSettleWith(1);
    uint256 _many = _gasToSettleWith(200);
    assertApproxEqAbs(_many, _one, 1000);
  }

  function _gasToSettleWith(
    uint256 _investors
  ) internal returns (uint256 _gas) {
    uint256 _snapshot = vm.snapshotState();
    for (uint256 _i; _i < _investors; ++_i) {
      address _who = address(uint160(0x10000 + _i));
      _asset.mint(_who, 100);
      vm.startPrank(_who);
      _asset.approve(address(_vault), 100);
      _vault.requestDeposit(100, _who, _who);
      vm.stopPrank();
    }
    vm.prank(_settler);
    _vault.closePeriod();
    vm.prank(_settler);
    uint256 _before = gasleft();
    _vault.settlePeriod(0, 0, _cash, address(0), type(uint256).max);
    _gas = _before - gasleft();
    vm.revertToState(_snapshot);
  }
}

contract Gated7540VaultUnit_ClaimDeposit is Gated7540VaultUnitTest {
  function test_WhenAStrangerClaims_ItReverts() external {
    _requestDeposit(_alice, 10);
    _settleAtPar();
    vm.expectRevert(_unauthorized(_stranger));
    vm.prank(_stranger);
    _vault.deposit(10, _stranger, _alice);
  }

  function test_WhenTheControllerClaimsEverything_ItMintsThroughTheHookAndClears(
    uint256 _assets,
    uint256 _nav
  ) external {
    _assets = bound(_assets, 1, _FUNDS);
    _nav = bound(_nav, 0, 1e12);
    _requestDeposit(_alice, _assets);
    _settleAt(_nav);
    uint256 _shares = _vault.maxMint(_alice);
    assertEq(_shares, Math.mulDiv(_assets, _PAR, _nav + 1));
    if (_shares == 0) return;

    vm.expectCall(
      _hook,
      abi.encodeCall(
        IPolicyHook.beforeTransfer, (_ctx(IPolicyHook.TransferKind.MINT, address(0), _bob, _shares, _alice))
      )
    );
    vm.expectEmit(address(_vault));
    emit IERC4626.Deposit(_alice, _bob, _assets, _shares);
    vm.prank(_alice);
    assertEq(_vault.deposit(_assets, _bob, _alice), _shares);

    assertEq(_vault.balanceOf(_bob), _shares);
    assertEq(_vault.claimableDepositRequest(0, _alice), 0);
    assertEq(_vault.maxMint(_alice), 0);
    (,, uint256 _unclaimed) = _vault.dealingState();
    assertEq(_unclaimed, 0);
  }

  /// @dev A genuine split: the first step always yields at least one share, then the remainder clears exactly
  function test_WhenClaimedInTwoStepsByAssets_SharesNeverExceedTheBook(
    uint256 _assets,
    uint256 _nav,
    uint256 _first
  ) external {
    _assets = bound(_assets, 2, 1e12);
    _nav = bound(_nav, 0, 1e9);
    _requestDeposit(_alice, _assets);
    _settleAt(_nav);
    uint256 _shares = _vault.maxMint(_alice);
    if (_shares < 2) return;
    _first = bound(_first, Math.ceilDiv(_assets, _shares), _assets - 1);

    vm.startPrank(_alice);
    uint256 _firstShares = _vault.deposit(_first, _alice, _alice);
    assertEq(_firstShares, Math.mulDiv(_first, _shares, _assets));
    assertGt(_firstShares, 0);
    uint256 _secondShares = _vault.deposit(_vault.maxDeposit(_alice), _alice, _alice);
    vm.stopPrank();

    assertEq(_firstShares + _secondShares, _shares, 'exactly the booked shares');
    assertEq(_vault.balanceOf(_alice), _shares);
    assertEq(_vault.maxDeposit(_alice) + _vault.maxMint(_alice), 0, 'nothing stranded');
  }

  function test_WhenAPartialDepositRoundsToZeroShares_ItReverts() external {
    _requestDeposit(_alice, 10);
    _settleAt(_PAR * 10 - 1); // 10 assets buy exactly 1 share unit
    assertEq(_vault.maxMint(_alice), 1);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAmount.selector);
    vm.prank(_alice);
    _vault.deposit(9, _alice, _alice);
    assertEq(_vault.maxDeposit(_alice), 10, 'the failed claim consumed nothing');
  }

  function test_WhenMintingPartially_TheAssetsRoundUp(
    uint256 _assets,
    uint256 _nav,
    uint256 _first
  ) external {
    _assets = bound(_assets, 1, _FUNDS);
    _nav = bound(_nav, 0, 1e9);
    _requestDeposit(_alice, _assets);
    _settleAt(_nav);
    uint256 _shares = _vault.maxMint(_alice);
    if (_shares < 2) return;
    _first = bound(_first, 1, _shares - 1);

    uint256 _cost = Math.mulDiv(_first, _assets, _shares, Math.Rounding.Ceil);
    vm.startPrank(_alice);
    assertEq(_vault.mint(_first, _alice, _alice), _cost);
    assertEq(_vault.claimableDepositRequest(0, _alice), _assets - _cost);
    // The remainder clears exactly, even when the round-up left fewer assets than shares (or none).
    uint256 _secondCost = _vault.mint(_vault.maxMint(_alice), _alice, _alice);
    vm.stopPrank();

    assertEq(_cost + _secondCost, _assets, 'exactly the booked assets');
    assertEq(_vault.balanceOf(_alice), _shares);
    assertEq(_vault.maxDeposit(_alice) + _vault.maxMint(_alice), 0, 'nothing stranded');
  }

  function test_WhenClaimingMoreThanClaimable_ItReverts() external {
    _requestDeposit(_alice, 10);
    _settleAtPar();
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ExceedsClaimable.selector, 11, 10));
    vm.prank(_alice);
    _vault.deposit(11, _alice, _alice);
  }

  function test_WhenTheAmountIsZero_ItReverts() external {
    _requestDeposit(_alice, 10);
    _settleAtPar();
    vm.startPrank(_alice);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAmount.selector);
    _vault.deposit(0, _alice, _alice);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAmount.selector);
    _vault.mint(0, _alice, _alice);
    vm.stopPrank();
  }

  function test_WhenARequestBuysNoShares_NothingReadsAsClaimable() external {
    _holdShares(_bob, 1000);
    _requestDeposit(_alice, 1);
    _settleAt(2 * (_supply() + _PAR));
    assertEq(_vault.maxMint(_alice), 0);
    assertEq(_vault.maxDeposit(_alice), 0, 'a deposit of what was paid would revert');
    assertEq(_vault.claimableDepositRequest(0, _alice), 1, 'the paid assets are still booked');
  }

  function test_WhenUsingTheErc4626Signature_TheCallerIsTheController() external {
    _requestDeposit(_alice, 10);
    _settleAtPar();
    vm.prank(_alice);
    _vault.deposit(10, _alice);
    assertEq(_vault.balanceOf(_alice), 10 * _PAR);
  }

  /// @dev The ERC-4626 two-argument `mint` claims for the caller as controller
  function test_WhenTheControllerMintsWithTwoArguments_ItClaimsItsOwnRequest() external {
    _requestDeposit(_alice, 100);
    _settleAtPar();
    vm.prank(_alice);
    assertEq(_vault.mint(40 * _PAR, _bob), 40);
    assertEq(_vault.balanceOf(_bob), 40 * _PAR);
    assertEq(_vault.maxMint(_alice), 60 * _PAR);
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ExceedsClaimable.selector, 1, 0));
    vm.prank(_bob);
    _vault.mint(1, _bob);
  }

  function test_WhenAnOperatorClaims_ItSucceeds() external {
    _requestDeposit(_alice, 10);
    _settleAtPar();
    vm.prank(_alice);
    _vault.setOperator(_bob, true);
    vm.prank(_bob);
    _vault.mint(10 * _PAR, _bob, _alice);
    assertEq(_vault.balanceOf(_bob), 10 * _PAR);
  }
}

contract Gated7540VaultUnit_RequestRedeem is Gated7540VaultUnitTest {
  function test_WhenTheControllerIsZero_ItReverts() external {
    _holdShares(_alice, 100);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAddress.selector);
    vm.prank(_alice);
    _vault.requestRedeem(30, address(0), _alice);
    assertEq(_vault.balanceOf(_alice), 100 * _PAR);
  }

  function test_WhenTheOwnerRequests_TheSharesAreEscrowedThroughTheHookAsATransfer(
    uint256 _shares
  ) external {
    _holdShares(_alice, 100);
    _shares = bound(_shares, 1, 100 * _PAR);
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IPolicyHook.beforeTransfer, (_ctx(IPolicyHook.TransferKind.TRANSFER, _alice, address(_vault), _shares, _alice))
      )
    );
    vm.expectEmit(address(_vault));
    emit IERC7540Redeem.RedeemRequest(_bob, _alice, 0, _alice, _shares);
    vm.prank(_alice);
    assertEq(_vault.requestRedeem(_shares, _bob, _alice), 0);
    assertEq(_vault.balanceOf(address(_vault)), _shares);
    assertEq(_vault.pendingRedeemRequest(0, _bob), _shares);
  }

  function test_WhenASpenderRequests_ItSpendsTheAllowance() external {
    _holdShares(_alice, 100);
    vm.prank(_alice);
    _vault.approve(_bob, 40);
    vm.prank(_bob);
    _vault.requestRedeem(30, _bob, _alice);
    assertEq(_vault.allowance(_alice, _bob), 10);
  }

  function test_WhenAnOperatorRequests_NoAllowanceIsNeeded() external {
    _holdShares(_alice, 100);
    vm.prank(_alice);
    _vault.setOperator(_bob, true);
    vm.prank(_bob);
    _vault.requestRedeem(30, _alice, _alice);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 30);
  }

  /// @dev A non-operator needs a share allowance from the owner, as for ERC-20 `transferFrom`
  function test_WhenAStrangerRequests_ItReverts() external {
    _holdShares(_alice, 100);
    vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, _stranger, 0, 30));
    vm.prank(_stranger);
    _vault.requestRedeem(30, _stranger, _alice);
  }

  function test_WhenTheAmountIsZero_ItReverts() external {
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAmount.selector);
    _requestRedeem(_alice, 0);
  }
}

contract Gated7540VaultUnit_ClaimRedeem is Gated7540VaultUnitTest {
  uint256 internal constant _HELD = 50;

  /// @dev Alice's whole position, settled at `_nav`; returns the assets it pays
  function _settledRedemption(
    uint256 _nav
  ) internal returns (uint256 _assets) {
    _holdShares(_alice, _HELD);
    _requestRedeem(_alice, _HELD * _PAR);
    _settleAt(_nav);
    _assets = _vault.maxWithdraw(_alice);
  }

  function test_WhenTheControllerRedeemsEverything_ItPaysAndClears(
    uint256 _nav
  ) external {
    uint256 _assets = _settledRedemption(bound(_nav, 49, _FUNDS / 2));
    vm.expectEmit(address(_vault));
    emit IERC4626.Withdraw(_alice, _bob, _alice, _assets, _HELD * _PAR);
    vm.prank(_alice);
    assertEq(_vault.redeem(_HELD * _PAR, _bob, _alice), _assets);
    assertEq(_asset.balanceOf(_bob), _FUNDS + _assets);
    assertEq(_vault.maxRedeem(_alice), 0);
    assertEq(_vault.maxWithdraw(_alice), 0);
  }

  /// @dev A genuine split: the first step always pays at least one asset, then the remainder clears exactly
  function test_WhenRedeemingPartially_TheAssetsRoundDown(
    uint256 _nav,
    uint256 _first
  ) external {
    uint256 _assets = _settledRedemption(bound(_nav, 49, 1e12));
    uint256 _shares = _HELD * _PAR;
    _first = bound(_first, Math.ceilDiv(_shares, _assets), _shares - 1);
    uint256 _before = _asset.balanceOf(_alice);

    vm.startPrank(_alice);
    uint256 _firstAssets = _vault.redeem(_first, _alice, _alice);
    assertEq(_firstAssets, Math.mulDiv(_first, _assets, _shares));
    assertGt(_firstAssets, 0);
    uint256 _secondAssets = _vault.redeem(_vault.maxRedeem(_alice), _alice, _alice);
    vm.stopPrank();

    assertEq(_firstAssets + _secondAssets, _assets, 'exactly the booked assets');
    assertEq(_asset.balanceOf(_alice) - _before, _assets);
    assertEq(_vault.maxRedeem(_alice) + _vault.maxWithdraw(_alice), 0, 'nothing stranded');
  }

  function test_WhenAPartialRedeemRoundsToZeroAssets_ItReverts() external {
    assertEq(_settledRedemption(49), _HELD * 50 * _PAR / (_HELD * _PAR + _PAR));
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAmount.selector);
    vm.prank(_alice);
    _vault.redeem(1, _alice, _alice);
    assertEq(_vault.maxRedeem(_alice), _HELD * _PAR, 'the failed claim consumed nothing');
  }

  /// @dev Ceil on the shares deducted: a tiny withdrawal can never take assets for zero shares. The remainder then
  ///      clears exactly, including when the round-up consumed every share and only assets are left
  function test_WhenWithdrawingPartially_TheSharesRoundUp(
    uint256 _nav,
    uint256 _first
  ) external {
    uint256 _assets = _settledRedemption(bound(_nav, 49, 1e12));
    if (_assets < 2) return;
    uint256 _shares = _HELD * _PAR;
    _first = bound(_first, 1, _assets - 1);
    uint256 _before = _asset.balanceOf(_alice);

    uint256 _burned = Math.mulDiv(_first, _shares, _assets, Math.Rounding.Ceil);
    vm.startPrank(_alice);
    assertEq(_vault.withdraw(_first, _alice, _alice), _burned);
    assertGt(_burned, 0);
    assertEq(_vault.maxRedeem(_alice), _shares - _burned);
    uint256 _secondBurned = _vault.withdraw(_vault.maxWithdraw(_alice), _alice, _alice);
    vm.stopPrank();

    assertEq(_burned + _secondBurned, _shares, 'exactly the booked shares');
    assertEq(_asset.balanceOf(_alice) - _before, _assets, 'exactly the booked assets');
    assertEq(_vault.maxRedeem(_alice) + _vault.maxWithdraw(_alice), 0, 'nothing stranded');
  }

  function test_WhenTheAmountIsZero_ItReverts() external {
    _settledRedemption(49);
    vm.startPrank(_alice);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAmount.selector);
    _vault.redeem(0, _alice, _alice);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAmount.selector);
    _vault.withdraw(0, _alice, _alice);
    vm.stopPrank();
  }

  function test_WhenARedemptionPaysNothing_NothingReadsAsClaimable() external {
    assertEq(_settledRedemption(0), 0);
    assertEq(_vault.maxRedeem(_alice), 0, 'a redemption of what was paid would revert');
    assertEq(_vault.claimableRedeemRequest(0, _alice), _HELD * _PAR, 'the paid shares are still booked');
  }

  function test_WhenClaimingMoreThanClaimable_ItReverts() external {
    uint256 _assets = _settledRedemption(49);
    vm.startPrank(_alice);
    vm.expectRevert(
      abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ExceedsClaimable.selector, _HELD * _PAR + 1, _HELD * _PAR)
    );
    _vault.redeem(_HELD * _PAR + 1, _alice, _alice);
    vm.expectRevert(
      abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ExceedsClaimable.selector, _assets + 1, _assets)
    );
    _vault.withdraw(_assets + 1, _alice, _alice);
    vm.stopPrank();
  }

  function test_WhenClaimsArePaused_MaxIsZeroAndClaimsRevert() external {
    _settledRedemption(49);
    vm.prank(_guardian);
    _vault.pause();
    assertEq(_vault.maxRedeem(_alice), 0);
    assertEq(_vault.maxWithdraw(_alice), 0);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vm.prank(_alice);
    _vault.redeem(1, _alice, _alice);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vm.prank(_alice);
    _vault.withdraw(1, _alice, _alice);
  }
}

/// @notice The escrow is one balance at the vault's own address, shared by every controller, while pending redemptions
///         are booked per controller. A forced transfer out of the vault may take only the surplus above the booked
///         total, and the vault's own address cannot be frozen, so enforcement on escrowed shares is per controller
contract Gated7540VaultUnit_Escrow is Gated7540VaultUnitTest {
  address internal _quarantine = makeAddr('quarantine');

  /// @dev Alice books 50 and keeps 10, bob books 30: 80 shares booked, 80 in escrow
  function _escrowTwo() internal {
    _holdShares(_alice, 60);
    _holdShares(_bob, 30);
    _requestRedeem(_alice, 50);
    _requestRedeem(_bob, 30);
  }

  function _exceedsSurplus(
    uint256 _requested,
    uint256 _surplus
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ExceedsSurplus.selector, _requested, _surplus);
  }

  function test_WhenTheAgentForcesBookedSharesOutOfTheEscrow_ItReverts() external {
    _escrowTwo();
    vm.expectRevert(_exceedsSurplus(1, 0));
    vm.prank(_agent);
    _vault.forcedTransfer(address(_vault), _quarantine, 1);
    assertEq(_vault.balanceOf(address(_vault)), 80);
  }

  /// @dev Shares that reach the vault outside a request (here a holder's plain transfer) are surplus: the agent can
  ///      force them out, and only them
  function test_WhenSharesReachTheEscrowOutsideARequest_TheAgentCanForceOnlyThoseOut() external {
    _escrowTwo();
    vm.prank(_alice);
    _vault.transfer(address(_vault), 10);

    vm.expectRevert(_exceedsSurplus(11, 10));
    vm.prank(_agent);
    _vault.forcedTransfer(address(_vault), _quarantine, 11);

    vm.prank(_agent);
    _vault.forcedTransfer(address(_vault), _quarantine, 10);
    assertEq(_vault.balanceOf(_quarantine), 10);

    _settleAtPar();
    assertEq(_vault.balanceOf(address(_vault)), 0);
  }

  /// @dev The booked total follows every exit from escrow: settlement, reject and recovery
  function test_WhenRedemptionsLeaveTheEscrow_TheBookedTotalFollows() external {
    _escrowTwo();
    vm.prank(_agent);
    _vault.rejectRedeemRequest(_bob); // 50 booked, 50 held
    vm.expectRevert(_exceedsSurplus(1, 0));
    vm.prank(_agent);
    _vault.forcedTransfer(address(_vault), _quarantine, 1);

    vm.prank(_agent);
    _vault.recoverRedeemRequest(_alice, _quarantine); // nothing booked, nothing held
    assertEq(_vault.balanceOf(address(_vault)), 0);
    vm.prank(_bob);
    _vault.transfer(address(_vault), 5);
    vm.prank(_agent);
    _vault.forcedTransfer(address(_vault), _quarantine, 5);
    assertEq(_vault.balanceOf(_quarantine), 55);

    _requestRedeem(_alice, 1);
    _settleAtPar(); // settled: nothing booked again
    vm.prank(_bob);
    _vault.transfer(address(_vault), 2);
    vm.prank(_agent);
    _vault.forcedTransfer(address(_vault), _quarantine, 2);
  }

  /// @dev Whatever stray amount sits in escrow and whatever the agent tries to force out, booked shares stay, and
  ///      every booked redemption still settles
  function testFuzz_TheAgentCanNeverForceBookedSharesOut(
    uint256 _stray,
    uint256 _amount
  ) external {
    _escrowTwo();
    _stray = bound(_stray, 0, 10);
    _amount = bound(_amount, 1, 90);
    if (_stray > 0) {
      vm.prank(_alice);
      _vault.transfer(address(_vault), _stray);
    }
    if (_amount > _stray) vm.expectRevert(_exceedsSurplus(_amount, _stray));
    vm.prank(_agent);
    _vault.forcedTransfer(address(_vault), _quarantine, _amount);

    _settleAtPar();
    assertEq(_vault.pendingRedeemRequest(0, _alice) + _vault.pendingRedeemRequest(0, _bob), 0);
  }

  function test_WhenTheAgentFreezesTheEscrow_ItReverts() external {
    _escrowTwo();
    vm.expectRevert(IGatedVaultBase.GatedVault_Unsupported.selector);
    vm.prank(_agent);
    _vault.setFrozenTokens(address(_vault), 30);
    assertEq(_vault.getFrozenTokens(address(_vault)), 0);
  }

  /// @dev Holding one controller's redemption is per controller: the agent recovers it, and the others still settle
  function test_ToHoldOneRedemption_TheAgentRecoversItAndTheOthersStillSettle() external {
    _escrowTwo();
    vm.prank(_agent);
    _vault.recoverRedeemRequest(_bob, _quarantine);
    assertEq(_vault.balanceOf(_quarantine), 30);
    assertEq(_vault.pendingRedeemRequest(0, _bob), 0);
    _settleAtPar();
    assertEq(_vault.balanceOf(address(_vault)), 0);
  }

  /// @dev The escrow rules do not mask the role check: without AGENT_ROLE both calls fail on the role, whatever they ask
  function test_WhenACallerWithoutTheAgentRoleNamesTheEscrow_TheRoleCheckAnswers() external {
    _escrowTwo();
    bytes memory _denied = _noRole(_stranger, _vault.AGENT_ROLE());
    vm.expectRevert(_denied);
    vm.prank(_stranger);
    _vault.forcedTransfer(address(_vault), _quarantine, 81);
    vm.expectRevert(_denied);
    vm.prank(_stranger);
    _vault.setFrozenTokens(address(_vault), 1);
  }

  /// @dev A forced transfer from any other address is unchanged
  function test_WhenTheAgentForcesFromAHolder_ItWorksAsBefore() external {
    _escrowTwo();
    vm.prank(_agent);
    _vault.forcedTransfer(_alice, _quarantine, 10);
    assertEq(_vault.balanceOf(_quarantine), 10);
  }
}

/// @dev Every claim and every action on a request is gated; each check is pinned (mutation: removing any one fails here)
contract Gated7540VaultUnit_ClaimAccess is Gated7540VaultUnitTest {
  address internal _operator = makeAddr('operator');

  function _notAlice(
    address _caller
  ) internal view returns (address _someoneElse) {
    _someoneElse = _caller == _alice || _caller == _operator ? _stranger : _caller;
  }

  function _claimableRedemption() internal {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50 * _PAR);
    _settleAtPar();
  }

  function _claimableDeposit() internal {
    _requestDeposit(_alice, 100);
    _settleAtPar();
  }

  function testFuzz_WhenSomeoneElseRedeemsTheControllersClaim_ItReverts(
    address _caller
  ) external {
    _caller = _notAlice(_caller);
    _claimableRedemption();
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_Unauthorized.selector, _caller));
    vm.prank(_caller);
    _vault.redeem(50, _alice, _alice);
  }

  function testFuzz_WhenSomeoneElseWithdrawsTheControllersClaim_ItReverts(
    address _caller
  ) external {
    _caller = _notAlice(_caller);
    _claimableRedemption();
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_Unauthorized.selector, _caller));
    vm.prank(_caller);
    _vault.withdraw(50, _alice, _alice);
  }

  function testFuzz_WhenSomeoneElseMintsTheControllersClaim_ItReverts(
    address _caller
  ) external {
    _caller = _notAlice(_caller);
    _claimableDeposit();
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_Unauthorized.selector, _caller));
    vm.prank(_caller);
    _vault.mint(100, _caller, _alice);
  }

  function testFuzz_WhenSomeoneElseDepositsTheControllersClaim_ItReverts(
    address _caller
  ) external {
    _caller = _notAlice(_caller);
    _claimableDeposit();
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_Unauthorized.selector, _caller));
    vm.prank(_caller);
    _vault.deposit(100, _caller, _alice);
  }

  /// @dev Control: an operator the controller approved can claim every way, to any receiver
  function test_WhenAnApprovedOperatorClaims_ItSucceeds() external {
    vm.prank(_alice);
    _vault.setOperator(_operator, true);
    _claimableRedemption();
    _claimableDeposit();
    vm.startPrank(_operator);
    _vault.mint(40 * _PAR, _bob, _alice);
    _vault.deposit(_vault.maxDeposit(_alice), _bob, _alice);
    _vault.redeem(20 * _PAR, _bob, _alice);
    _vault.withdraw(_vault.maxWithdraw(_alice), _bob, _alice);
    vm.stopPrank();
    assertEq(_vault.maxMint(_alice) + _vault.maxRedeem(_alice) + _vault.maxWithdraw(_alice), 0);
  }
}

contract Gated7540VaultUnit_Rejects is Gated7540VaultUnitTest {
  function _closed() internal {
    vm.prank(_settler);
    _vault.closePeriod();
  }

  function test_WhenADepositIsRejected_TheAssetsReturnToTheController() external {
    vm.prank(_alice);
    _vault.requestDeposit(40, _bob, _alice);
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.DepositRequestRejected(_bob, 40);
    vm.prank(_agent);
    _vault.rejectDepositRequest(_bob);
    assertEq(_asset.balanceOf(_bob), _FUNDS + 40);
    assertEq(_vault.pendingDepositRequest(0, _bob), 0);
  }

  /// @dev A rejected request leaves the period's book, so it is not priced
  function test_WhenARequestIsRejected_ThePeriodSettlesWithoutIt() external {
    _requestDeposit(_alice, 40);
    _requestDeposit(_bob, 60);
    vm.prank(_agent);
    _vault.rejectDepositRequest(_alice);
    vm.startPrank(_settler);
    _vault.closePeriod();
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.PeriodSettled(1, 0, 0, 60, 60 * _PAR, 0, 0, 0, 0);
    _vault.settlePeriod(0, 0, _cash, address(0), type(uint256).max);
    vm.stopPrank();
    assertEq(_vault.maxMint(_bob), 60 * _PAR);
    assertEq(_vault.maxMint(_alice), 0);
  }

  /// @dev A controller that was rejected can request again in the same period
  function test_WhenRejected_TheControllerCanRequestAgain() external {
    _requestDeposit(_alice, 40);
    vm.prank(_agent);
    _vault.rejectDepositRequest(_alice);
    _requestDeposit(_alice, 10);
    assertEq(_vault.pendingDepositRequest(0, _alice), 10);
  }

  /// @dev M-2 (reverses R2): the shares return as a plain TRANSFER, so the full policy applies to the controller
  function test_WhenARedemptionIsRejected_TheSharesReturnAsAPlainTransferAndItEmits() external {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 30);
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IPolicyHook.beforeTransfer, (_ctx(IPolicyHook.TransferKind.TRANSFER, address(_vault), _alice, 30, _agent))
      )
    );
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.RedeemRequestRejected(_alice, 30);
    vm.prank(_agent);
    _vault.rejectRedeemRequest(_alice);
    assertEq(_vault.balanceOf(_alice), 50 * _PAR);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);
  }

  /// @dev M-2: a plain TRANSFER respects the pause; the shares stay escrowed (the agent can still recover them)
  function test_WhenPaused_ARedemptionRejectIsRefusedAndTheSharesStayEscrowed() external {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 30);
    vm.prank(_guardian);
    _vault.pause();
    vm.expectRevert(abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_TransferRejected.selector, Reasons.PAUSED));
    vm.prank(_agent);
    _vault.rejectRedeemRequest(_alice);
    assertEq(_vault.balanceOf(address(_vault)), 30);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 30);
  }

  function test_WhenNothingIsPending_RejectsRevert() external {
    vm.startPrank(_agent);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _vault.rejectDepositRequest(_alice);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _vault.rejectRedeemRequest(_alice);
    vm.stopPrank();
  }

  function testFuzz_WhileThePeriodIsOpen_OnlyTheAgentRejects(
    address _caller
  ) external {
    bytes32 _role = _vault.AGENT_ROLE();
    if (_vault.hasRole(_role, _caller)) _caller = _stranger;
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    _requestDeposit(_alice, 5);
    vm.startPrank(_caller);
    vm.expectRevert(_noRole(_caller, _role));
    _vault.rejectRedeemRequest(_alice);
    vm.expectRevert(_noRole(_caller, _role));
    _vault.rejectDepositRequest(_alice);
    vm.expectRevert(_noRole(_caller, _role));
    _vault.recoverRedeemRequest(_alice, _bob);
    vm.stopPrank();
    assertEq(_vault.pendingRedeemRequest(0, _alice), 50);
  }

  function test_WhileThePeriodIsOpen_TheSettlerCannotReject() external {
    _requestDeposit(_alice, 5);
    vm.expectRevert(_noRole(_settler, _vault.AGENT_ROLE()));
    vm.prank(_settler);
    _vault.rejectDepositRequest(_alice);
  }

  function test_OnceThePeriodHasClosed_OnlyTheSettlerRejects() external {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    _requestDeposit(_alice, 5);
    _closed();

    bytes memory _denied = _noRole(_agent, _vault.SETTLER_ROLE());
    vm.startPrank(_agent);
    vm.expectRevert(_denied);
    _vault.rejectRedeemRequest(_alice);
    vm.expectRevert(_denied);
    _vault.rejectDepositRequest(_alice);
    vm.expectRevert(_denied);
    _vault.recoverRedeemRequest(_alice, _bob);
    vm.stopPrank();

    vm.startPrank(_settler);
    _vault.rejectDepositRequest(_alice);
    _vault.rejectRedeemRequest(_alice);
    vm.stopPrank();
    assertEq(_vault.pendingRedeemRequest(0, _alice) + _vault.pendingDepositRequest(0, _alice), 0);
  }

  function test_OnceThePeriodHasClosed_TheSettlerRecovers() external {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    _closed();
    vm.prank(_settler);
    _vault.recoverRedeemRequest(_alice, _bob);
    assertEq(_vault.balanceOf(_bob), 50);
  }

  /// @dev Rejected out of a closed period, the amount leaves that period's book
  function test_WhenRejectedOutOfAClosedPeriod_ThePeriodSettlesWithoutIt() external {
    _requestDeposit(_alice, 40);
    _requestDeposit(_bob, 60);
    _closed();
    vm.startPrank(_settler);
    _vault.rejectDepositRequest(_alice);
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.PeriodSettled(1, 0, 0, 60, 60 * _PAR, 0, 0, 0, 0);
    _vault.settlePeriod(0, 0, _cash, address(0), type(uint256).max);
    vm.stopPrank();
  }

  function test_OnceSettled_NothingIsPendingToReject() external {
    _requestDeposit(_alice, 40);
    _settleAtPar();
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    vm.prank(_agent);
    _vault.rejectDepositRequest(_alice);
  }
}

contract Gated7540VaultUnit_Recover is Gated7540VaultUnitTest {
  function _recover(
    address _controller,
    address _to
  ) internal {
    vm.prank(_agent);
    _vault.recoverRedeemRequest(_controller, _to);
  }

  function test_WhenCallerIsNotAnAgent_ItReverts() external {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    bytes32 _role = _vault.AGENT_ROLE();
    vm.expectRevert(_noRole(_settler, _role));
    vm.prank(_settler);
    _vault.recoverRedeemRequest(_alice, _bob);
  }

  function test_WhenNothingIsPending_ItReverts() external {
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _recover(_alice, _bob);
  }

  function test_WhenTheRecipientIsZero_ItReverts() external {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAddress.selector);
    _recover(_alice, address(0));
  }

  function test_WhenAnAgentRecovers_TheEscrowMovesAsForcedAndTheRequestClears(
    uint256 _shares
  ) external {
    _holdShares(_alice, 100);
    _shares = bound(_shares, 1, 100 * _PAR);
    _requestRedeem(_alice, _shares);
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IPolicyHook.beforeTransfer, (_ctx(IPolicyHook.TransferKind.FORCED, address(_vault), _bob, _shares, _agent))
      )
    );
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.RedeemRequestRecovered(_alice, _bob, _shares, _agent);
    _recover(_alice, _bob);

    assertEq(_vault.balanceOf(_bob), _shares);
    assertEq(_vault.balanceOf(address(_vault)), 0);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);
  }

  function test_WhenPaused_RecoveryStillWorks() external {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    vm.prank(_guardian);
    _vault.pause();
    _recover(_alice, _bob);
    assertEq(_vault.balanceOf(_bob), 50);
  }

  function test_WhenRecovered_LaterRejectsRevertWithNoRequestAndThePeriodSettlesWithoutIt() external {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    _recover(_alice, _bob);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    vm.prank(_agent);
    _vault.rejectRedeemRequest(_alice);
    _settleAtPar();
    assertEq(_vault.balanceOf(_bob), 50);
  }
}

contract Gated7540VaultUnit_RecoverClaimable is Gated7540VaultUnitTest {
  function _recover() internal {
    vm.prank(_agent);
    _vault.recoverClaimable(_alice, _bob);
  }

  /// @dev Its mint raises `totalSupply()`, so what it delivers must leave `unclaimedShares` or it would count twice
  function testFuzz_RecoveringClaimableSharesLeavesTheSupplyUnchanged(
    uint256 _assets,
    uint256 _nav
  ) external {
    _assets = bound(_assets, 1, _FUNDS);
    _requestDeposit(_alice, _assets);
    _settleAt(bound(_nav, 0, 1e9));
    uint256 _before = _supply();
    if (_vault.maxMint(_alice) == 0) return;
    _recover();
    assertEq(_supply(), _before);
    assertEq(_vault.balanceOf(_bob), _before);
    assertEq(_vault.maxMint(_alice), 0);
  }

  function test_RecoveringClaimableCashLowersWhatTheVaultOwes() external {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50 * _PAR);
    _settleAtPar();
    assertEq(_asset.balanceOf(address(_vault)), 50);
    _recover();
    assertEq(_asset.balanceOf(_bob), _FUNDS + 50);
    assertEq(_asset.balanceOf(address(_vault)), 0);

    // The audit must not count the recovered cash as still owed.
    _requestDeposit(_alice, 10);
    _settleAtPar();
  }

  function test_APendingRequestStaysWhenTheClaimableIsRecovered() external {
    _requestDeposit(_alice, 10);
    _settleAtPar();
    _requestDeposit(_alice, 5);
    _recover();
    assertEq(_vault.pendingDepositRequest(0, _alice), 5);
    assertEq(_vault.maxMint(_alice), 0);
    _settleAtPar();
    assertEq(_vault.maxMint(_alice), 5 * _PAR);
  }

  function test_ASettledRequestThatNeverRolledIsRecoveredToo() external {
    _requestDeposit(_alice, 10);
    _settleAtPar();
    _recover();
    assertEq(_vault.balanceOf(_bob), 10 * _PAR);
    _settleAtPar();
    assertEq(_vault.maxMint(_alice), 0, 'it does not pay twice');
  }

  function test_WhenOwedRoundedToNothing_TheAmountsStillClear() external {
    _requestDeposit(_alice, 1);
    _settleAt(2 * _PAR); // 1 asset buys less than one share unit
    assertEq(_vault.maxMint(_alice), 0);
    assertEq(_vault.maxDeposit(_alice), 0, 'a claim of the asset would revert');
    assertEq(_vault.claimableDepositRequest(0, _alice), 1);
    _recover();
    assertEq(_vault.claimableDepositRequest(0, _alice), 0);
  }
}

contract Gated7540VaultUnit_Views is Gated7540VaultUnitTest {
  function test_WhenPreviewing_ItAlwaysReverts() external {
    vm.expectRevert(IGated7540Vault.Gated7540Vault_AsyncOnly.selector);
    _vault.previewDeposit(1);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_AsyncOnly.selector);
    _vault.previewMint(1);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_AsyncOnly.selector);
    _vault.previewWithdraw(1);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_AsyncOnly.selector);
    _vault.previewRedeem(1);
  }

  function test_WhenTheControllerIsIneligible_MaxDepositAndMaxMintAreZero() external {
    _requestDeposit(_alice, 10);
    _settleAtPar();
    _hookDecides(Reasons.RECEIVER_NOT_VERIFIED);
    assertEq(_vault.maxDeposit(_alice), 0);
    assertEq(_vault.maxMint(_alice), 0);
  }

  function test_ClaimableDoesNotDependOnTheRollHavingBeenWritten() external {
    _requestDeposit(_alice, 10);
    _settleAtPar();
    assertEq(_vault.pendingDepositRequest(0, _alice), 0);
    assertEq(_vault.claimableDepositRequest(0, _alice), 10);
    assertEq(_vault.maxDeposit(_alice), 10);
    assertEq(_vault.maxMint(_alice), 10 * _PAR);
  }
}

/// @notice Integration: the async vault behind a real ComplianceHook with an identity rule, HolderRestriction and the
///         fund's holder cap (`FundHoldersRule`, a fund of one class with a cap of 2)
contract Gated7540VaultIntegrationTest is Test {
  uint256 internal constant _PAR = 1e6;

  Gated7540Vault internal _vault;
  MockAsset internal _asset;
  MockIdentityRegistry internal _identity;
  HolderRestrictionRule internal _restrictionRule;
  Fund internal _fund;
  address internal _guardian = makeAddr('guardian');
  address internal _agent = makeAddr('agent');
  address internal _settler = makeAddr('settler');
  address internal _cash = makeAddr('cash');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');
  address internal _carol = makeAddr('carol');
  address internal _eve = makeAddr('eve'); // never verified

  function setUp() public {
    // Configure, then hand over: this test is the vault admin while it configures.
    PolicyRegistry _registry = new PolicyRegistry(address(this), address(this));
    _identity = new MockIdentityRegistry();
    MockIdentityRule _identityRule = new MockIdentityRule(IIdentityRegistry(address(_identity)));
    _restrictionRule = new HolderRestrictionRule();
    _fund = new Fund(address(this), _registry);
    FundHoldersRule _fundRule = new FundHoldersRule(_fund);
    _registry.attest(address(_identityRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_restrictionRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_fundRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _fund.setRule(address(_fundRule));
    _fund.setHolderCap(2);

    _asset = new MockAsset(6);
    Gated7540Vault _impl = new Gated7540Vault();
    IComplianceRule[] memory _rules = new IComplianceRule[](3);
    _rules[0] = _identityRule;
    _rules[1] = _restrictionRule;
    _rules[2] = _fundRule;
    // CREATE2 through ProxyDeployer, as in production: the address does not depend on this contract's nonce.
    ProxyDeployer _proxyDeployer = new ProxyDeployer(address(this), _registry);
    ComplianceHook _hook = new ComplianceHook(_registry);
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _vault = Gated7540Vault(
      address(
        _proxyDeployer.deploy(
          'gASYNC',
          address(_impl),
          abi.encodeCall(
            Gated7540Vault.initialize,
            (
              IERC20(address(_asset)),
              'Gated Async Fund',
              'gASYNC',
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
    _vault.grantRole(_vault.SETTLER_ROLE(), _settler);
    _vault.grantRole(_vault.AGENT_ROLE(), _agent);
    _fund.registerClass(address(_vault));
    // The mock identity rule has no exemption for a token's own address, as `CredentialRule` does. The fund never counts
    // the class itself, so the escrow takes no investor slot.
    _identity.set(address(_vault), true);

    _identity.set(_alice, true);
    _identity.set(_bob, true);
    _identity.set(_carol, true);
    address[5] memory _accounts = [_alice, _bob, _carol, _eve, _cash];
    for (uint256 _i; _i < 5; ++_i) {
      _asset.mint(_accounts[_i], 1e12);
      vm.prank(_accounts[_i]);
      _asset.approve(address(_vault), type(uint256).max);
    }
  }

  function _supply() internal view returns (uint256 _all) {
    (,, uint256 _unclaimed) = _vault.dealingState();
    _all = _vault.totalSupply() + _unclaimed;
  }

  function _settleAtPar() internal {
    uint256 _nav = _supply() / _PAR;
    vm.startPrank(_settler);
    _vault.closePeriod();
    _vault.settlePeriod(_nav, 0, _cash, address(0), type(uint256).max);
    vm.stopPrank();
  }

  /// @dev Leaves `_account` holding `_amount * _PAR` shares
  function _invest(
    address _account,
    uint256 _amount
  ) internal {
    vm.prank(_account);
    _vault.requestDeposit(_amount, _account, _account);
    _settleAtPar();
    vm.prank(_account);
    _vault.mint(_amount * _PAR, _account, _account);
  }
}

contract Gated7540VaultIntegration_Lifecycle is Gated7540VaultIntegrationTest {
  function test_WhenAnInvestorRoundTrips_AssetsAndSharesSettle() external {
    _invest(_alice, 1000);
    assertEq(_vault.balanceOf(_alice), 1000 * _PAR);
    assertEq(_asset.balanceOf(_cash), 1e12 + 1000);
    assertEq(_fund.holderCount(), 1);

    vm.prank(_alice);
    _vault.requestRedeem(1000 * _PAR, _alice, _alice);
    assertEq(_fund.holderCount(), 0); // full escrow: alice left, and the vault, the class itself, never joins
    vm.startPrank(_settler);
    _vault.closePeriod();
    _vault.settlePeriod(1100, 0, _cash, address(0), type(uint256).max); // the value rose 10%
    vm.stopPrank();
    assertEq(_vault.totalSupply(), 0);
    uint256 _owed = _vault.maxWithdraw(_alice);
    assertApproxEqRel(_owed, 1100, 0.002e18);
    vm.prank(_alice);
    _vault.redeem(1000 * _PAR, _alice, _alice);
    assertEq(_asset.balanceOf(_alice), 1e12 - 1000 + _owed);
  }

  function test_WhenTheControllerIsUnverified_ADepositRequestIsRefused() external {
    vm.expectRevert(
      abi.encodeWithSelector(
        IGated7540Vault.Gated7540Vault_ControllerNotEligible.selector, Reasons.RECEIVER_NOT_VERIFIED
      )
    );
    vm.prank(_eve);
    _vault.requestDeposit(10, _eve, _eve);
  }

  /// @dev Eligibility is about who will hold the shares: a verified owner cannot open a request for an unverified
  ///      controller. Kills the mutant that checks the owner instead (every other test uses owner == controller)
  function test_WhenAVerifiedOwnerRequestsForAnUnverifiedController_ItIsRefused() external {
    vm.expectRevert(
      abi.encodeWithSelector(
        IGated7540Vault.Gated7540Vault_ControllerNotEligible.selector, Reasons.RECEIVER_NOT_VERIFIED
      )
    );
    vm.prank(_alice);
    _vault.requestDeposit(10, _eve, _alice);
  }
}

contract Gated7540VaultIntegration_Escrow is Gated7540VaultIntegrationTest {
  /// @dev Owner-specified (R1): cap full, the vault holds nothing, a partial redemption request still succeeds
  function test_WhenTheCapIsFullAndTheVaultIsEmpty_APartialRedeemRequestSucceeds() external {
    _invest(_alice, 100);
    _invest(_bob, 100);
    assertEq(_fund.holderCount(), 2); // cap reached
    assertEq(_vault.balanceOf(address(_vault)), 0);

    vm.prank(_alice);
    _vault.requestRedeem(40, _alice, _alice);
    assertEq(_vault.balanceOf(address(_vault)), 40);
    assertEq(_fund.holderCount(), 2);
  }

  /// @dev The escrow move is a TRANSFER, so a locked holder cannot exit by filing a request
  function test_WhenTheHolderIsLocked_ARedeemRequestIsRefused() external {
    _invest(_alice, 100);
    vm.prank(_agent);
    _restrictionRule.setLockup(address(_vault), _alice, block.timestamp + 30 days);
    vm.expectRevert(abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_TransferRejected.selector, Reasons.LOCKED));
    vm.prank(_alice);
    _vault.requestRedeem(100, _alice, _alice);
  }

  function test_WhenSharesAreFrozen_TheyCannotBeEscrowed() external {
    _invest(_alice, 100);
    vm.prank(_agent);
    _vault.setFrozenTokens(_alice, 100 * _PAR);
    vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943InsufficientUnfrozenBalance.selector, _alice, 1, 0));
    vm.prank(_alice);
    _vault.requestRedeem(1, _alice, _alice);
  }

  /// @dev A freeze or lock on the vault's own address stops settlement, and that is a deliberate stop
  function test_WhenTheVaultItselfIsFrozen_SettlementStops() external {
    _invest(_alice, 100);
    vm.prank(_alice);
    _vault.requestRedeem(40, _alice, _alice);
    vm.prank(_agent);
    _restrictionRule.setFrozen(address(_vault), address(_vault), true);
    uint256 _nav = _supply() / _PAR;
    vm.startPrank(_settler);
    _vault.closePeriod();
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_TransferRejected.selector, Reasons.SENDER_FROZEN)
    );
    _vault.settlePeriod(_nav, 0, _cash, address(0), type(uint256).max);
    vm.stopPrank();
  }

  /// @dev M-2, cap full: a controller that left the count cannot be re-admitted by a reject; the agent recovers instead
  function test_WhenRejectedAtAFullCapToANewHolder_TheRejectRevertsAndTheAgentRecovers() external {
    _invest(_alice, 100);
    vm.prank(_bob);
    _vault.requestDeposit(100, _bob, _bob);
    vm.prank(_carol);
    _vault.requestDeposit(100, _carol, _carol);
    _settleAtPar(); // their shares are unclaimed, so they do not count yet
    vm.prank(_alice);
    _vault.requestRedeem(100 * _PAR, _alice, _alice); // alice leaves the count
    vm.prank(_bob);
    _vault.mint(100 * _PAR, _bob, _bob);
    vm.prank(_carol);
    _vault.mint(100 * _PAR, _carol, _carol); // the cap is full again without alice

    vm.expectRevert(abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_TransferRejected.selector, Reasons.MAX_HOLDERS));
    vm.prank(_agent);
    _vault.rejectRedeemRequest(_alice);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 100 * _PAR);

    vm.prank(_agent);
    _vault.recoverRedeemRequest(_alice, _bob); // FORCED, to an existing holder
    assertEq(_vault.balanceOf(_bob), 200 * _PAR);
    assertEq(_fund.holderCount(), 2);
  }

  /// @dev M-2, cap full: a controller that still holds is not a new holder, so the reject goes through
  function test_WhenRejectedAtAFullCapToAnExistingHolder_TheSharesReturn() external {
    _invest(_alice, 100);
    _invest(_bob, 100); // cap full
    vm.prank(_alice);
    _vault.requestRedeem(40, _alice, _alice); // alice still holds the rest
    vm.prank(_agent);
    _vault.rejectRedeemRequest(_alice);
    assertEq(_vault.balanceOf(_alice), 100 * _PAR);
    assertEq(_fund.holderCount(), 2);
  }

  /// @dev M-2, the steering attack: naming a new holder as controller cannot route shares past a full cap
  function test_WhenAHolderNamesANewControllerAtAFullCap_TheRejectCannotBypassTheCap() external {
    _invest(_alice, 100);
    _invest(_bob, 100); // cap full; carol is verified but holds nothing
    vm.expectRevert(abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_TransferRejected.selector, Reasons.MAX_HOLDERS));
    vm.prank(_alice);
    _vault.transfer(_carol, 10); // the direct route is refused...

    vm.prank(_alice);
    _vault.requestRedeem(10, _carol, _alice);
    vm.expectRevert(abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_TransferRejected.selector, Reasons.MAX_HOLDERS));
    vm.prank(_agent);
    _vault.rejectRedeemRequest(_carol); // ...and so is the request-then-reject route
    assertEq(_vault.balanceOf(_carol), 0);
    assertEq(_fund.holderCount(), 2);
  }

  /// @dev A de-verified controller's reject reverts and the shares stay escrowed (unchanged by M-2)
  function test_WhenTheControllerWasDeverified_TheRejectRevertsAndTheSharesStayEscrowed() external {
    _invest(_alice, 100);
    vm.prank(_alice);
    _vault.requestRedeem(60, _alice, _alice);
    _identity.set(_alice, false);

    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_TransferRejected.selector, Reasons.RECEIVER_NOT_VERIFIED)
    );
    vm.prank(_agent);
    _vault.rejectRedeemRequest(_alice);
    assertEq(_vault.balanceOf(address(_vault)), 60);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 60);
  }

  /// @dev Owner-specified: de-verified controller -> reject reverts -> agent recovers to a verified account -> no request
  function test_WhenTheControllerWasDeverified_TheAgentRecoversToAVerifiedAccount() external {
    address _treasury = makeAddr('treasury');
    _identity.set(_treasury, true);
    _invest(_alice, 100);
    vm.prank(_alice);
    _vault.requestRedeem(60, _alice, _alice);
    _identity.set(_alice, false);

    vm.prank(_agent);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_TransferRejected.selector, Reasons.RECEIVER_NOT_VERIFIED)
    );
    _vault.rejectRedeemRequest(_alice);

    vm.prank(_agent);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_TransferRejected.selector, Reasons.RECEIVER_NOT_VERIFIED)
    );
    _vault.recoverRedeemRequest(_alice, _eve); // the recovery account must be verified too

    vm.prank(_agent);
    _vault.recoverRedeemRequest(_alice, _treasury);
    assertEq(_vault.balanceOf(_treasury), 60);
    assertEq(_vault.balanceOf(address(_vault)), 0);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);

    vm.prank(_agent);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _vault.rejectRedeemRequest(_alice);
  }
}

/// @notice Drives requests, settlements, claims and rejects across a few controllers
contract Gated7540Handler is Test {
  /// @dev What an action needs an actor to have; the handler picks the first actor (from the fuzzed seed) that has it
  enum Need {
    PendingDeposit,
    ClaimableDepositAssets,
    ClaimableDepositShares,
    Shares,
    PendingRedeem,
    ClaimableRedeemShares,
    ClaimableRedeemAssets
  }

  Gated7540Vault internal _vault;
  MockAsset internal _asset;
  address internal _settler;
  address internal _cash;
  address[3] internal _actors;

  /// @notice Ghost counters: how many times each action actually executed in the current run
  mapping(bytes32 _action => uint256 _count) public executed;

  constructor(
    Gated7540Vault _target,
    MockAsset _underlying,
    address _settlerRole,
    address _cashAccount
  ) {
    _vault = _target;
    _asset = _underlying;
    _settler = _settlerRole;
    _cash = _cashAccount;
    _actors = [makeAddr('actor0'), makeAddr('actor1'), makeAddr('actor2')];
    for (uint256 _i; _i < 3; ++_i) {
      vm.prank(_actors[_i]);
      _asset.approve(address(_vault), type(uint256).max);
    }
  }

  function actors() external view returns (address[3] memory _all) {
    _all = _actors;
  }

  /// @dev Whether a request on this side would wait for an earlier period to settle
  function _waits(
    address _controller,
    bool _isDeposit
  ) internal view returns (bool _waiting) {
    (uint64 _open, uint64 _settled,) = _vault.dealingState();
    uint256 _pending =
      _isDeposit ? _vault.pendingDepositRequest(0, _controller) : _vault.pendingRedeemRequest(0, _controller);
    _waiting = _pending != 0 && _open != _settled + 1 && _opensEarlier(_controller, _isDeposit, _open);
  }

  /// @dev Whether the pending request sits in the closed period, from the state the views can show
  function _opensEarlier(
    address _controller,
    bool _isDeposit,
    uint64 _open
  ) internal view returns (bool _earlier) {
    _earlier = _joinedIn[_controller][_isDeposit] != _open;
  }

  /// @notice The period each controller's pending request joined, on each side
  mapping(address _controller => mapping(bool _isDeposit => uint64 _period)) internal _joinedIn;

  function _noteJoin(
    address _controller,
    bool _isDeposit
  ) internal {
    (uint64 _open,,) = _vault.dealingState();
    _joinedIn[_controller][_isDeposit] = _open;
  }

  function requestDeposit(
    uint256 _seed,
    uint256 _assets
  ) external {
    address _actor = _actors[_seed % 3];
    if (_waits(_actor, true)) return;
    _assets = bound(_assets, 1, 1e15);
    _asset.mint(_actor, _assets);
    vm.prank(_actor);
    _vault.requestDeposit(_assets, _actor, _actor);
    _noteJoin(_actor, true);
    ++executed['requestDeposit'];
  }

  /// @dev Controller differs from the owner: the owner pays, the next actor controls the claim
  function requestDepositFor(
    uint256 _seed,
    uint256 _assets
  ) external {
    address _owner = _actors[_seed % 3];
    address _controller = _actors[(_seed + 1) % 3];
    if (_waits(_controller, true)) return;
    _assets = bound(_assets, 1, 1e15);
    _asset.mint(_owner, _assets);
    vm.prank(_owner);
    _vault.requestDeposit(_assets, _controller, _owner);
    _noteJoin(_controller, true);
    ++executed['requestDepositFor'];
  }

  /// @dev Controller differs from the owner: the owner's shares are escrowed under the next actor's request
  function requestRedeemFor(
    uint256 _seed,
    uint256 _shares
  ) external {
    (address _owner, uint256 _max) = _firstWith(_seed, Need.Shares);
    if (_max == 0) return;
    address _controller = _owner == _actors[0] ? _actors[1] : _actors[0];
    if (_waits(_controller, false)) return;
    vm.prank(_owner);
    _vault.requestRedeem(bound(_shares, 1, _max), _controller, _owner);
    _noteJoin(_controller, false);
    ++executed['requestRedeemFor'];
  }

  function requestRedeem(
    uint256 _seed,
    uint256 _shares
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.Shares);
    if (_max == 0 || _waits(_actor, false)) return;
    vm.prank(_actor);
    _vault.requestRedeem(bound(_shares, 1, _max), _actor, _actor);
    _noteJoin(_actor, false);
    ++executed['requestRedeem'];
  }

  function closePeriod() external {
    (uint64 _open, uint64 _settled,) = _vault.dealingState();
    if (_open != _settled + 1) return;
    vm.prank(_settler);
    _vault.closePeriod();
    ++executed['closePeriod'];
  }

  /// @dev Settles at a value from half to twice par, closing first if it must, and funding the cash account for whatever
  ///      it must pay
  function settlePeriod(
    uint256 _navSeed,
    uint256 _feeSeed,
    uint256 _limitSeed
  ) external {
    (uint64 _open, uint64 _settled, uint256 _unclaimed) = _vault.dealingState();
    if (_open == _settled + 1) {
      vm.prank(_settler);
      _vault.closePeriod();
    }
    uint256 _par = (_vault.totalSupply() + _unclaimed) / 1e6;
    uint256 _nav = bound(_navSeed, _par / 2, 2 * _par + 1);
    uint256 _fee = bound(_feeSeed, 0, 1000);
    // Half the settlements take the whole book, and the others a fuzzed part of it.
    (uint256 _book,,) = _vault.periodBook(_settled + 1, false);
    uint256 _limit = _limitSeed % 2 == 0 ? type(uint256).max : bound(_limitSeed, 0, _book);
    _asset.mint(_cash, _vault.balanceOf(address(_vault)) * 3 / 1e6 + 2000);
    vm.prank(_settler);
    _vault.settlePeriod(_nav, _fee, _cash, _cash, _limit);
    ++executed['settlePeriod'];
  }

  /// @dev Floor on shares: a partial claim that would round to zero shares is taken in full instead
  function claimDeposit(
    uint256 _seed,
    uint256 _assets
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.ClaimableDepositAssets);
    if (_max == 0 || _vault.maxMint(_actor) == 0) return;
    _assets = bound(_assets, 1, _max);
    if (_assets < _max && Math.mulDiv(_assets, _vault.maxMint(_actor), _max) == 0) _assets = _max;
    vm.prank(_actor);
    _vault.deposit(_assets, _actor, _actor);
    ++executed['claimDeposit'];
  }

  /// @dev Ceil on assets consumed; a mint never reverts for rounding
  function claimMint(
    uint256 _seed,
    uint256 _shares
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.ClaimableDepositShares);
    if (_max == 0) return;
    vm.prank(_actor);
    _vault.mint(bound(_shares, 1, _max), _actor, _actor);
    ++executed['claimMint'];
  }

  /// @dev Floor on assets: a partial claim that would round to zero assets is taken in full instead
  function claimRedeem(
    uint256 _seed,
    uint256 _shares
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.ClaimableRedeemShares);
    if (_max == 0 || _vault.maxWithdraw(_actor) == 0) return;
    _shares = bound(_shares, 1, _max);
    if (_shares < _max && Math.mulDiv(_shares, _vault.maxWithdraw(_actor), _max) == 0) _shares = _max;
    vm.prank(_actor);
    _vault.redeem(_shares, _actor, _actor);
    ++executed['claimRedeem'];
  }

  /// @dev Ceil on shares deducted; can leave assets claimable with zero shares, which the exact-clearing path pays out
  function claimWithdraw(
    uint256 _seed,
    uint256 _assets
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.ClaimableRedeemAssets);
    if (_max == 0) return;
    vm.prank(_actor);
    _vault.withdraw(bound(_assets, 1, _max), _actor, _actor);
    ++executed['claimWithdraw'];
  }

  /// @dev Taking requests back is rarer than the rest, or few would live to settle and be claimed
  function _skips(
    uint256 _seed
  ) internal pure returns (bool _skip) {
    _skip = _seed % 4 != 0;
  }

  function rejectDeposit(
    uint256 _seed
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.PendingDeposit);
    if (_max == 0 || _skips(_seed)) return;
    vm.prank(_rejecter(_actor, true));
    _vault.rejectDepositRequest(_actor);
    ++executed['rejectDeposit'];
  }

  function rejectRedeem(
    uint256 _seed
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.PendingRedeem);
    if (_max == 0 || _skips(_seed)) return;
    vm.prank(_rejecter(_actor, false));
    _vault.rejectRedeemRequest(_actor);
    ++executed['rejectRedeem'];
  }

  function recoverRedeem(
    uint256 _seed
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.PendingRedeem);
    if (_max == 0 || _skips(_seed)) return;
    vm.prank(_rejecter(_actor, false));
    _vault.recoverRedeemRequest(_actor, _actors[(_seed + 1) % 3]);
    ++executed['recoverRedeem'];
  }

  function recoverClaimable(
    uint256 _seed
  ) external {
    address _actor = _actors[_seed % 3];
    if (_skips(_seed)) return;
    if (_vault.maxDeposit(_actor) + _vault.maxMint(_actor) + _vault.maxRedeem(_actor) + _vault.maxWithdraw(_actor) == 0)
    {
      return;
    }
    _vault.recoverClaimable(_actor, _actors[(_seed + 1) % 3]);
    ++executed['recoverClaimable'];
  }

  /// @dev This handler is the agent; the settler rejects once the request's period has closed
  function _rejecter(
    address _controller,
    bool _isDeposit
  ) internal view returns (address _who) {
    (uint64 _open,,) = _vault.dealingState();
    _who = _joinedIn[_controller][_isDeposit] == _open ? address(this) : _settler;
  }

  /// @dev The first actor, scanning from `_seed`, with a non-zero amount of `_need`; (seed actor, 0) if none has any
  function _firstWith(
    uint256 _seed,
    Need _need
  ) internal view returns (address _actor, uint256 _amount) {
    for (uint256 _k; _k < 3; ++_k) {
      _actor = _actors[(_seed + _k) % 3];
      _amount = _amountOf(_actor, _need);
      if (_amount > 0) return (_actor, _amount);
    }
    _actor = _actors[_seed % 3];
  }

  function _amountOf(
    address _actor,
    Need _need
  ) internal view returns (uint256 _amount) {
    if (_need == Need.PendingDeposit) return _vault.pendingDepositRequest(0, _actor);
    if (_need == Need.ClaimableDepositAssets) return _vault.maxDeposit(_actor);
    if (_need == Need.ClaimableDepositShares) return _vault.maxMint(_actor);
    if (_need == Need.Shares) return _vault.balanceOf(_actor);
    if (_need == Need.PendingRedeem) return _vault.pendingRedeemRequest(0, _actor);
    if (_need == Need.ClaimableRedeemShares) return _vault.maxRedeem(_actor);
    return _vault.maxWithdraw(_actor);
  }
}

contract Gated7540VaultInvariantTest is Gated7540VaultUnitTest {
  Gated7540Handler internal _handler;

  function setUp() public override {
    super.setUp();
    _handler = new Gated7540Handler(_vault, _asset, _settler, _cash);
    bytes32 _agentRole = _vault.AGENT_ROLE(); // read first: an inline call would consume the prank
    vm.prank(_admin);
    _vault.grantRole(_agentRole, address(_handler));
    targetContract(address(_handler));
  }

  /// @dev The vault always holds pending deposits plus claimable redemption cash, whichever amounts have rolled, and a
  ///      claim cannot be short: rounding leaves the vault at most one unit per settled request
  function invariant_TheVaultCanPayEveryClaim() external view {
    address[3] memory _all = _handler.actors();
    uint256 _owed;
    for (uint256 _i; _i < 3; ++_i) {
      _owed += _vault.pendingDepositRequest(0, _all[_i]) + _vault.maxWithdraw(_all[_i]);
    }
    assertGe(_asset.balanceOf(address(_vault)), _owed);
  }

  /// @dev The vault's own share balance is exactly its unsettled redemption books. They hold every controller's pending
  ///      shares and, for each settlement that took part of a book, at most one unit per controller after the first that
  ///      nobody owns
  function invariant_EscrowMatchesPendingRedemptions() external view {
    address[3] memory _all = _handler.actors();
    uint256 _pending;
    for (uint256 _i; _i < 3; ++_i) {
      _pending += _vault.pendingRedeemRequest(0, _all[_i]);
    }
    (uint64 _open, uint64 _settled,) = _vault.dealingState();
    uint256 _books;
    for (uint256 _period = _settled + 1; _period <= _open; ++_period) {
      (uint256 _paid,,) = _vault.periodBook(_period, false);
      _books += _paid;
    }
    assertEq(_vault.balanceOf(address(_vault)), _books);
    assertLe(_pending, _books);
    assertLe(_books - _pending, 2 * uint256(_settled));
  }

  /// @dev Unclaimed shares cover what every controller is owed
  function invariant_UnclaimedSharesCoverEveryClaim() external view {
    address[3] memory _all = _handler.actors();
    uint256 _owed;
    for (uint256 _i; _i < 3; ++_i) {
      _owed += _vault.maxMint(_all[_i]);
    }
    (,, uint256 _unclaimed) = _vault.dealingState();
    assertGe(_unclaimed, _owed);
  }

  /// @dev Nothing is stranded: claimable assets are always fully withdrawable, and claimable shares always mintable
  function invariant_ClaimsCanAlwaysBeClearedInFull() external {
    address[3] memory _all = _handler.actors();
    for (uint256 _i; _i < 3; ++_i) {
      uint256 _snapshot = vm.snapshotState();
      uint256 _assets = _vault.maxWithdraw(_all[_i]);
      if (_assets > 0) {
        vm.prank(_all[_i]);
        _vault.withdraw(_assets, _all[_i], _all[_i]);
        assertEq(_vault.maxWithdraw(_all[_i]), 0, 'redemption cash fully cleared');
      }
      uint256 _shares = _vault.maxMint(_all[_i]);
      if (_shares > 0) {
        vm.prank(_all[_i]);
        _vault.mint(_shares, _all[_i], _all[_i]);
        assertEq(_vault.maxMint(_all[_i]), 0, 'deposit shares fully cleared');
      }
      vm.revertToState(_snapshot);
    }
  }

  /// @dev Non-vacuity, by family: every run must have settled periods with requests in them and claimed from them on both
  ///      sides, and taken requests back, including requests whose controller differs from the owner. The actions inside
  ///      a family are not each required: a rare one misses the odd run out of 256 by chance, not because the handler
  ///      regressed into no-ops
  function afterInvariant() external view {
    assertGt(_ran('requestDeposit') + _ran('requestDepositFor'), 0, 'deposit requests');
    assertGt(_ran('requestRedeem') + _ran('requestRedeemFor'), 0, 'redeem requests');
    assertGt(_ran('closePeriod'), 0, 'closes');
    assertGt(_ran('settlePeriod'), 0, 'settlements');
    assertGt(_ran('claimDeposit') + _ran('claimMint'), 0, 'deposit claims');
    assertGt(_ran('claimRedeem') + _ran('claimWithdraw'), 0, 'redeem claims');
    assertGt(_ran('rejectDeposit') + _ran('rejectRedeem') + _ran('recoverRedeem'), 0, 'requests taken back');
  }

  function _ran(
    bytes32 _action
  ) internal view returns (uint256 _count) {
    _count = _handler.executed(_action);
  }

  function invariant_SupplyIsHeldByActorsAndEscrow() external view {
    address[3] memory _all = _handler.actors();
    uint256 _sum = _vault.balanceOf(address(_vault));
    for (uint256 _i; _i < 3; ++_i) {
      _sum += _vault.balanceOf(_all[_i]);
    }
    assertEq(_sum, _vault.totalSupply());
  }
}

/// @dev Aderyn `contract-locks-ether` is a false positive for this implementation: no path accepts ETH
contract Gated7540VaultUnit_Ether is Gated7540VaultUnitTest {
  function test_WhenEtherIsSentPlainly_ItReverts() external {
    vm.deal(_alice, 1 ether);
    vm.prank(_alice);
    (bool _ok,) = address(_vault).call{value: 1}('');
    assertFalse(_ok);
    assertEq(address(_vault).balance, 0);
  }
}

/// @dev Aderyn `unused-state-variable` on the storage location is a false positive: it is read in assembly
contract Gated7540VaultUnit_Storage is Gated7540VaultUnitTest {
  function test_TheErc7201LocationHoldsTheVaultState() external view {
    bytes32 _location =
      keccak256(abi.encode(uint256(keccak256('gated.storage.Gated7540Vault')) - 1)) & ~bytes32(uint256(0xff));
    assertEq(_location, 0x2cc225a2bfbd5a47b58fbfec984f4f856b2fa5e8b68081e6d3300ec76f5f3900);
    assertEq(address(uint160(uint256(vm.load(address(_vault), _location)))), address(_asset), 'slot 0: asset');
  }
}

/// @notice The async vault with a minimum position (RD7). The eligibility probes must not read the minimum as a block, and
///         the escrow (the vault itself) is exempt, or a redeem request below the minimum could never be filed
contract Gated7540VaultIntegration_MinPosition is Gated7540VaultIntegrationTest {
  uint256 internal constant _MIN = 1000;

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
    _minRule.setMinPosition(address(_vault), _MIN * _PAR);
  }

  function _settledDeposit(
    uint256 _amount
  ) internal {
    vm.prank(_alice);
    _vault.requestDeposit(_amount, _alice, _alice);
    _settleAtPar();
  }

  /// @dev An empty controller cannot know how many shares a request will buy, so the request is not refused for size
  function test_WhenAMinimumIsSet_AFreshControllerCanRequestAndClaimTheMinimum() external {
    _enableMinPosition();
    _invest(_alice, _MIN);
    assertEq(_vault.balanceOf(_alice), _MIN * _PAR);
  }

  function test_WhenAMinimumIsSet_ClaimableAmountsOfAFreshControllerAreNotHidden() external {
    _enableMinPosition();
    _settledDeposit(_MIN);
    assertEq(_vault.maxDeposit(_alice), _MIN);
    assertEq(_vault.maxMint(_alice), _MIN * _PAR);
  }

  /// @dev A claim below the minimum is refused by the hook; the agent's enforcement mint is exempt and delivers it
  function test_WhenAClaimWouldLeaveDust_TheClaimRevertsAndTheAgentCanRecover() external {
    _enableMinPosition();
    _settledDeposit(_MIN - 1);
    uint256 _shares = (_MIN - 1) * _PAR;

    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_TransferRejected.selector, Reasons.BELOW_MIN_POSITION)
    );
    vm.prank(_alice);
    _vault.mint(_shares, _alice, _alice);
    assertEq(_vault.maxMint(_alice), _shares, 'the failed claim consumed nothing');

    vm.prank(_agent);
    _vault.recoverClaimable(_alice, _alice);
    assertEq(_vault.balanceOf(_alice), _shares);
  }

  function test_WhenARedeemRequestWouldLeaveDustWithTheController_ItIsRefused() external {
    _enableMinPosition();
    _invest(_alice, 2 * _MIN);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_TransferRejected.selector, Reasons.BELOW_MIN_POSITION)
    );
    vm.prank(_alice);
    _vault.requestRedeem((_MIN + 1) * _PAR, _alice, _alice);
  }

  /// @dev The escrow holds 1 share, below the minimum, and is exempt as the token itself; the settlement burns from it
  function test_WhenTheEscrowHoldsLessThanTheMinimum_TheRedeemLifecycleStillRuns() external {
    _enableMinPosition();
    _invest(_alice, 2 * _MIN);
    vm.prank(_alice);
    _vault.requestRedeem(_PAR, _alice, _alice);
    assertEq(_vault.balanceOf(address(_vault)), _PAR);

    _settleAtPar();
    vm.prank(_alice);
    _vault.redeem(_PAR, _alice, _alice);
    assertEq(_vault.balanceOf(address(_vault)), 0);
    assertEq(_vault.balanceOf(_alice), 2 * _MIN * _PAR - _PAR);
  }
}

/// @dev M-3: compliance holds after settlement. Claims re-run the controller's policy pre-flight, and the agent can
///      recover claimable balances to a verified account, even while paused or at a full cap
contract Gated7540VaultIntegration_Claimable is Gated7540VaultIntegrationTest {
  address internal _treasury = makeAddr('treasury');

  function _settledDeposit(
    address _account,
    uint256 _amount
  ) internal {
    vm.prank(_account);
    _vault.requestDeposit(_amount, _account, _account);
    _settleAtPar();
  }

  function _settledRedemption(
    address _account,
    uint256 _amount
  ) internal {
    _invest(_account, _amount);
    vm.prank(_account);
    _vault.requestRedeem(_amount * _PAR, _account, _account);
    _settleAtPar();
  }

  function test_WhenTheControllerIsDeVerifiedAfterADepositIsSettled_TheClaimIsRefused() external {
    _settledDeposit(_alice, 100);
    _identity.set(_alice, false);
    assertEq(_vault.maxDeposit(_alice) + _vault.maxMint(_alice), 0);
    bytes memory _refused = abi.encodeWithSelector(
      IGated7540Vault.Gated7540Vault_ControllerNotEligible.selector, Reasons.RECEIVER_NOT_VERIFIED
    );
    vm.startPrank(_alice);
    vm.expectRevert(_refused);
    _vault.deposit(100, _bob, _alice); // even to a verified receiver
    vm.expectRevert(_refused);
    _vault.mint(100, _bob, _alice);
    vm.stopPrank();
  }

  function test_WhenTheControllerIsDeVerifiedAfterARedemptionIsSettled_ThePayoutIsRefused() external {
    _settledRedemption(_alice, 100);
    _identity.set(_alice, false);
    assertEq(_vault.maxRedeem(_alice) + _vault.maxWithdraw(_alice), 0);
    bytes memory _refused = abi.encodeWithSelector(
      IGated7540Vault.Gated7540Vault_ControllerNotEligible.selector, Reasons.SENDER_NOT_VERIFIED
    );
    vm.startPrank(_alice);
    vm.expectRevert(_refused);
    _vault.redeem(100, _eve, _alice);
    vm.expectRevert(_refused);
    _vault.withdraw(100, _eve, _alice);
    vm.stopPrank();
  }

  /// @dev The payout probe is a zero-amount burn: a controller whose shares were all escrowed and burned still collects
  function test_WhenTheControllerHoldsNoShares_ThePayoutIsStillAllowed() external {
    _settledRedemption(_alice, 100);
    assertEq(_vault.balanceOf(_alice), 0);
    assertEq(_vault.maxRedeem(_alice), 100 * _PAR);
    uint256 _before = _asset.balanceOf(_alice);
    vm.prank(_alice);
    _vault.redeem(100 * _PAR, _alice, _alice);
    assertEq(_asset.balanceOf(_alice) - _before, 100);
  }

  /// @dev The payout probe includes lockups: an agent lockup on the controller holds the payout until it expires
  function test_WhenTheControllerIsLockedUp_ThePayoutWaitsForTheUnlock() external {
    _settledRedemption(_alice, 100);
    vm.prank(_agent);
    _restrictionRule.setLockup(address(_vault), _alice, block.timestamp + 1 days);
    assertEq(_vault.maxRedeem(_alice), 0);
    vm.expectRevert(
      abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ControllerNotEligible.selector, Reasons.LOCKED)
    );
    vm.prank(_alice);
    _vault.redeem(100 * _PAR, _alice, _alice);
    vm.warp(block.timestamp + 1 days);
    vm.prank(_alice);
    _vault.redeem(100 * _PAR, _alice, _alice);
  }

  function test_WhenAnAgentRecoversAClaimableRedemption_TheAssetsGoToTheRecoveryAccount() external {
    _settledRedemption(_alice, 100);
    _identity.set(_alice, false);
    _identity.set(_treasury, true);
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.ClaimableRecovered(_alice, _treasury, 100, 0, _agent);
    vm.prank(_agent);
    _vault.recoverClaimable(_alice, _treasury);
    assertEq(_asset.balanceOf(_treasury), 100);
    assertEq(_vault.claimableRedeemRequest(0, _alice), 0);
    assertEq(_asset.balanceOf(address(_vault)), 0, 'nothing left owed');
  }

  /// @dev The stranded case: the cap filled after settlement, so the controller's own claim fails; the agent delivers
  function test_WhenACapFilledAfterSettlement_TheAgentDeliversTheStrandedShares() external {
    _settledDeposit(_alice, 100);
    _invest(_bob, 10);
    _invest(_carol, 10); // cap 2 now full
    vm.expectRevert(
      abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ControllerNotEligible.selector, Reasons.MAX_HOLDERS)
    );
    vm.prank(_alice);
    _vault.mint(100 * _PAR, _alice, _alice);

    vm.expectEmit(address(_vault));
    emit IGated7540Vault.ClaimableRecovered(_alice, _alice, 0, 100 * _PAR, _agent);
    vm.prank(_agent);
    _vault.recoverClaimable(_alice, _alice);
    assertEq(_vault.balanceOf(_alice), 100 * _PAR);
    assertEq(_fund.holderCount(), 3, 'exempt from the cap, still counted');
    assertEq(_vault.claimableDepositRequest(0, _alice), 0);
  }

  function test_WhenPaused_RecoveryStillWorks() external {
    _settledDeposit(_alice, 100);
    _settledRedemption(_bob, 50);
    _identity.set(_treasury, true);
    vm.prank(_guardian);
    _vault.pause();
    vm.prank(_agent);
    _vault.recoverClaimable(_alice, _treasury);
    vm.prank(_agent);
    _vault.recoverClaimable(_bob, _treasury);
    assertEq(_vault.balanceOf(_treasury), 100 * _PAR);
    assertEq(_asset.balanceOf(_treasury), 50);
  }

  function test_WhenBothSidesAreClaimable_OneRecoveryClearsBoth() external {
    _settledRedemption(_alice, 40);
    _settledDeposit(_alice, 100);
    _identity.set(_treasury, true);
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.ClaimableRecovered(_alice, _treasury, 40, 100 * _PAR, _agent);
    vm.prank(_agent);
    _vault.recoverClaimable(_alice, _treasury);
    assertEq(_vault.claimableDepositRequest(0, _alice) + _vault.claimableRedeemRequest(0, _alice), 0);
  }

  function test_WhenTheRecoveryAccountIsUnverified_ItReverts() external {
    _settledRedemption(_alice, 100);
    vm.expectRevert(
      abi.encodeWithSelector(
        IGated7540Vault.Gated7540Vault_RecipientNotEligible.selector, Reasons.RECEIVER_NOT_VERIFIED
      )
    );
    vm.prank(_agent);
    _vault.recoverClaimable(_alice, _eve);
  }

  function test_WhenTheCallerIsNotTheAgent_ItReverts() external {
    _settledRedemption(_alice, 100);
    bytes32 _role = _vault.AGENT_ROLE();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _settler, _role));
    vm.prank(_settler);
    _vault.recoverClaimable(_alice, _bob);
  }

  function test_WhenNothingIsClaimable_ItReverts() external {
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingClaimable.selector);
    vm.prank(_agent);
    _vault.recoverClaimable(_alice, _bob);
  }

  function test_WhenTheRecoveryAccountIsZero_ItReverts() external {
    _settledRedemption(_alice, 100);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAddress.selector);
    vm.prank(_agent);
    _vault.recoverClaimable(_alice, address(0));
  }
}

/// @notice A vault proxy cannot be moved onto another template's implementation, attested or not
contract Gated7540VaultUnit_Template is Gated7540VaultUnitTest {
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
    assertEq(_vault.templateId(), keccak256('Gated7540Vault'));
  }

  function test_WhenUpgradedToTheTokenImplementation_ItIsRefused() external {
    address _impl = address(new IntentToken());
    _attestedImplementation(_impl);
    vm.expectRevert(
      abi.encodeWithSelector(
        ITemplated.Templated_WrongTemplate.selector, _impl, keccak256('Gated7540Vault'), keccak256('IntentToken')
      )
    );
    vm.prank(_admin);
    _vault.upgradeToAndCall(_impl, '');
  }

  function test_WhenUpgradedToTheOtherVaultImplementation_ItIsRefused() external {
    address _impl = address(new Gated4626Vault());
    _attestedImplementation(_impl);
    vm.expectRevert(
      abi.encodeWithSelector(
        ITemplated.Templated_WrongTemplate.selector, _impl, keccak256('Gated7540Vault'), keccak256('Gated4626Vault')
      )
    );
    vm.prank(_admin);
    _vault.upgradeToAndCall(_impl, '');
  }

  function test_WhenUpgradedToANewImplementationOfItself_ItUpgrades() external {
    address _impl = address(new Gated7540Vault());
    _attestedImplementation(_impl);
    vm.prank(_admin);
    _vault.upgradeToAndCall(_impl, '');
    assertEq(_vault.templateId(), keccak256('Gated7540Vault'));
  }
}
