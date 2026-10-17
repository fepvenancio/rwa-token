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
import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC7540Deposit} from 'interfaces/IERC7540Deposit.sol';
import {IERC7540Operator} from 'interfaces/IERC7540Operator.sol';
import {IERC7540Redeem} from 'interfaces/IERC7540Redeem.sol';
import {IERC7575} from 'interfaces/IERC7575.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {IdentityRule} from 'contracts/hooks/rules/IdentityRule.sol';
import {LockupRule} from 'contracts/hooks/rules/LockupRule.sol';
import {MaxHoldersRule} from 'contracts/hooks/rules/MaxHoldersRule.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {MockIdentityRegistry} from 'contracts/test/MockIdentityRegistry.sol';
import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';

contract Gated7540VaultUnitTest is Helpers {
  uint256 internal constant _FUNDS = 1e18;
  uint256 internal constant _ONE = 1e6; // 10**decimals(): asset 6, offset 0

  Gated7540Vault internal _vault;
  MockAsset internal _asset;
  address internal _registry;
  address internal _hook;
  address internal _admin = makeAddr('timelock');
  address internal _guardian = makeAddr('guardian');
  address internal _fulfiller = makeAddr('fulfiller');
  address internal _agent = makeAddr('agent');
  address internal _custody = makeAddr('custody');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');
  address internal _stranger = makeAddr('stranger');

  function setUp() public virtual {
    _asset = new MockAsset(6);
    _registry = _mockContract('registry');
    _hook = _mockContract('hook');
    vm.mockCall(
      _registry, abi.encodeCall(IPolicyRegistry.isAttested, (_hook, IPolicyRegistry.AttestKind.HOOK)), abi.encode(true)
    );
    _hookDecides(Reasons.TRANSFER_OK);
    vm.mockCall(_hook, abi.encodeCall(IPolicyHook.wantsAfter, ()), abi.encode(false));

    Gated7540Vault _impl = new Gated7540Vault();
    _vault = Gated7540Vault(
      address(
        new ERC1967Proxy(
          address(_impl),
          abi.encodeCall(
            Gated7540Vault.initialize,
            (IERC20(address(_asset)), 'Gated Async Fund', 'gASYNC', _admin, _guardian, _registry, _hook, _custody)
          )
        )
      )
    );
    vm.startPrank(_admin);
    _vault.grantRole(_vault.FULFILLER_ROLE(), _fulfiller);
    _vault.grantRole(_vault.AGENT_ROLE(), _agent);
    vm.stopPrank();

    _fund(_alice);
    _fund(_bob);
    _fund(_fulfiller);
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

  function _fulfillDeposit(
    address _controller,
    uint256 _assets,
    uint256 _shares
  ) internal {
    vm.prank(_fulfiller);
    _vault.fulfillDeposit(_controller, _assets, _shares);
  }

  /// @dev Full deposit lifecycle at a 1:1 price, leaving `_account` holding `_shares`
  function _holdShares(
    address _account,
    uint256 _shares
  ) internal {
    _requestDeposit(_account, _shares);
    _fulfillDeposit(_account, _shares, _shares);
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

  function _fulfillRedeem(
    address _controller,
    uint256 _shares,
    uint256 _assets
  ) internal {
    vm.prank(_fulfiller);
    _vault.fulfillRedeem(_controller, _shares, _assets);
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
      ref: bytes32(0),
      deadline: 0,
      extra: ''
    });
  }

  function _unauthorized(
    address _caller
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_Unauthorized.selector, _caller);
  }
}

