// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {Vm} from 'forge-std/Vm.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IFund} from 'interfaces/IFund.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {Fund} from 'contracts/fund/Fund.sol';
import {Helpers} from 'contracts/test/Helpers.sol';

contract FundUnitTest is Helpers {
  Fund internal _fund;
  address internal _owner = makeAddr('owner');
  address internal _stranger = makeAddr('stranger');
  address internal _registry;
  address internal _rule = makeAddr('rule');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');

  function setUp() public virtual {
    _registry = _mockContract('registry');
    _attest(_rule, true);
    _fund = new Fund(_owner, IPolicyRegistry(_registry));
  }

  function _attest(
    address _candidate,
    bool _attested
  ) internal {
    vm.mockCall(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (_candidate, IPolicyRegistry.AttestKind.RULE)),
      abi.encode(_attested)
    );
  }

  function _setRule() internal {
    vm.prank(_owner);
    _fund.setRule(_rule);
  }

  /**
   * @dev A token that passes every registration check: ERC-165 `IPolicyGated`, a hook that lists `_rule`, no supply
   * @param _name The label
   * @return _token The token
   */
  function _newClass(
    string memory _name
  ) internal returns (address _token) {
    _token = _mockContract(_name);
    address _hook = _mockContract(string.concat(_name, 'Hook'));
    _mockErc165(_token, true);
    vm.mockCall(_token, abi.encodeCall(IPolicyGated.policyHook, ()), abi.encode(_hook));
    vm.mockCall(_token, abi.encodeCall(IERC20.totalSupply, ()), abi.encode(0));
    _hookLists(_hook, _rule);
  }

  /// @dev ERC165Checker asks for the ERC-165 id, then for 0xffffffff, then for the interface itself
  function _mockErc165(
    address _token,
    bool _supportsPolicyGated
  ) internal {
    vm.mockCall(_token, abi.encodeCall(IERC165.supportsInterface, (type(IERC165).interfaceId)), abi.encode(true));
    vm.mockCall(_token, abi.encodeCall(IERC165.supportsInterface, (bytes4(0xffffffff))), abi.encode(false));
    vm.mockCall(
      _token,
      abi.encodeCall(IERC165.supportsInterface, (type(IPolicyGated).interfaceId)),
      abi.encode(_supportsPolicyGated)
    );
  }

  function _hookLists(
    address _hook,
    address _listed
  ) internal {
    IComplianceRule[] memory _list = new IComplianceRule[](1);
    _list[0] = IComplianceRule(_listed);
    vm.mockCall(_hook, abi.encodeWithSelector(IComplianceHook.rules.selector), abi.encode(_list));
  }

  /// @dev Sets the rule once, then registers a new class
  function _registered(
    string memory _name
  ) internal returns (address _token) {
    if (_fund.rule() == address(0)) _setRule();
    _token = _newClass(_name);
    vm.prank(_owner);
    _fund.registerClass(_token);
  }

  function _join(
    address _token,
    address _account
  ) internal {
    vm.prank(_rule);
    _fund.join(_token, _account);
  }

  function _leave(
    address _token,
    address _account
  ) internal {
    vm.prank(_rule);
    _fund.leave(_token, _account);
  }

  function _exempt(
    address _account,
    bool _isExempt
  ) internal {
    vm.prank(_owner);
    _fund.setExempt(_account, _isExempt);
  }

  function _notOwner(
    address _caller
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller);
  }
}

contract FundUnit_Constructor is FundUnitTest {
  function test_WhenDeployed_OwnerRegistryAndLimitsAreSet() external view {
    assertEq(_fund.owner(), _owner);
    assertEq(address(_fund.REGISTRY()), _registry);
    assertEq(_fund.MAX_CLASSES(), 32);
    assertEq(_fund.classCount(), 0);
    assertEq(_fund.holderCount(), 0);
    assertEq(_fund.holderCap(), 0);
    assertEq(_fund.rule(), address(0));
  }

  function test_WhenTheRegistryIsZero_Reverts() external {
    vm.expectRevert(IFund.Fund_ZeroAddress.selector);
    new Fund(_owner, IPolicyRegistry(address(0)));
  }

  function test_WhenAskedForInterfaces_FundAndErc165AreSupported() external view {
    assertTrue(_fund.supportsInterface(type(IFund).interfaceId));
    assertTrue(_fund.supportsInterface(type(IERC165).interfaceId));
    assertFalse(_fund.supportsInterface(bytes4(0xffffffff)));
  }

  function test_WhenOwnershipMoves_OnlyTheNewOwnerConfigures() external {
    address _timelock = makeAddr('timelock');
    vm.prank(_owner);
    _fund.transferOwnership(_timelock);

    vm.expectRevert(_notOwner(_owner));
    vm.prank(_owner);
    _fund.setRule(_rule);

    vm.prank(_timelock);
    _fund.setRule(_rule);
    assertEq(_fund.rule(), _rule);
  }
}

