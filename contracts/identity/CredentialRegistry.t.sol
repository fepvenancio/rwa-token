// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {ICredentialRegistry} from 'interfaces/ICredentialRegistry.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {Quals} from 'interfaces/Quals.sol';

import {CredentialRegistry} from 'contracts/identity/CredentialRegistry.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockERC1271Wallet} from 'contracts/test/MockERC1271Wallet.sol';

contract CredentialRegistryUnitTest is Helpers {
  uint256 internal constant _NOW = 1_792_198_800; // Sat 2026-10-17 01:00 UTC
  uint32 internal constant _ALL = type(uint32).max;
  uint32 internal constant _KYC_MASK = Quals.KYC | Quals.PROFESSIONAL | Quals.CUSTOMER;

  CredentialRegistry internal _registry;
  MockERC1271Wallet internal _wallet;
  address internal _admin = makeAddr('admin');
  address internal _guardian = makeAddr('guardian');
  address internal _recovery = makeAddr('recovery');
  address internal _kyc = makeAddr('kyc'); // attester 0, limited to _KYC_MASK
  address internal _attester1 = makeAddr('attester1'); // attester 1
  address internal _signer; // attester 2, a key we can sign with
  uint256 internal _signerPk;
  address internal _walletOwner; // owns attester 3, a contract account
  uint256 internal _walletPk;
  address internal _subject = makeAddr('subject');
  address internal _other = makeAddr('other');
  address internal _stranger = makeAddr('stranger');

  function setUp() public virtual {
    vm.warp(_NOW);
    (_signer, _signerPk) = makeAddrAndKey('signer');
    (_walletOwner, _walletPk) = makeAddrAndKey('walletOwner');
    _wallet = new MockERC1271Wallet(_walletOwner);
    _registry = new CredentialRegistry(_admin, _guardian);
    vm.startPrank(_admin);
    _registry.grantRole(_registry.RECOVERY_ROLE(), _recovery);
    _registry.addAttester(_kyc, _KYC_MASK);
    _registry.addAttester(_attester1, _ALL);
    _registry.addAttester(_signer, _ALL);
    _registry.addAttester(address(_wallet), _ALL);
    vm.stopPrank();
  }

  function _set(
    address _by,
    address _who,
    uint64 _until,
    uint32 _quals
  ) internal {
    vm.prank(_by);
    _registry.set(_who, _until, _quals);
  }

  function _active(
    address _by,
    address _who
  ) internal {
    _set(_by, _who, uint64(_NOW + 365 days), Quals.KYC);
  }

  function _credential(
    address _who,
    uint64 _until,
    uint32 _quals,
    uint64 _issuedAt,
    uint8 _attester
  ) internal pure returns (ICredentialRegistry.Credential memory _c) {
    _c = ICredentialRegistry.Credential({
      subject: _who, validUntil: _until, quals: _quals, issuedAt: _issuedAt, attester: _attester
    });
  }

  function _sign(
    uint256 _pk,
    ICredentialRegistry.Credential memory _c
  ) internal view returns (bytes memory _sig) {
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_pk, _registry.credentialHash(_c));
    _sig = abi.encodePacked(_r, _s, _v);
  }

  function _signedByAttester2(
    address _who,
    uint64 _issuedAt
  ) internal view returns (ICredentialRegistry.Credential memory _c, bytes memory _sig) {
    _c = _credential(_who, uint64(_NOW + 365 days), Quals.KYC, _issuedAt, 2);
    _sig = _sign(_signerPk, _c);
  }

  function _status(
    address _who
  ) internal view returns (ICredentialRegistry.Status _s) {
    (_s,,) = _registry.profileOf(_who);
  }

  function _unauthorized(
    address _caller,
    bytes32 _role
  ) internal pure returns (bytes memory _data) {
    _data = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role);
  }

  function _expect(
    bytes4 _selector
  ) internal {
    vm.expectRevert(_selector);
  }
}

contract CredentialRegistryUnit_Constructor is CredentialRegistryUnitTest {
  function test_WhenTheAdminIsZero_ItReverts() external {
    _expect(ICredentialRegistry.CredentialRegistry_ZeroAddress.selector);
    new CredentialRegistry(address(0), _guardian);
  }

  function test_WhenTheGuardianIsZero_ItReverts() external {
    _expect(ICredentialRegistry.CredentialRegistry_ZeroAddress.selector);
    new CredentialRegistry(_admin, address(0));
  }

  function test_WhenDeployed_TheRolesAndTheAttesterListAreSet() external view {
    assertTrue(_registry.hasRole(_registry.DEFAULT_ADMIN_ROLE(), _admin));
    assertTrue(_registry.hasRole(_registry.GUARDIAN_ROLE(), _guardian));
    assertFalse(_registry.hasRole(_registry.DEFAULT_ADMIN_ROLE(), address(this)));
    assertEq(_registry.attesterCount(), 4);
    assertEq(_registry.MAX_ATTESTERS(), 64);
    assertEq(_registry.GUARDIAN_ROLE(), keccak256('GUARDIAN_ROLE'));
    assertEq(_registry.RECOVERY_ROLE(), keccak256('RECOVERY_ROLE'));
  }

  function test_WhenAskedForInterfaces_ItAnswersTheRegistryTheIdentityRegistryAndAccessControl() external view {
    assertTrue(_registry.supportsInterface(type(ICredentialRegistry).interfaceId));
    assertTrue(_registry.supportsInterface(type(IIdentityRegistry).interfaceId));
    assertTrue(_registry.supportsInterface(type(IERC165).interfaceId));
    assertTrue(_registry.supportsInterface(type(IAccessControl).interfaceId));
    assertFalse(_registry.supportsInterface(0xffffffff));
  }

  function test_WhenReadingTheTypehash_ItMatchesTheCredentialType() external view {
    assertEq(
      _registry.CREDENTIAL_TYPEHASH(),
      keccak256('Credential(address subject,uint64 validUntil,uint32 quals,uint64 issuedAt,uint8 attester)')
    );
  }
}

