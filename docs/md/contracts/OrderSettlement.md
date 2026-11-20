[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Settlement and distribution

# OrderSettlement

Settles signed orders against each other, in whole or in parts, many in one transaction. A maker signs what it gives at most and what it takes at least. An operator submits two orders that cross and how much each gives, and the two amounts move straight between the makers under the allowances they gave.

- **contracts/intents/OrderSettlement.sol**
- immutable, **not a proxy**
- admin after hand-over: **the main timelock**
- not attested: it holds **no role on any token**

<a id="in-one-minute"></a>

> ### In one minute
>
> A maker is a party that signs an order: "I give up to this much of one token, and for all of it I take at least this much of another." The two amounts together are its limit price. The maker also gives this contract an allowance on the token it gives. An operator finds two orders that name each other's tokens, picks how much each maker gives, and submits them as a fill. The contract checks both signatures, that neither order is filled past its amount, and that each maker receives at least its limit for what it gives. Then it moves the first maker's amount to the second maker and the second's to the first. An order can fill in many parts, a batch holds many fills, and if any fill fails the whole batch is undone. The contract holds no role on any token and never holds a token. Each token sees a plain transfer, so its rules judge the two makers as on any transfer.

<a id="order"></a>
## An order

A maker signs an `Order` as EIP-712 typed data on this contract's domain: name `OrderSettlement`, version `1`, the chain id and this contract's address. `orderHash(order)` returns the hash the maker signs. The signature is checked with OpenZeppelin's `SignatureChecker`, so a maker that is a contract signs through ERC-1271.

| Field | Meaning |
|---|---|
| `maker` | Who signs, gives and receives. An order names no other receiver. |
| `giveToken`, `giveId`, `giveAmount` | The token the maker gives, and the most it gives. `giveId` is zero for an ERC-20 and the token id for an ERC-1155. |
| `takeToken`, `takeId`, `takeAmount` | The token the maker takes, and the least it takes for all of `giveAmount`. `takeId` is zero for an ERC-20. |
| `giveIs1155`, `takeIs1155` | True when that side is an ERC-1155. An ERC-721 is not supported. |
| `taker` | The only counterparty allowed, or the zero address for anyone. |
| `allOrNothing` | True when the order fills in one fill for all of `giveAmount`, or not at all. |
| `nonce` | A value the maker chooses. It makes the order unique, and it is what `cancelOrder` spends. |
| `validAfter` | The first moment the order is valid, inclusive. Zero for no lower bound. |
| `deadline` | The last moment the order is valid, inclusive. |

`giveAmount` and `takeAmount` are the maker's limit price. In the tests the seller gives 10 units of a security for at least 500 of cash, and the investor gives 500 of cash for at least 10 units. Nothing in an order says which side is cash: an order names two tokens, and any two can trade.

An order is measured by what it gives. `filled(orderHash)` is the amount of `giveToken` the maker has given so far, and the order is spent when that reaches `giveAmount`, whatever the maker received on the way.

<a id="how"></a>
## How a fill settles

There is one entry point, `settle(fills)`. It is called by an `OPERATOR_ROLE` holder, it is guarded against reentry, and it stops while the contract is paused. A `Fill` is two orders, `first` and `second`, their two signatures, and two amounts: `firstGives`, of the first order's `giveToken`, and `secondGives`, of the second's. A *leg* is one of the two transfers of a fill.

> **Diagram.** One fill of settle. An operator calls the contract with a batch of fills. It checks the role, the pause and each fill's checks, otherwise OrderSettlement_FillRefused with the index, the refusal and which order. It records what the fill gives of both orders in filled. The first leg moves firstGives of the first order's giveToken straight from the first maker to the second maker, otherwise OrderSettlement_TransferFailed with the index, false and the token's reason. The second leg moves secondGives of the second order's giveToken from the second maker to the first maker, otherwise OrderSettlement_TransferFailed with the index, true and the token's reason. Then the contract emits OrderFilled once for each order. Neither amount passes through the contract.
>
> **Each amount goes straight from one maker to the other.** The contract calls `transferFrom` on an ERC-20 and `safeTransferFrom` on an ERC-1155, under the maker's allowance or approval for all. A gated token's hook sees each leg as a TRANSFER. A revert at any step undoes every step before it, and every earlier fill of the batch.

For each fill, in order:

1. **The checks.** The contract runs its own checks, [below](#checks), and reverts at the first that fails with `OrderSettlement_FillRefused(index, refusal, secondOrder)`. No token has been called yet.
2. **What is filled.** `filled[orderHash]` rises by `firstGives` for the first order and by `secondGives` for the second. This is written before either token is called.
3. **The first leg.** `firstGives` of the first order's `giveToken` moves from the first maker to the second maker.
4. **The second leg.** `secondGives` of the second order's `giveToken` moves from the second maker to the first maker.
5. **The events.** `OrderFilled(orderHash, maker, counterparty, given, received)`, once for each order.

For an ERC-20 leg the contract reads the receiver's balance before and after, and reverts with `OrderSettlement_WrongAmountReceived(index, secondLeg, expected, received)` unless it rose by exactly the amount. So a token that keeps a fee on transfers cannot settle here: the maker would get less than its limit (`test_ATokenThatKeepsAFeeIsRefused`). An ERC-1155 leg has no such check.

<a id="checks"></a>
## The checks, in order

`Refusal` is an enum whose members are in the order the checks run. The fill's two amounts come first. Then the three checks on an order's shape run on the first order and then on the second. Then the two checks on the pair. Then the eight checks on an order's state and terms run on the first order, all eight, and then on the second. `secondOrder` in the error is true when the check failed on the second order, and false for the first order or for the fill as a whole.

| `Refusal` | On | When |
|---|---|---|
| `ZERO_AMOUNT` | the fill | `firstGives` or `secondGives` is zero. |
| `EMPTY_ORDER` | each order | Its `giveAmount` or `takeAmount` is zero. |
| `ID_ON_ERC20` | each order | It names a token id other than zero on a side that is not an ERC-1155. |
| `SAME_ASSET` | each order | It gives and takes the same token and id. |
| `SELF_FILL` | the fill | Both orders are one maker's. |
| `DO_NOT_CROSS` | the fill | The two orders do not name each other's assets: each must give what the other takes, by token, id and kind. Another id of the same ERC-1155 is another asset. This check does not look at the prices. |
| `EXPIRED` | each order | The block's time is after its `deadline`. |
| `NOT_YET_VALID` | each order | The block's time is before its `validAfter`. |
| `CANCELLED` | each order | Its maker cancelled its nonce. |
| `WRONG_TAKER` | each order | It names a taker, and the other maker is not it. |
| `BAD_SIGNATURE` | each order | The signature does not verify for the maker and the order as submitted. An order changed after signing fails here (`test_AnOrderChangedAfterSigningIsRefused`). |
| `OVERFILLED` | each order | The fill gives more than `giveAmount` less what the order has filled. |
| `NOT_WHOLE` | each order | It is all or nothing, and the fill does not give exactly `giveAmount`. |
| `BELOW_LIMIT` | each order | Its maker would receive less than its limit for what it gives, [below](#limit). |
| `TOKEN_REFUSES` | a leg | Only `canFill` answers this. In `settle` the token's own error comes back in `OrderSettlement_TransferFailed`. |

Each test of a refusal asks `canFill` first and then expects the same refusal from `settle`, so the two agree on every row but the last (`OrderSettlement_DegenerateFills`, `OrderSettlement_Settle`, `OrderSettlement_Cancel`).

<a id="limit"></a>
## The limit and its rounding

A maker that gives `g` in a fill must receive at least this much, or the fill is refused with `BELOW_LIMIT`:

```
Math.mulDiv(g, takeAmount, giveAmount, Math.Rounding.Ceil)
```

That is the maker's price for `g`, rounded up. The check runs for both orders: the first maker gives `firstGives` and receives `secondGives`, and the second maker the reverse. Rounding is always against the counterparty, so no sequence of small fills pays a maker less than its price. The product is 512 bits wide, so no two amounts overflow it (`test_VeryLargeAmountsDoNotOverflowTheLimit`).

**An example**, from `test_TheLimitIsRoundedAgainstTheCounterparty`. A seller gives 3 for at least 10, which is 3.33 for each one. A buyer gives 12 for at least 3. A fill where the seller gives 1 and receives 3 is refused: the seller's limit for 1 is 10 / 3 rounded up, which is 4. A fill where the seller gives 1 and receives 4 settles. The buyer's side passes too: it gives 4, and its limit for 4 is 4 × 3 / 12, which is 1.

A maker can receive more than its limit. The fuzz test `testFuzz_AnOrderIsNeverFilledPastItsAmountOrBelowItsLimit` fills one order in up to four parts of any size and checks that what the maker gave is at most its amount, and what it received is at least its limit for what it gave.

Two orders can name each other's assets and still have no fill: when the limits do not overlap, every pair of amounts is below one limit or the other.

<a id="parts"></a>
## Partial fills, and all or nothing

- **An order fills in parts.** Each fill adds to `filled[orderHash]`, and a fill that would take the order past `giveAmount` is refused with `OVERFILLED` (`test_AnOrderFillsInPartsUpToItsAmountAndNeverPastIt`).
- **The two orders need not be the same size.** A larger order meets a smaller one and stays open for the rest, which a later fill against another order can take (`test_ALargerOrderStaysOpenForTheRest`).
- **All or nothing.** An order with `allOrNothing` set fills only in a fill that gives exactly its `giveAmount`; any other amount is refused with `NOT_WHOLE` (`test_AnAllOrNothingOrderFillsWholeOrNotAtAll`). The flag is about what the maker gives. What it receives is still bounded by its limit alone.
- **A fill does not spend the nonce.** What stops an order from filling twice is `filled`, kept for the order's hash. The nonce is spent by `cancelOrder` alone.

<a id="batch"></a>
## A batch

`settle` takes an array of fills and runs them in order, in one transaction. A later fill of an order sees what the earlier fills of it filled, so one order can meet several others in one batch (`test_ABatchSettlesEveryFillAndALaterFillSeesTheEarlierOnes`). One fill that fails reverts the whole batch, and the error carries the fill's index (`test_OneFillThatFailsRevertsTheBatchAndNamesItsIndex`). An empty batch does nothing (`test_AnEmptyBatchDoesNothing`). The contract sets no limit on the length of a batch.

Fills are not netted. Each fill makes its own two transfers, even when one maker appears in many fills of the batch.

<a id="cancel"></a>
## Cancelling

A maker calls `cancelOrder(nonce)`. Every order it signed with that nonce fills no further, and what an order filled before stays (`test_ACancelledOrderFillsNoFurtherAndKeepsWhatItFilled`). The call works while the contract is paused (`test_CancellingWorksWhilePaused`). It marks the caller's own nonce, so another account's call does nothing to the maker's order, and a second call for the same nonce reverts with `OrderSettlement_NonceCancelled` (`test_OnlyTheMakerCancelsAndOnlyOnce`). A cancelled nonce costs one bit of storage: bit `nonce & 0xff` of word `nonce >> 8`, kept per maker. Nothing un-cancels a nonce.

**A nonce is not an order.** What is filled is kept for each order's hash, and what is cancelled for each maker's nonce. So two different orders a maker signs with one nonce can both fill, each up to its own amount, and one cancel stops both (`test_TwoOrdersWithOneNonceBothFillAndOneCancelStopsBoth`). A maker that wants one order to replace another signs both with the same nonce and cancels them together. Otherwise it gives each order its own nonce.

Taking the allowance back stops an order too: the token then refuses the maker's leg (`test_WithNoAllowanceTheTokenRefusesAndTheFillNamesTheLeg`). An order nobody fills lapses after its `deadline`.

<a id="token"></a>
## What the token and its rules see

The contract calls `transferFrom(maker, otherMaker, amount)` on an ERC-20 and `safeTransferFrom(maker, otherMaker, id, amount, '')` on an ERC-1155. A gated token builds a TRANSFER from that, with this contract as the operator, and asks its hook as for any transfer by a spender.

- **The rules judge the two makers.** The sender and the receiver of each leg are the makers, and no shipped rule reads the operator. A maker the policy refuses stops the fill (`test_AMakerThePolicyRefusesStopsTheFillWithTheTokensOwnError`). The token's pause and frozen amounts apply as on any transfer.
- **The contract needs no credential.** It never holds a token, so it is never a sender or a receiver. The tests settle through the real [CredentialRule](CredentialRule.md) with no credential for the contract.
- **A token that lists [ExecutedOnlyRule](ExecutedOnlyRule.md) cannot trade here.** That rule refuses every TRANSFER with `KIND_NOT_ALLOWED`, and a leg here is one.
- **[SettlementWindowRule](SettlementWindowRule.md) does not apply here.** It judges EXECUTED movements only. A product that wants signed intents and a window settles through the [DvPExecutor](DvPExecutor.md).
- **The allowance is the maker's.** On an ERC-20 the maker approves this contract for an amount. On an ERC-1155 it sets approval for all, which covers every token id of that contract. Either way the contract moves a maker's tokens only as a signed order of that maker allows.
- **Any gated ERC-20 or ERC-1155 can be a leg.** The tests settle an `IntentToken` against the cash token, shares of a [Gated4626Vault](Gated4626Vault.md) against cash with no change to the vault (`test_SharesOfA4626SettleAgainstCash`), and a series of a [Gated1155](Gated1155.md) against cash in parts (`test_ASeriesOfAGated1155SettlesAgainstCashInParts`).

<a id="errors"></a>
## When a leg fails

`OrderSettlement_TransferFailed(index, secondLeg, reason)` wraps what the token reverted with, so the operator knows which fill and which leg. `secondLeg` is false for the first maker's transfer and true for the second maker's. `reason` is the token's revert data, for example `ERC8473PolicyRejected(reason)` from a gated token's policy, or `ERC20InsufficientAllowance` from a maker that gave no allowance. The first leg runs first, so if both would fail the first is the one reported. A second leg that fails undoes the first.

An ERC-20 leg is a low-level call. A token that returns nothing is taken as done, as OpenZeppelin's `SafeERC20` takes it, and a token that returns anything but `true` fails the leg with what it returned as `reason`.

Not wrapped, so they arrive with their own error:

- The contract's own gates: `ReentrancyGuardReentrantCall`, `AccessControlUnauthorizedAccount`, `EnforcedPause`, in that order.
- `OrderSettlement_FillRefused` and `OrderSettlement_WrongAmountReceived`, which are the contract's own.
- The two reads of the receiver's balance around an ERC-20 leg, which run outside the wrapped call. A token address with no code reverts there with empty revert data.

<a id="preflight"></a>
## What the pre-flight returns

`canFill(fill)` takes one fill and returns `(refusal, secondOrder, tokenReason)`. Anyone can call it. It answers in this order, stopping at the first refusal:

1. **The contract's own checks**, the same code `settle` runs: a `Refusal` and which order, with no token reason.
2. **The first leg's token**, if it has a pre-flight: `TOKEN_REFUSES`, `secondOrder` false, and the token's reason when it gives one.
3. **The second leg's token**, the same way: `TOKEN_REFUSES`, `secondOrder` true.
4. Otherwise `NONE`.

Which pre-flight a token is asked depends on what it answers through ERC-165:

| The leg's token answers | It is asked | What that covers |
|---|---|---|
| `IPolicyGated`, for an ERC-20 leg; `IGated1155`, for an ERC-1155 leg | `canTransferWithReason` | The token's pause, the maker's unfrozen balance and its policy, with a reason code. An amount above the maker's balance reads `INSUFFICIENT_UNFROZEN` (`test_AnAmountAboveTheMakersBalanceReadsRefusedInThePreflight`). |
| Only ERC-7943: `IERC7943Fungible` or `IERC7943MultiToken` | `canTransfer` | A yes or a no with no reason, so `tokenReason` is zero. ERC-7943 does not let this answer no for a balance check alone. |
| Neither | Nothing | Nothing: the leg reads as passing. |

What it cannot see:

- **The operator and the pause.** It checks neither `OPERATOR_ROLE` nor whether this contract is paused.
- **Allowances.** It checks no allowance and no approval for all. A maker that gave none reads as passing, and `settle` reverts on its leg.
- **A token with no pre-flight.** Its balances, its pause and a fee it keeps are not seen.
- **The rest of a batch.** It answers for one fill against what is filled on chain. A later fill of a batch runs after the earlier ones.
- **One leg's effect on the other.** Both legs are asked against the state before either runs.
- **The next block.** A pre-flight answers for the latest block and a write lands in a later one, so at a time boundary the two can differ.

Simulating `settle` itself from the operator's address shows the real outcome.

<a id="operator"></a>
## What the operator can and cannot do

### It chooses

- which orders meet;
- how much each gives in a fill, up to what is left of each order;
- the price, anywhere between the two limits, by the two amounts it submits (`test_TheOperatorChoosesAPriceBetweenTheTwoLimitsAndNoneOutsideThem`);
- when to submit, and whether to submit at all.

### It cannot

- move anything outside a signed order, or change a field of one;
- fill an order past its `giveAmount`;
- give a maker less than its limit for what it gives;
- send anything to anyone but the two makers;
- fill an order after its maker cancelled it, after its deadline, or while the contract is paused.

There is no fee and no receiver but the makers. So whatever lies between two limits goes to one of the two makers, and never to the operator. Which maker gets it is the operator's choice. In that test the seller takes at least 50 of cash for each unit and the buyer pays at most 60: fills at 50, at 55 and at 60 all settle, and a fill whose cash is the smallest amount below the seller's limit or above the buyer's is refused with `BELOW_LIMIT`.

<a id="dvp"></a>
## How it differs from DvPExecutor

Both settle one asset against another in one transaction, with no way to run one side alone. They reach the token by different paths.

|  | [DvPExecutor](DvPExecutor.md) | OrderSettlement |
|---|---|---|
| A party signs | A transfer intent on its token's own domain, or an ERC-3009 authorization for the cash | An order on this contract's domain |
| The token is moved by | `executeTransfer`, which checks the intent itself | `transferFrom` or `safeTransferFrom`, under the maker's allowance or approval for all |
| The rules see | EXECUTED | TRANSFER |
| It needs on the token | `EXECUTOR_ROLE` | No role |
| The security can be | A token with signed intents, an `IntentToken` | An ERC-20 or an ERC-1155 that takes a plain transfer and moves exactly the amount |
| Amounts | Exactly the trade both parties signed, once | Any part of an order, up to its amount |
| Price | Fixed by the two signatures | Chosen by the operator between the two signed limits |
| One transaction holds | One trade | A batch of fills |
| A token with `ExecutedOnlyRule` | Can trade | Cannot trade |
| `SettlementWindowRule` | Applies to each executed leg | Does not apply |
| A reference on chain | The intent's `ref`, in `IntentExecuted` | None: an order has no reference field |

<a id="roles"></a>
## Roles, pause and reentry

- **OPERATOR_ROLE**: Submits fills. Deployed: the account passed as `operator` to the hand-over, the same as on the other two executors.
- **GUARDIAN_ROLE**: Pauses with no delay. Deployed: the guardian multisig, from the constructor.
- **DEFAULT_ADMIN_ROLE**: Grants roles and unpauses. Deployed: the deployer until the hand-over, then the main timelock.
- **RECOVERY_ROLE**: `unpause()` and revoking `GUARDIAN_ROLE`, and nothing else (`test_RecoveryRevokesTheGuardianAndNoOtherRole`). Deployed: the recovery timelock.

The contract holds no role on any token, and no product grants it one. A profile asks for it with the flag `orderSettlement`, and `Core` then deploys one, under the part key `orderSettlement`, with the deployer as admin and the guardian. `CoreHandover` grants the operator and the recovery timelock their roles and hands the admin role to the main timelock, as for the other two executors. None of the profiles in `ignition/profiles.ts` sets the flag. For a core built without it, `CoreParts` adds it alone and `PartsHandover` hands it over the same way, which `test/nodejs/products.test.ts` does on a running `cash` core.

Pausing stops `settle` without touching the tokens. `cancelOrder` and `canFill` still work. `settle` carries OpenZeppelin's reentrancy guard, which keeps its flag in storage, and what a fill gives is recorded before either token is called, so a token that calls back cannot fill an order twice. The read-only functions and `cancelOrder` are unguarded.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `settle(fills)` | `OPERATOR_ROLE`, while not paused | Settles the fills in order, atomically. For each: the checks, what both orders have filled, the two legs, two `OrderFilled` events. |
| `cancelOrder(nonce)` | Anyone, for its own nonce, also while paused | Cancels every order the caller signed with that nonce and emits `OrderCancelled`. Reverts with `OrderSettlement_NonceCancelled` if already cancelled. |
| `canFill(fill)` | Anyone (read-only) | Pre-flight for one fill: `(refusal, secondOrder, tokenReason)`. |
| `orderHash(order)` | Anyone (read-only) | The EIP-712 hash a maker signs. |
| `filled(orderHash)` | Anyone (read-only) | How much of its `giveToken` an order has given so far. |
| `nonceCancelled(maker, nonce)` | Anyone (read-only) | Whether a maker cancelled a nonce. |
| `pause()` | `GUARDIAN_ROLE` | Stops `settle`. Reverts with `EnforcedPause` if already paused. |
| `unpause()` | `DEFAULT_ADMIN_ROLE` or `RECOVERY_ROLE` | Resumes settlement. Anyone else gets `AccessControlUnauthorizedAccount(caller, DEFAULT_ADMIN_ROLE)`. Reverts with `ExpectedPause` if not paused. |
| `revokeRole(role, account)` | The role's admin; `RECOVERY_ROLE` for `GUARDIAN_ROLE` as well | Removes a role. |
| `grantRole(role, account)` | `DEFAULT_ADMIN_ROLE` | Grants a role: operators, guardians and the recovery timelock. |
| `renounceRole(role, account)` | The account itself | OpenZeppelin `AccessControl`. The deployer gives up its admin role this way at hand-over. |
| `hasRole`, `getRoleAdmin`, `paused`, `eip712Domain`, `OPERATOR_ROLE`, `GUARDIAN_ROLE`, `RECOVERY_ROLE`, `DEFAULT_ADMIN_ROLE` | Anyone (read-only) | The state of the roles and the pause, and the signing domain. |
| `supportsInterface(id)` | Anyone (read-only) | ERC-165: `IOrderSettlement` and the `AccessControl` interfaces. |

| Error or event | When |
|---|---|
| `OrderFilled(orderHash, maker, counterparty, given, received)` | Twice per settled fill, once for each order, after both legs. |
| `OrderCancelled(maker, nonce)` | A maker cancelled a nonce. |
| `OrderSettlement_FillRefused(index, refusal, secondOrder)` | A fill failed one of the contract's own checks. |
| `OrderSettlement_TransferFailed(index, secondLeg, reason)` | A token refused a leg. |
| `OrderSettlement_WrongAmountReceived(index, secondLeg, expected, received)` | An ERC-20 leg did not raise the receiver's balance by exactly the amount. |
| `OrderSettlement_NonceCancelled()` | `cancelOrder` for a nonce the caller already cancelled. |
| `OrderSettlement_ZeroAddress()` | The constructor got a zero admin or guardian. |
| `Paused`, `Unpaused`, `RoleGranted`, `RoleRevoked` | Inherited from OpenZeppelin. |

<a id="why"></a>
## Why it is built this way

- **No role on the token.** The contract can move only what a maker both approved and signed for. A token's admin grants it nothing, so a token needs no change to trade here, and an intent token that should not trade here lists `ExecutedOnlyRule`.
- **The maker receives at its own address.** A third-party receiver would have to be judged by the token's policy, and this contract holds no policy.
- **The operator sets the price, inside both limits.** The contract cannot know which order was there first, so it cannot give the older order its price. With no fee and no other receiver, the difference stays with the makers.
- **Refused before the tokens are called.** A fill of nothing, an empty order, one maker on both sides and an order that gives what it takes are refused by name, and not later by a token with an error that says less.
- **Filled by hash, cancelled by nonce.** An order that fills in parts needs a running total, which is kept for its hash. A cancel needs one bit.
- **Little state, replaceable.** It stores its roles, its pause flag, what each order has filled and the nonces makers cancelled. It is a plain contract, and replacing it means deploying another and having makers approve and sign for that one.

<a id="limits"></a>
## What it does not do

- **No matching.** It keeps no book and finds no counterparty. The operator matches orders off-chain and submits fills.
- **No fee.** A fill is two transfers between two makers. Nothing goes to the operator or to a venue.
- **No third-party receiver.** Each maker receives at the address that signed.
- **No ERC-721.** An order names an ERC-20 or an ERC-1155 on each side.
- **No netting.** A maker in many fills of a batch makes and receives a transfer in each.
- **No token that keeps a fee.** An ERC-20 leg must raise the receiver's balance by exactly the amount.
- **No best price.** The operator picks the price within the two limits, and which maker gets the difference. A maker's protection is its own limit.
- **It does not bound the allowance.** An allowance, or an approval for all on an ERC-1155, is what the maker trusts this contract with. The contract uses it only as the maker's signed orders allow, so the orders a maker has signed and not cancelled are the bound.
- **It does not protect the makers' timing.** An operator can hold an order back until its deadline passes, or fill it late in its window. The maker's controls are a short deadline, `validAfter` and cancelling.
- **No list of tokens.** Nothing on-chain says which tokens are genuine. A maker who signs an order that names a counterfeit token can be paid in it.
- **No settlement window and no reference.** A product that needs either settles signed intents through the [DvPExecutor](DvPExecutor.md).

<a id="connected"></a>
## Connected to

- [DvPExecutor](DvPExecutor.md): Settles one trade from two signed intents, as executed movements.
- [IntentExecutor](IntentExecutor.md): The executor for intents without a payment, governed the same way.
- [ExecutedOnlyRule](ExecutedOnlyRule.md): A token that lists it refuses every leg here.
- [Gated1155](Gated1155.md): A series of it can be a leg, by token id.
- [Gated4626Vault](Gated4626Vault.md): Its shares are an ERC-20 and trade here against cash.
- [Who can do what](../roles.md): The operator, the guardian and the two timelocks on each executor.

<a id="source"></a>
## Source and tests

- Contract: `contracts/intents/OrderSettlement.sol`, interface `IOrderSettlement.sol`
- Tests: `OrderSettlement.t.sol` (the real contract on real tokens behind the credential registry, the rule and the hook: fills in whole and in parts, each refusal, cancelling, the roles and the pause, a refused maker, a fee-taking token, vault shares, a multi-token series, batches, and the fuzzed limit) and `test/nodejs/products.test.ts` (added to a running core, handed over, and an order's hash checked against viem's). The EIP-712 type `ORDER_TYPES` is in `test/nodejs/fixtures.ts`.