contract FundUnit_SetRule is FundUnitTest {
  function test_WhenCallerIsNotTheOwner_Reverts() external {
    vm.expectRevert(_notOwner(_stranger));
    vm.prank(_stranger);
    _fund.setRule(_rule);
  }

  function test_WhenTheRuleIsZero_Reverts() external {
    vm.expectRevert(IFund.Fund_ZeroAddress.selector);
    vm.prank(_owner);
    _fund.setRule(address(0));
  }

  function test_WhenTheRuleIsNotAttested_Reverts() external {
    address _unattested = makeAddr('unattested');
    _attest(_unattested, false);
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_NotAttested.selector, _unattested));
    vm.prank(_owner);
    _fund.setRule(_unattested);
  }

  function test_WhenTheRuleIsAttested_ItIsCheckedSetAndEmitted() external {
    vm.expectCall(_registry, abi.encodeCall(IPolicyRegistry.isAttested, (_rule, IPolicyRegistry.AttestKind.RULE)), 1);
    vm.expectEmit(true, true, false, false, address(_fund));
    emit IFund.RuleSet(address(0), _rule);
    vm.prank(_owner);
    _fund.setRule(_rule);
    assertEq(_fund.rule(), _rule);
  }

  function test_WhenTheRuleIsReplaced_TheEventNamesTheOldOne() external {
    _setRule();
    address _next = makeAddr('next');
    _attest(_next, true);
    vm.expectEmit(true, true, false, false, address(_fund));
    emit IFund.RuleSet(_rule, _next);
    vm.prank(_owner);
    _fund.setRule(_next);
    assertEq(_fund.rule(), _next);
  }
}

contract FundUnit_SetHolderCap is FundUnitTest {
  function test_WhenCallerIsNotTheOwner_Reverts() external {
    vm.expectRevert(_notOwner(_stranger));
    vm.prank(_stranger);
    _fund.setHolderCap(5);
  }

  function test_WhenTheCapIsSet_ItIsStoredAndTheEventNamesTheOldCap() external {
    vm.expectEmit(false, false, false, true, address(_fund));
    emit IFund.HolderCapSet(0, 5);
    vm.prank(_owner);
    _fund.setHolderCap(5);
    assertEq(_fund.holderCap(), 5);

    vm.expectEmit(false, false, false, true, address(_fund));
    emit IFund.HolderCapSet(5, 2);
    vm.prank(_owner);
    _fund.setHolderCap(2);
    assertEq(_fund.holderCap(), 2);
  }

  function test_WhenTheCapExceedsUint48_Reverts() external {
    uint256 _tooBig = uint256(type(uint48).max) + 1;
    vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 48, _tooBig));
    vm.prank(_owner);
    _fund.setHolderCap(_tooBig);
  }

  function testFuzz_WhenTheCapFitsUint48_ItIsStored(
    uint256 _cap
  ) external {
    _cap = bound(_cap, 0, type(uint48).max);
    vm.prank(_owner);
    _fund.setHolderCap(_cap);
    assertEq(_fund.holderCap(), _cap);
  }

  /// @dev The rule, the count and the cap share one slot: a write to any of them must leave the other two alone
  function test_WhenTheRuleCountAndCapShareASlot_NoWriteDisturbsTheOthers() external {
    address _token = _registered('classA');
    address _next = makeAddr('next');
    _attest(_next, true);
    vm.prank(_owner);
    _fund.setHolderCap(type(uint48).max);

    _join(_token, _alice);
    _join(_token, _bob);
    assertEq(_fund.rule(), _rule);
    assertEq(_fund.holderCap(), type(uint48).max);
    assertEq(_fund.holderCount(), 2);

    vm.prank(_owner);
    _fund.setRule(_next);
    assertEq(_fund.holderCap(), type(uint48).max);
    assertEq(_fund.holderCount(), 2);

    vm.prank(_owner);
    _fund.setHolderCap(5);
    assertEq(_fund.rule(), _next);
    assertEq(_fund.holderCount(), 2);

    vm.prank(_next);
    _fund.leave(_token, _alice);
    assertEq(_fund.rule(), _next);
    assertEq(_fund.holderCap(), 5);
    assertEq(_fund.holderCount(), 1);
  }

  function test_WhenTheCapIsLoweredBelowTheCount_TheCountIsUntouched() external {
    address _token = _registered('classA');
    vm.prank(_owner);
    _fund.setHolderCap(3);
    _join(_token, _alice);
    _join(_token, _bob);
    vm.prank(_owner);
    _fund.setHolderCap(1);
    assertEq(_fund.holderCount(), 2);
    assertEq(_fund.holderCap(), 1);
  }
}

