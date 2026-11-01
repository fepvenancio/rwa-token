// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {IGatedVaultBase} from 'interfaces/IGatedVaultBase.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ISignedEntry} from 'interfaces/ISignedEntry.sol';
import {Quals} from 'interfaces/Quals.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {CredentialRule} from 'contracts/hooks/rules/CredentialRule.sol';
import {CredentialRegistry} from 'contracts/identity/CredentialRegistry.sol';
import {SignedEntry} from 'contracts/intents/SignedEntry.sol';
import {MockERC1271Wallet} from 'contracts/test/MockERC1271Wallet.sol';
import {MockERC3009Token} from 'contracts/test/MockERC3009Token.sol';
import {MockPermitAsset} from 'contracts/test/MockPermitAsset.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';
import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';

abstract contract SignedEntryTest is Test {
  uint256 internal constant _NOW = 1_792_198_800;
  uint256 internal constant _ASSETS = 1000e6;
  uint256 internal constant _PAR = 1e6;
  bytes32 internal constant _ENTRY_TYPEHASH = keccak256(
    'Entry(address investor,address vault,uint256 assets,uint256 minShares,bool asynchronous,bytes32 nonce,uint256 validAfter,uint256 deadline)'
  );
  bytes32 internal constant _PERMIT_TYPEHASH =
    keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)');

  PolicyRegistry internal _registry;
  CredentialRegistry internal _creds;
  CredentialRule internal _rule;
  ComplianceHook internal _hook;
  ProxyDeployer internal _deployer;
  SignedEntry internal _router;
  address internal _investor;
  uint256 internal _investorKey;
  address internal _relayer = makeAddr('relayer');
  address internal _stranger = makeAddr('stranger');
  address internal _guardian = makeAddr('guardian');
  uint256 internal _salt;

  function setUp() public virtual {
    vm.warp(_NOW);
    (_investor, _investorKey) = makeAddrAndKey('investor');
    _registry = new PolicyRegistry(address(this), address(this));
    _creds = new CredentialRegistry(address(this), _guardian);
    _creds.addAttester(address(this), type(uint32).max);
    _rule = new CredentialRule(_creds);
    _registry.attest(address(_rule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _hook = new ComplianceHook(_registry);
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _deployer = new ProxyDeployer(address(this), _registry);
    _router = new SignedEntry();
    _credential(_investor);
    _credential(address(_router));
  }

  function _credential(
    address _who
  ) internal {
    _creds.set(_who, uint64(block.timestamp + 3650 days), Quals.KYC, 756);
  }

  function _rules() internal view returns (IComplianceRule[] memory _list) {
    _list = new IComplianceRule[](1);
    _list[0] = _rule;
  }

  function _vault4626(
    address _asset
  ) internal returns (Gated4626Vault _vault) {
    Gated4626Vault _impl = new Gated4626Vault();
    if (_registry.kindOf(address(_impl).codehash) == IPolicyRegistry.AttestKind.NONE) {
      _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    }
    string memory _symbol = string(abi.encodePacked('v', vm.toString(++_salt)));
    _vault = Gated4626Vault(
      _deployer.deploy(
        _symbol,
        address(_impl),
        abi.encodeCall(
          Gated4626Vault.initialize,
          (IERC20(_asset), 'Fund', _symbol, address(this), _guardian, address(_registry), address(_hook), _rules())
        ),
        address(_hook),
        _rules()
      )
    );
    _rule.setPolicy(address(_vault), Quals.KYC, 0, 0, 1);
  }

  function _vault7540(
    address _asset
  ) internal returns (Gated7540Vault _vault) {
    Gated7540Vault _impl = new Gated7540Vault();
    if (_registry.kindOf(address(_impl).codehash) == IPolicyRegistry.AttestKind.NONE) {
      _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    }
    string memory _symbol = string(abi.encodePacked('a', vm.toString(++_salt)));
    _vault = Gated7540Vault(
      _deployer.deploy(
        _symbol,
        address(_impl),
        abi.encodeCall(
          Gated7540Vault.initialize,
          (IERC20(_asset), 'Fund', _symbol, address(this), _guardian, address(_registry), address(_hook), _rules())
        ),
        address(_hook),
        _rules()
      )
    );
    _rule.setPolicy(address(_vault), Quals.KYC, 0, 0, 1);
  }

  function _entry(
    address _vault,
    bool _asynchronous
  ) internal view returns (ISignedEntry.Entry memory _e) {
    _e = ISignedEntry.Entry({
      investor: _investor,
      vault: _vault,
      assets: _ASSETS,
      minShares: 0,
      asynchronous: _asynchronous,
      nonce: keccak256('a nonce'),
      validAfter: 0,
      deadline: block.timestamp + 1 hours
    });
  }

  function _sign(
    ISignedEntry.Entry memory _e
  ) internal view returns (bytes memory _sig) {
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_investorKey, _router.entryHash(_e));
    _sig = abi.encodePacked(_r, _s, _v);
  }
}

