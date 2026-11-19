// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC1155Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {Initializable} from '@openzeppelin/contracts/proxy/utils/Initializable.sol';
import {IERC1155} from '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';
import {IERC1155Receiver} from '@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol';
import {IERC1155MetadataURI} from '@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import {Test, Vm} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC7943MultiToken} from 'interfaces/IERC7943MultiToken.sol';
import {IERC8473} from 'interfaces/IERC8473.sol';
import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';
import {IGated1155} from 'interfaces/IGated1155.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyGatedCore} from 'interfaces/IPolicyGatedCore.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';
import {Quals} from 'interfaces/Quals.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {CredentialRule} from 'contracts/hooks/rules/CredentialRule.sol';
import {HolderRestrictionRule} from 'contracts/hooks/rules/HolderRestrictionRule.sol';
import {CredentialRegistry} from 'contracts/identity/CredentialRegistry.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {Gated1155} from 'contracts/tokens/Gated1155.sol';
import {GatedToken} from 'contracts/tokens/GatedToken.sol';

/// @notice A policy that records what the token had done by the time each `afterTransfer` reached it, can reject one
///         token id, and can call back into the token from a chosen `afterTransfer`
contract MockRecordingPolicy {
  /// @notice The registry the policy names
  address public immutable REGISTRY;
  /// @notice How many times `afterTransfer` was called
  uint256 public afterCount;
  /// @notice The id whose balance of the receiver is read at each `afterTransfer`
  uint256 public probeId;
  /// @notice The receiver's balance of `probeId` at each `afterTransfer`
  uint256[] public probeSeen;
  /// @notice The supply of the moved id at each `afterTransfer`
  uint256[] public supplySeen;
  /// @notice The id of each `afterTransfer`, in order
  uint256[] public idsSeen;
  /// @notice The id `checkTransfer` rejects, when `rejectReason` is set
  uint256 public rejectId;
  /// @notice The sender `checkTransfer` rejects, when it is not zero
  address public rejectFrom;
  /// @notice The reason it rejects with; zero rejects nothing
  bytes32 public rejectReason;
  /// @notice The `afterTransfer` call, counted from one, that calls back into the token; zero never does
  uint256 public reenterAt;

  constructor(
    address _registry
  ) {
    REGISTRY = _registry;
  }

  function setProbe(
    uint256 _probeId
  ) external {
    probeId = _probeId;
  }

  function setRejection(
    uint256 _rejectId,
    address _rejectFrom,
    bytes32 _rejectReason
  ) external {
    rejectId = _rejectId;
    rejectFrom = _rejectFrom;
    rejectReason = _rejectReason;
  }

  function setReenterAt(
    uint256 _call
  ) external {
    reenterAt = _call;
  }

  function onInstall(
    address,
    address,
    bytes calldata
  ) external {}

  function afterTransfer(
    IERC8473Policy.TransferContext calldata _ctx
  ) external {
    ++afterCount;
    idsSeen.push(_ctx.tokenId);
    probeSeen.push(IERC1155(_ctx.token).balanceOf(_ctx.to, probeId));
    supplySeen.push(Gated1155(_ctx.token).totalSupply(_ctx.tokenId));
    if (afterCount == reenterAt) {
      IERC1155(_ctx.token).safeTransferFrom(_ctx.to, address(0xbeef), _ctx.tokenId, 0, '');
    }
  }

  function checkTransfer(
    IERC8473Policy.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    bool _matches = rejectFrom == address(0) ? _ctx.tokenId == rejectId : _ctx.from == rejectFrom;
    _reason = rejectReason != bytes32(0) && _matches ? rejectReason : Reasons.TRANSFER_OK;
  }

  function wantsAfterTransfer() external pure returns (bool _wants) {
    _wants = true;
  }

  function supportsInterface(
    bytes4
  ) external pure returns (bool _supported) {
    _supported = true;
  }

  function checkSend(
    address,
    address
  ) external pure returns (bytes32 _reason) {
    _reason = Reasons.TRANSFER_OK;
  }

  function checkReceive(
    address,
    address
  ) external pure returns (bytes32 _reason) {
    _reason = Reasons.TRANSFER_OK;
  }
}

/// @notice An ERC-1155 receiver that records its callbacks and, when given somewhere to forward, passes on what it
///         receives from inside the callback
contract MockReceiver is IERC1155Receiver {
  /// @notice The policy whose `afterCount` it reads in each callback; zero reads none
  MockRecordingPolicy public immutable POLICY;
  /// @notice Where it forwards; zero keeps the tokens
  address public immutable NEXT;
  /// @notice Calls to `onERC1155Received`
  uint256 public singles;
  /// @notice Calls to `onERC1155BatchReceived`
  uint256 public batches;
  /// @notice The policy's `afterCount` when the last callback ran
  uint256 public afterCountSeen;
  /// @notice The data of the last callback
  bytes public lastData;
  /// @notice The operator of the last callback
  address public lastOperator;

  constructor(
    MockRecordingPolicy _policy,
    address _next
  ) {
    POLICY = _policy;
    NEXT = _next;
  }

  function onERC1155Received(
    address _operator,
    address,
    uint256 _id,
    uint256 _value,
    bytes calldata _data
  ) external returns (bytes4 _selector) {
    ++singles;
    _record(_operator, _data);
    if (NEXT != address(0)) IERC1155(msg.sender).safeTransferFrom(address(this), NEXT, _id, _value, '');
    _selector = IERC1155Receiver.onERC1155Received.selector;
  }

  function onERC1155BatchReceived(
    address _operator,
    address,
    uint256[] calldata _ids,
    uint256[] calldata _values,
    bytes calldata _data
  ) external returns (bytes4 _selector) {
    ++batches;
    _record(_operator, _data);
    if (NEXT != address(0)) IERC1155(msg.sender).safeBatchTransferFrom(address(this), NEXT, _ids, _values, '');
    _selector = IERC1155Receiver.onERC1155BatchReceived.selector;
  }

  function supportsInterface(
    bytes4 _interfaceId
  ) external pure returns (bool _supported) {
    _supported = _interfaceId == type(IERC1155Receiver).interfaceId || _interfaceId == type(IERC165).interfaceId;
  }

  function _record(
    address _operator,
    bytes calldata _data
  ) internal {
    lastOperator = _operator;
    lastData = _data;
    if (address(POLICY) != address(0)) afterCountSeen = POLICY.afterCount();
  }
}