contract Gated7540VaultUnit_Initialize is Gated7540VaultUnitTest {
  function test_WhenInitialized_ItWiresTheVault() external view {
    assertEq(_vault.asset(), address(_asset));
    assertEq(_vault.share(), address(_vault));
    assertEq(_vault.decimals(), 6);
    assertEq(_vault.custody(), _custody);
    assertEq(_vault.lastPrice(), _ONE);
    assertEq(_vault.policyHook(), _hook);
  }

  function test_WhenCalledTwice_ItReverts() external {
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    _vault.initialize(IERC20(address(_asset)), 'X', 'X', _admin, _guardian, _registry, _hook, _custody);
  }

  function test_WhenCustodyIsZero_ItReverts() external {
    Gated7540Vault _impl = new Gated7540Vault();
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAddress.selector);
    new ERC1967Proxy(
      address(_impl),
      abi.encodeCall(
        Gated7540Vault.initialize, (IERC20(address(_asset)), 'X', 'X', _admin, _guardian, _registry, _hook, address(0))
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
    vm.expectRevert(IGated7540Vault.Gated7540Vault_Unsupported.selector);
    vm.prank(_alice);
    _vault.mint(_bob, 1);
  }

  function test_WhenEvenABurnerBurns_ItReverts() external {
    bytes32 _burnerRole = _vault.BURNER_ROLE();
    vm.prank(_admin);
    _vault.grantRole(_burnerRole, _alice);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_Unsupported.selector);
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

contract Gated7540VaultUnit_FulfillDeposit is Gated7540VaultUnitTest {
  function test_WhenCallerIsNotTheFulfiller_ItReverts() external {
    _requestDeposit(_alice, 10);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, _stranger, _vault.FULFILLER_ROLE()
      )
    );
    vm.prank(_stranger);
    _vault.fulfillDeposit(_alice, 10, 10);
  }

  function test_WhenAnAmountIsZero_ItReverts() external {
    _requestDeposit(_alice, 10);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAmount.selector);
    _fulfillDeposit(_alice, 0, 10);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAmount.selector);
    _fulfillDeposit(_alice, 10, 0);
  }

  function test_WhenItExceedsThePending_ItReverts() external {
    _requestDeposit(_alice, 10);
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ExceedsPending.selector, 11, 10));
    _fulfillDeposit(_alice, 11, 11);
  }

  function test_WhenValid_ItSendsAssetsToCustodyRecordsThePriceAndEmits(
    uint256 _assets,
    uint256 _fulfilled,
    uint256 _shares
  ) external {
    _assets = bound(_assets, 1, _FUNDS);
    _fulfilled = bound(_fulfilled, 1, _assets);
    _shares = bound(_shares, 1, _FUNDS);
    _requestDeposit(_alice, _assets);
    uint256 _price = Math.mulDiv(_fulfilled, _ONE, _shares);

    vm.expectEmit(address(_vault));
    emit IGated7540Vault.Fulfilled(_alice, true, _price, _fulfilled, _shares, _fulfiller);
    _fulfillDeposit(_alice, _fulfilled, _shares);

    assertEq(_asset.balanceOf(_custody), _fulfilled);
    assertEq(_vault.pendingDepositRequest(0, _alice), _assets - _fulfilled);
    assertEq(_vault.claimableDepositRequest(0, _alice), _fulfilled);
    assertEq(_vault.maxMint(_alice), _shares);
    assertEq(_vault.lastPrice(), _price);
  }
}

contract Gated7540VaultUnit_ClaimDeposit is Gated7540VaultUnitTest {
  function test_WhenAStrangerClaims_ItReverts() external {
    _requestDeposit(_alice, 10);
    _fulfillDeposit(_alice, 10, 10);
    vm.expectRevert(_unauthorized(_stranger));
    vm.prank(_stranger);
    _vault.deposit(10, _stranger, _alice);
  }

  function test_WhenTheControllerClaimsEverything_ItMintsThroughTheHookAndClears(
    uint256 _assets,
    uint256 _shares
  ) external {
    _assets = bound(_assets, 1, _FUNDS);
    _shares = bound(_shares, 1, _FUNDS);
    _requestDeposit(_alice, _assets);
    _fulfillDeposit(_alice, _assets, _shares);

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
  }

  /// @dev A genuine split: the first step always yields at least one share, then the remainder clears exactly
  function test_WhenClaimedInTwoStepsByAssets_SharesNeverExceedTheFulfilment(
    uint256 _assets,
    uint256 _shares,
    uint256 _first
  ) external {
    _assets = bound(_assets, 2, _FUNDS);
    _shares = bound(_shares, 2, _FUNDS);
    // Smallest first step that floors to >= 1 share; <= _assets - 1 because _shares >= 2.
    _first = bound(_first, Math.ceilDiv(_assets, _shares), _assets - 1);
    _requestDeposit(_alice, _assets);
    _fulfillDeposit(_alice, _assets, _shares);

    vm.startPrank(_alice);
    uint256 _firstShares = _vault.deposit(_first, _alice, _alice);
    assertEq(_firstShares, Math.mulDiv(_first, _shares, _assets));
    assertGt(_firstShares, 0);
    uint256 _secondShares = _vault.deposit(_vault.maxDeposit(_alice), _alice, _alice);
    vm.stopPrank();

    assertEq(_firstShares + _secondShares, _shares, 'exactly the fulfilled shares');
    assertEq(_vault.balanceOf(_alice), _shares);
    assertEq(_vault.maxDeposit(_alice) + _vault.maxMint(_alice), 0, 'nothing stranded');
  }

  function test_WhenAPartialDepositRoundsToZeroShares_ItReverts() external {
    _requestDeposit(_alice, 10);
    _fulfillDeposit(_alice, 10, 1);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAmount.selector);
    vm.prank(_alice);
    _vault.deposit(9, _alice, _alice);
    assertEq(_vault.maxDeposit(_alice), 10, 'the failed claim consumed nothing');
  }

  function test_WhenMintingPartially_TheAssetsRoundUp(
    uint256 _assets,
    uint256 _shares,
    uint256 _first
  ) external {
    _assets = bound(_assets, 1, _FUNDS);
    _shares = bound(_shares, 2, _FUNDS);
    _first = bound(_first, 1, _shares - 1);
    _requestDeposit(_alice, _assets);
    _fulfillDeposit(_alice, _assets, _shares);

    uint256 _cost = Math.mulDiv(_first, _assets, _shares, Math.Rounding.Ceil);
    vm.startPrank(_alice);
    assertEq(_vault.mint(_first, _alice, _alice), _cost);
    assertEq(_vault.claimableDepositRequest(0, _alice), _assets - _cost);
    // The remainder clears exactly, even when the round-up left fewer assets than shares (or none).
    uint256 _secondCost = _vault.mint(_vault.maxMint(_alice), _alice, _alice);
    vm.stopPrank();

    assertEq(_cost + _secondCost, _assets, 'exactly the fulfilled assets');
    assertEq(_vault.balanceOf(_alice), _shares);
    assertEq(_vault.maxDeposit(_alice) + _vault.maxMint(_alice), 0, 'nothing stranded');
  }

  function test_WhenClaimingMoreThanClaimable_ItReverts() external {
    _requestDeposit(_alice, 10);
    _fulfillDeposit(_alice, 10, 20);
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ExceedsClaimable.selector, 11, 10));
    vm.prank(_alice);
    _vault.deposit(11, _alice, _alice);
  }

  function test_WhenUsingTheErc4626Signature_TheCallerIsTheController() external {
    _requestDeposit(_alice, 10);
    _fulfillDeposit(_alice, 10, 10);
    vm.prank(_alice);
    _vault.deposit(10, _alice);
    assertEq(_vault.balanceOf(_alice), 10);
  }

  function test_WhenAnOperatorClaims_ItSucceeds() external {
    _requestDeposit(_alice, 10);
    _fulfillDeposit(_alice, 10, 10);
    vm.prank(_alice);
    _vault.setOperator(_bob, true);
    vm.prank(_bob);
    _vault.mint(10, _bob, _alice);
    assertEq(_vault.balanceOf(_bob), 10);
  }
}

