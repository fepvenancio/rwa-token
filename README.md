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
(planned) Gated4626Vault, Gated7540Vault

ComplianceHook (one per token, immutable) ──► ordered list of ≤16 attested IComplianceRule (first rejection wins)
IdentityRule, (planned) SettlementWindowRule, MaxHoldersRule, LockupRule   hook-agnostic, shareable across tokens
PolicyRegistry (one per deployment, immutable)  codehash allowlist: HOOK / RULE / IMPLEMENTATION
(planned) IntentExecutor                         replaceable, role-gated submitter of intents
```

| Path | Contents |
|---|---|
| `contracts/interfaces/` | Frozen ABI: `IPolicyGated`, `IPolicyHook`, `IComplianceRule`, `IComplianceHook`, `IPolicyRegistry`, `ITransferIntent`, `IIntentExecutor`, `IIdentityRule`, `IIdentityRegistry`, `Errors.sol` (reason codes) |
| `contracts/base/` | `PolicyGatedERC20Upgradeable` |
| `contracts/governance/` | `PolicyRegistry` |
| `contracts/mixins/`, `contracts/tokens/` | `IntentSettledUpgradeable`, `IntentToken` |
| `contracts/hooks/` | `ComplianceHook`, `BaseRule`, `rules/IdentityRule` |
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
| `AGENT_ROLE` | issuer | none | `forcedTransfer` (clawback; bypasses pause and freeze, still policy-checked), `setFrozen` |
| `EXECUTOR_ROLE` | executor | none | settle holder-signed intents; it cannot alter them |
| `ATTESTER_ROLE` (registry) | security council | none | attest / revoke codehashes |

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
  implementation deployment has its own codehash, because UUPS stores `address(this)` in an immutable.

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

CI (`.github/workflows/ci.yml`) runs all of the above on every push and pull request.

## Deviations from the brief

The brief is in [`CLAUDE.md`](CLAUDE.md). Where the code intentionally differs, it is recorded here:

- **More interface files.** There are three beyond those listed in brief §3: `IComplianceHook`, `IIdentityRule` and
  `IIdentityRegistry`. Wonderland standards give every contract an interface. Structs and enums live inside their
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
- **Smoke test.** `test/nodejs/smoke.test.ts` stays until the Phase 6 viem tests replace it.
