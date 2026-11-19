// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC7943MultiToken} from 'interfaces/IERC7943MultiToken.sol';
import {IPolicyGatedCore} from 'interfaces/IPolicyGatedCore.sol';

/**
 * @title IGated1155
 * @notice A policy-gated ERC-1155: every movement of an amount of a token id (transfer, forced transfer, mint, burn) is
 *         decided by the same external policy hook as the other templates, with `tokenId` set to the id and `amount`
 *         to the amount. A batch is its items in order, each one a movement of its own
 * @dev Inherits the ERC-7943 Final multi-token interface and the core every gated template shares. This interface
 *      holds what neither covers: issuance, metadata, the collection's name and symbol and the reasoned pre-flight.
 *      One policy judges every id alike: the account-level answers of both standards take no token id
 */
interface IGated1155 is IERC7943MultiToken, IPolicyGatedCore {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted with the standard's `ForcedTransfer` when an agent forces a transfer, so the agent is not lost
   * @param _from The account the tokens were taken from
   * @param _to The account the tokens were sent to
   * @param _tokenId The token id moved
   * @param _amount The amount moved
   * @param _agent The AGENT_ROLE account that forced the transfer
   */
  event ForcedTransferBy(
    address indexed _from, address indexed _to, uint256 _tokenId, uint256 _amount, address indexed _agent
  );

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Mints an amount of a token id
   * @dev Only MINTER_ROLE. The hook decides, with `from` == address(0). A receiver that is a contract gets ERC-1155's
   *      `onERC1155Received` after the mint, and one that does not accept it reverts the mint
   * @param _to The receiver
   * @param _tokenId The token id
   * @param _amount The amount
   */
  function mint(
    address _to,
    uint256 _tokenId,
    uint256 _amount
  ) external;

  /**
   * @notice Burns an amount of a token id from an account
   * @dev Only BURNER_ROLE. An enforcement action: no approval is needed, frozen tokens are taken as needed, which
   *      lowers the frozen amount by the part taken, and the pause does not stop it. The policy still decides, and sees
   *      a FORCED movement with `from` set and `to` == address(0)
   * @param _from The holder
   * @param _tokenId The token id
   * @param _amount The amount
   */
  function burn(
    address _from,
    uint256 _tokenId,
    uint256 _amount
  ) external;

  /**
   * @notice Replaces the metadata URI of a token id
   * @dev Only AGENT_ROLE. Emits ERC-1155's `URI`. The URI is public and describes the id, never a holder
   * @param _tokenId The token id
   * @param _uri The new URI
   */
  function setURI(
    uint256 _tokenId,
    string calldata _uri
  ) external;

  /**
   * @notice The collection's name, set at initialisation
   * @return _name The name
   */
  function name() external view returns (string memory _name);

  /**
   * @notice The collection's symbol, set at initialisation
   * @return _symbol The symbol
   */
  function symbol() external view returns (string memory _symbol);

  /**
   * @notice Pre-flight for a plain transfer by `_from`, a mint (`_from` == 0) or a burn (`_to` == 0) of one token id,
   *         with the reason
   * @dev Runs the same checks and policy call as the state-changing path for one item, minus the write. The operator
   *      in the context is `_from`, which is zero for a mint, so the answer does not depend on who asks. It models
   *      TRANSFER, MINT and BURN only. This template has no holder's burn: `burn` is the burner's enforcement action, a
   *      FORCED movement, which no pre-flight predicts, so a burn asked about here is answered as a holder's would be.
   *      Unlike `canTransfer`, the balance counts: `INSUFFICIENT_UNFROZEN` for any amount above the unfrozen balance.
   *      Approval and the receiver callback are not judged. For a batch, ask about each item: when an id is named
   *      twice, the later answers depend on the earlier moves
   * @param _from The sender, or address(0) for a mint
   * @param _to The receiver, or address(0) for a burn
   * @param _tokenId The token id
   * @param _amount The amount
   * @return _ok True if the movement would pass
   * @return _reason The reason code; `Reasons.TRANSFER_OK` when `_ok`
   */
  function canTransferWithReason(
    address _from,
    address _to,
    uint256 _tokenId,
    uint256 _amount
  ) external view returns (bool _ok, bytes32 _reason);
}
