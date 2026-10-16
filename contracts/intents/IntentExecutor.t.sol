// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IIntentExecutor} from 'interfaces/IIntentExecutor.sol';
import {IIntentExecutorBatch} from 'interfaces/IIntentExecutorBatch.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

import {IntentExecutor} from 'contracts/intents/IntentExecutor.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {IntentTokenIntegrationTest} from 'contracts/tokens/IntentToken.t.sol';

contract IntentExecutorUnitTest is Helpers {
  IntentExecutor internal _executor;
  address internal _token;
  address internal _admin = makeAddr('timelock');
  address internal _guardian = makeAddr('guardian');
  address internal _operator = makeAddr('operator');
  address internal _stranger = makeAddr('stranger');

  function setUp() public virtual {
    _token = _mockContract('token');
    _executor = new IntentExecutor(_admin, _guardian);
    vm.startPrank(_admin);
    _executor.grantRole(_executor.OPERATOR_ROLE(), _operator);
    vm.stopPrank();
  }

  function _intent(
    uint256 _seed
  ) internal pure returns (ITransferIntent.TransferIntent memory _transferIntent) {
    _transferIntent = ITransferIntent.TransferIntent({
      from: address(uint160(0x1000 + _seed)),
      to: address(uint160(0x2000 + _seed)),
      amount: _seed + 1,
      nonce: keccak256(abi.encode('nonce', _seed)),
      deadline: 1000 + _seed,
      ref: keccak256(abi.encode('ref', _seed))
    });
  }

  function _sig(
    uint256 _seed
  ) internal pure returns (bytes memory _signature) {
    _signature = abi.encode(keccak256(abi.encode('r', _seed)), keccak256(abi.encode('s', _seed)));
  }

  function _settles(
    uint256 _seed,
    bytes32 _hash
  ) internal {
    _mockAndExpect(
      _token, abi.encodeCall(ITransferIntent.executeTransfer, (_intent(_seed), _sig(_seed))), abi.encode(_hash)
    );
  }

  function _batch(
    uint256 _length
  ) internal pure returns (ITransferIntent.TransferIntent[] memory _intents, bytes[] memory _sigs) {
    _intents = new ITransferIntent.TransferIntent[](_length);
    _sigs = new bytes[](_length);
    for (uint256 _i; _i < _length; ++_i) {
      _intents[_i] = _intent(_i);
      _sigs[_i] = _sig(_i);
    }
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

contract IntentExecutorUnit_Constructor is IntentExecutorUnitTest {
  function test_WhenAdminIsZero_ItReverts() external {
    vm.expectRevert(IIntentExecutorBatch.IntentExecutor_ZeroAddress.selector);
    new IntentExecutor(address(0), _guardian);
  }

  function test_WhenGuardianIsZero_ItReverts() external {
    vm.expectRevert(IIntentExecutorBatch.IntentExecutor_ZeroAddress.selector);
    new IntentExecutor(_admin, address(0));
  }

  function test_WhenValid_ItGrantsAdminAndGuardianOnly() external view {
    assertTrue(_executor.hasRole(_executor.DEFAULT_ADMIN_ROLE(), _admin));
    assertTrue(_executor.hasRole(_executor.GUARDIAN_ROLE(), _guardian));
    assertFalse(_executor.hasRole(_executor.OPERATOR_ROLE(), _admin));
    assertFalse(_executor.paused());
  }
}

contract IntentExecutorUnit_Execute is IntentExecutorUnitTest {
  function test_WhenCallerIsNotOperator_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _executor.OPERATOR_ROLE()));
    vm.prank(_stranger);
    _executor.execute(_token, _intent(0), _sig(0));
  }

  function test_WhenOperatorCalls_ItForwardsTheExactIntentAndReturnsTheHash(
    uint8 _seed,
    bytes32 _hash
  ) external {
    _settles(_seed, _hash);
    vm.prank(_operator);
    assertEq(_executor.execute(_token, _intent(_seed), _sig(_seed)), _hash);
  }

  function test_WhenTheTokenRejects_ItBubblesTheRevertUnchanged(
    bytes32 _reason
  ) external {
    vm.mockCallRevert(
      _token, abi.encodeCall(ITransferIntent.executeTransfer, (_intent(0), _sig(0))), _rejected(_reason)
    );
    vm.expectRevert(_rejected(_reason));
    vm.prank(_operator);
    _executor.execute(_token, _intent(0), _sig(0));
  }

  function test_WhenPaused_ItReverts() external {
    vm.prank(_guardian);
    _executor.pause();
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vm.prank(_operator);
    _executor.execute(_token, _intent(0), _sig(0));
  }
}