contract Gated1155UnitTest is Helpers {
  Gated1155 internal _token;
  address internal _registry;
  address internal _hook;

  address internal _admin = makeAddr('timelock');
  address internal _guardian = makeAddr('guardian');
  address internal _recovery = makeAddr('recoveryTimelock');
  address internal _minter = makeAddr('minter');
  address internal _burner = makeAddr('burner');
  address internal _agent = makeAddr('agent');
  address internal _upgrader = makeAddr('upgrader');
  address internal _stranger = makeAddr('stranger');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');
  address internal _carol = makeAddr('carol');

  uint256 internal constant _ID = 1;
  uint256 internal constant _OTHER = 2;

  IERC8473Policy.TransferKind internal constant _TRANSFER = IERC8473Policy.TransferKind.TRANSFER;
  IERC8473Policy.TransferKind internal constant _MINT = IERC8473Policy.TransferKind.MINT;
  IERC8473Policy.TransferKind internal constant _FORCED = IERC8473Policy.TransferKind.FORCED;

  /// @dev Alice starts with 100 of `_ID` and 50 of `_OTHER`
  function setUp() public virtual {
    _registry = _mockContract('registry');
    _hook = _mockContract('hook');
    _attested(_hook, IPolicyRegistry.AttestKind.HOOK, true);
    vm.mockCall(_hook, abi.encodeCall(IComplianceHook.REGISTRY, ()), abi.encode(_registry));
    _mockPolicy(_hook);
    _hookAccountChecksDecide(Reasons.TRANSFER_OK, Reasons.TRANSFER_OK);
    _hookDecides(Reasons.TRANSFER_OK);
    vm.mockCall(_hook, abi.encodeCall(IERC8473Policy.wantsAfterTransfer, ()), abi.encode(false));

    _token = _deploy(_hook);

    vm.startPrank(_admin);
    _token.grantRole(_token.MINTER_ROLE(), _minter);
    _token.grantRole(_token.BURNER_ROLE(), _burner);
    _token.grantRole(_token.AGENT_ROLE(), _agent);
    _token.grantRole(_token.UPGRADER_ROLE(), _upgrader);
    _token.grantRole(_token.RECOVERY_ROLE(), _recovery);
    vm.stopPrank();

    vm.startPrank(_minter);
    _token.mint(_alice, _ID, 100);
    _token.mint(_alice, _OTHER, 50);
    vm.stopPrank();
  }

  function _deploy(
    address _initialHook
  ) internal returns (Gated1155 _proxy) {
    Gated1155 _impl = new Gated1155();
    _proxy = Gated1155(
      address(
        new ERC1967Proxy(
          address(_impl),
          abi.encodeCall(
            Gated1155.initialize,
            ('Gated Series', 'gSER', _admin, _guardian, _registry, _initialHook, new IComplianceRule[](0))
          )
        )
      )
    );
  }

  /// @dev Replaces the mocked hook with a recording policy, which wants `afterTransfer`
  function _installRecordingPolicy() internal returns (MockRecordingPolicy _policy) {
    _policy = new MockRecordingPolicy(_registry);
    _attested(address(_policy), IPolicyRegistry.AttestKind.HOOK, true);
    vm.prank(_admin);
    _token.installPolicy(address(_policy), '');
  }

  function _attested(
    address _target,
    IPolicyRegistry.AttestKind _kind,
    bool _isAttested
  ) internal {
    vm.mockCall(_registry, abi.encodeCall(IPolicyRegistry.isAttested, (_target, _kind)), abi.encode(_isAttested));
  }

  function _hookAccountChecksDecide(
    bytes32 _sendReason,
    bytes32 _receiveReason
  ) internal {
    vm.mockCall(_hook, abi.encodeWithSelector(IERC8473Policy.checkSend.selector), abi.encode(_sendReason));
    vm.mockCall(_hook, abi.encodeWithSelector(IERC8473Policy.checkReceive.selector), abi.encode(_receiveReason));
  }

  function _hookDecides(
    bytes32 _reason
  ) internal {
    vm.mockCall(_hook, abi.encodeWithSelector(IERC8473Policy.checkTransfer.selector), abi.encode(_reason));
  }

  /// @dev The context the token builds: the id, the amount and that id's two balances before the move
  function _ctx(
    address _from,
    address _to,
    uint256 _tokenId,
    uint256 _amount,
    address _operator,
    IERC8473Policy.TransferKind _kind
  ) internal view returns (IERC8473Policy.TransferContext memory _context) {
    _context = _ctxWith(
      _from,
      _to,
      _tokenId,
      _amount,
      _operator,
      _kind,
      _token.balanceOf(_from, _tokenId),
      _token.balanceOf(_to, _tokenId)
    );
  }

  /// @dev A context with the balances stated, for a movement that follows another in the same call
  function _ctxWith(
    address _from,
    address _to,
    uint256 _tokenId,
    uint256 _amount,
    address _operator,
    IERC8473Policy.TransferKind _kind,
    uint256 _fromBalance,
    uint256 _toBalance
  ) internal view returns (IERC8473Policy.TransferContext memory _context) {
    _context = IERC8473Policy.TransferContext({
      token: address(_token),
      from: _from,
      to: _to,
      tokenId: _tokenId,
      amount: _amount,
      operator: _operator,
      kind: _kind,
      data: abi.encode(_fromBalance, _toBalance)
    });
  }

  function _expectAsked(
    IERC8473Policy.TransferContext memory _context
  ) internal {
    vm.expectCall(_token.policy(), abi.encodeCall(IERC8473Policy.checkTransfer, (_context)));
  }

  function _expectNotAsked() internal {
    vm.expectCall(_token.policy(), abi.encodeWithSelector(IERC8473Policy.checkTransfer.selector), 0);
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
    _revertData = abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, _reason);
  }

  function _frozenError(
    address _account,
    uint256 _tokenId,
    uint256 _amount,
    uint256 _unfrozen
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(
      IERC7943MultiToken.ERC7943InsufficientUnfrozenBalance.selector, _account, _tokenId, _amount, _unfrozen
    );
  }

  function _balanceError(
    address _account,
    uint256 _balance,
    uint256 _needed,
    uint256 _tokenId
  ) internal pure returns (bytes memory _revertData) {
    _revertData =
      abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, _account, _balance, _needed, _tokenId);
  }

  function _notAReceiver(
    address _account
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, _account);
  }

  function _freeze(
    address _account,
    uint256 _tokenId,
    uint256 _amount
  ) internal {
    vm.prank(_agent);
    _token.setFrozenTokens(_account, _tokenId, _amount);
  }

  function _pause() internal {
    vm.prank(_guardian);
    _token.pause();
  }

  function _pair(
    uint256 _first,
    uint256 _second
  ) internal pure returns (uint256[] memory _array) {
    _array = new uint256[](2);
    _array[0] = _first;
    _array[1] = _second;
  }

  /// @dev How many of the recorded logs the token emitted with this topic
  function _count(
    Vm.Log[] memory _logs,
    bytes32 _topic
  ) internal view returns (uint256 _found) {
    for (uint256 _i = 0; _i < _logs.length; ++_i) {
      if (_logs[_i].emitter == address(_token) && _logs[_i].topics[0] == _topic) ++_found;
    }
  }
}

contract Gated1155Unit_Initialize is Gated1155UnitTest {
  function test_WhenInitialized_ItHoldsItsNameRolesHookAndRegistry() external view {
    assertEq(_token.name(), 'Gated Series');
    assertEq(_token.symbol(), 'gSER');
    assertTrue(_token.hasRole(_token.DEFAULT_ADMIN_ROLE(), _admin));
    assertTrue(_token.hasRole(_token.GUARDIAN_ROLE(), _guardian));
    assertEq(_token.policy(), _hook);
    assertEq(_token.registry(), _registry);
    assertEq(_token.templateId(), keccak256('Gated1155'));
  }

  /// @dev The frozen amounts live at the ERC-7201 location the constant names: the formula equals it, and an amount
  ///      frozen through the token is the word the mapping, the struct's third member, puts there
  function test_TheErc7201LocationHoldsTheFrozenAmounts() external {
    bytes32 _location =
      keccak256(abi.encode(uint256(keccak256('gated.storage.Gated1155')) - 1)) & ~bytes32(uint256(0xff));
    assertEq(_location, 0x99a6bb33e7f2ba3c982ab9d869b98714e59c3a13fe4325b59d537b88a1ff8800);
    _freeze(_alice, _ID, 7);
    bytes32 _slot = keccak256(abi.encode(_ID, keccak256(abi.encode(_alice, uint256(_location) + 2))));
    assertEq(uint256(vm.load(address(_token), _slot)), 7);
  }

  /// @dev No receive or payable function, so ether sent to the token is refused
  function test_WhenEtherIsSent_ItReverts() external {
    vm.deal(address(this), 1 ether);
    (bool _ok,) = address(_token).call{value: 1 ether}('');
    assertFalse(_ok);
    assertEq(address(_token).balance, 0);
  }

  function test_WhenTheImplementationIsInitializedDirectly_ItReverts() external {
    Gated1155 _impl = new Gated1155();
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    _impl.initialize('X', 'X', _admin, _guardian, _registry, _hook, new IComplianceRule[](0));
  }

  function test_WhenTheAdminIsZero_ItReverts() external {
    Gated1155 _impl = new Gated1155();
    vm.expectRevert(IPolicyGatedCore.PolicyGated_ZeroAddress.selector);
    new ERC1967Proxy(
      address(_impl),
      abi.encodeCall(
        Gated1155.initialize, ('X', 'X', address(0), _guardian, _registry, _hook, new IComplianceRule[](0))
      )
    );
  }

  function test_WhenTheHookIsNotAttested_ItReverts() external {
    address _other = _mockContract('otherHook');
    _attested(_other, IPolicyRegistry.AttestKind.HOOK, false);
    Gated1155 _impl = new Gated1155();
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_NotAttested.selector, _other, IPolicyRegistry.AttestKind.HOOK)
    );
    new ERC1967Proxy(
      address(_impl),
      abi.encodeCall(Gated1155.initialize, ('X', 'X', _admin, _guardian, _registry, _other, new IComplianceRule[](0)))
    );
  }
}

contract Gated1155Unit_Mint is Gated1155UnitTest {
  function test_WhenTheMinterMints_TheHookSeesAMintOfTheIdAndTheSupplyRises() external {
    _expectAsked(_ctx(address(0), _bob, _ID, 40, _minter, _MINT));
    vm.expectEmit(address(_token));
    emit IERC1155.TransferSingle(_minter, address(0), _bob, _ID, 40);
    vm.prank(_minter);
    _token.mint(_bob, _ID, 40);
    assertEq(_token.balanceOf(_bob, _ID), 40);
    assertEq(_token.totalSupply(_ID), 140);
    assertEq(_token.totalSupply(_OTHER), 50);
    assertEq(_token.totalSupply(), 190);
  }

  function test_WhenTheCallerIsNotTheMinter_ItReverts() external {
    vm.expectRevert(_unauthorized(_alice, _token.MINTER_ROLE()));
    vm.prank(_alice);
    _token.mint(_alice, _ID, 1);
  }

  function test_WhenTheReceiverIsZero_ItReverts() external {
    vm.expectRevert(_notAReceiver(address(0)));
    vm.prank(_minter);
    _token.mint(address(0), _ID, 1);
  }

  function test_WhenTheHookRejects_NothingIsMinted() external {
    _hookDecides(Reasons.RECEIVER_NOT_VERIFIED);
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_minter);
    _token.mint(_bob, _ID, 40);
    assertEq(_token.balanceOf(_bob, _ID), 0);
    assertEq(_token.totalSupply(_ID), 100);
  }

  function test_WhenTheSupplyIsReadDuringAfterTransfer_ItAlreadyCountsTheMint() external {
    MockRecordingPolicy _policy = _installRecordingPolicy();
    vm.prank(_minter);
    _token.mint(_bob, _ID, 40);
    assertEq(_policy.supplySeen(0), 140);
  }
}

