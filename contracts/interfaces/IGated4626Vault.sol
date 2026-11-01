// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';

/**
 * @title IGated4626Vault
 * @notice ERC-4626 vault whose shares are a policy-gated token. Deposits and mints arrive at the hook as MINT to the
 *         receiver; withdrawals and redemptions as BURN from the owner, with the caller as operator. The asset leg is
 *         an ordinary ERC-20 transfer and is not hooked
 * @dev `max*` express the gating: `maxDeposit` / `maxMint` are 0 when paused or when a mint of a very large amount to
 *      `receiver` would be rejected (identity, freeze, the holder caps); `maxRedeem` is the unfrozen balance, or 0 when
 *      paused or when a burn of nothing from `owner` would be rejected (identity, freeze, lockup). The mint probe is above
 *      any minimum position up to `type(uint128).max` and the burn probe is empty, so such a minimum does not read as a
 *      block: a deposit or
 *      redemption that would leave dust reverts when it executes. A rule that bounded the size of a position (a supply
 *      cap, a maximum balance) would refuse the mint probe and zero `maxDeposit` and `maxMint`.
 *      `maxWithdraw` is `convertToAssets(maxRedeem, Floor)`. `preview*` stay pure conversions. Share
 *      supply moves only through deposits and redemptions: the issuer `mint` / `burn` primitives revert. A payer other
 *      than the receiver, and a receiver of redemption cash other than the owner, must pass the token's policy
 *      (`IGatedVaultBase`); the `max*` views name one account and cannot say so.
 *
 *      With a `Portfolio` plugged the vault holds no working money: deposits go on to it, and withdrawals raise from it.
 *      `totalAssets()` is `min(pricedValue() − feesOwed, last + last × elapsed × maxRate)`, with the subtraction stopping at
 *      zero: losses count at once, gains are limited and none count again in the same block, so a donation cannot jump the
 *      price. Deposits and withdrawals move `last` by exactly their amount. While `priceFresh()` is false `totalAssets()` is
 *      the last counted value and deposits and withdrawals stop. While the value net of fees reads nothing, although
 *      holders have a value counted, `totalAssets()` reads zero, nothing is written down and deposits and withdrawals stop,
 *      so the value can come back under the limit. A count that finds the value fallen by more than half closes deposits for
 *      good, as a write-off does. With no shares nothing is anyone's: `totalAssets()` is zero, so the next
 *      investor buys at par and the mark restarts there, and whatever is left counts for them under the limit.
 *      `maxWithdraw` and `maxRedeem` are limited by what the portfolio can raise
 */
interface IGated4626Vault {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when the value is counted, which every deposit and withdrawal does first
   * @param _counted The value counted, before the fee
   * @param _fee The fee charged on it
   */
  event Accrued(uint256 _counted, uint256 _fee);

  /**
   * @notice Emitted when fees owed are paid
   * @param _recipient The fee model's recipient
   * @param _assets The assets paid
   */
  event FeesCollected(address indexed _recipient, uint256 _assets);

  /**
   * @notice Emitted when the fee model changes
   * @param _feeModel The fee model
   */
  event FeeModelSet(address indexed _feeModel);

  /**
   * @notice Emitted when the limit on counted gains changes
   * @param _maxRateBps The most the counted value may rise in a year, in basis points
   */
  event MaxRateSet(uint256 _maxRateBps);

  /**
   * @notice Emitted when the portfolio changes
   * @param _portfolio The portfolio
   */
  event PortfolioSet(address indexed _portfolio);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when charging or collecting fees with no fee model
  error Gated4626Vault_NoFeeModel();

  /// @notice Thrown when something needs a portfolio and none is plugged
  error Gated4626Vault_NoPortfolio();

  /**
   * @notice Thrown when a component is not attested in the registry this vault names
   * @param _target The component
   */
  error Gated4626Vault_NotAttested(address _target);

  /// @notice Thrown when the portfolio being replaced still holds value or has an adapter on its list
  error Gated4626Vault_PortfolioNotEmpty();

  /**
   * @notice Thrown when a portfolio is another vault's, holds another asset, or accepts reported adapters. On an instant
   *         vault a stale price is free money for whoever notices first
   * @param _portfolio The portfolio
   */
  error Gated4626Vault_PortfolioRefused(address _portfolio);

