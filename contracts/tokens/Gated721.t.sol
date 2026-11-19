// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC4906} from '@openzeppelin/contracts/interfaces/IERC4906.sol';
import {IERC721Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {Initializable} from '@openzeppelin/contracts/proxy/utils/Initializable.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {IERC721Receiver} from '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import {IERC721Metadata} from '@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC7943NonFungible} from 'interfaces/IERC7943NonFungible.sol';
import {IERC8473} from 'interfaces/IERC8473.sol';
import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';
import {IGated721} from 'interfaces/IGated721.sol';
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
import {Gated721} from 'contracts/tokens/Gated721.sol';
import {GatedToken} from 'contracts/tokens/GatedToken.sol';

/// @notice A hook that calls back into the token from `afterTransfer`, which the token's guard must refuse
contract MockReentrantHook {
  /// @notice The registry the hook names
  address public immutable REGISTRY;
  /// @notice The token it calls back into
  Gated721 public token;

  constructor(
    address _registry
  ) {
    REGISTRY = _registry;
  }

  function setToken(
    Gated721 _token
  ) external {
    token = _token;
  }

  function checkTransfer(
    IERC8473Policy.TransferContext calldata
  ) external pure returns (bytes32 _reason) {
    _reason = Reasons.TRANSFER_OK;
  }

  function wantsAfterTransfer() external pure returns (bool _wants) {
    _wants = true;
  }

  function onInstall(
    address,
    address,
    bytes calldata
  ) external {}

  function supportsInterface(
    bytes4
  ) external pure returns (bool _supported) {
    _supported = true;
  }

  function afterTransfer(
    IERC8473Policy.TransferContext calldata _ctx
  ) external {
    if (_ctx.to != address(0)) token.transferFrom(_ctx.to, address(0xbeef), _ctx.tokenId);
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

/// @notice A receiver that passes every token it receives on to `next`, from inside the ERC-721 callback
contract MockForwardingReceiver is IERC721Receiver {
  /// @notice Where it forwards
  address public immutable NEXT;

  constructor(
    address _next
  ) {
    NEXT = _next;
  }

  function onERC721Received(
    address,
    address,
    uint256 _tokenId,
    bytes calldata
  ) external returns (bytes4 _selector) {
    IERC721(msg.sender).transferFrom(address(this), NEXT, _tokenId);
    _selector = IERC721Receiver.onERC721Received.selector;
  }
}

contract Gated721UnitTest is Helpers {
  Gated721 internal _token;
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
  string internal constant _URI = 'ipfs://note-1';

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

    vm.prank(_minter);
    _token.mint(_alice, _ID, _URI);
  }

  function _deploy(
    address _initialHook
  ) internal returns (Gated721 _proxy) {
    Gated721 _impl = new Gated721();
    _proxy = Gated721(
      address(
        new ERC1967Proxy(
          address(_impl),
          abi.encodeCall(
            Gated721.initialize,
            ('Gated Note', 'gNOTE', _admin, _guardian, _registry, _initialHook, new IComplianceRule[](0))
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

  /// @dev The context the token builds: `tokenId` is the token, `amount` one, `data` the holdings before the move
  function _ctx(
    address _from,
    address _to,
    uint256 _tokenId,
    address _operator,
    IERC8473Policy.TransferKind _kind
  ) internal view returns (IERC8473Policy.TransferContext memory _context) {
    _context = IERC8473Policy.TransferContext({
      token: address(_token),
      from: _from,
      to: _to,
      tokenId: _tokenId,
      amount: 1,
      operator: _operator,
      kind: _kind,
      data: abi.encode(_from == address(0) ? 0 : _token.balanceOf(_from), _to == address(0) ? 0 : _token.balanceOf(_to))
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
    _revertData = abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, _reason);
  }

  function _frozenError(
    address _account,
    uint256 _tokenId
  ) internal pure returns (bytes memory _revertData) {
    _revertData =
      abi.encodeWithSelector(IERC7943NonFungible.ERC7943InsufficientUnfrozenBalance.selector, _account, _tokenId);
  }

  function _freeze(
    address _account,
    uint256 _tokenId
  ) internal {
    vm.prank(_agent);
    _token.setFrozenTokens(_account, _tokenId, true);
  }
}

contract Gated721Unit_Initialize is Gated721UnitTest {
  function test_WhenInitialized_ItHoldsItsNameRolesHookAndRegistry() external view {
    assertEq(_token.name(), 'Gated Note');
    assertEq(_token.symbol(), 'gNOTE');
    assertTrue(_token.hasRole(_token.DEFAULT_ADMIN_ROLE(), _admin));
    assertTrue(_token.hasRole(_token.GUARDIAN_ROLE(), _guardian));
    assertEq(_token.policy(), _hook);
    assertEq(_token.registry(), _registry);
    assertEq(_token.templateId(), keccak256('Gated721'));
  }

  /// @dev The freezes live at the ERC-7201 location the constant names: the formula equals it, and a freeze set through
  ///      the token is the word the mapping puts there
  function test_TheErc7201LocationHoldsTheFreezes() external {
    bytes32 _location =
      keccak256(abi.encode(uint256(keccak256('gated.storage.Gated721')) - 1)) & ~bytes32(uint256(0xff));
    assertEq(_location, 0xe2e6a0763355f0c539395516a687d1cc0bc64d7e84611f8f6d2274edd1a6f900);
    _freeze(_alice, _ID);
    bytes32 _slot = keccak256(abi.encode(_ID, keccak256(abi.encode(_alice, _location))));
    assertEq(uint256(vm.load(address(_token), _slot)), 1);
  }

  /// @dev No receive or payable function, so ether sent to the token is refused
  function test_WhenEtherIsSent_ItReverts() external {
    vm.deal(address(this), 1 ether);
    (bool _ok,) = address(_token).call{value: 1 ether}('');
    assertFalse(_ok);
    assertEq(address(_token).balance, 0);
  }

  function test_WhenTheImplementationIsInitializedDirectly_ItReverts() external {
    Gated721 _impl = new Gated721();
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    _impl.initialize('X', 'X', _admin, _guardian, _registry, _hook, new IComplianceRule[](0));
  }

  function test_WhenTheAdminIsZero_ItReverts() external {
    Gated721 _impl = new Gated721();
    vm.expectRevert(IPolicyGatedCore.PolicyGated_ZeroAddress.selector);
    new ERC1967Proxy(
      address(_impl),
      abi.encodeCall(Gated721.initialize, ('X', 'X', address(0), _guardian, _registry, _hook, new IComplianceRule[](0)))
    );
  }

  function test_WhenTheHookIsNotAttested_ItReverts() external {
    address _other = _mockContract('otherHook');
    _attested(_other, IPolicyRegistry.AttestKind.HOOK, false);
    Gated721 _impl = new Gated721();
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_NotAttested.selector, _other, IPolicyRegistry.AttestKind.HOOK)
    );
    new ERC1967Proxy(
      address(_impl),
      abi.encodeCall(Gated721.initialize, ('X', 'X', _admin, _guardian, _registry, _other, new IComplianceRule[](0)))
    );
  }
}

contract Gated721Unit_Mint is Gated721UnitTest {
  function test_WhenTheMinterMints_TheHookSeesAMintOfOneAndTheTokenHasItsUri() external {
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IERC8473Policy.checkTransfer, (_ctx(address(0), _bob, 2, _minter, IERC8473Policy.TransferKind.MINT))
      )
    );
    vm.expectEmit(address(_token));
    emit IERC721.Transfer(address(0), _bob, 2);
    vm.expectEmit(address(_token));
    emit IERC4906.MetadataUpdate(2);
    vm.prank(_minter);
    _token.mint(_bob, 2, 'ipfs://note-2');
    assertEq(_token.ownerOf(2), _bob);
    assertEq(_token.tokenURI(2), 'ipfs://note-2');
    assertEq(_token.balanceOf(_bob), 1);
  }

  function test_WhenTheCallerIsNotTheMinter_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _token.MINTER_ROLE()));
    vm.prank(_stranger);
    _token.mint(_bob, 2, '');
  }

  function test_WhenTheTokenExists_ItRevertsWithoutAskingTheHook() external {
    vm.expectCall(_hook, abi.encodeWithSelector(IERC8473Policy.checkTransfer.selector), 0);
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
    vm.prank(_minter);
    _token.mint(_bob, _ID, '');
  }

  function test_WhenTheReceiverIsZero_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
    vm.prank(_minter);
    _token.mint(address(0), 2, '');
  }

  function test_WhenTheHookRejects_NothingIsMinted() external {
    _hookDecides(Reasons.RECEIVER_NOT_VERIFIED);
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_minter);
    _token.mint(_bob, 2, '');
    assertEq(_token.balanceOf(_bob), 0);
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
    _token.ownerOf(2);
  }
}

