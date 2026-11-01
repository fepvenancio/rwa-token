// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title ICredentialRegistry
 * @notice One record per address: who vouched for it (an attester), what it is (qualification bits), until when, and
 *         its standing. Attesters write records directly, or sign an EIP-712 credential off chain that
 *         anyone may submit. The registry stores flags only: no names, no evidence, no hashes of personal data
 * @dev The effective status is resolved at read time (`profileOf`), so a rule never does time or trust arithmetic.
 *      A lapsed credential and a killed attester both leave the holder able to exit. An explicit block does not.
 *      The guardian can only block an address or kill an attester; the main timelock and the recovery timelock undo it
 */
interface ICredentialRegistry {
  /*///////////////////////////////////////////////////////////////
                            ENUMS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The standing of an address
   * @param NONE Never written
   * @param ACTIVE Vouched for and within its validity: may send and receive
   * @param EXIT_ONLY May send, burn and redeem but not receive: set by the attester, or the attester was killed
   * @param BLOCKED May do nothing. Set by the attester or the guardian
   * @param LAPSED Returned by `profileOf` only, for an `ACTIVE` record past its `validUntil`. Never stored and never
   *        accepted as an input
   */
  enum Status {
    NONE,
    ACTIVE,
    EXIT_ONLY,
    BLOCKED,
    LAPSED
  }

  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The stored record of an address, one storage slot
   * @param validUntil Unix seconds. Non-zero and in the future when written as `ACTIVE`; the record reads `LAPSED` after it
   * @param status The stored status. Never `LAPSED`
   * @param quals The qualification bits (see `Quals`)
   * @param attester The id of the attester that wrote the record
   * @param issuedAt When the attester issued the record. Only ever rises for one address
   * @param guardianBlock Set by the guardian. Cleared only by `clearGuardianBlock`
   */
  struct Record {
    uint64 validUntil;
    Status status;
    uint32 quals;
    uint8 attester;
    uint64 issuedAt;
    bool guardianBlock;
  }

  /**
   * @notice An attester: an account allowed to write records, within a set of qualification bits
   * @param account The account, or the ERC-1271 contract, whose key signs
   * @param allowedQuals The bits the attester may assert
   * @param killed Set by the guardian or the admin: the attester can no longer write, and its records read `EXIT_ONLY`
   */
  struct Attester {
    address account;
    uint32 allowedQuals;
    bool killed;
  }

  /**
   * @notice The credential an attester signs (EIP-712 typed data)
   * @param subject The address the credential is about
   * @param validUntil Unix seconds; must be in the future when submitted
   * @param quals The qualification bits
   * @param issuedAt When the attester issued it; strictly above the stored value and not in the future
   * @param attester The id of the signing attester
   */
  struct Credential {
    address subject;
    uint64 validUntil;
    uint32 quals;
    uint64 issuedAt;
    uint8 attester;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when an attester writes a record as `ACTIVE`, directly or from a signed credential
   * @param _subject The address
   * @param _attester The attester id
   * @param _validUntil Unix seconds
   * @param _quals The qualification bits
   * @param _issuedAt When the record was issued
   */
  event CredentialSet(
    address indexed _subject, uint8 indexed _attester, uint64 _validUntil, uint32 _quals, uint64 _issuedAt
  );

  /**
   * @notice Emitted when an attester changes the status of its own record
   * @param _subject The address
   * @param _attester The attester id
   * @param _status The new stored status
   */
  event StatusSet(address indexed _subject, uint8 indexed _attester, Status _status);

  /**
   * @notice Emitted when the guardian blocks an address
   * @param _subject The address
   * @param _guardian The account that blocked it
   */
  event SubjectBlocked(address indexed _subject, address indexed _guardian);

  /**
   * @notice Emitted when a guardian block is cleared
   * @param _subject The address
   * @param _by The admin or recovery account that cleared it
   */
  event SubjectUnblocked(address indexed _subject, address indexed _by);

  /**
   * @notice Emitted when an attester is added
   * @param _id The attester id
   * @param _account The attester account
   * @param _allowedQuals The bits it may assert
   */
  event AttesterAdded(uint8 indexed _id, address indexed _account, uint32 _allowedQuals);

  /**
   * @notice Emitted when an attester's account changes (key rotation)
   * @param _id The attester id
   * @param _oldAccount The previous account
   * @param _newAccount The new account
   */
  event AttesterAccountSet(uint8 indexed _id, address indexed _oldAccount, address indexed _newAccount);

  /**
   * @notice Emitted when the bits an attester may assert change; records already written are not touched
   * @param _id The attester id
   * @param _allowedQuals The new allowed bits
   */
  event AttesterQualsSet(uint8 indexed _id, uint32 _allowedQuals);

