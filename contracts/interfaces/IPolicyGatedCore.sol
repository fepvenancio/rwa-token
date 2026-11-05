// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

/**
 * @title IPolicyGatedCore
 * @notice What every gated template shares, whatever it counts: pause, the policy hook and the registry
 * @dev `IPolicyGated` (fungible templates) and `IGated721` inherit it. Events and errors keep the names and signatures
 *      they had in `IPolicyGated`, so their topics and selectors did not move
 */
interface IPolicyGatedCore {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when the policy hook is replaced
   * @param _oldHook The previous hook; address(0) at initialization
   * @param _newHook The new hook
   */
  event PolicyHookChanged(address indexed _oldHook, address indexed _newHook);

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
   * @notice Thrown when a movement is rejected by the policy hook. The token's own checks keep their own errors: on a
   *         fungible template a frozen amount in the way reverts with `ERC7943InsufficientUnfrozenBalance` and an
   *         amount above the balance with `ERC20InsufficientBalance`; on an ERC-721 a frozen token reverts with the
   *         standard's `ERC7943InsufficientUnfrozenBalance` and ownership and approval with ERC-721's errors
   * @param _reason A reason code from `Reasons`
   */
  error PolicyGated_TransferRejected(bytes32 _reason);

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
   * @notice Replaces the policy hook
   * @dev Only DEFAULT_ADMIN_ROLE (timelock). `_newHook` must be attested as HOOK in the registry and name the token's
   *      registry
   * @param _newHook The new hook
   */
  function setPolicyHook(
    address _newHook
  ) external;

  /**
   * @notice Lifts the pause
   * @dev Only DEFAULT_ADMIN_ROLE (the main timelock) or RECOVERY_ROLE (the recovery timelock, which the guardian
   *      cannot cancel)
   */
  function unpause() external;

  /**
   * @notice The current policy hook
   * @return _hook The hook address
   */
  function policyHook() external view returns (address _hook);

  /**
   * @notice The policy registry, fixed at initialization
   * @return _registry The registry address
   */
  function registry() external view returns (address _registry);
}
