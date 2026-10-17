// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import {stdError} from 'forge-std/StdError.sol';
import {Test} from 'forge-std/Test.sol';
import {Vm} from 'forge-std/Vm.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IMaxHoldersRule} from 'interfaces/IMaxHoldersRule.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {MaxHoldersRule} from 'contracts/hooks/rules/MaxHoldersRule.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockStatefulToken} from 'contracts/test/MockStatefulToken.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';

contract MaxHoldersRuleUnitTest is Helpers {
  bytes32 internal constant _ADMIN_ROLE = 0x00;

  MaxHoldersRule internal _rule;
  address internal _token;
  address internal _hook = makeAddr('hook');
  address internal _admin = makeAddr('timelock');
  address internal _stranger = makeAddr('stranger');
  address internal _from = makeAddr('from');
  address internal _to = makeAddr('to');

  function setUp() public virtual {
    _token = _mockContract('token');
    vm.mockCall(_token, abi.encodeCall(IAccessControl.hasRole, (_ADMIN_ROLE, _admin)), abi.encode(true));
    vm.mockCall(_token, abi.encodeCall(IAccessControl.hasRole, (_ADMIN_ROLE, _stranger)), abi.encode(false));
    vm.mockCall(_token, abi.encodeCall(IPolicyGated.policyHook, ()), abi.encode(_hook));
    _rule = new MaxHoldersRule();
  }

  function _bal(
    address _account,
    uint256 _amount
  ) internal {
    vm.mockCall(_token, abi.encodeCall(IERC20.balanceOf, (_account)), abi.encode(_amount));
  }

  function _cap(
    uint256 _value
  ) internal {
    vm.prank(_admin);
    _rule.setCap(_token, _value);
  }

  function _seed(
    uint256 _count
  ) internal {
    vm.prank(_admin);
    _rule.seedHolderCount(_token, _count);
  }

  function _ctx(
    IPolicyHook.TransferKind _kind,
    address _sender,
    address _receiver,
    uint256 _amount
  ) internal view returns (IPolicyHook.TransferContext memory _context) {
    _context = IPolicyHook.TransferContext({
      token: _token,
      from: _sender,
      to: _receiver,
      id: 0,
      amount: _amount,
      operator: _sender,
      kind: _kind,
      ref: bytes32(0),
      deadline: 0,
      extra: ''
    });
  }

  function _exempt(
    address _account,
    bool _isExempt
  ) internal {
    vm.prank(_admin);
    _rule.setExemptHolder(_token, _account, _isExempt);
  }

  /// @dev Maps a fuzzed seed onto TRANSFER or EXECUTED, the holder-driven kinds that are capped
  function _holderKind(
    uint8 _seedValue
  ) internal pure returns (IPolicyHook.TransferKind _kind) {
    _kind = IPolicyHook.TransferKind(bound(_seedValue, 0, 1));
  }

  function _after(
    IPolicyHook.TransferContext memory _context
  ) internal {
    vm.prank(_hook);
    _rule.after_(_context);
  }
}

contract MaxHoldersRuleUnit_Admin is MaxHoldersRuleUnitTest {
  function test_WhenCallerIsNotTheTokensAdmin_SetCapReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IMaxHoldersRule.MaxHoldersRule_OnlyTokenAdmin.selector, _token, _stranger));
    vm.prank(_stranger);
    _rule.setCap(_token, 10);
  }

  function test_WhenCallerIsNotTheTokensAdmin_SeedReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IMaxHoldersRule.MaxHoldersRule_OnlyTokenAdmin.selector, _token, _stranger));
    vm.prank(_stranger);
    _rule.seedHolderCount(_token, 10);
  }

  function test_WhenTheAdminSetsTheCap_ItStoresAndEmits(
    uint256 _first,
    uint256 _second
  ) external {
    _cap(_first);
    vm.expectEmit(address(_rule));
    emit IMaxHoldersRule.CapSet(_token, _first, _second);
    _cap(_second);
    assertEq(_rule.capOf(_token), _second);
  }

  function test_WhenTheAdminSeeds_ItOverwritesAtAnyTimeAndEmits(
    uint256 _first,
    uint256 _second
  ) external {
    _seed(_first);
    vm.expectEmit(address(_rule));
    emit IMaxHoldersRule.HolderCountSeeded(_token, _first, _second);
    _seed(_second);
    assertEq(_rule.holderCount(_token), _second);
  }
}