contract FundUnit_RegisterClass is FundUnitTest {
  function test_WhenCallerIsNotTheOwner_Reverts() external {
    _setRule();
    address _token = _newClass('classA');
    vm.expectRevert(_notOwner(_stranger));
    vm.prank(_stranger);
    _fund.registerClass(_token);
  }

  function test_WhenTheTokenIsZero_Reverts() external {
    _setRule();
    vm.expectRevert(IFund.Fund_ZeroAddress.selector);
    vm.prank(_owner);
    _fund.registerClass(address(0));
  }

  function test_WhenTheRuleIsNotSet_Reverts() external {
    address _token = _newClass('classA');
    vm.expectRevert(IFund.Fund_RuleNotSet.selector);
    vm.prank(_owner);
    _fund.registerClass(_token);
  }

  function test_WhenTheTokenIsAlreadyRegistered_Reverts() external {
    address _token = _registered('classA');
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_AlreadyRegistered.selector, _token));
    vm.prank(_owner);
    _fund.registerClass(_token);
  }

  function test_WhenTheFundIsFull_Reverts() external {
    for (uint256 _i; _i < 32; ++_i) {
      _registered(string.concat('class', vm.toString(_i)));
    }
    assertEq(_fund.classCount(), 32);
    address _extra = _newClass('extra');
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_TooManyClasses.selector, 32));
    vm.prank(_owner);
    _fund.registerClass(_extra);
  }

  function test_WhenTheTokenIsNotPolicyGated_Reverts() external {
    _setRule();
    address _token = _newClass('classA');
    _mockErc165(_token, false);
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_NotPolicyGated.selector, _token));
    vm.prank(_owner);
    _fund.registerClass(_token);
  }

  function test_WhenTheAddressHasNoCode_Reverts() external {
    _setRule();
    address _eoa = makeAddr('eoa');
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_NotPolicyGated.selector, _eoa));
    vm.prank(_owner);
    _fund.registerClass(_eoa);
  }

  function test_WhenTheHookDoesNotListTheRule_Reverts() external {
    _setRule();
    address _token = _newClass('classA');
    _hookLists(IPolicyGated(_token).policyHook(), makeAddr('otherRule'));
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_RuleNotListed.selector, _token, _rule));
    vm.prank(_owner);
    _fund.registerClass(_token);
  }

  function test_WhenTheHookListsTheRuleAmongOthers_ItRegisters() external {
    _setRule();
    address _token = _newClass('classA');
    IComplianceRule[] memory _list = new IComplianceRule[](3);
    _list[0] = IComplianceRule(makeAddr('first'));
    _list[1] = IComplianceRule(_rule);
    _list[2] = IComplianceRule(makeAddr('last'));
    vm.mockCall(
      IPolicyGated(_token).policyHook(), abi.encodeWithSelector(IComplianceHook.rules.selector), abi.encode(_list)
    );
    vm.prank(_owner);
    _fund.registerClass(_token);
    assertEq(_fund.classIndexOf(_token), 1);
  }

  function test_WhenTheTokenHasSupply_Reverts() external {
    _setRule();
    address _token = _newClass('classA');
    vm.mockCall(_token, abi.encodeCall(IERC20.totalSupply, ()), abi.encode(7));
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_ClassHasSupply.selector, _token, 7));
    vm.prank(_owner);
    _fund.registerClass(_token);
  }

  function test_WhenAClassIsRegistered_ItIsNumberedFromOneAndTheEventSaysSo() external {
    _setRule();
    address _first = _newClass('classA');
    address _second = _newClass('classB');

    vm.expectEmit(true, true, false, false, address(_fund));
    emit IFund.ClassRegistered(_first, 1);
    vm.prank(_owner);
    _fund.registerClass(_first);

    vm.expectEmit(true, true, false, false, address(_fund));
    emit IFund.ClassRegistered(_second, 2);
    vm.prank(_owner);
    _fund.registerClass(_second);

    assertEq(_fund.classCount(), 2);
    assertEq(_fund.classAt(1), _first);
    assertEq(_fund.classAt(2), _second);
    assertEq(_fund.classIndexOf(_first), 1);
    assertEq(_fund.classIndexOf(_second), 2);
    assertEq(_fund.classIndexOf(makeAddr('unknown')), 0);
  }
}

