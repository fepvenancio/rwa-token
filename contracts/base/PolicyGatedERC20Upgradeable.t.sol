// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {Initializable} from '@openzeppelin/contracts/proxy/utils/Initializable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import {Test} from 'forge-std/Test.sol';
import {Vm} from 'forge-std/Vm.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC7943Fungible} from 'interfaces/IERC7943Fungible.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';

import {Helpers} from 'contracts/test/Helpers.sol';
import {PolicyGatedHarness} from 'contracts/test/PolicyGatedHarness.sol';

contract PolicyGatedUnitTest is Helpers {
  bytes32 internal constant _PERMIT_TYPEHASH =
    keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)');

  PolicyGatedHarness internal _token;
  address internal _registry;
  address internal _hook;

  address internal _admin = makeAddr('timelock');
  address internal _guardian = makeAddr('guardian');
  address internal _minter = makeAddr('minter');
  address internal _burner = makeAddr('burner');
  address internal _agent = makeAddr('agent');
  address internal _upgrader = makeAddr('upgrader');
  address internal _stranger = makeAddr('stranger');
  address internal _bob = makeAddr('bob');
  address internal _alice;
  uint256 internal _alicePk;

  uint256 internal constant _INITIAL = 1000 ether;

  function setUp() public virtual {
    (_alice, _alicePk) = makeAddrAndKey('alice');
    _registry = _mockContract('registry');
    _hook = _mockContract('hook');
    _attested(_hook, IPolicyRegistry.AttestKind.HOOK, true);
    _hookNamesRegistry(_hook, _registry);
    _hookAccountChecksDecide(Reasons.TRANSFER_OK, Reasons.TRANSFER_OK);
    _hookDecides(Reasons.TRANSFER_OK);
    vm.mockCall(_hook, abi.encodeCall(IPolicyHook.wantsAfter, ()), abi.encode(false));

    _token = _deploy(_hook);

    vm.startPrank(_admin);
    _token.grantRole(_token.MINTER_ROLE(), _minter);
    _token.grantRole(_token.BURNER_ROLE(), _burner);
    _token.grantRole(_token.AGENT_ROLE(), _agent);
    _token.grantRole(_token.UPGRADER_ROLE(), _upgrader);
    vm.stopPrank();

    vm.prank(_minter);
    _token.mint(_alice, _INITIAL);
  }

  function _deploy(
    address _initialHook
  ) internal returns (PolicyGatedHarness _proxy) {
    PolicyGatedHarness _impl = new PolicyGatedHarness();
    _proxy = PolicyGatedHarness(
      address(
        new ERC1967Proxy(
          address(_impl),
          abi.encodeCall(
            PolicyGatedHarness.initialize, ('Gated', 'GTD', _admin, _guardian, _registry, _initialHook, _noRules())
          )
        )
      )
    );
  }

  function _attested(
    address _target,
    IPolicyRegistry.AttestKind _kind,
    bool _isAttested
  ) internal {
    vm.mockCall(_registry, abi.encodeCall(IPolicyRegistry.isAttested, (_target, _kind)), abi.encode(_isAttested));
  }

  /// @dev A hook names the registry it vets rules against; the token requires it to be its own
  function _hookNamesRegistry(
    address _hookAddress,
    address _namedRegistry
  ) internal {
    vm.mockCall(_hookAddress, abi.encodeCall(IComplianceHook.REGISTRY, ()), abi.encode(_namedRegistry));
  }

  /// @dev The hook's account-level answers, which `canSend` and `canReceive` are built from
  function _hookAccountChecksDecide(
    bytes32 _sendReason,
    bytes32 _receiveReason
  ) internal {
    vm.mockCall(_hook, abi.encodeWithSelector(IPolicyHook.checkSend.selector), abi.encode(_sendReason));
    vm.mockCall(_hook, abi.encodeWithSelector(IPolicyHook.checkReceive.selector), abi.encode(_receiveReason));
  }

  function _noRules() internal pure returns (IComplianceRule[] memory _ruleSet) {
    _ruleSet = new IComplianceRule[](0);
  }

  function _hookDecides(
    bytes32 _reason
  ) internal {
    vm.mockCall(_hook, abi.encodeWithSelector(IPolicyHook.beforeTransfer.selector), abi.encode(_reason));
  }

  function _ctx(
    address _from,
    address _to,
    uint256 _amount,
    address _operator,
    IPolicyHook.TransferKind _kind
  ) internal view returns (IPolicyHook.TransferContext memory _context) {
    _context = IPolicyHook.TransferContext({
      token: address(_token),
      from: _from,
      to: _to,
      id: 0,
      amount: _amount,
      operator: _operator,
      kind: _kind,
      extra: _balances(_from, _to)
    });
  }

  /// @dev The `extra` the token builds for every kind: the balances before the move, zero for the zero address
  function _balances(
    address _from,
    address _to
  ) internal view returns (bytes memory _extra) {
    _extra =
      abi.encode(_from == address(0) ? 0 : _token.balanceOf(_from), _to == address(0) ? 0 : _token.balanceOf(_to));
  }

  function _unauthorized(
    address _caller,
    bytes32 _role
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role);
  }

  function _rejected(
    bytes32 _reason
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IPolicyGated.PolicyGated_TransferRejected.selector, _reason);
  }
}

contract PolicyGatedUnit_Initialize is PolicyGatedUnitTest {
  function test_WhenAdminIsZero_ItReverts() external {
    PolicyGatedHarness _impl = new PolicyGatedHarness();
    vm.expectRevert(IPolicyGated.PolicyGated_ZeroAddress.selector);
    new ERC1967Proxy(
      address(_impl),
      abi.encodeCall(PolicyGatedHarness.initialize, ('G', 'G', address(0), _guardian, _registry, _hook, _noRules()))
    );
  }

  function test_WhenGuardianIsZero_ItReverts() external {
    PolicyGatedHarness _impl = new PolicyGatedHarness();
    vm.expectRevert(IPolicyGated.PolicyGated_ZeroAddress.selector);
    new ERC1967Proxy(
      address(_impl),
      abi.encodeCall(PolicyGatedHarness.initialize, ('G', 'G', _admin, address(0), _registry, _hook, _noRules()))
    );
  }

  function test_WhenRegistryIsZero_ItReverts() external {
    PolicyGatedHarness _impl = new PolicyGatedHarness();
    vm.expectRevert(IPolicyGated.PolicyGated_ZeroAddress.selector);
    new ERC1967Proxy(
      address(_impl),
      abi.encodeCall(PolicyGatedHarness.initialize, ('G', 'G', _admin, _guardian, address(0), _hook, _noRules()))
    );
  }

  function test_WhenHookIsZero_ItReverts() external {
    PolicyGatedHarness _impl = new PolicyGatedHarness();
    vm.expectRevert(IPolicyGated.PolicyGated_ZeroAddress.selector);
    new ERC1967Proxy(
      address(_impl),
      abi.encodeCall(PolicyGatedHarness.initialize, ('G', 'G', _admin, _guardian, _registry, address(0), _noRules()))
    );
  }

  function test_WhenHookIsNotAttested_ItReverts() external {
    address _rogue = _mockContract('rogue');
    _attested(_rogue, IPolicyRegistry.AttestKind.HOOK, false);
    PolicyGatedHarness _impl = new PolicyGatedHarness();
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_NotAttested.selector, _rogue, IPolicyRegistry.AttestKind.HOOK)
    );
    new ERC1967Proxy(
      address(_impl),
      abi.encodeCall(PolicyGatedHarness.initialize, ('G', 'G', _admin, _guardian, _registry, _rogue, _noRules()))
    );
  }

  function test_WhenValid_ItWiresRolesRegistryAndHook() external view {
    assertTrue(_token.hasRole(_token.DEFAULT_ADMIN_ROLE(), _admin));
    assertTrue(_token.hasRole(_token.GUARDIAN_ROLE(), _guardian));
    assertEq(_token.registry(), _registry);
    assertEq(_token.policyHook(), _hook);
  }

  function test_WhenCalledTwice_ItReverts() external {
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    _token.initialize('G', 'G', _admin, _guardian, _registry, _hook, _noRules());
  }

  function test_WhenCalledOnTheImplementation_ItReverts() external {
    PolicyGatedHarness _impl = new PolicyGatedHarness();
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    _impl.initialize('G', 'G', _admin, _guardian, _registry, _hook, _noRules());
  }
}

