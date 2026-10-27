// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

/**
 * @title IComplianceHook
 * @notice Policy hook shared by every token of a deployment. Each token has its own ordered list of attested rules and
 *         its own after mask; the first rejection wins, and a token with no rules rejects every movement
 * @dev The registry is the only immutable, so one attestation of the hook's codehash serves every token. A token's rules
 *      are set by that token's own DEFAULT_ADMIN_ROLE, checked live as the rules do for their own configuration, or by
 *      the token itself, so that its initialiser can install the hook and the initial rules in one call
 */
interface IComplianceHook is IPolicyHook {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a token's ordered rule set is replaced
   * @param _token The token
   * @param _ruleIds The new rule ids, in evaluation order
   */
  event RuleSetChanged(address indexed _token, bytes32[] _ruleIds);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when a rule set contains two rules of the same type: the same contract twice, or two contracts with
   *         the same `ruleId`. One instance of each rule type per token
   * @param _rule The later of the two rules
   */
  error ComplianceHook_DuplicateRule(address _rule);

  /**
   * @notice Thrown when a rule is not attested as RULE in the registry
   * @param _rule The rule
   */
  error ComplianceHook_NotAttested(address _rule);

  /**
   * @notice Thrown when a caller that is neither the token nor holds the token's DEFAULT_ADMIN_ROLE changes its rule set
   * @param _token The token whose rules were to change
   * @param _caller The unauthorized caller
   */
  error ComplianceHook_NotTokenAdmin(address _token, address _caller);

  /**
   * @notice Thrown when `afterTransfer` is called by an account other than the token named in the context
   * @param _caller The unauthorized caller
   */
  error ComplianceHook_OnlyToken(address _caller);

  /**
   * @notice Thrown when a rule set exceeds `MAX_RULES`
   * @param _count The rule set size
   */
  error ComplianceHook_TooManyRules(uint256 _count);

  /// @notice Thrown when the registry given to the constructor is the zero address
  error ComplianceHook_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Atomically replaces a token's ordered rule set
   * @dev Only the token's DEFAULT_ADMIN_ROLE (asked live) or the token itself. Every rule must be attested as RULE; no
   *      duplicates; at most `MAX_RULES` per token. An empty set makes the hook reject every movement of the token
   * @param _token The token
   * @param _newRules The new rules, in evaluation order
   */
  function setRules(
    address _token,
    IComplianceRule[] calldata _newRules
  ) external;

  /**
   * @notice The hard cap on the number of rules of one token
   * @return _maxRules The cap
   */
  // getter of an UPPER_SNAKE constant/immutable
  // solhint-disable-next-line style-guide-casing
  function MAX_RULES() external view returns (uint256 _maxRules);

  /**
   * @notice The registry used to vet rules, and the one every token using this hook must name as its own
   * @return _registry The registry
   */
  // getter of an UPPER_SNAKE constant/immutable
  // solhint-disable-next-line style-guide-casing
  function REGISTRY() external view returns (IPolicyRegistry _registry);

  /**
   * @notice The number of rules installed for a token
   * @param _token The token
   * @return _count The count
   */
  function ruleCount(
    address _token
  ) external view returns (uint256 _count);

  /**
   * @notice The rules installed for a token, in evaluation order
   * @param _token The token
   * @return _rules The rules
   */
  function rules(
    address _token
  ) external view returns (IComplianceRule[] memory _rules);
}
