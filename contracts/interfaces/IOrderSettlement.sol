// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IOrderSettlement
 * @notice Settles signed orders against each other, in whole or in parts, many in one transaction
 * @dev A maker signs an `Order` on this contract's EIP-712 domain: what it gives at most, and what it takes at least
 *      for all of it, which together are its limit price. An operator submits two orders that cross and how much each
 *      gives. The contract checks both orders and both limits, records how much of each order is filled, and moves the
 *      two amounts between the makers under the allowances they gave it. It holds no role on any token and never
 *      holds a token. Each token sees a plain transfer with this contract as the operator, so its policy judges the
 *      two makers as on any transfer: a token that lets only signed intents move cannot trade here.
 *      The operator chooses which orders meet, in what amounts and at what price between the two limits. It cannot
 *      move anything outside a signed order, past an order's amount, worse than an order's limit, or to anyone but
 *      the two makers; with no fee and no other receiver, whatever lies between two limits goes to one of the makers
 */
interface IOrderSettlement {
  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Why a fill is refused, in the order the checks run
   * @param NONE Not refused
   * @param ZERO_AMOUNT One of the two amounts of the fill is zero
   * @param EMPTY_ORDER The order gives or takes nothing
   * @param ID_ON_ERC20 The order names a token id on a side that is not an ERC-1155
   * @param SAME_ASSET The order gives and takes the same token and id
   * @param SELF_FILL Both orders are one maker's
   * @param DO_NOT_CROSS The two orders do not name each other's tokens, ids and kinds
   * @param EXPIRED The order's deadline has passed
   * @param NOT_YET_VALID The order's `validAfter` has not come
   * @param CANCELLED The maker cancelled the order's nonce
   * @param WRONG_TAKER The order names a taker, and the other maker is not it
   * @param BAD_SIGNATURE The maker's signature does not verify
   * @param OVERFILLED The fill would take the order past what it gives
   * @param NOT_WHOLE The order is all or nothing, and the fill is not all of it
   * @param BELOW_LIMIT The maker would receive less than its limit for what it gives
   * @param TOKEN_REFUSES The token's own pre-flight refuses the transfer. Only `canFill` answers this; in `settle` the
   *        token's own error comes back in `OrderSettlement_TransferFailed`
   */
  enum Refusal {
    NONE,
    ZERO_AMOUNT,
    EMPTY_ORDER,
    ID_ON_ERC20,
    SAME_ASSET,
    SELF_FILL,
    DO_NOT_CROSS,
    EXPIRED,
    NOT_YET_VALID,
    CANCELLED,
    WRONG_TAKER,
    BAD_SIGNATURE,
    OVERFILLED,
    NOT_WHOLE,
    BELOW_LIMIT,
    TOKEN_REFUSES
  }

  /**
   * @notice What a maker signs
   * @param maker Who signs, gives and receives
   * @param giveToken The token the maker gives
   * @param giveId The token id it gives: zero for an ERC-20
   * @param giveAmount The most it gives
   * @param takeToken The token the maker takes
   * @param takeId The token id it takes: zero for an ERC-20
   * @param takeAmount The least it takes for all of `giveAmount`. With `giveAmount` it is the maker's limit price
   * @param giveIs1155 True when the token it gives is an ERC-1155
   * @param takeIs1155 True when the token it takes is an ERC-1155
   * @param taker The only counterparty allowed; the zero address for anyone
   * @param allOrNothing True when the order fills in one fill for all of `giveAmount` or not at all
   * @param nonce A nonce the maker chooses. It makes the order unique, and it is what `cancelOrder` spends
   * @param validAfter The first moment it is valid, inclusive; zero for no lower bound
   * @param deadline The last moment it is valid, inclusive
   */
  struct Order {
    address maker;
    address giveToken;
    uint256 giveId;
    uint256 giveAmount;
    address takeToken;
    uint256 takeId;
    uint256 takeAmount;
    bool giveIs1155;
    bool takeIs1155;
    address taker;
    bool allOrNothing;
    bytes32 nonce;
    uint256 validAfter;
    uint256 deadline;
  }

  /**
   * @notice Two orders that cross, and how much of each is filled
   * @param first One order
   * @param firstSig Its maker's signature over `orderHash(first)`
   * @param second The order on the other side
   * @param secondSig Its maker's signature over `orderHash(second)`
   * @param firstGives How much the first maker gives, of its `giveToken`
   * @param secondGives How much the second maker gives, of its `giveToken`
   */
  struct Fill {
    Order first;
    bytes firstSig;
    Order second;
    bytes secondSig;
    uint256 firstGives;
    uint256 secondGives;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted for each of the two orders of a fill
   * @param _orderHash The hash the maker signed
   * @param _maker The maker
   * @param _counterparty The other maker
   * @param _given What the maker gave in this fill
   * @param _received What the maker received in this fill
   */
  event OrderFilled(
    bytes32 indexed _orderHash, address indexed _maker, address indexed _counterparty, uint256 _given, uint256 _received
  );

