// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Reasons} from 'interfaces/Errors.sol';

import {ICredentialRegistry} from 'interfaces/ICredentialRegistry.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';
import {Quals} from 'interfaces/Quals.sol';

import {CredentialRule} from 'contracts/hooks/rules/CredentialRule.sol';
import {CredentialRegistry} from 'contracts/identity/CredentialRegistry.sol';
import {IntentTokenIntegrationTest} from 'contracts/tokens/IntentToken.t.sol';

/// @notice Integration: a real `CredentialRegistry`, `CredentialRule` and `ComplianceHook` on a real `IntentToken`,
///         wired in deployment order. alice (KYC, professional) holds 1,000 tokens
contract CredentialRuleIntegrationTest is IntentTokenIntegrationTest {
  uint256 internal constant _NOW = 1_792_198_800; // Sat 2026-10-17 01:00 UTC

  CredentialRegistry internal _creds;
  CredentialRule internal _credentialRule;
  address internal _kyc = makeAddr('kycAttester');
  address internal _recovery = makeAddr('recoveryTimelock');
  address internal _carol = makeAddr('carol');

  function setUp() public virtual override {
    super.setUp(); // alice holds 1000 ether under an identity-only hook
    vm.warp(_NOW);
    _creds = new CredentialRegistry(_admin, _guardian);
    vm.startPrank(_admin);
    _creds.grantRole(_creds.RECOVERY_ROLE(), _recovery);
    _creds.addAttester(_kyc, type(uint32).max);
    vm.stopPrank();

    _credentialRule = new CredentialRule(_creds);
    vm.prank(_attester);
    _registry.attest(address(_credentialRule).codehash, IPolicyRegistry.AttestKind.RULE, 'ipfs://credential-rule');
    vm.prank(_admin);
    _credentialRule.setPolicy(address(_token), Quals.KYC, 0, 0, 1);

    _credential(_alice, Quals.KYC | Quals.PROFESSIONAL, 30 days);
    _credential(_bob, Quals.KYC, 365 days);
    _credential(_treasury, Quals.KYC | Quals.INFRA, 365 days);
    _installRules(_one(_credentialRule));
  }

  function _credential(
    address _who,
    uint32 _quals,
    uint256 _validFor
  ) internal {
    vm.prank(_kyc);
    _creds.set(_who, uint64(block.timestamp + _validFor), _quals);
  }

  function _transferWithParity(
    address _from,
    address _to,
    uint256 _amount
  ) internal returns (bool _ok, bytes32 _reason) {
    (_ok, _reason) = _token.canTransferWithReason(_from, _to, _amount);
    if (!_ok) vm.expectRevert(_rejected(_reason));
    vm.prank(_from);
    _token.transfer(_to, _amount);
  }
}

contract CredentialRuleIntegration_Eligibility is CredentialRuleIntegrationTest {
  function test_WhenBothPartiesHoldCredentials_TheTransferSucceedsAndPreflightAgrees() external {
    (bool _ok,) = _transferWithParity(_alice, _bob, 10 ether);
    assertTrue(_ok);
    assertEq(_token.balanceOf(_bob), 10 ether);
  }

  function test_WhenTheReceiverHasNoCredential_TheTransferIsRejectedAndPreflightAgrees() external {
    (bool _ok, bytes32 _reason) = _transferWithParity(_alice, _eve, 10 ether);
    assertFalse(_ok);
    assertEq(_reason, Reasons.RECEIVER_NOT_VERIFIED);
  }

  function test_WhenMintingToAnAddressWithoutACredential_ItIsRejectedAndIsUserAllowedAgrees() external {
    assertFalse(_token.canReceive(_eve));
    assertTrue(_token.canReceive(_bob));
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_minter);
    _token.mint(_eve, 1 ether);
  }

  function test_WhenThePolicyNeedsAProfessional_OnlyAProfessionalCanReceive() external {
    vm.prank(_admin);
    _credentialRule.setPolicy(address(_token), Quals.KYC, Quals.PROFESSIONAL | Quals.INFRA, 0, 1);

    (bool _okBob, bytes32 _reasonBob) = _transferWithParity(_alice, _bob, 1 ether);
    assertFalse(_okBob);
    assertEq(_reasonBob, Reasons.RECEIVER_NOT_ELIGIBLE);

    (bool _okTreasury,) = _transferWithParity(_alice, _treasury, 1 ether); // INFRA passes the any-mask
    assertTrue(_okTreasury);

    _credential(_carol, Quals.KYC | Quals.PROFESSIONAL, 30 days);
    (bool _okCarol,) = _transferWithParity(_alice, _carol, 1 ether);
    assertTrue(_okCarol);
  }

  function test_WhenTheTokenTrustsADifferentAttester_NoOneIsEligible() external {
    vm.prank(_admin);
    _credentialRule.setPolicy(address(_token), Quals.KYC, 0, 0, uint64(1) << 5);
    (bool _ok, bytes32 _reason) = _transferWithParity(_alice, _bob, 1 ether);
    assertFalse(_ok);
    assertEq(_reason, Reasons.RECEIVER_NOT_ELIGIBLE);
  }

  function test_WhenThePolicyIsRemoved_ReceiversAreRejectedButHoldersCanStillLeave() external {
    vm.prank(_admin);
    _credentialRule.setPolicy(address(_token), 0, 0, 0, 0);
    (bool _ok, bytes32 _reason) = _transferWithParity(_alice, _bob, 1 ether);
    assertFalse(_ok);
    assertEq(_reason, Reasons.RECEIVER_NOT_ELIGIBLE);

    vm.prank(_burner);
    _token.burn(_alice, 1 ether); // an enforcement burn still works
    assertEq(_token.balanceOf(_alice), 999 ether);
  }
}

