// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {ICredentialRegistry} from 'interfaces/ICredentialRegistry.sol';
import {ICredentialRule} from 'interfaces/ICredentialRule.sol';
import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';
import {Quals} from 'interfaces/Quals.sol';

import {CredentialRule} from 'contracts/hooks/rules/CredentialRule.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockStatefulToken} from 'contracts/test/MockStatefulToken.sol';

contract CredentialRuleUnitTest is Helpers {
  bytes32 internal constant _DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 internal constant _BURNER_ROLE = keccak256('BURNER_ROLE');

  CredentialRule internal _rule;
  address internal _registry;
  address internal _token;
  address internal _admin = makeAddr('admin');
  address internal _stranger = makeAddr('stranger');
  address internal _from = makeAddr('from');
  address internal _to = makeAddr('to');
  address internal _burner = makeAddr('burner');

  function setUp() public virtual {
    _registry = _mockContract('registry');
    _token = _mockContract('token');
    _admins(_token);
    vm.mockCall(_token, abi.encodeCall(IAccessControl.hasRole, (_BURNER_ROLE, _burner)), abi.encode(true));
    vm.mockCall(_token, abi.encodeCall(IAccessControl.hasRole, (_BURNER_ROLE, _from)), abi.encode(false));
    _rule = new CredentialRule(ICredentialRegistry(_registry));
    _policy(Quals.KYC, 0, 0, 1);
  }

  function _admins(
    address _forToken
  ) internal {
    vm.mockCall(_forToken, abi.encodeCall(IAccessControl.hasRole, (_DEFAULT_ADMIN_ROLE, _admin)), abi.encode(true));
    vm.mockCall(_forToken, abi.encodeCall(IAccessControl.hasRole, (_DEFAULT_ADMIN_ROLE, _stranger)), abi.encode(false));
  }

  function _policy(
    uint32 _requireAll,
    uint32 _requireAny,
    uint32 _forbidAny,
    uint64 _attesters
  ) internal {
    vm.prank(_admin);
    _rule.setPolicy(_token, _requireAll, _requireAny, _forbidAny, _attesters);
  }

  function _standing(
    address _who,
    ICredentialRegistry.Status _status,
    uint32 _quals,
    uint8 _attester
  ) internal {
    vm.mockCall(
      _registry, abi.encodeCall(ICredentialRegistry.profileOf, (_who)), abi.encode(_status, _quals, _attester)
    );
  }

  function _stand(
    address _who,
    ICredentialRegistry.Status _status
  ) internal {
    _standing(_who, _status, Quals.KYC, 0);
  }

  function _ctx(
    IERC8473Policy.TransferKind _kind
  ) internal view returns (IERC8473Policy.TransferContext memory _context) {
    _context = IERC8473Policy.TransferContext({
      token: _token,
      from: _kind == IERC8473Policy.TransferKind.MINT ? address(0) : _from,
      to: _kind == IERC8473Policy.TransferKind.BURN ? address(0) : _to,
      tokenId: 0,
      amount: 1,
      operator: _kind == IERC8473Policy.TransferKind.BURN ? _burner : _from,
      kind: _kind,
      data: ''
    });
  }

  function _call(
    address _who
  ) internal pure returns (bytes memory _data) {
    _data = abi.encodeCall(ICredentialRegistry.profileOf, (_who));
  }

  /// @dev The kind of each uint8 in 0..4, as the hook enum orders them
  function _kind(
    uint8 _seed
  ) internal pure returns (IERC8473Policy.TransferKind _k) {
    _k = IERC8473Policy.TransferKind(bound(_seed, 0, 4));
  }

  function _statusOf(
    uint8 _seed
  ) internal pure returns (ICredentialRegistry.Status _s) {
    _s = ICredentialRegistry.Status(bound(_seed, 0, 4));
  }
}

