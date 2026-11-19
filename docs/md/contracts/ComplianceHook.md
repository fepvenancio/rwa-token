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

The diagram follows one transfer of the intent token in the demo deployment, whose list has five rules. Every movement kind takes the same path: transfers, executed intents, forced transfers, mints and burns. The pre-flight answers (`canTransferWithReason`, `canExecute`) ask the same `checkTransfer`, so they give the answer the write would give in the same state, for the same kind and the same operator. `canTransferWithReason` takes the sender as the operator, which is the zero address on a mint, and asks only about `TRANSFER`, `MINT` and `BURN`. It does not ask about `FORCED`, so it can say `LOCKED_UP` where a `BURNER_ROLE` holder's `burn` passes.

> **Diagram.** One movement through the hook. The token builds the movement context and calls checkTransfer. The hook loads the rule list kept for that token; an empty list returns NO_RULES. It then asks CredentialRule, MinPositionRule, HolderRestrictionRule, SettlementWindowRule and FundHoldersRule in order. The first rule that does not answer TRANSFER_OK ends the decision, its reason is returned, later rules are not asked, and the token reverts with ERC8473PolicyRejected. If all answer OK the token moves the balances, then calls afterTransfer, because the hook's wantsAfterTransfer is always true. The hook calls after\_ only on FundHoldersRule, the one rule whose bit is set in the token's after mask.
>
> **First rejection wins.** The intent token's five rules in the order the demo deployment lists them. Each rule is asked in turn, and the first one that does not answer `TRANSFER_OK` ends the decision. Only `FundHoldersRule` asked for a call after the move when the list was installed, so its bit is the only one set in the token's after mask.

1. **The token checks first.** The token's own mechanical checks run before the hook: a pause (which `FORCED` ignores), then the unfrozen balance, then whether it has a hook at all (`NO_HOOK`). The token reads its hook address once per movement, so the hook that approves a movement is the hook that sees its `afterTransfer`.
2. **The list of this token.** `checkTransfer(ctx)` looks up the list kept for `ctx.token`. A token with no rules gets `NO_RULES` for every kind, `FORCED` included, because the token asks the hook even for a forced transfer.
3. **Rules in order, read-only.** The hook calls `check(ctx)` on each rule in list order and returns the first reason that is not `TRANSFER_OK`. `checkTransfer` and `check` are view functions, so the EVM runs them as static calls and a rule cannot change state while it decides.
4. **Balances move, then bookkeeping.** After the move the token asks `wantsAfterTransfer()`, which is true for every caller: the function takes no token, so a hook shared by many tokens cannot answer for one of them. The token then calls `afterTransfer(ctx)`. The hook refuses that call from anyone but the token named in the context (`ComplianceHook_OnlyToken(caller)`). It returns at once when the calling token's after mask has no bit set. Otherwise it walks the list of the calling token and calls `after_` in list order on the rules whose bit is set. This runs inside the token's reentrancy guard, so a rule that calls back into a transfer makes the whole movement revert.

<a id="lists"></a>
## The lists the deployment installs

Each product names its list in `ignition/profiles.ts`. The demo deployment is the `full` profile, whose lists are `RULE_ORDER` in `ignition/modules/roles.ts`; every other profile uses `PLAIN_RULES`. The `Product` module passes the list in the token's setup data. While it is being set up, the token installs the hook and hands it the list as the installation's data, and the hook's `onInstall` installs the list. [`ProxyDeployer`](ProxyDeployer.md) then reverts with `ProxyDeployer_RulesMismatch` unless the hook ends up holding exactly that list for the new token.