contract Gated1155Unit_Transfer is Gated1155UnitTest {
  function test_WhenTheHolderTransfers_TheHookSeesATransferWithTheIdsBalances() external {
    vm.prank(_minter);
    _token.mint(_bob, _ID, 5);
    _expectAsked(_ctxWith(_alice, _bob, _ID, 30, _alice, _TRANSFER, 100, 5));
    vm.expectEmit(address(_token));
    emit IERC1155.TransferSingle(_alice, _alice, _bob, _ID, 30);
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _bob, _ID, 30, '');
    assertEq(_token.balanceOf(_alice, _ID), 70);
    assertEq(_token.balanceOf(_bob, _ID), 35);
    assertEq(_token.balanceOf(_alice, _OTHER), 50);
  }

  function test_WhenAnApprovedOperatorTransfers_TheOperatorIsInTheContext() external {
    vm.prank(_alice);
    _token.setApprovalForAll(_carol, true);
    _expectAsked(_ctx(_alice, _bob, _ID, 30, _carol, _TRANSFER));
    vm.prank(_carol);
    _token.safeTransferFrom(_alice, _bob, _ID, 30, '');
    assertEq(_token.balanceOf(_bob, _ID), 30);
  }

  function test_WhenTheCallerIsNotApproved_Erc1155RevertsBeforeTheHookIsAsked() external {
    _expectNotAsked();
    vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, _stranger, _alice));
    vm.prank(_stranger);
    _token.safeTransferFrom(_alice, _bob, _ID, 30, '');
  }

  function test_WhenTheAmountIsAboveTheBalance_ItRevertsWithErc1155sErrorWithoutAskingTheHook() external {
    _expectNotAsked();
    vm.expectRevert(_balanceError(_alice, 100, 101, _ID));
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _bob, _ID, 101, '');
  }

  function test_WhenTheHookRejects_NothingMoves() external {
    _hookDecides(Reasons.LOCKED_UP);
    vm.expectRevert(_rejected(Reasons.LOCKED_UP));
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _bob, _ID, 30, '');
    assertEq(_token.balanceOf(_alice, _ID), 100);
  }

  function test_WhenThePolicyCannotBeAsked_TheTransferRevertsAndThePreflightReadsFalse() external {
    vm.mockCallRevert(_hook, abi.encodeWithSelector(IERC8473Policy.checkTransfer.selector), 'down');
    assertFalse(_token.canTransfer(_alice, _bob, _ID, 30));
    vm.expectRevert(_rejected(Reasons.CHECK_UNAVAILABLE));
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _bob, _ID, 30, '');
  }

  function test_WhenTheHookWantsAfter_ItIsCalledWithTheSameContext() external {
    vm.mockCall(_hook, abi.encodeCall(IERC8473Policy.wantsAfterTransfer, ()), abi.encode(true));
    IERC8473Policy.TransferContext memory _context = _ctx(_alice, _bob, _ID, 30, _alice, _TRANSFER);
    _mockAndExpect(_hook, abi.encodeCall(IERC8473Policy.afterTransfer, (_context)), '');
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _bob, _ID, 30, '');
  }

  function test_WhenTheAmountIsZeroOrTheReceiverIsTheSender_ThePolicyIsStillAsked() external {
    _expectAsked(_ctx(_alice, _bob, _ID, 0, _alice, _TRANSFER));
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _bob, _ID, 0, '');

    _expectAsked(_ctx(_alice, _alice, _ID, 10, _alice, _TRANSFER));
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _alice, _ID, 10, '');
    assertEq(_token.balanceOf(_alice, _ID), 100);
  }

  /// @dev ERC-1155's `data` is the receiver's: it reaches the callback unaltered and never the policy, whose context
  ///      holds the two balances and nothing else
  function test_WhenTheTransferCarriesData_ItReachesTheReceiverAndNotThePolicy() external {
    MockReceiver _receiver = new MockReceiver(MockRecordingPolicy(address(0)), address(0));
    _expectAsked(_ctx(_alice, address(_receiver), _ID, 30, _alice, _TRANSFER));
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, address(_receiver), _ID, 30, 'order 42');
    assertEq(_receiver.lastData(), 'order 42');
    assertEq(_receiver.lastOperator(), _alice);
  }
}

contract Gated1155Unit_Batch is Gated1155UnitTest {
  MockRecordingPolicy internal _policy;

  function setUp() public override {
    super.setUp();
    _policy = _installRecordingPolicy();
  }

  function _batch(
    address _to,
    uint256[] memory _ids,
    uint256[] memory _values
  ) internal {
    vm.prank(_alice);
    _token.safeBatchTransferFrom(_alice, _to, _ids, _values, '');
  }

  function test_WhenABatchMoves_ThePolicyIsAskedAboutEachItemInOrder() external {
    _expectAsked(_ctxWith(_alice, _bob, _ID, 30, _alice, _TRANSFER, 100, 0));
    _expectAsked(_ctxWith(_alice, _bob, _OTHER, 20, _alice, _TRANSFER, 50, 0));
    _batch(_bob, _pair(_ID, _OTHER), _pair(30, 20));
    assertEq(_token.balanceOf(_bob, _ID), 30);
    assertEq(_token.balanceOf(_bob, _OTHER), 20);
    assertEq(_policy.idsSeen(0), _ID);
    assertEq(_policy.idsSeen(1), _OTHER);
  }

  function test_WhenABatchMoves_EachItemEmitsItsOwnTransferSingleAndNoTransferBatch() external {
    vm.recordLogs();
    vm.expectEmit(address(_token));
    emit IERC1155.TransferSingle(_alice, _alice, _bob, _ID, 30);
    vm.expectEmit(address(_token));
    emit IERC1155.TransferSingle(_alice, _alice, _bob, _OTHER, 20);
    _batch(_bob, _pair(_ID, _OTHER), _pair(30, 20));
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    assertEq(_count(_logs, IERC1155.TransferSingle.selector), 2);
    assertEq(_count(_logs, IERC1155.TransferBatch.selector), 0);
  }

  /// @dev ERC-8473, token rule 10: the first item's `afterTransfer` runs before the second item moves
  function test_WhenABatchMoves_AfterTransferFollowsEachItemBeforeTheNextMoves() external {
    _policy.setProbe(_OTHER);
    _batch(_bob, _pair(_ID, _OTHER), _pair(30, 20));
    assertEq(_policy.afterCount(), 2);
    assertEq(_policy.probeSeen(0), 0);
    assertEq(_policy.probeSeen(1), 20);
  }

  function test_WhenAnIdIsNamedTwice_TheSecondItemSeesTheBalancesTheFirstLeft() external {
    _expectAsked(_ctxWith(_alice, _bob, _ID, 30, _alice, _TRANSFER, 100, 0));
    _expectAsked(_ctxWith(_alice, _bob, _ID, 10, _alice, _TRANSFER, 70, 30));
    _batch(_bob, _pair(_ID, _ID), _pair(30, 10));
    assertEq(_token.balanceOf(_bob, _ID), 40);
  }

  function test_WhenAnIdNamedTwiceExceedsTheBalance_TheSecondItemRevertsTheBatch() external {
    vm.expectRevert(_balanceError(_alice, 40, 60, _ID));
    _batch(_bob, _pair(_ID, _ID), _pair(60, 60));
    assertEq(_token.balanceOf(_alice, _ID), 100);
  }

  function test_WhenThePolicyRejectsALaterItem_TheEarlierItemsAreUndone() external {
    vm.prank(_minter);
    _token.mint(_alice, 3, 10);
    _policy.setRejection(3, address(0), Reasons.RECEIVER_NOT_ELIGIBLE);
    uint256[] memory _ids = new uint256[](3);
    uint256[] memory _values = new uint256[](3);
    (_ids[0], _ids[1], _ids[2]) = (_ID, _OTHER, 3);
    (_values[0], _values[1], _values[2]) = (30, 20, 5);
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_ELIGIBLE));
    _batch(_bob, _ids, _values);
    assertEq(_token.balanceOf(_bob, _ID), 0);
    assertEq(_token.balanceOf(_bob, _OTHER), 0);
    assertEq(_policy.afterCount(), 1); // the mint above
  }

  function test_WhenALaterItemIsAboveItsUnfrozenBalance_TheBatchReverts() external {
    _freeze(_alice, _OTHER, 40);
    vm.expectRevert(_frozenError(_alice, _OTHER, 20, 10));
    _batch(_bob, _pair(_ID, _OTHER), _pair(30, 20));
    assertEq(_token.balanceOf(_bob, _ID), 0);
  }

  function test_WhenTheBatchIsEmpty_NobodyIsAskedAndNothingIsEmitted() external {
    _expectNotAsked();
    vm.recordLogs();
    _batch(_bob, new uint256[](0), new uint256[](0));
    assertEq(vm.getRecordedLogs().length, 0);
    assertEq(_policy.afterCount(), 0);
  }

  function test_WhenTheArraysDiffer_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidArrayLength.selector, 2, 1));
    _batch(_bob, _pair(_ID, _OTHER), new uint256[](1));
  }

  function test_WhenPaused_TheBatchIsRejected() external {
    _pause();
    vm.expectRevert(_rejected(Reasons.PAUSED));
    _batch(_bob, _pair(_ID, _OTHER), _pair(30, 20));
  }
}

