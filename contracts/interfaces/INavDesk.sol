// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title INavDesk
 * @notice Turns a reported value into an approved price for one 7540 vault, on a schedule. Nobody chooses the cut-off, the
 *         price is struck after requests close, and two people approve every price
 * @dev Holds no money and has no role table: it asks the vault live. It must hold the vault's SETTLER_ROLE, which
 *      `isWired` shows to monitors. If nothing can be approved the period stays closed and new requests wait in the next
 *      one, which is a dealing suspension: nobody trades at a wrong price
 */
interface INavDesk {
  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice A price on the table. Everything in it is frozen, because a timelock change can land inside the cooldown
   * @param period The period it prices; 0 with nothing on the table
   * @param proposedAt When it was proposed
   * @param asOf When the report was struck
   * @param acceptedAt When the checker accepted it; 0 until then
   * @param proposer The reporter, who may not also accept it
   * @param nav The net asset value
   * @param fee The fee, in assets
   * @param mark The high-water mark after this price
   * @param markMovedAt When the mark last moved, as of this price
   * @param reportHash The hash of the off-chain NAV pack
   * @param cash The cash account
   * @param feeRecipient The fee recipient
   * @param redeemLimit The most shares this period may take from its redemptions; `type(uint256).max` with the gate off
   */
  struct Proposal {
    uint64 period;
    uint64 proposedAt;
    uint64 asOf;
    uint64 acceptedAt;
    address proposer;
    uint256 nav;
    uint256 fee;
    uint256 mark;
    uint256 markMovedAt;
    uint256 paidSinceMark;
    bytes32 reportHash;
    address cash;
    address feeRecipient;
    uint256 redeemLimit;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a checker accepts a proposal
   * @param _proposalHash The proposal
   * @param _checker The checker
   */
  event ProposalAccepted(bytes32 indexed _proposalHash, address indexed _checker);

  /**
   * @notice Emitted when a proposal is cancelled
   * @param _proposalHash The proposal
   * @param _by The account that cancelled it
   */
  event ProposalCancelled(bytes32 indexed _proposalHash, address indexed _by);

  /**
   * @notice Emitted when a proposal settles its period
   * @param _proposalHash The proposal
   * @param _period The period
   */
  event ProposalExecuted(bytes32 indexed _proposalHash, uint256 indexed _period);

  /**
   * @notice Emitted when a reporter proposes a price
   * @param _proposalHash The proposal
   * @param _period The period it prices
   * @param _reported What the reporter said of everything not priced on-chain
   * @param _priced What the portfolio priced on-chain
   * @param _nav The net asset value
   * @param _fee The fee
   * @param _reportHash The hash of the off-chain NAV pack
   * @param _asOf When the report was struck
   * @param _redeemLimit The most shares the period may take from its redemptions
   */
  event ProposalMade(
    bytes32 indexed _proposalHash,
    uint256 indexed _period,
    uint256 _reported,
    uint256 _priced,
    uint256 _nav,
    uint256 _fee,
    bytes32 _reportHash,
    uint256 _asOf,
    uint256 _redeemLimit
  );

  /**
   * @notice Emitted when the redemption gate's level changes
   * @param _gateBps The level, in basis points of all shares; zero is off
   */
  event RedemptionGateSet(uint256 _gateBps);

  /**
   * @notice Emitted when the agent takes a request out of a stuck period
   * @param _controller The controller
   * @param _isDeposit True on the deposit side
   * @param _to Where the shares went, on a recovery; otherwise the controller
   */
  event RequestReleased(address indexed _controller, bool _isDeposit, address _to);

  /**
   * @notice Emitted when the admin changes a setting
   * @param _portfolio The portfolio, or zero for none
   * @param _custodianAccount The cash account when there is no portfolio
   * @param _periodLength The time between cut-offs
   * @param _cooldown The time between a proposal and its execution
   * @param _maxReportAge The oldest report that may execute
   */
  event SettingsChanged(
    address indexed _portfolio,
    address indexed _custodianAccount,
    uint256 _periodLength,
    uint256 _cooldown,
    uint256 _maxReportAge
  );

  /**
   * @notice Emitted when the fee model changes
   * @param _feeModel The fee model, or zero for none
   */
  event FeeModelSet(address indexed _feeModel);