contract CredentialRegistryUnit_AddAttester is CredentialRegistryUnitTest {
  function test_WhenCallerIsNotTheAdmin_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _registry.DEFAULT_ADMIN_ROLE()));
    vm.prank(_stranger);
    _registry.addAttester(makeAddr('new'), 1);
  }

  function test_WhenTheGuardianTries_ItReverts() external {
    vm.expectRevert(_unauthorized(_guardian, _registry.DEFAULT_ADMIN_ROLE()));
    vm.prank(_guardian);
    _registry.addAttester(makeAddr('new'), 1);
  }

  function test_WhenTheAccountIsZero_ItReverts() external {
    _expect(ICredentialRegistry.CredentialRegistry_ZeroAddress.selector);
    vm.prank(_admin);
    _registry.addAttester(address(0), 1);
  }

  function test_WhenTheAccountIsAlreadyAnAttester_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_AttesterExists.selector, _kyc));
    vm.prank(_admin);
    _registry.addAttester(_kyc, 1);
  }

  function test_WhenAddingTheSixtyFifth_ItReverts() external {
    vm.startPrank(_admin);
    for (uint256 _i = 4; _i < 64; ++_i) {
      _registry.addAttester(address(uint160(0x1000 + _i)), 1);
    }
    assertEq(_registry.attesterCount(), 64);
    _expect(ICredentialRegistry.CredentialRegistry_TooManyAttesters.selector);
    _registry.addAttester(address(uint160(0x9999)), 1);
    vm.stopPrank();
  }

  function test_WhenValid_ItAssignsTheNextIdStoresAndEmits(
    uint32 _allowed
  ) external {
    address _new = makeAddr('new');
    vm.expectEmit(address(_registry));
    emit ICredentialRegistry.AttesterAdded(4, _new, _allowed);
    vm.prank(_admin);
    uint8 _id = _registry.addAttester(_new, _allowed);

    assertEq(_id, 4);
    assertEq(_registry.attesterCount(), 5);
    ICredentialRegistry.Attester memory _a = _registry.attesterAt(4);
    assertEq(_a.account, _new);
    assertEq(_a.allowedQuals, _allowed);
    assertFalse(_a.killed);
    (bool _found, uint8 _foundId) = _registry.attesterIdOf(_new);
    assertTrue(_found);
    assertEq(_foundId, 4);
  }

  function test_WhenAskedAboutAnUnknownAccountOrId_ItSaysSo() external {
    (bool _found, uint8 _id) = _registry.attesterIdOf(_stranger);
    assertFalse(_found);
    assertEq(_id, 0);
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_UnknownAttester.selector, 9));
    _registry.attesterAt(9);
  }
}

contract CredentialRegistryUnit_AttesterAdmin is CredentialRegistryUnitTest {
  function test_WhenSettingTheAccountAsAStranger_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _registry.DEFAULT_ADMIN_ROLE()));
    vm.prank(_stranger);
    _registry.setAttesterAccount(0, makeAddr('new'));
  }

  function test_WhenSettingTheAccountOfAnUnknownId_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_UnknownAttester.selector, 9));
    vm.prank(_admin);
    _registry.setAttesterAccount(9, makeAddr('new'));
  }

  function test_WhenSettingTheAccountToZeroOrToAnExistingAttester_ItReverts() external {
    _expect(ICredentialRegistry.CredentialRegistry_ZeroAddress.selector);
    vm.prank(_admin);
    _registry.setAttesterAccount(0, address(0));

    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_AttesterExists.selector, _attester1));
    vm.prank(_admin);
    _registry.setAttesterAccount(0, _attester1);
  }

  function test_WhenTheAccountIsRotated_TheOldOneStopsWritingAndTheNewOneStarts() external {
    address _new = makeAddr('rotated');
    vm.expectEmit(address(_registry));
    emit ICredentialRegistry.AttesterAccountSet(0, _kyc, _new);
    vm.prank(_admin);
    _registry.setAttesterAccount(0, _new);

    assertEq(_registry.attesterAt(0).account, _new);
    (bool _oldFound,) = _registry.attesterIdOf(_kyc);
    assertFalse(_oldFound);
    (bool _newFound, uint8 _id) = _registry.attesterIdOf(_new);
    assertTrue(_newFound);
    assertEq(_id, 0);

    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_NotAnAttester.selector, _kyc));
    vm.prank(_kyc);
    _registry.set(_subject, uint64(_NOW + 1 days), Quals.KYC);
    _active(_new, _subject);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.ACTIVE));
  }

  function test_WhenSettingTheQualsAsAStranger_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger, _registry.DEFAULT_ADMIN_ROLE()));
    vm.prank(_stranger);
    _registry.setAttesterQuals(0, 1);
  }

  function test_WhenSettingTheQualsOfAnUnknownId_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_UnknownAttester.selector, 9));
    vm.prank(_admin);
    _registry.setAttesterQuals(9, 1);
  }

  function test_WhenTheQualsChange_RecordsAlreadyWrittenAreNotTouched() external {
    _set(_kyc, _subject, uint64(_NOW + 30 days), Quals.PROFESSIONAL | Quals.KYC);
    vm.expectEmit(address(_registry));
    emit ICredentialRegistry.AttesterQualsSet(0, Quals.KYC);
    vm.prank(_admin);
    _registry.setAttesterQuals(0, Quals.KYC);

    (ICredentialRegistry.Status _s, uint32 _quals,) = _registry.profileOf(_subject);
    assertEq(uint8(_s), uint8(ICredentialRegistry.Status.ACTIVE));
    assertEq(_quals, Quals.PROFESSIONAL | Quals.KYC);

    vm.expectRevert(
      abi.encodeWithSelector(
        ICredentialRegistry.CredentialRegistry_QualsNotAllowed.selector, 0, Quals.PROFESSIONAL, Quals.KYC
      )
    );
    vm.prank(_kyc);
    _registry.set(_other, uint64(_NOW + 1 days), Quals.PROFESSIONAL);
  }
}

