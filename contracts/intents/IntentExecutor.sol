// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';

import {IIntentExecutor} from 'interfaces/IIntentExecutor.sol';
import {IIntentExecutorBatch} from 'interfaces/IIntentExecutorBatch.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

/**
 * @title IntentExecutor
 * @notice Replaceable, role-gated submitter of holder-signed transfer intents. Tokens authorise it by granting it
 *         their EXECUTOR_ROLE; operators (bank / relayer keys) hold OPERATOR_ROLE here
 * @dev Immutable, not a proxy: replacing it means deploying a new executor and moving the token's EXECUTOR_ROLE.
 *      Forward-only: the token remains the single source of truth for signature, nonce, deadline, freeze, pause and
 *      policy checks, so nothing is checked twice. The executor holds no funds and no state of its own
 */
contract IntentExecutor is AccessControl, Pausable, IIntentExecutor, IIntentExecutorBatch {
  /// @notice Role allowed to submit intents
  bytes32 public constant OPERATOR_ROLE = keccak256('OPERATOR_ROLE');

  /// @notice Role allowed to pause the executor, with no delay
  bytes32 public constant GUARDIAN_ROLE = keccak256('GUARDIAN_ROLE');

  /// @notice Role of the recovery timelock: may only `unpause` and revoke GUARDIAN_ROLE, a path the guardian cannot
  ///         cancel (owner decision M-1). Granted and revoked by DEFAULT_ADMIN_ROLE like any role
  bytes32 public constant RECOVERY_ROLE = keccak256('RECOVERY_ROLE');

  /**
   * @notice Deploys the executor
   * @param _admin The timelock, granted DEFAULT_ADMIN_ROLE; it grants OPERATOR_ROLE and unpauses
   * @param _guardian The guardian multisig, granted GUARDIAN_ROLE; it can only pause
   */
  constructor(
    address _admin,
    address _guardian
  ) {
    if (_admin == address(0) || _guardian == address(0)) revert IntentExecutor_ZeroAddress();
    // _grantRole returns false only if the role is already held; either way the account ends up holding it.
    // aderyn-ignore-next-line(unchecked-return)
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    // As above.
    // aderyn-ignore-next-line(unchecked-return)
    _grantRole(GUARDIAN_ROLE, _guardian);
  }

  /**
   * @inheritdoc IIntentExecutor
   * @dev Only OPERATOR_ROLE, and only while not paused. The token's revert data bubbles up unchanged
   */
  function execute(
    address _token,
    ITransferIntent.TransferIntent calldata _intent,
    bytes calldata _sig
  ) external onlyRole(OPERATOR_ROLE) whenNotPaused returns (bytes32 _intentHash) {
    _intentHash = ITransferIntent(_token).executeTransfer(_intent, _sig);
  }

  /// @inheritdoc IIntentExecutorBatch
  function executeBatch(
    address _token,
    ITransferIntent.TransferIntent[] calldata _intents,
    bytes[] calldata _sigs
  ) external onlyRole(OPERATOR_ROLE) whenNotPaused returns (bytes32[] memory _intentHashes) {
    uint256 _length = _intents.length;
    if (_length != _sigs.length) revert IntentExecutor_LengthMismatch(_length, _sigs.length);

    _intentHashes = new bytes32[](_length);
    // Batches are atomic by design: the first failing intent reverts the batch with its index.
    // aderyn-ignore-next-line(require-revert-in-loop)
    for (uint256 _i; _i < _length; ++_i) {
      // Any failure reverts the whole batch, naming the failing index and carrying the token's reason.
      try ITransferIntent(_token).executeTransfer(_intents[_i], _sigs[_i]) returns (bytes32 _intentHash) {
        _intentHashes[_i] = _intentHash;
      } catch (bytes memory _reason) {
        revert IntentExecutor_BatchItemFailed(_i, _reason);
      }
    }
  }

  /// @inheritdoc IIntentExecutorBatch
  function pause() external onlyRole(GUARDIAN_ROLE) {
    _pause();
  }

  /**
   * @inheritdoc IIntentExecutorBatch
   * @dev DEFAULT_ADMIN_ROLE (the main timelock) or RECOVERY_ROLE (the recovery timelock, which the guardian cannot
   *      cancel). Anyone else gets the usual AccessControl error for DEFAULT_ADMIN_ROLE
   */
  function unpause() external {
    address _sender = _msgSender();
    if (!hasRole(DEFAULT_ADMIN_ROLE, _sender) && !hasRole(RECOVERY_ROLE, _sender)) {
      revert AccessControlUnauthorizedAccount(_sender, DEFAULT_ADMIN_ROLE);
    }
    _unpause();
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

  /// @inheritdoc AccessControl
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(IIntentExecutor).interfaceId
      || _interfaceId == type(IIntentExecutorBatch).interfaceId || super.supportsInterface(_interfaceId);
  }
}
