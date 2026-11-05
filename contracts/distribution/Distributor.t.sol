// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Hashes} from '@openzeppelin/contracts/utils/cryptography/Hashes.sol';

import {IDistributor} from 'interfaces/IDistributor.sol';
import {IERC7943Fungible} from 'interfaces/IERC7943Fungible.sol';

import {Distributor} from 'contracts/distribution/Distributor.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';

contract DistributorTest is Helpers {
  bytes32 internal constant _MAKER_ROLE = keccak256('DISTRIBUTION_MAKER_ROLE');
  bytes32 internal constant _CHECKER_ROLE = keccak256('CHECKER_ROLE');
  uint256 internal constant _ALICE_SHARE = 300;
  uint256 internal constant _BOB_SHARE = 700;
  uint256 internal constant _TOTAL = _ALICE_SHARE + _BOB_SHARE;
  uint64 internal constant _EXPIRY = 2_000_000_000;

  Distributor internal _distributor;
  MockAsset internal _asset;
  address internal _token;
  address internal _maker = makeAddr('maker');
  address internal _checker = makeAddr('checker');
  address internal _funder = makeAddr('funder');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');
  address internal _stranger = makeAddr('stranger');
  bytes32 internal _root;

  function setUp() public virtual {
    vm.warp(1_900_000_000);
    _token = _mockContract('token');
    vm.mockCall(_token, abi.encodeWithSelector(IAccessControl.hasRole.selector), abi.encode(false));
    _grant(_MAKER_ROLE, _maker);
    _grant(_CHECKER_ROLE, _checker);
    _canReceive(_alice, true);
    _canReceive(_bob, true);
    _distributor = new Distributor(_token);
    _asset = new MockAsset(6);
    _asset.mint(_funder, 10 * _TOTAL);
    vm.prank(_funder);
    _asset.approve(address(_distributor), type(uint256).max);
    _root = Hashes.commutativeKeccak256(_leaf(_alice, _ALICE_SHARE), _leaf(_bob, _BOB_SHARE));
  }

  function _grant(
    bytes32 _role,
    address _who
  ) internal {
    vm.mockCall(_token, abi.encodeCall(IAccessControl.hasRole, (_role, _who)), abi.encode(true));
  }

  function _canReceive(
    address _who,
    bool _can
  ) internal {
    vm.mockCall(_token, abi.encodeCall(IERC7943Fungible.canReceive, (_who)), abi.encode(_can));
  }

  function _leaf(
    address _holder,
    uint256 _amount
  ) internal pure returns (bytes32 _hash) {
    _hash = keccak256(bytes.concat(keccak256(abi.encode(_holder, _amount))));
  }

  function _proof(
    bytes32 _sibling
  ) internal pure returns (bytes32[] memory _path) {
    _path = new bytes32[](1);
    _path[0] = _sibling;
  }

  function _proposed() internal returns (uint256 _id) {
    vm.prank(_maker);
    _id = _distributor.propose(_root, IERC20(address(_asset)), _TOTAL, _EXPIRY, _funder);
  }

  function _approved() internal returns (uint256 _id) {
    _id = _proposed();
    vm.prank(_checker);
    _distributor.approve(_id);
  }

  function _unauthorized(
    address _caller
  ) internal pure returns (bytes memory _data) {
    _data = abi.encodeWithSelector(IDistributor.Distributor_Unauthorized.selector, _caller);
  }
}

contract Distributor_Propose is DistributorTest {
  function test_WithNoToken_ItReverts() external {
    vm.expectRevert(IDistributor.Distributor_InvalidValue.selector);
    new Distributor(address(0));
  }

  function testFuzz_OnlyTheMakerProposes(
    address _caller
  ) external {
    if (_caller == _maker) _caller = _stranger;
    vm.expectRevert(_unauthorized(_caller));
    vm.prank(_caller);
    _distributor.propose(_root, IERC20(address(_asset)), _TOTAL, _EXPIRY, _funder);
  }

  function test_ItRecordsAndEmits() external {
    vm.expectEmit(address(_distributor));
    emit IDistributor.DistributionProposed(1, _root, IERC20(address(_asset)), _TOTAL, _EXPIRY, _funder);
    uint256 _id = _proposed();
    assertEq(_id, 1);
    IDistributor.Distribution memory _d = _distributor.distributionOf(_id);
    assertEq(_d.root, _root);
    assertEq(address(_d.asset), address(_asset));
    assertEq(_d.total, _TOTAL);
    assertEq(_d.expiry, _EXPIRY);
    assertEq(_d.maker, _maker);
    assertEq(_d.funder, _funder);
    assertFalse(_d.approved);
    assertEq(_proposed(), 2);
  }

  function test_EachValueMustBeThere() external {
    vm.startPrank(_maker);
    vm.expectRevert(IDistributor.Distributor_InvalidValue.selector);
    _distributor.propose(bytes32(0), IERC20(address(_asset)), _TOTAL, _EXPIRY, _funder);
    vm.expectRevert(IDistributor.Distributor_InvalidValue.selector);
    _distributor.propose(_root, IERC20(address(0)), _TOTAL, _EXPIRY, _funder);
    vm.expectRevert(IDistributor.Distributor_InvalidValue.selector);
    _distributor.propose(_root, IERC20(address(_asset)), 0, _EXPIRY, _funder);
    vm.expectRevert(IDistributor.Distributor_InvalidValue.selector);
    _distributor.propose(_root, IERC20(address(_asset)), _TOTAL, _EXPIRY, address(0));
    vm.expectRevert(IDistributor.Distributor_InvalidValue.selector);
    _distributor.propose(_root, IERC20(address(_asset)), _TOTAL, uint64(block.timestamp), _funder);
    vm.stopPrank();
  }
}

