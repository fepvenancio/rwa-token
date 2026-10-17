// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC1271} from '@openzeppelin/contracts/interfaces/IERC1271.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

import {Helpers} from 'contracts/test/Helpers.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';

contract IntentSettledUnitTest is Helpers {
  bytes32 internal constant _DOMAIN_TYPEHASH =
    keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');
  /// @dev secp256k1 group order, used to build a high-s twin of a valid signature
  uint256 internal constant _SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
  string internal constant _NAME = 'Gated Note';

  IntentToken internal _token;
  address internal _registry;
  address internal _hook;

  address internal _admin = makeAddr('timelock');
  address internal _guardian = makeAddr('guardian');
  address internal _minter = makeAddr('minter');
  address internal _executor = makeAddr('executor');
  address internal _stranger = makeAddr('stranger');
  address internal _bob = makeAddr('bob');
  address internal _alice;
  uint256 internal _alicePk;

  function setUp() public virtual {
    (_alice, _alicePk) = makeAddrAndKey('alice');
    _registry = _mockContract('registry');
    _hook = _mockContract('hook');
    vm.mockCall(
      _registry, abi.encodeCall(IPolicyRegistry.isAttested, (_hook, IPolicyRegistry.AttestKind.HOOK)), abi.encode(true)
    );
    _hookDecides(Reasons.TRANSFER_OK);
    vm.mockCall(_hook, abi.encodeCall(IPolicyHook.wantsAfter, ()), abi.encode(false));

    IntentToken _impl = new IntentToken();
    _token = IntentToken(
      address(
        new ERC1967Proxy(
          address(_impl), abi.encodeCall(IntentToken.initialize, (_NAME, 'GNOTE', _admin, _guardian, _registry, _hook))
        )
      )
    );
    vm.startPrank(_admin);
    _token.grantRole(_token.MINTER_ROLE(), _minter);
    _token.grantRole(_token.EXECUTOR_ROLE(), _executor);
    vm.stopPrank();

    vm.prank(_minter);
    _token.mint(_alice, 1000 ether);
  }

  function _hookDecides(
    bytes32 _reason
  ) internal {
    vm.mockCall(_hook, abi.encodeWithSelector(IPolicyHook.beforeTransfer.selector), abi.encode(_reason));
  }

  function _intent(
    uint256 _amount,
    bytes32 _nonce,
    uint256 _deadline
  ) internal view returns (ITransferIntent.TransferIntent memory _transferIntent) {
    _transferIntent = ITransferIntent.TransferIntent({
      from: _alice, to: _bob, amount: _amount, nonce: _nonce, deadline: _deadline, ref: bytes32('ISO20022:MSG-1')
    });
  }

  function _structHash(
    ITransferIntent.TransferIntent memory _i
  ) internal view returns (bytes32 _hash) {
    _hash = keccak256(
      abi.encode(_token.TRANSFER_INTENT_TYPEHASH(), _i.from, _i.to, _i.amount, _i.nonce, _i.deadline, _i.ref)
    );
  }

  function _digest(
    ITransferIntent.TransferIntent memory _i,
    uint256 _chainId,
    address _verifyingContract
  ) internal view returns (bytes32 _hash) {
    bytes32 _domain =
      keccak256(abi.encode(_DOMAIN_TYPEHASH, keccak256(bytes(_NAME)), keccak256('1'), _chainId, _verifyingContract));
    _hash = keccak256(abi.encodePacked('\x19\x01', _domain, _structHash(_i)));
  }

  function _sign(
    uint256 _pk,
    bytes32 _hash
  ) internal pure returns (bytes memory _sig) {
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_pk, _hash);
    _sig = abi.encodePacked(_r, _s, _v);
  }

  function _signed(
    ITransferIntent.TransferIntent memory _i
  ) internal view returns (bytes memory _sig) {
    _sig = _sign(_alicePk, _token.intentHash(_i));
  }

  function _execute(
    ITransferIntent.TransferIntent memory _i,
    bytes memory _sig
  ) internal returns (bytes32 _hash) {
    vm.prank(_executor);
    _hash = _token.executeTransfer(_i, _sig);
  }

  function _rejected(
    bytes32 _reason
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IPolicyGated.PolicyGated_TransferRejected.selector, _reason);
  }
}

contract IntentSettledUnit_IntentHash is IntentSettledUnitTest {
  function test_WhenQueried_ItMatchesTheEip712Digest(
    uint256 _amount,
    bytes32 _nonce,
    uint256 _deadline
  ) external view {
    ITransferIntent.TransferIntent memory _i = _intent(_amount, _nonce, _deadline);
    assertEq(_token.intentHash(_i), _digest(_i, block.chainid, address(_token)));
  }
}