contract CredentialRegistryUnit_Set is CredentialRegistryUnitTest {
  function test_WhenTheCallerIsNotAnAttester_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_NotAnAttester.selector, _stranger));
    vm.prank(_stranger);
    _registry.set(_subject, uint64(_NOW + 1 days), Quals.KYC);
  }

  function test_WhenTheSubjectIsZero_ItReverts() external {
    _expect(ICredentialRegistry.CredentialRegistry_ZeroAddress.selector);
    vm.prank(_kyc);
    _registry.set(address(0), uint64(_NOW + 1 days), Quals.KYC);
  }

  function test_WhenTheAttesterIsKilled_ItReverts() external {
    vm.prank(_guardian);
    _registry.killAttester(0);
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_AttesterKilled.selector, 0));
    vm.prank(_kyc);
    _registry.set(_subject, uint64(_NOW + 1 days), Quals.KYC);
  }

  function test_WhenTheQualsAreOutsideTheAllowedMask_ItReverts(
    uint32 _quals
  ) external {
    _quals = _quals | uint32(1 << 31); // bit 31 is outside _KYC_MASK
    vm.expectRevert(
      abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_QualsNotAllowed.selector, 0, _quals, _KYC_MASK)
    );
    vm.prank(_kyc);
    _registry.set(_subject, uint64(_NOW + 1 days), _quals);
  }

  function test_WhenTheValidityIsNotInTheFuture_ItReverts(
    uint64 _until
  ) external {
    _until = uint64(bound(_until, 0, _NOW));
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_ValidityInPast.selector, _until));
    vm.prank(_kyc);
    _registry.set(_subject, _until, Quals.KYC);
  }

  function test_WhenTheValidityIsOneSecondAhead_ItIsAccepted() external {
    _set(_kyc, _subject, uint64(_NOW + 1), Quals.KYC);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.ACTIVE));
  }

  function test_WhenValid_ItStoresTheRecordAndEmits(
    uint64 _until,
    uint32 _quals
  ) external {
    _until = uint64(bound(_until, _NOW + 1, type(uint64).max));
    _quals = _quals & _KYC_MASK;
    vm.expectEmit(address(_registry));
    emit ICredentialRegistry.CredentialSet(_subject, 0, _until, _quals, uint64(_NOW));
    vm.prank(_kyc);
    _registry.set(_subject, _until, _quals);

    ICredentialRegistry.Record memory _r = _registry.recordOf(_subject);
    assertEq(_r.validUntil, _until);
    assertEq(uint8(_r.status), uint8(ICredentialRegistry.Status.ACTIVE));
    assertEq(_r.quals, _quals);
    assertEq(_r.attester, 0);
    assertEq(_r.issuedAt, uint64(_NOW));
    assertFalse(_r.guardianBlock);
  }

  function test_WhenTheSameAttesterWritesAgain_ItOverwrites() external {
    _set(_kyc, _subject, uint64(_NOW + 10 days), Quals.KYC);
    vm.warp(_NOW + 1 days);
    _set(_kyc, _subject, uint64(_NOW + 20 days), Quals.KYC | Quals.CUSTOMER);
    ICredentialRegistry.Record memory _r = _registry.recordOf(_subject);
    assertEq(_r.validUntil, _NOW + 20 days);
    assertEq(_r.quals, Quals.KYC | Quals.CUSTOMER);
    assertEq(_r.issuedAt, uint64(_NOW + 1 days));
  }

  function test_WhenAnotherActiveAttesterOwnsTheRecord_ItReverts() external {
    _active(_kyc, _subject);
    vm.expectRevert(
      abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_RecordOwnedByAnotherAttester.selector, _subject, 0)
    );
    vm.prank(_attester1);
    _registry.set(_subject, uint64(_NOW + 1 days), Quals.KYC);
  }

  function test_WhenAnotherActiveAttesterBlockedTheRecord_ItStillReverts() external {
    _active(_kyc, _subject);
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.BLOCKED);
    vm.expectRevert(
      abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_RecordOwnedByAnotherAttester.selector, _subject, 0)
    );
    vm.prank(_attester1);
    _registry.set(_subject, uint64(_NOW + 1 days), Quals.KYC);
  }

  function test_WhenTheOwningAttesterIsKilled_AnotherMayTakeTheRecordOver() external {
    _active(_kyc, _subject);
    vm.prank(_guardian);
    _registry.killAttester(0);
    _set(_attester1, _subject, uint64(_NOW + 30 days), Quals.KYC | Quals.LICENSED);
    ICredentialRegistry.Record memory _r = _registry.recordOf(_subject);
    assertEq(_r.attester, 1);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.ACTIVE));
  }

  function test_WhenAGuardianBlockIsSet_AWriteKeepsIt() external {
    vm.prank(_guardian);
    _registry.blockSubject(_subject);
    _active(_kyc, _subject);
    assertTrue(_registry.recordOf(_subject).guardianBlock);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.BLOCKED));
  }
}