contract FundUnit_Join is FundUnitTest {
  address internal _classA;
  address internal _classB;

  function setUp() public override {
    super.setUp();
    _classA = _registered('classA');
    _classB = _registered('classB');
  }

  function test_WhenCallerIsNotTheRule_Reverts() external {
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_OnlyRule.selector, _stranger));
    vm.prank(_stranger);
    _fund.join(_classA, _alice);
  }

  function test_WhenTheTokenIsNotAClass_Reverts() external {
    address _unknown = makeAddr('unknown');
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_NotAClass.selector, _unknown));
    _join(_unknown, _alice);
  }

  function test_WhenAnAccountJoinsItsFirstClass_TheCountAndMaskUpdateAndBothEventsAreEmitted() external {
    vm.expectEmit(true, false, false, true, address(_fund));
    emit IFund.HolderClassesUpdated(_alice, 1);
    vm.expectEmit(false, false, false, true, address(_fund));
    emit IFund.HolderCountUpdated(1);
    _join(_classA, _alice);

    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.heldClasses(_alice), 1);
  }

  function test_WhenAnAccountJoinsASecondClass_TheCountStaysAndOnlyTheMaskEventIsEmitted() external {
    _join(_classA, _alice);
    vm.recordLogs();
    _join(_classB, _alice);
    Vm.Log[] memory _logs = vm.getRecordedLogs();

    assertEq(_logs.length, 1);
    assertEq(_logs[0].topics[0], IFund.HolderClassesUpdated.selector);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.heldClasses(_alice), 3);
  }

  function test_WhenTwoAccountsJoin_TheyCountSeparately() external {
    _join(_classA, _alice);
    _join(_classA, _bob);
    assertEq(_fund.holderCount(), 2);
  }

  function test_WhenAnAccountJoinsAClassItAlreadyHolds_NothingChangesAndNothingIsEmitted() external {
    _join(_classA, _alice);
    vm.recordLogs();
    _join(_classA, _alice);
    assertEq(vm.getRecordedLogs().length, 0);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.heldClasses(_alice), 1);
  }

  function test_WhenTheAccountIsTheClassItself_NothingIsRecorded() external {
    vm.recordLogs();
    _join(_classA, _classA);
    assertEq(vm.getRecordedLogs().length, 0);
    assertEq(_fund.holderCount(), 0);
    assertEq(_fund.heldClasses(_classA), 0);
  }

  function test_WhenTheAccountIsAnotherClass_ItCountsLikeAnyAccount() external {
    _join(_classA, _classB);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.heldClasses(_classB), 1);
  }

  function test_WhenTheAccountIsExempt_TheMaskIsRecordedButTheCountDoesNotMove() external {
    _exempt(_alice, true);
    vm.recordLogs();
    _join(_classA, _alice);
    Vm.Log[] memory _logs = vm.getRecordedLogs();

    assertEq(_logs.length, 1);
    assertEq(_logs[0].topics[0], IFund.HolderClassesUpdated.selector);
    assertEq(_fund.holderCount(), 0);
    assertEq(_fund.heldClasses(_alice), 1);
  }
}

contract FundUnit_Leave is FundUnitTest {
  address internal _classA;
  address internal _classB;

  function setUp() public override {
    super.setUp();
    _classA = _registered('classA');
    _classB = _registered('classB');
  }

  function test_WhenCallerIsNotTheRule_Reverts() external {
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_OnlyRule.selector, _stranger));
    vm.prank(_stranger);
    _fund.leave(_classA, _alice);
  }

  function test_WhenTheTokenIsNotAClass_Reverts() external {
    address _unknown = makeAddr('unknown');
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_NotAClass.selector, _unknown));
    _leave(_unknown, _alice);
  }

  function test_WhenAnAccountLeavesItsLastClass_TheCountDropsAndBothEventsAreEmitted() external {
    _join(_classA, _alice);
    vm.expectEmit(true, false, false, true, address(_fund));
    emit IFund.HolderClassesUpdated(_alice, 0);
    vm.expectEmit(false, false, false, true, address(_fund));
    emit IFund.HolderCountUpdated(0);
    _leave(_classA, _alice);

    assertEq(_fund.holderCount(), 0);
    assertEq(_fund.heldClasses(_alice), 0);
  }

  function test_WhenAnAccountLeavesOneOfTwoClasses_TheCountStaysAndTheOtherBitRemains() external {
    _join(_classA, _alice);
    _join(_classB, _alice);
    vm.recordLogs();
    _leave(_classA, _alice);
    Vm.Log[] memory _logs = vm.getRecordedLogs();

    assertEq(_logs.length, 1);
    assertEq(_logs[0].topics[0], IFund.HolderClassesUpdated.selector);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.heldClasses(_alice), 2);
  }

  function test_WhenAnAccountLeavesAClassItDidNotHold_NothingChangesAndItDoesNotRevert() external {
    _join(_classA, _bob);
    vm.recordLogs();
    _leave(_classB, _alice);
    assertEq(vm.getRecordedLogs().length, 0);
    assertEq(_fund.holderCount(), 1);
  }

  function test_WhenTheAccountIsTheClassItself_NothingChanges() external {
    _join(_classA, _alice);
    vm.recordLogs();
    _leave(_classA, _classA);
    assertEq(vm.getRecordedLogs().length, 0);
    assertEq(_fund.holderCount(), 1);
  }

  function test_WhenAnExemptAccountLeaves_TheMaskClearsAndTheCountDoesNotMoveAndItStaysExempt() external {
    _join(_classA, _bob);
    _exempt(_alice, true);
    _join(_classA, _alice);
    vm.recordLogs();
    _leave(_classA, _alice);
    Vm.Log[] memory _logs = vm.getRecordedLogs();

    assertEq(_logs.length, 1);
    assertEq(_logs[0].topics[0], IFund.HolderClassesUpdated.selector);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.heldClasses(_alice), 0);
    assertTrue(_fund.isExempt(_alice));
  }

  function test_WhenAnAccountLeavesAndRejoins_ItCountsOnce() external {
    _join(_classA, _alice);
    _leave(_classA, _alice);
    _join(_classA, _alice);
    assertEq(_fund.holderCount(), 1);
  }
}