contract PolicyGatedUnit_Mint is PolicyGatedUnitTest {
  function test_WhenCallerIsNotMinter_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _token.MINTER_ROLE()));
    vm.prank(_stranger);
    _token.mint(_bob, 1);
  }

  function test_WhenHookAccepts_ItMintsWithAMintContext(
    uint256 _amount
  ) external {
    _amount = bound(_amount, 0, type(uint128).max);
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IPolicyHook.beforeTransfer, (_ctx(address(0), _bob, _amount, _minter, IPolicyHook.TransferKind.MINT))
      )
    );
    vm.prank(_minter);
    _token.mint(_bob, _amount);
    assertEq(_token.balanceOf(_bob), _amount);
  }

  function test_WhenHookRejects_ItRevertsWithTheReason(
    bytes32 _reason
  ) external {
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.RECEIVER_NOT_VERIFIED;
    _hookDecides(_reason);
    vm.expectRevert(_rejected(_reason));
    vm.prank(_minter);
    _token.mint(_bob, 1);
  }
}

contract PolicyGatedUnit_Burn is PolicyGatedUnitTest {
  function test_WhenCallerIsNotBurner_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _token.BURNER_ROLE()));
    vm.prank(_stranger);
    _token.burn(_alice, 1);
  }

  function test_WhenAmountExceedsBalance_ItReverts() external {
    vm.expectRevert(
      abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, _alice, _INITIAL, _INITIAL + 1)
    );
    vm.prank(_burner);
    _token.burn(_alice, _INITIAL + 1);
  }

  function test_WhenHookAccepts_ItBurnsWithABurnContext(
    uint256 _amount
  ) external {
    _amount = bound(_amount, 0, _INITIAL);
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IPolicyHook.beforeTransfer, (_ctx(_alice, address(0), _amount, _burner, IPolicyHook.TransferKind.BURN))
      )
    );
    vm.prank(_burner);
    _token.burn(_alice, _amount);
    assertEq(_token.balanceOf(_alice), _INITIAL - _amount);
  }

  /// @dev Regression: a BURNER could not burn frozen tokens (the brief exempts enforcement burns from frozen)
  function test_WhenTokensAreFrozen_ItBurnsAndReleasesTheFrozenAmount(
    uint256 _frozen,
    uint256 _amount
  ) external {
    _frozen = bound(_frozen, 1, _INITIAL);
    _amount = bound(_amount, _INITIAL - _frozen + 1, _INITIAL);
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _frozen);

    uint256 _remaining = _INITIAL - _amount;
    if (_remaining < _frozen) {
      vm.expectEmit(address(_token));
      emit IERC7943Fungible.Frozen(_alice, _remaining);
    }
    vm.expectEmit(address(_token));
    emit IERC20.Transfer(_alice, address(0), _amount);
    vm.prank(_burner);
    _token.burn(_alice, _amount);

    assertEq(_token.balanceOf(_alice), _remaining);
    assertLe(_token.getFrozenTokens(_alice), _token.balanceOf(_alice));
  }
}

contract PolicyGatedUnit_ForcedTransfer is PolicyGatedUnitTest {
  function test_WhenCallerIsNotAgent_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _token.AGENT_ROLE()));
    vm.prank(_stranger);
    _token.forcedTransfer(_alice, _bob, 1);
  }

  function test_WhenAmountExceedsBalance_ItReverts() external {
    vm.expectRevert(
      abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, _alice, _INITIAL, _INITIAL + 1)
    );
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, _INITIAL + 1);
  }

  /// @dev A plain transfer later in the same transaction must not inherit the FORCED kind from transient storage
  function test_WhenAPlainTransferFollowsAForcedTransferInTheSameTransaction_ItIsAPlainTransfer() external {
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, 10);
    vm.expectCall(
      _hook,
      abi.encodeCall(IPolicyHook.beforeTransfer, (_ctx(_bob, _alice, 1, _bob, IPolicyHook.TransferKind.TRANSFER)))
    );
    vm.prank(_bob);
    _token.transfer(_alice, 1);
  }

  function test_WhenValid_ItMovesWithAForcedContextAndEmits(
    uint256 _amount
  ) external {
    _amount = bound(_amount, 0, _INITIAL);
    vm.expectCall(
      _hook,
      abi.encodeCall(IPolicyHook.beforeTransfer, (_ctx(_alice, _bob, _amount, _agent, IPolicyHook.TransferKind.FORCED)))
    );
    vm.expectEmit(address(_token));
    emit IERC20.Transfer(_alice, _bob, _amount);
    vm.expectEmit(address(_token));
    emit IERC7943Fungible.ForcedTransfer(_alice, _bob, _amount);
    vm.expectEmit(address(_token));
    emit IPolicyGated.ForcedTransferBy(_alice, _bob, _amount, _agent);
    vm.prank(_agent);
    assertTrue(_token.forcedTransfer(_alice, _bob, _amount));
    assertEq(_token.balanceOf(_bob), _amount);
  }

  function test_WhenTokensAreFrozen_ItReleasesFrozenBeforeTheTransfer(
    uint256 _frozen,
    uint256 _amount
  ) external {
    _frozen = bound(_frozen, 1, _INITIAL);
    _amount = bound(_amount, _INITIAL - _frozen + 1, _INITIAL);
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _frozen);

    vm.expectEmit(address(_token));
    emit IERC7943Fungible.Frozen(_alice, _INITIAL - _amount);
    vm.expectEmit(address(_token));
    emit IERC20.Transfer(_alice, _bob, _amount);
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, _amount);
    assertEq(_token.getFrozenTokens(_alice), _INITIAL - _amount);
  }

  /// @dev A frozen amount that still fits in what remains is left alone: no write and no `Frozen` event
  function test_WhenTheFrozenAmountStillFits_ItIsLeftAlone(
    uint256 _frozen
  ) external {
    _frozen = bound(_frozen, 1, _INITIAL - 1);
    uint256 _amount = _INITIAL - _frozen; // what remains equals the frozen amount
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _frozen);

    vm.recordLogs();
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, _amount);
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    for (uint256 _i; _i < _logs.length; ++_i) {
      assertNotEq(_logs[_i].topics[0], IERC7943Fungible.Frozen.selector, 'Frozen emitted');
    }
    assertEq(_token.getFrozenTokens(_alice), _frozen);
  }

  function test_WhenPaused_ItStillMoves() external {
    vm.prank(_guardian);
    _token.pause();
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, 1);
    assertEq(_token.balanceOf(_bob), 1);
  }

  function test_WhenHookRejects_ItRevertsAndKeepsFrozen() external {
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _INITIAL);
    _hookDecides(Reasons.RECEIVER_NOT_VERIFIED);
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, _INITIAL);
    assertEq(_token.getFrozenTokens(_alice), _INITIAL);
  }
}

