// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC7943NonFungible} from 'interfaces/IERC7943NonFungible.sol';
import {IPolicyGatedCore} from 'interfaces/IPolicyGatedCore.sol';

/**
 * @title IGated721
 * @notice A policy-gated ERC-721: every movement of a token (transfer, forced transfer, mint, burn) is decided by the
 *         same external policy hook as the fungible templates, with `id` set to the token and `amount` to one
 * @dev Inherits the ERC-7943 Final non-fungible interface and the core every gated template shares. This interface
 *      holds what neither covers: issuance, metadata and the reasoned pre-flight
 */
interface IGated721 is IERC7943NonFungible, IPolicyGatedCore {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted with the standard's `ForcedTransfer` when an agent forces a transfer, so the agent is not lost. It
   *         has the signature and topic of the fungible templates' event
   * @param _from The account the token was taken from
   * @param _to The account the token was sent to
   * @param _tokenId The token moved
   * @param _agent The AGENT_ROLE account that forced the transfer
   */
  event ForcedTransferBy(address indexed _from, address indexed _to, uint256 _tokenId, address indexed _agent);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Mints a token with its metadata URI
   * @dev Only MINTER_ROLE. No receiver callback. The hook decides, with `from` == address(0)
   * @param _to The receiver
   * @param _tokenId The new token; reverts with ERC-721's `ERC721InvalidSender` if it exists
   * @param _uri The token's metadata URI
   */
  function mint(
    address _to,
    uint256 _tokenId,
    string calldata _uri
  ) external;

  /**
   * @notice Burns a token
   * @dev Only BURNER_ROLE. An enforcement action: no approval is needed, a frozen token can be burned, which clears its
   *      freeze, and the pause does not stop it. The policy still decides, and sees a FORCED movement with `from` set
   *      and `to` == address(0)
   * @param _tokenId The token
   */
  function burn(
    uint256 _tokenId
  ) external;

  /**
   * @notice Replaces the metadata URI of a token
   * @dev Only AGENT_ROLE. Emits ERC-4906's `MetadataUpdate`
   * @param _tokenId The token; must exist
   * @param _uri The new URI
   */
  function setTokenURI(
    uint256 _tokenId,
    string calldata _uri
  ) external;

  /**
   * @notice Pre-flight for a plain transfer by `_from`, a mint (`_from` == 0) or a burn (`_to` == 0), with the reason
   * @dev Runs the same checks and policy call as the state-changing path, minus the write. The operator in the context
   *      is `_from`, which is zero for a mint, so the answer does not depend on who asks. It models TRANSFER, MINT and
   *      BURN only. This template has no holder's burn: `burn` is the burner's enforcement action, a FORCED movement,
   *      which no pre-flight predicts, so a burn asked about here is answered as a holder's would be, and a frozen token
   *      or a lockup stops it although it does not stop `burn`. Unlike `canTransfer`, ownership counts:
   *      `NOT_TOKEN_OWNER` when `_from` is not the token's owner, which for a mint means the token exists. Approval is
   *      not judged
   * @param _from The sender, or address(0) for a mint
   * @param _to The receiver, or address(0) for a burn
   * @param _tokenId The token
   * @return _ok True if the movement would succeed
   * @return _reason The reason code; `Reasons.TRANSFER_OK` when `_ok`
   */
  function canTransferWithReason(
    address _from,
    address _to,
    uint256 _tokenId
  ) external view returns (bool _ok, bytes32 _reason);
}
