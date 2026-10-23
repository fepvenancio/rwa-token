// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

/**
 * @title IFund
 * @notice A fund is a set of share classes. Each class is a policy-gated token or vault with its own balances, hook and
 *         roles. The fund keeps what no single class can know: the list of its classes, how many distinct investors hold
 *         any of them, and which classes each investor holds
 * @dev Classes are numbered from 1 in the order they were registered, and 0 means "not a class". Class `n` owns bit
 *      `n - 1` of an investor's class mask. A class never counts itself as an investor, because a 7540 vault escrows
 *      shares at its own address. Only the installed rule writes investor state, and only for a registered class: the
 *      fund's state is shared by every class, so a token that merely names itself in a movement must not reach it.
 *      The fund does not check which hooks list the installed rule after registration. Changing the rule needs the same
 *      timelock batch to change every class's rule list, or the old rule's `after_` calls revert
 */
interface IFund {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a class is registered
   * @param _token The class token
   * @param _index The class number, from 1
   */
  event ClassRegistered(address indexed _token, uint256 indexed _index);

  /**
   * @notice Emitted when the installed rule changes
   * @param _oldRule The previous rule, or the zero address
   * @param _newRule The new rule
   */
  event RuleSet(address indexed _oldRule, address indexed _newRule);

  /**
   * @notice Emitted when the investor cap changes
   * @param _oldCap The previous cap
   * @param _newCap The new cap
   */
  event HolderCapSet(uint256 _oldCap, uint256 _newCap);

  /**
   * @notice Emitted when an account's exemption changes
   * @param _account The account
   * @param _exempt Whether it is exempt
   */
  event ExemptSet(address indexed _account, bool _exempt);

  /**
   * @notice Emitted when the investor count changes
   * @param _count The new count
   */
  event HolderCountUpdated(uint256 _count);

  /**
   * @notice Emitted whenever the set of classes an account holds changes. Together with the class tokens' own transfer
   *         events this is the register of investors, so no on-chain holder list is kept
   * @param _account The account
   * @param _classes The class bitmask after the change, without the exemption flag
   */
  event HolderClassesUpdated(address indexed _account, uint256 _classes);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a constructor or setter argument is the zero address
  error Fund_ZeroAddress();

  /**
   * @notice Thrown when a rule-only function is called by another account
   * @param _caller The unauthorized caller
   */
  error Fund_OnlyRule(address _caller);

  /**
   * @notice Thrown when a token is not a registered class
   * @param _token The token
   */
  error Fund_NotAClass(address _token);

  /**
   * @notice Thrown when a token is already a registered class
   * @param _token The token
   */
  error Fund_AlreadyRegistered(address _token);

  /**
   * @notice Thrown when registering would exceed `MAX_CLASSES`
   * @param _max The limit
   */
  error Fund_TooManyClasses(uint256 _max);

  /// @notice Thrown when a class is registered before the rule is set
  error Fund_RuleNotSet();

  /**
   * @notice Thrown when a token does not report ERC-165 support for `IPolicyGated`
   * @param _token The token
   */
  error Fund_NotPolicyGated(address _token);

  /**
   * @notice Thrown when the token's current hook does not list the installed rule
   * @param _token The token
   * @param _rule The installed rule
   */
  error Fund_RuleNotListed(address _token, address _rule);

  /**
   * @notice Thrown when a class already has supply: its holders were never recorded, so the count would start wrong
   * @param _token The token
   * @param _supply The token's total supply
   */
  error Fund_ClassHasSupply(address _token, uint256 _supply);

  /**
   * @notice Thrown when a rule is not attested as RULE in the registry
   * @param _rule The rule
   */
  error Fund_NotAttested(address _rule);

  /**
   * @notice Thrown when a class number is outside 1 to `classCount()`
   * @param _index The number given
   */
  error Fund_ClassOutOfRange(uint256 _index);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Registers a share class
   * @dev Only the owner. The token must be new, the fund under `MAX_CLASSES`, the rule set, the token an ERC-165
   *      `IPolicyGated`, its current hook must list the rule, and its total supply must be zero. Registration is
   *      permanent
   * @param _token The class token
   */
  function registerClass(
    address _token
  ) external;