contract CredentialRuleIntegration_Lapse is CredentialRuleIntegrationTest {
  function test_WhenTheSenderHasLapsed_ItCanStillSendButNotReceive() external {
    vm.warp(_NOW + 31 days); // alice's credential ran out after 30 days, bob's after 365
    assertTrue(_token.canSend(_alice)); // a lapsed holder may send but not receive
    assertFalse(_token.canReceive(_alice));
    (bool _sendOk,) = _transferWithParity(_alice, _bob, 100 ether);
    assertTrue(_sendOk);

    (bool _ok, bytes32 _reason) = _transferWithParity(_bob, _alice, 1 ether);
    assertFalse(_ok);
    assertEq(_reason, Reasons.CREDENTIAL_EXPIRED);
  }

  function test_WhenTheReceiverHasLapsed_MintingToItIsRejected() external {
    vm.warp(_NOW + 31 days);
    vm.expectRevert(_rejected(Reasons.CREDENTIAL_EXPIRED));
    vm.prank(_minter);
    _token.mint(_alice, 1 ether);
    assertFalse(_token.canReceive(_alice));
  }

  function test_WhenTheAttesterRenews_TheHolderReceivesAgain() external {
    vm.warp(_NOW + 31 days);
    _credential(_alice, Quals.KYC | Quals.PROFESSIONAL, 365 days);
    (bool _ok,) = _transferWithParity(_bob, _alice, 0);
    assertTrue(_ok);
    assertTrue(_token.canReceive(_alice));
  }

  function test_WhenTheAttesterSetsExitOnly_TheHolderCanSendButNotReceive() external {
    vm.prank(_kyc);
    _creds.setStatus(_alice, ICredentialRegistry.Status.EXIT_ONLY);
    (bool _sendOk,) = _transferWithParity(_alice, _bob, 5 ether);
    assertTrue(_sendOk);
    (bool _receiveOk, bytes32 _reason) = _transferWithParity(_bob, _alice, 1 ether);
    assertFalse(_receiveOk);
    assertEq(_reason, Reasons.RECEIVER_NOT_VERIFIED);
  }

  function test_WhenTheAttesterIsKilledAndRevived_HoldersExitThenReceiveAgain() external {
    vm.prank(_guardian);
    _creds.killAttester(0);

    (bool _sendOk,) = _transferWithParity(_alice, _bob, 5 ether); // bob reads EXIT_ONLY too: receiving fails
    assertFalse(_sendOk);
    vm.prank(_burner);
    _token.burn(_alice, 1 ether); // an enforcement burn works
    assertEq(_token.balanceOf(_alice), 999 ether);

    vm.prank(_recovery);
    _creds.reviveAttester(0);
    (bool _revivedOk,) = _transferWithParity(_alice, _bob, 5 ether);
    assertTrue(_revivedOk);
  }

  function test_WhenSenderAndReceiverStandingsVary_PreflightAlwaysMatchesTheRealCall() external {
    for (uint256 _round; _round < 4; ++_round) {
      uint256 _snap = vm.snapshotState();
      if (_round == 1) {
        vm.prank(_kyc);
        _creds.setStatus(_alice, ICredentialRegistry.Status.EXIT_ONLY);
      } else if (_round == 2) {
        vm.prank(_guardian);
        _creds.blockSubject(_alice);
      } else if (_round == 3) {
        vm.warp(_NOW + 31 days);
      }
      _transferWithParity(_alice, _bob, 1 ether);
      _transferWithParity(_bob, _alice, 0);
      vm.revertToState(_snap);
    }
  }
}