contract Gated721Unit_Transfer is Gated721UnitTest {
  function test_WhenTheOwnerTransfers_TheHookSeesATransferWithTheHoldings() external {
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IERC8473Policy.checkTransfer, (_ctx(_alice, _bob, _ID, _alice, IERC8473Policy.TransferKind.TRANSFER))
      )
    );
    vm.prank(_alice);
    _token.transferFrom(_alice, _bob, _ID);
    assertEq(_token.ownerOf(_ID), _bob);
    assertEq(_token.balanceOf(_alice), 0);
  }

  function test_WhenAnApprovedOperatorTransfers_TheOperatorIsInTheContext() external {
    vm.prank(_alice);
    _token.approve(_carol, _ID);
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IERC8473Policy.checkTransfer, (_ctx(_alice, _bob, _ID, _carol, IERC8473Policy.TransferKind.TRANSFER))
      )
    );
    vm.prank(_carol);
    _token.transferFrom(_alice, _bob, _ID);
    assertEq(_token.ownerOf(_ID), _bob);
    assertEq(_token.getApproved(_ID), address(0));
  }

  function test_WhenTheCallerIsNotApproved_ErcSevenTwentyOneRevertsBeforeTheHookIsAsked() external {
    vm.expectCall(_hook, abi.encodeWithSelector(IERC8473Policy.checkTransfer.selector), 0);
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, _stranger, _ID));
    vm.prank(_stranger);
    _token.transferFrom(_alice, _bob, _ID);
  }

  function test_WhenFromIsNotTheOwner_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, _bob, _ID, _alice));
    vm.prank(_alice);
    _token.transferFrom(_bob, _carol, _ID);
  }

  function test_WhenTheHookRejects_NothingMoves() external {
    _hookDecides(Reasons.LOCKED_UP);
    vm.expectRevert(_rejected(Reasons.LOCKED_UP));
    vm.prank(_alice);
    _token.transferFrom(_alice, _bob, _ID);
    assertEq(_token.ownerOf(_ID), _alice);
  }

  function test_WhenTheHookWantsAfter_ItIsCalledWithTheSameContext() external {
    vm.mockCall(_hook, abi.encodeCall(IERC8473Policy.wantsAfterTransfer, ()), abi.encode(true));
    IERC8473Policy.TransferContext memory _context =
      _ctx(_alice, _bob, _ID, _alice, IERC8473Policy.TransferKind.TRANSFER);
    _mockAndExpect(_hook, abi.encodeCall(IERC8473Policy.afterTransfer, (_context)), '');
    vm.prank(_alice);
    _token.transferFrom(_alice, _bob, _ID);
  }

  function test_WhenTheReceiverForwardsTheTokenFromItsCallback_ThePolicyJudgesThatMoveToo() external {
    MockForwardingReceiver _receiver = new MockForwardingReceiver(_carol);
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, address(_receiver), _ID);
    assertEq(_token.ownerOf(_ID), _carol);

    // The second move is refused on its own: the whole transfer reverts.
    vm.prank(_minter);
    _token.mint(_alice, 2, '');
    IERC8473Policy.TransferContext memory _onward =
      _ctx(address(_receiver), _carol, 2, address(_receiver), IERC8473Policy.TransferKind.TRANSFER);
    _onward.data = abi.encode(uint256(1), _token.balanceOf(_carol));
    vm.mockCall(_hook, abi.encodeCall(IERC8473Policy.checkTransfer, (_onward)), abi.encode(Reasons.RECEIVER_FROZEN));
    vm.expectRevert(_rejected(Reasons.RECEIVER_FROZEN));
    vm.prank(_alice);
    _token.safeTransferFrom(_alice, address(_receiver), 2);
    assertEq(_token.ownerOf(2), _alice);
  }

  function test_WhenTheHookCallsBackIntoTheToken_TheGuardRefusesIt() external {
    MockReentrantHook _reentrant = new MockReentrantHook(_registry);
    _attested(address(_reentrant), IPolicyRegistry.AttestKind.HOOK, true);
    vm.prank(_admin);
    _token.installPolicy(address(_reentrant), '');
    _reentrant.setToken(_token);
    vm.prank(_bob);
    _token.setApprovalForAll(address(_reentrant), true);

    vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    vm.prank(_alice);
    _token.transferFrom(_alice, _bob, _ID);
  }
}