contract Distributor_Approve is DistributorTest {
  function testFuzz_OnlyTheCheckerApproves(
    address _caller
  ) external {
    if (_caller == _checker) _caller = _stranger;
    uint256 _id = _proposed();
    vm.expectRevert(_unauthorized(_caller));
    vm.prank(_caller);
    _distributor.approve(_id);
  }

  function test_TheMakerCannotApproveItsOwn() external {
    _grant(_CHECKER_ROLE, _maker);
    uint256 _id = _proposed();
    vm.expectRevert(IDistributor.Distributor_SelfApproval.selector);
    vm.prank(_maker);
    _distributor.approve(_id);
  }

  function test_ItPullsTheFundingAndEmits() external {
    uint256 _id = _proposed();
    vm.expectEmit(address(_distributor));
    emit IDistributor.DistributionApproved(_id, _checker);
    vm.prank(_checker);
    _distributor.approve(_id);
    assertEq(_asset.balanceOf(address(_distributor)), _TOTAL);
    assertTrue(_distributor.distributionOf(_id).approved);
  }

  function test_ApprovingTwiceReverts() external {
    uint256 _id = _approved();
    vm.expectRevert(IDistributor.Distributor_AlreadyApproved.selector);
    vm.prank(_checker);
    _distributor.approve(_id);
  }

  function test_ApprovingNothingReverts() external {
    vm.expectRevert(IDistributor.Distributor_NotApproved.selector);
    vm.prank(_checker);
    _distributor.approve(99);
  }

  function test_AfterTheExpiryNothingIsApproved() external {
    uint256 _id = _proposed();
    vm.warp(_distributor.distributionOf(_id).expiry + 1);
    vm.expectRevert(IDistributor.Distributor_Expired.selector);
    vm.prank(_checker);
    _distributor.approve(_id);
    assertEq(_asset.balanceOf(address(_distributor)), 0, 'no funding pulled');
  }

  function test_AtTheExpiryItCanStillBeApproved() external {
    uint256 _id = _proposed();
    vm.warp(_distributor.distributionOf(_id).expiry);
    vm.prank(_checker);
    _distributor.approve(_id);
    assertTrue(_distributor.distributionOf(_id).approved);
  }

  function test_AFunderShortOfMoneyStopsTheApproval() external {
    uint256 _id = _proposed();
    vm.prank(_funder);
    _asset.approve(address(_distributor), 0);
    vm.expectRevert();
    vm.prank(_checker);
    _distributor.approve(_id);
    assertFalse(_distributor.distributionOf(_id).approved);
  }
}

