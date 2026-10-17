// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {Initializable} from '@openzeppelin/contracts/proxy/utils/Initializable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

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
          abi.encodeCall(PolicyGatedHarness.initialize, ('Gated', 'GTD', _admin, _guardian, _registry, _initialHook))
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
      ref: bytes32(0),
      deadline: 0,
      extra: ''
    });
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
      address(_impl), abi.encodeCall(PolicyGatedHarness.initialize, ('G', 'G', address(0), _guardian, _registry, _hook))
    );
  }

  function test_WhenGuardianIsZero_ItReverts() external {
    PolicyGatedHarness _impl = new PolicyGatedHarness();
    vm.expectRevert(IPolicyGated.PolicyGated_ZeroAddress.selector);
    new ERC1967Proxy(
      address(_impl), abi.encodeCall(PolicyGatedHarness.initialize, ('G', 'G', _admin, address(0), _registry, _hook))
    );
  }

  function test_WhenRegistryIsZero_ItReverts() external {
    PolicyGatedHarness _impl = new PolicyGatedHarness();
    vm.expectRevert(IPolicyGated.PolicyGated_ZeroAddress.selector);
    new ERC1967Proxy(
      address(_impl), abi.encodeCall(PolicyGatedHarness.initialize, ('G', 'G', _admin, _guardian, address(0), _hook))
    );
  }

  function test_WhenHookIsZero_ItReverts() external {
    PolicyGatedHarness _impl = new PolicyGatedHarness();
    vm.expectRevert(IPolicyGated.PolicyGated_ZeroAddress.selector);
    new ERC1967Proxy(
      address(_impl),
      abi.encodeCall(PolicyGatedHarness.initialize, ('G', 'G', _admin, _guardian, _registry, address(0)))
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
      address(_impl), abi.encodeCall(PolicyGatedHarness.initialize, ('G', 'G', _admin, _guardian, _registry, _rogue))
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
    _token.initialize('G', 'G', _admin, _guardian, _registry, _hook);
  }

  function test_WhenCalledOnTheImplementation_ItReverts() external {
    PolicyGatedHarness _impl = new PolicyGatedHarness();
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    _impl.initialize('G', 'G', _admin, _guardian, _registry, _hook);
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
    _token.setFrozen(_alice, _frozen);

    uint256 _remaining = _INITIAL - _amount;
    if (_remaining < _frozen) {
      vm.expectEmit(address(_token));
      emit IPolicyGated.Frozen(_alice, _remaining);
    }
    vm.expectEmit(address(_token));
    emit IERC20.Transfer(_alice, address(0), _amount);
    vm.prank(_burner);
    _token.burn(_alice, _amount);

    assertEq(_token.balanceOf(_alice), _remaining);
    assertLe(_token.getFrozen(_alice), _token.balanceOf(_alice));
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
    emit IPolicyGated.ForcedTransfer(_alice, _bob, _amount, _agent);
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, _amount);
    assertEq(_token.balanceOf(_bob), _amount);
  }

  function test_WhenTokensAreFrozen_ItReleasesFrozenBeforeTheTransfer(
    uint256 _frozen,
    uint256 _amount
  ) external {
    _frozen = bound(_frozen, 1, _INITIAL);
    _amount = bound(_amount, _INITIAL - _frozen + 1, _INITIAL);
    vm.prank(_agent);
    _token.setFrozen(_alice, _frozen);

    vm.expectEmit(address(_token));
    emit IPolicyGated.Frozen(_alice, _INITIAL - _amount);
    vm.expectEmit(address(_token));
    emit IERC20.Transfer(_alice, _bob, _amount);
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, _amount);
    assertEq(_token.getFrozen(_alice), _INITIAL - _amount);
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
    _token.setFrozen(_alice, _INITIAL);
    _hookDecides(Reasons.RECEIVER_NOT_VERIFIED);
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, _INITIAL);
    assertEq(_token.getFrozen(_alice), _INITIAL);
  }
}

