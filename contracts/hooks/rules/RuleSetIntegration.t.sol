// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {LockupRule} from 'contracts/hooks/rules/LockupRule.sol';
import {MaxHoldersRule} from 'contracts/hooks/rules/MaxHoldersRule.sol';
import {SettlementWindowRule} from 'contracts/hooks/rules/SettlementWindowRule.sol';
import {IntentTokenIntegrationTest} from 'contracts/tokens/IntentToken.t.sol';

/**
 * @notice Brief §6 step 5: every Phase 4 rule registered in a real ComplianceHook, in the recommended order
 *         Identity → Lockup → SettlementWindow → MaxHolders, with pre-flight parity against the state-changing calls
 */
contract RuleSetIntegrationTest is IntentTokenIntegrationTest {
  uint256 internal constant _MONDAY_10AM = 1_791_763_200 + 10 hours; // Mon 2026-10-12 10:00 UTC
  uint256 internal constant _SATURDAY_10AM = 1_791_763_200 + 5 days + 10 hours;

  LockupRule internal _lockupRule;
  SettlementWindowRule internal _windowRule;
  MaxHoldersRule internal _maxHoldersRule;
  address internal _carol = makeAddr('carol');
  address internal _dave = makeAddr('dave');

  function setUp() public virtual override {
    super.setUp(); // alice holds 1000 ether under an identity-only hook
    vm.warp(_MONDAY_10AM);
    _identity.set(_carol, true);
    _identity.set(_dave, true);

    _lockupRule = new LockupRule();
    _windowRule = new SettlementWindowRule();
    _maxHoldersRule = new MaxHoldersRule();
    vm.startPrank(_attester);
    _registry.attest(address(_lockupRule).codehash, IPolicyRegistry.AttestKind.RULE, 'ipfs://lockup');
    _registry.attest(address(_windowRule).codehash, IPolicyRegistry.AttestKind.RULE, 'ipfs://window');
    _registry.attest(address(_maxHoldersRule).codehash, IPolicyRegistry.AttestKind.RULE, 'ipfs://max-holders');
    vm.stopPrank();

    vm.startPrank(_admin);
    // P5: seeding is legitimate here because the rule is not yet in the token's active set.
    _maxHoldersRule.seedHolderCount(address(_token), 1);
    _maxHoldersRule.setCap(address(_token), 3);
    _windowRule.setWindow(address(_token), 9 hours, 17 hours, _windowRule.MON_TO_FRI());

    IComplianceRule[] memory _ruleSet = new IComplianceRule[](4);
    _ruleSet[0] = _identityRule;
    _ruleSet[1] = _lockupRule;
    _ruleSet[2] = _windowRule;
    _ruleSet[3] = _maxHoldersRule;
    // Same admin, registry and token as the attested hook, so the same attested codehash.
    _token.setPolicyHook(address(new ComplianceHook(_admin, _registry, address(_token), _ruleSet)));
    vm.stopPrank();
  }

  function _assertTransferParity(
    address _from,
    address _to,
    uint256 _amount,
    bytes32 _expected
  ) internal {
    (bool _ok, bytes32 _reason) = _token.canTransfer(_from, _to, _amount);
    assertEq(_reason, _expected, 'canTransfer reason');
    assertEq(_ok, _expected == Reasons.TRANSFER_OK);
    if (_expected != Reasons.TRANSFER_OK) vm.expectRevert(_rejected(_expected));
    vm.prank(_from);
    _token.transfer(_to, _amount);
  }

  function _assertExecuteParity(
    ITransferIntent.TransferIntent memory _i,
    bytes memory _sig,
    bytes32 _expected
  ) internal {
    vm.prank(_executor);
    (bool _ok, bytes32 _reason) = _token.canExecute(_i, _sig);
    assertEq(_reason, _expected, 'canExecute reason');
    assertEq(_ok, _expected == Reasons.TRANSFER_OK);
    if (_expected != Reasons.TRANSFER_OK) vm.expectRevert(_rejected(_expected));
    vm.prank(_executor);
    _token.executeTransfer(_i, _sig);
  }
}

