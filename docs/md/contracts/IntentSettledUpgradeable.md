[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Token

# IntentSettledUpgradeable

Lets a holder authorise a transfer by signing a message instead of sending a transaction. An approved executor submits the signed message, and the token checks it, field by field, before the transfer goes through the same compliance checks as any other.

- **contracts/mixins/IntentSettledUpgradeable.sol**
- abstract mixin, **used by IntentToken**
- role: **EXECUTOR_ROLE**, administered by the main timelock
- attested as part of the **IntentToken implementation**

<a id="in-one-minute"></a>

> ### In one minute
>
> An **intent** is a transfer instruction the holder signs with their key: "send this amount to that account, between these times". Signing costs nothing and needs no transaction. The issuer's settlement system then submits it through an **executor**, an account the token has authorised, at the time it chooses.
>
> The token checks that the intent is in date, has not been used or cancelled, is submitted by the executor it names, pays someone, and carries the holder's valid signature. Then the transfer runs through the policy hook like any other movement, labelled EXECUTED. The executor cannot change a field: any change breaks the signature. Until it runs, the holder can cancel it.

<a id="how"></a>
## How an intent is settled

In the deployment four parties take part. The holder signs. An operator key (an issuer or relayer key with `OPERATOR_ROLE` on the executor) submits. The executor contract holds the token's `EXECUTOR_ROLE` and calls the token. The token runs the checks and asks the hook.

> **Diagram.** Sequence of a signed intent. The holder signs the intent off-chain with EIP-712 and hands the intent and signature to the operator key. The operator may first ask the token canExecute, naming the executor, and gets true or a reason code. The operator calls execute on the IntentExecutor, which checks its operator role, that it is not paused and that the intent states no consideration, then calls executeTransfer on the token. The token runs its checks and marks the nonce used, asks the hook checkTransfer with kind EXECUTED, gets TRANSFER_OK, moves the balances, calls afterTransfer if the hook wants it, and returns the intent hash with the event IntentExecuted. The executor returns the intent hash to the operator.
>
> **The holder signs once; the token checks everything.** Dashed lines are off-chain hand-overs, read-only calls and returns. `afterTransfer` runs if the hook asks for it. The executor passes the intent on unchanged; its own check is that the intent states no payment, which it could not enforce.

1. **Sign.** The holder's wallet signs the intent as EIP-712 typed data, structured data the wallet can show field by field. `intentHash(intent)` returns the digest the token expects.
2. **Optional pre-flight.** `canExecute(intent, sig, executor)` runs the same checks without writing, as they would run from the account it names, whoever asks.
3. **Submit.** The operator calls `execute(token, intent, sig)` on the [`IntentExecutor`](IntentExecutor.md). It checks its own `OPERATOR_ROLE` and pause, refuses an intent that states a consideration (`IntentExecutor_ConsiderationNotSupported`), and calls `executeTransfer`.
4. **Check and move.** The token runs the checks below, marks the nonce used, and moves the tokens as EXECUTED through the base's one movement path, where the pause, the unfrozen balance and the hook decide.
5. **Record.** The token emits `IntentExecuted(intentHash, from, to, amount, executor, ref)`, where `executor` is the account that called the token, and returns the intent hash.

<a id="order"></a>
## The checks, in order

`executeTransfer` and `canExecute` run the same checks in the same order, and the first one that fails decides the answer. The tests pin most of the order pair by pair (`IntentSettledUnit_CheckOrder`); the deadline against the nonce and the place of `ZERO_RECEIVER` have no such test. `test_WhenAnyIntentIsChecked_CanExecuteAgreesWithExecuteTransfer` fuzzes that `canExecute` returns the reason `executeTransfer` reverts with, or success when it succeeds.

> **Diagram.** The checks of executeTransfer in order. 0: the caller must hold EXECUTOR_ROLE, or AccessControlUnauthorizedAccount. 1: after the deadline gives INTENT_EXPIRED. 2: a used or cancelled nonce gives NONCE_USED. 3: a stated consideration with no executor named gives CONSIDERATION_NEEDS_EXECUTOR. 4: a named executor that is not the caller gives WRONG_EXECUTOR. 5: before validAfter gives INTENT_NOT_YET_VALID. 6: a zero receiver gives ZERO_RECEIVER. 7: a signature that is not valid for from gives BAD_SIGNATURE. 8: the nonce is marked used. 9: the tokens move as EXECUTED through \_moveAs and \_move, with the pause, unfrozen balance and hook checks, which can give PAUSED, a balance error or a rule's reason. Then IntentExecuted is emitted and the intent hash returned.
>
> **Message checks first, then the policy.** Checks 1 to 7, and the pause and the hook in step 9, revert with `ERC8473PolicyRejected(reason)` carrying the code in the red box. `canExecute` returns the same codes without reverting. At step 0 it answers `NOT_EXECUTOR` when the account it names lacks the role, and at step 8 it writes nothing.

- **The role comes first in both.** A caller without the role gets the access error whatever else is wrong (`test_WhenTheCallerLacksTheRole_TheRoleCheckComesFirst`), and `canExecute` says `NOT_EXECUTOR` before it looks at anything else (`test_TheRoleIsCheckedBeforeEverythingElseAsInTheCall`).
- **Times are inclusive.** The intent can run at the exact second of `deadline` and at the exact second of `validAfter` (`test_WhenDeadlineIsNow_ItExecutes`, `test_WhenValidAfterIsNow_ItExecutes`). An intent whose `validAfter` is later than its `deadline` does not run at any time (`test_WhenTheWindowIsEmpty_ItNeverExecutes`).
- **Step 9 is the ordinary movement path.** An amount within the balance but above the unfrozen part reverts with `ERC7943InsufficientUnfrozenBalance`, an amount above the balance with `ERC20InsufficientBalance`. `canExecute` answers `INSUFFICIENT_UNFROZEN` for both (`test_WhenTheSenderIsFrozen_TheIntentFailsAndPreflightAgrees`, `test_WhenTheAmountExceedsTheBalance_TheIntentRevertsWithTheBaseErrorAndPreflightAgrees`). It makes no `canTransfer`-style exception for a balance shortfall.
- **A revert keeps the nonce.** Marking the nonce in step 8 is undone with everything else when step 9 fails (`test_WhenHookRejects_ItRevertsAndKeepsTheNonceUnused`). An intent refused because the settlement window is closed can be submitted again once it opens, until its deadline.

<a id="intent"></a>
## What the holder signs

A `TransferIntent` has ten fields, all fixed-size, signed as EIP-712 typed data with this type string (`TRANSFER_INTENT_TYPEHASH` is its `keccak256`):

```
TransferIntent(address from,address to,uint256 amount,bytes32 nonce,uint256 deadline,bytes32 ref,address executor,uint256 validAfter,address considerationToken,uint256 considerationAmount)
```

| Field | Meaning |
|---|---|
| `from` | The holder: the signer and the sender of the tokens. |
| `to` | The receiver. |
| `amount` | The number of tokens to move. An intent moves this amount or nothing. |
| `nonce` | 32 random bytes the signer chooses. Each value works once for that signer. |
| `deadline` | The last second at which the intent can run. |
| `ref` | A 32-byte reference to an off-chain message, such as the hash of an ISO 20022 message id. It appears in the `IntentExecuted` event and in the context the rules receive. None of the shipped rules reads it, and the token does not check that it is unique. |
| `executor` | The one account allowed to submit it. Zero means any holder of `EXECUTOR_ROLE`. |
| `validAfter` | The first second at which the intent can run. Zero means no lower bound. |
| `considerationToken`, `considerationAmount` | What the signer is to receive in return for this leg. They are signed, so nobody can change them. The token does not check the payment itself: the executor the intent names is the one that can enforce it. |

**The domain** ties a signature to one token on one chain: name is the token's name, version is `"1"`, then the chain id and the token's address (the proxy). It is the same domain as ERC-2612 `permit` on the same token, and the token reports it through `eip712Domain()` (ERC-5267). A signature made for another chain or another token fails with `BAD_SIGNATURE` (`test_WhenSignedForAnotherChain_ItRevertsWithBadSignature`, `test_WhenSignedForAnotherToken_ItRevertsWithBadSignature`).

<a id="nonces"></a>
## Nonces and cancelling

A **nonce** here is a random 32-byte value that makes each intent unique, in the style of ERC-3009. The token keeps one used-or-not flag per signer and nonce, and nothing else. Because nonces are random rather than counted, the signer needs nothing from the chain to sign, can sign many intents at once, and the executor can run them in any order.

- Executing an intent marks its nonce used, so the same intent does not run twice (`NONCE_USED`; `check_executedIntentCannotReplay`).
- `cancelIntent(nonce)` marks one of the caller's own nonces used, so no intent that account signed with it can run. It needs no other field, works while the token is paused, and emits `IntentCancelled(from, nonce)`. Cancelling a nonce that is already used reverts with `ERC8473PolicyRejected(NONCE_USED)`. An account that cancels a value has no effect on another signer's nonce of the same value (`test_WhenAnotherAccountCancels_ItDoesNotAffectTheSigner`).
- A cancel and an execution race: whichever transaction is mined first wins. A used nonce stays used, and nothing undoes an execution.
- `nonceUsed(signer, nonce)` tells whether a nonce is spent. These nonces are separate from the counter `nonces(owner)` that `permit` uses.

<a id="executor"></a>
## Naming an executor, and stating a payment

Several accounts may hold `EXECUTOR_ROLE` on one token. A product names which get it. The two executor contracts are the [`IntentExecutor`](IntentExecutor.md), which forwards intents one by one or in batches, and the [`DvPExecutor`](DvPExecutor.md), which settles a share trade against cash in one transaction. Two fields let the holder control which one runs the intent:

| `executor` | Consideration (token or amount) | Result |
|---|---|---|
| zero | none | Any `EXECUTOR_ROLE` holder may run it. |
| zero | stated | Refused from every caller: `CONSIDERATION_NEEDS_EXECUTOR`. |
| an address | none or stated | Runs when that address calls the token and holds the role. Any other role holder gets `WRONG_EXECUTOR`. |

The token reads the consideration fields for that check and for nothing else, and they never reach the hook (`test_WhenConsiderationIsSetWithAnExecutor_ItExecutesAndTheHookSeesNoConsideration`). It moves one token and cannot see a second leg, so it cannot tell whether the payment happened. An intent that states a payment therefore has to name the executor that will enforce it; otherwise any executor could run it and deliver the tokens without the payment.

The `IntentExecutor` moves one token too, so it refuses every intent that states a consideration, whoever the intent names, with `IntentExecutor_ConsiderationNotSupported(index)`. The `DvPExecutor` checks that the two legs describe one trade and runs them together, so the delivery and the payment happen in the same transaction or not at all. An intent that states a payment and names some other account gets exactly what that account's code does, which is why a signer should check which contract the `executor` field names.

<a id="signature"></a>
## Signature checks

The token uses OpenZeppelin's `SignatureChecker`, which chooses the method by whether `from` has code:

- **No code (an ordinary key):** the 65-byte signature is recovered with ECDSA. The low-`s` form is the one accepted, so a valid signature cannot be rewritten into a second valid one (`test_WhenSignatureIsMalleatedToHighS_ItRevertsWithBadSignature`).
- **Code (a contract wallet):** the token asks the wallet with ERC-1271 `isValidSignature(hash, signature)`. That also covers an ordinary key with an EIP-7702 delegation, which has code; its wallet code must answer ERC-1271, or its intents fail with `BAD_SIGNATURE`.

A change to any field, by the executor or anyone else, changes the digest and fails the check (`test_WhenTheExecutorAltersTheIntent_ItRevertsWithBadSignature`).

<a id="executed"></a>
## What the rules see

The mixin moves the tokens with the base's `_moveAs(from, to, amount, EXECUTED, ref, deadline)`, which passes the kind to the one movement path. The hook receives:

| Field | Value for an executed intent |
|---|---|
| `kind` | EXECUTED |
| `from`, `to`, `amount` | From the intent. |
| `operator` | The account that called `executeTransfer`: the executor, not the holder. In `canExecute`, the account it names (`test_TheRulesSeeTheNamedAccountAsTheOperator`). |
| `data` | `abi.encode(fromBalance, toBalance, ref, deadline)`: the two balances before the move, then the intent's reference and deadline. Rules that read the balances decode the first two words. |

Among the shipped rules, [`SettlementWindowRule`](SettlementWindowRule.md) judges this kind and no other: an executed intent passes inside the token's daily window, on its enabled weekdays. [`ExecutedOnlyRule`](ExecutedOnlyRule.md) looks at the same field from the other side: it refuses a plain transfer, so that movements between holders go through signed intents.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `executeTransfer(intent, sig)` | `EXECUTOR_ROLE` | Runs the checks, marks the nonce used, moves the tokens as EXECUTED, emits `IntentExecuted`, returns the intent hash. |
| `canExecute(intent, sig, executor)` | Anyone (read-only) | Returns `(ok, reason)` for the same checks in the same order, as they would run from `executor`. The answer does not depend on who asks (`test_TheAnswerDoesNotDependOnWhoAsks`). |
| `cancelIntent(nonce)` | Anyone, for their own nonces | Marks the nonce used. Emits `IntentCancelled`. |
| `intentHash(intent)` | Anyone (read-only) | The EIP-712 digest the holder signs. |
| `nonceUsed(signer, nonce)` | Anyone (read-only) | Whether the nonce is used or cancelled. |
| `EXECUTOR_ROLE()`, `TRANSFER_INTENT_TYPEHASH()` | Anyone (read-only) | The role id and the type hash. |
| `supportsInterface(interfaceId)` | Anyone (read-only) | Adds `ITransferIntent` to what the base reports. |

| Event or error | When |
|---|---|
| `IntentExecuted(intentHash, from, to, amount, executor, ref)` | After the balances have moved and the hook's `afterTransfer` has run. |
| `IntentCancelled(from, nonce)` | A signer cancels a nonce. |
| `ERC8473PolicyRejected(reason)` | Any check above that carries a reason code: `INTENT_EXPIRED`, `NONCE_USED`, `CONSIDERATION_NEEDS_EXECUTOR`, `WRONG_EXECUTOR`, `INTENT_NOT_YET_VALID`, `ZERO_RECEIVER`, `BAD_SIGNATURE`, `PAUSED`, a rule's reason, or `CHECK_UNAVAILABLE` when the hook cannot be asked. `NOT_EXECUTOR` is `canExecute`'s answer; the write reverts with the access error instead. |
| `AccessControlUnauthorizedAccount` | `executeTransfer` from an account without the role. |
| `ERC7943InsufficientUnfrozenBalance`, `ERC20InsufficientBalance` | The amount does not fit, as in any movement. |

`EXECUTOR_ROLE` is granted and revoked by `DEFAULT_ADMIN_ROLE`, the main timelock after hand-over, like every role on the token. Everything else on the token comes from [the base](PolicyGatedERC20Upgradeable.md#functions).

<a id="why"></a>
## Why it is built this way

- **The holder keeps the keys; the issuer keeps the timing.** The holder authorises once, off-chain, and pays no gas. Settlement happens when the executor runs the intent, not when it is signed.
- **The executor can run it or not.** Every field is inside the signed digest, so there is nothing an executor can adjust.
- **Message checks live in the mixin, policy lives in the hook.** Deadline, nonce, executor, payment field, start time, receiver and signature are facts about the signed message, not decisions about who may hold the token, so they are not rules. Once the message is sound, the movement takes the same path as every other and the same rules decide.
- **Binding stops a leg from running alone.** An intent written for a delivery-versus-payment trade names the DvP executor, so no other executor can deliver its tokens without the cash leg (`check_intentNamingAnotherExecutorNeverExecutes`).
- **The pre-flight names the caller.** `canExecute` takes the account that would call, so a relayer or a monitor can ask from any address and get the answer for that executor. It reuses the private check function and the base's checks.
- **No state beyond nonces.** The mixin stores the used-nonce flags and nothing else, in its own ERC-7201 namespace (`gated.storage.IntentSettled`). Executors hold no intents and no nonces, so there are none to move when one is replaced. An intent that names the replaced executor does not run from its successor (`WRONG_EXECUTOR`), so its holder signs a fresh one; an intent that names no executor can run from the successor.

<a id="limits"></a>
## What it does not do

- **It does not enforce a stated payment.** It hashes the consideration fields into the digest and rejects them without a named executor. Whether the payment happens is up to the executor's code.
- **It is not the only way to move the token.** A holder can still use `transfer`, and a window rule that judges EXECUTED does not bind it, unless the token also lists `ExecutedOnlyRule`.
- **Signing reserves nothing.** The token does not know an intent exists until it is submitted. The balance can change meanwhile, and the intent then fails on the amount or the rules.
- **It does not limit when within its dates an intent runs.** The executor chooses the moment and the order. A short `deadline` is the holder's control, and cancelling takes a transaction from the signer (for a contract wallet, the wallet's own call).
- **`canExecute` does not see the executor contract.** It answers for the token alone: not the executor's `OPERATOR_ROLE`, its pause, or its refusal of a stated consideration.
- **`canExecute` answers for the latest block,** and a write lands in the next one, so at a deadline or a `validAfter` they can differ by one second (`test/nodejs/time.test.ts`). A contract wallet's ERC-1271 answer can also change between the two.
- **It does not limit who holds the role.** `EXECUTOR_ROLE` can be granted to any account by the token's admin. The post-deploy check confirms that the executors a product names hold it and that none of the deployment's wallets does. It does not ask about an executor the product does not name.

<a id="connected"></a>
## Connected to

- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): The base whose one movement path settles every intent.
- [IntentToken](IntentToken.md): The template that includes this mixin.
- [IntentExecutor](IntentExecutor.md): Submits intents one by one or in atomic batches, and refuses stated payments.
- [DvPExecutor](DvPExecutor.md): Settles a share trade against its payment in one transaction.
- [SettlementWindowRule](SettlementWindowRule.md): The rule that limits executed intents to settlement hours.
- [ExecutedOnlyRule](ExecutedOnlyRule.md): The rule that makes signed intents the way holders move a token.
- [One movement](../movement.md): The full path of a movement through the token and its rules.

<a id="source"></a>
## Source and tests

- Contract: `contracts/mixins/IntentSettledUpgradeable.sol`, interface `ITransferIntent.sol`
- Unit tests: `IntentSettledUpgradeable.t.sol` (replay, expiry, wrong chain or token, high-`s` malleability, ERC-1271 wallets, executor binding, start time, consideration, the check order, cancelling, and `canExecute` parity)
- Integration: `IntentToken.t.sol` (real registry and hook), `test/nodejs/intents.test.ts` (a real wallet's `signTypedData` settling through the executor), `test/nodejs/time.test.ts` (inclusive times), and the Halmos properties in `IntentTokenHalmos.t.sol`: `check_executedIntentCannotReplay`, `check_cancelledNonceNeverExecutes`, `check_intentNamingAnotherExecutorNeverExecutes`, `check_considerationWithoutExecutorNeverExecutes`
