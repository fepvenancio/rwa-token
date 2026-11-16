[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Vaults

# FeeModel

Works out a fund's fee. The rates are fixed when it is deployed, it remembers nothing, and whoever asks supplies the value, the share count, the high-water mark, the clocks and what was paid since the mark moved.

- **contracts/nav/FeeModel.sol**
- immutable, **no storage**, one view
- attested as **FEE_MODEL**
- asked by a **NavDesk** or a **Gated4626Vault**

<a id="in-one-minute"></a>

> ### In one minute
>
> A fund charges two kinds of fee: a management fee for the time that has passed, and a performance fee on gains above a high-water mark, which the caller starts at the vault's price, or at par if that is higher, and restarts at par when fewer than `1e6` share units are left. It moves up when a performance fee is charged, except inside a soft hurdle's catch-up, where it waits until the catch-up is complete. This contract is the arithmetic. One function, `quote`, takes the numbers and returns the fee, the mark after that fee, whether the mark moved, and the performance fee paid since it last moved.
>
> It stores nothing. The rates and the recipient are immutables, which sit in its code, so the security council's attestation of the code hash covers them. Changing the fees means deploying another model, attesting it, and swapping through the timelock. It does not pay anyone: a [NavDesk](NavDesk.md) or a [Gated4626Vault](Gated4626Vault.md) calls it, keeps the mark, the clocks and what was paid since the mark moved, and moves the money.

<a id="how"></a>
## The formula

`quote(_gross, _supply, _mark, _markAge, _feeAge, _paidSince)` returns `(_fee, _newMark, _markMoved, _newPaidSince)`. The mark, the price and what was paid are in assets per 1e18 share units. The ages are in seconds. A year is 365 days. Every step rounds down. The code runs in this order:

*quote, with the leading underscores dropped*

```
if supply == 0, or supply, gross, mark or paidSince is above type(uint128).max:
    return (0, mark, false, paidSince)

fee     = gross × MANAGEMENT_BPS × min(feeAge, 20 years) / (10,000 × 1 year)
price   = (gross - fee) × 1e18 / supply
hurdled = mark + mark × HURDLE_BPS × min(markAge, 20 years) / (10,000 × 1 year)
before  = price + paidSince      // the price had nothing been paid since the mark moved

if before <= hurdled:
    return (fee, mark, false, paidSince)

hard hurdle:  due = (before - hurdled) × PERFORMANCE_BPS / 10,000, and it is caught up
soft hurdle:  whole = (before - mark) × PERFORMANCE_BPS / 10,000
              caught up when whole <= before - hurdled
              due = whole if caught up, else before - hurdled

if due <= paidSince:
    return (fee, mark, false, paidSince)

paid    = (due - paidSince) × supply / 1e18
fee     = fee + paid
if not caught up:
    return (fee, mark, false, paidSince + paid × 1e18 / supply)
newMark = price - paid × 1e18 / supply
return (fee, newMark, true, 0)
```

### What the two callers pass

| Input | `NavDesk`, for a 7540 | `Gated4626Vault`, with a portfolio |
|---|---|---|
| `_gross` | The reported value plus `pricedValue()` | The counted value: the priced value net of fees owed, up to the rate limit |
| `_supply` | `totalSupply()` plus the unclaimed shares | `totalSupply()` |
| `_mark` | Its `mark` | Its mark |
| `_markAge` | Seconds since `markMovedAt` | Seconds since its `markMovedAt` |
| `_feeAge` | Seconds since `lastFeeAt` | Seconds since its `lastFeeAt` |
| `_paidSince` | Its `paidSinceMark`, frozen in the proposal with the mark | Its `paidSinceMark()` |
| When it asks | At `propose`; the result is frozen until the proposal executes or is cancelled | At each accrual |
| How the fee is paid | In `settlePeriod`, when the proposal executes | Added to `feesOwed`; `collectFees()` pays it from idle money |

<a id="numbers"></a>
## Worked numbers

These figures come from running the code's integer arithmetic, and each row with a test name matches what that test asserts in `FeeModel.t.sol`. Both tables use an asset and a share with 18 decimals, 1,000 shares and a mark of 1.00 (`_mark` is 1e18), written in whole units.

### Hard against soft

A 20% performance rate, a 10% yearly hurdle, one year since the mark moved, and no management fee, so the hurdle has reached 1.10.

| Gross | Price | Hard: fee | Hard: mark after | Soft: fee | Soft: mark after | Note |
|---|---|---|---|---|---|---|
| 900 | 0.90 | 0 | 1.00, stays | 0 | 1.00, stays | Below the mark |
| 1,000 | 1.00 | 0 | 1.00, stays | 0 | 1.00, stays | At the mark, below the hurdle |
| 1,100 | 1.10 | 0 | 1.00, stays | 0 | 1.00, stays | Exactly at the hurdle: `test_AtTheHurdleThereIsNone` |
| 1,110 | 1.11 | 2 | 1.108 | 10 | 1.00, stays; 0.01 carried | `test_JustAboveAHardOrSoftHurdle_TheyDiffer`, `test_TheMarkNeverLandsBelowTheHurdle`, `test_InsideTheBandTheMarkStaysAndWhatIsPaidIsCarried` |
| 1,125 | 1.125 | 5 | 1.12 | 25 | 1.10 | The soft catch-up ends: its fee is 20% of the whole gain |
| 1,210 | 1.21 | 22 | 1.188 | 42 | 1.168 | Hard: `test_AHardHurdleChargesOnlyWhatIsAboveIt` |
| 1,500 | 1.50 | 80 | 1.42 | 100 | 1.40 | Soft: `test_ASoftHurdleCatchesUpToTheRateOnTheWholeGain` |

### Management fee, and the two together

| Terms | Gross | `_feeAge` | Fee | Mark after | Test |
|---|---|---|---|---|---|
| 2% management | 1,000 | 1 year | 20 | 1.00, stays | `test_ItIsTheGrossTimesTheRateTimesTheAge` |
| 2% management | 1,000 | half a year | 10 | 1.00, stays | `test_ForHalfAYearItIsHalf` |
| 5% management | 1,000 | 20 or 200 years | 1,000 | 1.00, stays | `test_TheAgeIsCappedAtTheWholeValueAtTheCeiling` |
| 20% performance, no hurdle | 1,100 | 0 | 20 | 1.08 | `test_AboveTheMarkItChargesTheRateOnTheGainAndMovesTheMark` |
| 2% management, 20% performance, no hurdle | 1,200 | 1 year | 59.2 (24 + 35.2) | 1.1408 | `test_ThePerformanceFeeAddsToTheManagementFee` |
| 2% management, 20% performance, no hurdle | 1,020 | 1 year | 20.4 | 1.00, stays | `test_ThePriceIsMeasuredAfterTheManagementFee` |
| 5% management, 50% performance, and no shares | 1,000 | 1 year | 0 | 1.00, stays | `test_WithNoSharesThereIsNoFeeAndTheMarkStaysEvenWithValuePresent` |

<a id="hurdles"></a>
## Hard and soft hurdles

A hurdle is a return the investors keep before any performance fee. Here it is `hurdled` in the formula: the mark plus simple yearly growth since the mark last moved. Below it nobody pays a performance fee and the mark stays. `SOFT_HURDLE` decides what happens above it.

- **Hard hurdle.** The performance rate applies to what is above the hurdle and to nothing below it.
- **Soft hurdle, with a full catch-up.** Above the hurdle the manager first takes everything until it holds the performance rate of the whole gain since the mark, then shares at that rate. In the table above and the figure below, investors stay at 1.10 while the price goes from 1.10 to 1.125. Until the catch-up is complete the mark and its clock stay where they were, and what each count charges is carried in `paidSince`, so the next count charges only the rest. On 1,000 shares, a count at a gross of 1,100.1 charges 0.1, and a second count at the same hurdle, at 1,125 less that fee, which has left the fund, charges 24.9: the 25 one count at 1,125 charges (`test_ACountInsideTheBandDoesNotCostTheCatchUp`, and `testFuzz_SplitInTwoItChargesWhatOneCountDoes` for any first count inside the band). A price that falls back keeps what was paid (`test_AFallBackBelowTheHurdleKeepsWhatWasPaid`), and when the hurdle's growth leaves nothing more due, nothing more is charged (`test_WhenTheHurdleOutgrowsWhatWasPaidNothingIsCharged`).

A hard hurdle takes `paidSince` off what is due in the same way. It is zero unless a soft model was swapped for a hard one inside its catch-up, and then the hard one does not charge again for what the soft one took (`test_AHardHurdleCarriesNothing`).

On either kind, once the catch-up is complete, the mark moves to the price after what is actually paid, which is not below `hurdled` (`testFuzz_OnceAFeeIsChargedTheMarkIsNotBelowTheHurdle`), and `paidSince` returns to zero (`test_ACountInsideTheBandDoesNotCostTheCatchUp`, `test_AHardHurdleCarriesNothing`), and net value does not fall as gross rises, apart from rounding (`testFuzz_NetValueNeverFallsAsGrossRises` allows 1,000 of the smallest unit for it).

> **Diagram.** A line chart of what the investor keeps per share against the price after the management fee, for a mark of 1.00, a hurdled price of 1.10 and a 20 percent performance rate. Up to 1.10 both hurdles keep the whole price. Above it, a hard hurdle rises at 80 percent of the price, reaching 1.26 at a price of 1.30. A soft hurdle stays flat at 1.10 until the price reaches 1.125, then rises at 80 percent of the price, reaching 1.24 at a price of 1.30. A dotted line shows the price with no performance fee, reaching 1.30.
>
> **What each hurdle leaves the investor.** A mark of 1.00, a hurdle that has reached 1.10 and a 20% performance rate. The solid line is the hard hurdle, the dashed line the soft hurdle. They run parallel above 1.125, the soft hurdle 0.02 lower, because by then its fee covers the whole gain from 1.00 and the hard hurdle's fee covers the gain from 1.10.

<a id="slicing"></a>
## Why slicing a gain does not clear a hurdle

The hurdle's clock, `_markAge`, runs from when the mark last moved, and the mark moves only when a performance fee is due and, on a soft hurdle, its catch-up is complete. A quote that finds the price at or below the hurdle changes nothing, so the next quote is measured from the same mark over a longer age. Asking more often does not restart the clock.

The example is a 10% yearly hurdle and a 20% performance rate. The price sits at 1.00 for eleven months and reaches 1.09 in the twelfth.

| Quote at | Price | Age of the mark | `hurdled` | Performance fee |
|---|---|---|---|---|
| Month 1 | 1.00 | 1 month | 1.0083 | 0 |
| Month 11 | 1.00 | 11 months | 1.0917 | 0 |
| Month 12 | 1.09 | 12 months | 1.10 | 0 |

A hurdle measured over the last month alone would compare 1.09 with 1.0083 and charge 16.33 on 1,000 shares with a hard hurdle, or 18 with a soft one. Over the whole time since the mark moved, the return is 9% against a 10% hurdle, so nothing is due. `testFuzz_ASteadyReturnBelowTheHurdlePaysNothingHoweverItIsSplit` pins the same thing for a steady 9% split into up to 200 quotes.

This depends on the caller. The model does not keep the clock, so the caller must restart it only when the mark moved. `NavDesk` and `Gated4626Vault` do that. With no shares, or fewer than `1e6` share units, `Gated4626Vault` does not ask the model. `NavDesk` does, with a gross value of zero, and gets no fee and the mark it passed. Each restarts the clock and starts the mark at par.

<a id="caps"></a>
## The caps, and why it does not revert

| Rate | Ceiling | In words |
|---|---|---|
| `MANAGEMENT_BPS` | 500 | 5% a year |
| `PERFORMANCE_BPS` | 5,000 | 50% of the gain |
| `HURDLE_BPS` | 5,000 | 50% a year, simple |

The constructor enforces these with `FeeModel_RateTooHigh`. It reverts with `FeeModel_ZeroRecipient` on a zero `RECIPIENT`, even with no rate, because a swap to this model must still pay what the last one left owed (`test_NobodyToPayIsRefused`).

After that, `quote` does not revert (`testFuzz_ItNeverRevertsAndAFeeNeverExceedsTheGross`, fuzzed over the full range of every input at the ceiling rates). A revert here would stop a price from being proposed on a desk, or stop a 4626 vault counting its value. The reasons it holds:

- **Ages are capped at 20 years.** At the 5% ceiling that is exactly the whole gross value, so the management fee cannot exceed the gross and `gross - fee` cannot go below zero. Time beyond the cap is not charged. The hurdle's age has the same cap.
- **A figure too large to be real gets no fee.** A `_gross`, `_supply`, `_mark` or `_paidSince` above `type(uint128).max` returns no fee and an unchanged mark, as does a `_supply` of zero (`test_AFigureTooLargeToBeRealGetsNoFee`, `test_AtTheLargestRealFiguresItDoesNotRevert`).
- **It compares before it subtracts.** `before - hurdled` and `before - mark` run only once `before` is above `hurdled`, which is at least the mark, `due - paidSince` only once `due` is above `paidSince`, and what is charged is at most `price - hurdled`, so the new mark is not below the hurdle.
- **The fee does not exceed the gross.** The performance fee is at most what the price after the management fee is worth across all shares. The products go through OpenZeppelin's `Math.mulDiv`, which keeps the full precision of the intermediate value.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `quote(_gross, _supply, _mark, _markAge, _feeAge, _paidSince)` | Anyone (read-only) | Returns `_fee` in assets, `_newMark`, `_markMoved`, which tells the caller to restart the mark's clock, and `_newPaidSince`, which the caller keeps for the next quote. |
| `RECIPIENT()` | Anyone (read-only) | Who is paid. The model pays nobody itself: the caller reads this and sends the money. |
| `MANAGEMENT_BPS()`, `PERFORMANCE_BPS()`, `HURDLE_BPS()`, `SOFT_HURDLE()` | Anyone (read-only) | The terms, fixed at construction. |
| `constructor(_recipient, _managementBps, _performanceBps, _hurdleBps, _softHurdle)` | Whoever deploys it | Sets the terms. Reverts with `FeeModel_RateTooHigh` or `FeeModel_ZeroRecipient`. Nothing uses a model until it is attested as `FEE_MODEL` and plugged in. |

<a id="why"></a>
## Why it is built this way

- **No storage.** The rates and the recipient are in the code, so one attested code hash covers one set of terms. Terms cannot change behind the attestation, and a change of terms goes through a deployment, an attestation and a timelock swap.
- **The caller keeps the state.** Replacing a model does not lose the mark, the clocks or what was paid since the mark moved, because the model never held them (`test_ASwapKeepsTheMarkAndTheClocks` in `NavDesk.t.sol` for the mark and the fee clock).
- **The performance fee is measured after the management fee.** A gain that only covers the management fee does not count as a gain (`test_ThePriceIsMeasuredAfterTheManagementFee`).
- **It does not revert.** A fee calculation should not be able to stop a fund from dealing. A figure too large to be real charges nothing, and an age above 20 years is charged as 20 years.

In a deployment, `Legos` deploys a model with the terms of the product's profile, the council attests it, and `Product` plugs it in. The `managed-fund` profile uses 100, 1,000 and 300 basis points with a hard hurdle, and `vault4626-invest` uses 50, 1,000 and 0.

<a id="limits"></a>
## What it does not do

- **It trusts its inputs.** The gross value, the share count, the mark, the ages and what was paid since the mark moved are what the caller says. On a desk the gross value rests on a report, so a wrong report gives a wrong fee.
- **It has one mark for the whole vault.** There is no high-water mark per investor and no equalisation. Investors who came in at different prices pay the same fee per share, and someone who comes in during a soft hurdle's catch-up pays into it on their own gains.
- **It does not compound.** The management fee and the hurdle are simple, in proportion to the time.
- **It does not raise an alarm.** A figure above `type(uint128).max` or an age above 20 years gets a smaller fee or none, with no error.
- **It does not move the mark without a charge.** With a performance rate of zero, or nothing due beyond what was paid, the mark and its clock stay where they are (`test_WithARateOfZeroTheMarkDoesNotMove`). Inside a soft hurdle's catch-up, a charge that rounds to no fee in assets changes nothing either (`test_AChargeInsideTheBandThatRoundsToNothingChangesNothing`). Past the catch-up, or on a hard hurdle, a charge above zero can still round to no fee in assets, because the fee adds `(due - paidSince) × supply / 1e18`. Then no performance fee is owed, the price has not fallen, and the mark moves to the whole price and its clock restarts (`test_WhenTheChargeRoundsToNoFeeTheMarkIsThePrice`). On a dust position the next investor buys at or below that price, so a mark left below it would be charged on their principal. A gain sliced into calls too small to pay a whole unit therefore pays nothing. That costs the fee recipient a rounding error per call: under 3 raw units while the supply is under 1e18 share units, and about one price unit, supply / 1e18 raw units, above that.
- **It does not know a price is dust.** It divides the gross value by the shares it is given, so one asset unit over one share unit reads as a price of `1e18`, against par's `1e12`, and with a charge that rounds to no fee the mark would move there. Its callers keep such dust from it: with fewer than `1e6` share units, less than one unit of the asset at par between them, the desk proposes a value of zero and the 4626 counts zero.
- **It does not pay.** On a 4626, `collectFees()` pays what idle money allows, so holders can leave ahead of fees owed, and a model replaced with fees still owed pays them to the replacement's recipient unless a timelock batch collects first. On a desk, the fee is paid when the proposal executes. A cancelled proposal pays nothing, and the desk's clocks stay where they were, so the next proposal quotes that time again.

<a id="connected"></a>
## Connected to

- [NavDesk](NavDesk.md): Quotes it at each proposal and freezes the result for a 7540 vault.
- [Gated4626Vault](Gated4626Vault.md): Quotes it on the counted value and keeps what it owes in `feesOwed`.
- [PolicyRegistry](PolicyRegistry.md): Where the council attests its code hash as `FEE_MODEL`.
- [Where the money sits](../money.md): Follows the money through a settlement.

<a id="source"></a>
## Source and tests

- Contract: `contracts/nav/FeeModel.sol`, interface `IFeeModel.sol`
- Tests: `FeeModel.t.sol` (the arithmetic and its properties), the fee tests in `NavDesk.t.sol` and `Gated4626VaultPortfolio.t.sol` (what each caller keeps and pays), and `test/nodejs/legos.test.ts` (a deployed model)

---

Describes the contracts at commit `e728b81` on `erc8473-main`.
