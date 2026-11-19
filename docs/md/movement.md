[Overview](index.md) · [Contracts](index.md#contracts) · [Who can do what](roles.md) · [One movement](movement.md) · [Deployment and governance](deployment.md) · [Where the money sits](money.md)

[Overview](index.md) / Topics

# One movement

Every change to a balance, on every token, goes through one internal function, `_move`. This page follows one movement through it: how its kind is chosen, what the rules are told, what the token checks itself, what each rule checks, and what the caller sees when the answer is no.

- one path: **\_move** in the base
- **5** kinds of movement
- up to **16** rules per token, first no wins
- **29** reason codes in Errors.sol

<a id="in-one-minute"></a>

> ### In one minute
>
> Whatever the route, a transfer, a mint, a vault deposit or an enforcement action, the token ends up in `_move`. It writes down who is involved and their balances, labels the movement with a kind, and checks two things itself: whether it is paused, and whether the sender can move that much. Then it asks the hook, which asks the token's rules one by one. The first rule that answers anything other than `TRANSFER_OK` stops the movement, and the whole call reverts with that answer. If they all agree, the balances move, `Transfer` is emitted, and rules that asked to be told afterwards are told. Read-only versions of the same path, the pre-flights, let anyone ask first.

[The path](#path) · [Kinds](#kinds) · [Context](#context) · [Token's own checks](#own-checks) · [Rule chain](#chain) · [Rules by kind](#matrix) · [After the move](#after) · [Pre-flights](#preflight) · [Reason codes](#reasons) · [Rejections](#rejections) · [Why](#why) · [Limits](#limits)

<a id="path"></a>
## The path of one movement

OpenZeppelin's ERC-20 code calls `_update(from, to, value)` for each balance change. The base overrides it to call `_move`, and `_move` is the one place that calls OpenZeppelin's own `_update`, the code that writes the balances. No fungible template overrides `_move`, so every route reaches these steps in this order.

The NFT template, [`Gated721`](contracts/Gated721.md), has its own path in the same order: ERC-721's existence and approval checks, then in its own `_move` the pause, the freeze of that item, the same hook, the move and `afterTransfer`. On a transfer, ERC-721 checks that `from` is the owner after that. Its context has the token id in `tokenId` and 1 as `amount`, and `data` holds how many items each side held. The rest of this page follows the fungible path.

> **Diagram.** Three functions lead into \_move. \_update infers the kind from the addresses and serves transfer, mint and the vault calls. \_moveAs announces FORCED or EXECUTED and serves forcedTransfer, executeTransfer and recoverRedeemRequest. \_mintAs announces FORCED and serves recoverClaimable. The burner's burn calls \_move itself, as FORCED. Inside \_move: 1, take the reentrancy guard. 2, build the context with the balances before the move. 3, read the hook address once. 4, if paused and the kind is not FORCED, revert with ERC8473PolicyRejected(PAUSED). 5, if the amount is above what the sender can move, revert with ERC7943InsufficientUnfrozenBalance, or with ERC20InsufficientBalance above the whole balance. 6, if no hook is installed, revert with ERC8473PolicyRejected(NO_HOOK). 7, the hook asks the token's rules in order; a reason other than TRANSFER_OK reverts with ERC8473PolicyRejected(reason). 8, OpenZeppelin's \_update moves the balances and emits Transfer. 9, if the hook's wantsAfterTransfer() is true, afterTransfer runs after\_ on the rules that asked. 10, release the guard.
>
> **Two gates before the balances move, one notice after.** Red boxes are reverts, and a revert undoes the whole call. Steps 4 to 7 are the shared check, `_check`, which `canTransfer`, `canTransferWithReason` and `canExecute` also run. `_check` only returns a reason code; `_move` turns it into the error shown.

- **Before `_move`.** Some entry points check things of their own first: the caller's role, the allowance in `transferFrom`, the intent and its signature in `executeTransfer`. `forcedTransfer` and the burner's `burn` also call `_releaseFrozen`. [What a rejection looks like](#rejections) lists them.
- **Step 1, the guard.** `_move` is `nonReentrant` (OpenZeppelin's `ReentrancyGuardUpgradeable`, which keeps its flag in storage), so nothing called during the movement can start another movement on the same token.
- **Step 2, the context.** See [What the hook is told](#context). The kind is an argument: [The five kinds](#kinds) says where it comes from.
- **Step 3, the hook.** The address is read once into a local variable, so the hook that approved the movement is the hook that hears about it afterwards.
- **Steps 4 and 5.** See [The token's own checks](#own-checks).
- **Steps 6 and 7.** The initialiser and `installPolicy` refuse the zero address (`PolicyGated_ZeroAddress`), so an initialised token has a hook. A hook that cannot be asked gives the reason `CHECK_UNAVAILABLE`. See [The rule chain](#chain).
- **Step 9.** See [After the balances move](#after).

<a id="kinds"></a>
## The five kinds

The kind tells the rules whose authority moves the tokens. A rule can treat an enforcement move by the agent differently from a holder's transfer, even when the addresses are the same. Three kinds can be read from the addresses, which is what `_update` does with `_inferKind`. The other two cannot, so the function that starts them calls `_moveAs` (between two accounts) or `_mintAs` (a mint) and names the kind. The burner's `burn` calls `_move` itself and names FORCED.

| Kind | What it is | Entry points | How the token knows |
|---|---|---|---|
| TRANSFER | A holder moves tokens, or a spender with an allowance does | `transfer`, `transferFrom`; on `Gated721`, `transferFrom` and `safeTransferFrom`; on `Gated7540Vault`, `requestRedeem` (owner to the vault) and `rejectRedeemRequest` (vault back to the controller) | Inferred: both addresses are set |
| EXECUTED | A holder's signed intent, run by an executor | `IntentToken.executeTransfer` | Named through `_moveAs`, with the intent's `ref` and `deadline` |
| FORCED | An enforcement move by the agent, the burner or, once a period has closed, the settler | `forcedTransfer`; `burn` on `GatedToken`, `IntentToken` and `Gated721` (so `to` is zero); on `Gated7540Vault`, `recoverRedeemRequest` (escrow to a recovery account) and `recoverClaimable` (claimable shares minted to a recovery account, so `from` is zero) | Named through `_moveAs`, through `_mintAs` for the mint, or by `burn` in its call to `_move` |
| MINT | New tokens | `mint` on `GatedToken`, `IntentToken` and `Gated721`; `Gated4626Vault.deposit` and `mint`; the `Gated7540Vault` deposit claims (`deposit`, `mint`) | Inferred: `from` is zero |
| BURN | A holder's own tokens destroyed | `Gated4626Vault.withdraw` and `redeem`; `Gated7540Vault.settlePeriod` (burns the escrowed shares it takes) | Inferred: `to` is zero |

The burner's `burn` is the one code path that produces FORCED with `to` zero: `_moveAs` and `_mintAs` refuse a zero receiver with `ERC20InvalidReceiver`. `GatedToken`, `IntentToken` and `Gated721` have no holder burn, so nothing on them produces BURN. Both vaults make the issuer's `mint(address, uint256)` and `burn(address, uint256)` revert with `GatedVault_Unsupported`. The 7540 vault's `redeem` and `withdraw` move no shares, because the shares were burned at settlement.

<a id="context"></a>
## What the hook is told

The token builds a `TransferContext` for every movement, with one function, `_context`, for the write and for the pre-flights that ask about a movement (`canTransferWithReason`, `canTransfer`, `canExecute`). A caller of the token cannot supply one.

| Field | Value |
|---|---|
| `token` | The token's own address. A shared hook and shared rules key their state by it. |
| `from` | The sender; zero on a mint. |
| `to` | The receiver; zero on a burn. |
| `tokenId` | 0 for these fungible tokens. |
| `amount` | The amount moved. |
| `operator` | The account that called the token: the holder for `transfer`, the spender for `transferFrom`, the executor for `executeTransfer`, the minter, burner, agent or settler for their calls, the caller of a vault function. |
| `kind` | One of the five kinds. |
| `data` | The balances before the move, then, for EXECUTED only, the intent's `ref` and `deadline`. The next table gives each kind. |

| Kind | `data` | Notes |
|---|---|---|
| TRANSFER | `abi.encode(fromBalance, toBalance)` | Two words. |
| EXECUTED | `abi.encode(fromBalance, toBalance, ref, deadline)` | Four words. Decoding the first two with `abi.decode(ctx.data, (uint256, uint256))` ignores the rest. No shipped rule reads `ref` or `deadline`. |
| FORCED | `abi.encode(fromBalance, toBalance)` | `fromBalance` is 0 on the enforcement mint, where `from` is zero. `toBalance` is 0 on the burner's burn, where `to` is zero. |
| MINT | `abi.encode(fromBalance, toBalance)` | `fromBalance` is 0. |
| BURN | `abi.encode(fromBalance, toBalance)` | `toBalance` is 0. |

A rule reads the balances from `data` and works out the balances after the move from `amount`, so on the movement path it makes no call back into the token for them. The calls the shipped rules do make to the token are views: `totalSupply` (`SupplyCapRule`, on a mint) and `policy` in `after_`. No rule reads the operator's roles.

<a id="own-checks"></a>
## The token's own checks

Two checks are mechanical and live in the token, not in a rule. Both run before the hook is asked.

### Pause

While the token is paused, every kind except FORCED gets the reason `PAUSED` from `_check`: transfers, intents, mints and holders' burns (vault redemptions). The FORCED movements pass: `forcedTransfer`, the burner's `burn`, and the 7540's `recoverRedeemRequest` and `recoverClaimable`. A vault call can stop before that with its own error, for example `ERC4626ExceededMaxDeposit` on a 4626 or `EnforcedPause` on a 7540 redemption claim; [What a rejection looks like](#rejections) lists them. The guardian pauses with no delay (`GUARDIAN_ROLE`). `unpause` takes `DEFAULT_ADMIN_ROLE` (the main timelock) or `RECOVERY_ROLE` (the recovery timelock).

### What the sender can move

The agent can hold back part of any balance with `setFrozenTokens(account, amount)`, except the 7540 vault's own address (`GatedVault_Unsupported`). The frozen amount may be larger than the balance. A holder can move only the unfrozen balance, `balance - frozen`, or nothing when the frozen amount is the larger. A FORCED move, the burner's `burn` included, may take the whole balance, frozen tokens included, but no more than that.

| Case | The write reverts with |
|---|---|
| Amount within the balance but above what the sender can move | `ERC7943InsufficientUnfrozenBalance(account, amount, unfrozen)`, the ERC-7943 error |
| Amount above the whole balance, frozen or not | `ERC20InsufficientBalance(sender, balance, needed)`, the ERC-20 error |
| `forcedTransfer` or the burner's `burn` above the whole balance | `ERC20InsufficientBalance`, from `_releaseFrozen`, before `_move` runs |

**Taking frozen tokens.** `forcedTransfer` and the burner's `burn` first call `_releaseFrozen`, which lowers the frozen amount by exactly the part of the amount that the unfrozen balance does not cover, and emits `Frozen` before the `Transfer`. Example: a balance of 100 with 30 frozen. The holder can send 70. Sending 80 reverts with `ERC7943InsufficientUnfrozenBalance` (amount 80, unfrozen 70), and sending 120 with `ERC20InsufficientBalance` (balance 100, needed 120). A forced transfer of 80 takes the 70 unfrozen tokens and 10 frozen ones, and the frozen amount drops to 20. A 4626 `redeem` stops at the unfrozen balance, because `maxRedeem` does.

This frozen amount is the token's own. The address freeze is a separate thing: `HolderRestrictionRule.setFrozen`, a rule's yes or no about an account, whatever the amount.

<a id="chain"></a>
## The rule chain

The hook, `ComplianceHook`, is shared by every token of a deployment. For each token it keeps an ordered list of rules, at most 16 (`MAX_RULES`). `checkTransfer` is a read-only call (`view`, made with `STATICCALL`), so neither the hook nor a rule can change anything while deciding. The token makes the call through `_ask`, which copies one word of the answer. A hook that reverts, runs out of gas, answers fewer than 32 bytes or has no code gives the reason `CHECK_UNAVAILABLE`, and the movement reverts with `ERC8473PolicyRejected(CHECK_UNAVAILABLE)`. The hook's own revert data is not passed on. This figure shows the list of the intent token in the `full` deployment profile.

> **Diagram.** The rule chain for the intent token in the full profile. The token calls checkTransfer. The hook reads the list kept for the token; an empty list returns NO_RULES. Then CredentialRule, MinPositionRule, HolderRestrictionRule, SettlementWindowRule and FundHoldersRule run in that order. Each either returns TRANSFER_OK and the next rule runs, or returns its own reason code, which the hook returns at once. SupplyCapRule and ExecutedOnlyRule run only where a product lists them. If all return TRANSFER_OK the hook returns TRANSFER_OK and the balances move.
>
> **The first rule to say no wins, and its reason is what the caller sees.** Red boxes list the codes each rule can return; the hook returns the first one at once and asks no further rule. So a sender who is both unverified and locked sees `SENDER_NOT_ELIGIBLE`, because `CredentialRule` runs first in this list.

| Product | Rule list, in order | Where it is stated |
|---|---|---|
| `IntentToken` in the `full` profile | `CredentialRule`, `MinPositionRule`, `HolderRestrictionRule`, `SettlementWindowRule`, `FundHoldersRule` | `RULE_ORDER` in `ignition/modules/roles.ts` |
| `Gated4626Vault`, `Gated7540Vault` in the `full` profile | `CredentialRule`, `MinPositionRule`, `HolderRestrictionRule`, `FundHoldersRule` | `RULE_ORDER` |
| The products of every other profile | `CredentialRule`, `HolderRestrictionRule` | `PLAIN_RULES` in `ignition/profiles.ts` |
| A product that asks for them | `SupplyCapRule` and `ExecutedOnlyRule` can be added to a product's list. No shipped profile lists them; the tests in `test/nodejs/legos.test.ts` do. | The product's `rules` |

Each token passes its list to its initialiser, which installs the hook with the list as the installation's data. The hook's `onInstall` installs the list, and `ProxyDeployer` refuses to finish unless the hook holds exactly that list. Later, the token's `DEFAULT_ADMIN_ROLE` holder (the main timelock) can replace a list with `setRules`, or with a list as the data of `installPolicy(newPolicy, data)`, using rules attested as `RULE` and no two with the same `ruleId`. The token's own code does not call `setRules`. The hook accepts any attested list. What stops a poor combination is `assertUsable` in `ignition/profiles.ts`, off-chain when a module is built: it refuses `SupplyCapRule` on a vault, `SettlementWindowRule` or `ExecutedOnlyRule` on anything but an `IntentToken`, and `MinPositionRule`, `FundHoldersRule` or `SupplyCapRule` on a `Gated721`.

<a id="matrix"></a>
## What each check does, kind by kind

Each row is one check. The token's own checks come first, then the rules in the order of the `full` profile's lists, then the two rules a product adds on request. "Can leave" means the credential registry reads the sender as `ACTIVE`, `EXIT_ONLY` or `LAPSED`. "Eligible" means it reads the receiver as `ACTIVE` and the token's policy accepts the receiver's attester and qualifications.

| Check | TRANSFER | EXECUTED | FORCED | MINT | BURN |
|---|---|---|---|---|---|
| Token: pause | rejects | rejects | passes | rejects | rejects |
| Token: amount the sender can move | unfrozen balance | unfrozen balance | whole balance | no sender | unfrozen balance |
| `CredentialRule`, sender | can leave | can leave | not checked | no sender | can leave |
| `CredentialRule`, receiver | eligible | eligible | eligible | eligible | no receiver |
| `MinPositionRule` | both sides | both sides | not checked | receiver | sender |
| `HolderRestrictionRule`, sender | not frozen, not locked | not frozen, not locked | not checked | no sender | not frozen, not locked |
| `HolderRestrictionRule`, receiver | not frozen | not frozen | not frozen | not frozen | no receiver |
| `SettlementWindowRule` | not checked | window open | not checked | not checked | not checked |
| `FundHoldersRule`, class | registered | registered | registered | registered | registered |
| `FundHoldersRule`, cap | caps a new investor | caps a new investor | not capped | caps a new investor | not capped |
| `SupplyCapRule` | not checked | not checked | not checked | within the cap | not checked |
| `ExecutedOnlyRule` | rejects | passes | passes | passes | passes |

The FORCED column also covers the enforcement mint of `recoverClaimable`, where there is no sender and `SupplyCapRule` does not apply, as the kind is not MINT. It also covers the burner's `burn`, where there is no receiver, so the two receiver rows do not apply to it. The BURN column is a holder's own burn, whoever the operator is. "Registered" means the token is a registered class of the fund and the rule is the fund's installed one; otherwise every movement gets `NOT_FUND_CLASS`.

### [CredentialRule](contracts/CredentialRule.md)

Asks `CredentialRegistry.profileOf` about each party. Sender first, on a transfer, an intent or a holder's burn: an address that reads `NONE` or `BLOCKED` gets `SENDER_NOT_ELIGIBLE`. A FORCED move, the burner's `burn` included, does not judge the sender. Then the receiver, when there is one: no policy for the token gives `RECEIVER_NOT_ELIGIBLE`, a lapsed credential `CREDENTIAL_EXPIRED`, any other standing but `ACTIVE` gives `RECEIVER_NOT_VERIFIED`, and an active credential the policy does not accept gives `RECEIVER_NOT_ELIGIBLE`. A holder whose credential lapsed can still send and redeem, and cannot receive. The token's own address is not judged on either side. The token's `DEFAULT_ADMIN_ROLE` sets the policy with `setPolicy`.

### [MinPositionRule](contracts/MinPositionRule.md)

Passes when the token's minimum is 0, the amount is 0, the sender is the receiver, or the kind is FORCED, the burner's `burn` included. Otherwise `BELOW_MIN_POSITION` when the receiver would end below the minimum, or the sender would keep a remainder above zero and below it. Exempt: the token itself (the 7540 escrow) and accounts the token's admin lists with `setExempt`. The admin sets the minimum with `setMinPosition`.

### [HolderRestrictionRule](contracts/HolderRestrictionRule.md)

For every kind but FORCED, a frozen sender gets `SENDER_FROZEN`, then a locked one gets `LOCKED_UP`: on a transfer, an intent or a holder's burn. A frozen receiver gets `RECEIVER_FROZEN` in every kind with a receiver, forced moves and mints included. The ways out of a frozen address are the burner's `burn` and a forced transfer to an unfrozen quarantine account. The token's `AGENT_ROLE` sets both with `setLockup` and `setFrozen`.

### [SettlementWindowRule](contracts/SettlementWindowRule.md)

Judges EXECUTED only. Outside the token's daily UTC window, or on a weekday the window does not include, it returns `WINDOW_CLOSED`. An overnight window belongs to the day it opened. The token's `DEFAULT_ADMIN_ROLE` sets it with `setWindow`.

### [FundHoldersRule](contracts/FundHoldersRule.md)

Returns `NOT_FUND_CLASS` for every movement of a token that is not a registered class of its fund, or when it is not the fund's installed rule. Otherwise a new investor (a receiver that holds no class of the fund, is not exempt and is not the class itself) passes while the count is below the cap, or at the cap when the sender empties its only class. Anything else gets `MAX_HOLDERS`. Zero amounts, burns, forced moves and receivers who already hold a class are not capped. The fund's owner sets the cap with `setHolderCap`.

### [SupplyCapRule](contracts/SupplyCapRule.md)

Judges MINT only. A mint that would take `totalSupply` above the token's cap gets `ABOVE_SUPPLY_CAP`, so a stolen minter key stops at the cap. The agent's enforcement mint has the kind FORCED and is not judged. The token's `DEFAULT_ADMIN_ROLE` sets the cap with `setSupplyCap`.

### [ExecutedOnlyRule](contracts/ExecutedOnlyRule.md)

Refuses TRANSFER with `KIND_NOT_ALLOWED`, so that every movement between holders is a signed intent with its `ref`, run by an executor. Mints, burns, forced moves and executed intents pass. It has no settings and no account-level answer.

### When a setting is missing

| Missing setting | Effect |
|---|---|
| The token has no rule list on the hook | Every movement, forced ones included, gets `NO_RULES` |
| `CredentialRule`: the token has no policy | Every receiver but the token itself gets `RECEIVER_NOT_ELIGIBLE`, in forced moves too. Burns, which have no receiver, can still pass |
| `MinPositionRule`: minimum 0 | The rule passes every movement |
| `HolderRestrictionRule`: nothing set | Nobody is frozen or locked |
| `SettlementWindowRule`: no window | Every executed intent gets `WINDOW_CLOSED`; other kinds are not affected |
| `FundHoldersRule`: the token is not a registered class | Every movement, forced ones included, gets `NOT_FUND_CLASS` |
| `FundHoldersRule`: cap 0 | A new investor gets `MAX_HOLDERS`. Forced moves, exempt receivers and existing investors still pass |
| `SupplyCapRule`: no cap set | A mint of any amount above zero gets `ABOVE_SUPPLY_CAP`; other kinds are not affected |

<a id="after"></a>
## After the balances move

Once the balances have moved and `Transfer` is emitted, the token asks the hook `wantsAfterTransfer()`. `ComplianceHook` answers yes to every caller: the function takes no token, so a shared hook cannot answer for one of them. Then the token calls `afterTransfer(ctx)`, which the hook accepts only from the token named in the context (`ComplianceHook_OnlyToken`). The hook returns at once when no rule in that token's list asked for `after_` when the list was installed. Otherwise it calls `after_` on the rules that did. Each rule accepts it only from the hook that token has installed at that moment (`ComplianceRule_OnlyHook`).

`FundHoldersRule` is the one shipped rule with an `after_`. It runs for every kind. It does nothing for a zero amount or a move to oneself. Otherwise it calls `Fund.leave(token, from)` when the move takes the sender's whole balance, and then `Fund.join(token, to)` when the receiver held none of this class before the move. The fund keeps the investor count; it does not record the class token itself.

This step can write state, so it runs while the token's reentrancy guard is still held: a rule that calls back into a function that moves balances reverts with `ReentrancyGuardReentrantCall`. If `after_` reverts, the whole movement reverts.

On `forcedTransfer` and `executeTransfer` the entry point's events come after `_move` returns: `ForcedTransfer` and `ForcedTransferBy`, and `IntentExecuted`. `Gated7540Vault` emits its own first: `RedeemRequest`, `RedeemRequestRejected`, `RedeemRequestRecovered`, `ClaimableRecovered`, `PeriodSettled` and a claim's `Deposit` come before the `Transfer`.

<a id="preflight"></a>
## Asking first: the pre-flights

`canTransferWithReason`, `canTransfer` and `canExecute` run the same `_check` as the write, without writing, so a wallet or an integrator can learn the answer before sending. `canSend` and `canReceive` ask the hook's account questions instead. None of them reverts when the hook cannot be asked: `canTransfer`, `canSend` and `canReceive` return false, and `canTransferWithReason` says `CHECK_UNAVAILABLE`. They answer for the block they read; a transaction mined later sees a later time, which matters at a lockup end, a window edge or an intent deadline.

| Function | What it asks | Operator it assumes |
|---|---|---|
| `canTransferWithReason(from, to, amount)` | Would a holder-driven movement pass, and if not, why. Returns `(ok, reason)`. The kind is MINT when `from` is zero, BURN when `to` is zero, otherwise TRANSFER | `from`, which is the zero address for a mint, so the answer does not depend on who asks |
| `canTransfer(from, to, amount)` | The ERC-7943 bool: the same question, with one difference below | the same |
| `canExecute(intent, sig, executor)` | Would `executeTransfer` pass if `executor` called it: its role, the intent checks, the signature, then the EXECUTED path. Returns `(ok, reason)` | `executor`, so the answer does not depend on who asks |
| `canSend(account)` | May the account send at all: the hook's `checkSend` over the token's rules. True for the zero address, without asking the hook, even while paused. For any other account, false while paused and with no hook | none: no amount, no counterparty |
| `canReceive(account)` | May the account receive at all: the hook's `checkReceive`. True for the zero address, without asking the hook, even while paused. For any other account, false while paused and with no hook | none |

### Where they differ from the write

- **`canTransfer` does not fail on a plain balance shortfall.** ERC-7943 forbids it. With nothing frozen on the sender, an amount above the balance reads true when the hook accepts it, while `canTransferWithReason` says `INSUFFICIENT_UNFROZEN` and the write reverts with `ERC20InsufficientBalance`. Once part of the balance is frozen, an amount above the unfrozen balance reads false in both. To learn whether a movement will succeed, call `canTransferWithReason` or `canExecute`.
- **They model a holder-driven movement.** `canTransfer` and `canTransferWithReason` cannot ask about FORCED or EXECUTED. So on a token that lists `ExecutedOnlyRule` they say no with `KIND_NOT_ALLOWED`, and only `canExecute` can say yes. A burn is asked as the holder's own burn, so frozen tokens, the lockup and the address freeze count, whoever the holder is and whoever asks. No pre-flight predicts `burn` or `forcedTransfer`. On `Gated721`, which has no holder burn, a burn pre-flight gives the answer a holder's burn would get, while `burn` itself takes a frozen item.
- **`canExecute` says `NOT_EXECUTOR` first** when the named account lacks `EXECUTOR_ROLE`, where the write reverts with `AccessControlUnauthorizedAccount`. It does not see what an executor contract refuses for itself, such as `IntentExecutor_ConsiderationNotSupported`.
- **The account questions leave out amounts and counts.** `canSend` and `canReceive` do not see the minimum position, the supply cap or the fund's investor cap: a new investor at a full fund reads true in `canReceive`, and the movement is refused with `MAX_HOLDERS`. They also cannot see the kinds a rule exempts: `canSend` is false for a locked holder although a forced transfer from it still passes.
- **None of them runs `afterTransfer`.**

The vaults' `maxDeposit` and `maxMint` pre-flight a mint of `type(uint128).max` shares (`_mintProbe`), large enough that a minimum position up to that size does not read as a block and not zero, so the fund's cap sees a new investor. `maxRedeem` and `maxWithdraw` pre-flight a burn of nothing from the owner. On `Gated7540Vault` the same probes run on the controller, and also guard `requestDeposit` and the claims. [Where the money sits](money.md) and the vault pages follow those flows.

<a id="reasons"></a>
## Every reason code

Each code is the `keccak256` hash of its name, so `TRANSFER_OK` is not zero and a rule that forgets to set its answer rejects. The list in `contracts/interfaces/Errors.sol` is append-only, and `InterfaceFreeze.t.sol` pins each value. Codes are grouped here by where they come from.

| Code | Returned by | Means |
|---|---|---|
| `TRANSFER_OK` | every rule, `ComplianceHook`, the intent checks, the pre-flights | Allowed |
| `PAUSED` | `_check` in the base; `canExecuteDvPGated` and `canExecuteDvP3009` while the executor is paused | Paused, and the kind is not FORCED |
| `INSUFFICIENT_UNFROZEN` | `_check`; `canExecuteDvP3009` for the buyer's cash balance | The sender cannot move that much. The token's write reverts with a balance error instead |
| `NO_HOOK` | `_check` | No hook installed. An initialised token has one, so in practice a bare implementation answers this |
| `CHECK_UNAVAILABLE` | `_ask` in the core, for `checkTransfer`, `checkSend` and `checkReceive` | The hook could not be asked: it reverted, ran out of gas, answered fewer than 32 bytes or has no code |
| `NO_RULES` | `ComplianceHook`: `checkTransfer`, `checkSend`, `checkReceive` | The token's rule list is empty |
| `SENDER_NOT_ELIGIBLE` | `CredentialRule`: `check`, `checkSend` | The sender has no credential, or is blocked |
| `RECEIVER_NOT_VERIFIED` | `CredentialRule`: `check`, `checkReceive` | The receiver's standing is neither `ACTIVE` nor `LAPSED` |
| `CREDENTIAL_EXPIRED` | `CredentialRule`: `check`, `checkReceive` | The receiver's credential has lapsed |
| `RECEIVER_NOT_ELIGIBLE` | `CredentialRule`: `check`, `checkReceive` | The token's policy does not accept the receiver, or the token has no policy |
| `BELOW_MIN_POSITION` | `MinPositionRule`: `check` | An account would end above zero and below the minimum |
| `SENDER_FROZEN` | `HolderRestrictionRule`: `check`, `checkSend` | The sender's address is frozen on this token |
| `LOCKED_UP` | `HolderRestrictionRule`: `check`, `checkSend` | The sender's lockup is still running |
| `RECEIVER_FROZEN` | `HolderRestrictionRule`: `check`, `checkReceive` | The receiver's address is frozen on this token |
| `WINDOW_CLOSED` | `SettlementWindowRule`: `check` | An executed intent outside the window |
| `NOT_FUND_CLASS` | `FundHoldersRule`: `check`, `checkSend`, `checkReceive` | The token is not a registered class, or the rule is not the fund's installed one |
| `MAX_HOLDERS` | `FundHoldersRule`: `check` | A new investor would pass the fund's cap |
| `ABOVE_SUPPLY_CAP` | `SupplyCapRule`: `check` | A mint would take the supply above the token's cap |
| `KIND_NOT_ALLOWED` | `ExecutedOnlyRule`: `check` | A plain transfer on a token whose movements must be signed intents |
| `NOT_EXECUTOR` | `canExecute` | The named account does not hold `EXECUTOR_ROLE`. Pre-flight only: the write has its role check |
| `INTENT_EXPIRED` | `executeTransfer`, `canExecute`; `canExecuteDvP3009` for the authorization | Past the deadline |
| `NONCE_USED` | `executeTransfer`, `canExecute`, `cancelIntent`; `canExecuteDvP3009` for the authorization | The nonce was used or cancelled |
| `CONSIDERATION_NEEDS_EXECUTOR` | `executeTransfer`, `canExecute` | The intent states a payment but names no executor to enforce it |
| `WRONG_EXECUTOR` | `executeTransfer`, `canExecute` | The intent names another executor |
| `INTENT_NOT_YET_VALID` | `executeTransfer`, `canExecute`; `canExecuteDvP3009` for the authorization | Before `validAfter` |
| `ZERO_RECEIVER` | `executeTransfer`, `canExecute`; `canTransferWithReason`, where `canTransfer` reads false | The intent pays the zero address; a pre-flight asks about a mint to it |
| `NOT_TOKEN_OWNER` | `Gated721.canTransferWithReason` | `from` does not own the item; for a mint, the item already exists. `canTransfer` leaves ownership to ERC-721, and the write reverts with ERC-721's own error |
| `BAD_SIGNATURE` | `executeTransfer`, `canExecute` | The signature is not the sender's over this intent, token and chain |
| `LEGS_DO_NOT_MATCH` | `canExecuteDvPGated`, `canExecuteDvP3009` | The two legs do not describe one trade. The write reverts with `DvPExecutor_LegsDoNotMatch` instead |

The intent checks run in this order, in `executeTransfer` and `canExecute`: deadline, nonce, consideration, executor, `validAfter`, zero receiver, signature, then the movement path. ERC-7943 also declares `ERC7943CannotSend`, `ERC7943CannotReceive` and `ERC7943CannotTransfer`; the token does not revert with them, because a policy rejection carries its reason in `ERC8473PolicyRejected`.

<a id="rejections"></a>
## What a rejection looks like

A rejected movement reverts; `transfer` does not return `false`. These are the errors a caller sees most, for a holder with 100 tokens, 30 of them frozen, sending to Bob, whose credential has lapsed, and to Carol, who is eligible:

```
transfer(bob, 10)     reverts ERC8473PolicyRejected(keccak256('CREDENTIAL_EXPIRED'))
transfer(carol, 80)   reverts ERC7943InsufficientUnfrozenBalance(holder, 80, 70)
transfer(carol, 120)  reverts ERC20InsufficientBalance(holder, 100, 120)
```

Some entry points check things of their own before the movement path, so the error depends on where the call stops. Read each row left to right, in the order the call meets the checks.

| Entry point | Stops before the movement with | The movement path rejects with |
|---|---|---|
| `transfer`, `transferFrom` | `transferFrom` spends the allowance first: `ERC20InsufficientAllowance`. A zero address: `ERC20InvalidSender`, `ERC20InvalidReceiver` | `ERC8473PolicyRejected(reason)`, `ERC7943InsufficientUnfrozenBalance` or `ERC20InsufficientBalance` |
| `mint` on a token | `AccessControlUnauthorizedAccount` without `MINTER_ROLE`. A zero receiver: `ERC20InvalidReceiver` | `ERC8473PolicyRejected(reason)`, for example a receiver without an eligible credential, or `ABOVE_SUPPLY_CAP` |
| `burn` on a token | Without `BURNER_ROLE`: `AccessControlUnauthorizedAccount`. Above the balance: `ERC20InsufficientBalance` | `ERC8473PolicyRejected(reason)`, for example `NOT_FUND_CLASS` or `NO_RULES`. It does not see `PAUSED`, `SENDER_FROZEN` or `LOCKED_UP` |
| `mint`, `burn` of an address and an amount, on a vault | `GatedVault_Unsupported` | Moves nothing |
| `forcedTransfer` | Without `AGENT_ROLE`: `AccessControlUnauthorizedAccount`. On the 7540 vault, out of its own address beyond the shares not booked to a pending redemption: `Gated7540Vault_ExceedsSurplus`. Above the balance: `ERC20InsufficientBalance`. A zero address: `ERC20InvalidSender`, `ERC20InvalidReceiver` | `ERC8473PolicyRejected(reason)`, for example the receiver's credential, `RECEIVER_FROZEN` or `NOT_FUND_CLASS`. It does not see `PAUSED` |
| `executeTransfer` | Without `EXECUTOR_ROLE`: `AccessControlUnauthorizedAccount`. The intent checks and the signature: `ERC8473PolicyRejected` with `INTENT_EXPIRED`, `NONCE_USED`, `CONSIDERATION_NEEDS_EXECUTOR`, `WRONG_EXECUTOR`, `INTENT_NOT_YET_VALID`, `ZERO_RECEIVER` or `BAD_SIGNATURE` | As `transfer` |
| `cancelIntent` | A nonce already used or cancelled: `ERC8473PolicyRejected(NONCE_USED)` | Moves nothing |
| `IntentExecutor.execute` | Without `OPERATOR_ROLE`: `AccessControlUnauthorizedAccount`. While paused: `EnforcedPause`. An intent that states a payment: `IntentExecutor_ConsiderationNotSupported(0)` | The token's revert, unchanged |
| `IntentExecutor.executeBatch` | As `execute`, plus `IntentExecutor_LengthMismatch` and `IntentExecutor_ConsiderationNotSupported(index)` | `IntentExecutor_BatchItemFailed(index, reason)`, with the token's revert data. The whole batch is undone |
| `DvPExecutor.executeDvPGated`, `executeDvP3009` | Without `OPERATOR_ROLE`, or while paused. Legs that do not mirror: `DvPExecutor_LegsDoNotMatch` | `DvPExecutor_LegFailed(leg, reason)`, `leg` being `CASH` or `SECURITIES`. In the ERC-3009 form a cash balance that does not add up gives `DvPExecutor_CashNotConserved`, and a failing payout to the seller is not wrapped |
| `Gated4626Vault.deposit`, `mint` | `ERC4626ExceededMaxDeposit` or `ERC4626ExceededMaxMint` when the max is 0: paused, credential, freeze, a full fund, no price from the portfolio, or exit-only. A payer the policy refuses: `GatedVault_ThirdPartyNotEligible(account, reason)` | `ERC8473PolicyRejected(reason)`, for example `BELOW_MIN_POSITION`, or any reason for a zero amount, which passes the max check |
| `Gated4626Vault.withdraw`, `redeem` | `ERC4626ExceededMaxWithdraw` or `ERC4626ExceededMaxRedeem`: the max is the unfrozen balance, limited by what a portfolio can raise, and 0 when the burn probe fails (paused, credential, freeze, lockup) or there is no price. A receiver the policy refuses: `GatedVault_ThirdPartyNotEligible`. Without an allowance: `ERC20InsufficientAllowance` | `ERC8473PolicyRejected(reason)`, for example `BELOW_MIN_POSITION` for a remainder |
| `Gated7540Vault.requestDeposit` | `Gated7540Vault_ZeroAmount`, `Gated7540Vault_ZeroAddress`, `Gated7540Vault_Unauthorized`, then `Gated7540Vault_ControllerNotEligible(reason)` from the mint probe on the controller, `PAUSED` included, `GatedVault_ThirdPartyNotEligible`, `Gated7540Vault_EarlierRequestUnsettled` | Moves no shares |
| `Gated7540Vault.requestRedeem` | `Gated7540Vault_ZeroAmount`, `Gated7540Vault_ZeroAddress`; a caller that is not the owner or its operator spends an allowance; `GatedVault_ThirdPartyNotEligible`, `Gated7540Vault_EarlierRequestUnsettled` | The move into escrow is a TRANSFER: `ERC8473PolicyRejected(reason)` or a balance error |
| `Gated7540Vault.settlePeriod` | Without `SETTLER_ROLE`: `AccessControlUnauthorizedAccount`. While paused: `EnforcedPause`. No closed period: `Gated7540Vault_NoClosedPeriod` | The burn of the shares it takes: `ERC8473PolicyRejected(reason)`. After it, `Gated7540Vault_BalanceAudit(held, owed)` |
| `Gated7540Vault.deposit`, `mint` (claims) | `Gated7540Vault_Unauthorized`, `Gated7540Vault_ControllerNotEligible(reason)` (`PAUSED` included), `Gated7540Vault_ZeroAmount`, `Gated7540Vault_ExceedsClaimable` | The mint to the receiver: `ERC8473PolicyRejected(reason)`, for example `BELOW_MIN_POSITION`; the claimable amount stays |
| `Gated7540Vault.redeem`, `withdraw` (claims) | `EnforcedPause` first, then `Gated7540Vault_Unauthorized`, `Gated7540Vault_ControllerNotEligible(reason)` from the burn probe, `GatedVault_ThirdPartyNotEligible`, `Gated7540Vault_ZeroAmount`, `Gated7540Vault_ExceedsClaimable` | Moves no shares: they were burned at settlement |
| `Gated7540Vault.rejectDepositRequest`, `rejectRedeemRequest` | `Gated7540Vault_NothingPending`, then `AccessControlUnauthorizedAccount` without `AGENT_ROLE` while the period is open, or without `SETTLER_ROLE` once it has closed | `rejectDepositRequest` moves no shares. `rejectRedeemRequest` is a TRANSFER back to the controller: `ERC8473PolicyRejected(reason)` |
| `Gated7540Vault.recoverRedeemRequest` | `Gated7540Vault_ZeroAddress`, then as `rejectRedeemRequest` | A FORCED move: `ERC8473PolicyRejected(reason)` for the receiver |
| `Gated7540Vault.recoverClaimable` | Without `AGENT_ROLE`; `Gated7540Vault_ZeroAddress`; a recipient the policy refuses: `Gated7540Vault_RecipientNotEligible(reason)`; `Gated7540Vault_NothingClaimable` | A FORCED mint: `ERC8473PolicyRejected(reason)` for the receiver |

<a id="why"></a>
## Why it is built this way

- **One path.** Every entry point ends in `_move`, so an entry point cannot skip a check, and the hook sees mints and burns as movements from and to the zero address.
- **The base holds no policy.** Pause and the frozen amount are mechanics every token needs. Everything about who, when and how much is a rule, so it can change without an upgrade.
- **One check for the write and the pre-flights.** `_check` and `_context` serve both, so a pre-flight sees what the write would, apart from the differences listed above.
- **Typed errors, not a silent false.** A rejection reverts and carries its reason, and a balance problem carries the standard error that names the cause.
- **Rules answer, they do not revert.** `check` is read-only and returns a code, so a pre-flight can report the reason instead of failing. A rule must not revert for an amount above the balance either, because `canTransfer` offers it one.
- **The balances travel with the context.** A rule that needs them does not call back into a token that is in the middle of a movement.

<a id="limits"></a>
## What this path does not do

- **It does not see a vault's asset.** The hook judges the token whose balance moves. A vault's asset is an ordinary ERC-20 transfer, outside this path unless the asset is itself a gated token, which then runs its own. See [Where the money sits](money.md).
- **It does not hold a rule in place.** The hook accepts any attested list, so a timelock change that drops `FundHoldersRule` from a class's list stops that class counting investors and enforcing the cap. `Fund.isClassIntact` and `Fund.firstBrokenClass` report it; they do not prevent it.
- **It does not re-check attestations.** Attestation is checked at install and upgrade. Revoking one leaves a running rule running until the timelock removes it, and the guardian can pause meanwhile.
- **It does not read the operator's roles.** Only `burn` itself is an enforcement burn. A `BURNER_ROLE` holder that redeems its own shares through a vault is judged like any holder: its lockup, minimum, freeze and frozen tokens apply.
- **A minimum does not stop every small move.** `MinPositionRule` does not stop 1 wei being sent to a holder already at or above the minimum, and FORCED moves, the burner's `burn` among them, can leave a remainder below it.
- **A pre-flight is not a promise.** It reads one block. A later block can have another time, another balance or another rule list.

<a id="connected"></a>
## Connected to

- [PolicyGatedERC20Upgradeable](contracts/PolicyGatedERC20Upgradeable.md): Where `_move`, the pause and the frozen amounts live.
- [ComplianceHook](contracts/ComplianceHook.md): The dispatcher that runs each token's rule list.
- [IntentSettledUpgradeable](contracts/IntentSettledUpgradeable.md): The intent checks in front of EXECUTED.
- [Fund](contracts/Fund.md): The investor count that `after_` keeps up to date.
- [Who can do what](roles.md): The roles behind each entry point.
- [Where the money sits](money.md): The vault flows step by step.

<a id="source"></a>
## Source and tests

- The path: `PolicyGatedERC20Upgradeable.sol` (`_move`, `_check`, `_context`, `_releaseFrozen`), `ComplianceHook.sol`, the rules in `contracts/hooks/rules/`, the intent checks in `IntentSettledUpgradeable.sol`
- Reason codes: `contracts/interfaces/Errors.sol`; the context: `IERC8473Policy.sol`; the rule lists: `ignition/modules/roles.ts` and `ignition/profiles.ts`
- Tests: `PolicyGatedERC20Upgradeable.t.sol` (pause, frozen amounts, kinds), `ComplianceHook.t.sol` (order, first rejection, empty list), `RuleSetIntegration.t.sol` (pre-flight against write through a rule set), one `.t.sol` next to each rule, `IntentToken.t.sol` (a rule that re-enters, for example `test_WhenARuleReentersTheToken_TheTransferReverts`), `test/nodejs/parity.test.ts` and `time.test.ts` (pre-flights from TypeScript, time boundaries)

---

Describes the contracts at commit `18e60b3` on `paris`.
