// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC7943Fungible} from 'interfaces/IERC7943Fungible.sol';
import {IPolicyGatedCore} from 'interfaces/IPolicyGatedCore.sol';

/**
 * @title IPolicyGated
 * @notice Enforcement core and integrator read path shared by every fungible gated template. Every balance movement (transfer,
 *         executed intent, forced transfer, mint, burn) is decided by an external policy hook
 * @dev Inherits the ERC-7943 Final fungible interface, whose id the token advertises: `forcedTransfer`,
 *      `setFrozenTokens`, `getFrozenTokens`, `canSend`, `canReceive` and the boolean `canTransfer` are declared there.
 *      Pause, the hook pointer and the registry are in `IPolicyGatedCore`, which every gated template shares. This
 *      interface holds what is left that the standard does not cover: issuance and the reasoned pre-flight
 */
interface IPolicyGated is IERC7943Fungible, IPolicyGatedCore {
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
   * @notice Pre-flight for a plain transfer by `_from`, a mint (`_from` == 0) or a burn (`_to` == 0), with the reason
   * @dev Runs the same mechanical checks and hook call as the state-changing path, minus the write. The operator in
   *      the context is `_from`, or the caller for a mint. It models holder-driven movements only: a burn
   *      (`_to` == 0) is simulated as a holder or vault burn, so frozen tokens count against `_amount` unless `_from` holds
   *      BURNER_ROLE. The enforcement paths differ: `burn` and `forcedTransfer` release frozen tokens first, and `forcedTransfer` also bypasses pause.
   *      Every shortfall counts here, an amount above the balance included. The boolean `canTransfer` is this function's
   *      first value except for a balance shortfall with no frozen amount in the way, which it leaves to the base standard
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
}
