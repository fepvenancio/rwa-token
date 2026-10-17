// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title IGated7540Vault
 * @notice ERC-7540 asynchronous vault whose shares are a policy-gated token. Requests aggregate per controller
 *         (`requestId = 0`); `FULFILLER_ROLE` (the bank) fulfils with explicit, off-chain-priced amounts
 * @dev Deposit flow: `requestDeposit` takes the assets into the vault (the controller must be able to hold shares);
 *      `fulfillDeposit` sends them to custody and makes shares claimable; the claim MINTs shares to the receiver
 *      through the hook. Redeem flow: `requestRedeem` escrows the shares into the vault as a TRANSFER through the
 *      hook (lockup, frozen, identity and pause apply; the vault is registered as a verified, holder-exempt account);
 *      `fulfillRedeem` pulls the assets from the fulfiller and BURNs the escrowed shares; the claim pays the assets.
 *      Rejects return what was requested to the controller. Partial claims round in the vault's favour and full claims
 *      clear exactly. `preview*` revert, as ERC-7540 requires. Issuer `mint` / `burn` revert
 */
interface IGated7540Vault {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when the custody address changes
   * @param _oldCustody The previous custody address
   * @param _newCustody The new custody address
   */
  event CustodyChanged(address indexed _oldCustody, address indexed _newCustody);

  /**
   * @notice Emitted when the fulfiller rejects a pending deposit request; the assets go back to the controller
   * @param _controller The controller
   * @param _assets The assets returned
   */
  event DepositRequestRejected(address indexed _controller, uint256 _assets);

  /**
   * @notice Emitted on every fulfilment, putting the NAV history on-chain
   * @param _controller The controller of the fulfilled request
   * @param _isDeposit True for a deposit fulfilment, false for a redemption
   * @param _price The fulfilment price: assets per `10**decimals()` shares, rounded down, and never below 1
   * @param _assets The assets of the fulfilment
   * @param _shares The shares of the fulfilment
   * @param _fulfiller The FULFILLER_ROLE account that fulfilled
   */
  event Fulfilled(
    address indexed _controller,
    bool indexed _isDeposit,
    uint256 _price,
    uint256 _assets,
    uint256 _shares,
    address _fulfiller
  );

  /**
   * @notice Emitted when an agent recovers a controller's claimable balances (an enforcement action)
   * @param _controller The controller whose claimable balances were cleared
   * @param _to The verified recovery account
   * @param _assets The claimable redemption assets paid to `_to`
   * @param _shares The claimable deposit shares minted to `_to`
   * @param _agent The AGENT_ROLE account that recovered them
   */
  event ClaimableRecovered(
    address indexed _controller, address indexed _to, uint256 _assets, uint256 _shares, address _agent
  );

  /**
   * @notice Emitted when an agent recovers a pending redemption whose controller cannot receive the shares back
   * @param _controller The controller whose request was cleared
   * @param _to The verified recovery account that received the escrowed shares
   * @param _shares The shares moved
   * @param _agent The AGENT_ROLE account that recovered them
   */
  event RedeemRequestRecovered(address indexed _controller, address indexed _to, uint256 _shares, address _agent);

  /**
   * @notice Emitted when the fulfiller rejects a pending redemption request; the shares go back to the controller
   * @param _controller The controller
   * @param _shares The shares returned
   */
  event RedeemRequestRejected(address indexed _controller, uint256 _shares);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown by `preview*`, which ERC-7540 requires to revert for asynchronous flows
  error Gated7540Vault_AsyncOnly();

  /**
   * @notice Thrown when a controller fails its policy pre-flight: on a deposit request or deposit claim (could it
   *         receive shares) or on a redemption payout (could it act as a sender)
   * @param _reason The reason code from the pre-flight
   */
  error Gated7540Vault_ControllerNotEligible(bytes32 _reason);

  /**
   * @notice Thrown when a claim exceeds what is claimable
   * @param _requested The requested amount
   * @param _claimable The claimable amount
   */
  error Gated7540Vault_ExceedsClaimable(uint256 _requested, uint256 _claimable);

  /**
   * @notice Thrown when a fulfilment exceeds what is pending
   * @param _requested The requested amount
   * @param _pending The pending amount
   */
  error Gated7540Vault_ExceedsPending(uint256 _requested, uint256 _pending);

  /// @notice Thrown when recovering the claimable balances of a controller that has none
  error Gated7540Vault_NothingClaimable();

  /// @notice Thrown when fulfilling, rejecting or recovering a controller with nothing pending
  error Gated7540Vault_NothingPending();

  /**
   * @notice Thrown when a recovery account fails the identity pre-flight for an enforcement delivery
   * @param _reason The reason code from the pre-flight
   */
  error Gated7540Vault_RecipientNotEligible(bytes32 _reason);

  /**
   * @notice Thrown when the caller may not act for the owner or controller
   * @param _caller The caller
   */
  error Gated7540Vault_Unauthorized(address _caller);

