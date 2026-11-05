// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IFeeModel
 * @notice Computes a period's fee, in assets. Immutable with no storage, so the attested codehash covers the rates; changing
 *         fees means deploying a new one and a timelock swap. The caller keeps the mark, its clocks and what was paid since
 *         the mark moved
 * @dev Management: the gross value × rate × `feeAge` / one year. Performance: the hurdle runs from when the mark last moved,
 *      `hurdled = mark × (1 + hurdle rate × markAge / one year)`, on the price after the management fee with what was paid
 *      since the mark moved added back. Below `hurdled` there is no fee and the mark stays. Above it a hard hurdle is due
 *      `rate × (price − hurdled)`, and a soft one `min(rate × (price − mark), price − hurdled)`: a full catch-up, so the
 *      investor keeps everything up to `hurdled` and net value never falls as gross rises. What was already paid since the
 *      mark moved comes off what is due. While a soft hurdle is still catching up the mark and its clock wait and what is
 *      paid is carried, so a count inside the band does not cost the catch-up; once due is the rate on the whole gain, the
 *      mark moves to the price after fees, which is never below `hurdled`, and what was paid returns to zero. Because the
 *      hurdle runs on `markAge`, a gain cannot clear it by being sliced across many calls. With no shares there is no fee and
 *      the mark stays. It never reverts: ages are capped and a figure too large to be real gets no fee
 */
interface IFeeModel {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a rate is above its ceiling
  error FeeModel_RateTooHigh();

  /// @notice Thrown when a model names nobody to pay, even with no rate: a swap to it must still pay what is owed
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
   * @param _paidSince The performance fee paid since the mark last moved: assets per 1e18 share units
   * @return _fee The fee, in assets; never above `_gross`
   * @return _newMark The mark after this fee
   * @return _markMoved Whether the mark moved, which restarts its clock
   * @return _newPaidSince The performance fee paid since the mark last moved, after this fee; zero when it moved
   */
  function quote(
    uint256 _gross,
    uint256 _supply,
    uint256 _mark,
    uint256 _markAge,
    uint256 _feeAge,
    uint256 _paidSince
  ) external view returns (uint256 _fee, uint256 _newMark, bool _markMoved, uint256 _newPaidSince);

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