  /**
   * @notice Emitted when an attester is killed
   * @param _id The attester id
   * @param _by The guardian or admin that killed it
   */
  event AttesterKilled(uint8 indexed _id, address indexed _by);

  /**
   * @notice Emitted when a killed attester is revived
   * @param _id The attester id
   * @param _by The admin or recovery account that revived it
   */
  event AttesterRevived(uint8 indexed _id, address indexed _by);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a required address argument is the zero address
  error CredentialRegistry_ZeroAddress();

  /**
   * @notice Thrown when the caller is not an attester
   * @param _caller The caller
   */
  error CredentialRegistry_NotAnAttester(address _caller);

  /**
   * @notice Thrown when an attester id does not exist
   * @param _id The id
   */
  error CredentialRegistry_UnknownAttester(uint8 _id);

  /**
   * @notice Thrown when a killed attester tries to write
   * @param _id The attester id
   */
  error CredentialRegistry_AttesterKilled(uint8 _id);

  /**
   * @notice Thrown when an account is already an attester
   * @param _account The account
   */
  error CredentialRegistry_AttesterExists(address _account);

  /// @notice Thrown when adding an attester beyond `MAX_ATTESTERS`
  error CredentialRegistry_TooManyAttesters();

  /**
   * @notice Thrown when a record asserts bits the attester may not assert
   * @param _id The attester id
   * @param _quals The bits asserted
   * @param _allowed The bits allowed
   */
  error CredentialRegistry_QualsNotAllowed(uint8 _id, uint32 _quals, uint32 _allowed);

  /**
   * @notice Thrown when an `ACTIVE` record would not be valid in the future
   * @param _validUntil The offered validity
   */
  error CredentialRegistry_ValidityInPast(uint64 _validUntil);

  /**
   * @notice Thrown when a status cannot be written (`NONE` and `LAPSED` never can)
   * @param _status The offered status
   */
  error CredentialRegistry_InvalidStatus(Status _status);

  /**
   * @notice Thrown when changing the status of an address that has no record
   * @param _subject The address
   */
  error CredentialRegistry_NoRecord(address _subject);

  /**
   * @notice Thrown when an attester changes the status of a record another attester wrote
   * @param _subject The address
   * @param _owner The attester id that wrote the record
   */
  error CredentialRegistry_NotRecordAttester(address _subject, uint8 _owner);

  /**
   * @notice Thrown when an attester would overwrite a record that belongs to another, active attester
   * @param _subject The address
   * @param _owner The attester id that wrote the record
   */
  error CredentialRegistry_RecordOwnedByAnotherAttester(address _subject, uint8 _owner);

  /// @notice Thrown when a credential's signature is not valid for its attester
  error CredentialRegistry_BadSignature();

  /**
   * @notice Thrown when a credential is not newer than the stored record
   * @param _issuedAt The credential's `issuedAt`
   * @param _stored The stored `issuedAt`
   */
  error CredentialRegistry_StaleCredential(uint64 _issuedAt, uint64 _stored);

  /**
   * @notice Thrown when a credential is issued in the future
   * @param _issuedAt The credential's `issuedAt`
   */
  error CredentialRegistry_IssuedInFuture(uint64 _issuedAt);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Adds an attester
   * @dev Only DEFAULT_ADMIN_ROLE. Ids are assigned in order and never reused
   * @param _account The attester account, or the ERC-1271 contract whose key signs
   * @param _allowedQuals The bits it may assert
   * @return _id The attester id
   */
  function addAttester(
    address _account,
    uint32 _allowedQuals
  ) external returns (uint8 _id);

  /**
   * @notice Blocks an address regardless of what any attester writes
   * @dev Only GUARDIAN_ROLE, with no delay. Idempotent: no event if already blocked. Works on an address that has no
   *      record yet, so a later write is born blocked
   * @param _subject The address
   */
  function blockSubject(
    address _subject
  ) external;

  /**
   * @notice Clears a guardian block
   * @dev Only DEFAULT_ADMIN_ROLE or RECOVERY_ROLE: the guardian can cancel the main timelock's operations, so the
   *      recovery timelock must be able to undo what the guardian did. Idempotent: no event if not blocked
   * @param _subject The address
   */
  function clearGuardianBlock(
    address _subject
  ) external;

  /**
   * @notice Kills an attester: it can no longer write, and its records read `EXIT_ONLY`
   * @dev Only GUARDIAN_ROLE or DEFAULT_ADMIN_ROLE, with no delay for the guardian. Idempotent: no event if already
   *      killed
   * @param _id The attester id
   */
  function killAttester(
    uint8 _id
  ) external;

  /**
   * @notice Submits a credential an attester signed off chain
   * @dev Anyone may submit. The signature is checked with ECDSA or ERC-1271 against the attester's account. Same checks
   *      as `set`, plus: `issuedAt` strictly above the stored one and not in the future, so an old credential can
   *      never overwrite a newer write, a status change or a block. Writes the record as `ACTIVE`
   * @param _credential The credential
   * @param _sig The attester's signature over `credentialHash(_credential)`
   */
  function register(
    Credential calldata _credential,
    bytes calldata _sig
  ) external;

