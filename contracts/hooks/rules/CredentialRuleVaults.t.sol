// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC4626Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {Quals} from 'interfaces/Quals.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {CredentialRule} from 'contracts/hooks/rules/CredentialRule.sol';
import {CredentialRegistry} from 'contracts/identity/CredentialRegistry.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';
import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';

/// @notice The two vault templates behind a real `CredentialRule`. This test contract is the registry attester, the
///         council and the vault admin while it configures, as the deploy module is
abstract contract CredentialVaultsTest is Test {
  uint256 internal constant _NOW = 1_792_198_800; // Sat 2026-10-17 01:00 UTC

  PolicyRegistry internal _policyRegistry;
  CredentialRegistry internal _creds;
  CredentialRule internal _rule;
  MockAsset internal _asset;
  ProxyDeployer internal _deployer;
  address internal _guardian = makeAddr('guardian');
  address internal _agent = makeAddr('agent');
  address internal _settler = makeAddr('settler');
  address internal _cash = makeAddr('cash');
  address internal _alice = makeAddr('alice'); // credential valid for 30 days
  address internal _bob = makeAddr('bob');
  address internal _carol = makeAddr('carol'); // no professional qualification
  address internal _eve = makeAddr('eve'); // never credentialed

  function _base() internal {
    vm.warp(_NOW);
    _policyRegistry = new PolicyRegistry(address(this), address(this));
    _creds = new CredentialRegistry(address(this), _guardian);
    _creds.addAttester(address(this), type(uint32).max);
    _rule = new CredentialRule(_creds);
    _policyRegistry.attest(address(_rule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _asset = new MockAsset(6);
    _deployer = new ProxyDeployer(address(this), _policyRegistry);
  }

  function _hook() internal returns (ComplianceHook _h, IComplianceRule[] memory _rules) {
    _rules = new IComplianceRule[](1);
    _rules[0] = _rule;
    _h = new ComplianceHook(_policyRegistry);
    _policyRegistry.attest(address(_h).codehash, IPolicyRegistry.AttestKind.HOOK, '');
  }

  function _credential(
    address _who,
    uint32 _quals,
    uint256 _validFor
  ) internal {
    _creds.set(_who, uint64(block.timestamp + _validFor), _quals);
  }

  function _fund(
    address _vault,
    address[4] memory _accounts
  ) internal {
    for (uint256 _i; _i < 4; ++_i) {
      _asset.mint(_accounts[_i], 1e12);
      vm.prank(_accounts[_i]);
      _asset.approve(_vault, type(uint256).max);
    }
    _asset.mint(_cash, 1e12);
    vm.prank(_cash);
    _asset.approve(_vault, type(uint256).max);
  }

  function _rejected(
    bytes32 _reason
  ) internal pure returns (bytes memory _data) {
    _data = abi.encodeWithSelector(IPolicyGated.PolicyGated_TransferRejected.selector, _reason);
  }
}

contract CredentialRuleVaults_7540 is CredentialVaultsTest {
  Gated7540Vault internal _vault;

  function setUp() public {
    _base();
    Gated7540Vault _impl = new Gated7540Vault();
    (ComplianceHook _h, IComplianceRule[] memory _rules) = _hook();
    _policyRegistry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _vault = Gated7540Vault(
      address(
        _deployer.deploy(
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
              address(_policyRegistry),
              address(_h),
              _rules
            )
          ),
          address(_h),
          _rules
        )
      )
    );
    _vault.grantRole(_vault.SETTLER_ROLE(), _settler);
    _vault.grantRole(_vault.AGENT_ROLE(), _agent);
    _rule.setPolicy(address(_vault), Quals.KYC, 0, 0, 1);

    _credential(_alice, Quals.KYC | Quals.PROFESSIONAL, 30 days);
    _credential(_bob, Quals.KYC | Quals.PROFESSIONAL, 365 days);
    _credential(_carol, Quals.KYC, 365 days);
    _fund(address(_vault), [_alice, _bob, _carol, _eve]);
  }

  uint256 internal constant _PAR = 1e6;

  /// @dev Closes the open period and settles it at par
  function _settle() internal {
    (,, uint256 _unclaimed) = _vault.dealingState();
    uint256 _nav = (_vault.totalSupply() + _unclaimed) / _PAR;
    vm.startPrank(_settler);
    _vault.closePeriod();
    _vault.settlePeriod(_nav, 0, _cash, address(0));
    vm.stopPrank();
  }

  /// @dev Leaves `_account` with `_amount * _PAR` shares
  function _invest(
    address _account,
    uint256 _amount
  ) internal {
    vm.prank(_account);
    _vault.requestDeposit(_amount, _account, _account);
    _settle();
    vm.prank(_account);
    _vault.mint(_amount * _PAR, _account, _account);
  }

  function _redeemAll(
    address _account,
    uint256 _amount
  ) internal {
    vm.prank(_account);
    _vault.requestRedeem(_amount * _PAR, _account, _account);
    _settle();
  }

  function test_WhenTheControllerHasLapsed_ItCanStillClaimItsRedemptionPayout() external {
    _invest(_alice, 1000);
    _redeemAll(_alice, 1000);
    vm.warp(_NOW + 31 days);
    vm.prank(_alice);
    _vault.redeem(1000 * _PAR, _alice, _alice);
    assertEq(_asset.balanceOf(_alice), 1e12);
  }

  function test_WhenTheControllerHasLapsed_ItCanRequestARedemptionButNotADeposit() external {
    _invest(_alice, 1000);
    vm.warp(_NOW + 31 days);
    vm.prank(_alice);
    _vault.requestRedeem(400 * _PAR, _alice, _alice); // the exit path stays open

    vm.expectRevert(
      abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ControllerNotEligible.selector, Reasons.CREDENTIAL_EXPIRED)
    );
    vm.prank(_alice);
    _vault.requestDeposit(10, _alice, _alice);
  }

  function test_WhenASettledDepositIsClaimedAfterTheLapse_ItIsRefusedAndTheAgentRecoversIt() external {
    vm.prank(_alice);
    _vault.requestDeposit(1000, _alice, _alice);
    _settle();
    vm.warp(_NOW + 31 days);

    vm.expectRevert(
      abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ControllerNotEligible.selector, Reasons.CREDENTIAL_EXPIRED)
    );
    vm.prank(_alice);
    _vault.mint(1000, _alice, _alice);

    vm.prank(_agent);
    _vault.recoverClaimable(_alice, _bob); // an enforcement mint to an eligible account
    assertEq(_vault.balanceOf(_bob), 1000 * _PAR);
  }

  function test_WhenTheControllerHasLapsed_RejectingItsRedemptionRevertsAndTheAgentRecoversIt() external {
    _invest(_alice, 1000);
    vm.prank(_alice);
    _vault.requestRedeem(1000 * _PAR, _alice, _alice);
    vm.warp(_NOW + 31 days);

    vm.expectRevert(_rejected(Reasons.CREDENTIAL_EXPIRED));
    vm.prank(_agent);
    _vault.rejectRedeemRequest(_alice);

    vm.prank(_agent);
    _vault.recoverRedeemRequest(_alice, _bob);
    assertEq(_vault.balanceOf(_bob), 1000 * _PAR);
  }

  function test_WhenTheRecoveryAccountIsNotEligible_RecoveringClaimableAssetsIsRefused() external {
    _invest(_alice, 1000);
    _redeemAll(_alice, 1000);

    vm.expectRevert(
      abi.encodeWithSelector(
        IGated7540Vault.Gated7540Vault_RecipientNotEligible.selector, Reasons.RECEIVER_NOT_VERIFIED
      )
    );
    vm.prank(_agent);
    _vault.recoverClaimable(_alice, _eve);

    vm.prank(_agent);
    _vault.recoverClaimable(_alice, _bob);
    assertEq(_asset.balanceOf(_bob), 1e12 + 1000);
  }

  function test_WhenTheGuardianBlocksTheController_ItCannotCollectItsPayout() external {
    _invest(_alice, 1000);
    _redeemAll(_alice, 1000);
    vm.prank(_guardian);
    _creds.blockSubject(_alice);

    vm.expectRevert(
      abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ControllerNotEligible.selector, Reasons.SENDER_NOT_VERIFIED)
    );
    vm.prank(_alice);
    _vault.redeem(1000 * _PAR, _alice, _alice);
  }

  function test_WhenThePolicyNeedsAProfessional_ARetailControllerCannotInvestAndTheEscrowStillWorks() external {
    _rule.setPolicy(address(_vault), Quals.KYC, Quals.PROFESSIONAL, 0, 1);

    vm.expectRevert(
      abi.encodeWithSelector(
        IGated7540Vault.Gated7540Vault_ControllerNotEligible.selector, Reasons.RECEIVER_NOT_ELIGIBLE
      )
    );
    vm.prank(_carol);
    _vault.requestDeposit(10, _carol, _carol);

    _invest(_bob, 1000);
    _redeemAll(_bob, 1000); // the escrow holds the shares in between, as the token's own address
    vm.prank(_bob);
    _vault.redeem(1000 * _PAR, _bob, _bob);
    assertEq(_vault.totalSupply(), 0);
  }
}