contract Gated721Unit_Burn is Gated721UnitTest {
  /// @dev The burner's burn is enforcement, so the policy sees FORCED with no receiver (ERC-8473, transfer kinds)
  function test_WhenTheBurnerBurns_ThePolicySeesAForcedMovementToZeroAndTheTokenIsGone() external {
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IERC8473Policy.checkTransfer, (_ctx(_alice, address(0), _ID, _burner, IERC8473Policy.TransferKind.FORCED))
      )
    );
    vm.prank(_burner);
    _token.burn(_ID);
    assertEq(_token.balanceOf(_alice), 0);
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _ID));
    _token.tokenURI(_ID);
  }

  function test_WhenTheCallerIsNotTheBurner_ItReverts() external {
    vm.expectRevert(_unauthorized(_alice, _token.BURNER_ROLE()));
    vm.prank(_alice);
    _token.burn(_ID);
  }

  function test_WhenTheTokenDoesNotExist_ItRevertsWithoutAskingTheHook() external {
    vm.expectCall(_hook, abi.encodeWithSelector(IERC8473Policy.checkTransfer.selector), 0);
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
    vm.prank(_burner);
    _token.burn(2);
  }

  function test_WhenTheTokenIsFrozen_TheBurnClearsTheFreezeBeforeTheTransferEvent() external {
    _freeze(_alice, _ID);
    vm.expectEmit(address(_token));
    emit IERC7943NonFungible.Frozen(_alice, _ID, false);
    vm.expectEmit(address(_token));
    emit IERC721.Transfer(_alice, address(0), _ID);
    vm.prank(_burner);
    _token.burn(_ID);
    assertFalse(_token.getFrozenTokens(_alice, _ID));
  }

  function test_WhenTheHookRejects_TheTokenAndItsFreezeStay() external {
    _freeze(_alice, _ID);
    _hookDecides(Reasons.SENDER_FROZEN);
    vm.expectRevert(_rejected(Reasons.SENDER_FROZEN));
    vm.prank(_burner);
    _token.burn(_ID);
    assertEq(_token.ownerOf(_ID), _alice);
    assertTrue(_token.getFrozenTokens(_alice, _ID));
  }
}