contract FundUnit_SetExempt is FundUnitTest {
  address internal _classA;

  function setUp() public override {
    super.setUp();
    _classA = _registered('classA');
  }

  function test_WhenCallerIsNotTheOwner_Reverts() external {
    vm.expectRevert(_notOwner(_stranger));
    vm.prank(_stranger);
    _fund.setExempt(_alice, true);
  }

  function test_WhenTheAccountIsZero_Reverts() external {
    vm.expectRevert(IFund.Fund_ZeroAddress.selector);
    vm.prank(_owner);
    _fund.setExempt(address(0), true);
  }

  function test_WhenANonHolderIsExempted_OnlyTheFlagChangesAndTheEventIsEmitted() external {
    vm.expectEmit(true, false, false, true, address(_fund));
    emit IFund.ExemptSet(_alice, true);
    _exempt(_alice, true);

    assertTrue(_fund.isExempt(_alice));
    assertEq(_fund.holderCount(), 0);
    assertEq(_fund.heldClasses(_alice), 0);
  }

  function test_WhenTheValueIsUnchanged_NothingIsEmitted() external {
    _exempt(_alice, true);
    vm.recordLogs();
    _exempt(_alice, true);
    _exempt(_bob, false);
    assertEq(vm.getRecordedLogs().length, 0);
  }

  function test_WhenAHolderIsExempted_TheCountFallsAndWhenUnexemptedItRises() external {
    _join(_classA, _alice);
    assertEq(_fund.holderCount(), 1);

    vm.expectEmit(true, false, false, true, address(_fund));
    emit IFund.ExemptSet(_alice, true);
    vm.expectEmit(false, false, false, true, address(_fund));
    emit IFund.HolderCountUpdated(0);
    _exempt(_alice, true);
    assertEq(_fund.holderCount(), 0);
    assertEq(_fund.heldClasses(_alice), 1);

    vm.expectEmit(true, false, false, true, address(_fund));
    emit IFund.ExemptSet(_alice, false);
    vm.expectEmit(false, false, false, true, address(_fund));
    emit IFund.HolderCountUpdated(1);
    _exempt(_alice, false);
    assertEq(_fund.holderCount(), 1);
    assertFalse(_fund.isExempt(_alice));
  }

  function test_WhenAnExemptNonHolderIsUnexempted_TheCountDoesNotMove() external {
    _exempt(_alice, true);
    _exempt(_alice, false);
    assertEq(_fund.holderCount(), 0);
  }

  function test_WhenAnAccountIsExempt_TheFlagIsNotPartOfTheClassMask() external {
    _join(_classA, _alice);
    _exempt(_alice, true);
    assertEq(_fund.heldClasses(_alice), 1);
  }
}

contract FundUnit_Views is FundUnitTest {
  address internal _classA;
  address internal _classB;
  address internal _classC;

  function setUp() public override {
    super.setUp();
    _classA = _registered('classA');
    _classB = _registered('classB');
    _classC = _registered('classC');
  }

  function test_WhenTheClassNumberIsOutOfRange_ClassAtReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_ClassOutOfRange.selector, 0));
    _fund.classAt(0);
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_ClassOutOfRange.selector, 4));
    _fund.classAt(4);
    assertEq(_fund.classAt(3), _classC);
  }

  function test_WhenAdmissionIsRead_ItReturnsEverythingTheRuleNeeds() external {
    vm.prank(_owner);
    _fund.setHolderCap(9);
    _join(_classB, _alice);
    _join(_classC, _alice);
    _join(_classA, _bob);

    (uint256 _index, uint256 _classes, bool _exemptFlag, uint256 _count, uint256 _cap, address _installed) =
      _fund.admission(_classC, _alice);
    assertEq(_index, 3);
    assertEq(_classes, 6);
    assertFalse(_exemptFlag);
    assertEq(_count, 2);
    assertEq(_cap, 9);
    assertEq(_installed, _rule);

    _exempt(_alice, true);
    (, _classes, _exemptFlag, _count,,) = _fund.admission(_classC, _alice);
    assertEq(_classes, 6);
    assertTrue(_exemptFlag);
    assertEq(_count, 1);
  }

  function test_WhenTheRuleIsReplaced_AdmissionReportsTheNewOne() external {
    address _next = makeAddr('next');
    _attest(_next, true);
    vm.prank(_owner);
    _fund.setRule(_next);
    (,,,,, address _installed) = _fund.admission(_classA, _alice);
    assertEq(_installed, _next);
  }

  function test_WhenTheTokenIsNotAClass_AdmissionReportsIndexZero() external {
    (uint256 _index,,,,,) = _fund.admission(makeAddr('unknown'), _alice);
    assertEq(_index, 0);
  }

  function test_WhenTheAccountIsTheZeroAddress_AdmissionReportsNoClasses() external view {
    (uint256 _index, uint256 _classes, bool _exemptFlag,,,) = _fund.admission(_classA, address(0));
    assertEq(_index, 1);
    assertEq(_classes, 0);
    assertFalse(_exemptFlag);
  }

  function test_WhenAnAccountHoldsTwoOfThreeClasses_PositionsListThoseTwoInClassOrder() external {
    _join(_classA, _alice);
    _join(_classC, _alice);
    vm.mockCall(_classA, abi.encodeCall(IERC20.balanceOf, (_alice)), abi.encode(11));
    vm.mockCall(_classC, abi.encodeCall(IERC20.balanceOf, (_alice)), abi.encode(33));

    (address[] memory _tokens, uint256[] memory _balances) = _fund.positionsOf(_alice);
    assertEq(_tokens.length, 2);
    assertEq(_balances.length, 2);
    assertEq(_tokens[0], _classA);
    assertEq(_tokens[1], _classC);
    assertEq(_balances[0], 11);
    assertEq(_balances[1], 33);
  }

  function test_WhenTheAccountHoldsNothing_PositionsAreEmpty() external view {
    (address[] memory _tokens, uint256[] memory _balances) = _fund.positionsOf(_alice);
    assertEq(_tokens.length, 0);
    assertEq(_balances.length, 0);
  }
}