contract Gated7540VaultUnit_RequestRedeem is Gated7540VaultUnitTest {
  function test_WhenTheControllerIsZero_ItReverts() external {
    _holdShares(_alice, 100);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAddress.selector);
    vm.prank(_alice);
    _vault.requestRedeem(30, address(0), _alice);
    assertEq(_vault.balanceOf(_alice), 100);
  }

  function test_WhenTheOwnerRequests_TheSharesAreEscrowedThroughTheHookAsATransfer(
    uint256 _shares
  ) external {
    _holdShares(_alice, 100);
    _shares = bound(_shares, 1, 100);
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

contract Gated7540VaultUnit_FulfillAndClaimRedeem is Gated7540VaultUnitTest {
  function test_WhenFulfilled_ItBurnsTheEscrowPullsTheAssetsAndEmits(
    uint256 _shares,
    uint256 _assets
  ) external {
    _holdShares(_alice, 100);
    _shares = bound(_shares, 1, 100);
    _assets = bound(_assets, 1, _FUNDS);
    _requestRedeem(_alice, 100);
    uint256 _price = Math.mulDiv(_assets, _ONE, _shares);

    vm.expectCall(
      _hook,
      abi.encodeCall(
        IPolicyHook.beforeTransfer,
        (_ctx(IPolicyHook.TransferKind.BURN, address(_vault), address(0), _shares, _fulfiller))
      )
    );
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.Fulfilled(_alice, false, _price, _assets, _shares, _fulfiller);
    _fulfillRedeem(_alice, _shares, _assets);

    assertEq(_vault.balanceOf(address(_vault)), 100 - _shares);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 100 - _shares);
    assertEq(_vault.claimableRedeemRequest(0, _alice), _shares);
    assertEq(_vault.maxWithdraw(_alice), _assets);
  }

  function test_WhenItExceedsThePending_ItReverts() external {
    _holdShares(_alice, 10);
    _requestRedeem(_alice, 10);
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ExceedsPending.selector, 11, 10));
    _fulfillRedeem(_alice, 11, 11);
  }

  function test_WhenTheControllerRedeemsEverything_ItPaysAndClears(
    uint256 _assets
  ) external {
    _assets = bound(_assets, 1, _FUNDS);
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    _fulfillRedeem(_alice, 50, _assets);

    vm.expectEmit(address(_vault));
    emit IERC4626.Withdraw(_alice, _bob, _alice, _assets, 50);
    vm.prank(_alice);
    assertEq(_vault.redeem(50, _bob, _alice), _assets);
    assertEq(_asset.balanceOf(_bob), _FUNDS + _assets);
    assertEq(_vault.maxRedeem(_alice), 0);
    assertEq(_vault.maxWithdraw(_alice), 0);
  }

  /// @dev A genuine split: the first step always pays at least one asset, then the remainder clears exactly
  function test_WhenRedeemingPartially_TheAssetsRoundDown(
    uint256 _assets,
    uint256 _first
  ) external {
    // >= 2 assets for 50 shares is always splittable; 1 asset is the zero-rounding case tested separately.
    _assets = bound(_assets, 2, _FUNDS);
    // Smallest first step that floors to >= 1 asset (<= 25 here), kept below the full 50 shares.
    _first = bound(_first, Math.ceilDiv(50, _assets), 49);
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    _fulfillRedeem(_alice, 50, _assets);
    uint256 _before = _asset.balanceOf(_alice);

    vm.startPrank(_alice);
    uint256 _firstAssets = _vault.redeem(_first, _alice, _alice);
    assertEq(_firstAssets, Math.mulDiv(_first, _assets, 50));
    assertGt(_firstAssets, 0);
    uint256 _secondAssets = _vault.redeem(_vault.maxRedeem(_alice), _alice, _alice);
    vm.stopPrank();

    assertEq(_firstAssets + _secondAssets, _assets, 'exactly the fulfilled assets');
    assertEq(_asset.balanceOf(_alice) - _before, _assets);
    assertEq(_vault.maxRedeem(_alice) + _vault.maxWithdraw(_alice), 0, 'nothing stranded');
  }

  function test_WhenAPartialRedeemRoundsToZeroAssets_ItReverts() external {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    _fulfillRedeem(_alice, 50, 1);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAmount.selector);
    vm.prank(_alice);
    _vault.redeem(49, _alice, _alice);
    assertEq(_vault.maxRedeem(_alice), 50, 'the failed claim consumed nothing');
  }

  /// @dev Ceil on the shares deducted: a tiny withdrawal can never take assets for zero shares. The remainder then
  ///      clears exactly, including when the round-up consumed every share and only assets are left
  function test_WhenWithdrawingPartially_TheSharesRoundUp(
    uint256 _assets,
    uint256 _first
  ) external {
    _assets = bound(_assets, 2, _FUNDS);
    _first = bound(_first, 1, _assets - 1);
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    _fulfillRedeem(_alice, 50, _assets);
    uint256 _before = _asset.balanceOf(_alice);

    uint256 _burned = Math.mulDiv(_first, 50, _assets, Math.Rounding.Ceil);
    vm.startPrank(_alice);
    assertEq(_vault.withdraw(_first, _alice, _alice), _burned);
    assertGt(_burned, 0);
    assertEq(_vault.maxRedeem(_alice), 50 - _burned);
    uint256 _secondBurned = _vault.withdraw(_vault.maxWithdraw(_alice), _alice, _alice);
    vm.stopPrank();

    assertEq(_burned + _secondBurned, 50, 'exactly the fulfilled shares');
    assertEq(_asset.balanceOf(_alice) - _before, _assets, 'exactly the fulfilled assets');
    assertEq(_vault.maxRedeem(_alice) + _vault.maxWithdraw(_alice), 0, 'nothing stranded');
  }

  function test_WhenClaimsArePaused_MaxIsZeroAndClaimsRevert() external {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    _fulfillRedeem(_alice, 50, 50);
    vm.prank(_guardian);
    _vault.pause();
    assertEq(_vault.maxRedeem(_alice), 0);
    assertEq(_vault.maxWithdraw(_alice), 0);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vm.prank(_alice);
    _vault.redeem(50, _alice, _alice);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vm.prank(_alice);
    _vault.withdraw(50, _alice, _alice);
  }
}