contract CredentialRuleUnit_Constructor is CredentialRuleUnitTest {
  function test_WhenTheRegistryIsZero_ItReverts() external {
    vm.expectRevert(ICredentialRule.CredentialRule_ZeroAddress.selector);
    new CredentialRule(ICredentialRegistry(address(0)));
  }

  function test_WhenDeployed_ItExposesTheRegistryAndTheRuleId() external view {
    assertEq(address(_rule.REGISTRY()), _registry);
    assertEq(_rule.ruleId(), keccak256('CredentialRule.v1'));
    assertFalse(_rule.wantsAfter());
  }

  function test_WhenAskedForInterfaces_ItAnswersTheRuleTheComplianceRuleAndErc165() external view {
    assertTrue(_rule.supportsInterface(type(ICredentialRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(IComplianceRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(IERC165).interfaceId));
    assertFalse(_rule.supportsInterface(0xffffffff));
  }
}

contract CredentialRuleUnit_SetPolicy is CredentialRuleUnitTest {
  function test_WhenCallerIsNotTheTokensAdmin_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(ICredentialRule.CredentialRule_OnlyTokenAdmin.selector, _token, _stranger));
    vm.prank(_stranger);
    _rule.setPolicy(_token, 1, 0, 0, 1);
  }

  function test_WhenCallerIsTheTokensAdmin_ItStoresAndEmits(
    uint32 _all,
    uint32 _any,
    uint32 _forbid,
    uint64 _attesters
  ) external {
    vm.expectEmit(address(_rule));
    emit ICredentialRule.PolicySet(_token, _all, _any, _forbid, _attesters);
    _policy(_all, _any, _forbid, _attesters);

    ICredentialRule.Policy memory _p = _rule.policyOf(_token);
    assertEq(_p.requireAll, _all);
    assertEq(_p.requireAny, _any);
    assertEq(_p.forbidAny, _forbid);
    assertEq(_p.attesters, _attesters);
  }

  function test_WhenSetAgain_ItReplacesTheWholePolicy() external {
    _policy(Quals.KYC | Quals.CUSTOMER, Quals.PROFESSIONAL, Quals.FUND, 7);
    _policy(Quals.KYC, 0, 0, 1);
    ICredentialRule.Policy memory _p = _rule.policyOf(_token);
    assertEq(_p.requireAll, Quals.KYC);
    assertEq(_p.requireAny, 0);
    assertEq(_p.forbidAny, 0);
    assertEq(_p.attesters, 1);
  }

  function test_WhenAFakeTokenAuthorisesAnAttacker_OnlyTheFakeTokensPolicyChanges() external {
    address _fakeToken = _mockContract('fakeToken');
    address _attacker = makeAddr('attacker');
    vm.mockCall(_fakeToken, abi.encodeCall(IAccessControl.hasRole, (_DEFAULT_ADMIN_ROLE, _attacker)), abi.encode(true));

    vm.prank(_attacker);
    _rule.setPolicy(_fakeToken, 0, 0, 0, type(uint64).max);

    assertEq(_rule.policyOf(_fakeToken).attesters, type(uint64).max);
    assertEq(_rule.policyOf(_token).attesters, 1);
    assertEq(_rule.policyOf(_token).requireAll, Quals.KYC);
  }

  function test_WhenNeverSet_ThePolicyIsAllZero() external view {
    ICredentialRule.Policy memory _p = _rule.policyOf(address(0xBEEF));
    assertEq(_p.requireAll, 0);
    assertEq(_p.requireAny, 0);
    assertEq(_p.forbidAny, 0);
    assertEq(_p.attesters, 0);
  }
}