/// @notice A class stub for `registerClass` whose read `WRITING` writes: 1 `policyHook`, 2 `totalSupply`, 0 none
contract FundStatefulClass {
  address public immutable HOOK;
  uint8 public immutable WRITING;
  uint256 public writes;

  constructor(
    address _hook,
    uint8 _writing
  ) {
    HOOK = _hook;
    WRITING = _writing;
  }

  function supportsInterface(
    bytes4 _interfaceId
  ) external pure returns (bool _supported) {
    _supported = _interfaceId == 0x01ffc9a7 || _interfaceId == type(IPolicyGated).interfaceId;
  }

  function policyHook() external returns (address _hook) {
    if (WRITING == 1) ++writes;
    _hook = HOOK;
  }

  function totalSupply() external returns (uint256 _supply) {
    if (WRITING == 2) ++writes;
    _supply = 0;
  }
}

/// @notice A hook stub whose `rules(token)` lists one rule and writes when asked to
contract FundStatefulHook {
  address public immutable RULE;
  bool public immutable WRITES;
  uint256 public writes;

  constructor(
    address _rule,
    bool _writes
  ) {
    RULE = _rule;
    WRITES = _writes;
  }

  function rules(
    address
  ) external returns (IComplianceRule[] memory _list) {
    if (WRITES) ++writes;
    _list = new IComplianceRule[](1);
    _list[0] = IComplianceRule(RULE);
  }
}

/// @notice A registry stub whose `isAttested` writes
contract FundStatefulRegistry {
  uint256 public writes;

  function isAttested(
    address,
    IPolicyRegistry.AttestKind
  ) external returns (bool _attested) {
    ++writes;
    _attested = true;
  }
}

/// @notice Every external read `Fund` makes before it writes goes through a view interface, so it is a STATICCALL: a
///         callee whose read writes makes the call revert, and the same call with a quiet callee succeeds
contract FundUnit_CallsAreStatic is FundUnitTest {
  function _classWithWriteIn(
    uint8 _writing,
    bool _hookWrites
  ) internal returns (address _token) {
    _token = address(new FundStatefulClass(address(new FundStatefulHook(_rule, _hookWrites)), _writing));
  }

  function test_WhenTheClassAndItsHookOnlyRead_RegistrationSucceeds() external {
    _setRule();
    address _token = _classWithWriteIn(0, false);
    vm.prank(_owner);
    _fund.registerClass(_token);
    assertEq(_fund.classIndexOf(_token), 1);
  }

  function test_WhenThePolicyHookReadWrites_RegistrationReverts() external {
    _setRule();
    address _token = _classWithWriteIn(1, false);
    vm.expectRevert(bytes('')); // a write inside a STATICCALL reverts with empty data, bubbled by the fund
    vm.prank(_owner);
    _fund.registerClass(_token);
  }

  function test_WhenTheRulesReadWrites_RegistrationReverts() external {
    _setRule();
    address _token = _classWithWriteIn(0, true);
    vm.expectRevert(bytes('')); // a write inside a STATICCALL reverts with empty data, bubbled by the fund
    vm.prank(_owner);
    _fund.registerClass(_token);
  }

  function test_WhenTheTotalSupplyReadWrites_RegistrationReverts() external {
    _setRule();
    address _token = _classWithWriteIn(2, false);
    vm.expectRevert(bytes('')); // a write inside a STATICCALL reverts with empty data, bubbled by the fund
    vm.prank(_owner);
    _fund.registerClass(_token);
  }

  function test_WhenTheRegistryReadWrites_SetRuleReverts() external {
    FundStatefulRegistry _stateful = new FundStatefulRegistry();
    Fund _own = new Fund(_owner, IPolicyRegistry(address(_stateful)));
    vm.expectRevert(bytes('')); // a write inside a STATICCALL reverts with empty data, bubbled by the fund
    vm.prank(_owner);
    _own.setRule(_rule);
  }
}