contract SignedEntry_Permit is SignedEntryTest {
  MockPermitAsset internal _asset;
  Gated4626Vault internal _vault;
  uint8 internal _v;
  bytes32 internal _r;
  bytes32 internal _s;

  function setUp() public override {
    super.setUp();
    _asset = new MockPermitAsset();
    _vault = _vault4626(address(_asset));
    _asset.mint(_investor, 10 * _ASSETS);
    (_v, _r, _s) = _signPermit(_ASSETS, block.timestamp + 1 hours);
  }

  function _signPermit(
    uint256 _value,
    uint256 _deadline
  ) internal view returns (uint8 _permitV, bytes32 _permitR, bytes32 _permitS) {
    bytes32 _structHash =
      keccak256(abi.encode(_PERMIT_TYPEHASH, _investor, address(_router), _value, _asset.nonces(_investor), _deadline));
    bytes32 _digest = keccak256(abi.encodePacked('\x19\x01', _asset.DOMAIN_SEPARATOR(), _structHash));
    (_permitV, _permitR, _permitS) = vm.sign(_investorKey, _digest);
  }

  function _enter(
    ISignedEntry.Entry memory _e
  ) internal returns (uint256 _shares) {
    bytes memory _sig = _sign(_e);
    vm.prank(_relayer);
    _shares = _router.enterWithPermit(_e, _sig, _v, _r, _s);
  }

  function test_TheHashIsTheOneTheInvestorSigns() external view {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    bytes32 _domain = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
        keccak256('SignedEntry'),
        keccak256('1'),
        block.chainid,
        address(_router)
      )
    );
    bytes32 _struct = keccak256(
      abi.encode(
        _ENTRY_TYPEHASH,
        _e.investor,
        _e.vault,
        _e.assets,
        _e.minShares,
        _e.asynchronous,
        _e.nonce,
        _e.validAfter,
        _e.deadline
      )
    );
    assertEq(_router.entryHash(_e), keccak256(abi.encodePacked('\x19\x01', _domain, _struct)));
  }

  function test_ARelayerSubmitsAndTheInvestorGetsTheShares() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    bytes32 _hash = _router.entryHash(_e);
    uint256 _expected = _vault.previewDeposit(_ASSETS);
    vm.expectEmit(address(_router));
    emit ISignedEntry.EntryExecuted(_hash, _investor, address(_vault), _ASSETS, _expected);
    assertEq(_enter(_e), _expected);
    assertEq(_vault.balanceOf(_investor), _expected);
    assertEq(_asset.balanceOf(_investor), 9 * _ASSETS);
    assertEq(_asset.balanceOf(address(_vault)), _ASSETS);
    assertTrue(_router.nonceUsed(_investor, _e.nonce));
  }

  function test_ItHoldsNothingAfterwards() external {
    _enter(_entry(address(_vault), false));
    assertEq(_asset.balanceOf(address(_router)), 0);
    assertEq(_asset.allowance(address(_router), address(_vault)), 0);
    assertEq(_vault.balanceOf(address(_router)), 0);
  }

  function test_APermitSomeoneElseSubmittedFirstDoesNotStopIt() external {
    _asset.permit(_investor, address(_router), _ASSETS, block.timestamp + 1 hours, _v, _r, _s);
    uint256 _shares = _enter(_entry(address(_vault), false));
    assertGt(_shares, 0);
  }

  function test_WithNoPermitAndNoAllowance_ItReverts() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    bytes memory _sig = _sign(_e);
    vm.expectRevert(
      abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(_router), 0, _ASSETS)
    );
    vm.prank(_relayer);
    _router.enterWithPermit(_e, _sig, 27, bytes32(uint256(1)), bytes32(uint256(2)));
  }

  function test_AfterTheDeadline_ItReverts() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    vm.warp(_e.deadline + 1);
    bytes memory _sig = _sign(_e);
    vm.expectRevert(ISignedEntry.SignedEntry_Expired.selector);
    _router.enterWithPermit(_e, _sig, _v, _r, _s);
  }

  function test_AtTheDeadline_ItPasses() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    vm.warp(_e.deadline);
    assertGt(_enter(_e), 0);
  }

  function test_BeforeItIsValid_ItReverts() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    _e.validAfter = block.timestamp + 1;
    bytes memory _sig = _sign(_e);
    vm.expectRevert(ISignedEntry.SignedEntry_NotYetValid.selector);
    _router.enterWithPermit(_e, _sig, _v, _r, _s);
  }

  function test_AtTheMomentItIsValid_ItPasses() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    _e.validAfter = block.timestamp;
    assertGt(_enter(_e), 0);
  }

  function test_ASignatureFromSomeoneElseIsRefused() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    (, uint256 _otherKey) = makeAddrAndKey('other');
    (uint8 _sv, bytes32 _sr, bytes32 _ss) = vm.sign(_otherKey, _router.entryHash(_e));
    vm.expectRevert(ISignedEntry.SignedEntry_BadSignature.selector);
    _router.enterWithPermit(_e, abi.encodePacked(_sr, _ss, _sv), _v, _r, _s);
  }

  function test_AnEntryChangedAfterSigningIsRefused() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    bytes memory _sig = _sign(_e);
    _e.assets += 1;
    vm.expectRevert(ISignedEntry.SignedEntry_BadSignature.selector);
    _router.enterWithPermit(_e, _sig, _v, _r, _s);
  }

  function test_AContractWalletSigns() external {
    MockERC1271Wallet _wallet = new MockERC1271Wallet(_investor);
    _credential(address(_wallet));
    _asset.mint(address(_wallet), _ASSETS);
    vm.prank(address(_wallet));
    _asset.approve(address(_router), _ASSETS);
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    _e.investor = address(_wallet);
    bytes memory _sig = _sign(_e);
    _router.enterWithPermit(_e, _sig, 27, bytes32(uint256(1)), bytes32(uint256(2)));
    assertGt(_vault.balanceOf(address(_wallet)), 0);
  }

  function test_AReplayIsRefused() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    _enter(_e);
    bytes memory _sig = _sign(_e);
    vm.expectRevert(ISignedEntry.SignedEntry_NonceUsed.selector);
    _router.enterWithPermit(_e, _sig, _v, _r, _s);
  }

  function test_ACancelledEntryIsRefused() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    vm.expectEmit(address(_router));
    emit ISignedEntry.EntryCancelled(_investor, _e.nonce);
    vm.prank(_investor);
    _router.cancelEntry(_e.nonce);
    bytes memory _sig = _sign(_e);
    vm.expectRevert(ISignedEntry.SignedEntry_NonceUsed.selector);
    _router.enterWithPermit(_e, _sig, _v, _r, _s);
  }

  function testFuzz_SomeoneElseCancellingDoesNothing(
    address _caller
  ) external {
    if (_caller == _investor) _caller = _stranger;
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    vm.prank(_caller);
    _router.cancelEntry(_e.nonce);
    assertFalse(_router.nonceUsed(_investor, _e.nonce));
    assertGt(_enter(_e), 0);
  }

  function test_FewerSharesThanAcceptedIsRefusedAndNothingMoves() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    uint256 _expected = _vault.previewDeposit(_ASSETS);
    _e.minShares = _expected + 1;
    bytes memory _sig = _sign(_e);
    vm.expectRevert(abi.encodeWithSelector(ISignedEntry.SignedEntry_TooFewShares.selector, _expected + 1, _expected));
    _router.enterWithPermit(_e, _sig, _v, _r, _s);
    assertEq(_asset.balanceOf(_investor), 10 * _ASSETS);
    assertFalse(_router.nonceUsed(_investor, _e.nonce));
  }

  function test_ExactlyTheSharesAcceptedPasses() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    _e.minShares = _vault.previewDeposit(_ASSETS);
    assertEq(_enter(_e), _e.minShares);
  }

  /// @dev It is an ordinary third-party payer, so a vault's policy decides
  function test_WithoutACredential_TheVaultRefusesIt() external {
    SignedEntry _uncredentialed = new SignedEntry();
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    (uint8 _sv, bytes32 _sr, bytes32 _ss) = vm.sign(_investorKey, _uncredentialed.entryHash(_e));
    vm.prank(_investor);
    _asset.approve(address(_uncredentialed), _ASSETS);
    vm.expectRevert(
      abi.encodeWithSelector(
        IGatedVaultBase.GatedVault_ThirdPartyNotEligible.selector,
        address(_uncredentialed),
        Reasons.RECEIVER_NOT_VERIFIED
      )
    );
    _uncredentialed.enterWithPermit(_e, abi.encodePacked(_sr, _ss, _sv), 27, bytes32(uint256(1)), bytes32(uint256(2)));
  }

  function test_AnInvestorThePolicyRefusesIsRefused() external {
    address _unverified;
    uint256 _key;
    (_unverified, _key) = makeAddrAndKey('unverified');
    _asset.mint(_unverified, _ASSETS);
    vm.prank(_unverified);
    _asset.approve(address(_router), _ASSETS);
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    _e.investor = _unverified;
    (uint8 _sv, bytes32 _sr, bytes32 _ss) = vm.sign(_key, _router.entryHash(_e));
    vm.expectRevert();
    _router.enterWithPermit(_e, abi.encodePacked(_sr, _ss, _sv), 27, bytes32(uint256(1)), bytes32(uint256(2)));
    assertEq(_asset.balanceOf(_unverified), _ASSETS);
  }

  function test_OnARequestItFilesUnderTheInvestorAsController() external {
    Gated7540Vault _async = _vault7540(address(_asset));
    ISignedEntry.Entry memory _e = _entry(address(_async), true);
    uint256 _shares = _enterAsync(_e);
    assertEq(_shares, 0);
    assertEq(_async.pendingDepositRequest(0, _investor), _ASSETS);
    assertEq(_asset.balanceOf(address(_async)), _ASSETS);
    assertEq(_asset.balanceOf(address(_router)), 0);

    // The investor claims as usual once the period has settled.
    address _settler = makeAddr('settler');
    _async.grantRole(_async.SETTLER_ROLE(), _settler);
    address _cash = makeAddr('cash');
    vm.startPrank(_settler);
    _async.closePeriod();
    _async.settlePeriod(0, 0, _cash, address(0));
    vm.stopPrank();
    vm.prank(_investor);
    _async.mint(_ASSETS * _PAR, _investor, _investor);
    assertEq(_async.balanceOf(_investor), _ASSETS * _PAR);
  }

  function _enterAsync(
    ISignedEntry.Entry memory _e
  ) internal returns (uint256 _shares) {
    bytes memory _sig = _sign(_e);
    vm.prank(_relayer);
    _shares = _router.enterWithPermit(_e, _sig, _v, _r, _s);
  }

  function test_ARequestNamingAMinimumIsRefused() external {
    Gated7540Vault _async = _vault7540(address(_asset));
    ISignedEntry.Entry memory _e = _entry(address(_async), true);
    _e.minShares = 1;
    bytes memory _sig = _sign(_e);
    vm.expectRevert(ISignedEntry.SignedEntry_MinimumOnARequest.selector);
    _router.enterWithPermit(_e, _sig, _v, _r, _s);
  }
}

