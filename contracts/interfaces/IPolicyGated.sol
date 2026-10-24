// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC7943Fungible} from 'interfaces/IERC7943Fungible.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

/**
 * @title IPolicyGated
 * @notice Enforcement core and integrator read path shared by every gated template. Every balance movement (transfer,
 *         executed intent, forced transfer, mint, burn) is decided by an external policy hook
 * @dev Inherits the ERC-7943 Final fungible interface, whose id the token advertises: `forcedTransfer`,
 *      `setFrozenTokens`, `getFrozenTokens`, `canSend`, `canReceive` and the boolean `canTransfer` are declared there.
 *      This interface holds what the standard does not cover: issuance, pause, the hook pointer, and the reasoned
 *      pre-flight
 */
interface IPolicyGated is IERC7943Fungible {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted with the standard's `ForcedTransfer` when an agent forces a transfer, so the agent is not lost
   * @param _from The account the tokens were taken from
   * @param _to The account the tokens were sent to
   * @param _amount The amount moved
   * @param _agent The AGENT_ROLE account that forced the transfer
   */
  event ForcedTransferBy(address indexed _from, address indexed _to, uint256 _amount, address indexed _agent);

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
   * @notice Thrown when a balance movement is rejected by the policy hook. An amount above the unfrozen balance reverts
   *         with `ERC7943InsufficientUnfrozenBalance` instead
   * @param _reason A reason code from `Reasons`
   */
  error PolicyGated_TransferRejected(bytes32 _reason);

  /// @notice Thrown when a required address argument is the zero address
  error PolicyGated_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Burns tokens from an account
   * @dev Only BURNER_ROLE. An enforcement action: no allowance is needed and frozen tokens can be burned, lowering the
   *      frozen amount by the part of `_amount` that was frozen. The hook still decides, with `from` set and `to` ==
   *      address(0)
   * @param _from The account to burn from
   * @param _amount The amount to burn
   */
  function burn(
    address _from,
    uint256 _amount
  ) external;

  /**
   * @notice Mints tokens to an account
   * @dev Only MINTER_ROLE. The hook decides, with `from` == address(0)
   * @param _to The receiver
   * @param _amount The amount to mint
   */
  function mint(
    address _to,
    uint256 _amount
  ) external;

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
   * @notice Pre-flight for a plain transfer by `_from`, a mint (`_from` == 0) or a burn (`_to` == 0), with the reason
   * @dev Runs the same mechanical checks and hook call as the state-changing path, minus the write. The operator in
   *      the context is `_from`, or the caller for a mint. It models holder-driven movements only: a burn
   *      (`_to` == 0) is simulated as a holder or vault burn, so frozen tokens count against `_amount`. The enforcement
   *      paths differ: `burn` and `forcedTransfer` release frozen tokens first, and `forcedTransfer` also bypasses pause.
   *      The boolean `canTransfer` is this function's first value
   * @param _from The sender, or address(0) for a mint
   * @param _to The receiver, or address(0) for a burn
   * @param _amount The amount
   * @return _ok True if the movement would succeed
   * @return _reason The reason code; `Reasons.TRANSFER_OK` when `_ok`
   */
  function canTransferWithReason(
    address _from,
    address _to,
    uint256 _amount
  ) external view returns (bool _ok, bytes32 _reason);

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
