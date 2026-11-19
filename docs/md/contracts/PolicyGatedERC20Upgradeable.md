[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Token

# PolicyGatedERC20Upgradeable

The base every fungible token in the stack is built on. It keeps the balances and the enforcement tools, takes its roles, pause and hook pointer from the shared core, and sends every balance movement through one internal function that asks the policy hook before anything moves.

- **contracts/base/PolicyGatedERC20Upgradeable.sol**
- abstract: **runs inside each token**, behind its proxy
- admin: **the main timelock** on each token, after hand-over
- attested as part of **each template implementation**

<a id="in-one-minute"></a>

> ### In one minute
>
> `GatedToken`, `IntentToken` and both vaults share this code. It extends [`PolicyGatedCoreUpgradeable`](PolicyGatedCoreUpgradeable.md), which holds the roles, the guardian and recovery, the pause, the hook pointer and the upgrade checks, and which the NFT template, [`Gated721`](Gated721.md), and the multi-token template, [`Gated1155`](Gated1155.md), share too. This page describes them as they apply to a fungible token. It does the bookkeeping of an ordinary ERC-20 token, plus what a regulated issuer needs: create and destroy tokens, move tokens without the holder's consent (a forced transfer), freeze part of a holder's balance, and pause the token in an emergency.
>
> It does not decide who may hold the token, where or when. For every movement it asks a separate contract, the **policy hook**, which runs a list of small checks called **rules** (identity, lockups, settlement hours, a fund's investor cap). The hook and its rules can be changed through governance without touching the token. Changing this base takes an upgrade to code the security council has reviewed and recorded in the registry (code that is **attested**).

<a id="how"></a>
## How every movement is decided

A transfer, a mint, a burn, a forced transfer and a signed intent all end in one internal function, `_move`. OpenZeppelin's ERC-20 code reaches it through `_update`, and the enforcement routes reach it through `_moveAs` and `_mintAs`. Each movement carries one of five **kinds**. `_move` builds a description of the movement for the hook (the **context**), runs the token's own mechanical checks, asks the hook, and only then moves the balances.

> **Diagram.** The movement path. Five kinds of movement feed it. TRANSFER from transfer and transferFrom, MINT from mint, and BURN from a vault's redemption or a 7540 settlement go through OpenZeppelin's internal functions into \_update, which infers the kind from the zero addresses. FORCED from forcedTransfer, burn and the 7540 recoveries, and EXECUTED from executeTransfer, are announced as an argument: through \_moveAs or \_mintAs, or by burn itself. All of them reach \_move, where a second entry while it runs reverts. Inside \_move the token builds the context, with the caller as operator and both balances before the move in data, and reads the hook address once. If the token is paused and the kind is not FORCED it reverts with ERC8473PolicyRejected(PAUSED). If the amount is above what the sender can move it reverts with ERC7943InsufficientUnfrozenBalance or ERC20InsufficientBalance. If the hook's checkTransfer does not return TRANSFER_OK it reverts with ERC8473PolicyRejected and the reason. Otherwise the balances move, Transfer is emitted, and the hook's afterTransfer runs if the hook wants it.
>
> **One path for every movement.** Red boxes are reverts. A revert undoes the whole call, including a frozen amount that `forcedTransfer` or `burn` lowered just before. The pre-flight answers build their context with the same function, run steps 3 to 5, and stop there.

1. **The route and the kind.** `transfer`, `transferFrom` and `mint` use OpenZeppelin's `_transfer` and `_mint`, and a vault's redemption and the 7540 vault's settlement use its `_burn`. All three call `_update`. The base overrides `_update` to call `_move` with a kind worked out from the addresses: `from` zero is MINT, `to` zero is BURN, a holder's own burn, anything else is TRANSFER. A kind the addresses cannot show is announced. `forcedTransfer` and `executeTransfer` call `_moveAs`, which passes the kind, and for an intent its `ref` and `deadline`, as arguments, and refuses a zero `from` or `to` (`ERC20InvalidSender`, `ERC20InvalidReceiver`). A forced transfer within the balance can reach that refusal, with a zero receiver, or with a zero `from` and a zero amount. An intent with a zero `to` or `from` is stopped before it, by `ZERO_RECEIVER` or `BAD_SIGNATURE`. `_mintAs(to, amount, kind)` passes the kind for a mint and refuses a zero `to`: the 7540 vault's `recoverClaimable` uses it for an enforcement mint, FORCED with a zero `from`. `burn` is the burner's enforcement action, not a holder's burn: it refuses a zero `from` (`ERC20InvalidSender`) and passes FORCED with a zero `to` to `_move` itself (`test_WhenTheBurnerBurns_ThePolicySeesAForcedMovementToZero`). Nothing is stored between calls, so each movement in a transaction gets its kind from its own route. `_update` does not see forced or executed movements, so a template that had to act on every movement would extend `_move`.
2. **Enforcement releases first.** `forcedTransfer` and `burn` call `_releaseFrozen` before the path starts. It reverts with `ERC20InsufficientBalance` for an amount above the balance, so for these two functions that error comes before the pause or the hook is asked. See [Frozen amounts](#frozen).
3. **The context.** The token builds it, and no caller can supply one. See [What the hook is told](#context).
4. **The hook is read once** into a local variable. The hook that approves a movement is the hook that sees its `afterTransfer`.
5. **Pause.** While the token is paused, every kind except FORCED is refused, mints and holders' burns included. The burner's `burn` is FORCED, so it passes (`test_WhenTheBurnerBurnsWhilePaused_ItPasses`).
6. **The unfrozen bound.** The amount must fit in what `from` can move: the unfrozen balance, or the whole balance for a FORCED movement: a forced transfer, the burner's `burn`, or the 7540 vault's `recoverRedeemRequest`. A mint has no sender, so this step does not apply to it. The write names the cause: an amount within the balance but above the unfrozen part reverts with `ERC7943InsufficientUnfrozenBalance(account, amount, unfrozen)`, and an amount above the balance with `ERC20InsufficientBalance(sender, balance, needed)`. A hook that returns the code `INSUFFICIENT_UNFROZEN` with no shortfall behind it is a policy rejection like any other (`test_WhenTheHookItselfReturnsInsufficientUnfrozen_ItIsAPolicyRejection`).
7. **The hook decides.** `checkTransfer(ctx)` is a read-only call that returns `TRANSFER_OK` or a reason code. Anything else reverts with `ERC8473PolicyRejected(reason)`. The call goes through the core's `_ask`: a hook that reverts, runs out of gas, answers fewer than 32 bytes or has no code gives the reason `CHECK_UNAVAILABLE`, and the hook's own revert data is not passed on. A token with no hook would answer `NO_HOOK`, but the initialiser and `installPolicy` both refuse a zero hook, so no function of the base leaves a token in that state.
8. **The balances move** with OpenZeppelin's ERC-20 logic, which emits `Transfer`.
9. **After the move.** If the hook's `wantsAfterTransfer()` is true, `afterTransfer(ctx)` runs with the same context; the fund rule uses it to keep the investor count. The shared hook always answers true, and its `afterTransfer` returns at once for a token none of whose rules wants it. It is still inside the reentrancy guard, so a hook or rule that tries to start another movement on the token reverts with `ReentrancyGuardReentrantCall` (`test_WhenARuleReentersTheToken_TheTransferReverts`).

<a id="context"></a>
## What the hook is told

Every movement reaches the hook as a `TransferContext`. The pre-flight answers build it with the same function (`_context`), so a rule sees the same shape of data whether the token is asking or moving.

| Field | Value |
|---|---|
| `token` | The token's own address. A shared hook keeps a separate rule list for each token. |
| `from`, `to` | Sender and receiver. `from` is zero on a mint, `to` is zero on a burn. |
| `tokenId` | 0 on these fungible tokens. |
| `amount` | The amount moved. |
| `operator` | The account that called the token. A pre-flight has no such call, so it says who it is simulating, as described [below](#preflight). |
| `kind` | TRANSFER EXECUTED FORCED MINT BURN |
| `data` | The balances of both sides before the move, and for an executed intent its reference and deadline. The next table gives it for each kind. |

| Kind | Comes from | `operator` | `data` |
|---|---|---|---|
| TRANSFER | `transfer`, `transferFrom`, the 7540 vault's `requestRedeem` and `rejectRedeemRequest` | The caller: the holder, the spender on `transferFrom`, or on the 7540 whoever requests or rejects | `abi.encode(fromBalance, toBalance)` |
| MINT | `mint`, a vault's deposit or claim | The caller: the minter, or whoever deposits or claims | `abi.encode(fromBalance, toBalance)`, with `fromBalance` 0 |
| BURN | A vault's redemption, the 7540 vault's settlement | The caller: whoever redeems or settles | `abi.encode(fromBalance, toBalance)`, with `toBalance` 0 |
| FORCED | `forcedTransfer`, `burn`, the 7540 vault's recoveries | The caller: the agent, the burner, or the role holder that may recover | `abi.encode(fromBalance, toBalance)`; on an enforcement mint `fromBalance` is 0, and on the burner's `burn` `toBalance` is 0 |
| EXECUTED | `executeTransfer` | The account that called `executeTransfer`: the executor, not the holder | `abi.encode(fromBalance, toBalance, ref, deadline)` |

A rule reads the balances with `abi.decode(ctx.data, (uint256, uint256))`, which ignores the two extra words of an executed intent, and works out the balances after the move from `amount`. So on the movement path no rule has to ask the token for a balance. None of the shipped rules reads `ref` or `deadline`. The context passed to `afterTransfer` is the same one the check saw, so its balances are those from before the move (`test_WhenTheHookWantsAfter_ItReceivesTheSameContext`).

<a id="frozen"></a>
## Frozen amounts

The agent can freeze an amount of a holder's tokens with `setFrozenTokens`. The token stores one number per account, not a list of specific tokens. The **unfrozen balance** is the balance minus the frozen amount, or zero when the frozen amount is the larger. Following ERC-7943, the frozen amount may be set above the balance, and on an account that holds nothing (`test_WhenAnAccountHoldsNothing_ItCanStillBeFrozen`). It changes in two ways: the agent sets it, or an enforcement action takes frozen tokens. A holder receiving or sending tokens leaves it as it is.

> **Diagram.** A worked example. Before: balance 30, frozen 25, so 5 are unfrozen and the holder can move up to 5. The agent forces a transfer of 20: the 5 unfrozen tokens go first, then 15 from the frozen part, and 10 frozen stay. After: balance 10, frozen 10, unfrozen 0, so the holder can move nothing.
>
> **Enforcement takes the unfrozen part first.** Shaded green is what the holder can move, grey is frozen, dashed is what the forced transfer takes. The token emits `Frozen(holder, 10)` before the `Transfer`, as ERC-7943 asks. The numbers are those of the unit test `test_WhenSomeOfTheAmountIsUnfrozen_OnlyTheRestIsReleased`.

- **Holders, spenders and executors** move at most the unfrozen balance, whatever the kind: a transfer, an executed intent, and a vault redemption (a holder's burn) alike. An account that holds `BURNER_ROLE` is bound the same way when it moves or redeems its own tokens: no check reads the operator's role.
- **Enforcement** (`forcedTransfer` and `burn`, both FORCED) can take up to the whole balance, and never more. Before moving, `burn` and `forcedTransfer` lower the frozen amount by the part of the amount the unfrozen balance does not cover. With a balance of 10 and a frozen amount of 100, forcing 10 leaves a frozen amount of 90 (`test_WhenFrozenExceedsTheBalance_ForcedTakesOnlyWhatMovesFromIt`). When the unfrozen balance covers the amount, the frozen amount stays as it is and no `Frozen` event is emitted (`test_WhenTheAmountIsWithinTheUnfrozenBalance_NothingIsReleased`).
- **Tokens received later** are covered by a frozen amount above the balance until the balance passes it, because the unfrozen balance is worked out at each movement.
- **An address freeze is a different tool.** This is a freeze of an amount on one token, kept in the token. Blocking an address from sending or receiving at all is a setting of [`HolderRestrictionRule`](HolderRestrictionRule.md), in the hook. A frozen amount does not stop an account receiving, and `canSend` does not read it.

<a id="preflight"></a>
## Asking before moving

Wallets, exchanges and the vaults ask the token whether a movement would pass before sending it. `canTransferWithReason` and `canTransfer` run the checks of the movement path without moving anything. They simulate a movement driven by `from` itself: the operator is `from`, which is the zero address for a mint, whoever asks (`test_WhenCalledByAThirdParty_ItSimulatesATransferByFrom`, `test_WhenPreflightingAMint_TheOperatorIsZeroWhoeverAsks`). A zero `from` reads as a mint and a zero `to` as a holder's burn. No pre-flight simulates FORCED, so none predicts `forcedTransfer` or `burn`. Both zero, a mint to the zero address, cannot happen, so it reads false with `ZERO_RECEIVER` without asking the hook, and `mint` to it reverts with `ERC20InvalidReceiver` (`PolicyGatedUnit_ZeroToZero`).

The two differ in one case, because ERC-7943 says `canTransfer` must not fail on a plain balance check and must fail when frozen tokens are in the way.

| Situation | `canTransferWithReason` | `canTransfer` | The real transfer |
|---|---|---|---|
| Hook accepts, amount within the unfrozen balance | true, `TRANSFER_OK` | true | moves |
| A rule refuses, for example a receiver without a credential | false, the rule's reason | false | `ERC8473PolicyRejected(reason)` |
| Token paused | false, `PAUSED` | false | `ERC8473PolicyRejected(PAUSED)` |
| `from` and `to` both zero | false, `ZERO_RECEIVER` | false | `mint` reverts with `ERC20InvalidReceiver` |
| Something frozen on `from`; amount above the unfrozen balance, within the balance | false, `INSUFFICIENT_UNFROZEN` | false | `ERC7943InsufficientUnfrozenBalance` |
| Something frozen on `from`; amount above the balance | false, `INSUFFICIENT_UNFROZEN` | false | `ERC20InsufficientBalance` |
| Nothing frozen; amount above the balance; hook accepts | false, `INSUFFICIENT_UNFROZEN` | true | `ERC20InsufficientBalance` |
| Nothing frozen; amount above the balance; hook refuses | false, `INSUFFICIENT_UNFROZEN` | false | `ERC20InsufficientBalance` |
| `to` is zero and `from` holds `BURNER_ROLE`; something frozen on `from`; amount above the unfrozen balance | false, `INSUFFICIENT_UNFROZEN` | false | The answer is a holder's burn's. The burner's `burn` is not predicted: it takes frozen tokens |

So to learn whether a movement will succeed, use `canTransferWithReason`. It is the same check the write runs, apart from the error it would turn into: it answers `INSUFFICIENT_UNFROZEN` where the write names one of the two balance errors. `canTransfer` is that check with the ERC-7943 exception: a shortfall counts only while a frozen amount is in the way of a holder. While part of the balance is frozen, an amount above the balance reads false; the standard does not say which clause wins there, and this is what the reference implementation published with ERC-7943 does.

`canSend(account)` and `canReceive(account)` ask a different question: may this account send, or receive, this token at all? They are true for the zero address, and the hook is not asked, even while paused. For any other account they are false while the token is paused or has no hook, and false when the hook cannot be asked: they do not revert. Otherwise they return the hook's `checkSend` or `checkReceive`, which asks each rule's account-level answer and stops at the first refusal. They take no amount and no counterparty, and ERC-7943 keeps quantitative rules out of them. So:

- A new investor at a full fund reads `canReceive` true, and the movement is refused with `MAX_HOLDERS`. The minimum position and the settlement window are not in them either.
- A locked or address-frozen holder reads `canSend` false, although `forcedTransfer` and `burn` still pass the rules for both.
- A holder whose whole balance is frozen with `setFrozenTokens` still reads `canSend` true when the rules accept it, and `canTransfer` false for any amount above zero.

ERC-7943 also has `canTransfer` perform the `canSend` and `canReceive` checks. Here `canTransfer` runs the movement path instead. For a plain transfer through the shipped rules it is not true while either account answer is false; `testFuzz_CanTransferNeverExceedsTheAccountQuestions` fuzzes that, in that one direction.

<a id="roles"></a>
## Roles and the guardian

Access is OpenZeppelin `AccessControl`. No role has an admin of its own, so `DEFAULT_ADMIN_ROLE` grants and revokes every role. After hand-over that is the main **timelock**, a contract that runs an approved call after a waiting period (24 hours by default in the deployment, with a floor of 1 hour in [`GovernanceTimelock`](GovernanceTimelock.md)) during which it can be cancelled.

| Role | Held by after hand-over | What it allows on the token |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | The main timelock. The operations account holds it while a product is placed, then renounces. | Grant and revoke roles, replace the hook, unpause. The hook and the rules also ask the token whether a caller holds it before they accept that token's rule list or policy settings. |
| `GUARDIAN_ROLE` | The guardian multisig, granted by the initialiser | `pause()`, with no delay. Nothing else in this base. `Gated4626Vault` also lets it lower the rate limit with `setMaxRate`. |
| `RECOVERY_ROLE` | The recovery timelock | Exactly `unpause()` and `revokeRole(GUARDIAN_ROLE, account)`. |
| `UPGRADER_ROLE` | The main timelock | Upgrades, to attested code of the same template. |
| `AGENT_ROLE` | The agent account, on each product | `forcedTransfer`, `setFrozenTokens`. `HolderRestrictionRule` also accepts lockups and address freezes from it. |
| `MINTER_ROLE` | The minter account, on a `GatedToken` or `IntentToken`; the deployment grants it on no vault | `mint` |
| `BURNER_ROLE` | The burner account, on a `GatedToken` or `IntentToken`; the deployment grants it on no vault | `burn`, an enforcement action: a FORCED movement, which may take frozen tokens and passes a pause. |

**The guardian can only stop things.** It pauses the token at once, and on the main timelock it holds `CANCELLER_ROLE`, so it can cancel any pending governance operation. It cannot unpause, change the hook, grant a role or upgrade.

**Why a second timelock.** A guardian that can cancel governance operations could also cancel its own removal, or an unpause it disagrees with. The recovery timelock closes that gap. It has the same delay, the governance multisig proposes and executes on it, it has no cancellers, and the guardian holds nothing on it. On a token, `revokeRole` lets a `RECOVERY_ROLE` holder revoke `GUARDIAN_ROLE` and passes every other revocation to the role's admin, and `unpause` accepts it beside the admin. It cannot revoke another role, grant a role, change the hook or upgrade: each reverts with `AccessControlUnauthorizedAccount` (`test_WhenRecoveryRevokesAnyOtherRole_ItReverts`, `test_WhenRecoveryGrantsAnyRole_ItReverts`, `test_WhenRecoveryChangesTheHookOrUpgrades_ItReverts`).

**Single keys.** The contract does not look at who holds a role. The post-deploy check asks only the account the deployment names for `MINTER_ROLE`, `BURNER_ROLE` or `AGENT_ROLE`: if that account holds the role and does not answer `getThreshold()` with at least 2, the check refuses it, unless the profile names the role as an exception. Every profile in `ignition/profiles.ts` names all three, for its test keys, so with those profiles the check refuses none of them. See [Deployment and governance](../deployment.md).

<a id="pause"></a>
## During a pause

- **Refused:** every movement whose kind is not FORCED. That covers transfers, mints, executed intents, and vault deposits and redemptions, which are mints and holders' burns. `canSend` and `canReceive` answer false for every account but the zero address.
- **Still possible:** `forcedTransfer`, the burner's `burn` and the 7540 vault's own FORCED recoveries, `setFrozenTokens`, `approve` and `permit`, `cancelIntent` on an intent token, role changes, replacing the hook and upgrades. The rules still run on a forced movement, so the receiver must still pass them; a `burn` has no receiver.
- **Lifting it** takes a timelock operation: the main timelock, or the recovery timelock if the guardian keeps cancelling. There is no automatic expiry.

<a id="hook"></a>
## Installing a policy

ERC-8473 calls the hook the token's policy. `installPolicy(_newPolicy, _data)` needs `DEFAULT_ADMIN_ROLE`, the timelock. The hook must not be the zero address (`PolicyGated_ZeroAddress`), its code hash must be attested as `HOOK` in the token's registry (`PolicyGated_NotAttested`), it must name the same registry (`PolicyGated_HookRegistryMismatch(_hookRegistry, _tokenRegistry)`), because a hook shared by several tokens checks their rules against its own registry, and it must answer the id of `IERC8473Policy`, `0x9cb56a99`, through ERC-165 (`PolicyGated_NotAPolicy`).

The token then stores the hook, emits `PolicyChanged` and calls the hook's `onInstall(token, previous, data)`. If that call reverts, the installation reverts and the token keeps the hook it had. The installation holds the reentrancy guard of the movement path, so no movement can begin while `onInstall` runs.

The hook keeps the rule list of each token itself. Data that is not empty is `abi.encode` of this token's ordered rule list, and the hook installs it in that call. With empty data the hook keeps the list it already holds for the token. If it holds none, it refuses every movement of the token with `NO_RULES` until the timelock, as the token's admin, sets the list with `setRules`.

When the token is first set up, its initialiser installs the hook the same way, with `abi.encode(rules)` as the data, so the token is live with its policy as soon as it exists (`test_WhenInitialised_ItCallsOnInstallWithNoPreviousPolicyAndTheRuleList`). An empty list sends empty data, and the hook's state stands: with no rules, every movement is refused (`test_WhenNoInitialRulesAreGiven_TheInstallationCarriesNoData`). See [`PolicyGatedCoreUpgradeable`](PolicyGatedCoreUpgradeable.md#hook) and [`ComplianceHook`](ComplianceHook.md).

<a id="upgrades"></a>
## Upgrades

Each token is a **proxy**: a small contract that holds the balances and forwards every call to shared code, its implementation. An upgrade points the proxy at other code (OpenZeppelin UUPS, `upgradeToAndCall`). The base checks three things, in this order (`_authorizeUpgrade`):

1. The caller holds `UPGRADER_ROLE`, which the deployment gives to the main timelock. The post-deploy check confirms that none of the deployment's wallets also holds it. `AccessControl` keeps no list of holders, so this is not a check of every account.
2. The target's code hash is attested as `IMPLEMENTATION` (`PolicyGated_NotAttested(newImplementation, IMPLEMENTATION)`). A UUPS implementation records its own address, so each deployment of it has its own code hash and needs its own attestation (`test_WhenAnImplementationIsRedeployed_ItNeedsItsOwnAttestation`).
3. The target reports the same `templateId()` as this token (`Templated_WrongTemplate(newImplementation, expected, actual)`). The id is `keccak256` of the template's name with no version, so a bug-fix release of a template passes, while an intent token cannot be moved onto a vault's code even when that code is attested (`test_WhenUpgradedToAVaultImplementationThatIsAttested_ItIsRefused`). Code with no `templateId()` is refused too (`test_WhenTheImplementationHasNoTemplateId_ItIsRefused`).

OpenZeppelin then checks that the target is a UUPS implementation (`UUPSUnsupportedProxiableUUID`, `ERC1967InvalidImplementation`) and emits `Upgraded`. Value sent with an upgrade reverts (`test_WhenTheUpgraderAttachesEther_TheUpgradeReverts`).

<a id="standards"></a>
## Standards it speaks, and multicall

- **ERC-7943** (uRWA, the fungible interface): `forcedTransfer`, `setFrozenTokens`, `getFrozenTokens`, `canSend`, `canReceive`, `canTransfer`, with the events `ForcedTransfer` and `Frozen` and the error `ERC7943InsufficientUnfrozenBalance`. The interface also declares the optional errors `ERC7943CannotSend`, `ERC7943CannotReceive` and `ERC7943CannotTransfer`. The token does not use them and rejects with `ERC8473PolicyRejected(reason)`, which carries the reason.
- **ERC-8473** (uRWA Policy, a draft that sits behind ERC-7943): `policy()` returns the hook, `PolicyChanged` is emitted on every installation, and a rejection by the hook reverts with `ERC8473PolicyRejected(reason)`.
- **ERC-165**: `supportsInterface` answers true for `IPolicyGated`, `IPolicyGatedCore`, `IERC8473` (`0x0505c8c9`), `IERC7943Fungible` (`0x3edbb4c4`), `IERC20`, `IERC20Permit`, `IAccessControl` and `IERC165`. An `IntentToken` adds `ITransferIntent`.
- **ERC-2612** `permit`: approval by signature. Its EIP-712 domain is the token name, version `"1"`, the chain and the token address, the same domain as signed intents.
- **Multicall**: `multicall(data)` runs each call on the token itself, so the caller stays the sender and its roles apply to each call. A minter can mint to several accounts, or an agent can set a frozen amount and force a transfer, in one transaction; the tokens have no batch functions of their own. If one call fails, all are undone (`test_WhenALaterCallFails_TheEarlierOnesAreUndone`). Each movement inside goes through `_move` on its own, with its own kind and the balances the previous call left (`test_WhenAForcedTransferIsFollowedByAPlainTransferInOneBatch_TheSecondIsPlain`). It is not payable, and it cannot initialise the token again (`test_WhenABatchCallsInitialize_ItReverts`). A contract that filters which functions an account may call on the token has to treat `multicall` as a way in.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `transfer(to, value)`, `transferFrom(from, to, value)` | A holder, or a spender with allowance | Standard ERC-20 transfer, decided as TRANSFER. `transferFrom` spends the allowance first. |
| `approve(spender, value)`, `permit(owner, spender, value, deadline, v, r, s)` | The holder; for `permit`, anyone with the holder's signature | Sets an allowance. Nothing moves, so the hook is not asked and it works while paused. |
| `mint(to, amount)` | `MINTER_ROLE` | Creates tokens for `to`, decided as MINT. Both vaults replace it with a function that reverts (`GatedVault_Unsupported`): their shares come from deposits. |
| `burn(from, amount)` | `BURNER_ROLE` | Destroys tokens of `from` without an allowance. May take frozen tokens, and lowers the frozen amount by the frozen part of what it burns. Works while paused. Decided as FORCED with a zero receiver. The vaults replace it with a function that reverts. |
| `forcedTransfer(from, to, amount)` | `AGENT_ROLE` | Moves tokens without the holder's consent, also while paused. May take frozen tokens like `burn`. Decided as FORCED, so the rules still run and can refuse the receiver. Returns `true`. On `Gated7540Vault`, out of the vault's own address it may take only shares not booked to a pending redemption (`Gated7540Vault_ExceedsSurplus`). |
| `setFrozenTokens(account, amount)` | `AGENT_ROLE` | Replaces the account's frozen amount. It may exceed the balance. Returns `true`. Works while paused. On `Gated7540Vault`, the vault's own address reverts (`GatedVault_Unsupported`). |
| `getFrozenTokens(account)` | Anyone (read-only) | The account's frozen amount. |
| `pause()` | `GUARDIAN_ROLE` | Stops every movement except forced ones, at once. `paused()` reads the state. |
| `unpause()` | `DEFAULT_ADMIN_ROLE` or `RECOVERY_ROLE` | Lifts the pause. Anyone else gets `AccessControlUnauthorizedAccount(caller, DEFAULT_ADMIN_ROLE)`. |
| `installPolicy(_newPolicy, _data)` | `DEFAULT_ADMIN_ROLE` | Installs a hook, after the checks under [Installing a policy](#hook), and calls its `onInstall` with the data. |
| `policy()`, `registry()` | Anyone (read-only) | The current hook, and the registry fixed at setup. |
| `canTransfer(from, to, amount)`, `canTransferWithReason(from, to, amount)`, `canSend(account)`, `canReceive(account)` | Anyone (read-only) | The pre-flight answers; see [Asking before moving](#preflight). |
| `upgradeToAndCall(newImplementation, data)` | `UPGRADER_ROLE` | Points the proxy at other code, after the checks under [Upgrades](#upgrades). `proxiableUUID()` and `UPGRADE_INTERFACE_VERSION()` are OpenZeppelin's reads; the first answers on the implementation and reverts through the proxy. |
| `grantRole(role, account)`, `revokeRole(role, account)`, `renounceRole(role, callerConfirmation)` | `grantRole`, `revokeRole`: `DEFAULT_ADMIN_ROLE`; `RECOVERY_ROLE` may also revoke `GUARDIAN_ROLE`. `renounceRole`: the account giving up its own role. | OpenZeppelin `AccessControl`, with the one exception for the recovery role. `hasRole` and `getRoleAdmin` are the reads, and each role has a getter with its name, such as `MINTER_ROLE()`. |
| `multicall(data)` | Anyone; each inner call keeps the caller's roles | Runs several calls on the token in one transaction, all or none. Not payable. |
| `templateId()`, `supportsInterface(interfaceId)` | Anyone (read-only) | The template's name hash, which each template defines, and the interfaces the token reports. |
| `name()`, `symbol()`, `decimals()`, `totalSupply()`, `balanceOf(account)`, `allowance(owner, spender)`, `nonces(owner)`, `DOMAIN_SEPARATOR()`, `eip712Domain()` | Anyone (read-only) | OpenZeppelin's ERC-20, ERC-2612 and ERC-5267 reads. `GatedToken` and `IntentToken` replace `decimals()` with the value fixed at setup. |

| Event | When |
|---|---|
| `Transfer`, `Approval` | The ERC-20 events. |
| `Frozen(account, amount)` | `setFrozenTokens`, and an enforcement action that lowers the frozen amount. `amount` is the frozen amount after the change. Comes before the `Transfer` of that action. |
| `ForcedTransfer(from, to, amount)`, `ForcedTransferBy(from, to, amount, agent)` | `forcedTransfer`, in that order, after `Transfer` and after the hook's `afterTransfer`. The second is ours and names the agent, which the standard's event does not. The 7540 vault's recoveries are not this function and do not emit them; the vault has its own events. |
| `PolicyChanged(_previousPolicy, _newPolicy)` | The initialiser, where `_previousPolicy` is zero, and every `installPolicy`. |
| `Paused`, `Unpaused`, `RoleGranted`, `RoleRevoked`, `Upgraded` | OpenZeppelin's events for the pause, the roles and an upgrade. |

| Error | When |
|---|---|
| `ERC8473PolicyRejected(reason)` | The pause or the hook refused a movement. `reason` is a code from `Reasons` (`Errors.sol`). The base itself produces `PAUSED`, `NO_HOOK` and, for a hook that cannot be asked, `CHECK_UNAVAILABLE`; the others come from the hook, its rules, or the intent mixin. Each code is the `keccak256` of its name, so `TRANSFER_OK` is not zero. |
| `ERC7943InsufficientUnfrozenBalance(account, amount, unfrozen)` | An amount within the balance and above the unfrozen balance. |
| `ERC20InsufficientBalance(sender, balance, needed)` | An amount above the balance. |
| `ERC20InvalidSender`, `ERC20InvalidReceiver` | `ERC20InvalidReceiver`: a zero receiver on `transfer`, `transferFrom`, `mint` or `forcedTransfer`. `ERC20InvalidSender`: a zero `from` on `burn`, and a zero `from` with a zero amount on `forcedTransfer`. With an amount, `forcedTransfer` from zero reverts with `ERC20InsufficientBalance`, and `transferFrom` from zero reverts with `ERC20InsufficientAllowance` or `ERC20InvalidApprover`. |
| `ERC20InsufficientAllowance`, `ERC20InvalidApprover`, `ERC20InvalidSpender`, `ERC2612ExpiredSignature`, `ERC2612InvalidSigner` | `transferFrom`, `approve` and `permit`. |
| `PolicyGated_ZeroAddress()` | A zero admin, guardian, registry or hook at setup, or a zero hook in `installPolicy`. |
| `PolicyGated_NotAttested(target, kind)` | A hook not attested as `HOOK`, or an upgrade target not attested as `IMPLEMENTATION`. |
| `PolicyGated_HookRegistryMismatch(_hookRegistry, _tokenRegistry)` | A hook that names another registry. |
| `PolicyGated_NotAPolicy(_target)` | A hook that does not answer the id of `IERC8473Policy`. |
| `Templated_WrongTemplate(newImplementation, expected, actual)` | An upgrade target of another template. |
| `AccessControlUnauthorizedAccount(account, neededRole)`, `AccessControlBadConfirmation()` | A caller without the role, and a `renounceRole` that names another account. |
| `EnforcedPause()`, `ExpectedPause()` | `pause()` while paused, and `unpause()` while not paused. |
| `ReentrancyGuardReentrantCall()` | A hook or rule that starts another movement on the token during one, or during an installation. |
| `InvalidInitialization()` | A second initialisation of a proxy, or any initialisation of the implementation itself. |
| `UUPSUnauthorizedCallContext()`, `UUPSUnsupportedProxiableUUID(slot)`, `ERC1967InvalidImplementation`, `ERC1967NonPayable` | OpenZeppelin's upgrade errors: `upgradeToAndCall` called other than through the proxy, a target that is not a UUPS implementation, and value sent with an upgrade that has no setup call. |
| `ERC7943CannotSend(account)`, `ERC7943CannotReceive(account)`, `ERC7943CannotTransfer(from, to, amount)` | Declared by the standard's interface as optional. The token does not revert with them. |

<a id="why"></a>
## Why it is built this way

- **One path, shared with the pre-flights.** The write and the pre-flight answers build the context and run the checks with the same functions (`_context`, `_check`), so they do not drift apart. The difference that remains is the ERC-7943 balance case above.
- **No policy in the base.** The base checks mechanical things: pause, the frozen bound, roles, attestations. Each question of who, where or when is a rule in the hook, so policy can change without upgrading the token.
- **Balances travel in the context.** Rules read both balances from `data` and work out the balances after the move from `amount`, with no call back into the token for them.
- **Kinds travel as arguments.** A forced transfer and an intent need a kind the addresses cannot show. `_moveAs` and `_mintAs` pass it straight to `_move`, so no later movement can pick up a stale kind. The one transient value is the reentrancy guard, from OpenZeppelin's `ReentrancyGuardTransient`.
- **The registry is asked at install time.** A hook is checked when it is installed and an implementation when it is upgraded to. A later withdrawal of an attestation does not change a running token: governance removes the component and the guardian can pause meanwhile, so a revocation does not silently drop a check or block every transfer.
- **The registry is fixed at setup.** The initialiser takes it once, and there is no setter.
- **No setup function of its own.** Its only state, the frozen amounts, starts at zero. Each template sets up ERC-20, `permit` and the core itself. `GatedToken`, `IntentToken` and `Gated7540Vault` call `__ERC20_init`, `__ERC20Permit_init` and `__PolicyGatedCore_init`. `Gated4626Vault` calls each parent's setup one by one, ending with `__PolicyGatedCore_init_unchained`, so that ERC-4626's sits between ERC-20's and `permit`'s.
- **Reason codes do not default to yes.** A hook or rule that forgets to set its answer returns zero, which is not `TRANSFER_OK`, so it refuses.
- **Namespaced storage.** The frozen amounts live in their own ERC-7201 namespace (`gated.storage.PolicyGatedERC20`), and the registry and the hook pointer in the core's (`gated.storage.PolicyGatedCore`), apart from the OpenZeppelin parents and the templates.

<a id="limits"></a>
## What it does not do

- **It has no policy of its own to fall back on.** A token whose hook holds no rules for it refuses every movement with `NO_RULES`.
- **It puts no delay or limit on the operational roles.** `mint`, `burn`, `forcedTransfer` and `setFrozenTokens` act at once, for any amount the rules accept. What limits them is who holds the role and the rule list: a [supply cap](SupplyCapRule.md) on a mint, or a credential on the receiver of a forced transfer (`test_WhenAForcedMoveHasAnIneligibleReceiver_ItIsRejected`).
- **A pause does not stop enforcement.** `forcedTransfer` and `burn` are FORCED movements and pass a pause. The pause stops holders and the minter, not the agent or the burner.
- **`canTransfer` can say yes where the write reverts**, as the table above shows. An integrator that wants to know whether a movement will succeed should call `canTransferWithReason`.
- **The pre-flights do not model every caller.** They simulate `from` moving its own tokens. They do not check an allowance, and they do not model a spender as operator, `forcedTransfer` or `burn`. A zero `to` reads as a holder's burn, which only the vaults have, while `transfer` to the zero address reverts with `ERC20InvalidReceiver`.
- **The pre-flights answer for the latest block,** and a write lands in the next one. At a time boundary, such as the end of a lockup, they can differ by one second (`test/nodejs/time.test.ts`).
- **Holding `BURNER_ROLE` exempts nothing but `burn`.** The base and the rules do not read whether the operator holds the role. A `BURNER_ROLE` holder that redeems its own shares through a vault is judged like any holder: its frozen tokens, lockup and minimum apply.
- **A forced transfer to the same account still releases.** `_releaseFrozen` does not look at the receiver, so a `forcedTransfer(a, a, amount)` the rules accept lowers the frozen amount of `a` by the usual rule, with its `Frozen` event, although no tokens leave.
- **A plain holder has no burn.** `burn` needs `BURNER_ROLE`. A holder's own burn exists on the vaults, as a redemption.
- **The upgrade check trusts what the target reports.** It compares the id the target returns, so an attested implementation that reports the same id passes. The review behind the attestation is the control on what that code does, and storage layout is checked off-chain (`npm run validate:upgrades`), not by the contract.
- **It moves nothing past a failing hook.** A hook or rule that reverts on a check gives `CHECK_UNAVAILABLE`: the pre-flights read false, and every movement reverts, forced ones included, until governance installs another hook. `wantsAfterTransfer` and `afterTransfer` are called directly, so a revert in either undoes the movement with the hook's own error.
- **It keeps no history of balances.** There are no snapshots. A distribution works from a list built off-chain at the record date ([`Distributor`](Distributor.md)).

<a id="connected"></a>
## Connected to

- [PolicyGatedCoreUpgradeable](PolicyGatedCoreUpgradeable.md): The roles, pause, hook pointer and upgrade checks this base extends.
- [GatedToken](GatedToken.md): The base and nothing else, as a template.
- [IntentSettledUpgradeable](IntentSettledUpgradeable.md): Adds signed transfers on top of this base, as the EXECUTED kind.
- [IntentToken](IntentToken.md): The template with signed transfers.
- [Gated4626Vault](Gated4626Vault.md): Vault shares as a gated token: deposits are mints, redemptions burns.
- [Gated7540Vault](Gated7540Vault.md): Request-and-claim vault on the same base, with its own enforcement recoveries.
- [ComplianceHook](ComplianceHook.md): The hook every movement asks, holding each token's ordered rules.
- [PolicyRegistry](PolicyRegistry.md): The record of reviewed code asked when a hook or implementation is installed.
- [One movement](../movement.md): A movement followed from the entry point through the rules.
- [Who can do what](../roles.md): The roles on each contract, and what a pause leaves possible.

<a id="source"></a>
## Source and tests

- Contract: `contracts/base/PolicyGatedERC20Upgradeable.sol`, over `contracts/base/PolicyGatedCoreUpgradeable.sol`
- Interfaces: `IPolicyGated.sol`, `IPolicyGatedCore.sol`, `IERC8473.sol`, `IERC7943Fungible.sol`, `ITemplated.sol`, `IERC8473Policy.sol` (the context and the kinds), `Errors.sol` (the reason codes)
- Unit tests: `PolicyGatedERC20Upgradeable.t.sol` (the role gates, frozen maths, pre-flight answers, recovery, upgrades, multicall, the context per kind, the installation and the hook that cannot be asked in `PolicyGatedUnit_Erc8473`, and the invariants `invariant_SumOfBalancesEqualsTotalSupply` and `invariant_TheUnfrozenBalanceIsExactlyWhatCanBeSent`)
- Integration: `GatedToken.t.sol` and `IntentToken.t.sol` (real registry and hook), `RuleSetIntegration.t.sol` (the shipped rules together), `test/nodejs/erc7943.test.ts` and `test/nodejs/parity.test.ts` (the deployed stack), and the Halmos properties `check_frozenBalanceInvariants` and `check_enforcementCanTakeFrozenTokens` in `IntentTokenHalmos.t.sol`

---

Describes the contracts at commit `75aa171` on `main`.