| Profile | Product | Rules, in the order they are asked | After mask |
|---|---|---|---|
| `full`, the demo | [`IntentToken`](IntentToken.md) | [CredentialRule](CredentialRule.md), [MinPositionRule](MinPositionRule.md), [HolderRestrictionRule](HolderRestrictionRule.md), [SettlementWindowRule](SettlementWindowRule.md), [FundHoldersRule](FundHoldersRule.md) | bit 4 (FundHoldersRule) |
| `full` | [`Gated4626Vault`](Gated4626Vault.md), [`Gated7540Vault`](Gated7540Vault.md) | CredentialRule, MinPositionRule, HolderRestrictionRule, FundHoldersRule | bit 3 (FundHoldersRule) |
| `token` | [`GatedToken`](GatedToken.md) | CredentialRule, HolderRestrictionRule | none |
| `intent` | [`IntentToken`](IntentToken.md) | CredentialRule, HolderRestrictionRule | none |
| `nft` | [`Gated721`](Gated721.md) | CredentialRule, HolderRestrictionRule | none |
| `multi` | [`Gated1155`](Gated1155.md) | CredentialRule, HolderRestrictionRule | none |
| `vault4626`, `vault4626-invest` | `Gated4626Vault` | CredentialRule, HolderRestrictionRule | none |
| `vault7540`, `managed-fund` | `Gated7540Vault` | CredentialRule, HolderRestrictionRule | none |

[`SupplyCapRule`](SupplyCapRule.md) and [`ExecutedOnlyRule`](ExecutedOnlyRule.md) are in no profile at this commit. A product asks for them by naming `supplyCapRule` or `executedOnlyRule` in its `rules`, as a profile in `test/nodejs/legos.test.ts` does.

Where the rules sit is a choice with a reason. `MinPositionRule` comes right after the credential check so that, when a minimum is set, the rules after it see real positions. The vaults have no window rule because they have no executed transfers. The fund rule comes last. Because the first refusal wins, the order also decides which reason a caller sees: a sender with no credential who is also locked up gets `SENDER_NOT_ELIGIBLE`, not `LOCKED_UP`.

`assertUsable` in `ignition/profiles.ts` throws when a module is built for a list its template cannot use: a window or signed-only rule on anything but an `IntentToken`, a supply cap on a vault, a minimum position, a fund rule or a supply cap on a `Gated721`, a fund rule or a supply cap on a `Gated1155`, a fund rule with no fund. That check runs when the module is built. The hook itself judges no combination: it takes any attested rule on any token, unless a rule the list adds refuses in its own `onInstall`.

<a id="set-rules"></a>
## Changing a token's list

A list is not edited in place. `setRules(token, rules)` replaces the whole list, and the checks below run in one call. One bad entry fails the whole call, so a token does not end up with half a list.

1. **Who is asking.** The caller is the token itself, or holds `DEFAULT_ADMIN_ROLE` on the token. The hook asks the token at call time (`hasRole`, a read-only call), so it keeps no admin list of its own and follows the token's role changes. An address with no code cannot be asked, so nobody else can set its list, and its own call reverts at step 5, where the hook asks the token for its policy. Otherwise: `ComplianceHook_NotTokenAdmin(token, caller)`. The exception is a contract with no `hasRole`: it cannot answer, and the call reverts without that error.
2. **The hard cap.** At most `MAX_RULES`, 16, per token (`ComplianceHook_TooManyRules(count)`). The cap is per token: two tokens can each hold 16.
3. **Reviewed rules only.** Each rule's code hash must be attested as `RULE` in the registry (`ComplianceHook_NotAttested(rule)`).
4. **One instance per `ruleId`.** No two rules on a list may share a `ruleId()`, which names the rule type (`ComplianceHook_DuplicateRule(rule)`). The same contract listed twice fails the same way, and so do two instances of one rule. The shipped rules fix their id in code, so a second configuration of the same logic on one token would need a contract with another id.
5. **Tell the rules it adds.** Once the whole list has passed checks 2 to 4, the hook asks the token which policy it consults at that moment (`policy()`) and calls `onInstall(token, policy)` on every rule of the new list that the list it replaces does not hold (`test_WhenARuleIsAdded_ItIsToldWithTheTokensPolicy`). A rule that stays is not called (`test_WhenARuleStays_ItIsNotToldAgain`). The replaced list is still the stored one while the rules are asked, so a rule that asks the hook which rules it held sees the list that lacked it (`test_WhenARuleIsAdded_ItIsToldBeforeTheListIsStored`). A rule that reverts fails the call with its own error, and the list stays as it was (`test_WhenAnAddedRuleRefuses_TheOldListStays`). The policy named is this hook when the token has it installed, and another one while this hook is being prepared for a token that still consults that other (`test_WhenTheTokenConsultsAnotherPolicy_TheRuleIsToldThatOne`).
6. **Store and announce.** The current list is cleared, the given one stored in order, and each rule's `wantsAfter()` is read once and recorded as a bit of the after mask. Emits `RuleSetChanged` with the token and the rule ids in order.

