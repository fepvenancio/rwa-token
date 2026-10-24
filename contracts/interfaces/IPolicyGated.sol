// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

/**
 * @title IPolicyGated
 * @notice Enforcement core and integrator read path shared by every gated template. Every balance movement (transfer,
 *         executed intent, forced transfer, mint, burn) is decided by an external policy hook
 * @dev Function names follow the project brief. The token does not claim the ERC-7943 interface id, whose names and
 *      return types differ
 */
interface IPolicyGated {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when an agent forces a transfer
   * @param _from The account the tokens were taken from
   * @param _to The account the tokens were sent to
   * @param _amount The amount moved
   * @param _agent The AGENT_ROLE account that forced the transfer
   */
  event ForcedTransfer(address indexed _from, address indexed _to, uint256 _amount, address indexed _agent);

  /**
   * @notice Emitted when an account's frozen amount changes, including when an enforcement action releases it
   * @param _user The account
   * @param _amount The new absolute frozen amount
   */
  event Frozen(address indexed _user, uint256 _amount);

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
   * @notice Thrown when freezing more than an account holds
   * @param _user The account
   * @param _amount The requested frozen amount
   * @param _balance The account's balance
   */
  error PolicyGated_FrozenExceedsBalance(address _user, uint256 _amount, uint256 _balance);

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
   * @notice Thrown when a balance movement is rejected by the token's mechanical checks or by the policy hook
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
   * @dev Only BURNER_ROLE. An enforcement action: no allowance is needed and frozen tokens can be burned, releasing
   *      the frozen amount as needed. The hook still decides, with `from` set and `to` == address(0)
   * @param _from The account to burn from
   * @param _amount The amount to burn
   */
  function burn(
    address _from,
    uint256 _amount
  ) external;

  /**
   * @notice Moves tokens between accounts without the holder's consent (clawback / recovery)
   * @dev Only AGENT_ROLE. Bypasses pause and frozen balance, releasing the frozen amount as needed. The hook still
   *      decides, with kind FORCED
   * @param _from The account the tokens are taken from
   * @param _to The account the tokens are sent to
   * @param _amount The amount to move
   */
  function forcedTransfer(
    address _from,
    address _to,
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
   * @notice Sets the absolute frozen amount for an account
   * @dev Only AGENT_ROLE. The amount must not exceed the account's balance
   * @param _user The account
   * @param _amount The new frozen amount
   */
  function setFrozen(
    address _user,
    uint256 _amount
  ) external;

  /**
   * @notice Replaces the policy hook
   * @dev Only DEFAULT_ADMIN_ROLE (timelock). `_newHook` must be attested as HOOK in the registry
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
   * @notice Pre-flight for a plain transfer by `_from`, a mint (`_from` == 0) or a burn (`_to` == 0)
   * @dev Runs the same mechanical checks and hook call as the state-changing path, minus the write. The operator in
   *      the context is `_from`, or the caller for a mint. It models holder-driven movements only: a burn
   *      (`_to` == 0) is simulated as a holder or vault burn, so frozen tokens count against `_amount`. The enforcement
   *      paths differ: `burn` and `forcedTransfer` release frozen tokens first, and `forcedTransfer` also bypasses pause
   * @param _from The sender, or address(0) for a mint
   * @param _to The receiver, or address(0) for a burn
   * @param _amount The amount
   * @return _ok True if the movement would succeed
   * @return _reason The reason code; `Reasons.TRANSFER_OK` when `_ok`
   */
  function canTransfer(
    address _from,
    address _to,
    uint256 _amount
  ) external view returns (bool _ok, bytes32 _reason);

  /**
   * @notice The frozen amount of an account
   * @param _user The account
   * @return _amount The frozen amount
   */
  function getFrozen(
    address _user
  ) external view returns (uint256 _amount);

  /**
   * @notice Whether the policy hook would accept `_user` as a mint receiver; an identity-style check
   * @dev Ignores pause and frozen balance
   * @param _user The account
   * @return _allowed True if accepted
   */
  function isUserAllowed(
    address _user
  ) external view returns (bool _allowed);

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
