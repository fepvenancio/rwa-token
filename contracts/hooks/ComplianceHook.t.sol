// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {Helpers} from 'contracts/test/Helpers.sol';

/**
 * @notice One hook serves many tokens: the rules and the after mask are keyed by token, and a token's rules are set by
 *         that token's own DEFAULT_ADMIN_ROLE or by the token itself (so its initialiser can install them)
 */
contract ComplianceHookUnitTest is Helpers {
  ComplianceHook internal _hook;
  address internal _tokenAdmin = makeAddr('tokenAdmin');
  address internal _token;
  address internal _otherToken;
  address internal _from = makeAddr('from');
  address internal _to = makeAddr('to');
  address internal _registry;

  function setUp() public virtual {
    _registry = _mockContract('registry');
    _token = _mockContract('token');
    _otherToken = _mockContract('otherToken');
    _hook = new ComplianceHook(IPolicyRegistry(_registry));
    _setAdmin(_token, _tokenAdmin, true);
  }

  /// @dev Mocks the token's own answer to `hasRole(DEFAULT_ADMIN_ROLE, account)`
  function _setAdmin(
    address _tokenAddress,
    address _account,
    bool _isAdmin
  ) internal {
    vm.mockCall(_tokenAddress, abi.encodeCall(IAccessControl.hasRole, (bytes32(0), _account)), abi.encode(_isAdmin));
  }

  /// @dev Creates a mocked, attested rule
  function _newRule(
    string memory _name,
    bool _wantsAfter
  ) internal returns (IComplianceRule _rule) {
    _rule = IComplianceRule(_mockContract(_name));
    vm.mockCall(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (address(_rule), IPolicyRegistry.AttestKind.RULE)),
      abi.encode(true)
    );
    vm.mockCall(address(_rule), abi.encodeCall(IComplianceRule.ruleId, ()), abi.encode(keccak256(bytes(_name))));
    vm.mockCall(address(_rule), abi.encodeCall(IComplianceRule.wantsAfter, ()), abi.encode(_wantsAfter));
  }

  function _mockCheck(
    IComplianceRule _rule,
    bytes32 _reason
  ) internal {
    vm.mockCall(address(_rule), abi.encodeWithSelector(IComplianceRule.check.selector), abi.encode(_reason));
  }

  /// @dev Installs a rule set on `_token` as its admin
  function _install(
    IComplianceRule[] memory _ruleSet
  ) internal {
    vm.prank(_tokenAdmin);
    _hook.setRules(_token, _ruleSet);
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

  function _two(
    IComplianceRule _a,
    IComplianceRule _b
  ) internal pure returns (IComplianceRule[] memory _ruleSet) {
    _ruleSet = new IComplianceRule[](2);
    _ruleSet[0] = _a;
    _ruleSet[1] = _b;
  }

  function _ctxFor(
    address _tokenAddress
  ) internal view returns (IPolicyHook.TransferContext memory _context) {
    _context = IPolicyHook.TransferContext({
      token: _tokenAddress,
      from: _from,
      to: _to,
      id: 0,
      amount: 1,
      operator: _from,
      kind: IPolicyHook.TransferKind.TRANSFER,
      extra: abi.encode(uint256(0), uint256(0))
    });
  }

  function _ctx() internal view returns (IPolicyHook.TransferContext memory _context) {
    _context = _ctxFor(_token);
  }
}

contract ComplianceHookUnit_Constructor is ComplianceHookUnitTest {
  function test_WhenRegistryIsZero_ItReverts() external {
    vm.expectRevert(IComplianceHook.ComplianceHook_ZeroAddress.selector);
    new ComplianceHook(IPolicyRegistry(address(0)));
  }

  function test_WhenValid_ItSetsTheRegistryAndStartsEmpty() external view {
    assertEq(address(_hook.REGISTRY()), _registry);
    assertEq(_hook.ruleCount(_token), 0);
    assertEq(_hook.MAX_RULES(), 16);
  }

  /// @dev The point of the shared hook: the only immutable is the registry, so one attestation serves every token
  function test_WhenTwoHooksShareARegistry_TheyShareACodehash() external {
    ComplianceHook _second = new ComplianceHook(IPolicyRegistry(_registry));
    assertEq(address(_second).codehash, address(_hook).codehash);
  }

  function test_WhenTheRegistryDiffers_ItChangesTheCodehash() external {
    ComplianceHook _other = new ComplianceHook(IPolicyRegistry(_mockContract('otherRegistry')));
    assertNotEq(address(_other).codehash, address(_hook).codehash);
  }
}

