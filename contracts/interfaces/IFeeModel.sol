// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IFeeModel
 * @notice Computes a period's fee, in assets. Immutable with no storage, so the attested codehash covers the rates; changing
 *         fees means deploying a new one and a timelock swap. The caller keeps the mark and its clocks
 * @dev Management: the gross value × rate × `feeAge` / one year. Performance: the hurdle runs from when the mark last moved,
 *      `hurdled = mark × (1 + hurdle rate × markAge / one year)`, on the price after the management fee. Below `hurdled` there
 *      is no fee and the mark stays. Above it a hard hurdle charges `rate × (price − hurdled)`, and a soft one
 *      `min(rate × (price − mark), price − hurdled)`: a full catch-up, so the investor keeps everything up to `hurdled` and
 *      net value never falls as gross rises. The mark moves to the price after fees, which is never below `hurdled`. Because the
 *      hurdle runs on `markAge`, a gain cannot clear it by being sliced across many calls. With no shares there is no fee and
 *      the mark stays. It never reverts: ages are capped and a figure too large to be real gets no fee
 */
interface IFeeModel {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a rate is above its ceiling
  error FeeModel_RateTooHigh();

  /// @notice Thrown when a rate would be charged with nobody to pay it to
  error FeeModel_ZeroRecipient();

  /*///////////////////////////////////////////////////////////////
                            VIEWS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Quotes the fee
   * @param _gross The gross value, in assets
   * @param _supply All shares
   * @param _mark The high-water mark: assets per 1e18 share units
   * @param _markAge The seconds since the mark last moved
   * @param _feeAge The seconds since the last fee
   * @return _fee The fee, in assets; never above `_gross`
   * @return _newMark The mark after this fee
   * @return _markMoved Whether the mark moved, which restarts its clock
   */
  function quote(
    uint256 _gross,
    uint256 _supply,
    uint256 _mark,
    uint256 _markAge,
    uint256 _feeAge
  ) external view returns (uint256 _fee, uint256 _newMark, bool _markMoved);

  /**
   * @notice Who is paid
   * @return _recipient The recipient
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function RECIPIENT() external view returns (address _recipient);

  /**
   * @notice The yearly management rate
   * @return _bps In basis points; at most 500
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function MANAGEMENT_BPS() external view returns (uint256 _bps);

  /**
   * @notice The performance rate
   * @return _bps In basis points; at most 5,000
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function PERFORMANCE_BPS() external view returns (uint256 _bps);

  /**
   * @notice The yearly hurdle rate
   * @return _bps In basis points; at most 5,000
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function HURDLE_BPS() external view returns (uint256 _bps);

  /**
   * @notice Whether the hurdle is soft
   * @return _soft True for a soft hurdle with a full catch-up, false for a hard one
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function SOFT_HURDLE() external view returns (bool _soft);
}
