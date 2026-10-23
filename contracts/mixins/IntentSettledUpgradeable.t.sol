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
  address internal _otherExecutor = makeAddr('otherExecutor');
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
    _token.grantRole(_token.EXECUTOR_ROLE(), _otherExecutor);
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
      from: _alice,
      to: _bob,
      amount: _amount,
      nonce: _nonce,
      deadline: _deadline,
      ref: bytes32('ISO20022:MSG-1'),
      executor: address(0),
      validAfter: 0,
      considerationToken: address(0),
      considerationAmount: 0
    });
  }

  function _structHash(
    ITransferIntent.TransferIntent memory _i
  ) internal view returns (bytes32 _hash) {
    _hash = keccak256(
      abi.encode(
        _token.TRANSFER_INTENT_TYPEHASH(),
        _i.from,
        _i.to,
        _i.amount,
        _i.nonce,
        _i.deadline,
        _i.ref,
        _i.executor,
        _i.validAfter,
        _i.considerationToken,
        _i.considerationAmount
      )
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

  function _executeAs(
    address _caller,
    ITransferIntent.TransferIntent memory _i,
    bytes memory _sig
  ) internal returns (bytes32 _hash) {
    vm.prank(_caller);
    _hash = _token.executeTransfer(_i, _sig);
  }

  function _canExecuteAs(
    address _caller,
    ITransferIntent.TransferIntent memory _i,
    bytes memory _sig
  ) internal returns (bool _ok, bytes32 _reason) {
    vm.prank(_caller);
    (_ok, _reason) = _token.canExecute(_i, _sig);
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
    uint256 _deadline,
    address _boundExecutor,
    uint256 _validAfter,
    address _considerationToken,
    uint256 _considerationAmount
  ) external view {
    ITransferIntent.TransferIntent memory _i = _intent(_amount, _nonce, _deadline);
    _i.executor = _boundExecutor;
    _i.validAfter = _validAfter;
    _i.considerationToken = _considerationToken;
    _i.considerationAmount = _considerationAmount;
    assertEq(_token.intentHash(_i), _digest(_i, block.chainid, address(_token)));
  }

  function test_WhenQueried_ItUsesThePinnedTypehash() external view {
    assertEq(
      _token.TRANSFER_INTENT_TYPEHASH(),
      keccak256(
        'TransferIntent(address from,address to,uint256 amount,bytes32 nonce,uint256 deadline,bytes32 ref,address executor,uint256 validAfter,address considerationToken,uint256 considerationAmount)'
      )
    );
  }

  function test_WhenAnyNewFieldChanges_TheHashChanges() external view {
    ITransferIntent.TransferIntent memory _base = _intent(1, keccak256('n'), block.timestamp);
    bytes32 _baseHash = _token.intentHash(_base);

    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    _i.executor = _executor;
    assertNotEq(_token.intentHash(_i), _baseHash, 'executor');

    _i = _intent(1, keccak256('n'), block.timestamp);
    _i.validAfter = 1;
    assertNotEq(_token.intentHash(_i), _baseHash, 'validAfter');

    _i = _intent(1, keccak256('n'), block.timestamp);
    _i.considerationToken = _executor;
    assertNotEq(_token.intentHash(_i), _baseHash, 'considerationToken');

    _i = _intent(1, keccak256('n'), block.timestamp);
    _i.considerationAmount = 1;
    assertNotEq(_token.intentHash(_i), _baseHash, 'considerationAmount');
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

contract IntentSettledUnit_Executor is IntentSettledUnitTest {
  function test_WhenExecutorIsZero_AnyExecutorRoleHolderExecutes() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    _executeAs(_otherExecutor, _i, _signed(_i));
    assertEq(_token.balanceOf(_bob), 1);
  }

  function test_WhenExecutorIsTheCaller_ItExecutes() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    _i.executor = _executor;
    _executeAs(_executor, _i, _signed(_i));
    assertEq(_token.balanceOf(_bob), 1);
  }

  function test_WhenExecutorIsAnotherRoleHolder_ItRevertsWithWrongExecutorAndKeepsTheNonce() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    _i.executor = _otherExecutor;
    bytes memory _sig = _signed(_i);

    vm.expectRevert(_rejected(Reasons.WRONG_EXECUTOR));
    _executeAs(_executor, _i, _sig);
    assertFalse(_token.nonceUsed(_alice, keccak256('n')));

    _executeAs(_otherExecutor, _i, _sig);
    assertEq(_token.balanceOf(_bob), 1);
  }

  function test_WhenExecutorNamesAnyOtherAddress_ItNeverExecutesFromTheCaller(
    address _named
  ) external {
    if (_named == address(0) || _named == _executor) _named = _otherExecutor;
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    _i.executor = _named;
    bytes memory _sig = _signed(_i);
    vm.expectRevert(_rejected(Reasons.WRONG_EXECUTOR));
    _executeAs(_executor, _i, _sig);
  }

  function test_WhenTheCallerLacksTheRole_TheRoleCheckComesFirst() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    _i.executor = _otherExecutor;
    bytes memory _sig = _signed(_i);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, _stranger, _token.EXECUTOR_ROLE()
      )
    );
    _executeAs(_stranger, _i, _sig);
  }
}

