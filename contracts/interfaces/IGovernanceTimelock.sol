// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IGovernanceTimelock
 * @notice The main governance timelock: OZ's TimelockController plus a recovery path the guardian cannot block
 * @dev The recovery timelock holds RECOVERY_ROLE here, which allows exactly one thing: revoking CANCELLER_ROLE (so a
 *      guardian that vetoes its own removal can be stripped of its cancel right). It cannot grant any role, propose,
 *      execute or cancel
 */
interface IGovernanceTimelock {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when the recovery timelock address is zero
  error GovernanceTimelock_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The role allowed to revoke CANCELLER_ROLE, and nothing else
   * @return _role The role id
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function RECOVERY_ROLE() external view returns (bytes32 _role);
}