contract IntentExecutorUnit_ExecuteBatch is IntentExecutorUnitTest {
  function test_WhenCallerIsNotOperator_ItReverts() external {
    (ITransferIntent.TransferIntent[] memory _intents, bytes[] memory _sigs) = _batch(1);
    vm.expectRevert(_unauthorized(_stranger, _executor.OPERATOR_ROLE()));
    vm.prank(_stranger);
    _executor.executeBatch(_token, _intents, _sigs);
  }

  function test_WhenLengthsDiffer_ItReverts(
    uint256 _intentCount,
    uint256 _sigCount
  ) external {
    _intentCount = bound(_intentCount, 0, 8);
    _sigCount = bound(_sigCount, 0, 8);
    if (_sigCount == _intentCount) _sigCount = _intentCount + 1;
    (ITransferIntent.TransferIntent[] memory _intents,) = _batch(_intentCount);
    bytes[] memory _sigs = new bytes[](_sigCount);
    vm.expectRevert(
      abi.encodeWithSelector(IIntentExecutorBatch.IntentExecutor_LengthMismatch.selector, _intentCount, _sigCount)
    );
    vm.prank(_operator);
    _executor.executeBatch(_token, _intents, _sigs);
  }

  function test_WhenEmpty_ItReturnsNothingAndCallsNothing() external {
    vm.expectCall(_token, abi.encodeWithSelector(ITransferIntent.executeTransfer.selector), 0);
    vm.prank(_operator);
    bytes32[] memory _hashes = _executor.executeBatch(_token, new ITransferIntent.TransferIntent[](0), new bytes[](0));
    assertEq(_hashes.length, 0);
  }

  function test_WhenEveryIntentSettles_ItReturnsEachHashInOrder(
    uint256 _length
  ) external {
    _length = bound(_length, 1, 8);
    for (uint256 _i; _i < _length; ++_i) {
      _settles(_i, keccak256(abi.encode('hash', _i)));
    }
    (ITransferIntent.TransferIntent[] memory _intents, bytes[] memory _sigs) = _batch(_length);
    vm.prank(_operator);
    bytes32[] memory _hashes = _executor.executeBatch(_token, _intents, _sigs);
    assertEq(_hashes.length, _length);
    for (uint256 _i; _i < _length; ++_i) {
      assertEq(_hashes[_i], keccak256(abi.encode('hash', _i)));
    }
  }

  function test_WhenOneIntentFails_ItRevertsWithItsIndexAndTheTokensReason(
    uint256 _length,
    uint256 _failing,
    bytes32 _reason
  ) external {
    _length = bound(_length, 1, 8);
    _failing = bound(_failing, 0, _length - 1);
    for (uint256 _i; _i < _length; ++_i) {
      if (_i == _failing) {
        vm.mockCallRevert(
          _token, abi.encodeCall(ITransferIntent.executeTransfer, (_intent(_i), _sig(_i))), _rejected(_reason)
        );
      } else {
        vm.mockCall(
          _token,
          abi.encodeCall(ITransferIntent.executeTransfer, (_intent(_i), _sig(_i))),
          abi.encode(keccak256(abi.encode('hash', _i)))
        );
      }
    }
    (ITransferIntent.TransferIntent[] memory _intents, bytes[] memory _sigs) = _batch(_length);
    vm.expectRevert(
      abi.encodeWithSelector(IIntentExecutorBatch.IntentExecutor_BatchItemFailed.selector, _failing, _rejected(_reason))
    );
    vm.prank(_operator);
    _executor.executeBatch(_token, _intents, _sigs);
  }

  function test_WhenPaused_ItReverts() external {
    vm.prank(_guardian);
    _executor.pause();
    (ITransferIntent.TransferIntent[] memory _intents, bytes[] memory _sigs) = _batch(1);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vm.prank(_operator);
    _executor.executeBatch(_token, _intents, _sigs);
  }
}

