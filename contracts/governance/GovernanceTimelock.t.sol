// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {TimelockController} from '@openzeppelin/contracts/governance/TimelockController.sol';
import {Test} from 'forge-std/Test.sol';

import {IGovernanceTimelock} from 'interfaces/IGovernanceTimelock.sol';

import {GovernanceTimelock} from 'contracts/governance/GovernanceTimelock.sol';

/// @dev M-1: the recovery timelock can strip the guardian's cancel right on the main timelock, and do nothing else
contract GovernanceTimelockUnitTest is Test {
  uint256 internal constant _DELAY = 1 days;
  uint256 internal constant _FLOOR = 1 hours;
  GovernanceTimelock internal _timelock;
  address internal _governance = makeAddr('governance');
  address internal _guardian = makeAddr('guardian');
  address internal _recovery = makeAddr('recoveryTimelock');
  address internal _stranger = makeAddr('stranger');

  function setUp() public {
    address[] memory _members = new address[](1);
    _members[0] = _governance;
    _timelock = new GovernanceTimelock(_DELAY, _members, _members, address(this), _recovery);
    _timelock.grantRole(_timelock.CANCELLER_ROLE(), _guardian);
    _timelock.renounceRole(_timelock.DEFAULT_ADMIN_ROLE(), address(this)); // self-administered, as deployed
  }

  function _unauthorized(
    address _caller,
    bytes32 _role
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role);
  }

  /// @dev The recovery timelock is this contract with no recovery of its own: the floor holds there too, and the role
  ///      is held by nobody
  function test_WhenDeployedWithNoRecovery_NobodyHoldsTheRoleAndTheFloorHolds() external {
    address[] memory _members = new address[](1);
    _members[0] = _governance;
    GovernanceTimelock _recoveryTimelock = new GovernanceTimelock(_DELAY, _members, _members, address(0), address(0));
    assertFalse(_recoveryTimelock.hasRole(_recoveryTimelock.RECOVERY_ROLE(), address(0)));
    assertFalse(_recoveryTimelock.hasRole(_recoveryTimelock.RECOVERY_ROLE(), _governance));
    assertEq(_recoveryTimelock.getMinDelay(), _DELAY);

    vm.expectRevert(_belowFloor(_FLOOR - 1));
    new GovernanceTimelock(_FLOOR - 1, _members, _members, address(0), address(0));
  }

  function test_TheRecoveryRoleIsHeldByTheRecoveryTimelockOnly() external view {
    assertEq(_timelock.RECOVERY_ROLE(), keccak256('RECOVERY_ROLE'));
    assertTrue(_timelock.hasRole(_timelock.RECOVERY_ROLE(), _recovery));
    assertFalse(_timelock.hasRole(_timelock.RECOVERY_ROLE(), _governance));
    assertFalse(_timelock.hasRole(_timelock.RECOVERY_ROLE(), _guardian));
  }

  function test_WhenRecoveryRevokesTheGuardiansCancelRight_TheGuardianCanNoLongerCancel() external {
    bytes32 _canceller = _timelock.CANCELLER_ROLE();
    vm.prank(_recovery);
    _timelock.revokeRole(_canceller, _guardian);
    assertFalse(_timelock.hasRole(_canceller, _guardian));

    vm.prank(_governance);
    _timelock.schedule(address(0x1234), 0, '', bytes32(0), bytes32(0), _DELAY);
    bytes32 _id = _timelock.hashOperation(address(0x1234), 0, '', bytes32(0), bytes32(0));
    vm.expectRevert(_unauthorized(_guardian, _canceller));
    vm.prank(_guardian);
    _timelock.cancel(_id);
  }

  function test_WhenRecoveryRevokesAnyOtherRole_ItReverts() external {
    bytes32 _adminRole = _timelock.DEFAULT_ADMIN_ROLE();
    bytes32 _proposer = _timelock.PROPOSER_ROLE();
    bytes32 _executor = _timelock.EXECUTOR_ROLE();
    vm.startPrank(_recovery);
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    _timelock.revokeRole(_proposer, _governance);
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    _timelock.revokeRole(_executor, _governance);
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    _timelock.revokeRole(_adminRole, address(_timelock));
    vm.stopPrank();
  }

  function test_WhenRecoveryGrantsAnyRole_ItReverts() external {
    bytes32 _adminRole = _timelock.DEFAULT_ADMIN_ROLE();
    bytes32 _canceller = _timelock.CANCELLER_ROLE();
    bytes32 _proposer = _timelock.PROPOSER_ROLE();
    vm.startPrank(_recovery);
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    _timelock.grantRole(_canceller, _stranger);
    vm.expectRevert(_unauthorized(_recovery, _adminRole));
    _timelock.grantRole(_proposer, _recovery);
    vm.stopPrank();
  }

  function test_WhenRecoveryProposesExecutesOrCancels_ItReverts() external {
    bytes32 _proposer = _timelock.PROPOSER_ROLE();
    bytes32 _executor = _timelock.EXECUTOR_ROLE();
    bytes32 _canceller = _timelock.CANCELLER_ROLE();
    vm.startPrank(_recovery);
    vm.expectRevert(_unauthorized(_recovery, _proposer));
    _timelock.schedule(address(0x1234), 0, '', bytes32(0), bytes32(0), _DELAY);
    vm.expectRevert(_unauthorized(_recovery, _executor));
    _timelock.execute(address(0x1234), 0, '', bytes32(0), bytes32(0));
    vm.expectRevert(_unauthorized(_recovery, _canceller));
    _timelock.cancel(bytes32(uint256(1)));
    vm.stopPrank();
  }

  /// @dev The guardian keeps its ordinary cancel power until recovery removes it
  function test_WhenTheGuardianCancelsAGovernanceOperation_ItIsCancelled() external {
    vm.prank(_governance);
    _timelock.schedule(address(0x1234), 0, '', bytes32(0), bytes32(0), _DELAY);
    bytes32 _id = _timelock.hashOperation(address(0x1234), 0, '', bytes32(0), bytes32(0));
    vm.prank(_guardian);
    _timelock.cancel(_id);
    assertFalse(_timelock.isOperationPending(_id));
  }

  function _belowFloor(
    uint256 _delay
  ) internal pure returns (bytes memory _revertData) {
    _revertData =
      abi.encodeWithSelector(IGovernanceTimelock.GovernanceTimelock_DelayBelowFloor.selector, _delay, _FLOOR);
  }

  /// @dev Schedules `updateDelay(_delay)`, the only way it can run (an operation of the timelock on itself), and
  ///      waits out the delay
  function _scheduleUpdateDelay(
    uint256 _delay
  ) internal {
    uint256 _wait = _timelock.getMinDelay();
    vm.prank(_governance);
    _timelock.schedule(
      address(_timelock), 0, abi.encodeCall(_timelock.updateDelay, (_delay)), bytes32(0), bytes32(_delay), _wait
    );
    vm.warp(block.timestamp + _wait);
  }

  function _executeUpdateDelay(
    uint256 _delay
  ) internal {
    vm.prank(_governance);
    _timelock.execute(
      address(_timelock), 0, abi.encodeCall(_timelock.updateDelay, (_delay)), bytes32(0), bytes32(_delay)
    );
  }

  function test_WhenDeployedWithADelayBelowTheFloor_ItReverts() external {
    address[] memory _members = new address[](1);
    _members[0] = _governance;
    vm.expectRevert(_belowFloor(_FLOOR - 1));
    new GovernanceTimelock(_FLOOR - 1, _members, _members, address(0), _recovery);
  }

  function test_WhenGovernanceLowersTheDelayBelowTheFloor_TheOperationReverts() external {
    _scheduleUpdateDelay(_FLOOR - 1);
    vm.expectRevert(_belowFloor(_FLOOR - 1));
    _executeUpdateDelay(_FLOOR - 1);
    assertEq(_timelock.getMinDelay(), _DELAY);
  }

  /// @dev The floor itself is allowed
  function test_WhenGovernanceSetsTheDelayToExactlyTheFloor_ItApplies() external {
    _scheduleUpdateDelay(_FLOOR);
    _executeUpdateDelay(_FLOOR);
    assertEq(_timelock.getMinDelay(), _FLOOR);
  }

  function test_WhenGovernanceRaisesTheDelay_ItApplies() external {
    _scheduleUpdateDelay(8 days);
    _executeUpdateDelay(8 days);
    assertEq(_timelock.getMinDelay(), 8 days);
  }

  /// @dev The floor does not mask OpenZeppelin's own check: only the timelock itself may call updateDelay
  function test_WhenAStrangerCallsUpdateDelay_ItRevertsAsUnauthorized() external {
    vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, _stranger));
    vm.prank(_stranger);
    _timelock.updateDelay(1 hours);
  }

  function testFuzz_TheDelayNeverDropsBelowTheFloor(
    uint256 _delay
  ) external {
    _delay = bound(_delay, 0, 30 days);
    _scheduleUpdateDelay(_delay);
    if (_delay < _FLOOR) vm.expectRevert(_belowFloor(_delay));
    _executeUpdateDelay(_delay);
    assertGe(_timelock.getMinDelay(), _FLOOR);
  }

  /// @dev RECOVERY_ROLE revokes CANCELLER_ROLE from any holder, governance's own included: OpenZeppelin makes every
  ///      proposer a canceller, and recovery is not limited to the guardian
  function test_WhenRecoveryRevokesGovernancesCancelRight_ItIsRevoked() external {
    bytes32 _canceller = _timelock.CANCELLER_ROLE();
    assertTrue(_timelock.hasRole(_canceller, _governance));
    vm.prank(_recovery);
    _timelock.revokeRole(_canceller, _governance);
    assertFalse(_timelock.hasRole(_canceller, _governance));
  }
}