contract ComplianceHookUnit_SetRules is ComplianceHookUnitTest {
  function test_WhenCallerIsNotTheTokenAdmin_ItReverts() external {
    address _stranger = makeAddr('stranger');
    _setAdmin(_token, _stranger, false);
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_NotTokenAdmin.selector, _token, _stranger));
    vm.prank(_stranger);
    _hook.setRules(_token, _none());
  }

  function test_WhenTheTokenHasNoCodeAndCallerIsNotTheToken_ItReverts() external {
    address _ghost = makeAddr('ghost');
    address _stranger = makeAddr('stranger');
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_NotTokenAdmin.selector, _ghost, _stranger));
    vm.prank(_stranger);
    _hook.setRules(_ghost, _none());
  }

  /// @dev The initialiser of a token runs before the token has any role the hook could ask about
  function test_WhenCallerIsTheToken_ItInstallsWithoutAskingTheToken() external {
    IComplianceRule _rule = _newRule('rule', false);
    vm.expectCall(_token, abi.encodeWithSelector(IAccessControl.hasRole.selector), 0);
    vm.prank(_token);
    _hook.setRules(_token, _one(_rule));
    assertEq(_hook.ruleCount(_token), 1);
  }

  /// @dev A token can set its own rules and nobody else's
  function test_WhenCallerIsAnotherToken_ItCannotSetTheRulesOfThisOne() external {
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_NotTokenAdmin.selector, _token, _otherToken));
    _setAdmin(_token, _otherToken, false);
    vm.prank(_otherToken);
    _hook.setRules(_token, _none());
  }

  function test_WhenAdminOfOneTokenSetsAnother_ItReverts() external {
    _setAdmin(_otherToken, _tokenAdmin, false);
    vm.expectRevert(
      abi.encodeWithSelector(IComplianceHook.ComplianceHook_NotTokenAdmin.selector, _otherToken, _tokenAdmin)
    );
    vm.prank(_tokenAdmin);
    _hook.setRules(_otherToken, _none());
  }

  function test_WhenAboveTheCap_ItReverts(
    uint256 _length
  ) external {
    _length = bound(_length, _hook.MAX_RULES() + 1, 64);
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_TooManyRules.selector, _length));
    vm.prank(_tokenAdmin);
    _hook.setRules(_token, new IComplianceRule[](_length));
  }

  /// @dev The cap is per token, not per hook
  function test_WhenTwoTokensEachHoldTheCap_BothAreAccepted() external {
    uint256 _length = _hook.MAX_RULES();
    IComplianceRule[] memory _ruleSet = new IComplianceRule[](_length);
    for (uint256 _i; _i < _length; ++_i) {
      _ruleSet[_i] = _newRule(string.concat('rule', vm.toString(_i)), false);
    }
    _install(_ruleSet);
    vm.prank(_otherToken);
    _hook.setRules(_otherToken, _ruleSet);
    assertEq(_hook.ruleCount(_token), 16);
    assertEq(_hook.ruleCount(_otherToken), 16);
  }

  function test_WhenARuleIsNotAttested_ItReverts() external {
    IComplianceRule _rule = _newRule('rule', false);
    vm.mockCall(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (address(_rule), IPolicyRegistry.AttestKind.RULE)),
      abi.encode(false)
    );
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_NotAttested.selector, address(_rule)));
    _install(_one(_rule));
  }

  function test_WhenARuleIsDuplicated_ItReverts() external {
    IComplianceRule _rule = _newRule('rule', false);
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_DuplicateRule.selector, address(_rule)));
    _install(_two(_rule, _rule));
  }

  /// @dev Regression: two instances of the same rule type (same `ruleId`) were accepted, making
  ///      `RuleSetChanged` ambiguous for indexers. One instance of each rule type per token
  function test_WhenTwoRulesShareARuleId_ItReverts() external {
    IComplianceRule _first = _newRule('identity', false);
    IComplianceRule _second = _newRule('identity-second-instance', false);
    vm.mockCall(address(_second), abi.encodeCall(IComplianceRule.ruleId, ()), abi.encode(keccak256('identity')));
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_DuplicateRule.selector, address(_second)));
    _install(_two(_first, _second));
  }

  function test_WhenValid_ItStoresTheOrderAndEmitsWithTheToken() external {
    IComplianceRule _a = _newRule('a', false);
    IComplianceRule _b = _newRule('b', true);
    bytes32[] memory _ids = new bytes32[](2);
    _ids[0] = keccak256('a');
    _ids[1] = keccak256('b');

    vm.expectEmit(address(_hook));
    emit IComplianceHook.RuleSetChanged(_token, _ids);
    _install(_two(_a, _b));

    IComplianceRule[] memory _installed = _hook.rules(_token);
    assertEq(_installed.length, 2);
    assertEq(address(_installed[0]), address(_a));
    assertEq(address(_installed[1]), address(_b));
    vm.prank(_token);
    assertTrue(_hook.wantsAfter());
  }

  function test_WhenReplaced_ItDropsThePreviousSet() external {
    _install(_two(_newRule('a', true), _newRule('b', false)));
    _install(_one(_newRule('c', false)));
    assertEq(_hook.ruleCount(_token), 1);
    vm.prank(_token);
    assertFalse(_hook.wantsAfter());
  }

  /// @dev Rule sets are keyed by token: setting one leaves the other untouched
  function test_WhenOneTokenIsSet_AnotherTokenKeepsItsOwnRules() external {
    IComplianceRule _a = _newRule('a', true);
    IComplianceRule _b = _newRule('b', false);
    _install(_one(_a));
    vm.prank(_otherToken);
    _hook.setRules(_otherToken, _one(_b));

    assertEq(address(_hook.rules(_token)[0]), address(_a));
    assertEq(address(_hook.rules(_otherToken)[0]), address(_b));
    vm.prank(_token);
    assertTrue(_hook.wantsAfter());
    vm.prank(_otherToken);
    assertFalse(_hook.wantsAfter());
  }

  /// @dev Replacing one token's rules must not clear another token's after mask
  function test_WhenOneTokenIsReplaced_AnotherTokensAfterMaskIsKept() external {
    _install(_one(_newRule('a', true)));
    vm.prank(_otherToken);
    _hook.setRules(_otherToken, _one(_newRule('b', true)));
    _install(_none());
    vm.prank(_otherToken);
    assertTrue(_hook.wantsAfter());
  }
}

