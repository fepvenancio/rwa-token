[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Policy

# ComplianceHook

The contract every token asks before a balance moves. One hook serves all the tokens of a deployment. It keeps an ordered list of reviewed rules for each token, asks them in turn, and passes on the first refusal.

- **contracts/hooks/ComplianceHook.sol**
- immutable, **not a proxy**
- no admin of its own: **each token's admin** sets that token's rules
- attested as **HOOK**
- at most **16 rules** per token

<a id="in-one-minute"></a>

> ### In one minute
>
> A token here does not decide on its own who may hold it. Before every transfer, mint or burn it asks a separate contract, the hook. The hook holds, for each token, a short ordered list of rules: small contracts that each check one thing, such as "does the receiver hold an accepted credential" or "is this holder locked up". The hook asks the rules one by one. If all say yes, the movement goes ahead. The first rule that says no stops it, and its reason code is what the caller sees.
>
> A rule must be reviewed and registered (attested) by the security council before it can go on a list, and a list holds at most 16 rules. A token with an empty list refuses every movement. A token's list changes only through the token's own setup or through an account holding the token's administrator role, which after hand-over is the timelock, so a change waits out a delay.

<a id="how"></a>
## How one movement passes through the list

The diagram follows one transfer of the intent token in the demo deployment, whose list has five rules. Every movement kind takes the same path: transfers, executed intents, forced transfers, mints and burns. The pre-flight answers (`canTransferWithReason`, `canExecute`) ask the same `beforeTransfer`, so they give the answer the write would give in the same state, for the same kind and the same operator. `canTransferWithReason` takes the sender as the operator, or the caller on a mint, and asks only about `TRANSFER`, `MINT` and `BURN`, so it can say `LOCKED` where a `BURNER_ROLE` holder's `burn` passes.

> **Diagram.** One movement through the hook. The token builds the movement context and calls beforeTransfer. The hook loads the rule list kept for that token; an empty list returns NO_RULES. It then asks CredentialRule, MinPositionRule, HolderRestrictionRule, SettlementWindowRule and FundHoldersRule in order. The first rule that does not answer TRANSFER_OK ends the decision, its reason is returned, later rules are not asked, and the token reverts with PolicyGated_TransferRejected. If all answer OK the token moves the balances, then, because the token's after mask has a bit set, calls afterTransfer, which calls after\_ only on FundHoldersRule, the one rule whose bit is set.
>
> **First rejection wins.** The intent token's five rules in the order the demo deployment lists them. Each rule is asked in turn, and the first one that does not answer `TRANSFER_OK` ends the decision. Only `FundHoldersRule` asked for a call after the move when the list was installed, so its bit is the only one set in the token's after mask.

1. **The token checks first.** The token's own mechanical checks run before the hook: a pause (which `FORCED` ignores), then the unfrozen balance, then whether it has a hook at all (`NO_HOOK`). The token reads its hook address once per movement, so the hook that approves a movement is the hook that sees its `afterTransfer`.
2. **The list of this token.** `beforeTransfer(ctx)` looks up the list kept for `ctx.token`. A token with no rules gets `NO_RULES` for every kind, `FORCED` included, because the token asks the hook even for a forced transfer.
3. **Rules in order, read-only.** The hook calls `check(ctx)` on each rule in list order and returns the first reason that is not `TRANSFER_OK`. `beforeTransfer` and `check` are view functions, so the EVM runs them as static calls and a rule cannot change state while it decides.
4. **Balances move, then bookkeeping.** After the move the token asks `wantsAfter()`, which the hook answers for the calling token from its after mask. If any bit is set, the token calls `afterTransfer(ctx)`. The hook refuses that call from anyone but the token named in the context (`ComplianceHook_OnlyToken(caller)`), walks the list of the calling token, and calls `after_` in list order on the rules whose bit is set. This runs inside the token's reentrancy guard, so a rule that calls back into a transfer makes the whole movement revert.

<a id="lists"></a>
## The lists the deployment installs

Each product names its list in `ignition/profiles.ts`. The demo deployment is the `full` profile, whose lists are `RULE_ORDER` in `ignition/modules/roles.ts`; every other profile uses `PLAIN_RULES`. The `Product` module passes the list in the token's setup data. The token installs it on the hook while it is being set up, and [`ProxyDeployer`](ProxyDeployer.md) reverts with `ProxyDeployer_RulesMismatch` unless the hook ends up holding exactly that list for the new token.

| Profile | Product | Rules, in the order they are asked | After mask |
|---|---|---|---|
| `full`, the demo | [`IntentToken`](IntentToken.md) | [CredentialRule](CredentialRule.md), [MinPositionRule](MinPositionRule.md), [HolderRestrictionRule](HolderRestrictionRule.md), [SettlementWindowRule](SettlementWindowRule.md), [FundHoldersRule](FundHoldersRule.md) | bit 4 (FundHoldersRule) |
| `full` | [`Gated4626Vault`](Gated4626Vault.md), [`Gated7540Vault`](Gated7540Vault.md) | CredentialRule, MinPositionRule, HolderRestrictionRule, FundHoldersRule | bit 3 (FundHoldersRule) |
| `token` | [`GatedToken`](GatedToken.md) | CredentialRule, HolderRestrictionRule | none |
| `intent` | [`IntentToken`](IntentToken.md) | CredentialRule, HolderRestrictionRule | none |
| `nft` | [`Gated721`](Gated721.md) | CredentialRule, HolderRestrictionRule | none |
| `vault4626`, `vault4626-invest` | `Gated4626Vault` | CredentialRule, HolderRestrictionRule | none |
| `vault7540`, `managed-fund` | `Gated7540Vault` | CredentialRule, HolderRestrictionRule | none |

[`SupplyCapRule`](SupplyCapRule.md) and [`ExecutedOnlyRule`](ExecutedOnlyRule.md) are in no profile at this commit. A product asks for them by naming `supplyCapRule` or `executedOnlyRule` in its `rules`, as a profile in `test/nodejs/legos.test.ts` does.

Where the rules sit is a choice with a reason. `MinPositionRule` comes right after the credential check so that, when a minimum is set, the rules after it see real positions. The vaults have no window rule because they have no executed transfers. The fund rule comes last. Because the first refusal wins, the order also decides which reason a caller sees: a sender with no credential who is also locked up gets `SENDER_NOT_VERIFIED`, not `LOCKED`.

`assertUsable` in `ignition/profiles.ts` throws when a module is built for a list its template cannot use: a window or signed-only rule on anything but an `IntentToken`, a supply cap on a vault, a minimum position, a fund rule or a supply cap on a `Gated721`, a fund rule with no fund. That check runs when the module is built. The hook itself accepts any attested rule on any token.

<a id="set-rules"></a>
## Changing a token's list

A list is not edited in place. `setRules(token, rules)` replaces the whole list, and the checks below run in one call. One bad entry fails the whole call, so a token does not end up with half a list.

1. **Who is asking.** The caller is the token itself, or holds `DEFAULT_ADMIN_ROLE` on the token. The hook asks the token at call time (`hasRole`, a read-only call), so it keeps no admin list of its own and follows the token's role changes. An address with no code cannot be asked, so nobody but that address itself could set its list. Otherwise: `ComplianceHook_NotTokenAdmin(token, caller)`. The exception is a contract with no `hasRole`: it cannot answer, and the call reverts without that error.
2. **The hard cap.** At most `MAX_RULES`, 16, per token (`ComplianceHook_TooManyRules(count)`). The cap is per token: two tokens can each hold 16.
3. **Reviewed rules only.** Each rule's code hash must be attested as `RULE` in the registry (`ComplianceHook_NotAttested(rule)`).
4. **One instance per `ruleId`.** No two rules on a list may share a `ruleId()`, which names the rule type (`ComplianceHook_DuplicateRule(rule)`). The same contract listed twice fails the same way, and so do two instances of one rule. The shipped rules fix their id in code, so a second configuration of the same logic on one token would need a contract with another id.
5. **Store and announce.** The current list is cleared, the given one stored in order, and each rule's `wantsAfter()` is read once and recorded as a bit of the after mask. Emits `RuleSetChanged` with the token and the rule ids in order.

The one place a token calls `setRules` itself is its setup function, which installs the hook and then the initial list in the same call. That is why the hook accepts the token without asking for a role: the token is the caller, and it holds no role on itself. While a product launches, the operations account holds `DEFAULT_ADMIN_ROLE`. The `Product` module then grants it to the main timelock and the operations account renounces, so a later change to a list is a governance operation with its delay. The governance multisig calling the hook directly is refused.

Passing an empty list is allowed, and it makes the token refuse every movement with `NO_RULES`.

Replacing the hook itself is the token's `setPolicyHook`, also under `DEFAULT_ADMIN_ROLE`. The token accepts only a hook attested as `HOOK` whose `REGISTRY()` is the token's own registry. A second hook built on the same registry has the same code hash, so the council's one attestation covers it. The token's list must be set on the receiving hook before the swap; otherwise the token refuses every movement with `NO_RULES` from the moment the swap takes effect.

<a id="account"></a>
## The account questions

ERC-7943, the standard the tokens implement, asks two questions that take no amount: may this account send at all, and may it receive at all. The token answers them with `canSend` and `canReceive`, which are false while the token is paused or has no hook, and otherwise ask the hook's `checkSend(token, account)` or `checkReceive(token, account)`. The hook walks the same list in the same order, calls each rule's own `checkSend` or `checkReceive`, and returns the first refusal, or `NO_RULES` for an empty list. A rule with no opinion about an account on its own, like the minimum position or the window, accepts every account there.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `setRules(token, rules)` | The token itself, or an account holding `DEFAULT_ADMIN_ROLE` on that token | Replaces the token's whole ordered list in one step. Emits `RuleSetChanged` with the token and the rule ids. Reverts with `ComplianceHook_NotTokenAdmin`, `ComplianceHook_TooManyRules`, `ComplianceHook_NotAttested` or `ComplianceHook_DuplicateRule`, and then nothing changes. |
| `beforeTransfer(ctx)` | Anyone (read-only) | The decision for one movement: `TRANSFER_OK` or the first refusal of the list of `ctx.token`; `NO_RULES` for an empty list. |
| `afterTransfer(ctx)` | The token named in `ctx.token` | Calls `after_` on the rules of that token whose bit is set in its after mask. Reverts with `ComplianceHook_OnlyToken(caller)` for any other caller. |
| `checkSend(token, account)`, `checkReceive(token, account)` | Anyone (read-only) | The account questions behind the token's `canSend` and `canReceive`. Same list, same order, first refusal wins, `NO_RULES` for an empty list. |
| `wantsAfter()` | Anyone (read-only) | True if the calling address's after mask has a bit set. It answers for the caller, so a shared hook answers each token for itself. |
| `rules(token)`, `ruleCount(token)` | Anyone (read-only) | A token's list in evaluation order, and its length. |
| `REGISTRY()`, `MAX_RULES()` | Anyone (read-only) | The registry the hook vets rules against, fixed at construction, and the cap of 16 rules per token. |
| `supportsInterface(id)` | Anyone (read-only) | ERC-165: true for `IPolicyHook`, `IComplianceHook` and `IERC165`. |

The constructor takes the registry and refuses the zero address (`ComplianceHook_ZeroAddress`). The hook has no other setter and no owner.

<a id="why"></a>
## Why it is built this way

- **One hook per deployment, one review.** The registry is the hook's only immutable, so two hooks on the same registry have the same code hash. The council attests it once, the `Core` module deploys one instance, and a product needs a list on that instance, not a hook of its own.
- **Everything is kept per token.** The lists and the after masks are stored by token address. A token can set its own list and no other, and one token's `afterTransfer` cannot run another token's rules, because the hook walks the list of the caller and refuses a caller the context does not name (tests cover both).
- **It fails closed.** An empty list refuses everything. A rule that is not attested, or a duplicate, fails the whole `setRules` call.
- **The after mask is fixed at install.** Reading `wantsAfter()` once, when the list is installed, saves a call per rule on every movement, and a rule cannot start or stop asking for `after_` later. The count and the mask share one storage word.
- **Attestation is checked when a rule is installed, not on every transfer.** Withdrawing an attestation does not silently drop a rule from a running token; governance removes it with `setRules`, and the guardian can pause the token meanwhile.
- **A hard cap of 16.** Every loop in the hook runs over at most 16 rules, so the number of rule calls in a movement has a known upper bound.

<a id="limits"></a>
## What it does not do

- **It does not judge a list.** Any set of attested rules, in any order, is accepted. No rule is required: a list without `CredentialRule` checks no identity, and a list without the fund's rule un-caps that class. The hook does not know the list a product is meant to have. `ProxyDeployer` compares it at launch, and the post-deploy check (`assertHandedOver`) compares it with the profile. After that, the control is the timelock's delay, and for a fund `Fund.firstBrokenClass()` reports a class whose list lost the rule.
- **It does not enforce one hook per deployment.** A second instance on the same registry shares the attested code hash, so a token can be placed on it. The post-deploy check (`assertHandedOver`, run off chain) throws if a product runs another instance. No contract refuses it, and after hand-over a swap to it is a timelock operation.
- **It does not re-check attestation.** A rule whose attestation is withdrawn stays on the list until a `setRules` removes it.
- **It does not catch a rule that reverts.** There is no try and catch around a rule. The interface tells a rule not to revert on a decision, and if one did, the movement and its pre-flight would revert with that rule's error, not a reason code.
- **It has no delay of its own.** `setRules` takes effect in the call. The delay comes from who holds the token's `DEFAULT_ADMIN_ROLE`.

<a id="connected"></a>
## Connected to

- [BaseRule](BaseRule.md): The parent every rule inherits, with the check that only a token's current hook may call `after_`.
- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): The token base that builds the context, asks the hook and reverts on a refusal.
- [PolicyRegistry](PolicyRegistry.md): The list of reviewed code the hook checks every rule against.
- [ProxyDeployer](ProxyDeployer.md): Reads the hook's list for each new token and refuses a token whose list is not the expected one.
- [One movement](../movement.md): Every check a movement meets, from the token's own checks to the last rule.
- [Deployment and governance](../deployment.md): How the lists are installed at launch and changed through the timelock.

<a id="source"></a>
## Source and tests

- Contract: `contracts/hooks/ComplianceHook.sol`, interfaces `IComplianceHook.sol` and `IPolicyHook.sol`, reason codes in `Errors.sol`
- Tests: `ComplianceHook.t.sol` (unit tests with mocked rules and registry: who may set a list, the cap, attestation, duplicates, first refusal, the after mask, isolation between tokens), `RuleSetIntegration.t.sol` (MinPositionRule, HolderRestrictionRule and SettlementWindowRule behind a test identity rule, on a real hook and a real IntentToken, with pre-flight parity), `IntentToken.t.sol` (a rule that tries to re-enter the token makes the movement revert), `test/nodejs/governance.test.ts` (list and hook changes through the timelock) and `test/nodejs/deployment.test.ts` (the deployed lists, and a second hook on the same registry refused by the hand-over check)

---

Describes the contracts at commit `4a906cc` on `main`.
