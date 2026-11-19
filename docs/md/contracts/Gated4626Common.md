[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Vaults

# Gated4626Common

What [Gated4626Vault](Gated4626Vault.md) and [Gated4626Management](Gated4626Management.md) share: the storage they both act on, and how the value is counted. Abstract, so it runs only as part of those two.

- **contracts/vaults/Gated4626Common.sol**
- abstract: **inherited, not deployed alone**
- extends **ERC4626Upgradeable** and **GatedVaultBase**
- one public function of its own: **decimals()**

<a id="in-one-minute"></a>

> ### In one minute
>
> Two contracts run on one vault's storage, so they have to agree on exactly where each figure lives. If each kept its own copy of the layout, the copies could drift apart, and one contract would read what the other wrote as something else. So the layout is written once, here, and both inherit it. The same goes for the arithmetic both need: how the value of a vault with a portfolio is counted, and when no price can be used.

<a id="functions"></a>
## What it holds

| Item | What it is |
|---|---|
| `Gated4626Storage` | The vault's ERC-7201 storage, at the location of `gated.storage.Gated4626Vault`. All of it is unused while no portfolio is plugged. `portfolio` and `feeModel` are the two plugs, zero for none. `last` is the value last counted and `lastAt` when. `maxRateBps` is the most the counted value may rise in a year. `exitOnly` says an earlier portfolio wrote off an adapter, or a count found the value fallen by more than half. `feesOwed` is fees charged and not yet paid, and `lastFeeAt` when a fee was last charged. `mark` is the high-water mark, `markMovedAt` when it last moved, and `paidSinceMark` the performance fee charged since then. `Gated4626VaultPortfolio_Storage` pins the location. |
| `_accrue()` | Brings the counted value up to date and charges any fee. It does nothing with no portfolio or while no price can be used. |
| `_counting()` | The value to count now, the fee due on it, and the mark and `paidSinceMark` after that fee. It writes nothing. `totalAssets()` reads it, and `_accrue()` writes what it returns. |
| `_dealingStopped()` | Whether no price can be used, which stops deposits and withdrawals: the portfolio's price cannot be read, or the value net of fees reads nothing although holders have a value counted. |
| `_fellTooFar(counted)` | Whether a value counted now is above zero and less than half of `last`. |
| `_priceFresh(portfolio)`, `_pricedValue(portfolio)`, `_writtenOff(portfolio)` | The portfolio's `priceFresh()`, `pricedValue()` and `writtenOff()`, each read in one place. |
| `_getGated4626Storage()` | The pointer to that storage. |
| `decimals()`, `_update`, `_decimalsOffset()` | The overrides the inheritance needs. `decimals()` is the vault's, the asset's plus the offset. `_update` is the base token's, so every share movement goes through the policy. `_decimalsOffset()` returns 6. |
| `_RATE_DENOMINATOR`, `_PRICE_SCALE`, `_VIRTUAL_SHARES`, `_PAR_MARK` | `1e4 × 365 days`, basis points per year in seconds. `1e18`, the share units a price is quoted for. `1e6`, the virtual shares of the offset: fewer share units than this count as no shares. `_PRICE_SCALE / _VIRTUAL_SHARES`, the mark at par and the lowest it can be. |

<a id="counting"></a>
## How the value is counted

`_counting()` works out a figure and writes nothing, so a read and a write cannot disagree. `_accrue()` stores what it returns. What each figure means for an investor is on the [`Gated4626Vault`](Gated4626Vault.md#counting) page.

*\_counting, in words close to the code*

```
counted, mark, paidSince = last, mark, paidSinceMark as stored

if the portfolio's priceFresh() is false:
    return counted, no fee, the mark and paidSince unchanged
if totalSupply() is under 1e6:
    return 0, no fee, the mark at par and moved, paidSince 0

net     = pricedValue() − feesOwed, stopping at zero
limit   = last + floor(last × maxRateBps × (now − lastAt) / (10,000 × 365 days))
counted = the smaller of net and limit

with a fee model:
    fee, mark, moved, paidSince = quote(counted, totalSupply(), mark,
                                        now − markMovedAt, now − lastFeeAt, paidSince)
```

*\_accrue, in words close to the code*

```
with no portfolio, or while dealing is stopped: do nothing

if not exit-only, and counted is not zero, and counted × 2 is under last:
    exitOnly = true, emit DepositsClosed(counted, last)

last   = counted − fee
lastAt = now
emit Accrued(counted, fee)

with a fee model:
    feesOwed += fee
    mark, paidSinceMark = what the quote returned
    lastFeeAt = now
    markMovedAt = now, if the mark moved
```

- **A gain counts once in a block.** A count sets `lastAt` to now, so the limit of a second count in the same block is `last` itself (`test_NoGainCountsAgainInTheSameBlock`). A loss is under the limit, so it counts at once (`test_ALossCountsAtOnce`).
- **Dealing stops in two cases.** `_dealingStopped()` is false with no portfolio and true while `priceFresh()` is false. Otherwise it is true when `last` is not zero, `1e6` share units or more exist, and `pricedValue()` is at or below `feesOwed`. A count then writes nothing, so the value can come back (`test_AReadOfNothingIsNotWrittenDownAndDealingStops`).
- **Under `1e6` share units nothing is anyone's.** The count is zero and the mark returns to par (`test_WithNoSharesNothingCounts`).
- **A fall of more than half is stored by the count that finds it.** Zero is no such fall: it means no shares, or a read of nothing, which a count does not write (`test_AFallOfMoreThanHalfClosesDepositsForGood`, `test_AFallOfExactlyHalfLeavesDepositsOpen`).
- **Both contracts count the same way.** On the vault, `deposit`, `mint`, `withdraw`, `redeem` and `accrue` call `_accrue()`. In the second contract, `setMaxRate`, `setFeeModel` and `collectFees` do.

<a id="connected"></a>
## Connected to

- [Gated4626Vault](Gated4626Vault.md): Inherits it, for deposits, redemptions and views.
- [Gated4626Management](Gated4626Management.md): Inherits it, for plugging a portfolio, the rate limit, the fee model and paying fees.
- [GatedVaultBase](GatedVaultBase.md): One of its parents: the third-party check and the probes.
- [FeeModel](FeeModel.md): The quote a count asks for.
- [Portfolio](Portfolio.md): Where the priced value and its freshness come from.

<a id="source"></a>
## Source and tests

- Contract: `contracts/vaults/Gated4626Common.sol`
- Tests: it has no test file of its own, being abstract. It is tested through `Gated4626Vault.t.sol`, `Gated4626VaultPortfolio.t.sol` and `Gated4626Management.t.sol`.