/// @notice Random joins, leaves and exemption changes against a plain model of the same rules
contract FundUnit_Model is FundUnitTest {
  uint256 internal constant _CLASSES = 3;
  uint256 internal constant _ACCOUNTS = 4;
  uint256 internal constant _OPS = 40;

  address[] internal _tokens;
  address[] internal _accounts;
  bool[_CLASSES][_ACCOUNTS] internal _held;
  bool[_ACCOUNTS] internal _isExempt;

  function setUp() public override {
    super.setUp();
    for (uint256 _i; _i < _CLASSES; ++_i) {
      _tokens.push(_registered(string.concat('class', vm.toString(_i))));
    }
    _accounts.push(_alice);
    _accounts.push(_bob);
    _accounts.push(makeAddr('carol'));
    _accounts.push(makeAddr('dave'));
    vm.prank(_owner);
    _fund.setHolderCap(7);
  }

  function testFuzz_WhenOperationsApply_CountAndMasksMatchTheModel(
    uint256 _seed
  ) external {
    for (uint256 _op; _op < _OPS; ++_op) {
      uint256 _r = uint256(keccak256(abi.encode(_seed, _op)));
      uint256 _c = (_r >> 8) % _CLASSES;
      uint256 _a = (_r >> 16) % _ACCOUNTS;
      uint256 _kind = _r % 3;
      if (_kind == 0) {
        _join(_tokens[_c], _accounts[_a]);
        _held[_a][_c] = true;
      } else if (_kind == 1) {
        _leave(_tokens[_c], _accounts[_a]);
        _held[_a][_c] = false;
      } else {
        bool _flag = (_r >> 24) % 2 == 0;
        _exempt(_accounts[_a], _flag);
        _isExempt[_a] = _flag;
      }
      _assertMatchesModel();
    }
  }

  function _assertMatchesModel() internal view {
    uint256 _expectedCount;
    for (uint256 _a; _a < _ACCOUNTS; ++_a) {
      uint256 _mask;
      for (uint256 _c; _c < _CLASSES; ++_c) {
        if (_held[_a][_c]) _mask |= 1 << _c;
      }
      assertEq(_fund.heldClasses(_accounts[_a]), _mask, 'mask');
      assertEq(_fund.isExempt(_accounts[_a]), _isExempt[_a], 'exempt');
      if (_mask != 0 && !_isExempt[_a]) ++_expectedCount;
    }
    assertEq(_fund.holderCount(), _expectedCount, 'count');
    // They share a slot with the count, so no join, leave or exemption may touch them.
    assertEq(_fund.rule(), _rule, 'rule');
    assertEq(_fund.holderCap(), 7, 'cap');
  }
}