contract Gated1155Unit_Callbacks is Gated1155UnitTest {
  MockRecordingPolicy internal _policy;
  MockReceiver internal _receiver;
  address internal _notAReceiverContract;

  function setUp() public override {
    super.setUp();
    _policy = _installRecordingPolicy();
    _receiver = new MockReceiver(_policy, address(0));
    _notAReceiverContract = _mockContract('notAReceiver');
  }

  function test_WhenAMintGoesToAContract_ItIsCalledAfterAfterTransfer() external {
    vm.prank(_minter);
    _token.mint(address(_receiver), _ID, 40);
    assertEq(_receiver.singles(), 1);
    assertEq(_receiver.afterCountSeen(), 1);
    assertEq(_receiver.lastOperator(), _minter);
  }

  function test_WhenATransferGoesToAContract_ItIsCalledAfterAfterTransfer() external {
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, address(_receiver), _ID, 30, '');
    assertEq(_receiver.singles(), 1);
    assertEq(_receiver.afterCountSeen(), 1);
  }

  function test_WhenAForcedTransferGoesToAContract_ItIsCalledAfterAfterTransfer() external {
    vm.prank(_agent);
    _token.forcedTransfer(_alice, address(_receiver), _ID, 30);
    assertEq(_receiver.singles(), 1);
    assertEq(_receiver.afterCountSeen(), 1);
    assertEq(_receiver.lastOperator(), _agent);
    assertEq(_token.balanceOf(address(_receiver), _ID), 30);
  }

  function test_WhenABatchGoesToAContract_ItGetsOneBatchCallbackAfterTheLastItem() external {
    vm.prank(_alice);
    _token.safeBatchTransferFrom(_alice, address(_receiver), _pair(_ID, _OTHER), _pair(30, 20), 'lot 7');
    assertEq(_receiver.batches(), 1);
    assertEq(_receiver.singles(), 0);
    assertEq(_receiver.afterCountSeen(), 2);
    assertEq(_receiver.lastData(), 'lot 7');
  }

  function test_WhenABatchOfOneGoesToAContract_ItGetsTheBatchCallback() external {
    uint256[] memory _ids = new uint256[](1);
    uint256[] memory _values = new uint256[](1);
    (_ids[0], _values[0]) = (_ID, 30);
    vm.prank(_alice);
    _token.safeBatchTransferFrom(_alice, address(_receiver), _ids, _values, 'lot 8');
    assertEq(_receiver.batches(), 1);
    assertEq(_receiver.singles(), 0);
    assertEq(_receiver.afterCountSeen(), 1);
    assertEq(_receiver.lastData(), 'lot 8');
  }

  /// @dev Nothing moved and no policy was asked, so the token calls nobody: a stranger cannot make it call a contract
  function test_WhenAnEmptyBatchGoesToAContract_NoCallbackIsMade() external {
    address _stranger = makeAddr('stranger');
    vm.expectCall(address(_receiver), abi.encodeWithSelector(IERC1155Receiver.onERC1155BatchReceived.selector), 0);
    vm.prank(_stranger);
    _token.safeBatchTransferFrom(_stranger, address(_receiver), new uint256[](0), new uint256[](0), 'anything');
    assertEq(_receiver.batches(), 0);
    assertEq(_receiver.singles(), 0);
  }

  function test_WhenPaused_AnEmptyBatchCallsNobody() external {
    _pause();
    address _stranger = makeAddr('stranger');
    vm.expectCall(address(_receiver), abi.encodeWithSelector(IERC1155Receiver.onERC1155BatchReceived.selector), 0);
    vm.prank(_stranger);
    _token.safeBatchTransferFrom(_stranger, address(_receiver), new uint256[](0), new uint256[](0), 'anything');
    assertEq(_receiver.batches(), 0);
  }

  function test_WhenTheReceivingContractHasNoReceiverInterface_EveryPathRefusesIt() external {
    vm.expectRevert(_notAReceiver(_notAReceiverContract));
    vm.prank(_minter);
    _token.mint(_notAReceiverContract, _ID, 40);

    vm.expectRevert(_notAReceiver(_notAReceiverContract));
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _notAReceiverContract, _ID, 30, '');

    vm.expectRevert(_notAReceiver(_notAReceiverContract));
    vm.prank(_alice);
    _token.safeBatchTransferFrom(_alice, _notAReceiverContract, _pair(_ID, _OTHER), _pair(30, 20), '');

    vm.expectRevert(_notAReceiver(_notAReceiverContract));
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _notAReceiverContract, _ID, 30);

    assertEq(_token.balanceOf(_notAReceiverContract, _ID), 0);
  }

  function test_WhenTokensAreBurned_NoCallbackIsMade() external {
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, address(_receiver), _ID, 30, '');
    vm.prank(_burner);
    _token.burn(address(_receiver), _ID, 30);
    assertEq(_receiver.singles(), 1);
    assertEq(_receiver.batches(), 0);
  }
}

contract Gated1155Unit_Reentrancy is Gated1155UnitTest {
  MockRecordingPolicy internal _policy;

  function setUp() public override {
    super.setUp();
    _policy = _installRecordingPolicy();
  }

  /// @dev The first item's `afterTransfer` calls back into the token while the batch is still running
  function test_WhenThePolicyCallsBackInTheMiddleOfABatch_TheGuardRefusesIt() external {
    _policy.setReenterAt(1);
    vm.prank(_bob);
    _token.setApprovalForAll(address(_policy), true);
    vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    vm.prank(_alice);
    _token.safeBatchTransferFrom(_alice, _bob, _pair(_ID, _OTHER), _pair(30, 20), '');
  }

  /// @dev The callback runs outside the guard with the state final, so the onward move is a movement of its own
  function test_WhenTheReceiverForwardsFromItsCallback_ThePolicyJudgesThatMoveToo() external {
    MockReceiver _forwarder = new MockReceiver(_policy, _carol);
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, address(_forwarder), _ID, 30, '');
    assertEq(_token.balanceOf(_carol, _ID), 30);
    assertEq(_policy.afterCount(), 2);

    // The onward move is refused on its own: the whole transfer reverts.
    _policy.setRejection(0, address(_forwarder), Reasons.RECEIVER_FROZEN);
    vm.expectRevert(_rejected(Reasons.RECEIVER_FROZEN));
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, address(_forwarder), _OTHER, 20, '');
    assertEq(_token.balanceOf(_alice, _OTHER), 50);
  }

  function test_WhenTheReceiverForwardsABatchFromItsCallback_EachItemIsJudgedAgain() external {
    MockReceiver _forwarder = new MockReceiver(_policy, _carol);
    vm.prank(_alice);
    _token.safeBatchTransferFrom(_alice, address(_forwarder), _pair(_ID, _OTHER), _pair(30, 20), '');
    assertEq(_token.balanceOf(_carol, _ID), 30);
    assertEq(_token.balanceOf(_carol, _OTHER), 20);
    assertEq(_policy.afterCount(), 4);
  }

  function test_WhenAMintedReceiverForwardsFromItsCallback_ThePolicyJudgesThatMoveToo() external {
    MockReceiver _forwarder = new MockReceiver(_policy, _carol);
    vm.prank(_minter);
    _token.mint(address(_forwarder), _ID, 40);
    assertEq(_token.balanceOf(_carol, _ID), 40);
    assertEq(_policy.afterCount(), 2);
  }
}

