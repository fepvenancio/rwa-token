[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Vaults

# Gated4626Vault

An ERC-4626 vault whose shares are a gated token. An investor pays in an asset and gets shares in the same transaction, and hands shares back the same way. The vault keeps its own money, or invests it through a portfolio, and then limits how fast a rise in value can count towards the price.

- **contracts/vaults/Gated4626Vault.sol**
- upgradeable: **UUPS** behind a TokenProxy
- admin: **the main timelock**
- implementation attested as **IMPLEMENTATION**
- share decimals: **the asset's plus 6**
- management code: **Gated4626Management**

<a id="in-one-minute"></a>

> ### In one minute
>
> A vault is a shared pot. You put an asset in and receive shares that stand for your part of the pot. You hand the shares back and take your part out. ERC-4626 is the common standard for such vaults, so wallets and other contracts already know how to use this one. The shares are a gated token: creating, moving and destroying them goes through the same compliance checks as every other token in the system, and the vault reports refusals up front through `maxDeposit` and `maxRedeem`.
>
> On its own the vault holds the money and its price is its balance. With a [`Portfolio`](Portfolio.md) plugged, the money goes on to the portfolio, which can put it in other on-chain vaults. The price then follows the portfolio's value, with one difference that protects holders: a loss counts at once, a gain counts no faster than a yearly rate limit. A sudden rise, or someone sending money in, cannot be bought ahead of and cashed out in the same moment.
>
> Plugging a portfolio, the rate limit, the fee model and paying fees run in a second contract, [`Gated4626Management`](Gated4626Management.md), which the implementation creates and nobody can swap alone. Those four functions are called on this vault, and everything an investor calls runs on the vault itself.

<a id="how"></a>
## One deposit and one redemption

Deposits and redemptions are OpenZeppelin's `ERC4626Upgradeable` (version 5.3.0), with steps added around it. Every change to a share balance goes through the base token's single path, which asks the policy hook first. A deposit reaches the hook as a MINT to the receiver, a redemption as a BURN from the owner, and in both the caller is the operator, the account driving the movement. The asset moves as a plain ERC-20 transfer the hook does not see, which is why [`GatedVaultBase`](GatedVaultBase.md) checks a third party on that leg.

> **Diagram.** The steps of a deposit and of a redemption, in order. Deposit: count the value and charge any fee, with a portfolio only. Check assets against maxDeposit of the receiver, else ERC4626ExceededMaxDeposit. Compute shares with previewDeposit. If the payer is not the receiver, run the enforcement probe on the payer, else GatedVault_ThirdPartyNotEligible. Add assets to last, with a portfolio only. Pull the asset from the payer to the vault. Mint shares to the receiver through the hook, else ERC8473PolicyRejected, and emit Deposit. Send the asset on to the portfolio, with a portfolio only. Redemption: count the value and charge any fee, with a portfolio only. Check shares against maxRedeem of the owner, else ERC4626ExceededMaxRedeem. Compute assets with previewRedeem. If the receiver is not the owner, run the enforcement probe on the receiver, else GatedVault_ThirdPartyNotEligible. With a portfolio only, take assets off last, call raise on the portfolio, and pull the asset from the portfolio to the vault. If the caller is not the owner, spend its share allowance, else ERC20InsufficientAllowance. Burn the shares from the owner through the hook, else ERC8473PolicyRejected. Pay the asset from the vault to the receiver and emit Withdraw.
>
> **One transaction each way.** The asset comes in before the shares are minted and goes out after they are burned, in OpenZeppelin's order. Step 1 comes first so that the price a caller can read with a preview is the price it pays (`test_AFeeIsChargedBeforeADepositPrices`).

|  | No portfolio | With a portfolio |
|---|---|---|
| Where the money sits | In the vault. | In the portfolio, idle or sent on to its adapters. The vault holds no working money. |
| `totalAssets()` | The vault's balance of the asset. | The counted value, [below](#counting). |
| Money sent straight in | Moves the price at once (`test_ItsPriceIsTheBalance`). The virtual shares limit what that can gain an attacker ([below](#price)). | Counts only under the rate limit (`test_ADonationCannotJumpThePrice`, `test_ADonationCountsOnlyUnderTheLimit`). |
| `maxDeposit`, `maxMint` | The policy and the pause. | Also 0 while no price can be used, and for good after a write-off or a fall of more than half in one count. |
| `maxRedeem`, `maxWithdraw` | The policy, the pause and the unfrozen balance. | Also 0 while no price can be used, and limited to what the portfolio can raise. |
| `accrue()`, `setFeeModel` | Revert with `Gated4626Vault_NoPortfolio`. | Work as described below. |

<a id="counting"></a>
## How the value is counted, with a portfolio

The price of a share comes from `totalAssets()` and the share supply. With a portfolio plugged, `totalAssets()` is worked out like this:

```
net     = pricedValue() − feesOwed, stopping at zero
limit   = last + last × (time since last was counted) × maxRate / (10,000 × 365 days)
counted = min(net, limit)

totalAssets() = counted − the fee due on it

While priceFresh() is false: totalAssets() = last
Else, under 1e6 share units: totalAssets() = 0
```

- **`pricedValue()`** is the portfolio's own answer: its idle money plus what each adapter, the portfolio's plug for one position, says that position is worth on chain.
- **`last`**, read with `lastCounted()`, is the value as last counted. Counting writes it, and deposits and withdrawals move it by exactly their amount (`test_DepositsAndWithdrawalsMoveLastByExactlyTheirAmount`).
- **`maxRate()`** is the limit's yearly rate, in basis points, applied simply from the last count, so with several counts in a year the counted value can rise by more than that rate. `setPortfolio` sets it and refuses zero (`Gated4626Vault_ZeroRate`). Both paths refuse more than 1e9 basis points a year (`Gated4626Vault_RateTooHigh(maxRateBps)`, `test_ARateAboveTheCeilingIsRefused`, `test_ARateAboveTheCeilingIsRefusedAndTheCeilingIsNot`), a ceiling there so the arithmetic cannot overflow (`testFuzz_NoRateTheAdminCanSetJamsTheVault`). `setMaxRate(maxRateBps)` changes it: `DEFAULT_ADMIN_ROLE` sets any value up to that, `GUARDIAN_ROLE` may set the present value or a lower one, including zero, and anyone else gets `Gated4626Vault_Unauthorized(caller)`. A change first counts at the outgoing rate (`test_ARateChangeCountsWhatTheOldRateAllowedFirst`), unless no price can be used: nothing can be counted then, so the new rate also covers the time since the last count.
- **`priceFresh()`** says whether every adapter can give a price right now, and that the money has not gone to a successor. While it is false, `totalAssets()` holds at `last`, the four `max*` read 0 so deposits and withdrawals stop, and `accrue()` does nothing. The limit's clock runs on, so when the price returns a gain counts under the limit from before the outage (`test_DuringATargetOutageThePriceHoldsAndDealingStops`).
- **A read of nothing** is the other time no price can be used: the value net of fees reads zero, although a value was counted and `1e6` share units or more exist (`test_WithAMillionShareUnitsAReadOfNothingStillStopsDealing`). `totalAssets()` reads 0, because that is the read, and the four `max*` read 0, so a holder cannot sell for nothing and nobody buys for nothing. `accrue()` writes nothing, so when the value returns it counts under the limit from `last` (`test_AReadOfNothingIsNotWrittenDownAndDealingStops`, `test_WhenTheValueReturnsThePriceIsWhatItWas`). A value that is low and not nothing counts at once (`test_ALowReadIsStillALoss`), and [a fall of more than half closes deposits](#exit-only).
- **With no shares**, or fewer than `1e6` share units, nothing is anyone's, whatever the portfolio holds. One unit of the asset buys `1e6` share units at par, so between them such dust owns less than that unit, and a count on a few such units could price them up to a million times above par and move the mark where no later gain reaches it. While the price can be read `totalAssets()` is 0, so the next investor buys at par, or up to half below it when the dust is close to `1e6` units, however little or much was left (`testFuzz_WithNoSharesAnythingLeftStillStrikesAtPar`, `testFuzz_DustBelowAMillionUnitsKeepsThePrincipalAndTheFee`), and the mark restarts at par (`test_WithNoSharesNothingCounts`, `test_WhenAHolderAloneLeavesOneShareUnitTheMarkStaysAtPar`). A read of nothing then stops nothing (`test_WithDustAReadOfNothingDoesNotStopDeposits`), and the dust can still be redeemed, for nothing (`test_TheLastShareUnitsCanStillBeRedeemed`). What was left counts for that investor under the limit. Shares left behind, `1e6` units or more, are not this case (`test_AMillionShareUnitsStillCount`). A count before the entry moves the mark to the price after what it actually charged, so the next investor is not charged a performance fee on what they pay in when the count charged something, to within a few raw units, even when a charge rounds to nothing: that costs the fee recipient and not the investor. Inside a hurdle nothing is charged and the mark stays below the price, so with a soft hurdle an investor who enters there later pays on the part between the mark and their entry (`test_WhenTheChargeRoundsToNoFeeTheMarkIsThePrice`, `test_TheMarkIsThePriceAfterWhatIsActuallyCharged`, `testFuzz_DustSharesAfterALossDoNotChargeTheNextInvestorOnPrincipal`).

Counting happens at the start of every `deposit`, `mint`, `withdraw` and `redeem`, in `collectFees`, `setMaxRate` and `setFeeModel`, and whenever anyone calls `accrue()`. Each time a price can be used it writes `last`, restarts the clock and emits `Accrued(counted, fee)`.

> **Diagram.** A year of counted value, with a limit of 10 percent a year and 1,000 counted at month 0. Until month 3 the priced value and the counted value are 1,000 while the limit climbs. At month 3 a gain lifts the priced value to 1,060; the counted value jumps to the limit, 1,025, then rises along the limit and reaches 1,060 at about month 7. At month 9 a loss takes the priced value to 1,010 and the counted value falls with it at once. An accrue call at month 9 writes last as 1,010 and restarts the limit from there. At month 10 the priced value returns to 1,060; the counted value jumps only to the new limit, about 1,018, and rises to about 1,035 by month 12.
>
> **Losses at once, gains at a limited rate.** The picture has no fees, and nobody counts between month 0 and month 9. The limit runs from when the value was last counted, so headroom builds in a quiet stretch: the jump at month 3 is that headroom. Counting restarts the limit from the counted value, which is why it starts low again after month 9.

Three things follow from the formula, and the tests pin each. In one block a gain counts once: after counting, the limit equals `last`, so a second count adds nothing (`test_NoGainCountsAgainInTheSameBlock`), and a round trip in one block never profits (`testFuzz_ARoundTripInOneBlockNeverProfits`). A loss in the priced value lowers the answer straight away (`test_ALossCountsAtOnce`). And the counted value does not pass the priced value however long it waits (`test_ADonationCountsOnlyUnderTheLimit`).

Between countings the limit is simple, not compound. At 10% with money waiting above the limit, one count after a year gives 1,100 on 1,000, and counting at the half year as well gives 1,102.50.

<a id="plugging"></a>
## Plugging a portfolio, and replacing one

`setPortfolio(portfolio, maxRateBps)`, called by `DEFAULT_ADMIN_ROLE`, does both. It checks, in this order: the rate is not zero (`Gated4626Vault_ZeroRate`) or above the ceiling (`Gated4626Vault_RateTooHigh(maxRateBps)`); the registry attests the address as `PORTFOLIO` (`Gated4626Vault_NotAttested(portfolio)`); the portfolio names this vault and its asset and refuses reported adapters (`Gated4626Vault_PortfolioRefused(portfolio)`); and any portfolio already plugged has no adapter on its list and prices at zero (`Gated4626Vault_PortfolioNotEmpty`), so a position that cannot be read has to be written off first (`test_APortfolioWithAnAdapterOnItsListCannotBeReplaced`). On a first plug it starts the clock. Then it adds the vault's own asset balance to `last`, emits `PortfolioSet(portfolio)` and `MaxRateSet(maxRateBps)`, and sends that balance to the portfolio.

### First plug

The vault's balance goes to the portfolio and counts in `last` at once, so the price of a share does not move (`test_AFirstPlugStartsFromTheMoneyTheVaultHeldAndKeepsThePrice`). From the next deposit on, the vault forwards what it receives.

### Replacement

The money moves first: the outgoing portfolio's `migrateTo(successor)` sends its idle money to the successor, and it refuses while adapters are installed. `last` already counts that money, so the price holds (`test_AReplacementKeepsThePrice`). A replacement keeps the limit's clock, so the next count allows what it would have allowed anyway, at the rate the call names (`test_AReplacementKeepsWhatTheLimitHadAllowed`). What the successor holds beyond that is treated as a donation, and counts only under the limit (`test_ADonationToTheNewPortfolioCountsOnlyUnderTheLimit`). The two calls belong in one timelock batch: see [the limits](#limits).

`setPortfolio` needs an attested address, and an account without code is not attested, so the setting cannot return to zero. Once plugged, a vault keeps a portfolio.

<a id="exit-only"></a>
## Exit-only, after a write-off or a large fall

If an adapter stops giving a price and the money behind it looks lost, or its target stops paying it out, the timelock can call `writeOffAdapter(adapter)` on the [`Portfolio`](Portfolio.md). The adapter leaves the list, so its value leaves `pricedValue()` and the loss counts at once. From then on `exitOnly()` reads true, `maxDeposit` and `maxMint` read 0, and holders can still redeem at the written-down price, up to the liquid money (`test_AfterAWriteOffTheVaultIsExitOnly`, `test_TheLossCountsAndHoldersExit`). A write-off that leaves the priced value at or below `feesOwed` is a read of nothing: `maxRedeem` and `maxWithdraw` read 0 until money comes back, and `maxDeposit` and `maxMint` stay 0 because the vault is exit-only for good.

The state survives a replacement: when `setPortfolio` finds that the outgoing portfolio has written something off, it keeps the answer in the vault's own storage, because a successor starts clear (`test_AReplacementKeepsTheExitOnlyState`). No function clears it.

A count that finds the value, net of the fees owed, below half of the last counted value does the same (`test_AFallOfMoreThanHalfClosesDepositsForGood`), a fall of exactly half does not (`test_AFallOfExactlyHalfLeavesDepositsOpen`), and it carries over to a replacement (`test_AReplacementKeepsItClosed`). The fall is measured against the last counted value, so money that holders take out is no fall (`test_AHolderLeavingIsNotAFall`), and with no shares nothing is (`test_TheLastHolderLeavingIsNotAFall`). `exitOnly()` reads true and `maxDeposit` and `maxMint` read 0 as soon as a count would find such a fall, while `maxRedeem` and `maxWithdraw` stay open. A read of nothing is not a count: it stops dealing and writes nothing, so it closes nothing and `exitOnly()` reads false through it (`test_AReadOfNothingDoesNotReadAsClosed`), unless the vault had already closed (`test_AClosedVaultStillReadsClosedThroughAReadOfNothing`). The close is stored by the count itself, which anyone can make with `accrue()`, and a deposit's revert writes nothing, so a fall nobody counts, and that goes away, closes nothing (`test_AFallNobodyCountedClosesNothing`). A holder can still leave at the price the fall left, and that withdrawal is such a count (`test_AHolderLeavingAfterAFallCountsItAndPaysThatPrice`). The count that closes them emits `DepositsClosed(counted, last)`, the value it found and the value counted before it, ahead of its `Accrued(counted, fee)`. It emits that once: a further fall says nothing new (`test_WhenAFallClosesDeposits_TheCountAnnouncesItOnce`), and a fall of exactly half says nothing (`test_AFallOfExactlyHalfIsNotAnnounced`). So the event can come later than `exitOnly()`, which reads true as soon as a count would find the fall. A write-off closes deposits by itself and says so in the portfolio's `AdapterWrittenOff`. It brings a `DepositsClosed` only if a count then finds a fall of more than half.

The reason is fairness to the holders who took the loss. If the money comes back later, someone who deposited at the written-down price would take part of a recovery that belongs to them.

<a id="fees"></a>
## Fees

A [`FeeModel`](FeeModel.md) is optional and needs a portfolio. `setFeeModel(feeModel)`, called by `DEFAULT_ADMIN_ROLE`, requires a model attested as `FEE_MODEL` (`Gated4626Vault_NotAttested(feeModel)`), counts first, and emits `FeeModelSet(feeModel)`. The first plug starts the high-water mark, the price a performance fee is measured from, at the last counted price, or at par if that is lower. Read it with `mark()`, in assets per `1e18` share units. So a gain made before the plug is not charged, and getting back to par after a loss pays no performance fee. The mark is the vault's, not an investor's: one who bought above it before the plug pays on the climb back to their own price (`test_TheFirstPlugStartsTheMarkAtTheCurrentPrice`, `test_AFirstPlugBelowParStartsTheMarkAtPar`, `test_AFirstPlugDuringAReadOfNothingStartsTheMarkAtTheLastPrice`).

1. **Charged while counting.** Each count asks the model to quote on the counted value, so a fee falls only on gains that have passed the rate limit (`test_ADonationDoesNotPayAPerformanceFeeUntilItCounts`). The fee comes off `totalAssets()` and is added to `feesOwed()`. The vault keeps what the model returns: the mark, its clock and `paidSinceMark()`, the performance fee charged since the mark last moved. So a count inside a soft hurdle's catch-up leaves the mark where it was, and the count that completes the catch-up charges what one count would have (`test_ASoftHurdleCarriesItsCatchUpAcrossCounts`). Anyone can call `accrue()`, and that cannot shorten the catch-up.
2. **Owed, and not counted again.** The money is still in the portfolio, so `net` leaves out `feesOwed`. At 2% a year on 1,000, a year later `totalAssets()` reads 980. Once something counts, `feesOwed()` reads 20 and the next year's 2% falls on 980 (`test_TheManagementFeeAccruesWithTime`, `test_FeesOwedAreNotCountedAgain`).
3. **Paid when collected.** `collectFees()`, which anyone can call, counts and then pays the model's `RECIPIENT()` the smaller of `feesOwed` and the portfolio's idle money, and emits `FeesCollected(recipient, assets)`. It does not raise money from adapters, and the price does not move (`test_FeesArePaidFromIdleMoneyAndThePriceDoesNotMove`, `test_FeesPayOnlyWhatIdleMoneyAllows`). With no model it reverts with `Gated4626Vault_NoFeeModel`, and while paused with `EnforcedPause` (`test_FeesAreNotPaidWhilePaused`).

With no shares both clocks restart and the mark starts at par, so the first investors pay neither on their principal nor for time before they arrived (`test_WithNoSharesTheFirstInvestorsDoNotPayForTimeBeforeThey`, `test_WhenTheLastHolderLeavesDustTheNextInvestorPaysNoFeeOnPrincipal`). Fewer than `1e6` share units count the same way: the mark starts at par (`test_WhenAHolderAloneLeavesOneShareUnitTheMarkStaysAtPar`), and the count that sets it restarts both clocks, which the vault has no getter to show, and returns `paidSinceMark()` to zero, so the next investor pays no catch-up on their principal (`test_WhenEveryoneHasLeftWhatWasPaidRestarts`). After a near-total loss the fees owed can exceed the value, which is a read of nothing: `totalAssets()` reads 0, nothing reverts and dealing stops (`test_ALossBelowTheFeesOwedReadsAsZeroAndNothingReverts`). How a fee is computed is on the [`FeeModel`](FeeModel.md) page.

<a id="max"></a>
## The `max*` functions

ERC-4626 lets a vault say how much an account may deposit or redeem right now, and the vault's own functions check the same numbers. Here they carry the policy, through the probes explained on [`GatedVaultBase`](GatedVaultBase.md): pretend movements that run the checks without the write. What they cannot say, a second account above all, is explained there too.

| Function | Reads 0 when | Otherwise |
|---|---|---|
| `maxDeposit(receiver)`, `maxMint(receiver)` | The hook or the pause would refuse a mint of `type(uint128).max` to `receiver`; or no price can be used; or the vault is exit-only. | `type(uint256).max` |
| `maxRedeem(owner)` | The hook or the pause would refuse a burn of 0 from `owner`; or no price can be used. | The unfrozen balance, `balanceOf(owner) − getFrozenTokens(owner)` or 0 when the frozen amount is the larger. With a portfolio, cut down to what `liquidAssets()` can pay when the position is worth more than that. |
| `maxWithdraw(owner)` | `maxRedeem(owner)` does. | `maxRedeem(owner)` converted to assets, rounded down. |

- **Redeeming the maximum works.** `redeem(maxRedeem(owner))` succeeds and one more share reverts, with and without a portfolio, apart from the minimum-position case below (`test_WhenRedeemingMaxRedeem_ItSucceedsAndOneMoreReverts`, `test_RedeemingMaxRedeemSucceedsAndOneMoreReverts`). A position that is wholly liquid is not cut down by rounding (`testFuzz_WhenAHoldersWholePositionIsLiquid_MaxRedeemIsAllOfIt`).
- **Rounding down for `maxWithdraw`.** `withdraw` rounds the shares it burns up. Deriving `maxWithdraw` from `maxRedeem` with floor rounding means it does not promise assets that `withdraw` could not deliver (`test_WhenThePriceMoves_WithdrawingMaxWithdrawAlwaysSucceeds`).
- **Where `maxRedeem` can overstate.** With a minimum position set, if a remainder below the minimum would stay behind, whether a frozen amount or, with a portfolio, the part `liquidAssets()` cannot pay, `redeem(maxRedeem(owner))` reverts with `ERC8473PolicyRejected(BELOW_MIN_POSITION)`: the minimum judges the whole balance, `maxRedeem` only the part it can pay. A test shows the frozen case (`test_WhenAFrozenRemainderBelowTheMinimumWouldStay_RedeemingAllOfMaxRedeemReverts`).
- **Whose call it is.** The burn probe names the owner as the operator, while a real redemption's operator is its caller. No check on the token and no shipped rule reads the operator, so the probe and the redemption get the same answer whoever calls.

<a id="checks"></a>
## Who is checked

A vault's rule list belongs to its product. The `vault4626` and `vault4626-invest` profiles list [`CredentialRule`](CredentialRule.md) and [`HolderRestrictionRule`](HolderRestrictionRule.md). The demo's `full` profile lists `CredentialRule`, [`MinPositionRule`](MinPositionRule.md), `HolderRestrictionRule` and [`FundHoldersRule`](FundHoldersRule.md), in that order. With that longer list, each call checks these accounts:

| Call | Account | What must hold |
|---|---|---|
| `deposit`, `mint` | receiver of the shares | An `ACTIVE` credential that the vault's policy accepts. Its address not frozen. At least the minimum position afterwards, if one is set. Room in the fund if it would be a new investor. |
| `deposit`, `mint` | caller, who pays | Itself the receiver, or passes the enforcement probe. It needs an allowance on the asset for the vault. |
| `withdraw`, `redeem` | owner of the shares | A credential that is not blocked or missing: a lapsed or exit-only one can still redeem. Its address not frozen and not locked up. Nothing or at least the minimum left. No more than its unfrozen balance. |
| `withdraw`, `redeem` | caller | The owner's share allowance, unless it is the owner. The policy does not judge a spender. |
| `withdraw`, `redeem` | receiver of the asset | Itself the owner, or passes the enforcement probe. |

`FundHoldersRule` does not cap a redemption. It refuses every movement, in either direction, with `NOT_FUND_CLASS` if the vault is not a registered class of the [`Fund`](Fund.md) or its list names a fund rule the fund has replaced.

<a id="pause-freeze"></a>
## Pause and freeze

Three tools stop shares from moving, and each shows up differently. The guardian pauses the whole vault. The agent can freeze an amount of one holder's shares on the token itself, or freeze or lock a holder's address in `HolderRestrictionRule`. A max of 0 means the call reverts with the matching error, such as `ERC4626ExceededMaxDeposit(receiver, assets, 0)`, for any amount above zero.

| Situation | Deposit, mint | Withdraw, redeem | Share transfer |
|---|---|---|---|
| Paused (`pause()` by `GUARDIAN_ROLE`) | The max is 0: `ERC4626ExceededMaxDeposit` or `ERC4626ExceededMaxMint` | The max is 0: `ERC4626ExceededMaxRedeem` or `ERC4626ExceededMaxWithdraw` | `ERC8473PolicyRejected` with `PAUSED` |
| An amount frozen on the owner (`setFrozenTokens`) | Not affected | Only the unfrozen part. Above it, the same two errors with the unfrozen figure as the max. | Above the unfrozen balance: `ERC7943InsufficientUnfrozenBalance`. Above the whole balance: `ERC20InsufficientBalance`. |
| Address frozen (`setFrozen` in the rule) | As receiver, the max is 0 (`RECEIVER_FROZEN`) | As owner, the max is 0 (`SENDER_FROZEN`) | `ERC8473PolicyRejected` with `SENDER_FROZEN` or `RECEIVER_FROZEN` |
| Locked up (`setLockup` in the rule) | Not affected | The max is 0 (`LOCKED_UP`) | `ERC8473PolicyRejected` with `LOCKED_UP` |

While paused, the agent's `forcedTransfer` and `setFrozenTokens` still work, and so does `accrue()`, which has no pause check. `collectFees()` reverts with `EnforcedPause`.

<a id="price"></a>
## Price, previews and the decimals offset

The share price follows from OpenZeppelin's formulas, which add 10<sup>6</sup> virtual shares and one virtual unit of the asset that nobody owns. `totalAssets()` here means whichever figure the vault's mode gives.

```
shares = assets × (totalSupply + 10^6) / (totalAssets + 1)
assets = shares × (totalAssets + 1) / (totalSupply + 10^6)
```

| Call | Converts | Rounds |
|---|---|---|
| `deposit`, `previewDeposit` | assets to shares | down: the receiver gets slightly fewer shares |
| `mint`, `previewMint` | shares to assets | up: the caller pays slightly more |
| `withdraw`, `previewWithdraw` | assets to shares | up: slightly more shares are burned |
| `redeem`, `previewRedeem` | shares to assets | down: slightly fewer assets are paid |

The previews are arithmetic only. They tell you what the formula gives, and the max functions tell you what the policy allows.

**Why an offset of 6.** `_decimalsOffset()` returns 6, which gives the formula its 10<sup>6</sup> virtual shares. Without them, the first depositor could deposit one unit, then send assets straight to the vault so that one share is worth so much that the next deposit rounds down to zero shares and its assets fall to the existing shares. A fuzz test runs that attack on a vault with no portfolio: the attacker does not get back more than it put in, and the victim loses at most about the donation divided by 10<sup>6</sup> (`test_WhenAnAttackerFrontRunsWithADonation_TheAttackerLosesAndTheVictimIsProtected`).

**Shares have 6 more decimals than the asset.** With a 6-decimal asset, shares have 12. A first deposit of 1,000 asset units (`1000e6`) into an empty vault mints `1e15` raw shares, which is 1,000 shares, and redeeming them returns exactly `1000e6`. A minimum position is set in shares, so it counts in those 12 decimals.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `deposit(assets, receiver)` | Anyone who has approved the vault on the asset and passes the third-party check | Takes `assets` from the caller and mints the shares they buy, rounded down, to `receiver`. Emits `Deposit`. Reverts `ERC4626ExceededMaxDeposit` above the max. |
| `mint(shares, receiver)` | Same | Mints exactly `shares` to `receiver` and takes what they cost, rounded up. Reverts `ERC4626ExceededMaxMint` above the max. |
| `withdraw(assets, receiver, owner)` | The owner, or a spender with the owner's share allowance | Burns the shares worth `assets`, rounded up, from `owner` and pays `assets` to `receiver`. Emits `Withdraw`. Reverts `ERC4626ExceededMaxWithdraw` above the max. |
| `redeem(shares, receiver, owner)` | Same | Burns `shares` from `owner` and pays what they are worth, rounded down, to `receiver`. Reverts `ERC4626ExceededMaxRedeem` above the max. |
| `maxDeposit`, `maxMint`, `maxWithdraw`, `maxRedeem` | Anyone (read-only) | What the policy and the portfolio allow right now, [above](#max). |
| `previewDeposit`, `previewMint`, `previewWithdraw`, `previewRedeem`, `convertToShares`, `convertToAssets` | Anyone (read-only) | Arithmetic on `totalAssets()` and the share supply. They do not ask the hook. |
| `totalAssets()`, `asset()`, `decimals()` | Anyone (read-only) | The value behind the price, the asset's address, and the asset's decimals plus 6. |
| `setPortfolio(portfolio, maxRateBps)` | `DEFAULT_ADMIN_ROLE` | Plugs or replaces a portfolio ([above](#plugging)). Errors: `Gated4626Vault_ZeroRate`, `Gated4626Vault_RateTooHigh(maxRateBps)`, `Gated4626Vault_NotAttested(target)`, `Gated4626Vault_PortfolioRefused(portfolio)`, `Gated4626Vault_PortfolioNotEmpty`. Events: `PortfolioSet`, `MaxRateSet`. |
| `setMaxRate(maxRateBps)` | `DEFAULT_ADMIN_ROLE` up to 1e9 basis points a year; `GUARDIAN_ROLE` at or below the present one | Counts at the outgoing rate when a price can be used, then changes the limit on counted gains. Emits `MaxRateSet`. Otherwise `Gated4626Vault_Unauthorized(caller)`, and `Gated4626Vault_RateTooHigh(maxRateBps)` above the ceiling. |
| `setFeeModel(feeModel)` | `DEFAULT_ADMIN_ROLE` | Plugs a fee model ([above](#fees)). Errors: `Gated4626Vault_NoPortfolio`, `Gated4626Vault_NotAttested(target)`. Emits `FeeModelSet`. |
| `accrue()` | Anyone | Counts the value and charges any fee; does nothing while no price can be used. Emits `Accrued(counted, fee)` when it counts, after `DepositsClosed(counted, last)` if that count closes deposits. Reverts `Gated4626Vault_NoPortfolio` with none plugged. |
| `collectFees()` | Anyone | Pays fees owed from the portfolio's idle money. Emits `FeesCollected`. Reverts `Gated4626Vault_NoFeeModel` with no model, and `EnforcedPause` while paused. |
| `MANAGEMENT_LOGIC()` | Anyone (read-only) | The second contract, [`Gated4626Management`](Gated4626Management.md), which four functions are handed to. An immutable of the implementation. |
| `portfolio()`, `feeModel()`, `maxRate()`, `lastCounted()`, `feesOwed()`, `mark()`, `paidSinceMark()`, `exitOnly()` | Anyone (read-only) | The state described above. `portfolio()` and `feeModel()` read zero when none is plugged. |
| `mint(address, uint256)`, `burn(address, uint256)` | Anyone, to no effect | The base token's issuer functions. They revert with `GatedVault_Unsupported`, even for a holder of `MINTER_ROLE` or `BURNER_ROLE` ([`GatedVaultBase`](GatedVaultBase.md)). |
| `transfer`, `transferFrom`, `approve`, `permit` | `transfer`: a holder. `transferFrom`: a spender with the holder's allowance. `approve`: any account. `permit`: anyone with the owner's signature. | Ordinary share transfers and allowances. `transfer` and `transferFrom` are each a TRANSFER through the hook; `approve` and `permit` only set allowances. With a holder's `permit` and signed exit, [`SignedExit`](SignedExit.md) redeems to the receiver the holder signed, while a relayer pays the gas. |
| `forcedTransfer`, `setFrozenTokens` | `AGENT_ROLE` | The base token's enforcement tools, on shares: move shares from any holder, and freeze part of a balance. |
| `pause()`, `unpause()` | `GUARDIAN_ROLE`; the main timelock or the recovery timelock | Stop and restart every share movement except a forced transfer. |
| `initialize` | Once, in the transaction that creates the proxy | Takes the asset, name, symbol, admin, guardian, registry, hook and rules. Sets the asset and the base token, installs the hook and the vault's rule list. [`ProxyDeployer`](ProxyDeployer.md) makes this call. |
| `supportsInterface`, `templateId()` | Anyone (read-only) | ERC-165, adding ERC-4626 to what the base token reports; and `keccak256("Gated4626Vault")`, which an upgrade must match. |

`setPortfolio`, `setMaxRate`, `setFeeModel` and `collectFees` are named here and run in [`Gated4626Management`](Gated4626Management.md), on this vault's storage, with its caller. The storage and the counting are in [`Gated4626Common`](Gated4626Common.md), which both contracts inherit. The rest is the base token's: roles, `installPolicy`, upgrades, `canTransfer`, `canTransferWithReason`, `canSend`, `canReceive` and `multicall`. See [`PolicyGatedERC20Upgradeable`](PolicyGatedERC20Upgradeable.md). The portfolio asks this vault's role table for `ALLOCATOR_ROLE` and for its other gates.

<a id="why"></a>
## Why it is built this way

- **OpenZeppelin's vault for the flows.** Rounding, events and the order of steps come from `ERC4626Upgradeable`. The vault adds the counting before each flow, the third-party check and the portfolio steps inside `_deposit` and `_withdraw`, the `max*` functions and `totalAssets()`. Both parents define `_update`, and the vault resolves it to the base token's version, so every share movement takes the hooked path.
- **A portfolio here must refuse reported adapters.** A reported value is a figure someone sent in, and it goes stale between reports. On a vault that deals instantly, a stale price is free money for whoever notices first, so `setPortfolio` refuses a portfolio whose `ACCEPTS_REPORTED()` is true. Reported values belong behind the [`Gated7540Vault`](Gated7540Vault.md), where a price is struck after requests close.
- **Losses at once, gains limited.** If a loss were held back, the first to leave would get out at the higher price and the rest would pay for it. If a gain counted at once, anyone could buy just before a rise they can see coming and sell straight after. The limit makes a gain arrive slowly, and a purchase counts first and so restarts the limit, which leaves no step in the price to buy ahead of.
- **Counting first.** Every flow counts before it prices, so a preview in the same block is what the call pays.
- **The policy shows through `max*`.** ERC-4626 expresses limits through these functions, and integrators read them before calling. A blocked account sees 0 instead of an unexplained revert, and the vault's own functions enforce the same answer.
- **Shares only through deposits and redemptions.** The issuer `mint` and `burn` revert, so the share supply does not grow without assets coming in. An invariant on a vault with no portfolio checks that the whole share supply converts to no more assets than the vault holds (`invariant_SharesAreAlwaysBacked`).
- **Attested code only.** The vault is a proxy: a small contract that keeps the address and the balances and runs shared code, its implementation. An upgrade (`UPGRADER_ROLE`, which the deployment gives to the main timelock) must target an implementation that the [`PolicyRegistry`](PolicyRegistry.md) attests, meaning an account with `ATTESTER_ROLE`, in a deployment the security council, has recorded its code hash, and that reports the same template id. Tests show the vault refusing attested `IntentToken` and `Gated7540Vault` implementations with `Templated_WrongTemplate`. An implementation that is not attested is refused before that, with `PolicyGated_NotAttested`.
- **Two contracts.** One contract's code is limited to 24,576 bytes. The four management functions, which no investor calls, are in a second contract, and that leaves this vault room under the limit. [The second contract's page](Gated4626Management.md) says what fixes it in place and what it costs.
- **No ETH.** There is no `receive` function. The one payable function is the inherited `upgradeToAndCall`, which only `UPGRADER_ROLE` can call and which refuses ETH when the upgrade carries no call. A test shows a plain ETH send reverting.

<a id="limits"></a>
## What it does not do

- **It does not value anything itself.** It takes `pricedValue()` and `priceFresh()` from the portfolio, which takes them from the adapters. The rate limit bounds how fast a wrong high price can count. A wrong low price counts at once, and any count writes it into `last`, which anyone can trigger with `accrue()`. Money coming back then counts only under the limit on that low figure: a value of 1,000 read once as 500 reads about 550 a year later at 10%. Deposits stay open at that price while the fall in one count is half or less, and close for good [beyond that](#exit-only). A read of nothing stops dealing, as above, but a donation that lifts the portfolio's priced value above `feesOwed` (one unit when nothing is owed) makes it a low read. That counts at once: the holders' value falls to that unit and climbs back only at `maxRate` from there, so the timelock has to raise the rate to bring it back. A stranger can do this with one unit more than the fees owed whenever a target reads nothing and is still fresh. The vault then takes no deposit at that price, so the stranger cannot buy shares from it (`test_AStrangersUnitDuringAReadOfNothingOpensNothing`). A donation of half the counted value or more does not close deposits, and shares can still be bought from a holder.
- **It does not make a replacement atomic.** `migrateTo` and `setPortfolio` belong in one timelock batch, and the contracts do not enforce that. If they are split, the outgoing portfolio gives no price from `migrateTo` on, so `totalAssets()` holds at `last`, the four `max*` read 0 and `accrue()` does nothing until the plug (`test_InTheGapThePriceHoldsAndDealingStops`). Money sent to the outgoing portfolio in that time holds up `setPortfolio` with `Gated4626Vault_PortfolioNotEmpty` until another `migrateTo` sends it on (`test_ADonationInTheGapCannotSetThePrice`). A plug that names the wrong portfolio reads as nothing, stops dealing and writes nothing down, so the money can still follow it (`test_APlugOfAnEmptyPortfolioStopsDealingUntilTheMoneyArrives`).
- **It does not queue exits.** `maxRedeem` is limited by `liquidAssets()`: idle money plus what the liquidity adapter, the one the allocator named for raising cash, can return. Beyond that a holder waits until the allocator brings money back, and whoever calls first is paid first (`test_WithNoLiquidityAdapter_ExitIsLimitedToIdleMoney`).
- **Exit-only closes the door to deposits, not to transfers.** Share transfers run as usual under the policy. No function reopens it, so new money after a close needs a new vault, unless the timelock upgrades the implementation.
- **The limit on a fall is on one count.** A fall of half or less leaves deposits open at that price, and several smaller falls do not add up when a count falls between them (`test_TwoSmallerFallsLeaveDepositsOpen`). Falls with no count between them are one fall.
- **A management fee too small to pay a unit at each count is not paid.** Every count restarts the fee clock and the fee rounds down, so under one raw unit is lost per count, and only one count a block matters. On a 2-decimal asset that is a cent a block: anyone calling `accrue()` every 12 seconds keeps a fund of up to about 2.6 million at 1% a year from paying any management fee (`test_ACountThatRoundsToNoFeeStillRestartsTheClock`). Holding the clock instead would charge that time to whoever arrives next (`test_NewMoneyDoesNotPayForTimeBeforeItArrived`).
- **Dust left on purpose costs the fee on one doubling.** A holder who leaves just under `1e6` share units, or mints that many into an empty vault for one raw unit, has the next investor pay as little as about half par with the mark at par, so the first doubling pays no performance fee. Investors lose nothing.
- **A fee model cannot be taken out.** `setFeeModel` needs an attested model, so the way to stop charging is an attested model with zero rates, which still names a recipient for the fees owed.
- **Money sent straight to the vault while a portfolio is plugged does not count.** It sits there until the next `setPortfolio`, which forwards it and adds it to `last` at once, outside the rate limit.
- **Dust and the investor cap.** An account that passes the probe can deposit 1 unit for a credentialed, empty receiver whose investor is not counted yet and take a fund investor slot, and shares sent to an exiting holder leave a remainder after an exit of the earlier exact balance. [`MinPositionRule`](MinPositionRule.md) closes the slot grab where it is listed with a non-zero minimum, and with a minimum set that exit reverts with `BELOW_MIN_POSITION` until the holder exits the current balance.

<a id="connected"></a>
## Connected to

- [GatedVaultBase](GatedVaultBase.md): The third-party check, the probes behind `max*`, and the reverting issuer functions.
- [Gated4626Management](Gated4626Management.md): The second contract: plugging a portfolio, the rate limit, the fee model and paying fees run there, on this vault's storage.
- [Gated4626Common](Gated4626Common.md): The storage and the counting the two contracts share.
- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): The base token the shares are: roles, freezes, pause and the hook path.
- [Portfolio](Portfolio.md): Where the money goes when one is plugged, and who may move it.
- [ERC4626Adapter](ERC4626Adapter.md): How a portfolio holds a position in another on-chain vault.
- [FeeModel](FeeModel.md): The quote behind each fee.
- [ComplianceHook](ComplianceHook.md): Runs the vault's rule list on every share movement and every probe.
- [SignedEntry](SignedEntry.md): Enters a vault from an investor's two signed messages, the entry and the cash, with a relayer paying the gas.
- [SignedExit](SignedExit.md): Redeems from a holder's signed exit and share permit, to the receiver the holder signed, with a relayer paying the gas.
- [Gated7540Vault](Gated7540Vault.md): The vault that deals in periods, for values that come from a report.
- [Where the money sits](../money.md): Every place an asset can be, across both vaults.

<a id="source"></a>
## Source and tests

- Contract: `contracts/vaults/Gated4626Vault.sol`, with `Gated4626Management.sol` and `Gated4626Common.sol`, interface `IGated4626Vault.sol`. The vault logic it inherits is OpenZeppelin's `ERC4626Upgradeable` from `@openzeppelin/contracts-upgradeable` 5.3.0.
- Tests: `Gated4626Vault.t.sol` (a vault with no portfolio: unit tests with a mocked hook, integration tests with the real hook, lockups and a minimum position, the donation attack, and invariants), `Gated4626VaultPortfolio.t.sol` (a real portfolio, adapter and outside vault: plugging, counting, write-offs and fees), `Gated4626Management.t.sol` (the wiring, direct calls, the hand-off and upgrades), `GatedVaultBase.t.sol` (third parties behind the real rules), `CredentialRuleVaults.t.sol` (a lapsed holder redeems but cannot deposit), `FundIntegration.t.sol` (the vault as a fund class at a full cap), and `test/nodejs/vaults.test.ts` (a deposit and `withdraw(maxWithdraw)` from TypeScript)