contract CredentialRuleUnit_Sender is CredentialRuleUnitTest {
  function test_WhenTheSenderCanLeave_ItIsOk(
    uint8 _kindSeed,
    uint8 _statusSeed
  ) external {
    IERC8473Policy.TransferKind _k = IERC8473Policy.TransferKind(bound(_kindSeed, 0, 1)); // TRANSFER, EXECUTED
    ICredentialRegistry.Status _s = ICredentialRegistry.Status(bound(_statusSeed, 1, 2)); // ACTIVE, EXIT_ONLY
    _stand(_from, _s);
    _stand(_to, ICredentialRegistry.Status.ACTIVE);
    assertEq(_rule.check(_ctx(_k)), Reasons.TRANSFER_OK);
  }

  function test_WhenTheSenderIsLapsed_ItCanStillSendAndBurn() external {
    _stand(_from, ICredentialRegistry.Status.LAPSED);
    _stand(_to, ICredentialRegistry.Status.ACTIVE);
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.TRANSFER)), Reasons.TRANSFER_OK);
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.EXECUTED)), Reasons.TRANSFER_OK);
    IERC8473Policy.TransferContext memory _burn = _ctx(IERC8473Policy.TransferKind.BURN);
    _burn.operator = _from; // a holder or vault burn, not an enforcement one
    assertEq(_rule.check(_burn), Reasons.TRANSFER_OK);
  }

  function test_WhenTheSenderIsNoneOrBlocked_ItIsRejected(
    uint8 _kindSeed,
    bool _blocked
  ) external {
    IERC8473Policy.TransferKind _k = IERC8473Policy.TransferKind(bound(_kindSeed, 0, 1));
    _stand(_from, _blocked ? ICredentialRegistry.Status.BLOCKED : ICredentialRegistry.Status.NONE);
    _stand(_to, ICredentialRegistry.Status.ACTIVE);
    assertEq(_rule.check(_ctx(_k)), Reasons.SENDER_NOT_ELIGIBLE);
  }

  function test_WhenAHolderBurnsAndTheSenderIsNoneOrBlocked_ItIsRejected(
    bool _blocked
  ) external {
    _stand(_from, _blocked ? ICredentialRegistry.Status.BLOCKED : ICredentialRegistry.Status.NONE);
    IERC8473Policy.TransferContext memory _burn = _ctx(IERC8473Policy.TransferKind.BURN);
    _burn.operator = _from;
    assertEq(_rule.check(_burn), Reasons.SENDER_NOT_ELIGIBLE);
  }

  function test_WhenBothLegsAreBad_TheSenderIsReportedFirst() external {
    _stand(_from, ICredentialRegistry.Status.NONE);
    _stand(_to, ICredentialRegistry.Status.NONE);
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.TRANSFER)), Reasons.SENDER_NOT_ELIGIBLE);
  }
}

contract CredentialRuleUnit_EnforcementBurn is CredentialRuleUnitTest {
  function test_WhenTheBurnerBurnsFromAnyStanding_ItIsOk(
    uint8 _statusSeed
  ) external {
    _stand(_from, _statusOf(_statusSeed));
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.BURN)), Reasons.TRANSFER_OK);
  }

  function test_WhenTheSenderCanLeave_TheBurnerRoleIsNotLookedUp() external {
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    vm.expectCall(_token, abi.encodeCall(IAccessControl.hasRole, (_BURNER_ROLE, _burner)), 0);
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.BURN)), Reasons.TRANSFER_OK);
  }

  function test_WhenTheSenderCannotLeave_TheBurnerRoleIsLookedUpOnce() external {
    _stand(_from, ICredentialRegistry.Status.BLOCKED);
    vm.expectCall(_token, abi.encodeCall(IAccessControl.hasRole, (_BURNER_ROLE, _burner)), 1);
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.BURN)), Reasons.TRANSFER_OK);
  }

  function test_WhenTheOperatorIsNotTheBurner_TheBurnIsRejected() external {
    _stand(_from, ICredentialRegistry.Status.BLOCKED);
    IERC8473Policy.TransferContext memory _burn = _ctx(IERC8473Policy.TransferKind.BURN);
    _burn.operator = _from;
    assertEq(_rule.check(_burn), Reasons.SENDER_NOT_ELIGIBLE);
  }

  function test_WhenTheKindIsNotBurn_TheBurnerRoleNeverHelps(
    uint8 _kindSeed
  ) external {
    IERC8473Policy.TransferKind _k = IERC8473Policy.TransferKind(bound(_kindSeed, 0, 1));
    _stand(_from, ICredentialRegistry.Status.BLOCKED);
    _stand(_to, ICredentialRegistry.Status.ACTIVE);
    IERC8473Policy.TransferContext memory _c = _ctx(_k);
    _c.operator = _burner;
    vm.expectCall(_token, abi.encodeCall(IAccessControl.hasRole, (_BURNER_ROLE, _burner)), 0);
    assertEq(_rule.check(_c), Reasons.SENDER_NOT_ELIGIBLE);
  }
}