contract Gated1155Unit_Burn is Gated1155UnitTest {
  /// @dev ERC-8473: a burn the holder does not direct is FORCED, with the zero address as the receiver
  function test_WhenTheBurnerBurns_ThePolicySeesAForcedMovementToZeroAndTheSupplyFalls() external {
    _expectAsked(_ctx(_alice, address(0), _ID, 40, _burner, _FORCED));
    vm.expectEmit(address(_token));
    emit IERC1155.TransferSingle(_burner, _alice, address(0), _ID, 40);
    vm.prank(_burner);
    _token.burn(_alice, _ID, 40);
    assertEq(_token.balanceOf(_alice, _ID), 60);
    assertEq(_token.totalSupply(_ID), 60);
  }

  function test_WhenTheCallerIsNotTheBurner_ItReverts() external {
    vm.expectRevert(_unauthorized(_alice, _token.BURNER_ROLE()));
    vm.prank(_alice);
    _token.burn(_alice, _ID, 1);
  }

  function test_WhenTheHolderIsZero_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidSender.selector, address(0)));
    vm.prank(_burner);
    _token.burn(address(0), _ID, 1);
  }

  function test_WhenTheAmountIsAboveTheBalance_ItRevertsWithoutAskingTheHook() external {
    _freeze(_alice, _ID, 100);
    _expectNotAsked();
    vm.expectRevert(_balanceError(_alice, 100, 101, _ID));
    vm.prank(_burner);
    _token.burn(_alice, _ID, 101);
    assertEq(_token.getFrozenTokens(_alice, _ID), 100);
  }

  function test_WhenTheBurnTakesFrozenTokens_TheFrozenAmountFallsByThePartTakenBeforeTheTransferEvent() external {
    _freeze(_alice, _ID, 80);
    vm.expectEmit(address(_token));
    emit IERC7943MultiToken.Frozen(_alice, _ID, 50);
    vm.expectEmit(address(_token));
    emit IERC1155.TransferSingle(_burner, _alice, address(0), _ID, 50);
    vm.prank(_burner);
    _token.burn(_alice, _ID, 50);
    assertEq(_token.getFrozenTokens(_alice, _ID), 50);
    assertEq(_token.getFrozenTokens(_alice, _OTHER), 0);
  }

  function test_WhenTheFrozenAmountExceedsTheBalance_ItLosesExactlyWhatLeaves() external {
    _freeze(_alice, _ID, 150);
    vm.prank(_burner);
    _token.burn(_alice, _ID, 10);
    assertEq(_token.getFrozenTokens(_alice, _ID), 140);
  }

  function test_WhenTheBurnStaysWithinTheUnfrozenBalance_TheFrozenAmountStays() external {
    _freeze(_alice, _ID, 80);
    vm.recordLogs();
    vm.prank(_burner);
    _token.burn(_alice, _ID, 20);
    assertEq(_count(vm.getRecordedLogs(), IERC7943MultiToken.Frozen.selector), 0);
    assertEq(_token.getFrozenTokens(_alice, _ID), 80);
  }

  function test_WhenTheHookRejects_TheBalanceAndTheFrozenAmountStay() external {
    _freeze(_alice, _ID, 80);
    _hookDecides(Reasons.SENDER_FROZEN);
    vm.expectRevert(_rejected(Reasons.SENDER_FROZEN));
    vm.prank(_burner);
    _token.burn(_alice, _ID, 50);
    assertEq(_token.balanceOf(_alice, _ID), 100);
    assertEq(_token.getFrozenTokens(_alice, _ID), 80);
  }
}

contract Gated1155Unit_ForcedTransfer is Gated1155UnitTest {
  function test_WhenTheAgentForces_TheHookSeesAForcedMoveAndBothEventsCarryTheIdAndTheAmount() external {
    _expectAsked(_ctx(_alice, _bob, _ID, 40, _agent, _FORCED));
    vm.expectEmit(address(_token));
    emit IERC1155.TransferSingle(_agent, _alice, _bob, _ID, 40);
    vm.expectEmit(address(_token));
    emit IERC7943MultiToken.ForcedTransfer(_alice, _bob, _ID, 40);
    vm.expectEmit(address(_token));
    emit IGated1155.ForcedTransferBy(_alice, _bob, _ID, 40, _agent);
    vm.prank(_agent);
    assertTrue(_token.forcedTransfer(_alice, _bob, _ID, 40));
    assertEq(_token.balanceOf(_bob, _ID), 40);
  }

  function test_WhenItTakesFrozenTokens_TheyAreUnfrozenFirstWithFrozenBeforeTransfer() external {
    _freeze(_alice, _ID, 80);
    vm.expectEmit(address(_token));
    emit IERC7943MultiToken.Frozen(_alice, _ID, 50);
    vm.expectEmit(address(_token));
    emit IERC1155.TransferSingle(_agent, _alice, _bob, _ID, 50);
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, _ID, 50);
    assertEq(_token.getFrozenTokens(_alice, _ID), 50);
  }

  function test_WhenPaused_ItStillWorks() external {
    _pause();
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, _ID, 40);
    assertEq(_token.balanceOf(_bob, _ID), 40);
  }

  function test_WhenTheHookRejectsTheReceiver_ItRevertsAndTheFrozenAmountStays() external {
    _freeze(_alice, _ID, 80);
    _hookDecides(Reasons.RECEIVER_NOT_VERIFIED);
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, _ID, 50);
    assertEq(_token.getFrozenTokens(_alice, _ID), 80);
  }

  function test_WhenTheAmountIsAboveTheBalance_ItReverts() external {
    vm.expectRevert(_balanceError(_alice, 100, 101, _ID));
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, _ID, 101);
  }

  function test_WhenAPartyIsZero_ItReverts() external {
    vm.expectRevert(_notAReceiver(address(0)));
    vm.prank(_agent);
    _token.forcedTransfer(_alice, address(0), _ID, 1);

    vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidSender.selector, address(0)));
    vm.prank(_agent);
    _token.forcedTransfer(address(0), _bob, _ID, 1);
  }

  function test_WhenTheCallerIsNotTheAgent_ItReverts() external {
    vm.expectRevert(_unauthorized(_alice, _token.AGENT_ROLE()));
    vm.prank(_alice);
    _token.forcedTransfer(_alice, _bob, _ID, 1);
  }
}

contract Gated1155Unit_Freeze is Gated1155UnitTest {
  function test_WhenTheAgentFreezes_ItEmitsFrozenAndOverwrites() external {
    vm.expectEmit(address(_token));
    emit IERC7943MultiToken.Frozen(_alice, _ID, 60);
    vm.prank(_agent);
    assertTrue(_token.setFrozenTokens(_alice, _ID, 60));
    _freeze(_alice, _ID, 25);
    assertEq(_token.getFrozenTokens(_alice, _ID), 25);
  }

  function test_WhenTheAmountExceedsTheBalance_ItIsStillRecorded() external {
    _freeze(_bob, _ID, 500);
    assertEq(_token.getFrozenTokens(_bob, _ID), 500);
  }

  function test_WhenTheCallerIsNotTheAgent_ItReverts() external {
    vm.expectRevert(_unauthorized(_alice, _token.AGENT_ROLE()));
    vm.prank(_alice);
    _token.setFrozenTokens(_alice, _ID, 0);
  }

  function test_WhenPartIsFrozen_TheHolderAndItsOperatorMoveExactlyTheUnfrozenPart() external {
    _freeze(_alice, _ID, 60);
    vm.expectRevert(_frozenError(_alice, _ID, 41, 40));
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _bob, _ID, 41, '');

    vm.prank(_alice);
    _token.setApprovalForAll(_carol, true);
    vm.expectRevert(_frozenError(_alice, _ID, 41, 40));
    vm.prank(_carol);
    _token.safeTransferFrom(_alice, _bob, _ID, 41, '');

    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _bob, _ID, 40, '');
    assertEq(_token.balanceOf(_bob, _ID), 40);
  }

  function test_WhenTheFrozenAmountExceedsTheBalance_NothingMovesAndAnAmountAboveTheBalanceIsErc1155s() external {
    _freeze(_alice, _ID, 150);
    vm.expectRevert(_frozenError(_alice, _ID, 1, 0));
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _bob, _ID, 1, '');

    vm.expectRevert(_balanceError(_alice, 100, 101, _ID));
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _bob, _ID, 101, '');
  }

  function test_WhenOneIdIsFrozen_AnotherIdIsFree() external {
    _freeze(_alice, _ID, 100);
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _bob, _OTHER, 50, '');
    assertEq(_token.balanceOf(_bob, _OTHER), 50);
  }

  function test_WhenTheHookBorrowsTheFrozenCodeWithNoShortfall_ItIsAPolicyRejection() external {
    _hookDecides(Reasons.INSUFFICIENT_UNFROZEN);
    vm.expectRevert(_rejected(Reasons.INSUFFICIENT_UNFROZEN));
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _bob, _ID, 30, '');
  }
}

