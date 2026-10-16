// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {Helpers} from 'contracts/test/Helpers.sol';

contract ComplianceHookUnitTest is Helpers {
  ComplianceHook internal _hook;
  address internal _admin = makeAddr('admin');
  address internal _token = makeAddr('token');
  address internal _from = makeAddr('from');
  address internal _to = makeAddr('to');
  address internal _registry;

  function setUp() public virtual {
    _registry = _mockContract('registry');
    _hook = new ComplianceHook(_admin, IPolicyRegistry(_registry), _token, _none());
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

  function _install(
    IComplianceRule[] memory _ruleSet
  ) internal {
    vm.prank(_admin);
    _hook.setRules(_ruleSet);
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

  function _ctx() internal view returns (IPolicyHook.TransferContext memory _context) {
    _context = IPolicyHook.TransferContext({
      token: _token,
      from: _from,
      to: _to,
      id: 0,
      amount: 1,
      operator: _from,
      kind: IPolicyHook.TransferKind.TRANSFER,
      ref: bytes32(0),
      deadline: 0,
      extra: ''
    });
  }
}

contract ComplianceHookUnit_Constructor is ComplianceHookUnitTest {
  function test_WhenAdminIsZero_ItReverts() external {
    vm.expectRevert(IComplianceHook.ComplianceHook_ZeroAddress.selector);
    new ComplianceHook(address(0), IPolicyRegistry(_registry), _token, _none());
  }

  function test_WhenRegistryIsZero_ItReverts() external {
    vm.expectRevert(IComplianceHook.ComplianceHook_ZeroAddress.selector);
    new ComplianceHook(_admin, IPolicyRegistry(address(0)), _token, _none());
  }

  function test_WhenTokenIsZero_ItReverts() external {
    vm.expectRevert(IComplianceHook.ComplianceHook_ZeroAddress.selector);
    new ComplianceHook(_admin, IPolicyRegistry(_registry), address(0), _none());
  }

  function test_WhenValid_ItSetsTheBindings() external view {
    assertEq(_hook.ADMIN(), _admin);
    assertEq(address(_hook.REGISTRY()), _registry);
    assertEq(_hook.TOKEN(), _token);
    assertEq(_hook.ruleCount(), 0);
  }

  /// @dev Regression: the admin lived in storage, so a clone controlled by anyone shared the attested codehash
  function test_WhenAdminDiffers_ItChangesTheCodehash() external {
    ComplianceHook _clone = new ComplianceHook(makeAddr('attacker'), IPolicyRegistry(_registry), _token, _none());
    assertNotEq(address(_clone).codehash, address(_hook).codehash);
  }

  function test_WhenInitialRulesAreGiven_ItInstallsThemInOrderAndEmits() external {
    IComplianceRule _a = _newRule('a', false);
    IComplianceRule _b = _newRule('b', true);
    bytes32[] memory _ids = new bytes32[](2);
    _ids[0] = keccak256('a');
    _ids[1] = keccak256('b');

    vm.expectEmit();
    emit IComplianceHook.RuleSetChanged(_ids);
    ComplianceHook _live = new ComplianceHook(_admin, IPolicyRegistry(_registry), _token, _two(_a, _b));

    IComplianceRule[] memory _installed = _live.rules();
    assertEq(_installed.length, 2);
    assertEq(address(_installed[0]), address(_a));
    assertEq(address(_installed[1]), address(_b));
    assertTrue(_live.wantsAfter());
  }

  function test_WhenAnInitialRuleIsNotAttested_ItReverts() external {
    IComplianceRule _rule = _newRule('rule', false);
    vm.mockCall(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (address(_rule), IPolicyRegistry.AttestKind.RULE)),
      abi.encode(false)
    );
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_NotAttested.selector, address(_rule)));
    new ComplianceHook(_admin, IPolicyRegistry(_registry), _token, _one(_rule));
  }

  function test_WhenAnInitialRuleIsDuplicated_ItReverts() external {
    IComplianceRule _rule = _newRule('rule', false);
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_DuplicateRule.selector, address(_rule)));
    new ComplianceHook(_admin, IPolicyRegistry(_registry), _token, _two(_rule, _rule));
  }

  function test_WhenInitialRulesExceedTheCap_ItReverts() external {
    uint256 _length = _hook.MAX_RULES() + 1;
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_TooManyRules.selector, _length));
    new ComplianceHook(_admin, IPolicyRegistry(_registry), _token, new IComplianceRule[](_length));
  }

  function test_WhenOnlyTheInitialRulesDiffer_ItKeepsTheCodehash() external {
    ComplianceHook _live = new ComplianceHook(_admin, IPolicyRegistry(_registry), _token, _one(_newRule('rule', false)));
    assertEq(address(_live).codehash, address(_hook).codehash);
  }
}

contract ComplianceHookUnit_SetRules is ComplianceHookUnitTest {
  function test_WhenCallerIsNotAdmin_ItReverts() external {
    address _stranger = makeAddr('stranger');
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_OnlyAdmin.selector, _stranger));
    vm.prank(_stranger);
    _hook.setRules(new IComplianceRule[](0));
  }

  function test_WhenAboveTheCap_ItReverts(
    uint256 _length
  ) external {
    _length = bound(_length, _hook.MAX_RULES() + 1, 64);
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_TooManyRules.selector, _length));
    vm.prank(_admin);
    _hook.setRules(new IComplianceRule[](_length));
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

  function test_WhenValid_ItStoresTheOrderAndEmits() external {
    IComplianceRule _a = _newRule('a', false);
    IComplianceRule _b = _newRule('b', true);
    bytes32[] memory _ids = new bytes32[](2);
    _ids[0] = keccak256('a');
    _ids[1] = keccak256('b');

    vm.expectEmit(address(_hook));
    emit IComplianceHook.RuleSetChanged(_ids);
    _install(_two(_a, _b));

    IComplianceRule[] memory _installed = _hook.rules();
    assertEq(_installed.length, 2);
    assertEq(address(_installed[0]), address(_a));
    assertEq(address(_installed[1]), address(_b));
    assertTrue(_hook.wantsAfter());
  }

  function test_WhenReplaced_ItDropsThePreviousSet() external {
    _install(_two(_newRule('a', true), _newRule('b', false)));
    _install(_one(_newRule('c', false)));
    assertEq(_hook.ruleCount(), 1);
    assertFalse(_hook.wantsAfter());
  }
}

contract ComplianceHookUnit_BeforeTransfer is ComplianceHookUnitTest {
  /// @dev Regression: an unconfigured hook approved every movement
  function test_WhenNoRules_ItReturnsNoRules() external view {
    assertEq(_hook.beforeTransfer(_ctx()), Reasons.NO_RULES);
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
  function test_WhenCallerIsNotTheToken_ItReverts() external {
    address _stranger = makeAddr('stranger');
    vm.expectRevert(abi.encodeWithSelector(IComplianceHook.ComplianceHook_OnlyToken.selector, _stranger));
    vm.prank(_stranger);
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

contract ComplianceHookUnit_SupportsInterface is ComplianceHookUnitTest {
  function test_WhenQueried_ItSupportsItsInterfaces() external view {
    assertTrue(_hook.supportsInterface(type(IPolicyHook).interfaceId));
    assertTrue(_hook.supportsInterface(type(IComplianceHook).interfaceId));
    assertTrue(_hook.supportsInterface(type(IERC165).interfaceId));
    assertFalse(_hook.supportsInterface(0xdeadbeef));
  }
}
