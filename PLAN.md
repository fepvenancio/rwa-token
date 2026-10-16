# PLAN

Status: **Phase 3 approved and pushed (`49e7f4e`). Phase 4 (rules): plan written, awaiting review. No Phase 4 code yet.**

Brief v2 ("Gated Token Stack") replaced the original executor-only brief on 2026-10-16. On the same day the owner supplied a reference implementation in `Imported/` (now deleted; its contents live in `contracts/`) and approved, in chat, integrating it with the major findings fixed, a common-bug sweep, and the Wonderland Solidity standards.

## Standing decisions
| Date | Decision |
|---|---|
| 2026-10-16 | `rwaToken/` is its own git repo. |
| 2026-10-16 | solc 0.8.30 pinned in config, `cancun`; source pragmas `^0.8.28`. |
| 2026-10-16 | **License: proprietary, all rights reserved; use requires the owners' approval.** SPDX `UNLICENSED` everywhere; `package.json` is `private` + `UNLICENSED` (CLAUDE.md rule 15). |
| 2026-10-16 | **Wonderland Solidity standards** (CLAUDE.md rule 16). Lint config `.solhint.json`; formatting config `foundry.toml [fmt]`; imports through `remappings.txt`. |
| 2026-10-16 | Adopting the imported code settles the interface questions: the brief's names, **no ERC-7943 interface id** (its names and returns differ); frozen ≤ balance; keccak256 reason codes (`TRANSFER_OK` ≠ 0, fail-closed); guardian pauses, timelock unpauses. |
| 2026-10-16 | **Security tooling:** Slither is the gate. Mythril is dropped (no Cancun/transient support; noted in the brief). Halmos is kept because it was verified to run (see below). Aderyn is not needed. |
| 2026-10-16 | **Interfaces frozen.** `contracts/test/InterfaceFreeze.t.sol` pins every ERC-165 id, event topic and reason code. Exact ERC-7943 conformance will come later as a separate adapter interface. |
| 2026-10-16 | **Compiler:** one setting for the `default` and `production` profiles (optimizer on, 200 runs), so tests run on the deployed bytecode. `ContractSizes.t.sol` asserts EIP-170; the size limit is never lifted. |
| 2026-10-16 | Use `network.create()` / `getOrCreate()` in TS tests; `connect()` is `@deprecated` in Hardhat 3.20. Brief §9 is updated from the installed typings. |
| 2026-10-16 | **Hook-agnostic rules:** `BaseRule.onlyHook(ctx)` checks `IPolicyGated(ctx.token).policyHook() == msg.sender`; there is no `HOOK` immutable. Rules are deployed once and shared, and survive hook replacement. |
| 2026-10-16 | **One rule instance per `ruleId` per hook:** `_setRules` rejects duplicate `ruleId`s, reusing `ComplianceHook_DuplicateRule`. The frozen interface got a NatSpec-only change under explicit owner instruction; ABI and ids are unchanged. |

