// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {ICredentialRegistry} from 'interfaces/ICredentialRegistry.sol';

/**
 * @title ICredentialRule
 * @notice Applies a per-token policy to the records of an `ICredentialRegistry`. The sender of a movement needs only a
 *         standing that lets it leave (`ACTIVE`, `EXIT_ONLY` or `LAPSED`). The receiver needs an `ACTIVE` record from a
 *         trusted attester whose qualification bits satisfy the token's policy
 * @dev Which leg is checked, by kind: TRANSFER and EXECUTED check both; MINT and FORCED check the receiver only; BURN
 *      checks the sender only, and a BURN whose operator holds the token's BURNER_ROLE (enforcement) checks nothing.
 *      Zero amounts are checked like any other. The rule keeps no running state and no `after_`; the registry is the
 *      state. Policy is keyed by token and set by the token's own DEFAULT_ADMIN_ROLE, checked live
 */
interface ICredentialRule is IComplianceRule {
  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice What a token accepts from a receiver
   * @param requireAll Every one of these bits must be present
   * @param requireAny At least one of these bits must be present; zero ignores the test
   * @param forbidAny None of these bits may be present
   * @param attesters Bitmap of the attester ids the token trusts, bit `i` for id `i`. Zero means the token has no
   *        policy, which admits nobody
   */
  struct Policy {
    uint32 requireAll;
    uint32 requireAny;
    uint32 forbidAny;
    uint64 attesters;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a token's policy is set
   * @param _token The token
   * @param _requireAll Bits every receiver must have
   * @param _requireAny Bits of which a receiver must have at least one; zero ignores the test
   * @param _forbidAny Bits no receiver may have
   * @param _attesters Bitmap of trusted attester ids
   */
  event PolicySet(address indexed _token, uint32 _requireAll, uint32 _requireAny, uint32 _forbidAny, uint64 _attesters);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when the caller does not hold the token's DEFAULT_ADMIN_ROLE
   * @param _token The token
   * @param _caller The unauthorized caller
   */
  error CredentialRule_OnlyTokenAdmin(address _token, address _caller);

  /// @notice Thrown when a constructor argument is the zero address
  error CredentialRule_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Sets a token's policy
   * @dev Only the token's DEFAULT_ADMIN_ROLE. Replaces the whole policy. `_attesters == 0` removes the policy: the
   *      token then admits no receiver, so every movement but a burn is refused; holders can still leave through a burn
   * @param _token The token
   * @param _requireAll Bits every receiver must have
   * @param _requireAny Bits of which a receiver must have at least one; zero ignores the test
   * @param _forbidAny Bits no receiver may have
   * @param _attesters Bitmap of trusted attester ids
   */
  function setPolicy(
    address _token,
    uint32 _requireAll,
    uint32 _requireAny,
    uint32 _forbidAny,
    uint64 _attesters
  ) external;

  /**
   * @notice A token's policy
   * @param _token The token
   * @return _policy The policy; all zero when unset
   */
  function policyOf(
    address _token
  ) external view returns (Policy memory _policy);

  /**
   * @notice The registry the rule reads
   * @return _registry The registry
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function REGISTRY() external view returns (ICredentialRegistry _registry);
}