/// @notice Exits need no lego: a holder signs the share token's `permit`, and a relayer submits it through `multicall`
contract SignedEntry_ExitsNeedNoLego is SignedEntryTest {
  MockPermitAsset internal _asset;

  function setUp() public override {
    super.setUp();
    _asset = new MockPermitAsset();
    _asset.mint(_investor, _ASSETS);
    vm.prank(_investor);
    _asset.approve(address(this), type(uint256).max);
  }

  function _permitCall(
    address _vault,
    uint256 _shares,
    uint256 _deadline
  ) internal view returns (bytes memory _call) {
    MockPermitAsset _shareToken = MockPermitAsset(_vault); // only for the ERC-2612 views
    bytes32 _structHash =
      keccak256(abi.encode(_PERMIT_TYPEHASH, _investor, _relayer, _shares, _shareToken.nonces(_investor), _deadline));
    bytes32 _digest = keccak256(abi.encodePacked('\x19\x01', _shareToken.DOMAIN_SEPARATOR(), _structHash));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_investorKey, _digest);
    _call = abi.encodeCall(_shareToken.permit, (_investor, _relayer, _shares, _deadline, _v, _r, _s));
  }

  function test_ARelayerFilesARedemptionOnAHoldersSignature() external {
    Gated7540Vault _vault = _vault7540(address(_asset));
    _creds.set(_investor, uint64(block.timestamp + 3650 days), Quals.KYC, 756);
    vm.prank(_investor);
    _asset.approve(address(_vault), _ASSETS);
    vm.prank(_investor);
    _vault.requestDeposit(_ASSETS, _investor, _investor);
    address _settler = makeAddr('settler');
    _vault.grantRole(_vault.SETTLER_ROLE(), _settler);
    vm.startPrank(_settler);
    _vault.closePeriod();
    _vault.settlePeriod(0, 0, makeAddr('cash'), address(0));
    vm.stopPrank();
    uint256 _shares = _ASSETS * _PAR;
    vm.prank(_investor);
    _vault.mint(_shares, _investor, _investor);

    bytes[] memory _calls = new bytes[](2);
    _calls[0] = _permitCall(address(_vault), _shares, block.timestamp + 1 hours);
    _calls[1] = abi.encodeCall(_vault.requestRedeem, (_shares, _investor, _investor));
    vm.prank(_relayer);
    _vault.multicall(_calls);
    assertEq(_vault.pendingRedeemRequest(0, _investor), _shares);
    assertEq(_vault.balanceOf(_investor), 0);
  }

  function test_ARelayerRedeemsOnAHoldersSignatureAndTheCashGoesToTheHolder() external {
    Gated4626Vault _vault = _vault4626(address(_asset));
    vm.prank(_investor);
    _asset.approve(address(_vault), _ASSETS);
    vm.prank(_investor);
    uint256 _shares = _vault.deposit(_ASSETS, _investor);

    bytes[] memory _calls = new bytes[](2);
    _calls[0] = _permitCall(address(_vault), _shares, block.timestamp + 1 hours);
    _calls[1] = abi.encodeWithSignature('redeem(uint256,address,address)', _shares, _investor, _investor);
    vm.prank(_relayer);
    _vault.multicall(_calls);
    assertEq(_vault.balanceOf(_investor), 0);
    assertEq(_asset.balanceOf(_investor), _ASSETS);
  }
}