contract IntentExecutorUnit_Pause is IntentExecutorUnitTest {
  function test_WhenCallerIsNotGuardian_ItReverts() external {
    vm.expectRevert(_unauthorized(_admin, _executor.GUARDIAN_ROLE()));
    vm.prank(_admin);
    _executor.pause();
  }

  function test_WhenGuardianPauses_ItPausesAndEmits() external {
    vm.expectEmit(address(_executor));
    emit Pausable.Paused(_guardian);
    vm.prank(_guardian);
    _executor.pause();
    assertTrue(_executor.paused());
  }

  function test_WhenGuardianUnpauses_ItReverts() external {
    vm.prank(_guardian);
    _executor.pause();
    vm.expectRevert(_unauthorized(_guardian, _executor.DEFAULT_ADMIN_ROLE()));
    vm.prank(_guardian);
    _executor.unpause();
  }

  function test_WhenAdminUnpauses_ItResumes() external {
    vm.prank(_guardian);
    _executor.pause();
    vm.expectEmit(address(_executor));
    emit Pausable.Unpaused(_admin);
    vm.prank(_admin);
    _executor.unpause();
    assertFalse(_executor.paused());
  }
}

contract IntentExecutorUnit_SupportsInterface is IntentExecutorUnitTest {
  function test_WhenQueried_ItSupportsItsInterfaces() external view {
    assertTrue(_executor.supportsInterface(type(IIntentExecutor).interfaceId));
    assertTrue(_executor.supportsInterface(type(IIntentExecutorBatch).interfaceId));
    assertTrue(_executor.supportsInterface(type(IAccessControl).interfaceId));
    assertTrue(_executor.supportsInterface(type(IERC165).interfaceId));
    assertFalse(_executor.supportsInterface(0xdeadbeef));
  }
}

/// @notice Integration: the executor settling through a real IntentToken, ComplianceHook and IdentityRule
contract IntentExecutorIntegrationTest is IntentTokenIntegrationTest {
  IntentExecutor internal _intentExecutor;
  address internal _operator = makeAddr('operator');

  function setUp() public virtual override {
    super.setUp();
    _intentExecutor = new IntentExecutor(_admin, _guardian);
    vm.startPrank(_admin);
    _intentExecutor.grantRole(_intentExecutor.OPERATOR_ROLE(), _operator);
    _token.grantRole(_token.EXECUTOR_ROLE(), address(_intentExecutor));
    vm.stopPrank();
  }

  function _signedBatch(
    address[] memory _receivers
  ) internal view returns (ITransferIntent.TransferIntent[] memory _intents, bytes[] memory _sigs) {
    _intents = new ITransferIntent.TransferIntent[](_receivers.length);
    _sigs = new bytes[](_receivers.length);
    for (uint256 _i; _i < _receivers.length; ++_i) {
      (_intents[_i], _sigs[_i]) = _signedIntent(_receivers[_i], 1 ether, keccak256(abi.encode('batch', _i)));
    }
  }
}

contract IntentExecutorIntegration_Execute is IntentExecutorIntegrationTest {
  function test_WhenAnOperatorSubmits_TheIntentSettlesWithTheExecutorAsSettler() external {
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_bob, 50 ether, keccak256('n'));

    vm.prank(address(_intentExecutor));
    (bool _ok,) = _token.canExecute(_i);
    assertTrue(_ok);

    vm.expectEmit(address(_token));
    emit ITransferIntent.IntentExecuted(_token.intentHash(_i), _alice, _bob, 50 ether, address(_intentExecutor), _i.ref);
    vm.prank(_operator);
    _intentExecutor.execute(address(_token), _i, _sig);
    assertEq(_token.balanceOf(_bob), 50 ether);
  }

  function test_WhenTheTokenRevokesTheExecutor_SettlementFails() external {
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_bob, 1, keccak256('n'));
    bytes32 _executorRole = _token.EXECUTOR_ROLE();
    vm.prank(_admin);
    _token.revokeRole(_executorRole, address(_intentExecutor));

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, address(_intentExecutor), _executorRole
      )
    );
    vm.prank(_operator);
    _intentExecutor.execute(address(_token), _i, _sig);
  }

  function test_WhenTheExecutorIsPaused_TheTokenStillSettlesThroughOtherExecutors() external {
    (ITransferIntent.TransferIntent memory _i, bytes memory _sig) = _signedIntent(_bob, 1, keccak256('n'));
    vm.prank(_guardian);
    _intentExecutor.pause();

    vm.expectRevert(Pausable.EnforcedPause.selector);
    vm.prank(_operator);
    _intentExecutor.execute(address(_token), _i, _sig);

    vm.prank(_executor);
    _token.executeTransfer(_i, _sig);
    assertEq(_token.balanceOf(_bob), 1);
  }
}