contract CredentialRuleVaults_4626 is CredentialVaultsTest {
  Gated4626Vault internal _vault;

  function setUp() public {
    _base();
    Gated4626Vault _impl = new Gated4626Vault();
    (ComplianceHook _h, IComplianceRule[] memory _rules) = _hook();
    _policyRegistry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _vault = Gated4626Vault(
      address(
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
              address(_policyRegistry),
              address(_h),
              _rules
            )
          ),
          address(_h),
          _rules
        )
      )
    );
    _rule.setPolicy(address(_vault), Quals.KYC, 0, 0, 1);

    _credential(_alice, Quals.KYC | Quals.PROFESSIONAL, 30 days);
    _credential(_bob, Quals.KYC | Quals.PROFESSIONAL, 365 days);
    _credential(_carol, Quals.KYC, 365 days);
    _fund(address(_vault), [_alice, _bob, _carol, _eve]);
  }

  function test_WhenTheHolderHasLapsed_ItCanRedeemButNotDeposit() external {
    vm.prank(_alice);
    uint256 _shares = _vault.deposit(1e6, _alice);
    vm.warp(_NOW + 31 days);

    assertEq(_vault.maxDeposit(_alice), 0);
    assertEq(_vault.maxMint(_alice), 0);
    assertEq(_vault.maxRedeem(_alice), _shares);

    vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, _alice, 1, 0));
    vm.prank(_alice);
    _vault.deposit(1, _alice);

    vm.prank(_alice);
    _vault.redeem(_shares, _alice, _alice);
    assertEq(_vault.balanceOf(_alice), 0);
  }

  function test_WhenTheGuardianBlocksTheHolder_ItCanNeitherDepositNorRedeem() external {
    vm.prank(_alice);
    _vault.deposit(1e6, _alice);
    vm.prank(_guardian);
    _creds.blockSubject(_alice);
    assertEq(_vault.maxDeposit(_alice), 0);
    assertEq(_vault.maxRedeem(_alice), 0);
  }

  function test_WhenThePolicyNeedsAProfessional_ARetailReceiverHasNoMaxDeposit() external {
    _rule.setPolicy(address(_vault), Quals.KYC, Quals.PROFESSIONAL, 0, 1);
    assertEq(_vault.maxDeposit(_carol), 0);
    assertEq(_vault.maxDeposit(_bob), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, _carol, 1, 0));
    vm.prank(_carol);
    _vault.deposit(1, _carol);
  }
}