  /**
   * @notice Emitted when a maker cancels a nonce
   * @param _maker The maker
   * @param _nonce The nonce
   */
  event OrderCancelled(address indexed _maker, bytes32 indexed _nonce);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when a fill fails one of the contract's own checks
   * @param _index The fill's place in the batch
   * @param _refusal Which check
   * @param _secondOrder True when the check failed on the second order, false for the first or for the fill as a whole
   */
  error OrderSettlement_FillRefused(uint256 _index, Refusal _refusal, bool _secondOrder);

  /// @notice Thrown when the maker's nonce is already cancelled
  error OrderSettlement_NonceCancelled();

  /**
   * @notice Thrown when a token refuses a transfer of a fill
   * @param _index The fill's place in the batch
   * @param _secondLeg True for the second maker's transfer, false for the first maker's
   * @param _reason What the token reverted with
   */
  error OrderSettlement_TransferFailed(uint256 _index, bool _secondLeg, bytes _reason);

  /**
   * @notice Thrown when an ERC-20 transfer did not raise the receiver's balance by exactly the amount
   * @param _index The fill's place in the batch
   * @param _secondLeg True for the second maker's transfer, false for the first maker's
   * @param _expected The amount of the leg
   * @param _received What the receiver's balance rose by
   */
  error OrderSettlement_WrongAmountReceived(uint256 _index, bool _secondLeg, uint256 _expected, uint256 _received);

  /// @notice Thrown when a constructor argument is the zero address
  error OrderSettlement_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Cancels every order the caller signed with a nonce
   * @dev What an order already filled stays. Two orders signed with one nonce are both cancelled
   * @param _nonce The nonce
   */
  function cancelOrder(
    bytes32 _nonce
  ) external;

  /**
   * @notice Pauses settlement
   * @dev Only GUARDIAN_ROLE, with no delay. Cancelling still works
   */
  function pause() external;

  /**
   * @notice Settles a batch of fills, in order, atomically
   * @dev Only OPERATOR_ROLE, only while not paused. Each fill runs the checks of `Refusal` in order, records what it
   *      fills of both orders, and moves the first maker's amount to the second maker and the second's to the first.
   *      A later fill of an order sees what the earlier fills of it filled. One fill that fails reverts the batch,
   *      naming its index
   * @param _fills The fills
   */
  function settle(
    Fill[] calldata _fills
  ) external;

  /**
   * @notice Resumes settlement
   * @dev Only DEFAULT_ADMIN_ROLE (the main timelock) or RECOVERY_ROLE (the recovery timelock, which the guardian
   *      cannot cancel)
   */
  function unpause() external;

  /**
   * @notice Whether a fill would pass the contract's own checks now, and the tokens' own pre-flight where they have one
   * @dev Runs the checks of `settle` for one fill. It does not check OPERATOR_ROLE or the pause. For a leg whose token
   *      answers the stack's reasoned pre-flight through ERC-165 it asks that token, and for one that answers only
   *      ERC-7943's it asks `canTransfer`; a refusal there reads `TOKEN_REFUSES` with the token's reason when it gives
   *      one. It checks no allowance, and no balance of a token that has no such pre-flight
   * @param _fill The fill
   * @return _refusal The first refusal, or `NONE`
   * @return _secondOrder True when it is about the second order or the second maker's leg
   * @return _tokenReason The token's reason code for `TOKEN_REFUSES`, when the token gives one
   */
  function canFill(
    Fill calldata _fill
  ) external view returns (Refusal _refusal, bool _secondOrder, bytes32 _tokenReason);

  /**
   * @notice How much of an order has been given so far
   * @param _orderHash The order's hash
   * @return _given The amount of its `giveToken` given so far
   */
  function filled(
    bytes32 _orderHash
  ) external view returns (uint256 _given);

  /**
   * @notice Whether a maker cancelled a nonce
   * @param _maker The maker
   * @param _nonce The nonce
   * @return _cancelled True if cancelled
   */
  function nonceCancelled(
    address _maker,
    bytes32 _nonce
  ) external view returns (bool _cancelled);

  /**
   * @notice The EIP-712 hash a maker signs
   * @param _order The order
   * @return _hash The hash
   */
  function orderHash(
    Order calldata _order
  ) external view returns (bytes32 _hash);

  /**
   * @notice The role allowed to pause
   * @return _role The role id
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function GUARDIAN_ROLE() external view returns (bytes32 _role);

  /**
   * @notice The role allowed to submit fills
   * @return _role The role id
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function OPERATOR_ROLE() external view returns (bytes32 _role);

  /**
   * @notice The role of the recovery timelock: it may only unpause and revoke GUARDIAN_ROLE
   * @return _role The role id
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function RECOVERY_ROLE() external view returns (bytes32 _role);
}
