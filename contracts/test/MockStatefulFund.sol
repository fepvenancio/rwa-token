// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title MockStatefulFund
 * @notice A "fund" whose read function writes state. A rule calls the fund through a view interface, which compiles to
 *         STATICCALL, so a rule that calls this mock from `check` must revert: proof that `check` cannot change state
 * @dev The selector matches `IFund.admission`; mutability is not part of a selector
 */
contract MockStatefulFund {
  /// @notice Incremented by every read; only possible when called with CALL
  uint256 public writes;

  /**
   * @notice `admission` that writes
   * @return _index A registered class
   * @return _held No classes
   * @return _exempt Not exempt
   * @return _count An empty fund
   * @return _cap A cap of one
   * @return _rule The caller, so the rule would be the installed one if the call succeeded
   */
  function admission(
    address,
    address
  ) external returns (uint256 _index, uint256 _held, bool _exempt, uint256 _count, uint256 _cap, address _rule) {
    ++writes;
    (_index, _held, _exempt, _count, _cap, _rule) = (1, 0, false, 0, 1, msg.sender);
  }
}