contract Gated7540VaultUnit_TotalAssetsAndShortMint is Gated7540VaultUnitTest {
  /// @dev Indicative: the share supply valued at the last fulfilment price, rounded down
  function test_TotalAssetsIsTheSupplyAtTheLastPrice() external {
    assertEq(_vault.totalAssets(), 0);
    _requestDeposit(_alice, 300);
    _fulfillDeposit(_alice, 300, 200); // 1.5 assets per share
    vm.prank(_alice);
    _vault.deposit(300, _alice, _alice);
    assertEq(_vault.totalAssets(), Math.mulDiv(200, _vault.lastPrice(), _ONE));
    assertEq(_vault.totalAssets(), 300);
  }

  /// @dev The ERC-4626 two-argument `mint` claims for the caller as controller
  function test_WhenTheControllerMintsWithTwoArguments_ItClaimsItsOwnRequest() external {
    _requestDeposit(_alice, 100);
    _fulfillDeposit(_alice, 100, 40);
    vm.prank(_alice);
    assertEq(_vault.mint(40, _bob), 100);
    assertEq(_vault.balanceOf(_bob), 40);
    assertEq(_vault.maxMint(_alice), 0);
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ExceedsClaimable.selector, 1, 0));
    vm.prank(_bob);
    _vault.mint(1, _bob);
  }
}

/// @dev Every claim and every fulfiller action is gated; each check is pinned (mutation: removing any one fails here)
contract Gated7540VaultUnit_ClaimAccess is Gated7540VaultUnitTest {
  address internal _operator = makeAddr('operator');

  function _notAlice(
    address _caller
  ) internal view returns (address _someoneElse) {
    _someoneElse = _caller == _alice || _caller == _operator ? _stranger : _caller;
  }

  function _claimableRedemption() internal {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    _fulfillRedeem(_alice, 50, 50);
  }

  function _claimableDeposit() internal {
    _requestDeposit(_alice, 100);
    _fulfillDeposit(_alice, 100, 100);
  }

  function testFuzz_WhenSomeoneElseRedeemsTheControllersClaim_ItReverts(
    address _caller
  ) external {
    _caller = _notAlice(_caller);
    _claimableRedemption();
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_Unauthorized.selector, _caller));
    vm.prank(_caller);
    _vault.redeem(50, _caller, _alice);
  }

  function testFuzz_WhenSomeoneElseWithdrawsTheControllersClaim_ItReverts(
    address _caller
  ) external {
    _caller = _notAlice(_caller);
    _claimableRedemption();
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_Unauthorized.selector, _caller));
    vm.prank(_caller);
    _vault.withdraw(50, _caller, _alice);
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
    _claimableDeposit();
    _claimableRedemption();
    vm.startPrank(_operator);
    _vault.mint(40, _bob, _alice);
    _vault.deposit(_vault.maxDeposit(_alice), _bob, _alice);
    _vault.redeem(20, _bob, _alice);
    _vault.withdraw(_vault.maxWithdraw(_alice), _bob, _alice);
    vm.stopPrank();
    assertEq(_vault.maxMint(_alice) + _vault.maxRedeem(_alice) + _vault.maxWithdraw(_alice), 0);
  }

  function testFuzz_WhenSomeoneWithoutTheRoleFulfilsARedemption_ItReverts(
    address _caller
  ) external {
    bytes32 _role = _vault.FULFILLER_ROLE();
    if (_vault.hasRole(_role, _caller)) _caller = _stranger;
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role));
    vm.prank(_caller);
    _vault.fulfillRedeem(_alice, 50, 50);
  }

  function testFuzz_WhenSomeoneWithoutTheRoleRejectsARedemption_ItReverts(
    address _caller
  ) external {
    bytes32 _role = _vault.FULFILLER_ROLE();
    if (_vault.hasRole(_role, _caller)) _caller = _stranger;
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role));
    vm.prank(_caller);
    _vault.rejectRedeemRequest(_alice);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 50);
  }
}

