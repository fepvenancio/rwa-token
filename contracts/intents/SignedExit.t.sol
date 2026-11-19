// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Vm} from 'forge-std/Vm.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IERC8473} from 'interfaces/IERC8473.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {IGatedVaultBase} from 'interfaces/IGatedVaultBase.sol';
import {ISignedExit} from 'interfaces/ISignedExit.sol';
import {Quals} from 'interfaces/Quals.sol';

import {SignedEntryTest} from 'contracts/intents/SignedEntry.t.sol';
import {SignedExit} from 'contracts/intents/SignedExit.sol';
import {MockPermitAsset} from 'contracts/test/MockPermitAsset.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';
import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';

/// @notice Real vaults behind the real credential registry, rule and hook, as in `SignedEntryTest`. The investor holds
///         shares; a relayer submits what it signed
contract SignedExitTest is SignedEntryTest {
  SignedExit internal _exits;
  MockPermitAsset internal _asset;
  address internal _other = makeAddr('other');
  address internal _settler = makeAddr('settler');
  address internal _cash = makeAddr('cash');

  function setUp() public virtual override {
    super.setUp();
    _exits = new SignedExit();
    _asset = new MockPermitAsset();
    _asset.mint(_investor, 10 * _ASSETS);
  }

  function _exit(
    address _vault,
    uint256 _shares,
    bool _asynchronous
  ) internal view returns (ISignedExit.Exit memory _e) {
    _e = ISignedExit.Exit({
      holder: _investor,
      vault: _vault,
      shares: _shares,
      receiver: _investor,
      minAssets: 0,
      asynchronous: _asynchronous,
      nonce: keccak256('an exit'),
      validAfter: 0,
      deadline: block.timestamp + 1 hours
    });
  }

  function _signExit(
    ISignedExit.Exit memory _e
  ) internal view returns (bytes memory _sig) {
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_investorKey, _exits.exitHash(_e));
    _sig = abi.encodePacked(_r, _s, _v);
  }

  /// @dev The investor's `permit` on the share token, for the exit contract to take the shares
  function _signShares(
    address _vault,
    uint256 _shares,
    uint256 _deadline
  ) internal view returns (uint8 _v, bytes32 _r, bytes32 _s) {
    MockPermitAsset _shareToken = MockPermitAsset(_vault); // only for the ERC-2612 views
    bytes32 _structHash = keccak256(
      abi.encode(_PERMIT_TYPEHASH, _investor, address(_exits), _shares, _shareToken.nonces(_investor), _deadline)
    );
    (_v, _r, _s) =
      vm.sign(_investorKey, keccak256(abi.encodePacked('\x19\x01', _shareToken.DOMAIN_SEPARATOR(), _structHash)));
  }

  function _run(
    ISignedExit.Exit memory _e
  ) internal returns (uint256 _assets) {
    bytes memory _sig = _signExit(_e);
    (uint8 _v, bytes32 _r, bytes32 _s) = _signShares(_e.vault, _e.shares, _e.deadline);
    vm.prank(_relayer);
    _assets = _exits.exitWithPermit(_e, _sig, _v, _r, _s);
  }

  /// @dev A 4626 vault in which the investor holds the shares of `_ASSETS`
  function _held4626() internal returns (Gated4626Vault _vault, uint256 _shares) {
    _vault = _vault4626(address(_asset));
    vm.startPrank(_investor);
    _asset.approve(address(_vault), _ASSETS);
    _shares = _vault.deposit(_ASSETS, _investor);
    vm.stopPrank();
  }

  function _settle(
    Gated7540Vault _vault,
    uint256 _nav
  ) internal {
    vm.startPrank(_settler);
    _vault.closePeriod();
    _vault.settlePeriod(_nav, 0, _cash, address(0), type(uint256).max);
    vm.stopPrank();
  }

  /// @dev A 7540 vault with a settler, and a cash account that funds redemptions
  function _async() internal returns (Gated7540Vault _vault) {
    _vault = _vault7540(address(_asset));
    _vault.grantRole(_vault.SETTLER_ROLE(), _settler);
    vm.prank(_cash);
    _asset.approve(address(_vault), type(uint256).max);
  }

  function _requestDeposit(
    Gated7540Vault _vault,
    address _who,
    uint256 _assets
  ) internal {
    if (_who != _investor) {
      _credential(_who);
      _asset.mint(_who, _assets);
    }
    vm.startPrank(_who);
    _asset.approve(address(_vault), _assets);
    _vault.requestDeposit(_assets, _who, _who);
    vm.stopPrank();
  }

  function _makeOperator(
    Gated7540Vault _vault,
    address _controller
  ) internal {
    vm.prank(_controller);
    _vault.setOperator(address(_exits), true);
  }

  function _one(
    address _controller
  ) internal pure returns (address[] memory _list) {
    _list = new address[](1);
    _list[0] = _controller;
  }
}