contract ComplianceHookUnit_BeforeTransfer is ComplianceHookUnitTest {
  /// @dev Regression: an unconfigured hook approved every movement
  function test_WhenNoRules_ItReturnsNoRules() external view {
    assertEq(_hook.beforeTransfer(_ctx()), Reasons.NO_RULES);
  }

  /// @dev A token that was never configured fails closed even when another token has rules
  function test_WhenAnotherTokenHasRules_ThisTokenStillReturnsNoRules() external {
    IComplianceRule _a = _newRule('a', false);
    vm.prank(_otherToken);
    _hook.setRules(_otherToken, _one(_a));
    _mockCheck(_a, Reasons.TRANSFER_OK);
    assertEq(_hook.beforeTransfer(_ctx()), Reasons.NO_RULES);
    assertEq(_hook.beforeTransfer(_ctxFor(_otherToken)), Reasons.TRANSFER_OK);
  }

  function test_WhenEveryRuleAccepts_ItReturnsOk() external {
    IComplianceRule _a = _newRule('a', false);
    IComplianceRule _b = _newRule('b', false);
    _install(_two(_a, _b));
    _mockCheck(_a, Reasons.TRANSFER_OK);
    _mockCheck(_b, Reasons.TRANSFER_OK);
    assertEq(_hook.beforeTransfer(_ctx()), Reasons.TRANSFER_OK);
  }

  function test_WhenARuleRejects_ItReturnsTheFirstReasonAndShortCircuits(
    bytes32 _reason
  ) external {
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.LOCKED;
    IComplianceRule _a = _newRule('a', false);
    IComplianceRule _b = _newRule('b', false);
    _install(_two(_a, _b));
    _mockCheck(_a, _reason);
    _mockCheck(_b, Reasons.MAX_HOLDERS);

    vm.expectCall(address(_b), abi.encodeWithSelector(IComplianceRule.check.selector), 0);
    assertEq(_hook.beforeTransfer(_ctx()), _reason);
  }
}