contract Gated7540VaultUnit_Rejects is Gated7540VaultUnitTest {
  function test_WhenADepositIsRejected_TheAssetsReturnToTheController() external {
    vm.prank(_alice);
    _vault.requestDeposit(40, _bob, _alice);
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.DepositRequestRejected(_bob, 40);
    vm.prank(_fulfiller);
    _vault.rejectDepositRequest(_bob);
    assertEq(_asset.balanceOf(_bob), _FUNDS + 40);
    assertEq(_vault.pendingDepositRequest(0, _bob), 0);
  }

  function test_WhenARedemptionIsRejected_TheSharesReturnAsForcedAndItEmits() external {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 30);
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IPolicyHook.beforeTransfer, (_ctx(IPolicyHook.TransferKind.FORCED, address(_vault), _alice, 30, _fulfiller))
      )
    );
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.RedeemRequestRejected(_alice, 30);
    vm.prank(_fulfiller);
    _vault.rejectRedeemRequest(_alice);
    assertEq(_vault.balanceOf(_alice), 50);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);
  }

  function test_WhenPaused_ARedemptionRejectStillWorks() external {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 30);
    vm.prank(_guardian);
    _vault.pause();
    vm.prank(_fulfiller);
    _vault.rejectRedeemRequest(_alice);
    assertEq(_vault.balanceOf(_alice), 50);
  }

  function test_WhenNothingIsPending_RejectsRevert() external {
    vm.startPrank(_fulfiller);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _vault.rejectDepositRequest(_alice);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _vault.rejectRedeemRequest(_alice);
    vm.stopPrank();
  }

  function test_WhenCallerIsNotTheFulfiller_RejectsRevert() external {
    bytes32 _role = _vault.FULFILLER_ROLE();
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _stranger, _role));
    vm.prank(_stranger);
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
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _fulfiller, _role));
    vm.prank(_fulfiller);
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
    _shares = bound(_shares, 1, 100);
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

  function test_WhenRecovered_LaterFulfilsAndRejectsRevertWithNoRequest() external {
    _holdShares(_alice, 50);
    _requestRedeem(_alice, 50);
    _recover(_alice, _bob);
    vm.startPrank(_fulfiller);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _vault.fulfillRedeem(_alice, 50, 50);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _vault.rejectRedeemRequest(_alice);
    vm.stopPrank();
  }

  function test_WhenNothingIsPending_FulfilDepositRevertsWithNoRequest() external {
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _fulfillDeposit(_alice, 1, 1);
  }
}

contract Gated7540VaultUnit_ViewsAndAdmin is Gated7540VaultUnitTest {
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

  function test_WhenConverting_ItUsesTheLastFulfilmentPrice() external {
    assertEq(_vault.convertToShares(5 * _ONE), 5 * _ONE); // 1:1 before any fulfilment
    _requestDeposit(_alice, 300);
    _fulfillDeposit(_alice, 300, 100); // 3 assets per share
    assertEq(_vault.lastPrice(), 3 * _ONE);
    assertEq(_vault.convertToAssets(10), 30);
    assertEq(_vault.convertToShares(30), 10);
  }

  function test_WhenTheControllerIsIneligible_MaxDepositAndMaxMintAreZero() external {
    _requestDeposit(_alice, 10);
    _fulfillDeposit(_alice, 10, 10);
    _hookDecides(Reasons.RECEIVER_NOT_VERIFIED);
    assertEq(_vault.maxDeposit(_alice), 0);
    assertEq(_vault.maxMint(_alice), 0);
  }

  function test_WhenTheTimelockChangesCustody_ItEmits() external {
    address _next = makeAddr('nextCustody');
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.CustodyChanged(_custody, _next);
    vm.prank(_admin);
    _vault.setCustody(_next);
    assertEq(_vault.custody(), _next);
  }

  function test_WhenAnyoneElseChangesCustody_ItReverts() external {
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _fulfiller, bytes32(0))
    );
    vm.prank(_fulfiller);
    _vault.setCustody(makeAddr('x'));
  }

  function test_WhenCustodyIsSetToZero_ItReverts() external {
    vm.expectRevert(IGated7540Vault.Gated7540Vault_ZeroAddress.selector);
    vm.prank(_admin);
    _vault.setCustody(address(0));
  }
}