contract Gated1155Unit_Pause is Gated1155UnitTest {
  function test_WhenPaused_TransfersAndMintsAreRejectedAndTheEnforcementBurnPasses() external {
    _pause();
    vm.expectRevert(_rejected(Reasons.PAUSED));
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, _bob, _ID, 30, '');

    vm.expectRevert(_rejected(Reasons.PAUSED));
    vm.prank(_minter);
    _token.mint(_bob, _ID, 1);

    assertFalse(_token.canTransfer(_alice, _bob, _ID, 30));
    assertFalse(_token.canSend(_alice));

    vm.prank(_burner);
    _token.burn(_alice, _ID, 100);
    assertEq(_token.balanceOf(_alice, _ID), 0);
  }

  function test_WhenTheCallerIsNotTheGuardian_ItCannotPause() external {
    vm.expectRevert(_unauthorized(_admin, _token.GUARDIAN_ROLE()));
    vm.prank(_admin);
    _token.pause();
  }

  function test_WhenPaused_TheGuardianCannotUnpauseAndTheTimelockOrRecoveryCan() external {
    _pause();
    vm.expectRevert(_unauthorized(_guardian, _token.DEFAULT_ADMIN_ROLE()));
    vm.prank(_guardian);
    _token.unpause();

    vm.prank(_recovery);
    _token.unpause();
    _pause();
    vm.prank(_admin);
    _token.unpause();
    assertFalse(_token.paused());
  }
}

contract Gated1155Unit_Preflight is Gated1155UnitTest {
  /// @dev ERC-7943: `canTransfer` must not be false for a balance, so only the reasoned pre-flight counts it
  function test_WhenTheAmountIsAboveTheBalanceAndNothingIsFrozen_OnlyTheReasonedPreflightSaysSo() external view {
    assertTrue(_token.canTransfer(_alice, _bob, _ID, 101));
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(_alice, _bob, _ID, 101);
    assertFalse(_ok);
    assertEq(_reason, Reasons.INSUFFICIENT_UNFROZEN);
  }

  function test_WhenPartOfTheIdIsFrozen_AnAmountAboveTheUnfrozenBalanceReadsFalse() external {
    _freeze(_alice, _ID, 60);
    assertTrue(_token.canTransfer(_alice, _bob, _ID, 40));
    assertFalse(_token.canTransfer(_alice, _bob, _ID, 41));
    assertFalse(_token.canTransfer(_alice, _bob, _ID, 101));
    // The other id has nothing frozen.
    assertTrue(_token.canTransfer(_alice, _bob, _OTHER, 50));
    assertTrue(_token.canTransfer(_alice, _bob, _OTHER, 51));
  }

  function test_WhenBothAddressesAreZero_ItReadsFalseWithoutAskingTheHook() external {
    _expectNotAsked();
    assertFalse(_token.canTransfer(address(0), address(0), _ID, 1));
    (, bytes32 _reason) = _token.canTransferWithReason(address(0), address(0), _ID, 1);
    assertEq(_reason, Reasons.ZERO_RECEIVER);
  }

  /// @dev ERC-8473, check rule 3: the operator simulated is the sender, zero for a mint, whoever asks
  function testFuzz_WhenAnyoneAsks_TheOperatorSimulatedIsTheSender(
    address _caller
  ) external {
    _expectAsked(_ctx(_alice, _bob, _ID, 30, _alice, _TRANSFER));
    _expectAsked(_ctx(address(0), _bob, _ID, 30, address(0), _MINT));
    _expectAsked(_ctx(_alice, address(0), _ID, 30, _alice, IERC8473Policy.TransferKind.BURN));
    vm.startPrank(_caller);
    _token.canTransfer(_alice, _bob, _ID, 30);
    _token.canTransfer(address(0), _bob, _ID, 30);
    _token.canTransfer(_alice, address(0), _ID, 30);
    vm.stopPrank();
  }

  function test_WhenTheBurnerAsksAboutBurningFrozenTokens_ItGetsTheHoldersAnswerAndTheBurnStillPasses() external {
    _freeze(_alice, _ID, 100);
    vm.prank(_burner);
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(_alice, address(0), _ID, 10);
    assertFalse(_ok);
    assertEq(_reason, Reasons.INSUFFICIENT_UNFROZEN);
    vm.prank(_burner);
    _token.burn(_alice, _ID, 10);
    assertEq(_token.balanceOf(_alice, _ID), 90);
  }

  function test_TheAccountAnswersAreTheHooks() external {
    _hookAccountChecksDecide(Reasons.SENDER_FROZEN, Reasons.RECEIVER_NOT_VERIFIED);
    assertFalse(_token.canSend(_alice));
    assertFalse(_token.canReceive(_bob));
    _hookAccountChecksDecide(Reasons.TRANSFER_OK, Reasons.TRANSFER_OK);
    assertTrue(_token.canSend(_alice));
    assertTrue(_token.canReceive(_bob));
  }

  /// @dev With nothing frozen, not paused and a policy that accepts, no amount makes `canTransfer` false
  function testFuzz_CanTransferIsNeverFalseForABalance(
    uint256 _amount
  ) external view {
    assertTrue(_token.canTransfer(_alice, _bob, _ID, _amount));
    assertTrue(_token.canTransfer(_stranger, _bob, _ID, _amount));
  }

  /// @dev `burn` is FORCED: for any frozen amount and pause it succeeds exactly when the policy permits it
  function testFuzz_TheEnforcementBurnFollowsThePolicyAlone(
    uint256 _frozen,
    uint256 _amount,
    bool _paused,
    uint256 _reasonSeed
  ) external {
    bytes32[3] memory _answers = [Reasons.TRANSFER_OK, Reasons.LOCKED_UP, Reasons.SENDER_FROZEN];
    bytes32 _answer = _answers[bound(_reasonSeed, 0, 2)];
    _hookDecides(_answer);
    _freeze(_alice, _ID, bound(_frozen, 0, 200));
    _amount = bound(_amount, 0, 100);
    if (_paused) _pause();

    vm.prank(_burner);
    (bool _wrote,) = address(_token).call(abi.encodeCall(Gated1155.burn, (_alice, _ID, _amount)));
    assertEq(_wrote, _answer == Reasons.TRANSFER_OK);
  }

  /// @dev Pre-flight never lies: for any sender, amount, frozen amount, pause and hook answer, it agrees with the write
  function testFuzz_ThePreflightAgreesWithTheWrite(
    uint256 _fromSeed,
    uint256 _amount,
    uint256 _frozen,
    bool _paused,
    uint256 _reasonSeed
  ) external {
    address[3] memory _senders = [_alice, _bob, _stranger];
    address _from = _senders[bound(_fromSeed, 0, 2)];
    bytes32[3] memory _answers = [Reasons.TRANSFER_OK, Reasons.LOCKED_UP, Reasons.RECEIVER_NOT_VERIFIED];
    _hookDecides(_answers[bound(_reasonSeed, 0, 2)]);
    _amount = bound(_amount, 0, 150);
    _freeze(_from, _ID, bound(_frozen, 0, 150));
    if (_paused) _pause();

    (bool _ok,) = _token.canTransferWithReason(_from, _carol, _ID, _amount);
    bool _allowed = _token.canTransfer(_from, _carol, _ID, _amount);
    vm.prank(_from);
    (bool _wrote,) = address(_token).call(abi.encodeCall(IERC1155.safeTransferFrom, (_from, _carol, _ID, _amount, '')));
    assertEq(_wrote, _ok);
    // The standard's bool is never stricter than the write.
    if (_wrote) assertTrue(_allowed);
  }
}