contract CredentialRegistryUnit_Register is CredentialRegistryUnitTest {
  function test_WhenSignedByAnEoaAttester_AnyoneCanSubmitIt() external {
    (ICredentialRegistry.Credential memory _c, bytes memory _sig) = _signedByAttester2(_subject, uint64(_NOW));
    vm.expectEmit(address(_registry));
    emit ICredentialRegistry.CredentialSet(_subject, 2, _c.validUntil, _c.quals, _c.issuedAt);
    vm.prank(_stranger);
    _registry.register(_c, _sig);

    ICredentialRegistry.Record memory _r = _registry.recordOf(_subject);
    assertEq(_r.attester, 2);
    assertEq(_r.validUntil, _c.validUntil);
    assertEq(_r.issuedAt, uint64(_NOW));
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.ACTIVE));
  }

  function test_WhenSignedByAContractAttester_ItIsAcceptedThroughErc1271() external {
    ICredentialRegistry.Credential memory _c =
      _credential(_subject, uint64(_NOW + 30 days), Quals.KYC | Quals.LICENSED, uint64(_NOW), 3);
    bytes memory _sig = _sign(_walletPk, _c);
    vm.prank(_stranger);
    _registry.register(_c, _sig);
    assertEq(_registry.recordOf(_subject).attester, 3);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.ACTIVE));
  }

  function test_WhenTheSignatureIsByAnotherKey_ItReverts() external {
    ICredentialRegistry.Credential memory _c = _credential(_subject, uint64(_NOW + 1 days), Quals.KYC, uint64(_NOW), 2);
    bytes memory _sig = _sign(_walletPk, _c);
    _expect(ICredentialRegistry.CredentialRegistry_BadSignature.selector);
    _registry.register(_c, _sig);
  }

  function test_WhenAFieldIsChangedAfterSigning_ItReverts() external {
    (ICredentialRegistry.Credential memory _c, bytes memory _sig) = _signedByAttester2(_subject, uint64(_NOW));
    _c.quals = Quals.KYC | Quals.PROFESSIONAL;
    _expect(ICredentialRegistry.CredentialRegistry_BadSignature.selector);
    _registry.register(_c, _sig);
  }

  function test_WhenTheAttesterIdIsUnknown_ItReverts() external {
    ICredentialRegistry.Credential memory _c = _credential(_subject, uint64(_NOW + 1 days), Quals.KYC, uint64(_NOW), 9);
    bytes memory _sig = _sign(_signerPk, _c);
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_UnknownAttester.selector, 9));
    _registry.register(_c, _sig);
  }

  function test_WhenTheAttesterIsKilled_ItReverts() external {
    (ICredentialRegistry.Credential memory _c, bytes memory _sig) = _signedByAttester2(_subject, uint64(_NOW));
    vm.prank(_guardian);
    _registry.killAttester(2);
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_AttesterKilled.selector, 2));
    _registry.register(_c, _sig);
  }

  function test_WhenTheQualsAreOutsideTheAllowedMask_ItReverts() external {
    vm.prank(_admin);
    _registry.setAttesterQuals(2, Quals.KYC);
    ICredentialRegistry.Credential memory _c =
      _credential(_subject, uint64(_NOW + 1 days), Quals.PROFESSIONAL, uint64(_NOW), 2);
    bytes memory _sig = _sign(_signerPk, _c);
    vm.expectRevert(
      abi.encodeWithSelector(
        ICredentialRegistry.CredentialRegistry_QualsNotAllowed.selector, 2, Quals.PROFESSIONAL, Quals.KYC
      )
    );
    _registry.register(_c, _sig);
  }

  function test_WhenTheValidityIsNotInTheFuture_ItReverts() external {
    ICredentialRegistry.Credential memory _c = _credential(_subject, uint64(_NOW), Quals.KYC, uint64(_NOW), 2);
    bytes memory _sig = _sign(_signerPk, _c);
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_ValidityInPast.selector, _NOW));
    _registry.register(_c, _sig);
  }

  function test_WhenIssuedInTheFuture_ItReverts() external {
    (ICredentialRegistry.Credential memory _c, bytes memory _sig) = _signedByAttester2(_subject, uint64(_NOW + 1));
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_IssuedInFuture.selector, _NOW + 1));
    _registry.register(_c, _sig);
  }

  function test_WhenTheSameCredentialIsSubmittedTwice_TheSecondReverts() external {
    (ICredentialRegistry.Credential memory _c, bytes memory _sig) = _signedByAttester2(_subject, uint64(_NOW));
    _registry.register(_c, _sig);
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_StaleCredential.selector, _NOW, _NOW));
    _registry.register(_c, _sig);
  }

  function test_WhenAnOlderCredentialArrivesAfterANewerOne_ItReverts() external {
    (ICredentialRegistry.Credential memory _old, bytes memory _oldSig) = _signedByAttester2(_subject, uint64(_NOW));
    vm.warp(_NOW + 1 days);
    (ICredentialRegistry.Credential memory _new, bytes memory _newSig) =
      _signedByAttester2(_subject, uint64(_NOW + 1 days));
    _registry.register(_new, _newSig);
    vm.expectRevert(
      abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_StaleCredential.selector, _NOW, _NOW + 1 days)
    );
    _registry.register(_old, _oldSig);
  }

  function test_WhenAnAttesterWroteDirectlyAfterTheSigning_TheSignedOneReverts() external {
    (ICredentialRegistry.Credential memory _c, bytes memory _sig) = _signedByAttester2(_subject, uint64(_NOW));
    vm.warp(_NOW + 1 hours);
    _set(_signer, _subject, uint64(_NOW + 30 days), Quals.KYC);
    vm.expectRevert(
      abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_StaleCredential.selector, _NOW, _NOW + 1 hours)
    );
    _registry.register(_c, _sig);
  }

  function test_WhenAnAttesterChangedTheStatusAfterTheSigning_TheSignedOneCannotUndoIt() external {
    _active(_signer, _subject);
    (ICredentialRegistry.Credential memory _c, bytes memory _sig) = _signedByAttester2(_subject, uint64(_NOW));
    vm.warp(_NOW + 1 hours);
    vm.prank(_signer);
    _registry.setStatus(_subject, ICredentialRegistry.Status.BLOCKED);
    // _c was issued at _NOW, before the block at _NOW + 1 hours
    vm.expectRevert(
      abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_StaleCredential.selector, _NOW, _NOW + 1 hours)
    );
    _registry.register(_c, _sig);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.BLOCKED));
  }

  function test_WhenTheAttesterIssuesANewerCredentialAfterItsOwnBlock_ItLiftsIt() external {
    _active(_signer, _subject);
    vm.warp(_NOW + 1 hours);
    vm.prank(_signer);
    _registry.setStatus(_subject, ICredentialRegistry.Status.BLOCKED);
    vm.warp(_NOW + 2 hours);
    (ICredentialRegistry.Credential memory _c, bytes memory _sig) = _signedByAttester2(_subject, uint64(_NOW + 2 hours));
    _registry.register(_c, _sig);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.ACTIVE));
  }

  function test_WhenTheChainIdDiffers_ItReverts() external {
    (ICredentialRegistry.Credential memory _c, bytes memory _sig) = _signedByAttester2(_subject, uint64(_NOW));
    vm.chainId(block.chainid + 1);
    _expect(ICredentialRegistry.CredentialRegistry_BadSignature.selector);
    _registry.register(_c, _sig);
  }

  function test_WhenSubmittedToAnotherRegistry_ItReverts() external {
    (ICredentialRegistry.Credential memory _c, bytes memory _sig) = _signedByAttester2(_subject, uint64(_NOW));
    CredentialRegistry _twin = new CredentialRegistry(_admin, _guardian);
    vm.prank(_admin);
    _twin.addAttester(_kyc, _KYC_MASK);
    vm.startPrank(_admin);
    _twin.addAttester(_attester1, _ALL);
    _twin.addAttester(_signer, _ALL);
    vm.stopPrank();
    _expect(ICredentialRegistry.CredentialRegistry_BadSignature.selector);
    _twin.register(_c, _sig);
  }

  function test_WhenTheKeyWasRotatedOut_TheOldSignatureReverts() external {
    (ICredentialRegistry.Credential memory _c, bytes memory _sig) = _signedByAttester2(_subject, uint64(_NOW));
    vm.prank(_admin);
    _registry.setAttesterAccount(2, makeAddr('newSigner'));
    _expect(ICredentialRegistry.CredentialRegistry_BadSignature.selector);
    _registry.register(_c, _sig);
  }

  function test_WhenAnotherActiveAttesterOwnsTheRecord_ItReverts() external {
    _active(_kyc, _subject);
    vm.warp(_NOW + 1 hours);
    (ICredentialRegistry.Credential memory _c, bytes memory _sig) = _signedByAttester2(_subject, uint64(_NOW + 1 hours));
    vm.expectRevert(
      abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_RecordOwnedByAnotherAttester.selector, _subject, 0)
    );
    _registry.register(_c, _sig);
  }

  function test_WhenAGuardianBlockIsSet_ASignedCredentialCannotClearIt() external {
    vm.prank(_guardian);
    _registry.blockSubject(_subject);
    (ICredentialRegistry.Credential memory _c, bytes memory _sig) = _signedByAttester2(_subject, uint64(_NOW));
    _registry.register(_c, _sig);
    assertTrue(_registry.recordOf(_subject).guardianBlock);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.BLOCKED));
  }
}

