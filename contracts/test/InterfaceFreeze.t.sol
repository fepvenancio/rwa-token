// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC7540Deposit} from 'interfaces/IERC7540Deposit.sol';
import {IERC7540Operator} from 'interfaces/IERC7540Operator.sol';
import {IERC7540Redeem} from 'interfaces/IERC7540Redeem.sol';
import {IERC7575} from 'interfaces/IERC7575.sol';
import {IFund} from 'interfaces/IFund.sol';
import {IFundHoldersRule} from 'interfaces/IFundHoldersRule.sol';
import {IGated4626Vault} from 'interfaces/IGated4626Vault.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {IGovernanceTimelock} from 'interfaces/IGovernanceTimelock.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IIdentityRule} from 'interfaces/IIdentityRule.sol';
import {IIntentExecutor} from 'interfaces/IIntentExecutor.sol';
import {IIntentExecutorBatch} from 'interfaces/IIntentExecutorBatch.sol';
import {ILockupRule} from 'interfaces/ILockupRule.sol';
import {IMaxHoldersRule} from 'interfaces/IMaxHoldersRule.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {IProxyDeployer} from 'interfaces/IProxyDeployer.sol';
import {ISettlementWindowRule} from 'interfaces/ISettlementWindowRule.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

/**
 * @notice Freeze guard for `contracts/interfaces/` (CLAUDE.md rules 4 and 14). Interfaces were frozen on 2026-10-16.
 *         A failure here means the frozen ABI changed: revert the change, or get an explicit instruction and re-pin
 */
contract InterfaceFreezeTest is Test {
  function test_WhenInterfacesCompile_TheirErc165IdsArePinned() external pure {
    assertEq(type(IPolicyGated).interfaceId, bytes4(0xf517b40d), 'IPolicyGated');
    assertEq(type(IPolicyHook).interfaceId, bytes4(0xb7723023), 'IPolicyHook');
    assertEq(type(IComplianceRule).interfaceId, bytes4(0x93d5c2be), 'IComplianceRule');
    assertEq(type(IComplianceHook).interfaceId, bytes4(0x2604e338), 'IComplianceHook');
    assertEq(type(IPolicyRegistry).interfaceId, bytes4(0x947f9fc8), 'IPolicyRegistry');
    assertEq(type(ITransferIntent).interfaceId, bytes4(0x7a2b1b79), 'ITransferIntent');
    assertEq(type(IIntentExecutor).interfaceId, bytes4(0xd2319653), 'IIntentExecutor');
    // Added in Phase 3 (2026-10-16): executeBatch, pause, unpause
    assertEq(type(IIntentExecutorBatch).interfaceId, bytes4(0x117727cb), 'IIntentExecutorBatch');
    // Added in Phase 4 (2026-10-16)
    assertEq(type(ILockupRule).interfaceId, bytes4(0xaafb038e), 'ILockupRule');
    assertEq(type(ISettlementWindowRule).interfaceId, bytes4(0xf2058aff), 'ISettlementWindowRule');
    // Re-pinned in Phase 5b (2026-10-17) on owner instruction R1: setExemptHolder / isExemptHolder added (was 0xa13cb93c)
    // Re-pinned 2026-10-22 on owner instruction: seedHolderCountFromHolders / seedHolderCountFromRule added (was
    // 0x0e091382)
    assertEq(type(IMaxHoldersRule).interfaceId, bytes4(0x360b3dad), 'IMaxHoldersRule');
    // Added in Phase 5a (2026-10-17)
    assertEq(type(IGated4626Vault).interfaceId, bytes4(0xb008690c), 'IGated4626Vault');
    // Added in Phase 5b (2026-10-17). The four ERC-7540 / ERC-7575 ids are the standard's own values.
    assertEq(type(IERC7540Operator).interfaceId, bytes4(0xe3bc4e65), 'IERC7540Operator');
    assertEq(type(IERC7540Deposit).interfaceId, bytes4(0xce3bbe50), 'IERC7540Deposit');
    assertEq(type(IERC7540Redeem).interfaceId, bytes4(0x620ee8e4), 'IERC7540Redeem');
    assertEq(type(IERC7575).interfaceId, bytes4(0x2f0a18c5), 'IERC7575');
    // Re-pinned 2026-10-17 on owner instruction: recoverRedeemRequest added (was 0x34aae296)
    // Re-pinned in v0.2.0 (2026-10-17): recoverClaimable added, the one post-freeze change (owner decision M-3)
    assertEq(type(IGated7540Vault).interfaceId, bytes4(0x75f5b0db), 'IGated7540Vault');
    assertEq(type(IIdentityRule).interfaceId, bytes4(0x150c4aea), 'IIdentityRule');
    assertEq(type(IIdentityRegistry).interfaceId, bytes4(0xb9209e33), 'IIdentityRegistry');
    // Added in Phase 7 (2026-10-17), after ProxyDeployer moved to OZ Ownable
    assertEq(type(IProxyDeployer).interfaceId, bytes4(0x886d8cd8), 'IProxyDeployer');
    // Added in v0.2.0 (owner decision M-1)
    assertEq(type(IGovernanceTimelock).interfaceId, bytes4(0x31993a1c), 'IGovernanceTimelock');
    // Added in the fund layer (2026-10-22), ids computed from the signatures with `cast sig`
    assertEq(type(IFund).interfaceId, bytes4(0x44c4a64f), 'IFund');
    assertEq(type(IFundHoldersRule).interfaceId, bytes4(0x5c275a39), 'IFundHoldersRule');
  }

  function test_WhenInterfacesCompile_TheirEventTopicsArePinned() external pure {
    assertEq(IPolicyGated.ForcedTransfer.selector, 0x31a05a6a55253f32ca1a2eae200ad7ddf38d17e9f6e0535e9a85ab4a218aeaa3);
    assertEq(IPolicyGated.Frozen.selector, 0x68e0d8c112165d0949ce87205b719ed7d98c7401866c34a159f7c67c6f5620e7);
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
    assertEq(
      IComplianceHook.RuleSetChanged.selector, 0x1a22bda7b05ed1fb294fe52899bc63d685e2b75bb9f93e1e840f5016038b3893
    );
    // Added in Phase 4 (2026-10-16)
    assertEq(ILockupRule.LockupSet.selector, 0xd3de67b8116f1abe42856d12f29c6dd6798dc57c837e1d2083e129b58d2e323a);
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
  }
}