A token's first list does not come through `setRules`. The token's setup function installs the hook with the list as the installation's data, `abi.encode(rules)`, and the hook's `onInstall(token, previousPolicy, data)` installs it in the same call, with checks 2 to 4 and step 6 above, and tells every rule of the list, as described below. Only the token may call `onInstall` (`ComplianceHook_OnlyToken(caller)`), so no role is asked. With no initial rules the data is empty and the hook keeps the list it holds for the token, which for a token it has not seen is the empty one. While a product launches, the operations account holds `DEFAULT_ADMIN_ROLE`. The `Product` module then grants it to the main timelock and the operations account renounces, so a later change to a list is a governance operation with its delay. The governance multisig calling the hook directly is refused.

Passing an empty list is allowed, and it makes the token refuse every movement with `NO_RULES`.

Replacing the hook itself is the token's `installPolicy(newPolicy, data)`, also under `DEFAULT_ADMIN_ROLE`. The token accepts only a hook attested as `HOOK` whose `REGISTRY()` is the token's own registry and which answers the ERC-165 id of `IERC8473Policy`, `0x9cb56a99`. A second hook built on the same registry has the same code hash, so the council's one attestation covers it. The token then calls the receiving hook's `onInstall(token, previousPolicy, data)`. Data that is not empty is `abi.encode` of the token's ordered list, and the hook stores it with the checks of `setRules`. Empty data keeps the list the receiving hook already holds for the token; if that list is empty, the token refuses every movement with `NO_RULES` from the moment the swap takes effect.

On every installation the hook tells each rule, with `onInstall(token, previousPolicy)` on the rule, and it does so before it stores a list. With data that is not empty the hook decodes the list and refuses one longer than 16 (`ComplianceHook_TooManyRules(count)`). It then takes the rules in order: each must be attested as `RULE` (`ComplianceHook_NotAttested(rule)`) and is then told. Only after every rule has been told is the list stored, by the step that checks duplicates and emits `RuleSetChanged`. With empty data the hook tells the rules of the list it already holds for the token and stores nothing. The rules are told first because a rule may ask the previous policy which rules it held for the token. When a token installs the hook it already has, that previous policy is this hook, and it must still answer with the list it held. A rule that reverts there undoes the whole installation, and the token keeps the hook and the list it had. The rules that keep no state derived from movements do nothing there. [`FundHoldersRule`](FundHoldersRule.md) reverts when the class has a supply and the previous hook listed neither it nor another rule of the same fund for the token. `setRules` asks the rules it adds the same question, in step 5 above, so a list that dropped the fund's rule cannot take it back while the class has a supply.

<a id="account"></a>
## The account questions

