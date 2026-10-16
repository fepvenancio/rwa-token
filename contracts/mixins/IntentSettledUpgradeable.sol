// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SignatureChecker} from '@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

import {PolicyGatedERC20Upgradeable} from 'contracts/base/PolicyGatedERC20Upgradeable.sol';

/**
 * @title IntentSettledUpgradeable
 * @notice Mixin: the holder signs an EIP-712 `TransferIntent`, EXECUTOR_ROLE executes it
 * @dev Shares the EIP-712 domain with ERC-2612 permit. Signatures are checked with OZ `SignatureChecker`, so EOAs
 *      (ECDSA, low-s only) and ERC-1271 smart accounts are supported. Nonces are random and tracked per signer
 */
abstract contract IntentSettledUpgradeable is PolicyGatedERC20Upgradeable, ITransferIntent {
  /**
   * @notice ERC-7201 namespaced storage of the mixin
   * @param nonces Whether each signer's nonce was used or cancelled
   * @custom:storage-location erc7201:gated.storage.IntentSettled
   */
  struct IntentSettledStorage {
    mapping(address _signer => mapping(bytes32 _nonce => bool _used)) nonces;
  }

  /// @notice Role allowed to execute signed intents
  bytes32 public constant EXECUTOR_ROLE = keccak256('EXECUTOR_ROLE');

  /// @notice EIP-712 typehash of `TransferIntent`
  bytes32 public constant TRANSFER_INTENT_TYPEHASH =
    keccak256('TransferIntent(address from,address to,uint256 amount,bytes32 nonce,uint256 deadline,bytes32 ref)');

  /// @notice keccak256(abi.encode(uint256(keccak256('gated.storage.IntentSettled')) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _INTENT_SETTLED_STORAGE_LOCATION =
    0xcc418472a3060d74aba67f2dfb002694e1ed5ee75dd235bfcf4b429d6fcd3c00;

  /// @inheritdoc ITransferIntent
  function executeTransfer(
    TransferIntent calldata _intent,
    bytes calldata _sig
  ) external onlyRole(EXECUTOR_ROLE) returns (bytes32 _intentHash) {
    bytes32 _reason = _intentPreflight(_intent);
    if (_reason != Reasons.TRANSFER_OK) revert PolicyGated_TransferRejected(_reason);

    _intentHash = intentHash(_intent);
    if (!SignatureChecker.isValidSignatureNow(_intent.from, _intentHash, _sig)) {
      revert PolicyGated_TransferRejected(Reasons.BAD_SIGNATURE);
    }

    _getIntentSettledStorage().nonces[_intent.from][_intent.nonce] = true;
    _moveAs(_intent.from, _intent.to, _intent.amount, IPolicyHook.TransferKind.EXECUTED, _intent.ref, _intent.deadline);

    // Emitted after the hook's afterTransfer: re-entry is blocked by `_update`'s guard and the hook is attested.
    // slither-disable-next-line reentrancy-events
    emit IntentExecuted(_intentHash, _intent.from, _intent.to, _intent.amount, _msgSender(), _intent.ref);
  }

  /// @inheritdoc ITransferIntent
  function cancelIntent(
    bytes32 _nonce
  ) external {
    IntentSettledStorage storage $ = _getIntentSettledStorage();
    if ($.nonces[_msgSender()][_nonce]) revert PolicyGated_TransferRejected(Reasons.NONCE_USED);
    $.nonces[_msgSender()][_nonce] = true;
    emit IntentCancelled(_msgSender(), _nonce);
  }

  /// @inheritdoc ITransferIntent
  function canExecute(
    TransferIntent calldata _intent
  ) external view returns (bool _ok, bytes32 _reason) {
    _reason = _intentPreflight(_intent);
    if (_reason == Reasons.TRANSFER_OK) {
      _reason = _check(
        _context(
          _intent.from,
          _intent.to,
          _intent.amount,
          _msgSender(),
          IPolicyHook.TransferKind.EXECUTED,
          _intent.ref,
          _intent.deadline
        ),
        _policyHook()
      );
    }
    _ok = _reason == Reasons.TRANSFER_OK;
  }

  /// @inheritdoc ITransferIntent
  function nonceUsed(
    address _signer,
    bytes32 _nonce
  ) external view returns (bool _used) {
    _used = _getIntentSettledStorage().nonces[_signer][_nonce];
  }

  /// @inheritdoc ITransferIntent
  function intentHash(
    TransferIntent calldata _intent
  ) public view returns (bytes32 _intentHash) {
    _intentHash = _hashTypedDataV4(
      keccak256(
        abi.encode(
          TRANSFER_INTENT_TYPEHASH,
          _intent.from,
          _intent.to,
          _intent.amount,
          _intent.nonce,
          _intent.deadline,
          _intent.ref
        )
      )
    );
  }

  /// @inheritdoc PolicyGatedERC20Upgradeable
  function supportsInterface(
    bytes4 _interfaceId
  ) public view virtual override returns (bool _supported) {
    _supported = _interfaceId == type(ITransferIntent).interfaceId || super.supportsInterface(_interfaceId);
  }

  /// @notice Initializes the mixin; it has no state to set
  // solhint-disable-next-line style-guide-casing
  function __IntentSettled_init() internal onlyInitializing {}

  /**
   * @notice Checks that do not depend on the signature: deadline (inclusive) and nonce
   * @param _intent The intent
   * @return _reason The reason code
   */
  function _intentPreflight(
    TransferIntent calldata _intent
  ) private view returns (bytes32 _reason) {
    if (block.timestamp > _intent.deadline) return Reasons.INTENT_EXPIRED;
    if (_getIntentSettledStorage().nonces[_intent.from][_intent.nonce]) return Reasons.NONCE_USED;
    _reason = Reasons.TRANSFER_OK;
  }

  /**
   * @notice The ERC-7201 storage of the mixin
   * @return $ The storage pointer
   */
  function _getIntentSettledStorage() private pure returns (IntentSettledStorage storage $) {
    assembly ('memory-safe') {
      $.slot := _INTENT_SETTLED_STORAGE_LOCATION
    }
  }
}