  /**
   * @notice Thrown when a limit on counted gains is above the ceiling, which is there so the arithmetic cannot overflow
   * @param _maxRateBps The limit
   */
  error Gated4626Vault_RateTooHigh(uint256 _maxRateBps);

  /**
   * @notice Thrown when the caller may not change the limit that way
   * @param _caller The caller
   */
  error Gated4626Vault_Unauthorized(address _caller);

  /// @notice Thrown when plugging a portfolio with no limit on counted gains
  error Gated4626Vault_ZeroRate();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Initializes a vault proxy
   * @param _asset The underlying asset
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
    string calldata _name,
    string calldata _symbol,
    address _admin,
    address _guardian,
    address _registry,
    address _hook,
    IComplianceRule[] memory _initialRules
  ) external;

  /**
   * @notice Brings the counted value up to date, charging any fee
   * @dev Anyone. Every deposit and withdrawal does this first
   */
  function accrue() external;

  /**
   * @notice Pays fees owed to the fee model's recipient, from the portfolio's idle money
   * @dev Anyone, while not paused. Pays what idle money allows
   */
  function collectFees() external;

  /**
   * @notice Plugs a fee model
   * @dev DEFAULT_ADMIN_ROLE. Needs a portfolio. The model must be attested as FEE_MODEL. Fees are charged only on gains that
   *      have passed the rate limit. The first plug starts the mark at the last counted price, or at par if that is lower, so
   *      a gain made before it is not charged
   * @param _feeModel The fee model
   */
  function setFeeModel(
    address _feeModel
  ) external;

  /**
   * @notice Changes the limit on counted gains
   * @dev DEFAULT_ADMIN_ROLE sets anything up to the ceiling; GUARDIAN_ROLE may only lower it
   * @param _maxRateBps The most the counted value may rise in a year, in basis points; at most 1e9
   */
  function setMaxRate(
    uint256 _maxRateBps
  ) external;

  /**
   * @notice Plugs a portfolio, or replaces one that has been emptied with `migrateTo`
   * @dev DEFAULT_ADMIN_ROLE. It must be attested as PORTFOLIO, be this vault's, hold this asset and refuse reported
   *      adapters. The one it replaces must have no adapter on its list and hold nothing, so an adapter that cannot be read
   *      has to be written off first. The vault's money goes to the new one and counts at once, so a first plug starts from
   *      what the vault held. A replacement keeps the price and the limit's clock: the next count allows what it would have
   *      allowed anyway, at the rate given here. A portfolio that has written off an adapter leaves the vault exit-only for
   *      good, whichever portfolio follows
   * @param _portfolio The portfolio
   * @param _maxRateBps The most the counted value may rise in a year, in basis points; not zero, and at most 1e9
   */
  function setPortfolio(
    address _portfolio,
    uint256 _maxRateBps
  ) external;

  /**
   * @notice The portfolio
   * @return _portfolio The portfolio; zero while the vault keeps its own money
   */
  function portfolio() external view returns (address _portfolio);

  /**
   * @notice The fee model
   * @return _feeModel The fee model, or zero for none
   */
  function feeModel() external view returns (address _feeModel);

  /**
   * @notice The most the counted value may rise in a year
   * @return _maxRateBps In basis points
   */
  function maxRate() external view returns (uint256 _maxRateBps);

  /**
   * @notice The value last counted
   * @return _last In assets
   */
  function lastCounted() external view returns (uint256 _last);

  /**
   * @notice Fees charged and not yet paid
   * @return _assets In assets
   */
  function feesOwed() external view returns (uint256 _assets);

  /**
   * @notice The high-water mark
   * @return _mark Assets per 1e18 share units
   */
  function mark() external view returns (uint256 _mark);

  /**
   * @notice Whether deposits are closed for good, because a portfolio wrote off an adapter or a count found the value fallen
   *         by more than half. Someone depositing at the written-down price would otherwise take part of any recovery from
   *         the holders who bore the loss
   * @dev It reads true as soon as a count would find such a fall, and is for good once one has. A fall nobody counts, and
   *      that goes away, closes nothing. Several smaller falls do not add up
   * @return _exitOnly True when they are
   */
  function exitOnly() external view returns (bool _exitOnly);
}
