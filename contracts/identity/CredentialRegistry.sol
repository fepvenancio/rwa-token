// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';
import {SignatureChecker} from '@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

import {ICredentialRegistry} from 'interfaces/ICredentialRegistry.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';

/**
 * @title CredentialRegistry
 * @notice The record of who vouched for each address, what it is and until when, as specified in
 *         `ICredentialRegistry`. Not a proxy: a schema change means a new registry, a new rule and `setRules`
 * @dev Stores flags only. The effective status is resolved at read time, so `CredentialRule` does no time or trust
 *      arithmetic. A killed attester is one bit in a mask read once per call, so checking two parties costs one extra
 *      cold read, not two. Attester ids are never reused, so a record can never be revived by a new attester
 */
contract CredentialRegistry is AccessControl, EIP712, ICredentialRegistry, IIdentityRegistry {
  using SafeCast for uint256;

  /**
   * @notice An attester as stored. Whether it is killed lives in `_killedMask`
   * @param account The account, or the ERC-1271 contract, whose key signs
   * @param allowedQuals The bits the attester may assert
   */
  struct AttesterData {
    address account;
    uint32 allowedQuals;
  }

  /// @inheritdoc ICredentialRegistry
  bytes32 public constant GUARDIAN_ROLE = keccak256('GUARDIAN_ROLE');

  /// @inheritdoc ICredentialRegistry
  bytes32 public constant RECOVERY_ROLE = keccak256('RECOVERY_ROLE');

  /// @inheritdoc ICredentialRegistry
  bytes32 public constant CREDENTIAL_TYPEHASH = keccak256(
    'Credential(address subject,uint64 validUntil,uint32 quals,uint16 country,uint64 issuedAt,uint8 attester)'
  );

  /// @inheritdoc ICredentialRegistry
  uint256 public constant MAX_ATTESTERS = 64;

  /// @notice The stored record of each address
  mapping(address _subject => Record _record) internal _records;

  /// @notice The attesters, indexed by id. Append only
  AttesterData[] internal _attesters;

  /// @notice Attester id plus one for each attester account; zero when the account is not an attester
  mapping(address _account => uint256 _idPlusOne) internal _attesterSlot;

  /// @notice Bit `i` is set when attester `i` is killed
  uint64 internal _killedMask;

  /**
   * @notice Deploys the registry
   * @param _admin The account granted DEFAULT_ADMIN_ROLE. The deployer until `Activate` hands over to the timelock
   * @param _guardian The guardian multisig, granted GUARDIAN_ROLE; it can only block addresses and kill attesters
   */
  constructor(
    address _admin,
    address _guardian
  ) EIP712('CredentialRegistry', '1') {
    if (_admin == address(0) || _guardian == address(0)) revert CredentialRegistry_ZeroAddress();
    // _grantRole returns false only if the role is already held; either way the account ends up holding it.
    // aderyn-ignore-next-line(unchecked-return)
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    // As above.
    // aderyn-ignore-next-line(unchecked-return)
    _grantRole(GUARDIAN_ROLE, _guardian);
  }

  /// @inheritdoc ICredentialRegistry
  function addAttester(
    address _account,
    uint32 _allowedQuals
  ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint8 _id) {
    if (_account == address(0)) revert CredentialRegistry_ZeroAddress();
    if (_attesterSlot[_account] != 0) revert CredentialRegistry_AttesterExists(_account);
    uint256 _count = _attesters.length;
    if (_count >= MAX_ATTESTERS) revert CredentialRegistry_TooManyAttesters();

    _id = uint8(_count);
    _attesters.push(AttesterData({account: _account, allowedQuals: _allowedQuals}));
    _attesterSlot[_account] = _count + 1;
    emit AttesterAdded(_id, _account, _allowedQuals);
  }

  /// @inheritdoc ICredentialRegistry
  function blockSubject(
    address _subject
  ) external onlyRole(GUARDIAN_ROLE) {
    Record memory _record = _records[_subject];
    if (_record.guardianBlock) return;
    _record.guardianBlock = true;
    _records[_subject] = _record;
    emit SubjectBlocked(_subject, _msgSender());
  }

  /// @inheritdoc ICredentialRegistry
  function clearGuardianBlock(
    address _subject
  ) external {
    _checkAdminOrRecovery();
    Record memory _record = _records[_subject];
    if (!_record.guardianBlock) return;
    _record.guardianBlock = false;
    _records[_subject] = _record;
    emit SubjectUnblocked(_subject, _msgSender());
  }

  /// @inheritdoc ICredentialRegistry
  function killAttester(
    uint8 _id
  ) external {
    address _sender = _msgSender();
    if (!hasRole(GUARDIAN_ROLE, _sender) && !hasRole(DEFAULT_ADMIN_ROLE, _sender)) {
      revert AccessControlUnauthorizedAccount(_sender, GUARDIAN_ROLE);
    }
    _requireAttester(_id);
    uint64 _bit = uint64(1) << _id;
    if (_killedMask & _bit != 0) return;
    _killedMask |= _bit;
    emit AttesterKilled(_id, _sender);
  }

  /// @inheritdoc ICredentialRegistry
  function register(
    Credential calldata _credential,
    bytes calldata _sig
  ) external {
    uint8 _id = _credential.attester;
    _requireAttester(_id);
    if (_isKilled(_id)) revert CredentialRegistry_AttesterKilled(_id);
    if (_credential.issuedAt > block.timestamp) revert CredentialRegistry_IssuedInFuture(_credential.issuedAt);
    if (!SignatureChecker.isValidSignatureNow(_attesters[_id].account, credentialHash(_credential), _sig)) {
      revert CredentialRegistry_BadSignature();
    }
    uint64 _stored = _records[_credential.subject].issuedAt;
    if (_credential.issuedAt <= _stored) revert CredentialRegistry_StaleCredential(_credential.issuedAt, _stored);

    _write(
      _id, _credential.subject, _credential.validUntil, _credential.quals, _credential.country, _credential.issuedAt
    );
  }

  /// @inheritdoc ICredentialRegistry
  function reviveAttester(
    uint8 _id
  ) external {
    _checkAdminOrRecovery();
    _requireAttester(_id);
    uint64 _bit = uint64(1) << _id;
    if (_killedMask & _bit == 0) return;
    _killedMask &= ~_bit;
    emit AttesterRevived(_id, _msgSender());
  }

  /// @inheritdoc ICredentialRegistry
  function set(
    address _subject,
    uint64 _validUntil,
    uint32 _quals,
    uint16 _country
  ) external {
    uint256 _slot = _attesterSlot[_msgSender()];
    if (_slot == 0) revert CredentialRegistry_NotAnAttester(_msgSender());
    _write(uint8(_slot - 1), _subject, _validUntil, _quals, _country, block.timestamp.toUint64());
  }

  /// @inheritdoc ICredentialRegistry
  function setAttesterAccount(
    uint8 _id,
    address _account
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _requireAttester(_id);
    if (_account == address(0)) revert CredentialRegistry_ZeroAddress();
    if (_attesterSlot[_account] != 0) revert CredentialRegistry_AttesterExists(_account);
    address _oldAccount = _attesters[_id].account;
    delete _attesterSlot[_oldAccount];
    _attesterSlot[_account] = uint256(_id) + 1;
    _attesters[_id].account = _account;
    emit AttesterAccountSet(_id, _oldAccount, _account);
  }

  /// @inheritdoc ICredentialRegistry
  function setAttesterQuals(
    uint8 _id,
    uint32 _allowedQuals
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _requireAttester(_id);
    _attesters[_id].allowedQuals = _allowedQuals;
    emit AttesterQualsSet(_id, _allowedQuals);
  }

  /// @inheritdoc ICredentialRegistry
  function setStatus(
    address _subject,
    Status _status
  ) external {
    uint256 _slot = _attesterSlot[_msgSender()];
    if (_slot == 0) revert CredentialRegistry_NotAnAttester(_msgSender());
    uint8 _id = uint8(_slot - 1);
    if (_status == Status.NONE || _status == Status.LAPSED) revert CredentialRegistry_InvalidStatus(_status);
    if (_isKilled(_id)) revert CredentialRegistry_AttesterKilled(_id);

    Record memory _record = _records[_subject];
    if (_record.status == Status.NONE) revert CredentialRegistry_NoRecord(_subject);
    if (_record.attester != _id) revert CredentialRegistry_NotRecordAttester(_subject, _record.attester);
    if (_status == Status.ACTIVE && _record.validUntil <= block.timestamp) {
      revert CredentialRegistry_ValidityInPast(_record.validUntil);
    }

    _record.status = _status;
    _record.issuedAt = block.timestamp.toUint64();
    _records[_subject] = _record;
    emit StatusSet(_subject, _id, _status);
  }

  /// @inheritdoc ICredentialRegistry
  function attesterAt(
    uint8 _id
  ) external view returns (Attester memory _attester) {
    _requireAttester(_id);
    AttesterData storage _data = _attesters[_id];
    _attester = Attester({account: _data.account, allowedQuals: _data.allowedQuals, killed: _isKilled(_id)});
  }

  /// @inheritdoc ICredentialRegistry
  function attesterCount() external view returns (uint256 _count) {
    _count = _attesters.length;
  }

  /// @inheritdoc ICredentialRegistry
  function attesterIdOf(
    address _account
  ) external view returns (bool _found, uint8 _id) {
    uint256 _slot = _attesterSlot[_account];
    if (_slot == 0) return (false, 0);
    _found = true;
    _id = uint8(_slot - 1);
  }

  /// @inheritdoc IIdentityRegistry
  function isVerified(
    address _user
  ) external view returns (bool _verified) {
    (Status _status,,,) = profileOf(_user);
    // Compares an enum standing with a constant, not a balance.
    // slither-disable-next-line incorrect-equality
    _verified = _status == Status.ACTIVE;
  }

  /// @inheritdoc ICredentialRegistry
  function recordOf(
    address _subject
  ) external view returns (Record memory _record) {
    _record = _records[_subject];
  }

  /**
   * @inheritdoc AccessControl
   * @dev RECOVERY_ROLE may revoke GUARDIAN_ROLE and nothing else; every other revocation needs the role's admin
   */
  function revokeRole(
    bytes32 _role,
    address _account
  ) public override {
    if (_role == GUARDIAN_ROLE && hasRole(RECOVERY_ROLE, _msgSender())) {
      // _revokeRole returns false only if the role was not held; either way the account ends up without it.
      // aderyn-ignore-next-line(unchecked-return)
      _revokeRole(_role, _account);
      return;
    }
    super.revokeRole(_role, _account);
  }

  /// @inheritdoc ICredentialRegistry
  function credentialHash(
    Credential calldata _credential
  ) public view returns (bytes32 _hash) {
    _hash = _hashTypedDataV4(
      keccak256(
        abi.encode(
          CREDENTIAL_TYPEHASH,
          _credential.subject,
          _credential.validUntil,
          _credential.quals,
          _credential.country,
          _credential.issuedAt,
          _credential.attester
        )
      )
    );
  }

  /// @inheritdoc ICredentialRegistry
  function profileOf(
    address _subject
  ) public view returns (Status _status, uint32 _quals, uint16 _country, uint8 _attester) {
    Record memory _record = _records[_subject];
    _quals = _record.quals;
    _country = _record.country;
    _attester = _record.attester;

    // The equalities compare enum standings with constants, not balances. The one on time is a strict `>`, by design:
    // a record reads ACTIVE through its last second (test: *_AtTheLastSecondOfValidity_*).
    // slither-disable-start incorrect-equality
    if (_record.guardianBlock || _record.status == Status.BLOCKED) {
      _status = Status.BLOCKED;
    } else if (_record.status == Status.NONE) {
      _status = Status.NONE;
    } else if (_isKilled(_record.attester)) {
      _status = Status.EXIT_ONLY;
    } else if (_record.status == Status.ACTIVE && block.timestamp > _record.validUntil) {
      _status = Status.LAPSED;
    } else {
      _status = _record.status;
    }
    // slither-disable-end incorrect-equality
  }

  /// @inheritdoc AccessControl
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(ICredentialRegistry).interfaceId
      || _interfaceId == type(IIdentityRegistry).interfaceId || super.supportsInterface(_interfaceId);
  }

  /**
   * @notice Writes a record as `ACTIVE` after every check shared by the direct and the signed path
   * @dev A guardian block already on the record is kept. An attester may overwrite a record only if the address has
   *      none, the same attester wrote it, or the attester that wrote it is killed
   * @param _id The writing attester
   * @param _subject The address
   * @param _validUntil Unix seconds
   * @param _quals The qualification bits
   * @param _country The country code
   * @param _issuedAt When the record was issued
   */
  function _write(
    uint8 _id,
    address _subject,
    uint64 _validUntil,
    uint32 _quals,
    uint16 _country,
    uint64 _issuedAt
  ) internal {
    if (_subject == address(0)) revert CredentialRegistry_ZeroAddress();
    if (_isKilled(_id)) revert CredentialRegistry_AttesterKilled(_id);
    uint32 _allowed = _attesters[_id].allowedQuals;
    if (_quals & ~_allowed != 0) revert CredentialRegistry_QualsNotAllowed(_id, _quals, _allowed);
    if (_validUntil <= block.timestamp) revert CredentialRegistry_ValidityInPast(_validUntil);

    Record memory _existing = _records[_subject];
    if (_existing.status != Status.NONE && _existing.attester != _id && !_isKilled(_existing.attester)) {
      revert CredentialRegistry_RecordOwnedByAnotherAttester(_subject, _existing.attester);
    }

    _records[_subject] = Record({
      validUntil: _validUntil,
      status: Status.ACTIVE,
      quals: _quals,
      country: _country,
      attester: _id,
      issuedAt: _issuedAt,
      guardianBlock: _existing.guardianBlock
    });
    emit CredentialSet(_subject, _id, _validUntil, _quals, _country, _issuedAt);
  }

  /**
   * @notice Reverts unless the caller holds DEFAULT_ADMIN_ROLE or RECOVERY_ROLE
   * @dev The guardian can cancel the main timelock's operations, so the recovery timelock must be able to undo what the
   *      guardian did. Anyone else gets the usual AccessControl error for DEFAULT_ADMIN_ROLE
   */
  function _checkAdminOrRecovery() internal view {
    address _sender = _msgSender();
    if (!hasRole(DEFAULT_ADMIN_ROLE, _sender) && !hasRole(RECOVERY_ROLE, _sender)) {
      revert AccessControlUnauthorizedAccount(_sender, DEFAULT_ADMIN_ROLE);
    }
  }

  /**
   * @notice Reverts unless an attester id exists
   * @param _id The attester id
   */
  function _requireAttester(
    uint8 _id
  ) internal view {
    if (_id >= _attesters.length) revert CredentialRegistry_UnknownAttester(_id);
  }

  /**
   * @notice Whether an attester is killed
   * @param _id The attester id, below `MAX_ATTESTERS`
   * @return _killed True if killed
   */
  function _isKilled(
    uint8 _id
  ) internal view returns (bool _killed) {
    _killed = _killedMask & (uint64(1) << _id) != 0;
  }
}