contract MaxHoldersRuleUnit_Exemptions is MaxHoldersRuleUnitTest {
  function test_WhenCallerIsNotTheTokensAdmin_SetExemptHolderReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IMaxHoldersRule.MaxHoldersRule_OnlyTokenAdmin.selector, _token, _stranger));
    vm.prank(_stranger);
    _rule.setExemptHolder(_token, _to, true);
  }

  function test_WhenTheAccountIsZero_SetExemptHolderReverts() external {
    vm.expectRevert(IMaxHoldersRule.MaxHoldersRule_ZeroAddress.selector);
    _exempt(address(0), true);
  }

  function test_WhenAnEmptyAccountIsExempted_ItStoresAndEmitsWithoutTouchingTheCount() external {
    _seed(2);
    _bal(_to, 0);
    vm.expectEmit(address(_rule));
    emit IMaxHoldersRule.HolderExemptionSet(_token, _to, true);
    _exempt(_to, true);
    assertTrue(_rule.isExemptHolder(_token, _to));
    assertEq(_rule.holderCount(_token), 2);
  }

  /// @dev "Never counts" must hold even when the exemption changes while the account holds a balance
  function test_WhenAHolderIsExemptedAndUnexempted_TheCountFollows() external {
    _seed(2);
    _bal(_to, 5);
    vm.expectEmit(address(_rule));
    emit IMaxHoldersRule.HolderCountUpdated(_token, 1);
    _exempt(_to, true);
    assertEq(_rule.holderCount(_token), 1);
    _exempt(_to, false);
    assertEq(_rule.holderCount(_token), 2);
  }

  function test_WhenTheExemptionIsUnchanged_NothingHappens() external {
    _seed(2);
    _bal(_to, 5);
    _exempt(_to, true);
    _exempt(_to, true);
    assertEq(_rule.holderCount(_token), 1);
  }

  /// @dev R1: an empty escrow vault at a full cap must still accept a redemption request
  function test_WhenTheReceiverIsExemptAtAFullCap_ItIsOk(
    uint8 _kindSeed
  ) external {
    _cap(2);
    _seed(2);
    _bal(_to, 0);
    _bal(_from, 10);
    _exempt(_to, true);
    assertEq(_rule.check(_ctx(_holderKind(_kindSeed), _from, _to, 3)), Reasons.TRANSFER_OK);
  }

  /// @dev An exempt sender was never counted, so its full exit frees no slot for a new holder
  function test_WhenAnExemptSenderEmptiesIntoANewHolderAtAFullCap_ItIsRejected() external {
    _cap(2);
    _seed(3); // includes the sender, which then becomes exempt: the count drops to 2, a full cap
    _bal(_from, 7);
    _exempt(_from, true);
    assertEq(_rule.holderCount(_token), 2);
    _bal(_to, 0);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, 7)), Reasons.MAX_HOLDERS);
  }

  /// @dev A holder escrowing everything into the exempt vault leaves; the vault never joins
  function test_WhenSharesMoveIntoAnExemptAccount_TheCountIgnoresIt() external {
    _bal(_to, 0);
    _exempt(_to, true); // empty, so no count adjustment
    _seed(1);
    _bal(_from, 0);
    _bal(_to, 4);
    _after(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, 4));
    assertEq(_rule.holderCount(_token), 0);
  }

  /// @dev The escrow vault burning its last shares at fulfilment must not decrement the count
  function test_WhenAnExemptAccountEmpties_TheCountIgnoresIt() external {
    _seed(2);
    _bal(_from, 3);
    _exempt(_from, true); // holds a balance, so the count drops to 1
    _bal(_from, 0);
    _after(_ctx(IPolicyHook.TransferKind.BURN, _from, address(0), 3));
    assertEq(_rule.holderCount(_token), 1);
  }
}

contract MaxHoldersRuleUnit_FakeToken is MaxHoldersRuleUnitTest {
  /// @dev Sound because state is keyed by token: a fake token can only authorise writes to its own key
  function test_WhenAFakeTokenAuthorisesAnAttacker_OnlyTheFakeTokensKeyChanges() external {
    _cap(3);
    _seed(2);
    address _fakeToken = _mockContract('fakeToken');
    address _attacker = makeAddr('attacker');
    vm.mockCall(_fakeToken, abi.encodeCall(IAccessControl.hasRole, (_ADMIN_ROLE, _attacker)), abi.encode(true));
    vm.mockCall(_fakeToken, abi.encodeCall(IPolicyGated.policyHook, ()), abi.encode(_attacker));
    vm.mockCall(_fakeToken, abi.encodeCall(IERC20.balanceOf, (_to)), abi.encode(uint256(1)));

    vm.startPrank(_attacker);
    _rule.setCap(_fakeToken, type(uint256).max);
    _rule.seedHolderCount(_fakeToken, 1000);
    IPolicyHook.TransferContext memory _fakeCtx = _ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 1);
    _fakeCtx.token = _fakeToken;
    _rule.after_(_fakeCtx);
    vm.stopPrank();

    assertEq(_rule.capOf(_fakeToken), type(uint256).max);
    assertEq(_rule.holderCount(_fakeToken), 1001);
    assertEq(_rule.capOf(_token), 3);
    assertEq(_rule.holderCount(_token), 2);
  }
}

