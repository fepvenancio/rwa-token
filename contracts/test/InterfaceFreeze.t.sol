// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IIdentityRule} from 'interfaces/IIdentityRule.sol';
import {IIntentExecutor} from 'interfaces/IIntentExecutor.sol';
import {IIntentExecutorBatch} from 'interfaces/IIntentExecutorBatch.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
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
    assertEq(type(IIdentityRule).interfaceId, bytes4(0x150c4aea), 'IIdentityRule');
    assertEq(type(IIdentityRegistry).interfaceId, bytes4(0xb9209e33), 'IIdentityRegistry');
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
  }
}
