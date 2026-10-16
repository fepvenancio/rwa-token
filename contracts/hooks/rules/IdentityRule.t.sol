// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IIdentityRule} from 'interfaces/IIdentityRule.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {IdentityRule} from 'contracts/hooks/rules/IdentityRule.sol';
import {Helpers} from 'contracts/test/Helpers.sol';

contract IdentityRuleUnitTest is Helpers {
  IdentityRule internal _rule;
  address internal _hook = makeAddr('hook');
  address internal _token;
  address internal _identity;
  address internal _from = makeAddr('from');
  address internal _to = makeAddr('to');

  function setUp() public virtual {
    _identity = _mockContract('identity');
    _token = _mockContract('token');
    _currentHook(_token, _hook);
    _rule = new IdentityRule(IIdentityRegistry(_identity));
  }

  function _currentHook(
    address _forToken,
    address _policyHook
  ) internal {
    vm.mockCall(_forToken, abi.encodeCall(IPolicyGated.policyHook, ()), abi.encode(_policyHook));
  }

  function _verified(
    address _user,
    bool _isVerified
  ) internal {
    vm.mockCall(_identity, abi.encodeCall(IIdentityRegistry.isVerified, (_user)), abi.encode(_isVerified));
  }

  function _ctx(
    IPolicyHook.TransferKind _kind,
    address _sender,
    address _receiver
  ) internal view returns (IPolicyHook.TransferContext memory _context) {
    _context = IPolicyHook.TransferContext({
      token: _token,
      from: _sender,
      to: _receiver,
      id: 0,
      amount: 1,
      operator: _sender,
      kind: _kind,
      ref: bytes32(0),
      deadline: 0,
      extra: ''
    });
  }

  /// @dev Maps a fuzzed seed onto TRANSFER or EXECUTED, the kinds that check both legs
  function _holderKind(
    uint8 _seed
  ) internal pure returns (IPolicyHook.TransferKind _kind) {
    _kind = IPolicyHook.TransferKind(bound(_seed, 0, 1));
  }
}

contract IdentityRuleUnit_Constructor is IdentityRuleUnitTest {
  function test_WhenIdentityIsZero_ItReverts() external {
    vm.expectRevert(IIdentityRule.IdentityRule_ZeroAddress.selector);
    new IdentityRule(IIdentityRegistry(address(0)));
  }

  function test_WhenValid_ItSetsTheIdentityRegistry() external view {
    assertEq(address(_rule.IDENTITY()), _identity);
  }

  /// @dev The codehash no longer depends on any hook, so one attestation covers every token using this configuration
  function test_WhenDeployedTwiceWithTheSameRegistry_ItKeepsTheCodehash() external {
    IdentityRule _twin = new IdentityRule(IIdentityRegistry(_identity));
    assertEq(address(_twin).codehash, address(_rule).codehash);
  }
}

