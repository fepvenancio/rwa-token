[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Policy

# FundHoldersRule

The fund-wide investor cap. It lets a new investor into a class of a fund only while the fund has room, and tells the fund each time someone starts or stops holding a class.

- **contracts/hooks/rules/FundHoldersRule.sol**
- immutable, **not a proxy**, one per fund
- cap and exemptions set on the **Fund** by its owner
- attested as **RULE**
- ruleId: **keccak256('FundHoldersRule.v1')**

<a id="in-one-minute"></a>

> ### In one minute
>
> A fund may be allowed only so many investors, counted across all its share classes. In the demo deployment this rule is the last one listed on every class of the fund. Before a movement it asks the [Fund](Fund.md) one question: would the receiver be a new investor, and if so, is there room? After the movement it tells the fund that someone has stopped holding a class, or has started.
>
> The count and the cap live in the fund, not in the rule, so the rule can be replaced without losing the count. An investor already in the fund is not refused for the cap, whichever class it moves into, and the issuer's forced transfers are not capped. A token that is not a registered class of the fund cannot move at all.

<a id="how"></a>
## How a movement is decided

`check(ctx)` reads the fund once, with `admission(token, to)`, which returns the token's class number, the receiver's class mask and exempt flag, the count, the cap and the fund's installed rule. Only at a full fund does it read the fund a second time, for the sender. The balances before the move come from the context the token built (`data`), not from the token.

> **Diagram.** The check, in order. 1: if the token is not a registered class of the fund, or this rule is not the fund's installed rule, NOT_FUND_CLASS. 2: if the receiver is not a new investor (zero amount, a move to oneself, a burn, FORCED, a move to the class itself, to an exempt account, or to an account that already holds any class), TRANSFER_OK. 3: if the cap is 0, MAX_HOLDERS. 4: if the count is below the cap, TRANSFER_OK. 5: if the count equals the cap and the move takes all of the sender's only class, TRANSFER_OK. Otherwise MAX_HOLDERS, which includes any new investor while the count is above the cap.
>
> **Only a new investor is counted against the cap.** Step 2 lets through every move that cannot add an investor, and forced transfers, which can but are exempt, so trades between existing investors, exits and enforcement do not meet the cap. Red boxes are refusals, which the token turns into `ERC8473PolicyRejected(reason)`.

1. **Wrong fund or wrong rule: refuse everything.** A token that is not a registered class of the fund, or a rule that the fund has replaced, answers `NOT_FUND_CLASS` for every movement, zero amounts, burns and forced transfers included. So a retired rule does not say yes in a pre-flight while its write would be refused, and a class cannot hold a balance before the fund records it.
2. **Who is a new investor.** A receiver that holds no class of the fund and is not exempt, receiving a non-zero amount from someone else. The class token itself is not one: `Gated7540Vault` keeps the shares of pending redemptions at its own address.
3. **Room, or a free slot.** Below the cap a new investor passes. At the cap it passes only by the net-zero case below.
4. **Above a lowered cap, nobody new.** When the owner lowers the cap below the count, no new investor is admitted, even by a move that would be net zero, until the count is back down. Existing investors can still trade among themselves and leave.

<a id="net-zero"></a>
## The net-zero case at a full cap

When the count equals the cap, a new investor is admitted if the sender stops being an investor in the same move, because one goes out and one comes in. All of these must hold: there is a sender, the sender is not the class itself, it is not exempt, this is the only class it holds, and the amount is its whole balance in that class.

| At a full cap, a move to a new investor where | Answer | Why |
|---|---|---|
| the sender holds only this class and moves all of it | `TRANSFER_OK` | one out, one in |
| the sender keeps part of its balance | `MAX_HOLDERS` | it stays an investor |
| the sender moves all of this class but holds another | `MAX_HOLDERS` | it stays an investor |
| the sender is exempt | `MAX_HOLDERS` | it was not counted, so it frees no slot |
| the sender is the class itself, as when the 7540 returns escrowed shares | `MAX_HOLDERS` | it was not counted |
| it is a mint | `MAX_HOLDERS` | there is no sender to free a slot |

<a id="kinds"></a>
## What it does for each kind of movement

Every kind first meets the class check of step 1, with `NOT_FUND_CLASS` for a token or rule that fails it.

| Kind | The cap | Recorded after the move |
|---|---|---|
| TRANSFER | applies to a new investor, net of a sender who leaves the fund | the sender leaves the class if it moved all of it; the receiver joins if it held none of it |
| EXECUTED | the same as a transfer | the same as a transfer |
| FORCED | not applied: enforcement is exempt | both sides, so the count can end above the cap; after the burner's `burn`, which has no receiver, the sender leaves if all of it was burnt |
| MINT | applies to a new investor; a mint has no sender to free a slot | the receiver joins |
| BURN | not applied: a burn has no receiver | the sender leaves if it burnt all of it |

A vault deposit is a `MINT` of shares, a 4626 redemption a `BURN`, and a 7540 redemption request a `TRANSFER` into the vault, which step 2 lets through because the receiver is the class itself. When the agent delivers a stranded 7540 deposit with `recoverClaimable`, that is an enforcement mint, so it is exempt from the cap and still counted. An integration test runs exactly that: another class fills the fund before a claim, the claim is refused, and the agent's recovery delivers the shares, counted.

<a id="after"></a>
## After the move: telling the fund

The rule's `wantsAfter()` is true, so the hook calls its `after_` once the balances have moved, inside the token's guard against reentry. The state lives in the [`Fund`](Fund.md): the rule keeps none. `after_` writes there, in this order: the sender leaves first, then the receiver joins.

> **Diagram.** After a movement. The class token moves the balances, then calls afterTransfer on the ComplianceHook, which accepts it only from the token named in the context. The hook calls after\_ on FundHoldersRule. The rule asks the token for its current policy and requires it to be the caller. It stops if the amount is zero or the sender is the receiver. It then calls leave on the Fund if the sender is not the zero address and the move took its whole balance, and after that join if the receiver is not the zero address and held none of the class before. The Fund accepts these only from its installed rule, only for a registered class, and ignores the class itself.
>
> **Two gates before the fund changes, and the leave comes first.** The rule accepts `after_` only from the hook the token currently has, and the fund accepts `join` and `leave` only from its installed rule and only for a registered class. A movement that changes nobody's holding of the class writes nothing. Because the leave comes first, a net-zero move at a full fund does not show the count above the cap, even for a moment.

1. **Nothing to record.** After the hook check, a zero amount or a move to oneself returns without touching the fund.
2. **The sender leaves.** `leave` is called when `from` is not the zero address, so a mint leaves nobody, and the amount equals the sender's whole balance before the move.
3. **The receiver joins.** `join` is called when `to` is not the zero address, so a burn joins nobody, and the receiver's balance before the move was zero. Both balances come from `data`, which the token built before the balances moved.
4. **The fund's own checks.** `join` and `leave` revert unless the caller is the fund's installed rule (`Fund_OnlyRule`) and the token is a registered class (`Fund_NotAClass`); a revert there undoes the whole movement. A class joining itself, such as shares going into the 7540 escrow, is ignored, and a leave for it changes nothing.

<a id="account-checks"></a>
## The account questions answer the class check alone

The token's `canSend(account)` and `canReceive(account)` come from ERC-7943, which keeps quantitative rules out of those two questions. A cap on investors depends on the movement, not on the account, so it belongs to `check` alone. `checkSend` and `checkReceive` answer `TRANSFER_OK` when the token is a class of the fund under this rule, and `NOT_FUND_CLASS` otherwise. They do not answer `MAX_HOLDERS`.

So at a full fund, `canReceive` is still true for a new investor, while a mint or a partial transfer to it is refused with `MAX_HOLDERS`. The pre-flight `canTransferWithReason` says `MAX_HOLDERS` too. The vaults' `maxDeposit` tests a mint, which does reach `check`, so it reads 0 for that investor, and `Gated7540Vault` refuses its deposit request up front.

<a id="reasons"></a>
## Reason codes

| Code | When |
|---|---|
| `NOT_FUND_CLASS` | The token is not a registered class of this rule's fund, or the fund's installed rule is another one. Every movement, every kind, any amount. |
| `MAX_HOLDERS` | A new investor while the cap is 0, or while the count is at the cap and the move is not net zero, or while the count is above the cap. |

<a id="config"></a>
## Who configures it, and what happens before they do

The rule has no setter and no admin of its own. The cap (`setHolderCap`), the exemptions (`setExempt`), the classes (`registerClass`) and which rule is installed (`setRule`) are all set on the [`Fund`](Fund.md) by its owner. The operations account owns the fund until the `FundOpen` module has set the rule and the cap and registered the first classes, and then hands it to the main timelock, so a later change waits for its delay.

**Not configured: it fails closed.** The `Product` module does not touch a fund, so a class launches inert: until the fund has this rule installed and the class registered, every movement is refused with `NOT_FUND_CLASS`. A cap of 0 is not off either: it admits no new investor.

<a id="order"></a>
## Where it sits, and who lists it

The demo deployment (`full`, through `RULE_ORDER`) lists it last on all three of its products, the intent token and both vaults, which are three classes of the fund `main`. A receiver who cannot hold the token at all is therefore refused for that reason before the cap is consulted. No other profile in `ignition/profiles.ts` lists it. `assertUsable` throws when a module is built for a product that lists this rule without naming a fund, or names a fund without listing it.

Each fund has its own rule instance: the `Fund` module deploys the two together. The fund's address is an immutable, so it is part of the attested code hash, and the council reads the fund's code and owner before it attests the rule.

<a id="replacement"></a>
## Replacing the rule

The rule holds no state, only the fund's address, so a replacement starts with the count and the masks as they are. The fund names one installed rule at a time, and this rule compares itself with it on every movement. While a class's rule list still names a rule the fund has replaced, that rule answers `NOT_FUND_CLASS` to everything, forced transfers included, and the class is closed. The change is therefore one main-timelock batch: `setRule` on the fund together with the hook's `setRules` for every class. A second instance for the same fund has the same code hash, so it is already attested. Each `setRules` tells the incoming rule, and on a class with holders it accepts because the list it replaces names another rule of the same fund (`test_WhenTheRuleIsReplaced_TheCountSurvivesAndTheWindowBetweenTheTwoStepsFailsClosedWithParity`). `Fund.firstBrokenClass()` names a class whose list does not name the installed rule.

<a id="install"></a>
## When the rule goes live on a class

The fund's count is built from the movements of each class, and it is kept across installations. So the rule answers for it each time it goes live on a class: when the class installs a hook whose list for the class names the rule, and when the hook's `setRules` adds the rule to the class's list. Either way the hook calls the rule's `onInstall(token, previousPolicy)`, and the rule accepts in two cases. The class has no supply, so there is nothing to count. Or the policy the class consulted until then lists, for the class, this rule or another rule of the same fund. Such a rule counted every movement while the fund had it installed and refused every movement while it did not, so no movement went unseen. The rule knows another rule of its fund by asking it through ERC-165 for the `IFundHoldersRule` id and then for `FUND()`; a listed rule that does not answer the id is passed over (`test_WhenThePreviousPolicyListedAnotherRuleOfTheSameFund_ItAccepts`, `test_WhenThePreviousPolicyListedARuleOfAnotherFund_ItReverts`). Otherwise the rule reverts with `FundHoldersRule_CountNotCurrent(token)`. An installation is then undone and the class keeps the hook it had; a `setRules` leaves the list as it was. `onInstall` writes nothing, so anyone may call it.

A class is set up with no supply, so its first installation passes. A class that has a supply can move to another hook that lists the rule only while the hook it leaves lists the rule too, or another rule of the same fund. The same holds when a class installs the hook it already has: the hook tells the rules before it stores a list from the data, so it still answers with the list it held. A class with a supply that installs its own hook with data that adds this rule to a list that named no rule of the fund is refused with `FundHoldersRule_CountNotCurrent`. `setRules` is judged the same way: the hook tells a rule it adds before it stores the new list, and names the policy the class consults at that moment. So on a class with a supply, a list that dropped the fund's rule cannot take it back (`test_WhenAClassWithHoldersDropsTheFundRule_ItCannotTakeItBack`). When a replacement hook is prepared with `setRules` for a class that still consults the outgoing hook, the rule is asked about the outgoing hook's list, and asked again when the class installs the replacement. The fund's count survives a hook replacement when both hooks list the rule. A receiving hook whose list for the class does not name the rule does not ask it: the installation goes through, the class moves uncounted, and `Fund.firstBrokenClass()` names it.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `check(ctx)` | Anyone (read-only); the hook in practice | The decision above: `TRANSFER_OK`, `NOT_FUND_CLASS` or `MAX_HOLDERS`. |
| `after_(ctx)` | The hook currently installed on `ctx.token` | Calls the fund's `leave` and then `join` as described above. Reverts with `ComplianceRule_OnlyHook(caller)` for any other caller. |
| `onInstall(token, previousPolicy)` | Anyone (read-only); the hook when a class installs it, or when a `setRules` adds the rule to the class's list | Returns when the class's `totalSupply()` is zero, or when `previousPolicy` is not the zero address and its `rules(token)` names this rule or a rule that answers the `IFundHoldersRule` id and whose `FUND()` is this rule's fund. Otherwise reverts with `FundHoldersRule_CountNotCurrent(token)`. Writes nothing. |
| `checkSend(token, account)`, `checkReceive(token, account)` | Anyone (read-only) | The class check of step 1 alone: `NOT_FUND_CLASS` or `TRANSFER_OK`. |
| `FUND()` | Anyone (read-only) | The fund the rule reads and writes, fixed at construction. The constructor refuses the zero address (`FundHoldersRule_ZeroAddress`). |
| `ruleId()`, `wantsAfter()`, `supportsInterface(id)` | Anyone (read-only) | `keccak256('FundHoldersRule.v1')`; true; ERC-165 for `IFundHoldersRule`, `IComplianceRule` and `IERC165`. |

<a id="why"></a>
## Why it is built this way

- **The investor count that matters is fund-wide.** One investor in three classes is one investor. A record shared by all the classes is what can see that, so the count lives in `Fund` and each class lists this one rule.
- **State in the fund, policy in the rule.** The rule can be replaced without losing the count. [`BaseRule`](BaseRule.md) accepts whichever hook a token names, which is safe for state kept per token and not for a count shared by tokens, so the fund adds its own gate: it takes writes from the installed rule, for registered classes.
- **Fail closed on a mismatch.** A token that is not a class, or a rule other than the fund's installed one, refuses every movement rather than letting balances move uncounted. The pre-flight calls give the same answer as the write.
- **Not in the way of an exit or of enforcement.** Only a new investor meets the cap. Existing investors trade and leave, and the agent's forced transfers are exempt, though counted.
- **Few reads.** One `admission` call answers the usual case, and the fund keeps the rule, the count and the cap in one storage word. The sender is read only at a full fund. Balances come from the context, so the rule does not ask the token for one.

<a id="limits"></a>
## What it does not cover

- **Investors are addresses.** One investor with two wallets counts twice, and an omnibus wallet counts once.
- **Dust can take a slot.** A non-zero balance makes an investor. On a class with no minimum position set, a tiny transfer to an eligible address takes a slot for as long as it is held; the agent can take it back with `forcedTransfer`. The demo lists put [`MinPositionRule`](MinPositionRule.md) before this rule for that reason, and it does nothing until a minimum is set.
- **A class whose list drops this rule is uncapped.** The hook accepts a list without this rule. A class whose list does not name the fund's rule moves uncounted, and the fund's count goes stale. `Fund.isClassIntact` and `firstBrokenClass` report it, and the post-deploy check asserts none is broken at hand-over; nothing prevents it afterwards.
- **A class that ran without the rule gets it back only when it is empty.** Once a class with a supply has a list that names no rule of the fund, the rule refuses to go live on it again, through `setRules` or through an installation, until the class's supply is zero. There is no recount of the movements it missed. Until then the class stays uncounted and uncapped, and `Fund.isClassIntact` and `firstBrokenClass` show it.
- **It holds no place for an open 7540 request.** A full `requestRedeem` takes the investor out of the count while the shares wait in the escrow, and `requestDeposit` reserves nothing. If the fund fills up meanwhile, a reject that returns the shares, or a deposit claim, is refused with `MAX_HOLDERS`. The agent's recovery works, and delivering to an account that holds nothing puts the count above the cap until investors leave.
- **The cap is a ratchet.** Above a lowered cap no new investor is admitted, net-zero moves included, until the count comes back down.
- **Pre-flight of a two-class swap can miss.** When two legs of a trade move classes of one fund, each pre-flight reads the state before either has run, so a swap can pass and then fail on its second leg.

<a id="connected"></a>
## Connected to

- [Fund](Fund.md): Where the classes, the count, the cap and each investor's classes are kept.
- [ComplianceHook](ComplianceHook.md): Lists this rule last on every class in the demo, and calls its `after_`.
- [BaseRule](BaseRule.md): The parent, with the hook check on `after_`.
- [MinPositionRule](MinPositionRule.md): Stops dust positions from taking investor slots, when a minimum is set.
- [Gated7540Vault](Gated7540Vault.md): The class whose escrow is its own address, which is not counted.

<a id="source"></a>
## Source and tests

- Contract: `contracts/hooks/rules/FundHoldersRule.sol`, interface `IFundHoldersRule.sol`, reason codes in `Errors.sol`
- Tests: `FundHoldersRule.t.sol` (every step of the check, the net-zero cases, `after_`, the gate against fake tokens and fake hooks, the account questions, the check on installation), `FundIntegration.t.sol` (three real classes: the cap with pre-flight parity, no event showing the count above the cap, forced transfers, the 7540 escrow, a blocked claim, rule replacement, a class with holders that drops the rule and cannot take it back), `FundInvariant.t.sol`, `FundHalmos.t.sol`, and `test/nodejs/fund.test.ts` (through the real deployment)
