// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IAdapter
 * @notice The plug between a `Portfolio` and one place money can go: a target vault, a custodian, a strategy. Immutable
 *         and attested, so its settings are part of the codehash the council reviewed
 * @dev The only way back out of an adapter is to its own portfolio: `deallocate` names no receiver
 */
interface IAdapter {
  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Puts to work assets the portfolio has just sent to this adapter
   * @dev Only the portfolio
   * @param _assets The assets sent
   */
  function allocate(
    uint256 _assets
  ) external;

  /**
   * @notice Returns assets to the portfolio
   * @dev Only the portfolio
   * @param _assets The assets to return
   */
  function deallocate(
    uint256 _assets
  ) external;

  /*///////////////////////////////////////////////////////////////
                            VIEWS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice What the position is worth now, for a priced adapter
   * @return _value The value in assets; zero with `fresh()` false when it cannot be read, and zero for a reported adapter
   */
  function value() external view returns (uint256 _value);

  /**
   * @notice What can be returned to the portfolio now
   * @return _liquid The assets available to `deallocate`; zero when it cannot be read
   */
  function liquid() external view returns (uint256 _liquid);

  /**
   * @notice Whether `value()` can be trusted right now
   * @return _fresh True when the value was read; a failed read is never a loss, it stops dealing
   */
  function fresh() external view returns (bool _fresh);

  /**
   * @notice Whether the value comes from a report rather than from the chain
   * @return _reported True for an adapter whose money can sit off-chain
   */
  function reported() external view returns (bool _reported);

  /**
   * @notice The risks this adapter counts against: one for itself and any it shares with other adapters
   * @return _ids The risk ids, at least one
   */
  function riskIds() external view returns (bytes32[] memory _ids);

  /**
   * @notice The portfolio this adapter serves
   * @return _portfolio The portfolio, fixed at construction
   */
  // solhint-disable-next-line style-guide-casing
  function PORTFOLIO() external view returns (address _portfolio);

  /**
   * @notice The asset this adapter takes and returns
   * @return _asset The asset
   */
  function asset() external view returns (address _asset);
}
