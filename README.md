# rwa-token — Gated Token Stack

Permissioned ERC-20 templates for institutional real-world assets. Every balance movement goes through one
mechanical base and an external, replaceable policy hook made of small, attested rules. One template adds
executor-settled transfers: the holder signs an EIP-712 intent, and an executor settles it.

> **Proprietary.** Copyright (c) 2026 Filipe Venancio. All rights reserved. See [LICENSE](LICENSE). No use, copying,
> modification or deployment without prior written permission.

## Architecture

```
PolicyGatedERC20Upgradeable        base: accounting, roles, enforcement, guardian, hook pointer (UUPS)
        ▲                                 every movement → TransferContext → hook.beforeTransfer → balances → afterTransfer
        │
IntentToken (+ IntentSettledUpgradeable)  holder-signed EIP-712 TransferIntent, settled by EXECUTOR_ROLE
Gated4626Vault (ERC-4626, gated max*, decimals offset 6), Gated7540Vault (ERC-7540 async, escrow, fulfiller)

ComplianceHook (one per token, immutable) ──► ordered list of ≤16 attested IComplianceRule (first rejection wins)
IdentityRule, LockupRule, SettlementWindowRule, MaxHoldersRule   hook-agnostic, shared across tokens; per-token
                                                 config authorised live by the token's own roles
PolicyRegistry (one per deployment, immutable)  codehash allowlist: HOOK / RULE / IMPLEMENTATION
IntentExecutor (immutable)                       replaceable, role-gated submitter: execute + atomic executeBatch
```

| Path | Contents |
|---|---|
| `contracts/interfaces/` | Frozen ABI: `IPolicyGated`, `IPolicyHook`, `IComplianceRule`, `IComplianceHook`, `IPolicyRegistry`, `ITransferIntent`, `IIntentExecutor`, `IIntentExecutorBatch`, `IIdentityRule`, `IIdentityRegistry`, `ILockupRule`, `ISettlementWindowRule`, `IMaxHoldersRule`, `IGated4626Vault`, `IGated7540Vault`, `IERC7540Operator` / `IERC7540Deposit` / `IERC7540Redeem` / `IERC7575` (spec-exact ids), `Errors.sol` (reason codes) |
| `contracts/base/` | `PolicyGatedERC20Upgradeable` |
| `contracts/governance/` | `PolicyRegistry` |
| `contracts/mixins/`, `contracts/tokens/` | `IntentSettledUpgradeable`, `IntentToken` |
| `contracts/hooks/` | `ComplianceHook`, `BaseRule`, `rules/` `IdentityRule`, `LockupRule`, `SettlementWindowRule`, `MaxHoldersRule` (recommended order) |
| `contracts/intents/` | `IntentExecutor` |
| `contracts/vaults/` | `Gated4626Vault`, `Gated7540Vault` |
| `contracts/test/` | Test helpers and mocks, interface-freeze and contract-size guards, Halmos properties |

Every contract has its `.t.sol` next to it. [`PLAN.md`](PLAN.md) tracks phases and decisions;
[`CLAUDE.md`](CLAUDE.md) is the build brief.

## Security model

| Power | Holder | Delay | Can |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | TimelockController | ≥ 7 days | grant/revoke every role, `unpause`, `setPolicyHook`, change hook rules, manage attesters |
| `GUARDIAN_ROLE` | multisig | none | `pause` the token and cancel pending timelock operations. **It can only stop things:** no unpause, no upgrades, no role or hook changes |
| `UPGRADER_ROLE` | timelock | ≥ 7 days | upgrade, only to an implementation attested as `IMPLEMENTATION` |
| `MINTER_ROLE` / `BURNER_ROLE` | issuer | none | mint, and burn (enforcement burns can take frozen tokens) |
| `AGENT_ROLE` | issuer | none | `forcedTransfer` (clawback; bypasses pause and freeze, still policy-checked), `setFrozen`; on the 7540 vault, `recoverRedeemRequest` (escrow → verified recovery account) |
| `EXECUTOR_ROLE` | `IntentExecutor` contract | none | settle holder-signed intents; it cannot alter them |
| `OPERATOR_ROLE` (executor) | bank / relayer keys | none | submit intents via `execute` / `executeBatch` (all-or-nothing) |
| `GUARDIAN_ROLE` (executor) | multisig | none | pause the executor only; the timelock unpauses |
| `ATTESTER_ROLE` (registry) | security council | none | attest / revoke codehashes |
| token `DEFAULT_ADMIN_ROLE` → rules | timelock | ≥ 7 days | set a token's holder cap, seed its holder count, set its settlement window |
| token `AGENT_ROLE` → rules | issuer | none | set or clear per-holder lockups |
| `FULFILLER_ROLE` (7540 vault) | bank | none | fulfil deposits/redemptions at off-chain NAV; reject pending requests |

