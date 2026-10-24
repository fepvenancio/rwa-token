// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IDvPExecutor} from 'interfaces/IDvPExecutor.sol';
import {IERC3009} from 'interfaces/IERC3009.sol';
import {IERC7540Deposit} from 'interfaces/IERC7540Deposit.sol';
import {IERC7540Operator} from 'interfaces/IERC7540Operator.sol';
import {IERC7540Redeem} from 'interfaces/IERC7540Redeem.sol';
import {IERC7575} from 'interfaces/IERC7575.sol';
import {IERC7943Fungible} from 'interfaces/IERC7943Fungible.sol';
import {IFund} from 'interfaces/IFund.sol';
import {IFundHoldersRule} from 'interfaces/IFundHoldersRule.sol';
import {IGated4626Vault} from 'interfaces/IGated4626Vault.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {IGovernanceTimelock} from 'interfaces/IGovernanceTimelock.sol';
import {IHolderRestrictionRule} from 'interfaces/IHolderRestrictionRule.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IIdentityRule} from 'interfaces/IIdentityRule.sol';
import {IIntentExecutor} from 'interfaces/IIntentExecutor.sol';
import {IIntentExecutorBatch} from 'interfaces/IIntentExecutorBatch.sol';
import {IMaxHoldersRule} from 'interfaces/IMaxHoldersRule.sol';
import {IMinPositionRule} from 'interfaces/IMinPositionRule.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {IProxyDeployer} from 'interfaces/IProxyDeployer.sol';
import {ISettlementWindowRule} from 'interfaces/ISettlementWindowRule.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

/**
 * @notice Freeze guard for `contracts/interfaces/` (CLAUDE.md rules 4 and 14). Interfaces were frozen on 2026-10-16.
 *         A failure here means the frozen ABI changed: revert the change, or get an explicit instruction and re-pin
 */
contract InterfaceFreezeTest is Test {
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
    assertEq(type(ITransferIntent).interfaceId, bytes4(0x51128254), 'ITransferIntent');
    assertEq(type(IIntentExecutor).interfaceId, bytes4(0x4e8890b4), 'IIntentExecutor');
    // Added in Phase 3 (2026-10-16): executeBatch, pause, unpause
    assertEq(type(IIntentExecutorBatch).interfaceId, bytes4(0x58c0d550), 'IIntentExecutorBatch');
    // Added in Phase 4 (2026-10-16)
    assertEq(type(ISettlementWindowRule).interfaceId, bytes4(0xf2058aff), 'ISettlementWindowRule');
    // Re-pinned in Phase 5b (2026-10-17) on owner instruction R1: setExemptHolder / isExemptHolder added (was 0xa13cb93c)
    // Re-pinned 2026-10-22 on owner instruction: seedHolderCountFromHolders / seedHolderCountFromRule added (was
    // 0x0e091382)
    assertEq(type(IMaxHoldersRule).interfaceId, bytes4(0x360b3dad), 'IMaxHoldersRule');
    // Added in Phase 5a (2026-10-17)
    // Re-pinned in S1 of the review items (2026-10-24): `initialize` takes the token's initial rules (was 0xb008690c)
    assertEq(type(IGated4626Vault).interfaceId, bytes4(0x6208cbc1), 'IGated4626Vault');
    // Added in Phase 5b (2026-10-17). The four ERC-7540 / ERC-7575 ids are the standard's own values.
    assertEq(type(IERC7540Operator).interfaceId, bytes4(0xe3bc4e65), 'IERC7540Operator');
    assertEq(type(IERC7540Deposit).interfaceId, bytes4(0xce3bbe50), 'IERC7540Deposit');
    assertEq(type(IERC7540Redeem).interfaceId, bytes4(0x620ee8e4), 'IERC7540Redeem');
    assertEq(type(IERC7575).interfaceId, bytes4(0x2f0a18c5), 'IERC7575');
    // Re-pinned 2026-10-17 on owner instruction: recoverRedeemRequest added (was 0x34aae296)
    // Re-pinned in v0.2.0 (2026-10-17): recoverClaimable added, the one post-freeze change (owner decision M-3)
    // Re-pinned in S1 of the review items (2026-10-24): `initialize` takes the token's initial rules (was 0x75f5b0db)
    assertEq(type(IGated7540Vault).interfaceId, bytes4(0x8f0b8793), 'IGated7540Vault');
    assertEq(type(IIdentityRule).interfaceId, bytes4(0x150c4aea), 'IIdentityRule');
    assertEq(type(IIdentityRegistry).interfaceId, bytes4(0xb9209e33), 'IIdentityRegistry');
    // Added in Phase 7 (2026-10-17), after ProxyDeployer moved to OZ Ownable
    // Re-pinned in S1 of the review items (2026-10-24): `deploy` takes and checks the expected rules (was 0x886d8cd8)
    assertEq(type(IProxyDeployer).interfaceId, bytes4(0xcedb15bb), 'IProxyDeployer');
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
    assertEq(IMaxHoldersRule.CapSet.selector, 0x113914a326da83d9b14b874c5cc74c6602b1ef1dc38916f0a4b3f618952f77ab);
    assertEq(
      IMaxHoldersRule.HolderCountSeeded.selector, 0x3b207bf9da27269642fda4f809efc7efaa06f42ec179fcf59ca932eb094bda34
    );
    assertEq(
      IMaxHoldersRule.HolderCountUpdated.selector, 0x3b44d433ae622a035b92513dcb4121b917fffdfa7ee90319d0e224a265504819
    );
    assertEq(
      IMaxHoldersRule.HolderExemptionSet.selector, 0x76f53701a110e481b9beccc51135df840459b6ca21581f88b3ee10235891f5e5
    );
    // Added in Phase 5b (2026-10-17)
    assertEq(
      IGated7540Vault.RedeemRequestRecovered.selector,
      0x274953cbe95d9877cd89aea6e3ca427fdd6170aeaa554aaea9ceceb36733cfd5
    );
    assertEq(IGated7540Vault.Fulfilled.selector, 0xaf0e36efc5836309f8f21b646c6bfec100f3cd067e3a9e9c232c2bcb3d7045ce);
    assertEq(
      IGated7540Vault.DepositRequestRejected.selector,
      0x62349aea2c873bb117c163dc27359603fe48b3c8e94fbb2acf192e0e6a300f38
    );
    assertEq(
      IGated7540Vault.RedeemRequestRejected.selector, 0x5e8a98909a36717c694a64574320783e7d08b72c502bc66cf1bb82c69b6614b8
    );
    assertEq(
      IGated7540Vault.CustodyChanged.selector, 0x76513a9766f12c52160aee58e04a50558448bf8d8cc1d1b2c60bcab3740c54bf
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
  }
}