contract CredentialRuleUnit_Receiver is CredentialRuleUnitTest {
  function test_WhenTheReceiverIsActiveAndEligible_ItIsOkForEveryKindThatChecksIt(
    uint8 _kindSeed
  ) external {
    uint8 _pick = uint8(bound(_kindSeed, 0, 3));
    IERC8473Policy.TransferKind _k = _pick == 3 ? IERC8473Policy.TransferKind.MINT : IERC8473Policy.TransferKind(_pick);
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    _stand(_to, ICredentialRegistry.Status.ACTIVE);
    assertEq(_rule.check(_ctx(_k)), Reasons.TRANSFER_OK);
  }

  function test_WhenTheReceiverIsNoneBlockedOrExitOnly_ItIsRejectedAsNotVerified(
    uint8 _kindSeed,
    uint8 _statusSeed
  ) external {
    IERC8473Policy.TransferKind _k = IERC8473Policy.TransferKind(bound(_kindSeed, 0, 3));
    uint256 _pick = bound(_statusSeed, 0, 2);
    ICredentialRegistry.Status _s = _pick == 0
      ? ICredentialRegistry.Status.NONE
      : (_pick == 1 ? ICredentialRegistry.Status.EXIT_ONLY : ICredentialRegistry.Status.BLOCKED);
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    _stand(_to, _s);
    assertEq(_rule.check(_ctx(_k)), Reasons.RECEIVER_NOT_VERIFIED);
  }

  function test_WhenTheReceiverIsLapsed_ItIsRejectedAsExpired(
    uint8 _kindSeed
  ) external {
    IERC8473Policy.TransferKind _k = IERC8473Policy.TransferKind(bound(_kindSeed, 0, 3));
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    _stand(_to, ICredentialRegistry.Status.LAPSED);
    assertEq(_rule.check(_ctx(_k)), Reasons.CREDENTIAL_EXPIRED);
  }

  function test_WhenAForcedMoveHasNoSender_TheReceiverIsStillChecked() external {
    IERC8473Policy.TransferContext memory _c = _ctx(IERC8473Policy.TransferKind.FORCED);
    _c.from = address(0); // an enforcement mint
    _stand(_to, ICredentialRegistry.Status.ACTIVE);
    assertEq(_rule.check(_c), Reasons.TRANSFER_OK);
    _stand(_to, ICredentialRegistry.Status.BLOCKED);
    assertEq(_rule.check(_c), Reasons.RECEIVER_NOT_VERIFIED);
  }

  function test_WhenTheAmountIsZero_TheLegsAreStillChecked() external {
    IERC8473Policy.TransferContext memory _c = _ctx(IERC8473Policy.TransferKind.TRANSFER);
    _c.amount = 0;
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    _stand(_to, ICredentialRegistry.Status.NONE);
    assertEq(_rule.check(_c), Reasons.RECEIVER_NOT_VERIFIED);
    _stand(_to, ICredentialRegistry.Status.ACTIVE);
    assertEq(_rule.check(_c), Reasons.TRANSFER_OK);
  }
}