  /**
   * @notice Emitted when this desk closes the vault's open period
   * @param _at The new cut-off
   */
  event CutOff(uint256 _at);

  /**
   * @notice Emitted when a desk takes over from another
   * @param _oldDesk The desk it replaces
   */
  event DeskAdopted(address indexed _oldDesk);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown on a second `adopt`, or an `adopt` of a desk with a proposal pending or for another vault
  error NavDesk_CannotAdopt();

  /// @notice Thrown when the period has not been closed for long enough to count as stuck
  error NavDesk_NotStuck();

  /**
   * @notice Thrown when a cooldown is out of bounds
   * @param _cooldown The cooldown
   */
  error NavDesk_InvalidCooldown(uint256 _cooldown);

  /**
   * @notice Thrown when a redemption gate's level is above the whole fund
   * @param _gateBps The level
   */
  error NavDesk_InvalidGate(uint256 _gateBps);

  /// @notice Thrown when a price would be proposed with no cash account
  error NavDesk_NoCashAccount();

  /// @notice Thrown when proposing or executing with no closed period
  error NavDesk_NoClosedPeriod();

  /// @notice Thrown when acting on a proposal that is not there
  error NavDesk_NoProposal();

  /**
   * @notice Thrown when the portfolio's move count is not what the report was struck against
   * @param _expected The report's count
   * @param _actual The portfolio's count
   */
  error NavDesk_MovesChanged(uint256 _expected, uint256 _actual);

  /// @notice Thrown when a value of zero would price shares that count: a million share units or more
  error NavDesk_ZeroNav();

  /// @notice Thrown when executing a proposal not yet accepted, or accepting one twice
  error NavDesk_AcceptanceWrong();

  /// @notice Thrown when closing before `periodLength` has passed
  error NavDesk_PeriodNotOver();

  /**
   * @notice Thrown when a fee model is not attested in the registry the vault names
   * @param _feeModel The fee model
   */
  error NavDesk_FeeModelRefused(address _feeModel);

  /// @notice Thrown when the portfolio is not attested, is another vault's, or holds another asset
  error NavDesk_PortfolioRefused();

  /// @notice Thrown when the portfolio cannot price every adapter
  error NavDesk_PriceNotFresh();

  /// @notice Thrown when proposing while a proposal is pending
  error NavDesk_ProposalPending();

  /// @notice Thrown when accepting a hash that is not the current proposal's
  error NavDesk_ProposalMismatch();

  /**
   * @notice Thrown when the oldest report allowed is younger than the cooldown, so every price would go stale first
   * @param _maxReportAge The oldest report that may execute
   * @param _cooldown The time between a proposal and its execution
   */
  error NavDesk_ReportAgeBelowCooldown(uint256 _maxReportAge, uint256 _cooldown);

  /// @notice Thrown when a report is struck before the cut-off or in the future
  error NavDesk_ReportOutOfWindow();

  /// @notice Thrown when a proposer tries to accept its own proposal
  error NavDesk_SelfAccept();

  /// @notice Thrown when executing a report older than `maxReportAge`
  error NavDesk_StaleReport();

  /// @notice Thrown when executing before the cooldown has passed
  error NavDesk_TooEarly();

  /**
   * @notice Thrown when executing a proposal for a period that is no longer the closed one, which takes a second settler
   * @param _proposed The period it priced
   * @param _closed The period closed now
   */
  error NavDesk_WrongPeriod(uint256 _proposed, uint256 _closed);

  /**
   * @notice Thrown when the caller lacks the vault role this needs
   * @param _caller The caller
   */
  error NavDesk_Unauthorized(address _caller);

  /// @notice Thrown when a required address or length is zero
  error NavDesk_ZeroValue();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Accepts the proposal on the table
   * @dev The vault's CHECKER_ROLE, never the proposer. The hash covers the period, the value, the fee, the mark and its
   *      clock, the report and its date, the cash account, the fee recipient and the redemption limit, so a replaced
   *      proposal cannot pick up an approval meant for another
   * @param _proposalHash The proposal
   */
  function accept(
    bytes32 _proposalHash
  ) external;