contract MaxHoldersRuleUnit_Check is MaxHoldersRuleUnitTest {
  function test_WhenTheAmountIsZero_ItIsOkEvenUnconfigured() external view {
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 0)), Reasons.TRANSFER_OK);
  }

  function test_WhenSendingToSelf_ItIsOk() external view {
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _from, 5)), Reasons.TRANSFER_OK);
  }

  function test_WhenBurning_ItIsOkEvenUnconfigured() external view {
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.BURN, _from, address(0), 5)), Reasons.TRANSFER_OK);
  }

  /// @dev A lowered cap never blocks existing holders
  function test_WhenTheReceiverAlreadyHolds_ItIsOkEvenAboveTheCap(
    uint8 _kindSeed
  ) external {
    _cap(5);
    _seed(10);
    _bal(_to, 1);
    assertEq(_rule.check(_ctx(_holderKind(_kindSeed), _from, _to, 3)), Reasons.TRANSFER_OK);
  }

  function test_WhenForcedToANewHolderAtTheCap_ItIsOk() external {
    _cap(3);
    _seed(3);
    _bal(_to, 0);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.FORCED, _from, _to, 3)), Reasons.TRANSFER_OK);
  }

  function test_WhenTheCapIsZero_ANewHolderFailsClosed() external {
    _bal(_to, 0);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 1)), Reasons.MAX_HOLDERS);
  }

  function test_WhenMintingToANewHolder_ItIsOkBelowTheCapAndRejectedAtIt(
    uint256 _capValue
  ) external {
    _capValue = bound(_capValue, 1, 1_000_000);
    _cap(_capValue);
    _bal(_to, 0);
    _seed(_capValue - 1);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 1)), Reasons.TRANSFER_OK);
    _seed(_capValue);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 1)), Reasons.MAX_HOLDERS);
  }

  function test_WhenTheSenderLeavesForANewHolderAtTheCap_ItIsOkNet(
    uint8 _kindSeed,
    uint256 _amount
  ) external {
    _amount = bound(_amount, 1, type(uint128).max);
    _cap(3);
    _seed(3);
    _bal(_to, 0);
    _bal(_from, _amount);
    assertEq(_rule.check(_ctx(_holderKind(_kindSeed), _from, _to, _amount)), Reasons.TRANSFER_OK);
  }

  function test_WhenTheSenderStaysAndANewHolderWouldExceedTheCap_ItIsRejected(
    uint8 _kindSeed,
    uint256 _amount,
    uint256 _extra
  ) external {
    _amount = bound(_amount, 1, type(uint128).max);
    _extra = bound(_extra, 1, type(uint128).max);
    _cap(3);
    _seed(3);
    _bal(_to, 0);
    _bal(_from, _amount + _extra);
    assertEq(_rule.check(_ctx(_holderKind(_kindSeed), _from, _to, _amount)), Reasons.MAX_HOLDERS);
  }

  function test_WhenTheCountIsAboveALoweredCap_ANetZeroMoveIsStillRejected() external {
    _cap(2);
    _seed(3);
    _bal(_to, 0);
    _bal(_from, 7);
    assertEq(_rule.check(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, 7)), Reasons.MAX_HOLDERS);
  }

  function test_WhenCalledWithStaticcall_ItDoesNotWrite() external {
    _cap(1);
    _bal(_to, 0);
    (bool _ok, bytes memory _out) = address(_rule)
      .staticcall(abi.encodeCall(IComplianceRule.check, (_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 1))));
    assertTrue(_ok);
    assertEq(abi.decode(_out, (bytes32)), Reasons.TRANSFER_OK);
  }
}