contract Gated721Unit_ForcedTransfer is Gated721UnitTest {
  function test_WhenTheAgentForces_TheHookSeesAForcedMoveAndBothEventsCarryTheToken() external {
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IERC8473Policy.checkTransfer, (_ctx(_alice, _bob, _ID, _agent, IERC8473Policy.TransferKind.FORCED))
      )
    );
    vm.expectEmit(address(_token));
    emit IERC721.Transfer(_alice, _bob, _ID);
    vm.expectEmit(address(_token));
    emit IERC7943NonFungible.ForcedTransfer(_alice, _bob, _ID);
    vm.expectEmit(address(_token));
    emit IGated721.ForcedTransferBy(_alice, _bob, _ID, _agent);
    vm.prank(_agent);
    assertTrue(_token.forcedTransfer(_alice, _bob, _ID));
    assertEq(_token.ownerOf(_ID), _bob);
  }

  function test_WhenTheTokenIsFrozen_ItIsUnfrozenFirstWithFrozenBeforeTransfer() external {
    _freeze(_alice, _ID);
    vm.expectEmit(address(_token));
    emit IERC7943NonFungible.Frozen(_alice, _ID, false);
    vm.expectEmit(address(_token));
    emit IERC721.Transfer(_alice, _bob, _ID);
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, _ID);
    assertFalse(_token.getFrozenTokens(_alice, _ID));
  }

  function test_WhenPaused_ItStillWorks() external {
    vm.prank(_guardian);
    _token.pause();
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, _ID);
    assertEq(_token.ownerOf(_ID), _bob);
  }

  function test_WhenTheHookRejectsTheReceiver_ItReverts() external {
    _hookDecides(Reasons.RECEIVER_NOT_VERIFIED);
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, _ID);
  }

  function test_WhenFromIsNotTheOwner_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, _bob, _ID, _alice));
    vm.prank(_agent);
    _token.forcedTransfer(_bob, _carol, _ID);
  }

  function test_WhenTheReceiverIsZero_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
    vm.prank(_agent);
    _token.forcedTransfer(_alice, address(0), _ID);
  }

  function test_WhenTheTokenDoesNotExist_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, 2);
  }

  function test_WhenTheCallerIsNotTheAgent_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _token.AGENT_ROLE()));
    vm.prank(_stranger);
    _token.forcedTransfer(_alice, _bob, _ID);
  }
}

contract Gated721Unit_Freeze is Gated721UnitTest {
  function test_WhenTheAgentFreezes_ItEmitsFrozenAndOverwrites() external {
    vm.expectEmit(address(_token));
    emit IERC7943NonFungible.Frozen(_alice, _ID, true);
    vm.prank(_agent);
    assertTrue(_token.setFrozenTokens(_alice, _ID, true));
    assertTrue(_token.getFrozenTokens(_alice, _ID));

    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _ID, false);
    assertFalse(_token.getFrozenTokens(_alice, _ID));
  }

  function test_WhenTheAccountDoesNotHoldTheToken_TheFreezeIsStillRecorded() external {
    _freeze(_bob, 7);
    assertTrue(_token.getFrozenTokens(_bob, 7));
  }

  function test_WhenTheCallerIsNotTheAgent_ItReverts() external {
    vm.expectRevert(_unauthorized(_alice, _token.AGENT_ROLE()));
    vm.prank(_alice);
    _token.setFrozenTokens(_alice, _ID, true);
  }

  function test_WhenFrozen_NeitherTheOwnerNorAnApprovedOperatorCanMoveIt() external {
    vm.prank(_alice);
    _token.approve(_carol, _ID);
    _freeze(_alice, _ID);

    assertFalse(_token.canTransfer(_alice, _bob, _ID));
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(_alice, _bob, _ID);
    assertFalse(_ok);
    assertEq(_reason, Reasons.INSUFFICIENT_UNFROZEN);

    vm.expectRevert(_frozenError(_alice, _ID));
    vm.prank(_alice);
    _token.transferFrom(_alice, _bob, _ID);
    vm.expectRevert(_frozenError(_alice, _ID));
    vm.prank(_carol);
    _token.transferFrom(_alice, _bob, _ID);
  }

  function test_WhenAnotherAccountIsFrozenForTheToken_TheOwnerCanStillMoveIt() external {
    _freeze(_bob, _ID);
    vm.prank(_alice);
    _token.transferFrom(_alice, _carol, _ID);
    assertEq(_token.ownerOf(_ID), _carol);
  }

  function test_WhenTheTokenReachesAnAccountFrozenForIt_ItArrivesFrozen() external {
    _freeze(_bob, _ID);
    vm.prank(_alice);
    _token.transferFrom(_alice, _bob, _ID);
    vm.expectRevert(_frozenError(_bob, _ID));
    vm.prank(_bob);
    _token.transferFrom(_bob, _carol, _ID);
  }

  function test_WhenTheHookBorrowsTheFrozenCodeWithNoFreeze_ItIsAPolicyRejection() external {
    _hookDecides(Reasons.INSUFFICIENT_UNFROZEN);
    vm.expectRevert(_rejected(Reasons.INSUFFICIENT_UNFROZEN));
    vm.prank(_alice);
    _token.transferFrom(_alice, _bob, _ID);
  }
}