| 2026-10-16 | **Proprietary `LICENSE`**: Copyright (c) 2026 Filipe Venancio, all rights reserved. The repo is private, and the license is in place for a possible switch to public. |
| 2026-10-16 | **Nonces stay a per-signer bool map** (not a bitmap). Random nonces are chosen independently by the HSM/client, with no coupling to executor state. The brief is fixed. |
| 2026-10-16 | **No Multicall in the base:** keep the base minimal; Safe and the timelock already batch. Many-intents-per-tx belongs on the executor as `executeBatch` (Phase 3). |
| 2026-10-16 | **Phase 7: one implementation per template**, deployed and attested once, with one proxy per token (recorded in the brief). |
| 2026-10-16 | **Hook gas (review #1) and the telemetry flag (review #5): leave as is.** The brief's "rule list loaded into memory once" stands. |
| 2026-10-16 | **README**: architecture, commands, security model, and the deviations-from-brief list. |

## Owner decisions (2026-10-16, answers to the open questions)
1. **Freeze**, after one change: `IntentCancelled(address indexed _from, bytes32 indexed _nonce)`, with no fake zero hash. Pin the ERC-165 ids in a test. Exact ERC-7943 conformance comes later as a separate adapter interface and does not block the freeze.
2. **Constructor rules:** `ComplianceHook(admin, registry, token, initialRules[])`, each checked against the registry in the constructor. The token is live at deploy; the timelock governs only changes. The rules live in storage, so the codehash is unaffected.
3. **Optimizer on in the default build** (200 runs): tests run on the deployed bytecode. Do not lift the size limit; add a size assertion to CI.
4. **solhint** pinned, with a lint script, run in CI.
5. **Delete `Imported/`.** Originals are kept outside the repo.
6. **Drop Mythril** (no Cancun/transient support), and note why in the brief. Slither is the gate. Keep Halmos only if it really runs on the nonce/signature and frozen-balance paths; otherwise use Aderyn plus the invariant tests.

## Phase 0 — scaffold ✅ (`764b8ac`)
- **Toolchain:** Hardhat 3.20.0 (TypeScript, ESM, node:test + viem). Pinned exactly: OZ 5.6.1 (both packages), hardhat-keystore 3.1.2, forge-std v1.16.2, viem 2.57.7, typescript 6.0.3.
- **Profiles:** fuzz runs are 256. The compiler profiles were later unified (see decisions).

## Integration of the imported stack

### What exists now
| Area | Files |
|---|---|
| Interfaces | `Errors.sol` (`library Reasons`), `IPolicyGated`, `IPolicyHook` (+`TransferKind`, `TransferContext`), `IComplianceRule`, `IComplianceHook`, `IPolicyRegistry` (+`AttestKind`), `ITransferIntent` (+`TransferIntent`), `IIntentExecutor`, `IIdentityRule`, `IIdentityRegistry` |
| Base | `PolicyGatedERC20Upgradeable` |
| Governance | `PolicyRegistry` |
| Mixin / token | `IntentSettledUpgradeable`, `IntentToken` |
| Hooks | `ComplianceHook`, `BaseRule`, `rules/IdentityRule` |
| Test support | `test/Helpers.sol` (mock-and-expect), `PolicyGatedHarness`, `MockIdentityRegistry`, `MockReentrantRule`, `InterfaceFreeze.t.sol`, `ContractSizes.t.sol`, `halmos/IntentTokenHalmos.t.sol` |
| Tests | One `.t.sol` next to every contract. Unit tests isolate each contract with `vm.mockCall`; `IntentToken.t.sol` is the integration suite; there are 2 invariants (`Σbalances == totalSupply`, `frozen ≤ balance`). |

Not built yet: the `IntentExecutor` contract (Phase 3), `SettlementWindow`/`MaxHolders`/`Lockup` rules (Phase 4), vaults (Phase 5), viem tests (Phase 6), Ignition (Phase 7).

### Fixes (each has a regression test that went red first)
| # | Severity | Fix |
|---|---|---|
| F1 | High | `ComplianceHook` **fails closed**: an empty rule set returns `NO_RULES` (appended reason code). Before, a fresh token was ungated until the first timelocked `setRules`. The constructor now takes `initialRules[]` (each attested), so a token is live with its policy at deploy and the timelock only governs changes. |
| F2 | High | `IdentityRule` no longer checks `from` on FORCED, so a clawback from a de-verified holder works. `to` is still checked. Burns still check `from`, which keeps vault-exit gating; the enforcement path is clawback to a verified treasury, then burn. |
| F3 | Medium | `burn()` (BURNER_ROLE) can burn frozen tokens and releases the frozen amount, emitting `Frozen` before `Transfer`, as `forcedTransfer` does. A shared `_releaseFrozen` helper also checks balance first, so over-burns revert with `ERC20InsufficientBalance`. |
| F4 | Medium | `ComplianceHook.ADMIN` is `immutable`, so it is part of the attested codehash and a clone with another admin is no longer attested. |
| — | Low | `canTransfer` simulates a transfer *by `from`*: the operator is `from`, or the caller for a mint. Before, it was whoever made the pre-flight call. |
| — | Low | The hook is read **once** per `_update`; the same hook decides and receives `afterTransfer`. |
| — | Low | `ComplianceHook` caches each rule's `wantsAfter` as a bitmask at install time, so a rule can't change its answer later and there are fewer external calls per transfer. |
| — | Low | `PolicyRegistry.attest` rejects codehash `0` and `keccak256("")`, which could never match. |
| — | Info | `setFrozen` above the balance reverts with `PolicyGated_FrozenExceedsBalance` instead of a misused ERC-20 error. A dead `tstore` clear in `_moveAs` was removed (a revert already rolls transient storage back). |

### Common-bug sweep (checked, no change needed)
- **Signatures:**
  - Replay is blocked by the per-signer nonce.
  - Cross-chain and cross-token replay are blocked by the EIP-712 domain.
  - High-s malleability is rejected by OZ ECDSA.
  - ERC-1271 is checked via staticcall.
  - Permit and intents use distinct typehashes and nonces.
- **Reentrancy:** `_update` is `nonReentrant` (transient), and rule calls into the token revert (integration-tested).
- **Upgrades:** the implementation is locked by `_disableInitializers`; double init is blocked; an upgrade needs `UPGRADER_ROLE` plus an attested implementation; state survives an upgrade (tested); ERC-7201 slots were verified with `cast index-erc7201`.
- **ERC-20 semantics:** `transfer` reverts rather than returning false; allowance is spent before `_update`; mint and burn to or from address(0) are guarded by OZ.
- **Bounded loops:** at most 16 rules.

### Owner-decision changes (2026-10-16)
- `IntentCancelled(address indexed _from, bytes32 indexed _nonce)`; the fake zero hash is gone.
- `ComplianceHook(admin, registry, token, initialRules[])`, sharing the internal `_setRules` with `setRules`. A test confirms the rules don't affect the codehash. **Deploy order:** deploy the rules (hook-agnostic; can be shared and attested once) → attest the rules → deploy the hook with its rules (bound to the predicted proxy) → attest the hook and implementation → deploy the proxy.
- The optimizer is on in `default`; `ContractSizes.t.sol` runs in CI.
- `solhint-community@4.0.1` is pinned. Scripts: `lint:sol` (`--max-warnings 0`), `fmt:check`, `typecheck`, `test`, `test:halmos`. `.solhintignore` skips tests.
- CI (`.github/workflows/ci.yml`):
  - **test job:** lint, typecheck, `hardhat test`.
  - **analysis job:** `forge fmt --check`, `slither .`, Halmos.
  - Tools are pinned: Foundry v1.8.1, slither 0.11.5, halmos 0.3.3, Node 24.
  - GitHub SSH is rewritten to HTTPS because forge-std is a git dependency. This was verified with SSH disabled.
- **Halmos verdict: keep.** It runs on the real proxied `IntentToken` (transient storage, delegatecall, symbolic `ecrecover`); 4 properties pass. **Mutation check:** each of 4 planted bugs (nonce not consumed, cancel not recorded, frozen check skipped, burn not releasing frozen) is killed by its property. Halmos discards reverting paths, so liveness properties assert on revert explicitly.
- **Slither gate:** `slither.config.json` excludes only detectors that are false project-wide (naming, assembly, timestamp, calls-loop). The 3 accepted instances are suppressed inline with reasons. It exits 0 on clean code and 255 when a finding is reintroduced (verified).

### Phase 4 design notes (from external review, validated)
- ✅ **Rules are hook-agnostic** (owner decision). `BaseRule` has no `HOOK`, so the zero-hook gap is gone with it. Tests cover:
  - one instance serving two tokens, each hook accepted only for its own token;
  - a replaced hook losing access at once;
  - an identical codehash for identical configuration.
- ✅ **Duplicate `ruleId`s are rejected** (owner decision; regression test went red first).
- Open for `MaxHoldersRule`: `isUserAllowed` builds a MINT context with amount 0, so the rule must decide whether a zero-amount mint counts against the cap.

### New fact for Phase 7
`UUPSUpgradeable` stores `address(this)` in an immutable, so **every implementation deployment has its own codehash**. IMPLEMENTATION attestations therefore cover one deployed instance, not a source version (tested).

### Verification
```
npm test             →  154 passing (153 solidity, 1 nodejs), incl. 2 invariants × 256 runs, size + freeze guards
npm run typecheck    →  clean
npm run lint:sol     →  0 warnings
npm run fmt:check    →  clean
slither .            →  0 results (exit 0)
npm run test:halmos  →  4 passed; 0 failed
```
**Accepted Slither findings** (by config or inline, with reasons):
- `reentrancy-events`: the events come after the guarded, attested `afterTransfer`.
- `uninitialized-local`: `_mask` starts at 0 by design.
- `calls-loop`: at most 16 attested rules.
- `timestamp`: the intent deadline.
- `assembly`: ERC-7201 accessors.
- `naming-convention`: Wonderland uses `_camelCase`.

### Deviations from the brief
- **Interface files:** there are three more than brief §3 lists: `IComplianceHook`, `IIdentityRule` and `IIdentityRegistry`. Wonderland gives every contract an interface. Structs and enums live inside their interfaces, so there is no `Types.sol`.
- **Error names:** errors are `<Contract>_<Name>` (e.g. `PolicyGated_TransferRejected(bytes32)`). Event parameters are `_camelCase`; topics are unaffected.
- **Rule management:** initial rules come through the constructor; `setRules` replaces the whole list atomically instead of add/remove/reorder. The brief is updated to match.
- **Mocks:** the brief's `MockAcceptHook`/`MockRejectHook` are replaced by `vm.mockCall`, per Wonderland. `MockAsset` waits for the vaults.
- **Smoke test:** `test/nodejs/smoke.test.ts` is kept so the node runner isn't empty until Phase 6.

## Phase 3 — IntentExecutor ✅ (approved 2026-10-16)

### Already done in Phase 3 scope
`IntentSettledUpgradeable` and `IntentToken` were integrated earlier and are tested for:
- replay, expiry (with an inclusive deadline), wrong chain and wrong token domain;
- high-s malleability, ERC-1271 signers, and a tampered intent;
- cancel then execute, role gating, and `canExecute` parity.

What's left is the executor.

### Goal
`contracts/intents/IntentExecutor.sol`, the replaceable, role-gated layer that submits holder-signed intents to tokens:
- `execute(token, intent, sig)`, implementing the frozen `IIntentExecutor`;
- `executeBatch(token, intents[], sigs[])` for many intents in one transaction.

### Design (defaults; changes need review)
- **Immutable, not a proxy.** "Replaceable" means deploy a new executor, have the token's timelock grant it `EXECUTOR_ROLE`, and revoke the old one. There is no registry attestation (`AttestKind` has no EXECUTOR kind); the token's role grant is the authorisation.
- **Access:** OZ `AccessControl`. `DEFAULT_ADMIN_ROLE` is the timelock. `OPERATOR_ROLE` is the bank/relayer keys allowed to submit. (The token-side role stays `EXECUTOR_ROLE`, held by this contract.)
- **Forward only.** The executor calls `ITransferIntent(token).executeTransfer(intent, sig)` and returns its hash. The token stays the single source of truth for signature, nonce, deadline, freeze, pause and policy, so nothing is checked twice. Token reverts bubble up unchanged (`PolicyGated_TransferRejected(reason)`).
- **Audit trail.** The token's `IntentExecuted` records the executor contract; the operator is the transaction's caller. No extra executor event: the executor has no state of its own.
- **Interface:** `IIntentExecutor` stays frozen. `executeBatch`, its error and (if chosen) pause semantics go in a **new** `IIntentExecutorBatch` interface, which is ERC-165-advertised and added to `InterfaceFreeze.t.sol` once approved.

### Tests first (red run shown before the implementation)
- **Unit** (`vm.mockCall` on the token):
  - only `OPERATOR_ROLE` can call;
  - forwards the exact calldata and returns the token's hash;
  - token revert data bubbles up byte-for-byte;
  - batch length mismatch reverts;
  - an empty batch is a no-op;
  - batch atomicity, per D3;
  - pause behaviour, per D1;
  - ERC-165.
- **Integration:** a real `IntentToken`, `ComplianceHook` and `IdentityRule`, with the executor granted `EXECUTOR_ROLE`:
  - an operator settles a signed intent, and `IntentExecuted` shows the executor;
  - a non-operator is rejected;
  - once the token revokes the role, execution fails;
  - a batch of N signed intents settles in one transaction;
  - a bad intent in the batch behaves per D3;
  - `canExecute` from the executor's address agrees with execution.
- **Guards:** a size check for `IntentExecutor`; freeze pins for the new interface.

### Owner decisions (2026-10-16)
- **D1 (a):** the guardian pauses the executor; the timelock unpauses (OZ `Pausable`).
- **D2 (a):** any token that grants `EXECUTOR_ROLE`; no allowlist.
- **D3 (a):** all-or-nothing. A batch is one accounting event. It reverts with `IntentExecutor_BatchItemFailed(index, tokenRevertData)` so the operator can drop the failing intent and resubmit.
- **D4 (a):** `IIntentExecutorBatch` is a separate interface with ERC-165 id `0x117727cb`, pinned in `InterfaceFreeze.t.sol`. `IIntentExecutor` stays frozen.

### As built
- `contracts/interfaces/IIntentExecutorBatch.sol` contains `executeBatch`, `pause` and `unpause`, plus the errors `IntentExecutor_BatchItemFailed`, `IntentExecutor_LengthMismatch` and `IntentExecutor_ZeroAddress`.
- `contracts/intents/IntentExecutor.sol`: OZ `AccessControl` + `Pausable`, immutable, forward-only. `execute` bubbles the token's revert unchanged; `executeBatch` wraps a failure with its index.
- `IntentExecutor.t.sol` (24 tests):
  - **unit:** role gating, exact forwarding, revert bubbling, length mismatch, empty batch, ordered hashes, failing index with the token's reason (fuzzed position), pause asymmetry, ERC-165;
  - **integration** on the real stack: settlement with the executor recorded in `IntentExecuted`, `canExecute` from the executor's address, role revocation, executor pause not blocking other executors, atomic batch failure (no balance or nonce change), and drop-and-resubmit.
- Process: the tests were red first (the executor was missing); the implementation went green on its first run. **Mutation check:** making the batch best-effort is caught by 3 tests.
- `ContractSizes.t.sol` covers `IntentExecutor`; the brief and README are updated.

### Verification
```
npm test             →  178 passing (177 solidity, 1 nodejs)
lint / typecheck / fmt  →  clean
slither .            →  0 results
npm run test:halmos  →  4 passed; 0 failed
```

## Phase 4 — rules (PLAN, awaiting review)

### Already done in Phase 4 scope
- `ComplianceHook`: ordering, short-circuit, the 16-rule cap, constructor rules, fail-closed, one instance per `ruleId`.
- `BaseRule`: hook-agnostic `onlyHook(ctx)`.
- `IdentityRule`, `MockReentrantRule` and `MockIdentityRegistry`.

What's left is the three rules from brief §6.

### Goal
- **Contracts:** `SettlementWindowRule`, `MaxHoldersRule` and `LockupRule` in `contracts/hooks/rules/`. Each inherits `BaseRule`, keys all state by `ctx.token`, and is one shared, attested instance for every token.
- **Interfaces** (Wonderland: events and errors in the interface): `ISettlementWindowRule`, `IMaxHoldersRule` and `ILockupRule`, as new files in `contracts/interfaces/`, pinned in `InterfaceFreeze.t.sol` once built. The existing frozen files are untouched.
- **Reason codes:** `OUTSIDE_SETTLEMENT_WINDOW`, `MAX_HOLDERS` and `LOCKED` already exist, so no new codes.

### Rule designs (defaults; the open choices are P1–P6)
- **`LockupRule`** (`ruleId` `LockupRule.v1`). It holds an unlock timestamp per (token, holder).
  - **Check:** TRANSFER and EXECUTED return `LOCKED` while `block.timestamp < unlock[token][from]`. FORCED, BURN and MINT are exempt (a mint only adds to a balance).
  - **Scope:** the lock covers the holder's whole balance, including tokens received later, as the brief specifies.
  - **Setter:** `setLockup(token, holder, unlockTime)`, callable by the token's `AGENT_ROLE` (operational, no delay; the agent can already freeze, so this adds no power). It emits `LockupSet`, and bulk issuance batches through the Safe.
- **`SettlementWindowRule`** (`ruleId` `SettlementWindowRule.v1`). It applies to EXECUTED only, and outside the window it returns `OUTSIDE_SETTLEMENT_WINDOW`. Window shape: P6.
- **`MaxHoldersRule`** (`ruleId` `MaxHoldersRule.v1`, `wantsAfter() == true`). It keeps a cap and a holder count per token.
  - **Check:** a movement that *adds* a holder is rejected with `MAX_HOLDERS` if the net count would exceed the cap. An account is "added" when it gets a non-zero amount while holding zero; the sender drops out if its balance goes to zero. Moving a full balance to a new holder at the cap is therefore allowed.
  - **Reductions are never blocked**, even if the cap is later lowered below the current count.
  - **`after_`:** updates the count from post-movement balances. Self-transfers and zero amounts never change it.

### Decisions needed (my recommendation first)
- **P1. Who configures per-token parameters** (cap, window), and how deployment avoids a 7-day dead token.
  - **(a) Recommended: the token's own roles, checked live.** The rule asks `IAccessControl(token).hasRole(…)`, as `onlyHook` does: policy parameters (cap, window) need the token's `DEFAULT_ADMIN_ROLE` (the timelock), and per-holder data (lockups) needs its `AGENT_ROLE`. It's sound for the same reason as `onlyHook`: a fake token can only write its own key. One shared instance per rule type, parameter changes need no redeploy, and holder counts survive.
    - **Bootstrap (Phase 7):** "configure, then hand over". The deploy script initialises the token with the deployer as temporary admin, configures the rules, grants the timelock admin and renounces, all in one deployment.
  - (b) Immutable parameters per rule instance. There's no bootstrap issue, but each new cap or window means a new instance and re-attestation, and **swapping a `MaxHoldersRule` loses its holder counts**.
- **P2. Amend brief §6 so rules can make *view* calls to `ctx.token`.** `MaxHoldersRule` must read `balanceOf`, and P1(a) reads `hasRole`. The brief's "read only own storage" and "no call back into the token" would forbid both.
  - **Recommended:** amend to "view calls to `ctx.token` are allowed; state-changing calls are forbidden (`MockReentrantRule` still proves the latter)". This is the reading already applied to `onlyHook`.
  - The alternative is to mirror every balance inside the rule: double storage writes per transfer, and it drifts if the rule is added to a live token.
- **P3. Zero-amount movements and `isUserAllowed`.** `isUserAllowed` simulates a zero-amount mint.
  - **Recommended:** zero amounts never add a holder, so `isUserAllowed` answers "may this account hold the token?" (identity, lockups) independently of whether the cap is full.
  - The alternative makes it report `false` while the cap is full.
- **P4. Which movements the cap applies to.**
  - **Recommended:** every kind that can add a holder (TRANSFER, EXECUTED, MINT, FORCED), counted net. BURN can't add one.
  - The alternative exempts FORCED so a clawback into a new treasury account can't be blocked; the default handles that by keeping the treasury a holder or using net counting.
- **P5. Adding `MaxHoldersRule` to a token that already has holders.**
  - **Recommended:** supported from genesis, through constructor rules or before the first mint. Adding it to a live token needs a one-time `seedHolderCount(token, n)` by the token's admin (timelock), allowed only while the count is untracked, with `n` verified off-chain.
  - Removing the rule from a hook and re-adding it later also requires a re-seed (documented).
- **P6. Window shape.**
  - **Recommended:** a daily UTC window `[open, close)` in seconds of the day (an overnight window is allowed when `open > close`), plus a weekday mask (default Mon–Fri). Holidays are not on-chain; use the executor pause or don't submit.
  - An unconfigured token **fails closed**: every EXECUTED movement is rejected.

### Tests first (red run shown before each implementation)
- **Per rule `<Name>Rule.t.sol`** (brief §6 step 4), unit tests with `vm.mockCall` on the token:
  - accept, and each rejection;
  - every exemption by kind;
  - fuzzed boundaries: the unlock second, window edges and the midnight wrap, cap ± 1, full-balance moves at the cap;
  - setter auth via the token's roles, and the fake-token-only-writes-its-own-key property;
  - view-ness (a `check` that mutates state would fail);
  - events and ERC-165.
- **`MaxHoldersRule` invariant:** `count == number of actors with balance > 0`, over random mint, transfer, forced and burn moves against a real token.
- **Integration** (brief §6 step 5), on the real stack: each rule registered in the hook, with `canTransfer` / `canExecute` agreeing with the state-changing call.
- **Recommended full order:** Identity → Lockup → SettlementWindow → MaxHolders (cheap static checks first, the stateful counter last).
- **Guards:** a size check per rule; freeze pins for the 3 new interfaces; Slither and Halmos stay green.

## Open questions for the owner
1. P1–P6 above. "defaults" accepts every recommendation.