contract CredentialRuleUnit_Policy is CredentialRuleUnitTest {
  function _receiver(
    uint32 _quals,
    uint8 _attester
  ) internal returns (bytes32 _reason) {
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    _standing(_to, ICredentialRegistry.Status.ACTIVE, _quals, _attester);
    _reason = _rule.check(_ctx(IERC8473Policy.TransferKind.TRANSFER));
  }

  function test_WhenARequiredBitIsMissing_ItIsNotEligible() external {
    _policy(Quals.KYC | Quals.CUSTOMER, 0, 0, 1);
    assertEq(_receiver(Quals.KYC, 0), Reasons.RECEIVER_NOT_ELIGIBLE);
    assertEq(_receiver(Quals.CUSTOMER, 0), Reasons.RECEIVER_NOT_ELIGIBLE);
    assertEq(_receiver(Quals.KYC | Quals.CUSTOMER, 0), Reasons.TRANSFER_OK);
    assertEq(_receiver(Quals.KYC | Quals.CUSTOMER | Quals.LICENSED, 0), Reasons.TRANSFER_OK);
  }

  function test_WhenNoneOfTheAnyBitsIsPresent_ItIsNotEligible() external {
    _policy(Quals.KYC, Quals.PROFESSIONAL | Quals.INSTITUTIONAL, 0, 1);
    assertEq(_receiver(Quals.KYC, 0), Reasons.RECEIVER_NOT_ELIGIBLE);
    assertEq(_receiver(Quals.KYC | Quals.PROFESSIONAL, 0), Reasons.TRANSFER_OK);
    assertEq(_receiver(Quals.KYC | Quals.INSTITUTIONAL, 0), Reasons.TRANSFER_OK);
    assertEq(_receiver(Quals.KYC | Quals.PROFESSIONAL | Quals.INSTITUTIONAL, 0), Reasons.TRANSFER_OK);
  }

  function test_WhenAnyIsZero_ThatTestIsIgnored() external {
    _policy(Quals.KYC, 0, 0, 1);
    assertEq(_receiver(Quals.KYC, 0), Reasons.TRANSFER_OK);
  }

  function test_WhenAForbiddenBitIsPresent_ItIsNotEligible() external {
    _policy(Quals.KYC, 0, Quals.FUND, 1);
    assertEq(_receiver(Quals.KYC | Quals.FUND, 0), Reasons.RECEIVER_NOT_ELIGIBLE);
    assertEq(_receiver(Quals.KYC | Quals.LICENSED, 0), Reasons.TRANSFER_OK);
  }

  function test_WhenTheAttesterIsNotTrusted_ItIsNotEligible() external {
    _policy(Quals.KYC, 0, 0, uint64(1) << 1);
    assertEq(_receiver(Quals.KYC, 0), Reasons.RECEIVER_NOT_ELIGIBLE);
    assertEq(_receiver(Quals.KYC, 1), Reasons.TRANSFER_OK);
    assertEq(_receiver(Quals.KYC, 2), Reasons.RECEIVER_NOT_ELIGIBLE);
  }

  function test_WhenTheAttesterIdIsTheHighestBit_ItWorks() external {
    _policy(Quals.KYC, 0, 0, uint64(1) << 63);
    assertEq(_receiver(Quals.KYC, 63), Reasons.TRANSFER_OK);
    assertEq(_receiver(Quals.KYC, 62), Reasons.RECEIVER_NOT_ELIGIBLE);
  }

  function test_WhenAnyPolicyAndReceiverAreFuzzed_ItMatchesTheDefinition(
    uint32 _all,
    uint32 _any,
    uint32 _forbid,
    uint64 _attesters,
    uint32 _quals,
    uint8 _attester
  ) external {
    _attester = uint8(bound(_attester, 0, 63));
    _policy(_all, _any, _forbid, _attesters);
    bool _eligible = _attesters != 0 && (_attesters >> _attester) & 1 == 1 && _quals & _all == _all
      && (_any == 0 || _quals & _any != 0) && _quals & _forbid == 0;
    assertEq(_receiver(_quals, _attester), _eligible ? Reasons.TRANSFER_OK : Reasons.RECEIVER_NOT_ELIGIBLE);
  }
}

contract CredentialRuleUnit_Unconfigured is CredentialRuleUnitTest {
  address internal _bareToken;

  function setUp() public override {
    super.setUp();
    _bareToken = _mockContract('bareToken');
    vm.mockCall(_bareToken, abi.encodeCall(IAccessControl.hasRole, (_BURNER_ROLE, _burner)), abi.encode(true));
    vm.mockCall(_bareToken, abi.encodeCall(IAccessControl.hasRole, (_BURNER_ROLE, _from)), abi.encode(false));
  }

  function _bare(
    IERC8473Policy.TransferKind _k
  ) internal view returns (IERC8473Policy.TransferContext memory _c) {
    _c = _ctx(_k);
    _c.token = _bareToken;
  }

  function test_WhenTheTokenHasNoPolicy_NoReceiverIsAdmitted(
    uint8 _statusSeed
  ) external {
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    _stand(_to, _statusOf(_statusSeed));
    assertEq(_rule.check(_bare(IERC8473Policy.TransferKind.TRANSFER)), Reasons.RECEIVER_NOT_ELIGIBLE);
    assertEq(_rule.check(_bare(IERC8473Policy.TransferKind.MINT)), Reasons.RECEIVER_NOT_ELIGIBLE);
    assertEq(_rule.check(_bare(IERC8473Policy.TransferKind.FORCED)), Reasons.RECEIVER_NOT_ELIGIBLE);
  }

  function test_WhenTheTokenHasNoPolicy_HoldersCanStillBurnAndExit() external {
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    IERC8473Policy.TransferContext memory _burn = _bare(IERC8473Policy.TransferKind.BURN);
    _burn.operator = _from;
    assertEq(_rule.check(_burn), Reasons.TRANSFER_OK);
  }

  function test_WhenAPolicyIsRemoved_ReceiversAreRejectedAgain() external {
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    _stand(_to, ICredentialRegistry.Status.ACTIVE);
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.TRANSFER)), Reasons.TRANSFER_OK);
    _policy(Quals.KYC, 0, 0, 0);
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.TRANSFER)), Reasons.RECEIVER_NOT_ELIGIBLE);
  }
}