contract Gated721Unit_Pause is Gated721UnitTest {
  function test_WhenPaused_TransfersAndMintsAreRejectedAndTheEnforcementBurnPasses() external {
    vm.prank(_guardian);
    _token.pause();
    vm.expectRevert(_rejected(Reasons.PAUSED));
    vm.prank(_alice);
    _token.transferFrom(_alice, _bob, _ID);
    vm.expectRevert(_rejected(Reasons.PAUSED));
    vm.prank(_minter);
    _token.mint(_bob, 2, '');
    assertFalse(_token.canSend(_alice));
    assertFalse(_token.canReceive(_bob));
    // An enforcement burn is FORCED, which the pause does not stop, as it does not stop a forced transfer.
    vm.prank(_burner);
    _token.burn(_ID);
    assertEq(_token.balanceOf(_alice), 0);
  }

  function test_WhenTheCallerIsNotTheGuardian_ItCannotPause() external {
    vm.expectRevert(_unauthorized(_admin, _token.GUARDIAN_ROLE()));
    vm.prank(_admin);
    _token.pause();
  }

  function test_WhenPaused_TheGuardianCannotUnpauseAndTheTimelockOrRecoveryCan() external {
    vm.prank(_guardian);
    _token.pause();
    vm.expectRevert(_unauthorized(_guardian, _token.DEFAULT_ADMIN_ROLE()));
    vm.prank(_guardian);
    _token.unpause();

    vm.prank(_recovery);
    _token.unpause();
    assertFalse(_token.paused());

    vm.prank(_guardian);
    _token.pause();
    vm.prank(_admin);
    _token.unpause();
    assertFalse(_token.paused());
  }

  function test_WhenTheRecoveryTimelockRevokesTheGuardian_ItCanRevokeNothingElse() external {
    bytes32 _guardianRole = _token.GUARDIAN_ROLE();
    bytes32 _agentRole = _token.AGENT_ROLE();
    vm.prank(_recovery);
    _token.revokeRole(_guardianRole, _guardian);
    assertFalse(_token.hasRole(_guardianRole, _guardian));

    vm.expectRevert(_unauthorized(_recovery, _token.DEFAULT_ADMIN_ROLE()));
    vm.prank(_recovery);
    _token.revokeRole(_agentRole, _agent);
  }
}

contract Gated721Unit_Preflight is Gated721UnitTest {
  function test_WhenFromIsNotTheOwner_OnlyTheReasonedPreflightSaysSo() external view {
    assertTrue(_token.canTransfer(_bob, _carol, _ID), 'ownership is left to ERC-721');
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(_bob, _carol, _ID);
    assertFalse(_ok);
    assertEq(_reason, Reasons.NOT_TOKEN_OWNER);
  }

  function test_WhenAMintIsAskedAbout_AnExistingTokenIsNotOwnedByTheZeroAddress() external view {
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(address(0), _bob, _ID);
    assertFalse(_ok);
    assertEq(_reason, Reasons.NOT_TOKEN_OWNER);
    (_ok,) = _token.canTransferWithReason(address(0), _bob, 2);
    assertTrue(_ok);
    (, _reason) = _token.canTransferWithReason(address(0), address(0), 2);
    assertEq(_reason, Reasons.ZERO_RECEIVER);
  }

  /// @dev A pre-flight simulates TRANSFER, MINT and BURN with `_from` as the operator, whoever asks. The burner's burn
  ///      is FORCED, which no pre-flight predicts: asked about a frozen token, the answer is the holder's, and `burn`
  ///      still takes the token
  function test_WhenTheBurnerAsksAboutBurningAFrozenToken_ItGetsTheHoldersAnswerAndTheBurnStillPasses() external {
    _freeze(_alice, _ID);
    vm.prank(_burner);
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(_alice, address(0), _ID);
    assertFalse(_ok);
    assertEq(_reason, Reasons.INSUFFICIENT_UNFROZEN);
    vm.prank(_burner);
    assertFalse(_token.canTransfer(_alice, address(0), _ID));

    vm.prank(_burner);
    _token.burn(_ID);
    assertEq(_token.balanceOf(_alice), 0);
  }

  /// @dev The operator of a burn pre-flight is `_from`, not the caller
  function test_WhenAnyoneAsksAboutABurn_TheOperatorIsTheSender(
    address _caller
  ) external {
    vm.expectCall(
      _hook,
      abi.encodeCall(
        IERC8473Policy.checkTransfer, (_ctx(_alice, address(0), _ID, _alice, IERC8473Policy.TransferKind.BURN))
      )
    );
    vm.prank(_caller);
    assertTrue(_token.canTransfer(_alice, address(0), _ID));
  }

  /// @dev Asked by the holder, the same answer: a frozen token stops a holder's burn
  function test_WhenAnAccountWithoutTheRoleAsksAboutBurningAFrozenToken_TheFreezeCounts() external {
    _freeze(_alice, _ID);
    vm.prank(_alice);
    (, bytes32 _reason) = _token.canTransferWithReason(_alice, address(0), _ID);
    assertEq(_reason, Reasons.INSUFFICIENT_UNFROZEN);
  }

  function test_WhenTheTokenHasNoHook_TheAnswersAreNoHookAndFalse() external {
    bytes32 _location =
      keccak256(abi.encode(uint256(keccak256('gated.storage.PolicyGatedCore')) - 1)) & ~bytes32(uint256(0xff));
    vm.store(address(_token), bytes32(uint256(_location) + 1), bytes32(0)); // PolicyGatedCoreStorage.hook
    (, bytes32 _reason) = _token.canTransferWithReason(_alice, _bob, _ID);
    assertEq(_reason, Reasons.NO_HOOK);
    assertFalse(_token.canSend(_alice));
    assertFalse(_token.canReceive(_bob));
  }

  function test_TheAccountAnswersAreTheHooks() external {
    _hookAccountChecksDecide(Reasons.LOCKED_UP, Reasons.RECEIVER_NOT_VERIFIED);
    assertFalse(_token.canSend(_alice));
    assertFalse(_token.canReceive(_bob));
    _hookAccountChecksDecide(Reasons.TRANSFER_OK, Reasons.TRANSFER_OK);
    assertTrue(_token.canSend(_alice));
    assertTrue(_token.canReceive(_bob));
  }

  /// @dev `burn` is FORCED: for any freeze and pause it succeeds exactly when the policy permits it, and the burn
  ///      pre-flight gives one answer whoever asks
  function testFuzz_TheEnforcementBurnFollowsThePolicyAlone(
    bool _frozen,
    bool _paused,
    uint256 _reasonSeed,
    address _caller
  ) external {
    bytes32[3] memory _answers = [Reasons.TRANSFER_OK, Reasons.LOCKED_UP, Reasons.SENDER_FROZEN];
    bytes32 _answer = _answers[bound(_reasonSeed, 0, 2)];
    _hookDecides(_answer);
    if (_frozen) _freeze(_alice, _ID);
    if (_paused) {
      vm.prank(_guardian);
      _token.pause();
    }

    vm.prank(_burner);
    (bool _askedByTheBurner,) = _token.canTransferWithReason(_alice, address(0), _ID);
    vm.prank(_caller);
    (bool _askedByAnyone,) = _token.canTransferWithReason(_alice, address(0), _ID);
    assertEq(_askedByTheBurner, _askedByAnyone);

    vm.prank(_burner);
    (bool _wrote,) = address(_token).call(abi.encodeCall(Gated721.burn, (_ID)));
    assertEq(_wrote, _answer == Reasons.TRANSFER_OK);
  }

  /// @dev Pre-flight never lies: for any owner, freeze, pause and hook answer, it agrees with the write
  function testFuzz_ThePreflightAgreesWithTheWrite(
    uint256 _fromSeed,
    bool _frozen,
    bool _paused,
    uint256 _reasonSeed
  ) external {
    address[3] memory _senders = [_alice, _bob, _stranger];
    address _from = _senders[bound(_fromSeed, 0, 2)];
    bytes32[3] memory _answers = [Reasons.TRANSFER_OK, Reasons.LOCKED_UP, Reasons.RECEIVER_NOT_VERIFIED];
    _hookDecides(_answers[bound(_reasonSeed, 0, 2)]);
    if (_frozen) _freeze(_from, _ID);
    if (_paused) {
      vm.prank(_guardian);
      _token.pause();
    }

    (bool _ok,) = _token.canTransferWithReason(_from, _carol, _ID);
    vm.prank(_from);
    (bool _wrote,) = address(_token).call(abi.encodeCall(IERC721.transferFrom, (_from, _carol, _ID)));
    assertEq(_wrote, _ok);
  }
}