contract IntentExecutorIntegration_ExecuteBatch is IntentExecutorIntegrationTest {
  function test_WhenEveryIntentIsValid_TheBatchSettlesInOneTransaction() external {
    address[] memory _receivers = new address[](3);
    _receivers[0] = _bob;
    _receivers[1] = _treasury;
    _receivers[2] = _bob;
    (ITransferIntent.TransferIntent[] memory _intents, bytes[] memory _sigs) = _signedBatch(_receivers);

    vm.prank(_operator);
    bytes32[] memory _hashes = _intentExecutor.executeBatch(address(_token), _intents, _sigs);

    assertEq(_hashes.length, 3);
    assertEq(_hashes[1], _token.intentHash(_intents[1]));
    assertEq(_token.balanceOf(_bob), 2 ether);
    assertEq(_token.balanceOf(_treasury), 1 ether);
  }

  function test_WhenOneIntentIsRejected_NothingSettlesAndTheIndexIsReported() external {
    address[] memory _receivers = new address[](3);
    _receivers[0] = _bob;
    _receivers[1] = _eve; // never verified
    _receivers[2] = _treasury;
    (ITransferIntent.TransferIntent[] memory _intents, bytes[] memory _sigs) = _signedBatch(_receivers);

    vm.expectRevert(
      abi.encodeWithSelector(
        IIntentExecutorBatch.IntentExecutor_BatchItemFailed.selector, 1, _rejected(Reasons.RECEIVER_NOT_VERIFIED)
      )
    );
    vm.prank(_operator);
    _intentExecutor.executeBatch(address(_token), _intents, _sigs);

    assertEq(_token.balanceOf(_bob), 0);
    assertEq(_token.balanceOf(_alice), 1000 ether);
    assertFalse(_token.nonceUsed(_alice, _intents[0].nonce));
  }

  function test_WhenTheFailingIntentIsDroppedAndResubmitted_TheRestSettles() external {
    address[] memory _receivers = new address[](3);
    _receivers[0] = _bob;
    _receivers[1] = _eve; // never verified
    _receivers[2] = _treasury;
    (ITransferIntent.TransferIntent[] memory _intents, bytes[] memory _sigs) = _signedBatch(_receivers);
    vm.prank(_operator);
    try _intentExecutor.executeBatch(address(_token), _intents, _sigs) {
      revert('batch should have failed');
    } catch (bytes memory _err) {
      (uint256 _index,) = abi.decode(_slice4(_err), (uint256, bytes));
      assertEq(_index, 1);
    }

    ITransferIntent.TransferIntent[] memory _kept = new ITransferIntent.TransferIntent[](2);
    bytes[] memory _keptSigs = new bytes[](2);
    (_kept[0], _keptSigs[0]) = (_intents[0], _sigs[0]);
    (_kept[1], _keptSigs[1]) = (_intents[2], _sigs[2]);
    vm.prank(_operator);
    _intentExecutor.executeBatch(address(_token), _kept, _keptSigs);

    assertEq(IERC20(address(_token)).balanceOf(_bob), 1 ether);
    assertEq(_token.balanceOf(_treasury), 1 ether);
    assertFalse(_token.nonceUsed(_alice, _intents[1].nonce));
  }

  /// @dev Strips the 4-byte error selector from revert data
  function _slice4(
    bytes memory _revertData
  ) internal pure returns (bytes memory _args) {
    _args = new bytes(_revertData.length - 4);
    for (uint256 _i; _i < _args.length; ++_i) {
      _args[_i] = _revertData[_i + 4];
    }
  }
}