contract MaxHoldersRuleUnit_After is MaxHoldersRuleUnitTest {
  function test_WhenCallerIsNotTheTokensHook_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IComplianceRule.ComplianceRule_OnlyHook.selector, _stranger));
    vm.prank(_stranger);
    _rule.after_(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 1));
  }

  function test_WhenMintingToANewHolder_ItCountsAndEmits(
    uint256 _amount
  ) external {
    _amount = bound(_amount, 1, type(uint128).max);
    _bal(_to, _amount);
    vm.expectEmit(address(_rule));
    emit IMaxHoldersRule.HolderCountUpdated(_token, 1);
    _after(_ctx(IPolicyHook.TransferKind.MINT, address(0), _to, _amount));
    assertEq(_rule.holderCount(_token), 1);
  }

  function test_WhenAFullBalanceMovesToANewHolder_TheCountIsUnchangedAndSilent() external {
    _seed(2);
    _bal(_to, 7);
    _bal(_from, 0);
    vm.recordLogs();
    _after(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, 7));
    assertEq(_rule.holderCount(_token), 2);
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    assertEq(_logs.length, 0);
  }

  function test_WhenAPartialAmountMovesToAnExistingHolder_TheCountIsUnchanged() external {
    _seed(2);
    _bal(_to, 12);
    _bal(_from, 3);
    _after(_ctx(IPolicyHook.TransferKind.EXECUTED, _from, _to, 7));
    assertEq(_rule.holderCount(_token), 2);
  }

  function test_WhenAHolderBurnsEverything_ItLeaves() external {
    _seed(2);
    _bal(_from, 0);
    _after(_ctx(IPolicyHook.TransferKind.BURN, _from, address(0), 5));
    assertEq(_rule.holderCount(_token), 1);
  }

  /// @dev P4: FORCED bypasses the cap check but is still counted
  function test_WhenForcedToANewHolderAboveTheCap_ItIsStillCounted() external {
    _cap(2);
    _seed(2);
    _bal(_to, 4);
    _bal(_from, 6);
    _after(_ctx(IPolicyHook.TransferKind.FORCED, _from, _to, 4));
    assertEq(_rule.holderCount(_token), 3);
  }

  function test_WhenTheAmountIsZeroOrSelf_NothingIsRead() external {
    _seed(2);
    vm.expectCall(_token, abi.encodeWithSelector(IERC20.balanceOf.selector), 0);
    _after(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _to, 0));
    _after(_ctx(IPolicyHook.TransferKind.TRANSFER, _from, _from, 5));
    assertEq(_rule.holderCount(_token), 2);
  }

  /// @dev An active rule with an unseeded count fails closed instead of drifting
  function test_WhenTheCountIsUnseededAndAHolderLeaves_ItReverts() external {
    _bal(_from, 0);
    vm.expectRevert(stdError.arithmeticError);
    vm.prank(_hook);
    _rule.after_(_ctx(IPolicyHook.TransferKind.BURN, _from, address(0), 5));
  }
}