contract IntentSettledUnit_ValidAfter is IntentSettledUnitTest {
  function test_WhenValidAfterIsNow_ItExecutes() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp + 1 days);
    _i.validAfter = block.timestamp;
    _execute(_i, _signed(_i));
    assertEq(_token.balanceOf(_bob), 1);
  }

  function test_WhenBeforeValidAfter_ItRevertsWithIntentNotYetValidUntilThatSecond(
    uint256 _wait
  ) external {
    _wait = bound(_wait, 2, 30 days);
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp + 60 days);
    _i.validAfter = block.timestamp + _wait;
    bytes memory _sig = _signed(_i);

    vm.expectRevert(_rejected(Reasons.INTENT_NOT_YET_VALID));
    _execute(_i, _sig);
    assertFalse(_token.nonceUsed(_alice, keccak256('n')));

    vm.warp(_i.validAfter - 1);
    vm.expectRevert(_rejected(Reasons.INTENT_NOT_YET_VALID));
    _execute(_i, _sig);

    vm.warp(_i.validAfter);
    _execute(_i, _sig);
    assertEq(_token.balanceOf(_bob), 1);
  }

  function test_WhenTheWindowIsEmpty_ItNeverExecutes() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp + 5);
    _i.validAfter = block.timestamp + 10;
    bytes memory _sig = _signed(_i);
    uint256 _start = block.timestamp;

    vm.expectRevert(_rejected(Reasons.INTENT_NOT_YET_VALID));
    _execute(_i, _sig);
    vm.warp(_start + 6);
    vm.expectRevert(_rejected(Reasons.INTENT_EXPIRED));
    _execute(_i, _sig);
    vm.warp(_start + 10);
    vm.expectRevert(_rejected(Reasons.INTENT_EXPIRED));
    _execute(_i, _sig);
  }
}

