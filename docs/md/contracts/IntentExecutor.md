[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Settlement and distribution

# IntentExecutor

The contract an operator uses to put holders' signed transfer instructions on-chain. It adds one check of its own, then hands each instruction to the token unchanged and lets the token decide.

- **contracts/intents/IntentExecutor.sol**
- immutable, **not a proxy**
- admin after hand-over: **the main timelock**
- not attested: a token trusts it by granting **EXECUTOR_ROLE**

<a id="in-one-minute"></a>

> ### In one minute
>
> A holder can sign a transfer instruction, called an intent, without sending a transaction or paying gas: who receives, how much, until when, and a single-use number (the nonce). Someone else has to submit it, and on an [IntentToken](IntentToken.md) that someone must hold `EXECUTOR_ROLE`. This contract is built to hold that role. The issuer's or a relayer's keys hold `OPERATOR_ROLE` here and call it, and it forwards each intent to the token without changing it. Its one check is that the intent does not say the signer is to be paid something in return, because this contract cannot make a payment happen. Operators can submit one intent, or a batch that settles all or nothing. The guardian can stop it at once.

<a id="how"></a>
## How an intent is executed

The operator calls `execute(token, intent, sig)`. The executor checks its own conditions and forwards the call. Everything about the intent itself is checked by the token, which runs the transfer through its compliance hook as an EXECUTED movement.

> **Diagram.** The holder signs an intent off-chain and gives it to the operator. The operator calls execute on the IntentExecutor. The executor checks that the caller holds OPERATOR_ROLE, that it is not paused, and that the intent states no consideration, otherwise it reverts. It forwards the same intent to the token with executeTransfer. The token checks, in order, the caller's EXECUTOR_ROLE, the deadline, the nonce, a stated consideration and the named executor, validAfter, a zero receiver and the holder's signature, then marks the nonce used. It asks the hook with checkTransfer, kind EXECUTED; the hook answers TRANSFER_OK or the token reverts. Balances move, afterTransfer runs on the hook, IntentExecuted is emitted, and the intent hash returns to the executor and the operator.
>
> **The executor forwards; the token decides.** A revert anywhere undoes the whole call, the nonce write included, so a refused intent can be submitted again once whatever refused it has changed, until its deadline. `execute` passes the token's revert data through unchanged, for example `ERC8473PolicyRejected(reason)`.

1. **Executor checks.** The caller holds `OPERATOR_ROLE` (`AccessControlUnauthorizedAccount`), the executor is not paused (`EnforcedPause`), and the intent states no consideration (`IntentExecutor_ConsiderationNotSupported(0)`). The role check comes first. If any of these fails, the token is not called.
2. **Token checks.** `executeTransfer` requires `EXECUTOR_ROLE` on its caller, then checks in this order: the deadline (`INTENT_EXPIRED`), the nonce (`NONCE_USED`), that a stated consideration names an executor (`CONSIDERATION_NEEDS_EXECUTOR`), that a named executor is the caller (`WRONG_EXECUTOR`), `validAfter` (`INTENT_NOT_YET_VALID`), that the receiver is not the zero address (`ZERO_RECEIVER`), and the signature (`BAD_SIGNATURE`). Each of those reason codes reaches the operator inside `ERC8473PolicyRejected(reason)`.
3. **Policy.** The movement goes through the token's pause and frozen-balance checks and its hook as EXECUTED, so the rules the token lists apply to it, and [SettlementWindowRule](SettlementWindowRule.md), which judges this kind alone, applies if listed ([One movement](../movement.md)).
4. **Record.** The token emits `IntentExecuted(intentHash, from, to, amount, executor, ref)`, where `executor` is the account that called the token: this contract's address.

<a id="consideration"></a>
## Why it refuses an intent that states a payment

An intent has two fields, `considerationToken` and `considerationAmount`, for what the signer is to receive in return. The holder signs them, so they appear in the message the wallet shows. The token does not enforce them: it reads them to require that an intent stating one names the executor allowed to run it. Enforcing the payment is left to the named executor.

This executor moves one token and nothing else, so it cannot pay anyone. If it ran such an intent, the shares would move and the payment the holder read in the message would not happen. A signer who read the payment and did not check which contract the `executor` field names would have no warning. So it refuses an intent with a non-zero consideration token or a non-zero amount, whoever the intent names, before calling the token. A trade with a payment goes through the [DvPExecutor](DvPExecutor.md), which moves both sides.

The refusal holds at two layers. This executor refuses before the token is called. And the token refuses such an intent from an executor other than the one it names (`WRONG_EXECUTOR`), or from every executor if it names none (`CONSIDERATION_NEEDS_EXECUTOR`).

<a id="batch"></a>
## Batches: all or nothing

`executeBatch(token, intents, sigs)` runs the intents in array order inside one transaction. The first one that fails reverts the batch and names its position, carrying the token's revert data inside.

> **Diagram.** A batch of three intents. Intent 0 settles, intent 1 is refused by the token, intent 2 is not reached. The batch reverts with IntentExecutor_BatchItemFailed(1, reason), so intent 0 is undone and its nonce stays unused. The operator then drops intent 1 and resubmits intents 0 and 2, which both settle.
>
> **A batch is one accounting event.** It settles every intent or none. The error names the failing position so the operator can drop it and submit the rest again. The dropped intent's nonce is still unused, so it can be resubmitted later.

- The arrays must have the same length (`IntentExecutor_LengthMismatch(intents, sigs)`). An empty batch returns nothing and calls nothing.
- The consideration check runs on each intent just before it is submitted. An intent that states one reverts the batch with `IntentExecutor_ConsiderationNotSupported(i)`, and that revert undoes the intents forwarded before it.
- Intents run in order, so an earlier intent can change what a later one sees: a balance, a minimum position, or a fund's investor count.
- A batch is for one token. Several tokens need several calls.

When a batch cannot name the index.IntentExecutor_BatchItemFailed(i, reason) wraps a revert from the token, which is what the try can catch. A token that returns normally but with too little data to read as a bytes32 fails differently: the decoding fails inside the executor, outside the catch, and the batch reverts with empty revert data, so no index and no reason reach the operator. A token address with no code does the same. The batch is still atomic, so nothing moves and earlier intents are undone. An IntentToken returns a proper hash, so this comes up with a token that is not built from this stack.

<a id="preflight"></a>
## Checking before submitting

The executor has no pre-flight function of its own. An operator asks the token: `canExecute(intent, sig, executor)`, with this contract's address as `executor`, returns `(ok, reason)` and answers for that account whoever is asking. It says `NOT_EXECUTOR` first if the account lacks `EXECUTOR_ROLE` on the token, then runs the same checks as `executeTransfer`, the signature and the hook included. Asked about another holder of the role, an intent that names this executor reads `WRONG_EXECUTOR`.

The token's pre-flight cannot see what belongs to the executor: `OPERATOR_ROLE`, the executor's pause, and the consideration refusal. An intent that names this executor and states a payment reads `(true, TRANSFER_OK)` from the token, and `execute` then refuses it. Calling `execute` as a simulation from the operator's address shows the real outcome.

<a id="pause"></a>
## Pause and recovery

The guardian pauses the executor with no delay, and both `execute` and `executeBatch` stop. Pausing it stops this route and nothing else. The token itself is not paused, and another holder of `EXECUTOR_ROLE` on the token keeps working. The token has its own pause, which stops every movement except a forced one. On a token that lists [ExecutedOnlyRule](ExecutedOnlyRule.md), where a plain `transfer` is refused, pausing the token's one executor stops holders' transfers on it.

The guardian cannot unpause. Unpausing takes `DEFAULT_ADMIN_ROLE` (the main timelock) or `RECOVERY_ROLE` (the recovery timelock), each after its delay. `RECOVERY_ROLE` allows exactly two things here: `unpause()` and revoking `GUARDIAN_ROLE`. It cannot grant a role, or revoke another one ([GovernanceTimelock](GovernanceTimelock.md)).

<a id="deployed"></a>
## As deployed

The executor is deployed only when a product in the profile names it. Of the profiles in `ignition/profiles.ts`, `full` and `intent` do, each on its intent token. For a core built without it, `CoreParts` adds it and `PartsHandover` grants its roles and hands it to the main timelock, as `CoreHandover` does.

- **Created by**: `Core`, as `IntentExecutor(deployer, guardian)`
- **OPERATOR_ROLE**: The account passed as `operator` to `CoreHandover`, the same as on the DvP executor
- **GUARDIAN_ROLE**: The guardian multisig, from the constructor
- **RECOVERY_ROLE**: The recovery timelock, granted in `CoreHandover`
- **DEFAULT_ADMIN_ROLE**: The main timelock; the deployer renounces at the end of `CoreHandover`
- **EXECUTOR_ROLE**: Held on each `IntentToken` whose product lists it under `executors`, granted in `Product`

The post-deploy check pins the operator and the guardian on the executor. On an intent token it requires `EXECUTOR_ROLE` on the executors the product names and refuses it for the wallet accounts it is given. It looks for no other holder, so an executor contract the product does not name, or an account it was not given, passes ([Deployment and governance](../deployment.md)).

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `execute(token, intent, sig)` | `OPERATOR_ROLE`, while not paused | Submits one signed intent to `token` and returns the hash the token returns. Reverts with `IntentExecutor_ConsiderationNotSupported(0)` if the intent states a payment; the token's own revert data passes through unchanged. |
| `executeBatch(token, intents, sigs)` | `OPERATOR_ROLE`, while not paused | Submits several intents on one token, in array order, all or none. Returns each hash in order. |
| `pause()` | `GUARDIAN_ROLE` | Stops `execute` and `executeBatch` at once. Reverts with `EnforcedPause` if already paused. |
| `unpause()` | `DEFAULT_ADMIN_ROLE` or `RECOVERY_ROLE` | Resumes settlement. Anyone else gets `AccessControlUnauthorizedAccount(caller, DEFAULT_ADMIN_ROLE)`. Reverts with `ExpectedPause` if not paused. |
| `revokeRole(role, account)` | The role's admin; `RECOVERY_ROLE` for `GUARDIAN_ROLE` as well | Removes a role. |
| `grantRole(role, account)` | `DEFAULT_ADMIN_ROLE` | Grants a role: operators, guardians and the recovery timelock. The constructor grants the admin and the guardian and nothing else. |
| `renounceRole(role, account)` | The account itself | OpenZeppelin `AccessControl`. The deployer gives up its admin role this way at hand-over. |
| `hasRole`, `getRoleAdmin`, `paused`, `OPERATOR_ROLE`, `GUARDIAN_ROLE`, `RECOVERY_ROLE`, `DEFAULT_ADMIN_ROLE` | Anyone (read-only) | The state of the roles and the pause. |
| `supportsInterface(id)` | Anyone (read-only) | ERC-165: `IIntentExecutor`, `IIntentExecutorBatch` and the `AccessControl` interfaces. |

| Error or event | When |
|---|---|
| `IntentExecutor_ZeroAddress()` | The constructor got a zero admin or guardian. |
| `IntentExecutor_ConsiderationNotSupported(index)` | The intent states a consideration. The index is zero for `execute`. |
| `IntentExecutor_LengthMismatch(intents, sigs)` | The two arrays of a batch differ in length. |
| `IntentExecutor_BatchItemFailed(index, reason)` | The token reverted on that intent; `reason` is its revert data. |
| `Paused`, `Unpaused`, `RoleGranted`, `RoleRevoked` | Inherited from OpenZeppelin. The executor defines no event of its own; a settled intent is recorded by the token's `IntentExecuted`. |

<a id="why"></a>
## Why it is built this way

- **Forward only.** The token is the single source of truth for the signature, nonce, deadline, executor binding, freeze, pause and policy. The executor checks none of them, so nothing is checked twice and the two cannot disagree on them.
- **No funds, no state.** It stores its roles and its pause flag: no intents, no nonces, no balances.
- **Replaceable.** It is a plain contract, not a proxy. Replacing it means deploying a different one and moving the token's `EXECUTOR_ROLE`, which after hand-over is a timelock operation.
- **Operators are separate from the token.** An issuer or relayer key holds a role on the executor and none on the token, and the guardian can stop that route alone.
- **Refuse rather than half-settle.** An intent that states a payment is refused outright, so a holder does not see shares leave without what the message promised.

<a id="limits"></a>
## What it does not do

- **It does not judge an intent.** A pass here says nothing about whether the token will accept it.
- **It cannot move anything without the holder's signature, but it does not protect the holder's timing.** An operator chooses when to submit, which intents go in a batch and in what order, and can hold an intent back. The holder's controls are a short `deadline` and `cancelIntent` on the token.
- **It has no list of tokens.** An operator names the token in each call and the executor calls that address. A token that has not granted it `EXECUTOR_ROLE` refuses, or, if that token is not built from this stack, does whatever its code does. The executor returns whatever hash the token returns without checking it.
- **It has no reentrancy guard.** It keeps no state to protect apart from its roles and pause flag, calling back in would need `OPERATOR_ROLE`, and the token's movement path has its own guard.
- **It runs no trade.** A leg that states a payment is refused here, and the [DvPExecutor](DvPExecutor.md) runs both legs.

<a id="connected"></a>
## Connected to

- [IntentSettledUpgradeable](IntentSettledUpgradeable.md): The token side: signatures, nonces, the executor binding and `canExecute`.
- [IntentToken](IntentToken.md): The token that grants this executor `EXECUTOR_ROLE`.
- [DvPExecutor](DvPExecutor.md): The executor for intents that state a payment: it settles both sides.
- [ExecutedOnlyRule](ExecutedOnlyRule.md): Refuses a plain transfer, so a holder's tokens move through an executor.
- [GovernanceTimelock](GovernanceTimelock.md): Its admin, and the recovery timelock that can unpause it.
- [One movement](../movement.md): What the token and its rules check on an executed transfer.

<a id="source"></a>
## Source and tests

- Contract: `contracts/intents/IntentExecutor.sol`, interfaces `IIntentExecutor.sol` and `IIntentExecutorBatch.sol`
- Tests: `IntentExecutor.t.sol` (unit tests with a mocked token, recovery included, and integration tests on a real `IntentToken`: the consideration refusal in `test_WhenTheIntentNamesTheIntentExecutorAndStatesAPayment_ItIsRefusedAndNothingMoves`, batches in `test_WhenTheFailingIntentIsDroppedAndResubmitted_TheRestSettles`, the pause in `test_WhenTheExecutorIsPaused_TheTokenStillSettlesThroughOtherExecutors`) and `test/nodejs/intents.test.ts` (wallet signatures, the executor binding from each address, the token's pre-flight beside the executor's refusal, a failed batch decoded)
- The signing helper `signIntent` is in `test/nodejs/fixtures.ts`.

---

Describes the contracts at commit `18e60b3` on `paris`.
