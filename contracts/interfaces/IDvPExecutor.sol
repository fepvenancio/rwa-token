// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

/**
 * @title IDvPExecutor
 * @notice Settles a trade of a gated security against cash in one transaction: both legs move or neither does. The
 *         executor builds nothing itself. Each party signs what it gives and what it is to receive, and the executor
 *         checks that the two signed statements mirror each other, then executes both
 * @dev Two cash forms: a gated cash token (a second `ITransferIntent` token, signed by the buyer) and an ERC-3009 token
 *      (an authorization signed by the buyer). There is no entry point that runs one leg alone. An intent that names this
 *      executor and states a consideration can be run by no other executor: the token rejects it
 */
interface IDvPExecutor {
  /*///////////////////////////////////////////////////////////////
                            ENUMS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The two legs of a trade
   * @param CASH The payment leg
   * @param SECURITIES The delivery leg
   */
  enum Leg {
    CASH,
    SECURITIES
  }

  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice An ERC-3009 `receiveWithAuthorization`, signed by the buyer. Its payee is always this executor
   * @param from The buyer, who pays
   * @param value The cash amount
   * @param validAfter The time after which the authorization is valid, exclusive
   * @param validBefore The time before which the authorization is valid, exclusive
   * @param nonce Must equal `keccak256(abi.encode(securityToken, securityToken.intentHash(securitiesIntent)))`, which ties
   *        the authorization to one securities intent on one token
   * @param signature The buyer's signature
   */
  struct Authorization {
    address from;
    uint256 value;
    uint256 validAfter;
    uint256 validBefore;
    bytes32 nonce;
    bytes signature;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a trade settles
   * @param _securitiesIntentHash The EIP-712 digest of the seller's intent
   * @param _seller The seller
   * @param _buyer The buyer
   * @param _securityToken The security token
   * @param _cashToken The cash token
   * @param _securityAmount The amount of security tokens delivered
   * @param _cashAmount The amount of cash paid
   * @param _operator The OPERATOR_ROLE account that submitted it
   */
  event DvPSettled(
    bytes32 indexed _securitiesIntentHash,
    address indexed _seller,
    address indexed _buyer,
    address _securityToken,
    address _cashToken,
    uint256 _securityAmount,
    uint256 _cashAmount,
    address _operator
  );

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a constructor argument is the zero address
  error DvPExecutor_ZeroAddress();

  /// @notice Thrown when the two legs do not describe the same trade: parties, amounts, tokens or nonce disagree
  error DvPExecutor_LegsDoNotMatch();

  /**
   * @notice Thrown when a leg fails; the whole trade reverts. For the ERC-3009 form the legs are the pull of the cash
   *         and the securities leg; a failing payout to the seller reverts with the cash token's own error
   * @param _leg The failing leg. The cash leg runs first, so a trade whose both legs fail reports the cash leg
   * @param _reason The token's revert data, e.g. `IPolicyGated.PolicyGated_TransferRejected(reason)`
   */
  error DvPExecutor_LegFailed(Leg _leg, bytes _reason);

  /**
   * @notice Thrown when a cash balance is not what the settlement must leave: the executor ends with the balance it
   *         started with, and the payout raises the seller's balance by exactly the cash amount. A fee-on-transfer cash
   *         token makes the trade revert: usually in the payout, with the cash token's own error, and with this error
   *         when a stray balance covers the shortfall or the fee falls on the payout alone
   * @param _account The executor or the seller
   * @param _expected The balance the account must have after settlement
   * @param _actual The balance it has
   */
  error DvPExecutor_CashNotConserved(address _account, uint256 _expected, uint256 _actual);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Settles a trade whose cash is a gated token
   * @dev Only OPERATOR_ROLE, only while not paused. The legs must mirror: the parties are swapped, each amount equals the
   *      other leg's stated consideration, each stated consideration token is the other leg's token, and the tokens
   *      differ. The cash leg runs first, then the securities leg; either failing reverts both. The executor does not
   *      compare the `executor` fields: each token does, and a stated consideration forces a named executor
   * @param _securityToken The security token, which must have granted this executor EXECUTOR_ROLE
   * @param _cashToken The cash token, which must have granted this executor EXECUTOR_ROLE
   * @param _securitiesIntent The seller's signed intent
   * @param _securitiesSig The seller's signature
   * @param _cashIntent The buyer's signed intent
   * @param _cashSig The buyer's signature
   * @return _securitiesIntentHash The EIP-712 digest of the seller's intent
   */
  function executeDvPGated(
    address _securityToken,
    address _cashToken,
    ITransferIntent.TransferIntent calldata _securitiesIntent,
    bytes calldata _securitiesSig,
    ITransferIntent.TransferIntent calldata _cashIntent,
    bytes calldata _cashSig
  ) external returns (bytes32 _securitiesIntentHash);

