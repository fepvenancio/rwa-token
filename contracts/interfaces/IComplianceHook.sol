// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

/**
 * @title IComplianceHook
 * @notice Policy hook bound to one token that dispatches to an ordered list of attested rules; first rejection wins.
 *         An empty rule set rejects every movement
 * @dev Admin, registry and token are immutable, so they are part of the attested codehash
 */
interface IComplianceHook is IPolicyHook {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when the ordered rule set is replaced
   * @param _ruleIds The new rule ids, in evaluation order
   */
  event RuleSetChanged(bytes32[] _ruleIds);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when a rule set contains two rules of the same type: the same contract twice, or two contracts with
   *         the same `ruleId`. One instance of each rule type per hook
   * @param _rule The later of the two rules
   */
  error ComplianceHook_DuplicateRule(address _rule);

  /**
   * @notice Thrown when a rule is not attested as RULE in the registry
   * @param _rule The rule
   */
  error ComplianceHook_NotAttested(address _rule);

  /**
   * @notice Thrown when a caller other than the admin changes the rule set
   * @param _caller The unauthorized caller
   */
  error ComplianceHook_OnlyAdmin(address _caller);

  /**
   * @notice Thrown when a caller other than the bound token calls `afterTransfer`
   * @param _caller The unauthorized caller
   */
  error ComplianceHook_OnlyToken(address _caller);

  /**
   * @notice Thrown when a rule set exceeds `MAX_RULES`
   * @param _count The rule set size
   */
  error ComplianceHook_TooManyRules(uint256 _count);

  /// @notice Thrown when a constructor argument is the zero address
  error ComplianceHook_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Atomically replaces the ordered rule set
   * @dev Only `ADMIN`. Every rule must be attested as RULE; no duplicates; at most `MAX_RULES`. An empty set makes the
   *      hook reject every movement
   * @param _newRules The new rules, in evaluation order
   */
  function setRules(
    IComplianceRule[] calldata _newRules
  ) external;

  /**
   * @notice The account allowed to change the rule set (the timelock)
   * @return _admin The admin
   */
  // getter of an UPPER_SNAKE constant/immutable
  // solhint-disable-next-line style-guide-casing
  function ADMIN() external view returns (address _admin);

  /**
   * @notice The hard cap on the number of rules
   * @return _maxRules The cap
   */
  // getter of an UPPER_SNAKE constant/immutable
  // solhint-disable-next-line style-guide-casing
  function MAX_RULES() external view returns (uint256 _maxRules);

  /**
   * @notice The registry used to vet rules
   * @return _registry The registry
   */
  // getter of an UPPER_SNAKE constant/immutable
  // solhint-disable-next-line style-guide-casing
  function REGISTRY() external view returns (IPolicyRegistry _registry);

  /**
   * @notice The token this hook serves; the only caller allowed in `afterTransfer`
   * @return _token The token
   */
  // getter of an UPPER_SNAKE constant/immutable
  // solhint-disable-next-line style-guide-casing
  function TOKEN() external view returns (address _token);

  /**
   * @notice The number of installed rules
   * @return _count The count
   */
  function ruleCount() external view returns (uint256 _count);

  /**
   * @notice The installed rules, in evaluation order
   * @return _rules The rules
   */
  function rules() external view returns (IComplianceRule[] memory _rules);
}
