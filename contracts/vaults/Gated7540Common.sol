// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

import {GatedVaultBase} from 'contracts/vaults/GatedVaultBase.sol';

/**
 * @title Gated7540Common
 * @notice What `Gated7540Vault` and `Gated7540Settlement` share: the storage they both act on and how a controller's request
 *         reads
 * @dev Its own contract, so that the two cannot disagree on the layout
 */
abstract contract Gated7540Common is GatedVaultBase {
  using SafeCast for uint256;

  /**
   * @notice One controller's request on one side: assets to shares on a deposit, shares to assets on a redemption
   * @param period The period holding `pending`; 0 with nothing pending
   * @param pending Requested, not yet settled
   * @param paid Settled and not yet claimed: what the controller gave
   * @param owed What that buys, not yet claimed
   */
  struct Request {
    uint64 period;
    uint128 pending;
    uint128 paid;
    uint128 owed;
  }

  /**
   * @notice One side of one period
   * @param paid What its requests gave, net of rejects
   * @param owed What that bought, at settlement
   */
  struct Book {
    uint128 paid;
    uint128 owed;
  }

  /**
   * @notice ERC-7201 namespaced storage of the vault
   * @param asset The underlying asset
   * @param decimals The share decimals: the asset's plus 6
   * @param openPeriod The period requests join; the first is 1
   * @param settledPeriod The last settled period
   * @param lastNav The value the last settlement dealt at, behind `convertTo*` and `totalAssets`
   * @param lastSupply All shares at that value
   * @param unclaimedShares Shares bought in settled periods and not yet minted
   * @param pendingDeposits Assets held for unsettled deposit requests
   * @param claimableCash Assets held for settled redemptions
   * @param pendingRedeemShares The shares booked to pending redemptions, every controller together: the part of the
   *        vault's own balance that a forced transfer may not take
   * @param requests Each controller's request on each side (true is the deposit side)
   * @param books Each period's totals on each side
   * @param operators Operator approvals per controller
   * @custom:storage-location erc7201:gated.storage.Gated7540Vault
   */
  struct Gated7540Storage {
    IERC20 asset;
    uint8 decimals;
    uint64 openPeriod;
    uint64 settledPeriod;
    uint128 lastNav;
    uint128 lastSupply;
    uint256 unclaimedShares;
    uint256 pendingDeposits;
    uint256 claimableCash;
    uint256 pendingRedeemShares;
    mapping(address _controller => mapping(bool _isDeposit => Request _request)) requests;
    mapping(uint256 _period => mapping(bool _isDeposit => Book _book)) books;
    mapping(address _controller => mapping(address _operator => bool _approved)) operators;
  }

  /// @notice The role allowed to close and settle periods
  bytes32 internal constant _SETTLER_ROLE = keccak256('SETTLER_ROLE');

  /// @notice The virtual shares of the price, and the digits added to the asset's decimals to keep them honest
  uint256 internal constant _VIRTUAL_SHARES = 1e6;

  /// @notice keccak256(abi.encode(uint256(keccak256('gated.storage.Gated7540Vault')) - 1)) & ~bytes32(uint256(0xff))
  // Read in assembly by the ERC-7201 accessor (test: Gated7540VaultUnit_Storage).
  // aderyn-ignore-next-line(unused-state-variable)
  bytes32 private constant _GATED_7540_STORAGE_LOCATION =
    0x2cc225a2bfbd5a47b58fbfec984f4f856b2fa5e8b68081e6d3300ec76f5f3900;

  /**
   * @notice Writes a controller's request
   * @param _controller The controller
   * @param _isDeposit True on the deposit side
   * @param _r The request
   */
  function _store(
    address _controller,
    bool _isDeposit,
    Request memory _r
  ) internal {
    _getGated7540Storage().requests[_controller][_isDeposit] = _r;
  }

  /**
   * @notice A controller's request with any settled part rolled into its claimable amounts
   * @param _controller The controller
   * @param _isDeposit True on the deposit side
   * @return _r The request
   */
  function _request(
    address _controller,
    bool _isDeposit
  ) internal view returns (Request memory _r) {
    Gated7540Storage storage $ = _getGated7540Storage();
    _r = $.requests[_controller][_isDeposit];
    if (_r.period == 0 || _r.period > $.settledPeriod) return _r;
    Book memory _book = $.books[_r.period][_isDeposit];
    _r.paid += _r.pending;
    _r.owed += Math.mulDiv(_r.pending, _book.owed, _book.paid).toUint128();
    _r.pending = 0;
    _r.period = 0;
  }

  /**
   * @notice The ERC-7201 storage of the vault
   * @return $ The storage pointer
   */
  function _getGated7540Storage() internal pure returns (Gated7540Storage storage $) {
    assembly ('memory-safe') {
      $.slot := _GATED_7540_STORAGE_LOCATION
    }
  }
}