contract ComplianceHookUnit_AfterTransfer is ComplianceHookUnitTest {
  function test_WhenCallerIsNotTheContextToken_ItReverts() external {
    address _stranger = makeAddr('stranger');
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_OnlyToken.selector, _stranger));
    vm.prank(_stranger);
    _hook.afterTransfer(_ctx());
  }

  /// @dev A token cannot run the `after_` hooks of another token's rules by naming it in the context
  function test_WhenAnotherTokenNamesThisOne_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_OnlyToken.selector, _otherToken));
    vm.prank(_otherToken);
    _hook.afterTransfer(_ctx());
  }

  function test_WhenCalledByTheToken_ItCallsOnlyRulesThatWantAfter() external {
    IComplianceRule _a = _newRule('a', false);
    IComplianceRule _b = _newRule('b', true);
    _install(_two(_a, _b));

    _mockAndExpect(address(_b), abi.encodeCall(IComplianceRule.after_, (_ctx())), '');
    vm.expectCall(address(_a), abi.encodeWithSelector(IComplianceRule.after_.selector), 0);
    vm.prank(_token);
    _hook.afterTransfer(_ctx());
  }

  function test_WhenTwoTokensHaveRules_ItCallsOnlyTheCallersRules() external {
    IComplianceRule _a = _newRule('a', true);
    IComplianceRule _b = _newRule('b', true);
    _install(_one(_a));
    vm.prank(_otherToken);
    _hook.setRules(_otherToken, _one(_b));

    _mockAndExpect(address(_a), abi.encodeCall(IComplianceRule.after_, (_ctx())), '');
    vm.expectCall(address(_b), abi.encodeWithSelector(IComplianceRule.after_.selector), 0);
    vm.prank(_token);
    _hook.afterTransfer(_ctx());
  }

  /// @dev Regression: per-rule flags were re-read on every transfer, so a rule could change its answer after install
  function test_WhenARuleChangesWantsAfterLater_ItKeepsTheInstalledFlag() external {
    IComplianceRule _a = _newRule('a', false);
    _install(_one(_a));
    vm.mockCall(address(_a), abi.encodeCall(IComplianceRule.wantsAfter, ()), abi.encode(true));

    vm.expectCall(address(_a), abi.encodeWithSelector(IComplianceRule.after_.selector), 0);
    vm.prank(_token);
    _hook.afterTransfer(_ctx());
  }
}

contract ComplianceHookUnit_WantsAfter is ComplianceHookUnitTest {
  /// @dev The token asks `wantsAfter()` with no argument, so the hook answers for the caller
  function test_WhenAskedByATokenWithAfterRules_ItReturnsTrue() external {
    _install(_one(_newRule('a', true)));
    vm.prank(_token);
    assertTrue(_hook.wantsAfter());
  }

  function test_WhenAskedByATokenWithoutAfterRules_ItReturnsFalse() external {
    _install(_one(_newRule('a', false)));
    vm.prank(_token);
    assertFalse(_hook.wantsAfter());
  }

  function test_WhenAskedByAnAccountThatIsNotAConfiguredToken_ItReturnsFalse() external {
    _install(_one(_newRule('a', true)));
    vm.prank(makeAddr('stranger'));
    assertFalse(_hook.wantsAfter());
  }
}

