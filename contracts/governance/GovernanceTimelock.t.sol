// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {Test} from 'forge-std/Test.sol';

import {IGovernanceTimelock} from 'interfaces/IGovernanceTimelock.sol';

import {GovernanceTimelock} from 'contracts/governance/GovernanceTimelock.sol';

/// @dev M-1: the recovery timelock can strip the guardian's cancel right on the main timelock, and do nothing else
contract GovernanceTimelockUnitTest is Test {
  uint256 internal constant _DELAY = 7 days;
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

  function test_WhenTheRecoveryAddressIsZero_ItReverts() external {
    address[] memory _members = new address[](1);
    _members[0] = _governance;
    vm.expectRevert(IGovernanceTimelock.GovernanceTimelock_ZeroAddress.selector);
    new GovernanceTimelock(_DELAY, _members, _members, address(0), address(0));
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
}
