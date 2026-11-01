// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// Needed by the compiler to resolve `@inheritdoc AccessControl`; solhint does not see NatSpec usage.
// solhint-disable-next-line no-unused-vars
import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {TimelockController} from '@openzeppelin/contracts/governance/TimelockController.sol';

import {IGovernanceTimelock} from 'interfaces/IGovernanceTimelock.sol';

/**
 * @title GovernanceTimelock
 * @notice The main governance timelock: OZ's TimelockController with a one-hour floor on its delay and one recovery
 *         power. The recovery timelock (its own delay, governance as proposer and executor, no cancellers) holds
 *         RECOVERY_ROLE here and may revoke CANCELLER_ROLE, so a guardian that vetoes its own removal can be stripped of
 *         its cancel right. The recovery timelock is this same contract deployed with no recovery of its own, so the
 *         floor holds on both
 * @dev RECOVERY_ROLE is deliberately not a role admin: an admin could also grant. Its admin is DEFAULT_ADMIN_ROLE
 *      (this timelock itself after hand-over), like every other role
 */
contract GovernanceTimelock is TimelockController, IGovernanceTimelock {
  /// @inheritdoc IGovernanceTimelock
  bytes32 public constant RECOVERY_ROLE = keccak256('RECOVERY_ROLE');

  /// @notice The lowest delay the timelock accepts, at deployment and in `updateDelay`
  uint256 private constant _MIN_DELAY = 1 hours;

  /**
   * @notice Deploys the timelock
   * @param _initialMinDelay The minimum delay, at least 1 hour (`GovernanceTimelock_DelayBelowFloor` otherwise)
   * @param _proposers The proposers (and, per OZ, cancellers): the governance multisig
   * @param _executors The executors: the governance multisig
   * @param _admin The optional bootstrap admin (the deployer), renounced after configuration
   * @param _recovery The recovery timelock, granted RECOVERY_ROLE; zero for a timelock with no recovery power over it,
   *        which is how the recovery timelock itself is deployed
   */
  constructor(
    uint256 _initialMinDelay,
    address[] memory _proposers,
    address[] memory _executors,
    address _admin,
    address _recovery
  ) TimelockController(_initialMinDelay, _proposers, _executors, _admin) {
    if (_initialMinDelay < _MIN_DELAY) revert GovernanceTimelock_DelayBelowFloor(_initialMinDelay, _MIN_DELAY);
    // _grantRole returns false only if the role is already held; either way the account ends up holding it.
    // aderyn-ignore-next-line(unchecked-return)
    if (_recovery != address(0)) _grantRole(RECOVERY_ROLE, _recovery);
  }

  /**
   * @inheritdoc AccessControl
   * @dev RECOVERY_ROLE may revoke CANCELLER_ROLE and nothing else; every other revocation needs the role's admin
   */
  function revokeRole(
    bytes32 _role,
    address _account
  ) public override {
    if (_role == CANCELLER_ROLE && hasRole(RECOVERY_ROLE, _msgSender())) {
      // _revokeRole returns false only if the role was not held; either way the account ends up without it.
      // aderyn-ignore-next-line(unchecked-return)
      _revokeRole(_role, _account);
      return;
    }
    super.revokeRole(_role, _account);
  }

  /**
   * @inheritdoc TimelockController
   * @dev Reverts with `GovernanceTimelock_DelayBelowFloor` below one hour. OpenZeppelin's caller check (only the
   *      timelock itself) runs first; a delay below the floor then reverts the whole call
   */
  function updateDelay(
    uint256 _newDelay
  ) public override {
    super.updateDelay(_newDelay);
    if (_newDelay < _MIN_DELAY) revert GovernanceTimelock_DelayBelowFloor(_newDelay, _MIN_DELAY);
  }
}