contract IntentSettledUnit_ExecuteTransfer is IntentSettledUnitTest {
  function test_WhenCallerIsNotExecutor_ItReverts() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    bytes memory _sig = _signed(_i);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, _stranger, _token.EXECUTOR_ROLE()
      )
    );
    vm.prank(_stranger);
    _token.executeTransfer(_i, _sig);
  }

  function test_WhenValid_ItMovesWithAnExecutedContextAndEmits(
    uint256 _amount,
    bytes32 _nonce
  ) external {
    _amount = bound(_amount, 0, 1000 ether);
    ITransferIntent.TransferIntent memory _i = _intent(_amount, _nonce, block.timestamp + 1 days);
    bytes memory _sig = _signed(_i);
    bytes32 _expectedHash = _token.intentHash(_i);

    IPolicyHook.TransferContext memory _ctx = IPolicyHook.TransferContext({
      token: address(_token),
      from: _alice,
      to: _bob,
      id: 0,
      amount: _amount,
      operator: _executor,
      kind: IPolicyHook.TransferKind.EXECUTED,
      ref: _i.ref,
      deadline: _i.deadline,
      extra: ''
    });
    vm.expectCall(_hook, abi.encodeCall(IPolicyHook.beforeTransfer, (_ctx)));
    vm.expectEmit(address(_token));
    emit ITransferIntent.IntentExecuted(_expectedHash, _alice, _bob, _amount, _executor, _i.ref);

    assertEq(_execute(_i, _sig), _expectedHash);
    assertEq(_token.balanceOf(_bob), _amount);
    assertTrue(_token.nonceUsed(_alice, _nonce));
  }

  /// @dev The kind, ref and deadline live in transient storage for the whole transaction; they must be cleared after
  ///      each movement, or a later plain transfer in the same transaction would reach the hook as EXECUTED
  function test_WhenAPlainTransferFollowsAnExecutionInTheSameTransaction_ItIsAPlainTransfer() external {
    ITransferIntent.TransferIntent memory _i = _intent(10, keccak256('n'), block.timestamp + 1 days);
    _execute(_i, _signed(_i));

    IPolicyHook.TransferContext memory _plain = IPolicyHook.TransferContext({
      token: address(_token),
      from: _bob,
      to: _alice,
      id: 0,
      amount: 1,
      operator: _bob,
      kind: IPolicyHook.TransferKind.TRANSFER,
      ref: bytes32(0),
      deadline: 0,
      extra: ''
    });
    vm.expectCall(_hook, abi.encodeCall(IPolicyHook.beforeTransfer, (_plain)));
    vm.prank(_bob);
    _token.transfer(_alice, 1);
  }

  function test_WhenDeadlineIsNow_ItExecutes() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    _execute(_i, _signed(_i));
    assertEq(_token.balanceOf(_bob), 1);
  }

  function test_WhenDeadlinePassed_ItRevertsWithIntentExpired(
    uint256 _lateness
  ) external {
    _lateness = bound(_lateness, 1, 365 days);
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    bytes memory _sig = _signed(_i);
    vm.warp(block.timestamp + _lateness);
    vm.expectRevert(_rejected(Reasons.INTENT_EXPIRED));
    _execute(_i, _sig);
  }

  function test_WhenReplayed_ItRevertsWithNonceUsed() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    bytes memory _sig = _signed(_i);
    _execute(_i, _sig);
    vm.expectRevert(_rejected(Reasons.NONCE_USED));
    _execute(_i, _sig);
  }

  function test_WhenTheExecutorAltersTheIntent_ItRevertsWithBadSignature(
    uint256 _amount
  ) external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    bytes memory _sig = _signed(_i);
    _i.amount = bound(_amount, 2, 1000 ether);
    vm.expectRevert(_rejected(Reasons.BAD_SIGNATURE));
    _execute(_i, _sig);
  }

  function test_WhenSignedByAnotherKey_ItRevertsWithBadSignature() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    (, uint256 _evePk) = makeAddrAndKey('eve');
    bytes memory _sig = _sign(_evePk, _token.intentHash(_i));
    vm.expectRevert(_rejected(Reasons.BAD_SIGNATURE));
    _execute(_i, _sig);
  }

  function test_WhenSignedForAnotherChain_ItRevertsWithBadSignature(
    uint256 _chainId
  ) external {
    _chainId = bound(_chainId, block.chainid + 1, type(uint64).max);
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    bytes memory _sig = _sign(_alicePk, _digest(_i, _chainId, address(_token)));
    vm.expectRevert(_rejected(Reasons.BAD_SIGNATURE));
    _execute(_i, _sig);
  }

  function test_WhenSignedForAnotherToken_ItRevertsWithBadSignature() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    bytes memory _sig = _sign(_alicePk, _digest(_i, block.chainid, makeAddr('otherToken')));
    vm.expectRevert(_rejected(Reasons.BAD_SIGNATURE));
    _execute(_i, _sig);
  }

  function test_WhenSignatureIsMalleatedToHighS_ItRevertsWithBadSignature() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_alicePk, _token.intentHash(_i));
    bytes32 _highS = bytes32(_SECP256K1_N - uint256(_s));
    uint8 _flippedV = _v == 27 ? 28 : 27;
    vm.expectRevert(_rejected(Reasons.BAD_SIGNATURE));
    _execute(_i, abi.encodePacked(_r, _highS, _flippedV));
  }

  function test_WhenFromIsAnErc1271WalletThatApproves_ItExecutes() external {
    address _wallet = _mockContract('wallet');
    vm.prank(_minter);
    _token.mint(_wallet, 10);
    ITransferIntent.TransferIntent memory _i = _intent(10, keccak256('n'), block.timestamp);
    _i.from = _wallet;
    // 64 bytes: OZ encodes the signature without zero-padding, so use a word-aligned length to match exactly.
    bytes memory _sig = abi.encode(keccak256('r'), keccak256('s'));
    _mockAndExpect(
      _wallet,
      abi.encodeCall(IERC1271.isValidSignature, (_token.intentHash(_i), _sig)),
      abi.encode(IERC1271.isValidSignature.selector)
    );
    _execute(_i, _sig);
    assertEq(_token.balanceOf(_bob), 10);
  }

  function test_WhenHookRejects_ItRevertsAndKeepsTheNonceUnused(
    bytes32 _reason
  ) external {
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.OUTSIDE_SETTLEMENT_WINDOW;
    _hookDecides(_reason);
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    bytes memory _sig = _signed(_i);
    vm.expectRevert(_rejected(_reason));
    _execute(_i, _sig);
    assertFalse(_token.nonceUsed(_alice, keccak256('n')));
  }
}

