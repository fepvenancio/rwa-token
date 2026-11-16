[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Policy

# BaseRule

The parent every compliance rule is built on. It holds the one access check a rule needs, defaults for everything a rule may leave out, and the ERC-165 answer that says "I am a rule".

- **contracts/hooks/BaseRule.sol**
- abstract: **not deployed on its own**
- no admin, no state
- each rule built on it is attested as **RULE**

<a id="in-one-minute"></a>

> ### In one minute
>
> A rule is a small contract that answers one compliance question about a movement of tokens. Many tokens share the same rule contracts, and many tokens share one hook, the contract that asks the rules. So a rule must be careful about who may tell it that a movement happened. `BaseRule` settles that once for every rule: it asks the token named in the movement which hook it uses, and accepts the call only from that hook. A rule that keeps records keeps them under the token's address, so a caller who builds a fake token touches only the fake token's records.

<a id="how"></a>
## How the hook check works

Rules have two kinds of entry point. `check`, `checkSend` and `checkReceive` only read, so anyone may call them. `after_` is the one that may write: the hook calls it after the balances moved, for rules that asked for it. `BaseRule` guards it with the `onlyHook(ctx)` modifier, which asks `ctx.token` for its current hook (`policy()`, a read-only call) and compares the answer with the caller. A third entry point, `onInstall`, is called by the hook when a token installs it. In `BaseRule` it does nothing and has no guard.

> **Diagram.** Three callers of after\_. First, the hook H calls after\_ with ctx.token set to the real token T; the rule asks T for its hook, T answers H, H is the caller, so the rule runs and writes under the key T. Second, an attacker A calls after\_ naming T; T answers H, A is not H, so the call reverts with ComplianceRule_OnlyHook(A). Third, the attacker deploys a fake token F whose policy returns A and calls after\_ naming F; the check passes, but the rule writes only under the key F, and T's records are untouched.
>
> **The token decides who its hook is.** The rule trusts the hook that `ctx.token` names, whichever hook that is at the moment of the call. Through `after_`, a real token's records can be written only by that token's current hook. A fake token can name anyone as its hook, but only for its own records, which no real token reads.

1. **One read per call.** The check is one read-only call to the token, and rules that do not want `after_` do not pay for it, because the hook does not call `after_` on them.
2. **A wrong caller reverts.** Anyone but the token's current hook gets `ComplianceRule_OnlyHook(caller)`.
3. **Sound only with per-token state.** Case 3 is harmless only because rule state is keyed by `ctx.token`. A rule that kept one shared record for all tokens could be written through a fake token, so the interface requires the per-token key. The one shipped rule whose record is shared by several tokens, [`FundHoldersRule`](FundHoldersRule.md), keeps it in the [`Fund`](Fund.md), which accepts updates from its installed rule alone and for a registered class alone, so a fake token's call reverts there with `Fund_NotAClass`.

<a id="functions"></a>
## What it gives every rule

A rule built on `BaseRule` must still write `check(ctx)`, its decision, and `ruleId()`, the name of its type. Everything else has a default it can keep or replace.

| Item | Who can call | Default |
|---|---|---|
| `onlyHook(ctx)` | A modifier, used on `after_` | Lets the call through if the caller is `IPolicyGated(ctx.token).policy()`; otherwise reverts with `ComplianceRule_OnlyHook(caller)`. |
| `after_(ctx)` | The hook of `ctx.token` | Does nothing. Kept behind `onlyHook` even when empty. |
| `onInstall(token, previousPolicy)` | Anyone; the hook calls it for every rule of a token's list when the token installs the hook | Does nothing. A rule that keeps state derived from a token's movements replaces it, to confirm that state is current or revert, which undoes the installation. |
| `wantsAfter()` | Anyone (read-only) | False: the hook will not call `after_`. The hook reads this once, when a list is installed, so a rule must keep it constant. |
| `checkSend(token, account)` | Anyone (read-only) | `TRANSFER_OK`: no opinion about a sender on its own. |
| `checkReceive(token, account)` | Anyone (read-only) | `TRANSFER_OK`: no opinion about a receiver on its own. |
| `supportsInterface(id)` | Anyone (read-only) | ERC-165: true for `IComplianceRule` and `IERC165`. |
| `check(ctx)`, `ruleId()` | Anyone (read-only) | No default: declared by `IComplianceRule` and written by each rule. |

<a id="shipped"></a>
## What the seven shipped rules do with it

Each writes `check` and `ruleId`. The last column answers a question every rule must answer: what happens on a token that lists the rule and has set nothing.

| Rule | Account questions | `after_` | Configured by | With nothing configured |
|---|---|---|---|---|
| [`CredentialRule`](CredentialRule.md) | its own | default | the token's `DEFAULT_ADMIN_ROLE` | **Fails closed**: no receiver is admitted but the token's own address. A burn can still pass. |
| [`MinPositionRule`](MinPositionRule.md) | default | default | the token's `DEFAULT_ADMIN_ROLE` | **Zero is off**: everything passes. |
| [`HolderRestrictionRule`](HolderRestrictionRule.md) | its own | default | the token's `AGENT_ROLE` | **Nothing restricted**: no holder is locked or frozen until the agent says so. |
| [`SettlementWindowRule`](SettlementWindowRule.md) | default | default | the token's `DEFAULT_ADMIN_ROLE` | **Fails closed** for `EXECUTED`. Other kinds pass. |
| [`FundHoldersRule`](FundHoldersRule.md) | its own, the class check alone | its own, with `wantsAfter()` true | the `Fund`'s owner, on the fund | **Fails closed**: `NOT_FUND_CLASS` on every movement until the fund registers the class under this rule. A cap of 0 admits no new investor. |
| [`SupplyCapRule`](SupplyCapRule.md) | default | default | the token's `DEFAULT_ADMIN_ROLE` | **Fails closed** for `MINT`: zero is a cap of zero, not off. Other kinds pass. |
| [`ExecutedOnlyRule`](ExecutedOnlyRule.md) | default | default | nothing to configure | Listing it is the setting: a plain transfer is refused at once. |

"Default" means the behaviour in the table above. `after_` stays reachable on all of them, but the hook calls it on `FundHoldersRule` alone, because that is the one rule whose `wantsAfter()` is true. `FundHoldersRule` is also the one rule with its own `onInstall`: it reverts unless the class has no supply or the token's previous hook listed it. The other six keep the default. The first six add their own interface to `supportsInterface`. `ExecutedOnlyRule` keeps the `BaseRule` answer.

<a id="context"></a>
## What a rule is told about a movement

The token builds a `TransferContext` for every movement and the hook hands it to each rule unchanged. The fields are `token`, `from`, `to`, `tokenId` (0 for these fungible tokens), `amount`, `operator` (the account driving the movement), `kind` and `data`. `data` starts with both balances before the move, so a rule works out the balances after it from `amount` and does not call back into the token for them. Anyone can call `check` with a context of their own, which only reads. The kind says what sort of movement it is:

| Kind | What it is | Sender and receiver |
|---|---|---|
| TRANSFER | `transfer` or `transferFrom` by the holder or a spender, and the 7540 vault's moves of shares into its escrow (`requestRedeem`) and back out (`rejectRedeemRequest`) | both set |
| EXECUTED | A transfer the holder signed in advance (an intent), carried out by an executor through `executeTransfer`. `data` also carries the intent's reference and deadline. | both set |
| FORCED | An enforcement move: the agent's `forcedTransfer`, the burner's `burn` on a token, the 7540 vault's `recoverRedeemRequest`, and its `recoverClaimable`, which is an enforcement mint | both set; no sender on an enforcement mint, no receiver on the burner's burn |
| MINT | New units: the minter's `mint` on a token, a 4626 deposit, a 7540 deposit claim | no sender (`address(0)`) |
| BURN | A holder's own burn: a 4626 redemption, and the burn of the escrowed shares in a 7540 `settlePeriod` | no receiver (`address(0)`) |

<a id="writing"></a>
## What a rule must promise

The interface sets the terms between the hook and a rule. `BaseRule` cannot enforce all of them, and the registry's `attest` takes only a code hash, a kind and a URI, so the rest depends on the council reading each rule against them before attesting it.

- **`check` is read-only and does not revert on a decision.** It returns `TRANSFER_OK` or a reason code. It must not revert even for an amount above the sender's balance: the write does not offer the hook such an amount, but the token's `canTransfer` does, so a rule compares before it subtracts.
- **The account questions agree with `check`.** If `checkSend` or `checkReceive` refuses an account, `check` refuses every movement on that side of a kind the rule does not exempt. They take no amount and must not encode a quantitative rule. ERC-7943 keeps those out of the account questions and names balance checks and amount limits, and `IComplianceRule` reads a holder count the same way.
- **State is keyed by `ctx.token`.** The rules with per-token settings authorise them by the token's own roles, asked live with `hasRole`. `FundHoldersRule` has no settings: its cap and exemptions are on the fund, under the fund's owner. The post-deploy check (`assertHandedOver`) asserts that none of the core's rules has a `hasRole` or `owner` function of its own.
- **`onInstall` answers for state derived from movements.** A rule that keeps such state confirms there that it is current for the token, or reverts, and the installation is undone. A rule that writes state there must accept only the token's installed policy as the caller.
- **`after_` moves nothing in the token.** It runs inside the token's reentrancy guard, so a transfer from it reverts.
- **`ruleId()` names the rule type.** A hook takes one rule of each type per token.

<a id="why"></a>
## Why it is built this way

- **Rules do not store their hook.** Because `onlyHook` asks the token, a rule has no hook address built in. One deployed instance can serve every token (for `FundHoldersRule`, every class of its fund), keeps working when a token moves to another hook, and its code hash, which the council attests, does not depend on any hook.
- **Rules are plain contracts, not proxies.** They are attested by code hash, so the reviewed code is the code that runs. Changing a rule means deploying another, having it attested, and swapping it in with the hook's `setRules`.
- **Defaults that do nothing.** A rule with no account-level opinion accepts there, and `check` still decides every movement. A rule that does not want `after_` costs nothing after the move.
- **A forgotten answer refuses.** Every reason code is the hash of its name, so `TRANSFER_OK` is not zero. A rule that forgets to set its return value returns zero, which the hook passes on as a refusal.

<a id="limits"></a>
## What it does not do

- **It does not make a rule's state per-token.** That is a duty on whoever writes the rule. `BaseRule` cannot see how a rule stores things, so this too depends on the council reading a rule before attesting it.
- **It does not guard `check`.** Anyone may call it with any context. That is harmless because it only reads, but the answer to an invented context means nothing.
- **It trusts the token named in the context.** `onlyHook` protects a real token's records from everyone but that token's current hook. It says nothing about whether `ctx.token` is a real token: a fake one passes for its own key, and any state shared across tokens needs its own gate, as the `Fund` has.

<a id="connected"></a>
## Connected to

- [ComplianceHook](ComplianceHook.md): The shared hook that calls the rules in order and calls `after_` on the ones that asked for it.
- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): The token base that answers `policy()` and builds the context every rule receives.
- [FundHoldersRule](FundHoldersRule.md): The one shipped rule that uses `after_`.
- [PolicyRegistry](PolicyRegistry.md): Where each rule's code hash is attested as `RULE` before a hook will install it.

<a id="source"></a>
## Source and tests

- Contract: `contracts/hooks/BaseRule.sol`, interfaces `IComplianceRule.sol` and `IERC8473Policy.sol` (the context and the kinds), reason codes in `Errors.sol`
- Tests: `BaseRule` has no test file of its own, being abstract; it is tested through the rules built on it. `FundHoldersRule.t.sol` covers `onlyHook` (`FundHoldersRuleGate`: an attacker naming the real class, and a fake token naming itself and its hook) and a rule's own `onInstall` (`FundHoldersRuleUnit_OnInstall`). `SupplyCapRule.t.sol` and `ExecutedOnlyRule.t.sol` pin the account-question defaults. The test files of `CredentialRule`, `MinPositionRule`, `HolderRestrictionRule` and `SettlementWindowRule` each have a test that a fake token changes only its own records.

---

Describes the contracts at commit `ea062b5` on `erc8473-main`.