/// @notice Integration: the async vault behind a real ComplianceHook with Identity, Lockup and MaxHolders
contract Gated7540VaultIntegrationTest is Test {
  Gated7540Vault internal _vault;
  MockAsset internal _asset;
  MockIdentityRegistry internal _identity;
  LockupRule internal _lockupRule;
  MaxHoldersRule internal _maxHoldersRule;
  address internal _guardian = makeAddr('guardian');
  address internal _agent = makeAddr('agent');
  address internal _fulfiller = makeAddr('fulfiller');
  address internal _custody = makeAddr('custody');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');
  address internal _carol = makeAddr('carol');
  address internal _eve = makeAddr('eve'); // never verified

  function setUp() public {
    // Configure, then hand over: this test is the vault admin while it configures.
    PolicyRegistry _registry = new PolicyRegistry(address(this), address(this));
    _identity = new MockIdentityRegistry();
    IdentityRule _identityRule = new IdentityRule(IIdentityRegistry(address(_identity)));
    _lockupRule = new LockupRule();
    _maxHoldersRule = new MaxHoldersRule();
    _registry.attest(address(_identityRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_lockupRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_maxHoldersRule).codehash, IPolicyRegistry.AttestKind.RULE, '');

    _asset = new MockAsset(6);
    Gated7540Vault _impl = new Gated7540Vault();
    IComplianceRule[] memory _rules = new IComplianceRule[](3);
    _rules[0] = _identityRule;
    _rules[1] = _lockupRule;
    _rules[2] = _maxHoldersRule;
    // CREATE2 through ProxyDeployer, as in production: the address does not depend on this contract's nonce.
    ProxyDeployer _proxyDeployer = new ProxyDeployer(address(this));
    address _predictedProxy = _proxyDeployer.predict('gASYNC', address(_impl));
    ComplianceHook _hook = new ComplianceHook(address(this), _registry, _predictedProxy, _rules);
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
              _custody
            )
          ),
          address(_hook)
        )
      )
    );
    _vault.grantRole(_vault.FULFILLER_ROLE(), _fulfiller);
    _vault.grantRole(_vault.AGENT_ROLE(), _agent);
    // The escrow vault is a bank-controlled, verified, holder-exempt account (owner decisions V2 and R1).
    _identity.set(address(_vault), true);
    _maxHoldersRule.setExemptHolder(address(_vault), address(_vault), true);
    _maxHoldersRule.setCap(address(_vault), 2);

    _identity.set(_alice, true);
    _identity.set(_bob, true);
    _identity.set(_carol, true);
    address[5] memory _accounts = [_alice, _bob, _carol, _eve, _fulfiller];
    for (uint256 _i; _i < 5; ++_i) {
      _asset.mint(_accounts[_i], 1e12);
      vm.prank(_accounts[_i]);
      _asset.approve(address(_vault), type(uint256).max);
    }
  }

  function _invest(
    address _account,
    uint256 _amount
  ) internal {
    vm.prank(_account);
    _vault.requestDeposit(_amount, _account, _account);
    vm.prank(_fulfiller);
    _vault.fulfillDeposit(_account, _amount, _amount);
    vm.prank(_account);
    _vault.mint(_amount, _account, _account);
  }
}

