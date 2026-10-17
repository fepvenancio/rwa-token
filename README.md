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

The audit package (scope, suppressions, mutation results, findings an auditor should know first) is indexed in
[`SECURITY.md`](SECURITY.md).

| Power | Holder | Delay | Can |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | TimelockController | ≥ 7 days | grant/revoke every role, `unpause`, `setPolicyHook`, change hook rules, manage attesters |
| `GUARDIAN_ROLE` | multisig | none | `pause` the token and cancel pending main-timelock operations. **It can only stop things:** no unpause, no upgrades, no role or hook changes, and no veto over its own removal (see `RECOVERY_ROLE`) |
| `RECOVERY_ROLE` | recovery timelock | ≥ 7 days | on every token, vault and the executor: `unpause` and revoke `GUARDIAN_ROLE`; on the main timelock: revoke `CANCELLER_ROLE`. Nothing else. Governance proposes and executes; nobody can cancel |
| `UPGRADER_ROLE` | timelock | ≥ 7 days | upgrade, only to an implementation attested as `IMPLEMENTATION` |
| `MINTER_ROLE` / `BURNER_ROLE` | issuer | none | mint, and burn (enforcement burns can take frozen tokens) |
| `AGENT_ROLE` | issuer | none | `forcedTransfer` (clawback; bypasses pause and freeze, still policy-checked), `setFrozen`; on the 7540 vault, `recoverRedeemRequest` (escrow → verified recovery account) and `recoverClaimable` (claimable assets and shares → verified recovery account, even while paused or at a full cap) |
| `EXECUTOR_ROLE` | `IntentExecutor` contract | none | settle holder-signed intents; it cannot alter them |
| `OPERATOR_ROLE` (executor) | bank / relayer keys | none | submit intents via `execute` / `executeBatch` (all-or-nothing) |
| `GUARDIAN_ROLE` (executor) | multisig | none | pause the executor only; the timelock unpauses |
| `ATTESTER_ROLE` (registry) | security council | none | attest / revoke codehashes |
| token `DEFAULT_ADMIN_ROLE` → rules | timelock | ≥ 7 days | set a token's holder cap, seed its holder count, set its settlement window |
| token `AGENT_ROLE` → rules | issuer | none | set or clear per-holder lockups |
| `FULFILLER_ROLE` (7540 vault) | bank | none | fulfil deposits/redemptions at off-chain NAV; reject pending requests |

- **Attested code only.** Hooks, rules and implementations are installed only if their runtime codehash is attested.
  Attestation is checked at install time; revoking it later does not silently change a live token.
- **Attestation covers hook code and binding, not rule set; the rule set is governed by the timelock.** A hook's
  admin, registry and token are immutables inside its attested codehash; its ordered rule list lives in storage. Each
  rule is attested on its own, and only the timelock can change the list (`setRules`) or install another hook.
- **Immutable policy components.** Hooks and rules are never proxies. Changing one means deploying a new one and
  swapping it in through the timelock. The hook's admin, registry and token are `immutable`, so they are part of the
  attested codehash.
- **Fail closed.** `TRANSFER_OK` is non-zero, and a hook with no rules rejects everything (`NO_RULES`). Every
  rejection reverts with `PolicyGated_TransferRejected(bytes32 reason)`; `transfer` never returns `false`.
- **Pre-flight parity.** `canTransfer` and `canExecute` run the same checks as the state-changing path.
- **Reentrancy.** `_update` is `nonReentrant` (transient storage); rules cannot call back into the token.
- **Reproducible builds.** solc 0.8.30, cancun, optimizer 200 runs, and no metadata hash, in both Hardhat and forge.
  Every codehash and CREATE2 address can be recomputed from the source at a tag; CI fails if two clean builds disagree.
- **Deployment.** One implementation per template, deployed and attested once, with one proxy per token. Each
  implementation deployment has its own codehash, because UUPS stores `address(this)` in an immutable. Each proxy sits
  at a CREATE2 address fixed before its hook exists, and `ProxyDeployer` refuses to deploy unless the hook is bound to
  that address (see the runbook below).

## Deployment runbook

Three Ignition modules in `ignition/modules/`, with two security-council steps between them. Each stage takes the
previous stages' addresses as parameters. `test/nodejs/fixtures.ts` runs this exact sequence on the local network,
playing the council and the identity provider, and ends with the post-deploy checks below.

1. **`Components`** (deployer):
   - the recovery timelock (plain OZ `TimelockController`, ≥ 7 days, governance multisig as proposer and executor),
     then the main timelock (`GovernanceTimelock`: ≥ 7 days, proposer **and** executor the governance multisig only;
     the recovery timelock may revoke `CANCELLER_ROLE` there). The deployer is the admin of both until `Activate`;
   - the `PolicyRegistry`: admin = timelock, attester = council;
   - the four rules, one implementation per template, `ProxyDeployer` (owner = deployer), and `IntentExecutor`.

   Parameters: `governance`, `council`, `guardian`, `identityRegistry`, `minDelay`.