contract Gated721Unit_Governance is Gated721UnitTest {
  function test_WhenTheTimelockSetsAnAttestedHook_ItIsInstalled() external {
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

  function test_WhenTheHookIsNotAttestedOrNamesAnotherRegistry_ItIsRefused() external {
    address _next = _mockContract('nextHook');
    _attested(_next, IPolicyRegistry.AttestKind.HOOK, false);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_NotAttested.selector, _next, IPolicyRegistry.AttestKind.HOOK)
    );
    vm.prank(_admin);
    _token.installPolicy(_next, '');

    address _otherRegistry = makeAddr('otherRegistry');
    _attested(_next, IPolicyRegistry.AttestKind.HOOK, true);
    vm.mockCall(_next, abi.encodeCall(IComplianceHook.REGISTRY, ()), abi.encode(_otherRegistry));
    _mockPolicy(_next);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGatedCore.PolicyGated_HookRegistryMismatch.selector, _otherRegistry, _registry)
    );
    vm.prank(_admin);
    _token.installPolicy(_next, '');
  }

  function test_WhenTheCallerIsNotTheTimelock_ItCannotSetTheHook() external {
    vm.expectRevert(_unauthorized(_guardian, _token.DEFAULT_ADMIN_ROLE()));
    vm.prank(_guardian);
    _token.installPolicy(_hook, '');
  }

  function test_WhenUpgradedToAnAttestedImplementationOfTheSameTemplate_ItKeepsItsTokens() external {
    Gated721 _next = new Gated721();
    _attested(address(_next), IPolicyRegistry.AttestKind.IMPLEMENTATION, true);
    vm.prank(_upgrader);
    _token.upgradeToAndCall(address(_next), '');
    assertEq(_token.ownerOf(_ID), _alice);
    assertEq(_token.tokenURI(_ID), _URI);
  }

  function test_WhenTheImplementationIsNotAttested_TheUpgradeIsRefused() external {
    Gated721 _next = new Gated721();
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
        ITemplated.Templated_WrongTemplate.selector, address(_other), keccak256('Gated721'), keccak256('GatedToken')
      )
    );
    vm.prank(_upgrader);
    _token.upgradeToAndCall(address(_other), '');
  }

  function test_WhenTheCallerIsNotTheUpgrader_ItCannotUpgrade() external {
    Gated721 _next = new Gated721();
    vm.expectRevert(_unauthorized(_admin, _token.UPGRADER_ROLE()));
    vm.prank(_admin);
    _token.upgradeToAndCall(address(_next), '');
  }

  function test_WhenTheAgentBatchesCalls_MulticallRunsThemAsTheAgent() external {
    bytes[] memory _calls = new bytes[](2);
    _calls[0] = abi.encodeCall(Gated721.setFrozenTokens, (_alice, _ID, true));
    _calls[1] = abi.encodeCall(Gated721.forcedTransfer, (_alice, _bob, _ID));
    vm.prank(_agent);
    _token.multicall(_calls);
    assertEq(_token.ownerOf(_ID), _bob);
    assertFalse(_token.getFrozenTokens(_alice, _ID));
  }
}