contract PolicyGatedUnit_SetFrozenTokens is PolicyGatedUnitTest {
  function test_WhenCallerIsNotAgent_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _token.AGENT_ROLE()));
    vm.prank(_stranger);
    _token.setFrozenTokens(_alice, 1);
  }

  /// @dev ERC-7943 Final: "MUST allow freezing more assets than those held"
  function test_WhenAmountExceedsBalance_ItIsAllowed(
    uint256 _amount
  ) external {
    _amount = bound(_amount, _INITIAL + 1, type(uint256).max);
    vm.expectEmit(address(_token));
    emit IERC7943Fungible.Frozen(_alice, _amount);
    vm.prank(_agent);
    assertTrue(_token.setFrozenTokens(_alice, _amount));
    assertEq(_token.getFrozenTokens(_alice), _amount);
  }

  function test_WhenAnAccountHoldsNothing_ItCanStillBeFrozen() external {
    vm.prank(_agent);
    assertTrue(_token.setFrozenTokens(_bob, 5));
    assertEq(_token.getFrozenTokens(_bob), 5);
    assertEq(_token.balanceOf(_bob), 0);
  }

  function test_WhenValid_ItSetsAndEmits(
    uint256 _amount
  ) external {
    _amount = bound(_amount, 0, _INITIAL);
    vm.expectEmit(address(_token));
    emit IERC7943Fungible.Frozen(_alice, _amount);
    vm.prank(_agent);
    assertTrue(_token.setFrozenTokens(_alice, _amount));
    assertEq(_token.getFrozenTokens(_alice), _amount);
  }

  /// @dev It overwrites, like `approve`
  function test_WhenSetAgain_ItReplacesThePreviousAmount() external {
    vm.startPrank(_agent);
    _token.setFrozenTokens(_alice, 100);
    _token.setFrozenTokens(_alice, 7);
    vm.stopPrank();
    assertEq(_token.getFrozenTokens(_alice), 7);
  }
}

/// @notice What an enforcement action takes from the frozen amount: exactly the part of what moves that was frozen
contract PolicyGatedUnit_ReleaseFrozen is PolicyGatedUnitTest {
  /// @dev Balance 10, frozen 100, force 10: the unfrozen balance is 0, so all 10 come out of the frozen amount
  function test_WhenFrozenExceedsTheBalance_ForcedTakesOnlyWhatMovesFromIt() external {
    vm.prank(_burner);
    _token.burn(_alice, _INITIAL - 10);
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, 100);

    vm.expectEmit(address(_token));
    emit IERC7943Fungible.Frozen(_alice, 90);
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, 10);
    assertEq(_token.getFrozenTokens(_alice), 90);
    assertEq(_token.balanceOf(_alice), 0);
  }

  /// @dev Part of the amount is unfrozen balance and part is frozen: only the frozen part comes off
  function test_WhenSomeOfTheAmountIsUnfrozen_OnlyTheRestIsReleased() external {
    vm.prank(_burner);
    _token.burn(_alice, _INITIAL - 10);
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, 40); // balance 10: unfrozen 0
    vm.prank(_minter);
    _token.mint(_alice, 20); // balance 30: unfrozen 0, frozen 40 still above it
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, 25); // unfrozen 5

    vm.expectEmit(address(_token));
    emit IERC7943Fungible.Frozen(_alice, 25 - 15); // forcing 20 takes 5 unfrozen and 15 frozen
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, 20);
    assertEq(_token.getFrozenTokens(_alice), 10);
    assertEq(_token.balanceOf(_alice), 10);
  }

  function test_WhenTheAmountIsWithinTheUnfrozenBalance_NothingIsReleased() external {
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, 100);
    vm.recordLogs();
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, 50);
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    for (uint256 _i; _i < _logs.length; ++_i) {
      assertNotEq(_logs[_i].topics[0], IERC7943Fungible.Frozen.selector, 'Frozen emitted');
    }
    assertEq(_token.getFrozenTokens(_alice), 100);
  }

  /// @dev "MUST emit a Frozen event before the underlying base token transfer event"
  function test_WhenFrozenTokensMove_FrozenIsEmittedBeforeTransfer() external {
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _INITIAL);
    vm.recordLogs();
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, 1);
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    uint256 _frozenAt = type(uint256).max;
    uint256 _transferAt = type(uint256).max;
    for (uint256 _i; _i < _logs.length; ++_i) {
      if (_logs[_i].topics[0] == IERC7943Fungible.Frozen.selector && _frozenAt == type(uint256).max) _frozenAt = _i;
      if (_logs[_i].topics[0] == IERC20.Transfer.selector && _transferAt == type(uint256).max) _transferAt = _i;
    }
    assertLt(_frozenAt, _transferAt, 'Frozen must come before Transfer');
  }

  /// @dev An enforcement burn releases the same way
  function test_WhenABurnerBurnsFrozenTokens_OnlyTheFrozenPartIsReleased() external {
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _INITIAL + 50);
    vm.expectEmit(address(_token));
    emit IERC7943Fungible.Frozen(_alice, 50); // nothing was unfrozen, so the whole burn comes out of the frozen amount
    vm.prank(_burner);
    _token.burn(_alice, _INITIAL);
    assertEq(_token.getFrozenTokens(_alice), 50);
  }
}

contract PolicyGatedUnit_Transfer is PolicyGatedUnitTest {
  function test_WhenAmountExceedsUnfrozen_ItRevertsWithInsufficientUnfrozen(
    uint256 _frozen,
    uint256 _amount
  ) external {
    _frozen = bound(_frozen, 1, _INITIAL);
    _amount = bound(_amount, _INITIAL - _frozen + 1, _INITIAL);
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _frozen);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC7943Fungible.ERC7943InsufficientUnfrozenBalance.selector, _alice, _amount, _INITIAL - _frozen
      )
    );
    vm.prank(_alice);
    _token.transfer(_bob, _amount);
  }

  /// @dev A frozen amount above the balance leaves nothing unfrozen, and the error says so
  function test_WhenFrozenExceedsTheBalance_NothingIsUnfrozen() external {
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _INITIAL * 2);
    vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943InsufficientUnfrozenBalance.selector, _alice, 1, 0));
    vm.prank(_alice);
    _token.transfer(_bob, 1);
  }

  /// @dev Only the token's own check may speak with the standard's error: a hook that returns the same reason code
  ///      for a movement with no shortfall is a policy rejection like any other, with its reason
  function test_WhenTheHookItselfReturnsInsufficientUnfrozen_ItIsAPolicyRejection() external {
    _hookDecides(Reasons.INSUFFICIENT_UNFROZEN);
    vm.expectRevert(_rejected(Reasons.INSUFFICIENT_UNFROZEN));
    vm.prank(_alice);
    _token.transfer(_bob, 1);
    vm.expectRevert(_rejected(Reasons.INSUFFICIENT_UNFROZEN));
    vm.prank(_minter);
    _token.mint(_bob, 1);
  }

  function test_WhenAmountWithinUnfrozen_ItMovesWithATransferContext(
    uint256 _frozen,
    uint256 _amount
  ) external {
    _frozen = bound(_frozen, 0, _INITIAL);
    _amount = bound(_amount, 0, _INITIAL - _frozen);
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _frozen);
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IPolicyHook.beforeTransfer, (_ctx(_alice, _bob, _amount, _alice, IPolicyHook.TransferKind.TRANSFER))
      )
    );
    vm.prank(_alice);
    assertTrue(_token.transfer(_bob, _amount));
    assertEq(_token.balanceOf(_bob), _amount);
  }

  function test_WhenSpenderMoves_ItPassesTheSpenderAsOperator() external {
    vm.prank(_alice);
    _token.approve(_bob, 1);
    vm.expectCall(
      _hook,
      abi.encodeCall(IPolicyHook.beforeTransfer, (_ctx(_alice, _bob, 1, _bob, IPolicyHook.TransferKind.TRANSFER)))
    );
    vm.prank(_bob);
    _token.transferFrom(_alice, _bob, 1);
  }

  function test_WhenPaused_ItRevertsWithPaused() external {
    vm.prank(_guardian);
    _token.pause();
    vm.expectRevert(_rejected(Reasons.PAUSED));
    vm.prank(_alice);
    _token.transfer(_bob, 1);
  }

  function test_WhenHookRejects_ItRevertsAndChangesNothing(
    bytes32 _reason
  ) external {
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.LOCKED;
    _hookDecides(_reason);
    vm.expectRevert(_rejected(_reason));
    vm.prank(_alice);
    _token.transfer(_bob, 1);
    assertEq(_token.balanceOf(_alice), _INITIAL);
    assertEq(_token.balanceOf(_bob), 0);
  }

  function test_WhenHookWantsAfter_ItCallsAfterTransferWithTheSameContext() external {
    vm.mockCall(_hook, abi.encodeCall(IPolicyHook.wantsAfter, ()), abi.encode(true));
    _mockAndExpect(
      _hook,
      abi.encodeCall(IPolicyHook.afterTransfer, (_ctx(_alice, _bob, 1, _alice, IPolicyHook.TransferKind.TRANSFER))),
      ''
    );
    vm.prank(_alice);
    _token.transfer(_bob, 1);
  }
}