  /**
   * @notice Installs the rule that writes investor state
   * @dev Only the owner. The rule must be attested as RULE in the registry
   * @param _rule The rule
   */
  function setRule(
    address _rule
  ) external;

  /**
   * @notice Sets the investor cap
   * @dev Only the owner. Lowering it below the count blocks new investors until the count falls back
   * @param _cap The cap; 0 admits no new investor
   */
  function setHolderCap(
    uint256 _cap
  ) external;

  /**
   * @notice Exempts an account from the count, or ends its exemption
   * @dev Only the owner. An exempt account never counts and never triggers the cap. For an account that holds a class,
   *      the count follows the change
   * @param _account The account
   * @param _exempt Whether it is exempt
   */
  function setExempt(
    address _account,
    bool _exempt
  ) external;

  /**
   * @notice Records that an account now holds a class
   * @dev Only the installed rule, and only for a registered class. Does nothing for the class itself or when the account
   *      already holds the class
   * @param _token The class token
   * @param _account The account
   */
  function join(
    address _token,
    address _account
  ) external;

  /**
   * @notice Records that an account no longer holds a class
   * @dev Only the installed rule, and only for a registered class. Does nothing for the class itself or when the account
   *      did not hold the class
   * @param _token The class token
   * @param _account The account
   */
  function leave(
    address _token,
    address _account
  ) external;

  /*///////////////////////////////////////////////////////////////
                            VIEWS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The most classes a fund can register; the class mask has a bit for each
   * @return _max The limit
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function MAX_CLASSES() external view returns (uint256 _max);

  /**
   * @notice The registry that must attest the rule
   * @return _registry The registry
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function REGISTRY() external view returns (IPolicyRegistry _registry);

  /**
   * @notice The number of registered classes
   * @return _count The count
   */
  function classCount() external view returns (uint256 _count);

  /**
   * @notice The token of a class
   * @param _index The class number, from 1
   * @return _token The token
   */
  function classAt(
    uint256 _index
  ) external view returns (address _token);

  /**
   * @notice The class number of a token
   * @param _token The token
   * @return _index The class number, from 1, or 0 when the token is not a class
   */
  function classIndexOf(
    address _token
  ) external view returns (uint256 _index);

  /**
   * @notice The number of distinct non-exempt accounts that hold at least one class
   * @return _count The count
   */
  function holderCount() external view returns (uint256 _count);

  /**
   * @notice The investor cap
   * @return _cap The cap
   */
  function holderCap() external view returns (uint256 _cap);

  /**
   * @notice The installed rule
   * @return _rule The rule, or the zero address
   */
  function rule() external view returns (address _rule);

  /**
   * @notice The classes an account holds
   * @param _account The account
   * @return _classes The class bitmask: bit `n - 1` is set when the account holds class `n`
   */
  function heldClasses(
    address _account
  ) external view returns (uint256 _classes);

  /**
   * @notice Whether an account is exempt from the count
   * @param _account The account
   * @return _exempt True if exempt
   */
  function isExempt(
    address _account
  ) external view returns (bool _exempt);

  /**
   * @notice Everything the rule needs to decide on a receiver, in one call
   * @param _token The class token
   * @param _account The receiver
   * @return _index The class number of `_token`, or 0 when it is not a class
   * @return _classes The class bitmask of `_account`
   * @return _exempt Whether `_account` is exempt
   * @return _count The investor count
   * @return _cap The investor cap
   */
  function admission(
    address _token,
    address _account
  ) external view returns (uint256 _index, uint256 _classes, bool _exempt, uint256 _count, uint256 _cap);

  /**
   * @notice An account's balance in each class it holds
   * @dev Loops over at most `MAX_CLASSES` classes and calls each class token, so read it off-chain
   * @param _account The account
   * @return _tokens The class tokens the account holds
   * @return _balances The balance in each, in the same order
   */
  function positionsOf(
    address _account
  ) external view returns (address[] memory _tokens, uint256[] memory _balances);
}