contract IntentSettledUnit_Consideration is IntentSettledUnitTest {
  address internal _cash = makeAddr('cashToken');

  function _assertNeedsExecutor(
    address _considerationToken,
    uint256 _considerationAmount
  ) internal {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    _i.considerationToken = _considerationToken;
    _i.considerationAmount = _considerationAmount;
    bytes memory _sig = _signed(_i);
    vm.expectRevert(_rejected(Reasons.CONSIDERATION_NEEDS_EXECUTOR));
    _execute(_i, _sig);
    assertFalse(_token.nonceUsed(_alice, keccak256('n')));
  }

  function test_WhenOnlyTheAmountIsSetAndNoExecutor_ItReverts() external {
    _assertNeedsExecutor(address(0), 1);
  }

  function test_WhenOnlyTheTokenIsSetAndNoExecutor_ItReverts() external {
    _assertNeedsExecutor(_cash, 0);
  }

  function test_WhenBothAreSetAndNoExecutor_ItReverts() external {
    _assertNeedsExecutor(_cash, 777);
  }

  function test_WhenAnyConsiderationIsSetAndNoExecutor_ItNeverExecutes(
    address _considerationToken,
    uint256 _considerationAmount
  ) external {
    if (_considerationToken == address(0) && _considerationAmount == 0) _considerationAmount = 1;
    _assertNeedsExecutor(_considerationToken, _considerationAmount);
  }

  function test_WhenConsiderationIsSetWithAnExecutor_ItExecutesAndTheHookSeesNoConsideration() external {
    ITransferIntent.TransferIntent memory _i = _intent(10, keccak256('n'), block.timestamp + 1 days);
    _i.executor = _executor;
    _i.considerationToken = _cash;
    _i.considerationAmount = 777;
    bytes memory _sig = _signed(_i);

    IPolicyHook.TransferContext memory _ctx = IPolicyHook.TransferContext({
      token: address(_token),
      from: _alice,
      to: _bob,
      id: 0,
      amount: 10,
      operator: _executor,
      kind: IPolicyHook.TransferKind.EXECUTED,
      ref: _i.ref,
      deadline: _i.deadline,
      extra: ''
    });
    vm.expectCall(_hook, abi.encodeCall(IPolicyHook.beforeTransfer, (_ctx)));
    vm.expectEmit(address(_token));
    emit ITransferIntent.IntentExecuted(_token.intentHash(_i), _alice, _bob, 10, _executor, _i.ref);
    _executeAs(_executor, _i, _sig);
    assertEq(_token.balanceOf(_bob), 10);
  }
}

