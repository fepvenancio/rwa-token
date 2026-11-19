// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title IDistributor
 * @notice Pays a funded distribution to a token's holders. The record is a Merkle root of `(holder, amount)` built off-chain at
 *         the record date, so the token gains no snapshots and transfers cost the same. A maker and a different checker
 *         approve it, then holders claim with a proof. A holder who may not receive cannot claim. Unclaimed money goes back
 *         to the funder after the expiry
 * @dev Immutable, one per token, with no role table: it asks the token. The checker's approval pulls the funding, so a
 *      distribution that can be claimed is one that was paid for. The list is a claim, like a NAV report: the root proves
 *      which list was used, not that it is right, and a list that sums above the funding pays first come, first served
 */
interface IDistributor {
  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Why `claimBatch` passed over a row
   * @param ALREADY_CLAIMED The holder's share was paid before
   * @param MAY_NOT_RECEIVE The token says the holder may not receive now
   * @param PAYMENT_FAILED The asset refused the payment; the share stays unclaimed
   */
  enum ClaimSkip {
    ALREADY_CLAIMED,
    MAY_NOT_RECEIVE,
    PAYMENT_FAILED
  }

  /**
   * @notice One distribution
   * @param root The Merkle root of `(holder, amount)`
   * @param asset What it pays
   * @param total What it pays in all
   * @param claimed What has been claimed or swept
   * @param expiry The last moment a holder can claim
   * @param maker Who proposed it, who may not approve it
   * @param funder Who pays for it, and gets back what is unclaimed
   * @param approved Whether a checker approved and funded it
   */
  struct Distribution {
    bytes32 root;
    IERC20 asset;
    uint256 total;
    uint256 claimed;
    uint64 expiry;
    address maker;
    address funder;
    bool approved;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a maker proposes a distribution
   * @param _id The distribution
   * @param _root The Merkle root
   * @param _asset What it pays
   * @param _total What it pays in all
   * @param _expiry The last moment a holder can claim
   * @param _funder Who pays for it
   */
  event DistributionProposed(
    uint256 indexed _id, bytes32 _root, IERC20 indexed _asset, uint256 _total, uint64 _expiry, address _funder
  );

  /**
   * @notice Emitted when a checker approves a distribution and it is funded
   * @param _id The distribution
   * @param _checker The checker
   */
  event DistributionApproved(uint256 indexed _id, address indexed _checker);

  /**
   * @notice Emitted when a holder's share is paid
   * @param _id The distribution
   * @param _holder The holder
   * @param _amount What it was paid
   */
  event DistributionClaimed(uint256 indexed _id, address indexed _holder, uint256 _amount);

  /**
   * @notice Emitted when `claimBatch` passes over a row. The holder's share stays as it was: unclaimed, unless the
   *         reason is that it was already paid
   * @param _id The distribution
   * @param _holder The holder
   * @param _reason Why
   */
  event DistributionClaimSkipped(uint256 indexed _id, address indexed _holder, ClaimSkip _reason);

  /**
   * @notice Emitted when what is unclaimed goes back to the funder
   * @param _id The distribution
   * @param _amount What went back
   */
  event DistributionSwept(uint256 indexed _id, uint256 _amount);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when approving a distribution twice
  error Distributor_AlreadyApproved();

  /// @notice Thrown when a holder claims twice
  error Distributor_AlreadyClaimed();

  /// @notice Thrown when a proof does not lead to the root
  error Distributor_BadProof();

  /// @notice Thrown when claiming after the expiry
  error Distributor_Expired();

  /// @notice Thrown when approving a distribution nobody proposed, or when a claim or a sweep is on one not approved
  error Distributor_NotApproved();

  /// @notice Thrown when sweeping before the expiry
  error Distributor_NotExpired();

  /// @notice Thrown when a maker tries to approve its own distribution
  error Distributor_SelfApproval();

  /**
   * @notice Thrown when the holder may not receive under the token's policy
   * @param _holder The holder
   */
  error Distributor_HolderMayNotReceive(address _holder);

  /// @notice Thrown when claims would pass what was funded
  error Distributor_OverFunding();

  /**
   * @notice Thrown when the caller lacks the token role this needs
   * @param _caller The caller
   */
  error Distributor_Unauthorized(address _caller);

  /// @notice Thrown when a required value is zero, or an expiry is not in the future
  error Distributor_InvalidValue();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Proposes a distribution
   * @dev The token's DISTRIBUTION_MAKER_ROLE
   * @param _root The Merkle root of `(holder, amount)`, each leaf the double hash OpenZeppelin's `StandardMerkleTree` uses
   * @param _asset What it pays
   * @param _total What it pays in all
   * @param _expiry The last moment a holder can claim
   * @param _funder Who pays for it; it approves this contract for the total
   * @return _id The distribution
   */
  function propose(
    bytes32 _root,
    IERC20 _asset,
    uint256 _total,
    uint64 _expiry,
    address _funder
  ) external returns (uint256 _id);

  /**
   * @notice Approves a distribution and pulls its funding
   * @dev The token's CHECKER_ROLE, never the maker
   * @param _id The distribution
   */
  function approve(
    uint256 _id
  ) external;

  /**
   * @notice Pays a holder's share
   * @dev Anyone, for the holder; the money goes only to the holder
   * @param _id The distribution
   * @param _holder The holder
   * @param _amount Its share
   * @param _proof The Merkle proof
   */
  function claim(
    uint256 _id,
    address _holder,
    uint256 _amount,
    bytes32[] calldata _proof
  ) external;

  /**
   * @notice Pays many holders' shares in one transaction
   * @dev Anyone, for the holders; the money goes only to each holder. A row is passed over, with
   *      `DistributionClaimSkipped`, when its holder was already paid, may not receive the token now, or the asset
   *      refuses the payment (a gated asset that does not accept the holder); a row passed over leaves the holder free
   *      to claim later. The caller's own errors revert the whole batch: arrays of different lengths, a proof that
   *      does not match, a row above what is left of the funding, a distribution not approved or expired
   * @param _id The distribution
   * @param _holders The holders
   * @param _amounts Their shares, in the same order
   * @param _proofs Their Merkle proofs, in the same order
   * @return _paid How many rows were paid
   */
  function claimBatch(
    uint256 _id,
    address[] calldata _holders,
    uint256[] calldata _amounts,
    bytes32[][] calldata _proofs
  ) external returns (uint256 _paid);

  /**
   * @notice Sends what is unclaimed back to the funder, after the expiry
   * @dev Anyone
   * @param _id The distribution
   */
  function sweep(
    uint256 _id
  ) external;

  /*///////////////////////////////////////////////////////////////
                            VIEWS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The token this pays holders of
   * @return _token The token
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function TOKEN() external view returns (address _token);

  /**
   * @notice The token role that proposes
   * @return _role keccak256('DISTRIBUTION_MAKER_ROLE')
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function DISTRIBUTION_MAKER_ROLE() external view returns (bytes32 _role);

  /**
   * @notice The token role that approves
   * @return _role keccak256('CHECKER_ROLE')
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function CHECKER_ROLE() external view returns (bytes32 _role);

  /**
   * @notice A distribution
   * @param _id The distribution
   * @return _distribution It
   */
  function distributionOf(
    uint256 _id
  ) external view returns (Distribution memory _distribution);

  /**
   * @notice Whether a holder has claimed
   * @param _id The distribution
   * @param _holder The holder
   * @return _claimed True when it has
   */
  function hasClaimed(
    uint256 _id,
    address _holder
  ) external view returns (bool _claimed);
}
