[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Portfolio

# Gated4626Adapter

An [ERC4626Adapter](ERC4626Adapter.md) for a target that is a [Gated4626Vault](Gated4626Vault.md) of the same issuer. It is fresh only while that vault deals, so a fund that invests through it stops when the fund it invests in stops.

- **contracts/portfolio/Gated4626Adapter.sol**
- immutable, **not a proxy**
- attested as **ADAPTER**
- **priced**: **reported()** is false
- one function overridden: **fresh()**

<a id="in-one-minute"></a>

> ### In one minute
>
> A fund can be built in two levels. One vault, the master, holds the investments. Other vaults, its feeder classes, each have their own investors and their own fees, and keep nothing themselves: a class's [Portfolio](Portfolio.md) has one adapter, into the master. The plain adapter is wrong for that. A master that cannot price its own portfolio holds its last price and stops dealing, but it still answers `previewRedeem` with that held price, so the plain adapter reads it as fresh and the class goes on taking deposits and paying redemptions at a price the master itself will not deal at. This adapter asks the master whether it deals, and is not fresh when it does not. Everything else is the plain adapter's code.

<a id="how"></a>
## When it is fresh

`fresh()` is the plain adapter's answer, that the position can be priced, and also that the target deals. The target is read with five views it already has, and its portfolio with two. Each read is one that cannot revert, and a read that fails counts as "does not deal".

| The target | Fresh | Why |
|---|---|---|
| Is paused | false (`test_WhenTheTargetIsPaused_ItIsNotFresh`) | A paused vault still answers `previewRedeem`. Without this a class would deal from its idle money at the price the guardian paused over. |
| Has a portfolio whose `priceFresh()` is false | false (`test_WhenTheTargetsPortfolioGivesNoFreshPrice_ItIsNotFresh`) | The target holds its last price and has stopped dealing. |
| Reads nothing: it has counted a value, it has at least `1e6` share units, and its portfolio's `pricedValue()` is no more than its `feesOwed()` | false (`test_WhenTheTargetReadsNothing_ItIsNotFresh`) | The target writes nothing down while this lasts. A class that read it as a loss would close its deposits for good over a value that can come back. |
| Has no portfolio and is not paused | true (`test_WhenTheTargetHasNoPortfolio_ItIsFresh`) | A vault that keeps its own money always has a price. |
| Cannot answer one of the reads, or names a portfolio with no code | false (the six tests of `Gated4626AdapterUnit_FailedReads`) | No answer is not a reason to deal. |
| Anything else | true | `testFuzz_ItIsFreshExactlyWhenTheTargetDeals` runs the whole table against random answers. |

The target's portfolio is asked for on every call and never stored, so a master that replaces its portfolio takes its classes with it, and in the gap between the two calls of a replacement the classes stop (`test_ItFollowsTheTargetToANewPortfolio`, `test_AClassFollowsItsMasterToANewPortfolio`).

What not being fresh does is the portfolio's and the vault's business, as for any adapter: the class's `priceFresh()` is false, so the class holds its last counted value, its `max*` views read zero and deposits and withdrawals revert, until the master deals again.

<a id="feeder"></a>
## A class and its master

- **Two credentials on the master.** The master's shares are gated like any other. The adapter holds them, so the master's policy must accept the adapter. A redemption pays the class's portfolio, which is not the shares' owner, and a master refuses a third-party receiver its policy does not accept, so it must accept the portfolio too. A class with the first and not the second can invest and cannot leave, and `maxRedeem` does not show it (`test_AClassWhoseAdapterTheMasterDoesNotAdmitCannotInvest`, `test_AClassWhosePortfolioTheMasterDoesNotAdmitCannotLeave`). The [post-deploy check](../deployment.md#check) reads both.
- **The price follows the master.** A gain reaches every class in proportion and a loss reaches them at once (`test_AGainInTheMasterReachesBothPricesInProportion`, `test_ALossInTheMasterReachesBothAtOnce`). Each class has its own rate limit on counted gains. With equal limits a class never runs ahead of its master. One counted less often trails it by the compounding until the gain is all counted, which the `accrue` [keeper](../deployment.md#operations) keeps small.
- **Fees are each class's own.** A class's [FeeModel](FeeModel.md) charges on that class's counted value, and one class's fee does not touch another's price (`test_OneClasssFeeDoesNotTouchTheOther`). The fee is paid from the class's idle money, so the allocator first brings that much back from the master (`test_AFeeIsPaidFromMoneyBroughtBackFromTheMaster`).
- **Leaving is one call.** With the adapter as the class portfolio's liquidity adapter, a holder's `redeem` on the class pulls from the master in the same transaction (`test_AnInvestorLeavesThroughTheMasterInOneCall`).

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `fresh()` | Anyone (read-only) | Whether the position can be priced and the target deals. |
| Everything else | As on [ERC4626Adapter](ERC4626Adapter.md#functions) | The same code: `allocate`, `deallocate`, `value()`, `liquid()`, the risk ids and the settings (`test_ItIsAnERC4626AdapterInEverythingElse`). Its `RISK_ID` is the plain adapter's for the same target. |
| The constructor | The deployer | Takes `(_portfolio, _target, _sharedRiskId)`, as the plain adapter does. |

Its code hash is not the plain adapter's, so the council attests it separately (`test_ItsCodeIsNotThePlainAdapters`).

<a id="limits"></a>
## What it does not do

- **It does not close a class when a small write-off closes its master.** A master whose portfolio writes off an adapter is exit-only for good, whatever the size. A class sees only the fall in price, and closes its own deposits only when that is more than half. The adapter cannot say "no deposits": not being fresh would stop redemptions too, and holders must be able to leave. So it is a rule for the operator: the timelock batch that writes off an adapter on a master also sets each class's [CredentialRule](CredentialRule.md) policy to one that trusts no attester. That admits no receiver, so no deposit, and still lets every holder redeem (`test_ASmallWriteOffClosesTheMasterAndNotItsClasses` pins that the class still takes them).
- **It does not follow a change in the vault's rule.** The third row of the table copies the vault's own condition for a read of nothing. The adapter is immutable and the vault can be upgraded, so an upgrade that changes when a `Gated4626Vault` stops dealing needs a new adapter, attested and swapped into each class.
- **It does not check that its target is a `Gated4626Vault`.** A target without those views fails the reads, and the adapter is never fresh. The council's attestation and the post-deploy check are what tie it to a master.
- **It does not make a class a holder the master counts specially.** To the master the adapter is one holder among others.
- **Everything the plain adapter does not do** holds here too: it does not judge the target's price, and it does not look at its own vault's pause.

<a id="connected"></a>
## Connected to

- [ERC4626Adapter](ERC4626Adapter.md): The adapter it inherits, for a target outside the issuer's stack.
- [Gated4626Vault](Gated4626Vault.md): Both the master it reads and the class that invests through it.
- [Portfolio](Portfolio.md): The class's portfolio, which moves money through it, and the master's, whose price it asks about.
- [PolicyRegistry](PolicyRegistry.md): Where its code hash must be attested as `ADAPTER`.

<a id="source"></a>
## Source and tests

- Contract: `contracts/portfolio/Gated4626Adapter.sol`, over `ERC4626Adapter.sol`; no interface of its own
- Tests: `Gated4626Adapter.t.sol` (a mocked vault and portfolio), `contracts/vaults/MasterFeeder.t.sol` (a real master and two classes), and `test/nodejs/legos.test.ts` and `control.test.ts` for the `master-feeder` profile