contract CredentialRegistryUnit_SetStatus is CredentialRegistryUnitTest {
  function test_WhenTheCallerIsNotAnAttester_ItReverts() external {
    _active(_kyc, _subject);
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_NotAnAttester.selector, _stranger));
    vm.prank(_stranger);
    _registry.setStatus(_subject, ICredentialRegistry.Status.BLOCKED);
  }

  function test_WhenThereIsNoRecord_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_NoRecord.selector, _subject));
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.BLOCKED);
  }

  function test_WhenAnotherAttesterWroteTheRecord_ItReverts() external {
    _active(_kyc, _subject);
    vm.expectRevert(
      abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_NotRecordAttester.selector, _subject, 0)
    );
    vm.prank(_attester1);
    _registry.setStatus(_subject, ICredentialRegistry.Status.BLOCKED);
  }

  function test_WhenTheAttesterIsKilled_ItReverts() external {
    _active(_kyc, _subject);
    vm.prank(_guardian);
    _registry.killAttester(0);
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_AttesterKilled.selector, 0));
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.BLOCKED);
  }

  function test_WhenTheStatusIsNoneOrLapsed_ItReverts() external {
    _active(_kyc, _subject);
    vm.expectRevert(
      abi.encodeWithSelector(
        ICredentialRegistry.CredentialRegistry_InvalidStatus.selector, ICredentialRegistry.Status.NONE
      )
    );
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.NONE);

    vm.expectRevert(
      abi.encodeWithSelector(
        ICredentialRegistry.CredentialRegistry_InvalidStatus.selector, ICredentialRegistry.Status.LAPSED
      )
    );
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.LAPSED);
  }

  function test_WhenSettingExitOnlyOrBlocked_ItStoresEmitsAndBumpsIssuedAt() external {
    _active(_kyc, _subject);
    vm.warp(_NOW + 1 hours);
    vm.expectEmit(address(_registry));
    emit ICredentialRegistry.StatusSet(_subject, 0, ICredentialRegistry.Status.EXIT_ONLY);
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.EXIT_ONLY);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.EXIT_ONLY));
    assertEq(_registry.recordOf(_subject).issuedAt, uint64(_NOW + 1 hours));

    vm.expectEmit(address(_registry));
    emit ICredentialRegistry.StatusSet(_subject, 0, ICredentialRegistry.Status.BLOCKED);
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.BLOCKED);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.BLOCKED));
  }

  function test_WhenRestoringActiveWhileValid_ItWorks() external {
    _active(_kyc, _subject);
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.BLOCKED);
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.ACTIVE);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.ACTIVE));
  }

  function test_WhenRestoringActiveAfterTheValidityEnded_ItReverts() external {
    _active(_kyc, _subject);
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.BLOCKED);
    vm.warp(_NOW + 366 days);
    vm.expectRevert(
      abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_ValidityInPast.selector, _NOW + 365 days)
    );
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.ACTIVE);
  }

  function test_WhenAGuardianBlockIsSet_SetStatusActiveDoesNotClearIt() external {
    _active(_kyc, _subject);
    vm.prank(_guardian);
    _registry.blockSubject(_subject);
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.ACTIVE);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.BLOCKED));
  }
}