- **Attested code only.** Hooks, rules and implementations are installed only if their runtime codehash is attested.
  Attestation is checked at install time; revoking it later does not silently change a live token.
- **Immutable policy components.** Hooks and rules are never proxies. Changing one means deploying a new one and
  swapping it in through the timelock. The hook's admin, registry and token are `immutable`, so they are part of the
  attested codehash.
- **Fail closed.** `TRANSFER_OK` is non-zero, and a hook with no rules rejects everything (`NO_RULES`). Every
  rejection reverts with `PolicyGated_TransferRejected(bytes32 reason)`; `transfer` never returns `false`.
- **Pre-flight parity.** `canTransfer` and `canExecute` run the same checks as the state-changing path.
- **Reentrancy.** `_update` is `nonReentrant` (transient storage); rules cannot call back into the token.
- **Deployment.** One implementation per template, deployed and attested once, with one proxy per token. Each
  implementation deployment has its own codehash, because UUPS stores `address(this)` in an immutable. Each proxy sits
  at a CREATE2 address fixed before its hook exists, and `ProxyDeployer` refuses to deploy unless the hook is bound to
  that address (see the runbook below).

## Deployment runbook

Three Ignition modules in `ignition/modules/`, with two security-council steps between them. Each stage takes the
previous stages' addresses as parameters. `test/nodejs/fixtures.ts` runs this exact sequence on the local network,
playing the council and the identity provider, and ends with the post-deploy checks below.

1. **`Components`** (deployer):
   - the TimelockController: minimum delay ≥ 7 days; proposer **and** executor are the governance multisig only;
     the deployer is its admin until `Activate`;
   - the `PolicyRegistry`: admin = timelock, attester = council;
   - the four rules, one implementation per template, `ProxyDeployer` (owner = deployer), and `IntentExecutor`.

   Parameters: `governance`, `council`, `guardian`, `identityRegistry`, `minDelay`.
2. **Council step 1.** For each rule and implementation, recompute the runtime codehash from the reviewed source and
   compare it with `extcodehash` of the deployed address, then `attest(codehash, RULE | IMPLEMENTATION, auditUri)`.
   Also compute where each token will live, before any hook or proxy exists:
   `CREATE2(ProxyDeployer, salt = keccak256(utf8(symbol)), initCode = TokenProxy.creationCode ++ abi.encode(implementation, ""))`.
   `ProxyDeployer.predict(symbol, implementation)` returns the same address.
3. **`Tokens`** (deployer): one `ComplianceHook` per token, with `ADMIN` = timelock, `TOKEN` = the predicted address,
   and the token's initial rules in the constructor (which re-checks each rule's attestation).
4. **Council step 2.** For each hook:
   - check that `TOKEN()` equals the address computed in step 2, `ADMIN()` is the timelock and `REGISTRY()` is the
     registry;
   - read `rules()`: the attestation covers the code and the immutables, not the rule list, which lives in storage;
   - then `attest(codehash, HOOK, auditUri)`.

   `TOKEN` is an immutable, so the codehash covers the token: the council attests *this hook for this token*, which
   means one attestation per token, not per hook type. A later hook with the same admin, registry and token shares that
   codehash whatever its rules, and only the timelock can install it, after the delay.
