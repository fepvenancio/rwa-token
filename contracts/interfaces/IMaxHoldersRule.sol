// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';

/**
 * @title IMaxHoldersRule
 * @notice Caps the number of holders per token. A holder is any account with balance > 0; zero amounts never add one.
 *         Only movements that add a new holder are checked, net of a sender who leaves, so a lowered cap never blocks
 *         existing holders. FORCED is exempt from the cap but still counted. `cap == 0` fails closed
 *      Exempt accounts (e.g. a 7540 escrow vault, a treasury) never count and never trigger the cap; a seeded count
 *      must exclude them too. `checkReceive` answers for the account as `check` answers for a mint: at or above the cap
 *      an account without tokens cannot receive, so `canReceive` and the vaults' `maxDeposit` say so
 * @dev The count is maintained in `after_` from post-transfer balances. The three seeds are accepted only while the
 *      rule is not in the rule list of the token's current hook (`IComplianceHook.rules()`): `seedHolderCountFromHolders`
 *      proves the count on-chain, `seedHolderCountFromRule` copies it from the instance being replaced, and
 *      `seedHolderCount` takes it as given. With a wrong count, an exit that would take it below zero reverts (fails
 *      closed); a seed, with the rule out of the list, is what corrects the count. Cap, seeds and exemptions are set by the token's
 *      own DEFAULT_ADMIN_ROLE, checked live
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
   * @notice Emitted when an account's exemption changes
   * @param _token The token
   * @param _account The account
   * @param _exempt Whether it is exempt
   */
  event HolderExemptionSet(address indexed _token, address indexed _account, bool _exempt);

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

  /// @notice Thrown when exempting the zero address
  error MaxHoldersRule_ZeroAddress();

  /**
   * @notice Thrown when a seed is attempted while this rule is in the token's rule list
   * @param _token The token
   */
  error MaxHoldersRule_RuleActive(address _token);

  /**
   * @notice Thrown when a holder list is not strictly ascending, which also rejects duplicates and the zero address
   * @param _index The first entry that is not above the one before it (the first is compared with the zero address)
   */
  error MaxHoldersRule_HoldersNotAscending(uint256 _index);

  /**
   * @notice Thrown when the listed balances do not add up to the total supply: an account outside the list holds tokens
   * @param _sum The sum of the listed balances
   * @param _supply The token's total supply
   */
  error MaxHoldersRule_HoldersIncomplete(uint256 _sum, uint256 _supply);

  /**
   * @notice Thrown when the rule to copy from is not in the token's rule list, so its count is not live
   * @param _token The token
   * @param _previousRule The rule given
   */
  error MaxHoldersRule_PreviousRuleNotActive(address _token, address _previousRule);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Overwrites a token's holder count with the number given
   * @dev Only the token's DEFAULT_ADMIN_ROLE, and only while this rule is not in the token's rule list. The number is not
   *      checked: one read off-chain is as old as the proposal that carries it, so prefer `seedHolderCountFromHolders`
   * @param _token The token
   * @param _count The number of non-exempt accounts with balance > 0
   */
  function seedHolderCount(
    address _token,
    uint256 _count
  ) external;

  /**
   * @notice Sets a token's holder count from a list of accounts whose balances add up to the total supply
   * @dev Only the token's DEFAULT_ADMIN_ROLE, and only while this rule is not in the token's rule list. If the listed
   *      balances add up to `totalSupply()`, no account outside the list holds tokens, so the count is exact when the call
   *      executes. Entries with no balance are allowed, so the list may be a superset of the holders. Exempt accounts
   *      that hold tokens must be listed: they are summed but not counted. Exemptions are read as they are when the call
   *      runs, so set them first
   * @param _token The token
   * @param _holders The accounts, in strictly ascending order
   */
  function seedHolderCountFromHolders(
    address _token,
    address[] calldata _holders
  ) external;

  /**
   * @notice Sets a token's holder count by copying it from the rule instance this one replaces
   * @dev Only the token's DEFAULT_ADMIN_ROLE, only while this rule is not in the token's rule list, and only while
   *      `_previousRule` is, so the copied count is live when the call executes. The count is copied as it stands, so it
   *      is exact only if the previous rule's count is and both rules exempt the same accounts that hold tokens.
   *      Exemptions are not copied: set the same ones on this rule first
   * @param _token The token
   * @param _previousRule The instance being replaced
   */
  function seedHolderCountFromRule(
    address _token,
    IMaxHoldersRule _previousRule
  ) external;

  /**
   * @notice Exempts an account from a token's holder count and cap, or lifts the exemption
   * @dev Only the token's DEFAULT_ADMIN_ROLE. If this rule is in the token's rule list and the account holds a balance,
   *      the count follows the change, so exempt accounts never count. If it is not, the count is left alone, so set
   *      exemptions before seeding
   * @param _token The token
   * @param _account The account
   * @param _exempt Whether it is exempt
   */
  function setExemptHolder(
    address _token,
    address _account,
    bool _exempt
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
   * @notice Whether an account is exempt from a token's holder count and cap
   * @param _token The token
   * @param _account The account
   * @return _exempt True if exempt
   */
  function isExemptHolder(
    address _token,
    address _account
  ) external view returns (bool _exempt);

  /**
   * @notice A token's holder count
   * @param _token The token
   * @return _count The number of non-exempt accounts with balance > 0, as tracked
   */
  function holderCount(
    address _token
  ) external view returns (uint256 _count);
}
