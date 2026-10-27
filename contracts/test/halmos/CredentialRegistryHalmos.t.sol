// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {ICredentialRegistry} from 'interfaces/ICredentialRegistry.sol';
import {Quals} from 'interfaces/Quals.sol';

import {CredentialRegistry} from 'contracts/identity/CredentialRegistry.sol';

/// @notice An ERC-1271 account that accepts every signature, so the symbolic run exercises the registry's own guards
///         and not signature recovery
contract CredentialRegistryHalmosSigner {
  function isValidSignature(
    bytes32,
    bytes calldata
  ) external pure returns (bytes4 _magic) {
    _magic = 0x1626ba7e;
  }
}

/**
 * @notice Halmos symbolic properties on the credential registry
 * @dev Run with `npm run test:halmos`. Hardhat compiles this file but does not run `check_` functions.
 *      Halmos discards reverting paths, so a property that must revert turns a success into `assert(false)` explicitly
 */
contract CredentialRegistryHalmos is Test {
  CredentialRegistry internal _registry;
  address internal _subject = address(0xA1);
  address internal _signerAccount;

  function setUp() public {
    _registry = new CredentialRegistry(address(this), address(this));
    _registry.addAttester(address(this), type(uint32).max); // id 0, writes directly
    _signerAccount = address(new CredentialRegistryHalmosSigner());
    _registry.addAttester(_signerAccount, type(uint32).max); // id 1, signs with a stub that accepts anything
    vm.warp(1_792_198_800);
  }

  /// @dev An `ACTIVE` record reads ACTIVE through its last second and LAPSED after it, for any validity and any time
  function check_ARecordLapsesExactlyAfterItsValidity(
    uint64 _validUntil,
    uint256 _later
  ) external {
    vm.assume(_validUntil > block.timestamp);
    _registry.set(_subject, _validUntil, Quals.KYC, 756);
    vm.assume(_later >= block.timestamp && _later <= type(uint64).max);
    vm.warp(_later);

    (ICredentialRegistry.Status _status,,,) = _registry.profileOf(_subject);
    if (_later <= _validUntil) assert(_status == ICredentialRegistry.Status.ACTIVE);
    else assert(_status == ICredentialRegistry.Status.LAPSED);
  }

  /// @dev A guardian block survives any later write by an attester and any later status change
  function check_AGuardianBlockSurvivesEveryWrite(
    uint64 _validUntil,
    uint32 _quals,
    uint8 _status
  ) external {
    _registry.blockSubject(_subject);
    vm.assume(_validUntil > block.timestamp);
    _registry.set(_subject, _validUntil, _quals, 756);
    (ICredentialRegistry.Status _afterSet,,,) = _registry.profileOf(_subject);
    assert(_afterSet == ICredentialRegistry.Status.BLOCKED);

    vm.assume(_status >= 1 && _status <= 3);
    _registry.setStatus(_subject, ICredentialRegistry.Status(_status));
    (ICredentialRegistry.Status _afterStatus,,,) = _registry.profileOf(_subject);
    assert(_afterStatus == ICredentialRegistry.Status.BLOCKED);
  }

  /// @dev A signed credential no newer than the stored record never gets in, whoever signed it and whatever it says.
  ///      Both credentials come from attester 1, since the registry refuses to overwrite another active attester's
  ///      record for a different reason. The call is low level, so a revert is an `ok == false` path and not a discarded
  ///      one. The next property is the control: with a newer `issuedAt` the same call succeeds, so the stub signer and
  ///      the setup are not what stops the stale one
  function check_ASignedCredentialCannotLowerIssuedAt(
    uint64 _validUntil,
    uint64 _issuedAt
  ) external {
    vm.assume(_validUntil > block.timestamp + 1 hours);
    uint64 _stored = uint64(block.timestamp);
    _registry.register(_signed(_validUntil, _stored), ''); // stores issuedAt = _stored, by attester 1
    vm.warp(block.timestamp + 1 hours);
    vm.assume(_issuedAt <= _stored);

    (bool _ok,) =
      address(_registry).call(abi.encodeCall(_registry.register, (_signed(_validUntil, _issuedAt), bytes(''))));
    assert(!_ok);
  }

  /// @dev Control for the property above: a credential issued after the stored record, within the present, is accepted
  function check_AFresherSignedCredentialIsAccepted(
    uint64 _validUntil,
    uint64 _issuedAt
  ) external {
    vm.assume(_validUntil > block.timestamp + 1 hours);
    uint64 _stored = uint64(block.timestamp);
    _registry.register(_signed(_validUntil, _stored), '');
    vm.warp(block.timestamp + 1 hours);
    vm.assume(_issuedAt > _stored && _issuedAt <= block.timestamp);

    _registry.register(_signed(_validUntil, _issuedAt), '');
    assert(_registry.recordOf(_subject).issuedAt == _issuedAt);
  }

  function _signed(
    uint64 _validUntil,
    uint64 _issuedAt
  ) internal view returns (ICredentialRegistry.Credential memory _c) {
    _c = ICredentialRegistry.Credential({
      subject: _subject, validUntil: _validUntil, quals: Quals.KYC, country: 756, issuedAt: _issuedAt, attester: 1
    });
  }

  /// @dev Whatever the attester writes or sets, the stored `issuedAt` never goes down
  function check_IssuedAtNeverGoesDown(
    uint64 _validUntil,
    uint8 _status
  ) external {
    vm.assume(_validUntil > block.timestamp);
    _registry.set(_subject, _validUntil, Quals.KYC, 756);
    uint64 _first = _registry.recordOf(_subject).issuedAt;
    vm.warp(block.timestamp + 1 hours);

    vm.assume(_status >= 1 && _status <= 3);
    _registry.setStatus(_subject, ICredentialRegistry.Status(_status));
    uint64 _second = _registry.recordOf(_subject).issuedAt;
    assert(_second >= _first);
  }
}
