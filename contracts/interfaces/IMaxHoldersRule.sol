// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';

/**
 * @title IMaxHoldersRule
 * @notice Caps the number of holders per token. A holder is any account with balance > 0; zero amounts never add one.
 *         Only movements that add a new holder are checked, net of a sender who leaves, so a lowered cap never blocks
 *         existing holders. FORCED is exempt from the cap but still counted. `cap == 0` fails closed
 * @dev The count is maintained in `after_` from post-transfer balances. `seedHolderCount` is only legitimate while
 *      the rule is not in the token's active rule set; the correct value is recomputable from the token's `Transfer`
 *      events. With a wrong count, an exit that would take it below zero reverts (fails closed) until re-seeded.
 *      Cap and seed are set by the token's own DEFAULT_ADMIN_ROLE, checked live
 */
interface IMaxHoldersRule is IComplianceRule {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a token's cap is set
   * @param _token The token
   * @param _oldCap The previous cap
   * @param _newCap The new cap
   */
  event CapSet(address indexed _token, uint256 _oldCap, uint256 _newCap);

  /**
   * @notice Emitted when the admin overwrites a token's holder count
   * @param _token The token
   * @param _oldCount The previous count
   * @param _newCount The seeded count
   */
  event HolderCountSeeded(address indexed _token, uint256 _oldCount, uint256 _newCount);

  /**
   * @notice Emitted when a movement changes a token's holder count
   * @param _token The token
   * @param _count The new count
   */
  event HolderCountUpdated(address indexed _token, uint256 _count);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when the caller does not hold the token's DEFAULT_ADMIN_ROLE
   * @param _token The token
   * @param _caller The unauthorized caller
   */
  error MaxHoldersRule_OnlyTokenAdmin(address _token, address _caller);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Overwrites a token's holder count
   * @dev Only the token's DEFAULT_ADMIN_ROLE. Only legitimate while this rule is not in the token's active rule set
   * @param _token The token
   * @param _count The number of accounts with balance > 0
   */
  function seedHolderCount(
    address _token,
    uint256 _count
  ) external;

  /**
   * @notice Sets a token's holder cap
   * @dev Only the token's DEFAULT_ADMIN_ROLE. 0 rejects every new holder
   * @param _token The token
   * @param _cap The maximum number of holders
   */
  function setCap(
    address _token,
    uint256 _cap
  ) external;

  /**
   * @notice A token's holder cap
   * @param _token The token
   * @return _cap The cap; 0 when not configured
   */
  function capOf(
    address _token
  ) external view returns (uint256 _cap);

  /**
   * @notice A token's holder count
   * @param _token The token
   * @return _count The number of accounts with balance > 0, as tracked
   */
  function holderCount(
    address _token
  ) external view returns (uint256 _count);
}