contract Gated1155Unit_Governance is Gated1155UnitTest {
  function test_WhenTheTimelockInstallsAnAttestedPolicy_ItIsInstalled() external {
    address _next = _mockContract('nextHook');
    _attested(_next, IPolicyRegistry.AttestKind.HOOK, true);
    vm.mockCall(_next, abi.encodeCall(IComplianceHook.REGISTRY, ()), abi.encode(_registry));
    _mockPolicy(_next);
    vm.expectEmit(address(_token));
    emit IERC8473.PolicyChanged(_hook, _next);
    vm.prank(_admin);
    _token.installPolicy(_next, '');
    assertEq(_token.policy(), _next);
  }

  function test_WhenTheCallerIsNotTheTimelock_ItCannotInstallAPolicy() external {
    vm.expectRevert(_unauthorized(_guardian, _token.DEFAULT_ADMIN_ROLE()));
    vm.prank(_guardian);
    _token.installPolicy(_hook, '');
  }

  function test_WhenUpgradedToAnAttestedImplementationOfTheSameTemplate_ItKeepsItsBalances() external {
    _freeze(_alice, _ID, 60);
    Gated1155 _next = new Gated1155();
    _attested(address(_next), IPolicyRegistry.AttestKind.IMPLEMENTATION, true);
    vm.prank(_upgrader);
    _token.upgradeToAndCall(address(_next), '');
    assertEq(_token.balanceOf(_alice, _ID), 100);
    assertEq(_token.totalSupply(_ID), 100);
    assertEq(_token.getFrozenTokens(_alice, _ID), 60);
    assertEq(_token.symbol(), 'gSER');
  }

  function test_WhenTheImplementationIsNotAttested_TheUpgradeIsRefused() external {
    Gated1155 _next = new Gated1155();
    _attested(address(_next), IPolicyRegistry.AttestKind.IMPLEMENTATION, false);
    vm.expectRevert(
      abi.encodeWithSelector(
        IPolicyGatedCore.PolicyGated_NotAttested.selector, address(_next), IPolicyRegistry.AttestKind.IMPLEMENTATION
      )
    );
    vm.prank(_upgrader);
    _token.upgradeToAndCall(address(_next), '');
  }

  function test_WhenTheImplementationIsAnotherTemplate_TheUpgradeIsRefused() external {
    GatedToken _other = new GatedToken();
    _attested(address(_other), IPolicyRegistry.AttestKind.IMPLEMENTATION, true);
    vm.expectRevert(
      abi.encodeWithSelector(
        ITemplated.Templated_WrongTemplate.selector, address(_other), keccak256('Gated1155'), keccak256('GatedToken')
      )
    );
    vm.prank(_upgrader);
    _token.upgradeToAndCall(address(_other), '');
  }

  function test_WhenTheCallerIsNotTheUpgrader_ItCannotUpgrade() external {
    Gated1155 _next = new Gated1155();
    vm.expectRevert(_unauthorized(_admin, _token.UPGRADER_ROLE()));
    vm.prank(_admin);
    _token.upgradeToAndCall(address(_next), '');
  }

  /// @dev No issuer batch functions: a role holder batches with `multicall`, each call a movement of its own
  function test_WhenTheAgentBatchesCalls_MulticallRunsThemAsTheAgent() external {
    bytes[] memory _calls = new bytes[](2);
    _calls[0] = abi.encodeCall(Gated1155.setFrozenTokens, (_alice, _ID, 100));
    _calls[1] = abi.encodeCall(Gated1155.forcedTransfer, (_alice, _bob, _ID, 100));
    vm.prank(_agent);
    _token.multicall(_calls);
    assertEq(_token.balanceOf(_bob, _ID), 100);
    assertEq(_token.getFrozenTokens(_alice, _ID), 0);
  }
}

contract Gated1155Unit_Metadata is Gated1155UnitTest {
  function test_WhenTheAgentSetsTheUri_ItEmitsUriForThatIdAlone() external {
    vm.expectEmit(address(_token));
    emit IERC1155.URI('ipfs://series-1', _ID);
    vm.prank(_agent);
    _token.setURI(_ID, 'ipfs://series-1');
    assertEq(_token.uri(_ID), 'ipfs://series-1');
    assertEq(_token.uri(_OTHER), '');
  }

  function test_WhenTheCallerIsNotTheAgent_ItReverts() external {
    vm.expectRevert(_unauthorized(_alice, _token.AGENT_ROLE()));
    vm.prank(_alice);
    _token.setURI(_ID, '');
  }
}

contract Gated1155Unit_SupportsInterface is Gated1155UnitTest {
  function test_WhenQueried_ItSupportsItsInterfacesAndNotTheOtherTemplates() external view {
    // ERC-7943 Final, multi-token: the standard's own id, as a literal
    assertTrue(_token.supportsInterface(0x41c4fbad));
    assertEq(type(IERC7943MultiToken).interfaceId, bytes4(0x41c4fbad));
    assertTrue(_token.supportsInterface(0x0505c8c9)); // ERC-8473
    assertTrue(_token.supportsInterface(type(IGated1155).interfaceId));
    assertTrue(_token.supportsInterface(type(IPolicyGatedCore).interfaceId));
    assertTrue(_token.supportsInterface(type(IERC1155).interfaceId));
    assertEq(type(IERC1155).interfaceId, bytes4(0xd9b67a26));
    assertTrue(_token.supportsInterface(type(IERC1155MetadataURI).interfaceId));
    assertTrue(_token.supportsInterface(type(IAccessControl).interfaceId));
    assertTrue(_token.supportsInterface(type(IERC165).interfaceId));
    assertFalse(_token.supportsInterface(type(IPolicyGated).interfaceId));
    assertFalse(_token.supportsInterface(0x3edbb4c4)); // ERC-7943 fungible
    assertFalse(_token.supportsInterface(0xbf1ef5fe)); // ERC-7943 non-fungible
    assertFalse(_token.supportsInterface(0xdeadbeef));
  }
}

/// @notice Drives holder transfers, freezes, mints, forced transfers and burns over three ids for the invariant suite
contract Gated1155Handler is Test {
  Gated1155 internal immutable _TOKEN;
  address internal immutable _AGENT;
  address internal immutable _BURNER;
  address internal immutable _MINTER;
  address[3] internal _holders;

  /// @notice Times a holder moved more than its unfrozen balance, was stopped within it, or an enforcement action
  ///         lowered the frozen amount by something other than the frozen part it took
  uint256 public violations;

  constructor(
    Gated1155 _token,
    address _agent,
    address _burner,
    address _minter,
    address[3] memory _accounts
  ) {
    _TOKEN = _token;
    _AGENT = _agent;
    _BURNER = _burner;
    _MINTER = _minter;
    _holders = _accounts;
  }

  function holderTransfer(
    uint256 _fromSeed,
    uint256 _toSeed,
    uint256 _idSeed,
    uint256 _amount
  ) external {
    address _from = _holders[bound(_fromSeed, 0, 2)];
    uint256 _tokenId = bound(_idSeed, 1, 3);
    uint256 _balance = _TOKEN.balanceOf(_from, _tokenId);
    uint256 _frozen = _TOKEN.getFrozenTokens(_from, _tokenId);
    uint256 _unfrozen = _balance > _frozen ? _balance - _frozen : 0;
    _amount = bound(_amount, 0, _balance + 10);
    vm.prank(_from);
    (bool _ok,) = address(_TOKEN)
      .call(abi.encodeCall(IERC1155.safeTransferFrom, (_from, _holders[bound(_toSeed, 0, 2)], _tokenId, _amount, '')));
    if (_ok != (_amount <= _unfrozen)) ++violations;
  }

  function setFrozen(
    uint256 _accountSeed,
    uint256 _idSeed,
    uint256 _amount
  ) external {
    vm.prank(_AGENT);
    _TOKEN.setFrozenTokens(_holders[bound(_accountSeed, 0, 2)], bound(_idSeed, 1, 3), bound(_amount, 0, 2000));
  }

  function mint(
    uint256 _toSeed,
    uint256 _idSeed,
    uint256 _amount
  ) external {
    vm.prank(_MINTER);
    _TOKEN.mint(_holders[bound(_toSeed, 0, 2)], bound(_idSeed, 1, 3), bound(_amount, 0, 1000));
  }

  function force(
    uint256 _fromSeed,
    uint256 _toSeed,
    uint256 _idSeed,
    uint256 _amount,
    bool _burn
  ) external {
    address _from = _holders[bound(_fromSeed, 0, 2)];
    address _to = _holders[bound(_toSeed, 0, 2)];
    uint256 _tokenId = bound(_idSeed, 1, 3);
    uint256 _balance = _TOKEN.balanceOf(_from, _tokenId);
    uint256 _frozen = _TOKEN.getFrozenTokens(_from, _tokenId);
    uint256 _unfrozen = _balance > _frozen ? _balance - _frozen : 0;
    _amount = bound(_amount, 0, _balance);
    if (_burn) {
      vm.prank(_BURNER);
      _TOKEN.burn(_from, _tokenId, _amount);
    } else {
      vm.prank(_AGENT);
      _TOKEN.forcedTransfer(_from, _to, _tokenId, _amount);
    }
    uint256 _taken = _amount > _unfrozen ? _amount - _unfrozen : 0;
    if (_TOKEN.getFrozenTokens(_from, _tokenId) != _frozen - _taken) ++violations;
  }
}

contract Gated1155Invariant_Balances is Gated1155UnitTest {
  Gated1155Handler internal _handler;
  address[3] internal _accounts;

  function setUp() public override {
    super.setUp();
    _accounts = [_alice, _bob, _carol];
    _handler = new Gated1155Handler(_token, _agent, _burner, _minter, _accounts);
    targetContract(address(_handler));
  }

  /// @dev A holder moves exactly up to its unfrozen balance of an id, and enforcement lowers the frozen amount by
  ///      exactly the frozen part it takes
  function invariant_AHolderMovesAtMostItsUnfrozenBalance() external view {
    assertEq(_handler.violations(), 0);
  }

  /// @dev For each id, the balances add up to its supply, and the supplies to the total
  function invariant_TheBalancesOfEachIdAddUpToItsSupply() external view {
    uint256 _total;
    for (uint256 _tokenId = 1; _tokenId <= 3; ++_tokenId) {
      uint256 _sum;
      for (uint256 _i = 0; _i < 3; ++_i) {
        _sum += _token.balanceOf(_accounts[_i], _tokenId);
      }
      assertEq(_sum, _token.totalSupply(_tokenId));
      _total += _sum;
    }
    assertEq(_total, _token.totalSupply());
  }
}