2. **Council step 1.** Attest only when two independent sources agree:
   - **Reproduce:** check out the release tag and run `npm ci && npm run verify:reproducible`. This builds from clean
     several ways, fails unless they all agree, and writes `release-build/manifest.json`.
   - **Compare with the published reference:** the release's `release-build-<tag>.tar.gz`, attached by the release
     workflow, after checking its `.sha256`. Its `manifest.json` must equal yours, contract by contract.
   - **Compare with the chain:** for each rule and implementation, take the manifest's `runtime` code, fill its
     `immutableSlots` with the bytes at the same positions in the deployed code, and confirm those bytes are the
     expected constructor arguments (e.g. `IdentityRule`'s identity registry; an implementation's own address). Then
     confirm the keccak256 of the result equals `extcodehash`.
   - Then `attest(codehash, RULE | IMPLEMENTATION, auditUri)`. The record for the change board reads: computed from the
     source at tag X, matched the release build, matched the chain.

   Also compute where each token will live, before any hook or proxy exists:
   `CREATE2(ProxyDeployer, salt = keccak256(utf8(symbol)), initCode = TokenProxy.creationCode ++ abi.encode(implementation, ""))`,
   with `TokenProxy.creationCode` from the manifest's `TokenProxy.creation`. `ProxyDeployer.predict(symbol,
   implementation)` returns the same address. Builds carry no metadata hash, so this code is the same in every clean
   build at the tag, and `verify:reproducible` checks that `ProxyDeployer` embeds exactly it.
3. **`Tokens`** (deployer): one `ComplianceHook` per token, with `ADMIN` = timelock, `TOKEN` = the predicted address,
   and the token's initial rules in the constructor (which re-checks each rule's attestation).
4. **Council step 2.** For each hook:
   - check that `TOKEN()` equals the address computed in step 2, `ADMIN()` is the timelock and `REGISTRY()` is the
     registry;
   - read `rules()` and compare it with the intended ordered list (`RULE_ORDER` in `ignition/modules/roles.ts`): the
     attestation covers the code and the immutables, not the rule list, which lives in storage;
   - then `attest(codehash, HOOK, auditUri)`, and **record the hook addresses reviewed**. These are the addresses
     passed to `Activate` as `<token>Hook`.

   `TOKEN` is an immutable, so the codehash covers the token: the council attests *this hook for this token*, which
   means one attestation per token, not per hook type. A later hook with the same admin, registry and token shares that
   codehash whatever its rules, and only the timelock can install it, after the delay.
5. **`Activate`** (deployer):
   - `ProxyDeployer.deploy(symbol, implementation, initData, hook)` for each token. It reverts **before creating the
     proxy** if `hook.TOKEN()` is not the predicted address, initialises in the same transaction, then checks the
     installed hook and the symbol. A symbol can be used once; a reverted deploy (mis-bound hook, failed `initialize`)
     leaves no proxy and does not use up the symbol. Every later call waits for all three deploys, so one
     mis-bound hook grants nothing anywhere;
   - configure: settlement window, holder caps, the 7540 vault's holder-cap exemption;
   - grant roles: MINTER, BURNER and AGENT to the issuer's accounts, EXECUTOR to `IntentExecutor`, FULFILLER to the
     bank, OPERATOR to the relayer, **UPGRADER to the timelock only**, CANCELLER on the timelock to the guardian;
   - hand over: DEFAULT_ADMIN_ROLE to the timelock on every token and on the executor; the deployer renounces it there
     and on the timelock; `ProxyDeployer` ownership moves to the timelock, so any later token is placed through
     governance (schedule `deploy`, wait out the delay, execute).
6. **Identity provider:** verify the 7540 vault, which escrows pending redemptions.
7. **Post-deploy checks** (the fixture's `assertHandedOver`):
   - the deployer holds no role on the timelock, registry, tokens or executor;
   - the timelock holds DEFAULT_ADMIN_ROLE everywhere and is the only UPGRADER;
   - every token's `policyHook()` is the hook address the council recorded in step 4, that hook's `TOKEN` is the
     token, and its `rules()` equals `RULE_ORDER`. A twin hook with the same immutables but other rules carries the same
     attested codehash and passes `ProxyDeployer`; this check is what refuses it;
   - the guardian can cancel main-timelock operations but cannot propose or execute them, and holds nothing on the
     recovery timelock;
   - the recovery timelock holds exactly `RECOVERY_ROLE` on each token, vault, the executor and the main timelock,
     nothing elsewhere, and has no cancellers (governance's automatic one is revoked in `Activate`);
   - `ProxyDeployer.owner()` is the timelock;
   - `getMinDelay() ≥ 7 days` on both timelocks.

   The recovery timelock's proposer and executor is the governance multisig. A compromised governance multisig is
   out of scope for this control, by design: recovery bounds the guardian, not governance.

## Commands

Requires Node 24 (CI pins 24.21.0). Foundry v1.8.1, Python 3.12 with `ci/requirements.txt` (slither, halmos) and the
pinned Aderyn binary are needed only for the analysis commands.

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
scripts/fetch-tool.sh aderyn   # installs the sha256-pinned Aderyn release binary (tools.lock) into .tools/bin
```

```bash
npm run aderyn        # second static-analysis gate (Cyfrin Aderyn); exclusions in aderyn.toml, the rest inline
```

```bash
pip install --require-hashes -r ci/requirements.txt   # slither + halmos with every dependency hash-pinned
```

```bash
npm run test:halmos   # symbolic properties: nonce/signature and frozen-balance paths
```

```bash
npm run validate:upgrades   # OZ upgrades-core over a Foundry build with storage layouts
```

```bash
npm run verify:reproducible # identical bytecode across clean Hardhat (production, default) and forge builds; writes release-build/
```

CI runs the reproducibility check on pull requests into `main`. On a `v*` tag, `.github/workflows/release.yml` reruns it
and attaches `release-build-<tag>.tar.gz` (manifest plus in-scope build-info, with its sha256) to the release as the
council's reference.

CI (`.github/workflows/ci.yml`) runs all of the above on every push and pull request, except the reproducibility check
(pull requests into `main` and tags only).

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