contract CredentialRuleUnit_Legs is CredentialRuleUnitTest {
  function test_WhenMinting_OnlyTheReceiverIsRead() external {
    _stand(_to, ICredentialRegistry.Status.ACTIVE);
    vm.expectCall(_registry, _call(_to), 1);
    vm.expectCall(_registry, _call(address(0)), 0);
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.MINT)), Reasons.TRANSFER_OK);
  }

  function test_WhenBurning_OnlyTheSenderIsRead() external {
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    vm.expectCall(_registry, _call(_from), 1);
    vm.expectCall(_registry, _call(address(0)), 0);
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.BURN)), Reasons.TRANSFER_OK);
  }

  function test_WhenForcing_OnlyTheReceiverIsRead() external {
    _stand(_to, ICredentialRegistry.Status.ACTIVE);
    vm.expectCall(_registry, _call(_to), 1);
    vm.expectCall(_registry, _call(_from), 0);
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.FORCED)), Reasons.TRANSFER_OK);
  }

  function test_WhenTransferring_BothLegsAreReadOnce(
    uint8 _kindSeed
  ) external {
    IERC8473Policy.TransferKind _k = IERC8473Policy.TransferKind(bound(_kindSeed, 0, 1));
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    _stand(_to, ICredentialRegistry.Status.ACTIVE);
    vm.expectCall(_registry, _call(_from), 1);
    vm.expectCall(_registry, _call(_to), 1);
    assertEq(_rule.check(_ctx(_k)), Reasons.TRANSFER_OK);
  }

  function test_WhenTheSenderFails_TheReceiverIsNotRead() external {
    _stand(_from, ICredentialRegistry.Status.NONE);
    vm.expectCall(_registry, _call(_to), 0);
    assertEq(_rule.check(_ctx(IERC8473Policy.TransferKind.TRANSFER)), Reasons.SENDER_NOT_ELIGIBLE);
  }
}

contract CredentialRuleUnit_Model is CredentialRuleUnitTest {
  function _expected(
    IERC8473Policy.TransferKind _k,
    ICredentialRegistry.Status _sender,
    ICredentialRegistry.Status _receiver,
    bool _isBurner
  ) internal pure returns (bytes32 _reason) {
    bool _checksSender = _k == IERC8473Policy.TransferKind.TRANSFER || _k == IERC8473Policy.TransferKind.EXECUTED
      || _k == IERC8473Policy.TransferKind.BURN;
    if (_checksSender) {
      bool _canLeave = _sender == ICredentialRegistry.Status.ACTIVE || _sender == ICredentialRegistry.Status.EXIT_ONLY
        || _sender == ICredentialRegistry.Status.LAPSED;
      bool _enforcement = _k == IERC8473Policy.TransferKind.BURN && _isBurner;
      if (!_canLeave && !_enforcement) return Reasons.SENDER_NOT_ELIGIBLE;
    }
    if (_k != IERC8473Policy.TransferKind.BURN) {
      if (_receiver == ICredentialRegistry.Status.LAPSED) return Reasons.CREDENTIAL_EXPIRED;
      if (_receiver != ICredentialRegistry.Status.ACTIVE) return Reasons.RECEIVER_NOT_VERIFIED;
    }
    _reason = Reasons.TRANSFER_OK;
  }

  function test_WhenKindStandingsAndOperatorAreFuzzed_ItMatchesTheTable(
    uint8 _kindSeed,
    uint8 _senderSeed,
    uint8 _receiverSeed,
    bool _isBurner
  ) external {
    IERC8473Policy.TransferKind _k = _kind(_kindSeed);
    ICredentialRegistry.Status _sender = _statusOf(_senderSeed);
    ICredentialRegistry.Status _receiver = _statusOf(_receiverSeed);
    _stand(_from, _sender);
    _stand(_to, _receiver);
    IERC8473Policy.TransferContext memory _c = _ctx(_k);
    _c.operator = _isBurner ? _burner : _from;
    assertEq(_rule.check(_c), _expected(_k, _sender, _receiver, _isBurner));
  }
}