contract Distributor_Claim is DistributorTest {
  uint256 internal _id;

  function setUp() public override {
    super.setUp();
    _id = _approved();
  }

  function testFuzz_AnyoneSubmitsAndTheMoneyGoesToTheHolder(
    address _caller
  ) external {
    vm.expectEmit(address(_distributor));
    emit IDistributor.DistributionClaimed(_id, _alice, _ALICE_SHARE);
    vm.prank(_caller);
    _distributor.claim(_id, _alice, _ALICE_SHARE, _proof(_leaf(_bob, _BOB_SHARE)));
    assertEq(_asset.balanceOf(_alice), _ALICE_SHARE);
    assertTrue(_distributor.hasClaimed(_id, _alice));
    assertEq(_distributor.distributionOf(_id).claimed, _ALICE_SHARE);
  }

  function test_AProofForTheWrongHolderIsRefused() external {
    _canReceive(_stranger, true);
    vm.expectRevert(IDistributor.Distributor_BadProof.selector);
    _distributor.claim(_id, _stranger, _ALICE_SHARE, _proof(_leaf(_bob, _BOB_SHARE)));
  }

  function test_AProofForAnotherAmountIsRefused() external {
    vm.expectRevert(IDistributor.Distributor_BadProof.selector);
    _distributor.claim(_id, _alice, _ALICE_SHARE + 1, _proof(_leaf(_bob, _BOB_SHARE)));
  }

  function test_ADoubleClaimIsRefused() external {
    bytes32[] memory _path = _proof(_leaf(_bob, _BOB_SHARE));
    _distributor.claim(_id, _alice, _ALICE_SHARE, _path);
    vm.expectRevert(IDistributor.Distributor_AlreadyClaimed.selector);
    _distributor.claim(_id, _alice, _ALICE_SHARE, _path);
  }

  function test_AHolderWhoMayNotReceiveCannotClaim() external {
    _canReceive(_alice, false);
    bytes32[] memory _path = _proof(_leaf(_bob, _BOB_SHARE));
    vm.expectRevert(abi.encodeWithSelector(IDistributor.Distributor_HolderMayNotReceive.selector, _alice));
    _distributor.claim(_id, _alice, _ALICE_SHARE, _path);

    _canReceive(_alice, true);
    _distributor.claim(_id, _alice, _ALICE_SHARE, _path);
    assertEq(_asset.balanceOf(_alice), _ALICE_SHARE);
  }

  function test_AtTheExpiryAClaimPassesAndAfterItIsRefused() external {
    bytes32[] memory _path = _proof(_leaf(_bob, _BOB_SHARE));
    vm.warp(_EXPIRY);
    _distributor.claim(_id, _alice, _ALICE_SHARE, _path);
    vm.warp(uint256(_EXPIRY) + 1);
    vm.expectRevert(IDistributor.Distributor_Expired.selector);
    _distributor.claim(_id, _bob, _BOB_SHARE, _proof(_leaf(_alice, _ALICE_SHARE)));
  }

  function test_BeforeApprovalNobodyClaims() external {
    uint256 _pending = _proposed();
    vm.expectRevert(IDistributor.Distributor_NotApproved.selector);
    _distributor.claim(_pending, _alice, _ALICE_SHARE, _proof(_leaf(_bob, _BOB_SHARE)));
  }

  /// @dev A list that sums above the funding pays first come, first served, and never touches another distribution's money
  function test_ClaimsCannotPassTheFunding() external {
    vm.prank(_maker);
    uint256 _short = _distributor.propose(_root, IERC20(address(_asset)), _ALICE_SHARE, _EXPIRY, _funder);
    vm.prank(_checker);
    _distributor.approve(_short);
    assertEq(_asset.balanceOf(address(_distributor)), _TOTAL + _ALICE_SHARE);

    vm.expectRevert(IDistributor.Distributor_OverFunding.selector);
    _distributor.claim(_short, _bob, _BOB_SHARE, _proof(_leaf(_alice, _ALICE_SHARE)));
    _distributor.claim(_short, _alice, _ALICE_SHARE, _proof(_leaf(_bob, _BOB_SHARE)));
    assertEq(_distributor.distributionOf(_short).claimed, _ALICE_SHARE);
  }

  function testFuzz_ClaimedNeverPassesTotal(
    bool _aliceFirst
  ) external {
    if (_aliceFirst) _distributor.claim(_id, _alice, _ALICE_SHARE, _proof(_leaf(_bob, _BOB_SHARE)));
    _distributor.claim(_id, _bob, _BOB_SHARE, _proof(_leaf(_alice, _ALICE_SHARE)));
    if (!_aliceFirst) _distributor.claim(_id, _alice, _ALICE_SHARE, _proof(_leaf(_bob, _BOB_SHARE)));
    assertEq(_distributor.distributionOf(_id).claimed, _TOTAL);
    assertEq(_asset.balanceOf(address(_distributor)), 0);
  }
}

contract Distributor_Sweep is DistributorTest {
  uint256 internal _id;

  function setUp() public override {
    super.setUp();
    _id = _approved();
  }

  function test_BeforeTheExpiryItReverts() external {
    vm.warp(_EXPIRY);
    vm.expectRevert(IDistributor.Distributor_NotExpired.selector);
    _distributor.sweep(_id);
  }

  function test_BeforeApprovalItReverts() external {
    uint256 _pending = _proposed();
    vm.warp(uint256(_EXPIRY) + 1);
    vm.expectRevert(IDistributor.Distributor_NotApproved.selector);
    _distributor.sweep(_pending);
  }

  function testFuzz_AfterTheExpiryWhatIsUnclaimedGoesBack(
    address _caller
  ) external {
    _distributor.claim(_id, _alice, _ALICE_SHARE, _proof(_leaf(_bob, _BOB_SHARE)));
    uint256 _before = _asset.balanceOf(_funder);
    vm.warp(uint256(_EXPIRY) + 1);
    vm.expectEmit(address(_distributor));
    emit IDistributor.DistributionSwept(_id, _BOB_SHARE);
    vm.prank(_caller);
    _distributor.sweep(_id);
    assertEq(_asset.balanceOf(_funder), _before + _BOB_SHARE);
    assertEq(_asset.balanceOf(address(_distributor)), 0);
  }

  function test_ASecondSweepPaysNothing() external {
    vm.warp(uint256(_EXPIRY) + 1);
    _distributor.sweep(_id);
    uint256 _before = _asset.balanceOf(_funder);
    _distributor.sweep(_id);
    assertEq(_asset.balanceOf(_funder), _before);
  }
}
