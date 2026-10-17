# Roles

Who can call what, and who holds each role once `Activate` has run. The role holders below are the ones the Ignition modules set up. Contracts do not forbid other holders: the timelock can grant any role to anyone, after its delay.

In OpenZeppelin `AccessControl`, `DEFAULT_ADMIN_ROLE` administers every other role unless a contract changes that. None of these contracts does. So whoever holds `DEFAULT_ADMIN_ROLE` on a contract can grant and revoke every role on it.

The word "operator" means three different things in this repo:

| Where | Meaning |
|---|---|
| `OPERATOR_ROLE` on `IntentExecutor` | the bank's or relayer's key that submits signed intents |
| `ctx.operator` in `TransferContext` | whoever called into the token for this movement: the holder, a spender, the agent, the minter, the executor |
| `setOperator` on `Gated7540Vault` | an account a controller has approved to act for it |

## Who holds what after `Activate`

| Holder | Where | Role | Set by |
|---|---|---|---|
| Timelock | each token | `DEFAULT_ADMIN_ROLE`, `UPGRADER_ROLE` | `Activate` grants admin, then the deployer renounces. `UPGRADER_ROLE` goes to the timelock only |
| Timelock | `PolicyRegistry` | `DEFAULT_ADMIN_ROLE` | constructor |
| Timelock | `IntentExecutor` | `DEFAULT_ADMIN_ROLE` | `Activate` |
| Timelock | each `ComplianceHook` | `ADMIN` (immutable) | constructor |
| Timelock | `ProxyDeployer` | owner | `Activate` calls `transferOwnership` |
| Governance multisig | timelock | `PROPOSER_ROLE`, `EXECUTOR_ROLE`, `CANCELLER_ROLE` | `Components` passes it as proposer and executor. OpenZeppelin gives proposers `CANCELLER_ROLE` too |
| Guardian multisig | each token | `GUARDIAN_ROLE` | token initialiser |
| Guardian multisig | `IntentExecutor` | `GUARDIAN_ROLE` | constructor |
| Guardian multisig | timelock | `CANCELLER_ROLE` | `Activate` |
| Security council | `PolicyRegistry` | `ATTESTER_ROLE` | constructor |
| Agent (issuer's compliance ops) | each token | `AGENT_ROLE` | `Activate` |
| Minter, burner (issuer) | `IntentToken` | `MINTER_ROLE`, `BURNER_ROLE` | `Activate` |
| `IntentExecutor` contract | `IntentToken` | `EXECUTOR_ROLE` | `Activate` |
| Relayer / bank key | `IntentExecutor` | `OPERATOR_ROLE` | `Activate` |
| Bank (fulfiller) | `Gated7540Vault` | `FULFILLER_ROLE` | `Activate` |

Until `Activate` finishes, the deployer account holds `DEFAULT_ADMIN_ROLE` on each token and on the executor, and is the timelock's admin and the `ProxyDeployer` owner. `Activate` hands all of these to the timelock and the deployer renounces.

Code: `ignition/modules/Activate.ts`, `ignition/modules/Components.ts`, `ignition/modules/roles.ts`.

## Authority map

Through the timelock. Every edge that leaves the timelock waits for the timelock delay:

```mermaid
flowchart LR
  Gov["Governance multisig"] -->|"schedule, execute"| TL["TimelockController"]
  Guard["Guardian multisig"] -->|"cancel only"| TL
  TL -->|"admin, upgrade"| Tokens["Tokens"]
  TL -->|"setRules"| Hook["ComplianceHook"]
  TL -->|"admin"| Reg["PolicyRegistry"]
  TL -->|"admin"| Exec["IntentExecutor"]
  TL -->|"deploy"| PD["ProxyDeployer"]
  TL -->|"window, cap, count, exemptions"| Rules["Rules"]
```

Takes effect at once, with no delay:

```mermaid
flowchart LR
  Guard["Guardian multisig"] -->|"pause"| Tokens["Tokens"]
  Guard -->|"pause"| Exec["IntentExecutor"]
  Agent["Agent"] -->|"force, freeze, recover"| Tokens
  Agent -->|"setLockup"| Rules["Rules"]
  Council["Security council"] -->|"attest, revoke"| Reg["PolicyRegistry"]
  Issuer["Minter and burner"] -->|"mint, burn"| IT["IntentToken"]
  Op["Operator key"] -->|"execute, executeBatch"| Exec
  Exec -->|"executeTransfer"| IT
  Bank["Fulfiller"] -->|"fulfil, reject"| V7["Gated7540Vault"]
```

Holders act on the tokens directly and are not drawn.

## Token functions and who may call them

All three tokens share the base. Rows marked 7540 exist only on `Gated7540Vault`.

| Function | Caller | Notes |
|---|---|---|
| `mint(to, amount)` | `MINTER_ROLE` | Reverts on both vaults whatever the role |
| `burn(from, amount)` | `BURNER_ROLE` | Releases the frozen amount it needs first. Reverts on both vaults |
| `forcedTransfer(from, to, amount)` | `AGENT_ROLE` | Works while paused and on frozen tokens. The hook still runs, with kind `FORCED` |
| `setFrozen(user, amount)` | `AGENT_ROLE` | Absolute amount, at most the balance |
| `pause()` | `GUARDIAN_ROLE` | No delay |
| `unpause()` | `DEFAULT_ADMIN_ROLE` | Timelock |
| `setPolicyHook(newHook)` | `DEFAULT_ADMIN_ROLE` | New hook must be attested as `HOOK` |
| `upgradeToAndCall(impl, data)` | `UPGRADER_ROLE` | New implementation must be attested as `IMPLEMENTATION` |
| `grantRole`, `revokeRole` | the role's admin, `DEFAULT_ADMIN_ROLE` | Any account may call `renounceRole` for itself |
| `transfer`, `transferFrom`, `approve`, `permit` | anyone | Movements go through the hook |
| `executeTransfer(intent, sig)` | `EXECUTOR_ROLE` | `IntentToken` only |
| `cancelIntent(nonce)` | anyone, for its own nonces | `IntentToken` only |
| `deposit`, `mint`, `withdraw`, `redeem` | anyone | `Gated4626Vault` only |
| `requestDeposit(assets, controller, owner)` | `owner`, or an operator of `owner` | 7540 |
| `requestRedeem(shares, controller, owner)` | `owner`, an operator of `owner`, or a spender with allowance | 7540 |
| `deposit`, `mint`, `redeem`, `withdraw` with a controller | the controller or an operator of it | 7540 claims |
| `setOperator(operator, approved)` | anyone, for itself | 7540 |
| `fulfillDeposit`, `fulfillRedeem`, `rejectDepositRequest`, `rejectRedeemRequest` | `FULFILLER_ROLE` | 7540 |
| `recoverRedeemRequest(controller, to)` | `AGENT_ROLE` | 7540 |
| `setCustody(newCustody)` | `DEFAULT_ADMIN_ROLE` | 7540 |

Code: `PolicyGatedERC20Upgradeable`, `IntentSettledUpgradeable`, `Gated4626Vault`, `Gated7540Vault`.

## Other contracts

| Contract | Function | Caller |
|---|---|---|
| `ComplianceHook` | `setRules(rules)` | `ADMIN` |
| `ComplianceHook` | `afterTransfer(ctx)` | `TOKEN` only |
| `PolicyRegistry` | `attest(codehash, kind, uri)`, `revoke(codehash)` | `ATTESTER_ROLE` |
| `PolicyRegistry` | `grantRole`, `revokeRole` | `DEFAULT_ADMIN_ROLE` |
| `IntentExecutor` | `execute`, `executeBatch` | `OPERATOR_ROLE`, and only while not paused |
| `IntentExecutor` | `pause()` | `GUARDIAN_ROLE` |
| `IntentExecutor` | `unpause()`, `grantRole` | `DEFAULT_ADMIN_ROLE` |
| `ProxyDeployer` | `deploy(...)` | owner |

Rules have no roles of their own. Each rule asks the token, at call time, who may configure it for that token:

| Rule function | Allowed if the caller holds, on the token |
|---|---|
| `SettlementWindowRule.setWindow` | `DEFAULT_ADMIN_ROLE` |
| `MaxHoldersRule.setCap`, `seedHolderCount`, `setExemptHolder` | `DEFAULT_ADMIN_ROLE` |
| `LockupRule.setLockup` | `AGENT_ROLE` |

After `Activate`, `DEFAULT_ADMIN_ROLE` on a token is the timelock, so the window, the cap, the count and the exemptions change only after the timelock delay. Lockups are set by the agent with no delay.

`afterTransfer` on the hook is open only to `TOKEN`. `after_` on a rule is open only to the hook currently installed on `ctx.token`, which the rule checks by calling `ctx.token.policyHook()`.

Code: `ComplianceHook`, `PolicyRegistry`, `IntentExecutor`, `ProxyDeployer`, `BaseRule.onlyHook`, `SettlementWindowRule.setWindow`, `MaxHoldersRule.onlyTokenAdmin`, `LockupRule.setLockup`.

## What the guardian can do

The guardian multisig holds three separate powers, on three contracts:

1. `pause()` on each token. It stops every movement except `FORCED` ones. No delay.
2. `pause()` on `IntentExecutor`. It stops `execute` and `executeBatch`. No delay.
3. `cancel(id)` on the timelock, through `CANCELLER_ROLE`. It cancels any scheduled operation that has not run yet.

It cannot schedule or execute timelock operations, unpause, change the hook, grant roles, or upgrade.

The timelock's `cancel` does not look at what an operation does. The guardian can therefore cancel a scheduled `unpause`. It can cancel a scheduled revocation of its own `CANCELLER_ROLE` too. Nothing in the code limits how often it can do either. [PLAN.md](../PLAN.md) lists this as a review item still waiting for an owner decision.

Code: `PolicyGatedERC20Upgradeable.pause`, `IntentExecutor.pause`, `ignition/modules/Activate.ts` (`timelock_canceller`).

## The delay

Everything the timelock does waits for `getMinDelay()` after it is scheduled. `Components.ts` takes the delay as the parameter `minDelay`, default 7 days. The module does not refuse a smaller value. The test fixture's post-deploy check does: it asserts `getMinDelay() >= 7 days`. Changing the delay later is itself a timelock operation (`updateDelay` can only be called by the timelock).

Actions with no delay: guardian pause, council attestation and revocation, and everything the agent, minter, burner, executor operator and fulfiller do.

Code: `ignition/modules/Components.ts`, `test/nodejs/fixtures.ts` (`assertHandedOver`).

## What nobody can do

- Change a token's registry. `registry()` is set in the initialiser and has no setter.
- Mint or burn vault shares through `mint` or `burn`.
- Make `transfer` return `true` without moving a balance. A rejected movement reverts.
- Let the executor change an intent. It passes the holder's signed fields to the token, which checks the signature.
- Let a rule configure itself for a token. Each rule reads the permission from the token.
