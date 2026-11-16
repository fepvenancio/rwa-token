[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Policy

# ExecutedOnlyRule

Turns off the plain transfer. On a token that lists it, a holder moves tokens to another holder by a signed intent that an executor carries out, and a call to `transfer` is refused.

- **contracts/hooks/rules/ExecutedOnlyRule.sol**
- immutable, **not a proxy**
- no settings, **no storage**
- attested as **RULE**
- ruleId: **keccak256('ExecutedOnlyRule.v1')**

<a id="in-one-minute"></a>

> ### In one minute
>
> A plain token transfer says nothing about why it happened. Some products want each movement between holders tied to an instruction. On an [IntentToken](IntentToken.md) a holder can sign an intent that names the receiver, the amount and a reference (`ref`, the hash of the issuer's message), and an executor submits it. This rule makes that the way a holder moves tokens: `transfer` and `transferFrom` revert with `KIND_NOT_ALLOWED`. Mints, burns, the agent's forced moves and executed intents pass. It has no settings and keeps no data: listing it is the whole configuration.

<a id="how"></a>
## How it decides

`check(ctx)` reads one field, the kind. A `TRANSFER` gets `KIND_NOT_ALLOWED`, whatever the amount. Everything else gets `TRANSFER_OK`. It reads no balance, no role and no storage, and it does not look at the reference.

| Kind | What the rule does |
|---|---|
| TRANSFER | `KIND_NOT_ALLOWED`, the one reason code, at any amount |
| EXECUTED | passes |
| FORCED | passes |
| MINT | passes |
| BURN | passes |

<a id="holder"></a>
## What it means for a holder

- **The send button reverts.** `transfer` reverts with `ERC8473PolicyRejected(KIND_NOT_ALLOWED)`. So does `transferFrom`: `approve` and `permit` still set an allowance, but a spender cannot use it to move the tokens.
- **To move, the holder signs.** The holder signs a `TransferIntent` (EIP-712 typed data) and hands it to whoever runs the executor. An account holding the token's `EXECUTOR_ROLE` calls `executeTransfer`, in a deployment [`IntentExecutor`](IntentExecutor.md) or [`DvPExecutor`](DvPExecutor.md). The other rules on the list still apply to that movement.
- **The holder depends on the executor.** The rule leaves no way for a holder to move tokens alone. An `IntentToken` has no holder burn either: `burn` needs `BURNER_ROLE`. If nobody submits the intent, nothing moves, and the intent lapses at its deadline.
- **Each such movement leaves its reference on chain.** `executeTransfer` emits `IntentExecuted(intentHash, from, to, amount, executor, ref)`.
- **Contracts are refused the same way.** A contract that moves this token with `transfer` or `transferFrom` makes a `TRANSFER`, so a vault could not take such a token as its asset.

<a id="account"></a>
## The account questions and the pre-flights

`checkSend` and `checkReceive` answer `TRANSFER_OK` for every account: they are the [`BaseRule`](BaseRule.md) defaults, and the rule has no opinion about an account. So `canSend` and `canReceive` can read true while a plain transfer is refused.

`canTransfer` and `canTransferWithReason` ask about a plain transfer, so between two holders they read false, the latter with `KIND_NOT_ALLOWED`. The pre-flight for a signed intent is `canExecute`.

<a id="config"></a>
## Who configures it, and where it sits

Nobody: there is nothing to set, no zero to read, and no state before or after. It refuses plain transfers from the moment it is on a token's list and stops when it is taken off, which is the hook's `setRules` under the token's `DEFAULT_ADMIN_ROLE`.

The demo deployment does not list it, and neither does any other profile in `ignition/profiles.ts` at this commit, so it has no set position. A product asks for it by naming `executedOnlyRule` in its `rules`, and the `Core` module then deploys it. A test does this with an `IntentToken` listing `credentialRule` then `executedOnlyRule`, with an `IntentExecutor`.

<a id="intent-token"></a>
## Why it is for an `IntentToken`

- **It is the template with `EXECUTED`.** `executeTransfer` comes from [`IntentSettledUpgradeable`](IntentSettledUpgradeable.md), which `IntentToken` inherits. On a [`GatedToken`](GatedToken.md), nothing can make an `EXECUTED` movement, so holders could not move tokens to each other at all.
- **A vault's escrow is a plain transfer.** [`Gated7540Vault`](Gated7540Vault.md) moves shares into its escrow in `requestRedeem`, and back in `rejectRedeemRequest`, as a `TRANSFER`. On a vault's list this rule would refuse both, so no redemption could be requested.

`assertUsable` in `ignition/profiles.ts` throws when a module is built that lists it on anything but an `IntentToken`. That check is in the deployment tooling. On chain, the hook accepts any attested rule on any token.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `check(ctx)` | Anyone (read-only); the hook in practice | `KIND_NOT_ALLOWED` for a `TRANSFER`, otherwise `TRANSFER_OK`. |
| `checkSend`, `checkReceive` | Anyone (read-only) | `TRANSFER_OK` for every account. |
| `after_(ctx)` | The hook of `ctx.token` | The empty default. The hook does not call it, because `wantsAfter()` is false. |
| `onInstall(token, previousPolicy)` | Anyone; the hook when a token installs it | The empty default: the rule keeps no state derived from movements. |
| `ruleId()`, `wantsAfter()`, `supportsInterface(id)` | Anyone (read-only) | `keccak256('ExecutedOnlyRule.v1')`; false; ERC-165 for `IComplianceRule` and `IERC165`, the `BaseRule` answer. |

`IExecutedOnlyRule` declares nothing beyond `IComplianceRule`. The rule has no events and no errors of its own.

<a id="why"></a>
## Why it is built this way

- **A rule, not a token feature.** Who may move and how is policy, so it sits on the token's list and comes off the same way, and the token base stays free of it.
- **Data stays off chain.** Originator and beneficiary data stay in the issuer's own message. The chain sees its hash, as `ref`.
- **Nothing to get wrong.** With no storage and no settings, the attested code is all there is, and one instance serves every token that lists it.

<a id="limits"></a>
## What it does not do

- **It does not check the reference.** The rule does not read `ref`, and the intent's own checks do not require it to be non-zero or to match anything. The holder's signature covers it, and that is all. Tying a reference to a real message is for the issuer's executor and its systems off chain.
- **It does not cover every movement.** Forced moves, mints and burns pass and carry no reference. `IntentExecuted` is not emitted for them.
- **It does not choose the executor.** Whoever holds `EXECUTOR_ROLE` on the token can submit intents that name no executor. Those grants are the token's admin's to make.
- **It does not hold movements to hours.** That is [`SettlementWindowRule`](SettlementWindowRule.md), which judges `EXECUTED` alone. Together the two would put a holder's movements inside the window; no profile lists them together at this commit.

<a id="connected"></a>
## Connected to

- [IntentToken](IntentToken.md): The template this rule is for.
- [IntentSettledUpgradeable](IntentSettledUpgradeable.md): Where signed intents are checked and executed.
- [IntentExecutor](IntentExecutor.md): Submits intents that state no consideration.
- [DvPExecutor](DvPExecutor.md): Settles a trade from two signed legs.
- [SettlementWindowRule](SettlementWindowRule.md): Holds executed movements to a token's hours.
- [BaseRule](BaseRule.md): The parent this rule inherits its defaults from.

<a id="source"></a>
## Source and tests

- Contract: `contracts/hooks/rules/ExecutedOnlyRule.sol`, interface `IExecutedOnlyRule.sol`, reason codes in `Errors.sol`
- Tests: `ExecutedOnlyRule.t.sol` (a plain transfer refused at any amount, every other kind passing, and on a real hook and `IntentToken`: the pre-flight agreeing, a signed intent moving, a forced move passing) and `test/nodejs/legos.test.ts` (the rule through the modules, and the module refusing it on a plain token)

---

Describes the contracts at commit `ea062b5` on `erc8473-main`.