contract PolicyGatedUnit_Pause is PolicyGatedUnitTest {
  function test_WhenCallerIsNotGuardian_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _token.GUARDIAN_ROLE()));
    vm.prank(_stranger);
    _token.pause();
  }

  function test_WhenGuardianPauses_ItPauses() external {
    vm.expectEmit(address(_token));
    emit Pausable.Paused(_guardian);
    vm.prank(_guardian);
    _token.pause();
    assertTrue(_token.paused());
  }

  function test_WhenGuardianUnpauses_ItReverts() external {
    vm.prank(_guardian);
    _token.pause();
    vm.expectRevert(_unauthorized(_guardian, _token.DEFAULT_ADMIN_ROLE()));
    vm.prank(_guardian);
    _token.unpause();
  }

  function test_WhenAdminUnpauses_ItUnpauses() external {
    vm.prank(_guardian);
    _token.pause();
    vm.prank(_admin);
    _token.unpause();
    assertFalse(_token.paused());
  }
}

contract PolicyGatedUnit_SetPolicyHook is PolicyGatedUnitTest {
  function test_WhenCallerIsNotAdmin_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _token.DEFAULT_ADMIN_ROLE()));
    vm.prank(_stranger);
    _token.setPolicyHook(_hook);
  }

  function test_WhenHookIsZero_ItReverts() external {
    vm.expectRevert(IPolicyGated.PolicyGated_ZeroAddress.selector);
    vm.prank(_admin);
    _token.setPolicyHook(address(0));
  }

  function test_WhenHookIsNotAttested_ItReverts() external {
    address _rogue = _mockContract('rogue');
    _attested(_rogue, IPolicyRegistry.AttestKind.HOOK, false);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_NotAttested.selector, _rogue, IPolicyRegistry.AttestKind.HOOK)
    );
    vm.prank(_admin);
    _token.setPolicyHook(_rogue);
  }

  function test_WhenHookIsAttested_ItReplacesAndEmits() external {
    address _next = _mockContract('next');
    _attested(_next, IPolicyRegistry.AttestKind.HOOK, true);
    _hookNamesRegistry(_next, _registry);
    vm.expectEmit(address(_token));
    emit IPolicyGated.PolicyHookChanged(_hook, _next);
    vm.prank(_admin);
    _token.setPolicyHook(_next);
    assertEq(_token.policyHook(), _next);
  }
}

contract PolicyGatedUnit_CanTransfer is PolicyGatedUnitTest {
  /// @dev Regression: the pre-flight passed the caller as operator, not the account whose transfer it simulates
  function test_WhenCalledByAThirdParty_ItSimulatesATransferByFrom() external {
    vm.expectCall(
      _hook,
      abi.encodeCall(IPolicyHook.beforeTransfer, (_ctx(_alice, _bob, 1, _alice, IPolicyHook.TransferKind.TRANSFER)))
    );
    vm.prank(_stranger);
    assertTrue(_token.canTransfer(_alice, _bob, 1));
    vm.prank(_stranger);
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(_alice, _bob, 1);
    assertTrue(_ok);
    assertEq(_reason, Reasons.TRANSFER_OK);
  }

  function test_WhenSimulatingAMint_ItUsesTheCallerAsOperator() external {
    vm.expectCall(
      _hook,
      abi.encodeCall(IPolicyHook.beforeTransfer, (_ctx(address(0), _bob, 1, _minter, IPolicyHook.TransferKind.MINT)))
    );
    vm.prank(_minter);
    _token.canTransferWithReason(address(0), _bob, 1);
  }

  function test_WhenPaused_ItReturnsPaused() external {
    vm.prank(_guardian);
    _token.pause();
    assertFalse(_token.canTransfer(_alice, _bob, 1));
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(_alice, _bob, 1);
    assertFalse(_ok);
    assertEq(_reason, Reasons.PAUSED);
  }

  function test_WhenFrozen_ItReturnsInsufficientUnfrozen() external {
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _INITIAL);
    assertFalse(_token.canTransfer(_alice, _bob, 1));
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(_alice, _bob, 1);
    assertFalse(_ok);
    assertEq(_reason, Reasons.INSUFFICIENT_UNFROZEN);
  }

  /// @dev "MUST validate that the amount does not exceed the unfrozen amount", the exact boundary
  function test_WhenTheAmountIsTheUnfrozenBalance_ItIsAllowedAndOneMoreIsNot(
    uint256 _frozen
  ) external {
    _frozen = bound(_frozen, 0, _INITIAL - 1);
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _frozen);
    assertTrue(_token.canTransfer(_alice, _bob, _INITIAL - _frozen));
    assertFalse(_token.canTransfer(_alice, _bob, _INITIAL - _frozen + 1));
  }

  /// @dev An enforcement burn (the operator holds BURNER_ROLE) may take frozen tokens, but never more than the balance:
  ///      the pre-flight must say so, as the write does
  function test_WhenABurnerAsksAboutBurningMoreThanItHolds_ItIsRefused() external {
    bytes32 _burnerRole = _token.BURNER_ROLE(); // read first: an external call in the arguments would consume the prank
    vm.prank(_admin);
    _token.grantRole(_burnerRole, _alice);
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(_alice, address(0), _INITIAL + 1);
    assertFalse(_ok);
    assertEq(_reason, Reasons.INSUFFICIENT_UNFROZEN);
    assertFalse(_token.canTransfer(_alice, address(0), _INITIAL + 1));
  }

  function test_WhenABurnerAsksAboutBurningFrozenTokens_ItIsAllowedUpToTheBalance() external {
    bytes32 _burnerRole = _token.BURNER_ROLE(); // read first: an external call in the arguments would consume the prank
    vm.prank(_admin);
    _token.grantRole(_burnerRole, _alice);
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _INITIAL);
    assertTrue(_token.canTransfer(_alice, address(0), _INITIAL));
    assertFalse(_token.canTransfer(_alice, address(0), _INITIAL + 1));
  }

  /// @dev A holder without the role is not exempt: frozen tokens count against its burn
  function test_WhenAHolderAsksAboutBurningFrozenTokens_ItIsRefused() external {
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _INITIAL);
    assertFalse(_token.canTransfer(_alice, address(0), 1));
  }

  function test_WhenFrozenExceedsTheBalance_NothingCanBeSent() external {
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _INITIAL + 1);
    assertFalse(_token.canTransfer(_alice, _bob, 1));
    assertTrue(_token.canTransfer(_alice, _bob, 0));
  }

  function test_WhenHookRejects_ItAgreesWithTransfer(
    bytes32 _reason
  ) external {
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.LOCKED;
    _hookDecides(_reason);
    assertFalse(_token.canTransfer(_alice, _bob, 1));
    (bool _ok, bytes32 _preflight) = _token.canTransferWithReason(_alice, _bob, 1);
    assertFalse(_ok);
    assertEq(_preflight, _reason);
    vm.expectRevert(_rejected(_reason));
    vm.prank(_alice);
    _token.transfer(_bob, 1);
  }

  /// @dev The boolean is the reasoned answer's first value, for every reason
  function testFuzz_ThePlainAnswerIsTheReasonedAnswersFlag(
    bytes32 _reason
  ) external {
    _hookDecides(_reason);
    (bool _ok,) = _token.canTransferWithReason(_alice, _bob, 1);
    assertEq(_token.canTransfer(_alice, _bob, 1), _ok);
    assertEq(_ok, _reason == Reasons.TRANSFER_OK);
  }
}