contract CredentialRegistryUnit_Guardian is CredentialRegistryUnitTest {
  function test_WhenBlockingAsAnyoneButTheGuardian_ItReverts() external {
    vm.expectRevert(_unauthorized(_admin, _registry.GUARDIAN_ROLE()));
    vm.prank(_admin);
    _registry.blockSubject(_subject);

    vm.expectRevert(_unauthorized(_kyc, _registry.GUARDIAN_ROLE()));
    vm.prank(_kyc);
    _registry.blockSubject(_subject);

    vm.expectRevert(_unauthorized(_recovery, _registry.GUARDIAN_ROLE()));
    vm.prank(_recovery);
    _registry.blockSubject(_subject);
  }

  function test_WhenTheGuardianBlocks_TheAddressReadsBlockedAndAnEventIsEmitted() external {
    _active(_kyc, _subject);
    vm.expectEmit(address(_registry));
    emit ICredentialRegistry.SubjectBlocked(_subject, _guardian);
    vm.prank(_guardian);
    _registry.blockSubject(_subject);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.BLOCKED));
    assertFalse(_registry.isVerified(_subject));
  }

  function test_WhenBlockingTwice_NoSecondEventIsEmitted() external {
    vm.prank(_guardian);
    _registry.blockSubject(_subject);
    vm.recordLogs();
    vm.prank(_guardian);
    _registry.blockSubject(_subject);
    assertEq(vm.getRecordedLogs().length, 0);
  }

  function test_WhenBlockingAnAddressWithNoRecord_ItReadsBlockedAndALaterWriteIsBornBlocked() external {
    vm.prank(_guardian);
    _registry.blockSubject(_subject);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.BLOCKED));
    _active(_kyc, _subject);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.BLOCKED));
  }

  function test_WhenClearingAsTheAdminOrRecovery_TheBlockIsLifted() external {
    _active(_kyc, _subject);
    vm.prank(_guardian);
    _registry.blockSubject(_subject);

    vm.expectEmit(address(_registry));
    emit ICredentialRegistry.SubjectUnblocked(_subject, _admin);
    vm.prank(_admin);
    _registry.clearGuardianBlock(_subject);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.ACTIVE));

    vm.prank(_guardian);
    _registry.blockSubject(_subject);
    vm.expectEmit(address(_registry));
    emit ICredentialRegistry.SubjectUnblocked(_subject, _recovery);
    vm.prank(_recovery);
    _registry.clearGuardianBlock(_subject);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.ACTIVE));
  }

  function test_WhenClearingAsAnyoneElse_ItReverts() external {
    vm.prank(_guardian);
    _registry.blockSubject(_subject);
    vm.expectRevert(_unauthorized(_guardian, _registry.DEFAULT_ADMIN_ROLE()));
    vm.prank(_guardian);
    _registry.clearGuardianBlock(_subject);

    vm.expectRevert(_unauthorized(_kyc, _registry.DEFAULT_ADMIN_ROLE()));
    vm.prank(_kyc);
    _registry.clearGuardianBlock(_subject);

    vm.expectRevert(_unauthorized(_stranger, _registry.DEFAULT_ADMIN_ROLE()));
    vm.prank(_stranger);
    _registry.clearGuardianBlock(_subject);
  }

  function test_WhenClearingAnAddressThatIsNotBlocked_NoEventIsEmitted() external {
    vm.recordLogs();
    vm.prank(_admin);
    _registry.clearGuardianBlock(_subject);
    assertEq(vm.getRecordedLogs().length, 0);
  }

  function test_WhenKillingAsTheGuardianOrTheAdmin_TheAttesterIsKilled() external {
    vm.expectEmit(address(_registry));
    emit ICredentialRegistry.AttesterKilled(0, _guardian);
    vm.prank(_guardian);
    _registry.killAttester(0);
    assertTrue(_registry.attesterAt(0).killed);

    vm.expectEmit(address(_registry));
    emit ICredentialRegistry.AttesterKilled(1, _admin);
    vm.prank(_admin);
    _registry.killAttester(1);
    assertTrue(_registry.attesterAt(1).killed);
  }

  function test_WhenKillingAsAnyoneElse_ItReverts() external {
    vm.expectRevert(_unauthorized(_recovery, _registry.GUARDIAN_ROLE()));
    vm.prank(_recovery);
    _registry.killAttester(0);

    vm.expectRevert(_unauthorized(_stranger, _registry.GUARDIAN_ROLE()));
    vm.prank(_stranger);
    _registry.killAttester(0);
  }

  function test_WhenKillingAnUnknownAttester_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_UnknownAttester.selector, 9));
    vm.prank(_guardian);
    _registry.killAttester(9);
  }

  function test_WhenKillingTwice_NoSecondEventIsEmitted() external {
    vm.prank(_guardian);
    _registry.killAttester(0);
    vm.recordLogs();
    vm.prank(_guardian);
    _registry.killAttester(0);
    assertEq(vm.getRecordedLogs().length, 0);
  }

  function test_WhenAnAttesterIsKilled_ItsRecordsReadExitOnlyUntilItIsRevived() external {
    _active(_kyc, _subject);
    vm.prank(_guardian);
    _registry.killAttester(0);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.EXIT_ONLY));

    vm.expectEmit(address(_registry));
    emit ICredentialRegistry.AttesterRevived(0, _recovery);
    vm.prank(_recovery);
    _registry.reviveAttester(0);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.ACTIVE));
  }

  function test_WhenRevivingAsTheAdmin_ItWorks() external {
    vm.prank(_guardian);
    _registry.killAttester(0);
    vm.prank(_admin);
    _registry.reviveAttester(0);
    assertFalse(_registry.attesterAt(0).killed);
  }

  function test_WhenRevivingAsTheGuardianOrAStranger_ItReverts() external {
    vm.prank(_guardian);
    _registry.killAttester(0);
    vm.expectRevert(_unauthorized(_guardian, _registry.DEFAULT_ADMIN_ROLE()));
    vm.prank(_guardian);
    _registry.reviveAttester(0);

    vm.expectRevert(_unauthorized(_stranger, _registry.DEFAULT_ADMIN_ROLE()));
    vm.prank(_stranger);
    _registry.reviveAttester(0);
  }

  function test_WhenRevivingAnUnknownAttester_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(ICredentialRegistry.CredentialRegistry_UnknownAttester.selector, 9));
    vm.prank(_admin);
    _registry.reviveAttester(9);
  }

  function test_WhenRevivingAnAttesterThatIsNotKilled_NoEventIsEmitted() external {
    vm.recordLogs();
    vm.prank(_admin);
    _registry.reviveAttester(0);
    assertEq(vm.getRecordedLogs().length, 0);
  }
}

