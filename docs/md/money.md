[Overview](index.md) · [Contracts](index.md#contracts) · [Who can do what](roles.md) · [One movement](movement.md) · [Deployment and governance](deployment.md) · [Where the money sits](money.md)

[Overview](index.md) / Topics

# Where the money sits

For each way money moves, this page shows where the asset and the shares are at every step, who can move them from there, and how the price and the rounding are worked out.

- a vault's asset: **not seen by the vault's hook**
- 7540: **one price per period**
- 4626 with a portfolio: **gains count at a limited rate**
- ETH: **the two timelocks** accept it, nothing else

[In one minute](#in-one-minute) · [Intent token](#intent) · [4626 vault](#v4626) · [4626 with a portfolio](#v4626-portfolio) · [7540 dealing period](#v7540) · [7540 prices and a worked example](#prices7540) · [The desk](#desk) · [A portfolio's adapters](#portfolio) · [DvP, gated cash](#dvp-gated) · [DvP, ERC-3009 cash](#dvp-3009) · [SignedEntry](#signed-entry) · [Distributor](#distributor) · [What the code does not have](#absent) · [Why](#why)

<a id="in-one-minute"></a>

> ### In one minute
>
> Two kinds of value move here. **Token balances**: every fungible template is a gated ERC-20 and the NFT a gated ERC-721, and each movement asks its hook and rules first. The **vault asset**: the two vaults take in and pay out an ERC-20 chosen at deployment, such as a stablecoin, and the vault's hook does not see those transfers. The intent token has no asset behind it: its balances are the record. A 4626 vault keeps its asset itself, or forwards it to a portfolio. A 7540 vault deals in periods: requests wait in the vault, one approved price settles them together, and only the difference between what came in and what must go out moves to or from a cash account. The DvP executor swaps a security against cash in one transaction and keeps nothing. SignedEntry lets an investor enter with signatures while a relayer pays the gas. A Distributor holds funded money until holders claim it.

| Flow | The asset sits | The shares or tokens sit | The price comes from |
|---|---|---|---|
| `IntentToken` transfer | no asset | holders' balances | no price: cash, if any, settles elsewhere |
| `Gated4626Vault`, no portfolio | in the vault | holders' balances | OpenZeppelin's formula on the vault's asset balance and share supply |
| `Gated4626Vault` with a `Portfolio` | in the portfolio and its priced adapters; in the vault only inside a call | holders' balances | the same formula on a counted value, with gains limited by a rate |
| `Gated7540Vault` | in the vault while a request or a payout waits; otherwise with the cash account | holders' balances; in escrow at the vault while a redemption waits; shares bought but not claimed are a number, `unclaimedShares` | a reported value, approved through a `NavDesk`, for a whole period |
| DvP | moves straight between buyer and seller, or through the executor inside one call | moves from seller to buyer | agreed off-chain and signed by both parties |
| `SignedEntry` | in `SignedEntry` inside one call, then as the vault | as the vault | as the vault; on a 4626 the investor signs the least it accepts |
| `Distributor` | in the `Distributor` from approval until claimed or swept | not touched | a list of `(holder, amount)` built off-chain |

<a id="intent"></a>
## Intent token: the token is the instrument

[`IntentToken`](contracts/IntentToken.md) holds no asset and moves no payment. Its balances are the record of who owns what. An **intent** is a transfer the holder signs off-chain and an executor submits; its `ref` field ties the move to an off-chain payment message. [`GatedToken`](contracts/GatedToken.md) is the same without intents.

> **Diagram.** Intent token flows. The minter mints tokens to holder A, raising the supply. Holder A moves tokens to holder B by a transfer or by a signed intent that an executor contract runs. The agent can force-transfer holder A's tokens to a quarantine account that holds a credential. The burner burns from holder B, a forced movement that lowers the supply.
>
> **No asset, no payment: only balances move.** Colours follow the movement kinds the rules see: MINT, TRANSFER or EXECUTED, FORCED. The burner's `burn` is FORCED too: these tokens have no holder's burn. The executor contracts hold no tokens; they submit the holder's signed intent. [One movement](movement.md) follows each kind through the rules.

| Who | Can move a holder's tokens by | Limits |
|---|---|---|
| The holder | `transfer` | The unfrozen balance, and the rules judge both sides. On a token that lists `ExecutedOnlyRule`, a plain transfer is refused. |
| A spender | `transferFrom`, with an allowance set by `approve` or by a signed `permit` | As for the holder, plus the allowance. |
| An executor contract (`EXECUTOR_ROLE`) | `executeTransfer(intent, sig)` | With the holder's signature, once per nonce, inside its validity window, and only if the intent names this executor or none. |
| The agent (`AGENT_ROLE`) | `forcedTransfer(from, to, amount)` | Up to the whole balance, frozen part included, also while paused. The receiver must hold a credential the policy accepts and must not be address-frozen. |
| The burner (`BURNER_ROLE`) | `burn(from, amount)` | No allowance needed. Up to the whole balance, frozen part included, also while paused. An address-frozen or locked-up holder can be burned from. |

An intent can state what its signer is to receive (`considerationToken`, `considerationAmount`). The token does not move it and does not check that it was paid. It refuses a stated consideration that names no executor (`CONSIDERATION_NEEDS_EXECUTOR`), so that the named executor is the one that can run it. `IntentExecutor` refuses every intent that states one (`IntentExecutor_ConsiderationNotSupported`), because it cannot enforce a payment. `DvPExecutor` is the one that does, below. Gas is paid by whoever sends the transaction, which for an intent is the operator, not the holder.

<a id="v4626"></a>
## `Gated4626Vault`: assets in, shares out

A **vault** takes in an asset and issues **shares**, a claim on part of what it holds. [`Gated4626Vault`](contracts/Gated4626Vault.md) is OpenZeppelin's ERC-4626 vault with gated shares. With no portfolio plugged it keeps the asset itself, and a deposit or a redemption happens in one call.

> **Diagram.** 4626 vault with no portfolio. Deposit: the payer's assets move into the vault by transferFrom, then new shares are minted to the receiver. Redemption: the owner's shares are burned, then assets move from the vault to the receiver by transfer. The vault holds the asset, and totalAssets is its balance.
>
> **The asset is pulled before shares are minted, and paid out after shares are burned.** If the hook rejects the share movement, the whole call reverts, the asset transfer included. On a deposit the hook judges the receiver of the shares; on a redemption, the owner. A payer other than the receiver, or a receiver of cash other than the owner, must pass a zero-amount enforcement probe of the token's policy, or the call reverts with `GatedVault_ThirdPartyNotEligible(account, reason)`. A holder paying itself is not judged, so a lapsed holder can leave.

### The price

OpenZeppelin's formulas, with a decimals offset of 6. The offset adds a million virtual shares and one virtual unit of asset, which makes the first-depositor donation attack unprofitable. With no portfolio, `totalAssets` is the vault's own balance of the asset.

*OpenZeppelin ERC4626Upgradeable, \_decimalsOffset() = 6*

```
shares = assets × (totalSupply + 10^6) / (totalAssets + 1)
assets = shares × (totalAssets + 1) / (totalSupply + 10^6)
totalAssets = asset.balanceOf(vault)
```

| Call | Converts | Rounds | Effect of rounding |
|---|---|---|---|
| `deposit(assets, receiver)` | assets to shares | down | the receiver gets slightly fewer shares |
| `mint(shares, receiver)` | shares to assets | up | the caller pays slightly more |
| `withdraw(assets, receiver, owner)` | assets to shares | up | slightly more shares are burned |
| `redeem(shares, receiver, owner)` | shares to assets | down | slightly fewer assets are paid |
| `maxWithdraw(owner)` | `maxRedeem(owner)` to assets | down | does not promise more than `withdraw` can deliver |

Each rounding favours the vault, and the dust stays in it, so it raises the value of every share a little. The price also moves when someone sends the asset straight to the vault, and if the asset's own balance changes.

Example with a 6-decimal asset and an empty vault, so shares have 12 decimals. A deposit of 1,000 assets (`1000e6` raw) mints `1000e6 × 10^6 / 1 = 1e15` raw shares, which is 1,000 shares. Redeeming all of them pays `1e15 × (1000e6 + 1) / (1e15 + 10^6) = 1000e6`: the 1,000 assets come back in full. If someone instead sends 100 assets straight to the vault before the redemption, `totalAssets` reads 1,100, and redeeming all the shares pays `1e15 × (1100e6 + 1) / (1e15 + 10^6) = 1099999999` raw, 1,099.999999 assets.

### Who can move what

- **The asset in the vault** leaves through `withdraw` and `redeem`, which burn the owner's shares. The caller must be the owner or hold an allowance on its shares. No other function pays it to an account. `setPortfolio`, by the main timelock, forwards it to a portfolio. An upgrade, through the timelock to attested code, could change all of this.
- **The shares** move like any gated balance: the holder, a spender, and the agent's `forcedTransfer`. The issuer's `mint` and `burn` of an address and an amount revert on the vault (`GatedVault_Unsupported`).
- **A frozen amount** cannot be redeemed: `maxRedeem` is the unfrozen balance.

<a id="v4626-portfolio"></a>
## `Gated4626Vault` investing through a portfolio

With a [`Portfolio`](contracts/Portfolio.md) plugged (`setPortfolio(portfolio, maxRateBps)`, the main timelock), the vault holds no working money. A deposit passes through it to the portfolio, and a withdrawal raises the money back first. The vault refuses a portfolio that accepts reported adapters (`Gated4626Vault_PortfolioRefused`), because on an instant vault a stale price is free money for whoever notices first. So its adapters are priced on-chain, such as an [`ERC4626Adapter`](contracts/ERC4626Adapter.md) over an outside vault.

> **Diagram.** 4626 with a portfolio, as a sequence. Deposit: 1, the investor's assets move into the vault. 2, new shares are minted to the investor. 3, the vault forwards the assets to the portfolio. Allocator: 4, the portfolio sends assets to the ERC4626Adapter. 5, the adapter deposits them in the outside vault and holds its shares. Withdrawal: 6, if idle money is short, the outside vault pays assets back to the portfolio. 7, the vault pulls the assets from the portfolio. 8, the investor's shares are burned. 9, the vault pays the assets to the investor.
>
> **The vault holds the money only inside a call.** Step 3 ends a deposit, with the money idle in the portfolio. Steps 4 and 5 are a separate call by an account with `ALLOCATOR_ROLE` on the vault. In step 6 `raise` draws the shortfall from the one adapter set with `setLiquidityAdapter`. In step 7 the vault uses the unlimited allowance the portfolio gave it at construction. Between calls the adapter holds the outside vault's shares, and the portfolio holds the idle money.

### The price

The formula is the same, but `totalAssets()` is a counted value, not a balance. Losses count at once. Gains count only up to a yearly rate, so a donation to the portfolio cannot jump the price, and in one block a second count adds nothing. Each deposit and withdrawal counts first (`accrue` does the same for anyone), then moves `last` by exactly its amount, so a price quoted is the price paid.

*Gated4626Common: \_counting and \_accrue*

```
net     = pricedValue() − feesOwed, stopping at zero
limit   = last + last × maxRate × elapsed / (10,000 × 365 days)
counted = min(net, limit)
fee     = feeModel.quote(counted, supply, mark, markAge, feeAge, paidSinceMark)   zero with no fee model
totalAssets() = counted − fee
while priceFresh() is false: totalAssets() = last, and no fee
```

Example with a 6-decimal asset and a limit of 1,000 basis points (10% a year). A deposit of 1,000,000 assets puts `last` at 1,000,000 and the money in the portfolio. A day later someone sends 10,000 assets straight to the portfolio, so `pricedValue()` reads 1,010,000. The limit is `1000000e6 + 1000000e6 × 1000 × 1 day / (10000 × 365 days)`, which rounds down to 1,000,273.972602, so that is `totalAssets()`. A loss works the other way: had `pricedValue()` then fallen to 910,000, `totalAssets()` would read 910,000 at once.

- **No price, no dealing.** While `priceFresh()` is false, `maxDeposit`, `maxMint`, `maxRedeem` and `maxWithdraw` read 0, and the last counted value stands. The same four read 0 while the value net of fees reads nothing although a value was counted and `1e6` share units or more exist: `totalAssets()` reads 0, nothing is written down, and the value can come back under the limit.
- **No shares, no price.** With no shares, or fewer than `1e6` share units, which own less than one unit of the asset at par between them, and while the price can be read, `totalAssets()` is 0, however much the portfolio holds. The next investor buys at par, or for as little as about half par when the dust is close to `1e6` units, the mark restarts at par, and what was left counts for them under the limit.
- **Exits are limited by what can be raised.** `maxRedeem` and `maxWithdraw` stop at `liquidAssets()`: the idle money plus what the liquidity adapter can return.
- **A write-off is for good, and so is a large fall.** Once a portfolio has written off an adapter (`writeOffAdapter`), or a count has found the value fallen by more than half, `maxDeposit` and `maxMint` read 0 and `exitOnly()` reads true, also after a replacement portfolio, so a later depositor does not take part of a recovery from the holders who bore the loss.
- **Fees.** A [`FeeModel`](contracts/FeeModel.md) (`setFeeModel`, the timelock) quotes on the counted value, so a gain pays only once it has passed the limit. Fees go into `feesOwed`, and `collectFees()`, which anyone can call while the vault is not paused, pays the model's `RECIPIENT` what idle money allows.
- **Plugging and replacing.** A first `setPortfolio` forwards what the vault held and counts it. A replacement needs the outgoing portfolio to have no adapter on its list and to read zero (`Gated4626Vault_PortfolioNotEmpty`), which `migrateTo` leaves it doing. So a position that cannot be read, or that its target will not pay out, has to be written off first, which leaves the vault exit-only. A replacement keeps the price and the limit's clock, so the next count allows what it would have allowed anyway. The portfolio must hold the vault's asset (`Gated4626Vault_PortfolioRefused`).

<a id="v7540"></a>
## `Gated7540Vault`: a dealing period

[`Gated7540Vault`](contracts/Gated7540Vault.md) is asynchronous (ERC-7540) and deals in periods. One period is open, and requests join it. A request is booked under a **controller**, the account entitled to claim it. When a period closes and is settled, everyone in it gets one price, in one transaction however many investors there are, and each claims later. Between settlements the working money is outside the vault, with a **cash account**: a `Portfolio` where one is plugged into the desk, otherwise the desk's `custodianAccount`.

> **Diagram.** One dealing period. Open: 1, an investor's assets move into the vault with requestDeposit, booked in pendingDeposits. 2, an investor's shares move into escrow at the vault's own address with requestRedeem, a transfer. Closed: closePeriod moves nothing, and requests join the next period. Settled: 3, the escrowed shares the settlement takes are burned, and any others stay in escrow for the next period. 4, the difference between deposits and assets plus fee moves to the cash account, or from it. 5, the fee goes to the fee recipient. 6, the vault must hold at least pendingDeposits plus claimableCash. Claimed: 7, deposit or mint mints shares to the receiver. 8, redeem or withdraw pays assets to the receiver.
>
> **Settlement moves only the difference.** Solid lines carry the asset, coloured dashed lines carry shares. Subscriptions pay redemptions, so in step 4 one line runs, or the other, or neither when they are equal. After steps 4 and 5 the vault holds exactly the period's payout on top of what it already held for others. Shares bought are not minted until step 7. Steps 7 and 8 happen when each controller chooses, in any order.

### Where things sit, and who can move them

| Stage | Asset | Shares | Who can move it next |
|---|---|---|---|
| Open | Deposit money in the vault, in `pendingDeposits` | Redeemed shares in escrow at the vault's own address, in `pendingRedeemShares` | Agent (`AGENT_ROLE`): `rejectDepositRequest` returns the assets to the controller, not to the owner who paid; `rejectRedeemRequest` returns the shares to the controller as an ordinary transfer; `recoverRedeemRequest(controller, to)` moves them to `to` as a forced move. There is no cancel by the requester. |
| Closed | As open. Requests made since wait in the next period | As open | Settler (`SETTLER_ROLE`, the desk): `settlePeriod`, or the same rejects and recovery. A controller with a request in the closed period cannot add to it (`Gated7540Vault_EarlierRequestUnsettled`). |
| Settled | Net inflow with the cash account; the payout for the shares taken in the vault, in `claimableCash` | Shares taken burned; any part carried stays in escrow, pending in the next period. Shares bought not minted yet, in `unclaimedShares` | Controller or its operator: claim with `deposit`, `mint`, `redeem` or `withdraw`, choosing the receiver. A receiver of cash other than the controller must pass the policy. Agent: `recoverClaimable(controller, to)` pays the assets to `to` and delivers the shares to it as an enforcement mint. Whoever controls the cash account decides what happens to the money there. |
| Claimed | At the receiver | At the receiver: a mint through the hook, so the rules judge it like any mint | As any holder. |

- **Who can pay in.** `requestDeposit(assets, controller, owner)` pulls from `owner`, who must be the caller or have approved the caller as an operator. An owner other than the controller must pass the policy (`GatedVault_ThirdPartyNotEligible`). The controller must pass a mint probe (`Gated7540Vault_ControllerNotEligible`), because the request cannot be cancelled.
- **The escrow is one balance** at the vault's address for every controller, while the bookkeeping is per controller. The agent's `forcedTransfer` out of that address may take only shares above `pendingRedeemShares` (`Gated7540Vault_ExceedsSurplus` otherwise), and `setFrozenTokens` refuses that address (`GatedVault_Unsupported`). For escrowed shares the agent's tool is `recoverRedeemRequest`.
- **Operators are full delegates.** An account approved with `setOperator` can open requests that pull the owner's assets or shares under any controller, and choose the receiver of a claim, as ERC-7540 specifies.
- **The balance audit** is the last thing `settlePeriod` does. It reverts with `Gated7540Vault_BalanceAudit(held, owed)` unless the vault's asset balance is at least `pendingDeposits + claimableCash`, so a period cannot settle while the vault is short of what it owes. A cash account that is short, or has not approved the vault, makes the pull revert first. A `Portfolio` approved its vault at construction.
- **During a pause.** `settlePeriod` and the redemption claims revert with `EnforcedPause`. `requestDeposit` and the deposit claims revert with `Gated7540Vault_ControllerNotEligible(PAUSED)`, and `requestRedeem` and `rejectRedeemRequest` with `ERC8473PolicyRejected(PAUSED)`. `closePeriod`, `rejectDepositRequest`, `recoverRedeemRequest` and `recoverClaimable` still work.

<a id="prices7540"></a>
## 7540 prices, rounding and a worked example

A period has one price, from the net asset value (NAV) that `settlePeriod(nav, fee, cash, feeRecipient, redeemLimit)` is given and the shares in existence. The `nav` leaves out what the vault itself holds, pending deposits and claimable redemption cash, because that money belongs to investors and is not invested. `decimals()` is the asset's plus 6, as on the 4626.

*Struck once per period (\_strike), rounding down*

```
supply   = totalSupply() + unclaimedShares
redeemed = the smaller of redemptions and redeemLimit
shares   = deposits × (supply + 10^6) / (nav + 1)
assets   = redeemed × (nav + 1) / (supply + 10^6)
```

*Then netted (\_net)*

```
out = assets + fee
deposits > out:  send deposits − out to cash
out > deposits:  pull out − deposits from cash
pay fee to feeRecipient
revert unless balance ≥ pendingDeposits + claimableCash
```

**A settlement can take part of a period's redemptions.** Past `redeemLimit` every request is filled at the same fraction. The rest stays in escrow and in the supply, joins the next period's book and deals at that period's price. Only the shares taken burn and are paid, so the cash account funds less. With a desk the limit is the level's share of all shares plus the shares the period's deposits buy. [The 7540 page works an example](contracts/Gated7540Vault.md#part-fills).

`PeriodSettled(period, nav, supply, deposits, shares, redemptions, redeemed, assets, fee)` puts the NAV history on-chain. `convertToShares`, `convertToAssets` and `totalAssets` use the last settlement's value and count unclaimed shares, so they are indicative. `previewDeposit`, `previewMint`, `previewRedeem` and `previewWithdraw` revert with `Gated7540Vault_AsyncOnly`, as ERC-7540 requires.

### A worked example

A 6-decimal asset, so shares have 12 decimals. Amounts are in whole units; the raw calls use `1000e6` assets and `200e12` shares. The desk has a cash account that has approved the vault and a `FeeModel` charging 10% on performance, with no management fee and no hurdle. No minimum position and no redemption gate are set. The figures are the formulas above in raw units.

*The three prices*

```
Period 1: nothing invested. The reporter reports 0, supply is 0, and with no shares there is no fee.
shares = 1000e6 × (0 + 10^6) / (0 + 1)                    = 1e15 raw = 1,000 shares

Period 2: the cash account's investments gained 110, and the reporter reports 1,110.
Fee: price 1.11 per share, mark 1.00, 10% × 0.11 × 1,000 shares = 11. So nav = 1,110 − 11 = 1,099. Supply is 1,000.
shares = 500e6 × (1e15 + 10^6) / (1099e6 + 1)             = 454959053726151 raw = 454.959053726151 shares
assets = 200e12 × (1099e6 + 1) / (1e15 + 10^6)            = 219799999 raw       = 219.799999 assets
out    = 219.799999 + 11 = 230.799999; deposits 500 are more, so 269.200001 goes to the cash account

Period 3: no gain. The reporter reports 1,379.200001, and the fee rounds down to 0. Supply is 1,254.959053726151.
assets = 300e12 × (1379200001 + 1) / (1254959053726151 + 10^6) = 329700000 raw = 329.7 assets
out    = 329.7; deposits are 0, so 329.7 is pulled from the cash account
```

### Where the assets sit

| Step | Alice | Bob | Vault | Cash account | Fee recipient |
|---|---|---|---|---|---|
| start | 1,000 | 500 | 0 | 0 | 0 |
| P1 `requestDeposit(1000, alice, alice)` | 0 | 500 | 1,000 | 0 | 0 |
| P1 settled at `nav` 0 | 0 | 500 | 0 | 1,000 | 0 |
| the investments gain 110 | 0 | 500 | 0 | 1,110 | 0 |
| P2 `requestDeposit(500, bob, bob)` | 0 | 0 | 500 | 1,110 | 0 |
| P2 settled at `nav` 1,099, fee 11 | 0 | 0 | 219.799999 | 1,379.200001 | 11 |
| P2 `redeem(200, alice, alice)` | 219.799999 | 0 | 0 | 1,379.200001 | 11 |
| P3 settled at `nav` 1,379.200001 | 219.799999 | 0 | 329.7 | 1,049.500001 | 11 |
| P3 `redeem(300, alice, alice)` | 549.499999 | 0 | 0 | 1,049.500001 | 11 |

### Where the shares sit

| Step | Alice | Bob | Escrow | `totalSupply` | `unclaimedShares` |
|---|---|---|---|---|---|
| P1 settled | 0 | 0 | 0 | 0 | 1,000 |
| P1 `deposit(1000, alice, alice)` | 1,000 | 0 | 0 | 1,000 | 0 |
| P2 `requestRedeem(200, alice, alice)` | 800 | 0 | 200 | 1,000 | 0 |
| P2 settled | 800 | 0 | 0 | 800 | 454.959053726151 |
| P2 `deposit(500, bob, bob)` | 800 | 454.959053726151 | 0 | 1,254.959053726151 | 0 |
| P3 `requestRedeem(300, alice, alice)` | 500 | 454.959053726151 | 300 | 1,254.959053726151 | 0 |
| P3 settled | 500 | 454.959053726151 | 0 | 954.959053726151 | 0 |

> **Diagram.** The two settlements of the example that moved money. Period 2, net inflow: the vault holds 500 of deposits, sends 269.200001 to the cash account and 11 to the fee recipient, and 219.799999 stays as claimable cash. Period 3, net outflow: the vault holds nothing, the cash account sends 329.7 to the vault, and it stays as claimable cash.
>
> **Subscriptions pay redemptions and the fee.** In period 2 Bob's 500 covered Alice's redemption and the fee, and the cash account received the rest. Afterwards the cash account's 1,379.200001, divided by the 1,254.959053726151 shares, is still a price of about 1.099. In period 3 nobody subscribed, so the money came from the cash account.

### Claims and rounding

A claim takes from the controller's own pair of what it paid and what that bought. Each controller's share of a period rounds down when it rolls into that pair, so at most one share unit per investor per period stays in `unclaimedShares`. For example, a period where 3 raw assets bought 10 raw shares gives an investor who paid 1 `floor(1 × 10 / 3) = 3`, and one who paid 2 `floor(2 × 10 / 3) = 6`; the last unit stays unclaimed. On the redemption side the same rounding leaves a unit of the asset in `claimableCash`.

*Claims: given what was paid, the other side rounds down; given what is owed, the paid side rounds up*

```
deposit(assets)   shares = floor(assets × owed / paid)     on the deposit side, paid is assets and owed is shares
mint(shares)      assets = ceil(shares × paid / owed)
redeem(shares)    assets = floor(shares × owed / paid)     on the redemption side, paid is shares and owed is assets
withdraw(assets)  shares = ceil(assets × paid / owed)
```

A claim of everything is exact, because the division has nothing to round. In raw units:

- A deposit pair of 1,000 assets and 800 shares. `deposit(333)` mints `floor(333 × 800 / 1000) = 266` shares and leaves 667 and 534. `mint(267)` then uses `ceil(267 × 667 / 534) = 334` assets.
- A redemption pair of 7 shares and 10 assets. `redeem(3)` pays `floor(3 × 10 / 7) = 4` assets. From the same pair, `withdraw(4)` uses `ceil(4 × 7 / 10) = 3` shares.

A zero input reverts with `Gated7540Vault_ZeroAmount` on all four claims, and so does a `deposit` that would mint 0 shares or a `redeem` that would pay 0 assets. If the shares claimed, added to what the receiver holds, come to less than a minimum position, the claim reverts with `BELOW_MIN_POSITION` and the claimable stays, until the agent's `recoverClaimable` delivers it.

<a id="desk"></a>
## The desk: who decides the price

[`NavDesk`](contracts/NavDesk.md) is one contract per 7540 vault. It holds no money and keeps no role table: it holds the vault's `SETTLER_ROLE` and asks the vault for everyone else's roles at call time. It turns a reported value into an approved price, in five steps.

1. **Cut-off.** `closePeriod()`: anyone, once `periodLength` has passed since `lastCutoff`. It closes the vault's open period. No role decides it.
2. **Report.** `propose(reported, reportHash, asOf, moves)`: the vault's `REPORTER_ROLE`, one proposal at a time. `asOf` must be no earlier than the cut-off and not in the future. The contract checks this stated date, not when the value was worked out. `moves` must equal the portfolio's count (`NavDesk_MovesChanged`), so a proposal that states an earlier count is refused, and an allocation or deallocation after the valuation does not count twice. The contract cannot tell whether the stated count is the one the report used. The desk works out `gross = reported + pricedValue()`, the fee from its `FeeModel`, `nav = gross − fee` and the redemption limit, and freezes them all in the proposal.
3. **Second person.** `accept(proposalHash)`: the vault's `CHECKER_ROLE`, not the proposer (`NavDesk_SelfAccept`). The hash covers the period, the value, the fee, the mark and its clock, the report and its date, the cash account, the fee recipient and the redemption limit.
4. **Wait.** The `cooldown`, between 1 hour and 3 days, counted from the proposal, not from the acceptance, so a checker who accepts after it has run leaves no wait before `execute()`. `cancel()`: `GUARDIAN_ROLE` or `CHECKER_ROLE`, any time before execution.
5. **Settle.** `execute()`: anyone, after acceptance and the cooldown, with a report no older than `maxReportAge` (`NavDesk_StaleReport`). It calls `settlePeriod(nav, fee, cash, feeRecipient, redeemLimit)` with the frozen figures.

The fee is worked out on the gross value by [`FeeModel.quote`](contracts/FeeModel.md): a management fee of gross × rate × time, then a performance fee on the price above a high-water mark and any hurdle. In the worked example the mark starts at 1.00 per share; period 2's price of 1.11 pays 10% of the 0.11 above it, and the mark moves to 1.099. With no shares there is no fee, the period strikes at par whatever is reported or sits in the portfolio, and the mark restarts at par.

With a portfolio, the portfolio is both the cash account and the source of on-chain value, and its prices must be fresh (`NavDesk_PriceNotFresh`). `nav` must be above zero while `1e6` share units or more exist (`NavDesk_ZeroNav`). If nothing can be approved, the period stays closed: a dealing suspension, with requests made since waiting in the next period. Once the period has been closed for longer than `maxReportAge` with no proposal on the table, `refundRequest` and `recoverRequest` (the vault's `AGENT_ROLE`) forward to the vault's reject and recovery, one controller at a time, so money that was not invested can go back.

The vault does not check who holds `SETTLER_ROLE`. Whoever holds it sets any price, any fee and any redemption limit, and names the cash account and the fee recipient: a net inflow and the fee go to the addresses it names, with no approval from them, and a net outflow is pulled from a cash account that approved the vault. The role belongs to a desk, and `NavDesk.isWired()` shows monitors that it does. The timelock can grant it to anyone, delayed and visibly. The `full` profile, for tests, gives it to a plain account.

<a id="portfolio"></a>
## A portfolio's adapters

A [`Portfolio`](contracts/Portfolio.md) is where one vault's money may go: its idle money and adapters, under caps on their allocation. From the portfolio it can return to the vault, pay the fee model's `RECIPIENT` through `collectFees`, or move to an attested successor with `migrateTo`. One portfolio serves one vault. It keeps no role table and asks the vault at call time, so a revoked role stops working at once. An **adapter** is the plug between the portfolio and one place money can go, and the way back out of an adapter is to its own portfolio, because `deallocate` names no receiver.

> **Diagram.** A portfolio and its adapters. The vault and the portfolio exchange assets: deposits and net inflow come in, and the vault pulls by its allowance. The portfolio sends assets to an ERC4626Adapter and takes them back with allocate and deallocate; the adapter deposits in and withdraws from an outside vault. The portfolio also allocates to and deallocates from a GuardedAccount, which sends assets to a custodian with execute, using transfer; the custodian sends them back off-chain. With no adapters installed, migrateTo moves the idle money to a successor portfolio.
>
> **Every arrow out of the portfolio goes to an installed adapter, the vault, or an attested successor.** Not drawn: `collectFees`, where the vault's allowance pays the fee model's `RECIPIENT` straight from the portfolio. The dashed arrow is the custodian's own act, which no contract can compel. `pricedValue()` counts the idle money and priced adapters; a reported adapter's value is in the report.

| Who, on the vault | Can | Limits |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` (the main timelock) | `addAdapter`, `removeAdapter`, `writeOffAdapter`, `setCaps`, `migrateTo`; on an account, `setPermission` and `revokePermission` | An adapter must be attested as `ADAPTER` in the vault's registry, serve this portfolio and asset, and name a risk. A successor must be attested as `PORTFOLIO`, for the same vault and asset. |
| `ALLOCATOR_ROLE` | `allocate`, `deallocate`, `setLiquidityAdapter`; on an account, `execute` | Installed adapters, with the allocation under the caps of every risk the adapter names. `allocate` and `execute` revert while the vault is paused; `deallocate` does not. |
| `GUARDIAN_ROLE` | `deallocate`; `setCaps` and `revokePermission` to reduce risk | It can lower both numbers of a cap, and neither may rise. It can pull money back and cannot send any out. |
| The vault itself | `raise(assets)`, and pull idle money through its allowance | The 4626 pulls for a withdrawal and for `collectFees`; the 7540 for a net outflow. Because that allowance is unlimited, whoever can upgrade the vault could take the idle money: an upgrade goes through the timelock, which makes it public first. |

### Caps

Each risk id has an absolute cap and a relative cap against the vault's `totalAssets()` (10,000 basis points is no limit). A cap left at zero allows nothing. An adapter counts against one risk of its own and optionally one it shares with other adapters. Caps are checked on `allocate` and on install (`Portfolio_CapExceeded`), so an exit or a gain can leave a risk above its relative cap. `allocate` also takes a minimum, `_minAdded`: for a priced adapter, the least its value must grow, so a fee taken on the way in shows up (`Portfolio_ShortAllocation`). `deallocate` reverts if less comes back than was asked (`Portfolio_ShortReturn`).

### A custodian is a `GuardedAccount`

[`GuardedAccount`](contracts/GuardedAccount.md) is a reported adapter that makes plain calls only: no delegatecall, no value, no modules. Each call needs a permission for its target and function, and the permission's validator must accept the parameters; no validator means refused (`GuardedAccount_CallRefused`). It can be built only on a portfolio that accepts reported adapters (`GuardedAccount_ReportedNotAccepted`), and a 4626 refuses such a portfolio, so custody sits behind a 7540. Money reaches a custodian like this:

1. **Set up.** The security council attests the account as `ADAPTER` and an [`ERC20CallValidator`](contracts/ERC20CallValidator.md) as `VALIDATOR`. The validator's settings are fixed at construction: one address (`WHO`) and the most one call may name (`MAX_PER_CALL`). The timelock runs `addAdapter`, `setCaps`, and `setPermission(asset, transfer selector, validator)`. A permission cannot name the account's own portfolio, its vault, or itself (`GuardedAccount_ForbiddenTarget`).
2. **Allocate.** The allocator's `allocate` sends idle money to the account. It stays there, and counts against the caps.
3. **Send.** The allocator's `execute` with the asset's `transfer(custodian, amount)` moves it to the custodian. The validator checks the receiver and the amount of that one call. Several calls can each reach the limit, so what bounds the total is what the account holds.
4. **Report.** The account's `value()` is 0 and `reported()` is true. What it and the custodian hold reaches the price only through the reporter's figure.
5. **Bring back.** The custodian sends the money to the account, on its own initiative and terms. Then `deallocate(account, assets)`, by the allocator or the guardian, pays it from the account's own balance to the portfolio.

[`ERC4626CallValidator`](contracts/ERC4626CallValidator.md) is the other shipped validator: it lets a strategy account call `deposit`, `mint`, `withdraw` and `redeem` on an outside vault when the receiver and owner are the account itself. `revokePermission` is the timelock's or the guardian's. A `GuardedAccount` is the most dangerous adapter here: it makes whatever calls its permissions allow, and an `approve` gives the spender up to what the validator allows. Each permission set needs its own review.

A `writeOffAdapter` takes an adapter off the list with whatever it holds. A priced adapter qualifies only while it cannot be priced or cannot pay out what it is priced at, `liquid()` below `value()`, and is otherwise refused with `Portfolio_StillPriced`; a reported one qualifies at any time. On a 4626 it leaves the vault exit-only, as above.

<a id="dvp-gated"></a>
## Delivery versus payment, with gated cash

**Delivery versus payment** (DvP) means the security and the cash change hands together or not at all. [`DvPExecutor`](contracts/DvPExecutor.md) does it for a security that carries signed intents, such as `IntentToken`. In this form the cash is itself a gated token with intents. Each party signs an intent on the token it gives: the seller on the security, the buyer on the cash, each naming the DvP executor and stating what it is to receive. The executor needs `EXECUTOR_ROLE` on both tokens, which each token's own administrator grants.

> **Diagram.** DvP with gated cash. The operator submits executeDvPGated to the DvP executor, which checks that the two signed legs mirror each other. It runs the cash leg first: the price moves from the buyer to the seller on the cash token. Then the securities leg: the shares move from the seller to the buyer on the security token. The executor holds nothing.
>
> **Both legs or neither, and the executor holds neither.** Each leg is an EXECUTED move on its own token, under that token's own rules. If either fails, the whole transaction reverts with `DvPExecutor_LegFailed(leg, reason)`, where `reason` is the token's revert data.

The legs **mirror** when the parties are swapped, each amount is the other leg's stated consideration, each stated consideration token is the other leg's token, and the two tokens differ (`DvPExecutor_LegsDoNotMatch`). Each signature covers its own leg, so the operator chooses which signed legs to pair and when to submit, and cannot change a figure. A leg that states a payment cannot run alone: `IntentExecutor` refuses it, and the token refuses an executor other than the one it names (`WRONG_EXECUTOR`).

<a id="dvp-3009"></a>
## Delivery versus payment, with ERC-3009 cash

ERC-3009 is a draft standard for signed token transfers, and the executor was written against the `bytes` signature form of `receiveWithAuthorization`. Here the buyer signs a `receiveWithAuthorization` payable to the DvP executor, for the price, with a nonce that ties it to this one trade: `keccak256(abi.encode(securityToken, securitiesIntentHash))`. The cash passes through the executor inside the one call. The cash token's own rules apply, and this stack's hook does not see it.

> **Diagram.** DvP with ERC-3009 cash. The operator submits executeDvP3009. 1, the executor pulls the price from the buyer with receiveWithAuthorization. 2, it runs the seller's intent on the security token: the shares move from the seller to the buyer. 3, it transfers the price to the seller. 4, it checks that its own cash balance is back where it started and that the seller's rose by exactly the price.
>
> **The cash passes through the executor and must leave it in the same call.** A shortfall reverts the whole trade with `DvPExecutor_CashNotConserved(account, expected, actual)`, or earlier with the cash token's own error, so a fee-on-transfer cash token fails the trade.

The authorization must come from the seller's buyer (the intent's `to`), for the seller's stated consideration, in the stated cash token, with the nonce above, and the two tokens must differ (`DvPExecutor_LegsDoNotMatch`). The security token's address is in the nonce because the executor cannot tell an honest token's intent hash from a counterfeit's. A failing pull or delivery reverts with `DvPExecutor_LegFailed`. A failing payout to the seller is not wrapped: it reverts with the cash token's own error, or with `SafeERC20FailedOperation` if the token returns false.

For tokens that implement the calls they make, the pre-flights `canExecuteDvPGated` and `canExecuteDvP3009` answer `(ok, reason)` without reverting: `PAUSED` for a paused executor, `LEGS_DO_NOT_MATCH`, then for ERC-3009 the authorization's window, nonce and the buyer's balance, then each leg's own `canExecute`. They do not check `OPERATOR_ROLE`, and for ERC-3009 cash they cannot check the buyer's signature.

<a id="signed-entry"></a>
## `SignedEntry`: entering with signatures, while a relayer pays the gas

[`SignedEntry`](contracts/SignedEntry.md) lets an investor with its own wallet enter a vault without sending a transaction. The investor signs an EIP-712 `Entry` (where, how much, the least it accepts, when) and, separately, the cash: an ERC-2612 `permit`, or an ERC-3009 authorization. Anyone can submit them. An entry whose flag matches a genuine vault leaves no money in the contract, and it has no roles.

> **Diagram.** SignedEntry as a sequence. 1, the investor gives the relayer two signatures off-chain. 2, the relayer calls enterWithPermit or enterWith3009. 3, the investor's assets move to SignedEntry within the call. 4, SignedEntry pays the vault with deposit or requestDeposit. 5, on a 4626 the vault mints shares to the investor; on a 7540 a request is booked under the investor as controller.
>
> **The money passes through inside one call.** Thin dashed lines are signatures and calls, the solid lines carry the asset, and the coloured line carries shares. On a 4626 the call reverts below the signed `minShares` (`SignedEntry_TooFewShares`). A request has no price yet, so an entry that names a minimum on a 7540 is refused (`SignedEntry_MinimumOnARequest`).

- **It is an ordinary third-party payer.** The vault's policy decides whether to accept it, so `SignedEntry` needs a credential on the vault's policy (`GatedVault_ThirdPartyNotEligible` otherwise), and on the asset's if the asset is gated.
- **What ties the cash to the entry.** An ERC-3009 authorization carries `cashNonce(entry)`, so it pays for this entry and no other. A `permit` is not bound the same way: one left unspent can pay for another entry of the same investor, which that investor also signed.
- **Who can stop it.** The investor's nonce is single use, `cancelEntry(nonce)` marks it used, and the deadline ends it. A relayer can hold a signed entry back until its deadline, so a short deadline is the investor's control. Nothing here pays the relayer.
- **Leaving** needs no such contract. On a 4626 a holder signs the share token's `permit`, and a relayer submits it with `redeem` through the token's `multicall`. On a 7540 the same route files `requestRedeem`. The later claim (`redeem`, `withdraw`) takes the controller or an operator it set with `setOperator`, and an allowance does not open it (`Gated7540Vault_Unauthorized`).

<a id="distributor"></a>
## `Distributor`: funding and paying a distribution

[`Distributor`](contracts/Distributor.md) pays one token's holders from a list built off-chain at the record date: a Merkle root of `(holder, amount)`. It asks the token for its roles at call time. The token gains no snapshots, and transfers cost the same. `Legos` deploys it for a product that sets `distributor`, and `Product` grants its maker and its checker on the token.

> **Diagram.** A distribution. 1, a maker proposes the root, the asset, the total, the expiry and the funder. 2, a different checker approves, and that call pulls the total from the funder into the Distributor. 3, each holder's share is paid to that holder with claim and a proof. 4, after the expiry, sweep returns what is left to the funder.
>
> **A distribution that can be claimed is one that was paid for.** The checker's approval pulls the funding, so without the funder's allowance and balance the approval reverts. Example: a total of 1,000 for holders A with 600, B with 300 and C with 100. A and B claim, and C may not receive. After the expiry, `sweep` returns `1,000 − 900 = 100` to the funder.

| Step | Who | What it refuses |
|---|---|---|
| `propose(root, asset, total, expiry, funder)` | The token's `DISTRIBUTION_MAKER_ROLE` | A zero root, asset, total or funder, or an expiry not in the future (`Distributor_InvalidValue`). |
| `approve(id)` | The token's `CHECKER_ROLE`, not the maker | An unknown id (`Distributor_NotApproved`), a second approval (`Distributor_AlreadyApproved`), a proposal past its expiry (`Distributor_Expired`), its own proposal (`Distributor_SelfApproval`). |
| `claim(id, holder, amount, proof)` | Anyone; the money goes to the holder | In this order: not approved, after the expiry (`Distributor_Expired`), a second claim (`Distributor_AlreadyClaimed`), a holder for whom `canReceive` is false (`Distributor_HolderMayNotReceive`), a bad proof (`Distributor_BadProof`), more than is left (`Distributor_OverFunding`). |
| `sweep(id)` | Anyone; the money goes to the funder | Not approved, or at or before the expiry (`Distributor_NotExpired`). |

The list is a claim, like a NAV report: the root proves which list two people approved, not that it is right. A list that sums above the funding pays first come, first served, until `Distributor_OverFunding`. `canReceive` is false while the token is paused, so claims stop during a pause, and the expiry still runs. A holder who does not claim gets nothing, and the money returns to the funder. If the asset is itself a gated token, the Distributor is an ordinary holder of it and needs a credential on its policy.

<a id="absent"></a>
## What the code does not have

- **Fees outside a fee model.** A token transfer, an intent, a DvP trade, a signed entry and a distribution charge nothing in these contracts. Fees come from a `FeeModel` on a 4626 with a portfolio or through a `NavDesk`; a plain account holding `SETTLER_ROLE` could name any fee in `settlePeriod`.
- **A tie between `migrateTo` and `setPortfolio`.** No contract makes them run together. Between two separate transactions the outgoing portfolio gives no price, so a 4626 holds its price and stops dealing until the plug.
- **A price feed, or proof that money exists.** A 4626 with a portfolio prices from its adapters, which ask the outside vault's `previewRedeem`. A 7540 prices from a report. `reportHash` proves which report was used, not that the money exists. A maker and a checker who collude can approve a wrong price. No contract compares either figure with an outside price.
- **Yield of its own.** No contract here earns interest. Returns come from an outside vault, a custodian or a strategy, and a bad one can lose what was allocated to it. An `ERC4626Adapter`'s attestation covers its target's address, not its behaviour, so the control on the target itself is whatever review comes before that attestation.
- **A way to make a custodian pay.** Money a custodian holds comes back off-chain. A custodian that does not return money is a risk no contract covers.
- **Recovery from a total loss.** A loss, an outage, a pause or short cash can stop settlement, and then requests wait. Beyond the desk's refund of what was not invested, a total loss is a wind-down, which the contracts do not perform.
- **ETH handling, outside the timelocks.** No contract of the system defines `receive` or a payable function. Each token proxy has OpenZeppelin's payable `fallback`, but it forwards to an implementation whose one payable function is `upgradeToAndCall`. That refuses value without setup data (`ERC1967NonPayable`), and with setup data the call it makes is to a non-payable function, which reverts (`test_WhenTheUpgraderAttachesEther_TheUpgradeReverts`; `test_WhenEtherIsSentPlainly_ItReverts` covers a plain send). OpenZeppelin's `TimelockController`, and so `GovernanceTimelock` and the recovery timelock, has `receive()` and a payable `execute`, so the two timelocks can hold ETH and send it with an operation.
- **A general sweep.** No contract has a function to recover an asset sent to it by mistake. The DvP executor says so in its NatSpec. A plain 4626 counts an asset sent to it as part of `totalAssets`, which raises the share price. With a portfolio plugged, an asset sent to the vault itself is not counted and stays there until a later `setPortfolio` forwards it. An asset sent to a portfolio counts under the rate limit. The 7540 vault pays out what its bookkeeping records, so an asset sent to it directly has no function that moves it. `Distributor.sweep` is narrower: it returns one distribution's unclaimed money. Tokens of the vault itself sent to its own address can be recovered by the agent's `forcedTransfer`.
- **A cancel for requests.** A 7540 requester cannot withdraw a pending request. The agent can reject it while its period is open and the settler once it has closed, and that is why a deposit request is refused up front when the controller could not hold the shares.
- **Automatic payment, or snapshots.** A distribution is claimed, not pushed, and the record date is whatever the off-chain list says.
- **DvP matching, partial fills or more than two legs.** The parties agree a DvP trade off-chain and sign fixed amounts.
- **A ledger between vaults.** One portfolio serves one vault, and a 7540 and a 4626 do not share money.

<a id="why"></a>
## Why it is built this way

- **The vault's hook does not see the asset leg.** The rules decide who may hold the gated token; the asset is an ERC-20 under its own issuer's rules. Gating the share movement is enough to gate entry and exit: a deposit is a MINT to the receiver and a redemption a BURN from the owner, and the third-party check covers who pays and who collects.
- **Asset in first, out last.** The 4626 vault pulls the asset before minting and burns before paying, OpenZeppelin's order, so a rejection or a re-entering asset token finds a consistent state.
- **One price per period, one transaction.** Everyone in a period deals at one value, and settlement does not loop over investors (`test_SettlementCostsTheSameFor1InvestorAnd200`). Shares are minted at the claim, so no rule judging one investor can block a whole period's settlement.
- **Netting.** Moving only the difference means subscriptions pay redemptions and the fee, and the cash account sees one transfer at most.
- **A limit fills every request alike.** Past a limit each request in a period takes the same fraction, so being first earns nothing, and the rest stays invested until a later price takes it.
- **Two people and a wait on every price.** A cut-off no role picks, a report stated as struck after it, a checker who is not the reporter, and a cooldown in which the guardian can cancel make a wrong price harder and traceable.
- **Gains count slowly, losses at once.** On an instant vault anyone can act on the price within a block, so a sudden gain would be free money for whoever enters first.
- **A portfolio per vault, with default deny.** There is no ledger between vaults to get wrong. Money leaves a portfolio only to attested adapters, under caps on their allocation, to its own vault, to the fee model's `RECIPIENT` through `collectFees`, or to an attested successor. A guarded account refuses any call without a permission and a validator.
- **Rounding against the caller, exact in full.** Partial claims round so the vault does not pay more than it holds for that claim, and a full claim clears the pair exactly.
- **The DvP executor keeps nothing.** Gated cash moves directly between the parties; ERC-3009 cash passes through within one call, and the balance checks make any leak revert the trade.
- **`SignedEntry` changes no vault.** A vault judges it like any other payer, so the policy stays in one place.
- **Funding at approval.** A distribution that can be claimed has its money in the contract already, and the token's transfers carry no snapshot cost.

<a id="connected"></a>
## Connected to

- [Gated4626Vault](contracts/Gated4626Vault.md): The instant vault, its gating-aware `max*` views and its plug for a portfolio.
- [Gated7540Vault](contracts/Gated7540Vault.md): Requests, periods, settlement, claims, rejects and recoveries.
- [NavDesk](contracts/NavDesk.md): Turns a reported value into an approved price.
- [FeeModel](contracts/FeeModel.md): Works out management and performance fees.
- [Portfolio](contracts/Portfolio.md): Where one vault's money may go.
- [ERC4626Adapter](contracts/ERC4626Adapter.md): A priced position in an outside vault.
- [GuardedAccount](contracts/GuardedAccount.md): A custodian or a strategy, reported, with default deny.
- [DvPExecutor](contracts/DvPExecutor.md): Atomic settlement of a security against cash.
- [SignedEntry](contracts/SignedEntry.md): Entering a vault with signatures.
- [Distributor](contracts/Distributor.md): Pays a funded distribution to holders who claim.
- [IntentToken](contracts/IntentToken.md): The token whose balances are the record.
- [One movement](movement.md): What the rules do with each share movement.
- [Who can do what](roles.md): The roles that move value, and what still works during a pause.

<a id="source"></a>
## Source and tests

- Vaults: `GatedVaultBase.sol`, `Gated4626Vault.sol`, `Gated4626Management.sol`, `Gated4626Common.sol`, `Gated7540Vault.sol`, `Gated7540Settlement.sol`, `Gated7540Common.sol`
- Pricing and money's destinations: `NavDesk.sol`, `FeeModel.sol`, `Portfolio.sol`, `ERC4626Adapter.sol`, `GuardedAccount.sol`, `ERC20CallValidator.sol`, `ERC4626CallValidator.sol`
- Settlement and distribution: `DvPExecutor.sol`, `IntentExecutor.sol`, `SignedEntry.sol`, `Distributor.sol`, `IntentSettledUpgradeable.sol`
- Tests: `Gated4626Vault.t.sol`, `Gated4626VaultPortfolio.t.sol`, `Gated4626Management.t.sol`, `Gated7540Vault.t.sol`, `Gated7540Settlement.t.sol`, `NavDesk.t.sol`, `FeeModel.t.sol`, `Portfolio.t.sol`, `GuardedAccount.t.sol`, `DvPExecutor.t.sol`, `SignedEntry.t.sol`, `Distributor.t.sol`, `test/nodejs/vaults.test.ts`, `test/nodejs/dvp.test.ts`, `test/nodejs/legos.test.ts`

---

Describes the contracts at commit `18e60b3` on `paris`.