contract IdentityRuleUnit_Check is IdentityRuleUnitTest {
  function test_WhenHolderMovementAndSenderUnverified_ItReturnsSenderNotVerified(
    uint8 _seed
  ) external {
    _verified(_from, false);
    _verified(_to, true);
    assertEq(_rule.check(_ctx(_holderKind(_seed), _from, _to)), Reasons.SENDER_NOT_VERIFIED);
  }

  function test_WhenHolderMovementAndReceiverUnverified_ItReturnsReceiverNotVerified(
    uint8 _seed
  ) external {
    _verified(_from, true);
    _verified(_to, false);
    assertEq(_rule.check(_ctx(_holderKind(_seed), _from, _to)), Reasons.RECEIVER_NOT_VERIFIED);
  }

  function test_WhenHolderMovementAndBothVerified_ItReturnsOk(
    uint8 _seed
  ) external {
    _verified(_from, true);
    _verified(_to, true);
    assertEq(_rule.check(_ctx(_holderKind(_seed), _from, _to)), Reasons.TRANSFER_OK);
  }

  function test_WhenMintToVerified_ItReturnsOkWithoutCheckingTheSender() external {
    _mockAndExpect(_identity, abi.encodeCall(IIdentityRegistry.isVerified, (_to)), abi.encode(true));
    vm.expectCall(_identity, abi.encodeCall(IIdentityRegistry.isVerified, (address(0))), 0);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to)), Reasons.TRANSFER_OK);
  }

  function test_WhenMintToUnverified_ItReturnsReceiverNotVerified() external {
    _verified(_to, false);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to)), Reasons.RECEIVER_NOT_VERIFIED);
  }

  /// @dev Regression: clawback from a de-verified holder was rejected with SENDER_NOT_VERIFIED
  function test_WhenForcedFromUnverifiedToVerified_ItReturnsOk() external {
    _verified(_from, false);
    _verified(_to, true);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.FORCED, _from, _to)), Reasons.TRANSFER_OK);
  }

  function test_WhenForcedToUnverified_ItReturnsReceiverNotVerified() external {
    _verified(_from, true);
    _verified(_to, false);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.FORCED, _from, _to)), Reasons.RECEIVER_NOT_VERIFIED);
  }

  function test_WhenBurnFromUnverified_ItReturnsSenderNotVerified() external {
    _verified(_from, false);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.BURN, _from, address(0))), Reasons.SENDER_NOT_VERIFIED);
  }

  function test_WhenBurnFromVerified_ItReturnsOkWithoutCheckingTheReceiver() external {
    _mockAndExpect(_identity, abi.encodeCall(IIdentityRegistry.isVerified, (_from)), abi.encode(true));
    vm.expectCall(_identity, abi.encodeCall(IIdentityRegistry.isVerified, (address(0))), 0);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.BURN, _from, address(0))), Reasons.TRANSFER_OK);
  }
}

contract IdentityRuleUnit_After is IdentityRuleUnitTest {
  function test_WhenCallerIsNotTheTokensHook_ItReverts() external {
    address _caller = makeAddr('stranger');
    vm.expectRevert(abi.encodeWithSelector(IComplianceRule.ComplianceRule_OnlyHook.selector, _caller));
    vm.prank(_caller);
    _rule.after_(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to));
  }

  function test_WhenCallerIsTheTokensHook_ItAsksTheTokenAndSucceeds() external {
    vm.expectCall(_token, abi.encodeCall(IPolicyGated.policyHook, ()));
    vm.prank(_hook);
    _rule.after_(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to));
  }

  /// @dev One instance serves many tokens: each token's own hook is accepted, but only for that token's context
  function test_WhenSharedByTwoTokens_EachHookIsAcceptedOnlyForItsOwnToken() external {
    address _otherToken = _mockContract('otherToken');
    address _otherHook = makeAddr('otherHook');
    _currentHook(_otherToken, _otherHook);
    IPolicyHook.TransferContext memory _otherCtx = _ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to);
    _otherCtx.token = _otherToken;

    vm.prank(_otherHook);
    _rule.after_(_otherCtx);

    vm.expectRevert(abi.encodeWithSelector(IComplianceRule.ComplianceRule_OnlyHook.selector, _otherHook));
    vm.prank(_otherHook);
    _rule.after_(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to));
  }

  /// @dev Replacing a token's hook needs no rule redeploy, and the replaced hook loses access at once
  function test_WhenTheTokenReplacesItsHook_OnlyTheNewHookIsAccepted() external {
    address _newHook = makeAddr('newHook');
    _currentHook(_token, _newHook);

    vm.prank(_newHook);
    _rule.after_(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to));

    vm.expectRevert(abi.encodeWithSelector(IComplianceRule.ComplianceRule_OnlyHook.selector, _hook));
    vm.prank(_hook);
    _rule.after_(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to));
  }
}

contract IdentityRuleUnit_Metadata is IdentityRuleUnitTest {
  function test_WhenQueried_ItReturnsItsMetadata() external view {
    assertEq(_rule.ruleId(), keccak256('IdentityRule.v1'));
    assertFalse(_rule.wantsAfter());
    assertTrue(_rule.supportsInterface(type(IComplianceRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(IERC165).interfaceId));
  }
}
