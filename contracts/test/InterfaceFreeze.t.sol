// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IAdapter} from 'interfaces/IAdapter.sol';
import {ICallValidator} from 'interfaces/ICallValidator.sol';
import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {ICredentialRegistry} from 'interfaces/ICredentialRegistry.sol';
import {ICredentialRule} from 'interfaces/ICredentialRule.sol';
import {IDistributor} from 'interfaces/IDistributor.sol';
import {IDvPExecutor} from 'interfaces/IDvPExecutor.sol';
import {IERC20CallValidator} from 'interfaces/IERC20CallValidator.sol';
import {IERC3009} from 'interfaces/IERC3009.sol';
import {IERC4626Adapter} from 'interfaces/IERC4626Adapter.sol';
import {IERC7540Deposit} from 'interfaces/IERC7540Deposit.sol';
import {IERC7540Operator} from 'interfaces/IERC7540Operator.sol';
import {IERC7540Redeem} from 'interfaces/IERC7540Redeem.sol';
import {IERC7575} from 'interfaces/IERC7575.sol';
import {IERC7943Fungible} from 'interfaces/IERC7943Fungible.sol';
import {IFeeModel} from 'interfaces/IFeeModel.sol';
import {IFund} from 'interfaces/IFund.sol';
import {IFundHoldersRule} from 'interfaces/IFundHoldersRule.sol';
import {IGated4626Vault} from 'interfaces/IGated4626Vault.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {IGovernanceTimelock} from 'interfaces/IGovernanceTimelock.sol';
import {IGuardedAccount} from 'interfaces/IGuardedAccount.sol';
import {IHolderRestrictionRule} from 'interfaces/IHolderRestrictionRule.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IIntentExecutor} from 'interfaces/IIntentExecutor.sol';
import {IIntentExecutorBatch} from 'interfaces/IIntentExecutorBatch.sol';
import {IMinPositionRule} from 'interfaces/IMinPositionRule.sol';
import {INavDesk} from 'interfaces/INavDesk.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {IPortfolio} from 'interfaces/IPortfolio.sol';
import {IProxyDeployer} from 'interfaces/IProxyDeployer.sol';
import {ISettlementWindowRule} from 'interfaces/ISettlementWindowRule.sol';
import {ISignedEntry} from 'interfaces/ISignedEntry.sol';
import {ISupplyCapRule} from 'interfaces/ISupplyCapRule.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';
import {Quals} from 'interfaces/Quals.sol';

/**
 * @notice Freeze guard for `contracts/interfaces/` (CLAUDE.md rules 4 and 14). Interfaces were frozen on 2026-10-16.
 *         A failure here means the frozen ABI changed: revert the change, or get an explicit instruction and re-pin
 */