/// @notice The real hook and rules, deployed through `ProxyDeployer` as a product is
contract Gated1155IntegrationTest is Test {
  Gated1155 internal _series;
  PolicyRegistry internal _registry;
  ComplianceHook internal _hook;
  CredentialRegistry internal _creds;
  CredentialRule internal _credentialRule;
  HolderRestrictionRule internal _restrictionRule;

  address internal _guardian = makeAddr('guardian');
  address internal _kyc = makeAddr('kycAttester');
  address internal _minter = makeAddr('minter');
  address internal _burner = makeAddr('burner');
  address internal _agent = makeAddr('agent');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');
  address internal _eve = makeAddr('eve'); // never verified

  uint256 internal constant _ID = 1;
  uint256 internal constant _OTHER = 2;

  function setUp() public {
    _registry = new PolicyRegistry(address(this), address(this));
    _creds = new CredentialRegistry(address(this), _guardian);
    _creds.addAttester(_kyc, type(uint32).max);
    _credentialRule = new CredentialRule(_creds);
    _restrictionRule = new HolderRestrictionRule();
    _registry.attest(address(_credentialRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_restrictionRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _hook = new ComplianceHook(_registry);
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    Gated1155 _impl = new Gated1155();
    _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');

    IComplianceRule[] memory _rules = new IComplianceRule[](2);
    _rules[0] = _credentialRule;
    _rules[1] = _restrictionRule;
    ProxyDeployer _proxyDeployer = new ProxyDeployer(address(this), _registry);
    _series = Gated1155(
      _proxyDeployer.deploy(
        'gSER',
        address(_impl),
        abi.encodeCall(
          Gated1155.initialize,
          ('Gated Series', 'gSER', address(this), _guardian, address(_registry), address(_hook), _rules)
        ),
        address(_hook),
        _rules
      )
    );
    _credentialRule.setPolicy(address(_series), Quals.KYC, 0, 0, 1);
    _series.grantRole(_series.MINTER_ROLE(), _minter);
    _series.grantRole(_series.BURNER_ROLE(), _burner);
    _series.grantRole(_series.AGENT_ROLE(), _agent);

    vm.startPrank(_kyc);
    _creds.set(_alice, uint64(block.timestamp + 365 days), Quals.KYC);
    _creds.set(_bob, uint64(block.timestamp + 365 days), Quals.KYC);
    vm.stopPrank();
    vm.startPrank(_minter);
    _series.mint(_alice, _ID, 100);
    _series.mint(_alice, _OTHER, 50);
    vm.stopPrank();
  }

  function _transferWithParity(
    address _from,
    address _to,
    uint256 _tokenId,
    uint256 _amount
  ) internal returns (bool _ok, bytes32 _reason) {
    (_ok, _reason) = _series.canTransferWithReason(_from, _to, _tokenId, _amount);
    if (!_ok) vm.expectRevert(abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, _reason));
    vm.prank(_from);
    _series.safeTransferFrom(_from, _to, _tokenId, _amount, '');
  }
}

contract Gated1155Integration_Rules is Gated1155IntegrationTest {
  function test_WhenDeployed_TheHookHoldsTheProductsRules() external view {
    assertEq(_series.policy(), address(_hook));
    assertEq(_hook.ruleCount(address(_series)), 2);
  }

  function test_WhenBothPartiesAreVerified_TheTransferSucceedsAndPreflightAgrees() external {
    (bool _ok,) = _transferWithParity(_alice, _bob, _ID, 30);
    assertTrue(_ok);
    assertEq(_series.balanceOf(_bob, _ID), 30);
  }

  function test_WhenTheReceiverIsNotVerified_TheTransferTheBatchAndTheMintAreRefused() external {
    assertFalse(_series.canReceive(_eve));
    (bool _ok, bytes32 _reason) = _transferWithParity(_alice, _eve, _ID, 30);
    assertFalse(_ok);
    assertEq(_reason, Reasons.RECEIVER_NOT_VERIFIED);

    uint256[] memory _ids = new uint256[](2);
    uint256[] memory _values = new uint256[](2);
    (_ids[0], _ids[1]) = (_ID, _OTHER);
    (_values[0], _values[1]) = (30, 20);
    vm.expectRevert(abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_alice);
    _series.safeBatchTransferFrom(_alice, _eve, _ids, _values, '');

    vm.expectRevert(abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_minter);
    _series.mint(_eve, _ID, 1);
  }

  /// @dev One policy for the contract: a lockup on a holder covers every id it holds
  function test_WhenTheHolderIsLocked_ItCanSendNoIdAndTheAgentCanStillForce() external {
    vm.prank(_agent);
    _restrictionRule.setLockup(address(_series), _alice, block.timestamp + 30 days);
    assertFalse(_series.canSend(_alice));
    (bool _ok, bytes32 _reason) = _transferWithParity(_alice, _bob, _ID, 30);
    assertFalse(_ok);
    assertEq(_reason, Reasons.LOCKED_UP);
    (_ok, _reason) = _transferWithParity(_alice, _bob, _OTHER, 20);
    assertFalse(_ok);
    assertEq(_reason, Reasons.LOCKED_UP);

    vm.prank(_agent);
    _series.forcedTransfer(_alice, _bob, _ID, 30);
    assertEq(_series.balanceOf(_bob, _ID), 30);
  }

  function test_WhenTheReceiverIsFrozenByTheRule_ItCannotReceiveEvenByForce() external {
    vm.prank(_agent);
    _restrictionRule.setFrozen(address(_series), _bob, true);
    assertFalse(_series.canReceive(_bob));
    (bool _ok, bytes32 _reason) = _transferWithParity(_alice, _bob, _ID, 30);
    assertFalse(_ok);
    assertEq(_reason, Reasons.RECEIVER_FROZEN);

    vm.expectRevert(abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, Reasons.RECEIVER_FROZEN));
    vm.prank(_agent);
    _series.forcedTransfer(_alice, _bob, _ID, 30);
  }

  function test_WhenTheAgentForcesToAnUnverifiedAccount_ItIsRefused() external {
    vm.expectRevert(abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_agent);
    _series.forcedTransfer(_alice, _eve, _ID, 30);
  }

  function test_WhenTheHolderIsLocked_TheBurnerCanStillBurn() external {
    vm.prank(_agent);
    _restrictionRule.setLockup(address(_series), _alice, block.timestamp + 30 days);
    // The pre-flight answers for a holder's burn, whoever asks; the burner's burn is FORCED and is not predicted.
    vm.prank(_burner);
    (, bytes32 _reason) = _series.canTransferWithReason(_alice, address(0), _ID, 100);
    assertEq(_reason, Reasons.LOCKED_UP);
    vm.prank(_burner);
    _series.burn(_alice, _ID, 100);
    assertEq(_series.balanceOf(_alice, _ID), 0);
    assertEq(_series.totalSupply(_ID), 0);
  }

  /// @dev ERC-7943 has `canTransfer` perform a `canSend` check on the sender and a `canReceive` check on the receiver:
  ///      through the shipped rules it is never true while either account answer is false
  function testFuzz_CanTransferIsNotTrueWhileAnAccountAnswerIsFalse(
    uint256 _amount,
    bool _toTheUnverified,
    bool _locked,
    bool _senderFrozen,
    bool _receiverFrozen
  ) external {
    address _to = _toTheUnverified ? _eve : _bob;
    vm.startPrank(_agent);
    if (_locked) _restrictionRule.setLockup(address(_series), _alice, block.timestamp + 1 days);
    if (_senderFrozen) _restrictionRule.setFrozen(address(_series), _alice, true);
    if (_receiverFrozen) _restrictionRule.setFrozen(address(_series), _to, true);
    vm.stopPrank();
    if (_series.canTransfer(_alice, _to, _ID, _amount)) {
      assertTrue(_series.canSend(_alice), 'canTransfer without canSend');
      assertTrue(_series.canReceive(_to), 'canTransfer without canReceive');
    }
  }

  /// @dev For any amount and either receiver, the reasoned pre-flight agrees with the write through the real rules
  function testFuzz_ThePreflightAgreesWithTheWrite(
    uint256 _amount,
    bool _toTheUnverified,
    bool _locked
  ) external {
    _amount = bound(_amount, 0, 100);
    if (_locked) {
      vm.prank(_agent);
      _restrictionRule.setLockup(address(_series), _alice, block.timestamp + 1 days);
    }
    (bool _ok,) = _transferWithParity(_alice, _toTheUnverified ? _eve : _bob, _ID, _amount);
    assertEq(_ok, !_toTheUnverified && !_locked);
  }
}