  /**
   * @notice Takes over from a desk being replaced: its last cut-off and its fee state, read at this moment, so nothing is
   *         charged twice however long the timelock took, and its redemption gate, so a replacement cannot lift it by
   *         forgetting it
   * @dev The vault's DEFAULT_ADMIN_ROLE, once, in the batch that moves SETTLER_ROLE. A fee model plugged in that batch,
   *      before or after this, keeps the fee clock taken; a first plug in a later operation starts it, as the desk dealt
   *      with no model in between. A desk that never charged passes on no mark, and a desk with its model off passes on
   *      no fee clock, so a plug made here keeps those
   * @param _oldDesk The desk it replaces; neither desk may have anything on the table
   */
  function adopt(
    address _oldDesk
  ) external;

  /**
   * @notice Cancels the proposal on the table
   * @dev The vault's GUARDIAN_ROLE or CHECKER_ROLE, any time before execution
   */
  function cancel() external;

  /**
   * @notice Closes the vault's open period and opens the next
   * @dev Anyone, once `periodLength` has passed since the last cut-off, so nobody chooses the cut-off
   */
  function closePeriod() external;

  /**
   * @notice Settles the period at the accepted price
   * @dev Anyone, after acceptance and the cooldown, with a report no older than `maxReportAge`, while the period it priced
   *      is still the closed one. Reverts if the cash account is short, so the desk raises cash before proposing
   */
  function execute() external;

  /**
   * @notice Proposes the price of the closed period: `nav = reported + pricedValue() - fee`, the fee being quoted now and
   *         frozen with the rest. With no shares, or fewer share units than one unit of the asset buys at par (`1e6`),
   *         nothing is anyone's: `nav` is zero whatever is reported or sits in the portfolio, so the period strikes at
   *         par, there is no fee, the mark restarts at par, and both fee clocks restart when it executes, so the first
   *         investors pay neither on their principal nor for time before they arrived.
   *         With a redemption gate on, the limit is worked out here and frozen with the rest:
   *         `supply × level / 10,000 + deposits × (supply + 1e6) / (nav + 1)`, the second part being the shares the period's
   *         deposits buy, so the level measures what leaves net of what comes in
   * @dev The vault's REPORTER_ROLE. One at a time
   * @param _reported One number covering everything not priced on-chain; the breakdown is in the NAV pack. It leaves out
   *        what the vault itself holds, which belongs to investors with open requests and claims
   * @param _reportHash The hash of the off-chain NAV pack
   * @param _asOf When the report was struck: not before the cut-off and not in the future, so a price is always struck
   *        after requests close
   * @param _moves The portfolio's `moves()` the report was struck against, so that money crossing between reported and
   *        on-chain after the valuation cannot count twice; 0 with no portfolio
   */
  function propose(
    uint256 _reported,
    bytes32 _reportHash,
    uint256 _asOf,
    uint256 _moves
  ) external;

  /**
   * @notice Forwards the vault's recovery of a pending redemption, out of a stuck period
   * @dev The vault's AGENT_ROLE, with no proposal on the table and the period closed for longer than `maxReportAge`
   * @param _controller The controller
   * @param _to The verified recovery account
   */
  function recoverRequest(
    address _controller,
    address _to
  ) external;

  /**
   * @notice Forwards the vault's reject of a pending request, out of a stuck period, so that cash that was never invested
   *         can always go back. No price is on the table, so nobody can use it as a free option on a known price
   * @dev The vault's AGENT_ROLE, with no proposal on the table and the period closed for longer than `maxReportAge`
   * @param _controller The controller
   * @param _isDeposit True on the deposit side
   */
  function refundRequest(
    address _controller,
    bool _isDeposit
  ) external;

  /**
   * @notice Plugs a fee model, or zero for none
   * @dev The vault's DEFAULT_ADMIN_ROLE. A first plug starts the mark at the vault's current price, or at par if that is
   *      lower, so a gain made before it is not charged, and the fee clock at now. A proposal on the table keeps the fee it froze; one made with no model froze
   *      none, and leaves what this plug set alone
   * @param _feeModel The fee model, attested as FEE_MODEL
   */
  function setFeeModel(
    address _feeModel
  ) external;

  /**
   * @notice Sets the redemption gate's level: the most that may leave in one period, net of deposits, as a share of all
   *         shares. Past it every request is filled at the same fraction, and the rest carries to the next period
   * @dev The vault's DEFAULT_ADMIN_ROLE. A proposal on the table keeps the limit it froze. The level is a share of what
   *      remains, so a fund winding down sets it to zero
   * @param _gateBps The level in basis points, up to 10,000; zero is off
   */
  function setRedemptionGate(
    uint256 _gateBps
  ) external;