/// @notice ERC-7943's account-level questions, answered from the hook's `checkSend` and `checkReceive`
contract PolicyGatedUnit_CanSendAndCanReceive is PolicyGatedUnitTest {
  function test_WhenTheHookAcceptsTheAccount_BothAreTrue() external view {
    assertTrue(_token.canSend(_bob));
    assertTrue(_token.canReceive(_bob));
  }

  function test_WhenTheHookRejectsSending_OnlyCanSendIsFalse(
    bytes32 _reason
  ) external {
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.SENDER_NOT_VERIFIED;
    _hookAccountChecksDecide(_reason, Reasons.TRANSFER_OK);
    assertFalse(_token.canSend(_bob));
    assertTrue(_token.canReceive(_bob));
  }

  function test_WhenTheHookRejectsReceiving_OnlyCanReceiveIsFalse(
    bytes32 _reason
  ) external {
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.RECEIVER_NOT_VERIFIED;
    _hookAccountChecksDecide(Reasons.TRANSFER_OK, _reason);
    assertTrue(_token.canSend(_bob));
    assertFalse(_token.canReceive(_bob));
  }

  function test_WhenAsked_ItAsksTheHookAboutThisTokenAndTheAccount() external {
    vm.expectCall(_hook, abi.encodeCall(IPolicyHook.checkSend, (address(_token), _bob)));
    vm.expectCall(_hook, abi.encodeCall(IPolicyHook.checkReceive, (address(_token), _bob)));
    _token.canSend(_bob);
    _token.canReceive(_bob);
  }

  /// @dev While paused nothing moves between holders, so neither side may be asked to
  function test_WhenPaused_BothAreFalse() external {
    vm.prank(_guardian);
    _token.pause();
    assertFalse(_token.canSend(_bob));
    assertFalse(_token.canReceive(_bob));
  }

  /// @dev The answers do not depend on the caller or on any amount
  function test_WhenAskedByAnyone_TheAnswerIsTheSame() external {
    vm.prank(_stranger);
    assertTrue(_token.canSend(_bob));
    vm.prank(_minter);
    assertTrue(_token.canReceive(_bob));
  }
}

/// @dev Another template: a harness that reports another id
contract PolicyGatedOtherTemplate is PolicyGatedHarness {
  function templateId() public pure override returns (bytes32 _id) {
    _id = keccak256('SomethingElse');
  }
}

/// @dev An upgradeable contract that does not say which template it is
contract PolicyGatedNoTemplate is UUPSUpgradeable {
  function _authorizeUpgrade(
    address
  ) internal pure override {}
}

contract PolicyGatedUnit_Upgrade is PolicyGatedUnitTest {
  function test_WhenCallerIsNotUpgrader_ItReverts() external {
    address _impl = address(new PolicyGatedHarness());
    vm.expectRevert(_unauthorized(_admin, _token.UPGRADER_ROLE()));
    vm.prank(_admin);
    _token.upgradeToAndCall(_impl, '');
  }

  function test_WhenImplementationIsNotAttested_ItReverts() external {
    address _impl = address(new PolicyGatedHarness());
    _attested(_impl, IPolicyRegistry.AttestKind.IMPLEMENTATION, false);
    vm.expectRevert(
      abi.encodeWithSelector(
        IPolicyGated.PolicyGated_NotAttested.selector, _impl, IPolicyRegistry.AttestKind.IMPLEMENTATION
      )
    );
    vm.prank(_upgrader);
    _token.upgradeToAndCall(_impl, '');
  }

  function test_WhenImplementationIsAttested_ItUpgradesAndKeepsState() external {
    address _impl = address(new PolicyGatedHarness());
    _attested(_impl, IPolicyRegistry.AttestKind.IMPLEMENTATION, true);
    vm.prank(_upgrader);
    _token.upgradeToAndCall(_impl, '');
    assertEq(_token.balanceOf(_alice), _INITIAL);
    assertEq(_token.policyHook(), _hook);
  }
}

/// @notice The attestation says the code was reviewed; the template id says what it is for, so a proxy cannot be moved
///         onto another template's implementation
contract PolicyGatedUnit_TemplateId is PolicyGatedUnitTest {
  bytes32 internal constant _OTHER = keccak256('SomethingElse');

  function test_WhenQueried_ItNamesTheTemplate() external view {
    assertEq(_token.templateId(), keccak256('PolicyGatedHarness'));
  }

  function test_WhenTheImplementationIsAnotherTemplate_ItIsRefusedEvenIfAttested() external {
    address _impl = address(new PolicyGatedOtherTemplate());
    _attested(_impl, IPolicyRegistry.AttestKind.IMPLEMENTATION, true);
    vm.expectRevert(
      abi.encodeWithSelector(
        ITemplated.Templated_WrongTemplate.selector, _impl, keccak256('PolicyGatedHarness'), _OTHER
      )
    );
    vm.prank(_upgrader);
    _token.upgradeToAndCall(_impl, '');
    assertEq(_token.balanceOf(_alice), _INITIAL);
  }

  function test_WhenTheImplementationHasNoTemplateId_ItIsRefused() external {
    address _impl = address(new PolicyGatedNoTemplate());
    _attested(_impl, IPolicyRegistry.AttestKind.IMPLEMENTATION, true);
    vm.expectRevert();
    vm.prank(_upgrader);
    _token.upgradeToAndCall(_impl, '');
  }

  function test_WhenTheImplementationIsTheSameTemplateAndAttested_ItUpgrades() external {
    address _impl = address(new PolicyGatedHarness());
    _attested(_impl, IPolicyRegistry.AttestKind.IMPLEMENTATION, true);
    vm.prank(_upgrader);
    _token.upgradeToAndCall(_impl, '');
    assertEq(_token.templateId(), keccak256('PolicyGatedHarness'));
  }

  /// @dev An unattested implementation is refused on the attestation first, whatever template it claims
  function test_WhenTheImplementationIsAnotherTemplateAndNotAttested_ItIsRefusedAsUnattested() external {
    address _impl = address(new PolicyGatedOtherTemplate());
    _attested(_impl, IPolicyRegistry.AttestKind.IMPLEMENTATION, false);
    vm.expectRevert(
      abi.encodeWithSelector(
        IPolicyGated.PolicyGated_NotAttested.selector, _impl, IPolicyRegistry.AttestKind.IMPLEMENTATION
      )
    );
    vm.prank(_upgrader);
    _token.upgradeToAndCall(_impl, '');
  }
}