contract SignedExit_Redeem4626 is SignedExitTest {
  function test_ARelayerSubmitsAndTheCashGoesToTheSignedReceiver() external {
    (Gated4626Vault _vault, uint256 _shares) = _held4626();
    ISignedExit.Exit memory _e = _exit(address(_vault), _shares, false);
    uint256 _before = _asset.balanceOf(_investor);

    vm.expectEmit(address(_exits));
    emit ISignedExit.ExitExecuted(_exits.exitHash(_e), _investor, address(_vault), _shares, _ASSETS);
    assertEq(_run(_e), _ASSETS);
    assertEq(_asset.balanceOf(_investor), _before + _ASSETS);
    assertEq(_vault.balanceOf(_investor), 0);
    assertEq(_asset.balanceOf(_relayer), 0);
    assertEq(_asset.balanceOf(address(_exits)), 0);
    assertEq(_vault.balanceOf(address(_exits)), 0);
    assertTrue(_exits.nonceUsed(_investor, _e.nonce));
  }

  /// @dev A receiver the holder names and the policy accepts
  function test_TheHolderCanNameAnotherEligibleReceiver() external {
    (Gated4626Vault _vault, uint256 _shares) = _held4626();
    _credential(_other);
    ISignedExit.Exit memory _e = _exit(address(_vault), _shares, false);
    _e.receiver = _other;
    assertEq(_run(_e), _ASSETS);
    assertEq(_asset.balanceOf(_other), _ASSETS);
  }

  /// @dev The vault's own third-party check still applies: the lego is no way around the policy
  function test_AReceiverThePolicyRefusesIsRefusedByTheVault() external {
    (Gated4626Vault _vault, uint256 _shares) = _held4626();
    ISignedExit.Exit memory _e = _exit(address(_vault), _shares, false);
    _e.receiver = _other; // no credential
    bytes memory _sig = _signExit(_e);
    (uint8 _v, bytes32 _r, bytes32 _s) = _signShares(_e.vault, _e.shares, _e.deadline);
    vm.expectRevert(
      abi.encodeWithSelector(
        IGatedVaultBase.GatedVault_ThirdPartyNotEligible.selector, _other, Reasons.RECEIVER_NOT_VERIFIED
      )
    );
    vm.prank(_relayer);
    _exits.exitWithPermit(_e, _sig, _v, _r, _s);
  }

  /// @dev Whoever submits can change nothing the holder signed
  function test_ARelayerCannotChangeTheReceiverTheMinimumOrTheShares() external {
    (Gated4626Vault _vault, uint256 _shares) = _held4626();
    _credential(_relayer);
    ISignedExit.Exit memory _e = _exit(address(_vault), _shares, false);
    _e.minAssets = _ASSETS;
    bytes memory _sig = _signExit(_e);
    (uint8 _v, bytes32 _r, bytes32 _s) = _signShares(_e.vault, _e.shares, _e.deadline);

    ISignedExit.Exit memory _toRelayer = _exit(address(_vault), _shares, false);
    _toRelayer.minAssets = _ASSETS;
    _toRelayer.receiver = _relayer;
    vm.expectRevert(ISignedExit.SignedExit_BadSignature.selector);
    vm.prank(_relayer);
    _exits.exitWithPermit(_toRelayer, _sig, _v, _r, _s);

    ISignedExit.Exit memory _noFloor = _exit(address(_vault), _shares, false);
    vm.expectRevert(ISignedExit.SignedExit_BadSignature.selector);
    vm.prank(_relayer);
    _exits.exitWithPermit(_noFloor, _sig, _v, _r, _s);

    ISignedExit.Exit memory _fewer = _exit(address(_vault), _shares - 1, false);
    _fewer.minAssets = _ASSETS;
    vm.expectRevert(ISignedExit.SignedExit_BadSignature.selector);
    vm.prank(_relayer);
    _exits.exitWithPermit(_fewer, _sig, _v, _r, _s);
    assertEq(_vault.balanceOf(_investor), _shares);
  }

  function test_FewerAssetsThanAcceptedIsRefusedAndNothingMoves() external {
    (Gated4626Vault _vault, uint256 _shares) = _held4626();
    ISignedExit.Exit memory _e = _exit(address(_vault), _shares, false);
    _e.minAssets = _ASSETS + 1;
    bytes memory _sig = _signExit(_e);
    (uint8 _v, bytes32 _r, bytes32 _s) = _signShares(_e.vault, _e.shares, _e.deadline);
    vm.expectRevert(abi.encodeWithSelector(ISignedExit.SignedExit_TooFewAssets.selector, _ASSETS + 1, _ASSETS));
    vm.prank(_relayer);
    _exits.exitWithPermit(_e, _sig, _v, _r, _s);
    assertEq(_vault.balanceOf(_investor), _shares);
    assertFalse(_exits.nonceUsed(_investor, _e.nonce));
  }

  function test_ExactlyTheMinimumPasses() external {
    (Gated4626Vault _vault, uint256 _shares) = _held4626();
    ISignedExit.Exit memory _e = _exit(address(_vault), _shares, false);
    _e.minAssets = _ASSETS;
    assertEq(_run(_e), _ASSETS);
  }

  function test_AReplayIsRefused() external {
    (Gated4626Vault _vault, uint256 _shares) = _held4626();
    ISignedExit.Exit memory _e = _exit(address(_vault), _shares / 2, false);
    bytes memory _sig = _signExit(_e);
    (uint8 _v, bytes32 _r, bytes32 _s) = _signShares(_e.vault, _e.shares, _e.deadline);
    vm.prank(_relayer);
    _exits.exitWithPermit(_e, _sig, _v, _r, _s);
    vm.expectRevert(ISignedExit.SignedExit_NonceUsed.selector);
    vm.prank(_stranger);
    _exits.exitWithPermit(_e, _sig, _v, _r, _s);
    assertEq(_vault.balanceOf(_investor), _shares - _shares / 2);
  }

  function test_BeforeItsWindowAndAfterItsDeadlineItIsRefused() external {
    (Gated4626Vault _vault, uint256 _shares) = _held4626();
    ISignedExit.Exit memory _e = _exit(address(_vault), _shares, false);
    _e.validAfter = block.timestamp + 10;
    bytes memory _sig = _signExit(_e);
    (uint8 _v, bytes32 _r, bytes32 _s) = _signShares(_e.vault, _e.shares, _e.deadline);
    vm.expectRevert(ISignedExit.SignedExit_NotYetValid.selector);
    _exits.exitWithPermit(_e, _sig, _v, _r, _s);
    vm.warp(_e.deadline + 1);
    vm.expectRevert(ISignedExit.SignedExit_Expired.selector);
    _exits.exitWithPermit(_e, _sig, _v, _r, _s);
  }

  function test_ACancelledExitIsRefusedAndOnlyItsHolderCancels() external {
    (Gated4626Vault _vault, uint256 _shares) = _held4626();
    ISignedExit.Exit memory _e = _exit(address(_vault), _shares, false);
    vm.prank(_stranger);
    _exits.cancelExit(_e.nonce);
    assertFalse(_exits.nonceUsed(_investor, _e.nonce));

    vm.expectEmit(address(_exits));
    emit ISignedExit.ExitCancelled(_investor, _e.nonce);
    vm.prank(_investor);
    _exits.cancelExit(_e.nonce);
    vm.expectRevert(ISignedExit.SignedExit_NonceUsed.selector);
    vm.prank(_investor);
    _exits.cancelExit(_e.nonce);

    bytes memory _sig = _signExit(_e);
    (uint8 _v, bytes32 _r, bytes32 _s) = _signShares(_e.vault, _e.shares, _e.deadline);
    vm.expectRevert(ISignedExit.SignedExit_NonceUsed.selector);
    _exits.exitWithPermit(_e, _sig, _v, _r, _s);
  }

  /// @dev Anyone can submit the signed permit first; the exit must still run on the allowance it left
  function test_APermitSubmittedFirstDoesNotStopTheExit() external {
    (Gated4626Vault _vault, uint256 _shares) = _held4626();
    ISignedExit.Exit memory _e = _exit(address(_vault), _shares, false);
    bytes memory _sig = _signExit(_e);
    (uint8 _v, bytes32 _r, bytes32 _s) = _signShares(_e.vault, _e.shares, _e.deadline);
    vm.prank(_stranger);
    _vault.permit(_investor, address(_exits), _shares, _e.deadline, _v, _r, _s);
    vm.prank(_relayer);
    assertEq(_exits.exitWithPermit(_e, _sig, _v, _r, _s), _ASSETS);
  }

  /// @dev A nonce is one bit of a word, as in the signed entry
  function test_WhenAHolderUsesTheNoncesOfOneWord_TheyShareOneStorageSlot() external {
    uint256 _word = uint256(keccak256('a word')) << 8;
    vm.record();
    vm.startPrank(_investor);
    for (uint256 _bit; _bit < 256; ++_bit) {
      _exits.cancelExit(bytes32(_word | _bit));
    }
    vm.stopPrank();
    (, bytes32[] memory _writes) = vm.accesses(address(_exits));
    assertEq(_writes.length, 256);
    for (uint256 _i = 1; _i < _writes.length; ++_i) {
      assertEq(_writes[_i], _writes[0], 'one slot for the whole word');
    }
  }
}