contract Gated721Unit_Metadata is Gated721UnitTest {
  function test_WhenTheAgentSetsTheUri_ItEmitsMetadataUpdate() external {
    vm.expectEmit(address(_token));
    emit IERC4906.MetadataUpdate(_ID);
    vm.prank(_agent);
    _token.setTokenURI(_ID, 'ipfs://note-1-corrected');
    assertEq(_token.tokenURI(_ID), 'ipfs://note-1-corrected');
  }

  function test_WhenTheTokenDoesNotExist_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
    vm.prank(_agent);
    _token.setTokenURI(2, '');
  }

  function test_WhenTheCallerIsNotTheAgent_ItReverts() external {
    vm.expectRevert(_unauthorized(_alice, _token.AGENT_ROLE()));
    vm.prank(_alice);
    _token.setTokenURI(_ID, '');
  }
}

contract Gated721Unit_SupportsInterface is Gated721UnitTest {
  function test_WhenQueried_ItSupportsItsInterfacesAndNotTheFungibleOnes() external view {
    // ERC-7943 Final, non-fungible: the standard's own id, as a literal
    assertTrue(_token.supportsInterface(0xbf1ef5fe));
    assertEq(type(IERC7943NonFungible).interfaceId, bytes4(0xbf1ef5fe));
    assertTrue(_token.supportsInterface(type(IGated721).interfaceId));
    assertTrue(_token.supportsInterface(type(IPolicyGatedCore).interfaceId));
    assertTrue(_token.supportsInterface(type(IERC721).interfaceId));
    assertTrue(_token.supportsInterface(type(IERC721Metadata).interfaceId));
    assertTrue(_token.supportsInterface(bytes4(0x49064906))); // ERC-4906
    assertTrue(_token.supportsInterface(type(IAccessControl).interfaceId));
    assertTrue(_token.supportsInterface(type(IERC165).interfaceId));
    assertFalse(_token.supportsInterface(type(IPolicyGated).interfaceId));
    assertFalse(_token.supportsInterface(0x3edbb4c4)); // ERC-7943 fungible
    assertFalse(_token.supportsInterface(0xdeadbeef));
  }
}

/// @notice Drives holder transfers, freezes, forced transfers and burns for the invariant suite
contract Gated721Handler is Test {
  Gated721 internal immutable _TOKEN;
  address internal immutable _AGENT;
  address internal immutable _BURNER;
  address internal immutable _MINTER;
  address[3] internal _holders;

  /// @notice Times a holder's transfer succeeded although frozen, or failed although not
  uint256 public violations;

  constructor(
    Gated721 _token,
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
    uint256 _idSeed,
    uint256 _toSeed
  ) external {
    uint256 _tokenId = bound(_idSeed, 1, 5);
    address _owner = _TOKEN.ownerOf(_tokenId);
    address _to = _holders[bound(_toSeed, 0, 2)];
    bool _frozen = _TOKEN.getFrozenTokens(_owner, _tokenId);
    vm.prank(_owner);
    (bool _ok,) = address(_TOKEN).call(abi.encodeCall(IERC721.transferFrom, (_owner, _to, _tokenId)));
    if (_ok == _frozen) ++violations;
  }

  function setFrozen(
    uint256 _idSeed,
    uint256 _accountSeed,
    bool _frozenStatus
  ) external {
    vm.prank(_AGENT);
    _TOKEN.setFrozenTokens(_holders[bound(_accountSeed, 0, 2)], bound(_idSeed, 1, 5), _frozenStatus);
  }

  function force(
    uint256 _idSeed,
    uint256 _toSeed
  ) external {
    uint256 _tokenId = bound(_idSeed, 1, 5);
    address _owner = _TOKEN.ownerOf(_tokenId);
    vm.prank(_AGENT);
    _TOKEN.forcedTransfer(_owner, _holders[bound(_toSeed, 0, 2)], _tokenId);
    if (_TOKEN.getFrozenTokens(_owner, _tokenId)) ++violations;
  }

  function burnAndReissue(
    uint256 _idSeed,
    uint256 _toSeed
  ) external {
    uint256 _tokenId = bound(_idSeed, 1, 5);
    address _owner = _TOKEN.ownerOf(_tokenId);
    vm.prank(_BURNER);
    _TOKEN.burn(_tokenId);
    if (_TOKEN.getFrozenTokens(_owner, _tokenId)) ++violations;
    vm.prank(_MINTER);
    _TOKEN.mint(_holders[bound(_toSeed, 0, 2)], _tokenId, '');
  }
}

contract Gated721Invariant_FrozenTokens is Gated721UnitTest {
  Gated721Handler internal _handler;

  function setUp() public override {
    super.setUp();
    address[3] memory _accounts = [_alice, _bob, _carol];
    for (uint256 _i = 2; _i <= 5; ++_i) {
      vm.prank(_minter);
      _token.mint(_accounts[_i % 3], _i, '');
    }
    _handler = new Gated721Handler(_token, _agent, _burner, _minter, _accounts);
    targetContract(address(_handler));
  }

  /// @dev A holder can move exactly its unfrozen tokens, and an enforcement action always clears the freeze it takes
  function invariant_AHolderMovesExactlyItsUnfrozenTokens() external view {
    assertEq(_handler.violations(), 0);
  }
}

