// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {ICredentialRegistry} from 'interfaces/ICredentialRegistry.sol';
import {IGatedVaultBase} from 'interfaces/IGatedVaultBase.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {Quals} from 'interfaces/Quals.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {CredentialRule} from 'contracts/hooks/rules/CredentialRule.sol';
import {HolderRestrictionRule} from 'contracts/hooks/rules/HolderRestrictionRule.sol';
import {CredentialRegistry} from 'contracts/identity/CredentialRegistry.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {GatedToken} from 'contracts/tokens/GatedToken.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';
import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';

/// @notice Both vaults behind a real `CredentialRule` and `HolderRestrictionRule`. Neither vault has a credential of its
///         own, which is part of what these tests prove. This test contract is the attester and the vaults' admin
abstract contract GatedVaultBaseTest is Test {
  uint256 internal constant _NOW = 1_792_198_800;
  uint256 internal constant _AMOUNT = 1e6;

  PolicyRegistry internal _policyRegistry;
  CredentialRegistry internal _creds;
  CredentialRule internal _rule;
  HolderRestrictionRule internal _restrictions;
  ComplianceHook internal _hook;
  MockAsset internal _asset;
  ProxyDeployer internal _deployer;
  IComplianceRule[] internal _rules;

  address internal _guardian = makeAddr('guardian');
  address internal _agent = makeAddr('agent');
  address internal _settler = makeAddr('settler');
  address internal _cash = makeAddr('cash');
  address internal _alice = makeAddr('alice'); // valid for 30 days
  address internal _bob = makeAddr('bob'); // a credentialed third party
  address internal _eve = makeAddr('eve'); // never credentialed
  address internal _lapsing = makeAddr('lapsing'); // valid for one day

  function _deployBase() internal {
    vm.warp(_NOW);
    _policyRegistry = new PolicyRegistry(address(this), address(this));
    _creds = new CredentialRegistry(address(this), _guardian);
    _creds.addAttester(address(this), type(uint32).max);
    _rule = new CredentialRule(_creds);
    _restrictions = new HolderRestrictionRule();
    _policyRegistry.attest(address(_rule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _policyRegistry.attest(address(_restrictions).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _hook = new ComplianceHook(_policyRegistry);
    _policyRegistry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _rules.push(_rule);
    _rules.push(_restrictions);
    _asset = new MockAsset(6);
    _deployer = new ProxyDeployer(address(this), _policyRegistry);

    _credential(_alice, 30 days);
    _credential(_bob, 365 days);
    _credential(_lapsing, 1 days);
  }

  function _credential(
    address _who,
    uint256 _validFor
  ) internal {
    _creds.set(_who, uint64(block.timestamp + _validFor), Quals.KYC, 0);
  }

  function _fund(
    address _vault
  ) internal {
    address[5] memory _accounts = [_alice, _bob, _eve, _lapsing, _cash];
    for (uint256 _i; _i < 5; ++_i) {
      _asset.mint(_accounts[_i], 1e12);
      vm.prank(_accounts[_i]);
      _asset.approve(_vault, type(uint256).max);
    }
  }

  function _notEligible(
    address _account,
    bytes32 _reason
  ) internal pure returns (bytes memory _data) {
    _data = abi.encodeWithSelector(IGatedVaultBase.GatedVault_ThirdPartyNotEligible.selector, _account, _reason);
  }
}

contract GatedVaultBase_4626 is GatedVaultBaseTest {
  Gated4626Vault internal _vault;
  uint256 internal _shares;

  function setUp() public {
    _deployBase();
    Gated4626Vault _impl = new Gated4626Vault();
    _policyRegistry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
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
            address(_policyRegistry),
            address(_hook),
            _rules
          )
        ),
        address(_hook),
        _rules
      )
    );
    _rule.setPolicy(address(_vault), Quals.KYC, 0, 0, 1);
    _vault.grantRole(_vault.AGENT_ROLE(), _agent);
    _fund(address(_vault));
    vm.prank(_alice);
    _shares = _vault.deposit(_AMOUNT, _alice);
  }

  function test_AReceiverPayingForItselfIsNotAskedAboutAgain() external {
    vm.prank(_bob);
    assertGt(_vault.deposit(_AMOUNT, _bob), 0);
  }

  function test_WhenAnUncredentialedPayerDepositsForAClient_ItIsRefused() external {
    vm.expectRevert(_notEligible(_eve, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_eve);
    _vault.deposit(_AMOUNT, _alice);
  }

  function test_WhenAnUncredentialedPayerMintsForAClient_ItIsRefused() external {
    vm.expectRevert(_notEligible(_eve, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_eve);
    _vault.mint(1e12, _alice);
  }

  function test_WhenALapsedPayerDepositsForAClient_ItSaysItLapsed() external {
    vm.warp(_NOW + 2 days);
    vm.expectRevert(_notEligible(_lapsing, Reasons.CREDENTIAL_EXPIRED));
    vm.prank(_lapsing);
    _vault.deposit(_AMOUNT, _alice);
  }

  function test_WhenACredentialedCustodianPaysForAClient_TheClientGetsTheShares() external {
    uint256 _before = _vault.balanceOf(_alice);
    vm.prank(_bob);
    uint256 _bought = _vault.deposit(_AMOUNT, _alice);
    assertEq(_vault.balanceOf(_alice), _before + _bought);
    assertEq(_vault.balanceOf(_bob), 0);
  }

  function test_WhenARedemptionPaysAnUncredentialedThirdParty_ItIsRefused() external {
    vm.expectRevert(_notEligible(_eve, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_alice);
    _vault.redeem(_shares, _eve, _alice);
  }

  function test_WhenAWithdrawalPaysAnUncredentialedThirdParty_ItIsRefused() external {
    vm.expectRevert(_notEligible(_eve, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_alice);
    _vault.withdraw(1, _eve, _alice);
  }

  function test_WhenARedemptionPaysACredentialedThirdParty_ItIsPaid() external {
    uint256 _before = _asset.balanceOf(_bob);
    vm.prank(_alice);
    uint256 _paid = _vault.redeem(_shares, _bob, _alice);
    assertEq(_asset.balanceOf(_bob), _before + _paid);
  }

  function test_WhenARedemptionPaysAFrozenThirdParty_ItIsRefused() external {
    vm.prank(_agent);
    _restrictions.setFrozen(address(_vault), _bob, true);
    vm.expectRevert(_notEligible(_bob, Reasons.RECEIVER_FROZEN));
    vm.prank(_alice);
    _vault.redeem(_shares, _bob, _alice);
  }

  function test_WhenTheHolderHasLapsed_ItRedeemsToItselfAndNotToAStranger() external {
    vm.warp(_NOW + 31 days);
    vm.expectRevert(_notEligible(_eve, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_alice);
    _vault.redeem(_shares, _eve, _alice);

    vm.prank(_alice);
    assertGt(_vault.redeem(_shares, _alice, _alice), 0);
  }

  function test_WhenTheAttesterWasKilled_TheHolderStillRedeemsToItself() external {
    vm.prank(_guardian);
    _creds.killAttester(0);
    vm.prank(_alice);
    assertGt(_vault.redeem(_shares, _alice, _alice), 0);
  }

  function test_WhenASpenderRedeemsForTheOwner_TheCashGoesToTheOwnerUnjudged() external {
    vm.prank(_alice);
    _vault.approve(_eve, _shares);
    vm.warp(_NOW + 31 days);
    uint256 _before = _asset.balanceOf(_alice);
    vm.prank(_eve);
    uint256 _paid = _vault.redeem(_shares, _alice, _alice);
    assertEq(_asset.balanceOf(_alice), _before + _paid);
  }

  function test_IssuerMintAndBurnAreNotSupported() external {
    vm.expectRevert(IGatedVaultBase.GatedVault_Unsupported.selector);
    _vault.mint(_alice, 1);
    vm.expectRevert(IGatedVaultBase.GatedVault_Unsupported.selector);
    _vault.burn(_alice, 1);
  }

  function testFuzz_APayerOtherThanTheReceiverIsJudgedAndTheReceiverItselfIsNot(
    uint256 _assets,
    bool _credentialed
  ) external {
    _assets = bound(_assets, 1, 1e9);
    address _payer = makeAddr('payer');
    _asset.mint(_payer, _assets);
    vm.prank(_payer);
    _asset.approve(address(_vault), _assets);
    if (_credentialed) _credential(_payer, 1 days);
    if (!_credentialed) vm.expectRevert(_notEligible(_payer, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_payer);
    _vault.deposit(_assets, _alice);
  }
}

contract GatedVaultBase_7540 is GatedVaultBaseTest {
  uint256 internal constant _PAR = 1e6;
  uint256 internal constant _SHARES = _AMOUNT * _PAR;

  Gated7540Vault internal _vault;

  function setUp() public {
    _deployBase();
    Gated7540Vault _impl = new Gated7540Vault();
    _policyRegistry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _vault = Gated7540Vault(
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
            address(_hook),
            _rules
          )
        ),
        address(_hook),
        _rules
      )
    );
    _rule.setPolicy(address(_vault), Quals.KYC, 0, 0, 1);
    _vault.grantRole(_vault.AGENT_ROLE(), _agent);
    _vault.grantRole(_vault.SETTLER_ROLE(), _settler);
    _fund(address(_vault));
    _invest(_alice);
    _invest(_lapsing);
  }

  /// @dev Closes the open period and settles it at par: one asset unit buys `_PAR` shares
  function _settle() internal {
    (,, uint256 _unclaimed) = _vault.dealingState();
    uint256 _nav = (_vault.totalSupply() + _unclaimed) / _PAR;
    vm.startPrank(_settler);
    _vault.closePeriod();
    _vault.settlePeriod(_nav, 0, _cash, address(0), type(uint256).max);
    vm.stopPrank();
  }

  function _invest(
    address _who
  ) internal {
    vm.prank(_who);
    _vault.requestDeposit(_AMOUNT, _who, _who);
    _settle();
    vm.prank(_who);
    _vault.mint(_SHARES, _who, _who);
  }

  function _settledRedemption(
    address _who
  ) internal {
    vm.prank(_who);
    _vault.requestRedeem(_SHARES, _who, _who);
    _settle();
  }

  function test_AControllerPayingForItselfIsNotAskedAboutAgain() external {
    vm.prank(_bob);
    _vault.requestDeposit(_AMOUNT, _bob, _bob);
    assertEq(_vault.pendingDepositRequest(0, _bob), _AMOUNT);
  }

  function test_WhenAnUncredentialedPayerRequestsForAController_ItIsRefused() external {
    vm.expectRevert(_notEligible(_eve, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_eve);
    _vault.requestDeposit(_AMOUNT, _bob, _eve);
  }

  function test_WhenAnOperatorRequestsFromAnUncredentialedPayer_ItIsRefused() external {
    vm.prank(_eve);
    _vault.setOperator(_bob, true);
    vm.expectRevert(_notEligible(_eve, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_bob);
    _vault.requestDeposit(_AMOUNT, _bob, _eve);
  }

  function test_WhenACredentialedCustodianPaysForAController_TheRequestIsTheControllers() external {
    vm.prank(_bob);
    _vault.requestDeposit(_AMOUNT, _alice, _bob);
    assertEq(_vault.pendingDepositRequest(0, _alice), _AMOUNT);
    assertEq(_vault.pendingDepositRequest(0, _bob), 0);
  }

  function test_WhenARedemptionPaysAnUncredentialedThirdParty_ItIsRefused() external {
    _settledRedemption(_alice);
    vm.expectRevert(_notEligible(_eve, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_alice);
    _vault.redeem(_SHARES, _eve, _alice);
    vm.expectRevert(_notEligible(_eve, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_alice);
    _vault.withdraw(_AMOUNT, _eve, _alice);
  }

  function test_WhenARedemptionPaysACredentialedThirdParty_ItIsPaid() external {
    _settledRedemption(_alice);
    uint256 _before = _asset.balanceOf(_bob);
    vm.prank(_alice);
    _vault.redeem(_SHARES, _bob, _alice);
    assertEq(_asset.balanceOf(_bob), _before + _AMOUNT);
  }

  function test_WhenARedemptionPaysAFrozenThirdParty_ItIsRefused() external {
    _settledRedemption(_alice);
    vm.prank(_agent);
    _restrictions.setFrozen(address(_vault), _bob, true);
    vm.expectRevert(_notEligible(_bob, Reasons.RECEIVER_FROZEN));
    vm.prank(_alice);
    _vault.withdraw(_AMOUNT, _bob, _alice);
  }

  function test_WhenTheControllerHasLapsed_ItCollectsForItselfAndNotForAStranger() external {
    _settledRedemption(_lapsing);
    vm.warp(_NOW + 2 days);
    vm.expectRevert(_notEligible(_eve, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_lapsing);
    _vault.redeem(_SHARES, _eve, _lapsing);

    uint256 _before = _asset.balanceOf(_lapsing);
    vm.prank(_lapsing);
    _vault.redeem(_SHARES, _lapsing, _lapsing);
    assertEq(_asset.balanceOf(_lapsing), _before + _AMOUNT);
  }

  function test_WhenAHolderNamesALapsedController_TheRequestIsRefused() external {
    vm.warp(_NOW + 2 days);
    vm.expectRevert(_notEligible(_lapsing, Reasons.CREDENTIAL_EXPIRED));
    vm.prank(_alice);
    _vault.requestRedeem(_SHARES, _lapsing, _alice);
  }

  function test_WhenAHolderNamesAnUncredentialedController_TheRequestIsRefused() external {
    vm.expectRevert(_notEligible(_eve, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_alice);
    _vault.requestRedeem(_SHARES, _eve, _alice);
  }

  function test_WhenAHolderNamesACredentialedController_TheRequestIsTheControllers() external {
    vm.prank(_alice);
    _vault.requestRedeem(_SHARES, _bob, _alice);
    assertEq(_vault.pendingRedeemRequest(0, _bob), _SHARES);
  }

  function test_WhenAHolderHasLapsed_ItCanStillNameItselfAsController() external {
    vm.warp(_NOW + 2 days);
    vm.prank(_lapsing);
    _vault.requestRedeem(_SHARES, _lapsing, _lapsing);
    assertEq(_vault.pendingRedeemRequest(0, _lapsing), _SHARES);
  }

  function test_TheVaultNeedsNoCredentialToHoldItsEscrow() external view {
    // The record's standing, its qualifications and attester: only the standing matters here.
    // solhint-disable-next-line no-unused-vars
    (ICredentialRegistry.Status _status,,) = _creds.profileOf(address(_vault));
    assertEq(uint8(_status), uint8(ICredentialRegistry.Status.NONE));
    assertTrue(_vault.canReceive(address(_vault)));
    assertTrue(_vault.canSend(address(_vault)));
  }

  function test_WhenTheVaultIsBlocked_TheEscrowStillWorksEndToEnd() external {
    vm.prank(_guardian);
    _creds.blockSubject(address(_vault));
    _settledRedemption(_alice);
    vm.prank(_alice);
    _vault.redeem(_SHARES, _alice, _alice);
    assertEq(_vault.balanceOf(address(_vault)), 0);
  }

  function test_WhenTheVaultHasACredentialThatLapsed_TheEscrowAndARejectStillWork() external {
    _credential(address(_vault), 1 days);
    vm.warp(_NOW + 2 days);
    vm.prank(_alice);
    _vault.requestRedeem(_SHARES, _alice, _alice);
    vm.prank(_agent);
    _vault.rejectRedeemRequest(_alice);
    assertEq(_vault.balanceOf(_alice), _SHARES);
  }

  function test_WhenTheVaultItselfIsFrozen_TheEscrowStops() external {
    vm.prank(_agent);
    _restrictions.setFrozen(address(_vault), address(_vault), true);
    vm.expectRevert();
    vm.prank(_alice);
    _vault.requestRedeem(_SHARES, _alice, _alice);
  }

  function test_WhenSharesReachTheVaultByMistake_TheAgentForcesThemBack() external {
    vm.prank(_alice);
    _vault.transfer(address(_vault), _SHARES);
    assertEq(_vault.balanceOf(address(_vault)), _SHARES);
    vm.prank(_agent);
    _vault.forcedTransfer(address(_vault), _alice, _SHARES);
    assertEq(_vault.balanceOf(_alice), _SHARES);
  }

  function test_IssuerMintAndBurnAreNotSupported() external {
    vm.expectRevert(IGatedVaultBase.GatedVault_Unsupported.selector);
    _vault.mint(_alice, 1);
    vm.expectRevert(IGatedVaultBase.GatedVault_Unsupported.selector);
    _vault.burn(_alice, 1);
  }
}

contract GatedVaultBase_GatedAsset is GatedVaultBaseTest {
  GatedToken internal _gatedCash;
  Gated7540Vault internal _vault;

  function setUp() public {
    _deployBase();
    GatedToken _gatedCashImpl = new GatedToken();
    Gated7540Vault _impl = new Gated7540Vault();
    _policyRegistry.attest(address(_gatedCashImpl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _policyRegistry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _gatedCash = GatedToken(
      _deployer.deploy(
        'gUSD',
        address(_gatedCashImpl),
        abi.encodeCall(
          GatedToken.initialize,
          ('Gated USD', 'gUSD', 6, address(this), _guardian, address(_policyRegistry), address(_hook), _rules)
        ),
        address(_hook),
        _rules
      )
    );
    _rule.setPolicy(address(_gatedCash), Quals.KYC, 0, 0, 1);
    _gatedCash.grantRole(_gatedCash.MINTER_ROLE(), address(this));
    _vault = Gated7540Vault(
      _deployer.deploy(
        'gASYNC',
        address(_impl),
        abi.encodeCall(
          Gated7540Vault.initialize,
          (
            IERC20(address(_gatedCash)),
            'Gated Async Fund',
            'gASYNC',
            address(this),
            _guardian,
            address(_policyRegistry),
            address(_hook),
            _rules
          )
        ),
        address(_hook),
        _rules
      )
    );
    _rule.setPolicy(address(_vault), Quals.KYC, 0, 0, 1);
    _gatedCash.mint(_alice, _AMOUNT);
    vm.prank(_alice);
    _gatedCash.approve(address(_vault), _AMOUNT);
  }

  function test_WhenTheAssetIsGated_TheVaultIsAnOrdinaryHolderOfItAndNeedsACredential() external {
    vm.expectRevert();
    vm.prank(_alice);
    _vault.requestDeposit(_AMOUNT, _alice, _alice);

    _credential(address(_vault), 365 days);
    vm.prank(_alice);
    _vault.requestDeposit(_AMOUNT, _alice, _alice);
    assertEq(_gatedCash.balanceOf(address(_vault)), _AMOUNT);
  }
}