contract Gated7540VaultIntegration_Lifecycle is Gated7540VaultIntegrationTest {
  function test_WhenAnInvestorRoundTrips_AssetsAndSharesSettle() external {
    _invest(_alice, 1000);
    assertEq(_vault.balanceOf(_alice), 1000);
    assertEq(_asset.balanceOf(_custody), 1000);
    assertEq(_maxHoldersRule.holderCount(address(_vault)), 1);

    vm.prank(_alice);
    _vault.requestRedeem(1000, _alice, _alice);
    assertEq(_maxHoldersRule.holderCount(address(_vault)), 0); // full escrow: alice left, the exempt vault never joined
    vm.prank(_fulfiller);
    _vault.fulfillRedeem(_alice, 1000, 1100); // NAV rose 10%
    assertEq(_vault.totalSupply(), 0);
    vm.prank(_alice);
    _vault.redeem(1000, _alice, _alice);
    assertEq(_asset.balanceOf(_alice), 1e12 - 1000 + 1100);
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
}

contract Gated7540VaultIntegration_Escrow is Gated7540VaultIntegrationTest {
  /// @dev Owner-specified (R1): cap full, the vault holds nothing, a partial redemption request still succeeds
  function test_WhenTheCapIsFullAndTheVaultIsEmpty_APartialRedeemRequestSucceeds() external {
    _invest(_alice, 100);
    _invest(_bob, 100);
    assertEq(_maxHoldersRule.holderCount(address(_vault)), 2); // cap reached
    assertEq(_vault.balanceOf(address(_vault)), 0);

    vm.prank(_alice);
    _vault.requestRedeem(40, _alice, _alice);
    assertEq(_vault.balanceOf(address(_vault)), 40);
    assertEq(_maxHoldersRule.holderCount(address(_vault)), 2);
  }

  /// @dev The escrow move is a TRANSFER, so a locked holder cannot exit by filing a request
  function test_WhenTheHolderIsLocked_ARedeemRequestIsRefused() external {
    _invest(_alice, 100);
    vm.prank(_agent);
    _lockupRule.setLockup(address(_vault), _alice, block.timestamp + 30 days);
    vm.expectRevert(abi.encodeWithSelector(IPolicyGated.PolicyGated_TransferRejected.selector, Reasons.LOCKED));
    vm.prank(_alice);
    _vault.requestRedeem(100, _alice, _alice);
  }

  function test_WhenSharesAreFrozen_TheyCannotBeEscrowed() external {
    _invest(_alice, 100);
    vm.prank(_agent);
    _vault.setFrozen(_alice, 100);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_TransferRejected.selector, Reasons.INSUFFICIENT_UNFROZEN)
    );
    vm.prank(_alice);
    _vault.requestRedeem(1, _alice, _alice);
  }

  /// @dev R2: returned as FORCED, so neither a full cap nor a pause blocks the unstick path
  function test_WhenRejectedAtAFullCapWhilePaused_TheSharesStillReturn() external {
    _invest(_alice, 100);
    vm.prank(_alice);
    _vault.requestRedeem(100, _alice, _alice); // alice leaves the count
    _invest(_bob, 100);
    _invest(_carol, 100); // the cap is full again without alice
    vm.prank(_guardian);
    _vault.pause();

    vm.prank(_fulfiller);
    _vault.rejectRedeemRequest(_alice);
    assertEq(_vault.balanceOf(_alice), 100);
    assertEq(_maxHoldersRule.holderCount(address(_vault)), 3); // FORCED is exempt from the cap but counted
  }

  /// @dev Owner-specified (R2): a de-verified controller's reject reverts and the shares stay escrowed
  function test_WhenTheControllerWasDeverified_TheRejectRevertsAndTheSharesStayEscrowed() external {
    _invest(_alice, 100);
    vm.prank(_alice);
    _vault.requestRedeem(60, _alice, _alice);
    _identity.set(_alice, false);

    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_TransferRejected.selector, Reasons.RECEIVER_NOT_VERIFIED)
    );
    vm.prank(_fulfiller);
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

    vm.prank(_fulfiller);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_TransferRejected.selector, Reasons.RECEIVER_NOT_VERIFIED)
    );
    _vault.rejectRedeemRequest(_alice);

    vm.prank(_agent);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_TransferRejected.selector, Reasons.RECEIVER_NOT_VERIFIED)
    );
    _vault.recoverRedeemRequest(_alice, _eve); // the recovery account must be verified too

    vm.prank(_agent);
    _vault.recoverRedeemRequest(_alice, _treasury);
    assertEq(_vault.balanceOf(_treasury), 60);
    assertEq(_vault.balanceOf(address(_vault)), 0);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);

    vm.startPrank(_fulfiller);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _vault.fulfillRedeem(_alice, 60, 60);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _vault.rejectRedeemRequest(_alice);
    vm.stopPrank();
  }
}

