// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyGatedCore} from 'interfaces/IPolicyGatedCore.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {ExecutedOnlyRule} from 'contracts/hooks/rules/ExecutedOnlyRule.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';

contract ExecutedOnlyRuleUnit is Helpers {
  ExecutedOnlyRule internal _rule;
  address internal _token = makeAddr('token');
  address internal _from = makeAddr('from');
  address internal _to = makeAddr('to');

  function setUp() public {
    _rule = new ExecutedOnlyRule();
  }

  function _ctx(
    IPolicyHook.TransferKind _kind,
    uint256 _amount
  ) internal view returns (IPolicyHook.TransferContext memory _context) {
    _context = IPolicyHook.TransferContext({
      token: _token, from: _from, to: _to, id: 0, amount: _amount, operator: _from, kind: _kind, extra: ''
    });
  }

  function testFuzz_APlainTransferIsRefusedAtAnyAmount(
    uint256 _amount
  ) external view {
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER, _amount)), Reasons.TRANSFER_NOT_EXECUTED);
  }

  function test_EveryOtherKindPasses() external view {
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.EXECUTED, 1)), Reasons.TRANSFER_OK);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.FORCED, 1)), Reasons.TRANSFER_OK);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.MINT, 1)), Reasons.TRANSFER_OK);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.BURN, 1)), Reasons.TRANSFER_OK);
  }

  function test_ItHasNoAccountLevelOpinion() external view {
    assertEq(_rule.checkSend(_token, _from), Reasons.TRANSFER_OK);
    assertEq(_rule.checkReceive(_token, _to), Reasons.TRANSFER_OK);
    assertFalse(_rule.wantsAfter());
    assertEq(_rule.ruleId(), keccak256('ExecutedOnlyRule.v1'));
    assertTrue(_rule.supportsInterface(type(IComplianceRule).interfaceId));
  }
}

/// @notice In a real hook on a real token: holders move only by signed intents
contract ExecutedOnlyRuleIntegration is Helpers {
  IntentToken internal _token;
  address internal _guardian = makeAddr('guardian');
  address internal _minter = makeAddr('minter');
  address internal _executor = makeAddr('executor');
  address internal _agent = makeAddr('agent');
  address internal _bob = makeAddr('bob');
  address internal _alice;
  uint256 internal _aliceKey;

  function setUp() public {
    (_alice, _aliceKey) = makeAddrAndKey('alice');
    PolicyRegistry _registry = new PolicyRegistry(address(this), address(this));
    ExecutedOnlyRule _rule = new ExecutedOnlyRule();
    _registry.attest(address(_rule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    ComplianceHook _hook = new ComplianceHook(_registry);
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    IntentToken _impl = new IntentToken();
    _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    IComplianceRule[] memory _rules = new IComplianceRule[](1);
    _rules[0] = _rule;
    ProxyDeployer _deployer = new ProxyDeployer(address(this), _registry);
    _token = IntentToken(
      _deployer.deploy(
        'EXE',
        address(_impl),
        abi.encodeCall(
          IntentToken.initialize,
          ('Executed', 'EXE', 18, address(this), _guardian, address(_registry), address(_hook), _rules)
        ),
        address(_hook),
        _rules
      )
    );
    _token.grantRole(_token.MINTER_ROLE(), _minter);
    _token.grantRole(_token.EXECUTOR_ROLE(), _executor);
    _token.grantRole(_token.AGENT_ROLE(), _agent);
    vm.prank(_minter);
    _token.mint(_alice, 100);
  }

  function test_APlainTransferIsRefusedAndThePreFlightSaysSo() external {
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(_alice, _bob, 1);
    assertFalse(_ok);
    assertEq(_reason, Reasons.TRANSFER_NOT_EXECUTED);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_TransferRejected.selector, Reasons.TRANSFER_NOT_EXECUTED)
    );
    vm.prank(_alice);
    _token.transfer(_bob, 1);
  }

  function test_ASignedIntentMovesAndThePreFlightAgrees() external {
    ITransferIntent.TransferIntent memory _intent = ITransferIntent.TransferIntent({
      from: _alice,
      to: _bob,
      amount: 7,
      nonce: keccak256('n'),
      deadline: block.timestamp + 1 days,
      ref: keccak256('the issuer message'),
      executor: address(0),
      validAfter: 0,
      considerationToken: address(0),
      considerationAmount: 0
    });
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_aliceKey, _token.intentHash(_intent));
    bytes memory _sig = abi.encodePacked(_r, _s, _v);
    (bool _ok,) = _token.canExecute(_intent, _sig, _executor);
    assertTrue(_ok);
    vm.prank(_executor);
    _token.executeTransfer(_intent, _sig);
    assertEq(_token.balanceOf(_bob), 7);
  }

  function test_AForcedMoveStillPasses() external {
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, 3);
    assertEq(_token.balanceOf(_bob), 3);
  }
}
