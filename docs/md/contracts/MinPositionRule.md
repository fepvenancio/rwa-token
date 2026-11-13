[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Policy

# MinPositionRule

A minimum holding per token. After a movement, every account it judges holds either nothing or at least the minimum, so no tiny leftover balances (dust) are created.

- **contracts/hooks/rules/MinPositionRule.sol**
- immutable, **not a proxy**
- set per token by the token's **DEFAULT_ADMIN_ROLE**
- attested as **RULE**
- ruleId: **keccak256('MinPositionRule.v1')**

<a id="in-one-minute"></a>

> ### In one minute
>
> Funds often set a minimum investment. This rule enforces one on the token: if the minimum is 1,000 units, nobody can end a transfer, a subscription or a redemption holding 1 to 999 units. Selling everything is fine; keeping a little is not. It also matters for the investor cap: a tiny balance would count as a whole investor, so blocking dust stops anyone from taking a place under the cap with one unit. The token's administrator sets the minimum, and 0 switches the rule off. Enforcement actions (the agent's forced transfers and the burner's burns) are not held to it.

<a id="how"></a>
## How a position is judged

The rule looks at the balance each side will have after the move. It reads both balances before the move from the context the token built (`extra`) and works from the amount, so it makes no call back into the token for a balance.

> **Diagram.** Allowed balances after a move. The sender may keep nothing, or the minimum or more; keeping more than zero and less than the minimum is refused with BELOW_MIN_POSITION. The receiver always ends above zero, so it must end with the minimum or more; less is refused with BELOW_MIN_POSITION.
>
> **Zero, or the minimum or more.** A sender may leave entirely or keep at least the minimum. A receiver of a non-zero amount ends above zero, so it must reach the minimum. Exactly the minimum is allowed on both sides.

> **Diagram.** The check, in order. First, if the minimum is 0, the amount is 0, the sender is the receiver, or the kind is FORCED, it returns TRANSFER_OK without judging. Second, if there is a receiver that would end below the minimum and is not exempt, it returns BELOW_MIN_POSITION. Third, if there is a sender that would keep more than zero and less than the minimum, is not exempt, and the movement is not a burn by a holder of the token's BURNER_ROLE, it returns BELOW_MIN_POSITION. Otherwise TRANSFER_OK.
>
> **Three steps, receiver before sender.** The exemption list and the token's roles are read only once a position would breach the minimum, so an ordinary movement pays for neither.

<a id="kinds"></a>
## What it does for each kind of movement

With a minimum above 0, a non-zero amount, and two different accounts:

| Kind | Receiver | Sender |
|---|---|---|
| TRANSFER | ends at the minimum or more, unless exempt | keeps 0, or the minimum or more, unless exempt |
| EXECUTED | the same as a transfer | the same as a transfer |
| FORCED | not judged | not judged (an enforcement mint has no sender) |
| MINT | ends at the minimum or more, unless exempt | none: a mint has no sender |
| BURN | none: a burn has no receiver | keeps 0, or the minimum or more, unless exempt or the operator holds the token's `BURNER_ROLE` |

The one reason code is `BELOW_MIN_POSITION`, and the token reverts with `PolicyGated_TransferRejected(BELOW_MIN_POSITION)`. A holder's own burn, such as a vault redemption, is judged on what it leaves behind. A burn by an account holding the token's `BURNER_ROLE` counts as enforcement and may leave any remainder. A plain transfer by that same account is judged like any other.

<a id="exempt"></a>
## What is not judged

- **Nothing to judge.** A minimum of 0 (the rule is off for the token), an amount of 0, and a move from an account to itself all pass. Nothing changes hands, so no dust appears.
- **Enforcement.** `FORCED` passes on both sides, the enforcement mint included, and so does a burn whose operator holds the token's `BURNER_ROLE` on the sender side. The rule asks the token for that role only when a burn would leave a remainder below the minimum.
- **The token itself.** The token's own address is exempt. On [`Gated7540Vault`](Gated7540Vault.md) that address is the escrow that holds the shares of pending redemptions.
- **Listed accounts.** The token's admin can exempt an account with `setExempt(token, account, true)`. An exempt account is not judged on its own side; the other side of the same movement still is. A listing on one token does not carry over to another.

<a id="account"></a>
## The account questions

`checkSend` and `checkReceive` answer `TRANSFER_OK` for every account: they are the [`BaseRule`](BaseRule.md) defaults. A minimum depends on the amount, and ERC-7943 keeps quantitative rules out of the account questions. So with a minimum set, `canReceive` still reads true for an empty eligible account, and a transfer below the minimum to it is refused. `canTransferWithReason` says `BELOW_MIN_POSITION` for that transfer.

<a id="config"></a>
## Who sets the minimum, and what zero means

**Zero is off.** A token that lists the rule and has set no minimum passes every movement: this rule does not fail closed. The hook still calls it on every movement, so a token that wants no minimum can leave it out of its list.

The rule asks the token at call time whether the caller holds `DEFAULT_ADMIN_ROLE`, through a read-only call. While a product launches that is the operations account, and the `Product` module calls `setMinPosition` with the `minPosition` parameter, 0 unless the deployment gives one. After the hand-over the main timelock is the admin, and a change is a governance operation with its delay.

<a id="order"></a>
## Where it sits, and who lists it

The demo deployment (`full`, through `RULE_ORDER`) lists it second on all three of its products, the intent token and both vaults, right after the credential check, so that with a minimum set the rules after it see real positions. No other profile in `ignition/profiles.ts` lists it: `PLAIN_RULES` is the credential rule and the holder restrictions. On those products, dust is not stopped by a rule.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `setMinPosition(token, amount)` | The token's `DEFAULT_ADMIN_ROLE` | Sets the token's minimum, in token units; 0 switches the rule off. Emits `MinPositionSet` with the token, the previous minimum and the one set. Reverts with `MinPositionRule_OnlyTokenAdmin(token, caller)`. |
| `setExempt(token, account, exempt)` | The token's `DEFAULT_ADMIN_ROLE` | Adds an account to, or removes it from, the token's exemption list. Emits `MinPositionExemptionSet(token, account, exempt)`. Reverts with `MinPositionRule_OnlyTokenAdmin`, or `MinPositionRule_ZeroAddress` for the zero address. |
| `check(ctx)` | Anyone (read-only); the hook in practice | The decision described above: `TRANSFER_OK` or `BELOW_MIN_POSITION`. |
| `minPosition(token)` | Anyone (read-only) | The token's minimum; 0 when off. |
| `isExempt(token, account)` | Anyone (read-only) | True for the token itself and for listed accounts. |
| `checkSend`, `checkReceive` | Anyone (read-only) | `TRANSFER_OK` for every account. |
| `after_(ctx)` | The hook of `ctx.token` | The empty default. The hook does not call it, because `wantsAfter()` is false. |
| `ruleId()`, `wantsAfter()`, `supportsInterface(id)` | Anyone (read-only) | `keccak256('MinPositionRule.v1')`; false; ERC-165 for `IMinPositionRule`, `IComplianceRule` and `IERC165`. |

<a id="edges"></a>
## Edge cases

- **Raising the minimum.** Existing balances are not touched. A holder left below a raised minimum cannot send part of it, but can send all of it to a receiver that then holds at least the minimum, redeem all of it, or receive enough to reach the minimum. A top-up that still leaves it below is refused.
- **An amount above the balance.** The token does not offer such a movement to the hook on a write, but its `canTransfer` asks with it. The rule answers without reverting: the sender side is computed only when the sender holds more than the amount.
- **It does not revert on arithmetic.** The receiver test is written as "the amount is below the minimum, and the balance is below the minimum minus the amount", which cannot overflow, and the sender's remainder is computed only when it is positive. A Halmos symbolic test (`check_theRuleNeverReverts`) covers any minimum, balances, amount and kind.
- **Vault limits.** The vaults' `maxDeposit` and `maxMint` test a mint of a very large amount (`type(uint128).max`), which is above any minimum up to that size, so such a minimum does not show up there as a block. A deposit too small for the minimum passes that check and is refused when the shares are minted. On `Gated7540Vault` a claim that would leave the receiver below the minimum is refused and the claimable amount stays; the agent's `recoverClaimable` delivers it as an enforcement mint, which is exempt.

<a id="why"></a>
## Why it is built this way

- **No dust, no cheap investor slots.** A fund caps its number of investors ([`FundHoldersRule`](FundHoldersRule.md)), and a one-unit balance counts as an investor. With a minimum set, a movement this rule judges cannot create such a position.
- **No call back into the token for balances.** The token puts the balances before the move in the context, the same way for the write and for every pre-flight, so the usual path makes no call to the token at all. The token is asked for a role, and only when a burn would leave dust.
- **One instance for every token.** The minimum and the exemptions are stored per token and authorised by that token's own admin, so the same attested contract serves every token in the deployment.

<a id="limits"></a>
## What it does not do

- **It does nothing until a minimum is set.** Listing the rule is not enough, and the deployment sets none unless given one. Where no minimum is set, a payer the token's policy accepts can deposit 1 unit into a 4626 for an eligible empty receiver and take a fund investor slot. No rule answers that there: the agent can take the dust back with `forcedTransfer` to an exempt or already counted account, and someone can watch `Fund.holderCount()`.
- **Enforcement and exempt accounts can still leave dust.** Forced transfers, burns by a `BURNER_ROLE` holder and listed accounts are not held to the minimum.
- **It asks the operator, not the intent.** A `BURNER_ROLE` holder that redeems its own vault shares passes its own minimum, because the rule sees a burn by that role. Burner accounts are issuer service accounts and should not also be investors.
- **1 unit can still reach an existing holder.** A receiver already at or above the minimum can receive any amount. A holder trying to exit an exact balance it read earlier then reverts with `BELOW_MIN_POSITION`, because the extra unit would stay behind. It exits the current balance instead.
- **A frozen remainder makes `maxRedeem` overstate.** `maxRedeem` is the unfrozen balance, and the minimum judges the whole balance. A holder whose frozen amount is above zero and below the minimum cannot redeem all of `maxRedeem`: the frozen remainder would stay behind, and the redemption reverts with `BELOW_MIN_POSITION`.
- **A minimum above `type(uint128).max` would refuse the vaults' mint probe** and read as a block in `maxDeposit`.

<a id="connected"></a>
## Connected to

- [ComplianceHook](ComplianceHook.md): Asks this rule second in the demo deployment's lists.
- [FundHoldersRule](FundHoldersRule.md): The investor cap that a dust position would otherwise use up.
- [Gated4626Vault](Gated4626Vault.md): Deposits and redemptions are mints and burns this rule judges.
- [Gated7540Vault](Gated7540Vault.md): The vault whose escrow is the token itself, which the rule exempts.
- [BaseRule](BaseRule.md): The parent this rule inherits its defaults from.
- [One movement](../movement.md): Where this rule sits among all the checks a movement meets.

<a id="source"></a>
## Source and tests

- Contract: `contracts/hooks/rules/MinPositionRule.sol`, interface `IMinPositionRule.sol`
- Tests: `MinPositionRule.t.sol` (each side, each kind, every exemption, a fuzz test of the whole decision, extreme numbers), `MinPositionRuleHalmos.t.sol` (symbolic checks that a transfer is refused exactly when it leaves dust, that a forced movement is not refused, and that the rule answers every input without reverting), `RuleSetIntegration.t.sol` (on a real token, with pre-flight parity) and `test/nodejs/deployment.test.ts` (the minimum off unless the deployment sets one)

---

Describes the contracts at commit `4a906cc` on `main`.