contract PolicyGatedUnit_SetFrozen is PolicyGatedUnitTest {
  function test_WhenCallerIsNotAgent_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _token.AGENT_ROLE()));
    vm.prank(_stranger);
    _token.setFrozen(_alice, 1);
  }

  function test_WhenAmountExceedsBalance_ItReverts(
    uint256 _amount
  ) external {
    _amount = bound(_amount, _INITIAL + 1, type(uint256).max);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_FrozenExceedsBalance.selector, _alice, _amount, _INITIAL)
    );
    vm.prank(_agent);
    _token.setFrozen(_alice, _amount);
  }

  function test_WhenValid_ItSetsAndEmits(
    uint256 _amount
  ) external {
    _amount = bound(_amount, 0, _INITIAL);
    vm.expectEmit(address(_token));
    emit IPolicyGated.Frozen(_alice, _amount);
    vm.prank(_agent);
    _token.setFrozen(_alice, _amount);
    assertEq(_token.getFrozen(_alice), _amount);
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
    _token.setFrozen(_alice, _frozen);
    vm.expectRevert(_rejected(Reasons.INSUFFICIENT_UNFROZEN));
    vm.prank(_alice);
    _token.transfer(_bob, _amount);
  }

  function test_WhenAmountWithinUnfrozen_ItMovesWithATransferContext(
    uint256 _frozen,
    uint256 _amount
  ) external {
    _frozen = bound(_frozen, 0, _INITIAL);
    _amount = bound(_amount, 0, _INITIAL - _frozen);
    vm.prank(_agent);
    _token.setFrozen(_alice, _frozen);
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
    (bool _ok, bytes32 _reason) = _token.canTransfer(_alice, _bob, 1);
    assertTrue(_ok);
    assertEq(_reason, Reasons.TRANSFER_OK);
  }

  function test_WhenSimulatingAMint_ItUsesTheCallerAsOperator() external {
    vm.expectCall(
      _hook,
      abi.encodeCall(IPolicyHook.beforeTransfer, (_ctx(address(0), _bob, 1, _minter, IPolicyHook.TransferKind.MINT)))
    );
    vm.prank(_minter);
    _token.canTransfer(address(0), _bob, 1);
  }

  function test_WhenPaused_ItReturnsPaused() external {
    vm.prank(_guardian);
    _token.pause();
    (bool _ok, bytes32 _reason) = _token.canTransfer(_alice, _bob, 1);
    assertFalse(_ok);
    assertEq(_reason, Reasons.PAUSED);
  }

  function test_WhenFrozen_ItReturnsInsufficientUnfrozen() external {
    vm.prank(_agent);
    _token.setFrozen(_alice, _INITIAL);
    (bool _ok, bytes32 _reason) = _token.canTransfer(_alice, _bob, 1);
    assertFalse(_ok);
    assertEq(_reason, Reasons.INSUFFICIENT_UNFROZEN);
  }

  function test_WhenHookRejects_ItAgreesWithTransfer(
    bytes32 _reason
  ) external {
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.LOCKED;
    _hookDecides(_reason);
    (bool _ok, bytes32 _preflight) = _token.canTransfer(_alice, _bob, 1);
    assertFalse(_ok);
    assertEq(_preflight, _reason);
    vm.expectRevert(_rejected(_reason));
    vm.prank(_alice);
    _token.transfer(_bob, 1);
  }
}

contract PolicyGatedUnit_IsUserAllowed is PolicyGatedUnitTest {
  function test_WhenHookAcceptsAMint_ItReturnsTrue() external view {
    assertTrue(_token.isUserAllowed(_bob));
  }

  function test_WhenHookRejectsAMint_ItReturnsFalse() external {
    _hookDecides(Reasons.RECEIVER_NOT_VERIFIED);
    assertFalse(_token.isUserAllowed(_bob));
  }
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
    uint256 _unfrozen = _token.balanceOf(_account) - _token.getFrozen(_account);
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

  function setFrozen(
    uint256 _user,
    uint256 _amount
  ) external {
    address _account = _actor(_user);
    _amount = bound(_amount, 0, _token.balanceOf(_account));
    vm.prank(_agent);
    _token.setFrozen(_account, _amount);
    ++executed['setFrozen'];
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

  function invariant_FrozenNeverExceedsBalance() external view {
    address[3] memory _all = _handler.actors();
    for (uint256 _i; _i < 3; ++_i) {
      assertLe(_token.getFrozen(_all[_i]), _token.balanceOf(_all[_i]));
    }
  }

  /// @dev Non-vacuity: every action must execute in every run (a consumed prank once made burn, forcedTransfer and
  ///      setFrozen silent no-ops, so the frozen invariant never saw an enforcement action)
  function afterInvariant() external view {
    string[5] memory _actions = ['mint', 'burn', 'transfer', 'forcedTransfer', 'setFrozen'];
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
