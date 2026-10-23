// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC1967Utils} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol';
import {Errors} from '@openzeppelin/contracts/utils/Errors.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {IdentityRule} from 'contracts/hooks/rules/IdentityRule.sol';
import {MockIdentityRegistry} from 'contracts/test/MockIdentityRegistry.sol';
import {MockReentrantRule} from 'contracts/test/MockReentrantRule.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';

/// @notice Integration: real registry, compliance hook and identity rule, wired in deployment order
contract IntentTokenIntegrationTest is Test {
  PolicyRegistry internal _registry;
  MockIdentityRegistry internal _identity;
  ComplianceHook internal _hook;
  IdentityRule internal _identityRule;
  IntentToken internal _impl;
  IntentToken internal _token;

  address internal _admin = makeAddr('timelock');
  address internal _guardian = makeAddr('guardian');
  address internal _attester = makeAddr('attester');
  address internal _minter = makeAddr('minter');
  address internal _burner = makeAddr('burner');
  address internal _agent = makeAddr('agent');
  address internal _executor = makeAddr('executor');
  address internal _treasury = makeAddr('treasury');
  address internal _bob = makeAddr('bob');
  address internal _eve = makeAddr('eve');
  address internal _alice;
  uint256 internal _alicePk;

  function setUp() public virtual {
    (_alice, _alicePk) = makeAddrAndKey('alice');
    _deployStack(true);
    _grantRoles();

    _identity.set(_alice, true);
    _identity.set(_bob, true);
    _identity.set(_treasury, true);

    vm.prank(_minter);
    _token.mint(_alice, 1000 ether);
  }

  /**
   * @dev Production order. Registry → implementation → rules → attest rules → hook with its initial rules (bound to the
   *      predicted proxy) → attest hook and implementation → proxy. Rules are hook-agnostic, so they can be deployed
   *      first and shared across tokens. The token is live with its policy at deploy; the timelock only governs changes
   */
  function _deployStack(
    bool _withRules
  ) internal {
    _registry = new PolicyRegistry(_admin, _attester);
    _identity = new MockIdentityRegistry();
    _impl = new IntentToken();

    _identityRule = new IdentityRule(IIdentityRegistry(address(_identity)));
    vm.prank(_attester);
    _registry.attest(address(_identityRule).codehash, IPolicyRegistry.AttestKind.RULE, 'ipfs://rule-review');

    // CREATE2 through ProxyDeployer, as in production: the address does not depend on this contract's nonce.
    ProxyDeployer _proxyDeployer = new ProxyDeployer(address(this));
    address _predictedProxy = _proxyDeployer.predict('GNOTE', address(_impl));
    _hook = new ComplianceHook(_admin, _registry, _predictedProxy, _withRules ? _one(_identityRule) : _none());

    vm.startPrank(_attester);
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, 'ipfs://hook-review');
    _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, 'ipfs://impl-review');
    vm.stopPrank();

    _token = IntentToken(
      address(
        _proxyDeployer.deploy(
          'GNOTE',
          address(_impl),
          abi.encodeCall(
            IntentToken.initialize, ('Gated Note', 'GNOTE', _admin, _guardian, address(_registry), address(_hook))
          ),
          address(_hook)
        )
      )
    );
    assertEq(address(_token), _predictedProxy, 'proxy address prediction');
  }

  function _installRules(
    IComplianceRule[] memory _ruleSet
  ) internal {
    vm.prank(_admin);
    _hook.setRules(_ruleSet);
  }

  function _grantRoles() internal {
    vm.startPrank(_admin);
    _token.grantRole(_token.MINTER_ROLE(), _minter);
    _token.grantRole(_token.BURNER_ROLE(), _burner);
    _token.grantRole(_token.AGENT_ROLE(), _agent);
    _token.grantRole(_token.EXECUTOR_ROLE(), _executor);
    _token.grantRole(_token.UPGRADER_ROLE(), _admin);
    vm.stopPrank();
  }

  function _none() internal pure returns (IComplianceRule[] memory _ruleSet) {
    _ruleSet = new IComplianceRule[](0);
  }

  function _one(
    IComplianceRule _rule
  ) internal pure returns (IComplianceRule[] memory _ruleSet) {
    _ruleSet = new IComplianceRule[](1);
    _ruleSet[0] = _rule;
  }

  function _rejected(
    bytes32 _reason
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IPolicyGated.PolicyGated_TransferRejected.selector, _reason);
  }

  function _signedIntent(
    address _to,
    uint256 _amount,
    bytes32 _nonce
  ) internal view returns (ITransferIntent.TransferIntent memory _i, bytes memory _sig) {
    (_i, _sig) = _signedIntentFor(_to, _amount, _nonce, address(0), address(0), 0);
  }

  /// @dev An intent from alice that names `_boundTo` as its only executor and states what she is to receive
  function _signedIntentFor(
    address _to,
    uint256 _amount,
    bytes32 _nonce,
    address _boundTo,
    address _considerationToken,
    uint256 _considerationAmount
  ) internal view returns (ITransferIntent.TransferIntent memory _i, bytes memory _sig) {
    _i = ITransferIntent.TransferIntent({
      from: _alice,
      to: _to,
      amount: _amount,
      nonce: _nonce,
      deadline: block.timestamp + 1 days,
      ref: bytes32('ISO20022:MSG-1'),
      executor: _boundTo,
      validAfter: 0,
      considerationToken: _considerationToken,
      considerationAmount: _considerationAmount
    });
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_alicePk, _token.intentHash(_i));
    _sig = abi.encodePacked(_r, _s, _v);
  }
}

