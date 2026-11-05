// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {MerkleProof} from '@openzeppelin/contracts/utils/cryptography/MerkleProof.sol';

import {IDistributor} from 'interfaces/IDistributor.sol';
import {IERC7943Fungible} from 'interfaces/IERC7943Fungible.sol';

/**
 * @title Distributor
 * @notice Pays a funded distribution to a token's holders, as specified in `IDistributor`
 * @dev Immutable, one per token
 */
contract Distributor is IDistributor {
  using SafeERC20 for IERC20;

  /// @inheritdoc IDistributor
  bytes32 public constant DISTRIBUTION_MAKER_ROLE = keccak256('DISTRIBUTION_MAKER_ROLE');

  /// @inheritdoc IDistributor
  bytes32 public constant CHECKER_ROLE = keccak256('CHECKER_ROLE');

  /// @inheritdoc IDistributor
  address public immutable TOKEN;

  /// @notice The next distribution's id; the first is 1
  uint256 internal _nextId = 1;

  /// @notice The distributions
  mapping(uint256 _id => Distribution _distribution) internal _distributions;

  /// @inheritdoc IDistributor
  mapping(uint256 _id => mapping(address _holder => bool _claimed)) public hasClaimed;

  /**
   * @notice Deploys it
   * @param _token The token it pays holders of
   */
  constructor(
    address _token
  ) {
    if (_token == address(0)) revert Distributor_InvalidValue();
    TOKEN = _token;
  }

  /// @inheritdoc IDistributor
  function propose(
    bytes32 _root,
    IERC20 _asset,
    uint256 _total,
    uint64 _expiry,
    address _funder
  ) external returns (uint256 _id) {
    _onlyRole(DISTRIBUTION_MAKER_ROLE);
    if (
      _root == bytes32(0) || address(_asset) == address(0) || _total == 0 || _funder == address(0)
        || _expiry <= block.timestamp
    ) revert Distributor_InvalidValue();
    _id = _nextId++;
    _distributions[_id] = Distribution({
      root: _root,
      asset: _asset,
      total: _total,
      claimed: 0,
      expiry: _expiry,
      maker: msg.sender,
      funder: _funder,
      approved: false
    });
    emit DistributionProposed(_id, _root, _asset, _total, _expiry, _funder);
  }

  /// @inheritdoc IDistributor
  function approve(
    uint256 _id
  ) external {
    _onlyRole(CHECKER_ROLE);
    Distribution storage _d = _distributions[_id];
    if (_d.root == bytes32(0)) revert Distributor_NotApproved();
    if (_d.approved) revert Distributor_AlreadyApproved();
    if (block.timestamp > _d.expiry) revert Distributor_Expired();
    if (msg.sender == _d.maker) revert Distributor_SelfApproval();
    _d.approved = true;
    emit DistributionApproved(_id, msg.sender);
    // The funder chose to approve this contract, and a maker and a checker named it.
    // slither-disable-next-line arbitrary-send-erc20
    _d.asset.safeTransferFrom(_d.funder, address(this), _d.total); // aderyn-ignore(arbitrary-transfer-from)
  }

  /// @inheritdoc IDistributor
  function claim(
    uint256 _id,
    address _holder,
    uint256 _amount,
    bytes32[] calldata _proof
  ) external {
    Distribution storage _d = _distributions[_id];
    if (!_d.approved) revert Distributor_NotApproved();
    if (block.timestamp > _d.expiry) revert Distributor_Expired();
    if (hasClaimed[_id][_holder]) revert Distributor_AlreadyClaimed();
    // View interface: compiled to STATICCALL, so the token cannot change any state or re-enter before the writes below.
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (!IERC7943Fungible(TOKEN).canReceive(_holder)) revert Distributor_HolderMayNotReceive(_holder);
    bytes32 _leaf = keccak256(bytes.concat(keccak256(abi.encode(_holder, _amount))));
    if (!MerkleProof.verifyCalldata(_proof, _d.root, _leaf)) revert Distributor_BadProof();
    if (_amount > _d.total - _d.claimed) revert Distributor_OverFunding();

    hasClaimed[_id][_holder] = true;
    _d.claimed += _amount;
    emit DistributionClaimed(_id, _holder, _amount);
    _d.asset.safeTransfer(_holder, _amount);
  }

  /// @inheritdoc IDistributor
  function sweep(
    uint256 _id
  ) external {
    Distribution storage _d = _distributions[_id];
    if (!_d.approved) revert Distributor_NotApproved();
    if (block.timestamp <= _d.expiry) revert Distributor_NotExpired();
    uint256 _left = _d.total - _d.claimed;
    _d.claimed = _d.total;
    emit DistributionSwept(_id, _left);
    _d.asset.safeTransfer(_d.funder, _left);
  }

  /// @inheritdoc IDistributor
  function distributionOf(
    uint256 _id
  ) external view returns (Distribution memory _distribution) {
    _distribution = _distributions[_id];
  }

  /**
   * @notice Reverts unless the caller holds a token role, asked live
   * @param _role The role
   */
  function _onlyRole(
    bytes32 _role
  ) private view {
    if (!IAccessControl(TOKEN).hasRole(_role, msg.sender)) revert Distributor_Unauthorized(msg.sender);
  }
}
