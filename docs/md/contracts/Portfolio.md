[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Portfolio

# Portfolio

Holds one vault's working money and limits where it can go: to an installed adapter, under caps on its allocation, to the vault, or to an attested successor by a timelock operation. None of its functions pays any other address.

- **contracts/portfolio/Portfolio.sol**
- immutable, **not a proxy**
- attested as **PORTFOLIO**
- **one per vault**, one asset
- no role table: it **asks the vault**
- at most **8** adapters

<a id="in-one-minute"></a>

> ### In one minute
>
> A vault that invests keeps its working money here rather than in the vault. A Portfolio serves one vault and holds one asset, both fixed when it is deployed. The money sitting in it is called idle. An account with the vault's `ALLOCATOR_ROLE` can send idle money to an adapter, a small attested contract that connects to one place money can go, such as an on-chain vault or a custodian. The timelock decides which adapters are installed and what the caps are. The allocator moves money within those limits. The guardian can bring money back and lower caps. The Portfolio keeps no list of roles: at each call it asks the vault who holds what. It also tells the vault and the [NavDesk](NavDesk.md) what the on-chain part of the money is worth.

<a id="where"></a>
## Where the money can go

The contract makes two kinds of payment, to an installed adapter and to a successor, and it gives the vault one allowance. An adapter's way back names no receiver, and both shipped adapters pay the portfolio.

> **Diagram.** Where one vault's money can go. The vault sends deposits and net inflow to the portfolio, and takes money back through its allowance, after calling raise on a 4626. The portfolio sends idle money by allocate to an installed adapter, under caps on its allocation, and gets it back by deallocate. An ERC4626Adapter is priced: it deposits into and withdraws from an outside ERC-4626 vault. A GuardedAccount is reported: it makes permitted calls that can reach a custodian or a strategy, which sends money back by its own decision. A timelock operation can move the idle money to a successor portfolio by migrateTo. No function of the portfolio pays any other address.
>
> **Three ways out of the idle money.** An installed adapter, under caps on its allocation, the vault through its allowance, and a successor by a timelock operation. The allowance has no limit, so the vault's own code decides what it pulls. On a 4626, `collectFees` uses it to pay the fee recipient straight from idle money. The dashed arrow is outside any contract: a custodian returns money because it chooses to.

1. **In.** On a [4626](Gated4626Vault.md) with a portfolio plugged, each deposit passes through the vault to the portfolio. On a [7540](Gated7540Vault.md), `settlePeriod` sends a period's net inflow to the cash account it is given, and a [NavDesk](NavDesk.md) with a portfolio names the portfolio as that account.
2. **To an adapter.** `allocate` sends idle money to an installed adapter. To be installed, an adapter must be attested as `ADAPTER` in the registry the vault names, and must serve this portfolio and this asset.
3. **Back from an adapter.** `deallocate` asks the adapter for an amount and names no receiver. [ERC4626Adapter](ERC4626Adapter.md) has the target pay the portfolio, and [GuardedAccount](GuardedAccount.md) pays the portfolio from its own balance.
4. **To the vault.** The constructor approves the vault for an unlimited amount of the asset. A 4626 withdrawal calls `raise(assets)` and then pulls. A 7540 does not call `raise`: a net outflow at settlement is pulled from the cash account (`test_NetOutflowIsPulledFromThePortfolio`), so idle money has to cover it or the settlement reverts, and the allocator brings money back beforehand.
5. **To a successor.** `migrateTo`, [described below](#migrate).

<a id="how"></a>
## Sending money out and bringing it back

`allocate(_adapter, _assets, _minAdded)` runs these steps. A failure at any step undoes the whole call.

1. **Who and when.** The caller must hold the vault's `ALLOCATOR_ROLE` (`Portfolio_Unauthorized`), and the vault must not be paused (`Portfolio_VaultPaused`). The adapter must be installed (`Portfolio_UnknownAdapter`) and the amount above zero (`Portfolio_ZeroAmount`).
2. **The starting point.** It reads the vault's `totalAssets()` for the relative caps, then takes its reentrancy guard. A priced adapter must be readable (`Portfolio_StalePrice`), and its `value()` is noted.
3. **The money moves.** The assets go to the adapter, and the adapter's `allocate(assets)` puts them to work.
4. **What counts.** For a priced adapter, which must still be readable, it is the change in `value()` across the call, so a fee taken on the way in does not count (`test_APricedAdapterThatTakesAFeeCountsWhatItIsWorth`). For a reported adapter it is the assets sent. Below `_minAdded` the call reverts with `Portfolio_ShortAllocation`. That floor is the allocator's own protection: it chooses what it sends, and the target decides what comes back.
5. **The caps.** `moves` goes up by one, and the amount is added to the adapter's `allocationOf` and to every risk the adapter names. If any risk passes a cap the call reverts with `Portfolio_CapExceeded(id, allocation, limit)`. It emits `Allocated(adapter, assets, allocated)`.

`deallocate(adapter, assets)` can be called by the allocator or the guardian, paused or not. The adapter must deliver at least `assets`, measured by the portfolio's own balance (`Portfolio_ShortReturn`). The allocation falls by the change in `value()` when a priced adapter can be read before and after, and otherwise by `assets`. It stops at zero, so taking out a gain leaves nothing against the cap (`test_AGainNeverTakesTheAllocationBelowZero`). Caps are not checked on the way back, so it works above a lowered cap. `moves` goes up by one and it emits `Deallocated(adapter, assets, deallocated)`.

`raise(assets)` can be called by the vault alone. If idle money covers `assets` it returns and nothing moves. Otherwise it draws the shortfall from the `liquidityAdapter` the allocator chose with `setLiquidityAdapter`, by the same steps as `deallocate`, or reverts with `Portfolio_NoLiquidityAdapter` if none is set. It pays nothing to the vault: the vault then pulls through its allowance (`test_RaisingDrawsOnARealTargetAndTheVaultPulls`). The 4626 is the vault that calls it. Neither the 7540 nor the desk calls `raise`, so behind a 7540 the liquidity adapter changes only what `liquidAssets()` says.

<a id="caps"></a>
## Caps

An adapter names the risks it counts against through `riskIds()`, at least one (`Portfolio_NoRiskIds`). A risk is a `bytes32` id with three numbers, which `riskOf(id)` returns as a `Risk`: `allocation`, `absoluteCap` and `relativeCapBps`. Several adapters can name one id, so one cap can cover several positions at one custodian while each adapter also has its own. Every risk an adapter names must have room, or the move fails whole (`test_TheSharedCapStopsAnAdapterWhoseOwnCapHasRoom`).

- **Absolute cap.** The most assets allowed under the id. Zero allows none, and a risk nobody has set caps for is at zero (`test_AnIdWithNoCapAllowsNothing`).
- **Relative cap.** The most allowed as a share of the vault's `totalAssets()`, in basis points. 10,000 means no limit. On a 4626 that total is the counted value, and on a 7540 it is the indicative value at the last settlement.
- **When they are checked.** On `allocate` and on `addAdapter`, and at no other time. An exit, or a fall in the vault's total, can leave a risk above its relative cap, and lowering a cap leaves what is allocated where it is (`test_ItWorksAboveALoweredCap`). A risk above its cap also refuses the installation of another adapter that names it, even an empty one.
- **What the allocation measures.** What went in, less what came out. It does not follow the market: a loss keeps its place against the cap (`test_ALossShowsAtOnceAndKeepsItsPlaceAgainstTheCap`), and a position that has grown can be worth more than its cap.
- **Who sets them.** `setCaps(id, absoluteCap, relativeCapBps)`. The vault's `DEFAULT_ADMIN_ROLE` sets any value. `GUARDIAN_ROLE` can only lower them: neither number may rise. Anyone else gets `Portfolio_Unauthorized`. A relative cap above 10,000 reverts with `Portfolio_InvalidCap` for any caller, before the role check. From the admin, an absolute cap that does not fit in 120 bits reverts with `SafeCastOverflowedUintDowncast`. It emits `CapsSet(id, absoluteCap, relativeCapBps)`.

<a id="priced-and-reported"></a>
## Priced adapters and reported adapters

An adapter says which kind it is through `reported()`. A priced adapter's value can be read on-chain in the same call. A reported adapter's money can sit off-chain, so its value reaches the chain as a figure in a report.

|  | Priced | Reported |
|---|---|---|
| `reported()` says | false | true |
| Shipped example | [ERC4626Adapter](ERC4626Adapter.md) | [GuardedAccount](GuardedAccount.md) |
| Where its value comes from | Its `value()` | The report a [NavDesk](NavDesk.md) reporter proposes and a checker accepts |
| In `pricedValue()` | Yes | No |
| In `priceFresh()` | Yes: an unreadable one makes it false | No |
| Allocation grows by | The change in `value()` across the call | The assets sent |
| Allocation at installation | Its `value()` at that moment, which must fit the caps (`test_APositionItAlreadyHoldsCountsAgainstItsCapsAtOnce`). If unreadable, `Portfolio_StalePrice` | Zero, whatever it holds (`test_AReportedAdapterStartsAtZeroWhateverItHolds`) |
| Portfolio it can join | Either | One whose `ACCEPTS_REPORTED` is true, or `Portfolio_ReportedNotAccepted` |

**Why the 4626 refuses reported adapters.** A 4626 deals at once, at the price it can read in that block. A custodian's position changes off-chain and shows up only when someone reports it. Between reports the price would be out of date, and whoever learned of a loss first could redeem at the stale price, at the expense of the holders who stay. A [7540](Gated7540Vault.md) does not have that exposure in the same way, because it deals at one approved price after requests have closed.

Three separate checks hold this line. `Gated4626Vault.setPortfolio` reverts with `Gated4626Vault_PortfolioRefused` when the portfolio's `ACCEPTS_REPORTED` is true (`test_APortfolioThatAcceptsReportedAdaptersIsRefused`). A portfolio with it false refuses a reported adapter in `addAdapter`. And the constructor of `GuardedAccount` reverts with `GuardedAccount_ReportedNotAccepted`. The `Legos` deployment module sets `ACCEPTS_REPORTED` true behind a 7540 and false behind a 4626. Refusing them also makes `pricedValue()` and `priceFresh()` cheaper, because those reads then skip asking each adapter which kind it is (`test_RefusingReportedAdaptersMakesTheReadsCheaper`).

<a id="reads"></a>
## What the vault and the desk read

| Read | What it says | Who acts on it |
|---|---|---|
| `pricedValue()` | Idle money plus the `value()` of every priced adapter. Reported adapters are not in it. An adapter that cannot be read counts as zero, which is not a loss, so read `priceFresh()` too. In the middle of a move the money is in neither place or in both, so it reverts with `ReentrancyGuardReentrantCall` (`test_NothingCanReadThePriceDuringAnAllocation`, `test_NothingCanReadThePriceDuringADeallocation`). | A 4626's `totalAssets()`. `NavDesk.propose`, which adds it to the reported figure. A 4626's `setPortfolio`, which reverts with `Gated4626Vault_PortfolioNotEmpty` until the portfolio being replaced reads zero and has no adapter on its list. |
| `priceFresh()` | True when every priced adapter's `fresh()` is true and the money has not gone to a successor. | False stops a 4626's deposits and withdrawals, and the last counted value stands (`test_DuringATargetOutageThePriceHoldsAndDealingStops`). `NavDesk.propose` reverts with `NavDesk_PriceNotFresh`. |
| `liquidAssets()` | Idle money plus what the liquidity adapter's `liquid()` says it can return at that moment. | A 4626's `maxRedeem` and `maxWithdraw` are limited by it (`test_WithNoLiquidityAdapter_ExitIsLimitedToIdleMoney`). |
| `moves()` | A count that goes up by one on each `allocate`, each `deallocate` and each `raise` that draws on the adapter. A valuation taken before a move is out of date once it changes. | `NavDesk.propose` takes the count the report was struck against and reverts with `NavDesk_MovesChanged` if it differs. A report struck before a move is refused, so money crossing between reported and on-chain does not count twice (`test_AMoveAfterTheValuationCannotCountTwice`). |

<a id="write-off"></a>
## Taking an adapter off, and what a write-off means

There are two ways off the list. Both clear the adapter's allocation from every risk it names, and clear `liquidityAdapter` if it was that adapter.

|  | Removing | Writing off |
|---|---|---|
| Function | `removeAdapter(adapter)` | `writeOffAdapter(adapter)` |
| What it says | This adapter is empty | This adapter comes off with whatever it holds |
| A priced adapter qualifies | When it can be read and is worth exactly zero. A position that lost everything comes off this way (`test_AnAdapterThatLostEverythingComesOffAndItsAllocationClears`) | While it cannot be read, or while what it can pay out, `liquid()`, is below what it reads, as when its target stops withdrawals and has `maxWithdraw` read 0 (`test_AnAdapterOverATargetThatStopsPayingCanBeWrittenOff`). One that reads and can pay what it reads reverts with `Portfolio_StillPriced`, and so does one worth nothing, which `removeAdapter` takes |
| A reported adapter qualifies | When its balance of the asset and its allocation are both zero | At any time |
| Otherwise | `Portfolio_NotEmpty`, including during an outage, so `removeAdapter` cannot orphan a position in an outage (`test_AnOutageCannotOrphanAPosition`). Nor can `setPortfolio`, which refuses while an adapter is on the list | `Portfolio_StillPriced` |
| Sets `writtenOff` | No (`test_RemovingAnEmptyAdapterIsNotAWriteOff`) | Yes, for good (`test_AWriteOffIsRememberedForGood`) |
| Emits | `AdapterRemoved(adapter)` | `AdapterWrittenOff(_adapter, _allocationCleared)` |

What follows a write-off:

- **On a priced adapter, the loss counts.** Its value leaves `pricedValue()` and `priceFresh()` stops asking about it, so a price stopped by that adapter can be read again, with the loss in it (`test_AWriteOffCountsTheLossOnAPricedAdapter`).
- **On a reported adapter, `pricedValue()` does not change** (`test_AWriteOffLeavesTheValueAloneOnAReportedAdapter`). Its value was only ever in the report, so the report has to say what is left.
- **The adapter keeps what it holds.** `deallocate` reverts with `Portfolio_UnknownAdapter` until it is added back.
- **A 4626 becomes exit-only for good.** `exitOnly()` reads true, `maxDeposit` and `maxMint` read 0 (`test_AfterAWriteOffTheVaultIsExitOnly`), and holders can still redeem (`test_TheLossCountsAndHoldersExit`), unless the priced value is at or below `feesOwed` (`test_AReadOfNothingIsNotWrittenDownAndDealingStops`, `test_AValueBelowTheFeesOwedIsAlsoAReadOfNothing`). A successor portfolio starts with `writtenOff` false, so `setPortfolio` copies the answer into the vault before it replaces the portfolio (`test_AReplacementKeepsTheExitOnlyState`).
- **A 7540 does not read `writtenOff`, and neither does the desk.** Dealing continues at whatever price the reporter and the checker approve.
- **It can be added back, and the flag stays.** `addAdapter` works again if the adapter is still attested. A priced position comes back at its value, against its caps, so it cannot return outside them (`test_AddingAPositionBackCannotTakeExposurePastTheCap`). A reported one comes back at zero, so the caps cannot see what a custodian still holds, and the timelock has to set them knowing that.

<a id="migrate"></a>
## Moving to a successor

`migrateTo(successor)` sends all the idle money to another portfolio. It needs the vault's `DEFAULT_ADMIN_ROLE`, no adapter still installed (`Portfolio_AdaptersInstalled`), a successor attested as `PORTFOLIO` in the vault's registry (`Portfolio_NotAttested`), and one that names the same vault (`Portfolio_WrongVault`) and the same asset (`Portfolio_WrongAsset`). It emits `Migrated(successor, assets)`. From then on `priceFresh()` reads false for good, so if the batch is split a 4626 holds its price and stops dealing, and a desk can propose no price (`test_AfterMigratingItNeverGivesAPriceAgain`, `test_InTheGapThePriceHoldsAndDealingStops`, `test_AfterAMigrationNoPriceIsProposed`). It can run again, to send on what arrived since (`test_MigratingAgainSendsOnWhatArrivedSince`).

So before it can run, money at each adapter has to come back, or the adapter has to be written off. It moves the money, marks the portfolio, and does nothing else. The vault learns of the successor through its own plug: `Gated4626Vault.setPortfolio` or `NavDesk.setSettings`. The interface expects a timelock batch to run both together. `migrateTo` does not compare `ACCEPTS_REPORTED` between the two portfolios; the 4626's `setPortfolio` makes its own check. The allowance to the vault stays behind on the emptied portfolio, with nothing left for it to pull.

<a id="who"></a>
## Who can do what, asked at call time

The contract has no role table. Each gate calls `hasRole` on the vault for the caller at that moment, so a revoked role stops working at once and a granted one works at once (`test_ARevokedRoleStopsWorkingAtOnce`, `test_ANewlyGrantedRoleWorksAtOnce`). The registry is asked for the same way, through the vault's `registry()`. All the roles are the vault's. `ALLOCATOR_ROLE` is given with the vault's `grantRole` by its admin.

| Who | What they can do here |
|---|---|
| The vault's `DEFAULT_ADMIN_ROLE`: the timelock after the hand-over, and the operations account while the `Product` module runs | `addAdapter`, `removeAdapter`, `writeOffAdapter`, `migrateTo`, and `setCaps` to any value |
| The vault's `ALLOCATOR_ROLE` | `allocate`, `deallocate`, `setLiquidityAdapter` |
| The vault's `GUARDIAN_ROLE` | `deallocate`, and `setCaps` where neither number rises |
| The vault itself | `raise`, and pulling idle money through its allowance |

### What a pause stops

A pause on the vault stops money going out to work and lets it come back.

### Stopped while the vault is paused

- `allocate`, with `Portfolio_VaultPaused` after the role check (`test_AnAllocationRevertsAndNothingMoves`, `test_AStrangerStillGetsTheRoleError`).
- `GuardedAccount.execute`, with `GuardedAccount_VaultPaused`.
- The vault's own dealing: a 4626's `maxRedeem` and `maxWithdraw` read 0, so a withdrawal reverts before it draws on `raise`, and a 7540's `settlePeriod` reverts. A 4626's `collectFees` reverts too, so the allowance pays no fee recipient.

### Not stopped

- `deallocate`, by the allocator or the guardian (`test_TheGuardianAndTheAllocatorStillBringMoneyBack`).
- `setCaps` (`test_TheGuardianStillLowersACap`) and `setLiquidityAdapter`.
- The admin's `addAdapter`, `removeAdapter`, `writeOffAdapter` and `migrateTo`.
- Money already at a target or a custodian. The pause is on this vault and does not reach them, and money a custodian holds comes back off-chain.

<a id="stolen-key"></a>
## What a stolen allocator key could do

The hand-over check pins the allocator to one named account, different from the desk's reporter and checker. It does not ask for a multisig, so a single key is a case to plan for.

### It could

- Send idle money to any installed adapter, with `_minAdded` at zero, at whatever price or fee the target gives. On a reported adapter the caps count what is sent. On a priced adapter they count the change in `value()`, so a target that takes a fee or gives a bad price can take more than the cap.
- Pull positions back with `deallocate`, paying any exit fee the target charges.
- On a [GuardedAccount](GuardedAccount.md), run any call its permissions allow, such as sending what the account holds to the custodian its validator names.
- Clear the liquidity adapter with `setLiquidityAdapter` and allocate the idle money. A 4626's holders are then limited to what is left idle until the money comes back (`test_WithNoLiquidityAdapter_ExitIsLimitedToIdleMoney`).
- Delay a price: each move changes `moves`, and `NavDesk.propose` reverts unless the report's count matches.

### It could not

- Install an adapter, raise a cap, set a permission or start a migration. Those need the vault's `DEFAULT_ADMIN_ROLE`.
- Name its own address in `allocate` or `deallocate`. The first takes an installed adapter, and the second has no receiver.
- Reach an address of its choosing through a `GuardedAccount`, unless a permission the timelock set allows that address.

**What limits it.** The caps limit how far `allocate` can take the allocation under each risk, and on a priced adapter the allocation leaves out what a fee or a bad price took on the way in. The list of adapters and the permissions bound where it can go. The response has no delay on the guardian's side: `pause()` on the vault stops `allocate` and `execute`, `deallocate` brings back what is at an adapter, `setCaps` lowers the caps, and `revokePermission` removes a permission. The guardian cannot revoke the role itself. The role's admin is the vault's `DEFAULT_ADMIN_ROLE`, so removal goes through the timelock and its delay, and takes effect on the next call. During a pause a stolen key can still call `deallocate` and `setLiquidityAdapter`. Neither sends money out of the portfolio.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `addAdapter(adapter)` | The vault's `DEFAULT_ADMIN_ROLE` | Installs an adapter, in this order of checks: attested as `ADAPTER` (`Portfolio_NotAttested`), serves this portfolio (`Portfolio_WrongPortfolio`) and asset (`Portfolio_WrongAsset`), kind accepted (`Portfolio_ReportedNotAccepted`), names a risk (`Portfolio_NoRiskIds`), room on the list of `MAX_ADAPTERS` (`Portfolio_TooManyAdapters`), not there already (`Portfolio_AdapterExists`), readable if priced (`Portfolio_StalePrice`), within caps (`Portfolio_CapExceeded`). Emits `AdapterAdded(adapter, allocation)`. |
| `removeAdapter(adapter)` | The vault's `DEFAULT_ADMIN_ROLE` | Takes an empty adapter off. `Portfolio_UnknownAdapter` if it is not installed, `Portfolio_NotEmpty` if it is not empty. Emits `AdapterRemoved`. |
| `writeOffAdapter(adapter)` | The vault's `DEFAULT_ADMIN_ROLE` | Takes an adapter off with whatever it holds and sets `writtenOff`. `Portfolio_UnknownAdapter` if it is not installed, `Portfolio_StillPriced` on a priced adapter that reads and can pay out what it reads. Emits `AdapterWrittenOff`. |
| `setCaps(id, absoluteCap, relativeCapBps)` | The vault's `DEFAULT_ADMIN_ROLE`, or its `GUARDIAN_ROLE` to lower | Sets a risk's caps. Emits `CapsSet`. |
| `allocate(_adapter, _assets, _minAdded)` | The vault's `ALLOCATOR_ROLE`, not while paused | Sends idle money to an installed adapter, if what it adds to the allocation fits the caps. Emits `Allocated`. |
| `deallocate(adapter, assets)` | The vault's `ALLOCATOR_ROLE` or `GUARDIAN_ROLE` | Brings money back from an installed adapter. Emits `Deallocated`. |
| `setLiquidityAdapter(adapter)` | The vault's `ALLOCATOR_ROLE` | Chooses the installed adapter `raise` draws on, or zero for none. Emits `LiquidityAdapterSet(adapter)`. |
| `raise(assets)` | The vault | Makes sure idle money covers an amount, drawing the shortfall from the liquidity adapter. |
| `migrateTo(successor)` | The vault's `DEFAULT_ADMIN_ROLE` | Moves the idle money to an attested successor for the same vault and asset. Emits `Migrated`. |
| `pricedValue()`, `priceFresh()`, `liquidAssets()`, `moves()` | Anyone (read-only) | See [What the vault and the desk read](#reads). |
| `adapters()`, `allocationOf(adapter)`, `riskOf(id)`, `liquidityAdapter()`, `writtenOff()` | Anyone (read-only) | The installed adapters, what one has outstanding against its caps, a risk's allocation and caps, the adapter `raise` draws on, and whether this portfolio has ever written one off. |
| `ALLOCATOR_ROLE()`, `MAX_ADAPTERS()`, `VAULT()`, `ASSET()`, `ACCEPTS_REPORTED()` | Anyone (read-only) | The role id held on the vault, the limit of 8 adapters, and the three settings fixed at construction. |
| The constructor | The deployer | Takes `(_vault, _asset, _acceptsReported)` and reverts with `Portfolio_ZeroAddress` on a zero vault or asset. Gives the vault its allowance. |

<a id="why"></a>
## Why it is built this way

- **One portfolio per vault.** With one vault there is no ledger between vaults to get wrong.
- **Immutable and attested.** The vault, the asset and `ACCEPTS_REPORTED` are immutables, so the attested code hash covers them.
- **It asks the vault for roles and the registry.** Revoking a role on the vault is enough, with no second list to keep in step. It also means a portfolio can be built before its vault exists: the `Legos` module names the address `ProxyDeployer.predict` gives.
- **A priced allocation is the change in value.** It counts what the position gained, not what the allocator sent, so a fee on the way in does not sit against the cap as if it were exposure.
- **A priced position counts at installation.** Otherwise a position written off during an outage could come back with nothing against its caps.
- **The price reverts mid-move.** `allocate` reads `totalAssets()` before taking its guard for this reason: a vault's total asks this portfolio, which gives no price in the middle of a move.
- **The guardian only reduces risk here.** It can bring money back and lower caps. Sending money out and raising caps are outside its reach.

<a id="limits"></a>
## What it does not do

- **It does not vouch for a target.** An adapter's code hash covers its target's address and not the target's behaviour, so a bad target can lose what was allocated to it. Attesting is the council's decision, and the contract cannot check what it reviewed. Nothing else controls the target itself.
- **It does not cap what it sends to a priced adapter.** `allocate` compares the change in `value()` with the caps and not `_assets`, so with `_minAdded` at zero a target that keeps a fee on the way in can take more than the cap. The fee is not counted, so how far past the cap depends on the fee, and a large enough fee takes all the idle money.
- **During an outage it can read zero.** That is not a loss, so read `priceFresh()` too. A 4626's `setPortfolio` refuses while an adapter is on the list, so a replacement cannot leave a position behind (`test_APortfolioWithAnAdapterOnItsListCannotBeReplaced`).
- **It does not limit the vault.** The allowance is unlimited, so an upgrade of the vault could take the idle money. That takes a timelock operation and an implementation the council has attested, and the delay makes it public.
- **It does not know what a custodian holds.** For a reported adapter, `allocationOf` is what was sent less what came back. It is not a valuation, and a report is a claim the contract cannot check.
- **It trusts a target's `maxWithdraw`.** A priced adapter that reads but whose target will not pay comes off by write-off only if the target says so through `maxWithdraw`, as ERC-4626 has it do while withdrawals are disabled. A target that answers with what it will not pay leaves the adapter on the list, and the vault's portfolio cannot be replaced, until it pays.
- **It does not re-check attestation.** The registry is asked at installation. Revoking an attestation leaves an installed adapter in place until the timelock takes it off.
- **It does not limit how often money moves.** Caps limit the allocation under a risk. There is no daily limit on `allocate` or `deallocate`.
- **It relies on its adapters' reads not reverting.** A failed read that an adapter catches is an outage. If an adapter's `fresh()` and `value()` both reverted, then `priceFresh()`, `pricedValue()`, `deallocate`, `removeAdapter` and `writeOffAdapter` would revert with them, so that adapter could not be taken off, and on a 4626 on this portfolio `totalAssets()`, deposits, withdrawals and `setPortfolio` would revert too. [ERC4626Adapter](ERC4626Adapter.md) turns any failed read into an outage (`test_WhenTheTargetHasNoCodeThePriceHoldsAndItCanBeWrittenOff`), and any other adapter has to do the same.
- **It moves one token.** No function moves anything but `ASSET`, so another token sent here stays here. It has no `receive` function, so a plain send of ether reverts.

<a id="connected"></a>
## Connected to

- [Gated4626Vault](Gated4626Vault.md): Forwards deposits here, calls `raise` on withdrawals, and counts its price from `pricedValue()`.
- [Gated7540Vault](Gated7540Vault.md): Sends net inflow here at settlement and pulls net outflow through its allowance.
- [NavDesk](NavDesk.md): Names this portfolio as the cash account and adds its on-chain value to the reported one.
- [ERC4626Adapter](ERC4626Adapter.md): The priced adapter: a position in one on-chain vault.
- [GuardedAccount](GuardedAccount.md): The reported adapter: a custodian or a strategy, by permission.
- [PolicyRegistry](PolicyRegistry.md): Where adapters and successors must be attested, as the vault names it.
- [Where the money sits](../money.md): The whole path of the money across the stack.

<a id="source"></a>
## Source and tests

- Contract: `contracts/portfolio/Portfolio.sol`, interfaces `IPortfolio.sol` and `IAdapter.sol`
- Tests: `Portfolio.t.sol` (unit tests with a mock vault and mock adapters, and integration tests against a real 4626 and a real target, among them `test_NothingLeavesExceptAlongTheListedPaths`), `Gated4626VaultPortfolio.t.sol` (the 4626 with a portfolio plugged), `NavDesk.t.sol` (`NavDesk_WithAPortfolio`), `test/nodejs/legos.test.ts` (the deployed profiles)
- Symbolic: `PortfolioHalmos.t.sol` (`check_anAllocationNeverPassesACap`)

---

Describes the contracts at commit `01024e9` on `main`.