contract PolicyGatedUnit_Permit is PolicyGatedUnitTest {
  function test_WhenSignedByTheOwner_ItSetsTheAllowance(
    uint256 _value
  ) external {
    uint256 _deadline = block.timestamp + 1 hours;
    bytes32 _digest = keccak256(
      abi.encodePacked(
        '\x19\x01',
        _token.DOMAIN_SEPARATOR(),
        keccak256(abi.encode(_PERMIT_TYPEHASH, _alice, _bob, _value, _token.nonces(_alice), _deadline))
      )
    );
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_alicePk, _digest);
    _token.permit(_alice, _bob, _value, _deadline, _v, _r, _s);
    assertEq(_token.allowance(_alice, _bob), _value);
    assertEq(_token.nonces(_alice), 1);
  }
}

contract PolicyGatedUnit_SupportsInterface is PolicyGatedUnitTest {
  function test_WhenQueried_ItSupportsItsInterfaces() external view {
    assertTrue(_token.supportsInterface(type(IPolicyGated).interfaceId));
    // ERC-7943 Final, fungible: the standard's own id, as a literal
    assertTrue(_token.supportsInterface(0x3edbb4c4));
    assertTrue(_token.supportsInterface(type(IERC7943Fungible).interfaceId));
    assertTrue(_token.supportsInterface(type(IERC20).interfaceId));
    assertTrue(_token.supportsInterface(type(IERC20Permit).interfaceId));
    assertTrue(_token.supportsInterface(type(IAccessControl).interfaceId));
    assertTrue(_token.supportsInterface(type(IERC165).interfaceId));
    assertFalse(_token.supportsInterface(0xdeadbeef));
  }
}

/// @notice Drives random enforcement and holder actions against the token for the invariant suite
contract PolicyGatedHandler is Test {
  PolicyGatedHarness internal _token;
  address internal _minter;
  address internal _burner;
  address internal _agent;
  address[3] internal _actors;

  constructor(
    PolicyGatedHarness _target,
    address _minterRole,
    address _burnerRole,
    address _agentRole
  ) {
    _token = _target;
    _minter = _minterRole;
    _burner = _burnerRole;
    _agent = _agentRole;
    _actors = [makeAddr('actor0'), makeAddr('actor1'), makeAddr('actor2')];
  }

  function actors() external view returns (address[3] memory _all) {
    _all = _actors;
  }

  /// @notice Ghost counters: how many times each action actually executed in the current run
  mapping(bytes32 _action => uint256 _count) public executed;

  // Every amount is computed before `vm.prank`: an external call in the arguments would consume the prank and turn
  // the action into an unauthorised no-op. `afterInvariant` in the test asserts each action really executes.

  function mint(
    uint256 _to,
    uint256 _amount
  ) external {
    vm.prank(_minter);
    _token.mint(_actor(_to), bound(_amount, 1, 1e30));
    ++executed['mint'];
  }

  function burn(
    uint256 _from,
    uint256 _amount
  ) external {
    address _account = _actor(_from);
    uint256 _balance = _token.balanceOf(_account);
    if (_balance == 0) return;
    _amount = bound(_amount, 1, _balance);
    vm.prank(_burner);
    _token.burn(_account, _amount);
    ++executed['burn'];
  }

  function transfer(
    uint256 _from,
    uint256 _to,
    uint256 _amount
  ) external {
    address _account = _actor(_from);
    uint256 _balance = _token.balanceOf(_account);
    uint256 _frozenAmount = _token.getFrozenTokens(_account);
    uint256 _unfrozen = _balance > _frozenAmount ? _balance - _frozenAmount : 0;
    if (_unfrozen == 0) return;
    _amount = bound(_amount, 1, _unfrozen);
    vm.prank(_account);
    _token.transfer(_actor(_to), _amount);
    ++executed['transfer'];
  }

  function forcedTransfer(
    uint256 _from,
    uint256 _to,
    uint256 _amount
  ) external {
    address _account = _actor(_from);
    uint256 _balance = _token.balanceOf(_account);
    if (_balance == 0) return;
    _amount = bound(_amount, 1, _balance);
    vm.prank(_agent);
    _token.forcedTransfer(_account, _actor(_to), _amount);
    ++executed['forcedTransfer'];
  }

  function setFrozenTokens(
    uint256 _user,
    uint256 _amount
  ) external {
    address _account = _actor(_user);
    // Up to twice the balance and a little more, so the frozen amount is often above what the account holds.
    _amount = bound(_amount, 0, 2 * _token.balanceOf(_account) + 7);
    vm.prank(_agent);
    _token.setFrozenTokens(_account, _amount);
    ++executed['setFrozenTokens'];
  }

  function _actor(
    uint256 _seed
  ) internal view returns (address _account) {
    _account = _actors[_seed % 3];
  }
}

contract PolicyGatedInvariantTest is PolicyGatedUnitTest {
  PolicyGatedHandler internal _handler;

  function setUp() public override {
    super.setUp();
    _handler = new PolicyGatedHandler(_token, _minter, _burner, _agent);
    // Move the setUp mint out of play so the handler's actors hold the whole supply.
    vm.prank(_burner);
    _token.burn(_alice, _INITIAL);
    targetContract(address(_handler));
  }

  function invariant_SumOfBalancesEqualsTotalSupply() external view {
    address[3] memory _all = _handler.actors();
    uint256 _sum;
    for (uint256 _i; _i < 3; ++_i) {
      _sum += _token.balanceOf(_all[_i]);
    }
    assertEq(_sum, _token.totalSupply());
  }

  /// @dev The unfrozen balance is what a transfer can move, to the unit, whether the frozen amount is above the balance
  ///      or below it: ERC-7943's `canTransfer` and the token's own check agree on the boundary
  function invariant_TheUnfrozenBalanceIsExactlyWhatCanBeSent() external view {
    address[3] memory _all = _handler.actors();
    for (uint256 _i; _i < 3; ++_i) {
      uint256 _balance = _token.balanceOf(_all[_i]);
      uint256 _frozenAmount = _token.getFrozenTokens(_all[_i]);
      uint256 _unfrozen = _balance > _frozenAmount ? _balance - _frozenAmount : 0;
      assertTrue(_token.canTransfer(_all[_i], _all[(_i + 1) % 3], _unfrozen));
      assertFalse(_token.canTransfer(_all[_i], _all[(_i + 1) % 3], _unfrozen + 1));
    }
  }

  /// @dev Non-vacuity: every action must execute in every run (a consumed prank once made burn, forcedTransfer and
  ///      setFrozenTokens silent no-ops, so the frozen invariant never saw an enforcement action)
  function afterInvariant() external view {
    string[5] memory _actions = ['mint', 'burn', 'transfer', 'forcedTransfer', 'setFrozenTokens'];
    for (uint256 _i; _i < _actions.length; ++_i) {
      assertGt(_handler.executed(bytes32(bytes(_actions[_i]))), 0, _actions[_i]);
    }
  }
}