contract IntentSettledUnit_CancelIntent is IntentSettledUnitTest {
  function test_WhenNonceIsFresh_ItMarksItUsedAndEmits(
    bytes32 _nonce
  ) external {
    vm.expectEmit(address(_token));
    emit ITransferIntent.IntentCancelled(_alice, _nonce);
    vm.prank(_alice);
    _token.cancelIntent(_nonce);
    assertTrue(_token.nonceUsed(_alice, _nonce));
  }

  function test_WhenNonceIsAlreadyUsed_ItReverts() external {
    vm.startPrank(_alice);
    _token.cancelIntent(keccak256('n'));
    vm.expectRevert(_rejected(Reasons.NONCE_USED));
    _token.cancelIntent(keccak256('n'));
    vm.stopPrank();
  }

  function test_WhenCancelledBeforeExecution_ItBlocksTheIntent() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    bytes memory _sig = _signed(_i);
    vm.prank(_alice);
    _token.cancelIntent(keccak256('n'));
    vm.expectRevert(_rejected(Reasons.NONCE_USED));
    _execute(_i, _sig);
  }

  function test_WhenAnotherAccountCancels_ItDoesNotAffectTheSigner() external {
    vm.prank(_stranger);
    _token.cancelIntent(keccak256('n'));
    assertFalse(_token.nonceUsed(_alice, keccak256('n')));
  }
}

contract IntentSettledUnit_CanExecute is IntentSettledUnitTest {
  function test_WhenExecutable_ItReturnsOk() external {
    vm.prank(_executor);
    (bool _ok, bytes32 _reason) = _token.canExecute(_intent(1, keccak256('n'), block.timestamp));
    assertTrue(_ok);
    assertEq(_reason, Reasons.TRANSFER_OK);
  }

  function test_WhenExpired_ItReturnsIntentExpired() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    vm.warp(block.timestamp + 1);
    (bool _ok, bytes32 _reason) = _token.canExecute(_i);
    assertFalse(_ok);
    assertEq(_reason, Reasons.INTENT_EXPIRED);
  }

  function test_WhenNonceUsed_ItReturnsNonceUsed() external {
    vm.prank(_alice);
    _token.cancelIntent(keccak256('n'));
    (bool _ok, bytes32 _reason) = _token.canExecute(_intent(1, keccak256('n'), block.timestamp));
    assertFalse(_ok);
    assertEq(_reason, Reasons.NONCE_USED);
  }

  function test_WhenHookRejects_ItAgreesWithExecuteTransfer(
    bytes32 _reason
  ) external {
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.OUTSIDE_SETTLEMENT_WINDOW;
    _hookDecides(_reason);
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    (bool _ok, bytes32 _preflight) = _token.canExecute(_i);
    assertFalse(_ok);
    assertEq(_preflight, _reason);
    bytes memory _sig = _signed(_i);
    vm.expectRevert(_rejected(_reason));
    _execute(_i, _sig);
  }
}

contract IntentSettledUnit_SupportsInterface is IntentSettledUnitTest {
  function test_WhenQueried_ItSupportsTransferIntentAndTheBase() external view {
    assertTrue(_token.supportsInterface(type(ITransferIntent).interfaceId));
    assertTrue(_token.supportsInterface(type(IPolicyGated).interfaceId));
  }
}