contract CredentialRegistryUnit_ProfileOf is CredentialRegistryUnitTest {
  function test_WhenNeverWritten_ItReadsNone() external view {
    (ICredentialRegistry.Status _s, uint32 _quals, uint8 _attester) = _registry.profileOf(_subject);
    assertEq(uint8(_s), uint8(ICredentialRegistry.Status.NONE));
    assertEq(_quals, 0);
    assertEq(_attester, 0);
    assertFalse(_registry.isVerified(_subject));
  }

  function test_WhenActiveAndWithinValidity_ItReadsActiveWithTheStoredFields() external {
    _set(_attester1, _subject, uint64(_NOW + 5 days), Quals.KYC | Quals.LICENSED);
    (ICredentialRegistry.Status _s, uint32 _quals, uint8 _attester) = _registry.profileOf(_subject);
    assertEq(uint8(_s), uint8(ICredentialRegistry.Status.ACTIVE));
    assertEq(_quals, Quals.KYC | Quals.LICENSED);
    assertEq(_attester, 1);
    assertTrue(_registry.isVerified(_subject));
  }

  function test_WhenAtTheLastSecondOfValidity_ItIsStillActiveAndTheNextSecondItIsLapsed() external {
    _set(_kyc, _subject, uint64(_NOW + 5 days), Quals.KYC);
    vm.warp(_NOW + 5 days);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.ACTIVE));
    vm.warp(_NOW + 5 days + 1);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.LAPSED));
    assertFalse(_registry.isVerified(_subject));
  }

  function test_WhenExitOnlyIsStored_ItStaysExitOnlyPastTheValidity() external {
    _set(_kyc, _subject, uint64(_NOW + 5 days), Quals.KYC);
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.EXIT_ONLY);
    vm.warp(_NOW + 6 days);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.EXIT_ONLY));
  }

  function test_WhenBlockedIsStored_ItStaysBlockedPastTheValidity() external {
    _set(_kyc, _subject, uint64(_NOW + 5 days), Quals.KYC);
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.BLOCKED);
    vm.warp(_NOW + 6 days);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.BLOCKED));
  }

  function test_WhenTheAttesterIsKilled_ItBeatsLapsed() external {
    _set(_kyc, _subject, uint64(_NOW + 5 days), Quals.KYC);
    vm.prank(_guardian);
    _registry.killAttester(0);
    vm.warp(_NOW + 6 days);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.EXIT_ONLY));
  }

  function test_WhenTheGuardianBlocks_ItBeatsEverything() external {
    _set(_kyc, _subject, uint64(_NOW + 5 days), Quals.KYC);
    vm.prank(_kyc);
    _registry.setStatus(_subject, ICredentialRegistry.Status.EXIT_ONLY);
    vm.prank(_guardian);
    _registry.killAttester(0);
    vm.prank(_guardian);
    _registry.blockSubject(_subject);
    vm.warp(_NOW + 6 days);
    assertEq(uint8(_status(_subject)), uint8(ICredentialRegistry.Status.BLOCKED));
  }

  function test_WhenAnythingIsStored_IsVerifiedIsTrueOnlyForActive(
    uint8 _stored,
    uint32 _wait
  ) external {
    _active(_kyc, _subject);
    _stored = uint8(bound(_stored, 1, 3));
    if (_stored != 1) {
      vm.prank(_kyc);
      _registry.setStatus(_subject, ICredentialRegistry.Status(_stored));
    }
    vm.warp(_NOW + bound(_wait, 0, 400 days));
    assertEq(_registry.isVerified(_subject), _status(_subject) == ICredentialRegistry.Status.ACTIVE);
  }
}

contract CredentialRegistryUnit_Roles is CredentialRegistryUnitTest {
  function test_WhenRecoveryRevokesTheGuardian_ItWorks() external {
    bytes32 _role = _registry.GUARDIAN_ROLE();
    vm.prank(_recovery);
    _registry.revokeRole(_role, _guardian);
    assertFalse(_registry.hasRole(_role, _guardian));
  }

  function test_WhenRecoveryRevokesAnythingElse_ItReverts() external {
    bytes32 _adminRole = _registry.DEFAULT_ADMIN_ROLE();
    bytes32 _recoveryRole = _registry.RECOVERY_ROLE();
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    vm.prank(_recovery);
    _registry.revokeRole(_adminRole, _admin);

    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    vm.prank(_recovery);
    _registry.revokeRole(_recoveryRole, _recovery);
  }

  function test_WhenRecoveryTriesToGrant_ItReverts() external {
    bytes32 _adminRole = _registry.DEFAULT_ADMIN_ROLE();
    bytes32 _guardianRole = _registry.GUARDIAN_ROLE();
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    vm.prank(_recovery);
    _registry.grantRole(_guardianRole, _recovery);
  }

  function test_WhenAStrangerRevokesTheGuardian_ItReverts() external {
    bytes32 _role = _registry.GUARDIAN_ROLE();
    vm.expectRevert(_unauthorized(_stranger, _registry.DEFAULT_ADMIN_ROLE()));
    vm.prank(_stranger);
    _registry.revokeRole(_role, _guardian);
  }

  function test_WhenTheAdminGrantsAndRevokes_ItWorks() external {
    bytes32 _role = _registry.GUARDIAN_ROLE();
    vm.startPrank(_admin);
    _registry.grantRole(_role, _stranger);
    assertTrue(_registry.hasRole(_role, _stranger));
    _registry.revokeRole(_role, _stranger);
    assertFalse(_registry.hasRole(_role, _stranger));
    vm.stopPrank();
  }
}

contract CredentialRegistryUnit_CredentialHash is CredentialRegistryUnitTest {
  function test_WhenHashing_ItIsTheEip712DigestOfTheTypedData() external view {
    ICredentialRegistry.Credential memory _c = _credential(_subject, uint64(_NOW + 1 days), Quals.KYC, uint64(_NOW), 2);
    bytes32 _structHash = keccak256(
      abi.encode(_registry.CREDENTIAL_TYPEHASH(), _c.subject, _c.validUntil, _c.quals, _c.issuedAt, _c.attester)
    );
    bytes32 _domain = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
        keccak256('CredentialRegistry'),
        keccak256('1'),
        block.chainid,
        address(_registry)
      )
    );
    assertEq(_registry.credentialHash(_c), keccak256(abi.encodePacked('\x19\x01', _domain, _structHash)));
  }
}