contract CredentialRuleIntegration_Enforcement is CredentialRuleIntegrationTest {
  function test_WhenTheGuardianBlocksAHolder_ItCannotSendButTheAgentCanTakeItsTokens() external {
    vm.prank(_guardian);
    _creds.blockSubject(_alice);

    (bool _ok, bytes32 _reason) = _transferWithParity(_alice, _bob, 1 ether);
    assertFalse(_ok);
    assertEq(_reason, Reasons.SENDER_NOT_VERIFIED);

    assertFalse(_token.canSend(_alice)); // the token-level probe agrees with the real call
    assertTrue(_token.canSend(_bob));

    vm.prank(_agent);
    _token.forcedTransfer(_alice, _treasury, 400 ether);
    assertEq(_token.balanceOf(_treasury), 400 ether);
  }

  function test_WhenTheGuardianBlocksAHolder_TheBurnerCanStillBurnFromIt() external {
    vm.prank(_guardian);
    _creds.blockSubject(_alice);
    vm.prank(_burner);
    _token.burn(_alice, 1000 ether);
    assertEq(_token.balanceOf(_alice), 0);
  }

  function test_WhenAForcedMoveHasAnIneligibleReceiver_ItIsRejected() external {
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _eve, 1 ether);

    vm.warp(_NOW + 366 days); // everyone has lapsed, treasury included
    vm.expectRevert(_rejected(Reasons.CREDENTIAL_EXPIRED));
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _treasury, 1 ether);
  }

  function test_WhenThePauseIsOn_AForcedMoveToAnEligibleReceiverStillWorks() external {
    vm.prank(_guardian);
    _token.pause();
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _treasury, 1 ether);
    assertEq(_token.balanceOf(_treasury), 1 ether);
  }

  function test_WhenTheRecoveryTimelockClearsABlock_TheHolderSendsAgain() external {
    vm.prank(_guardian);
    _creds.blockSubject(_alice);
    vm.prank(_recovery);
    _creds.clearGuardianBlock(_alice);
    (bool _ok,) = _transferWithParity(_alice, _bob, 1 ether);
    assertTrue(_ok);
  }

  function test_WhenAnAttesterLiftsItsOwnBlock_TheGuardiansBlockStaysUntilCleared() external {
    vm.prank(_guardian);
    _creds.blockSubject(_alice);
    vm.prank(_kyc);
    _creds.setStatus(_alice, ICredentialRegistry.Status.ACTIVE);
    (bool _ok, bytes32 _reason) = _transferWithParity(_alice, _bob, 1 ether);
    assertFalse(_ok);
    assertEq(_reason, Reasons.SENDER_NOT_VERIFIED);
  }
}

contract CredentialRuleIntegration_Intents is CredentialRuleIntegrationTest {
  function test_WhenTheReceiverHoldsACredential_ASignedIntentSettlesAndPreflightAgrees() external {
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_bob, 10 ether, bytes32('n1'));
    (bool _ok, bytes32 _reason) = _token.canExecute(_i, _sig, _executor);
    assertTrue(_ok);
    assertEq(_reason, Reasons.TRANSFER_OK);

    vm.prank(_executor);
    _token.executeTransfer(_i, _sig);
    assertEq(_token.balanceOf(_bob), 10 ether);
  }

  function test_WhenTheReceiverLapsedBeforeExecution_TheIntentIsRejectedAndPreflightAgrees() external {
    _credential(_bob, Quals.KYC, 1 hours);
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_bob, 10 ether, bytes32('n2'));
    vm.warp(_NOW + 2 hours);

    (bool _ok, bytes32 _reason) = _token.canExecute(_i, _sig, _executor);
    assertFalse(_ok);
    assertEq(_reason, Reasons.CREDENTIAL_EXPIRED);

    vm.expectRevert(_rejected(Reasons.CREDENTIAL_EXPIRED));
    vm.prank(_executor);
    _token.executeTransfer(_i, _sig);
  }

  function test_WhenTheSignerHasLapsed_TheIntentStillSettles() external {
    vm.warp(_NOW + 31 days); // alice's credential has lapsed, so she can only send
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_bob, 10 ether, bytes32('n3'));
    vm.prank(_executor);
    _token.executeTransfer(_i, _sig);
    assertEq(_token.balanceOf(_bob), 10 ether);
  }
}