5. **`Activate`** (deployer):
   - `ProxyDeployer.deploy(symbol, implementation, initData, hook)` for each token. It reverts **before creating the
     proxy** if `hook.TOKEN()` is not the predicted address, initialises in the same transaction, then checks the
     installed hook and the symbol. A symbol can be used once. Every later call waits for all three deploys, so one
     mis-bound hook grants nothing anywhere;
   - configure: settlement window, holder caps, the 7540 vault's holder-cap exemption;
   - grant roles: MINTER, BURNER and AGENT to the issuer's accounts, EXECUTOR to `IntentExecutor`, FULFILLER to the
     bank, OPERATOR to the relayer, **UPGRADER to the timelock only**, CANCELLER on the timelock to the guardian;
   - hand over: DEFAULT_ADMIN_ROLE to the timelock on every token and on the executor; the deployer renounces it there
     and on the timelock.
6. **Identity provider:** verify the 7540 vault, which escrows pending redemptions.
7. **Post-deploy checks** (the fixture's `assertHandedOver`):
   - the deployer holds no role on the timelock, registry, tokens or executor;
   - the timelock holds DEFAULT_ADMIN_ROLE everywhere and is the only UPGRADER;
   - every hook's `TOKEN` is its token and every token's `policyHook` is its hook;
   - the guardian can cancel timelock operations but cannot propose or execute them;
   - `getMinDelay() ≥ 7 days`.

## Commands

Requires Node 24 (as in CI). Foundry v1.8.1, slither 0.11.5 and halmos 0.3.3 are needed only for the analysis
commands.

```bash
npm ci
```

```bash
npm test              # Hardhat 3: Solidity (unit, fuzz, invariants, size + freeze guards) and node:test runners
```

```bash
npm run lint:sol      # solhint (Wonderland config), fails on any warning
```

```bash
npm run typecheck
```

```bash
npm run fmt:check     # forge fmt (Wonderland profile in foundry.toml)
```

```bash
slither .             # static-analysis gate; accepted findings in slither.config.json and inline
```

```bash
npm run test:halmos   # symbolic properties: nonce/signature and frozen-balance paths
```

```bash
npm run validate:upgrades   # OZ upgrades-core over a Foundry build with storage layouts
```

CI (`.github/workflows/ci.yml`) runs all of the above on every push and pull request.

## Deviations from the brief

The brief is in [`CLAUDE.md`](CLAUDE.md). Where the code intentionally differs, it is recorded here:

- **More interface files.** There are three beyond those listed in brief §3: `IComplianceHook`, `IIdentityRule` and
  `IIdentityRegistry`. (`IIntentExecutorBatch` is listed in the brief.) Wonderland standards give every contract an interface. Structs and enums live inside their
  interfaces, so there is no `Types.sol`.
- **Error naming.** Errors follow `<Contract>_<Name>`, e.g. `PolicyGated_TransferRejected(bytes32)`. Event
  parameters are `_camelCase`; topics are unaffected.
- **No ERC-7943 interface id.** Its function names and return types differ from `IPolicyGated`. Exact conformance
  is planned as a separate adapter interface.
- **Pause roles.** The base follows the brief's guardian prose: `pause` needs `GUARDIAN_ROLE`, and `unpause` needs
  the timelock. The brief's interface comments still say `PAUSER_ROLE`.
- **Extra reason codes.** `NO_HOOK` and `NO_RULES` are appended.
- **`canTransfer` scope.** It models holder-driven movements, with the operator set to `from`. A simulated burn
  respects frozen tokens. The enforcement paths `burn` and `forcedTransfer` release frozen tokens first.
- **`canExecute` scope.** It cannot check the signature, because the frozen interface has no signature parameter.
- **Duplicate rules.** A duplicate `ruleId` reuses `ComplianceHook_DuplicateRule`, so the frozen ABI is unchanged.
- **Mocks.** The brief's `MockAcceptHook` / `MockRejectHook` are replaced by `vm.mockCall`, per the Wonderland
  testing standard. `MockAsset` arrives with the vaults.
- **Deployment contracts.** `ProxyDeployer` and `TokenProxy` (in `contracts/deploy/`) are not in the brief. `TokenProxy`
  is OZ's `ERC1967Proxy` with only OZ's documented `_unsafeAllowUninitialized` override, so that it can be created
  without init data. That keeps its CREATE2 address independent of the hook; `ProxyDeployer` initialises it in the same
  transaction.