contract SignedEntry_3009 is SignedEntryTest {
  bytes32 internal constant _RECEIVE_TYPEHASH = keccak256(
    'ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)'
  );

  MockERC3009Token internal _asset;
  Gated4626Vault internal _vault;

  function setUp() public override {
    super.setUp();
    _asset = new MockERC3009Token();
    _vault = _vault4626(address(_asset));
    _asset.mint(_investor, 10 * _ASSETS);
  }

  function _signCash(
    ISignedEntry.Entry memory _e,
    bytes32 _nonce
  ) internal view returns (bytes memory _sig) {
    bytes32 _structHash = keccak256(
      abi.encode(_RECEIVE_TYPEHASH, _e.investor, address(_router), _e.assets, _e.validAfter, _e.deadline, _nonce)
    );
    bytes32 _domain = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
        keccak256('Mock USD'),
        keccak256('2'),
        block.chainid,
        address(_asset)
      )
    );
    bytes32 _digest = keccak256(abi.encodePacked('\x19\x01', _domain, _structHash));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_investorKey, _digest);
    _sig = abi.encodePacked(_r, _s, _v);
  }

  function test_TheNonceBindsTheCashToTheEntry() external view {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    assertEq(_router.cashNonce(_e), keccak256(abi.encode(address(_router), _router.entryHash(_e))));
  }

  function test_ARelayerSubmitsWithBothSignatures() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    bytes memory _sig = _sign(_e);
    bytes memory _cash = _signCash(_e, _router.cashNonce(_e));
    uint256 _expected = _vault.previewDeposit(_ASSETS);
    vm.prank(_relayer);
    assertEq(_router.enterWith3009(_e, _sig, _cash), _expected);
    assertEq(_vault.balanceOf(_investor), _expected);
    assertEq(_asset.balanceOf(address(_router)), 0);
    assertTrue(_asset.authorizationState(_investor, _router.cashNonce(_e)));
  }

  function test_AnAuthorizationForAnotherEntryIsRefused() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    bytes memory _sig = _sign(_e);
    bytes memory _cash = _signCash(_e, keccak256('some other nonce'));
    vm.expectRevert();
    _router.enterWith3009(_e, _sig, _cash);
    assertEq(_asset.balanceOf(_investor), 10 * _ASSETS);
  }

  function test_AReplayIsRefused() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    bytes memory _sig = _sign(_e);
    bytes memory _cash = _signCash(_e, _router.cashNonce(_e));
    _router.enterWith3009(_e, _sig, _cash);
    vm.expectRevert(ISignedEntry.SignedEntry_NonceUsed.selector);
    _router.enterWith3009(_e, _sig, _cash);
  }

  function test_TheEntryIsCheckedAsWithAPermit() external {
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    bytes memory _cash = _signCash(_e, _router.cashNonce(_e));
    (, uint256 _otherKey) = makeAddrAndKey('other');
    (uint8 _sv, bytes32 _sr, bytes32 _ss) = vm.sign(_otherKey, _router.entryHash(_e));
    vm.expectRevert(ISignedEntry.SignedEntry_BadSignature.selector);
    _router.enterWith3009(_e, abi.encodePacked(_sr, _ss, _sv), _cash);
  }
}
