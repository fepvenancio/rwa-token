// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title ICallValidator
 * @notice Judges the parameters of one call a `GuardedAccount` would make. Immutable and attested, so its settings are
 *         part of the codehash the council reviewed
 */
interface ICallValidator {
  /**
   * @notice Whether a call may run
   * @dev MUST be view. Anything it does not recognise is refused, so nothing passes by omission
   * @param _account The account that would make the call
   * @param _target The contract it would call
   * @param _data The calldata
   * @return _allowed True when the call may run
   */
  function validate(
    address _account,
    address _target,
    bytes calldata _data
  ) external view returns (bool _allowed);
}