/// @notice The monitor's views: a class is intact when it is registered and its hook still lists the fund's rule
contract FundUnit_ClassIntegrity is FundUnitTest {
  address internal _otherRule = makeAddr('otherRule');

  function _hookOf(
    address _token
  ) internal view returns (address _hook) {
    _hook = IPolicyGated(_token).policyHook();
  }

  /// @dev Replaces the rule list the class's hook reports
  function _break(
    address _token
  ) internal {
    _hookLists(_hookOf(_token), _otherRule);
  }

  function test_WhenTheTokenIsNotAClass_ItIsNotIntact() external {
    _setRule();
    address _unregistered = _newClass('unregistered'); // passes every check, but is never registered
    assertFalse(_fund.isClassIntact(_unregistered));
    assertFalse(_fund.isClassIntact(address(0)));
  }

  function test_WhenTheHookListsTheInstalledRule_TheClassIsIntact() external {
    address _token = _registered('alpha');
    assertTrue(_fund.isClassIntact(_token));
  }

  function test_WhenTheHookListsTheRuleAmongOthers_TheClassIsIntact() external {
    address _token = _registered('alpha');
    IComplianceRule[] memory _list = new IComplianceRule[](3);
    _list[0] = IComplianceRule(_otherRule);
    _list[1] = IComplianceRule(_rule);
    _list[2] = IComplianceRule(makeAddr('another'));
    vm.mockCall(_hookOf(_token), abi.encodeWithSelector(IComplianceHook.rules.selector), abi.encode(_list));
    assertTrue(_fund.isClassIntact(_token));
  }

  /// @dev The documented hazard: dropping the fund rule from a registered class un-caps it silently
  function test_WhenTheHookNoLongerListsTheRule_TheClassIsNotIntact() external {
    address _token = _registered('alpha');
    _break(_token);
    assertFalse(_fund.isClassIntact(_token));
  }

  function test_WhenTheHookListsNothing_TheClassIsNotIntact() external {
    address _token = _registered('alpha');
    vm.mockCall(
      _hookOf(_token), abi.encodeWithSelector(IComplianceHook.rules.selector), abi.encode(new IComplianceRule[](0))
    );
    assertFalse(_fund.isClassIntact(_token));
  }

  /// @dev Replacing the rule breaks every class whose hook lists only the old one, until the hook lists the new one
  function test_WhenTheRuleIsReplaced_EveryClassIsBrokenUntilItsHookListsTheNewOne() external {
    address _first = _registered('alpha');
    address _second = _registered('beta');
    _attest(_otherRule, true);
    vm.prank(_owner);
    _fund.setRule(_otherRule);
    assertFalse(_fund.isClassIntact(_first));
    assertFalse(_fund.isClassIntact(_second));

    _hookLists(_hookOf(_first), _otherRule);
    assertTrue(_fund.isClassIntact(_first));
    assertFalse(_fund.isClassIntact(_second));
    _hookLists(_hookOf(_second), _otherRule);
    assertTrue(_fund.isClassIntact(_second));
  }

  /// @dev A monitor that reverts on the very thing it watches is no monitor: a hook that cannot answer is a broken class
  function test_WhenTheHookReverts_TheClassIsNotIntactAndTheViewDoesNotRevert() external {
    address _token = _registered('alpha');
    vm.mockCallRevert(_hookOf(_token), abi.encodeWithSelector(IComplianceHook.rules.selector), 'no rules');
    assertFalse(_fund.isClassIntact(_token));
    assertEq(_fund.firstBrokenClass(), _token);
  }

  function test_WhenTheTokenCannotNameItsHook_TheClassIsNotIntactAndTheViewDoesNotRevert() external {
    address _token = _registered('alpha');
    vm.mockCallRevert(_token, abi.encodeCall(IPolicyGated.policyHook, ()), 'no hook');
    assertFalse(_fund.isClassIntact(_token));
    assertEq(_fund.firstBrokenClass(), _token);
  }

  function test_WhenThereAreNoClasses_FirstBrokenClassIsZero() external view {
    assertEq(_fund.firstBrokenClass(), address(0));
  }

  function test_WhenEveryClassIsIntact_FirstBrokenClassIsZero() external {
    _registered('alpha');
    _registered('beta');
    _registered('gamma');
    assertEq(_fund.firstBrokenClass(), address(0));
  }

  /// @dev In registration order, not in address order
  function test_WhenSeveralClassesAreBroken_TheFirstRegisteredIsReturned() external {
    address _first = _registered('alpha');
    address _second = _registered('beta');
    address _third = _registered('gamma');
    _break(_third);
    assertEq(_fund.firstBrokenClass(), _third);
    _break(_second);
    assertEq(_fund.firstBrokenClass(), _second);
    _break(_first);
    assertEq(_fund.firstBrokenClass(), _first);

    _hookLists(_hookOf(_first), _rule);
    assertEq(_fund.firstBrokenClass(), _second);
  }

  /// @dev The whole decision as a property: the lowest broken class number, or none
  function testFuzz_WhenAnySubsetIsBroken_TheLowestRegisteredBrokenClassIsReturned(
    uint256 _count,
    uint256 _mask
  ) external {
    _count = bound(_count, 1, 12);
    address[] memory _tokens = new address[](_count);
    for (uint256 _i; _i < _count; ++_i) {
      _tokens[_i] = _registered(string.concat('class', vm.toString(_i)));
    }
    address _expected;
    for (uint256 _i = _count; _i > 0; --_i) {
      if (_mask >> (_i - 1) & 1 == 1) {
        _break(_tokens[_i - 1]);
        _expected = _tokens[_i - 1];
      }
    }
    assertEq(_fund.firstBrokenClass(), _expected);
    for (uint256 _i; _i < _count; ++_i) {
      assertEq(_fund.isClassIntact(_tokens[_i]), _mask >> _i & 1 == 0);
    }
  }

  function test_WhenCalledWithStaticcall_NothingIsWritten() external {
    address _token = _registered('alpha');
    (bool _ok, bytes memory _out) = address(_fund).staticcall(abi.encodeCall(IFund.isClassIntact, (_token)));
    assertTrue(_ok);
    assertTrue(abi.decode(_out, (bool)));
    (_ok, _out) = address(_fund).staticcall(abi.encodeCall(IFund.firstBrokenClass, ()));
    assertTrue(_ok);
    assertEq(abi.decode(_out, (address)), address(0));
  }
}