/// @notice Drives requests, fulfilments, claims and rejects across a few controllers
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
  address internal _fulfiller;
  address[3] internal _actors;

  /// @notice Ghost counters: how many times each action actually executed in the current run
  mapping(bytes32 _action => uint256 _count) public executed;

  constructor(
    Gated7540Vault _target,
    MockAsset _underlying,
    address _fulfillerRole
  ) {
    _vault = _target;
    _asset = _underlying;
    _fulfiller = _fulfillerRole;
    _actors = [makeAddr('actor0'), makeAddr('actor1'), makeAddr('actor2')];
    for (uint256 _i; _i < 3; ++_i) {
      vm.prank(_actors[_i]);
      _asset.approve(address(_vault), type(uint256).max);
    }
    vm.prank(_fulfiller);
    _asset.approve(address(_vault), type(uint256).max);
  }

  function actors() external view returns (address[3] memory _all) {
    _all = _actors;
  }

  function requestDeposit(
    uint256 _seed,
    uint256 _assets
  ) external {
    address _actor = _actors[_seed % 3];
    _assets = bound(_assets, 1, 1e15);
    _asset.mint(_actor, _assets);
    vm.prank(_actor);
    _vault.requestDeposit(_assets, _actor, _actor);
    ++executed['requestDeposit'];
  }

  /// @dev Controller differs from the owner: the owner pays, the next actor controls the claim
  function requestDepositFor(
    uint256 _seed,
    uint256 _assets
  ) external {
    address _owner = _actors[_seed % 3];
    address _controller = _actors[(_seed + 1) % 3];
    _assets = bound(_assets, 1, 1e15);
    _asset.mint(_owner, _assets);
    vm.prank(_owner);
    _vault.requestDeposit(_assets, _controller, _owner);
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
    vm.prank(_owner);
    _vault.requestRedeem(bound(_shares, 1, _max), _controller, _owner);
    ++executed['requestRedeemFor'];
  }

  function fulfillDeposit(
    uint256 _seed,
    uint256 _assets,
    uint256 _shares
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.PendingDeposit);
    if (_max == 0) return;
    vm.prank(_fulfiller);
    _vault.fulfillDeposit(_actor, bound(_assets, 1, _max), bound(_shares, 1, 1e15));
    ++executed['fulfillDeposit'];
  }

  /// @dev Floor on shares: a partial claim that would round to zero shares is taken in full instead
  function claimDeposit(
    uint256 _seed,
    uint256 _assets
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.ClaimableDepositAssets);
    if (_max == 0) return;
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

  function requestRedeem(
    uint256 _seed,
    uint256 _shares
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.Shares);
    if (_max == 0) return;
    vm.prank(_actor);
    _vault.requestRedeem(bound(_shares, 1, _max), _actor, _actor);
    ++executed['requestRedeem'];
  }

  function fulfillRedeem(
    uint256 _seed,
    uint256 _shares,
    uint256 _assets
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.PendingRedeem);
    if (_max == 0) return;
    _assets = bound(_assets, 1, 1e15);
    _asset.mint(_fulfiller, _assets);
    vm.prank(_fulfiller);
    _vault.fulfillRedeem(_actor, bound(_shares, 1, _max), _assets);
    ++executed['fulfillRedeem'];
  }

  /// @dev Floor on assets: a partial claim that would round to zero assets is taken in full instead
  function claimRedeem(
    uint256 _seed,
    uint256 _shares
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.ClaimableRedeemShares);
    if (_max == 0) return;
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

  function rejectDeposit(
    uint256 _seed
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.PendingDeposit);
    if (_max == 0) return;
    vm.prank(_fulfiller);
    _vault.rejectDepositRequest(_actor);
    ++executed['rejectDeposit'];
  }

  function rejectRedeem(
    uint256 _seed
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.PendingRedeem);
    if (_max == 0) return;
    vm.prank(_fulfiller);
    _vault.rejectRedeemRequest(_actor);
    ++executed['rejectRedeem'];
  }

  function recoverRedeem(
    uint256 _seed
  ) external {
    (address _actor, uint256 _max) = _firstWith(_seed, Need.PendingRedeem);
    if (_max == 0) return;
    _vault.recoverRedeemRequest(_actor, _actors[(_seed + 1) % 3]);
    ++executed['recoverRedeem'];
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
    _handler = new Gated7540Handler(_vault, _asset, _fulfiller);
    bytes32 _agentRole = _vault.AGENT_ROLE(); // read first: an inline call would consume the prank
    vm.prank(_admin);
    _vault.grantRole(_agentRole, address(_handler));
    targetContract(address(_handler));
  }

  /// @dev The vault holds exactly the pending deposit assets plus the claimable redemption assets
  function invariant_VaultAssetsMatchItsObligations() external view {
    address[3] memory _all = _handler.actors();
    uint256 _owed;
    for (uint256 _i; _i < 3; ++_i) {
      _owed += _vault.pendingDepositRequest(0, _all[_i]) + _vault.maxWithdraw(_all[_i]);
    }
    assertEq(_asset.balanceOf(address(_vault)), _owed);
  }

  /// @dev The vault's own share balance is exactly the escrowed pending redemptions
  function invariant_EscrowMatchesPendingRedemptions() external view {
    address[3] memory _all = _handler.actors();
    uint256 _pending;
    for (uint256 _i; _i < 3; ++_i) {
      _pending += _vault.pendingRedeemRequest(0, _all[_i]);
    }
    assertEq(_vault.balanceOf(address(_vault)), _pending);
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
        assertEq(_vault.maxWithdraw(_all[_i]) + _vault.maxRedeem(_all[_i]), 0, 'redemption fully cleared');
      }
      uint256 _shares = _vault.maxMint(_all[_i]);
      if (_shares > 0) {
        vm.prank(_all[_i]);
        _vault.mint(_shares, _all[_i], _all[_i]);
        assertEq(_vault.maxMint(_all[_i]) + _vault.maxDeposit(_all[_i]), 0, 'deposit fully cleared');
      }
      vm.revertToState(_snapshot);
    }
  }

  /// @dev Non-vacuity: every run must have executed every action at least once, so the invariants above are checked
  ///      against vaults that went through deposits, mint and withdraw claims, rejections and recoveries. Runs reach
  ///      400+ executed actions, so a missing action means the handler regressed into no-ops, not bad luck.
  ///      Includes requests whose controller differs from the owner.
  function afterInvariant() external view {
    string[13] memory _actions = [
      'requestDeposit',
      'requestDepositFor',
      'requestRedeemFor',
      'fulfillDeposit',
      'claimDeposit',
      'claimMint',
      'requestRedeem',
      'fulfillRedeem',
      'claimRedeem',
      'claimWithdraw',
      'rejectDeposit',
      'rejectRedeem',
      'recoverRedeem'
    ];
    for (uint256 _i; _i < _actions.length; ++_i) {
      assertGt(_handler.executed(bytes32(bytes(_actions[_i]))), 0, _actions[_i]);
    }
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
    assertEq(address(uint160(uint256(vm.load(address(_vault), _location)))), _custody, 'slot 0: custody');
    assertEq(uint256(vm.load(address(_vault), bytes32(uint256(_location) + 1))), _ONE, 'slot 1: lastPrice');
  }
}
