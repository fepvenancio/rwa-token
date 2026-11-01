// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAdapter} from 'interfaces/IAdapter.sol';

/**
 * @title IGuardedAccount
 * @notice A reported adapter that runs only the calls its validators allow, for strategies and custody. It makes plain
 *         calls: no delegatecall, no value, no modules. Each call needs a permission for its target and function, and the
 *         permission's validator must accept the parameters. No validator means refused, so nothing passes by omission
 * @dev It has no role table: it asks its portfolio's vault at call time. It is the most dangerous lego in the stack, and only
 *      a review of each permission set closes that. An `approve` gives the spender up to what it allows
 */
interface IGuardedAccount is IAdapter {
  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice One call
   * @param target The contract to call
   * @param data The calldata
   */
  struct Call {
    address target;
    bytes data;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted for each call made
   * @param _target The contract called
   * @param _selector The function called
   * @param _data The calldata
   */
  event CallMade(address indexed _target, bytes4 indexed _selector, bytes _data);

  /**
   * @notice Emitted when a permission is revoked
   * @param _target The contract
   * @param _selector The function
   */
  event PermissionRevoked(address indexed _target, bytes4 indexed _selector);

  /**
   * @notice Emitted when a permission is set
   * @param _target The contract
   * @param _selector The function
   * @param _validator The validator that judges its parameters
   */
  event PermissionSet(address indexed _target, bytes4 indexed _selector, address indexed _validator);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when a call is refused: it has no permission, or its validator did not accept it
   * @param _target The contract
   * @param _selector The function
   */
  error GuardedAccount_CallRefused(address _target, bytes4 _selector);

  /**
   * @notice Thrown when a permission would name the account's own portfolio or vault, or the account itself
   * @param _target The contract
   */
  error GuardedAccount_ForbiddenTarget(address _target);

  /// @notice Thrown when no risk id is given
  error GuardedAccount_NoRiskId();

  /**
   * @notice Thrown when the validator is not attested as VALIDATOR in the registry the vault names
   * @param _validator The validator
   */
  error GuardedAccount_NotAttested(address _validator);

  /// @notice Thrown when the portfolio does not accept reported adapters
  error GuardedAccount_ReportedNotAccepted();

  /**
   * @notice Thrown when the caller lacks what this needs
   * @param _caller The caller
   */
  error GuardedAccount_Unauthorized(address _caller);

  /// @notice Thrown when an address given is zero
  error GuardedAccount_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Makes calls, atomically
   * @dev The vault's ALLOCATOR_ROLE
   * @param _calls The calls
   */
  function execute(
    Call[] calldata _calls
  ) external;

  /**
   * @notice Removes a permission, at once
   * @dev The vault's DEFAULT_ADMIN_ROLE or GUARDIAN_ROLE
   * @param _target The contract
   * @param _selector The function
   */
  function revokePermission(
    address _target,
    bytes4 _selector
  ) external;

  /**
   * @notice Allows a function of a contract, judged by a validator
   * @dev The vault's DEFAULT_ADMIN_ROLE (the timelock). The validator must be attested. The account's own portfolio and vault,
   *      and the account itself, cannot be named
   * @param _target The contract
   * @param _selector The function
   * @param _validator The validator
   */
  function setPermission(
    address _target,
    bytes4 _selector,
    address _validator
  ) external;

  /*///////////////////////////////////////////////////////////////
                            VIEWS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The validator that judges a function of a contract
   * @param _target The contract
   * @param _selector The function
   * @return _validator The validator; zero means refused
   */
  function validatorOf(
    address _target,
    bytes4 _selector
  ) external view returns (address _validator);

  /**
   * @notice The vault its portfolio serves
   * @return _vault The vault
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function VAULT() external view returns (address _vault);

  /**
   * @notice The risk that is this account's alone
   * @return _riskId The id
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function RISK_ID() external view returns (bytes32 _riskId);

  /**
   * @notice A risk shared with other adapters, for example one custodian
   * @return _riskId The id, or zero for none
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function SHARED_RISK_ID() external view returns (bytes32 _riskId);
}