contract RuleSetIntegration_Lockup is RuleSetIntegrationTest {
  function test_WhenAHolderIsLocked_TransfersAndIntentsAgreeUntilUnlock() external {
    vm.prank(_agent);
    _lockupRule.setLockup(address(_token), _alice, block.timestamp + 30 days);

    _assertTransferParity(_alice, _bob, 1 ether, Reasons.LOCKED);
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_bob, 1 ether, keccak256('n'));
    _assertExecuteParity(_i, _sig, Reasons.LOCKED);

    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, 1 ether); // FORCED is exempt
    assertEq(_token.balanceOf(_bob), 1 ether);

    vm.warp(block.timestamp + 30 days); // the unlock second; plain transfers ignore the settlement window
    _assertTransferParity(_alice, _bob, 1 ether, Reasons.TRANSFER_OK);
  }
}

contract RuleSetIntegration_SettlementWindow is RuleSetIntegrationTest {
  function test_WhenOutsideTheWindow_IntentsAreRejectedButPlainTransfersAreNot() external {
    vm.warp(_SATURDAY_10AM);
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_bob, 1 ether, keccak256('n'));
    _assertExecuteParity(_i, _sig, Reasons.OUTSIDE_SETTLEMENT_WINDOW);
    _assertTransferParity(_alice, _bob, 1 ether, Reasons.TRANSFER_OK);
  }

  function test_WhenInsideTheWindow_IntentsSettle() external {
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_bob, 1 ether, keccak256('n'));
    _assertExecuteParity(_i, _sig, Reasons.TRANSFER_OK);
    assertEq(_token.balanceOf(_bob), 1 ether);
  }
}

contract RuleSetIntegration_MaxHolders is RuleSetIntegrationTest {
  function _fillToTheCap() internal {
    _assertTransferParity(_alice, _bob, 10 ether, Reasons.TRANSFER_OK);
    _assertTransferParity(_alice, _treasury, 10 ether, Reasons.TRANSFER_OK);
    assertEq(_maxHoldersRule.holderCount(address(_token)), 3);
  }

  function test_WhenTheCapIsFull_ANewHolderIsRejectedWithParity() external {
    _fillToTheCap();
    _assertTransferParity(_alice, _carol, 1 ether, Reasons.MAX_HOLDERS);
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_carol, 1 ether, keccak256('n'));
    _assertExecuteParity(_i, _sig, Reasons.MAX_HOLDERS);
  }

  function test_WhenTheCapIsFull_AFullBalanceMoveToANewHolderIsAllowed() external {
    _fillToTheCap();
    _assertTransferParity(_bob, _carol, 10 ether, Reasons.TRANSFER_OK);
    assertEq(_maxHoldersRule.holderCount(address(_token)), 3);
  }

  function test_WhenTheCapIsFull_ForcedIsExemptButCounted() external {
    _fillToTheCap();
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _dave, 1 ether);
    assertEq(_maxHoldersRule.holderCount(address(_token)), 4);
  }

  function test_WhenTheReceiverIsUnverifiedAtAFullCap_IdentityRejectsFirst() external {
    _fillToTheCap();
    _assertTransferParity(_alice, _eve, 1 ether, Reasons.RECEIVER_NOT_VERIFIED);
  }

  function test_WhenEveryoneLeaves_TheCountReturnsToZero() external {
    _fillToTheCap();
    vm.startPrank(_burner);
    _token.burn(_alice, _token.balanceOf(_alice));
    _token.burn(_bob, _token.balanceOf(_bob));
    _token.burn(_treasury, _token.balanceOf(_treasury));
    vm.stopPrank();
    assertEq(_maxHoldersRule.holderCount(address(_token)), 0);
  }
}