  /**
   * @notice Changes the settings
   * @dev The vault's DEFAULT_ADMIN_ROLE
   * @param _portfolio The portfolio, attested for this vault and its asset, or zero for none. When plugged it is both the cash account
   *        and the source of on-chain value
   * @param _custodianAccount The cash account when there is no portfolio; it approves the vault to pull
   * @param _periodLength The time between cut-offs; not zero
   * @param _cooldown The time between a proposal and its execution, within the constants
   * @param _maxReportAge The oldest report that may execute; not below the cooldown
   */
  function setSettings(
    address _portfolio,
    address _custodianAccount,
    uint256 _periodLength,
    uint256 _cooldown,
    uint256 _maxReportAge
  ) external;

  /**
   * @notice The vault this desk serves
   * @return _vault The vault
   */
  // getter of an UPPER_SNAKE immutable
  // solhint-disable-next-line style-guide-casing
  function VAULT() external view returns (address _vault);

  /**
   * @notice The shortest cooldown
   * @return _cooldown 1 hour
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function MIN_COOLDOWN() external view returns (uint256 _cooldown);

  /**
   * @notice The longest cooldown
   * @return _cooldown 3 days
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function MAX_COOLDOWN() external view returns (uint256 _cooldown);

  /**
   * @notice The role that proposes prices
   * @return _role keccak256('REPORTER_ROLE')
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function REPORTER_ROLE() external view returns (bytes32 _role);

  /**
   * @notice The role that accepts prices
   * @return _role keccak256('CHECKER_ROLE')
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function CHECKER_ROLE() external view returns (bytes32 _role);

  /**
   * @notice The portfolio
   * @return _portfolio The portfolio, or zero for none
   */
  function portfolio() external view returns (address _portfolio);

  /**
   * @notice The cash account when there is no portfolio
   * @return _custodianAccount The account
   */
  function custodianAccount() external view returns (address _custodianAccount);

  /**
   * @notice The time between cut-offs
   * @return _periodLength In seconds
   */
  function periodLength() external view returns (uint256 _periodLength);

  /**
   * @notice The time between a proposal and its execution
   * @return _cooldown In seconds
   */
  function cooldown() external view returns (uint256 _cooldown);

  /**
   * @notice The oldest report that may execute
   * @return _maxReportAge In seconds
   */
  function maxReportAge() external view returns (uint256 _maxReportAge);

  /**
   * @notice The redemption gate's level
   * @return _gateBps In basis points of all shares; zero is off
   */
  function redemptionGate() external view returns (uint256 _gateBps);

  /**
   * @notice The fee model
   * @return _feeModel The fee model, or zero for none
   */
  function feeModel() external view returns (address _feeModel);

  /**
   * @notice The high-water mark
   * @return _mark Assets per 1e18 share units
   */
  function mark() external view returns (uint256 _mark);

  /**
   * @notice When the mark last moved
   * @return _at The time
   */
  function markMovedAt() external view returns (uint256 _at);

  /**
   * @notice The performance fee paid since the mark last moved, which a soft hurdle's catch-up counts
   * @return _paid Assets per 1e18 share units
   */
  function paidSinceMark() external view returns (uint256 _paid);

  /**
   * @notice When a fee was last charged
   * @return _at The time
   */
  function lastFeeAt() external view returns (uint256 _at);

  /**
   * @notice The last cut-off
   * @return _lastCutoff When it was
   */
  function lastCutoff() external view returns (uint256 _lastCutoff);

  /**
   * @notice The proposal on the table
   * @return _proposal The proposal; its `period` is 0 with nothing on the table
   */
  function proposal() external view returns (Proposal memory _proposal);

  /**
   * @notice Whether this desk can settle: it holds the vault's SETTLER_ROLE
   * @return _wired True when it does
   */
  function isWired() external view returns (bool _wired);

  /**
   * @notice The hash `accept` takes for a proposal
   * @param _proposal The proposal
   * @return _hash The hash
   */
  function hashOf(
    Proposal memory _proposal
  ) external pure returns (bytes32 _hash);
}