contract IntentTokenIntegration_Deployment is IntentTokenIntegrationTest {
  function test_WhenDeployed_ThePolicyIsAlreadyInstalled() external view {
    assertEq(_hook.ruleCount(), 1);
    assertEq(address(_hook.rules()[0]), address(_identityRule));
    (bool _ok, bytes32 _reason) = _token.canTransfer(_alice, _eve, 1);
    assertFalse(_ok);
    assertEq(_reason, Reasons.RECEIVER_NOT_VERIFIED);
  }

  /// @dev Regression: a hook without rules used to approve everything; it now fails closed
  function test_WhenTheHookIsDeployedWithoutRules_EveryMovementIsRejected() external {
    _deployStack(false);
    _grantRoles();
    vm.expectRevert(_rejected(Reasons.NO_RULES));
    vm.prank(_minter);
    _token.mint(_eve, 1);
  }

  /// @dev Regression: a clone of the attested hook with an attacker as admin was itself attested
  function test_WhenAHookCloneHasAnotherAdmin_ItIsNotAttested() external {
    ComplianceHook _clone = new ComplianceHook(makeAddr('attacker'), _registry, address(_token), _none());
    assertFalse(_registry.isAttested(address(_clone), IPolicyRegistry.AttestKind.HOOK));
    vm.expectRevert(
      abi.encodeWithSelector(
        IPolicyGated.PolicyGated_NotAttested.selector, address(_clone), IPolicyRegistry.AttestKind.HOOK
      )
    );
    vm.prank(_admin);
    _token.setPolicyHook(address(_clone));
  }

  function test_WhenAnIdenticalHookIsInstalled_ItIsAccepted() external {
    ComplianceHook _twin = new ComplianceHook(_admin, _registry, address(_token), _one(_identityRule));
    vm.prank(_admin);
    _token.setPolicyHook(address(_twin));
    assertEq(_token.policyHook(), address(_twin));
  }
}

contract IntentTokenIntegration_Identity is IntentTokenIntegrationTest {
  function test_WhenMintingToAnUnverifiedAccount_ItIsRejected() external {
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_minter);
    _token.mint(_eve, 1);
  }

  function test_WhenBothPartiesAreVerified_TheTransferSucceedsAndPreflightAgrees() external {
    (bool _ok, bytes32 _reason) = _token.canTransfer(_alice, _bob, 10 ether);
    assertTrue(_ok);
    assertEq(_reason, Reasons.TRANSFER_OK);
    vm.prank(_alice);
    _token.transfer(_bob, 10 ether);
    assertEq(_token.balanceOf(_bob), 10 ether);
  }

  function test_WhenTheReceiverIsUnverified_TheTransferFailsAndPreflightAgrees() external {
    (bool _ok, bytes32 _reason) = _token.canTransfer(_alice, _eve, 1);
    assertFalse(_ok);
    assertEq(_reason, Reasons.RECEIVER_NOT_VERIFIED);
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_alice);
    _token.transfer(_eve, 1);
  }
}

contract IntentTokenIntegration_Enforcement is IntentTokenIntegrationTest {
  /// @dev Regression: a frozen, de-verified holder's tokens could be neither clawed back nor burned
  function test_WhenAHolderIsDeverified_TheirTokensCanBeClawedBackThenBurned() external {
    vm.prank(_agent);
    _token.setFrozen(_alice, 1000 ether);
    _identity.set(_alice, false);

    vm.prank(_agent);
    _token.forcedTransfer(_alice, _treasury, 1000 ether);
    assertEq(_token.balanceOf(_treasury), 1000 ether);
    assertEq(_token.getFrozen(_alice), 0);

    vm.prank(_burner);
    _token.burn(_treasury, 1000 ether);
    assertEq(_token.totalSupply(), 0);
  }

  function test_WhenForcingToAnUnverifiedAccount_ItIsRejected() external {
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _eve, 1);
  }

  function test_WhenPaused_OnlyForcedTransfersMoveUntilTheTimelockUnpauses() external {
    vm.prank(_guardian);
    _token.pause();

    vm.expectRevert(_rejected(Reasons.PAUSED));
    vm.prank(_alice);
    _token.transfer(_bob, 1);

    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, 1);

    vm.prank(_admin);
    _token.unpause();
    vm.prank(_alice);
    _token.transfer(_bob, 1);
    assertEq(_token.balanceOf(_bob), 2);
  }
}