contract MaxHoldersRuleUnit_Metadata is MaxHoldersRuleUnitTest {
  function test_WhenQueried_ItReturnsItsMetadata() external view {
    assertEq(_rule.ruleId(), keccak256('MaxHoldersRule.v1'));
    assertTrue(_rule.wantsAfter());
    assertTrue(_rule.supportsInterface(type(IComplianceRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(IMaxHoldersRule).interfaceId));
    assertTrue(_rule.supportsInterface(type(IERC165).interfaceId));
  }
}

/// @notice Drives mint, transfer, forced and burn moves on a real token for the holder-count invariant
contract MaxHoldersHandler is Test {
  IntentToken internal _token;
  MaxHoldersRule internal _rule;
  address[4] internal _actors;

  constructor(
    IntentToken _target,
    MaxHoldersRule _maxHoldersRule
  ) {
    _token = _target;
    _rule = _maxHoldersRule;
    _actors = [makeAddr('actor0'), makeAddr('actor1'), makeAddr('actor2'), makeAddr('actor3')];
  }

  function actors() external view returns (address[4] memory _all) {
    _all = _actors;
  }

  function mint(
    uint256 _to,
    uint256 _amount
  ) external {
    _token.mint(_actor(_to), bound(_amount, 0, 1e24));
  }

  function transfer(
    uint256 _from,
    uint256 _to,
    uint256 _amount
  ) external {
    address _sender = _actor(_from);
    vm.prank(_sender);
    _token.transfer(_actor(_to), bound(_amount, 0, _token.balanceOf(_sender)));
  }

  /// @dev Freezes change which moves succeed, never the holder count
  function setFrozen(
    uint256 _user,
    uint256 _amount
  ) external {
    address _account = _actor(_user);
    _token.setFrozen(_account, bound(_amount, 0, _token.balanceOf(_account)));
  }

  /// @dev Exemption changes move a current holder in or out of the count
  function setExempt(
    uint256 _seed,
    bool _isExempt
  ) external {
    _rule.setExemptHolder(address(_token), _actor(_seed), _isExempt);
  }

  /// @dev Cap changes, including lowering it below the current count, never change the holder count
  function setCap(
    uint256 _cap
  ) external {
    _rule.setCap(address(_token), bound(_cap, 0, 5));
  }

  function forcedTransfer(
    uint256 _from,
    uint256 _to,
    uint256 _amount
  ) external {
    address _sender = _actor(_from);
    _token.forcedTransfer(_sender, _actor(_to), bound(_amount, 0, _token.balanceOf(_sender)));
  }

  function burn(
    uint256 _from,
    uint256 _amount
  ) external {
    address _sender = _actor(_from);
    _token.burn(_sender, bound(_amount, 0, _token.balanceOf(_sender)));
  }

  function _actor(
    uint256 _seed
  ) internal view returns (address _account) {
    _account = _actors[_seed % 4];
  }
}

/// @notice Invariant on a real token: the tracked count always equals the number of accounts with balance > 0
contract MaxHoldersRuleInvariantTest is Test {
  MaxHoldersRule internal _rule;
  IntentToken internal _token;
  MaxHoldersHandler internal _handler;

  function setUp() public {
    // Configure, then hand over: this test is the token admin while it configures, as the deploy module will be.
    PolicyRegistry _registry = new PolicyRegistry(address(this), address(this));
    _rule = new MaxHoldersRule();
    _registry.attest(address(_rule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    IntentToken _impl = new IntentToken();
    IComplianceRule[] memory _rules = new IComplianceRule[](1);
    _rules[0] = _rule;
    address _predictedProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
    ComplianceHook _hook = new ComplianceHook(address(this), _registry, _predictedProxy, _rules);
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _token = IntentToken(
      address(
        new ERC1967Proxy(
          address(_impl),
          abi.encodeCall(
            IntentToken.initialize, ('Capped', 'CAP', address(this), address(this), address(_registry), address(_hook))
          )
        )
      )
    );
    _rule.setCap(address(_token), 3); // below the 4 actors, so rejections are exercised

    _handler = new MaxHoldersHandler(_token, _rule);
    _token.grantRole(_token.MINTER_ROLE(), address(_handler));
    _token.grantRole(_token.BURNER_ROLE(), address(_handler));
    _token.grantRole(_token.AGENT_ROLE(), address(_handler));
    _token.grantRole(_token.DEFAULT_ADMIN_ROLE(), address(_handler)); // so the handler can change the cap
    targetContract(address(_handler));
  }

  function invariant_TheCountEqualsTheNumberOfNonExemptHolders() external view {
    address[4] memory _all = _handler.actors();
    uint256 _holders;
    for (uint256 _i; _i < 4; ++_i) {
      if (_token.balanceOf(_all[_i]) > 0 && !_rule.isExemptHolder(address(_token), _all[_i])) ++_holders;
    }
    assertEq(_rule.holderCount(address(_token)), _holders);
  }
}

/// @dev Aderyn `reentrancy-state-change` is a false positive: the token is read through STATICCALL
contract MaxHoldersRuleUnit_TokenCallsAreStatic is MaxHoldersRuleUnitTest {
  function test_WhenTheTokenTriesToWriteDuringTheRoleCheck_AdminWritesRevert() external {
    MockStatefulToken _stateful = new MockStatefulToken();
    vm.startPrank(_admin);
    vm.expectRevert();
    _rule.setCap(address(_stateful), 3);
    vm.expectRevert();
    _rule.seedHolderCount(address(_stateful), 1);
    vm.expectRevert();
    _rule.setExemptHolder(address(_stateful), _to, true);
    vm.stopPrank();
  }

  function test_WhenTheTokenTriesToWriteDuringTheHookOrBalanceRead_AfterReverts() external {
    MockStatefulToken _stateful = new MockStatefulToken();
    IPolicyHook.TransferContext memory _ctxStateful = _ctx(IPolicyHook.TransferKind.MINT, address(0), _to, 1);
    _ctxStateful.token = address(_stateful);
    vm.expectRevert();
    _rule.after_(_ctxStateful);
    assertEq(_rule.holderCount(address(_stateful)), 0);
  }
}