/// @notice The real hook and rules, deployed through `ProxyDeployer` as a product is
contract Gated721IntegrationTest is Test {
  Gated721 internal _nft;
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
    Gated721 _impl = new Gated721();
    _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');

    IComplianceRule[] memory _rules = new IComplianceRule[](2);
    _rules[0] = _credentialRule;
    _rules[1] = _restrictionRule;
    ProxyDeployer _proxyDeployer = new ProxyDeployer(address(this), _registry);
    _nft = Gated721(
      _proxyDeployer.deploy(
        'gNOTE',
        address(_impl),
        abi.encodeCall(
          Gated721.initialize,
          ('Gated Note', 'gNOTE', address(this), _guardian, address(_registry), address(_hook), _rules)
        ),
        address(_hook),
        _rules
      )
    );
    _credentialRule.setPolicy(address(_nft), Quals.KYC, 0, 0, 1);
    _nft.grantRole(_nft.MINTER_ROLE(), _minter);
    _nft.grantRole(_nft.BURNER_ROLE(), _burner);
    _nft.grantRole(_nft.AGENT_ROLE(), _agent);

    vm.startPrank(_kyc);
    _creds.set(_alice, uint64(block.timestamp + 365 days), Quals.KYC);
    _creds.set(_bob, uint64(block.timestamp + 365 days), Quals.KYC);
    vm.stopPrank();
    vm.prank(_minter);
    _nft.mint(_alice, _ID, 'ipfs://note-1');
  }

  function _transferWithParity(
    address _from,
    address _to,
    uint256 _tokenId
  ) internal returns (bool _ok, bytes32 _reason) {
    (_ok, _reason) = _nft.canTransferWithReason(_from, _to, _tokenId);
    if (!_ok) vm.expectRevert(abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, _reason));
    vm.prank(_from);
    _nft.transferFrom(_from, _to, _tokenId);
  }
}

contract Gated721Integration_Rules is Gated721IntegrationTest {
  function test_WhenDeployed_TheHookHoldsTheProductsRules() external view {
    assertEq(_nft.policy(), address(_hook));
    assertEq(_hook.ruleCount(address(_nft)), 2);
  }

  function test_WhenBothPartiesAreVerified_TheTransferSucceedsAndPreflightAgrees() external {
    (bool _ok,) = _transferWithParity(_alice, _bob, _ID);
    assertTrue(_ok);
    assertEq(_nft.ownerOf(_ID), _bob);
  }

  function test_WhenTheReceiverIsNotVerified_TheTransferAndTheMintAreRefused() external {
    assertFalse(_nft.canReceive(_eve));
    (bool _ok, bytes32 _reason) = _transferWithParity(_alice, _eve, _ID);
    assertFalse(_ok);
    assertEq(_reason, Reasons.RECEIVER_NOT_VERIFIED);

    vm.expectRevert(abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_minter);
    _nft.mint(_eve, 2, '');
  }

  function test_WhenTheHolderIsLocked_ItCannotSendAndTheAgentCanStillForce() external {
    vm.prank(_agent);
    _restrictionRule.setLockup(address(_nft), _alice, block.timestamp + 30 days);
    assertFalse(_nft.canSend(_alice));
    (bool _ok, bytes32 _reason) = _transferWithParity(_alice, _bob, _ID);
    assertFalse(_ok);
    assertEq(_reason, Reasons.LOCKED_UP);

    vm.prank(_agent);
    _nft.forcedTransfer(_alice, _bob, _ID);
    assertEq(_nft.ownerOf(_ID), _bob);
  }

  function test_WhenTheReceiverIsFrozenByTheRule_ItCannotReceiveEvenByForce() external {
    vm.prank(_agent);
    _restrictionRule.setFrozen(address(_nft), _bob, true);
    assertFalse(_nft.canReceive(_bob));
    (bool _ok, bytes32 _reason) = _transferWithParity(_alice, _bob, _ID);
    assertFalse(_ok);
    assertEq(_reason, Reasons.RECEIVER_FROZEN);

    vm.expectRevert(abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, Reasons.RECEIVER_FROZEN));
    vm.prank(_agent);
    _nft.forcedTransfer(_alice, _bob, _ID);
  }

  function test_WhenTheAgentForcesToAnUnverifiedAccount_ItIsRefused() external {
    vm.expectRevert(abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_agent);
    _nft.forcedTransfer(_alice, _eve, _ID);
  }

  function test_WhenTheHolderIsLocked_TheBurnerCanStillBurn() external {
    vm.prank(_agent);
    _restrictionRule.setLockup(address(_nft), _alice, block.timestamp + 30 days);
    // The pre-flight answers for a holder's burn, whoever asks; the burner's burn is FORCED and is not predicted.
    vm.prank(_burner);
    (, bytes32 _askedByTheBurner) = _nft.canTransferWithReason(_alice, address(0), _ID);
    assertEq(_askedByTheBurner, Reasons.LOCKED_UP);
    vm.prank(_alice);
    (, bytes32 _reason) = _nft.canTransferWithReason(_alice, address(0), _ID);
    assertEq(_reason, Reasons.LOCKED_UP);
    vm.prank(_burner);
    _nft.burn(_ID);
    assertEq(_nft.balanceOf(_alice), 0);
  }
}
