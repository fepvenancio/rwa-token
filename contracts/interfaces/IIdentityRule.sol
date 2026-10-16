// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';

/**
 * @title IIdentityRule
 * @notice Requires `from` to be verified, except on MINT and FORCED, and `to` to be verified, except on BURN.
 *         A forced transfer can therefore claw back from a de-verified holder, but only to a verified account
 */
interface IIdentityRule is IComplianceRule {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a constructor argument is the zero address
  error IdentityRule_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The identity registry consulted by the rule
   * @return _identity The registry
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function IDENTITY() external view returns (IIdentityRegistry _identity);
}