contract SignedExit_Request7540 is SignedExitTest {
  Gated7540Vault internal _vault;
  uint256 internal _shares;

  function setUp() public override {
    super.setUp();
    _vault = _async();
    _requestDeposit(_vault, _investor, _ASSETS);
    _settle(_vault, 0);
    _shares = _ASSETS * _PAR;
    vm.prank(_investor);
    _vault.mint(_shares, _investor, _investor);
  }

  function test_ARelayerFilesTheRequestWithTheHolderAsController() external {
    ISignedExit.Exit memory _e = _exit(address(_vault), _shares, true);
    vm.expectEmit(address(_exits));
    emit ISignedExit.ExitExecuted(_exits.exitHash(_e), _investor, address(_vault), _shares, 0);
    assertEq(_run(_e), 0);
    assertEq(_vault.pendingRedeemRequest(0, _investor), _shares);
    assertEq(_vault.balanceOf(_investor), 0);
    assertEq(_vault.pendingRedeemRequest(0, address(_exits)), 0);
    assertEq(_vault.pendingRedeemRequest(0, _relayer), 0);
  }

  function test_ARequestNamingAMinimumIsRefused() external {
    ISignedExit.Exit memory _e = _exit(address(_vault), _shares, true);
    _e.minAssets = 1;
    bytes memory _sig = _signExit(_e);
    (uint8 _v, bytes32 _r, bytes32 _s) = _signShares(_e.vault, _e.shares, _e.deadline);
    vm.expectRevert(ISignedExit.SignedExit_MinimumOnARequest.selector);
    _exits.exitWithPermit(_e, _sig, _v, _r, _s);
  }

  function test_ARequestNamingAnotherReceiverIsRefused() external {
    ISignedExit.Exit memory _e = _exit(address(_vault), _shares, true);
    _e.receiver = _other;
    bytes memory _sig = _signExit(_e);
    (uint8 _v, bytes32 _r, bytes32 _s) = _signShares(_e.vault, _e.shares, _e.deadline);
    vm.expectRevert(ISignedExit.SignedExit_ReceiverOnARequest.selector);
    _exits.exitWithPermit(_e, _sig, _v, _r, _s);
  }
}