/// @notice Random writers and enforcement actions. Rejections are expected and counted: the invariants hold after every
///         outcome
contract CredentialRegistryHandler is Helpers {
  uint256 internal constant _START = 1_792_198_800;

  CredentialRegistry internal _registry;
  address internal _admin;
  address internal _guardian;
  address internal _recovery;
  address[3] internal _attesters; // ids 0, 1, 2
  uint256 internal _signerPk; // the key of attester 2
  address[3] internal _subjects;

  /// @notice Actions the handler took
  uint256 public actions;
  /// @notice Calls the registry rejected
  uint256 public rejections;
  /// @notice Writes and status changes the registry accepted
  uint256 public writes;
  /// @notice Times a record's `issuedAt` went down
  uint256 public issuedAtDecreases;
  /// @notice The handler's own record of who the guardian blocked and nobody has cleared, kept apart from the registry
  mapping(address _subject => bool _blocked) public ghostBlocked;

  constructor(
    CredentialRegistry _registryArg,
    address _adminArg,
    address _guardianArg,
    address _recoveryArg,
    address[3] memory _attestersArg,
    uint256 _signerPkArg
  ) {
    _registry = _registryArg;
    _admin = _adminArg;
    _guardian = _guardianArg;
    _recovery = _recoveryArg;
    _attesters = _attestersArg;
    _signerPk = _signerPkArg;
    _subjects = [makeAddr('s0'), makeAddr('s1'), makeAddr('s2')];
  }

  function subjects() external view returns (address[3] memory _all) {
    _all = _subjects;
  }

  function set(
    uint8 _who,
    uint8 _by,
    uint64 _until,
    uint32 _quals
  ) external {
    address _subject = _subjects[_who % 3];
    uint64 _before = _registry.recordOf(_subject).issuedAt;
    _until = uint64(bound(_until, 0, block.timestamp + 400 days));
    vm.prank(_attesters[_by % 3]);
    try _registry.set(_subject, _until, _quals) {
      ++writes;
    } catch {
      ++rejections;
    }
    _after(_subject, _before);
  }

  function register(
    uint8 _who,
    uint64 _until,
    uint64 _issuedAt
  ) external {
    address _subject = _subjects[_who % 3];
    uint64 _before = _registry.recordOf(_subject).issuedAt;
    _until = uint64(bound(_until, 0, block.timestamp + 400 days));
    _issuedAt = uint64(bound(_issuedAt, 0, block.timestamp + 1 days));
    ICredentialRegistry.Credential memory _c = ICredentialRegistry.Credential({
      subject: _subject, validUntil: _until, quals: Quals.KYC, issuedAt: _issuedAt, attester: 2
    });
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_signerPk, _registry.credentialHash(_c));
    try _registry.register(_c, abi.encodePacked(_r, _s, _v)) {
      ++writes;
    } catch {
      ++rejections;
    }
    _after(_subject, _before);
  }

  function setStatus(
    uint8 _who,
    uint8 _by,
    uint8 _status
  ) external {
    address _subject = _subjects[_who % 3];
    uint64 _before = _registry.recordOf(_subject).issuedAt;
    vm.prank(_attesters[_by % 3]);
    try _registry.setStatus(_subject, ICredentialRegistry.Status(_status % 5)) {
      ++writes;
    } catch {
      ++rejections;
    }
    _after(_subject, _before);
  }

  function blockSubject(
    uint8 _who
  ) external {
    address _subject = _subjects[_who % 3];
    uint64 _before = _registry.recordOf(_subject).issuedAt;
    vm.prank(_guardian);
    _registry.blockSubject(_subject);
    ghostBlocked[_subject] = true;
    _after(_subject, _before);
  }

  function clearBlock(
    uint8 _who,
    bool _byRecovery
  ) external {
    address _subject = _subjects[_who % 3];
    uint64 _before = _registry.recordOf(_subject).issuedAt;
    vm.prank(_byRecovery ? _recovery : _admin);
    _registry.clearGuardianBlock(_subject);
    ghostBlocked[_subject] = false;
    _after(_subject, _before);
  }

  function killOrRevive(
    uint8 _id,
    bool _kill
  ) external {
    vm.prank(_kill ? _guardian : _admin);
    if (_kill) _registry.killAttester(_id % 3);
    else _registry.reviveAttester(_id % 3);
    ++actions;
  }

  function warp(
    uint32 _seconds
  ) external {
    vm.warp(block.timestamp + bound(_seconds, 0, 30 days));
    ++actions;
  }

  function _after(
    address _subject,
    uint64 _before
  ) internal {
    if (_registry.recordOf(_subject).issuedAt < _before) ++issuedAtDecreases;
    ++actions;
  }
}

contract CredentialRegistryInvariantTest is CredentialRegistryUnitTest {
  CredentialRegistryHandler internal _handler;

  function setUp() public override {
    super.setUp();
    address[3] memory _atts = [_kyc, _attester1, _signer];
    _handler = new CredentialRegistryHandler(_registry, _admin, _guardian, _recovery, _atts, _signerPk);
    targetContract(address(_handler));
  }

  /// @dev A record's `issuedAt` never goes down, whatever the sequence of writes, statuses, blocks and kills
  function invariant_IssuedAtNeverDecreases() external view {
    assertEq(_handler.issuedAtDecreases(), 0);
  }

  /// @dev An address that reads ACTIVE is within its validity
  function invariant_ActiveIsAlwaysWithinValidity() external view {
    address[3] memory _all = _handler.subjects();
    for (uint256 _i; _i < 3; ++_i) {
      if (_status(_all[_i]) == ICredentialRegistry.Status.ACTIVE) {
        assertGe(_registry.recordOf(_all[_i]).validUntil, block.timestamp);
      }
    }
  }

  /// @dev An address the guardian blocked reads BLOCKED until a timelock path clears it. The handler keeps its own
  ///      record of the blocks, so a registry that lost the flag would be caught
  function invariant_AGuardianBlockAlwaysReadsBlocked() external view {
    address[3] memory _all = _handler.subjects();
    for (uint256 _i; _i < 3; ++_i) {
      if (_handler.ghostBlocked(_all[_i])) {
        assertEq(uint8(_status(_all[_i])), uint8(ICredentialRegistry.Status.BLOCKED));
      }
    }
  }

  /// @dev Non-vacuity: every run executes actions. That the handler can reach both a write and a rejection is shown by
  ///      `test_WhenTheHandlerRuns_ItReachesAWriteAndARejection`, and that the invariants can fail by the mutation run
  function afterInvariant() external view {
    assertGt(_handler.actions(), 0, 'no action executed');
  }

  function test_WhenTheHandlerRuns_ItReachesAWriteAndARejection() external {
    _handler.set(1, 1, uint64(_NOW + 30 days), Quals.KYC); // attester 1 may assert anything: accepted
    assertEq(_handler.writes(), 1);
    assertEq(_handler.rejections(), 0);
    _handler.set(0, 0, uint64(_NOW + 30 days), Quals.FUND); // attester 0 may not assert FUND: rejected
    assertEq(_handler.rejections(), 1);
    assertEq(_handler.actions(), 2);
  }
}