contract IntentTokenIntegration_Intents is IntentTokenIntegrationTest {
  function test_WhenTheReceiverIsVerified_TheIntentSettles() external {
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_bob, 50 ether, keccak256('n1'));
    vm.prank(_executor);
    (bool _ok,) = _token.canExecute(_i, _sig);
    assertTrue(_ok);
    vm.prank(_executor);
    _token.executeTransfer(_i, _sig);
    assertEq(_token.balanceOf(_bob), 50 ether);
  }

  function test_WhenTheReceiverIsUnverified_TheIntentFailsAndPreflightAgrees() external {
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_eve, 1, keccak256('n2'));
    (bool _ok, bytes32 _reason) = _token.canExecute(_i, _sig);
    assertFalse(_ok);
    assertEq(_reason, Reasons.RECEIVER_NOT_VERIFIED);
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_executor);
    _token.executeTransfer(_i, _sig);
  }

  function test_WhenTheSignatureIsBad_PreflightAgreesWithTheRealStack() external {
    (ITransferIntent.TransferIntent memory _i,) = _signedIntent(_bob, 1, keccak256('n4'));
    (, uint256 _evePk) = makeAddrAndKey('eve');
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_evePk, _token.intentHash(_i));
    bytes memory _badSig = abi.encodePacked(_r, _s, _v);

    vm.prank(_executor);
    (bool _ok, bytes32 _reason) = _token.canExecute(_i, _badSig);
    assertFalse(_ok);
    assertEq(_reason, Reasons.BAD_SIGNATURE);
    vm.expectRevert(_rejected(Reasons.BAD_SIGNATURE));
    vm.prank(_executor);
    _token.executeTransfer(_i, _badSig);
  }

  function test_WhenTheSenderIsFrozen_TheIntentFailsAndPreflightAgrees() external {
    vm.prank(_agent);
    _token.setFrozen(_alice, 1000 ether);
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_bob, 1, keccak256('n3'));
    (bool _ok, bytes32 _reason) = _token.canExecute(_i, _sig);
    assertFalse(_ok);
    assertEq(_reason, Reasons.INSUFFICIENT_UNFROZEN);
  }
}

contract IntentTokenIntegration_Safety is IntentTokenIntegrationTest {
  function test_WhenARuleReentersTheToken_TheTransferReverts() external {
    MockReentrantRule _reentrant = new MockReentrantRule();
    vm.prank(_attester);
    _registry.attest(address(_reentrant).codehash, IPolicyRegistry.AttestKind.RULE, 'ipfs://mock');
    IComplianceRule[] memory _ruleSet = new IComplianceRule[](2);
    _ruleSet[0] = _identityRule;
    _ruleSet[1] = _reentrant;
    _installRules(_ruleSet);

    vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    vm.prank(_alice);
    _token.transfer(_bob, 1);
  }

  function test_WhenAnImplementationIsRedeployed_ItNeedsItsOwnAttestation() external {
    // UUPSUpgradeable stores address(this) in an immutable, so every implementation deployment has its own codehash.
    IntentToken _next = new IntentToken();
    assertNotEq(address(_next).codehash, address(_impl).codehash);
    assertFalse(_registry.isAttested(address(_next), IPolicyRegistry.AttestKind.IMPLEMENTATION));
  }

  function test_WhenUpgradedToAnAttestedImplementation_StateIsPreserved() external {
    IntentToken _next = new IntentToken();
    vm.prank(_attester);
    _registry.attest(address(_next).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, 'ipfs://impl-v2-review');
    vm.prank(_admin);
    _token.upgradeToAndCall(address(_next), '');
    assertEq(_token.balanceOf(_alice), 1000 ether);
    assertEq(_token.policyHook(), address(_hook));
  }
}

/// @dev Aderyn `contract-locks-ether` is a false positive for this implementation: no path accepts ETH
contract IntentTokenIntegration_Ether is IntentTokenIntegrationTest {
  function test_WhenEtherIsSentPlainly_ItReverts() external {
    vm.deal(_alice, 1 ether);
    vm.prank(_alice);
    (bool _ok,) = address(_token).call{value: 1}('');
    assertFalse(_ok, 'the proxy delegates to an implementation with no receive or payable fallback');
    assertEq(address(_token).balance, 0);
  }

  function test_WhenEtherIsAttachedToATokenFunction_ItReverts() external {
    vm.deal(_alice, 1 ether);
    vm.prank(_alice);
    (bool _ok,) = address(_token).call{value: 1}(abi.encodeCall(_token.transfer, (_bob, 0)));
    assertFalse(_ok, 'every implementation function is non-payable');
  }

  /// @dev The only payable entry point is UUPS `upgradeToAndCall`; even the upgrader cannot leave ETH behind
  function test_WhenTheUpgraderAttachesEther_TheUpgradeReverts() external {
    vm.deal(_admin, 1 ether);
    vm.prank(_admin);
    vm.expectRevert(ERC1967Utils.ERC1967NonPayable.selector);
    _token.upgradeToAndCall{value: 1}(address(_impl), '');

    vm.prank(_admin);
    vm.expectRevert(Errors.FailedCall.selector); // the delegated call is non-payable; OZ Address wraps the empty revert
    _token.upgradeToAndCall{value: 1}(address(_impl), abi.encodeCall(_token.decimals, ()));
    assertEq(address(_token).balance, 0);
  }
}
