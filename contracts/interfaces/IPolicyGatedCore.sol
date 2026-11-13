// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC8473} from 'interfaces/IERC8473.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

/**
 * @title IPolicyGatedCore
 * @notice What every gated template shares, whatever it counts: pause, the ERC-8473 policy and the registry
 * @dev `IPolicyGated` (fungible templates) and `IGated721` inherit it. `policy()`, `PolicyChanged` and
 *      `ERC8473PolicyRejected` come from `IERC8473`
 */
interface IPolicyGatedCore is IERC8473 {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when installing a hook or implementation that is not attested for the required kind
   * @param _target The component
   * @param _kind The required kind
   */
  error PolicyGated_NotAttested(address _target, IPolicyRegistry.AttestKind _kind);

  /**
   * @notice Thrown when installing a hook that vets rules against a different registry than the token's own
   * @param _hookRegistry The registry the hook names
   * @param _tokenRegistry The token's registry
   */
  error PolicyGated_HookRegistryMismatch(address _hookRegistry, address _tokenRegistry);

  /**
   * @notice Thrown when installing a policy that does not answer ERC-8473's policy interface id through ERC-165
   * @param _target The contract
   */
  error PolicyGated_NotAPolicy(address _target);

  /// @notice Thrown when a required address argument is the zero address
  error PolicyGated_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Pauses every movement except forced transfers
   * @dev Only GUARDIAN_ROLE, with no delay
   */
  function pause() external;

  /**
   * @notice Installs a policy: the first one, a replacement, or the current one again
   * @dev Only DEFAULT_ADMIN_ROLE (timelock). `_newPolicy` must be attested as HOOK in the registry, name the token's
   *      registry and answer ERC-8473's policy interface id. The token sets it, emits `PolicyChanged`, then calls its
   *      `onInstall` with the previous policy and `_data`; if that reverts, the installation reverts
   * @param _newPolicy The new policy
   * @param _data Passed to the policy's `onInstall` unchanged. For `ComplianceHook` it is `abi.encode` of the token's
   *        ordered rule list, or empty to keep the list the hook already holds for the token
   */
  function installPolicy(
    address _newPolicy,
    bytes calldata _data
  ) external;

  /**
   * @notice Lifts the pause
   * @dev Only DEFAULT_ADMIN_ROLE (the main timelock) or RECOVERY_ROLE (the recovery timelock, which the guardian
   *      cannot cancel)
   */
  function unpause() external;

  /**
   * @notice The policy registry, fixed at initialization
   * @return _registry The registry address
   */
  function registry() external view returns (address _registry);
}