contract ComplianceHookUnit_AccountChecks is ComplianceHookUnitTest {
  function _mockSend(
    IComplianceRule _rule,
    bytes32 _reason
  ) internal {
    vm.mockCall(address(_rule), abi.encodeCall(IComplianceRule.checkSend, (_token, _from)), abi.encode(_reason));
  }

  function _mockReceive(
    IComplianceRule _rule,
    bytes32 _reason
  ) internal {
    vm.mockCall(address(_rule), abi.encodeCall(IComplianceRule.checkReceive, (_token, _to)), abi.encode(_reason));
  }

  function test_WhenNoRules_BothChecksReturnNoRules() external view {
    assertEq(_hook.checkSend(_token, _from), Reasons.NO_RULES);
    assertEq(_hook.checkReceive(_token, _to), Reasons.NO_RULES);
  }

  function test_WhenEveryRuleAccepts_BothChecksReturnOk() external {
    IComplianceRule _a = _newRule('a', false);
    IComplianceRule _b = _newRule('b', false);
    _install(_two(_a, _b));
    _mockSend(_a, Reasons.TRANSFER_OK);
    _mockSend(_b, Reasons.TRANSFER_OK);
    _mockReceive(_a, Reasons.TRANSFER_OK);
    _mockReceive(_b, Reasons.TRANSFER_OK);
    assertEq(_hook.checkSend(_token, _from), Reasons.TRANSFER_OK);
    assertEq(_hook.checkReceive(_token, _to), Reasons.TRANSFER_OK);
  }

  function test_WhenARuleRejectsTheSender_ItReturnsTheFirstReasonAndShortCircuits(
    bytes32 _reason
  ) external {
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.SENDER_NOT_VERIFIED;
    IComplianceRule _a = _newRule('a', false);
    IComplianceRule _b = _newRule('b', false);
    _install(_two(_a, _b));
    _mockSend(_a, _reason);
    _mockSend(_b, Reasons.SENDER_NOT_VERIFIED);

    vm.expectCall(address(_b), abi.encodeWithSelector(IComplianceRule.checkSend.selector), 0);
    assertEq(_hook.checkSend(_token, _from), _reason);
  }

  function test_WhenARuleRejectsTheReceiver_ItReturnsTheFirstReasonAndShortCircuits(
    bytes32 _reason
  ) external {
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.RECEIVER_NOT_VERIFIED;
    IComplianceRule _a = _newRule('a', false);
    IComplianceRule _b = _newRule('b', false);
    _install(_two(_a, _b));
    _mockReceive(_a, _reason);
    _mockReceive(_b, Reasons.RECEIVER_NOT_VERIFIED);

    vm.expectCall(address(_b), abi.encodeWithSelector(IComplianceRule.checkReceive.selector), 0);
    assertEq(_hook.checkReceive(_token, _to), _reason);
  }

  /// @dev The account checks read the rules of the token they are asked about
  function test_WhenAnotherTokenHasRules_ThisTokenStillReturnsNoRules() external {
    IComplianceRule _a = _newRule('a', false);
    vm.prank(_otherToken);
    _hook.setRules(_otherToken, _one(_a));
    assertEq(_hook.checkSend(_token, _from), Reasons.NO_RULES);
    assertEq(_hook.checkReceive(_token, _to), Reasons.NO_RULES);
  }
}

contract ComplianceHookUnit_SupportsInterface is ComplianceHookUnitTest {
  function test_WhenQueried_ItSupportsItsInterfaces() external view {
    assertTrue(_hook.supportsInterface(type(IPolicyHook).interfaceId));
    assertTrue(_hook.supportsInterface(type(IComplianceHook).interfaceId));
    assertTrue(_hook.supportsInterface(type(IERC165).interfaceId));
    assertFalse(_hook.supportsInterface(0xdeadbeef));
  }
}
