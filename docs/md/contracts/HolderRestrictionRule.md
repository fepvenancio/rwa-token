[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Policy

# HolderRestrictionRule

Two restrictions on one holder of one token: a lockup, which stops the holder sending until a set time, and an address freeze, which stops the holder sending or receiving until it is lifted. The token's agent sets both.

- **contracts/hooks/rules/HolderRestrictionRule.sol**
- immutable, **not a proxy**
- set per holder by the token's **AGENT_ROLE**
- attested as **RULE**
- ruleId: **keccak256('HolderRestrictionRule.v1')**

<a id="in-one-minute"></a>

> ### In one minute
>
> Issuers need two everyday tools for single holders. A **lockup** keeps a holder's tokens in place until a date, for example after a private placement: the holder cannot transfer or redeem before then, but can still receive. A **freeze** stops an address altogether, for example while a court order or an investigation is open: nothing goes in or out. The token's agent sets both, holder by holder. The agent can still take tokens out of a locked or frozen account with a forced transfer, to an account that is allowed to hold them.

<a id="how"></a>
## How a movement is judged

The rule judges the sender first, then the receiver. Both settings of a holder live in one storage word, so a movement costs one read for the sender and one for the receiver.

> **Diagram.** The check, in order. First, if the kind is FORCED or there is no sender, the sender is not judged and the rule goes to step four. Second, a frozen sender returns SENDER_FROZEN. Third, a sender whose lockup is still running returns LOCKED_UP: the movement is a TRANSFER, an EXECUTED intent or a holder's BURN. Fourth, if there is a receiver and it is frozen, RECEIVER_FROZEN. Otherwise TRANSFER_OK.
>
> **Freeze before lockup, sender before receiver.** A sender that is both frozen and locked sees `SENDER_FROZEN`. A locked sender paying a frozen receiver sees `LOCKED_UP`. The rule does not look at the operator and makes no call to the token.

<a id="kinds"></a>
## What it does for each kind of movement

Zero amounts are judged like any other, because the rule does not read the amount.

| Kind | Sender frozen | Sender locked | Receiver frozen |
|---|---|---|---|
| TRANSFER | `SENDER_FROZEN` | `LOCKED_UP` | `RECEIVER_FROZEN` |
| EXECUTED | `SENDER_FROZEN` | `LOCKED_UP` | `RECEIVER_FROZEN` |
| FORCED | not checked | not checked | `RECEIVER_FROZEN`, the enforcement mint included; the burner's `burn` has no receiver |
| MINT | no sender | no sender | `RECEIVER_FROZEN` |
| BURN | `SENDER_FROZEN` | `LOCKED_UP` | no receiver |

A lockup does not stop a holder from receiving: only the sender's lockup is read. A lockup covers the holder's whole balance, including tokens received after it was set. A `BURN` is a holder's own, such as a vault redemption, and is judged the same whoever the operator is. The burner's `burn` on the token is `FORCED`. The token reverts a refused movement with `ERC8473PolicyRejected(reason)`.

<a id="way-out"></a>
## The way out of a frozen account

A freeze stops every movement the holder directs, a vault redemption included. The two enforcement actions pass it, because both are `FORCED`: the burner's `burn`, which destroys the tokens and has no receiver, and a forced transfer by the agent to a quarantine account. The receiver side is still checked on a forced transfer, so the quarantine account must not be frozen itself, and it must pass the token's other rules, such as holding a credential the token accepts.

> **Diagram.** Three ways tokens could leave a frozen holder F. A TRANSFER, an EXECUTED intent or a holder's BURN, by the holder, a spender or an executor, is refused with SENDER_FROZEN. The burner's burn, which is FORCED, goes through: the sender is not judged and there is no receiver. A FORCED transfer by the agent to a quarantine account Q goes through: the sender is not judged, Q must not be frozen and must pass the other rules.
>
> **Enforcement is the route out of a frozen account.** The burner destroys the tokens, or the agent moves them to a quarantine account that is not frozen and is allowed to hold them. The freeze itself stays until the agent lifts it.

The address freeze here is not the token's own frozen amount (`setFrozenTokens` on the token), which holds back part of a balance and lets the rest move. The two can be used together.

<a id="account"></a>
## The account questions

`checkSend(token, account)` answers `SENDER_FROZEN` for a frozen account, then `LOCKED_UP` while its lockup runs, otherwise `TRANSFER_OK`. `checkReceive(token, account)` answers `RECEIVER_FROZEN` for a frozen account, otherwise `TRANSFER_OK`. So the token's `canSend` is false for a frozen holder and for a locked one, and `canReceive` is false for a frozen one.

These answers agree with `check` for every movement the holder drives. They cannot know about the movements the rule exempts, which only the movement itself reveals: a forced transfer and the burner's `burn` still pass for a frozen or locked sender, while `canSend` says no.

<a id="config"></a>
## Who sets them, and what happens before they do

The rule asks the token at call time whether the caller holds `AGENT_ROLE`, through a read-only call. The `Product` module grants that role on every product to the agent account named in its parameters, and sets no restriction. These settings have no timelock in front of them: they take effect in the agent's call.

**Not configured means not restricted.** This rule neither fails closed nor has an on or off switch. A holder with no entry has an unlock time of 0 and is not frozen, and every movement passes. A lockup ends by itself at its unlock second: the holder is locked while the block time is before `unlockTime` and free from that second on. A freeze stays until the agent lifts it.

<a id="order"></a>
## Where it sits, and who lists it

Every product in every profile of `ignition/profiles.ts` lists it. In the demo deployment (`full`, through `RULE_ORDER`) it is third on the intent token and both vaults, after the credential check and the minimum position. In the other profiles (`PLAIN_RULES`) it is second, after the credential check.

<a id="vaults"></a>
## On the vaults

- [`Gated4626Vault`](Gated4626Vault.md): a holder's `redeem` or `withdraw` burns shares as a holder burn, so a lockup and a freeze both stop it. `maxRedeem` and `maxWithdraw` read 0 for a locked or frozen owner, and `maxDeposit` and `maxMint` read 0 for a frozen receiver.
- [`Gated7540Vault`](Gated7540Vault.md): `requestRedeem` moves the owner's shares into the vault as a TRANSFER, so both settings apply there. Collecting a settled redemption runs a burn check of nothing on the controller, so a locked or frozen controller cannot collect until released. Requesting and claiming a deposit run a mint check on the controller, so a frozen controller can do neither.
- **On the vault's own address.** Unlike the credential rule, this rule does not pass the token's own address. A freeze on a 7540's own address stops the settlement of any period that takes redemptions: the burn of the escrowed shares taken is refused with `SENDER_FROZEN`. A lockup there does the same with `LOCKED_UP`. A period that takes no redemptions, because it has none or its redemption limit takes none, makes no such burn, so it still settles, and any net inflow goes to the cash account.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `setLockup(token, holder, unlockTime)` | The token's `AGENT_ROLE` | Locks the holder until `unlockTime`, the first second at which it may send again. A time at or before the current block clears the lockup (stored as 0). Leaves the freeze as it is. Emits `LockupSet(token, holder, unlockTime)` with the stored time. Reverts with `HolderRestrictionRule_OnlyTokenAgent(token, caller)`, `HolderRestrictionRule_ZeroAddress` for a zero holder, or `HolderRestrictionRule_UnlockTimeTooLarge(time)` for a future time that does not fit 64 bits. |
| `setFrozen(token, holder, frozen)` | The token's `AGENT_ROLE` | Freezes or unfreezes the holder. Leaves the lockup as it is. Emits `HolderFrozenSet(token, holder, frozen)`. Reverts with `HolderRestrictionRule_OnlyTokenAgent` or `HolderRestrictionRule_ZeroAddress`. |
| `check(ctx)` | Anyone (read-only); the hook in practice | The decision above: `TRANSFER_OK`, `SENDER_FROZEN`, `LOCKED_UP` or `RECEIVER_FROZEN`. |
| `checkSend(token, account)`, `checkReceive(token, account)` | Anyone (read-only) | The account questions above. Neither asks the token for a role. |
| `unlockTime(token, holder)`, `isFrozen(token, holder)` | Anyone (read-only) | The stored unlock time and the freeze flag. The time is 0 when never set or when cleared; a lockup that has run out still returns its past time. |
| `AGENT_ROLE()` | Anyone (read-only) | `keccak256('AGENT_ROLE')`, the token role the setters require. |
| `after_(ctx)` | The hook of `ctx.token` | The empty default. The hook does not call it, because `wantsAfter()` is false. |
| `onInstall(token, previousPolicy)` | Anyone; the hook when a token installs it, or when a `setRules` adds the rule to the token's list | The empty default: the rule keeps no state derived from movements. |
| `ruleId()`, `wantsAfter()`, `supportsInterface(id)` | Anyone (read-only) | `keccak256('HolderRestrictionRule.v1')`; false; ERC-165 for `IHolderRestrictionRule`, `IComplianceRule` and `IERC165`. |

<a id="why"></a>
## Why it is built this way

- **One word per holder.** The unlock time (64 bits) and the freeze flag share one storage word, so each side of a movement costs one read, and setting one does not disturb the other.
- **The agent's role, asked live.** Lockups and freezes are day-to-day operational data, so they belong to the same role that runs forced transfers and frozen amounts on the token. The rule keeps no list of agents; it asks the token, so a role change on the token takes effect here at once.
- **A holder's exit respects the lockup; enforcement does not.** A holder's own burn, such as a vault redemption, is a way out and waits for the unlock. The burner's `burn` on the token and a forced transfer are enforcement actions and pass a lockup.
- **A freeze stops the holder, not enforcement.** A frozen sender is refused in every kind but `FORCED`, and a frozen receiver in every kind that has a receiver. That leaves two controlled routes out: the burner's `burn`, and the agent's forced transfer to a quarantine account that is not frozen.
- **Clearing needs no range check.** A time at or before the current block clears the lockup, so only a future time has to fit the 64 bits it is stored in.
- **One instance for every token.** Restrictions are stored per token and holder, so a freeze on one token does not touch the same address on another.

<a id="limits"></a>
## What it does not do

- **It locks a holder, not a tranche.** A lockup covers the whole balance, and there is one unlock time per holder per token.
- **It has no exception for enforcement on the receiving side.** A forced transfer or an enforcement mint into a frozen account is refused, so a quarantine account must not be frozen.
- **It does not cover a stolen agent key.** Whoever holds `AGENT_ROLE` can lock or freeze any holder, at once, with no delay. The post-deploy check (`assertHandedOver`) looks at the deployment's `agent` account: unless the profile names the exception, if that account holds the role it must answer `getThreshold()` with 2 or more. A grant to an address the check was not told about goes unseen. Every profile in `ignition/profiles.ts` names it, as demo signers, so a real deployment has to state its own.

<a id="connected"></a>
## Connected to

- [ComplianceHook](ComplianceHook.md): Asks this rule in every profile's list.
- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): Where the agent runs `forcedTransfer` and the token's own frozen amounts.
- [CredentialRule](CredentialRule.md): What a quarantine account must also pass to receive a forced transfer.
- [BaseRule](BaseRule.md): The parent this rule inherits from.
- [Who can do what](../roles.md): Who holds `AGENT_ROLE` and `BURNER_ROLE` on each token.
- [One movement](../movement.md): Every check a movement meets, in order.

<a id="source"></a>
## Source and tests

- Contract: `contracts/hooks/rules/HolderRestrictionRule.sol`, interface `IHolderRestrictionRule.sol`
- Tests: `HolderRestrictionRule.t.sol` (setters, each kind under a lockup and a freeze, the unlock second, the account questions and a fuzz test that they agree with `check`), `RuleSetIntegration.t.sol` (on a real token, including the forced transfer to a quarantine account and the enforcement burn from a frozen holder) and `test/nodejs/time.test.ts` (a lockup holds until its unlock second)

---

Describes the contracts at commit `5670fa8` on `paris`.
