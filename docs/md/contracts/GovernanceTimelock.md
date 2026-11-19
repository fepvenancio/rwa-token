[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Governance and deployment

# GovernanceTimelock

The code behind both timelocks. It is OpenZeppelin's `TimelockController` with two additions: its delay refuses to go below one hour, and a holder of `RECOVERY_ROLE` may take away a canceller's right to cancel. Governance changes wait here for a fixed delay before they run, and on the main timelock the guardian can cancel them during the wait.

- **contracts/governance/GovernanceTimelock.sol**
- immutable, **not a proxy**, deployed twice
- delay: **24 hours** by default, floor **1 hour**
- admin: **itself** after `CoreHandover`
- not attested: nothing installs it by code hash

<a id="in-one-minute"></a>

> ### In one minute
>
> A timelock is a contract that holds admin powers and uses them only after a public waiting period. The governance multisig proposes a change, the timelock records it, and once the delay has passed (24 hours by default) governance executes it. While it waits, anyone can see what is coming, and the guardian, a multisig whose job is to stop things, can cancel it. That cancel power has one weak spot: the guardian could cancel its own replacement. So a second deployment of this contract exists, the recovery timelock, with the same delay and nobody able to cancel. It can do only a few undoing things: unpause, take the guardian's role away, clear a guardian block or revive an attester in the credential registry, and take a cancel right on the main timelock.

<a id="how"></a>
## How it works

Two timelocks, the same code, one proposer. Governance proposes and executes on both. On the main timelock the guardian can cancel. On the recovery timelock nobody can, and it holds a role in a handful of places, each limited to a few functions.

> **Diagram.** The main timelock: governance schedules an operation, it waits at least the minimum delay, then governance executes it and the timelock calls the target as its admin or owner: each product, the executors, both registries, each fund, and itself. During the wait the guardian can cancel it, and a cancelled operation does not run. The recovery timelock, the same contract deployed with no recovery of its own: governance schedules, it waits the same delay with no cancellers, the guardian holds no role there, then governance executes it. It can call unpause and revoke GUARDIAN_ROLE on each product and executor; revoke GUARDIAN_ROLE, clear a guardian block and revive an attester on the credential registry; and revoke CANCELLER_ROLE on the main timelock.
>
> **The guardian can stop a change, and recovery can stop the guardian.** If the guardian cancels the operation that would replace it, governance schedules the undoing steps on the recovery timelock, where the guardian has no cancel right. After that timelock's delay, one batch can unpause what the guardian paused and take its roles, including its cancel right on the main timelock.

1. **Propose.** A `PROPOSER_ROLE` holder calls `schedule` or `scheduleBatch` with the target, the call data and a delay. A delay shorter than the timelock's minimum is refused (`TimelockInsufficientDelay`).
2. **Wait.** The operation is public from the moment it is scheduled (`CallScheduled`). Executing it early fails with `TimelockUnexpectedOperationState`.
3. **Cancel, perhaps.** A `CANCELLER_ROLE` holder can cancel an operation that is scheduled and not yet executed, including one whose delay has already passed (`Cancelled`).
4. **Execute.** An `EXECUTOR_ROLE` holder calls `execute` or `executeBatch`, and the timelock makes the calls itself, so the target sees the timelock as the caller (`CallExecuted`). A batch runs all its calls or none.

<a id="deployed"></a>
## Roles as deployed, and the hand-over

`Core` creates the recovery timelock first, passing the zero address as its own recovery so that nobody holds `RECOVERY_ROLE` on it. It then creates the main timelock, which names the recovery timelock and grants it `RECOVERY_ROLE` in the constructor. The deployer account is an extra admin on both, so that `CoreHandover` can finish the setup without a delay. On the two timelocks, `CoreHandover` then does three things:

1. Grants the guardian `CANCELLER_ROLE` on the main timelock.
2. Revokes the `CANCELLER_ROLE` that OpenZeppelin's constructor gave governance on the recovery timelock, because OpenZeppelin makes each proposer a canceller.
3. Has the deployer renounce `DEFAULT_ADMIN_ROLE` on both. Each timelock keeps that role on itself, which OpenZeppelin's constructor granted, so from here a change to either one's roles is an operation of that timelock, with its delay.

| Role | Main timelock | Recovery timelock |
|---|---|---|
| `PROPOSER_ROLE` | Governance multisig | Governance multisig |
| `EXECUTOR_ROLE` | Governance multisig | Governance multisig |
| `CANCELLER_ROLE` | Governance multisig and the guardian | Nobody |
| `DEFAULT_ADMIN_ROLE` | Itself | Itself |
| `RECOVERY_ROLE` | The recovery timelock | Nobody. The role exists, because it is the same code |

The post-deploy check (`assertHandedOver` in `test/nodejs/fixtures.ts`) asserts that the recovery timelock's code is identical to the main timelock's, that the guardian holds nothing on the recovery timelock and on the main timelock can cancel and cannot propose or execute, the recovery timelock's roles and the absence of cancellers on it among the accounts the stack knows, that on each timelock no known account but governance proposes or executes and the zero address holds no proposer, executor or canceller role, that the deployer and the operations account hold no role, and at least 24 hours on both delays. It does not assert governance's own roles on the main timelock.

<a id="delay"></a>
## The delay and the floor

The delay is a deployment parameter, `minDelay` in the `Core` module, 24 hours (86,400 seconds) unless the deployment sets another value. Both timelocks start with the same value, so at deployment the recovery path is no faster than the normal one.

- **What enforces it per operation:** OpenZeppelin refuses to schedule anything with a shorter delay than the current minimum, and refuses to execute before the scheduled time.
- **The floor:** the contract refuses less than one hour, at deployment and in `updateDelay`, with `GovernanceTimelock_DelayBelowFloor(delay, floor)`. Both timelocks run this code, so the floor holds on both. One hour exactly is accepted (`test_WhenGovernanceSetsTheDelayToExactlyTheFloor_ItApplies`).
- **What checks the 24 hours:** the post-deploy check, not the contract. Between the 24 hours and the floor, the delay is governance's choice.
- **Changing it later:** `updateDelay` accepts a call from the timelock itself and nobody else (`TimelockUnauthorizedCaller`), so a different delay is an ordinary operation: it waits out the current delay, and on the main timelock the guardian can cancel it. A delay below the floor reverts when the operation runs.

<a id="holds"></a>
## What the main timelock controls

After the hand-overs, the main timelock holds these, and each power runs only as an operation that has waited out the delay.

| Where | What it holds | What that lets governance do |
|---|---|---|
| Each product | `DEFAULT_ADMIN_ROLE` (from the end of `Product`), and `UPGRADER_ROLE` | Grant and revoke the product's roles, `unpause`, `installPolicy`, upgrade to an attested implementation of the same template, change the token's rule list on the hook (`setRules`) and the settings that rules keep under the token's admin, such as `setPolicy`. On a 4626 vault, `setPortfolio` and `setFeeModel`. |
| A vault's legos, through the vault's role | Nothing of their own: `Portfolio`, `GuardedAccount` and `NavDesk` ask the vault | Add or remove an adapter, raise caps, migrate a portfolio; set a permission on a guarded account; change a desk's settings and fee model, and `adopt` on a successor desk. |
| `IntentExecutor`, `DvPExecutor` | `DEFAULT_ADMIN_ROLE` | Grant and revoke `OPERATOR_ROLE` and `GUARDIAN_ROLE`, `unpause`. |
| `PolicyRegistry` | `DEFAULT_ADMIN_ROLE`, from the constructor | Decide who holds `ATTESTER_ROLE`. Attesting itself is the council's. |
| `CredentialRegistry` | `DEFAULT_ADMIN_ROLE` | Manage attesters and the guardian, kill or revive an attester, clear a guardian block. |
| Each `Fund` | Ownership, from the end of `FundOpen` | Register a later class, set the fund's rule, investor cap and exemptions. |
| Itself | `DEFAULT_ADMIN_ROLE` | Change its own proposers, executors, cancellers and recovery holder, and its delay through `updateDelay`. |

It does not own [`ProxyDeployer`](ProxyDeployer.md): the operations account does, so that a launch does not wait for this delay. It does not attest code. It does not write credentials, mint, burn or force a transfer, unless it first gives itself that power, which is itself a delayed and visible operation.

<a id="recovery"></a>
## The guardian and the recovery timelock

On this contract the guardian's one power is to cancel, and it takes effect at once. Its powers elsewhere are on [Who can do what](../roles.md). Cancelling is what makes the delay a safeguard, because a harmful operation can be stopped before it runs. It also lets the guardian cancel the operation that would replace it, or that would unpause a token it paused. That is the case the recovery timelock exists for.

The recovery timelock is the same contract, with the same delay and governance as proposer and executor, and no cancellers. It holds `RECOVERY_ROLE` on each product, each executor, the credential registry and the main timelock, and its own `DEFAULT_ADMIN_ROLE`. It holds nothing on `PolicyRegistry`, and the post-deploy check pins that whole set.

| Where | `RECOVERY_ROLE` allows | Granted by |
|---|---|---|
| Each product | `unpause()`, and `revokeRole(GUARDIAN_ROLE, account)` | `Product` |
| `IntentExecutor`, `DvPExecutor` | `unpause()`, and `revokeRole(GUARDIAN_ROLE, account)` | `CoreHandover` |
| `CredentialRegistry` | `revokeRole(GUARDIAN_ROLE, account)`, `clearGuardianBlock(subject)`, `reviveAttester(id)` | `CoreHandover` |
| Main timelock | `revokeRole(CANCELLER_ROLE, account)` | The constructor, from `Core` |

On the main timelock, `RECOVERY_ROLE` cannot grant any role, revoke any other role, or propose, execute or cancel; the tests try each and expect `AccessControlUnauthorizedAccount`. Each `unpause` in a recovery batch must target something that is paused when the batch runs, otherwise OpenZeppelin's `ExpectedPause` reverts the whole batch. Until the batch executes, the guardian keeps all its powers.

<a id="functions"></a>
## What it can do

The contract is OpenZeppelin's `TimelockController` (contracts 5.3.0), plus the floor, the role id and the one branch in `revokeRole`. In that release a subclass cannot extend `updateDelay`, so the contract keeps the delay itself: `updateDelay` repeats OpenZeppelin's caller check and event and adds the floor, and `getMinDelay` reads that value. Who can call is given as deployed.

| Function | Who can call | What it does |
|---|---|---|
| `schedule`, `scheduleBatch` | `PROPOSER_ROLE`: governance | Records an operation and when it becomes ready. Reverts with `TimelockInsufficientDelay` below the minimum, `TimelockUnexpectedOperationState` if the same operation exists, and `TimelockInvalidOperationLength` if a batch's arrays differ in length. |
| `execute`, `executeBatch` | `EXECUTOR_ROLE`: governance | Runs a ready operation. Reverts with `TimelockUnexpectedOperationState` if not ready, `TimelockUnexecutedPredecessor` if the operation it depends on has not run, or the target's own revert. |
| `cancel(id)` | `CANCELLER_ROLE`: on the main timelock, governance and the guardian; on the recovery timelock, nobody | Deletes a pending operation. Reverts with `TimelockUnexpectedOperationState` if not pending. |
| `updateDelay(newDelay)` | The timelock itself | Changes the minimum delay, to no less than one hour. Emits `MinDelayChange`. Reverts with `TimelockUnauthorizedCaller` for any other caller, and with `GovernanceTimelock_DelayBelowFloor` below the floor. |
| `revokeRole(role, account)` | The role's admin; also `RECOVERY_ROLE`, for `CANCELLER_ROLE` only | Takes a role away. The recovery branch has no other condition: it removes the cancel right from whichever account is named. Every other case is OpenZeppelin's, and reverts with `AccessControlUnauthorizedAccount` for a caller without the admin role. |
| `grantRole(role, account)` | `DEFAULT_ADMIN_ROLE`: the timelock itself | Gives a role. An operation of the timelock on itself. |
| `renounceRole(role, account)` | The holder of the role | Gives up one's own role. How the deployer leaves. |
| `RECOVERY_ROLE()`, `PROPOSER_ROLE()`, `EXECUTOR_ROLE()`, `CANCELLER_ROLE()`, `DEFAULT_ADMIN_ROLE()`, `hasRole`, `getRoleAdmin` | Anyone (read-only) | The role ids and the role table. The admin of `RECOVERY_ROLE` is `DEFAULT_ADMIN_ROLE`, as for the others. |
| `getMinDelay`, `getTimestamp`, `getOperationState`, `isOperation`, `isOperationPending`, `isOperationReady`, `isOperationDone`, `hashOperation`, `hashOperationBatch` | Anyone (read-only) | The delay and the state of an operation. |
| `receive`, `onERC721Received`, `onERC1155Received`, `onERC1155BatchReceived`, `supportsInterface` | Anyone | OpenZeppelin's: the timelock can receive ether and these token standards, and an operation can send them on. |

The constructor takes the delay, the proposers, the executors, an optional bootstrap admin and the recovery account, which may be zero. Below one hour it reverts with `GovernanceTimelock_DelayBelowFloor`. Role changes emit OpenZeppelin's `RoleGranted` and `RoleRevoked`.

<a id="why"></a>
## Why it is built this way

- **OpenZeppelin, plus a constructor check and two overrides.** The constructor refuses a delay below the floor and grants `RECOVERY_ROLE` when given an account. `revokeRole` lets `RECOVERY_ROLE` revoke `CANCELLER_ROLE` and falls through to OpenZeppelin for every other case. `updateDelay` runs OpenZeppelin's version, caller check first, then refuses a delay below the floor.
- **One contract for both timelocks.** So the floor holds on both, and the post-deploy check can compare the two by their code.
- **`RECOVERY_ROLE` is not a role admin.** A role admin could also grant the role it administers. Revoking is the smallest power that gets governance past a guardian that cancels its own replacement.
- **No cancellers on the recovery timelock.** If the guardian could cancel there, the problem would only move. It starts with the same delay, so at deployment it is no shortcut around the main timelock.
- **The asymmetry is the point.** The guardian acts at once and can only stop. Starting or changing something waits for a timelock.

<a id="limits"></a>
## What it does not do

- **It does not protect against governance.** The governance multisig proposes and executes on both timelocks. Recovery bounds the guardian, not governance, and a compromised governance multisig is outside what this control covers. The delay gives others time to see the operation, and the guardian time to cancel it on the main timelock.
- **It does not judge an operation.** An operation that waits out the delay and is not cancelled runs. A ready operation does not expire: it stays ready until it is executed or cancelled.
- **`RECOVERY_ROLE` is not limited to the guardian.** It can remove the cancel right of any holder on the main timelock, governance's included (`test_WhenRecoveryRevokesGovernancesCancelRight_ItIsRevoked`).
- **The recovery timelock's shape is state, not code.** It is its own admin, so governance could give it a canceller, or grant someone `RECOVERY_ROLE` on it, through one of its own operations, which nobody can cancel. The contract allows that, and the post-deploy check fails on it when the account is one the stack knows. The check cannot list a role's holders, so any other address passes. In the same way the main timelock could take `RECOVERY_ROLE` from the recovery timelock through an operation of its own.
- **The 24 hours is not a promise of the contract.** The floor is one hour. The post-deploy check asserts 24 hours when it is run, and an operation can lower the delay afterwards.
- **It does not hold everything.** `ProxyDeployer` is the operations account's. The council attests and the guardian pauses without waiting, and the holders of operational roles such as `AGENT_ROLE` and `MINTER_ROLE` act without it.

<a id="connected"></a>
## Connected to

- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): The token base: pause by the guardian, unpause and role changes through a timelock.
- [PolicyRegistry](PolicyRegistry.md): Administered by the main timelock, which decides who attests.
- [ProxyDeployer](ProxyDeployer.md): Not owned by a timelock: a launch does not wait for this delay.
- [CredentialRegistry](CredentialRegistry.md): Where the recovery timelock can also clear a guardian block and revive an attester.
- [Fund](Fund.md): Owned by the main timelock once its first classes are registered.
- [IntentExecutor](IntentExecutor.md): Paused by the guardian, unpaused by either timelock.
- [Who can do what](../roles.md): Every role in the system and who holds it.
- [Deployment and governance](../deployment.md): The modules that create the timelocks and hand powers to them.

<a id="source"></a>
## Source and tests

- Contract: `contracts/governance/GovernanceTimelock.sol`, interface `IGovernanceTimelock.sol`
- Deployment: `ignition/modules/Core.ts` (both timelocks, the delay) and `CoreHandover.ts` (the guardian as canceller, `RECOVERY_ROLE` grants on the core, the hand-over)
- Tests: `GovernanceTimelock.t.sol` (what `RECOVERY_ROLE` can and cannot do, and the floor at deployment and in `updateDelay`), `test/nodejs/governance.test.ts` (upgrades, cancels and recovery through the real timelocks), and `assertHandedOver` in `test/nodejs/fixtures.ts` (the post-deploy check)