/// @dev `_mintAs` announces the kind: FORCED with `from == address(0)` is an enforcement mint (brief §5)
contract PolicyGatedUnit_MintAs is PolicyGatedUnitTest {
  function test_WhenMintingAsForced_TheHookSeesAForcedContextFromZero() external {
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IPolicyHook.beforeTransfer, (_ctx(address(0), _bob, 5, address(this), IPolicyHook.TransferKind.FORCED))
      )
    );
    _token.mintAs(_bob, 5, IPolicyHook.TransferKind.FORCED);
    assertEq(_token.balanceOf(_bob), 5);
  }

  function test_WhenPaused_AForcedMintStillSettlesButAPlainMintDoesNot() external {
    vm.prank(_guardian);
    _token.pause();
    _token.mintAs(_bob, 5, IPolicyHook.TransferKind.FORCED);
    assertEq(_token.balanceOf(_bob), 5);
    vm.expectRevert(_rejected(Reasons.PAUSED));
    _token.mintAs(_bob, 5, IPolicyHook.TransferKind.MINT);
  }

  /// @dev The announced kind is consumed: a plain movement right after is still inferred, not FORCED
  function test_WhenAForcedMintIsFollowedByAPlainTransfer_TheTransferIsPlain() external {
    _token.mintAs(_bob, 5, IPolicyHook.TransferKind.FORCED);
    vm.expectCall(
      _hook,
      abi.encodeCall(IPolicyHook.beforeTransfer, (_ctx(_bob, _alice, 1, _bob, IPolicyHook.TransferKind.TRANSFER)))
    );
    vm.prank(_bob);
    _token.transfer(_alice, 1);
  }
}

/// @dev M-1: RECOVERY_ROLE (the recovery timelock) can only unpause and revoke GUARDIAN_ROLE; the guardian cannot block it
contract PolicyGatedUnit_Recovery is PolicyGatedUnitTest {
  address internal _recovery = makeAddr('recoveryTimelock');

  function setUp() public override {
    super.setUp();
    bytes32 _role = _token.RECOVERY_ROLE(); // read first: an inline call would consume the prank
    vm.prank(_admin);
    _token.grantRole(_role, _recovery);
    vm.prank(_guardian);
    _token.pause();
  }

  function test_WhenRecoveryUnpauses_ItUnpauses() external {
    vm.prank(_recovery);
    _token.unpause();
    assertFalse(_token.paused());
  }

  function test_WhenRecoveryRevokesTheGuardian_TheGuardianCanNoLongerPause() external {
    bytes32 _guardianRole = _token.GUARDIAN_ROLE();
    vm.prank(_recovery);
    _token.revokeRole(_guardianRole, _guardian);
    assertFalse(_token.hasRole(_guardianRole, _guardian));
    vm.prank(_recovery);
    _token.unpause();
    vm.expectRevert(_unauthorized(_guardian, _guardianRole));
    vm.prank(_guardian);
    _token.pause();
  }

  function test_WhenRecoveryRevokesAnyOtherRole_ItReverts() external {
    bytes32 _adminRole = _token.DEFAULT_ADMIN_ROLE();
    bytes32 _agentRole = _token.AGENT_ROLE();
    bytes32 _upgraderRole = _token.UPGRADER_ROLE();
    vm.startPrank(_recovery);
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    _token.revokeRole(_agentRole, _agent);
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    _token.revokeRole(_adminRole, _admin);
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    _token.revokeRole(_upgraderRole, _admin);
    vm.stopPrank();
  }

  function test_WhenRecoveryGrantsAnyRole_ItReverts() external {
    bytes32 _adminRole = _token.DEFAULT_ADMIN_ROLE();
    bytes32 _guardianRole = _token.GUARDIAN_ROLE();
    bytes32 _recoveryRole = _token.RECOVERY_ROLE();
    vm.startPrank(_recovery);
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    _token.grantRole(_guardianRole, _recovery);
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    _token.grantRole(_recoveryRole, _stranger);
    vm.stopPrank();
  }

  function test_WhenRecoveryChangesTheHookOrUpgrades_ItReverts() external {
    bytes32 _adminRole = _token.DEFAULT_ADMIN_ROLE();
    bytes32 _upgraderRole = _token.UPGRADER_ROLE();
    vm.startPrank(_recovery);
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    _token.setPolicyHook(makeAddr('otherHook'));
    vm.expectRevert(_unauthorized(_recovery, _upgraderRole));
    _token.upgradeToAndCall(makeAddr('otherImpl'), '');
    vm.stopPrank();
  }

  function test_WhenAStrangerUnpauses_ItStillReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _token.DEFAULT_ADMIN_ROLE()));
    vm.prank(_stranger);
    _token.unpause();
  }
}

/// @notice The context the token builds is part of the hook interface: the balances before the move ride in `extra`
contract PolicyGatedUnit_Context is PolicyGatedUnitTest {
  function _expectBefore(
    address _from,
    address _to,
    uint256 _amount,
    address _operator,
    IPolicyHook.TransferKind _kind,
    bytes memory _extra
  ) internal {
    IPolicyHook.TransferContext memory _context = IPolicyHook.TransferContext({
      token: address(_token),
      from: _from,
      to: _to,
      id: 0,
      amount: _amount,
      operator: _operator,
      kind: _kind,
      extra: _extra
    });
    _mockAndExpect(_hook, abi.encodeCall(IPolicyHook.beforeTransfer, (_context)), abi.encode(Reasons.TRANSFER_OK));
  }

  function test_WhenTransferring_ExtraCarriesBothBalancesBeforeTheMove() external {
    _expectBefore(_alice, _bob, 10 ether, _alice, IPolicyHook.TransferKind.TRANSFER, abi.encode(_INITIAL, uint256(0)));
    vm.prank(_alice);
    _token.transfer(_bob, 10 ether);
  }

  function test_WhenMinting_TheSenderBalanceIsZero() external {
    _expectBefore(address(0), _alice, 5 ether, _minter, IPolicyHook.TransferKind.MINT, abi.encode(uint256(0), _INITIAL));
    vm.prank(_minter);
    _token.mint(_alice, 5 ether);
  }

  function test_WhenBurning_TheReceiverBalanceIsZero() external {
    _expectBefore(_alice, address(0), 5 ether, _burner, IPolicyHook.TransferKind.BURN, abi.encode(_INITIAL, uint256(0)));
    vm.prank(_burner);
    _token.burn(_alice, 5 ether);
  }

  function test_WhenForced_ExtraHasNoRefOrDeadline() external {
    _expectBefore(_alice, _bob, 3 ether, _agent, IPolicyHook.TransferKind.FORCED, abi.encode(_INITIAL, uint256(0)));
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, 3 ether);
  }

  /// @dev EXECUTED appends the intent's reference and deadline after the balances
  function test_WhenExecuted_ExtraAppendsRefAndDeadline() external {
    bytes32 _ref = keccak256('pacs.008');
    uint256 _deadline = block.timestamp + 1 days;
    _expectBefore(
      _alice,
      _bob,
      2 ether,
      address(this),
      IPolicyHook.TransferKind.EXECUTED,
      abi.encode(_INITIAL, uint256(0), _ref, _deadline)
    );
    _token.moveAs(_alice, _bob, 2 ether, IPolicyHook.TransferKind.EXECUTED, _ref, _deadline);
  }

  /// @dev The pre-flight builds the context with the same code, so it asks the hook the same question
  function test_WhenPreflightRuns_ItBuildsTheSameContextAsTheWrite() external {
    _expectBefore(_alice, _bob, 7 ether, _alice, IPolicyHook.TransferKind.TRANSFER, abi.encode(_INITIAL, uint256(0)));
    (bool _ok,) = _token.canTransferWithReason(_alice, _bob, 7 ether);
    assertTrue(_ok);
  }

  /// @dev `afterTransfer` gets the context the check saw, so a rule derives the post-move balances from `amount`
  function test_WhenTheHookWantsAfter_ItReceivesTheSameContext() external {
    vm.mockCall(_hook, abi.encodeCall(IPolicyHook.wantsAfter, ()), abi.encode(true));
    bytes memory _extra = abi.encode(_INITIAL, uint256(0));
    IPolicyHook.TransferContext memory _context = IPolicyHook.TransferContext({
      token: address(_token),
      from: _alice,
      to: _bob,
      id: 0,
      amount: 4 ether,
      operator: _alice,
      kind: IPolicyHook.TransferKind.TRANSFER,
      extra: _extra
    });
    _mockAndExpect(_hook, abi.encodeCall(IPolicyHook.afterTransfer, (_context)), '');
    vm.prank(_alice);
    _token.transfer(_bob, 4 ether);
  }
}

