// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';

/**
 * @title IGated7540Vault
 * @notice ERC-7540 asynchronous vault whose shares are a policy-gated token, dealt in periods. One period is open and
 *         requests join it. Everyone in a period gets one price, settled in one transaction however many investors there
 *         are, and each claims later. Requests aggregate per controller (`requestId = 0`). A settlement can take only part
 *         of a period's redemptions: every request is filled at the same fraction, and the rest carries to the next period,
 *         stays invested, and deals at that period's price
 * @dev Deposit flow: `requestDeposit` takes the assets into the vault (the controller must be able to hold shares);
 *      settlement prices them; the claim MINTs shares to the receiver through the hook. Redeem flow: `requestRedeem`
 *      escrows the shares into the vault as a TRANSFER through the hook (pause, the frozen amount and the rules apply; the
 *      vault is the token's own address, which `CredentialRule` does not judge and the fund never counts); settlement
 *      BURNs the escrow and prices it; the claim pays the assets.
 *
 *      The price is the 4626's form, so `decimals()` is the asset's plus 6: with `supply = totalSupply() + unclaimed`,
 *      shares for all deposits are `deposits × (supply + 1e6) / (nav + 1)` and assets for the redemptions taken are
 *      `redeemed × (nav + 1) / (supply + 1e6)`, both rounded down. The virtual amounts stop a donation inflating the
 *      price, and across a whole fund they move value by `price − 1` smallest asset units. Given what was paid, a claim
 *      rounds the other side down; given what is owed, it rounds the paid side up; a full claim clears exactly. Rounding
 *      each investor's claim down leaves at most one unit per period in `unclaimedShares`, for good.
 *
 *      Rejects return what was requested to the controller. `preview*` revert, as ERC-7540 requires. Issuer `mint` / `burn`
 *      revert. A payer other than the controller, a receiver of redemption cash other than the controller, and a controller
 *      other than the owner of the shares must pass the token's policy (`IGatedVaultBase`)
 */
interface IGated7540Vault {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

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
   * @notice Emitted when a pending deposit request is rejected; the assets go back to the controller
   * @param _controller The controller
   * @param _assets The assets returned
   */
  event DepositRequestRejected(address indexed _controller, uint256 _assets);

  /**
   * @notice Emitted when the open period closes and the next one opens
   * @param _period The period that closed
   */
  event PeriodClosed(uint256 indexed _period);

  /**
   * @notice Emitted on every settlement, putting the NAV history on-chain
   * @param _period The period
   * @param _nav The net asset value the period dealt at
   * @param _supply All shares at that value: the total supply plus unclaimed shares, before the settlement's burn
   * @param _deposits The assets of the period's deposit requests
   * @param _shares The shares they bought
   * @param _redemptions The shares of the period's redemption requests, carried ones included
   * @param _redeemed The shares taken from them; the rest carry to the next period
   * @param _assets The assets the shares taken pay
   * @param _fee The fee paid
   */
  event PeriodSettled(
    uint256 indexed _period,
    uint256 _nav,
    uint256 _supply,
    uint256 _deposits,
    uint256 _shares,
    uint256 _redemptions,
    uint256 _redeemed,
    uint256 _assets,
    uint256 _fee
  );

  /**
   * @notice Emitted when a pending redemption whose controller cannot receive the shares back is recovered
   * @param _controller The controller whose request was cleared
   * @param _to The verified recovery account that received the escrowed shares
   * @param _shares The shares moved
   * @param _agent The account that recovered them
   */
  event RedeemRequestRecovered(address indexed _controller, address indexed _to, uint256 _shares, address _agent);

  /**
   * @notice Emitted when a pending redemption request is rejected; the shares go back to the controller
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
   * @notice Thrown when the vault would hold less after a settlement than it owes
   * @param _held The assets it holds
   * @param _owed Pending deposits plus claimable redemption cash
   */
  error Gated7540Vault_BalanceAudit(uint256 _held, uint256 _owed);