/// @dev Aderyn `reentrancy-state-change` is a false positive: the token is read through STATICCALL
contract CredentialRuleUnit_TokenCallsAreStatic is CredentialRuleUnitTest {
  function test_WhenTheTokenTriesToWriteDuringTheAdminCheck_SetPolicyReverts() external {
    MockStatefulToken _stateful = new MockStatefulToken();
    _stateful.hasRole(_DEFAULT_ADMIN_ROLE, _admin); // control: the same read writes when called with CALL
    assertEq(_stateful.writes(), 1);

    vm.expectRevert(bytes('')); // a write inside a STATICCALL reverts with empty data, bubbled by the rule
    vm.prank(_admin);
    _rule.setPolicy(address(_stateful), 1, 0, 0, 1);
    assertEq(_rule.policyOf(address(_stateful)).attesters, 0);
  }

  function test_WhenTheTokenTriesToWriteDuringTheBurnerCheck_CheckReverts() external {
    MockStatefulToken _stateful = new MockStatefulToken();
    _stand(_from, ICredentialRegistry.Status.BLOCKED);
    IERC8473Policy.TransferContext memory _c = _ctx(IERC8473Policy.TransferKind.BURN);
    _c.token = address(_stateful);
    vm.expectRevert(bytes(''));
    _rule.check(_c);
    assertEq(_stateful.writes(), 0);
  }

  function test_WhenCalledWithStaticcall_CheckSucceeds() external {
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    _stand(_to, ICredentialRegistry.Status.ACTIVE);
    (bool _ok, bytes memory _ret) =
      address(_rule).staticcall(abi.encodeCall(_rule.check, (_ctx(IERC8473Policy.TransferKind.TRANSFER))));
    assertTrue(_ok);
    assertEq(abi.decode(_ret, (bytes32)), Reasons.TRANSFER_OK);
  }
}

/// @dev The account-level probes (`canSend` and `canReceive` on the token) must agree with `check`: a probe that rejects
///      an account means `check` rejects every movement of a kind the rule does not exempt on that side
contract CredentialRuleUnit_TheTokensOwnAddress is CredentialRuleUnitTest {
  function _standingOfTheToken(
    uint8 _seed
  ) internal {
    _stand(_token, _statusOf(_seed));
  }

  function test_WhenTheAccountIsTheToken_ItMayReceiveWhateverItsStanding(
    uint8 _statusSeed
  ) external {
    _standingOfTheToken(_statusSeed);
    assertEq(_rule.checkReceive(_token, _token), Reasons.TRANSFER_OK);

    IERC8473Policy.TransferContext memory _c = _ctx(IERC8473Policy.TransferKind.TRANSFER);
    _c.to = _token;
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    assertEq(_rule.check(_c), Reasons.TRANSFER_OK);
  }

  function test_WhenTheAccountIsTheToken_ItMaySendWhateverItsStanding(
    uint8 _statusSeed
  ) external {
    _standingOfTheToken(_statusSeed);
    assertEq(_rule.checkSend(_token, _token), Reasons.TRANSFER_OK);

    IERC8473Policy.TransferContext memory _c = _ctx(IERC8473Policy.TransferKind.BURN);
    _c.from = _token;
    _c.operator = _from; // not a burner: a settlement burn is the vault's own
    assertEq(_rule.check(_c), Reasons.TRANSFER_OK);
  }

  function test_WhenTheTokenHasNoPolicy_ItsOwnAddressMayStillReceive() external {
    address _unset = _mockContract('unset');
    assertEq(_rule.checkReceive(_unset, _unset), Reasons.TRANSFER_OK);
  }

  function test_TheRegistryIsNotAskedAboutTheToken() external {
    vm.expectCall(_registry, _call(_token), 0);
    _rule.checkSend(_token, _token);
    _rule.checkReceive(_token, _token);
  }

  function test_AnotherTokensAddressIsJudgedLikeAnyAccount() external {
    address _other = _mockContract('other');
    _stand(_other, ICredentialRegistry.Status.NONE);
    assertEq(_rule.checkReceive(_token, _other), Reasons.RECEIVER_NOT_VERIFIED);
    assertEq(_rule.checkSend(_token, _other), Reasons.SENDER_NOT_ELIGIBLE);
  }

  function test_TheTokenInAnotherTokensQuestionIsJudgedToo() external {
    address _other = _mockContract('other');
    _stand(_token, ICredentialRegistry.Status.BLOCKED);
    assertEq(_rule.checkReceive(_other, _token), Reasons.RECEIVER_NOT_ELIGIBLE); // that token has no policy
    assertEq(_rule.checkSend(_other, _token), Reasons.SENDER_NOT_ELIGIBLE);
  }
}