ERC-7943, the standard the tokens implement, asks two questions that take no amount: may this account send at all, and may it receive at all. The token answers them with `canSend` and `canReceive`, which are true for the zero address without asking the hook, false for any other account while the token is paused or has no hook, and otherwise ask the hook's `checkSend(token, account)` or `checkReceive(token, account)`. The hook walks the same list in the same order, calls each rule's own `checkSend` or `checkReceive`, and returns the first refusal, or `NO_RULES` for an empty list. A rule with no opinion about an account on its own, like the minimum position or the window, accepts every account there.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `setRules(token, rules)` | The token itself, or an account holding `DEFAULT_ADMIN_ROLE` on that token | Replaces the token's whole ordered list in one step. Before it stores the list, it calls `onInstall(token, policy)` on each rule the replaced list did not hold, with the policy the token consults at that moment. Emits `RuleSetChanged` with the token and the rule ids. Reverts with `ComplianceHook_NotTokenAdmin`, `ComplianceHook_TooManyRules`, `ComplianceHook_NotAttested` or `ComplianceHook_DuplicateRule`, or with a rule's own error when an added rule refuses, and then nothing changes. |
| `onInstall(token, previousPolicy, data)` | The token named in `token`, which calls it every time it installs the hook | Data that is not empty is `abi.encode` of the token's ordered rule list. A list longer than 16 is refused. Each rule is attested and then told with `onInstall(token, previousPolicy)`, and after every rule has been told the list is stored with the checks of `setRules` and the same `RuleSetChanged`. Empty data tells the rules of the list the hook already holds for the token and stores nothing. Reverts with `ComplianceHook_OnlyToken(caller)` for any other caller, with `ComplianceHook_TooManyRules`, `ComplianceHook_NotAttested` or `ComplianceHook_DuplicateRule` for a bad list, and with a rule's own error when a rule refuses. |
| `checkTransfer(ctx)` | Anyone (read-only) | The decision for one movement: `TRANSFER_OK` or the first refusal of the list of `ctx.token`; `NO_RULES` for an empty list. |
| `afterTransfer(ctx)` | The token named in `ctx.token` | Calls `after_` on the rules of that token whose bit is set in its after mask, and returns at once when no bit is set. Reverts with `ComplianceHook_OnlyToken(caller)` for any other caller. |
| `checkSend(token, account)`, `checkReceive(token, account)` | Anyone (read-only) | The account questions behind the token's `canSend` and `canReceive`. Same list, same order, first refusal wins, `NO_RULES` for an empty list. |
| `wantsAfterTransfer()` | Anyone (read-only) | True, always and for every caller. It takes no token and does not read the caller, so every token calls `afterTransfer` after each movement, and the after mask decides there which rules run. |
| `rules(token)`, `ruleCount(token)` | Anyone (read-only) | A token's list in evaluation order, and its length. |
| `REGISTRY()`, `MAX_RULES()` | Anyone (read-only) | The registry the hook vets rules against, fixed at construction, and the cap of 16 rules per token. |
| `supportsInterface(id)` | Anyone (read-only) | ERC-165: true for `IERC8473Policy` (`0x9cb56a99`), `IComplianceHook` and `IERC165`. |

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

- **It does not judge a list.** Any set of attested rules, in any order, is accepted, unless a rule the list adds refuses to go live. No rule is required: a list without `CredentialRule` checks no identity, and a list without the fund's rule un-caps that class. The hook does not know the list a product is meant to have. `ProxyDeployer` compares it at launch, and the post-deploy check (`assertHandedOver`) compares it with the profile. After that, the control is the timelock's delay, and for a fund `Fund.firstBrokenClass()` reports a class whose list lost the rule.
- **It does not enforce one hook per deployment.** A second instance on the same registry shares the attested code hash, so a token can be placed on it. The post-deploy check (`assertHandedOver`, run off chain) throws if a product runs another instance. No contract refuses it, and after hand-over a swap to it is a timelock operation.
- **It does not re-check attestation.** A rule whose attestation is withdrawn stays on the list until a `setRules` removes it.
- **It does not catch a rule that reverts.** There is no try and catch around a rule. The interface tells a rule not to revert on a decision. If one did, the hook's `checkTransfer` would revert with that rule's error. The token asks the hook through a call that reads any failure as a refusal, so the movement would revert with `ERC8473PolicyRejected(CHECK_UNAVAILABLE)` and the token's pre-flights would read false, with `CHECK_UNAVAILABLE` as the reason. A rule that reverts in `after_` makes the movement revert with that rule's error.
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

- Contract: `contracts/hooks/ComplianceHook.sol`, interfaces `IComplianceHook.sol` and `IERC8473Policy.sol`, reason codes in `Errors.sol`
- Tests: `ComplianceHook.t.sol` (unit tests with mocked rules and registry: who may set a list, the cap, attestation, duplicates, the rules a new list adds being told in `ComplianceHookUnit_SetRulesTellsAddedRules`, first refusal, the after mask, installation through `onInstall` in `ComplianceHookUnit_OnInstall`, isolation between tokens), `RuleSetIntegration.t.sol` (MinPositionRule, HolderRestrictionRule and SettlementWindowRule behind a test identity rule, on a real hook and a real IntentToken, with pre-flight parity), `IntentToken.t.sol` (a rule that tries to re-enter the token makes the movement revert), `test/nodejs/governance.test.ts` (list and hook changes through the timelock) and `test/nodejs/deployment.test.ts` (the deployed lists, and a second hook on the same registry refused by the hand-over check)