  /**
   * @notice Settles a trade whose cash is an ERC-3009 token
   * @dev Only OPERATOR_ROLE, only while not paused. The authorization must be from the seller's receiver, for the seller's
   *      stated consideration in the stated cash token, with the nonce described in `Authorization`. The executor pulls
   *      the cash, executes the securities leg, pays the seller and requires that it ends with the balance it started
   *      with and that the payout raised the seller's balance by exactly the cash amount
   * @param _securityToken The security token, which must have granted this executor EXECUTOR_ROLE
   * @param _cashToken The ERC-3009 cash token
   * @param _securitiesIntent The seller's signed intent
   * @param _securitiesSig The seller's signature
   * @param _authorization The buyer's signed authorization, payable to this executor
   * @return _securitiesIntentHash The EIP-712 digest of the seller's intent
   */
  function executeDvP3009(
    address _securityToken,
    address _cashToken,
    ITransferIntent.TransferIntent calldata _securitiesIntent,
    bytes calldata _securitiesSig,
    Authorization calldata _authorization
  ) external returns (bytes32 _securitiesIntentHash);

  /**
   * @notice Stops all settlement through this executor
   * @dev Only GUARDIAN_ROLE, with no delay
   */
  function pause() external;

  /**
   * @notice Resumes settlement through this executor
   * @dev Only DEFAULT_ADMIN_ROLE (the main timelock) or RECOVERY_ROLE (the recovery timelock, which the guardian cannot
   *      cancel)
   */
  function unpause() external;

  /**
   * @notice Pre-flight for `executeDvPGated`
   * @dev Runs the pause check, the mirror check and both legs' `canExecute` from this executor's address, cash first.
   *      It does not check OPERATOR_ROLE, nor that this executor holds EXECUTOR_ROLE on the two tokens (the tokens'
   *      own `canExecute` checks neither role). Legs on tokens that share policy state, such as two classes of one
   *      fund, are each checked against the current state, and the first leg's movement can change the second's answer
   * @param _securityToken The security token
   * @param _cashToken The cash token
   * @param _securitiesIntent The seller's signed intent
   * @param _securitiesSig The seller's signature
   * @param _cashIntent The buyer's signed intent
   * @param _cashSig The buyer's signature
   * @return _ok True if the trade would settle
   * @return _reason The reason code; `Reasons.TRANSFER_OK` when `_ok`
   */
  function canExecuteDvPGated(
    address _securityToken,
    address _cashToken,
    ITransferIntent.TransferIntent calldata _securitiesIntent,
    bytes calldata _securitiesSig,
    ITransferIntent.TransferIntent calldata _cashIntent,
    bytes calldata _cashSig
  ) external view returns (bool _ok, bytes32 _reason);

  /**
   * @notice Pre-flight for `executeDvP3009`
   * @dev Runs the pause check, the match check, then for the authorization its window (not yet valid, then expired,
   *      both ends exclusive), its state and the buyer's balance, then the securities leg's `canExecute`. It cannot
   *      check the buyer's signature, which the cash token exposes no view for, nor a pause or blocklist on the cash
   *      token. It does not check OPERATOR_ROLE, nor that this executor holds EXECUTOR_ROLE on the security token
   * @param _securityToken The security token
   * @param _cashToken The ERC-3009 cash token
   * @param _securitiesIntent The seller's signed intent
   * @param _securitiesSig The seller's signature
   * @param _authorization The buyer's signed authorization
   * @return _ok True if the trade would settle, given a valid authorization signature
   * @return _reason The reason code; `Reasons.TRANSFER_OK` when `_ok`
   */
  function canExecuteDvP3009(
    address _securityToken,
    address _cashToken,
    ITransferIntent.TransferIntent calldata _securitiesIntent,
    bytes calldata _securitiesSig,
    Authorization calldata _authorization
  ) external view returns (bool _ok, bytes32 _reason);
}