contract CredentialRuleUnit_AccountProbes is CredentialRuleUnitTest {
  function test_WhenAskedWhetherAnAccountMaySend_ItAnswersFromItsStandingAndIgnoresTheToken(
    uint8 _statusSeed
  ) external {
    ICredentialRegistry.Status _s = _statusOf(_statusSeed);
    _stand(_from, _s);
    bool _cannot = _s == ICredentialRegistry.Status.NONE || _s == ICredentialRegistry.Status.BLOCKED;
    bytes32 _expected = _cannot ? Reasons.SENDER_NOT_ELIGIBLE : Reasons.TRANSFER_OK;
    assertEq(_rule.checkSend(_token, _from), _expected);
    assertEq(_rule.checkSend(address(0xBEEF), _from), _expected);
  }

  function test_WhenAskedWhetherAnAccountMayReceive_ItAppliesThePolicyOfThatToken() external {
    _standing(_to, ICredentialRegistry.Status.ACTIVE, Quals.KYC, 0);
    assertEq(_rule.checkReceive(_token, _to), Reasons.TRANSFER_OK);
    assertEq(_rule.checkReceive(address(0xBEEF), _to), Reasons.RECEIVER_NOT_ELIGIBLE); // that token has no policy
    _policy(Quals.KYC | Quals.CUSTOMER, 0, 0, 1);
    assertEq(_rule.checkReceive(_token, _to), Reasons.RECEIVER_NOT_ELIGIBLE);
  }

  function test_WhenAProbeIsAskedTwiceForOneAccount_TheRegistryIsReadOncePerCall() external {
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    vm.expectCall(_registry, _call(_from), 1);
    _rule.checkSend(_token, _from);
    _stand(_to, ICredentialRegistry.Status.ACTIVE);
    vm.expectCall(_registry, _call(_to), 1);
    _rule.checkReceive(_token, _to);
  }

  function test_WhenKindStandingsAndPolicyAreFuzzed_CheckIsTheProbesInOrderWithTheEnforcementBurnExempt(
    uint8 _kindSeed,
    uint8 _senderSeed,
    uint8 _receiverSeed,
    uint32 _quals,
    uint32 _requireAll,
    bool _isBurner
  ) external {
    _policy(_requireAll, 0, 0, 1);
    IERC8473Policy.TransferKind _k = _kind(_kindSeed);
    _standing(_from, _statusOf(_senderSeed), 0, 0);
    _standing(_to, _statusOf(_receiverSeed), _quals, 0);
    IERC8473Policy.TransferContext memory _c = _ctx(_k);
    _c.operator = _isBurner ? _burner : _from;

    bytes32 _send = _rule.checkSend(_token, _from);
    bytes32 _receive = _rule.checkReceive(_token, _to);
    bytes32 _expected;
    if (_k == IERC8473Policy.TransferKind.TRANSFER || _k == IERC8473Policy.TransferKind.EXECUTED) {
      _expected = _send != Reasons.TRANSFER_OK ? _send : _receive;
    } else if (_k == IERC8473Policy.TransferKind.BURN) {
      _expected = _isBurner ? Reasons.TRANSFER_OK : _send;
    } else {
      _expected = _receive; // MINT and FORCED check the receiver only
    }
    assertEq(_rule.check(_c), _expected);
  }

  function test_WhenCalledWithStaticcall_TheProbesSucceed() external {
    _stand(_from, ICredentialRegistry.Status.ACTIVE);
    _stand(_to, ICredentialRegistry.Status.ACTIVE);
    (bool _sendOk, bytes memory _sendRet) = address(_rule).staticcall(abi.encodeCall(_rule.checkSend, (_token, _from)));
    (bool _receiveOk, bytes memory _receiveRet) =
      address(_rule).staticcall(abi.encodeCall(_rule.checkReceive, (_token, _to)));
    assertTrue(_sendOk && _receiveOk);
    assertEq(abi.decode(_sendRet, (bytes32)), Reasons.TRANSFER_OK);
    assertEq(abi.decode(_receiveRet, (bytes32)), Reasons.TRANSFER_OK);
  }
}