contract InterfaceFreezeTest is Test {
  /// @dev The portfolio lego, added on owner instruction (2026-10-30). `AttestKind` gained two values, appended so the
  ///      numbers already in use keep their meaning; a record written under one number must not read as another
  function test_WhenThePortfolioLegoCompiles_ItsIdsTopicsAndKindsArePinned() external pure {
    assertEq(type(IAdapter).interfaceId, bytes4(0x4ffb2bfe), 'IAdapter');
    assertEq(type(IERC4626Adapter).interfaceId, bytes4(0x3398a02a), 'IERC4626Adapter');
    // Re-pinned 2026-10-31 on owner instruction: `allocate` takes the least it may add.
    assertEq(type(IPortfolio).interfaceId, bytes4(0x61d1b676), 'IPortfolio');

    assertEq(IPortfolio.AdapterAdded.selector, 0x9537fb53b49c6ea87760a6c4ea4ce6599f9e1785fcde3ff4f15211b1a4614681);
    assertEq(IPortfolio.AdapterRemoved.selector, 0xdf980d21d8c7bb34800e668dbe003299093bac8e693614151d3c57f73f98a93d);
    assertEq(IPortfolio.AdapterWrittenOff.selector, 0xe27ee757ca32ebdf0e08bbbaa45aaf138381e27c392d6af3329c73ae62ae3655);
    assertEq(IPortfolio.Allocated.selector, 0x9af9811abc6f1b9cf2234f8ed76daa9a577d4ffbbe0af66ec4b748cde6f4c39f);
    assertEq(IPortfolio.CapsSet.selector, 0x81a8f97824c3f9462a46c6e730749c119a5bac832940db5e6a9b64380f38e8c8);
    assertEq(IPortfolio.Deallocated.selector, 0x931c6bc7a1a0f8481f36670fac9821728b3288a15385b293eada3cb081e75245);
    assertEq(
      IPortfolio.LiquidityAdapterSet.selector, 0x2f142f81afc2d991c70116388a8896ce09113d194ab05771f16818eeefa79205
    );
    assertEq(IPortfolio.Migrated.selector, 0x8b80bd19aea7b735bc6d75db8d6adbe18b28c30d62b3555245eb67b2340caedc);

    assertEq(uint8(IPolicyRegistry.AttestKind.NONE), 0);
    assertEq(uint8(IPolicyRegistry.AttestKind.HOOK), 1);
    assertEq(uint8(IPolicyRegistry.AttestKind.RULE), 2);
    assertEq(uint8(IPolicyRegistry.AttestKind.IMPLEMENTATION), 3);
    assertEq(uint8(IPolicyRegistry.AttestKind.PORTFOLIO), 4);
    assertEq(uint8(IPolicyRegistry.AttestKind.ADAPTER), 5);
    assertEq(uint8(IPolicyRegistry.AttestKind.VALIDATOR), 6);
    assertEq(uint8(IPolicyRegistry.AttestKind.FEE_MODEL), 7);
  }

  function test_WhenInterfacesCompile_TheirErc165IdsArePinned() external pure {
    // Re-pinned in S2 of the review items (2026-10-24) on owner instruction (RD3): `IPolicyGated` inherits the ERC-7943
    // Final interface, so `forcedTransfer`, `setFrozenTokens`, `getFrozenTokens`, `canSend`, `canReceive` and the
    // boolean `canTransfer` live in `IERC7943Fungible`. What is left in `IPolicyGated` is mint, burn, pause, unpause,
    // setPolicyHook, canTransferWithReason, policyHook and registry (was 0xf517b40d; `setFrozen`, `getFrozen`,
    // `isUserAllowed` and the tuple `canTransfer` are gone)
    assertEq(type(IPolicyGated).interfaceId, bytes4(0x02331726), 'IPolicyGated');
    // Re-pinned in S1 of the review items (2026-10-24) on owner instruction (RD1 to RD3): `TransferContext` lost `ref` and
    // `deadline`, `IPolicyHook` and `IComplianceRule` gained `checkSend` and `checkReceive`, and `IComplianceHook` became
    // the shared hook (per-token `setRules`, `rules` and `ruleCount`; no `ADMIN` or `TOKEN`). Ids computed from the
    // compiled interfaces' signatures with `cast sig` (were 0xb7723023, 0x93d5c2be and 0x2604e338)
    assertEq(type(IPolicyHook).interfaceId, bytes4(0x4f7b9fbb), 'IPolicyHook');
    assertEq(type(IComplianceRule).interfaceId, bytes4(0x837a7ec1), 'IComplianceRule');
    assertEq(type(IComplianceHook).interfaceId, bytes4(0xa8f3d563), 'IComplianceHook');
    assertEq(type(IPolicyRegistry).interfaceId, bytes4(0x947f9fc8), 'IPolicyRegistry');
    // Re-pinned 2026-10-23 on owner instruction (intent revision I-1): `TransferIntent` gained executor, validAfter,
    // considerationToken and considerationAmount, and `canExecute` takes the signature. Ids computed from the
    // signatures with `cast sig` (was 0x7a2b1b79, 0xd2319653 and 0x117727cb)
    // Re-pinned 2026-10-31 on owner instruction: `canExecute` takes the executor.
    assertEq(type(ITransferIntent).interfaceId, bytes4(0xf81fba59), 'ITransferIntent');
    assertEq(type(IIntentExecutor).interfaceId, bytes4(0x4e8890b4), 'IIntentExecutor');
    // Added in Phase 3 (2026-10-16): executeBatch, pause, unpause
    assertEq(type(IIntentExecutorBatch).interfaceId, bytes4(0x58c0d550), 'IIntentExecutorBatch');
    // Added in Phase 4 (2026-10-16)
    assertEq(type(ISettlementWindowRule).interfaceId, bytes4(0xf2058aff), 'ISettlementWindowRule');
    // Re-pinned in Phase 5b (2026-10-17) on owner instruction R1: setExemptHolder / isExemptHolder added (was 0xa13cb93c)
    // Re-pinned 2026-10-22 on owner instruction: seedHolderCountFromHolders / seedHolderCountFromRule added (was
    // 0x0e091382)
    // Added in Phase 5a (2026-10-17)
    // Re-pinned in S1 of the review items (2026-10-24): `initialize` takes the token's initial rules (was 0xb008690c)
    // Re-pinned 2026-11-01 on owner instruction: the portfolio plug.
    assertEq(type(IGated4626Vault).interfaceId, bytes4(0x56f3979a), 'IGated4626Vault');
    // Added in Phase 5b (2026-10-17). The four ERC-7540 / ERC-7575 ids are the standard's own values.
    assertEq(type(IERC7540Operator).interfaceId, bytes4(0xe3bc4e65), 'IERC7540Operator');
    assertEq(type(IERC7540Deposit).interfaceId, bytes4(0xce3bbe50), 'IERC7540Deposit');
    assertEq(type(IERC7540Redeem).interfaceId, bytes4(0x620ee8e4), 'IERC7540Redeem');
    assertEq(type(IERC7575).interfaceId, bytes4(0x2f0a18c5), 'IERC7575');
    // Re-pinned 2026-10-17 on owner instruction: recoverRedeemRequest added (was 0x34aae296)
    // Re-pinned in v0.2.0 (2026-10-17): recoverClaimable added, the one post-freeze change (owner decision M-3)
    // Re-pinned in S1 of the review items (2026-10-24): `initialize` takes the token's initial rules (was 0x75f5b0db)
    // Re-pinned 2026-10-31 on owner instruction: dealing periods replace per-investor fulfilment.
    // Re-pinned 2026-11-02 on owner instruction: `SETTLEMENT_LOGIC` added (was 0xc6a5eee9), then the redemption gate:
    // `settlePeriod` takes a limit and `periodBook` added (was 0xa17876dd)
    assertEq(type(IGated7540Vault).interfaceId, bytes4(0xa61d9790), 'IGated7540Vault');
    // Re-pinned 2026-11-02 on owner instruction: the redemption gate, which adds a field to the struct `hashOf` takes
    // (was 0x6d2f4b62)
    assertEq(type(INavDesk).interfaceId, bytes4(0xc98f37f8), 'INavDesk');
    assertEq(type(ISignedEntry).interfaceId, bytes4(0x05cc4f78), 'ISignedEntry');
    assertEq(type(ISupplyCapRule).interfaceId, bytes4(0x52c89ff1), 'ISupplyCapRule');
    assertEq(type(IDistributor).interfaceId, bytes4(0xd75218de), 'IDistributor');
    assertEq(type(IGuardedAccount).interfaceId, bytes4(0x30444861), 'IGuardedAccount');
    assertEq(type(ICallValidator).interfaceId, bytes4(0x9e8d53da), 'ICallValidator');
    assertEq(type(IERC20CallValidator).interfaceId, bytes4(0x4095b410), 'IERC20CallValidator');
    assertEq(type(IFeeModel).interfaceId, bytes4(0xb7b102a7), 'IFeeModel');
    assertEq(type(IIdentityRegistry).interfaceId, bytes4(0xb9209e33), 'IIdentityRegistry');
    // Added in Phase 7 (2026-10-17), after ProxyDeployer moved to OZ Ownable
    // Re-pinned in S1 of the review items (2026-10-24): `deploy` takes and checks the expected rules (was 0x886d8cd8)
    // Re-pinned 2026-10-27 on owner instruction (PLAN.md, D1): `REGISTRY` added, so `deploy` can check the first
    // implementation (was 0xcedb15bb). Computed from the signatures with `cast sig`: 0xcedb15bb ^ 0x06433b1b
    assertEq(type(IProxyDeployer).interfaceId, bytes4(0xc8982ea0), 'IProxyDeployer');
    // Added in v0.2.0 (owner decision M-1)
    assertEq(type(IGovernanceTimelock).interfaceId, bytes4(0x31993a1c), 'IGovernanceTimelock');
    // Added in the fund layer (2026-10-22), ids computed from the signatures with `cast sig`
    // Re-pinned in S4 of the review items (2026-10-24): `isClassIntact` and `firstBrokenClass` (was 0x44c4a64f)
    assertEq(type(IFund).interfaceId, bytes4(0x2d89d7d8), 'IFund');
    assertEq(type(IFundHoldersRule).interfaceId, bytes4(0x5c275a39), 'IFundHoldersRule');
    // Added in the DvP executor (E-1, 2026-10-23), ids computed from the signatures with `cast sig`. `IERC3009` is the
    // subset of ERC-3009 that the executor calls; its id is the XOR of those two selectors, not a standard id
    assertEq(type(IDvPExecutor).interfaceId, bytes4(0xe68774e8), 'IDvPExecutor');
    assertEq(type(IERC3009).interfaceId, bytes4(0x61fdaa61), 'IERC3009');
    // Added in S0 of the review items (2026-10-23), ids computed from the signatures with `cast sig`.
    // `IERC7943Fungible` is the Final text of ERC-7943, so its id is the standard's own value
    assertEq(type(IERC7943Fungible).interfaceId, bytes4(0x3edbb4c4), 'IERC7943Fungible');
    assertEq(type(ITemplated).interfaceId, bytes4(0x7aa77f29), 'ITemplated');
    assertEq(type(IHolderRestrictionRule).interfaceId, bytes4(0x3abb7c85), 'IHolderRestrictionRule');
    assertEq(type(IMinPositionRule).interfaceId, bytes4(0x44ac9195), 'IMinPositionRule');
    // Added in the credential layer (C-1, 2026-10-23), ids computed from the signatures with `cast sig`. The enum
    // `Status` is `uint8` in a signature and `Credential` a tuple
    // Re-pinned 2026-11-01 on owner instruction: a record no longer holds a country (was 0x4573f2ef).
    assertEq(type(ICredentialRegistry).interfaceId, bytes4(0xd224eb70), 'ICredentialRegistry');
    assertEq(type(ICredentialRule).interfaceId, bytes4(0x35778007), 'ICredentialRule');
  }

  function test_WhenInterfacesCompile_TheirEventTopicsArePinned() external pure {
    // Changed in S2 of the review items (2026-10-24): the four-argument `ForcedTransfer` (topic 0x31a05a6a...) is gone,
    // replaced by the standard's three-argument one (pinned below) and `ForcedTransferBy`, which keeps the agent;
    // `Frozen` is the standard's, with the same topic as before
    assertEq(IPolicyGated.ForcedTransferBy.selector, 0x9820680c613c6b8b74bedc929c1ffd105ced2cf11b34457bb8b06bd8ecb15978);
    assertEq(
      IPolicyGated.PolicyHookChanged.selector, 0x964de01ec9270e869e61cc2efab9db5a19eac89859423a5963b19266cef000ca
    );
    assertEq(
      ITransferIntent.IntentExecuted.selector, 0xbfb47f4ecbd3340a56ddfb40a6e422e8805e7c3f5f2563dd89154d3da6c8aee8
    );
    // IntentCancelled(address indexed _from, bytes32 indexed _nonce)
    assertEq(
      ITransferIntent.IntentCancelled.selector, 0x0915fa0c02c377ca42f90c129fdec2942c2772fe5d673d334f6796f273de6632
    );
    assertEq(IPolicyRegistry.Attested.selector, 0xfbcfa3db039a6044e4cfd9df66c6bedbea51deda16f667d43fcb2ab26172743d);
    assertEq(
      IPolicyRegistry.AttestationRevoked.selector, 0x59d1b98a5da8bbc1db92f7d8d2e21c3067da65edbe08f4ae23df11487ee4c8b0
    );
    // Re-pinned in S1 of the review items (2026-10-24): the event names the token, `RuleSetChanged(address indexed,
    // bytes32[])` (was 0x1a22bda7b05ed1fb294fe52899bc63d685e2b75bb9f93e1e840f5016038b3893)
    assertEq(
      IComplianceHook.RuleSetChanged.selector, 0x052ffefccfad2a8a01111e4860d2a689b1f4b6e9d3a42f3d03311bbad21ed820
    );
    // Added in Phase 4 (2026-10-16)
    assertEq(
      ISettlementWindowRule.WindowSet.selector, 0xcfbaf2575cd70ccd40d11716312d33d4c45312c933586af58b3ccc959f81b96c
    );
    // Added in Phase 5b (2026-10-17)
    assertEq(IGated7540Vault.PeriodClosed.selector, 0x5263beccfd97c2947207bf7254d7c0c216431d4b9cea8c9b3371e8187020851b);
    assertEq(IGated7540Vault.PeriodSettled.selector, 0x39d3c67674d292704c2851b742b22a1b77d05815087d567f9f88db757d712cf3);
    assertEq(INavDesk.RedemptionGateSet.selector, 0xfc2be19943a0efc953aac14c4c78a12070a9462eedf09cc83e5ef03dc08dd9e1);
    assertEq(
      IGated4626Vault.DepositsClosed.selector, 0xf34c35fcda8d0564587a2d0e666df41b4133820a1793824d4668c285c18b4beb
    );
    assertEq(INavDesk.FeeModelSet.selector, 0x57e1682cf9947a26bcd0a26e75237738985e93b1cb7b5cff920f48b9e72b0eb7);
    assertEq(IGated4626Vault.Accrued.selector, 0xe0c50b11a6cc6d75470f28bd76d20c8d223c626324486a273eefadf6c6e973a7);
    assertEq(IGated4626Vault.FeeModelSet.selector, 0x57e1682cf9947a26bcd0a26e75237738985e93b1cb7b5cff920f48b9e72b0eb7);
    assertEq(IGated4626Vault.FeesCollected.selector, 0x9dc46f23cfb5ddcad0ae7ea2be38d47fec07bb9382ec7e564efc69e036dd66ce);
    assertEq(IGated4626Vault.MaxRateSet.selector, 0x08ee7b4c9309523d0db8e9554983c42a2b594b0a05a721d6237edb07bec7dab3);
    assertEq(IGated4626Vault.PortfolioSet.selector, 0x0d5636196773d6bc83dfcd7e1aadeb530723d82fce181c4a3680a0bcfe0b2f0f);
    assertEq(ISupplyCapRule.SupplyCapSet.selector, 0xf8ee54017f503850b1efbe5e44529540dc62ae2a9b329417770fb104e87dacaa);
    assertEq(
      IDistributor.DistributionApproved.selector, 0x0ddd602aa86fb0c636893a72925c2bab77936b913012a959b14d8ab202d6e3c5
    );
    assertEq(
      IDistributor.DistributionClaimed.selector, 0x64bdb55782b54d32d4886f2dc4f69cf7344fd99862caaa6703164c8fc13f2ea8
    );
    assertEq(
      IDistributor.DistributionProposed.selector, 0xdecb52003d63f8fec877496be8045b66e1945cc76a8fb743c948fe181ead3feb
    );
    assertEq(
      IDistributor.DistributionSwept.selector, 0x394babdfc435cd4ce1602316d1be5142c7f0880c34f5808b80c46111206c7106
    );
    assertEq(ISignedEntry.EntryCancelled.selector, 0x112e0bf83077a00b180a2c526e1e40fd2b7ce442cc2bfb9c6d3510870ddf0e96);
    assertEq(ISignedEntry.EntryExecuted.selector, 0xb98db96ae7f09fd2003f14676b3a4f20fb1592e2f5adb29d28d14c116a594be0);
    assertEq(IGuardedAccount.CallMade.selector, 0xf7069cb373783a30940dc185ef11ac49cdc063baa4035fbd6c914a9ab6975350);
    assertEq(
      IGuardedAccount.PermissionRevoked.selector, 0x9490008f9cc8bcb46b963024434fb1ff254b868936cc6c7614597b1b1a37c6a7
    );
    assertEq(IGuardedAccount.PermissionSet.selector, 0x0075380c8fcf1e82a38d57f9741e445075fd2eead9d6890b827c9a9935e8cbb3);
    assertEq(INavDesk.CutOff.selector, 0x3059172a9b0c574ae2c014e7ae803574138d1151319008a9d8712f37a87c375b);
    assertEq(INavDesk.DeskAdopted.selector, 0xa66dee6ab9d4713c6eda1dfbdfcaa28b4ca7a43d637d84a3310c088708ea6cbb);
    assertEq(INavDesk.ProposalAccepted.selector, 0x6931ab328a92d5384b647f50bea59bf9c0154a2c39315df2738ad91bb3c9d769);
    assertEq(INavDesk.ProposalCancelled.selector, 0x56a54393c88fb71d37dc109609d88e0b586637deb2452aef5f41d3eb32adedfc);
    assertEq(INavDesk.ProposalExecuted.selector, 0x120985525cfb78f6c03f96986f9687f49caf81e29350d21fa052e8c0df211ebb);
    assertEq(INavDesk.ProposalMade.selector, 0x5e920e4fe92ae146d56c6dc3288f9a03dc637430962df1f76ce9c61dc960af39);
    assertEq(INavDesk.RequestReleased.selector, 0x8200f2685c547311254dcb33469a4d5f90fe2a82745d94f07b09838b8e1cb112);
    assertEq(INavDesk.SettingsChanged.selector, 0x036001a16a233eae5020698275f1719506f862029418b8c2e7e8fd0c9fdee5e7);
    assertEq(
      IGated7540Vault.RedeemRequestRecovered.selector,
      0x274953cbe95d9877cd89aea6e3ca427fdd6170aeaa554aaea9ceceb36733cfd5
    );
    assertEq(
      IGated7540Vault.DepositRequestRejected.selector,
      0x62349aea2c873bb117c163dc27359603fe48b3c8e94fbb2acf192e0e6a300f38
    );
    assertEq(
      IGated7540Vault.RedeemRequestRejected.selector, 0x5e8a98909a36717c694a64574320783e7d08b72c502bc66cf1bb82c69b6614b8
    );
    assertEq(
      IERC7540Deposit.DepositRequest.selector, 0xbb58420bb8ce44e11b84e214cc0de10ce5e7c24d0355b2815c3d758b514cae72
    );
    assertEq(IERC7540Redeem.RedeemRequest.selector, 0x1fdc681a13d8c5da54e301c7ce6542dcde4581e4725043fdab2db12ddc574506);
    assertEq(IERC7540Operator.OperatorSet.selector, 0xceb576d9f15e4e200fdb5096d64d5dfd667e16def20c1eefd14256d8e3faa267);
    // Added in Phase 7 (2026-10-17): deployment tooling and the runbook decode it
    assertEq(IProxyDeployer.ProxyDeployed.selector, 0x389a3c9c5265cf3f40a0cf66a7bb66a57b95d2ba6a945110dd880a283b8c0704);
    // Added in v0.2.0 (owner decision M-3)
    assertEq(
      IGated7540Vault.ClaimableRecovered.selector, 0x0c540b8a1efd2cc0ebc90a5c128ab14cb8011c0c1021a7a9acfdffd478e42c04
    );
    // Added in the fund layer (2026-10-22), topics computed with `cast keccak`
    assertEq(IFund.ClassRegistered.selector, 0xf7aa1688f2f49ca390ca9db30a49ef1701d5823ad13c1d18946e798c371d82e9);
    assertEq(IFund.RuleSet.selector, 0xad94ea837b15ca544ad01b8e325c9c2ce361fdb551d2c8c6a23d652709f23017);
    assertEq(IFund.HolderCapSet.selector, 0xa18fd2e9ea8c6d87fce8efb5b336dbfb3af26ec55e3d02dd9bbb04274e4f8130);
    assertEq(IFund.ExemptSet.selector, 0xf33950bf7aa3300efb48f7896f309484c287418977abeba9f08f12cbe451d36a);
    assertEq(IFund.HolderCountUpdated.selector, 0x8ac0638de66e0910c02cbd2be8467a89277dac49177d5811c91422a8f475ba75);
    assertEq(IFund.HolderClassesUpdated.selector, 0x020767ac8d9f815f24bcaa5228933945b8766fe5dff7fe83d918163bcfd787fa);
    // Added in the DvP executor (E-1, 2026-10-23), topic computed with `cast keccak`
    assertEq(IDvPExecutor.DvPSettled.selector, 0xf86f6efd1a86b116715d573898aa1ed9745de3ea96e91eb7d0eb96b775182845);
    // Added in S0 of the review items (2026-10-23), topics computed with `cast keccak`. ERC-7943's `Frozen` has the
    // signature of ours, so its topic is the one pinned above; its three-argument `ForcedTransfer` is a new topic
    assertEq(IERC7943Fungible.Frozen.selector, 0x68e0d8c112165d0949ce87205b719ed7d98c7401866c34a159f7c67c6f5620e7);
    assertEq(
      IERC7943Fungible.ForcedTransfer.selector, 0x7b3ce50c216d2ccf9919c6b9f1bfb33f0350a33010f188750b4af38e00448138
    );
    assertEq(
      IHolderRestrictionRule.LockupSet.selector, 0xd3de67b8116f1abe42856d12f29c6dd6798dc57c837e1d2083e129b58d2e323a
    );
    assertEq(
      IHolderRestrictionRule.HolderFrozenSet.selector,
      0x833d9460c464a61e1259eee77549545d4e1483cf3d029bbdb8abcb44828d66ea
    );
    assertEq(
      IMinPositionRule.MinPositionSet.selector, 0x21af437ac0dfb7856224d1ee482b5a1a9955b346e2052abcc0da07d488917720
    );
    assertEq(
      IMinPositionRule.MinPositionExemptionSet.selector,
      0x938633e92689b6d84f33389b7d3f4f49175261a456e19fcbf4e423f8d095fc07
    );
    // Added in the credential layer (C-1, 2026-10-23), topics computed with `cast keccak`
    assertEq(
      ICredentialRegistry.CredentialSet.selector, 0x62696bfef46e93b00f133a80152dadf9f45c617aa5b847061be528b3e677b32a
    );
    assertEq(ICredentialRegistry.StatusSet.selector, 0xe07c9ed653206f6d019e37fbf43c2610409800ac75a0178854d7a6ec8974a61b);
    assertEq(
      ICredentialRegistry.SubjectBlocked.selector, 0xf8e7a7c3298f51e1686201ded81cdc69cde53159622a0620bc94c69bce4ab0b3
    );
    assertEq(
      ICredentialRegistry.SubjectUnblocked.selector, 0xe1ef50d52db3764eed26458645193b75dddc7c21fda345136344477e1ae7d4f0
    );
    assertEq(
      ICredentialRegistry.AttesterAdded.selector, 0x347cac8b384a3552298ea649f27dfef8faa49e42e44a90756c8963e71bdf9219
    );
    assertEq(
      ICredentialRegistry.AttesterAccountSet.selector,
      0x126a98f664550ef552f7d1ccb188e342eeef9d47571dc28fa7595bd48bd65517
    );
    assertEq(
      ICredentialRegistry.AttesterQualsSet.selector, 0x7c05a7be122c2ff08dcb7b70aacd1d79b8e6f0ca2edfd25ddcf1e4c288ed8034
    );
    assertEq(
      ICredentialRegistry.AttesterKilled.selector, 0xb7f7a33c95d88e6a5f56a073b3056f10e2eaa7be2b33945a03a9b4feec632ee4
    );
    assertEq(
      ICredentialRegistry.AttesterRevived.selector, 0xc7732850c902d4cc0faee5c1a6e5606c7a3c0151bd2f933b46ec7ebb9074a9df
    );
    assertEq(ICredentialRule.PolicySet.selector, 0xf9fded0e2c7053e53ea59d9519aeffbc2e928990390f779721d6484d985b503e);
  }

  function test_WhenReasonsCompile_TheirValuesArePinned() external pure {
    assertEq(Reasons.TRANSFER_OK, keccak256('TRANSFER_OK'));
    assertEq(Reasons.PAUSED, keccak256('PAUSED'));
    assertEq(Reasons.INSUFFICIENT_UNFROZEN, keccak256('INSUFFICIENT_UNFROZEN'));
    assertEq(Reasons.SENDER_NOT_VERIFIED, keccak256('SENDER_NOT_VERIFIED'));
    assertEq(Reasons.RECEIVER_NOT_VERIFIED, keccak256('RECEIVER_NOT_VERIFIED'));
    assertEq(Reasons.OUTSIDE_SETTLEMENT_WINDOW, keccak256('OUTSIDE_SETTLEMENT_WINDOW'));
    assertEq(Reasons.MAX_HOLDERS, keccak256('MAX_HOLDERS'));
    assertEq(Reasons.LOCKED, keccak256('LOCKED'));
    assertEq(Reasons.INTENT_EXPIRED, keccak256('INTENT_EXPIRED'));
    assertEq(Reasons.NONCE_USED, keccak256('NONCE_USED'));
    assertEq(Reasons.BAD_SIGNATURE, keccak256('BAD_SIGNATURE'));
    assertEq(Reasons.NO_HOOK, keccak256('NO_HOOK'));
    assertEq(Reasons.NO_RULES, keccak256('NO_RULES'));
    // Appended in the fund layer (2026-10-22)
    assertEq(Reasons.NOT_FUND_CLASS, keccak256('NOT_FUND_CLASS'));
    // Appended in the intent revision (2026-10-23)
    assertEq(Reasons.WRONG_EXECUTOR, keccak256('WRONG_EXECUTOR'));
    assertEq(Reasons.INTENT_NOT_YET_VALID, keccak256('INTENT_NOT_YET_VALID'));
    assertEq(Reasons.CONSIDERATION_NEEDS_EXECUTOR, keccak256('CONSIDERATION_NEEDS_EXECUTOR'));
    // Appended in the DvP executor (2026-10-23)
    assertEq(Reasons.LEGS_DO_NOT_MATCH, keccak256('LEGS_DO_NOT_MATCH'));
    // Appended in S0 of the review items (2026-10-23)
    assertEq(Reasons.BELOW_MIN_POSITION, keccak256('BELOW_MIN_POSITION'));
    assertEq(Reasons.SENDER_FROZEN, keccak256('SENDER_FROZEN'));
    assertEq(Reasons.RECEIVER_FROZEN, keccak256('RECEIVER_FROZEN'));
    // Appended in the credential layer (2026-10-23)
    assertEq(Reasons.CREDENTIAL_EXPIRED, keccak256('CREDENTIAL_EXPIRED'));
    assertEq(Reasons.RECEIVER_NOT_ELIGIBLE, keccak256('RECEIVER_NOT_ELIGIBLE'));
    assertEq(Reasons.NOT_EXECUTOR, keccak256('NOT_EXECUTOR'));
    assertEq(Reasons.ZERO_RECEIVER, keccak256('ZERO_RECEIVER'));
    assertEq(Reasons.ABOVE_SUPPLY_CAP, keccak256('ABOVE_SUPPLY_CAP'));
    assertEq(Reasons.TRANSFER_NOT_EXECUTED, keccak256('TRANSFER_NOT_EXECUTED'));
  }

  /// @dev The qualification bits are part of the frozen vocabulary: a record written under one meaning must never be read
  ///      under another. Bits 10 to 15 are reserved and 16 to 31 belong to a deployment
  function test_WhenQualsCompile_TheirBitsArePinned() external pure {
    assertEq(Quals.KYC, uint32(1));
    assertEq(Quals.PROFESSIONAL, uint32(2));
    assertEq(Quals.QUALIFIED, uint32(4));
    assertEq(Quals.INSTITUTIONAL, uint32(8));
    assertEq(Quals.FUND, uint32(16));
    assertEq(Quals.LICENSED, uint32(32));
    assertEq(Quals.CUSTOMER, uint32(64));
    assertEq(Quals.INFRA, uint32(128));
    assertEq(Quals.US_PERSON, uint32(256));
    assertEq(Quals.EEA, uint32(512));
  }
}
