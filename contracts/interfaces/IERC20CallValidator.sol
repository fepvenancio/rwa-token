// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ICallValidator} from 'interfaces/ICallValidator.sol';

/**
 * @title IERC20CallValidator
 * @notice Allows `transfer` to exactly one address, or `approve` of exactly one spender, up to one amount per call, and
 *         nothing else. A custodian is a `GuardedAccount` with one permission: the asset's `transfer`, with this validator
 *         naming the custodian
 */
interface IERC20CallValidator is ICallValidator {
  /// @notice Thrown when the address it names is zero
  error ERC20CallValidator_ZeroAddress();

  /**
   * @notice The one address allowed
   * @return _who The address
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function WHO() external view returns (address _who);

  /**
   * @notice The most one call may name
   * @return _max The amount
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function MAX_PER_CALL() external view returns (uint256 _max);
}
