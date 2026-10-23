// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IFund} from 'interfaces/IFund.sol';

/**
 * @title IFundHoldersRule
 * @notice Caps the number of distinct investors across all classes of one fund. An investor is any non-exempt account
 *         that holds at least one class, and counts once however many classes it holds. The state lives in the fund, so
 *         a replaced rule keeps the count
 * @dev A token that is not a registered class of the fund is rejected with `Reasons.NOT_FUND_CLASS` on every movement,
 *      so a class is unusable until it is registered. So is every class of a rule that is no longer the fund's
 *      installed one, so a retired rule never says yes in a pre-flight while the write fails. Only a new investor is
 *      checked, net of a sender who leaves the fund, so a lowered cap never blocks existing investors. FORCED is exempt
 *      from the cap but still counted. A cap of 0 fails closed. The class itself and exempt accounts never count
 */
interface IFundHoldersRule is IComplianceRule {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when the constructor argument is the zero address
  error FundHoldersRule_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The fund whose state the rule reads and writes
   * @return _fund The fund
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function FUND() external view returns (IFund _fund);
}
