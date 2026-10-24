// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {HolderRestrictionRule} from 'contracts/hooks/rules/HolderRestrictionRule.sol';
import {MaxHoldersRule} from 'contracts/hooks/rules/MaxHoldersRule.sol';
import {MinPositionRule} from 'contracts/hooks/rules/MinPositionRule.sol';
import {SettlementWindowRule} from 'contracts/hooks/rules/SettlementWindowRule.sol';
import {IntentTokenIntegrationTest} from 'contracts/tokens/IntentToken.t.sol';

/**
 * @notice Brief §6 step 5: every Phase 4 rule registered in a real ComplianceHook, in the recommended order
 *         Identity → MinPosition → HolderRestriction → SettlementWindow → MaxHolders, with pre-flight parity against the state-changing calls
 */
contract RuleSetIntegrationTest is IntentTokenIntegrationTest {
  uint256 internal constant _MONDAY_10AM = 1_791_763_200 + 10 hours; // Mon 2026-10-12 10:00 UTC
  uint256 internal constant _SATURDAY_10AM = 1_791_763_200 + 5 days + 10 hours;

  MinPositionRule internal _minPositionRule;
  HolderRestrictionRule internal _restrictionRule;
  SettlementWindowRule internal _windowRule;
  MaxHoldersRule internal _maxHoldersRule;
  address internal _carol = makeAddr('carol');
  address internal _dave = makeAddr('dave');

  function setUp() public virtual override {
    super.setUp(); // alice holds 1000 ether under an identity-only hook
    vm.warp(_MONDAY_10AM);
    _identity.set(_carol, true);
    _identity.set(_dave, true);

    _minPositionRule = new MinPositionRule();
    _restrictionRule = new HolderRestrictionRule();
    _windowRule = new SettlementWindowRule();
    _maxHoldersRule = new MaxHoldersRule();
    vm.startPrank(_attester);
    _registry.attest(address(_minPositionRule).codehash, IPolicyRegistry.AttestKind.RULE, 'ipfs://min-position');
    _registry.attest(address(_restrictionRule).codehash, IPolicyRegistry.AttestKind.RULE, 'ipfs://restriction');
    _registry.attest(address(_windowRule).codehash, IPolicyRegistry.AttestKind.RULE, 'ipfs://window');
    _registry.attest(address(_maxHoldersRule).codehash, IPolicyRegistry.AttestKind.RULE, 'ipfs://max-holders');
    vm.stopPrank();

    vm.startPrank(_admin);
    // P5: seeding is legitimate here because the rule is not yet in the token's active set.
    _maxHoldersRule.seedHolderCount(address(_token), 1);
    _maxHoldersRule.setCap(address(_token), 3);
    _windowRule.setWindow(address(_token), 9 hours, 17 hours, _windowRule.MON_TO_FRI());

    IComplianceRule[] memory _ruleSet = new IComplianceRule[](5);
    _ruleSet[0] = _identityRule;
    _ruleSet[1] = _minPositionRule;
    _ruleSet[2] = _restrictionRule;
    _ruleSet[3] = _windowRule;
    _ruleSet[4] = _maxHoldersRule;
    // The shared hook is already installed; the token's admin replaces the token's rule set on it.
    _hook.setRules(address(_token), _ruleSet);
    vm.stopPrank();
  }

  function _assertTransferParity(
    address _from,
    address _to,
    uint256 _amount,
    bytes32 _expected
  ) internal {
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(_from, _to, _amount);
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
    _restrictionRule.setLockup(address(_token), _alice, block.timestamp + 30 days);

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

  /// @dev The vaults' `max*` ask `canReceive`, so it must say what a mint to the account would say
  function test_WhenTheCapIsFull_CanReceiveIsFalseForANewAccountAndTrueForAHolder() external {
    _fillToTheCap();
    assertFalse(_token.canReceive(_carol));
    assertTrue(_token.canReceive(_bob));
    assertTrue(_token.canSend(_carol)); // the cap never stops a sender
    (bool _mintOk,) = _token.canTransferWithReason(address(0), _carol, 1);
    assertFalse(_mintOk);

    _assertTransferParity(_bob, _treasury, 10 ether, Reasons.TRANSFER_OK); // bob leaves: a slot frees
    assertTrue(_token.canReceive(_carol));
    (_mintOk,) = _token.canTransferWithReason(address(0), _carol, 1);
    assertTrue(_mintOk);
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

contract RuleSetIntegration_Freeze is RuleSetIntegrationTest {
  function _freeze(
    address _account,
    bool _frozen
  ) internal {
    vm.prank(_agent);
    _restrictionRule.setFrozen(address(_token), _account, _frozen);
  }

  function test_WhenTheSenderIsFrozen_TransfersAndIntentsAgreeUntilUnfrozen() external {
    _freeze(_alice, true);

    _assertTransferParity(_alice, _bob, 1 ether, Reasons.SENDER_FROZEN);
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_bob, 1 ether, keccak256('n'));
    _assertExecuteParity(_i, _sig, Reasons.SENDER_FROZEN);
    assertFalse(_token.canSend(_alice));
    assertFalse(_token.canReceive(_alice));

    _freeze(_alice, false);
    assertTrue(_token.canSend(_alice));
    _assertTransferParity(_alice, _bob, 1 ether, Reasons.TRANSFER_OK);
  }

  /// @dev RD4: the freeze on the receiver applies to a mint and to a forced transfer as well
  function test_WhenTheReceiverIsFrozen_TransfersMintsAndForcedMovesAreRejected() external {
    _freeze(_bob, true);

    _assertTransferParity(_alice, _bob, 1 ether, Reasons.RECEIVER_FROZEN);
    vm.expectRevert(_rejected(Reasons.RECEIVER_FROZEN));
    vm.prank(_minter);
    _token.mint(_bob, 1 ether);
    vm.expectRevert(_rejected(Reasons.RECEIVER_FROZEN));
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, 1 ether);
    assertFalse(_token.canReceive(_bob));
    assertFalse(_token.canSend(_bob));
  }

  /// @dev A frozen holder can still be moved out of by force, and that is the enforcement route
  function test_WhenTheSenderIsFrozen_AForcedTransferToAQuarantineAccountWorks() external {
    _freeze(_alice, true);
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _treasury, 1 ether);
    assertEq(_token.balanceOf(_treasury), 1 ether);
  }

  /// @dev RD4: a burn, even the enforcement burner's, is refused from a frozen account
  function test_WhenTheSenderIsFrozen_ABurnIsRejected() external {
    _freeze(_alice, true);
    vm.expectRevert(_rejected(Reasons.SENDER_FROZEN));
    vm.prank(_burner);
    _token.burn(_alice, 1 ether);
  }

  function test_WhenAFrozenHolderIsAlsoLocked_TheFreezeIsReportedFirst() external {
    _freeze(_alice, true);
    vm.prank(_agent);
    _restrictionRule.setLockup(address(_token), _alice, block.timestamp + 30 days);
    _assertTransferParity(_alice, _bob, 1 ether, Reasons.SENDER_FROZEN);
  }
}

