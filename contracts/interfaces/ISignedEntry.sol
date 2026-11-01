// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title ISignedEntry
 * @notice Lets an investor with its own wallet enter a vault with one signature, while a relayer pays the gas. It changes no
 *         vault: it is an ordinary third-party payer, so it needs a credential on the vault's policy (`IGatedVaultBase`), and
 *         on the asset's if the asset is gated. It holds no money between calls, has no roles and is not upgradeable
 * @dev Exits need no such lego: a holder signs the share token's `permit`, and a relayer submits it with `requestRedeem` or
 *      `redeem` through the token's `multicall`.
 *
 *      The investor signs an EIP-712 `Entry`: where, how much, the least it accepts, and when. The cash comes by a second
 *      signature in the same transaction, an ERC-2612 `permit` or an ERC-3009 `receiveWithAuthorization`. The authorization's
 *      nonce is `cashNonce(entry)`, so it pays for this entry and no other. A permit is not bound the same way, so a permit
 *      left unspent can be spent by another entry of the same investor, which that investor also signed
 */
interface ISignedEntry {
  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice What the investor signs
   * @param investor Who pays and who receives the shares, or controls the request
   * @param vault The vault
   * @param assets The assets to pay
   * @param minShares The least it accepts on a 4626; zero on a 7540, where a request has no price yet
   * @param asynchronous True for a 7540, where this files a request; false for a 4626, where this deposits
   * @param nonce A random nonce, single use
   * @param validAfter The first moment it is valid, inclusive; zero for no lower bound
   * @param deadline The last moment it is valid, inclusive
   */
  struct Entry {
    address investor;
    address vault;
    uint256 assets;
    uint256 minShares;
    bool asynchronous;
    bytes32 nonce;
    uint256 validAfter;
    uint256 deadline;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when an investor cancels an entry
   * @param _investor The investor
   * @param _nonce The nonce
   */
  event EntryCancelled(address indexed _investor, bytes32 indexed _nonce);

  /**
   * @notice Emitted when an entry executes
   * @param _entryHash The hash the investor signed
   * @param _investor The investor
   * @param _vault The vault
   * @param _assets The assets paid
   * @param _shares The shares received; zero for a request
   */
  event EntryExecuted(
    bytes32 indexed _entryHash, address indexed _investor, address indexed _vault, uint256 _assets, uint256 _shares
  );

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when the signature is not the investor's
  error SignedEntry_BadSignature();

  /**
   * @notice Thrown when the vault did not take all the cash, as when a 7540 treats a deposit as a claim for this contract
   * @param _left The allowance the vault left unspent
   */
  error SignedEntry_CashNotTaken(uint256 _left);

  /// @notice Thrown after the deadline
  error SignedEntry_Expired();

  /// @notice Thrown when a request names a minimum, which it could not honour
  error SignedEntry_MinimumOnARequest();

  /// @notice Thrown when the nonce was used or cancelled
  error SignedEntry_NonceUsed();

  /// @notice Thrown before `validAfter`
  error SignedEntry_NotYetValid();

  /**
   * @notice Thrown when a deposit buys fewer shares than the investor accepted
   * @param _minShares The least it accepted
   * @param _shares The shares it would get
   */
  error SignedEntry_TooFewShares(uint256 _minShares, uint256 _shares);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Marks a nonce used, so an entry signed with it cannot execute
   * @param _nonce The nonce
   */
  function cancelEntry(
    bytes32 _nonce
  ) external;

  /**
   * @notice Executes an entry, with the cash by ERC-3009
   * @dev Anyone. The investor signs `receiveWithAuthorization` to this contract with `cashNonce(entry)`, `validAfter` and
   *      `validBefore` being the entry's `validAfter` and `deadline`; ERC-3009's window excludes both ends
   * @param _entry The entry
   * @param _entrySig The investor's signature of the entry
   * @param _cashSig The investor's signature of the authorization
   * @return _shares The shares received; zero for a request
   */
  function enterWith3009(
    Entry calldata _entry,
    bytes calldata _entrySig,
    bytes calldata _cashSig
  ) external returns (uint256 _shares);

  /**
   * @notice Executes an entry, with the cash by ERC-2612
   * @dev Anyone. A permit someone already submitted does not stop it: only the allowance matters
   * @param _entry The entry
   * @param _entrySig The investor's signature of the entry
   * @param _v The permit's v; the permit is for this contract, the entry's assets and its deadline
   * @param _r The permit's r
   * @param _s The permit's s
   * @return _shares The shares received; zero for a request
   */
  function enterWithPermit(
    Entry calldata _entry,
    bytes calldata _entrySig,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external returns (uint256 _shares);

  /*///////////////////////////////////////////////////////////////
                            VIEWS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The nonce an ERC-3009 authorization for this entry must carry
   * @param _entry The entry
   * @return _nonce `keccak256(abi.encode(address(this), entryHash(entry)))`
   */
  function cashNonce(
    Entry calldata _entry
  ) external view returns (bytes32 _nonce);

  /**
   * @notice The EIP-712 hash the investor signs
   * @param _entry The entry
   * @return _hash The hash
   */
  function entryHash(
    Entry calldata _entry
  ) external view returns (bytes32 _hash);

  /**
   * @notice Whether a nonce was used or cancelled
   * @param _investor The investor
   * @param _nonce The nonce
   * @return _used True when it was
   */
  function nonceUsed(
    address _investor,
    bytes32 _nonce
  ) external view returns (bool _used);
}