  /// @notice Thrown by the issuer `mint` / `burn` primitives, which vault shares do not support
  error Gated7540Vault_Unsupported();

  /// @notice Thrown on a zero address argument
  error Gated7540Vault_ZeroAddress();

  /// @notice Thrown when an amount, or a claim's computed output, is zero
  error Gated7540Vault_ZeroAmount();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Fulfils (part of) a controller's pending deposit at an off-chain NAV
   * @dev Only FULFILLER_ROLE. Sends the assets to custody and makes `_shares` claimable. Emits `Fulfilled`
   * @param _controller The controller
   * @param _assets The pending assets fulfilled; non-zero
   * @param _shares The shares they buy; non-zero
   */
  function fulfillDeposit(
    address _controller,
    uint256 _assets,
    uint256 _shares
  ) external;

  /**
   * @notice Fulfils (part of) a controller's pending redemption at an off-chain NAV
   * @dev Only FULFILLER_ROLE. Pulls `_assets` from the fulfiller, BURNs the escrowed shares and makes the assets
   *      claimable. Emits `Fulfilled`
   * @param _controller The controller
   * @param _shares The pending shares fulfilled; non-zero
   * @param _assets The assets they pay; non-zero
   */
  function fulfillRedeem(
    address _controller,
    uint256 _shares,
    uint256 _assets
  ) external;

  /**
   * @notice Initializes a vault proxy
   * @param _asset The underlying asset
   * @param _name The share token name, also the EIP-712 domain name
   * @param _symbol The share token symbol
   * @param _admin The timelock, granted DEFAULT_ADMIN_ROLE
   * @param _guardian The guardian multisig, granted GUARDIAN_ROLE
   * @param _registry The policy registry
   * @param _hook The initial policy hook; must be attested as HOOK
   * @param _custody The custody address that receives fulfilled deposit assets
   */
  function initialize(
    IERC20 _asset,
    string calldata _name,
    string calldata _symbol,
    address _admin,
    address _guardian,
    address _registry,
    address _hook,
    address _custody
  ) external;

  /**
   * @notice Recovers a controller's claimable balances to a verified account (an enforcement action)
   * @dev Only AGENT_ROLE. Pays the claimable redemption assets to `_to` and delivers the claimable deposit shares to
   *      `_to` as an enforcement mint (FORCED, `from == address(0)`): bypasses pause and the holder cap, but `_to` must
   *      pass identity. For a controller that became ineligible after fulfilment, or a deposit stranded by a full cap.
   *      Reverts if nothing is claimable. Emits `ClaimableRecovered`
   * @param _controller The controller
   * @param _to The verified recovery account, e.g. custody, the treasury, or the controller's own recovery account
   */
  function recoverClaimable(
    address _controller,
    address _to
  ) external;

  /**
   * @notice Recovers a controller's whole pending redemption to a verified account (an enforcement action)
   * @dev Only AGENT_ROLE. Clears the controller's pending bookkeeping and moves the escrowed shares to `_to` internally
   *      as FORCED: bypasses pause, lockup and the holder cap, but `_to` must pass identity. The path for a controller
   *      that was de-verified, whose reject reverts. Reverts if nothing is pending
   * @param _controller The controller
   * @param _to The verified recovery account, e.g. the treasury
   */
  function recoverRedeemRequest(
    address _controller,
    address _to
  ) external;

  /**
   * @notice Rejects a controller's whole pending deposit and returns the assets to the controller
   * @dev Only FULFILLER_ROLE. The way to unstick a request whose controller became ineligible (no cancellation)
   * @param _controller The controller
   */
  function rejectDepositRequest(
    address _controller
  ) external;

  /**
   * @notice Rejects a controller's whole pending redemption and returns the escrowed shares to the controller
   * @dev Only FULFILLER_ROLE. Moved internally as FORCED: bypasses pause, lockup and the holder cap, but the controller
   *      must still be verified. If it was de-verified this reverts and the shares stay escrowed for agent recovery
   * @param _controller The controller
   */
  function rejectRedeemRequest(
    address _controller
  ) external;

  /**
   * @notice Changes the custody address
   * @dev Only DEFAULT_ADMIN_ROLE (timelock)
   * @param _newCustody The new custody address
   */
  function setCustody(
    address _newCustody
  ) external;

  /**
   * @notice The role allowed to fulfil and reject requests
   * @return _role keccak256('FULFILLER_ROLE')
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function FULFILLER_ROLE() external view returns (bytes32 _role);

  /**
   * @notice The custody address that receives fulfilled deposit assets
   * @return _custody The custody address
   */
  function custody() external view returns (address _custody);

  /**
   * @notice The last fulfilment price, used by `convertTo*` and the indicative `totalAssets`
   * @return _price Assets per `10**decimals()` shares, never below 1; `10**decimals()` (1:1) before the first fulfilment
   */
  function lastPrice() external view returns (uint256 _price);
}