/// @notice L-1: dust can no longer be used to take holder slots or to leave a position nobody can exit
contract RuleSetIntegration_MinPosition is RuleSetIntegrationTest {
  uint256 internal constant _MIN = 10 ether;

  function setUp() public override {
    super.setUp();
    vm.prank(_admin);
    _minPositionRule.setMinPosition(address(_token), _MIN);
  }

  function test_WhenADustTransferTargetsAnEmptyAccount_ItIsRejectedWithParityAndTakesNoSlot() external {
    _assertTransferParity(_alice, _bob, 1, Reasons.BELOW_MIN_POSITION);
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_bob, 1, keccak256('n'));
    _assertExecuteParity(_i, _sig, Reasons.BELOW_MIN_POSITION);
    assertEq(_maxHoldersRule.holderCount(address(_token)), 1);

    _assertTransferParity(_alice, _bob, _MIN, Reasons.TRANSFER_OK);
    assertEq(_maxHoldersRule.holderCount(address(_token)), 2);
  }

  function test_WhenATransferWouldLeaveDustBehind_ItIsRejected() external {
    _assertTransferParity(_alice, _bob, 1000 ether - 1, Reasons.BELOW_MIN_POSITION);
    _assertTransferParity(_alice, _bob, 1000 ether, Reasons.TRANSFER_OK);
    assertEq(_token.balanceOf(_alice), 0);
  }

  function test_WhenAMintWouldLeaveDust_ItIsRejected() external {
    vm.expectRevert(_rejected(Reasons.BELOW_MIN_POSITION));
    vm.prank(_minter);
    _token.mint(_bob, _MIN - 1);
    vm.prank(_minter);
    _token.mint(_bob, _MIN);
    assertEq(_token.balanceOf(_bob), _MIN);
  }

  /// @dev Enforcement is exempt: a forced transfer may leave or create a dust position, and it still counts as a holder
  function test_WhenForced_DustIsAllowedAndTheHolderIsCounted() external {
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _dave, 1);
    assertEq(_token.balanceOf(_dave), 1);
    assertEq(_maxHoldersRule.holderCount(address(_token)), 2);
  }

  function test_WhenAnEnforcementBurnLeavesDust_ItIsAllowed() external {
    vm.prank(_burner);
    _token.burn(_alice, 1000 ether - 1);
    assertEq(_token.balanceOf(_alice), 1);
  }

  /// @dev A minimum of zero switches the rule off for the token
  function test_WhenTheMinimumIsSwitchedOff_DustMovesAgain() external {
    vm.prank(_admin);
    _minPositionRule.setMinPosition(address(_token), 0);
    _assertTransferParity(_alice, _bob, 1, Reasons.TRANSFER_OK);
  }

  /// @dev The account answers have no opinion about an amount: a would-be holder can still receive
  function test_WhenAMinimumIsSet_CanReceiveStillAcceptsAnEmptyVerifiedAccount() external view {
    assertTrue(_token.canReceive(_bob));
    assertTrue(_token.canSend(_alice));
  }
}