  /**
   * @notice Thrown when a controller fails its policy pre-flight: on a deposit request or deposit claim (could it
   *         receive shares) or on a redemption payout (could it act as a sender)
   * @param _reason The reason code from the pre-flight
   */
  error Gated7540Vault_ControllerNotEligible(bytes32 _reason);

  /**
   * @notice Thrown when a controller with a request in an earlier, unsettled period requests again
   * @param _period The period the earlier request is in
   */
  error Gated7540Vault_EarlierRequestUnsettled(uint256 _period);

  /**
   * @notice Thrown when a claim exceeds what is claimable
   * @param _requested The requested amount
   * @param _claimable The claimable amount
   */
  error Gated7540Vault_ExceedsClaimable(uint256 _requested, uint256 _claimable);

  /**
   * @notice Thrown when a forced transfer out of the vault would take shares booked to pending redemptions
   * @param _requested The amount to move
   * @param _surplus The vault's shares above the pending total, the only ones a forced transfer may take
   */
  error Gated7540Vault_ExceedsSurplus(uint256 _requested, uint256 _surplus);

  /// @notice Thrown when settling with no closed period
  error Gated7540Vault_NoClosedPeriod();

  /// @notice Thrown when recovering the claimable balances of a controller that has none
  error Gated7540Vault_NothingClaimable();

  /// @notice Thrown when rejecting or recovering a controller with nothing pending
  error Gated7540Vault_NothingPending();

  /**
   * @notice Thrown when closing the open period while an earlier closed one is unsettled
   * @param _period The unsettled period
   */
  error Gated7540Vault_PeriodUnsettled(uint256 _period);

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

  /// @notice Thrown on a zero address argument
  error Gated7540Vault_ZeroAddress();

  /// @notice Thrown when an amount, or a claim's computed output, is zero
  error Gated7540Vault_ZeroAmount();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Closes the open period and opens the next
   * @dev SETTLER_ROLE. Reverts while an earlier closed period is unsettled, so at most one is closed
   */
  function closePeriod() external;

  /**
   * @notice Initializes a vault proxy
   * @param _asset The underlying asset; its `decimals()` must answer, and the shares take that plus 6
   * @param _name The share token name, also the EIP-712 domain name
   * @param _symbol The share token symbol
   * @param _admin The first admin, granted DEFAULT_ADMIN_ROLE: the operations account in a launch, which hands it to the timelock
   * @param _guardian The guardian multisig, granted GUARDIAN_ROLE
   * @param _registry The policy registry
   * @param _hook The initial policy hook; must be attested as HOOK and name the same registry
   * @param _initialRules The rule set installed on the hook for this token in the same call; empty installs none
   */
  function initialize(
    IERC20 _asset,
    string memory _name,
    string memory _symbol,
    address _admin,
    address _guardian,
    address _registry,
    address _hook,
    IComplianceRule[] memory _initialRules
  ) external;

  /**
   * @notice Recovers a controller's claimable balances to a verified account (an enforcement action)
   * @dev Only AGENT_ROLE. Pays the claimable redemption assets to `_to` and delivers the claimable deposit shares to
   *      `_to` as an enforcement mint (FORCED, `from == address(0)`): bypasses pause and the holder cap, but `_to` must
   *      pass identity. For a controller that became ineligible after settlement, or a deposit stranded by a full cap.
   *      Reverts if nothing is claimable. Emits `ClaimableRecovered`
   * @param _controller The controller
   * @param _to The verified recovery account, e.g. the treasury or the controller's own recovery account
   */
  function recoverClaimable(
    address _controller,
    address _to
  ) external;