  /**
   * @notice Revives a killed attester
   * @dev Only DEFAULT_ADMIN_ROLE or RECOVERY_ROLE. Idempotent: no event if not killed
   * @param _id The attester id
   */
  function reviveAttester(
    uint8 _id
  ) external;

  /**
   * @notice Writes a record as `ACTIVE`, directly
   * @dev Only an active attester, `issuedAt` is `block.timestamp`. `_quals` must be within the attester's allowed bits
   *      and `_validUntil` in the future. An attester may overwrite a record only if the address has none, the same
   *      attester wrote it, or the attester that wrote it is killed. A guardian block is kept
   * @param _subject The address
   * @param _validUntil Unix seconds
   * @param _quals The qualification bits
   */
  function set(
    address _subject,
    uint64 _validUntil,
    uint32 _quals
  ) external;

  /**
   * @notice Changes the stored status of the caller's own record
   * @dev Only the attester that wrote the record, while not killed. `ACTIVE` needs a `validUntil` in the future,
   *      `EXIT_ONLY` and `BLOCKED` are always allowed; `NONE` and `LAPSED` revert. Sets `issuedAt` to
   *      `block.timestamp`, so an older signed credential cannot overwrite it. Does not clear a guardian block
   * @param _subject The address
   * @param _status The new stored status
   */
  function setStatus(
    address _subject,
    Status _status
  ) external;

  /**
   * @notice Changes the account of an attester (key rotation) without reissuing its records
   * @dev Only DEFAULT_ADMIN_ROLE. Signatures by the old account stop working at once
   * @param _id The attester id
   * @param _account The new account
   */
  function setAttesterAccount(
    uint8 _id,
    address _account
  ) external;

  /**
   * @notice Changes the bits an attester may assert; records already written are not touched
   * @dev Only DEFAULT_ADMIN_ROLE
   * @param _id The attester id
   * @param _allowedQuals The new allowed bits
   */
  function setAttesterQuals(
    uint8 _id,
    uint32 _allowedQuals
  ) external;

  /**
   * @notice The number of attesters added so far
   * @return _count The count, at most `MAX_ATTESTERS`
   */
  function attesterCount() external view returns (uint256 _count);

  /**
   * @notice An attester by id
   * @param _id The attester id
   * @return _attester The attester
   */
  function attesterAt(
    uint8 _id
  ) external view returns (Attester memory _attester);

  /**
   * @notice The id of an attester account
   * @param _account The account
   * @return _found True if the account is an attester
   * @return _id The attester id; 0 when not found
   */
  function attesterIdOf(
    address _account
  ) external view returns (bool _found, uint8 _id);

  /**
   * @notice The EIP-712 digest an attester signs for a credential
   * @dev Domain: name "CredentialRegistry", version "1", chain id, verifying contract = this registry
   * @param _credential The credential
   * @return _hash The digest
   */
  function credentialHash(
    Credential calldata _credential
  ) external view returns (bytes32 _hash);

  /**
   * @notice The effective standing of an address, resolved now
   * @dev Order: a guardian block or a stored `BLOCKED` is `BLOCKED`; never written is `NONE`; a killed attester gives
   *      `EXIT_ONLY`; a stored `ACTIVE` past `validUntil` is `LAPSED`; otherwise the stored status
   * @param _subject The address
   * @return _status The effective status
   * @return _quals The qualification bits as stored
   * @return _attester The attester id that wrote the record
   */
  function profileOf(
    address _subject
  ) external view returns (Status _status, uint32 _quals, uint8 _attester);

  /**
   * @notice The stored record of an address, unresolved
   * @param _subject The address
   * @return _record The record
   */
  function recordOf(
    address _subject
  ) external view returns (Record memory _record);

  /**
   * @notice The most attesters the registry holds; also the width of a token policy's attester bitmap
   * @return _max 64
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function MAX_ATTESTERS() external view returns (uint256 _max);

  /**
   * @notice The EIP-712 type hash of `Credential`
   * @return _typehash keccak256 of the `Credential` type string
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function CREDENTIAL_TYPEHASH() external view returns (bytes32 _typehash);

  /**
   * @notice The role that may block addresses and kill attesters, with no delay
   * @return _role keccak256('GUARDIAN_ROLE')
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function GUARDIAN_ROLE() external view returns (bytes32 _role);

  /**
   * @notice The role of the recovery timelock: may clear blocks, revive attesters and revoke GUARDIAN_ROLE
   * @return _role keccak256('RECOVERY_ROLE')
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function RECOVERY_ROLE() external view returns (bytes32 _role);
}
