// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

/**
 * @title IIntentExecutorBatch
 * @notice Batch settlement and the emergency stop of the intent executor. Kept apart from the frozen
 *         `IIntentExecutor`, with its own ERC-165 id
 * @dev A batch is one accounting event: it settles all of its intents or none of them
 */
interface IIntentExecutorBatch {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when one intent of a batch fails; the whole batch reverts
   * @param _index The position of the failing intent, so the operator can drop it and resubmit
   * @param _reason The token's revert data, e.g. `IPolicyGated.PolicyGated_TransferRejected(reason)`
   */
  error IntentExecutor_BatchItemFailed(uint256 _index, bytes _reason);

  /**
   * @notice Thrown when the intents and signatures arrays differ in length
   * @param _intents The number of intents
   * @param _sigs The number of signatures
   */
  error IntentExecutor_LengthMismatch(uint256 _intents, uint256 _sigs);

  /// @notice Thrown when a constructor argument is the zero address
  error IntentExecutor_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Settles several signed intents on one token, atomically
   * @dev Only OPERATOR_ROLE, and only while not paused. Reverts with `IntentExecutor_BatchItemFailed` at the first
   *      failing intent, undoing the whole batch
   * @param _token The token, which must have granted this executor EXECUTOR_ROLE
   * @param _intents The intents, in settlement order
   * @param _sigs The holders' signatures, one per intent
   * @return _intentHashes The EIP-712 digest of each settled intent, in order
   */
  function executeBatch(
    address _token,
    ITransferIntent.TransferIntent[] calldata _intents,
    bytes[] calldata _sigs
  ) external returns (bytes32[] memory _intentHashes);

  /**
   * @notice Stops all settlement through this executor
   * @dev Only GUARDIAN_ROLE, with no delay
   */
  function pause() external;

  /**
   * @notice Resumes settlement through this executor
   * @dev Only DEFAULT_ADMIN_ROLE (the main timelock) or RECOVERY_ROLE (the recovery timelock, which the guardian
   *      cannot cancel)
   */
  function unpause() external;
}