  /**
   * @notice Recovers a controller's whole pending redemption, a carried part included, to a verified account (an
   *         enforcement action)
   * @dev AGENT_ROLE while the request's period is open, SETTLER_ROLE once it has closed. Clears the controller's pending
   *      bookkeeping and moves the escrowed shares to `_to` internally as FORCED: bypasses pause, lockup and the holder
   *      cap, but `_to` must pass the token's policy (identity, freeze, fund class). The path for a controller that was de-verified, whose reject reverts. Reverts
   *      if nothing is pending
   * @param _controller The controller
   * @param _to The verified recovery account, e.g. the treasury
   */
  function recoverRedeemRequest(
    address _controller,
    address _to
  ) external;

  /**
   * @notice Rejects a controller's whole pending deposit and returns the assets to the controller
   * @dev AGENT_ROLE while the request's period is open, SETTLER_ROLE once it has closed. The way to unstick a request
   *      whose controller became ineligible (no cancellation)
   * @param _controller The controller
   */
  function rejectDepositRequest(
    address _controller
  ) external;

  /**
   * @notice Rejects a controller's whole pending redemption, a carried part included, and returns the escrowed shares to
   *         the controller
   * @dev AGENT_ROLE while the request's period is open, SETTLER_ROLE once it has closed. Returned as a plain TRANSFER, so
   *      the full policy applies to the controller (identity, cap, pause, lockup, and freeze on the escrow). If it is
   *      blocked this reverts and the shares stay escrowed for `recoverRedeemRequest`
   * @param _controller The controller
   */
  function rejectRedeemRequest(
    address _controller
  ) external;

  /**
   * @notice Settles the closed period at one price
   * @dev SETTLER_ROLE, not while paused. Burns the escrow of the shares taken, then nets: only the difference between deposits and
   *      `assets + fee` moves to or from `_cash`, so subscriptions pay redemptions. Pays the fee, then reverts unless the
   *      vault holds at least pending deposits plus claimable redemption cash. Whoever holds the role sets any price and
   *      can name any cash account that approved the vault, so the role belongs to a `NavDesk`
   * @param _nav The net asset value the period deals at. It leaves out what this vault holds, which is pending deposits and
   *        claimable redemption cash: that money belongs to investors, and is not yet or no longer invested
   * @param _fee The fee to pay, in assets
   * @param _cash The account that receives net inflow and funds net outflow
   * @param _feeRecipient The account that receives the fee
   * @param _redeemLimit The most shares to take from the period's redemptions. The rest carry to the next period, each
   *        request being filled at the same fraction. `type(uint256).max` takes them all
   */
  function settlePeriod(
    uint256 _nav,
    uint256 _fee,
    address _cash,
    address _feeRecipient,
    uint256 _redeemLimit
  ) external;

  /**
   * @notice The role allowed to close and settle periods
   * @return _role keccak256('SETTLER_ROLE')
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function SETTLER_ROLE() external view returns (bytes32 _role);

  /**
   * @notice The contract that holds the settlement and recovery functions, which this vault hands them to
   * @dev An immutable of the implementation, created by its constructor, so the implementation's attested codehash pins it
   *      and each implementation has its own. Reached directly it does nothing: nobody holds a role on it
   * @return _logic The second contract
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function SETTLEMENT_LOGIC() external view returns (address _logic);

  /**
   * @notice Where dealing stands
   * @return _open The open period; the first is 1
   * @return _settled The last settled period; 0 before the first settlement. A closed period is `_settled + 1` when that
   *         is below `_open`
   * @return _unclaimedShares Shares bought in settled periods and not yet minted
   */
  function dealingState() external view returns (uint64 _open, uint64 _settled, uint256 _unclaimedShares);

  /**
   * @notice One side of one period
   * @param _period The period
   * @param _isDeposit True for its deposits, false for its redemptions
   * @return _paid What its requests gave, net of rejects: on the redemption side, carried shares included
   * @return _owed What that bought, at settlement
   * @return _carried On the redemption side, what settlement left of `_paid` for the next period
   */
  function periodBook(
    uint256 _period,
    bool _isDeposit
  ) external view returns (uint256 _paid, uint256 _owed, uint256 _carried);
}
