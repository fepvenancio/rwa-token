// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title MockStatefulToken
 * @notice A "token" whose read functions write state. Rules call the token through view interfaces, which compile to
 *         STATICCALL, so any rule that calls this mock must revert: proof that nothing the rule calls can change state
 *         (and so cannot re-enter the rule with effect) between the call and the rule's own write
 * @dev The selectors match `IAccessControl.hasRole`, `IERC20.balanceOf` and `IPolicyGated.policyHook`; mutability is not
 *      part of a selector
 */
contract MockStatefulToken {
  /// @notice Incremented by every read; only possible when called with CALL
  uint256 public writes;

  /**
   * @notice `hasRole` that writes
   * @return _granted Always true
   */
  function hasRole(
    bytes32,
    address
  ) external returns (bool _granted) {
    ++writes;
    _granted = true;
  }

  /**
   * @notice `balanceOf` that writes
   * @return _balance Always zero
   */
  function balanceOf(
    address
  ) external returns (uint256 _balance) {
    ++writes;
    _balance = 0;
  }

  /**
   * @notice `policyHook` that writes
   * @return _hook The caller, so `onlyHook` would pass if the call succeeded
   */
  function policyHook() external returns (address _hook) {
    ++writes;
    _hook = msg.sender;
  }
}
