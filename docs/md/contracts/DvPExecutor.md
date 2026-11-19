[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Settlement and distribution

# DvPExecutor

Settles a trade of a security token against cash in one transaction: the shares move and the cash moves, or nothing moves. Each side signs what it gives and what it is to receive, and the executor checks that the two signed statements describe the same trade.

- **contracts/intents/DvPExecutor.sol**
- immutable, **not a proxy**
- admin after hand-over: **the main timelock**
- not attested: a token trusts it by granting **EXECUTOR_ROLE**

<a id="in-one-minute"></a>

> ### In one minute
>
> Delivery versus payment (DvP) means the seller's shares are delivered only if the buyer pays, and the buyer pays only if the shares are delivered. The two parties agree a trade off-chain. The seller signs an intent (a signed transfer instruction) to send shares to the buyer, stating the cash token and the price it expects in return. The buyer signs the payment in one of two ways: an intent on a gated cash token, stating the shares it expects, or an ERC-3009 authorization (a signed permission to pull a payment) tied to the seller's intent. An operator submits both. The executor checks that they describe one trade, runs the cash leg first, then the shares, and if any part fails the whole transaction is undone. It does no matching, pricing, fees or partial fills.

<a id="how"></a>
## How a trade settles

There are two entry points, one per form of cash, and the executor has no entry point that runs one leg alone. Both are called by an `OPERATOR_ROLE` holder, both are guarded against reentry, and both stop while the executor is paused. A *leg* is one side of the trade: the cash leg pays, the securities leg delivers.

> **Diagram.** Gated cash, executeDvPGated. An operator calls the executor, which checks the role, the pause and that the two legs mirror, otherwise DvPExecutor_LegsDoNotMatch. The cash leg runs first: the buyer's intent on the cash token moves the price straight from the buyer to the seller. The securities leg runs second: the seller's intent on the security token moves the shares from the seller to the buyer. A token that refuses a leg makes the whole trade revert with DvPExecutor_LegFailed naming the leg. Then the executor emits DvPSettled. The cash does not pass through the executor.
>
> **Gated cash: the cash goes straight from the buyer to the seller.** The executor calls `executeTransfer` on each token, and each token checks its own intent and moves its own balance. Both legs reach their token's hook as EXECUTED. A revert at any step undoes every step before it.

> **Diagram.** ERC-3009 cash, executeDvP3009. An operator calls the executor, which checks the role, the pause and that the authorization matches the seller's intent, otherwise DvPExecutor_LegsDoNotMatch. The cash leg runs first: the executor pulls the price from the buyer to itself with receiveWithAuthorization. The securities leg runs second: the seller's intent moves the shares from the seller to the buyer. Then the executor pays the price to the seller with safeTransfer. It then requires that it holds what it held before the pull and that the seller is up by exactly the price, otherwise DvPExecutor_CashNotConserved. Then it emits DvPSettled.
>
> **ERC-3009 cash: the cash passes through the executor inside the call.** The purple arrow is an executed intent, which its token checks and runs through its hook. The plain arrows are movements of a cash token that has no hook. The call succeeds only if the executor ends with the balance it started with.

|  | Gated cash token | ERC-3009 cash token |
|---|---|---|
| The cash is | An [IntentToken](IntentToken.md) of its own, under its own rule list | A token with `receiveWithAuthorization` and `authorizationState` (`IERC3009`), outside the hook |
| The buyer signs | A transfer intent on the cash token | An ERC-3009 authorization, payable to the executor |
| Entry point | `executeDvPGated` | `executeDvP3009` |
| Pre-flight | `canExecuteDvPGated` | `canExecuteDvP3009` |
| Where the cash goes | Straight from the buyer to the seller | From the buyer to the executor, then on to the seller, within the call |
| The executor needs | `EXECUTOR_ROLE` on both tokens | `EXECUTOR_ROLE` on the security token |

<a id="signed"></a>
## What each party signs

Each signature covers both what its signer gives and what it is to receive. The executor builds nothing itself; it compares the two signed statements.

| Field | Seller's intent, on the security token | Buyer's intent, on the gated cash token |
|---|---|---|
| `from`, `to` | the seller, the buyer | the buyer, the seller |
| `amount` | the shares | the price |
| `considerationToken` | the cash token | the security token |
| `considerationAmount` | the price | the shares |
| `executor` | this executor | this executor |
| `nonce`, `deadline`, `validAfter`, `ref` | as for any intent, chosen by each signer; the executor does not compare them across the legs |  |

In the ERC-3009 form the buyer signs instead an authorization in the cash token's own format, held in the struct `Authorization`: `from` (the buyer), `value` (the price), `validAfter`, `validBefore`, `nonce` and `signature`. The payee is not in the struct: the executor passes itself. ERC-3009's `receiveWithAuthorization` can be submitted by its payee alone, so nobody else can spend the authorization.

A token refuses an intent that states a consideration and names no executor, and refuses an intent that names an executor from any other caller. So both intents of a trade name this executor, and neither can be run by the [IntentExecutor](IntentExecutor.md), which refuses a stated payment before it calls the token. The executor does not compare the `executor` fields itself; each token does.

<a id="match"></a>
## When the two legs describe one trade

These checks run before any leg, and any failure reverts with `DvPExecutor_LegsDoNotMatch`. In the gated form no token has been called yet. In the ERC-3009 form the security token's `intentHash` has been read and no cash has moved.

### Gated form: the legs mirror

Seven conditions, in `executeDvPGated` and `canExecuteDvPGated`:

1. The two tokens differ: `securityToken != cashToken`.
2. The seller's `from` is the buyer's `to`.
3. The seller's `to` is the buyer's `from`.
4. The seller's `amount` (the shares) is the buyer's `considerationAmount`.
5. The buyer's `amount` (the price) is the seller's `considerationAmount`.
6. The seller's `considerationToken` is `cashToken`.
7. The buyer's `considerationToken` is `securityToken`.

### ERC-3009 form: the authorization matches

Five conditions, in `executeDvP3009` and `canExecuteDvP3009`:

1. The two tokens differ: `securityToken != cashToken`.
2. The authorization's `from` is the seller's `to`, the buyer.
3. The authorization's `value` is the seller's `considerationAmount`.
4. The seller's `considerationToken` is `cashToken`.
5. The authorization's `nonce` is derived from the security token and the seller's intent, as below.

The conditions do not require the seller and the buyer to be different accounts. A trade between an account and itself passes and settles in both forms. The securities leg is a self-transfer, and so is a gated cash leg. An ERC-3009 cash leg goes out to the executor and comes back (`test_WhenTheSellerIsAlsoTheBuyer_AGatedTradeSettlesToo`, `test_WhenTheSellerIsAlsoTheBuyer_PreflightSaysYesAndTheTradeSettles`).

<a id="nonce"></a>
## The ERC-3009 nonce

An ERC-3009 authorization carries a nonce chosen by the signer. Here the buyer's nonce must be this value, which the buyer's client computes before signing:

```
keccak256(abi.encode(securityToken, securityToken.intentHash(securitiesIntent)))
```

The intent hash ties the payment to one exact securities intent: the same seller, buyer, shares, price, deadline and nonce. The cash token treats the nonce as an opaque value, so the executor does the comparison, and a buyer who signed this nonce has committed to that intent.

**Why not the bare hash.** The executor gets the hash by asking the token it was handed, and it cannot tell an honest token's answer from a counterfeit's. Anyone can compute the genuine hash of an intent. With the bare hash as the nonce, an operator could pair the buyer's authorization with a counterfeit "security token" that reports the genuine hash and delivers nothing, and put its own account in the seller's place, so the cash would go to the operator. With the token's address inside, the executor computes a different nonce for the counterfeit and the authorization does not match. `test_WhenAnOperatorSubstitutesACounterfeitSecurityToken_TheAuthorizationIsRefused` tries exactly this substitution and expects `DvPExecutor_LegsDoNotMatch` with no cash moved.

The buyer's wallet shows the value, the executor as payee and an opaque nonce, so in this form it cannot show what the buyer receives. In the gated form the buyer's intent states the shares in clear.

<a id="conservation"></a>
## The balance checks after the legs

The ERC-3009 form moves cash through the executor, so it measures the result. It reads its own cash balance before the pull, and the seller's cash balance after the securities leg, just before the payout. After paying the seller it requires two things, and reverts with `DvPExecutor_CashNotConserved(account, expected, actual)` otherwise:

- its own balance equals what it read before the pull;
- the seller's balance rose by exactly the price. Because it was read after the pull, a seller who is also the payer is measured on the payout alone.

A cash token that takes a fee on transfers fails the trade. Usually the payout itself reverts with the cash token's own error, because the executor received less than it must pay (`test_WhenTheCashTokenTakesAFee_TheTradeRevertsAndKeepsEverything`). When a stray balance in the executor covers the shortfall, or the fee falls on the payout alone, the balance check catches it (`test_WhenAStrayBalanceHidesTheShortfall_TheConservationCheckStillCatchesTheFee`). The executor has no function to sweep out anything sent to it by mistake, and a settled trade leaves that balance as it was (`test_WhenTheTradeSettles_TheExecutorBalanceIsExactlyWhatWasDonated`).

The gated form has no balance checks. Its cash moves directly between the parties, so the executor holds none of it, and each token reverts if it cannot make the move.

<a id="errors"></a>
## When a leg fails

`DvPExecutor_LegFailed(leg, reason)` wraps the token's revert data so the operator knows which leg failed. `leg` is `CASH` (0) or `SECURITIES` (1), and `reason` is the token's revert data, for example `ERC8473PolicyRejected(reason)`. The cash leg runs first, so if both legs would fail the cash leg is the one reported (`test_WhenBothLegsFail_TheCashLegIsReportedBecauseItRunsFirst`). In the ERC-3009 form the cash leg is the pull, and the securities leg runs between the pull and the payout.

Not wrapped, so they arrive with their own error:

- The payout to the seller in the ERC-3009 form: the cash token's own error (for a blocklisted seller, say), `SafeERC20FailedOperation(token)` for a token that returns false, and `ReentrancyGuardReentrantCall` for a token that calls back into the executor during the payout. A token that calls back during the pull, or during a gated leg, is reported as that leg's `DvPExecutor_LegFailed` with the guard's error inside.
- The executor's own gates: `ReentrancyGuardReentrantCall`, `AccessControlUnauthorizedAccount`, `EnforcedPause`, in that order.
- In the ERC-3009 form, the read of the security token's `intentHash` and the reads of the cash balances, which run outside any leg. A security token with no `intentHash`, such as a `GatedToken`, reverts with no data.
- A token address with no code reverts with empty revert data, because Solidity does not route that failure to the `catch` (`test_WhenTheSecurityTokenHasNoCode_ItRevertsAfterTheCashLegRan`). The same goes for a token that returns too little data to read as a hash.

<a id="preflight"></a>
## What the pre-flights return

`canExecuteDvPGated` and `canExecuteDvP3009` take the same arguments as the entry points and return `(ok, reason)`: a refusal comes back as a reason code, and `ok` is true when the reason is `TRANSFER_OK`. Anyone can call them. They ask the tokens' own `canExecute` with the executor's address, so the answer does not depend on who asks. They answer in this order, stopping at the first refusal:

### `canExecuteDvPGated`

1. The executor's pause: `PAUSED`.
2. The mirror: `LEGS_DO_NOT_MATCH`.
3. The cash token's `canExecute` for the buyer's intent: its reason, such as `NOT_EXECUTOR` or `NONCE_USED`.
4. The security token's `canExecute` for the seller's intent: its reason, such as `LOCKED_UP`.

### `canExecuteDvP3009`

1. The executor's pause: `PAUSED`.
2. The match: `LEGS_DO_NOT_MATCH`.
3. The authorization: `INTENT_NOT_YET_VALID` at or before `validAfter`, `INTENT_EXPIRED` at or after `validBefore`, `NONCE_USED` if used or cancelled, `INSUFFICIENT_UNFROZEN` if the buyer's balance is below the value.
4. The security token's `canExecute` for the seller's intent: its reason.

What they cannot see:

- **The operator.** Neither checks `OPERATOR_ROLE`. A token on which the executor holds no `EXECUTOR_ROLE` does show up, as `NOT_EXECUTOR` from its own `canExecute`.
- **The ERC-3009 side.** The buyer's signature (the cash token exposes no view for it), a pause or blocklist on the cash token, and a transfer fee. So `canExecuteDvP3009` saying yes means the trade would settle given a valid authorization signature and an ordinary cash token.
- **One leg's effect on the other.** Both legs are asked against the state before either runs. When the two tokens share policy state, such as two classes of one [Fund](Fund.md), the first leg can change the second's answer. `test_WhenTheFundIsAboveItsLoweredCap_ASwapOfTwoClassesPassesPreflightAndFailsOnTheSecondLeg` shows it: a fund whose investor cap was lowered below its count, and a buyer who pays with its whole position in one class for shares of another. The buyer leaves the fund on the first leg and counts as a new investor on the second, which the lowered cap refuses, though the pre-flight said yes.
- **The next block.** A pre-flight answers for the latest block and a write lands in a later one, so at a time boundary the two can differ.

Simulating the entry point itself from the operator's address shows the real outcome. A token address with no code makes a pre-flight revert, as it does the entry point.

<a id="time"></a>
## Time, cancellation and policy

- **Windows differ at the edge.** An intent's `deadline` and `validAfter` are inclusive. An ERC-3009 `validBefore` and `validAfter` are exclusive. A buyer who signs `validBefore` equal to the intent's deadline loses that last second, and a trade submitted in it reverts as a whole (`test_WhenTheAuthorizationEndsOnTheIntentDeadline_TheIntentsLastSecondIsLost`); one second later, both are valid on the deadline (`test_WhenTheAuthorizationEndsOneSecondAfterTheIntentDeadline_TheTradeSettlesOnTheDeadline`).
- **Cancelling.** The seller, and the buyer in the gated form, cancel by spending their nonce with `cancelIntent` on their own token. An ERC-3009 authorization is cancelled on the cash token by whatever means it offers; the pre-flight then reads `NONCE_USED`. Either way the trade then fails as a whole.
- **Expiry.** A trade nobody submits lapses at the first deadline to pass: an intent's `deadline` or the authorization's `validBefore`.
- **A failed trade spends nothing.** The nonces and the authorization stay unused, because the revert undoes their writes, so the same signatures can settle later (`test_WhenTheSecuritiesLegIsLocked_NothingMovesAndNoNonceIsSpent`, `test_WhenTheSecuritiesLegIsLocked_NothingMovesAndTheAuthorizationStaysUnused`). A settled trade cannot settle twice (`test_WhenTheTradeSettled_ItCannotSettleTwice`).
- **Policy applies to each executed leg.** The securities leg reaches the hook as EXECUTED, so the rules the token lists apply to it, among them [SettlementWindowRule](SettlementWindowRule.md) (`test_WhenOutsideTheSettlementWindow_TheTradeWaitsForTheNextOpening`) and the fund-wide cap of [FundHoldersRule](FundHoldersRule.md) (`test_WhenTheFundIsFull_APartialSaleToANewInvestorIsRefusedAtTheSecuritiesLeg`). A gated cash leg runs the cash token's own rule list, pause and frozen amounts. The shares go straight from the seller to the buyer, so the executor does not hold them and needs no credential on the security token.

<a id="roles"></a>
## Roles, pause and reentry

- **OPERATOR_ROLE**: Submits trades. Deployed: the account passed as `operator` to `CoreHandover`, the same as on the intent executor.
- **GUARDIAN_ROLE**: Pauses with no delay. Deployed: the guardian multisig, from the constructor.
- **DEFAULT_ADMIN_ROLE**: Grants roles and unpauses. Deployed: the deployer until `CoreHandover`, then the main timelock.
- **RECOVERY_ROLE**: `unpause()` and revoking `GUARDIAN_ROLE`, and nothing else. Deployed: the recovery timelock.
- **EXECUTOR_ROLE**: Held by this contract on the tokens it settles. `Product` grants it on a token whose product lists `dvp` under `executors`.

`Core` deploys the executor only when a product in the profile names it. Of the profiles in `ignition/profiles.ts`, `full` and `intent` do, each on its intent token. For a core built without it, `CoreParts` adds it and `PartsHandover` grants its roles and hands it to the main timelock, as `CoreHandover` does. No profile includes a gated cash token. Such a token is an `IntentToken` of its own, placed as a product of its own or deployed apart, as `test/nodejs/dvp.test.ts` does, and it has to grant this executor the role too.

Pausing the executor stops both entry points without touching the tokens. Both entry points carry OpenZeppelin's reentrancy guard, which keeps its flag in storage, and the tests cover a cash token calling back during the pull, during the payout and during a gated leg. The pre-flights are read-only and unguarded.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `executeDvPGated(securityToken, cashToken, securitiesIntent, securitiesSig, cashIntent, cashSig)` | `OPERATOR_ROLE`, while not paused | Checks that the two intents mirror, executes the cash intent, then the securities intent. Returns the seller intent's hash and emits `DvPSettled`. |
| `executeDvP3009(securityToken, cashToken, securitiesIntent, securitiesSig, authorization)` | `OPERATOR_ROLE`, while not paused | Checks that the authorization matches the intent, pulls the cash, executes the securities intent, pays the seller, checks the balances. Returns the seller intent's hash and emits `DvPSettled`. |
| `canExecuteDvPGated(…)`, `canExecuteDvP3009(…)` | Anyone (read-only) | Pre-flight for the same arguments: `(ok, reason)`. |
| `pause()` | `GUARDIAN_ROLE` | Stops both entry points at once. Reverts with `EnforcedPause` if already paused. |
| `unpause()` | `DEFAULT_ADMIN_ROLE` or `RECOVERY_ROLE` | Resumes settlement. Anyone else gets `AccessControlUnauthorizedAccount(caller, DEFAULT_ADMIN_ROLE)`. Reverts with `ExpectedPause` if not paused. |
| `revokeRole(role, account)` | The role's admin; `RECOVERY_ROLE` for `GUARDIAN_ROLE` as well | Removes a role. |
| `grantRole(role, account)` | `DEFAULT_ADMIN_ROLE` | Grants a role: operators, guardians and the recovery timelock. |
| `renounceRole(role, account)` | The account itself | OpenZeppelin `AccessControl`. The deployer gives up its admin role this way at hand-over. |
| `hasRole`, `getRoleAdmin`, `paused`, `OPERATOR_ROLE`, `GUARDIAN_ROLE`, `RECOVERY_ROLE`, `DEFAULT_ADMIN_ROLE` | Anyone (read-only) | The state of the roles and the pause. |
| `supportsInterface(id)` | Anyone (read-only) | ERC-165: `IDvPExecutor` and the `AccessControl` interfaces. |

| Error or event | When |
|---|---|
| `DvPSettled(securitiesIntentHash, seller, buyer, securityToken, cashToken, securityAmount, cashAmount, operator)` | Once per settled trade. Each executed leg also emits `IntentExecuted` on its token, with this contract as the executor. In the gated form, who it names as the seller follows the order in which the operator passes the legs ([What it does not do](#limits)). |
| `DvPExecutor_ZeroAddress()` | The constructor got a zero admin or guardian. |
| `DvPExecutor_LegsDoNotMatch()` | The legs do not describe one trade. |
| `DvPExecutor_LegFailed(leg, reason)` | A token refused a leg. |
| `DvPExecutor_CashNotConserved(account, expected, actual)` | ERC-3009 form: the executor or the seller does not end with the required balance. |
| `Paused`, `Unpaused`, `RoleGranted`, `RoleRevoked` | Inherited from OpenZeppelin. |

<a id="why"></a>
## Why it is built this way

- **Both legs or neither.** The executor has no entry point that runs one leg alone, and an intent that states a payment can be run by the executor it names and no other. The [IntentExecutor](IntentExecutor.md) refuses such intents outright.
- **The operator cannot redirect value.** It chooses which signed legs to pair, when to submit and which token addresses to pass. But in the gated form each signature covers the other party, both amounts and both tokens, and the mirror makes them agree. In the ERC-3009 form the nonce commits to the whole securities intent and the security token's address, and the payout goes to the intent's `from`. Each signature is valid on its own token's domain alone.
- **Cash first.** The legs revert together, so the order decides which failure is reported: a trade where both would fail reports the cash leg. In the ERC-3009 form the executor must hold the cash before it can pay the seller.
- **The tokens decide.** Each token stays the single source of truth for its signature, nonce, time window, executor binding and policy. The executor adds the check that the legs describe one trade, atomicity, and in the ERC-3009 form the balance checks.
- **No state, replaceable.** It stores its roles and pause flag, and it does not keep settlement funds. It is a plain contract, and replacing it means deploying a different one and moving the tokens' `EXECUTOR_ROLE`.

<a id="limits"></a>
## What it does not do

- **No matching, pricing, fees or partial fills.** Two parties agree a trade off-chain, and the executor settles exactly that trade, two legs and no more.
- **No list of tokens.** Nothing on-chain says which tokens are genuine. A party who signs a trade that names a counterfeit token loses to it.
- **ERC-3009 is a Draft, and its token is outside the hook.** The executor calls the form of `receiveWithAuthorization` that takes the signature as `bytes`, and that form has to exist on the token and chain it is used with. A blocklisted executor, buyer or seller, or a paused cash token, fails the whole trade.
- **It does not protect the parties' timing.** An operator can hold a signed trade back until the first deadline passes. The parties' controls are short deadlines and cancelling.
- **No way to tell the gated legs apart.** The mirror is symmetric, so an operator can pass the two legs the other way round: each intent still moves only what it signed, but the shares move first, a refused shares leg is reported as `CASH`, the return value is the buyer intent's hash, and `DvPSettled` names the buyer as seller and the cash token as the security token.
- **No sweep.** The executor has no function to move anything sent to it by mistake. A gated token's agent can still take its own token out with `forcedTransfer`.
- **No wallet display of the shares in the ERC-3009 form.** The buyer's wallet shows an opaque nonce, so the buyer relies on its own client to have computed it from the right intent.

<a id="connected"></a>
## Connected to

- [IntentSettledUpgradeable](IntentSettledUpgradeable.md): The token side of each leg: signature, nonce, executor binding and `canExecute`.
- [IntentToken](IntentToken.md): The security token, and the form a gated cash token takes.
- [IntentExecutor](IntentExecutor.md): The executor for intents without a payment.
- [SignedEntry](SignedEntry.md): Uses the same form of ERC-3009 nonce to tie a payment to one entry into a vault.
- [FundHoldersRule](FundHoldersRule.md): The fund-wide investor cap that applies to the securities leg.
- [Where the money sits](../money.md): Where cash and shares are at each step.

<a id="source"></a>
## Source and tests

- Contract: `contracts/intents/DvPExecutor.sol`, interfaces `IDvPExecutor.sol` and `IERC3009.sol`
- Tests: `DvPExecutor.t.sol` (unit tests with mocked tokens; integration tests for both forms, the counterfeit token, fees, deadlines, reentry, and the fund cap across two classes) and `test/nodejs/dvp.test.ts` (trades through the deployed stack). The signing helpers `signGatedTrade`, `sign3009Trade` and `dvpNonce` are in `test/nodejs/fixtures.ts`.

---

Describes the contracts at commit `6ef0d4e` on `erc8473-conformance`.