/// @notice A token only accepts a hook that vets rules against the token's own registry, and installs its initial rule
///         set on the hook in the same call that installs the hook
contract PolicyGatedUnit_SharedHook is PolicyGatedUnitTest {
  function test_WhenTheHookNamesAnotherRegistry_SetPolicyHookReverts() external {
    address _next = _mockContract('next');
    address _otherRegistry = _mockContract('otherRegistry');
    _attested(_next, IPolicyRegistry.AttestKind.HOOK, true);
    _hookNamesRegistry(_next, _otherRegistry);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_HookRegistryMismatch.selector, _otherRegistry, _registry)
    );
    vm.prank(_admin);
    _token.setPolicyHook(_next);
  }

  function test_WhenTheHookNamesAnotherRegistry_InitializeReverts() external {
    address _next = _mockContract('next');
    address _otherRegistry = _mockContract('otherRegistry');
    _attested(_next, IPolicyRegistry.AttestKind.HOOK, true);
    _hookNamesRegistry(_next, _otherRegistry);
    PolicyGatedHarness _impl = new PolicyGatedHarness();
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_HookRegistryMismatch.selector, _otherRegistry, _registry)
    );
    new ERC1967Proxy(
      address(_impl),
      abi.encodeCall(PolicyGatedHarness.initialize, ('G', 'G', _admin, _guardian, _registry, _next, _noRules()))
    );
  }

  function test_WhenInitialRulesAreGiven_TheTokenInstallsThemOnTheHookItself() external {
    IComplianceRule[] memory _ruleSet = new IComplianceRule[](1);
    _ruleSet[0] = IComplianceRule(_mockContract('rule'));
    vm.mockCall(_hook, abi.encodeWithSelector(IComplianceHook.setRules.selector), '');
    vm.expectCall(_hook, abi.encodeWithSelector(IComplianceHook.setRules.selector), 1);
    PolicyGatedHarness _impl = new PolicyGatedHarness();
    new ERC1967Proxy(
      address(_impl),
      abi.encodeCall(PolicyGatedHarness.initialize, ('G', 'G', _admin, _guardian, _registry, _hook, _ruleSet))
    );
  }

  function test_WhenNoInitialRulesAreGiven_TheTokenLeavesTheHookAlone() external {
    vm.expectCall(_hook, abi.encodeWithSelector(IComplianceHook.setRules.selector), 0);
    _deploy(_hook);
  }
}

/// @notice `MulticallUpgradeable`: every call of the token can be batched atomically, and the sender is preserved
contract PolicyGatedUnit_Multicall is PolicyGatedUnitTest {
  function _calls2(
    bytes memory _first,
    bytes memory _second
  ) internal pure returns (bytes[] memory _calls) {
    _calls = new bytes[](2);
    _calls[0] = _first;
    _calls[1] = _second;
  }

  function test_WhenAMinterBatchesTwoMints_BothHappen() external {
    bytes[] memory _calls = _calls2(abi.encodeCall(_token.mint, (_bob, 3)), abi.encodeCall(_token.mint, (_alice, 4)));
    vm.prank(_minter);
    _token.multicall(_calls);
    assertEq(_token.balanceOf(_bob), 3);
    assertEq(_token.balanceOf(_alice), _INITIAL + 4);
  }

  /// @dev The sender is the caller of `multicall`, so a role gate applies to each call inside it
  function test_WhenAStrangerBatchesARoleGatedCall_ItReverts() external {
    bytes[] memory _calls = _calls2(abi.encodeCall(_token.mint, (_bob, 3)), abi.encodeCall(_token.mint, (_bob, 4)));
    vm.expectRevert(_unauthorized(_stranger, _token.MINTER_ROLE()));
    vm.prank(_stranger);
    _token.multicall(_calls);
    assertEq(_token.balanceOf(_bob), 0);
  }

  /// @dev Atomic: a later call that fails undoes the earlier ones
  function test_WhenALaterCallFails_TheEarlierOnesAreUndone() external {
    bytes[] memory _calls = _calls2(abi.encodeCall(_token.mint, (_bob, 3)), abi.encodeCall(_token.burn, (_alice, 1)));
    vm.expectRevert(_unauthorized(_minter, _token.BURNER_ROLE()));
    vm.prank(_minter);
    _token.multicall(_calls);
    assertEq(_token.balanceOf(_bob), 0);
    assertEq(_token.balanceOf(_alice), _INITIAL);
  }

  function test_WhenAHolderBatchesTransfers_TheHookSeesTheHolderAsOperator() external {
    vm.expectCall(
      _hook,
      abi.encodeCall(IPolicyHook.beforeTransfer, (_ctx(_alice, _bob, 1, _alice, IPolicyHook.TransferKind.TRANSFER)))
    );
    bytes[] memory _calls =
      _calls2(abi.encodeCall(_token.transfer, (_bob, 1)), abi.encodeCall(_token.transfer, (_bob, 2)));
    vm.prank(_alice);
    _token.multicall(_calls);
    assertEq(_token.balanceOf(_bob), 3);
  }

  /// @dev The kind announced for a forced transfer is cleared before the next call of the batch
  function test_WhenAForcedTransferIsFollowedByAPlainTransferInOneBatch_TheSecondIsPlain() external {
    vm.startPrank(_admin);
    _token.grantRole(_token.AGENT_ROLE(), _alice);
    vm.stopPrank();
    bytes[] memory _calls =
      _calls2(abi.encodeCall(_token.forcedTransfer, (_alice, _bob, 10)), abi.encodeCall(_token.transfer, (_bob, 2)));
    // The second movement reaches the hook as a plain transfer by alice, with the balances the first one left.
    IPolicyHook.TransferContext memory _plain = _ctx(_alice, _bob, 2, _alice, IPolicyHook.TransferKind.TRANSFER);
    _plain.extra = abi.encode(_INITIAL - 10, uint256(10));
    vm.expectCall(_hook, abi.encodeCall(IPolicyHook.beforeTransfer, (_plain)));
    vm.prank(_alice);
    _token.multicall(_calls);
    assertEq(_token.balanceOf(_bob), 12);
  }

  /// @dev It is not payable, so no value can enter through a batch
  function test_WhenValueIsSent_ItReverts() external {
    bytes[] memory _calls = new bytes[](0);
    vm.deal(_alice, 1);
    vm.prank(_alice);
    (bool _ok,) = address(_token).call{value: 1}(abi.encodeCall(_token.multicall, (_calls)));
    assertFalse(_ok);
  }

  /// @dev A batch cannot initialise the token again
  function test_WhenABatchCallsInitialize_ItReverts() external {
    bytes[] memory _calls = new bytes[](1);
    _calls[0] = abi.encodeCall(_token.initialize, ('G', 'G', _admin, _guardian, _registry, _hook, _noRules()));
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    vm.prank(_alice);
    _token.multicall(_calls);
  }
}