contract IntentSettledUnit_CheckOrder is IntentSettledUnitTest {
  function _malformed() internal view returns (ITransferIntent.TransferIntent memory _i) {
    _i = _intent(1, keccak256('n'), block.timestamp);
    _i.considerationAmount = 1;
  }

  function test_WhenTheIntentIsExpiredAndMalformed_ExpiryWins() external {
    ITransferIntent.TransferIntent memory _i = _malformed();
    _i.validAfter = block.timestamp + 5;
    bytes memory _sig = _signed(_i);
    vm.warp(block.timestamp + 1);
    vm.expectRevert(_rejected(Reasons.INTENT_EXPIRED));
    _execute(_i, _sig);
  }

  function test_WhenTheNonceIsUsedAndTheIntentIsMalformed_NonceUsedWins() external {
    ITransferIntent.TransferIntent memory _i = _malformed();
    bytes memory _sig = _signed(_i);
    vm.prank(_alice);
    _token.cancelIntent(keccak256('n'));
    vm.expectRevert(_rejected(Reasons.NONCE_USED));
    _execute(_i, _sig);
  }

  function test_WhenTheNonceIsUsedAndTheExecutorIsWrong_NonceUsedWins() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    _i.executor = _otherExecutor;
    bytes memory _sig = _signed(_i);
    vm.prank(_alice);
    _token.cancelIntent(keccak256('n'));
    vm.expectRevert(_rejected(Reasons.NONCE_USED));
    _execute(_i, _sig);
  }

  function test_WhenTheIntentIsMalformedAndNotYetValid_TheConsiderationCheckWins() external {
    ITransferIntent.TransferIntent memory _i = _malformed();
    _i.deadline = block.timestamp + 1 days;
    _i.validAfter = block.timestamp + 5;
    bytes memory _sig = _signed(_i);
    vm.expectRevert(_rejected(Reasons.CONSIDERATION_NEEDS_EXECUTOR));
    _execute(_i, _sig);
  }

  function test_WhenTheExecutorIsWrongAndTheIntentIsNotYetValid_TheExecutorCheckWins() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp + 1 days);
    _i.executor = _otherExecutor;
    _i.validAfter = block.timestamp + 5;
    bytes memory _sig = _signed(_i);
    vm.expectRevert(_rejected(Reasons.WRONG_EXECUTOR));
    _execute(_i, _sig);
  }

  function test_WhenTheIntentIsNotYetValidAndTheSignatureIsBad_TheWindowWins() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp + 1 days);
    _i.validAfter = block.timestamp + 5;
    (, uint256 _evePk) = makeAddrAndKey('eve');
    bytes memory _sig = _sign(_evePk, _token.intentHash(_i));
    vm.expectRevert(_rejected(Reasons.INTENT_NOT_YET_VALID));
    _execute(_i, _sig);
  }

  function test_WhenTheSignatureIsBadAndTheHookRejects_TheSignatureWins() external {
    _hookDecides(Reasons.OUTSIDE_SETTLEMENT_WINDOW);
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    (, uint256 _evePk) = makeAddrAndKey('eve');
    bytes memory _sig = _sign(_evePk, _token.intentHash(_i));
    vm.expectRevert(_rejected(Reasons.BAD_SIGNATURE));
    _execute(_i, _sig);
    (bool _ok, bytes32 _reason) = _canExecuteAs(_executor, _i, _sig);
    assertFalse(_ok);
    assertEq(_reason, Reasons.BAD_SIGNATURE);
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
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    vm.prank(_executor);
    (bool _ok, bytes32 _reason) = _token.canExecute(_i, _signed(_i));
    assertTrue(_ok);
    assertEq(_reason, Reasons.TRANSFER_OK);
  }

  function test_WhenExpired_ItReturnsIntentExpired() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    bytes memory _sig = _signed(_i);
    vm.warp(block.timestamp + 1);
    (bool _ok, bytes32 _reason) = _token.canExecute(_i, _sig);
    assertFalse(_ok);
    assertEq(_reason, Reasons.INTENT_EXPIRED);
  }

  function test_WhenNonceUsed_ItReturnsNonceUsed() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    bytes memory _sig = _signed(_i);
    vm.prank(_alice);
    _token.cancelIntent(keccak256('n'));
    (bool _ok, bytes32 _reason) = _token.canExecute(_i, _sig);
    assertFalse(_ok);
    assertEq(_reason, Reasons.NONCE_USED);
  }

  function test_WhenHookRejects_ItAgreesWithExecuteTransfer(
    bytes32 _reason
  ) external {
    if (_reason == Reasons.TRANSFER_OK) _reason = Reasons.OUTSIDE_SETTLEMENT_WINDOW;
    _hookDecides(_reason);
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    bytes memory _sig = _signed(_i);
    (bool _ok, bytes32 _preflight) = _token.canExecute(_i, _sig);
    assertFalse(_ok);
    assertEq(_preflight, _reason);
    vm.expectRevert(_rejected(_reason));
    _execute(_i, _sig);
  }

  function test_WhenTheSignatureIsBad_ItReturnsBadSignatureAndExecuteTransferAgrees() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    (, uint256 _evePk) = makeAddrAndKey('eve');
    bytes memory _sig = _sign(_evePk, _token.intentHash(_i));
    (bool _ok, bytes32 _reason) = _canExecuteAs(_executor, _i, _sig);
    assertFalse(_ok);
    assertEq(_reason, Reasons.BAD_SIGNATURE);
    vm.expectRevert(_rejected(Reasons.BAD_SIGNATURE));
    _execute(_i, _sig);
  }

  function test_WhenTheSignatureIsOverAnAlteredIntent_ItReturnsBadSignature() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    bytes memory _sig = _signed(_i);
    _i.amount = 2;
    (bool _ok, bytes32 _reason) = _canExecuteAs(_executor, _i, _sig);
    assertFalse(_ok);
    assertEq(_reason, Reasons.BAD_SIGNATURE);
  }

  function test_WhenFromIsAnErc1271WalletThatApproves_ItReturnsOk() external {
    address _wallet = _mockContract('wallet');
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    _i.from = _wallet;
    bytes memory _sig = abi.encode(keccak256('r'), keccak256('s'));
    vm.prank(_minter);
    _token.mint(_wallet, 1);
    _mockAndExpect(
      _wallet,
      abi.encodeCall(IERC1271.isValidSignature, (_token.intentHash(_i), _sig)),
      abi.encode(IERC1271.isValidSignature.selector)
    );
    (bool _ok, bytes32 _reason) = _canExecuteAs(_executor, _i, _sig);
    assertTrue(_ok);
    assertEq(_reason, Reasons.TRANSFER_OK);
  }

  function test_WhenTheNamedExecutorIsNotTheCaller_ItReturnsWrongExecutor() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    _i.executor = _otherExecutor;
    bytes memory _sig = _signed(_i);

    (bool _ok, bytes32 _reason) = _canExecuteAs(_executor, _i, _sig);
    assertFalse(_ok);
    assertEq(_reason, Reasons.WRONG_EXECUTOR);

    (_ok, _reason) = _canExecuteAs(_otherExecutor, _i, _sig);
    assertTrue(_ok);
    assertEq(_reason, Reasons.TRANSFER_OK);
  }

  function test_WhenBeforeValidAfter_ItReturnsIntentNotYetValid() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp + 1 days);
    _i.validAfter = block.timestamp + 1;
    bytes memory _sig = _signed(_i);
    (bool _ok, bytes32 _reason) = _canExecuteAs(_executor, _i, _sig);
    assertFalse(_ok);
    assertEq(_reason, Reasons.INTENT_NOT_YET_VALID);
  }

  function test_WhenConsiderationIsSetWithoutAnExecutor_ItReturnsConsiderationNeedsExecutor() external {
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp);
    _i.considerationToken = makeAddr('cashToken');
    _i.considerationAmount = 5;
    bytes memory _sig = _signed(_i);
    (bool _ok, bytes32 _reason) = _canExecuteAs(_executor, _i, _sig);
    assertFalse(_ok);
    assertEq(_reason, Reasons.CONSIDERATION_NEEDS_EXECUTOR);
  }

  /// @dev Pre-flight never lies: for any combination of the new checks, the signature, the nonce, the window and the
  ///      hook, `canExecute` returns exactly what `executeTransfer` reverts with, or the call succeeds
  function test_WhenAnyIntentIsChecked_CanExecuteAgreesWithExecuteTransfer(
    uint8 _executorChoice,
    uint8 _timeChoice,
    uint8 _considerationChoice,
    bool _goodSignature,
    bool _nonceSpent,
    bool _hookRejects,
    bool _callerIsOther
  ) external {
    vm.warp(1_000_000);
    ITransferIntent.TransferIntent memory _i = _intent(1, keccak256('n'), block.timestamp + 1 days);

    _executorChoice = uint8(bound(_executorChoice, 0, 2));
    if (_executorChoice == 1) _i.executor = _executor;
    if (_executorChoice == 2) _i.executor = _otherExecutor;

    _timeChoice = uint8(bound(_timeChoice, 0, 4));
    if (_timeChoice == 1) _i.validAfter = block.timestamp;
    if (_timeChoice == 2) _i.validAfter = block.timestamp + 1;
    if (_timeChoice == 3) _i.deadline = block.timestamp;
    if (_timeChoice == 4) _i.deadline = block.timestamp - 1;

    _considerationChoice = uint8(bound(_considerationChoice, 0, 3));
    if (_considerationChoice == 1) _i.considerationAmount = 1;
    if (_considerationChoice == 2) _i.considerationToken = makeAddr('cashToken');
    if (_considerationChoice == 3) {
      _i.considerationToken = makeAddr('cashToken');
      _i.considerationAmount = 9;
    }

    (, uint256 _evePk) = makeAddrAndKey('eve');
    bytes memory _sig = _sign(_goodSignature ? _alicePk : _evePk, _token.intentHash(_i));
    if (_nonceSpent) {
      vm.prank(_alice);
      _token.cancelIntent(keccak256('n'));
    }
    if (_hookRejects) _hookDecides(Reasons.OUTSIDE_SETTLEMENT_WINDOW);

    address _caller = _callerIsOther ? _otherExecutor : _executor;
    (bool _ok, bytes32 _reason) = _canExecuteAs(_caller, _i, _sig);

    vm.prank(_caller);
    try _token.executeTransfer(_i, _sig) {
      assertTrue(_ok, 'executed but pre-flight said no');
      assertEq(_reason, Reasons.TRANSFER_OK);
    } catch (bytes memory _revertData) {
      assertFalse(_ok, 'reverted but pre-flight said yes');
      assertEq(_revertData, _rejected(_reason));
    }
  }
}

contract IntentSettledUnit_SupportsInterface is IntentSettledUnitTest {
  function test_WhenQueried_ItSupportsTransferIntentAndTheBase() external view {
    assertTrue(_token.supportsInterface(type(ITransferIntent).interfaceId));
    assertTrue(_token.supportsInterface(type(IPolicyGated).interfaceId));
  }
}