contract SignedExit_ClaimFor is SignedExitTest {
  Gated7540Vault internal _vault;
  address internal _second = makeAddr('second');

  function setUp() public override {
    super.setUp();
    _vault = _async();
  }

  function _two() internal view returns (address[] memory _list) {
    _list = new address[](2);
    _list[0] = _investor;
    _list[1] = _second;
  }

  /// @dev Both controllers have a settled deposit to claim
  function _twoSettledDeposits() internal {
    _requestDeposit(_vault, _investor, _ASSETS);
    _requestDeposit(_vault, _second, _ASSETS);
    _settle(_vault, 0);
  }

  function test_AnyoneDeliversTheSharesOfASettledDepositToItsController() external {
    _twoSettledDeposits();
    _makeOperator(_vault, _investor);
    _makeOperator(_vault, _second);
    uint256 _shares = _ASSETS * _PAR;

    vm.expectEmit(address(_exits));
    emit ISignedExit.ClaimDelivered(address(_vault), _investor, true, _shares);
    vm.expectEmit(address(_exits));
    emit ISignedExit.ClaimDelivered(address(_vault), _second, true, _shares);
    vm.prank(_stranger);
    assertEq(_exits.claimFor(address(_vault), _two()), 2);
    assertEq(_vault.balanceOf(_investor), _shares);
    assertEq(_vault.balanceOf(_second), _shares);
    assertEq(_vault.balanceOf(_stranger), 0);
    assertEq(_vault.balanceOf(address(_exits)), 0);
    assertEq(_vault.claimableDepositRequest(0, _investor), 0);
  }

  function test_AnyoneDeliversTheCashOfASettledRedemptionToItsController() external {
    _twoSettledDeposits();
    uint256 _shares = _ASSETS * _PAR;
    vm.startPrank(_investor);
    _vault.mint(_shares, _investor, _investor);
    _vault.requestRedeem(_shares, _investor, _investor);
    vm.stopPrank();
    _settle(_vault, 2 * _ASSETS); // par: two investors' worth of assets for two investors' worth of shares
    _makeOperator(_vault, _investor);
    uint256 _before = _asset.balanceOf(_investor);
    uint256 _owed = _vault.maxWithdraw(_investor);
    assertGt(_owed, 0);

    vm.expectEmit(address(_exits));
    emit ISignedExit.ClaimDelivered(address(_vault), _investor, false, _owed);
    vm.prank(_stranger);
    assertEq(_exits.claimFor(address(_vault), _one(_investor)), 1);
    assertEq(_asset.balanceOf(_investor), _before + _owed);
    assertEq(_asset.balanceOf(_stranger), 0);
    assertEq(_asset.balanceOf(address(_exits)), 0);
    assertEq(_vault.claimableRedeemRequest(0, _investor), 0);
  }

  /// @dev A controller that gave no leave is passed over, with the vault's own error in the event, and the other is served
  function test_AControllerThatDidNotAllowItIsPassedOverAndTheOthersAreServed() external {
    _twoSettledDeposits();
    _makeOperator(_vault, _second);
    vm.recordLogs();
    assertEq(_exits.claimFor(address(_vault), _two()), 1);
    assertEq(_vault.balanceOf(_investor), 0);
    assertEq(_vault.balanceOf(_second), _ASSETS * _PAR);
    assertEq(_vault.claimableDepositRequest(0, _investor), _ASSETS, 'the claim stays with the vault');

    Vm.Log[] memory _logs = vm.getRecordedLogs();
    bool _skipped;
    for (uint256 _i; _i < _logs.length; ++_i) {
      if (_logs[_i].emitter != address(_exits) || _logs[_i].topics[0] != ISignedExit.ClaimSkipped.selector) continue;
      assertEq(address(uint160(uint256(_logs[_i].topics[2]))), _investor);
      (bool _isDeposit, bytes memory _reason) = abi.decode(_logs[_i].data, (bool, bytes));
      assertTrue(_isDeposit);
      assertEq(_reason, abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_Unauthorized.selector, address(_exits)));
      _skipped = true;
    }
    assertTrue(_skipped, 'no ClaimSkipped for the first controller');
  }

  /// @dev A controller the policy does not let receive now does not hold back the others
  function test_AControllerThePolicyRefusesIsPassedOverAndTheOthersAreServed() external {
    _twoSettledDeposits();
    _makeOperator(_vault, _investor);
    _makeOperator(_vault, _second);
    vm.prank(_guardian);
    _creds.blockSubject(_investor);

    assertEq(_exits.claimFor(address(_vault), _two()), 1);
    assertEq(_vault.balanceOf(_investor), 0);
    assertEq(_vault.balanceOf(_second), _ASSETS * _PAR);
    assertEq(_vault.claimableDepositRequest(0, _investor), _ASSETS);

    _creds.clearGuardianBlock(_investor);
    assertEq(_exits.claimFor(address(_vault), _two()), 1);
    assertEq(_vault.balanceOf(_investor), _ASSETS * _PAR);
  }

  /// @dev On a 7540 the vault's three-argument `redeem` is a claim. So an exit signed as synchronous for a 7540 is a
  ///      signed claim of settled cash to the signed receiver: it needs the holder's signature and the holder's leave
  ///      as operator, and the vault still judges the receiver
  function test_OnA7540ASynchronousExitIsASignedClaimThatNeedsTheHoldersLeave() external {
    _twoSettledDeposits();
    uint256 _shares = _ASSETS * _PAR;
    vm.startPrank(_investor);
    _vault.mint(_shares, _investor, _investor);
    _vault.requestRedeem(_shares, _investor, _investor);
    vm.stopPrank();
    _settle(_vault, 2 * _ASSETS);
    uint256 _owed = _vault.maxWithdraw(_investor);
    _credential(_other);

    ISignedExit.Exit memory _e = _exit(address(_vault), _vault.claimableRedeemRequest(0, _investor), false);
    _e.receiver = _other;
    _e.minAssets = _owed;
    bytes memory _sig = _signExit(_e);
    (uint8 _v, bytes32 _r, bytes32 _s) = _signShares(_e.vault, _e.shares, _e.deadline);

    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_Unauthorized.selector, address(_exits)));
    vm.prank(_relayer);
    _exits.exitWithPermit(_e, _sig, _v, _r, _s);

    _makeOperator(_vault, _investor);
    vm.prank(_relayer);
    assertEq(_exits.exitWithPermit(_e, _sig, _v, _r, _s), _owed);
    assertEq(_asset.balanceOf(_other), _owed);
    assertEq(_asset.balanceOf(_relayer), 0);
    assertEq(_vault.claimableRedeemRequest(0, _investor), 0);
  }

  function test_WithNothingToClaimNothingHappens() external {
    _makeOperator(_vault, _investor);
    vm.recordLogs();
    assertEq(_exits.claimFor(address(_vault), _two()), 0);
    assertEq(vm.getRecordedLogs().length, 0);
  }

  /// @dev Being an operator lets the contract do much under ERC-7540. It offers one thing without a signature: a claim
  ///      to the controller itself. A request still pending is left alone, and no request is filed
  function test_ItLeavesAPendingRequestAloneAndFilesNone() external {
    _requestDeposit(_vault, _investor, _ASSETS);
    _makeOperator(_vault, _investor);
    assertEq(_exits.claimFor(address(_vault), _one(_investor)), 0);
    assertEq(_vault.pendingDepositRequest(0, _investor), _ASSETS);
    assertEq(_vault.pendingRedeemRequest(0, _investor), 0);
    assertEq(_asset.balanceOf(address(_exits)), 0);
  }
}

contract SignedExit_Hash is SignedExitTest {
  function test_TheHashIsTheEip712DigestOfTheExit() external view {
    ISignedExit.Exit memory _e = _exit(address(0xBEEF), 7, false);
    bytes32 _structHash = keccak256(
      abi.encode(
        keccak256(
          'Exit(address holder,address vault,uint256 shares,address receiver,uint256 minAssets,bool asynchronous,bytes32 nonce,uint256 validAfter,uint256 deadline)'
        ),
        _e.holder,
        _e.vault,
        _e.shares,
        _e.receiver,
        _e.minAssets,
        _e.asynchronous,
        _e.nonce,
        _e.validAfter,
        _e.deadline
      )
    );
    bytes32 _domain = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
        keccak256('SignedExit'),
        keccak256('1'),
        block.chainid,
        address(_exits)
      )
    );
    assertEq(_exits.exitHash(_e), keccak256(abi.encodePacked('\x19\x01', _domain, _structHash)));
  }
}
