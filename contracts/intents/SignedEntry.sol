// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';
import {SignatureChecker} from '@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol';

import {IERC3009} from 'interfaces/IERC3009.sol';
import {IERC7540Deposit} from 'interfaces/IERC7540Deposit.sol';
import {ISignedEntry} from 'interfaces/ISignedEntry.sol';

/**
 * @title SignedEntry
 * @notice Lets an investor enter a vault with one signature while a relayer pays the gas, as specified in `ISignedEntry`
 * @dev Immutable, with no roles. Anyone can deploy and run one, and a vault's policy decides whether to accept it as a payer
 */
contract SignedEntry is EIP712, ISignedEntry {
  using SafeERC20 for IERC20;

  /// @notice The EIP-712 type of what the investor signs
  bytes32 private constant _ENTRY_TYPEHASH = keccak256(
    'Entry(address investor,address vault,uint256 assets,uint256 minShares,bool asynchronous,bytes32 nonce,uint256 validAfter,uint256 deadline)'
  );

  /// @notice Used and cancelled nonces, per investor
  mapping(address _investor => mapping(bytes32 _nonce => bool _used)) internal _nonces;

  /// @notice Deploys it, with its EIP-712 domain
  constructor() EIP712('SignedEntry', '1') {}

  // What an entry bought is known only after the vault's call, so its event follows it. The nonce was spent before any
  // external call, so a re-entry cannot repeat the entry.
  // slither-disable-start reentrancy-events
  /// @inheritdoc ISignedEntry
  function enterWithPermit(
    Entry calldata _entry,
    bytes calldata _entrySig,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external returns (uint256 _shares) {
    bytes32 _hash = _accept(_entry, _entrySig);
    IERC20 _asset = IERC20(IERC4626(_entry.vault).asset());
    // Anyone can submit a signed permit first, and that must not stop the entry: only the allowance matters.
    try IERC20Permit(address(_asset))
      .permit(_entry.investor, address(this), _entry.assets, _entry.deadline, _v, _r, _s) {}
      catch {}
    // The investor signed the entry naming these assets, checked above.
    // slither-disable-next-line arbitrary-send-erc20,arbitrary-send-erc20-permit
    _asset.safeTransferFrom(_entry.investor, address(this), _entry.assets); // aderyn-ignore(arbitrary-transfer-from)
    _shares = _deal(_entry, _hash, _asset);
  }

  /// @inheritdoc ISignedEntry
  function enterWith3009(
    Entry calldata _entry,
    bytes calldata _entrySig,
    bytes calldata _cashSig
  ) external returns (uint256 _shares) {
    bytes32 _hash = _accept(_entry, _entrySig);
    IERC20 _asset = IERC20(IERC4626(_entry.vault).asset());
    IERC3009(address(_asset))
      .receiveWithAuthorization(
        _entry.investor,
        address(this),
        _entry.assets,
        _entry.validAfter,
        _entry.deadline,
        keccak256(abi.encode(address(this), _hash)),
        _cashSig
      );
    _shares = _deal(_entry, _hash, _asset);
  }

  /// @inheritdoc ISignedEntry
  function cancelEntry(
    bytes32 _nonce
  ) external {
    _nonces[msg.sender][_nonce] = true;
    emit EntryCancelled(msg.sender, _nonce);
  }

  /// @inheritdoc ISignedEntry
  function cashNonce(
    Entry calldata _entry
  ) external view returns (bytes32 _nonce) {
    _nonce = keccak256(abi.encode(address(this), entryHash(_entry)));
  }

  /// @inheritdoc ISignedEntry
  function nonceUsed(
    address _investor,
    bytes32 _nonce
  ) external view returns (bool _used) {
    _used = _nonces[_investor][_nonce];
  }

  /// @inheritdoc ISignedEntry
  function entryHash(
    Entry calldata _entry
  ) public view returns (bytes32 _hash) {
    _hash = _hashTypedDataV4(keccak256(abi.encode(_ENTRY_TYPEHASH, _entry)));
  }

  /**
   * @notice Checks an entry and spends its nonce
   * @param _entry The entry
   * @param _sig The investor's signature
   * @return _hash The hash it signed
   */
  function _accept(
    Entry calldata _entry,
    bytes calldata _sig
  ) private returns (bytes32 _hash) {
    if (block.timestamp > _entry.deadline) revert SignedEntry_Expired();
    if (block.timestamp < _entry.validAfter) revert SignedEntry_NotYetValid();
    if (_nonces[_entry.investor][_entry.nonce]) revert SignedEntry_NonceUsed();
    if (_entry.asynchronous && _entry.minShares != 0) revert SignedEntry_MinimumOnARequest();
    _hash = entryHash(_entry);
    if (!SignatureChecker.isValidSignatureNow(_entry.investor, _hash, _sig)) revert SignedEntry_BadSignature();
    _nonces[_entry.investor][_entry.nonce] = true;
  }

  /**
   * @notice Pays the vault and reports
   * @param _entry The entry
   * @param _hash The hash the investor signed
   * @param _asset The vault's asset, held here for this call
   * @return _shares The shares received; zero for a request
   */
  function _deal(
    Entry calldata _entry,
    bytes32 _hash,
    IERC20 _asset
  ) private returns (uint256 _shares) {
    _asset.forceApprove(_entry.vault, _entry.assets);
    if (_entry.asynchronous) {
      // Returns the aggregated request id, 0, which says nothing.
      // slither-disable-next-line unused-return
      IERC7540Deposit(_entry.vault).requestDeposit(_entry.assets, _entry.investor, address(this)); // aderyn-ignore(unchecked-return)
    } else {
      _shares = IERC4626(_entry.vault).deposit(_entry.assets, _entry.investor);
      if (_shares < _entry.minShares) revert SignedEntry_TooFewShares(_entry.minShares, _shares);
    }
    // An allowance and not a balance: anyone can send this contract a balance, and that must not stop an entry.
    uint256 _left = _asset.allowance(address(this), _entry.vault);
    if (_left != 0) revert SignedEntry_CashNotTaken(_left);
    emit EntryExecuted(_hash, _entry.investor, _entry.vault, _entry.assets, _shares);
  }
  // slither-disable-end reentrancy-events
}
