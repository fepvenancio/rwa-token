# PLAN

Status: **v0.2.0 released (2026-10-18): review fixes M-1, M-2, M-3, L-2, L-3; L-4 and L-5 documented; L-1 accepted. Change-board page published.**

Brief v2 ("Gated Token Stack") replaced the original executor-only brief on 2026-10-16. On the same day the owner supplied a reference implementation in `Imported/` (now deleted; its contents live in `contracts/`) and approved, in chat, integrating it with the major findings fixed, a common-bug sweep, and the Wonderland Solidity standards.

## Standing decisions
| Date | Decision |
|---|---|
| 2026-10-16 | The project is its own git repo. |
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
- **Access:** OZ `AccessControl`. `DEFAULT_ADMIN_ROLE` is the timelock. `OPERATOR_ROLE` is the issuer/relayer keys allowed to submit. (The token-side role stays `EXECUTOR_ROLE`, held by this contract.)
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

## Phase 4 — rules ✅ (awaiting review)

### Already done in Phase 4 scope
- `ComplianceHook`: ordering, short-circuit, the 16-rule cap, constructor rules, fail-closed, one instance per `ruleId`.
- `BaseRule`: hook-agnostic `onlyHook(ctx)`.
- `IdentityRule`, `MockReentrantRule` and `MockIdentityRegistry`.

What's left is the three rules from brief §6.

### Goal
- **Contracts:** `SettlementWindowRule`, `MaxHoldersRule` and `LockupRule` in `contracts/hooks/rules/`. Each inherits `BaseRule`, keys all state by `ctx.token`, and is one shared, attested instance for every token.
- **Interfaces** (Wonderland: events and errors in the interface): `ISettlementWindowRule`, `IMaxHoldersRule` and `ILockupRule`, as new files in `contracts/interfaces/`, pinned in `InterfaceFreeze.t.sol` once built. The existing frozen files are untouched.
- **Reason codes:** `OUTSIDE_SETTLEMENT_WINDOW`, `MAX_HOLDERS` and `LOCKED` already exist, so no new codes.

### Owner decisions (2026-10-16)
- **P1. Configuration authority.** Rule configuration is authorised live through `IAccessControl(token).hasRole(…)`:
  - the token's `DEFAULT_ADMIN_ROLE` sets the cap and the window;
  - its `AGENT_ROLE` sets lockups.

  "Configure, then hand over" is a single Ignition module (Phase 7). Its last step **asserts the deployer holds no role on the token, the hook, or any rule.**
- **P2. View calls into the token.** Brief §6 now reads: "Rules may make view calls to the token (`balanceOf`, `hasRole`, `policyHook`, `getFrozen`). State-changing calls are forbidden and blocked by the guard."
- **P3. Holder definition.** A holder is any account with balance > 0, and zero amounts never add one. `isUserAllowed` stays "may hold", not "may hold right now".
- **P4 (changed from my recommendation). FORCED and the cap.** FORCED is **exempt from the cap check** in `check()`, but **still counted** in `after_()`. MINT, TRANSFER and EXECUTED are capped, counted net.
- **P5. Seeding the count.** `seedHolderCount(token, n)` is callable by the token's `DEFAULT_ADMIN_ROLE` **at any time** and emits `HolderCountSeeded(token, old, new)`. It is documented as legitimate only while the rule is not in the token's active set; the correct value can be recomputed from `Transfer` events. The invariant test covers continuous operation only.
- **P6. Settlement window.**
  - Shape: a daily UTC window plus a weekday mask, with Mon–Fri as the default. An installed but unconfigured window fails closed.
  - Weekday: `((ts / 1 days) + 3) % 7`, with Mon = 0. Verified against calendar dates.
  - Same-day window: `isDay(today) && t >= open && t < close`.
  - Overnight window: `(isDay(today) && t >= open) || (isDay(yesterday) && t < close)`.
  - The tests cover Monday 01:00 and Saturday 01:00 for an overnight window.

### Rule designs (final)
- **`MaxHoldersRule`** (`MaxHoldersRule.v1`, `wantsAfter() == true`). It keeps a cap and a count per token.
  - **`check()`** uses pre-transfer balances, in order:
    1. `amount == 0 || from == to || to == address(0)` → OK.
    2. `balanceOf(to) > 0` → OK (a lowered cap never blocks existing holders).
    3. `kind == FORCED` → OK (P4).
    4. Otherwise, with `senderLeaves = from != 0 && balanceOf(from) == amount`, reject with `MAX_HOLDERS` if `cap == 0` (fail closed) or `count + (senderLeaves ? 0 : 1) > cap`.
  - **`after_()`** (only the token's hook) uses post-transfer balances:
    - return early if `amount == 0 || from == to`;
    - `to` became a holder iff `to != 0 && balanceOf(to) == amount`, so the count goes up;
    - `from` left iff `from != 0 && balanceOf(from) == 0`, so the count goes down.
  - **Unseeded count:** the arithmetic is checked. If the rule is active on a live token with an unseeded or wrong count, an exit that would take the count below zero reverts, so the token fails closed until the admin re-seeds.
  - **Admin (token `DEFAULT_ADMIN_ROLE`):** `setCap(token, cap)` emits `CapSet(token, old, new)`; `seedHolderCount(token, n)` emits `HolderCountSeeded`.
- **`LockupRule`** (`LockupRule.v1`).
  - **Check:** TRANSFER and EXECUTED return `LOCKED` while `block.timestamp < unlock[token][from]`. FORCED, BURN and MINT are exempt.
  - **Setter:** `setLockup(token, holder, t)`, by the token's `AGENT_ROLE`. **A `t <= block.timestamp` clears the lockup** (stored as 0). Emits `LockupSet`.
- **`SettlementWindowRule`** (`SettlementWindowRule.v1`).
  - **Check:** EXECUTED only, per P6.
  - **Setter:** `setWindow(token, open, close, dayMask)`, by the token's `DEFAULT_ADMIN_ROLE`. It requires `open, close < 1 days`, `open != close`, and a non-zero 7-bit mask. `MON_TO_FRI = 0x1F` is the default value to pass. Emits `WindowSet`.

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

### As built (Phase 4)
- **Interfaces** (new files; the existing frozen ones are untouched): `ILockupRule` `0xaafb038e`, `ISettlementWindowRule` `0xf2058aff`, `IMaxHoldersRule` `0xa13cb93c`. These ids and the 5 new event topics are pinned in `InterfaceFreeze.t.sol`. Each value was computed independently with `cast` and matches the compiler.
- **Rules:** `LockupRule`, `SettlementWindowRule` and `MaxHoldersRule`, implemented exactly per the owner decisions and math above. Two small additions:
  - `SettlementWindowRule.isOpen(token, ts)`, a view for operators;
  - `HolderCountUpdated(token, count)`, emitted only when the count changes (Wonderland: an event on every state change).
- **Tests** (each red first, because the rules were missing; then green on the first implementation run):
  - **Unit:** every `check()` / `after_()` branch in spec order; setter auth through the token's roles; fake-token key isolation; staticcall view-ness; fuzzed boundaries (unlock second, window edges, cap ± 1, full-balance move at the cap); the owner's Monday-01:00 and Saturday-01:00 overnight cases; `isOpen` agreeing with `check`; the fail-closed underflow; events; ERC-165.
  - **Invariant:** `MaxHoldersRuleInvariantTest` runs on a **real** token deployed "configure, then hand over", with cap 3 and 4 actors. **Mutation check:** dropping the exit decrement, or the self-transfer skip, is caught.
  - **Integration** (`RuleSetIntegration.t.sol`, brief §6 step 5): all four rules in the recommended order on the real stack, with `canTransfer` / `canExecute` agreeing with the state-changing calls. It shows identity rejecting before the cap does, FORCED exempt but counted, a full-balance move at the cap, and the legitimate P5 seed (before the rule is active).
- **Slither gate:** it caught 6 new results. All were triaged and suppressed **inline at the exact lines, with reasons**; the global exclusion list is unchanged.
  - `weak-prng` (3): calendar modulo on the timestamp, not randomness.
  - `incorrect-equality` (3): the exact balance equalities are the owner's holder definition, read inside the token's guarded `_update`.
- **Brief §6** is updated: the P2 wording, rule-writing step 2, and the final definitions of the three rules.

### Verification (Phase 4)
```
npm test             →  241 passing (240 solidity, 1 nodejs)
lint / typecheck / fmt  →  clean
slither .            →  0 results
npm run test:halmos  →  4 passed; 0 failed
```

### External review of Phase 4 (2026-10-16): validation and follow-ups
- **Confirmed true:**
  - live role delegation;
  - the window math and the two overnight tests;
  - the `MaxHoldersRule` branch logic;
  - the rule-order rationale;
  - `amount = 1` making `maxDeposit` cap-aware;
  - the `maxWithdraw` rounding rule;
  - the vault-lockup gap and the 7540 custody question.
- **Corrected:**
  - there are no `_requireTokenAgent` / `_requireTokenAdmin` helpers (it's an inline check, and the `onlyTokenAdmin` modifier in `MaxHoldersRule`);
  - burns use `BURNER_ROLE`, not `ISSUER_ROLE`;
  - the lockup reason code is `LOCKED`, not `LOCKUP_ACTIVE`;
  - the invariant had 4 actors and 4 actions, with no freeze and no cap changes.
- **Fixed:**
  - added the missing `MaxHoldersRule` fake-token isolation test (setters and `after_`);
  - the invariant handler now also fuzzes `setFrozen` and `setCap`, including lowering the cap below the count. It is still mutation-checked: dropping the exit decrement is caught;
  - brief §7: `maxRedeem = balance - frozen` (gated), and `maxWithdraw = _convertToAssets(maxRedeem, Floor)`.
- **Verification:** `npm test` gives 242 passing (241 solidity, 1 nodejs). Lint, typecheck, fmt, Slither (0) and Halmos (4/4) are clean.

## Phase 5 — vaults (plan approved 2026-10-17; 5a in progress)

### Owner decisions (2026-10-17, all defaults)
- **V1 (a):** `LockupRule` exempts BURN **only** when `ctx.operator` holds the token's `BURNER_ROLE`. Holder-initiated burns (vault redemptions, 7540 requests) respect the lockup.
- **V2 (owner reversed, 2026-10-17): ESCROW.** `requestRedeem` *transfers* the shares to the vault, as a TRANSFER, so the lockup, frozen, identity and pause checks all apply. They are BURNed at fulfilment. Brief §7 stays as written. The vault address must be registered as a verified holder in the identity registry (an issuer-controlled contract, normal practice in ERC-3643 deployments).
  - Note: the hole cited for the reversal (a locked holder exiting through a redemption BURN) was already closed by V1. Escrow is kept for its other benefits: reversible via reject, and pending state visible for reconciliation.
- **V3 (a):** `FULFILLER_ROLE` fulfils with explicit amounts priced off-chain at NAV, with partial fulfilment allowed. Deposited assets go to a custody address at fulfilment; redemption assets are pulled from the fulfiller at fulfilment.
- **V4:**
  - deposit and redeem both async;
  - `requestId = 0`, aggregated per controller;
  - no cancellation;
  - operators honoured for claims;
  - async `preview*` revert.
- **V5 (a):** `_decimalsOffset() = 6`.

### Verified standard facts
These ERC-165 ids were recomputed from the signatures with `cast`, and all four match the spec:

| Interface | Composition | ID |
|---|---|---|
| ERC-7540 operator | `isOperator` ^ `setOperator` | `0xe3bc4e65` |
| ERC-7540 async deposit | `requestDeposit` ^ `pendingDepositRequest` ^ `claimableDepositRequest` ^ **`deposit(uint256,address,address)` ^ `mint(uint256,address,address)`** | `0xce3bbe50` |
| ERC-7540 async redeem | `requestRedeem` ^ `pendingRedeemRequest` ^ `claimableRedeemRequest` | `0x620ee8e4` |
| ERC-7575 | **every ERC-4626 vault function + `share()`** | `0x2f0a18c5` |

Our interface files are split exactly along these lines, so the compiled ids equal the standard's; they'll be pinned in `InterfaceFreeze.t.sol`.

OZ 5.6.1 provides `ERC4626Upgradeable`, with hooks `_deposit`, `_withdraw`, `_decimalsOffset`, `_convertTo*` and the `max*` functions. It has no 7540 interface or contract.

### Proposed split: two review checkpoints
- **5a:** V1 (the `LockupRule` change) and `Gated4626Vault`.
- **5b:** `Gated7540Vault`.

Each gets red tests, then the implementation, then green, then a stop for review.

### 5a-1. `LockupRule` (V1)
- `check`: TRANSFER and EXECUTED are locked as today. BURN is locked too, unless `IAccessControl(token).hasRole(BURNER_ROLE, ctx.operator)` (a view call, allowed by P2). FORCED and MINT stay exempt.
- `ILockupRule` is a frozen file. No new function or error is needed, but the NatSpec changes, so this edit is made under the owner's V1 instruction. Brief §6 is updated.
- **Tests:**
  - holder-initiated BURN is locked;
  - a BURN by a `BURNER_ROLE` operator is exempt;
  - a vault `redeem` by a locked holder is rejected with `LOCKED`, and `maxRedeem` returns 0 (integration).

### 5a-2. `Gated4626Vault` (`contracts/vaults/`)
- **Inheritance:** OZ `ERC4626Upgradeable` + `PolicyGatedERC20Upgradeable`. The diamonds are resolved explicitly: `_update` overrides both `ERC20Upgradeable` and the base, and `decimals` overrides both `ERC20Upgradeable` and `ERC4626Upgradeable`. UUPS, with `_disableInitializers` in the implementation constructor.
- **Share movements go through the hook:** `deposit`/`mint` arrive as MINT to the receiver, `withdraw`/`redeem` as BURN from the owner (operator = caller). The asset leg is a plain ERC-20 movement and is not hooked.
- **Gated `max*`** (brief §7):
  - `maxDeposit` / `maxMint` return 0 if paused or if `canTransfer(0, receiver, 1)` is not OK; otherwise OZ's value.
  - `maxRedeem` returns 0 if paused or if `canTransfer(owner, 0, 1)` is not OK; otherwise `balanceOf - getFrozen`.
  - `maxWithdraw` is `_convertToAssets(maxRedeem, Floor)`.
  - `preview*` stay pure conversions.
- **V5:** `_decimalsOffset() = 6`.
- **ERC-165:** IERC4626 (`0x87dfe5a0`, informational), plus everything the base advertises.
- **Tests:**
  - **Unit** (mocked hook/registry): every `max*` branch; `deposit(maxDeposit+1)` reverts and `deposit(maxDeposit)` succeeds (brief §7); the hook sees MINT/BURN contexts with the right operator; pause; frozen shares cap `maxRedeem`/`maxWithdraw`; the rounding rule (`withdraw(maxWithdraw)` always succeeds, fuzzed); the inflation-attack scenario is unprofitable with offset 6.
  - **Integration** (real Identity + MaxHolders + Lockup): unverified receivers get `maxDeposit` 0 and deposits revert; at the cap a new investor gets `maxDeposit` 0 while an existing one can top up; a locked holder can't redeem; vault shares count as holders.
  - **Invariant:** `sum(balances) == totalSupply`, `frozen <= balance`, and assets are conserved (vault asset balance = deposits - withdrawals).

### 5b. `Gated7540Vault` (`contracts/vaults/`)
- **Interfaces** (new files, spec-exact):
  - `IERC7540Operator`, `IERC7540Deposit`, `IERC7540Redeem` and `IERC7575`;
  - `IGated7540Vault` (Wonderland: errors, plus fulfilment events `DepositFulfilled` and `RedeemFulfilled`, and `CustodySet`).
- **Requests** (`requestId = 0`):
  - **`requestDeposit(assets, controller, owner)`:** `owner == msg.sender` or an operator. It pulls the assets into the vault and adds them to `pendingDeposit[controller]`. It emits `DepositRequest`.
  - **`requestRedeem(shares, controller, owner)`:** `owner == msg.sender`, an operator, or an ERC-20 allowance (operators skip the allowance; non-infinite allowances are deducted). It **escrows** the shares into the vault as a TRANSFER through the hook (lockup, frozen, identity and pause apply). The shares are BURNed at `fulfillRedeem`. It adds them to `pendingRedeem[controller]` and emits `RedeemRequest`.
- **Fulfilment** (`FULFILLER_ROLE`, V3):
  - **`fulfillDeposit(controller, assets, shares)`:** moves pending to claimable and sends `assets` to `custody`.
  - **`fulfillRedeem(controller, shares, assets)`:** moves pending to claimable and pulls `assets` from the fulfiller into the vault.
  - Partial fulfilment is fine.
- **Claims:**
  - `deposit(assets, receiver, controller)` and `mint(shares, receiver, controller)` mint shares (a MINT through the hook, so the receiver must be verified and under the cap).
  - `redeem(shares, receiver, controller)` and `withdraw(assets, receiver, controller)` pay out claimable assets pro-rata; rounding favours the vault.
  - The 4626-signature `deposit`/`mint`/`redeem`/`withdraw` act with `controller = msg.sender`.
  - `controller == msg.sender` or an operator.
- **`max*`** return the claimable amounts, gated as in §7. Async `preview*` revert.

### Owner decisions on Q1–Q5 (2026-10-17)
- **Q1:** `mint` and `burn` **hard-revert** on both vaults (`<Vault>_Unsupported`); supply moves only through the deposit and redeem flows. `MINTER_ROLE` and `BURNER_ROLE` are never granted on a vault; the Phase 7 deploy module asserts it ("belt and braces").
- **Q2:** `requestDeposit` reverts unless `canTransfer(0, controller, 1)` is OK. **New in 5b:** `FULFILLER_ROLE` gets `rejectDepositRequest(controller)` (assets returned) and `rejectRedeemRequest(controller)` (escrowed shares returned). Eligibility can change between request and fulfilment, and without ERC-7887 these are the only ways to unstick a request.
- **Q3:**
  - `convertTo*` use the last fulfilment price.
  - `totalAssets` is derived from it and is **indicative**, as the NatSpec will say.
  - **Every fulfilment emits `Fulfilled(price, assets, shares)`**, putting the NAV history on-chain.
  - Async `preview*` revert, per the spec.
- **Q4:** an initializer parameter that only the timelock can change, emitting `CustodyChanged(old, new)`.
- **Q5:** 5a is `Gated4626Vault` plus V1; 5b is `Gated7540Vault`.

### 5b questions (do not block 5a), recommendation first
- **R1. The escrow vault and `MaxHoldersRule`.** While the vault holds escrowed shares, it counts as a holder.
  - If the cap is full and the vault holds nothing, the vault is a *new* holder, so a **partial** redemption request is rejected with `MAX_HOLDERS`. **Exits get blocked by the cap.**
  - The vault also takes up one investor slot.
  - **(a) Recommended:** a per-token *excluded holders* list in `MaxHoldersRule`, set by the token admin (the vault gets added). Excluded accounts are neither counted nor capped. This means **new functions on the pushed `IMaxHoldersRule`**, so it needs an explicit instruction and a re-pin.
  - (b) No rule change: the vault keeps a permanent dust balance, so it's always an existing holder, and the cap is set to legal cap + 1. That's operationally fragile.
- **R2. How `rejectRedeemRequest` returns the shares** (vault → controller).
  - **(a) Recommended: as FORCED.** It's a privileged fulfiller action, so it bypasses pause, the cap and the lockup, while `IdentityRule` still requires a verified receiver. If the controller has since been de-verified, the agent's `forcedTransfer` to a treasury is the fallback.
  - (b) As TRANSFER: the return fails at a full cap or while paused.
  - Either way, shares and assets go back to the **controller**: with `requestId = 0`, state is per controller and the original owner isn't kept.
- **R3. The `Fulfilled` event.**
  - **Recommended:** `Fulfilled(address indexed controller, bool indexed isDeposit, uint256 price, uint256 assets, uint256 shares)`. That's your fields plus the controller and the direction, so the NAV history can be reconciled per request.
  - `price` = assets per whole share = `assets * 10**decimals() / shares` (rounded down).

### 5a, as approved (now in progress)
- **V1 `LockupRule`:** BURN is locked unless `ctx.operator` holds the token's `BURNER_ROLE`. The check reads storage first and only calls `hasRole` when a lockup is active. `ILockupRule` gets a NatSpec-only change (V1 instruction); its id is unchanged.
- **Base:** `mint` / `burn` become `virtual`, so a vault can hard-revert them (Q1). An internal `_canTransfer` is shared by `canTransfer` and the vault `max*` functions, and `getFrozen` becomes `public`. `IPolicyGated` is unchanged.
- **`Gated4626Vault`:** as planned above. Plus Q1: `mint(address,uint256)` and `burn(address,uint256)` revert with `Gated4626Vault_Unsupported`.
- **Test note on brief §7's "`deposit(maxDeposit+1)` reverts, `deposit(maxDeposit)` succeeds":**
  - For an *allowed* receiver, `maxDeposit` is `type(uint256).max`, so "+1" overflows.
  - For a *blocked* receiver, `deposit(0)` still reverts, because `IdentityRule` rejects regardless of amount.
  - So the tests assert the meaningful form. Blocked receivers get `maxDeposit == 0` and `deposit(1)` reverts. Allowed receivers can deposit. For redemptions, the exact form holds: `redeem(maxRedeem+1)` reverts and `redeem(maxRedeem)` succeeds.

### 5a as built (2026-10-17)
- **V1 `LockupRule`:** holder-initiated BURN is locked. The fix had a regression test that went red first. BURN by a `BURNER_ROLE` operator is exempt. The rule reads storage first, so there's no role lookup when the holder isn't locked (tested). `ILockupRule` got a NatSpec-only change (id unchanged; the freeze test still passes), and brief §6 is updated.
- **Base:**
  - `mint` / `burn` are `virtual`;
  - an internal `_canTransfer` is shared by `canTransfer` and the vault `max*`;
  - `getFrozen` is `public`;
  - two inline Slither suppressions (comparing a reason code with a constant).
  - Behaviour is unchanged: 244 tests passed before and after.
- **`Gated4626Vault`** (16,038 B; `IGated4626Vault` id `0xb008690c`, pinned):
  - OZ `ERC4626Upgradeable` + the base, with the `_update` and `decimals` diamonds resolved;
  - gated `max*` per brief §7 (including the rounding rule);
  - `_decimalsOffset = 6`;
  - `mint` / `burn` hard-revert (Q1).
- **Tests** (red first: the vault was missing):
  - **Unit:** wiring and initialisation locks; Q1 reverts even for role holders; hook contexts (MINT and BURN with the caller as operator, including a spender); every `max*` branch (allowed, hook rejection, pause, frozen); `redeem(maxRedeem+1)` reverts and `redeem(maxRedeem)` succeeds; `withdraw(maxWithdraw)` always succeeds under price moves; the inflation attack; ERC-165.
  - **Integration** (real Identity + Lockup + MaxHolders): an unverified receiver is blocked; at the cap a new investor is blocked while holders can top up; a locked holder can't redeem (pre-flight says `LOCKED`, `maxRedeem` is 0) until the unlock; a de-verified holder's exit is gated; a full exit frees a holder slot.
  - **Invariants:** `Σ shares == totalSupply`, `frozen ≤ balance`, **assets conserved** (vault assets = ghost in − ghost out), and **shares always backed**.
  - **Mutation check (3 mutants, all killed):** `maxRedeem` ignoring frozen (3 tests); `maxWithdraw` rounding up (the rounding test); `decimalsOffset` set to 0.
  - The offset-0 mutant was first caught only by the `decimals()` check. **The inflation test was strengthened** with a victim-loss bound (≤ donation/1e6 + rounding) and now kills it too.
- **Verification:** `npm test` gives 273 passing (272 solidity, 1 nodejs). Lint, typecheck and fmt are clean, Slither reports 0, Halmos 4/4.

### Owner decisions on R1–R3 and the brief (2026-10-17)
- **§7 test sentence** rewritten to the meaningful form.
- **Slither suppressions:** each carries a one-line reason above the disable comment (all audited).
- **R1 (a):** `setExemptHolder(token, account, bool)` on `MaxHoldersRule` (token admin, `HolderExemptionSet`). Exempt accounts never count and never trigger the cap, and the seed excludes them. This is the rule's own interface and nothing is deployed, so the change was made and re-pinned.
- **R2 (a):** the reject moves shares internally via `_moveAs(vault, controller, shares, FORCED)`, not the external `forcedTransfer`, and emits `RedeemRequestRejected` (not `ForcedTransfer`). Identity still applies to the controller: if the controller was de-verified, the reject reverts and the shares stay escrowed.
- **R3:** `Fulfilled(controller indexed, isDeposit indexed, price, assets, shares, fulfiller)`, where `price` = assets per `10**decimals()` shares (pinned in NatSpec), and `fulfiller` is not indexed.

### 5b as built (2026-10-17)
- **R1 `MaxHoldersRule`:**
  - the review's four exemption points (receiver early-return; `_senderLeaves` and both `after_` sides ignore exempt accounts);
  - plus **count-follows-exemption**: exempting or un-exempting an account that holds a balance moves it in or out of the count, so "never counts" holds and the count can't drift into the fail-closed underflow.
  - The `IMaxHoldersRule` id was re-pinned `0xa13cb93c → 0x0e091382` (independently checked with `cast`); `HolderExemptionSet` is pinned.
  - **Invariant** extended: the handler fuzzes `setExemptHolder`, and the property is now count == non-exempt holders.
  - **Mutation check:** dropping the exemption on the `after_` decrement is caught by a unit test and the invariant.
- **Spec interfaces:** `IERC7540Operator` `0xe3bc4e65`, `IERC7540Deposit` `0xce3bbe50`, `IERC7540Redeem` `0x620ee8e4` and `IERC7575` `0x2f0a18c5`. All four are the **standard's literal ids**, asserted in both the unit test and the freeze test.
- **`IGated7540Vault`** `0x34aae296`; its 4 events and the 3 ERC-7540 events are pinned.
- **`Gated7540Vault`** (20,389 B: OZ `ERC4626Upgradeable` + the base):
  - requests, fulfilment, claims and rejects exactly as specified above;
  - checks-effects-interactions throughout: state and events are written before token or hook calls;
  - the claim rounding follows the review's table (full claims clear exactly; Floor for shares-out and assets-out; Ceil for assets-in and shares-burned), and a claim whose computed output is zero reverts instead of silently losing value;
  - `maxDeposit` / `maxMint` = claimable, gated by the controller pre-flight;
  - `maxRedeem` / `maxWithdraw` = claimable, and 0 while paused;
  - `preview*` revert; `convertTo*` use the last price (1:1 before the first fulfilment); `totalAssets` is indicative;
  - the issuer `mint` / `burn` revert (Q1).
- **Tests** (red first: the vault was missing; green on the first implementation run):
  - **Unit:** 50+ cases, including fuzzed rounding for all four claim paths and the "two-step claim never exceeds the fulfilment" property.
  - **Integration** (real Identity + Lockup + MaxHolders, vault verified and exempt):
    - a round trip with NAV +10%;
    - an unverified controller refused at request;
    - **owner case: cap full, vault empty, a partial redemption request succeeds**;
    - a locked holder can't escrow (`LOCKED`) and frozen shares can't be escrowed;
    - a reject at a full cap while paused still returns the shares (FORCED, counted);
    - **owner case: a de-verified controller's reject reverts and the shares stay escrowed.**
  - **Invariants:** the vault's assets equal Σ(pending deposits + claimable redemption assets); the vault's own shares equal Σ pending redemptions; supply = actors + escrow.
  - **Mutation check:** withdraw shares rounded down, mint assets rounded down, and a reject that keeps pending. All 3 killed.
- **Gates:** first run had 1 solhint and 3 Slither findings, all fixed or triaged with an inline reason:
  - `IERC7575` ordering (id unchanged);
  - `arbitrary-send-erc20`: the `requestDeposit` `owner` is authorised; operators are trusted by spec;
  - `missing-inheritance`: `IERC7575` duplicates OZ's `IERC4626`; conformance is pinned by the id test;
  - an `incorrect-equality` suppression lost when a line was wrapped.

  264 stray duplicate files in the gitignored `artifacts/` (a concurrent-build race) broke `tsc`; they were cleaned by a rebuild.
- **Verification:** `npm test` gives 338 passing (337 solidity, 1 nodejs); lint, typecheck and fmt are clean; Slither reports 0; Halmos 4/4.

### Defaults I applied in 5b (flag if you disagree)
- **Claims on the redemption side** (`redeem` / `withdraw`) are blocked while paused, consistent with "the guardian can stop things"; deposit claims are already blocked by the hook.
- **Fulfilment while paused:** `fulfillDeposit` works; `fulfillRedeem` reverts, because the escrow BURN is a share movement.
- **Price and zero inputs:** the price is 1:1 until the first fulfilment. Zero-amount requests revert, as in the spec's reference code; zero-output claims revert; a zero controller reverts.

### 5b approval follow-ups (2026-10-17)
- **`arbitrary-send-erc20` suppression check:** the guard (`owner == msg.sender || isOperator`) runs before the pull. The test was strengthened to "a non-operator with a victim as owner reverts **and moves nothing**" (fuzzed; the victim has approved the vault), and a revoked-operator case was added. **Mutation check:** removing the guard fails both tests. The suppression stands. Pushed with 5b (`5791968`).
- **`recoverRedeemRequest(controller, to)`** (owner decision; `AGENT_ROLE`, an enforcement action):
  - clears the controller's pending redemption;
  - FORCED-moves the escrow to `to` internally (`to` must pass identity);
  - emits `RedeemRequestRecovered(controller, to, shares, agent)`;
  - reverts with `NothingPending` when there is nothing to recover and `ZeroAddress` for a zero `to`.

  Both fulfils now also revert with `NothingPending` when nothing is pending, so after a recovery the fulfil and the reject both say "no request". `IGated7540Vault` was re-pinned `0x34aae296 → 0x316209a5` (= the old id XOR the new selector, matching the compiler), and the new event topic is pinned.
  - **Tests** (red first): agent-only, nothing pending, zero recipient, the FORCED context with the event, works while paused, and fulfil/reject say "no request" afterwards. Integration runs the owner's sequence: de-verified controller → reject reverts → recovery to an unverified account reverts → recovery to a verified treasury → fulfil and reject revert with no request. **The invariant handler fuzzes recovery**, so escrow == Σ pending still holds across sequences. **Mutation check:** a recovery that doesn't clear pending is caught by 3 tests and the invariant.
- **Verification:** `npm test` gives 347 passing (346 solidity, 1 nodejs); lint, typecheck and fmt are clean; Slither reports 0; Halmos 4/4.

## Phase 6 — viem integration (approved and pushed 2026-10-17)

### Goal (brief §8)
`test/nodejs/*.test.ts` (node:test + viem, `network.create()`) covering:
- `signTypedData` → execute;
- vault flows;
- event decoding;
- pre-flight parity from the TypeScript side.

The temporary `smoke.test.ts` is deleted.

### What TypeScript adds over the Solidity suite (recommended scope: only this, no re-port of unit coverage)
1. **Real-wallet EIP-712.**
   - `walletClient.signTypedData` (domain: token name, `"1"`, chainId, token address) produces a digest equal to the on-chain `intentHash` and to viem's `hashTypedData`.
   - The signed intent settles via `IntentExecutor.execute`, and the `IntentExecuted` log is decoded.
   - A signature for the wrong chainId or token is decoded client-side as `PolicyGated_TransferRejected(BAD_SIGNATURE)`.
2. **Batch error decoding, as operator tooling would do it.** A failing `executeBatch` reverts with `IntentExecutor_BatchItemFailed(index, bytes)`. The test decodes the index **and** the nested `PolicyGated_TransferRejected(reason)` from those bytes, then drops the item and resubmits.
3. **Pre-flight parity matrix.** For each case (identity, lockup, window, cap, frozen, pause) × (transfer, intent, deposit, redeem):
   - `canTransfer` / `canExecute` / `max*` from a client;
   - versus `simulateContract` and the actual write outcome;
   - asserted equal, reason by reason.
4. **Vault flows end to end.**
   - **4626:** `maxDeposit` → `deposit` → `maxRedeem` → `redeem`.
   - **7540:** `requestDeposit` → `fulfillDeposit` → claim; `requestRedeem` (escrow) → `fulfillRedeem` → claim; reject; recovery.
   - The NAV history is rebuilt from decoded `Fulfilled` events and checked against `lastPrice`.
5. **Time-dependent flows** via `networkHelpers.time`: lockup expiry, settlement-window open and close, and intent deadlines.

### Setup
- **Proxy artifact:** add `solidity.npmFilesToBuild: ['@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol']` to `hardhat.config.ts`. Hardhat 3 only emits artifacts for project sources; this lets viem deploy OZ's own proxy by name. The option was verified in the installed typings.
- **Shared fixture** `test/nodejs/fixtures.ts`, using `networkHelpers.loadFixture`:
  - it deploys the stack in the Phase 7 order (registry → rules → attest → hook with its constructor rules → implementations → proxies);
  - "configure, then hand over" (the deployer configures caps, windows, exemptions and roles), with the vault registered as verified and exempt.
- **Helpers:** typed error and event decoding (`decodeErrorResult`, `parseEventLogs`), plus the intent signer.
- **Assertions:** `viem.assertions.revertWithCustomErrorWithArgs` / `emitWithArgs` where they fit, and explicit decoding where the point is to show client-side decoding.

### Decisions needed (recommendation first)
- **Q1. Scope:**
  - **(a) Recommended:** TypeScript-only value as listed above.
  - (b) Also port the Solidity unit cases.
- **Q2. Deployment in tests:**
  - **(a) Recommended:** a hand-rolled TypeScript fixture now that mirrors the deploy order; Phase 7's Ignition module replaces it, so tests and deployment end up sharing one source of truth.
  - (b) Write the Ignition module now and use it in Phase 6 tests. That pulls Phase 7 forward.
- **Q3. Timelock in Phase 6 fixtures:**
  - **(a) Recommended:** a plain admin account, so the tests focus on flows; the real `TimelockController` (≥ 7 days, guardian as canceller) is exercised in the Phase 7 deploy tests.
  - (b) A real timelock with time travel in every flow.

### Environment note (not a code issue)
- The repo sits under `~/Documents`, which is an **iCloud Drive** folder (verified). iCloud created "name 2" duplicates **inside the gitignored build output** twice: 264 files in `artifacts/`, plus `forge-out/` copies. The first batch broke `tsc`.
- Sources and git were never affected (checked); the build dirs were wiped and rebuilt clean.
- Recommendation: move the repo out of iCloud-synced folders (e.g. `~/dev/`), or exclude it from iCloud. That's the owner's environment choice; nothing was changed.

### Owner decisions on Phase 6 (2026-10-17)
- **Q1 (a):** TypeScript covers only what Solidity can't. The parity matrix and the NAV-history rebuild from `Fulfilled` are the most valuable parts, because they are what the ops tooling will do.
- **Q2 (a), plus:** the fixture is **the only place deployment order lives**. Phase 7's Ignition module imports or mirrors it rather than re-deriving it. The fixture ends with an assertion that **the deployer holds no role on the token, hook, rules or vaults**, so the hand-over check exists before Phase 7.
- **Q3 (a):** a plain admin in Phase 6; the real timelock in Phase 7.
- **Repo moved out of iCloud** to `~/dev/gated-token-stack`, before Phase 6.
  - `git fsck`: 228 reachable objects, 0 missing; the only note is git's virtual empty tree, referenced by the earlier `rebase --root`.
  - No file-provider attributes on `~/dev` or `.git`.
  - Fresh `npm ci`, then the full gate: 347 passing, lint, typecheck and fmt clean, Slither 0, Halmos 4/4, 0 duplicates.

### Phase 6 as built (2026-10-17)
- **`hardhat.config.ts`:** `solidity.npmFilesToBuild` adds OZ `ERC1967Proxy`, so TS (and Phase 7) deploys OZ's own proxy by name.
- **`test/nodejs/fixtures.ts`:** the single source of deployment order.
  - Order:
    1. Registry, identity and the four shared rules, then the attester attests the rules.
    2. Per template: implementation, then a hook bound to the predicted proxy address (initial rules in its constructor; the prediction is asserted).
    3. Attest the hook and the implementation, then deploy the proxy.
  - Configure-then-hand-over: the deployer is initialised as admin of the token, vaults and executor. As admin it:
    - sets the window (09:00–17:00, Mon–Fri), the caps (3) and the 7540 vault's holder exemption;
    - grants the operational roles;
    - grants DEFAULT_ADMIN_ROLE to the admin, then renounces.
  - The hook's `ADMIN` is the admin from the start (it is immutable).
  - Ends in `assertHandedOver`:
    - the deployer holds none of the roles returned by any `*_ROLE()` getter, nor DEFAULT_ADMIN_ROLE, on the registry, token, vaults or executor;
    - the admin holds DEFAULT_ADMIN_ROLE on each of them, so the check is not vacuous;
    - every hook's `ADMIN` is the admin;
    - rules have no access control of their own.
  - The clock is pinned to a Monday 10:00 UTC (2031) so window-dependent flows are deterministic.
  - Helpers: `REASONS` / `reasonName`; `signIntent`, which takes the domain from the chain via ERC-5267 `eip712Domain()` and uses a random nonce and ref; `revertOf`, which decodes revert data against combined ABIs because the executor bubbles the token's errors.
- **Tests (46):**
  - `deployment.test.ts`: the stack is live with its policy from deploy.
  - `intents.test.ts`:
    - wallet `signTypedData` = on-chain `intentHash` = viem `hashTypedData`;
    - settle through `IntentExecutor`, and decode `IntentExecuted` both by assertion and from the receipt;
    - a wrong-chain signature reverts BAD_SIGNATURE;
    - replay and cancel both give NONCE_USED;
    - batch failure decodes to the index plus the nested `PolicyGated_TransferRejected(reason)`; the batch is atomic, and dropping the failed item lets the rest settle.
  - `parity.test.ts`: 8 conditions × 4 operations, each checked three ways: pre-flight (`canTransfer` / `canExecute` / `max*`), `simulateContract`, and the write.
    - Conditions: none, receiver de-verified, sender de-verified, lockup, Saturday, cap, full freeze, pause.
    - Operations: transfer, intent, 4626 deposit, 4626 redeem.
    - Vault cells check `maxDeposit` / `maxRedeem` against `canTransfer` with the zero address, then the exact `redeem(maxRedeem + 1)` revert from the same state.
  - `vaults.test.ts`:
    - 4626 deposit, then `withdraw(maxWithdraw)` returns the assets exactly;
    - 7540 request → fulfil → claim for both legs (custody receives the assets; escrow is burned at fulfilment);
    - reject deposit and reject redeem;
    - recovery after de-verification (reject fails, recovery succeeds);
    - NAV history rebuilt from `Fulfilled` logs: price recomputed off-chain, including a rounding case, and the last price equals `lastPrice()`.
  - `time.test.ts`: lockup holds until its unlock second; the window is `[open, close)` and closed at weekends, with the same intent settling at Monday's open; the deadline is inclusive.
- **Findings worth knowing (none are contract bugs):**
  1. `canExecute` takes no signature (frozen interface), so it says OK for a bad signature. The integrator's signature pre-flight is `verifyTypedData` against the chain-reported domain, as `intents.test.ts` shows.
  2. Pre-flight evaluates the latest block, but a write lands in the next one. At a time boundary they can differ by one second. Example: at the deadline second, `canExecute` is OK, but a write mined one second later expires. Ops tooling should leave margin near boundaries.
  3. hardhat-viem's `balancesHaveChanged` tracks native ETH only, not ERC-20 balances, so token balances are asserted directly.
- **Mutation check:** four planted bugs, each killed, then restored from git.
  1. The executor hand-over skipped: 46 failing, through the fixture assertion.
  2. `canExecute` skips the hook: 8 failing.
  3. NAV price rounds up: 1 failing.
  4. An exclusive deadline: 1 failing.
- **`smoke.test.ts` deleted.**

### Verification (Phase 6)
- `npx hardhat test`: **392 passing (346 solidity, 46 nodejs)**.
- solhint clean, `tsc` clean, `forge fmt --check` clean, Slither 0 results, Halmos 4 passed / 0 failed, 0 iCloud duplicates.

## Phase 7 — deploy + security (built 2026-10-17, awaiting review)

### Goal (brief §8)
An Ignition deployment of the whole stack:
1. registry → attest implementations, hook and rules → timelock (≥ 7 days, guardian as canceller) → proxies → roles → guardian multisig;
2. one implementation per template, one proxy per token;
3. `npx @openzeppelin/upgrades-core validate`;
4. Slither clean and Halmos green. Both are already gates in CI and stay that way.

### Facts that shape the plan (verified 2026-10-17)
- **A proxy can't start without a hook.** `_setHook` rejects `address(0)` and requires a HOOK attestation, so `initialize` needs an attested hook.
- **A hook is bound to one token.** `ComplianceHook.TOKEN` is an immutable and part of the hook's codehash, so the hook must exist and be attested before the proxy, and it needs the proxy's address in advance.
- **Ignition can't predict that address safely.** The Phase 6 fixture predicts it from the deployer's nonce. Ignition batches transactions from one account, can interleave independent futures, and can resume a failed run, so a nonce-predicted address is not reliable there. A wrong prediction doesn't fail the proxy deploy; it yields a token whose hook rejects every `afterTransfer`.
- **The council's attestations are outside Ignition.** On a real network the attester is the security council multisig, and Ignition can't sign for it. Rules must be attested before a hook is constructed (the hook constructor checks them), and the hook before its proxy. So a live deployment has two council steps.
- **OZ's TimelockController** constructor grants PROPOSER and CANCELLER to the proposers. Giving the guardian CANCELLER needs an admin, so the deployer is the timelock's admin only long enough to grant it, then renounces (the same configure-then-hand-over as everything else).
- **UUPS `__self` immutable:** redeploying an implementation produces a new codehash. An upgrade test can therefore show that an unattested build of identical source is rejected.
- **Tooling:**
  - `@nomicfoundation/hardhat-ignition` 3.1.9 and `-viem` are installed. The builder offers `getParameter`, `getAccount`, `staticCall`, `encodeFunctionCall` and `after`.
  - `@openzeppelin/upgrades-core` is not installed. Hardhat 3 splits each build-info into `<id>.json` plus `<id>.output.json`, which upgrades-core may not read. The documented alternative is Foundry build-info with `storageLayout` extra output, which already goes to `forge-out/`. To verify at implementation time.

### Proposed design
1. **`contracts/deploy/ProxyDeployer.sol`: a one-shot CREATE helper, the only new contract.**
   - Its constructor records its own first CREATE address as `PROXY`, a pure function of the helper's address and nonce 1, unaffected by anything the deployer EOA does.
   - `deploy(impl, initData)`: owner only, once only. It creates the `ERC1967Proxy` and asserts the result equals `PROXY`.
   - It holds no roles and is neither a hook nor a rule, so it needs no attestation.
   - It ships with an interface, a `.t.sol` and NatSpec, per rule 16.
   - About 30 lines. The alternatives are below (Q1).
2. **Ignition modules (`ignition/modules/`), split at the council steps:**
   - `Components`:
     - deploys the timelock (admin = deployer; minDelay = 7 days; proposers and executors = governance multisig);
     - deploys the registry (admin = timelock, attester = council);
     - deploys the rules, the three implementations, and one `ProxyDeployer` per token;
     - deploys the executor (admin = deployer);
     - takes the identity registry address as a parameter.
   - *Council step 1:* attest the rules and the implementations.
   - `Tokens`: deploys one hook per token (admin = timelock, token = `ProxyDeployer.PROXY`, initial rules), reading `PROXY` with `staticCall`.
   - *Council step 2:* attest the hooks.
   - `Activate`:
     - `ProxyDeployer.deploy` for each proxy, initialised with admin = deployer;
     - configure the rules: window, caps, 7540 exemption, verification of the escrow vault;
     - grant roles: MINTER, BURNER and AGENT to the ops accounts; EXECUTOR to IntentExecutor; FULFILLER; UPGRADER to the timelock; OPERATOR;
     - grant CANCELLER on the timelock to the guardian;
     - hand over: DEFAULT_ADMIN_ROLE to the timelock everywhere; the deployer renounces it on the tokens, executor and timelock.
   - **Parameters:** governance multisig, council, guardian, ops accounts, identity registry, minDelay (default 7 days), caps and window.
3. **The fixture becomes the runner for the modules.**
   - `fixtures.ts` deploys `Components`, plays the council (local attester wallet), deploys `Tokens`, plays the council again, then deploys `Activate`, and ends in `assertHandedOver`, extended to the timelock and to "the guardian holds CANCELLER and nothing that proposes or executes".
   - The order then lives in the modules, and the fixture adds only the council steps. This fulfils Q2 ("import or mirror"). Phase 6's 46 tests rerun unchanged on the Ignition deployment, because none of them needs the admin after deploy.
4. **`test/nodejs/governance.test.ts` (new), everything through the real timelock:**
   - Upgrades:
     - an upgrade to an attested implementation can't execute before 7 days and executes after;
     - an upgrade to an unattested redeploy reverts `PolicyGated_NotAttested` at execution;
   - Guardian:
     - cancels a pending operation;
     - cannot schedule or execute;
     - pauses the token and the executor, but only the timelock unpauses.
   - Policy changes: a hook swap (`setPolicyHook`) and `setRules` go through the timelock and take effect only after the delay.
5. **upgrades-core:** pin `@openzeppelin/upgrades-core` as a devDependency (named in the brief; OZ only, rule 1). Add `npm run validate:upgrades` over the Foundry build-info with `storageLayout`, and a CI step for it. The `@custom:oz-upgrades-unsafe-allow constructor` annotations are already on every implementation.
6. **README:** a deployment runbook covering the three modules, the two council steps with how to recompute a codehash before attesting, and the post-deploy checks (the same assertions as the fixture).

### Decisions needed (recommendation first)
- **Q1. How the hook learns its proxy's address:**
  - **(a) Recommended:** `ProxyDeployer` (above). Deterministic, safe to resume, and immune to stray transactions; costs about 30 lines of audited surface.
  - (b) Predict from the deployer's nonce as the Phase 6 fixture does, plus a post-deploy check. No new contract, but fragile under Ignition batching and resume, and a mismatch is found only after the proxy exists.
  - (c) CREATE3 via CreateX, an external factory at a fixed address. No circularity, but a new external dependency, which must be etched onto the local network.
  - (d) Let the base initialise with no hook (fail closed with NO_HOOK) and set it during configuration. The cleanest order, but it changes the base and the documented init semantics.
- **Q2. Timelock executors:**
  - **(a) Recommended:** the governance multisig only.
  - (b) Open execution (`address(0)`): anyone may execute once the delay passes.
- **Q3. Real networks in this phase:** add a `sepolia` network entry with `configVariable` and the keystore, plus a dry-run doc? **Recommended: no.** Phase 7 proves the modules on the in-process network; a real network is a separate step with your RPC and keys.
- **Q4. Who holds UPGRADER_ROLE after hand-over:** **recommended: the timelock only** (brief rule 13). Phase 6 gave it to the plain admin.

### Out of scope
- No changes to interfaces or existing contracts, unless Q1 (d) is chosen, which touches the base.
- No Mythril (brief §8).

### Owner decisions on Phase 7 (2026-10-17)
- **Q1 (a), `ProxyDeployer`, on three conditions:**
  1. **CREATE2, keyed on a salt derived from the token symbol**, so the council can compute the token address off-chain before any hook or proxy exists and verify it afterwards.
  2. **Single-use per salt:** a reused salt reverts.
  3. **A loud binding check:** `hook.TOKEN() == token` is asserted before any role is granted.
  - The attested hook codehash already includes the token address: `TOKEN` is an immutable set from a constructor argument. So the council attests *this hook for this token*, which means one attestation per token, not per hook type. This goes in the runbook.
- **Q2 (a):** the timelock's proposer and executor is the governance multisig only. Open execution would remove the window to abort.
- **Q3:** no Sepolia in Phase 7.
- **Q4:** UPGRADER_ROLE goes to the timelock only; `Activate` ends with the deployer holding nothing.

### How the Q1 conditions are met (implementation consequences, verified against the code)
- **CREATE2 of the full proxy creation code would be circular.** That code embeds `initialize(…, hook)`, and the hook needs the address. So `deploy` CREATE2s the proxy with **empty init data** and calls `initialize` **in the same transaction**. The address is then `f(ProxyDeployer, keccak256(symbol), implementation)`, and atomic initialisation leaves no window to initialise first.
- **`deploy` is owner-only** (immutable `OWNER` = the deployer). Because the address does not cover the init data, anyone else could otherwise take the address with the same salt and implementation but their own admin.
- **The binding check is on-chain, inside `deploy`.** Ignition has no assertion step, so `deploy` reverts *before creating the proxy* if `hook.TOKEN() != predicted`. After `initialize`, it also reverts unless `policyHook() == hook` and `symbol() == symbol`. Every role grant in `Activate` depends on that transaction, so a mismatch stops the deployment before any role is granted.
- **"Before anything is deployed", made precise:** the address depends on the `ProxyDeployer` and implementation addresses, both fixed once `Components` has run. The council can compute every token address at its first step, before any hook or proxy exists. Computing it before `Components` would need CREATE3 or deterministic deployment of the helper and implementations; not done.
- **What a hook's codehash does not cover: its rule list.** The rules live in storage. The council attests the code and immutables `(ADMIN, REGISTRY, TOKEN)`; each rule is attested on its own and checked by the hook constructor, but the *selection and order* of rules is not covered by the hook attestation. The runbook has the council read `hook.rules()` before attesting. A twin hook with the same immutables but different rules shares the codehash, and only the timelock can install it (existing test `test_WhenAnIdenticalHookIsInstalled_ItIsAccepted`).
- **Ignition on the in-process network is ephemeral per `deploy` call,** so modules cannot reuse each other through `useModule` in tests. Each stage takes the previous stage's addresses as parameters, which is how a live deployment with council steps in between works anyway.

### Phase 7 as built (2026-10-17)
- **`contracts/deploy/ProxyDeployer.sol`** (+ `IProxyDeployer`, `.t.sol`, 12 tests, written red first):
  - CREATE2, salt `keccak256(bytes(symbol))`, over `TokenProxy(implementation, "")`;
  - `initialize` runs in the same transaction;
  - owner only; a symbol is single-use across implementations (`saltUsed`);
  - reverts `HookTokenMismatch` before creating the proxy, and `HookNotInstalled` / `SymbolMismatch` after initialising;
  - emits `ProxyDeployed`, whose topic is pinned in `InterfaceFreeze`; it is also in `ContractSizes`.
- **`contracts/deploy/TokenProxy.sol`** (+ `.t.sol`): OZ 5.6's `ERC1967Proxy` reverts `ERC1967ProxyUninitialized` on empty init data. `TokenProxy` is that proxy with only OZ's documented `_unsafeAllowUninitialized` override. Safe because `ProxyDeployer` initialises atomically. Considered and rejected: a hook-independent no-op init call to keep OZ's exact bytecode (obscure); a bootstrap implementation (more code).
- **Ignition modules** (`ignition/modules/`):
  - `Components`: timelock, registry, rules, implementations, `ProxyDeployer`, executor.
  - `Tokens`: hooks, bound to `ProxyDeployer.predict` via `staticCall`.
  - `Activate`: deploys through `ProxyDeployer`, configures, grants roles, hands over to the timelock.
  - `roles.ts` holds the role ids and the default token names and symbols.
  - Every config and grant call in `Activate` waits for **all** token deploys. Without this, Ignition ran token-independent grants (the timelock CANCELLER, the executor OPERATOR) in the first batch, before a failed deploy. The tampered-hook test caught it.
- **`npmFilesToBuild`:** `TimelockController` replaces `ERC1967Proxy`, which nothing deploys by name any more.
- **`fixtures.ts` now runs the modules:** `deployUntilActivate` (stages 1–2 and both council steps) plus `activate`. It plays the council and the identity provider, then runs `assertHandedOver`, which now checks:
  - the deployer holds no role on the timelock, registry, tokens or executor; the timelock is admin everywhere and the only UPGRADER;
  - hook ↔ token binding both ways; hook admin = timelock;
  - the guardian can cancel but not propose or execute; minimum delay ≥ 7 days.
  - All 46 Phase 6 tests pass unchanged on the Ignition deployment.
- **New tests:**
  - `deployment.test.ts`:
    - the council's off-chain CREATE2 formula matches every token;
    - a tampered `Activate` (two hooks swapped) reverts `ProxyDeployer_HookTokenMismatch`, creates no proxy, consumes no salt and grants no role anywhere.
  - `governance.test.ts`, everything through the real timelock:
    - an upgrade waits out the delay (it fails right after scheduling and again one second before the delay elapses) and then lands;
    - an unattested redeploy of the same source is refused at execution with `PolicyGated_NotAttested`;
    - governance can't upgrade, swap the hook or set rules directly;
    - the guardian cancels but can't schedule or execute; it pauses, and only the timelock unpauses;
    - a hook swap and `setRules` take effect only on execution;
    - guardian membership changes only through the timelock.
- **upgrades-core 1.46.0**, pinned. It can't read Hardhat 3's build-info, which lacks `storageLayout`, so `npm run validate:upgrades` makes a clean Foundry build with `--extra-output storageLayout` into `forge-upgrades/` (gitignored, wiped each run so stale build-info can't mask a regression) and excludes `contracts/test/**`. Added to the CI analysis job.
- **README:** the deployment runbook (three modules, two council steps, the CREATE2 formula, the hook-attestation scope, post-deploy checks), plus a deviation entry for `ProxyDeployer` / `TokenProxy`. The stale smoke-test line is removed.
- **Mutation check:** five planted bugs, each killed, then restored.
  1. No hook-binding check: 2 failing (unit test and Ignition tamper test).
  2. No salt check: 1 failing.
  3. UPGRADER_ROLE granted to an ops account: 54 failing.
  4. Deployer keeps timelock admin: 54 failing.
  5. Upgrade-unsafe state initialiser: `validate` FAILED.

### Verification (Phase 7)
- `npx hardhat test`: **415 passing (360 solidity, 55 nodejs)**.
- solhint, `tsc` and `forge fmt` clean; Slither 0 results; Halmos 4/4; upgrades-core: 3 upgradeable contracts, 3 passed.

### CI fix found while closing Phase 7
- **CI failed on the Phase 6 push (`a2082b8`), in typecheck only.** CI ran `tsc` before anything had compiled, so the ABI typings in `artifacts/` were missing and every contract type was `unknown`: 253 errors.
  - This reproduces locally by removing `artifacts/`; building first fixes it.
  - Local runs had hidden it because the artifacts already existed.
- **Fix:** CI now runs `npx hardhat build` before `npm run typecheck`.

### Vault initializer order (owner: fix it, 2026-10-17)
- **The warning:** upgrades-core flagged both vaults for calling `__ERC4626_init` before the base's composite `__PolicyGatedERC20_init`.
- **The fix:** both now expand that initializer in linearized order: `__ERC20_init`, then `__ERC4626_init`, then `__ERC20Permit_init` (which includes EIP712), then `__AccessControl_init`, then `__Pausable_init`, then `__PolicyGatedERC20_init_unchained`.
- **Result:**
  - `validate:upgrades`: 3 passed, no upgrades-core warnings;
  - vault suites: 93 passing; full suite: 415 passing.
- **Still printed:** 8 solc "unreachable code" warnings from inside OZ's `ERC4626Upgradeable` (code after the 7540 vault's always-reverting `preview*` overrides). They are not ours, and the count was the same before the change.

### Owner follow-ups on `ProxyDeployer` (2026-10-17): pinned in tests
1. **A failed `initialize` leaves no proxy and does not use up the symbol.** A revert undoes the CREATE2 and the `saltUsed` write together. Test: the deploy fails, then after the fix the same symbol deploys at the predicted address.
2. **A mis-bound hook leaves the salt free.** Test: `HookTokenMismatch` revert, then `saltUsed == false`, then the correct hook deploys at the predicted address.
3. **Ownership after `Activate`:**
   - `ProxyDeployer` moved from an immutable `OWNER` to OZ `Ownable`. The `OWNER()` getter and the `ProxyDeployer_OnlyOwner` / `ProxyDeployer_ZeroAddress` errors were replaced by OZ's `owner()`, `OwnableUnauthorizedAccount` and `OwnableInvalidOwner`; `IProxyDeployer` was not yet frozen.
   - `Activate` calls `transferOwnership(timelock)` after all deploys. The timelock was chosen over renouncing so later tokens keep the same CREATE2 scheme under governance.
   - `assertHandedOver` checks `owner() == timelock`; the tamper test checks the deployer still owns it when `Activate` fails.
   - Unit test: the former owner can't deploy after the transfer.
   - Governance test: a new token (`NEW`) can be placed only by a scheduled timelock operation, still bound to its attested hook; a direct deploy from the deployer EOA reverts `OwnableUnauthorizedAccount`.
   - Mutation check: keeping ownership with the deployer gives 55 failing.
- **README security model:** "Attestation covers hook code and binding, not rule set; the rule set is governed by the timelock."

### Finding: bytecode depends on the compile job (resolved 2026-10-17)
- **Cause:** Hardhat 3 gives each compile job its own remappings list (forge-std entries depend on which test files share the job), and solc metadata includes the remappings. The trailing metadata hash, and so the bytecode, depended on job grouping. It surfaced when the separately compiled `TokenProxy` stopped matching the copy embedded in `ProxyDeployer` (first difference at byte 892 of 935).
- **Owner decision: both (a) and (b), as two layers of one control:**
  - **(a) Source-reproducible builds.** `metadata.bytecodeHash = "none"` in the shared Hardhat compiler config, `bytecode_hash = 'none'` in `foundry.toml`; solc 0.8.30, cancun, optimizer 200 runs, pinned in both.
  - **(b) A published reference.** `.github/workflows/release.yml`: on a `v*` tag it reruns the reproducibility check and attaches `release-build-<tag>.tar.gz` (`manifest.json` + production build-info, with a `.sha256`) to the release.
  - The council attests only when its clean build at the tag matches the published reference and the chain (README runbook, step 2).
- **Verified before pushing:**
  1. **Pinned-ID and codehash tests:** all 419 tests pass with the metadata hash off. Interface IDs and event topics come from the ABI, and registry tests compute codehashes at runtime.
  2. **upgrades-core does not use the metadata:**
     - `validate` still passes all 3 contracts;
     - a deliberately incompatible storage reference (`--contract Gated4626Vault --reference IntentToken`) still fails ("Deleted namespace erc7201:gated.storage.IntentSettled");
     - the unsafe-state-initialiser mutant still fails.
     - So no production-only fallback was needed.
  3. **Reproducibility gate:** `scripts/verify-reproducible.ts` (`npm run verify:reproducible`, in the CI analysis job).
     - Compares runtime code, creation code and immutable slot positions for 12 contracts (8 attested plus registry, executor, `ProxyDeployer`, `TokenProxy`) across: two clean production builds (each file compiled alone), the default profile (files grouped with the tests), and forge.
     - Also checks that `ProxyDeployer` embeds the `TokenProxy` artifact's creation code.
     - Result: REPRODUCIBLE.
     - **Two clean builds alone would not have caught today's break.** With the metadata hash re-enabled, the two production rebuilds stayed identical, while the default-profile and forge builds differed for every contract. The cross-job comparisons are what catch it, and the mutant confirms the gate fails.
- **This changes no deployed contract, because none exists yet.** Every address and codehash changed with this setting, which is fine now. After a first deployment the same change would be a migration: new implementations, attestations and hooks, and new CREATE2 addresses.

### Twin-hook check and `IProxyDeployer` pin (owner: yes, 2026-10-17)
- **The gap (from validating the external review):** a hook with the same admin, registry and token shares the attested codehash whatever its rules, and `ProxyDeployer` checks only `TOKEN()`. So a weaker twin could be passed to `Activate`.
- **Fix:**
  - `RULE_ORDER` in `ignition/modules/roles.ts` is the single definition of each token's ordered rule list; `Tokens` builds hooks from it.
  - `assertHandedOver` checks each token runs the stage-2 (council-reviewed) hook and that `hook.rules()` equals `RULE_ORDER`.
  - The runbook has the council record the reviewed hook addresses and check `policyHook()` and `rules()` after deployment.
- **Tests:**
  - new `deployment.test.ts` case: a twin hook (same immutables, only `MaxHoldersRule`) is attested, Activate completes, and the post-deploy check rejects it ("runs another hook");
  - mutant: hooks built with the rule list reversed give 55 failing ("rule 0").
- **`type(IProxyDeployer).interfaceId` pinned** at `0x886d8cd8`: `cast` selectors XORed, checked against solc's value by the test. All 20 interfaces are now pinned.

### Phase 7 closing items (2026-10-17)
1. **`v0.1.0` tag** on the commit whose CI analysis job (including `verify:reproducible`) is green. It exercises `release.yml` for real and gives the council a first reference build to practise the step-2 procedure against.
2. **`SECURITY.md`**, the audit package index:
   - the brief, the security model, the runbook and the deviation list (by link);
   - scope and build settings;
   - the three Phase 7 findings (CREATE2 circularity, the `_unsafeAllowUninitialized` argument, the hook attestation scope) plus the recorded limits;
   - every Slither and solhint suppression with its reason;
   - the mutation results across all phases;
   - verification commands and tool versions.

### Post-v0.1.0 adjustments (owner, 2026-10-17)
- **CI time:** `verify:reproducible` (about 11 minutes on a hosted runner) now runs only on pull requests into `main` (`ci.yml`) and on `v*` tags (`release.yml`, before publishing). Pushes to `main` skip it.
- **Archive size:** the reference build now carries `manifest.json` plus build-info for in-scope sources only: 36 isolated jobs rooted in `contracts/`, excluding `contracts/test/` and `.t.sol`. Tests, mocks and the OZ-rooted `TimelockController` job are dropped. The script fails if a build-info is not single-root.
  - Size: 42 MB → 2.6 MB compressed (431 MB → 26 MB uncompressed).
  - The OZ sources a contract imports remain inside its job's solc input, since they are needed to reproduce it.
- **The `v0.1.0` archive was published before this change and is the larger one.** The next tag gets the trimmed archive.

### Aderyn as a second static-analysis gate (owner, 2026-10-17)
- **Setup:** `@cyfrin/aderyn` 0.6.8, pinned. `aderyn.toml` sets the scope (`contracts/`, minus tests and mocks) and the project-wide exclusions; `scripts/aderyn-gate.ts` (`npm run aderyn`) fails on any remaining finding. It's in the CI analysis job after Slither.
- **First run:** 5 high and 13 low detector types; no exploitable issue.
- **One real fix:** `ProxyDeployer`'s constructor parameter `_owner` shadowed `Ownable._owner`; renamed `_initialOwner`.
- **The rest triaged** (full table in `SECURITY.md` §4):
  - project-wide: `centralization-risk`, `push-zero-opcode`, `unspecific-solidity-pragma`, `uninitialized-local-variable`, `unused-import`;
  - inline, with the reason on the line above.
- **Owner: "add tests to validate the issues if not false positives".** Each acknowledgement whose verdict rests on behaviour is now pinned by a test:
  - **`contract-locks-ether`:** turned out to be a false positive, not an accepted risk. Plain ETH sent to the token or either vault reverts; ETH attached to a token function reverts; even the upgrader's `upgradeToAndCall{value}` reverts (`ERC1967NonPayable` with empty data; non-payable delegated call with data). Tests: `IntentTokenIntegration_Ether`, `Gated4626VaultUnit_Ether`, `Gated7540VaultUnit_Ether`.
  - **`reentrancy-state-change`:** `MockStatefulToken`, whose `hasRole` / `balanceOf` / `policyHook` write state. Every rule entry point that reads the token reverts against it, proving those reads are STATICCALLs; a direct call to the same mock succeeds as a control. Tests: `{Lockup,SettlementWindow,MaxHolders}RuleUnit_TokenCallsAreStatic`.
  - **`unused-state-variable`:** `Gated7540VaultUnit_Storage` checks the ERC-7201 formula equals the constant and that the slot holds custody and `lastPrice`.
- **Interplay with Slither:** where a Slither next-line suppression already occupies the line above, Aderyn uses its same-line form. The 7540 contract declaration uses Slither's block form instead, because `forge fmt` wraps the inheritance list. Slither attributes `missing-inheritance` to the whole contract, so that block closes after the last line.
- **Mutation check:** removing one inline suppression fails the gate (1 high).
- **Supply-chain note:** the package downloads its binary in `postinstall` from Cyfrin's GitHub release, without a checksum. Recorded in `SECURITY.md`.

### Toolchain supply chain (owner, 2026-10-17): fixed, not just recorded
- **Owner:** "An unverified binary download in the pipeline that gates attested code is the one line an auditor will flag." Fix Aderyn, and give every run-time fetch the same treatment. Cancun is confirmed as the target EVM.
- **Aderyn:** the `@cyfrin/aderyn` npm package (whose `postinstall` downloaded the binary without a checksum) is removed. `tools.lock` pins the release assets' sha256, and `scripts/fetch-tool.sh` downloads (https only), verifies and installs into `.tools/bin`; `npm run aderyn` uses only that binary.
  - The pinned hashes were checked against three agreeing sources: the downloaded file, GitHub's asset digest, and the project's `.sha256`.
  - Aderyn has no attestation.
- **forge:** `foundry-rs/foundry-toolchain` (version-pinned only) is replaced by `scripts/fetch-tool.sh foundry`, with the sha256 pinned and Foundry's sigstore provenance verified once (`gh attestation verify -R foundry-rs/foundry`).
- **Slither and Halmos:** `ci/requirements.in` → `ci/requirements.txt` (uv, `--universal --python-version 3.12 --generate-hashes`): 61 packages, installed with `pip install --require-hashes`.
  - Verified in a fresh 3.12 venv: Slither 0 results, Halmos 4/4.
  - Corrupted hashes make pip refuse the install.
- **GitHub Actions:** pinned to commit SHAs (checkout v4.4.0, setup-node v4.4.0, setup-python v5.6.0).
- **Runtimes:** Node 24.21.0 (24.22.0 was only 3 days old) and Python 3.12.15.
- **npm:** `npm ci --ignore-scripts`. Remaining install scripts (esbuild, keccak, secp256k1, fsevents) ship prebuilt binaries inside their integrity-checked tarballs; the full suite passes (430) on a clean `--ignore-scripts` install. forge-std is pinned to a git commit.
- **solc:** Hardhat, forge and Aderyn each download it and verify it against soliditylang.org's hashes. Documented.
- **Tamper checks:** a one-character change to a `tools.lock` hash makes `fetch-tool.sh` fail; an unknown tool or platform is refused.

### Test-quality review (2026-10-17): validated, real findings fixed
- **Validation:** 4 of the 6 findings were real. False: the "TamperedHook" parity test (doesn't exist), the Halmos finding (quoted code not in the repo; the "nonce not consumed" mutant proves the success branch is reachable), the `|revert` regexes (none exist), "NO_HOOK unused" (used at `PolicyGatedERC20Upgradeable.sol:329`; defensive, unreachable), rule constructor admin checks (the rules have no constructor).
- **Fixed, test-only (bytecode identical to v0.1.0):**
  1. **7540 invariant handler:**
     - each action picks the first actor (from the fuzzed seed) that has something to act on, instead of `bound(x, 1, 0)` reverting; partial claims that would round to zero are taken in full;
     - new `claimMint` and `claimWithdraw` actions (the round-up paths);
     - new invariant `invariant_ClaimsCanAlwaysBeClearedInFull` (from any reachable state, claimable assets withdraw and claimable shares mint to exactly zero);
     - `afterInvariant()` asserts every one of the 11 actions executed in every run.
     - Measured: runs execute 400+ real actions.
     - The previous invariants were not vacuous: a probe confirmed the fuzzer reached the handler. The all-zero counters seen first were a shrinking artefact of an always-failing probe.
     - Mutant: a no-op `claimWithdraw` fails `afterInvariant`.
  2. **Partial-claim fuzz tests:**
     - the deposit-by-assets and redeem tests now bound the first step so it yields at least one unit, making every run a genuine split;
     - all four (deposit, mint, redeem, withdraw) claim the remainder and assert exact totals with nothing left claimable;
     - the zero-rounding reverts have their own deterministic tests.
  3. **Zero `controller`** on `requestDeposit` and `requestRedeem`: tested (`Gated7540Vault_ZeroAddress`, nothing moved).
  4. **No bare `vm.expectRevert()` remains:**
     - the stranger request pins `ERC20InsufficientAllowance(stranger, 0, 30)`;
     - the `ProxyDeployer` cases pin `HookTokenMismatch` and `PolicyGated_NotAttested`;
     - the STATICCALL tests pin an empty revert (`bytes('')`, strict in EDR, verified by probe);
     - the non-payable upgrade pins `Errors.FailedCall` (OZ `Address` wraps the empty revert).
- **Result:** 435 passing (378 solidity, 57 nodejs).

### Independent review (2026-10-17): validation and test fixes
- **Validation:** every security and logic finding was real (M-1, M-2, M-3, L-1 to L-5). Of the test findings, I first called "the `requestDeposit` eligibility check survives" outdated because 4 tests kill the *deleted*-check mutant. That was wrong: the reviewer's mutant *swaps the subject* (checks the owner instead of the controller), and it survived because every test used owner == controller. It is now killed by `test_WhenAVerifiedOwnerRequestsForAnUnverifiedController_ItIsRefused` (verified on a scratch copy; correction relayed by a teammate session). Also, "no `count <= cap` invariant" is by design: a lowered cap and FORCED moves can push the count over the cap.
- **Code findings, awaiting owner decisions:**
  - M-1: guardian permanent freeze (a brief §4 change);
  - M-2: a reject steered past the cap (reverses R2);
  - M-3: no recovery or refund of claimable balances (an interface change);
  - L-5: operator scope (brief or code);
  - L-1: dust cap griefing.
  - Small code fixes proposed, not yet applied: L-2 (release frozen tokens in internal FORCED moves), L-3 (zero price), L-4 (cap only net additions).
- **Test fixes (test files only; bytecode unchanged):**
  1. **Access checks pinned:** `Gated7540VaultUnit_ClaimAccess`.
     - A fuzzed non-controller can't redeem, withdraw, mint or deposit another controller's claim; an approved operator can (the control).
     - A fuzzed account without the role can't fulfil or reject a redemption.
     - `withdraw` reverts while paused.
  2. **Two no-op invariant handlers fixed** (in `PolicyGatedERC20Upgradeable.t.sol` and `MaxHoldersRule.t.sol`). `balanceOf` inside the call arguments consumed `vm.prank`. Amounts are now computed first; ghost counters plus `afterInvariant` require every action to execute.
     - A sweep of every `.t.sol` found no other instance (one fragile case in `ProxyDeployer.t.sol` was reordered).
     - Proof: with the old handler, `invariant_FrozenNeverExceedsBalance` passes against a `forcedTransfer` that keeps frozen tokens; with the fixed handler it fails.
  3. **Fixtures no longer predict addresses from the nonce:** `IntentToken`, `Gated4626Vault`, `Gated7540Vault` and `MaxHoldersRule` deploy through `ProxyDeployer` (CREATE2), as in production. `--gas-stats` now passes on all four (164 tests).
  4. **Coverage:** `ContractSizes.t.sol` skips (`vm.skip`) only when the bytecode contains EDR's coverage address `0xc0bE…C0BE`, i.e. under `--coverage`. Normal builds still assert EIP-170, and `--coverage` runs with no failures.
  5. **Gaps filled:**
     - exactly `MAX_RULES` (16) rules install;
     - 7540 `totalAssets` equals the supply at the last price;
     - the two-argument `mint` claims for the caller;
     - the transient kind, ref and deadline are cleared between movements in one transaction (forced then plain; executed then plain);
     - the 7540 handler adds `requestDepositFor` / `requestRedeemFor` (controller differs from owner), checked in `afterInvariant`.
- **Mutation re-run (12 mutants, full suite):**
  - all 9 vault access mutants are now killed (6 survived before);
  - "kind slot not cleared" and "`forcedTransfer` keeps frozen" are killed;
  - "ref slot not cleared" survives as an equivalent mutant: the ref is read only when the kind slot is set, and every movement that sets the kind rewrites it first.
- **Mutation hygiene (teammate session's note, adopted):** the runs above edited the real `contracts/` files in place and restored them afterwards, but an interrupted run would have left a missing access check one `git commit -a` away (one mutant was live during the teammate's snapshot). From now on mutants run only in a scratch copy (`git ls-files` → rsync, `node_modules` symlinked); the eligibility-subject mutant was checked that way.
- **Owner decision pending (teammate's suggestion):** an `isolated` Hardhat test profile (`isolate: true`) plus a CI step `npx hardhat test solidity --test-profile isolated` (about 25 s). It reproduced the 11 nonce-dependent fixture failures before the CREATE2 fix, so it would stop that class returning.

### Owner: push, isolated profile, three fixes (2026-10-17)
- **Pushed** `2caf004` and `dc26f25`.
- **Isolated test profile:** `test.solidity.profiles.isolated` (`isolate: true`, same fuzz runs; Hardhat requires a `default` profile) and a CI step `npx hardhat test solidity --test-profile isolated`. Checked on a scratch copy: with the pre-CREATE2 nonce fixture restored, this profile reproduces the `ComplianceHook_OnlyToken` failures (4 in the 4626 file). The current suite passes it (395).
- **L-2 fixed:** `rejectRedeemRequest` and `recoverRedeemRequest` call `_releaseFrozen(address(this), shares)` before their internal FORCED move, as `forcedTransfer` does. `_releaseFrozen` became `internal` and moved next to `_moveAs` (solhint ordering). Tests (red first): `Gated7540VaultUnit_FrozenEscrow`.
- **L-3 fixed:** `_recordPrice` stores at least 1, so `convertTo*` never divide by zero. `IGated7540Vault` NatSpec for `Fulfilled._price` and `lastPrice()` now says "never below 1"; this is text only, so the ABI, ERC-165 ID and topics are unchanged. Tests (red first): `Gated7540VaultUnit_ZeroPrice`, including a fuzz test that the price is never 0.
- **Mutants on a scratch copy:** each fix removed in turn is caught (1, 1 and 3 failing).
- **Bytecode:** only `Gated7540Vault` differs from v0.1.0, so the next tag needs a new implementation attestation for it.
- **L-4: prose corrected, behaviour unchanged (owner, 2026-10-17).** The formula `count + (senderLeaves ? 0 : 1) > cap` is the intended behaviour: a lowered cap is a ratchet. Swaps would let the register churn without ever shrinking, while existing holders can still transfer among themselves and exit, so nobody is trapped.
  - Brief §6 now says: a full-balance move to a new holder is net-zero and passes when `count <= cap`; any other new holder needs `count < cap`; above a lowered cap no new holder is admitted, net-zero or not, until the count is back down to the cap (full-balance moves) or below it (any other).
  - I adjusted the owner's wording at the boundary: at `count == cap` a full-balance move passes, as pinned by `test_WhenTheSenderLeavesForANewHolderAtTheCap_ItIsOkNet`.
  - Pins: `test_WhenTheCountIsAboveALoweredCap_ANetZeroMoveIsStillRejected` (above the cap) and the `count == cap` test above.

## v0.2.0: design fixes from the 2026-10-17 review (owner decisions; implemented)

Order: M-3, then M-2, then M-1, then the L-5 and L-1 docs. Each M is its own commit, tests first. Bytecode changes, so this is v0.2.0. The change-board findings page is published after the fixes land.

- **M-3: claimable balances (the one post-freeze interface change, `IGated7540Vault`, re-pinned).**
  - Claim-time eligibility through the hook, with no new business logic in the vault:
    - deposit claims (`deposit`/`mint`) require `canTransfer(address(0), controller, 1)`, the same probe as `maxDeposit`;
    - redemption payouts (`redeem`/`withdraw`) require `canTransfer(controller, address(0), 0)`, a zero-amount burn probe: controller identity and lockup, without tripping the frozen-balance check on a controller that holds no shares;
    - `maxRedeem`/`maxWithdraw` use the same probe, so pre-flight matches.
  - `recoverClaimable(controller, to)`, AGENT_ROLE:
    - claimable redemption assets go to `to`;
    - claimable deposit shares are delivered to `to` by an enforcement mint;
    - `to` must pass a zero-amount FORCED probe (identity);
    - emits `ClaimableRecovered(controller, to, assets, shares, agent)`;
    - works while paused and when the cap is full, which covers the stranded-deposit case.
  - Base: a new internal `_mintAs(to, amount, kind)` announces the kind and calls `_mint`; `_moveAs` is unchanged.
  - Brief §5: FORCED with `from == address(0)` is an enforcement mint. Rules treat it as FORCED (exempt from cap, pause and lockup) and still require `to` verified. FORCED with `to == address(0)` is reserved and unused.
  - Every rule is tested against FORCED-from-zero; `MaxHoldersRule.after_` counts the new holder.
- **M-2: reverses R2.** Rejected redemption shares return as a plain TRANSFER from the vault to the controller, so cap, pause, lockup and freeze apply. If that is blocked, the reject reverts and the agent uses `recoverRedeemRequest`. The L-2 release moves to the recover path only, since a frozen escrow now blocks a reject. Cap-full tested both ways.
- **M-1: recovery timelock.**
  - A second TimelockController: 7-day delay, governance multisig as proposer and executor, no cancellers, and the guardian holds nothing on it.
  - It holds RECOVERY_ROLE: on every token, vault and the executor it can only `unpause()` and `revokeRole(GUARDIAN_ROLE, ...)`; on the main timelock it can only `revokeRole(CANCELLER_ROLE, ...)` (a `TimelockController` subclass, since OZ can't scope a role admin to revoke-only).
  - It must not be able to grant roles, change hooks, upgrade, or propose on the main timelock; each is tested to revert.
  - The hand-over check pins the recovery timelock's exact role set.
  - Brief §4 updated. Runbook: a compromised governance multisig is out of scope for this control, by design.
- **L-5:** standard ERC-7540 operators (full delegates); brief corrected; a test pins it.
- **L-1:** accepted with agent clean-up; `MinPositionRule` (a per-token minimum, attested) later.
- **As built:**
  - M-3 `0822a4a`, M-2 `d99a82f`, M-1 `cfd95c3`, then the L-5/L-1 docs commit. Each has tests written first, and every M's mutants were run on a scratch copy and caught.
  - Owner clarifications applied: the payout probe uses amount 0 (the amount-1 probe would block payouts to controllers holding no shares; that mutant breaks 11 tests); claimable deposit shares are delivered as an enforcement mint (`_mintAs`, FORCED from zero), so delivery works at a full cap and while paused; the recovery timelock covers the guardian's full surface (every token, vault and the executor, plus its main-timelock canceller).
  - `GovernanceTimelock` replaces the plain main timelock (an OZ subclass). The recovery timelock is plain OZ.
  - Interface changes: `IGated7540Vault` re-pinned to `0x75f5b0db` (M-3) and `IGovernanceTimelock` added (`0x31993a1c`); `IPolicyGated` and `IIntentExecutorBatch` changed NatSpec only, so their IDs are unchanged.
  - Result: 495 passing; lint, Slither, Aderyn, Halmos, upgrades-core, isolated profile and reproducibility (13 contracts) all clean.
- **Docs:** the eight `docs/` guides were updated for v0.2.0 (`ca88619`), including a correction to the documented error for paused deposit claims (now `Gated7540Vault_ControllerNotEligible(PAUSED)`, from the claim-time check).
- **Released:** tag `v0.2.0` on `ca88619`, after CI was green.
  - The release workflow attached `release-build-v0.2.0.tar.gz` (2.9 MB, sha256 `63cab1240bded016295ac39ef033f180193f85401c78b821270005785239c95d`).
  - Verified as the council would: the sha256 matches, the manifest is identical to a local clean build for all 13 contracts, and its 38 build-info roots are all in scope (no tests, mocks or OZ-rooted jobs).
- **Attestation impact vs v0.1.0:**
  - changed: the `IntentToken`, `Gated4626Vault` and `Gated7540Vault` implementations (re-attest), and `IntentExecutor`;
  - new: `GovernanceTimelock`;
  - unchanged: the four rules, `ComplianceHook`, `PolicyRegistry`, `ProxyDeployer`, `TokenProxy`.
- **Mutation tally since v0.1.0:** 33 planted, 32 caught. The survivor ("ref slot not cleared") is an equivalent mutant. An earlier report of "24" was a miscount.
- **Change-board page** (private until the owner shares it): https://claude.ai/artifact/HxFZz3atMCyaj4U9HbcjEo. It covers status by finding, decisions, test evidence, attestation impact, verification, and the reviewer's "by design" notes left unchanged.

### Remaining brief items (deferred until the first external integrator is known)
- **ERC-3643 `IToken` read adapter.**
- **Exact ERC-7943 conformance,** once the ERC is Final. Today there is no 7943 interface ID, because the function names and return types differ (README deviations).

## Docs: `docs/` (built 2026-10-17, awaiting review)

There is no `docs/` folder. The README has the security model and the deployment runbook. Nothing explains how the contracts connect, or follows a holder, an operator or the issuer through a flow. The request: an architecture page, plus diagrams of the user flows, the roles, the money and how the protocol works, exact against the code.

### Source of truth
- The Solidity in `contracts/` and the modules in `ignition/modules/`, read in full on 2026-10-17. Non-test source is identical at `2caf004` and `dc26f25`. The OpenZeppelin 5.6.1 behaviour the pages rely on (timelock constructor roles, ERC-4626 order of transfer and mint, EIP-712 version string) was read in `node_modules`.
- Where `CLAUDE.md`, the README and the code disagree, the pages follow the code. The differences go in the summary of this task. The brief, README and SECURITY.md are not edited.
- No contract, interface, test or config file changes. Another session is committing to this checkout, so `contracts/` and `ignition/` are re-checked for changes before the pages are called done.

### Pages
| File | What it explains | Diagrams |
|---|---|---|
| `docs/README.md` | Index, reading order, a one-table glossary (hook, rule, kind, context, attested, timelock, guardian, controller), and the commit the pages were checked against | none |
| `docs/architecture.md` | Each contract and what it does; how they call each other; which are proxies and which are immutable; the ERC-7201 storage namespaces; how each template inherits the base | component map, inheritance, install-time vs run-time calls |
| `docs/roles.md` | Every role on every contract, who holds it after `Activate`, the exact functions it opens, its delay, what it cannot do. The guardian's two separate powers: `pause` on the token, `cancel` on the timelock | authority map; function × role table |
| `docs/transfer-checks.md` | What `_update` does for every balance movement: the five kinds, the context, pause and frozen checks, hook, rule order, `afterTransfer`, the transient slots. Rule × kind table; the 13 reason codes and who returns each; where `canTransfer` and `canExecute` differ from the real call | `_update` flow; one transfer through the hook and rules |
| `docs/flows-token.md` | `IntentToken` flows step by step, with who signs or sends what: mint, burn, transfer, signed intent (sign, pre-flight, execute, batch, cancel), forced transfer, freeze, lockup, pause and unpause. The EIP-712 domain and type | one sequence per flow (about 8) |
| `docs/flows-vaults.md` | `Gated4626Vault` deposit, mint, withdraw, redeem and the gated `max*`. `Gated7540Vault` request, fulfil and claim for deposits and redemptions, reject, recover, operators. What pause blocks in each call | sequences; request state diagrams |
| `docs/money.md` | Where tokens and assets sit at each step of each template; who pays, who receives, who holds custody; the price and rounding rules with worked numbers; what the code does not have (no fees, no yield logic, no payment leg on `IntentToken`) | one money-flow diagram per template; balance tables |
| `docs/governance-and-deployment.md` | Timelock operations (schedule, wait, execute, cancel); council attestation and where it is checked; hook swap, rule-set change, upgrade; the deploy order and `ProxyDeployer`'s CREATE2 binding; the state after `Activate`. Points to the README runbook for commands instead of repeating them | deploy sequence; governed change; upgrade; end state |

### How accuracy is checked
1. Each behaviour is written from the function that does it. Every section ends with a `Code:` line naming the contract and function (names, not line numbers, so edits do not break them).
2. A throwaway script in the session scratchpad (not committed) pulls every code identifier, role, reason code, event, error and path out of the pages. It fails if one is missing from `contracts/`, `ignition/` or `test/`. It also scans for the banned wording below.
3. The rule × kind table, the pause table and the worked numbers are run against the real contracts in a scratch copy of the repo (as the mutation runs are), never in the working tree.
4. Each Mermaid block is parsed with Mermaid (a pinned release, loaded outside the repo). A block that does not parse is fixed.
5. A fresh agent (`gsd-doc-verifier`) gets the pages and the repo, not my conclusions, and returns every claim that does not hold. I fix them and re-run it until it returns none.
6. At the end: `npx hardhat test` (both runners) with the summary line pasted; `git diff --stat` shows only `docs/` and `PLAN.md`; `contracts/interfaces/` is unchanged.

### Writing rules
- Plain sentences: who calls what, what changes, what reverts and with which error. Exact names in code font.
- No filler or sales words (the scan in check 2 lists them: robust, seamless, leverage, comprehensive, ensure, crucial, streamline, powerful, delve, landscape, "not just X but Y"). No closing summary paragraph on a page. No em-dash chains.
- Every number (delay, cap, rule count, decimals) comes from the code or from a deployment parameter, and the page says which.
- The pages describe what the code does today.

### Defaults I chose (say if you want another)
1. **Mermaid** in the `.md` files: GitHub renders it, and the flows need sequence diagrams. The README uses ASCII boxes.
2. **Behaviours the 2026-10-17 review left for you to decide are stated as plain facts**, each with one line saying PLAN.md tracks it. The guardian's `CANCELLER_ROLE` also covers a scheduled unpause (`roles.md`). A 7540 reject is a FORCED move to the controller, so it skips pause and the holder cap, and a redemption claim pays out without the hook (`flows-vaults.md`). The holder cap counts any balance above zero, so a 1-wei holder takes a slot (`transfer-checks.md`). If you change the code, those lines change with it. Alternative: leave them out.
3. **README, SECURITY.md and `CLAUDE.md` are not edited**, and the README gets no link to `docs/` until you say so (one line).
4. **Eight files.** One page per question a reader asks (what is it, who can do what, how is a transfer decided, what happens when I use it, where does the money go, who can change it) is easier to keep correct than one long file.

### Out of scope
Code, interface, test or CI changes. Fixing the open review items. An API reference that repeats the NatSpec. Tooling docs (README and SECURITY.md cover them). The ERC-3643 read adapter and exact ERC-7943 conformance (not built).

### Done when
All eight pages exist, checks 1 to 6 pass with their output shown, and the summary lists every place the brief, README or SECURITY.md disagrees with the code.

### As built (2026-10-17)
- **Pages:** the eight in the table above, with 27 Mermaid diagrams. The README, SECURITY.md and `CLAUDE.md` are not edited, and the README has no link to `docs/`.
- **Checked against** the contracts and Ignition modules at `6fb8e05` (the page index says so).
- **Check 2, names:** every identifier, path, link, anchor and `Contract.function` named on the pages exists, and the banned-wording scan is clean.
- **Check 3, behaviour:** 13 throwaway tests, run on a scratch copy against the deployed stack, all pass. They cover the rule × kind table, the settlement window and weekday formula, the holder cap, pause with the timelock and the guardian's cancel, frozen amounts and event order, intent check order, batch and cancel, the roles after `Activate`, and the 4626 and 7540 worked numbers. The tests are not in the repo.
- **Check 4, diagrams:** all 27 parse and render with Mermaid 11.4.1. Three were redrawn to be readable, and numbered edge labels were changed because Mermaid printed an error inside the diagram.
- **Check 5, independent verification:** two fresh agents read the pages against the code over four rounds (full pass, cross-review, then two passes over the edits). They reported about 40 problems, none in the rule × kind table, the reason codes, the formulas or the worked numbers. Each was checked against the code before it was fixed. The larger ones: the 7540 lock bites at `requestRedeem` (a `TRANSFER`), not at a burn; diagram arrows that were not real calls; the order of checks in `requestDeposit`, `fulfillDeposit` and `executeTransfer`; zero-amount calls on the 4626 vault; the ordering inside `Activate`.
- **Check 6, suite:** `npx hardhat test` on a clean copy of `6fb8e05`: 452 passing (395 solidity, 57 nodejs). Contract source is unchanged by this work.
- **Where the brief, README and SECURITY.md differ from the code** (not edited):
  1. README guardian row: the token's `GUARDIAN_ROLE` only pauses. Cancelling timelock operations is a separate `CANCELLER_ROLE` on the timelock, granted in `Activate`.
  2. README rules row: lists cap, seed and window under the token admin and leaves out `setExemptHolder`.
  3. README runbook: "MINTER, BURNER and AGENT to the issuer's accounts". `Activate` grants `MINTER_ROLE` and `BURNER_ROLE` on `IntentToken` only.
  4. README and brief: "minimum delay ≥ 7 days". `Components.ts` only defaults to 7 days and accepts less. The fixture's post-deploy check enforces it, not the module.
  5. Brief §7: 7540 operators "for claims only". The code also lets an operator call `requestDeposit` and `requestRedeem` for the owner (review item L-5).
  6. SECURITY.md §3 item 1: "depends only on the deployer". The CREATE2 address depends on the `ProxyDeployer` contract's address, not the deployer account.
- **Will go stale when review item M-3 (claimable recovery, in progress in another session) lands:** `flows-vaults.md` ("What cannot be undone once fulfilled", the pause table, the 7540 `max*` text), `roles.md` (function table), `money.md` ("only places the asset can leave the vault") and the statements that `ControllerNotEligible` is raised only on `requestDeposit`.
- **Not yet committed:** another session committed the first version of `docs/` as `e44dbb8` before verification finished. The fixes from the verification rounds are uncommitted edits on top of it.

## v0.3.0 candidate: `MaxHoldersRule` without live seeding (2026-10-22: A and B merged in PR #1, merge commit `b6f8e9b`)

Source: the snapshot-window discussion on the urwa-policy draft (Ethereum Magicians thread 30048, posts #2 to #5), checked against this repo's code.

### Where we are (verified 2026-10-22)

- **Every template starts with the rule.** `RULE_ORDER` in `ignition/modules/roles.ts` puts `maxHoldersRule` in the initial set of `intent`, `fund` and `asyncFund`, and `ProxyDeployer` creates each token already bound to its hook. The count starts at 0 with 0 holders and follows every movement, so a token deployed this way never needs a seed.
- **The 7540 escrow is exempted before any holder exists** (`Activate.ts`), so the exemption does not touch the count.
- **The count survives hook swaps.** The rule's state is keyed by token, and `onlyHook` accepts whichever hook the token has installed. A new hook that keeps the same rule instance keeps counting.
- **Only `MaxHoldersRule` keeps state derived from movements** (it is the only rule with `wantsAfter`). Lockups, the window and identity are set directly or read from a registry, so they stay valid while a rule is out of the set.

### When a seed is still needed

The count is wrong whenever the rule instance missed movements on a token that has holders:
1. the rule is removed from a token's set (`setRules`, or a new hook without it) and added back later;
2. a new rule instance or version replaces the current one, and starts at 0;
3. the rule is added to a token that ran without it.

**Today's behaviour.** `seedHolderCount(token, n)` takes a number computed off-chain, and its caller is the main timelock, so the number is at least 7 days old when it lands (P5 allows a seed at any time).
- **Too high:** the rule turns away new holders below the cap.
- **Too low:** it admits holders past the cap. Once the count reaches zero, the next full exit that does not create a new holder reverts in `after_`. That includes `forcedTransfer` and `burn` of a full balance, so enforcement is blocked too, until a reseed that itself takes 7 days.

### Change A: never remove the rule (procedure and docs, no code)

- To lift a cap, call `setCap(token, type(uint256).max)` instead of dropping the rule. The count keeps running, so lowering the cap again later is a parameter change, not a reinstall.
- Review rule: a `setRules` or `setPolicyHook` proposal that drops `MaxHoldersRule` for a token with `totalSupply() > 0` is rejected, unless it follows the paused seeding procedure in `governance-and-deployment.md`.
- Docs: `transfer-checks.md`, `governance-and-deployment.md` and `roles.md` say this, and name cases 1 to 3 as cold starts.
- **As built (docs only, no code):**
  - `transfer-checks.md`, MaxHoldersRule section: the seed is unchecked and accepted at any time; when the count goes stale and what a stale count does; lift a cap with `setCap(token, type(uint256).max)`.
  - `governance-and-deployment.md`, new section "The holder count across rule and hook changes": the three cold starts, and the procedure for an unavoidable one. It runs:
    1. no `unpause` pending on the recovery timelock, and no other operation on the token;
    2. the guardian pauses;
    3. an off-chain count;
    4. one batch: `setCap` and the exemptions for an instance that has never served the token, the seed, the rule or hook change, then `unpause`.

    If the token is unpaused before the batch executes, start again. Until B ships, this procedure is the only safe cold start, and it costs a pause of at least the delay.
  - `roles.md`: a seeded count is at least the delay old when it lands.
  - **Checked.** Every added sentence was checked against the code, then by an independent read of the diff. That read found two real problems, both fixed:
    - a pending recovery-timelock `unpause`, which nobody can cancel, could lift the pause mid-procedure;
    - "new instance" missed the shared rule instance being added to a token that ran without it. That case needs `setCap` too, or the cap is 0.

    It also corrected two wordings: "stale" became "can go stale", because only movements that add or remove a holder change the count.

### Change B: `MaxHoldersRule` v2 with a verified seed (code)

A rule change is a new deployment (brief rule 12): v2 is attested and swapped in per token. It adds:
- **`seedHolderCountFromHolders(token, address[] holders)`.** Token admin, only while the rule is not in the token's active set. It:
  1. requires `holders` strictly ascending, so there are no duplicates;
  2. sums `balanceOf` over the list, and counts the non-zero balances of accounts that are not exempt;
  3. reverts with `MaxHoldersRule_HoldersIncomplete(sum, supply)` unless the sum equals `totalSupply()`;
  4. sets the count and emits `HolderCountSeeded`.

  If the listed balances add up to the supply, no unlisted account holds anything, so the count is exact when the batch executes, whatever moved during the delay. A new holder outside the list makes the batch revert instead of installing a stale count. Entries with no balance are allowed. Every new holder must pass `IdentityRule`, so listing all verified identities too keeps the batch valid across the delay, at the cost of more entries.
- **`seedHolderCountFromRule(token, previousRule)`,** for case 2 when the list is too long. Only while v2 is not active and `previousRule` is. It copies `previousRule.holderCount(token)`: one read, no holder limit, and exact at execution, because the previous rule counts until the same batch swaps it out. Its weakness is exemptions. They are a mapping, so v2 cannot check it has all of v1's, and a missing one leaves the count off by one for that account. Below the limit, prefer the list seed, which is consistent with whatever exemptions v2 has.
- **`setExemptHolder` leaves the count alone while the rule is not active;** the seed computes it. Today, exempting a holding account (the escrow) on a cold start with a count of 0 underflows, so exemptions could not be set before the seed.
- **`seedHolderCount(token, n)`** stays, but only while the rule is not active (reverses P5). Its only remaining use is a cold start above the list limit, under a pause (below).
- **"Active"** means the rule is in `IComplianceHook(IPolicyGated(token).policyHook()).rules()`. A hook without `rules()` makes the seeds revert.

**Measured limit of the list seed.**
- **First estimate (stand-in):** anvil with Prague rules, a plain ERC-20 behind an ERC-1967 proxy, called through a `TimelockController` batch: about 4,470 gas per entry, so about 3,720 entries.
- **In-stack (the number that counts):** the production deployment (`deployStack`: Ignition modules, `IntentToken` behind its proxy), a batch on `GovernanceTimelock` of `setCap`, `seedHolderCountFromHolders` and `setRules`, with random-looking addresses that each hold tokens.
  - 500 entries: 3,627,120 gas; 1,000: 7,072,643; 2,000: 13,978,456. That is about 6,900 gas per entry.
  - 2,400 entries: 16,746,337 gas, which fits under the 16,777,216 per-transaction cap (EIP-7825). With 2,410, the batch ran out of gas and reverted.
- **Why it is higher than the estimate:** each listed account that holds tokens also costs a cold read of its exemption in the rule (2,100 gas).
- **Empty entries:** 1,000 holders plus 1,000 entries with no balance took 11,533,516 gas, so an empty entry costs about 4,500 gas: the balance read still happens. Padding the list as a margin takes room from the 2,400.
- **Ceiling:** the two cold reads alone cost 4,200 gas per holder, so no implementation of this check can pass about 4,000 holders in one transaction.

**Above the limit.** A cold start with more than about 2,400 listed accounts that hold tokens has two options:
- `seedHolderCountFromRule`, from an instance that has been counting;
- a pause. The guardian pauses, the count is taken off-chain, and one batch runs `seedHolderCount`, `setRules` and `unpause`. The pause lasts at least the 7-day delay. The agent must not run `forcedTransfer`, `recoverRedeemRequest` or `recoverClaimable` meanwhile, because FORCED moves while paused. Change A exists so that this never happens.

**Migration, per token, in one timelock batch** (after v2's codehash is attested):
1. `v2.setCap`;
2. `v2.setExemptHolder` for each exemption, with no count change while v2 is inactive;
3. `v2.seedHolderCountFromHolders`, or `seedHolderCountFromRule`;
4. `hook.setRules`, with v2 in v1's place.

In Ignition, `Components` deploys v2. `roles.ts` and `Activate` change only the contract name.

**Tests first.**
- **Unit** (`MaxHoldersRule.t.sol`, `vm.mockCall` and `vm.expectCall`):
  - the list seed counts exactly;
  - an unlisted holder reverts;
  - unsorted and duplicate lists revert;
  - zero-balance entries are allowed;
  - exempt accounts are summed but not counted;
  - every seed reverts while active and for a non-admin;
  - `seedHolderCountFromRule` reverts unless the previous rule is active;
  - `setExemptHolder` leaves the count while inactive;
  - fuzz with `bound`.
- **Integration, today's behaviour first:**
  - a remove and re-add with a stale seed admits a holder past the cap;
  - a count that is too low blocks a full `forcedTransfer` once it reaches zero.
- **Integration, the fix:**
  - a holder arrives between proposal and execution: the off-chain seed installs a stale count, and the list seed reverts;
  - a list that includes that holder installs the true count;
  - v1 to v2 through `seedHolderCountFromRule` keeps the exact count;
  - a 7540 cold start with the escrow exempt.
- **Gas:** the in-stack limit, as above.
- **Planted bugs:**
  - the ascending check removed;
  - the supply check removed;
  - exempt accounts counted;
  - a seed allowed while active;
  - `seedHolderCountFromRule` without its active check;
  - `setExemptHolder` adjusting the count while inactive;
  - `>` changed to `>=` in `_releaseFrozen` (see the table below).

### Decisions

1. **A now, B later. Owner, 2026-10-22: approved.** A is done. Later the same day the owner noted that the code is a demo, so changes that make it better are fine, and asked for B now.
2. **Interface change. Owner, 2026-10-22: allowed.** `IMaxHoldersRule` is re-pinned from `0x0e091382` to `0x360b3dad`.
3. **P5 reversal. Owner, 2026-10-22: reversed.** Every seed reverts while the rule is in the token's rule list.
4. **`ruleId`. Owner, 2026-10-22: keep `MaxHoldersRule.v1`,** so a hook can never hold the old and the new instance at once. The attested codehash tells the versions apart.

### Change B as built (2026-10-22)

**Code.**
- `IMaxHoldersRule`:
  - adds `seedHolderCountFromHolders(token, holders)` and `seedHolderCountFromRule(token, previousRule)`;
  - adds four errors: `MaxHoldersRule_RuleActive`, `MaxHoldersRule_HoldersNotAscending`, `MaxHoldersRule_HoldersIncomplete` and `MaxHoldersRule_PreviousRuleNotActive`;
  - updates the NatSpec of the interface, `seedHolderCount` and `setExemptHolder`.
  - Events are unchanged; `InterfaceFreeze.t.sol` re-pins the interface ID.
- `MaxHoldersRule`:
  - an `onlyWhileInactive` modifier on all three seeds;
  - `_isListed(token, rule)` reads `IComplianceHook(IPolicyGated(token).policyHook()).rules()`, and every call it makes is a view (STATICCALL);
  - `setExemptHolder` adjusts the count only while the rule is listed;
  - `_seed` is shared by the three seeds and emits `HolderCountSeeded`;
  - `ruleId` is unchanged.
- **Static analysis.**
  - Slither first flagged `_balance == 0` (rewritten as `> 0`, so no suppression) and three zero-start locals (`slither-disable` with the reason, recorded in SECURITY.md §4).
  - Aderyn flagged the revert inside the loop. It is acknowledged inline as in `ComplianceHook`, and recorded in SECURITY.md.

**Tests first.**
- New tests were written against empty stubs: 145 passing, 15 failing. The 15 were exactly the new behaviour.
- The two tests that document today's behaviour passed before and after, as planned: the stale off-chain seed, and a full `forcedTransfer` reverting at a count of zero.
- After the implementation: 160 passing in the three affected files.
- **Unit** (`MaxHoldersRuleUnit_Seeding`):
  - every seed reverts while the rule is listed, and the list and copy seeds revert for a non-admin;
  - the list seed counts non-exempt accounts that hold tokens, with `expectCall` on `totalSupply`;
  - a fuzz over three balances with `bound`;
  - an account outside the list reverts with the sum and the supply;
  - unsorted, duplicate and zero-address lists revert with the index;
  - the copy seed copies a listed previous rule (with `expectCall`) and reverts for an unlisted one;
  - `setExemptHolder` while unlisted emits only `HolderExemptionSet`.
- **Existing tests:**
  - the seed test renamed `..._WhileTheRuleIsInactive_...`;
  - the unit base mocks the hook's `rules()`, and `_seed` takes the rule out of the list while it seeds;
  - the fake-token test mocks the attacker's `rules()`;
  - the static-call test covers both new seeds.
- **Integration:**
  - `MaxHoldersRuleIntegration_Seeding`, on a real `IntentToken` and `ComplianceHook`:
    - the stale off-chain seed;
    - the list seed reverting when a holder arrives after the proposal, and exact with a superset list (with `canTransfer` parity on the next mint);
    - the copy seed keeping the live count across a replacement;
    - the hook rejecting a set with both instances;
    - every seed reverting while listed;
    - a full `forcedTransfer` reverting at a count of zero.
  - `Gated7540VaultIntegration_HolderRuleColdStart`: a new instance on a live vault whose escrow holds shares. The exemption is set while the instance is unlisted, then the list seed runs, then the swap; the count equals the live rule's.

**Docs.**
- An independent read of the docs and NatSpec diff against the code found eight problems. All are fixed:
  - the 2,400 limit ignored empty entries, which still cost a balance read (now measured at about 4,500 gas);
  - "the next seed sets it" holds only if the exemptions are set before the seed; the NatSpec and the docs now say to set them first;
  - the copy seed is exact only if the old count is and both instances exempt the same accounts; the docs now say how the batch brings the exemptions in line, including for an instance coming back;
  - "a live count is never overwritten" was overstated, because a batch can take the rule out, seed and put it back;
  - "fails closed until re-seeded" was overstated;
  - the governance table did not list the new reverts;
  - "the seed has to read the count when the batch executes" contradicted the paused procedure;
  - three nits: the `setExemptHolder` revert condition, the `_index` parameter at index 0, and `holderCount`'s `@return` (non-exempt).
- `transfer-checks.md`: the three seeds and their errors; `setExemptHolder` while unlisted.
- `governance-and-deployment.md`: the copy seed for a replacement and the list seed for any cold start, with the measured limit. The paused procedure applies only above that limit, with no live instance to copy from.
- `roles.md`: the function table.
- `docs/README.md`: "Checked against" names this change.

**Planted bugs** (three scratch copies; each one run against `MaxHoldersRule.t.sol`, `Gated7540Vault.t.sol` and `RuleSetIntegration.t.sol`):
- **Caught: all 11 rule bugs,** with 1 to 9 failing tests each:
  - the ascending check removed, or weakened to allow duplicates;
  - the supply check removed;
  - exempt accounts counted;
  - zero balances counted;
  - each of the three seeds allowed while the rule is listed;
  - the copy seed without its previous-rule check;
  - `setExemptHolder` adjusting an unlisted count;
  - `_isListed` always false.
- **`_releaseFrozen` `>` → `>=`:** this is urwa-policy 0.2 #2b, run against the base, vault and token tests. It survived (212 passing). `test_WhenTheFrozenAmountStillFits_ItIsLeftAlone` (fuzzed) was added; it passes on the real code and fails with the bug planted.

**Gates** (2026-10-22, on the final code):
- `npm run lint:sol`: 0 warnings. `npm run fmt:check`: clean. `npm run typecheck`: clean.
- `npx hardhat test`: 513 passing (453 solidity, 60 nodejs). `--test-profile isolated`: 453 passing.
- `slither .`: 0 results. `npm run aderyn`: 0 findings.
- `npm run validate:upgrades`: 3 of 3 passed.
- `npm run verify:reproducible`: 13 contracts identical across two production builds, the default profile and forge.
- **Halmos:** not run locally (not installed on this machine), so CI is the check. Its targets, the nonce, signature and frozen paths in the base and intent code, are not changed by this work.
- **Attestation impact:** `MaxHoldersRule` gets a new codehash, so it needs a new attestation and a per-token migration (the batch above). Every other contract is unchanged.

### Do the urwa-policy fixes apply here?

| urwa-policy fix | Here |
|---|---|
| 0.1 fix 1: read the policy's answer only after the length check | No. The base calls the hook with a Solidity call, which reverts on short or empty return data. There is no hand-written assembly on that path. |
| 0.1 fix 2: seed only before installation | Yes: change B (reverses P5). |
| 0.2 #1: the FORCED kind must not leak to the next movement | Already tested: `test_WhenAPlainTransferFollowsAForcedTransferInTheSameTransaction_ItIsAPlainTransfer`, and the EXECUTED case in `IntentSettledUpgradeable.t.sol`. |
| 0.2 #2a: a forced overdraft reverts with `ERC20InsufficientBalance` | Already tested, for `forcedTransfer` and `burn`. |
| 0.2 #2b: no `Frozen` event when the frozen amount already fits | Probably untested: no test asserts that no event is emitted when `frozen == balance - amount`. The impact is low, a redundant event. It is in B's planted-bug list; add a test if it survives. |
| 0.2 #3: the redundant code-length check | No equivalent. |
| 0.2 #4a and #4b: the zero-amount and self-transfer guards in the cap | Already tested: `test_WhenTheAmountIsZero_ItIsOkEvenUnconfigured` and `test_WhenTheAmountIsZeroOrSelf_NothingIsRead`. |
| 0.3 #1: the mint pre-flight's operator is zero, not the caller | Applies in principle. `_canTransfer` (and so the vault `max*`) and `isUserAllowed` use the caller for a mint. No rule reads the operator on MINT, so no answer is wrong today; only the pre-flight context depends on who calls it. It is a base change, so an upgrade through the timelock and a new attested implementation. Recommend folding it into the next base bug-fix upgrade, not upgrading for it alone. |
| 0.3 #2: a reinstall is a new installation | Yes: cases 1 and 2 above. |
| 0.4: the snapshot window | Yes, and the window is wider here, because the seed goes through the 7-day timelock. Change B's list seed closes it. |

## Audit leftovers from 2026-10-17 (approved 2026-10-22)

The two items still open from the 2026-10-17 audit. Both are text only. The build has no metadata hash, so the bytecode and the attested codehashes do not change.

1. **Two `Gated7540Vault` comments overclaim.**
   - `withdraw`: "assets can never be drained for zero shares". `_claimMint`: "shares can never be minted for zero assets".
   - Rounding up makes each partial claim take at least its pro-rata share, which can use one side of the claimable pair up first. After that, the rest of the other side moves against zero.
   - **Proof, in a scratch copy:** with 3 shares claimable for 10 assets, three one-asset withdrawals use the shares up, and the fourth pays an asset for 0 shares. With 10 shares claimable for 3 assets, the fourth one-share mint consumes 0 assets.
   - Nothing is lost: the remainder is owed to the controller either way.
   - **Change:** both comments say what the rounding does guarantee, and what happens after one side is used up.
2. **README runbook step 7 lags `assertHandedOver`.**
   - **Missing from step 7:** the check that every hook's `ADMIN` is the main timelock, the check that no rule exposes `hasRole` or `owner`, and the recovery timelock in the deployer check.
   - **Change:** step 7 gets these three.
   - **Same list in `docs/governance-and-deployment.md` ("After `Activate`"):** it also omits the hook-`ADMIN` check, so it gets that one line too.
3. **`docs/README.md` "Checked against"** names the PR #1 merge commit `b6f8e9b`, as promised for after the merge.

**Gates:** lint, fmt, tests in both runners, Slither, Aderyn, and a check that the `Gated7540Vault` deployed bytecode is unchanged.

**Result (2026-10-22).**
- Both comments now say what the rounding guarantees and what happens after one side is used up.
- README step 7 lists the hook-`ADMIN` check, the rule access-control check and both timelocks in the deployer check. The docs list has the hook-`ADMIN` check.
- `docs/README.md` names `b6f8e9b`.
- **Gates:**
  - lint 0, fmt clean;
  - 513 passing (453 solidity, 60 nodejs), isolated 453;
  - Slither 0, Aderyn 0;
  - the `Gated7540Vault` deployed bytecode hash is unchanged (`303eebf4…`).

## Fund layer: `Fund` plus `FundHoldersRule` (approved 2026-10-22; F-1 and F-2 approved and committed on `fund-layer`, not pushed)

Source: [the assessment](docs/superpowers/specs/2026-10-22-fund-assessment.md) and its [benchmark](docs/superpowers/specs/fund-gas-bench/). On 2026-10-22 the owner asked for this plan using the assessment's defaults for its open questions. No code is written. Nothing here changes an existing contract, so the deployed bytecode of all 13 current contracts stays as it is.

### Goal

A fund is a set of share classes. Each class is an existing gated token or vault, with its own balances, hook and roles. The fund adds what no single class can know: a list of its classes, the number of distinct investors across them, and which classes each investor is in.

- A fund-wide investor cap, enforced through each class's hook like every other policy.
- Works the same for `IntentToken`, `Gated4626Vault` and `Gated7540Vault`. The fund code never branches on which one a class is.
- No change to the base, `ComplianceHook`, `ProxyDeployer`, the registry, the existing rules, or any existing interface.

### Assumptions

The first seven are the assessment's defaults for its questions 1 to 7. F8 to F15 are choices made while planning. Say which you want changed.

| # | Assumption | Why |
|---|---|---|
| F1 | Per-subscription lots are not solved. `LockupRule` keeps one unlock time per holder and token, so a new subscription resets it. | A lot ledger is a separate design (ERC-1450 batches, ERC-1410 partitions). |
| F2 | Investors are counted by address. Dust can fill the cap and one investor with two wallets counts twice (finding L-1, accepted for `MaxHoldersRule`, inherited here). `IIdentityRegistry` does not change. | An identity id needs a registry change and an identity provider that supplies it. |
| F3 | One subscription asset per class. `Gated7540Vault` stays its own share token. | Several assets per class means splitting the share token from the vault (ERC-7575). |
| F4 | `MAX_CLASSES = 32`. | The mask allows 256. On-chain loops over classes cost about 8,600 gas each, so the limit keeps them bounded. |
| F5 | Holders can transfer among verified investors. No restricted-transfer rule (the ERC-1450 behaviour) is built. | It is a separate rule, and it must let the 7540 escrow legs through (assessment 5.5). |
| F6 | Two contracts: `Fund` holds state, `FundHoldersRule` holds policy. | A replaced rule keeps the investor count. `MaxHoldersRule` needed a seeding procedure because its state lives in the rule. Costs about 3,900 gas per movement. |
| F7 | No class price on chain, so no AUM view. | Needs a price source and an owner. Later. |
| F8 | `Fund` is `Ownable` like `ProxyDeployer`: the deployer owns it during deployment and `Activate` hands ownership to the timelock. This differs from assessment 5.1, which said an immutable `ADMIN`. | Setting up a fund (`setRule`, `registerClass`, the cap) would otherwise need timelock operations, a 7-day wait on a first deployment. `ComplianceHook` avoids that by taking its rules in the constructor, which `Fund` cannot do because the rule and the fund need each other's address. |
| F9 | Registration is append-only and only for a class with `totalSupply() == 0`. | A class that already has holders would start with a wrong count, the cold start that `MaxHoldersRule` had to solve. This closes it by construction. A class can be closed to new issuance, not unregistered. |
| F10 | The fund cap rejects with the existing `MAX_HOLDERS`. One reason is appended: `NOT_FUND_CLASS`. | Fewer frozen codes. The hook order tells which cap fired, because the class cap runs first. |
| F11 | One hook per class stays. `FundHoldersRule` goes last in `RULE_ORDER`. | A shared hook would make every class pay for every rule in the list (6,945 to 10,219 gas per rule). |
| F12 | The demo deployment makes the three existing tokens (`intent`, `fund`, `asyncFund`) classes of one demo fund. The Ignition keys `fund` and `asyncFund` already mean the 4626 and 7540 vaults, so the new futures are `fundContract` and `fundHoldersRule`. The old keys are not renamed. | Avoids a clash without touching tests that use the old keys. A 4626 vault named `fund` is a misnomer after this lands, and it is left alone. |
| F13 | Files: `contracts/fund/Fund.sol`, `contracts/hooks/rules/FundHoldersRule.sol`, `contracts/interfaces/IFund.sol`, `contracts/interfaces/IFundHoldersRule.sol`, each with its `.t.sol` next to it. | Rules live with the rules. |
| F14 | The class itself is never counted (no storage). Any other account can be exempted with `setExempt`, with the same semantics as `MaxHoldersRule.setExemptHolder`. | The 7540 escrow holds shares at the vault's own address. |
| F15 | Two review checkpoints, F-1 and F-2 below. | Contracts and Solidity tests first, then deployment, TypeScript tests and docs. |

### Design

**`Fund`** (immutable code, `Ownable`, `IFund`). Immutable: `REGISTRY`. Constant: `MAX_CLASSES`.

State:
- an append-only class list and a `classIndexOf` mapping (position plus one, so 0 means "not a class");
- one slot holding `{rule, count, cap}`: the installed rule, and a 48-bit count and cap. The rule is set before the first investor, so the first count write is a 5,000 write and not a 22,100 one (benchmark, M4 against M2), and the rule is read with the count and cap for free. (F-1 had `{count, cap}` in 128 bits each, with the rule in a slot of its own. F-2 changed it, see "F-2 as built".)
- `holder[account]`: one bit per class, plus a top bit for "exempt".

Owner functions:
- `registerClass(token)` reverts unless the token is new, the list is under `MAX_CLASSES`, the rule is set, `supportsInterface(IPolicyGated)` is true, its current hook lists the rule (`IComplianceHook.rules()`), and `totalSupply() == 0`.
- `setRule(rule)`: the rule must be attested as RULE in `REGISTRY`.
- `setHolderCap(cap)`.
- `setExempt(account, exempt)`: for an account that holds a class, the count follows the change, as in `MaxHoldersRule`.

Rule-only functions: `join(token, account)` and `leave(token, account)`. Each resolves the class itself and reverts for an unregistered token (the second gate, after the rule's own). Each is a no-op for `account == token`. `join` sets the bit and raises the count when the account had no class and is not exempt. `leave` clears the bit and lowers the count when the last class goes and the account is not exempt.

Views: `classCount`, `classAt`, `classIndexOf`, `holderCount`, `holderCap`, `rule`, `heldClasses(account)`, `isExempt(account)`, and `positionsOf(account)`, which returns each class balance the account holds. The rule also needs one combined read (class index, the account's bits, count and cap in one call) because every external call costs several hundred gas even warm. That function is kept only if the measurement shows it saves at least 1,000 gas.

Events, on every state change: `ClassRegistered`, `RuleSet`, `HolderCapSet`, `ExemptSet`, `HolderCountUpdated`, and `HolderClassesUpdated(account, mask)` on every mask change. The last one is the register: about 2,400 gas each, and it replaces an on-chain holder list.

**`FundHoldersRule`** (immutable code, `BaseRule`, `IFundHoldersRule`). Immutable: `FUND`. `ruleId` is `keccak256('FundHoldersRule.v1')`. `wantsAfter` is true. The council attests it as RULE.

`check` runs the cheap tests first:
1. An unregistered `ctx.token`, or a rule that is not the fund's installed one (added in F-2), returns `NOT_FUND_CLASS`, for every movement including burns and zero amounts, so `isUserAllowed` also fails closed on a class that is not registered yet.
2. Zero amount, self-transfer, a burn, kind FORCED, a receiver equal to `ctx.token`, an exempt receiver, and a receiver who already holds any class return `TRANSFER_OK`.
3. Otherwise the receiver is a new investor. A cap of 0 rejects. A count below the cap passes. A count at or above the cap passes only when the move is net zero: the sender leaves the fund entirely (full balance, and this is the sender's only class, and the sender is not exempt) and the count is at most the cap. That last test runs only when the cheap one already failed.

`after_` skips zero amounts and self-transfers, calls `join` for a receiver whose class balance went from zero to positive, and calls `leave` for a sender whose balance reached zero. Movements to an existing class holder write nothing. FORCED is exempt from the cap and still counted, as in `MaxHoldersRule`.

**What does not change.** `PolicyGatedERC20Upgradeable`, `ComplianceHook`, `ProxyDeployer`, `PolicyRegistry`, `IntentExecutor`, the three templates and the four existing rules. No vault change, so the 3,030 bytes left in `Gated7540Vault` stay.

### The invariant that is new

Existing rules are safe because their state is keyed by `ctx.token`. The fund's state is shared across classes, so that argument does not carry over. A fake token can pass `onlyHook` by naming itself as the hook's token, and without the gate it could set masks for real investors. Two gates stop that: the rule refuses an unregistered `ctx.token`, and `Fund.join` and `Fund.leave` accept only the installed rule and also refuse an unregistered token. Only the owner (the timelock after hand-over) registers. This gets its own tests and a Halmos property.

### Interfaces and the freeze

- New: `IFund`, `IFundHoldersRule`. Their ERC-165 ids, event topics and the new reason are pinned in `InterfaceFreeze.t.sol`.
- `Errors.sol` gets `NOT_FUND_CLASS` appended, which the brief allows. No existing id, topic or code changes. The freeze test proves it.
- Errors are named `Fund_*` and `FundHoldersRule_*` (rule 16).

### Tests first (rule 5: the red run is shown before each implementation)

Unit tests isolate with `vm.mockCall` and `vm.expectCall` (rule 16), fuzz with `bound`:
1. `Fund.t.sol`:
   - `registerClass`: each revert (not owner, zero address, duplicate, over `MAX_CLASSES`, no rule set, not ERC-165 `IPolicyGated`, hook does not list the rule, supply above zero);
   - `setRule`: unattested and zero address;
   - `join` and `leave`: only the rule, only a registered token, the class itself never counted, each count transition;
   - `setExempt` on a current holder and on a non-holder;
   - the views, including `positionsOf` and out-of-range `classAt`.
2. `FundHoldersRule.t.sol`:
   - accept and each reject (`NOT_FUND_CLASS` for transfer, mint and burn, `MAX_HOLDERS`);
   - cap 0, FORCED, the escrow receiver, an exempt receiver;
   - the net-zero case at the cap, once with the sender keeping another class and once without;
   - `after_` joins and leaves, a zero amount, a self-transfer;
   - `*_TokenCallsAreStatic`, the same guard `MaxHoldersRule` has;
   - fuzz.
3. The registration gate: a fake token that names itself, and a fake hook calling `after_`, change neither `holderCount` nor any mask; a direct `join` or `leave` from a non-rule reverts.
4. Integration, three classes (one `IntentToken`, one `Gated4626Vault`, one `Gated7540Vault`), real hooks and the real rule set:
   - `canTransfer` and the state-changing call agree for each outcome;
   - 7540 `requestRedeem`, `fulfillRedeem`, `rejectRedeemRequest` and `recoverRedeemRequest` leave the count right (the escrow is never counted);
   - a hook replacement that keeps the rule keeps the state, and a `setRule` to a new instance keeps the count;
   - an investor in two classes counts once, and counts zero after leaving both;
   - the vault `max*` functions return 0 at a full cap.
5. Invariants (stateful fuzz over the three classes): `holderCount` equals the number of non-exempt accounts with any class bit, and a class bit is set exactly when that account's class balance is positive.
6. Halmos: an unregistered token cannot change the count or a mask; a join followed by a leave restores the count. Kept only if it runs on the proxied path as the existing properties do.
7. `ContractSizes.t.sol` gets both contracts.

### Gas

Expected on an ordinary transfer between existing class holders: about +23,000 on top of whatever the class's hook already costs (benchmark M10 at +19,326, plus the separate-contract cost of about 3,900, measured over a hook with `IdentityRule` and a class `MaxHoldersRule`). A first investor by mint is about +47,000. These are expectations, not gates. The real contracts are benchmarked again at the end with the same harness, and the plan stops for review if an ordinary transfer is more than 10% above that.

### Deployment (F-2)

- `Components`: deploys `Fund` (owner is the deployer, `REGISTRY` is the registry) and `FundHoldersRule(fund)`.
- Council step 1 attests `FundHoldersRule` as RULE with the other rules. The council reads `rule.FUND()`, the fund's code and its owner first: the rule's codehash covers the fund's address and not the fund's code. `Fund` is reviewed but not attested, like `ProxyDeployer`.
- `roles.ts`: `RULE_ORDER` gets `fundHoldersRule` last for all three tokens. `Tokens` takes it as a rule parameter, so every hook is built with it.
- `Activate`, after all token deploys: `setRule`, `setHolderCap` (new parameter `fundHolderCap`, default equal to `holderCap`), then `registerClass` for each token, then `transferOwnership(timelock)`. Until a class is registered, every movement on it is rejected with `NOT_FUND_CLASS`, so no balance can exist before registration. The roles that mint come after registration.
- `assertHandedOver` gains: the fund is owned by the timelock, its rule is the attested instance, and every demo token is a registered class.
- Runbook (README step 7 and `docs/governance-and-deployment.md`): never remove `FundHoldersRule` from a registered class's hook (same rule as `MaxHoldersRule`, change A), because movements made without it are not recorded; register a class only while its supply is zero; the council check above.

### TypeScript (F-2)

`fixtures.ts` attests the new rule in council step 1. A new `test/nodejs/fund.test.ts`: a class registered through the real timelock after the delay; the fund cap enforced across two classes through viem; `HolderClassesUpdated` decoded; `canTransfer` parity from the TypeScript side. The existing 60 TypeScript tests must pass unchanged apart from the rule list in the fixtures. A test that spreads holders across classes counts each holder once per fund, so it can hit a fund cap equal to the class cap earlier than before. If so, the fixtures raise `fundHolderCap`, and the test body stays as it is.

### Docs (F-2)

- `docs/`: `architecture.md` (contracts table, structure and inheritance diagrams), `roles.md`, `transfer-checks.md` (a `FundHoldersRule` section), `governance-and-deployment.md`, and "Checked against" in `docs/README.md`. Every edited sentence is verified against the code, as in the last docs pass.
- README: contracts list, rule order, deviations from the brief, runbook step 7.
- Proposed brief edits, which need your OK because the brief is the standing instruction file: §3 layout gets `contracts/fund/`, and §6 gets `FundHoldersRule` in the rule list.

### Checkpoints and gates

- **F-1:** interfaces, `NOT_FUND_CLASS`, `Fund`, `FundHoldersRule`, the Solidity tests above, the freeze and size tests. Stop for review.
- **F-2:** Ignition, `fund.test.ts`, the benchmark rerun, the docs. Stop for review.
- **Gates at each:** `npx hardhat test` in both runners with the summary line pasted, `npm run lint:sol`, `npm run fmt:check`, `slither .`, `npm run aderyn`, `npm run validate:upgrades`, the Halmos run, the isolated profile, and `npm run verify:reproducible` (the manifest grows from 13 to 15: `FundHoldersRule` under ATTESTED, `Fund` under DEPLOYED). The 13 existing entries must be byte-identical to `v0.2.0`. The baseline today is 513 passing (453 Solidity, 60 TypeScript).
- **Attestation impact:** new `FundHoldersRule` (RULE) and `Fund` (reviewed, not attested). Unchanged: every current attested contract.

### Risks

1. The new invariant above. It is the one place a bug could let one class corrupt the count for all of them.
2. A rule dropped from a registered class's hook leaves the state silently stale. The runbook forbids it and monitoring should read `hook.rules()`. The fund cannot see it.
3. Counting by address (F2).
4. About +23,000 gas on each movement in a class. The cheapest way to cut it is folding the fund count into `MaxHoldersRule`, which saves most of the 10,219 per-rule dispatch cost. That is not in this plan: it merges two rules and re-pins `IMaxHoldersRule`.
5. Replacing `Fund` itself loses its state. The split exists so that the rule is the part that gets replaced. A `Fund` replacement would need a seeding path like `MaxHoldersRule`'s, and is not planned.

### Not in this plan

Class prices and AUM, restricted transfers, identity ids, lots, an ERC-7575 share split, CREATE2-derived class addresses, a data-contract rule list in `ComplianceHook`, and folding the fund count into `MaxHoldersRule`.

### F-1 as built (2026-10-22, approved by the owner)

Contracts and Solidity tests only. No Ignition, no TypeScript test, no docs (F-2). Committed on `fund-layer`, not pushed.

- **New code:**
  - `contracts/interfaces/IFund.sol`, `contracts/interfaces/IFundHoldersRule.sol`;
  - `NOT_FUND_CLASS` appended to `Errors.sol`;
  - `contracts/fund/Fund.sol`, `contracts/hooks/rules/FundHoldersRule.sol`;
  - `contracts/test/MockStatefulFund.sol`, a fund whose read writes state, for the static-call guard.
- **Tests (124 new):**
  - `Fund.t.sol` 56: every revert, each count transition, exemption, views, and a fuzz run against a plain model of the same rules;
  - `FundHoldersRule.t.sol` 44: accept and each reject, the net-zero cases, `after_`, the static-call guard, and the registration gate with the real `Fund` (a fake token that names itself, a caller that is not the rule, the real hook of a real class);
  - `FundIntegration.t.sol` 21: one `IntentToken`, one `Gated4626Vault` and one `Gated7540Vault` with real hooks and rules, covering the cap across classes with pre-flight parity, net zero at the cap, FORCED counted, an unregistered class, the 7540 escrow (request, fulfil, reject at a full cap, recover), a hook replacement and a rule replacement;
  - `FundInvariant.t.sol` 3 invariants over 128,000 calls per seed (three seeds run): class bits equal positive balances, the count equals the non-exempt investors, and no class, fulfiller or custody account is ever recorded;
  - `halmos/FundHalmos.t.sol` 5 properties: an unregistered token never changes state, only the rule writes, and the count is right after any two operations on two accounts and any three on one account (the second account already an investor), and join then leave restores the state.
- **Freeze and size:** `InterfaceFreeze.t.sol` pins both interface ids (computed independently with `cast sig`, and equal to the compiler's), six event topics and the new reason. `ContractSizes.t.sol` and the reproducibility manifest (13 to 15 contracts) have both new contracts.
- **Red runs.**
  - The freeze additions failed to compile on the missing `Reasons.NOT_FUND_CLASS` alone.
  - Against a throwaway stub, none of the 56 `Fund` tests passed.
  - Against a stub rule, 24 rule tests failed and 20 passed. The 20 are accept-path and "nothing recorded" tests that an always-OK stub satisfies by construction, and each has a failing counterpart.
  - The integration and invariant suites test existing contracts in combination, so they were not red first. The mutation runs below are their evidence.
- **Mutation checks, on a scratch copy.**
  - 40 bugs planted (20 in `Fund`, 20 in the rule), 39 killed by the Solidity tests. The survivor was an equivalent mutant: the `account == token` guard in `leave` was dead code, because `join` never records the class itself. It is removed.
  - Seven planted in `Fund` for Halmos. Six were killed at first. The seventh (an exempt account that leaves decrements the count) needs the count above zero to show, so the three-operation property now starts with a second investor, and all seven are killed.
- **Differences from the plan above:**
  - `admission` is in from the start. Whether it saves the 1,000 gas the plan set as its test stays a measurement for F-2.
  - `leave` has no guard for the class itself (above). The rule does not skip a receiver equal to the token: the fund ignores it, and a test pins that.
  - A second `FundHoldersRule` with the same fund has the same codehash, so the registry already attests it. Replacing a rule with identical code needs no attestation. Only changed code does.
  - `IFund` lists its two constant getters under views, which the lint's declaration order requires.
- **Finding, rule replacement (superseded in F-2).** `Fund.setRule` takes effect at once. In F-1, until the classes' hooks listed the new rule, the old rule's pre-flight still said yes and its `after_` was refused with `Fund_OnlyRule` only for movements that change a holder's classes, so a transfer between existing holders went through. An outside review of F-1 pointed at both halves. F-2 makes the old rule fail closed in `check` instead, see "F-2 as built".
- **Results.**
  - `npx hardhat test`: 637 passing (577 Solidity, 60 TypeScript), up from 513. The isolated profile: 577 passing.
  - Lint 0, fmt clean, `tsc` clean, Slither 0, Aderyn 0, upgrades-core 3 of 3 (`Fund` is immutable, so it is outside its scope). Slither's first run found three things in the new code (two locals that start at zero by design, one ignored tuple return) and Aderyn's found two view-call-before-write patterns. Each has an inline suppression with its reason.
  - `verify:reproducible`: 15 contracts identical across the two production builds.
  - The deployed bytecode of the 13 existing contracts is identical to `d3574df`, compared against a pristine build of that commit.
  - Halmos: the 5 fund properties take about 38 seconds. The existing four take 3 seconds. A first draft of one property took 124 seconds, so it was split.
- **Not yet (done in F-2):** the benchmark rerun, so the gas expectations above were estimates.
- **Note:** `docs/superpowers/` is git-ignored at the owner's request (2026-10-22). The assessment and benchmark linked in this section are local files.

### F-2 as built (2026-10-23, approved by the owner)

Ignition, the TypeScript tests, the benchmark rerun, the docs, and two changes to F-1's code that came out of the measurements and an outside review. The owner approved it, the fail-closed change included, and it is committed on `fund-layer`, not pushed.

- **Deployment.**
  - `Components` deploys `Fund(deployer, registry)` and `FundHoldersRule(fund)`. `RULE_ORDER` puts `fundHoldersRule` last for all three tokens, and `Tokens` takes it as a rule parameter.
  - `Activate` takes `fundContract`, `fundHoldersRule` and `fundHolderCap`. The plan said `fundHolderCap` would default to `holderCap`. I made it required, like `holderCap`, because that is simpler, and did not check whether Ignition can default one parameter to another. After the token deploys it calls `setRule` and `setHolderCap`, then `registerClass` for `intent`, `fund` and `asyncFund`, chained so they are classes 1, 2 and 3. The role grants wait for the registrations, and `Fund` ownership moves to the timelock after them.
  - `assertHandedOver` gained: the fund is owned by the timelock, runs the attested rule that points back at it, has the intended cap, and holds the three tokens as classes 1 to 3 in order.
- **TypeScript.** `fund.test.ts` has 7 tests: the deployment, the register events decoded, the cap across three classes with pre-flight parity, an executor-settled intent at a full cap (refused, with `canExecute` agreeing, and a whole-balance intent admitted), a class created after hand-over (rejected until the timelock registers it), the rule replaced in one timelock batch, and the rule set alone (every movement fails closed, pre-flight included). `deployment.test.ts` gained a twin hook without the fund rule, which now stops `Activate` at `registerClass`. Two existing tests changed for the fifth rule: a hard-coded rule count of 3 in `governance.test.ts`, and the twin hook in `deployment.test.ts`, which now lists the fund rule so that it still reaches the post-deploy check. The other 58 pass unchanged.
- **Benchmark on the real contracts**, over a hook with `IdentityRule` and a class `MaxHoldersRule`, gas including the 21,000 intrinsic (harness in `docs/superpowers/specs/fund-gas-bench/`):

  | Movement | Added by the fund layer |
  |---|---|
  | transfer between existing holders | +26,906 |
  | mint to an existing holder | +25,285 |
  | existing investor takes a second class | +31,808 |
  | first investor ever | +53,346 |
  | new investor by transfer | +54,964 |
  | whole-balance move to a new holder | +57,342 |
  | burn, investor stays in the fund | +33,124 |
  | burn, investor leaves the fund | +32,724 |

  The plan expected about +23,000 for an ordinary transfer and +47,000 for a first investor, so the real cost is 17% and 13% above it, over the plan's 10% line. The estimate took the lean in-rule variant (+19,326) and added the 3,900 split cost, and the real rule is closer to the non-lean variant with a separate contract (+26,674). It is not a bug, and nothing here stops on it, but the plan said to stop, so it is reported.
- **`admission`, measured.** Against a variant that reads the fund with separate lazy calls, the single `admission` read costs 2,247 more on an ordinary movement and 3,474 more on a burn, and saves 2,460 when a new investor joins. It fails the plan's test of saving 1,000 on the common path. It is kept because of the next point: the rule rides in the slot that `admission` reads anyway.
- **Change to F-1: the retired rule fails closed.** An outside review of F-1 made two points, both checked. First, while a class's hook lists a rule the fund has replaced, `canTransfer` says yes but a mint to a new holder reverts, which breaks "pre-flight never lies". Second, and not in my F-1 note, a transfer between two existing holders needs no write to the fund, so under the retired rule it went through. I proved that second point on `19323f3` with a probe test before changing anything. The fix is the review's own: `admission` also returns the installed rule, and `FundHoldersRule.check` returns `NOT_FUND_CLASS` for every movement unless that rule is itself. To make it free, the installed rule, the count and the cap share one slot (`address rule`, `uint48 count`, `uint48 cap`), so the new read costs nothing extra: measured, +254 gas on an ordinary movement, and about 1,700 less on every join and leave, because the count write no longer needs a separate rule-slot read. The cap now reverts above `type(uint48).max`. `IFund`'s interface id does not change (a return type is not in a selector). `NOT_FUND_CLASS`'s NatSpec widened and its value did not. During a replacement the class is now closed to everything, `forcedTransfer` included, until its hook lists the new rule, so the batch is the only safe way to change the rule, as the runbook says.
- **Tests added.** `FundIntegration_Claimable`: a 7540 deposit fulfilled while the fund has room, the fund then filled through two other classes, the claim refused with `ControllerNotEligible(MAX_HOLDERS)`, and `recoverClaimable` delivering it as a counted enforcement mint (count 3 over a cap of 2). Static-call tests for the reads that the first suite left out: the balance reads in `after_`, the sender's `admission` and balance in `check`, and `Fund`'s reads in `registerClass` and `setRule`, each with a control showing the revert comes from the write. Packed-slot tests: no write to the rule, the count or the cap disturbs the other two (also asserted at every step of the model fuzz and in the Halmos properties).
- **Mutation checks.** The Solidity set was run again on the new code, with seven mutants added and the dead-code one removed (46 planted in `Fund` and the rule, all caught). Six wiring mutants in the Ignition modules (fund ownership not handed over, cap never set, a class not registered, the intent hook built without the rule, classes registered in another order, the rule not installed) are all caught by the fixture's checks. Halmos: all seven F-1 mutants caught, and the properties now also assert that the rule and the cap never move.
- **Docs.** `architecture.md` (the fund section, tables, diagrams), `transfer-checks.md` (a `FundHoldersRule` section, the order table, the reason code), `roles.md`, `governance-and-deployment.md` (a section on changing the fund's rule, the deployment steps, the checks), `flows-token.md`, `flows-vaults.md`, `money.md`, `docs/README.md`, the root README (runbook steps 1, 2, 5 and 7, security model, deviations) and SECURITY.md (scope, suppressions). A fresh agent that had not seen my reasoning checked every changed sentence against the code and found three wrong claims, four overclaims and a set of stale sentences on pages the diff had not touched. All are fixed. One it named is older than the fund layer and I left it: the README says three interface files are extra to the brief, and it is more.
- **Results.**
  - `npx hardhat test`: 658 passing (590 Solidity, 68 TypeScript), up from 637. The isolated profile: 590 passing.
  - Lint 0, fmt clean, `tsc` clean, Slither 0, Aderyn 0, upgrades-core 3 of 3, Halmos 5 fund properties in 39 s (and the existing 4 in 7 s).
  - `verify:reproducible`: 15 contracts identical across the two production builds. The 13 existing contracts' deployed bytecode is identical to `d3574df`.
- **Brief.** On the owner's go-ahead, `CLAUDE.md` got two edits: the §3 layout lists `contracts/fund/` and `FundHoldersRule.sol`, and §6 has a `FundHoldersRule` entry. It notes that the rule's state is shared by every class, so it is sound only through the fund's registration gate. The points the review raised about the market, an identity adapter or a TypeScript kit were set aside at the owner's request.

### The review of F-1, claim by claim (2026-10-23)

The pasted review's code and architecture claims, checked against the repo:

| Claim | Verdict |
|---|---|
| Its line references (`Fund.sol`, `FundHoldersRule.sol`, `FundIntegration.t.sol`, PLAN.md line 1438) | Accurate for `19323f3`. It read the real code |
| Pre-flight says yes while a mint to a new holder reverts, after `setRule` alone | True and documented in F-1 |
| A transfer between existing holders still succeeds under the retired rule | True. Proved with a probe on `19323f3`. My F-1 note ("movements revert") overstated it. Fixed in F-2 as above |
| `recoverClaimable` across classes at a full cap has no test | True. Added, and it behaves as the review predicted |
| Every external call in a rule is proven to be a STATICCALL | Overstated: the guard covered `policyHook` and the first `admission` only. Completed in F-2 |
| Packing makes the first investor "a 5,000 write instead of 22,100" | Imprecise: only the count write. The account's own slot is still a fresh 22,100, and a new investor costs about +53,000 in all |
| 125k to 135k gas for a warm transfer, 180k to 200k to onboard | Close for a three-rule hook (128,050 for a transfer, 183,676 for a new investor by transfer, 205,926 for a first mint). More with a longer rule list |
| "72+ planted mutants killed" | Not checkable as stated. The fund layer's own count is 46 Solidity, 7 Halmos and 6 deployment mutants, all caught after F-2 |
| "No cold-start seeding problem by construction" | True for registration. A rule dropped from a registered class's hook still leaves the state stale, and the docs say so |
| Standard interfaces keep the stack composable with DeFi and custodians | Overstated. A gated token reverts for any counterparty that is not verified, so every venue contract must itself be a verified holder |
| Address-based counting, per-holder lockup instead of per-lot | Accurate, and F2 and F1 in this plan |

Not assessed: the scores, the market and buyer claims, the audit-cost figures, and the identity-adapter and relayer-kit suggestions.

### DvP and the fund layer (considered, not built)

What exists. `IntentToken.executeTransfer` moves one token between two accounts on the signature of the sender, and the movement reaches the hook as `EXECUTED`, with the intent's `ref` and `deadline` in the context. `IntentExecutor.executeBatch(token, intents, sigs)` takes one token and is all-or-nothing for the intents in it.

What that means for delivery versus payment. There is no multi-token atomic settlement today. A securities leg and a cash leg are two intents on two tokens, and `executeBatch` cannot hold both because it takes one token. Even two separate calls would not make a DvP, because each signed intent can be executed alone: an operator could execute the securities leg and never the cash leg, and nothing on chain ties them. The `ref` field is free-form and nothing reads it. So the executor is not yet a DvP engine, and the brief's "grows into multi-leg DvP later" is still to do.

What the fund layer does with it. Nothing in `Fund` or `FundHoldersRule` blocks a DvP. The rule treats `EXECUTED` like `TRANSFER`: a new investor is capped, and a whole-balance intent that empties the sender's only class is net zero and passes. This is covered by unit tests and by a TypeScript test that signs a real intent, which `canExecute` and the executor refuse at a full cap and admit for a whole balance. The settlement window rule already applies to `EXECUTED` movements.

The shape of a DvP executor, and a change to the intent that it needs, are in the next section. It replaces the sketch that was here, which bound the legs through `ref` and a convention.

## DvP: an intent revision and a DvP executor (design 2026-10-23, Option B chosen; I-1, E-1 and E-2 built, awaiting review)

On 2026-10-23 the owner asked for a plan for the DvP executor, and whether the intents should change while the code is still a demo. The analysis below led to a change of the intent and a separate executor. The owner chose Option B for D8 (the intent carries the payment leg) and kept D1 to D7 as recommended. I-1 (the intent revision), E-1 (the executor contract) and E-2 (deployment, TypeScript tests, gas, docs) are built and wait for the owner's review ("I-1 as built", "E-1 as built" and "E-2 as built" at the end of this section).

### Goal and limits

A secondary trade of a share class against cash, settled atomically: both legs move or neither does, and the hook runs on each gated leg, so identity, lockup, the settlement window, the class cap and the fund cap all apply. Not goals: custody across transactions, price discovery, matching, fees, partial fills, more than two legs, cross-chain, and any change to the base, the hook, the rules or the two vault templates.

### What the intent could and could not do before I-1 (read from the code)

1. A signature commits `from`, `to`, `amount`, `nonce`, `deadline` and `ref`. Nothing in it says who may execute the intent or on what condition. `executeTransfer` checks only that the caller holds `EXECUTOR_ROLE`.
2. So any account holding that role on the token can execute any valid signed intent. Today those are the `IntentExecutor`'s operators. A DvP executor would be a second holder.
3. `ref` is free-form and nothing reads it. The nonce is random and per signer, so pre-signed trades can be executed in any order. The deadline is inclusive. Signatures are ECDSA or ERC-1271.
4. `canExecute` leaves the signature out, so its pre-flight can say yes to an intent that then fails with `BAD_SIGNATURE`. That is a gap against the brief's "pre-flight never lies".
5. `executeBatch(token, intents, sigs)` takes one token.
6. Only `IntentToken` has intents. The vault templates do not (for the 7540 vault the brief says the request is the intent). The mixin is about 1.9 KB (the base-only harness is 13,174 bytes and `IntentToken` is 15,089), so it would fit in `Gated4626Vault` and, with about 1.1 KB to spare, in `Gated7540Vault`. The design says no for the 7540 vault.
7. ERC-2612 `permit` is on every template, but its nonce is sequential per owner (OpenZeppelin `Nonces`), so a holder's permits must be used in the order they were signed.

### The hard problem: a leg that can be executed alone

The seller's signed securities intent is a complete instruction. Any executor can run it with no cash leg, and `ref` does not help because nothing reads it. Whatever the DvP executor checks, it cannot stop the intent from being run somewhere else. The options:

| Option | How | Cost | Verdict |
|---|---|---|---|
| 0. Convention | The DvP executor is the only `EXECUTOR_ROLE` holder on the token. A reserved prefix of `ref` marks trade intents, and the executor's standalone path refuses it | No change to intents. A governance invariant (nobody else is ever granted the role) and a reserved prefix in a free field that nothing else reads | Works, and is fragile: one later grant to another executor silently removes the guarantee. It also switches off plain intents on that token |
| 1. Executor binding | Add `address executor` to the signed `TransferIntent`. The token requires `executor == address(0)` or `executor == msg.sender` | Breaking change to the struct, the typehash and the selectors of `executeTransfer`, `canExecute`, `IIntentExecutor.execute` and `executeBatch`. About 12 Solidity and 5 TypeScript files, plus docs. `IntentToken`'s implementation is re-attested and `IntentExecutor` is redeployed | The guarantee is on chain, per intent, and the signer chooses it. Other executors can coexist on the same token. **The core of the fix, taken, together with the consideration fields below** |
| 2. Escrow in `to` | The seller's intent pays the DvP executor, which forwards | The executor must be a verified identity and exempt from the caps. Tokens strand if the intent is executed alone, so it needs recovery state | Worse |
| 3. Permit legs | `permit` then `transferFrom` for both legs | The kind is `TRANSFER`, so no window and no `ref` in the context. Sequential nonces. Permits can be front-run. USDT has no permit | A fallback for vault shares only |
| 4. Witness | The token verifies a signature over a caller-defined typed struct, as Permit2 does | A dynamic typehash inside the token: more audit surface. It contains option 1 | More than this needs |

### The intent revision (I-1), Option B

`TransferIntent` becomes (new fields after `ref`, in this order):

```
address from; address to; uint256 amount; bytes32 nonce; uint256 deadline; bytes32 ref;
address executor;            // zero: any EXECUTOR_ROLE holder, as today
uint256 validAfter;          // zero: no lower bound
address considerationToken;  // what the signer is to receive for this leg, informational to the token
uint256 considerationAmount;
```

What the token checks, in the mixin and in the pre-flight that `canExecute` shares with `executeTransfer`:

- **Executor.** `executor != address(0) && executor != msg.sender` gives `WRONG_EXECUTOR`.
- **Window.** The intent is executable when `validAfter <= block.timestamp <= deadline`. Before `validAfter` it gives `INTENT_NOT_YET_VALID`. The deadline check is the existing one.
- **Consistency (the owner's condition for B).** If `considerationToken != address(0)` or `considerationAmount != 0`, then `executor` must be non-zero; otherwise `CONSIDERATION_NEEDS_EXECUTOR`. Without it a signer could put a payment in the message and any executor could run the transfer without it. It is a check on the message's own consistency, not a rule about who, where or when; rule 11 is read that way by the owner's decision.
- **Signature in the pre-flight.** `canExecute(intent, sig)` includes the signature check (`BAD_SIGNATURE`), so the pre-flight covers the whole write path. `isValidSignatureNow` is a static call, so it stays a view. A bound intent is only executable from its executor, so pre-flight must run from that address (an `eth_call` with `from`, or the executor's `canExecuteDvPGated` and `canExecuteDvP3009`); from any other address it returns `WRONG_EXECUTOR`.
- The existing checks keep their order and the new ones follow them; tests pin the order.

The token never reads `considerationToken` or `considerationAmount` beyond the consistency check: they are hashed into the signature and nothing else. Only the executor named in the intent enforces the payment. The NatSpec says so.

Reasons appended to `Errors.sol`: `WRONG_EXECUTOR`, `INTENT_NOT_YET_VALID`, `CONSIDERATION_NEEDS_EXECUTOR`. The nonce model, `cancelIntent`, the domain, ERC-1271 and the `IntentExecuted` event do not change. `ref` stays free for the ISO 20022 reference.

What it touches: `ITransferIntent`, `IntentSettledUpgradeable`, `IIntentExecutor`, `IIntentExecutorBatch`, `IntentExecutor`, `Errors.sol`; the intent tests (`IntentSettledUpgradeable.t.sol`, `IntentExecutor.t.sol`, `IntentToken.t.sol`, `RuleSetIntegration.t.sol`), the Halmos intent properties (`IntentTokenHalmos.t.sol`), the TypeScript signing helper and tests (`fixtures.ts`, `intents.test.ts`, `time.test.ts`, `parity.test.ts`, `fund.test.ts`); `InterfaceFreeze.t.sol` (three ids re-pinned); the docs; and brief §5, which prints the struct and the `canExecute` signature and lists the reasons. Existing signed intents stop verifying. There are none outside the tests. Gas per execution rises by about 1.4k inside the call, measured in I-1 (see "I-1 as built"); the plan's earlier estimate of a few hundred was low. `IntentToken` has 9,487 bytes of room, and `ContractSizes.t.sol` guards the limit.

### Why B and not A (the owner's decision)

Option A was `executor` alone, with the trade terms bound by a hash in `ref`. B was proposed in an outside review, and I checked it against the mixin.

- A leaves the seller signing a `bytes32`. The signature does commit to every term, but only a signer whose tool recomputes the hash from the terms is protected, and a custodian policy engine that sees only the typed message cannot apply a price limit. A also spends `ref`, which the brief reserves for the ISO 20022 reference. B puts the payment leg in the typed message and frees `ref`.
- B makes the executor simpler: no `Trade` struct, no `tradeId`. The executor takes the signed legs and checks that they mirror.
- B does not make the token enforce the payment. The review said the mixin would; it cannot, because it sees only its own token. That is why the consistency check exists.
- The soundness argument, to be pinned by tests: the executor requires the securities intent's consideration to equal the cash leg, so it is non-zero; the consistency check then forces a non-zero `executor`; the executor check then forces that executor to be the one calling. A DvP leg therefore cannot be run by any other executor, and none can carry a payment its signer did not see.
- B does not help the buyer on an ERC-3009 cash leg. The authorization has no consideration fields, so the buyer's wallet shows a value, the executor as payee, and a nonce (a hash of the security token's address and the seller's `intentHash`, see E-1). With a gated cash token the buyer's own intent carries the mirror fields.
- The cost of B: the frozen struct has 10 fields and fixes the shape of a trade as one consideration leg. A fee leg, a basket or a three-party trade needs another struct change, where under A it would have been a new executor. The token also carries two fields it does not enforce, which a reader may assume it does. The consideration does not reach the hook (`TransferContext` is frozen; only `extra` can grow), so no rule can check a price. Nothing here needs that today.

### The DvP executor (E-1, E-2)

`DvPExecutor`, immutable, with the roles of `IntentExecutor`: the timelock as admin, `OPERATOR_ROLE`, the guardian's pause, the recovery timelock's unpause. It holds `EXECUTOR_ROLE` on the tokens it settles, and nothing else. It is not attested, like `IntentExecutor`, and goes into SECURITY.md scope. It has no sweep: a token sent to it by mistake stays there.

Two entry points, both `OPERATOR_ROLE`, `whenNotPaused`, `nonReentrant`, and neither runs one leg alone:

- **`executeDvPGated(securityToken, cashToken, securitiesIntent, securitiesSig, cashIntent, cashSig)`.** The cash token is an `IntentToken` too. The executor checks that the legs mirror, then calls `cashToken.executeTransfer(cashIntent, cashSig)` and `securityToken.executeTransfer(securitiesIntent, securitiesSig)`. Cash goes buyer to seller and shares seller to buyer directly; the executor holds nothing. Mirror: `securitiesIntent.from == cashIntent.to` and `securitiesIntent.to == cashIntent.from`; `securitiesIntent.amount == cashIntent.considerationAmount` and `cashIntent.amount == securitiesIntent.considerationAmount`; `securitiesIntent.considerationToken == cashToken` and `cashIntent.considerationToken == securityToken`; the two tokens differ. The executor does not compare the `executor` fields: the tokens do, and the consistency check makes them non-zero (see above). The two deadlines and `validAfter` values need not match; each token checks its own, so the trade runs in the overlap.
- **`executeDvP3009(securityToken, cashToken, securitiesIntent, securitiesSig, authorization)`.** The cash token is a USDC-style ERC-3009 token. The executor checks that `authorization.from == securitiesIntent.to`, that its value is `securitiesIntent.considerationAmount`, that `securitiesIntent.considerationToken == cashToken`, and that `authorization.nonce == keccak256(abi.encode(securityToken, securityToken.intentHash(securitiesIntent)))`. That nonce ties the buyer's authorization to exactly this securities intent on exactly this token; the intent carries every term and names the executor. The token's address is in the nonce because the executor cannot tell an honest token's hash from a counterfeit's: with the bare hash, an operator could pair the buyer's authorization with a substituted token that reports that hash and delivers nothing, and pay the cash to itself (found while building E-1; `test_WhenAnOperatorSubstitutesACounterfeitSecurityToken_TheAuthorizationIsRefused`). The gated form has no such gap, because the buyer's signed intent names the security token in `considerationToken`. Then it calls `receiveWithAuthorization` with the buyer's own times and signature (only the payee can call it, so nobody can front-run it with `transferWithAuthorization`, which has a different typehash), then `securityToken.executeTransfer`, then pays the cash on to the seller, and requires that its own cash balance is what it was before the call and that the seller's balance rose by exactly the value, which refuses fee-on-transfer tokens whether the fee falls on the pull or on the payout. The executor does not map or touch the authorization's times. At the exact second of the deadline the intent (inclusive) and the authorization (strict, in Circle's code) can disagree; the trade then reverts as a whole, and tests pin it.
- **Cancel.** Either party cancels by spending the nonce on their own token (`cancelIntent`), or for the authorization by `cancelAuthorization`. The trade then fails atomically. No new function.
- **Pre-flight.** `canExecuteDvPGated` and `canExecuteDvP3009` return `(ok, reason)`. They check, in order, the executor's own pause (`PAUSED`), the match (`LEGS_DO_NOT_MATCH`, a reason appended to `Errors.sol`), and then each leg from the executor's address, cash first, with the token's reason. For the external stablecoin the cash leg is the authorization's window with Circle's strict edges (`INTENT_NOT_YET_VALID`, `INTENT_EXPIRED`), its state (`NONCE_USED`) and the buyer's balance (`INSUFFICIENT_UNFROZEN`). It cannot check the buyer's signature, which the cash token exposes no view for, nor a pause or blocklist on the cash token, so the 3009 pre-flight can say yes to a trade that then fails. Two legs on tokens that share policy state, such as two classes of one fund, each get the current state, and the first leg's movement can change the second's answer. A leg that fails reverts with `DvPExecutor_LegFailed(leg, reason)` carrying the token's revert data.
- **Event.** `DvPSettled(securitiesIntentHash, seller, buyer, securityToken, cashToken, securityAmount, cashAmount, operator)`. The tokens emit their own `IntentExecuted` as well.
- **Fund layer.** The securities leg is `EXECUTED`. The fund cap, the net-zero rule for a whole-balance sale, the window, the lockup and identity all apply to it with no change. The executor never holds a class token, so it needs no identity entry and no cap exemption.
- **Deployment (E-2, not built).** `Components` deploys it. `Activate` grants it `EXECUTOR_ROLE` on `intent` (the only deployed token with intents) and on any gated cash token, which must itself be an `IntentToken`; none is deployed today, so a gated cash leg needs one added to `Tokens`. It also grants `OPERATOR_ROLE` and hands over its admin like the executor's. `assertHandedOver` (in `fixtures.ts`) pins its roles and the set of `EXECUTOR_ROLE` holders on each of those tokens.

### Tests first

- **Token (I-1), each red before green:** `WRONG_EXECUTOR` (zero executor passes, the named one passes, any other fails); `INTENT_NOT_YET_VALID` and the deadline, both inclusive; `CONSIDERATION_NEEDS_EXECUTOR` for amount only, token only and both, and a zero consideration with a zero executor passing; `intentHash` changes with each new field (fuzzed); `canExecute` and `executeTransfer` agree on every reason, `BAD_SIGNATURE` included; an intent with the four new fields at zero behaves as today.
- **The leg alone:** a securities intent signed for the DvP executor and run through `IntentExecutor` reverts `WRONG_EXECUTOR`; the same with a consideration and a zero executor reverts `CONSIDERATION_NEEDS_EXECUTOR`; the DvP executor has no entry point for one leg. Mutation check in a scratch copy: delete the consistency check and the first test must fail.
- **Executor unit:** each mirror field, wrong in turn, reverts; changing any field of either intent makes its signature fail; atomicity in both directions (cash leg fails and shares stay, share leg fails and cash stays); the executor holds nothing after any call; a cash token whose transfer re-enters; a fee-on-transfer cash token; a 3009 mock that requires the caller to be the payee; an authorization whose nonce is not the securities intent's hash; an authorization reused for a second intent; the deadline edge for the 3009 leg; a pair that cannot settle twice.
- **Integration:** a class token and a gated cash token with real hooks and the fund rule, and a 3009 mock; pre-flight parity; the settlement window; a lockup; a whole-balance sale to a new investor at a full fund cap (passes) and a partial sale (refused).
- **Properties:** a fuzz test that after an ERC-3009 trade the executor's cash balance is exactly what was donated to it and the seller received the value (a stateful invariant would add nothing: beyond its roles and pause flag the executor keeps no state). Two Halmos properties on stub tokens with real balances: if the gated entry point returns, both legs ran once and the intents mirror; if the 3009 entry point returns, the executor kept its cash, the seller received exactly the value, and the nonce was the one that ties the intent.
- **TypeScript:** real signing of the intents (all ten fields in the typed data) and of the 3009 authorization with viem, through the deployment, with a class created and traded.
- **Mutation checks** on the executor and on the new intent checks, in a scratch copy.

### Checkpoints and gates

- **I-1:** the intent revision, complete with tests, Halmos, TypeScript and docs. Stop for review.
- **E-1:** `IDvPExecutor`, `DvPExecutor`, its Solidity tests, the freeze and size entries. Stop for review.
- **E-2:** Ignition, the TypeScript tests, the benchmark of a DvP, the docs. Stop for review.
- **Gates at each:** both runners with the summary line, lint, fmt, `tsc`, Slither, Aderyn, upgrades-core, Halmos, the isolated profile, reproducibility. After I-1 the bytecode of `IntentToken` and `IntentExecutor` changes on purpose and nothing else existing does, which the comparison with the pristine build will show.

### Risks

- ERC-3009 is a Draft. USDC's current source (Circle's FiatToken v2.2) has the bytes-signature overload, so contract wallets work, and it takes `receiveWithAuthorization` only from the payee. It also reverts while the token is paused and for a blocklisted party (the executor too), which would fail the whole trade. I read Circle's repository, not each chain's deployed version, and I did not check EURC.
- An operator that never executes cannot take anything. A trade it ignores expires at its deadline, and either party can cancel.
- The change to the intent is breaking, and the cost of that is lowest now.
- The cash leg of kind ERC-3009 leaves the pause and blocklist of an external token outside the hook, so it is a dependency we do not control.
- The signed consideration is a one-leg shape, frozen with the interface. A second consideration leg is a new struct change.

### Not in this plan

Matching and order books, fees, partial fills, more than two legs, cross-chain settlement, a Permit2 cash leg, class switches, DvP for the two vault templates, and any rule that reads the consideration.

### Decisions (2026-10-23)

| # | Question | Decision |
|---|---|---|
| D1 | Revise `TransferIntent` now and add `executor`? | Yes |
| D2 | Add `validAfter` in the same revision? | Yes |
| D3 | Make `canExecute` take the signature? | Yes |
| D4 | Which cash tokens in the first version? | A gated cash token and ERC-3009. Permit2 later, if USDT or an arbitrary ERC-20 is needed |
| D5 | Who may call the executor? | `OPERATOR_ROLE` only. The signed legs bind every term, so opening it later is a new deployment of an immutable contract, not a rewrite |
| D6 | `DvPExecutor` beside `IntentExecutor` or replacing it? | Beside. They can share a token safely. Revised 2026-10-23 on the owner's instruction: `IntentExecutor` now refuses any intent that states a consideration (`IntentExecutor_ConsiderationNotSupported`), because it cannot enforce a payment; otherwise it and its tests stay as they were |
| D7 | The two vault templates? | Out of the first version. Their secondary trades stay plain transfers until the owner says otherwise |
| D8 | Consideration fields in the intent? | Option B, with the check that a non-zero consideration needs a non-zero executor |

D8 was chosen by the owner in so many words, and D1 to D7 were kept as recommended; I read that as adopting my recommendations. If any of them was meant to stay open, say which.

My defaults, which the owner can overrule: the new fields go after `ref` in the order `executor`, `validAfter`, `considerationToken`, `considerationAmount`; two entry points (gated and 3009) in place of one with a kind flag; cash comes in first; the executor's errors are named `DvPExecutor_<Name>`; the reason names are `WRONG_EXECUTOR`, `INTENT_NOT_YET_VALID` and `CONSIDERATION_NEEDS_EXECUTOR`; the event is `DvPSettled`.

### I-1 as built (2026-10-23, awaiting review)

What changed:

- `ITransferIntent`: `TransferIntent` has the four new fields after `ref`, in the order `executor`, `validAfter`, `considerationToken`, `considerationAmount`; `canExecute(intent, sig)` takes the signature. `Errors.sol` has `WRONG_EXECUTOR`, `INTENT_NOT_YET_VALID` and `CONSIDERATION_NEEDS_EXECUTOR`, each the keccak256 of its name.
- `IntentSettledUpgradeable`: `_intentPreflight` checks, in this order, the deadline, the nonce, the consideration (either field non-zero needs an executor), the executor (non-zero must be the caller) and `validAfter` (inclusive). `canExecute` and `executeTransfer` then check the signature, then the hook, in the same order. `intentHash` encodes the typehash and the struct in one `abi.encode`; a struct of static fields encodes in place, and the tests build the hash field by field to prove the order. The typehash string has all ten fields.
- `IntentExecutor`: only a NatSpec sentence changed. Its bytecode changes because the struct type is part of its function selectors.
- Not touched: the base, the hook, the rules, the vaults, the fund layer, `IIntentExecutor` and `IIntentExecutorBatch` (their ids change because they carry the struct type), the nonce model, `cancelIntent`, the domain, the `IntentExecuted` event.

Rule 11 (no `if` about who or when in a template) is read as the owner decided: these are checks on the signed message's own fields, in the same class as the deadline and the nonce, which were already in the mixin. The brief's §5 now says so.

Tests, written first. With the interface changed and the mixin compiling but behaving as before (a stub), the four intent test files ran **84 passing, 25 failing**: the hash and typehash tests, every executor, `validAfter`, consideration and check-order test, the `canExecute` signature tests, the parity fuzz test, and the two regression tests below. After the mixin change all 109 passed, and the full Solidity run failed only `InterfaceFreeze` on the three changed ids. The ids were computed with `cast sig`; the same method reproduces the three old pinned values.

- `IntentSettledUpgradeable.t.sol`: the typehash pinned as a string; the hash fuzzed over all ten fields and a test that changing each new field changes it; executor binding (zero, the caller, another role holder, any other address, the role check first); `validAfter` (inclusive, the second before, an empty window); the three consideration cases and a fuzz; the check order (six tests); `canExecute` (bad signature, altered intent, ERC-1271 wallet, wrong executor, not yet valid, consideration without executor); and a fuzz that `canExecute` returns exactly what `executeTransfer` reverts with, over the executor, window, consideration, signature, nonce, hook and caller.
- The regression for the whole design, `IntentExecutor.t.sol` on the real token: an intent that names another executor and states a payment is refused by `IntentExecutor.execute` and by `executeBatch` with `WRONG_EXECUTOR`, nothing moves, and the same signed intent runs from the executor it names. An intent that states a payment and names no executor is refused by every executor. An intent that names `IntentExecutor` settled the transfer alone whatever it stated; that behaviour was reversed on 2026-10-23 (see "Validation of an outside review"): `IntentExecutor` now refuses an intent that states a consideration, and the token's `WRONG_EXECUTOR` and `CONSIDERATION_NEEDS_EXECUTOR` checks remain the guard for any other executor that holds the role. The same test now expects `IntentExecutor_ConsiderationNotSupported`, and a zero-consideration intent naming another executor still reaches the token and gets `WRONG_EXECUTOR`.
- `IntentToken.t.sol`: a bad signature, with `canExecute` and `executeTransfer` agreeing on the real stack.
- TypeScript: the signing helper has all ten fields; four new tests (all ten fields hash alike in viem and on chain and settle through the real executor; a named other executor is refused and pre-flight says so from each address; a consideration without an executor is refused; `validAfter` is inclusive at its second) and the chain-domain test now expects `canExecute` to say `BAD_SIGNATURE`.
- Halmos: `check_intentNamingAnotherExecutorNeverExecutes` and `check_considerationWithoutExecutorNeverExecutes`, on the proxied token with a symbolic signature.

Mutation checks, in place and restored, on the mixin: the consideration check dropped; applied to the amount only; applied to the token only; the executor comparison dropped; the `validAfter` check dropped; made exclusive; the signature dropped from `canExecute`; the executor check moved before the nonce check; a field left out of the hash. Each is caught by 1 to 7 tests. The order mutant survived at first, so `test_WhenTheNonceIsUsedAndTheExecutorIsWrong_NonceUsedWins` was added. Dropping the consideration check or the executor comparison also fails exactly the matching Halmos property and no other.

Gas, measured with the real token, a mocked hook and a probe in a scratch copy: `executeTransfer` costs 121,767 gas before and 123,201 after, +1,434 (+1.2%), inside the call. The four extra calldata words add about 500 gas more in a transaction when they are zero. `canExecute` also checks the signature now, which costs more by design.

Gates, on the final tree:

- `npx hardhat test`: **695 passing (623 Solidity, 72 TypeScript)**; the isolated profile: 623 Solidity.
- `forge fmt --check` and `solhint --max-warnings 0`: clean. `tsc --noEmit`: clean.
- Halmos: **11 properties pass** (5 fund, 6 intent token) in about 2.5 minutes. Aderyn: 0 findings. upgrades-core: 3 upgradeable contracts, 3 passed.
- `verify:reproducible`: 15 contracts identical across two production builds, the default profile and forge; `TokenProxy` matches `ProxyDeployer`.
- Bytecode against `82c3c92`, built from a clean worktree: exactly `IntentToken` and `IntentExecutor` differ, and the other 35 contracts are byte-identical. That is the change the plan expected.
- Slither: **0 results** (311 contracts, 97 detectors), run on the final tree after the last source edit, which was NatSpec and test files only.

A fresh agent checked the documentation diff against the code. It found one wrong statement (the token "signs" and "never reads" the consideration), four overclaims and several stale sentences; all are fixed. One sentence it flagged as unpinned, that `IntentExecutor` treats a consideration as a record, now has a test.

What was not done in I-1, and E-1 and E-2 then did: the executor contract (`IDvPExecutor`, `DvPExecutor`), the Ignition and TypeScript work, and the DvP docs and the brief's executor line.

### E-1 as built (2026-10-23, awaiting review)

What was built:

- `IDvPExecutor` and `DvPExecutor` (6,710 bytes of runtime code, 17,866 under the limit): `executeDvPGated`, `executeDvP3009`, their pre-flights `canExecuteDvPGated` and `canExecuteDvP3009`, `pause` and `unpause`, with the roles, the guardian pause and the recovery timelock of `IntentExecutor`. Each entry point is `nonReentrant`, `OPERATOR_ROLE` and `whenNotPaused`. There is no entry point that runs one leg.
- `IERC3009`, the two functions of ERC-3009 the executor calls. `Errors.sol` has one more reason, `LEGS_DO_NOT_MATCH`.
- Test mocks: `MockERC3009Token` (USDC-shaped, with Circle's checks and an optional transfer fee), `MockReentrantCashToken`, `MockReentrantGatedToken`, `MockFakeSecurityToken`.
- Pins: `InterfaceFreeze.t.sol` has the ids of `IDvPExecutor` and `IERC3009` (computed with `cast sig`), the `DvPSettled` topic and the new reason; `ContractSizes.t.sol` has `DvPExecutor`.
- Not touched: the base, the hook, the rules, the vaults, the fund layer, `IntentExecutor`, Ignition, the brief.

Where the build differs from the plan above, and why:

- **The authorization's nonce includes the security token's address:** `keccak256(abi.encode(securityToken, securityToken.intentHash(securitiesIntent)))`, not the bare hash. With the bare hash an operator could pair the buyer's authorization with a substituted security token that reports the genuine hash and delivers nothing, and pay the buyer's cash to an account of its own. The executor cannot tell an honest token's hash from a counterfeit's. The gated form is not exposed, because the buyer's signed intent names the security token. This changes what the buyer signs, so E-2's TypeScript helper must compute this nonce. `test_WhenAnOperatorSubstitutesACounterfeitSecurityToken_TheAuthorizationIsRefused` is the regression; it builds the authorization the naive design would have produced.
- **A failing leg reverts with `DvPExecutor_LegFailed(leg, reason)`** carrying the token's revert data, as `IntentExecutor.executeBatch` does for its items, instead of bubbling the token's error unchanged. With two tokens the operator needs to know which leg refused. The legs are the two gated legs, or the pull of the cash and the securities leg; the 3009 payout to the seller is not wrapped, and a failure there (a blocklisted seller, a re-entering token) reverts with the cash token's own error.
- **The seller's cash balance is checked as well as the executor's.** A fee on the payout leaves the executor whole and the seller short; only the seller check sees it.
- **The pre-flight returns the executor's own pause as `PAUSED` and a mismatch as `LEGS_DO_NOT_MATCH`.** The 3009 pre-flight cannot check the buyer's signature or a pause or blocklist on the cash token, and says so in its NatSpec.
- **The executor-balance property is a fuzz test, not a stateful invariant**, because beyond its roles and its pause flag the executor keeps no state between calls.
- Modifier order is `nonReentrant onlyRole whenNotPaused`, because Aderyn flags the guard when it is not first.

Tests, written first. With the interfaces, the mocks and a stub executor whose settlement functions reverted and whose pre-flights answered no, `DvPExecutor.t.sol` ran **13 passing, 54 failing** (the 13 are nine constructor, role and ERC-165 tests, and four tests that passed for nothing: two with a bare `vm.expectRevert()`, and two reentrancy tests whose low-level call `vm.expectRevert` does not check; all four were later made exact). After the implementation all 67 passed. A test for the gated-path reentrancy guard, and the fixes that a mutation run and a review forced, made it 72. They are:

- Unit, with every external call mocked and the ones that matter to a test expected (or expected not to happen): the constructor and roles (the recovery rules of M-1); the gated entry point (role, pause, both legs and the event, each mirrored field wrong in turn, equal tokens, a failing cash leg that never runs the securities leg, a failing securities leg, both failing and the cash leg reported first, a security token or a cash token without code); the 3009 entry point (role, pause, the happy path and the event, each authorization field wrong in turn, equal tokens, the executor ending with more or less cash, the seller receiving anything but the value, a failing pull that never runs the securities leg, a failing delivery that never pays the seller, a security token without code); and both pre-flights (each reason, Circle's strict edges at 10, 11, 1999 and 2000, the cash leg reported before the securities leg in the gated one and the authorization before the securities leg in the 3009 one).
- Integration on the real stack (`RuleSetIntegrationTest` as the base, so identity, lockup, settlement window and the holder cap are real), with a real gated cash token: a trade settles and the executor keeps nothing; a locked seller undoes the cash leg; a buyer without cash moves no shares; both failing reports the cash leg; a Saturday trade waits for Monday; at a full holder cap a partial sale to a new holder is refused and a whole-balance sale is admitted; a seller's or buyer's cancel fails the trade atomically; a mismatched pair; an intent naming another executor, or stating a payment with none; a paused executor; a second attempt; a token that revoked the executor. Every case that is a policy refusal compares pre-flight with the real call. The revoked executor is the known gap: pre-flight says yes, because the tokens' own `canExecute` does not check the caller's role either, and the test pins that.
- Integration with the ERC-3009 mock: the happy path, a locked seller, an authorization that belongs to another intent, one that pays less than the stated consideration, the counterfeit token, a used authorization, an authorization that ends on the intent's deadline (the intent's last second is lost, because the intent's deadline is inclusive and `validBefore` is exclusive) and one that ends a second later (it settles on the deadline), a fee-on-transfer token with its exact error, a stray balance hiding a fee, and the fuzz test that the executor's balance is exactly what was donated to it.
- Integration on the fund layer (`FundIntegrationTest` as the base): at a full fund of three investors, a partial sale to a new investor is refused with `MAX_HOLDERS` at the securities leg, a whole-balance sale to a new investor is admitted and the count stays at three, and a partial sale to an existing investor is admitted.
- Reentrancy: a cash token that calls back as an operator during the pull, and during the payout, and a gated token that calls back, are each stopped by the guard. (The first version of these tests passed with the guard removed, because `vm.expectRevert` does not compare the data of a low-level call; they now compare the returned data.)
- Halmos on stub tokens with real balances: if the gated entry point returns, both legs ran once and the intents mirror; if the 3009 entry point returns, the securities leg ran once, the cash was pulled once, the executor kept its cash, the seller received exactly the value, and the nonce was the one that ties the intent.

Mutation checks, in place and restored, 26 in all: the pause, role and reentrancy modifiers dropped (gated and 3009); each of the seven mirror conditions dropped; the two legs swapped; each of the five authorization conditions dropped, and the bare-hash nonce; the executor and the seller conservation checks dropped; the securities leg never run; the seller never paid; the pre-flight legs swapped, both window edges moved, the pause ignored. Each is caught by 1 to 18 tests. Two weaknesses in my own tests showed up and were fixed: the 3009 reentrancy mutant survived (the assertion above), and the gated guard had no test. Halmos catches the dropped mirror conditions, the dropped securities leg, the dropped nonce, payer, value and token conditions, and the dropped executor conservation check, each with the property that targets it.

Gates, on the final tree:

- `npx hardhat test`: **767 passing (695 Solidity, 72 TypeScript)**; the isolated profile: 695 Solidity.
- `forge fmt --check`, `solhint --max-warnings 0` and `tsc --noEmit`: clean. Aderyn: 0 findings (five inline suppressions with reasons, three of them as in `IntentExecutor`). upgrades-core: 3 of 3.
- Halmos: **13 properties pass** (2 executor, 5 fund, 6 intent token). This, upgrades-core, `verify:reproducible` and the bytecode comparison ran before the last edits, which touched only NatSpec, inline suppressions and tests.
- Bytecode against `82c3c92`, from a clean worktree: `IntentToken` and `IntentExecutor` differ (I-1), `DvPExecutor` is new, and the other 35 contracts are byte-identical.
- `verify:reproducible`, with `DvPExecutor` added to its list for this run only (E-2 adds it for good): **16 contracts identical** across two production builds, the default profile and forge, with `DvPExecutor` among them.
- Slither: **0 results** (337 contracts, 97 detectors) on the final tree. The first run found three `unused-return` findings, the ignored `ok` of the tokens' `canExecute`, which the reason already carries; they are suppressed inline with that reason.

A fresh agent checked the E-1 record, the NatSpec and the tests against the code, and looked for a way an operator, a counterfeit token or a party could redirect value. It found none: each party's signature covers the parts of the trade that decide where its own value goes, and the operator's choices (the token addresses, which signed legs to pair, the signature bytes and the timing) are pinned by the mirror and by the nonce. It found one wrong statement of mine in the tests (a no-code test that failed on the mirror check instead), a dozen overclaims in the record and NatSpec, and one gap, all fixed or documented below.

Known limits, as documented in the NatSpec:

- Pre-flight checks neither `OPERATOR_ROLE` nor that the executor holds `EXECUTOR_ROLE` on the tokens, because the tokens' own `canExecute` does not check the caller's role. After a token revokes the executor, pre-flight still says yes and the real call fails; the post-deploy check that pins the role set (E-2) is what guards that.
- The 3009 pre-flight cannot see the buyer's signature, nor a pause or blocklist on the cash token.
- A 3009 trade whose seller is the executor itself reverts with `DvPExecutor_CashNotConserved` (the executor cannot sign an intent, so this is unreachable with a valid signature). A seller who is also the buyer reverted too, with pre-flight saying yes; that was a bug in E-1, fixed in E-2 ("Validation of an outside review").
- There is no on-chain allowlist of tokens. A party who signs a trade that names a counterfeit token loses to it.
- In the 3009 form the buyer's signature covers the securities intent only through an opaque nonce, so a wallet cannot show what the buyer receives. In the gated form the cash intent states it in clear.
- Two legs on tokens that share policy state, such as two classes of one fund, each get the current state in pre-flight.

What was not done in E-1, and E-2 then did: the Ignition module and the post-deploy checks for the executor, the TypeScript tests and signing helper including the new nonce, the gas of a DvP, the docs and SECURITY.md entries, the brief's lines, and `DvPExecutor` in `verify-reproducible.ts`.

### E-2 as built (2026-10-23, awaiting review)

What changed:

- `Components` deploys `DvPExecutor(deployer, guardian)`. `Activate` grants it `EXECUTOR_ROLE` on the intent token (the intent token's executors are now exactly `IntentExecutor` and `DvPExecutor`), `OPERATOR_ROLE` to the same `operator` account as the intent executor, and `RECOVERY_ROLE` to the recovery timelock, then hands its admin to the main timelock like the other contracts. Neither executor is attested.
- A gated cash token is not deployed by `Activate`. It is a separate instrument; its administrator grants the DvP executor `EXECUTOR_ROLE` (a governance operation if the timelock administers it). The ERC-3009 token is external (USDC).
- The post-deploy check (`assertHandedOver`, now exported) adds the DvP executor to the deployer-holds-nothing, timelock-is-admin and recovery-role-set pins, pins its operator and guardian, and pins `EXECUTOR_ROLE` on the intent token: the two executors hold it, and no account the stack knows about does.
- TypeScript: `signIntent` takes the token whose domain is signed; `dvpNonce`, `signGatedTrade`, `sign3009Trade` and `deployGatedCashToken` in `fixtures.ts`; `dvp.test.ts` (seven flows and the gas test); deployment and governance tests extended.
- Docs: a new page, [flows-dvp.md](docs/flows-dvp.md), and edits to the architecture, roles, governance-and-deployment, money, transfer-checks and flows-token pages, the docs index, the README (components, roles, runbook, post-deploy checks) and SECURITY.md (scope, trust and limits, mutation rows). The brief's §1, §3 and §5 and `verify-reproducible.ts` (16 contracts) carry the new contract.

Tests, written first. With the helpers and the new tests in place and no deployment wiring, the TypeScript suite ran **69 passing, 14 failing**: the 11 new DvP, deployment and governance tests, and three existing governance tests that now name the DvP executor. After the wiring all 83 passed. They are:

- `dvp.test.ts`, through the production deployment: a gated trade settles and the events name the executor; an ERC-3009 trade settles with the helper-computed nonce; the bare-hash nonce is refused; the settlement window refuses a Saturday trade and admits it on Monday; at a full holder cap a partial sale to a new investor is refused and a whole-balance sale is admitted; the intent executor cannot settle a DvP-bound intent, and an intent that states a payment and names no executor is refused; only the operator submits, and a paused executor refuses and pre-flight says `PAUSED`.
- Deployment: the DvP executor's roles, its ERC-165 id and nothing paused; an `Activate` pointed at the wrong contract leaves the real executor with the deployer and the hand-over check refuses it.
- Governance: the guardian pause, the recovery batch (unpause and guardian removal) and the forbidden-calls list now include the DvP executor; and an `EXECUTOR_ROLE` granted on the intent token to the operator key, through the timelock, fails the post-deploy check.

Mutation checks on the wiring, in place and restored: the DvP executor never granted `EXECUTOR_ROLE`, its operator role or its recovery role; never handed over; the operator key also granted `EXECUTOR_ROLE`; the DvP operator role given to the minter. Each makes `Activate` fail the post-deploy check (the deployment, DvP and governance tests fail). Dropping the check for stray `EXECUTOR_ROLE` holders is caught by the governance test that grants one. A first run of this script was wrong: it left the previous mutant's file in place for the next one, so its results were discarded and it was redone with both files restored before each mutant.

Gas, measured on the local chain with the real policy on the security token and identity on the gated cash token (`npx hardhat test nodejs test/nodejs/dvp.test.ts` prints it): a gated trade **382,001**; an ERC-3009 trade **296,445** (with a mock cash token, which is cheaper than USDC behind its proxy and blocklist); for scale, one securities intent through `IntentExecutor` 205,829 and one plain cash transfer 68,663. The test asserts only loose ceilings.

Gates, on the final tree:

- `npx hardhat test`: **781 passing (698 Solidity, 83 TypeScript)**; the isolated profile: 698 Solidity.
- `forge fmt --check`, `solhint --max-warnings 0` and `tsc --noEmit`: clean. Aderyn: 0 findings. upgrades-core: 3 of 3.
- Halmos: **13 properties pass**.
- `verify:reproducible`: **16 contracts identical** across two production builds, the default profile and forge, with `DvPExecutor` in the list permanently.
- Bytecode against `82c3c92`: `IntentToken` and `IntentExecutor` differ (I-1), `DvPExecutor` is new (6,710 bytes), the other 35 are identical.
- Slither: **0 results** (338 contracts, 97 detectors). It ran before the last edits, which touched NatSpec and documentation only.
- A fresh agent checked the E-2 documentation against the code. It found one wrong statement (SECURITY.md said no deployed executor enforces a payment, which was true before `DvPExecutor`), four overclaims (the fee-on-transfer error, `cancelAuthorization` which no test covers and which the buyer does not call directly, the whole-balance sale at the fund-wide cap which holds only if the sale empties the seller's only class, and gas figures that vary by a few hundred between runs), and seven stale sentences that still said "the executor" or listed suppressions and mutants without the DvP executor. All are fixed. The same pass found that the DvP executor's `revokeRole`, `unpause` and `pause` overrides had no recorded mutants; four were run (recovery cannot revoke the guardian, recovery can revoke any role, recovery cannot unpause, anyone can pause) and each is caught by one test in `DvPExecutorUnit_Roles`.

#### Validation of an outside review

The owner pasted a review of E-1 and asked whether it is true. Each finding was reproduced with a test before anything was changed.

1. **Self-trade in `executeDvP3009`: true, a bug in my code, fixed.** If the seller, the buyer and the authorization's payer are one account, pre-flight returned yes and execution reverted with `DvPExecutor_CashNotConserved(seller, before + price, before)`: the executor read the seller's balance before the pull took the price from the same account, so the payout could not raise it by the price. The test reproduced the exact revert. The fix is Option 2 of the review: the seller's balance is read after the pull and the delivery, immediately before the payout, so the check measures the payout alone. Option 1 (forbid self-trades) would make the executor decide who may trade with whom, which belongs to a rule, not to the executor, and the gated form already settles a self-trade (the review is right about that, and a test now pins it). The Halmos property no longer excludes the self-trade case; it asserts a net change of zero for a seller who is also the payer. The mutant that reads the balance before the pull is killed by the new Solidity test; Halmos cannot kill it, because its property is about what holds when a call returns, and the mutant only makes a legitimate call revert.
2. **`IntentExecutor` settled an intent that stated a consideration, free of payment: true, and a design property. Changed on the owner's instruction, 2026-10-23 (see "The `IntentExecutor` refusal" below).** The test that pinned it was mine, and SECURITY.md said so. The risk the review describes is real: a signer who reads the consideration fields and does not check which contract the `executor` field names is protected only if it names `DvPExecutor`. The attacker needs the `IntentExecutor` operator to submit the intent, and the operator could move the shares of a plain intent in the same way, so the consideration fields added no new theft; they added a false sense of safety. The owner chose the review's recommendation, which reverses decision D6's "`IntentExecutor` and its tests stay as they are", and removes the use of the consideration fields as a record on a free-of-payment intent (`ref` remains for the reference).
3. **Pre-flight on a multi-class fund swap: true, and already documented.** `test_WhenTheFundIsAboveItsLoweredCap_ASwapOfTwoClassesPassesPreflightAndFailsOnTheSecondLeg` reproduces it with two intent-capable classes of one fund and a cap lowered below the investor count: pre-flight says yes, and the second leg fails with `MAX_HOLDERS` because the first leg took the buyer out of the fund. The review's names for the fund's internals (`isInvestor`, `classCount`) are not in the code (`heldClasses`, `positionsOf`), but the mechanism is as described. It is in the NatSpec, in flows-dvp.md and in SECURITY.md.
4. The review's praise of the tests is accurate as far as I checked: the parity fuzz, the deadline and `validBefore` edge tests and the reentrancy tests with `OPERATOR_ROLE` granted to the attacker exist as described.

What is not done: the brief's §8 phase list does not mention the DvP phases. The work is committed on `fund-layer` (I-1 `0b1b765`, E-1 `128933c`, E-2 `589790a`, the `IntentExecutor` refusal `24b7798`) and not pushed.

#### The `IntentExecutor` refusal (2026-10-23, on the owner's instruction)

`IntentExecutor.execute` and `executeBatch` now revert with `IntentExecutor_ConsiderationNotSupported(index)` (declared in `IIntentExecutorBatch`; the index is the position in the batch, and zero for `execute`) when an intent's `considerationToken` or `considerationAmount` is non-zero, before the token is called. The check is the executor's, not the token's, so the token's `canExecute` does not see it. Decision D6 is revised: `IntentExecutor` stays beside `DvPExecutor`, but it is no longer unchanged. Its bytecode already differed from the last commit because of the intent revision (3,599 bytes now).

Tests, written first. With the error declared and nothing throwing it: **31 passing, 8 failing** in `IntentExecutor.t.sol`, the eight being the refusal tests (token only, amount only, both, a fuzz over any consideration, a batch that names the position of the intent that states one, and three on the real token: naming the intent executor, naming the DvP executor, naming no executor). After the change all 39 pass. The unit helper `_intent` now has a zero consideration and still names an executor and a `validAfter`, so forwarding of those fields stays pinned; a test shows an intent with no consideration is still forwarded with every other field. The role and pause checks still come first. Seven mutants, each caught by 2 to 7 tests: `execute` never refuses; the check ignores the amount, or the token, or needs both; `executeBatch` never refuses, or names the wrong position; `execute` refuses only after calling the token.

Tests that relied on the old behaviour were rewritten, not loosened. In Solidity, an intent naming the intent executor and stating a payment is now refused and nothing moves (it was settled alone before); a zero-consideration intent naming another executor still reaches the token and gets `WRONG_EXECUTOR`; a stated payment naming the DvP executor is refused by the intent executor, refused by the token if another role holder submits it directly, and runs from the DvP executor. In TypeScript, `intents.test.ts` and `dvp.test.ts` expect the new error through the real stack, and a new test shows a batch naming the position.

Gates on the final tree: `npx hardhat test` **792 passing (707 Solidity, 85 TypeScript)**; isolated profile 707; `forge fmt`, `solhint`, `tsc` clean; Aderyn 0; Halmos 13 properties pass; upgrades-core 3 of 3; `verify:reproducible` 16 contracts identical; bytecode against `82c3c92`: `IntentToken` and `IntentExecutor` differ and `DvPExecutor` is new, the other 35 identical. Slither: **0 results** (338 contracts, 97 detectors) on the final tree.

Docs updated: flows-token (the executor paragraph and the batch diagram), transfer-checks, flows-dvp, architecture, roles, the README, SECURITY.md (the consideration bullet and a mutation row), the brief's §1 and §5. Not changed: `IIntentExecutor`'s ERC-165 id (errors are not part of it) and `InterfaceFreeze.t.sol`, which pins no error selectors. Nothing is committed or pushed.

## Review items, built before the first deployment (plan 2026-10-23; decisions made; S0 to S5, decision 4, finding 1 and finding 4 committed)

On 2026-10-23 the owner pasted a merged outside assessment and then said: "I prefer to have the code ready from the gate than waiting to do fixes X months after... if one institutions uses this seriously the gas costs are unecessary". The first version of this section proposed eleven decisions. The owner answered them the same day with changes, and added an S0 for the interfaces. The numbers below are the owner's answer; they differ from the first version's. A second answer settled the one open point of the first reply: `IPolicyHook` keeps its shape, with `checkSend` and `checkReceive` added and `ref` and `deadline` moved from fields into `extra`. The brief's rule 4 is satisfied: the owner's RD3 is the explicit instruction to reopen `contracts/interfaces/`, to be re-frozen after S0.

### The assessment, checked against HEAD `7536ec2`

| Claim | Result | Evidence |
|---|---|---|
| ERC-7943 differs from our interface | True | The standard is Final (created 2025-06-10). Fungible id `0x3edbb4c4` is the XOR of the six selectors (recomputed with `cast sig`). We differ in names (`setFrozen`, `getFrozen`), in `canTransfer` returning `(bool, bytes32)`, in having no `canSend`/`canReceive` and no `bool` returns, and in `setFrozen` reverting above the balance (Final: "MUST allow freezing more assets than those held"). Our `ForcedTransfer` event also has an `agent` argument; Final's has three |
| `AttestKind.IMPLEMENTATION` is not tied to a template | True, reproduced | `_authorizeUpgrade` checks only the attestation. A probe upgraded an `IntentToken` proxy to the `Gated4626Vault` implementation and it was accepted: balances survive, `decimals()` goes 18 to 6, `asset()` is 0, `totalAssets()` and `deposit` revert, plain transfers still work. Needs `UPGRADER_ROLE` (the timelock), so a governance mistake, not an attack |
| Dropping `FundHoldersRule` from a registered class's hook un-caps it silently | True, reproduced, already documented | A probe: `setRules` without the rule on a registered class is accepted; at a full cap of 3 a fourth investor then received tokens and `fund.holderCount()` stayed 3. Documented in the fund section above and in `governance-and-deployment.md`; the runbook forbids it |
| No `unregisterClass` | True | `Fund` has `registerClass` only |
| The hook codehash is per token | True, documented | `TOKEN`, `ADMIN` and `REGISTRY` are immutables, so each class needs its own deployed hook and its own council attestation |
| No address-level freeze | Partly | `setFrozen` is read only for the sender, so inflows and mints to a frozen holder pass. But `IdentityRule` rejects a de-verified sender (all kinds except MINT and FORCED) and a de-verified receiver (all kinds except BURN), so de-verifying in the identity registry blocks an address both ways. The registry is external, no role in this repo writes to it, and no document presents de-verification as the freeze route |
| Pause blocks mint and burn | True, documented | `_check` lets only FORCED through, and FORCED to `address(0)` is reserved. A burn by `BURNER_ROLE` from a de-verified holder is also refused by `IdentityRule` (`SENDER_NOT_VERIFIED`), paused or not. The enforcement route is `forcedTransfer` to the treasury, then a burn after an unpause, which takes the timelock delay or the recovery timelock's |
| Dust griefing | True, accepted as L-1 | `MinPositionRule` is planned and not built. The 4626 route needs a verified empty receiver and 1 wei |
| No batch primitives, no recovery address, no jurisdiction rule, whole-balance lockup | True | |
| ERC-7540 `maxDeposit` can overstate when controller and receiver differ | True, protected | `maxDeposit` checks the controller; the hook checks the receiver at the mint |
| "A thin ERC-7943 adapter would do" | Wrong | Freezing above the balance, the return types and the event shape cannot be done from outside the token. They touch the base. The Docs section above deferred exact conformance until the ERC was Final, and it now is |

Checked after the owner's answer: the ERC-3643 reference token (`Token.sol` in the ERC-3643 repository, main) puts `whenNotPaused` on `transfer` and `transferFrom` only; `mint`, `burn` and `forcedTransfer` carry `onlyAgent` alone, so its agents can mint and burn while paused. Its `setAddressFrozen` blocks `transfer` and `transferFrom` in both directions, but mint, burn and `forcedTransfer` ignore the flag. Not checked: whether the ERC-3643 text (as opposed to that token) says anything about pause, and whether it declares an ERC-165 id.

### Measured baseline

An ordinary `transfer` of 0.1 token between two existing holders on `IntentToken`, every touched account cold (`vm.cool`), probe in a scratch copy, so the numbers move by a few hundred gas between runs:

| Rules installed, in order | Gas | Step |
|---|---|---|
| `IdentityRule` | 36,962 | |
| + `LockupRule` | 43,825 | +6,863 |
| + `MaxHoldersRule` | 69,198 | +25,373 |
| + `FundHoldersRule` | 91,082 | +21,884 |

By reading the code (not traced), the four-rule transfer calls back into the proxied token seven times: `balanceOf` five times (`MaxHoldersRule.check` once, and `MaxHoldersRule.after_` and `FundHoldersRule.after_` twice each) and `policyHook` twice (`onlyHook` in each `after_`).

One more share class today: `new ComplianceHook` with four rules costs 880,631 gas (3,316 bytes of runtime code), plus 29,144 gas for the council's `attest`, plus one council review of that hook.

Deployed sizes against the 24,576-byte limit, today and with `MulticallUpgradeable` added to the base (spike in a scratch copy, compiled):

| Contract | Today | Headroom | With Multicall | Headroom |
|---|---|---|---|---|
| `IntentToken` | 15,574 | 9,002 | 16,194 | 8,382 |
| `Gated4626Vault` | 16,253 | 8,323 | 16,859 | 7,717 |
| `Gated7540Vault` | 21,546 | 3,030 | 22,152 | **2,424** |

Multicall costs about 610 bytes in each template. Everything else the base gains has to fit in the 2,424 bytes the 7540 vault has left.

### Decisions (the owner's, 2026-10-23)

| # | Decision | As decided | What I add or check |
|---|---|---|---|
| RD1 | Hook topology | **Shared.** One `ComplianceHook` per deployment, one codehash for the council to attest. State is keyed by token (`rules(token)`, `afterMask[token]`, `MAX_RULES` per token). The per-token admin comes from the token itself, `IAccessControl(token).hasRole(DEFAULT_ADMIN_ROLE, msg.sender)`, as the rules already do, so the hook has no `ADMIN` or `TOKEN` immutable. `setRules(token, rules)` also accepts `msg.sender == token`, so the token's initialiser installs the hook and the initial rule set in one call; until then `NO_RULES` fails closed. `ProxyDeployer` loses the `TOKEN()` binding check, passes `initialRules` in the init data and checks `hook.rules(proxy)` equals them afterwards. `afterTransfer` requires `msg.sender == ctx.token`. `onlyHook` in the rules is unchanged. The post-deploy check pins `rules(token)` to `RULE_ORDER` as now | The `msg.sender == token` clause is what makes the chicken-and-egg work: during the proxy's construction the token has no code yet, so the hook could not ask it `hasRole`. It is safe: a contract can only set the rules of its own address, and every rule is still attested. Confirmed by the owner: the token's `_setHook` and `ProxyDeployer` require `hook.REGISTRY()` equal to the token's registry, because a shared hook built on another registry would vet rules against the wrong list. The token initialisers (`IntentToken`, both vaults) gain an `initialRules` argument |
| RD2 | Balances in `extra` | **Do it.** `extra` is ours (rule 14). Pre-move `abi.encode(uint256 fromBalance, uint256 toBalance)`, zero for the zero side; for EXECUTED the layout appends `bytes32 ref, uint256 deadline`. `check` reads `extra`; `after_` derives the post-move balances from `amount` (`to + amount`, `from - amount`). The layout is documented in the policy interface's NatSpec. It is built by the same code in `_canTransfer` and `canExecute`, so parity holds | Same context for `check` and `after_`, so the base reads the two balances once per movement and the rules make no callbacks into the token. The two counting rules already return early on a self-transfer and a zero amount. `abi.decode` of the first two words ignores the EXECUTED tail |
| RD3 | ERC-7943 Final | **The token face only.** `IPolicyGated` takes 7943's names and return types: `setFrozenTokens` (above the balance), `getFrozenTokens`, `forcedTransfer` returns `bool`, `canTransfer` returns `bool`, `canSend`, `canReceive`. `supportsInterface(0x3edbb4c4)`. The reasoned pre-flight moves to a second name, `canTransferWithReason`. Policy rejections keep `PolicyGated_TransferRejected(bytes32)`; the token's own frozen check uses `ERC7943InsufficientUnfrozenBalance`. `canSend` and `canReceive` come from the policy's account-level checks. `IPolicyHook` keeps its shape with two edits: `checkSend` and `checkReceive` are added (also to `IComplianceRule`, with a default of `TRANSFER_OK` in `BaseRule`), and `ref` and `deadline` leave the context as fields and ride in `extra` for EXECUTED, which removes two transient slots. `_releaseFrozen` unfreezes only the frozen part of what moves, with `Frozen` before `Transfer`. Brief rule 7 is amended: policy rejections revert `PolicyGated_TransferRejected(bytes32)`, the token's own frozen check reverts `ERC7943InsufficientUnfrozenBalance` | The second name returns `(bool allowed, bytes32 reason)`, as the old `canTransfer` did. `isUserAllowed` goes: it is today a zero-amount mint probe, which `canReceive` replaces. The `ForcedTransfer` event becomes Final's three-argument event, with a second event `ForcedTransferBy(from, to, amount, agent)` so the agent is not lost. |
| RD4 | Address freeze | **Fold in** as `HolderRestrictionRule`, replacing `LockupRule`. Packed `uint64 unlockTime` plus `bool frozen` per (token, holder): one storage read. The freeze is in `checkSend` and `checkReceive` (account-level, both directions, as ERC-3643's `setAddressFrozen`); the lockup stays in the transfer check because it depends on the kind (an enforcement burn is exempt). `AGENT_ROLE` sets both. FORCED ignores the freeze on `from`; the receiver is still identity-checked | Mint to a frozen account is refused here (`checkReceive`); the ERC-3643 reference token allows it. Also refused: a burn, by a holder or by `BURNER_ROLE`, from a frozen account, so the enforcement route stays `forcedTransfer` to a quarantine account, as RD9 says. Confirmed by the owner: the freeze on `to` applies to FORCED and to MINT; the reference token checks neither. The docs say a quarantine wallet is never address-frozen (use a lockup), otherwise enforcement into it fails |
| RD5 | `MaxHoldersRule` on fund classes | **Leave out.** The investor count that matters for a fund is fund-wide. The rule stays available for a class with its own regulatory limit, and the docs say so. It also removes the per-class seed and exempt-holder ceremony for the escrow vault | `RULE_ORDER` loses it for `intent`, `fund` and `asyncFund`, since the deployment registers all three as classes. The measured step was 25,373 gas |
| RD6 | Template check | **Yes.** `templateId()` constant per template, compared in `_authorizeUpgrade` next to the attestation. `AttestKind` stays | The id is not versioned: `keccak256('IntentToken')`, `'Gated4626Vault'`, `'Gated7540Vault'`, so a bug-fix implementation of the same template stays upgradeable |
| RD7 | `MinPositionRule` | **Yes, zero means off.** The post-move balance of each non-zero side must be zero or at least the minimum, so no dust is left behind on either side. FORCED exempt; a holder's burn is checked, an enforcement burn (the operator holds `BURNER_ROLE`, as the lockup rule and the token's frozen-balance check define it) is not, and the role is asked only when a burn would leave a balance below the minimum. Ordered right after the identity rule and before the holder rules, so the counts only ever see real positions. This closes L-1 | Exempt, confirmed by the owner: the token itself (the 7540 escrow, without which a redeem request below the minimum would be refused) and accounts the token's admin lists. A new reason `BELOW_MIN_POSITION` |
| RD8 | Batching | **No bespoke batch functions; add `MulticallUpgradeable`.** One function, every role-gated call gets atomic batching, `_msgSender()` is preserved through the delegatecall to self | Measured at about 610 bytes (above). OpenZeppelin's `multicall` is not payable, so no ETH can enter. The size is the risk: shared hook plumbing, the 7943 face, `templateId` and the policy checks must fit in 2,424 bytes in the 7540 vault. Measured after S2. If over, the lever is `via-ir` pinned in both toolchains, as the owner decided, not moving functions out of the vault. It needs the same setting in Hardhat and forge (the reproducibility gate compares them) and a clean run of Slither, Aderyn and Halmos. `optimizer.runs` is 200 in both (`hardhat.config.ts`, `foundry.toml`); lowering it changes no code but costs gas on every call |
| RD9 | Pause | **Docs only, no `forcedBurn`.** Incident path: `forcedTransfer(from, quarantine)` during the pause, then `burn(quarantine)` after the unpause. The docs say plainly that this differs from ERC-3643, which lets agents burn while paused | Verified above, for the ERC-3643 reference token. The docs will say "the ERC-3643 reference token". Our pause also blocks the issuer's mint, which that token does not |
| RD10 | Fund integrity | **`Fund.isClassIntact(token)`, no `unregisterClass`.** Intact means registered and the installed rule listed in `hook.rules(token)`. Add `firstBrokenClass()` so the monitor and the post-deploy check make one call | `firstBrokenClass()` returns the first registered class that is not intact, or the zero address |
| RD11 | Order | **S0 to S5** below. The owner's S0 is the specification, the interface edits and the re-pinned `InterfaceFreeze.t.sol`, in one commit with the tree green, then a re-freeze | S0 is built in the additive form: see "S0 as built" for why the edits to the existing frozen interfaces move to the steps that implement them |

The first estimate of the gas result is the owner's: the 91k four-rule transfer should land around 65 to 70k with RD2 and RD5, before `MinPositionRule`. By arithmetic RD5 alone gives about 65.7k (91,082 minus 25,373). To be re-measured after S3, with the probe above.

### Decided: the policy interface

`IPolicyHook` keeps its shape (`beforeTransfer`, `afterTransfer`, `wantsAfter`, `policyHook()` on the token) with two edits, both landing in S1:

- `checkSend(address token, address account)` and `checkReceive(address token, address account)`, each returning a reason code, on `IPolicyHook` and on `IComplianceRule`; `BaseRule` returns `TRANSFER_OK` by default. They serve `canSend` and `canReceive` and nothing else: `check(ctx)` already applies the same account-level decision to a movement, per kind, so the hook still makes one call per rule per movement. A rule's `check` and its `checkSend` and `checkReceive` must agree, and a test pins that.
- `TransferContext` loses `ref` and `deadline` as fields: `{token, from, to, id, amount, operator, kind, extra}`. No contract reads them; the base builds them and tests set them. For EXECUTED they ride in `extra` after the balances.

The draft ERC in `~/dev/urwa-policy` is not adopted by this stack; RD2 puts balances in `extra` for every kind, which that draft does not allow, so its amendment stays an S5 item.

### Assumptions, say if wrong

1. The demo rule order becomes: `intent`: identity, min position, holder restriction, settlement window, fund holders. `fund` and `asyncFund`: identity, min position, holder restriction, fund holders.
2. The rule setters (`setLockup`, `setFrozen`, and the cap and exemption setters that stay) are batched by OpenZeppelin's `Multicall` on the rule, which preserves the sender, not by array functions, for the reason RD8 gives. S3 decides whether it fits.

### S0: the interface specification

Text only, no NatSpec (it lands with the code, as rule 16 requires). Parameter names carry the project's underscore; the ERC-165 ids do not depend on names.

```solidity
// contracts/interfaces/IERC7943Fungible.sol (new): the Final text
interface IERC7943Fungible is IERC165 {
  event ForcedTransfer(address indexed from, address indexed to, uint256 amount);
  event Frozen(address indexed account, uint256 amount);
  error ERC7943CannotSend(address account);
  error ERC7943CannotReceive(address account);
  error ERC7943CannotTransfer(address from, address to, uint256 amount);
  error ERC7943InsufficientUnfrozenBalance(address account, uint256 amount, uint256 unfrozen);
  function forcedTransfer(address from, address to, uint256 amount) external returns (bool result);
  function setFrozenTokens(address account, uint256 amount) external returns (bool result);
  function canSend(address account) external view returns (bool allowed);
  function canReceive(address account) external view returns (bool allowed);
  function getFrozenTokens(address account) external view returns (uint256 amount);
  function canTransfer(address from, address to, uint256 amount) external view returns (bool allowed);
} // id 0x3edbb4c4

// contracts/interfaces/IPolicyGated.sol: is IERC7943Fungible
//   removed: setFrozen, getFrozen, isUserAllowed, canTransfer(bool, bytes32), ForcedTransfer with an agent,
//            Frozen (now inherited), PolicyGated_FrozenExceedsBalance
//   added:   canTransferWithReason(from, to, amount) returns (bool allowed, bytes32 reason)
//            event ForcedTransferBy(address indexed from, address indexed to, uint256 amount, address indexed agent)
//            error PolicyGated_HookRegistryMismatch(address hookRegistry, address tokenRegistry)   // _setHook and init
//   kept:    mint, burn, pause, unpause, setPolicyHook, registry, PolicyHookChanged, PolicyGated_TransferRejected
//            policyHook() stays

// contracts/interfaces/ITemplated.sol (new)
interface ITemplated {
  error Templated_WrongTemplate(address newImplementation, bytes32 expected, bytes32 actual);
  function templateId() external pure returns (bytes32 id);
}

// contracts/interfaces/IComplianceHook.sol: shared
//   removed: ADMIN(), TOKEN(), the constructor's token and initialRules, RuleSetChanged(bytes32[])
//   setRules(address token, IComplianceRule[] calldata rules)   // token admin, or msg.sender == token
//   rules(address token) returns (IComplianceRule[] memory)
//   ruleCount(address token) returns (uint256)
//   event RuleSetChanged(address indexed token, bytes32[] ruleIds)
//   errors: ComplianceHook_NotTokenAdmin(address token, address caller)
//   kept: MAX_RULES, REGISTRY(), the 16-rule cap, per-rule attestation, NO_RULES fail-closed

// contracts/interfaces/IFund.sol: added
//   isClassIntact(address token) returns (bool)
//   firstBrokenClass() returns (address token)        // zero address when every class is intact

// contracts/interfaces/IHolderRestrictionRule.sol (new; replaces ILockupRule)
//   setLockup(address token, address holder, uint256 unlockTime)      // token AGENT_ROLE
//   setFrozen(address token, address holder, bool frozen)             // token AGENT_ROLE
//   unlockTime(address token, address holder) returns (uint256)
//   isFrozen(address token, address holder) returns (bool)
//   events LockupSet(token, holder, unlockTime), HolderFrozenSet(token, holder, frozen)

// contracts/interfaces/IMinPositionRule.sol (new)
//   setMinPosition(address token, uint256 amount)                     // token DEFAULT_ADMIN_ROLE; zero is off
//   setExempt(address token, address account, bool exempt)            // token DEFAULT_ADMIN_ROLE
//   minPosition(address token) returns (uint256), isExempt(address token, address account) returns (bool)
//   events MinPositionSet, ExemptSet

// contracts/interfaces/Errors.sol: appended reasons
//   BELOW_MIN_POSITION, SENDER_FROZEN, RECEIVER_FROZEN

// TransferContext.extra, pre-move, for every kind:
//   abi.encode(uint256 fromBalance, uint256 toBalance)   // zero for address(0)

// contracts/interfaces/IPolicyHook.sol and IComplianceRule.sol: the two edits of "Decided: the policy interface"
//   TransferContext { address token; address from; address to; uint256 id; uint256 amount; address operator;
//                     TransferKind kind; bytes extra; }          // ref and deadline removed
//   function checkSend(address token, address account) external view returns (bytes32 reason)     // both interfaces
//   function checkReceive(address token, address account) external view returns (bytes32 reason)  // both interfaces
//   BaseRule: both default to TRANSFER_OK
```

The initialisers of `IntentToken`, `Gated4626Vault` and `Gated7540Vault` gain an `initialRules` argument. `IPolicyRegistry`, `ITransferIntent`, `IIntentExecutor`, `IIntentExecutorBatch`, `IDvPExecutor` and `IERC3009` do not change.

### The other designs, as decided

**Template ids (RD6).** `_authorizeUpgrade` keeps the attestation check and then requires `ITemplated(newImpl).templateId() == templateId()`. An implementation without the function reverts the call, so it is refused. Tests first: each template to another template's implementation refused, to a new implementation of its own accepted, an implementation without `templateId` refused.

**Frozen amounts above the balance (RD3).** `_check` already treats the unfrozen amount as zero when `frozen > balance`. `_releaseFrozen` follows the standard: it lowers the frozen amount by exactly what the action needs, so with a balance of 10, a frozen amount of 100 and a forced transfer of 10, the frozen amount becomes 90 (today it becomes 0). The `frozen <= balance` invariant test and the Halmos frozen properties are rewritten around `unfrozen = balance - min(frozen, balance)`.

**Fund integrity (RD10).** The post-deploy check calls `firstBrokenClass()`. It cannot prevent a drop; nothing in the hook can know about the fund. The docs name the call as the monitor.

**Gas candidates (R7, each measured alone before it is kept).** The five `balanceOf` callbacks go with RD2. Packing the rule count and the after mask into one word saves one cold read. Storing the rule list as the code of a data contract replaces one cold read per rule with one `EXTCODECOPY`, worth it only if the probe shows a clear gain at four rules, because each `setRules` then deploys a data contract. A candidate is kept when it saves about 2,000 gas per transfer or per class and the code stays simple. Results go into the docs as measured numbers; tests do not assert gas.

### Build order

Each step: tests first with the red run shown, implementation, both runners, Slither, Aderyn and Halmos where touched, the gas probe re-run, then stop for review. Commits only on the owner's order, files staged by name.

| Step | Content |
|---|---|
| S0 | This section, the new interface files, the appended reasons and their pins (built, see below). The breaking edits to the existing frozen interfaces land with the step that implements them. Re-freeze on approval |
| S1 | The shared hook and the context with balances; the rules' balance reads move to the context (the existing rules, so the tree stays green); `ProxyDeployer` and the initialisers take `initialRules` |
| S2 | The base: ERC-7943 face, `_releaseFrozen`, `MulticallUpgradeable`, `templateId`. **Size gate** on the 7540 vault |
| S3 | The rules: `HolderRestrictionRule`, `MinPositionRule`; `MaxHoldersRule` and `FundHoldersRule` adapted to the context. Gas probe re-run (built, see "S3 as built"; the two counting rules had read the context since S1, so their S3 change is the cap answer in `checkReceive`) |
| S4 | The fund views; the Ignition modules and fixtures (shared hook deployment, the new `RULE_ORDER`, the post-deploy checks) (built, see "S4 as built"; the shared hook deployment had landed in S1) |
| S5 | Docs, `SECURITY.md`, `README.md`, the brief (`CLAUDE.md` §1, §4, §5, §6 and the rule list), the pause runbook, the amendment to the draft ERC for RD2, `InterfaceFreeze` re-pinned, reproducibility (built, see "S5 as built"; the draft ERC amendment is in another repository and is not done) |

### What this changes in frozen files

By step: S1 `IPolicyHook`, `IComplianceRule`, `IComplianceHook` and the semantics of `TransferContext.extra`; S2 `IPolicyGated` and the ERC-165 id of every template; S4 `IFund`. New files, built in S0: `IERC7943Fungible`, `ITemplated`, `IHolderRestrictionRule`, `IMinPositionRule`, and three appended reason codes in `Errors.sol`. `ILockupRule` goes in S3. Every implementation, hook and rule codehash changes, which is free before the first deployment. `InterfaceFreeze.t.sol` is re-pinned in each step's commit.

### S0 as built (2026-10-23, committed `71f10cd`)

The owner's S0 was: the specification, the interface edits and the re-pinned `InterfaceFreeze.t.sol`, one commit, tree green. All of it cannot be one green commit. Changing `IPolicyGated`, `IPolicyHook`, `IComplianceRule` and `IComplianceHook` breaks every contract and test that implements or calls them (`TransferContext` alone appears in 23 contract and test files, and the shared hook is a rewrite of `ComplianceHook`). Making that compile would pull S1 and S2 into S0. So S0 is built in the additive form, which stays green:

- The specification above, final.
- Four new interface files: `IERC7943Fungible` (the Final text), `ITemplated`, `IHolderRestrictionRule`, `IMinPositionRule`, with full NatSpec.
- Three appended reasons in `Errors.sol`: `BELOW_MIN_POSITION`, `SENDER_FROZEN`, `RECEIVER_FROZEN`.
- `InterfaceFreeze.t.sol` pins the four ids (`0x3edbb4c4`, `0x7aa77f29`, `0x3abb7c85`, `0x44ac9195`, computed with `cast sig`; the first is the standard's own and `type(IERC7943Fungible).interfaceId` reproduced it), the event topics and the three reasons.

Tests first: the pins were added before the files and the run failed to compile (`HHE902`, the import of `IERC7943Fungible.sol` could not be resolved), then passed once the files existed. `forge fmt --check` and `solhint` are clean. Both runners: 792 passing (707 Solidity, 85 TypeScript), unchanged, since the pins live in existing tests.

"Re-freeze" then means: the specification here is frozen for S1 to S5, and the new interface files are frozen by their pins. Each existing interface changes in one commit together with the code that implements it and its new pin.

### S1 as built (2026-10-24, committed `0aaed89`)

One shared `ComplianceHook` and the balances in the context. What changed:

- **Hook.** `ComplianceHook(registry)` is the only constructor argument. State is per token: a mapping to a struct holding the rules by position and one word with the rule count and the after mask. `setRules(token, rules)` is allowed to the token itself or to whoever holds `DEFAULT_ADMIN_ROLE` on it, asked live (a token with no code is refused); `afterTransfer` requires `msg.sender == ctx.token`; `wantsAfter()` answers for `msg.sender`; `rules(token)`, `ruleCount(token)`, `checkSend` and `checkReceive` (first rejection wins, `NO_RULES` for a token with none). `RuleSetChanged(token, ruleIds)`.
- **Token.** The initialisers of `IntentToken` and both vaults take `initialRules`. The base's init installs the hook, then calls `setRules(address(this), initialRules)` on it (skipped for an empty list). `_setHook` also requires `hook.REGISTRY()` to equal the token's registry (`PolicyGated_HookRegistryMismatch`).
- **Context.** `TransferContext` is `{token, from, to, id, amount, operator, kind, extra}`. `extra` is `abi.encode(fromBalance, toBalance)` before the move for every kind, with `bytes32 ref, uint256 deadline` appended for EXECUTED. It is built in `_context`, which the write and every pre-flight share, so parity holds by construction. `afterTransfer` gets the same context.
- **Rules.** `IPolicyHook` and `IComplianceRule` gained `checkSend` and `checkReceive` (`BaseRule` returns `TRANSFER_OK`; `IdentityRule` answers them from the registry). `MaxHoldersRule` and `FundHoldersRule` read the balances from `extra` and make no call into the token except the `policyHook` lookup in `onlyHook`. `Fund._hookListsRule` and `MaxHoldersRule._isListed` read `rules(token)`.
- **Deployer.** `ProxyDeployer.deploy(symbol, implementation, initData, hook, expectedRules)` no longer checks a binding; it checks that the token installed `hook` and that `hook.rules(proxy)` equals `expectedRules`, in order (`ProxyDeployer_RulesMismatch`).
- **Deployment.** The `Tokens` stage is gone. `Components` deploys the hook; the council attests rules, hook and implementations in one step; `Activate` takes `hook` and the five rule addresses, passes each token its `RULE_ORDER` list in the init data, and the hand-over check pins `hook.rules(token)` to `RULE_ORDER`. Consequence for the owner to weigh: there is no longer a council read of each token's rule list between the deploy of the hook and the token coming up, because the list is installed when the token is initialised. What stops a wrong list is the attestation of every rule, `ProxyDeployer`'s equality check and the post-deploy check, all before any role is granted.
- **Pins.** `InterfaceFreeze.t.sol` re-pinned, ids computed with `cast sig` from the compiled interfaces: `IPolicyHook` `0x4f7b9fbb` (was `0xb7723023`), `IComplianceRule` `0x837a7ec1` (was `0x93d5c2be`), `IComplianceHook` `0xa8f3d563` (was `0x2604e338`), `IProxyDeployer` `0xcedb15bb` (was `0x886d8cd8`), `IGated4626Vault` `0x6208cbc1` (was `0xb008690c`), `IGated7540Vault` `0x8f0b8793` (was `0x75f5b0db`); `RuleSetChanged` topic `0x052ffefc...d820`.

Two statements of the plan that the build did not bear out. The two transient slots do not go: `executeTransfer` has to hand the kind, the reference and the deadline to `_update`, which OpenZeppelin fixes at three arguments, so they still travel through transient storage; what changed is that the reference and the deadline land in `extra` instead of in struct fields. And the vault initialisers take the rules, and for the 7540 vault the name and symbol, as `memory`, because the extra calldata array put them over the stack limit.

Tests first, red run shown: the new `ComplianceHook.t.sol` and the new base tests (`PolicyGatedUnit_Context`, `PolicyGatedUnit_SharedHook`) failed to compile against the old code (wrong argument counts, `setRules(address, ...)`, `checkSend`, the ten-field context, `PolicyGated_HookRegistryMismatch`), then passed. New or rewritten: the hook suite (per-token isolation, the token and admin authorisation, the cap per token, `afterTransfer` for the context token only, `wantsAfter` for the caller, account checks), the context layout for each kind and its parity with the pre-flight, the registry check and the initial rules, `ProxyDeployer`'s rules check, the identity account checks, and the TypeScript deployment tests (a twin hook, an unattested hook, an unattested rule). The tests that mocked `balanceOf` for the counting rules now put the balances before the move in the context, and the two "token tries to write during the balance read" tests became "the rule never reads it".

Gates on the working tree: Solidity runner 737 passing (was 707), Node runner 85 passing, `forge fmt --check`, `solhint --max-warnings 0`, `tsc --noEmit`, `validate:upgrades` (3 of 3), Aderyn 0 findings, Halmos 13 of 13 (the fund suite's hook stub needed `rules(address)`), reproducibility (16 contracts identical, `TokenProxy` matches `ProxyDeployer`), Slither 0 results (it first reported two benign findings in the 7540 initialiser, a reentrancy through the `setRules` call before the vault's own initial state; suppressed inline with the reason, since the hook is attested and `initialize` cannot be re-entered). Aderyn needed inline suppressions: the narrowings in the hook (bounded by `MAX_RULES`), and the errors that S0's interfaces declare before anything throws them. The S0 commit on its own did not pass the Aderyn gate for that reason; these suppressions come off as S2 and S3 use the errors.

Measured, same probe and method as the baseline (transfer of 0.1 token between two holders, every touched account cold, scratch copy):

| Rules installed, in order | Before | After S1 |
|---|---|---|
| `IdentityRule` | 36,962 | 35,661 |
| + `LockupRule` | 43,825 | 42,523 |
| + `MaxHoldersRule` | 69,198 | 62,977 |
| + `FundHoldersRule` | 91,082 | 81,804 |
| identity, lockup, fund (no per-class cap, RD5's set) | n/a | 63,389 |

The four-rule transfer fell 9,278 gas (10%): the balance callbacks that RD2 removes, and one cold storage read fewer from packing the count with the mask. With RD5's set, which S4 puts in the deployment, a transfer costs 63,389, which is 27,693 (30%) below the old four-rule figure. That is above the 57,000 to 59,000 the decision estimated: RD2 saved most of its estimate on `MaxHoldersRule`, which RD5 then removes, so the two overlap. One more class: the shared hook is deployed once (852,213 gas, 4,078 bytes), and a class costs `setRules` for four rules inside its initialiser, 152,941 gas, with no deployment, no attestation and no council review of a new hook; it was 880,631 plus 29,144 and a review.

Sizes (deployed bytes, headroom to 24,576): `IntentToken` 16,287 (8,289), `Gated4626Vault` 16,949 (7,627), `Gated7540Vault` 22,010 (2,566; was 3,030), `ComplianceHook` 4,078. The 7540 vault now has 2,566 bytes for what S2 adds: `MulticallUpgradeable` measured at about 610, plus the ERC-7943 face and `templateId`. That is tight; the `via-ir` fallback of RD8 is a real possibility.

The docs, `README.md`, `SECURITY.md` and `CLAUDE.md` still describe a hook per token and the `Tokens` stage; the plan puts them in S5.

### S2 as built (2026-10-24, committed `6709889`)

The ERC-7943 face, the freeze semantics, `MulticallUpgradeable` and the template check. What changed:

- **`IPolicyGated`** inherits `IERC7943Fungible`. Removed: `setFrozen`, `getFrozen`, `isUserAllowed`, the tuple `canTransfer`, the four-argument `ForcedTransfer` and `PolicyGated_FrozenExceedsBalance`. Added: `canTransferWithReason`, `ForcedTransferBy`. The token answers `supportsInterface(0x3edbb4c4)`. `forcedTransfer` emits the standard's three-argument `ForcedTransfer` and then `ForcedTransferBy`, and returns `true`.
- **Freeze.** `setFrozenTokens` accepts an amount above the balance. `_releaseFrozen` lowers the frozen amount by exactly the part of the amount that was frozen (balance 10, frozen 100, force 10: frozen becomes 90) and emits `Frozen` before `Transfer`. `_check` measures the unfrozen balance, zero when the frozen amount is the larger, so a zero amount passes. A forced transfer and an enforcement burn (the operator holds `BURNER_ROLE`, as the lockup rule defines it) may take frozen tokens but never more than the balance. The token's own check reverts with `ERC7943InsufficientUnfrozenBalance(account, amount, unfrozen)`; a policy rejection, including a hook that returns the same reason code with no shortfall behind it, keeps `PolicyGated_TransferRejected(reason)`.
- **`canSend`, `canReceive`** are the hook's `checkSend` and `checkReceive` for this token, false while paused and when there is no hook. `FundHoldersRule` answers both with `NOT_FUND_CLASS` for a token that is not a registered class or when it is not the fund's installed rule, so `canReceive` is false exactly when every movement is (pulled forward from S3, so the standard's answer is truthful at this stop).
- **Template id.** Each template reports `keccak256('IntentToken')`, `'Gated4626Vault'` or `'Gated7540Vault'`; `_authorizeUpgrade` refuses an attested implementation that reports another id, or none. The review's reproduction is a governance test on the deployed stack: the timelock schedules the intent token's upgrade to the attested 4626 implementation and the execution reverts with `Templated_WrongTemplate`.
- **`MulticallUpgradeable`** in the base, with `__Multicall_init` in the initialisers. It is not payable, preserves the sender, and a forced transfer followed by a plain one in one batch reaches the hook as FORCED and then TRANSFER.
- **Pins.** `IPolicyGated` `0x02331726` (was `0xf517b40d`); `ForcedTransferBy` topic `0x9820680c...5978`; the old `ForcedTransfer` and `Frozen` pins moved to `IERC7943Fungible`. The two Aderyn suppressions for errors now thrown came off.

Tests first, red run shown (the new base, template and conformance tests failed to compile against the old interface). Solidity runner 790 passing (was 737), Node runner 91 (was 85, with the cross-template upgrade test and the new `erc7943.test.ts`). The Halmos frozen properties were rewritten for the new semantics (the frozen amount never rises, and enforcement releases exactly the frozen part) and pass with the other twelve. Fourteen mutants of the new base logic were run against the base and `IntentToken` suites and every one was killed: the release taking the whole amount, a missing `Frozen`, a zero amount refused when the frozen amount is the larger, the burn and forced exemptions dropped, the template check dropped, `canSend` ignoring pause, `canReceive` asking about sending, `setFrozenTokens` refusing above the balance, the unfrozen error as a policy rejection, `ForcedTransferBy` dropped, `forcedTransfer` returning false, the standard's id dropped from `supportsInterface`, and `canTransfer` ignoring the amount.

Gates on the working tree: `forge fmt --check`, `solhint --max-warnings 0`, `tsc --noEmit`, `validate:upgrades` (3 of 3, so `__Multicall_init` is where the validator wants it), Aderyn 0, Halmos 13 of 13, reproducibility (16 contracts), Slither 0 results (it first reported two equality findings, on an enum and on a reason code, which are suppressed inline with the reason).

Sizes against the 24,576-byte limit, with S1 in brackets: `IntentToken` 17,778 (16,287), `Gated4626Vault` 18,375 (16,949), `Gated7540Vault` **23,479** (22,010), headroom 1,097. The size gate holds without `via-ir`. S2 added 1,469 bytes to the 7540 vault, of which about 610 is `MulticallUpgradeable`, against the 2,566 that were left. Nothing in S3 to S5 touches the vault's code, but 1,097 bytes is what any later feature in a template has to fit in.

Gas, same probe: the four-rule transfer is 82,020 (S1: 81,804, so +216, the `_check` helper and the enforcement-burn lookup); the RD5 set 63,604.

**The outside review of S0 to S2, checked against the code.**

| Claim | Result |
|---|---|
| One shared hook and one attestation replace a hook and a council step per class | True. The saving is smaller than stated: the 880,631 gas of the old hook deployment and the 29,144 of its attestation are replaced by `setRules` in the initialiser (152,941 for four rules), so the net is about 757,000 and one council step, not 909,000 |
| Rule list and mask share one word, so the three hook calls read one warm slot | True: `beforeTransfer`, `wantsAfter` and `afterTransfer` read the same word, warm after the first |
| A predicted proxy address cannot be set on the shared hook before it exists; the init and the equality check are atomic | True. Before `deploy` the address has no code, so `setRules` for it reverts `ComplianceHook_NotTokenAdmin`; `new TokenProxy` and `initialize` run in one call |
| A token cannot install a hook on another registry | True, tested in the base and in `ProxyDeployer` |
| Moving `ref` and `deadline` into `extra` shrinks the struct a rule receives from 10 words to 8 | **False for what the rule receives.** The ABI encoding of the context is 384 bytes before and 384 bytes after for every kind but EXECUTED, which grew from 384 to 448; the two words removed from the head are replaced by the two balances in `extra`. The saving comes from the removed callbacks, not from a smaller context |
| It removes 5 reentrant `balanceOf` reads, 9,278 gas (10.2%), 30.4% with RD5 | Numbers true (91,082 to 81,804, and to 63,389). The reads are view calls back into the token, not reentrant (the guard is held and a view call is allowed), the 9,278 includes about 1,300 from the packed word, and two `policyHook` callbacks per transfer remain (`onlyHook` in each `after_`) |
| Self-transfers and zero amounts return early in both counting rules, in `check` and `after_` | True. In `FundHoldersRule.check` the class test runs first, so a zero-amount probe on a token that is not the fund's class is still `NOT_FUND_CLASS` |
| Pre-flight with `amount > fromBalance` is caught in `_check` before the rules | **False as built in the first S2 pass, true now.** An account holding `BURNER_ROLE` was exempt from the frozen check and so from the balance bound, so `canTransfer(burner, 0, balance + 1)` said yes while the write would revert. Reproduced by a failing test, fixed: enforcement actions may take frozen tokens but never more than the balance |
| `_releaseFrozen` used to clamp the frozen amount and would wipe an excess freeze | Accurate about the clamp, but no excess freeze could exist before: `setFrozen` refused amounts above the balance |
| `Frozen` before `Transfer`; `canSend`/`canReceive`/`canTransfer` as the standard says; id advertised | True, tested (including the exact unfrozen boundary and a pair-by-pair check of `canTransfer` against `canSend` and `canReceive` on the real identity rule) |
| The template check closes the cross-template upgrade completely | True for a template that reports its id honestly. The attestation stays the root of trust: a council that attests code which lies about its id defeats it |
| Multicall is safe with the transient slots because `_consumePending` clears them first | True and tested (`test_WhenAForcedTransferIsFollowedByAPlainTransferInOneBatch_TheSecondIsPlain`). A reverting subcall reverts the transaction and the transient storage with it |
| The working tree has S2's TypeScript callers still to do | Out of date: S1 is committed (`0aaed89`) and S2 was complete, TypeScript included, when the review arrived |
| `MinPositionRule`: `IMinPositionRule` and `PLAN.md` line 1989 disagree about exemptions | The quoted line does not exist in this file. The substance is right: neither the plan nor the interface said what happens to an enforcement burn that leaves a remainder below the minimum. Now stated in both: an enforcement burn is exempt, and the role is asked only when a burn would leave a balance in (0, min). Test and implementation are S3 |
| `CredentialRule` should override `checkSend` and `checkReceive` | Valid, and missing: the Credential-layer section does not mention `checkSend`, `checkReceive`, `canSend` or `canReceive`. That section is not part of this plan, so it is left as it is and flagged to the owner |
| `EXIT_ONLY` fixes a real vault case: a lapsed investor cannot redeem | True of the code: `Gated7540Vault._requirePayoutEligible` runs the burn probe `_canTransfer(controller, 0, 0)`, `IdentityRule` rejects an unverified sender for a burn, and `requestRedeem` is a transfer from the same sender. Today the exit is `recoverRedeemRequest` or `recoverClaimable` by `AGENT_ROLE` |

Found while validating, fixed in S2: the pre-flight gap above, and a flaw the fuzzer found afterwards: a hook returning `INSUFFICIENT_UNFROZEN` for a mint was relabelled with the standard's error and a zero account. The token now confirms a real shortfall before using the standard's error.

### S3 as built (2026-10-24, committed `58fdb7b`)

The two rules, and one change to the vaults and the counting rules that the minimum forced. What changed:

- **`HolderRestrictionRule`** replaces `LockupRule`; `LockupRule.sol`, `LockupRule.t.sol` and `ILockupRule.sol` are deleted. One storage word per (token, holder): `struct Restriction { uint64 unlockTime; bool frozen }` (a test pins the packing). `check` judges the sender first, for every kind except FORCED and a mint: frozen gives `SENDER_FROZEN`, a lockup still running gives `LOCKED` (TRANSFER and EXECUTED; a BURN unless the operator holds `BURNER_ROLE`, asked only while a lockup is running). Then the receiver, for every kind except a burn: frozen gives `RECEIVER_FROZEN`, so a mint or a forced transfer into a frozen account is refused, as RD4 decided. A burn from a frozen account is refused even for the burner. `checkSend` and `checkReceive` answer the freeze; the lockup depends on the kind, so they ignore it. `setLockup` and `setFrozen` keep each other's field. `setLockup` refuses a future time above 64 bits (`UnlockTimeTooLarge`); a time at or before now clears the lockup as before.
- **`MinPositionRule`**, as RD7: per token, 0 is off. After a movement the receiver holds `toBalance + amount`, which must reach the minimum, and the sender holds `fromBalance - amount`, which must be 0 or reach it. Neither sum is computed where it could overflow or underflow, so a view never reverts on arithmetic (Halmos proves it for every input). Exempt: FORCED (including the enforcement mint), the token itself (the 7540 escrow), accounts the token's admin lists, and an enforcement burn (the operator holds `BURNER_ROLE`); the role is asked only when a burn would leave a remainder below the minimum, and the exemptions only when a position would breach. Zero amounts and self-moves are never judged. A holder who sits below a raised minimum can only exit completely or top up. `isExempt` is true for the token itself without a listing.
- **Aderyn.** The five "unused until S3" suppressions in `IHolderRestrictionRule` and `IMinPositionRule` are gone; the three on `IERC7943Fungible` stay for good (the standard's own errors).
- **Pins.** The `ILockupRule` id and event pin go; `LockupSet` keeps its topic under `IHolderRestrictionRule` (same signature). No interface id changed in S3. NatSpec only: `IComplianceRule.checkReceive` (below), `IGated4626Vault`, `IFundHoldersRule`, `IMaxHoldersRule`, `IMinPositionRule`.

**What the plan did not foresee: the one-wei probes.** The vaults asked `canTransfer(0, receiver, 1)` for `maxDeposit`, `maxMint`, the 7540 `requestDeposit` and the claim check, and `canTransfer(owner, 0, 1)` for the 4626 `maxRedeem`. With a minimum set, one wei is dust. Written first, the new vault tests failed: `maxDeposit` read 0 for any account holding less than the minimum, `requestDeposit` refused every fresh controller with `ControllerNotEligible(BELOW_MIN_POSITION)` (10 tests red), and after fixing the mint side alone a holder sitting exactly at the minimum still had `maxRedeem` 0, because a burn of one share leaves dust. A rule cannot tell a probe from a movement, so the probes had to ask what they mean:

- **Mint side: `canReceive`.** A new internal `_accountReason(account, sending)` in the base (the reason behind `canSend` and `canReceive`; PAUSED, NO_HOOK, or the hook's `checkSend` / `checkReceive`). It has no amount, so a minimum cannot read as a block. The vault `max*` and the 7540 request and claim checks use it.
- **The cap had to follow.** `maxDeposit` is 0 for a new investor at a full cap, which `Gated4626Vault.t.sol` and `FundIntegration.t.sol` assert and ERC-4626 requires (`maxDeposit` must not exceed what `deposit` accepts). The one-wei probe carried that. So `MaxHoldersRule.checkReceive` and `FundHoldersRule.checkReceive` now answer the cap as `check` answers for a mint: an account that is not yet a holder (an investor, for the fund) cannot receive at or above the cap; an exempt account, an existing holder and the class itself can. The token is asked for a balance only at or above the cap. This reverses a stance of mine in S2 ("a full fund does not stop an account from being asked"), not one of yours. `canReceive` becomes more useful to integrators for it: an exchange asking whether it can send to an address now learns that the fund is full.
- **Burn side.** The 4626 `maxRedeem` probes a burn of nothing (the 7540 payout probe already did): identity, freeze, lockup, pause. The size of a real redemption is judged when it burns.
- **`IComplianceRule.checkReceive` NatSpec.** It must not depend on an amount, and it must agree with `check` except where the movement itself frees what the account would take: a transfer that empties its sender can still admit a new holder at the cap, which an account question cannot know.
- **Limit that stays.** A 7540 request cannot know how many shares it will buy, so it is not refused for size. For a fresh controller whose fulfilled shares come to less than the minimum, the claim reverts with `BELOW_MIN_POSITION` and the claimable stays; the agent's `recoverClaimable` (an enforcement mint, exempt) delivers it, or the fulfiller rejects the request before fulfilling. A test shows the claim reverting and the recovery.

Alternatives I did not take: leave the counting rules alone and let `maxDeposit` ignore the cap (it would overstate, against ERC-4626); probe with the largest amount instead of one wei (works for a minimum, breaks `maxDeposit` for any future supply-cap or maximum-position rule, which is why one wei was the right probe for upper bounds); put `if (reason == BELOW_MIN_POSITION)` in the vault (rule knowledge in a template, brief rule 11).

Tests first, red runs shown. The first run failed to compile against the missing rules; with the rules in, the rule suites passed and nine `checkReceive` cap tests failed; the ten vault minimum-position tests failed on the probes; after the mint side, one `maxRedeem` test still failed. Solidity runner 890 passing (was 790), Node runner 92 (was 91, with the freeze test). Halmos 16 of 16 (was 13): `MinPositionRuleHalmos` proves that a transfer is rejected exactly when a position would be left in (0, min), that the rule never reverts on any input of any kind, and that FORCED is never rejected. Mutation checks: 5 of 5 planted bugs fail a Halmos property; of 24 planted in the two rules, 23 fail a Solidity test and one is equivalent (dropping the `min == 0` early return gives the same answers, since the checks that follow pass at 0; it only saves the decode); of 12 planted in the probes and account answers, 11 failed a test at once and one (the no-hook answer of `_accountReason`) survived because no test could reach a token without a hook. The new base test clears the hook slot and kills it; it also covers the `NO_HOOK` reason of the pre-flight, which nothing tested before.

Gates on the working tree: `forge fmt --check`, `solhint --max-warnings 0`, `tsc --noEmit`, `validate:upgrades` (3 of 3), Aderyn 0, Halmos 16 of 16, reproducibility (17 contracts: `LockupRule` out, `HolderRestrictionRule` and `MinPositionRule` in). Slither's first full run had one result: `_stored` in `setLockup` starts at zero by design. It is suppressed inline with that reason; the rule alone then gives 0 results, and the second full run (375 contracts, 97 detectors) gave 0 results.

Sizes against the 24,576-byte limit, with S2 in brackets: `IntentToken` 17,855 (17,778), `Gated4626Vault` 18,449 (18,375), `Gated7540Vault` **23,548** (23,479), headroom 1,028. The base grew about 70 bytes (`_accountReason`); the vaults' probes got lighter and nearly paid for it. `HolderRestrictionRule` 3,180, `MinPositionRule` 2,779.

**Gas, and a flag about the numbers.** Same probe as before (transfer of 0.1 token, every account cold), on forge 1.8.1. The absolute numbers in the S1 and S2 commit messages do not reproduce today: the same probe on the S2 commit (`6709889`) gives 108,336 for identity, lockup and fund, against the 63,604 reported, and 129,252 for the four rules, against 82,020. About 27,000 of each figure is outside the token's own frame (the proxy and the cold accesses around it, constant across rule sets); the token's frame alone is 81,122 and 102,038. I could not find why the earlier figures were lower (the probe file is the same; I suspect a different forge version or a harness detail). The deltas between rule sets are what the decisions used, and they hold: below, S2 and S3 are measured side by side now. Inside the token's frame:

| Rules, in order | Gas | Step |
|---|---|---|
| S2: identity, lockup, fund | 81,122 | |
| S3: identity, restriction, fund | 84,549 | +3,427 (the receiver's word; the freeze) |
| + `MinPositionRule`, minimum off | 93,757 | +9,208 |
| the same, minimum on | 95,295 | +1,538 |
| + `MaxHoldersRule` (a class with its own cap) | 116,211 | +20,916 |

The demo class set of the assumptions (identity, minimum, restriction, fund) costs 95,295 against S2's 81,122: +14,173 (17%), of which 10,746 is the minimum rule. **A rule that is off still costs 9,208**: the call, the context it is handed, a cold account and a cold read. The rule list is per token, so a token that does not want a minimum should leave the rule out; the list is S4's decision (assumption 1 puts the rule in all three classes).

**Decisions for you.**

1. **The probes.** The change above (`canReceive` for the mint side, cap-aware counting rules, a zero-amount burn probe). It touches the vaults, which the plan listed for S5 at most, and reverses my S2 position on `canReceive`. The alternatives are above.
2. **Where `MinPositionRule` is listed (S4).** In all three demo classes as assumption 1 says (+10.7k a transfer with the minimum on, 9.2k when off), or only in the classes that set a minimum. A token's list is its own, so this is a deployment choice, not a code one.
3. **The Credential layer plan** (the other session) does not mention `checkSend` or `checkReceive`. `BaseRule` answers OK to both, so `canSend`, `canReceive` and the vaults' `max*` would say yes to an account that `CredentialRule` refuses in `check`. The rule has to override them, without an amount.

### S4 as built (2026-10-24, committed `ed8471f`)

The fund's monitor, the rule lists of the demo deployment and the post-deploy check. What changed:

- **`Fund.isClassIntact(token)` and `Fund.firstBrokenClass()`** (RD10). A class is intact when it is registered and its hook still lists the fund's installed rule. `firstBrokenClass()` returns the first class that is not, in registration order, or the zero address; it loops over at most 32 classes. Neither reverts: a token that cannot name its hook, or a hook that cannot list its rules, is a broken class (try/catch around both calls), so the call that says which class is broken cannot be stopped by the broken class. The views cover the three ways a class stops being capped or starts failing closed: the fund rule dropped from a class's list (the runbook's forbidden step, reproduced in `FundIntegration_Integrity` and in a timelock test), the rule replaced in the fund while the lists still name the old one (every class is broken until its hook lists the new rule, and the monitor walks down the classes as each is fixed), and a hook swap to a hook that does not list it. They prevent none of it: nothing in the hook can know about the fund. `IFund` is re-pinned, `0x44c4a64f` to `0x2d89d7d8`; no event changed.
- **The demo rule lists** (RD5 and assumption 1). Intent token: identity, minimum position, holder restriction, settlement window, fund holders. Both vaults: identity, minimum position, holder restriction, fund holders. No `MaxHoldersRule` on any class. `deployment.test.ts` writes the order out; it does not read it from the module.
- **Ignition.** `Components` deploys `MinPositionRule`. `MaxHoldersRule` is still deployed and attested, and listed on no token, so governance can add it to a class that has a limit of its own without another council step; it is one line to drop. `Activate` takes `intentMinPosition`, `fundMinPosition` and `asyncFundMinPosition` (0 by default, which switches the rule off) and sets each before the hand-over. The per-class cap and the escrow exemption are gone from `Activate` and from the fixture's parameters (`holderCap`, `maxHoldersRule`): the 7540 vault is the token itself, which neither the fund rule nor the minimum counts.
- **Post-deploy check** (`assertHandedOver`, the one the runbook prescribes). It still pins each hook's list. It now also asserts that every class is intact and that `firstBrokenClass()` is the zero address.
- **Tests first, red runs shown.** The Solidity run failed to compile against a `Fund` without the views; with the views in, the Node run still failed on Ignition (the fixture could not build: no `minPositionRule`), which took nearly every stack test with it. Solidity runner 906 passing (was 890), Node runner 95 (was 92): the decided order, a deployment that sets minimums and enforces one, and the dropped rule through the timelock.
- **Mutation checks.** Eight planted bugs in the new `Fund` views (an unregistered token passing, the registration ignored, the first or last class skipped, a failing hook or token counted as listed, the wrong comparison, the last broken class returned instead of the first): all eight fail a test.

Gates on the working tree: `forge fmt --check`, `solhint --max-warnings 0`, `tsc --noEmit`, `validate:upgrades` (3 of 3), Aderyn 0 (the empty `catch` blocks carry inline suppressions with their reason), Halmos 16 of 16, reproducibility (17 contracts), Slither 0 results (377 contracts, 97 detectors).

**Gas, measured as whole transactions on the deployed stack.** A new probe, not in the repo: the stack is deployed through Ignition, an ordinary transfer of a tenth of a token between two holders is sent as a real transaction, and `gasUsed` is read from the receipt (21,000 of intrinsic gas included). The same probe ran on four commits, each in a copy of its own tree, on Hardhat's in-process node. This is not comparable to the inside-the-token-frame table in S3 (which leaves out the intrinsic gas and the proxy).

| Deployed stack | Intent token transfer | 4626 share transfer |
|---|---|---|
| Before the review items (`7536ec2`) | 144,700 | 138,001 |
| S2 (`6709889`) | 135,463 | 128,526 |
| S3 (`58fdb7b`) | 138,890 | 131,953 |
| S4 (working tree) | 127,204 | 120,290 |

S4 is 17,496 gas (12.1%) below the stack before the review items for the intent token and 17,711 (12.8%) for the 4626 share, while it adds the address freeze, the minimum position (off) and the account-level answers. The steps agree with the S3 probe: S3 added 3,427 to each (the receiver's word); S4 removes `MaxHoldersRule` (about 20,900) and adds `MinPositionRule` (9,208 even when off), a net of 11,700 less. S0 to S2 together are 9,237 below the start (the balance callbacks moved into the context). What would save most now is a deployment choice: a token that wants no minimum can leave `MinPositionRule` out of its list (9,208 a transfer).

Sizes: `Fund` 6,012 bytes (limit 24,576).

**The outside review of S2 and S3, checked against the code.** It was mostly praise; the claims that carry weight:

| Claim | Result |
|---|---|
| The two S2 fixes work as described: the enforcement-burn bound in `_availableToMove` and `_check`, and `ERC7943InsufficientUnfrozenBalance` only on a real shortfall in `_update` | True, and the code is as quoted. One note: the "previously" state existed in the S2 working tree only; no commit ever held it |
| `HolderRestrictionRule` reads one word for the sender and answers the freeze and the lockup from it; the role is asked only for a burn while a lockup runs | True (`vm.load` pin at `HolderRestrictionRule.t.sol:209`) |
| `MinPositionRule` cannot overflow or underflow, and asks for the exemption and the role only once a position would breach | True |
| "Backed by 16/16 Halmos symbolic proofs" | Overstated. 16 is the whole suite; three properties are about `MinPositionRule`. `HolderRestrictionRule` has none: it has no arithmetic beyond its checked 64-bit cast |
| "Formally verified across all 5 `TransferKind`s" | Partly. Never reverting is proven for all five kinds. The exact decision is proven for TRANSFER, with balances constrained so the sums fit; MINT, BURN and EXECUTED rest on unit and fuzz tests |
| 23 of 24 mutants killed | True; the 24th is equivalent |
| `canSend` is true during a lockup while every holder-driven move is refused with `LOCKED` | True, and by design (RD4 puts the lockup in `check` only). It is what an integrator reading `canSend` gets wrong, so it is decision 4 |
| `Gated4626Vault.maxRedeem` probes zero "because" the lockup sits in `check(BURN)` | The conclusion is right, the reason is half of it. The zero amount is for the minimum (one share leaves dust); that the probe is a burn and not `canSend` is for the lockup |
| `CredentialRule` must answer `checkSend` and `checkReceive`: sender `ACTIVE`, `EXIT_ONLY` or `LAPSED`, `NONE` and `BLOCKED` refused with `SENDER_NOT_VERIFIED`; receiver eligible | Matches the Credential plan's table. The receiver's reasons are three, not one: `RECEIVER_NOT_VERIFIED`, `CREDENTIAL_EXPIRED`, `RECEIVER_NOT_ELIGIBLE` |
| Reference `IHolderRestrictionRule.sol#L13` | It is line 12 |

**Decisions for you.**

1. **`MinPositionRule` in all three classes, off by default** (assumption 1), costing 9,208 a transfer. The alternative is to list it only on the classes that will set a minimum; a class can be given the rule later through `setRules` (a timelock operation), so leaving it out is reversible.
2. **`MaxHoldersRule` deployed and attested but unlisted.** It spends one deployment and one attestation to save a council step later. Dropping it from `Components` and the council step is one line each.
3. **`Activate` sets the minimums.** The alternative is to set none at deployment and leave it to the timelock (seven days). The default of 0 means a deployment that sets nothing behaves as before.
4. **`canSend` and the lockup** (done, as a separate commit after S4: see "Decision 4 as built"). Today a locked holder reads `canSend` true and every movement of theirs is refused. The freeze already sets the precedent for the fix: it is in `checkSend` although FORCED passes it. Putting the lockup in `checkSend` as well (the holder's word is already read, so no new read) makes `canSend` say `LOCKED` for exactly the movements `check` refuses; FORCED and the enforcement burn stay exempt in `check`. It contradicts RD4's sentence that the lockup stays in the transfer check, which is why I have not done it. I recommend it: one line and a test, and it makes the standard's account question truthful during a lockup.

### Decision 4 as built: the lockup in `HolderRestrictionRule.checkSend` (2026-10-24, committed `f3a8295`)

You accepted the recommendation in decision 4 of the S4 record and asked for it as a commit of its own after S4. What changed:

- **`checkSend(token, account)`** returns `SENDER_FROZEN` for a frozen account, then `LOCKED` while `block.timestamp < unlockTime`, and `TRANSFER_OK` otherwise: the same order as `check`. It reads the holder's one word and asks the token for nothing. `checkReceive` is unchanged: a locked account can still be paid.
- **Effect.** `canSend` says `LOCKED` during a lockup, in agreement with `canTransferWithReason` and with the 4626 `maxRedeem`, which was already 0. Nothing else asks `checkSend`: the vaults ask `checkReceive`, so no vault behaviour moved, and a transfer's gas does not move (the answer is off the hot path).
- **The one gap that stays**, the one `IComplianceRule` allows: `check` still passes FORCED and an enforcement burn for a locked holder, because the movement decides those. A test pins it, as the freeze already has the same gap for FORCED.
- **Amends RD4's sentence** "the lockup stays in the transfer check because it depends on the kind". The lockup is now in both; the transfer check still applies the exemptions by kind. `IHolderRestrictionRule` NatSpec is amended; no interface id changes.
- **Tests first, red run shown:** seven failed (`TRANSFER_OK` where `LOCKED` was expected): the new unit tests (locked, the unlock second, cleared, frozen and locked together, no role asked, the allowed gap, and the fuzz that now includes a locked sender), the real token's `canSend` and `canReceive` around a lockup, and the 4626 vault's `canSend` next to `maxRedeem`; the TypeScript lockup test asserts the same on the deployed stack. Six planted bugs (lock ignored, `<=` at the boundary, lock before freeze, freeze ignored, `checkReceive` refusing a locked account, the comparison reversed): all six fail a test.
- **Gates:** Solidity runner 911 passing (was 906), Node runner 95; `forge fmt --check`, `solhint --max-warnings 0`, `tsc --noEmit`, `validate:upgrades` (3 of 3), Aderyn 0, Halmos 16 of 16, reproducibility (17 contracts), Slither 0 results.
- **For S5:** the docs say `canSend` is false for a frozen or a locked holder, and that it does not answer for the enforcement routes (`forcedTransfer`, a `BURNER_ROLE` burn), which pass `check` for both.

### S5 as built (2026-10-24, committed `d901045`)

The documentation, brought in line with the code of S0 to S4 and the `checkSend` change. What changed:

- **`CLAUDE.md` (the brief):** the hook is shared (§1, §6), rule 4 notes the interfaces were reopened once, rule 7 is amended (policy rejections are `PolicyGated_TransferRejected`, the token's own frozen shortfall is `ERC7943InsufficientUnfrozenBalance`), the repo layout, §4 (`IERC7943Fungible`, the new `IPolicyGated`, the freeze arithmetic, `multicall`, `templateId`, the registry enforcement points), §5 (`TransferContext.extra`, `checkSend` and `checkReceive`, the account-level answers, the appended reason codes), §6 (topology, the dispatcher, the demo lists, `HolderRestrictionRule`, `MinPositionRule`, `MaxHoldersRule` as available and unlisted, the fund monitor), §7 (the `max*` probes, the 7540 escrow and the below-minimum claim) and §8.
- **`README.md`:** the architecture block, the security-model table and bullets, the deployment runbook rewritten for two modules and one council step (the `Tokens` stage and the second council step are gone), the deviations (ERC-7943 Final, interfaces reopened once, two known departures from the standard's text).
- **`SECURITY.md`:** scope, items 1 and 3 of "things that differ" (a token's address is fixed by its symbol; a hook's attestation covers its code, not any token's list), new limits (dropping the fund rule, account-level answers, the pause, the two ERC-7943 departures, a burner's own burns, a frozen remainder below the minimum, a below-minimum 7540 claim), the suppression tables, and the mutation results of this series.
- **`docs/`:** all nine pages. New sections: the incident runbook, the monitor, setting a minimum position, adding `MaxHoldersRule` to a class later, `HolderRestrictionRule`, `MinPositionRule`, "Vaults as fund classes", "Account-level questions", "During a pause". The anchors other pages link to were kept.
- **How it was checked.** A change ledger written from the code; four page writers working from it; a scripted check (stale terms, links, anchors, Mermaid hazards: clean except the intended mentions); five independent verifiers, one per group of pages, each checking every changed sentence against the code. Three statements were wrong (a reference to a `PLAN.md` entry that did not exist yet, a "no test covers it" for a test added minutes before, and an unqualified `redeem(maxRedeem)` claim); the verifiers also found about 40 overstatements, omissions and naming slips. All are fixed; the ones that could not be settled by reading (the ERC-3643 reference token, gas figures, mutation counts) stay marked as such. A second verifier then checked the rewritten sentences and found seven more (a count of "two gaps" between a rule's account answer and its `check` where the rule's own exemptions are the other part, "no rule reads a balance from the token" without "on the movement path", and the like); they are fixed too. Examples: "the one allowed gap" when there are two, "every movement is rejected with `NOT_FUND_CLASS`" when an earlier rule or the pause answers first, a lockup recommended for a quarantine account that a vault exit would trip on, and a `maxRedeem` that overstates when a frozen remainder below the minimum would stay. The last of these is now pinned by a test (`test_WhenAFrozenRemainderBelowTheMinimumWouldStay_RedeemingAllOfMaxRedeemReverts`), the one change outside the documents.
- **Gates.** Solidity runner 912 passing (was 911, the added test), Node runner 95; `forge fmt --check`, `solhint --max-warnings 0` and `tsc --noEmit` clean. Nothing else in the code changed, so Slither, Aderyn, Halmos, `validate:upgrades` and the reproducibility check stand as at `f3a8295`.
- **Not done, or not re-measured.** The amendment to the draft ERC for RD2 lives in `~/dev/urwa-policy`, a different repository, and is not done. The DvP gas figures in `docs/flows-dvp.md` and the `seedHolderCountFromHolders` figures in the governance page predate the shared hook and are marked as such. The ERC-3643 reference token paragraphs rest on the 2026-10-23 check recorded in RD9; they say so, and say that the ERC-3643 text itself was not checked.

**The latest outside review (architecture and code), checked.**

| Claim | Result |
|---|---|
| The shared hook, balances in `extra`, the 7943 face, the template id and the fund views are as decided | True |
| `wantsAfter()` is keyed by `msg.sender`, so an off-chain caller gets an empty answer; `wantsAfter(token)` would be the honest signature | True and harmless. Worth doing only if the interface is reopened again |
| The base imports `IComplianceHook` to read `REGISTRY()` | True: a small layering leak from the base to one hook interface |
| 1. `canReceive` and `canTransfer` disagree at a full cap, and 7943 forbids quantitative rules in `canSend` and `canReceive` | **True, and my S3 change caused it.** ERC-7943 Final says `canTransfer` "MUST perform a `canSend` check on the `from` parameter and a `canReceive` check on the `to` parameter", and that `canSend` and `canReceive` "MUST NOT encode transfer-specific or quantitative rules (e.g., balance checks, amount limits)". A holder cap is a count, which the standard does not mention, so the second point is a defensible reading and not a certain one. The first is certain: at a full cap a full-balance transfer to a new holder passes `canTransfer` while `canReceive` says false. S2 had it right (the cap was a decision about a movement) and S3 broke it to keep the vaults' `max*` from overstating |
| 1, option (a): drop the cap from `checkReceive` and accept that `maxDeposit` overstates at a full cap, as it does for a minimum | The comparison does not hold. A minimum makes only small deposits fail; a full cap makes every deposit by a new investor fail, so `maxDeposit` would exceed what `deposit` accepts, which ERC-4626 forbids |
| 2. An address freeze blocks an enforcement burn, a lockup does not | True, and decided (RD4): the way out of a frozen account is `forcedTransfer` to a quarantine account. It is documented in the brief, the README, the governance page and `SECURITY.md`. No change |
| 3. `_takesFrozenTokens` asks `BURNER_ROLE` in the base, duplicated in two rules, and a burner redeeming through a vault can redeem frozen shares | Half true. The role is asked in the base and in both rules. The vault claim is false for frozen tokens: `maxRedeem` stops at the unfrozen balance, so a probe of a burner holding frozen shares failed with `ERC4626ExceededMaxRedeem`. It is true for a lockup and the minimum: the same probe had a locked burner redeem in full. That is now a limit in `SECURITY.md`. A flag announced by `burn()` would also have to reach the rules, which means a new field in `extra` |
| 4. A balance shortfall reverts with the 7943 error, and `canTransfer` returns false for it; 7943 leaves balance validation to the base | **True.** ERC-7943 Final: `canTransfer` "MUST NOT return false based on token-specific, non-permissioned validations such as balance or allowance checks", and `ERC7943InsufficientUnfrozenBalance` is for an amount at or below the balance, with "more specific errors from the base standard" when the amount exceeds it. Here an amount above the balance reverts with the 7943 error and makes `canTransfer` false. The draft ERC repository adopted the conformant reading on 2026-10-23 (Phase 0.7, `e75e5ee`), so the two now disagree |
| 5. `MinPositionRule` costs about 9.2k when off | True, and in the plan and the docs. Nothing to change in code |
| 6. `Gated7540Vault` has 1,028 bytes of headroom, from 3,030 | True. The via-ir fallback it leaned on does not exist: measured on 2026-11-02, via-ir makes the 7540 bigger (27,895 bytes against 24,320) |
| 7. The docs were stale | True before this step; this step |
| The suppressions are justified by the test that pins them | Mostly: each has its reason on the line above, not all name a test |

I did not change the code for findings 1, 3 and 4. Each is a decision that reopens something you decided or touches many tests, and 1 and 4 each have more than one fix. The README and `SECURITY.md` now state both departures from the standard plainly, and `docs/README.md` says the pages follow the code.

**Decisions for you.**

1. **Finding 1, `canReceive` and the cap.** Options: (a1) take the cap out of `checkReceive` in both counting rules, so `canReceive` is eligibility only (identity, freeze, fund class), and give the vaults' mint-side probes a mint of a very large amount instead of `canReceive`: the minimum cannot read as a block (the amount clears it), a new investor at a full cap still reads as refused, and the standard's account question stays clean; the cost is that a future rule bounding a position's size would zero `maxDeposit`, and a rule author would have to know. (b) keep the cap in `checkReceive` and remove the net-zero exception, so `canTransfer` and `canReceive` always agree: a strict ratchet, which also stops a holder moving a whole position to a new wallet at a full cap, a use `MaxHoldersRule` was built to allow. (c) leave it and keep the documented departure. I recommend (a1).
2. **Finding 4, the balance shortfall.** Follow the standard: `canTransfer` stays true for an amount above the balance when nothing is frozen, and false when a frozen amount stands in the way; a plain transfer above the balance reverts with the base's `ERC20InsufficientBalance`; `canTransferWithReason` keeps full parity and says `INSUFFICIENT_UNFROZEN` for it, so "pre-flight never lies" stays true for the function that carries a reason. It changes S2's behaviour and the tests that assert the 7943 error for an amount above the balance (Solidity, TypeScript, one Halmos property). I recommend it, as its own step with the red run first.
3. **Finding 3.** Leave as it is and document it (done), or add a flag. I recommend leaving it.
4. **The draft ERC amendment for RD2** (`~/dev/urwa-policy`): do it now, in that repository, or leave it until RD2's other consequences are settled.

### Finding 1 as built: the holder cap leaves `canReceive` (2026-10-24, committed `1f7b8fc`)

Your option (a1) for finding 1 of the outside review, built as the first of two separate steps (finding 4 is the second). The review was right that my S3 change had made `canReceive` and `canTransfer` disagree: ERC-7943 Final says `canTransfer` "MUST perform a `canSend` check on the `from` parameter and a `canReceive` check on the `to` parameter" and that `canSend` and `canReceive` "MUST NOT encode transfer-specific or quantitative rules". What changed:

- **The cap is `check`'s alone.** `MaxHoldersRule` no longer overrides `checkReceive` (the `BaseRule` default accepts). `FundHoldersRule.checkReceive` answers what `checkSend` answers, `NOT_FUND_CLASS` for a token that is not a registered class or when the rule is not the fund's installed one. A new holder or investor at a full cap is eligible at account level (`canReceive` true); a mint or a partial transfer to it is refused by `check` with `MAX_HOLDERS`; a full-balance transfer to it passes (net zero), and `canReceive` agrees, so for a plain transfer through the shipped rules `canTransfer` is not true while `canReceive` is false.
- **The vaults probe a mint again, of a very large amount.** The base has `_mintProbe(receiver)`, which is `_canTransfer(address(0), receiver, _MINT_PROBE)` with `_MINT_PROBE = type(uint128).max`. `Gated4626Vault.maxDeposit` and `maxMint`, and `Gated7540Vault.requestDeposit`, `maxDeposit`, `maxMint` and the deposit-claim check use it, in place of the account question of S3. The amount is not zero, so a holder cap sees a new holder and refuses it (`maxDeposit` is 0 for a new investor at a full cap, as ERC-4626 requires), and it is above any minimum position up to `type(uint128).max`, so such a minimum does not read as a block. `maxRedeem` and `maxWithdraw` are unchanged (a burn of nothing). The internal `_accountReason` is gone; `canSend` and `canReceive` are built from the hook's `checkSend` and `checkReceive` as they were in S2.
- **A limit you should know.** A rule that bounded the size of a position (a supply cap, a maximum balance) would refuse the probe and zero `maxDeposit` and `maxMint`. None of the shipped rules does, and a rule author has to know: the NatSpec of `_mintProbe`, `IGated4626Vault` and `IComplianceRule` say so.
- **NatSpec** (no interface id changes): `IComplianceRule.checkReceive` and `checkSend` say an account answer must not depend on an amount or encode a quantitative rule (the "one allowed gap" is gone); `IMaxHoldersRule`, `IFundHoldersRule`, `IMinPositionRule` and `IGated4626Vault` follow.
- **Tests first, red run shown.** Written against the cap-aware code: the account tests of both counting rules failed (`MAX_HOLDERS` where `TRANSFER_OK` was expected), the integration test of a full cap failed, a fuzz of `canTransfer` against `canSend` and `canReceive` over cap, freeze, lockup and identity found "canTransfer without canReceive" (a full-balance transfer to a new holder at a full cap), and the vault unit tests failed once their hook stubs no longer answered `checkReceive`. After the change 514 tests of the affected suites pass. In TypeScript, `parity.test.ts` asserts `maxDeposit` against the mint probe again, and `fund.test.ts` asserts `canReceive` stays true at a full fund cap.
- **Mutation checks:** 11 of 11 planted bugs killed, each by at least one test (`mutate_f1.py` in the session scratchpad): the probe amount one wei, and zero; `Gated4626Vault.maxDeposit` probing one wei; `maxMint` of the 4626 vault, and `requestDeposit`, `maxDeposit` and the deposit-claim check of the 7540 vault, each ignoring the probe; `FundHoldersRule` and `MaxHoldersRule` each answering the cap in `checkReceive` again; `canReceive` ignoring pause; the mint probe asking the sender side. `SECURITY.md` has the row, and marks the S3 row as superseded for the cap and the probe.
- **Gates, on the final tree (after the verifier's corrections):** Solidity runner 906 passing (was 912: 13 tests that asserted the cap in `checkReceive` are removed and 7 that assert it is not are added), Node runner 95; `forge fmt --check`, `solhint --max-warnings 0` and `tsc --noEmit` clean; `validate:upgrades` 3 of 3; Aderyn 0; Halmos 16 of 16; reproducible, 17 contracts identical across two builds; Slither 0 results (377 contracts, 97 detectors).
- **Docs.** `CLAUDE.md` (§5, §6, §7), `README.md` (the security-model bullet; the first of the two departures from the standard is removed, one remains), `SECURITY.md` (the account-level bullet, the departure bullet, the new limit) and five `docs/` pages say what the code now does. A verifier checked the changed sentences against the code; its first round found two stale sentences in `CLAUDE.md` (one said `checkReceive` still adds the fund cap) and eight overstatements, for example "never true while either answer is false" (an enforcement burn passes for a locked holder while `canSend` says `LOCKED`), "clears any minimum" (a minimum above `type(uint128).max` would refuse the probe) and a mutation-table row that still described the old account answers. All are corrected.

**Left for you.** Finding 4 (the balance shortfall) is the next step, as its own commit. Nothing else changes.

### Finding 4 as built: a balance shortfall follows ERC-7943 (2026-10-25, committed `a4f237d`)

Decision 2 of the second outside review, built as the second of the two separate steps. ERC-7943 Final, fetched again on 2026-10-24: `canTransfer` "MUST validate that the `amount` being transferred doesn't exceed the unfrozen amount (which is the difference between the current balance and the frozen balance)" and "MUST NOT return false based on token-specific, non-permissioned validations such as balance or allowance checks"; `ERC7943InsufficientUnfrozenBalance` is for an amount "less than or equal to its balance, but greater than its unfrozen balance", and for an amount above the whole balance "more specific errors from the base standard SHOULD be used instead". The two MUSTs collide when nothing is frozen and the amount is above the balance: the first would say false, the second forbids it. I resolved it the way the draft ERC's reference does (`ExampleToken._tokenCheck`, Phase 0.7): the unfrozen validation applies while something is frozen, and with nothing frozen the balance is left to the base. What changed, all in `PolicyGatedERC20Upgradeable`:

- **The write.** A shortfall found by the token's own check reverts `ERC20InsufficientBalance(from, balance, amount)` when the amount is above the whole balance, frozen or not, and `ERC7943InsufficientUnfrozenBalance` when it is within the balance but above the unfrozen balance. `forcedTransfer` and an enforcement burn already reverted the base error above the balance, through `_releaseFrozen`. Policy rejections are unchanged.
- **`canTransfer` (the bool).** `_canTransfer(from, to, amount, false)`: a shortfall counts only when a frozen amount stands in the way, meaning `frozen > 0` for the sender and the movement is not one that may take frozen tokens (FORCED, or a burn whose operator holds `BURNER_ROLE`, which is what a pre-flight with a burner as sender models). A pure balance shortfall is ignored and the hook decides as usual, with the amount above the balance as given. So with nothing frozen an amount above the balance reads true when the hook accepts it; with something frozen an amount above the unfrozen balance reads false, above the balance too; a hook rejection reads false whatever the amount.
- **Unchanged.** `canTransferWithReason`, `canExecute`, the vault `max*` probes and the 7540 checks count every shortfall (`_check(ctx, hook)` keeps its meaning), so "pre-flight never lies" holds for them. The one place the two pre-flights differ is a pure balance shortfall: `canTransfer` true, `canTransferWithReason` `(false, INSUFFICIENT_UNFROZEN)`. I kept the reason code `INSUFFICIENT_UNFROZEN` for it rather than appending a new one, as you decided.
- **The shipped rules tolerate an amount above the balance** (`MinPositionRule` compares before it subtracts, the counting rules compare for equality), which `canTransfer` now relies on: it must not revert. A fuzz over amounts and minimums pins it for the five rules of the integration list; it does not cover `FundHoldersRule`, whose check also compares for equality.
- **No interface change.** `IPolicyGated` NatSpec only; `InterfaceFreeze.t.sol` passes.
- **Tests first, red run shown.** 11 failed against the code of `1f7b8fc`: the base error expected above the balance (the unit fuzz, the integration test with the real rules, the intent, the DvP trade with a buyer short of cash, and its both-legs variant), `canTransfer` expected true above the balance (the base unit tests, the burner pre-flight tests, the integration fuzz, the TypeScript test), and the table fuzz over frozen amount, amount and hook (it found "false != true" for nothing frozen and an amount above the balance). Three new tests pass before and after, because they pin what must not change: a hook rejection, a frozen amount, and the real rules' rejections still make `canTransfer` false. Three existing tests asserted the old rule and were not in the red run, since they passed against the old code; the green run found them and I changed them: the intent token's pair test (now `canTransfer` equals `canSend` and `canReceive`, and the reasoned answer adds the balance), the base invariant on the unfrozen boundary, and the TypeScript test of the account answers.
- **Mutation checks:** 11 of 11 planted bugs killed, each by at least one test (`mutate_f4.py` in the session scratchpad, run against the unit, integration, intent, DvP and vault suites): the write never using the base error; using it at the balance too; using it for every shortfall; `canTransfer` counting a pure balance shortfall; `canTransferWithReason` leaving it to the base; the frozen amount ignored in `canTransfer`'s test; another account's frozen amount asked; enforcement kinds not excluded; the ignored shortfall skipping the hook; the shortfall boundary moved to `<=`; the strict `_check` made lenient (killed through `canExecute`). `SECURITY.md` has the row.
- **Size.** `IntentToken` 17,778 to 17,945 bytes, `Gated4626Vault` 18,399 to 18,552, `Gated7540Vault` 23,495 to 23,661 (margin 915 of 24,576). Gas of a successful transfer: not measured; its path gains one internal call.
- **Gates, on the final tree (after the verifier's corrections):** Solidity runner 915 passing (was 906: nine added), Node runner 96 (was 95: one added); `forge fmt --check`, `solhint --max-warnings 0` and `tsc --noEmit` clean; `validate:upgrades` 3 of 3; Aderyn 0; Halmos 16 of 16 (its properties do not name the revert error); reproducible, 17 contracts identical across two builds; Slither 0 results (378 contracts, 97 detectors).
- **Docs.** `CLAUDE.md` (rule 7, §4, §5), `README.md` (the security-model bullets, the deviations: "one known departure" is replaced by the difference between the two pre-flights), `SECURITY.md` (the same bullet, a new mutation row) and seven `docs/` pages say what the code does. A writer agent updated `docs/`; an independent verifier derived the truth table from the code and checked the diff. It found, and I corrected: two stale sentences in `MinPositionRule` (its NatSpec and a test comment said the token refuses a sender short of the amount before the hook is asked, which `canTransfer` no longer does), the qualifier "with nothing frozen" in several places (it is also true for a burn by a `BURNER_ROLE` sender with something frozen), a `SECURITY.md` sentence that was wrong for that burner, "as the standard requires" for the `frozen > 0` boundary (the standard does not say which clause wins above the balance, so the prose now says it follows the draft ERC's reference and that a one-unit freeze flips the answer), "canTransfer cannot" overstated against other known differences between the pre-flights and the write, a 4626 `redeem` or `withdraw` that is stopped by `maxRedeem` or `maxWithdraw` before the token's error, and two test names. It also found that only `canTransfer` hands the hook an amount above the sender's balance, so a rule author must know; `CLAUDE.md` §6, the `IComplianceRule.check` NatSpec and `transfer-checks.md` now say so. Left alone: `ITransferIntent.sol` (frozen interface, stale since S2) says `executeTransfer` reverts `PolicyGated_TransferRejected` carrying the reason `canExecute` returns, which is not so for a shortfall; and `CLAUDE.md` §5's "Pre-flight never lies" is an absolute that `canExecute` already breaks in small ways (it does not check the executor role, the zero `to` or the time of a later block). Neither is new.

**Left for you.** Nothing else in the review items. Open: the draft ERC amendment for RD2 in `~/dev/urwa-policy` (not done), and the Credential-layer plan, which still lacks `checkSend`/`checkReceive`. Finding 3 stays as it is.

### Not in this plan

A `JurisdictionRule`, amount-level lockups, an ERC-3643 read adapter, ERC-1066 style reason codes, a recovery address for identity re-keying. The assessment calls them secondary, and none of them changes what the items above build.
## Credential layer: `CredentialRegistry` plus `CredentialRule` (track A; planned 2026-10-23; C-1 committed and ported, C-2 built and awaiting review)

Source: [the assessment](docs/superpowers/specs/2026-10-23-credential-layer-assessment.md) and the [three research reports](docs/superpowers/specs/research-2026-10-23/). On 2026-10-23 the owner asked for this plan using the assessment's defaults for its section 6. No code is written. Nothing here changes an existing contract's code, an existing interface id or an existing event, so the bytecode of every contract already in the manifest stays as it is.

### Goal

Today identity is one yes or no per address (`IdentityRule` over `IIdentityRegistry.isVerified`). An issuer needs to know, per address, who vouched for it, what it is (customer, professional investor, fund, licensed institution, infrastructure), until when, and its standing, and each token needs to say which of those it accepts. A holder whose credential lapses must still be able to exit.

- One small registry holds the record. One small rule applies a per-token policy to it.
- The record is written by attesters, either directly or from an EIP-712 credential the attester signed off chain. That signed record is the verifiable-credential part: W3C credentials stay off chain, the issuer's service verifies them and signs this record.
- No change to the base, `ComplianceHook`, `PolicyRegistry`, the other rules or any frozen interface. `CredentialRegistry` also answers `isVerified`, so the existing `IdentityRule` can read it unchanged.

### Where this starts

Track A touches files the DvP work has uncommitted edits in: `Errors.sol`, `InterfaceFreeze.t.sol`, `ContractSizes.t.sol`, `verify-reproducible.ts`, `Components.ts`, `roles.ts` and the docs. So it starts only after the DvP work is committed, on a new branch cut from that commit, in a `git worktree` outside `/Users/address0/dev/gated-token-stack` (one HEAD serves every session there). The baseline test count is taken at that commit and written into C-1. For reference: the committed code at `82c3c92` passes 658 (590 Solidity, 68 TypeScript), which I ran from a clean export on 2026-10-23. The DvP session records 792 (707, 85) on its working tree, which I have not re-run.

### Assumptions

C1 to C12 are the assessment's defaults. Say which you want changed.

| # | Assumption | Why |
|---|---|---|
| C1 | One record per address. Two attesters vouching for one wallet share the one slot (see decision 12). | Keeps a check to one slot read per party. |
| C2 | The qualification bits are fixed in a shared `Quals` library (bits 0 to 7 named, 8 to 15 reserved, 16 to 31 free for a deployment). The registry never interprets them. | The meaning of a bit is a legal question, so it lives in one reviewable place. |
| C3 | `CredentialRegistry` and `CredentialRule` are immutable contracts, not proxies. A schema change means a new registry, a new rule and `setRules`. | Rule 12 for the rule. The registry follows `PolicyRegistry` and the executors. |
| C4 | The registry stores flags only. No names, no evidence hashes, no URIs, no hashes of personal data. | EDPB Guidelines 02/2025: hashes of personal data stay personal data. The link from address to person stays with the attester. |
| C5 | `validUntil` is required and non-zero for an `ACTIVE` record. There is no cap on validity. | A credential that cannot lapse is the failure seen in Securitize. A cap is arbitrary and left to the attester's process. |
| C6 | At most 64 attesters. Ids are never reused. | The rule's per-token trust is a `uint64` bitmap. Reusing an id would revive old records. |
| C7 | Holder caps still count addresses (finding A5). Omnibus wallets and entity ids are out of v1. | Needs an entity map. Say so in anything client-facing. |
| C8 | No change for ERC-7943. | Track B (assessment decision 9). |
| C9 | The rule has no `after_` and no running state. | The pitfalls in assessment 3.2: counters by type drift and state is missed while a rule is out of the list. |
| C10 | A token's policy is set by the token's `DEFAULT_ADMIN_ROLE`, read live with `hasRole`, as `SettlementWindowRule.setWindow` does. | Same authority as the other per-token configuration. |
| C11 | `ctx.operator` is used only to test `BURNER_ROLE` on a `BURN`, as `LockupRule` does. A spender is never checked. | Keeps pre-flight honest. Same documented caveat as `LockupRule`. |
| C12 | `IdentityRule`, `IIdentityRegistry` and `MockIdentityRegistry` stay as they are and stay supported. | External ERC-3643 style registries still plug in through them. |

### Design

**`CredentialRegistry`** (immutable, `AccessControl`, `EIP712`, `ERC165`, `ICredentialRegistry`, `IIdentityRegistry`). Roles: `DEFAULT_ADMIN_ROLE`, `GUARDIAN_ROLE`, `RECOVERY_ROLE`. Constructor `(admin, guardian)`, administered by the deployer until `Activate` hands over, as `IntentExecutor` is.

Record, one slot, 25 bytes used: `validUntil` (`uint64`), `status` (`uint8`), `quals` (`uint32`), `country` (`uint16`, ISO 3166-1 numeric), `attester` (`uint8`), `issuedAt` (`uint64`), `guardianBlock` (`bool`).

Status values: `NONE`, `ACTIVE`, `EXIT_ONLY`, `BLOCKED`, `LAPSED`. `LAPSED` is only ever returned by `profileOf`, never stored, and no write accepts it.

`profileOf(subject)` returns `(status, quals, country, attester)` with the effective status, resolved in this order:
1. never written: `NONE`;
2. `guardianBlock` set, or stored `BLOCKED`: `BLOCKED`;
3. the attester is killed: `EXIT_ONLY`;
4. stored `ACTIVE` and `block.timestamp > validUntil`: `LAPSED`;
5. otherwise the stored status.

`isVerified(subject)` is `profileOf(subject).status == ACTIVE`.

Writers:
- `set(subject, validUntil, quals, country)`: an active attester; stores `ACTIVE`, `issuedAt = block.timestamp`. `quals` must be inside the attester's allowed mask; `validUntil` must be in the future.
- `register(credential, sig)`: anyone submits an EIP-712 `Credential(subject, validUntil, quals, country, issuedAt)` signed by an attester. Checked with OpenZeppelin `SignatureChecker`, so an HSM-backed or Safe attester works through ERC-1271. Same checks as `set`, plus `issuedAt` strictly above the stored one and not in the future. The domain is name, version `"1"`, chain id and the registry address.
- `setStatus(subject, status)`: the record's own attester; `ACTIVE` (only while `validUntil` is in the future), `EXIT_ONLY` or `BLOCKED`. Sets `issuedAt = block.timestamp`, so an older signed credential cannot overwrite it.

Guardian (stop only, no delay): `blockSubject(subject)`, `killAttester(id)`.

Admin, a timelock after hand-over: `addAttester(account, allowedQuals)` (returns the id), `setAttesterAccount(id, account)` (key rotation without reissuing), `setAttesterQuals(id, allowedQuals)` (affects only later writes), `killAttester(id)`.

Admin or recovery (decision 11): `clearGuardianBlock(subject)`, `reviveAttester(id)`. `RECOVERY_ROLE` may also revoke `GUARDIAN_ROLE` and nothing else, the same override the tokens and executors have.

Events on every state change (rule 16): `CredentialSet`, `StatusSet`, `SubjectBlocked`, `SubjectUnblocked`, `AttesterAdded`, `AttesterAccountSet`, `AttesterQualsSet`, `AttesterKilled`, `AttesterRevived`.

**`CredentialRule`** (immutable, `BaseRule`, `ICredentialRule`). Immutable: `REGISTRY`. `ruleId` is `keccak256('CredentialRule.v1')`. `wantsAfter` is false. The council attests it as RULE.

Per-token policy, one slot, set by `setPolicy(token, requireAll, requireAny, forbidAny, attesters)`: three `uint32` masks and a `uint64` attester bitmap. A record is *eligible* for a token when: the status is `ACTIVE`, the attester's bit is in `attesters`, `quals & requireAll == requireAll`, `requireAny == 0` or `quals & requireAny != 0`, and `quals & forbidAny == 0`. `attesters == 0` means unconfigured, which admits nobody.

| Kind | Sender must be | Receiver must be |
|---|---|---|
| `TRANSFER`, `EXECUTED` | `ACTIVE`, `EXIT_ONLY` or `LAPSED` | eligible |
| `MINT` | none | eligible |
| `BURN` from a holder or a vault | `ACTIVE`, `EXIT_ONLY` or `LAPSED` | none |
| `BURN` whose operator holds the token's `BURNER_ROLE` | none | none |
| `FORCED` | none | eligible |

The role lookup for the enforcement burn happens only when the sender check would otherwise fail. Zero amounts are not skipped: the 7540 vault's zero-amount burn probe must still see a blocked controller. A sender that is `NONE` or `BLOCKED` gets `SENDER_NOT_VERIFIED`. A receiver that is `NONE`, `BLOCKED` or `EXIT_ONLY` gets `RECEIVER_NOT_VERIFIED`, `LAPSED` gets `CREDENTIAL_EXPIRED`, and an active receiver that fails the policy, or any receiver of a token with no policy, gets `RECEIVER_NOT_ELIGIBLE`. Unconfigured affects receivers only: a sender needs no policy, so existing holders can still exit.

**What does not change.** `PolicyGatedERC20Upgradeable`, `ComplianceHook`, `PolicyRegistry`, `ProxyDeployer`, the executors, `Fund`, the templates and the other five rules. `IdentityRule` stays in the manifest and is only taken out of the demo deployment's rule order (C-2).

### Decisions

Numbers 1 to 10 are the assessment's section 6, adopted at the owner's instruction to use its defaults. 11 to 17 came up while planning. They are my defaults, and the owner can overrule any of them.

| # | Question | Decision |
|---|---|---|
| 1 | Scope | Track A now. The tokenised-deposit needs (decimals, references, role split, supply cap, issuance switch) are track B, a separate plan. On the owner's direction of 2026-10-23 they are built as new legos around the unchanged token, not as changes to it (see "Track B, on the same pieces") |
| 2 | Lapse and kill | A lapsed credential and a killed attester give exit-only. An explicit block stops everything |
| 3 | Enforcement burn | A burn by `BURNER_ROLE` skips the sender check, unlike `IdentityRule` today |
| 4 | Forced receiver | A `FORCED` move needs an eligible receiver (stricter than JPMD) |
| 5 | Signed credential in v1 | Yes |
| 6 | Qualification bits | The eight in `Quals`; counsel reviews the wording before any issuer relies on it |
| 7 | Target chain and the Cancun EVM | Closed 2026-10-23 by the owner: Cancun and signed intents are accepted, and the code is not designed around chains that lack them. A deployment still has to confirm its chain has EIP-1153 |
| 8 | Fast emergency upgrade path | Decided by the owner, 2026-10-30: none. Upgrades keep the 7-day timelock, and the guardian can pause meanwhile |
| 9 | ERC-7943 adapter | Closed, 2026-10-30: not needed. The base implements the fungible interface directly (`0x3edbb4c4`, pinned in `InterfaceFreeze.t.sol`) |
| 10 | Omnibus and entities | Out of v1 (C7) |
| 11 | Who reverses a guardian action | The main timelock **and** the recovery timelock. The assessment said the timelock only. The guardian holds `CANCELLER_ROLE` on the main timelock and could cancel the operation that unblocks what it blocked, which is the reason the recovery timelock exists (owner decision M-1). So `clearGuardianBlock` and `reviveAttester` accept `DEFAULT_ADMIN_ROLE` or `RECOVERY_ROLE` |
| 12 | One attester overwriting another's record | Allowed only if the slot is `NONE`, the same attester wrote it, or the previous attester is killed. Otherwise it reverts. The assessment did not say |
| 13 | Reason codes | Two appended, `CREDENTIAL_EXPIRED` and `RECEIVER_NOT_ELIGIBLE`. `LAPSED` exists as a return value so the first one is accurate. `SENDER_NOT_VERIFIED` and `RECEIVER_NOT_VERIFIED` are reused |
| 14 | Demo deployment | `credentialRule` replaces `identityRule` in `RULE_ORDER` for all three tokens, and the Ignition key `identityRule` is renamed, not left as a misnomer. `IdentityRule` stays in the repo and in the manifest |
| 15 | Where the files go | `contracts/identity/CredentialRegistry.sol`, `contracts/hooks/rules/CredentialRule.sol`, `contracts/interfaces/ICredentialRegistry.sol`, `ICredentialRule.sol` and `Quals.sol`, each contract with its `.t.sol` next to it. The new `identity/` folder needs a brief edit, proposed in C-2 |
| 16 | Attester set-up at deployment | The deployer is the registry's admin until `Activate`, which adds the first attester, sets each token's policy, grants `RECOVERY_ROLE` to the recovery timelock, hands `DEFAULT_ADMIN_ROLE` to the main timelock and renounces. After that, adding an attester or changing a policy waits for the timelock delay |
| 17 | Gas stop line | Expect +11,000 to +15,000 gas per ordinary movement over `IdentityRule` (an estimate from EIP-2929 prices, not measured). Stop for review if the measured figure is more than +20,000 |

### Interfaces and the freeze

- New: `ICredentialRegistry`, `ICredentialRule`, the `Quals` library. Their ERC-165 ids, event topics, the `Quals` values and the two new reasons are pinned in `InterfaceFreeze.t.sol`.
- `Errors.sol` gets `CREDENTIAL_EXPIRED` and `RECEIVER_NOT_ELIGIBLE` appended, which the brief allows. No existing id, topic or code changes. The freeze test proves it.
- `IIdentityRegistry` is not touched. The registry's ERC-165 answers both ids.
- Errors are named `CredentialRegistry_*` and `CredentialRule_*` (rule 16).

### Tests first (rule 5: the red run is shown before each implementation)

Unit tests isolate with `vm.mockCall` and `vm.expectCall`, fuzz with `bound`:
1. `CredentialRegistry.t.sol`:
   - `set`, `register`, `setStatus` and every revert (not an attester, killed attester, quals outside the allowed mask, `validUntil` in the past or zero, `LAPSED` as an input, wrong status transition);
   - `profileOf` for each of the five resolution steps, and `isVerified` equal to `ACTIVE`;
   - the expiry boundary: the second equal to `validUntil` and the one after;
   - replay: the same signed credential twice, an older one over a newer one, an old one after a direct write, another chain id or registry address, an ERC-1271 attester, a signature by a rotated-out key;
   - a guardian block cannot be cleared by an attester, by a signed credential or by `setStatus`; both timelock paths clear it; a killed attester gives `EXIT_ONLY` and `reviveAttester` restores it;
   - the overwrite rule (decision 12) in each branch;
   - role gates on every function, `RECOVERY_ROLE` can revoke `GUARDIAN_ROLE` and nothing else;
   - ids are never reused, the 65th attester reverts.
2. `CredentialRule.t.sol`:
   - accept and each reject in the table above, for every kind;
   - an enforcement burn and a `FORCED` move against `NONE`, `BLOCKED`, `LAPSED` and killed-attester senders;
   - exit-only holder: can send, burn and redeem, cannot receive;
   - each mask on its own (`requireAll`, `requireAny`, `forbidAny`), the attester bitmap, an unset policy (receivers rejected, senders unaffected);
   - `setPolicy` only by the token's `DEFAULT_ADMIN_ROLE`, and a fake token cannot read or change another token's policy;
   - zero amounts are checked;
   - `*_TokenCallsAreStatic` and view-ness, the same guard the other rules have;
   - fuzz over kind, operator and status.
3. Integration, real hooks and the real rule set, three tokens (`IntentToken`, `Gated4626Vault`, `Gated7540Vault`):
   - `canTransfer`, `isUserAllowed` and the state-changing call agree for each outcome and each kind, with the documented burner exception;
   - 7540: a lapsed controller can claim a redemption payout, `rejectRedeemRequest` to a lapsed controller reverts and `recoverRedeemRequest` to an eligible account works, the escrow vault is credentialed with `INFRA`, `recoverClaimable` needs an eligible `to`;
   - the existing `IdentityRule` over the registry behaves as it does over `MockIdentityRegistry`;
   - the rule in a real `RuleSetIntegration` order with lockup, window and the two cap rules.
4. Invariants (stateful fuzz): `issuedAt` never decreases for an address; a record read as `ACTIVE` never has `validUntil` in the past; an address with `guardianBlock` never reads anything but `BLOCKED` until a timelock path clears it.
5. Halmos: a lapsed record never resolves to `ACTIVE`; the signed path cannot lower `issuedAt` or clear a block. Kept only if it runs on this path as the existing properties do.
6. `ContractSizes.t.sol` gets both contracts.
7. Mutation checks on both contracts in a scratch copy (never the shared tree): drop the expiry test, drop the block check, drop the `issuedAt` test, make the burner exemption unconditional, skip zero amounts, swap sender and receiver. Each must be caught.

### Gas

Measured with the harness in `docs/superpowers/specs/fund-gas-bench/` on the real contracts: an ordinary transfer, a mint and a vault claim, once with `IdentityRule` over the registry and once with `CredentialRule`, plus the cost of `set`, `register` and `setStatus`. Decision 17 sets the stop line. The numbers go into the "as built" record.

### Deployment (C-2)

- `Components`: deploys `CredentialRegistry(deployer, guardian)` and `CredentialRule(registry)`, and no longer takes `identityRegistry` as a parameter. The key `identityRule` becomes `credentialRule` here, in `Tokens`, `roles.ts` and the tests that name it.
- Council step 1 attests `CredentialRule` as RULE with the others. The council reads `rule.REGISTRY()`, the registry's code, its admin and its attester list first: the rule's codehash covers the registry's address and not the registry's code. The registry is reviewed, not attested, like `Fund` and `ProxyDeployer`.
- `RULE_ORDER`: `credentialRule` first for all three tokens, where `identityRule` was.
- `Activate`: `addAttester` for the demo KYC attester (new parameter `kycAttester`), `setPolicy` for each token while the deployer is still its admin (`requireAll = KYC`, `attesters` = that attester, which matches today's identity-only behaviour), grant `RECOVERY_ROLE` to the recovery timelock, grant `DEFAULT_ADMIN_ROLE` to the main timelock, deployer renounces.
- `assertHandedOver` gains: the registry's admin is the timelock, its recovery role is the recovery timelock, the guardian holds `GUARDIAN_ROLE`, the deployer holds nothing, and every token's policy is the intended one.
- Runbook (README and `docs/governance-and-deployment.md`): the council check above; how an attester is onboarded and rotated; never remove `CredentialRule` from a token's hook without replacing it, because a hook with no identity rule admits anyone.

### TypeScript (C-2)

`fixtures.ts` replaces the `identity.write.set` calls with a helper that has the demo attester write a credential for the holders, the recovery account and the 7540 escrow vault (with `INFRA`). The tests that use the old registry in `governance.test.ts`, `deployment.test.ts`, `parity.test.ts`, `dvp.test.ts`, `fund.test.ts` and `vaults.test.ts` keep their assertions. A new `test/nodejs/credentials.test.ts`: a real EIP-712 credential signed with viem and submitted by a third party; expiry through the real clock helper; a lapsed holder exits and cannot receive; a guardian block, and its reversal through the recovery timelock after the delay; `canTransfer` parity from the TypeScript side; event decoding. The existing tests must pass unchanged apart from the identity set-up.

### Docs (C-2)

- `docs/`: `architecture.md` (contracts table and diagrams), `roles.md` (registry roles, who holds them after `Activate`, what the guardian can do to it), `transfer-checks.md` (a `CredentialRule` section and a row in the per-kind table), `governance-and-deployment.md`, and "Checked against" in `docs/README.md`. Every edited sentence is verified against the code, and a fresh agent checks the diff afterwards.
- README: contracts list, rule order, deviations from the brief, the runbook.
- Proposed brief edits, which need your OK because the brief is the standing instruction file: §3 layout gets `contracts/identity/`, and §6 gets `CredentialRule` in the rule list and a line on the registry. `SECURITY.md` gets the attester trust assumption.

### Checkpoints and gates

- **C-1:** `Quals`, the two interfaces, the two reason codes, `CredentialRegistry`, `CredentialRule`, all Solidity tests above, the mutation run, the gas measurement, the freeze and size tests. Stop for review.
- **C-2:** Ignition, `credentials.test.ts`, the fixture changes, the docs. Stop for review.
- **Gates at each:** `npx hardhat test` in both runners with the summary line pasted, `npm run lint:sol`, `npm run fmt:check`, `tsc`, `slither .`, `npm run aderyn`, `npm run validate:upgrades`, the Halmos run, the isolated profile, and `npm run verify:reproducible` (the manifest grows from 16 to 18: `CredentialRule` under ATTESTED, `CredentialRegistry` under DEPLOYED). The 16 existing entries must be byte-identical to the base commit.
- **Attestation impact:** new `CredentialRule` (RULE) and `CredentialRegistry` (reviewed, not attested). Unchanged: every current attested contract.

### Risks

1. Attesters are the trust root. A compromised attester can credential any wallet for every token that trusts it. The limits are the per-attester allowed qualifications, the per-token attester bitmap, and the guardian's kill. There is no on-chain proof of the KYC itself.
2. The rule's codehash does not cover the registry's code (assessment A6). The council check and the runbook carry it. A registry attestation kind is a later option and needs an interface change.
3. The meaning of each qualification bit is legal. A wrongly defined bit is a misclassification. Counsel reviews `Quals` before any issuer relies on it.
4. Public flags. Even a status bit and a country can identify a customer under secrecy rules. The registry stores no personal data, but on a public chain the pattern is visible. Deployment choice, not a contract fix.
5. Exit-only lets a lapsed holder sell to an eligible buyer. An issuer that wants a lapsed holder frozen uses `setStatus(BLOCKED)`.
6. One record per address (C1): a second provider for the same wallet needs the overwrite rule, and the earlier attester's view is lost.
7. A compromised guardian can block every address. The recovery timelock removes it after its delay, the same class of risk as a guardian that pauses.
8. The enforcement-burn exemption lets a `BURNER_ROLE` holder burn from an unregistered address. Today it can already burn from any verified holder, so the extra reach is small, but it is new.
9. Adding an attester or changing a policy waits for the timelock delay once the deployer has handed over.
10. Holder caps still count addresses (C7).
11. The gas figure is an estimate until C-1 measures it.

### Not in this plan

Entity ids and omnibus handling, the follow-on rules (`SupplyCapRule`, `IssuanceSwitchRule`, `JurisdictionRule`, `HolderLimitRule`, each a small plan of its own), every track B item, an ERC-7943 adapter, an adapter that reads ONCHAINID or EAS into the registry, zero-knowledge proofs, evidence or hash storage, a cap on validity, a registry attestation kind, appeals or dispute handling, and any change to `IdentityRule`.

### Track B, on the same pieces (noted 2026-10-23, not planned or approved)

The owner's direction: Cancun and signatures are not a concern, and the aim is code that is easy to reuse. I checked the token: `mint`, `burn`, `forcedTransfer` and `setFrozen` are gated only by a role, and a contract can hold a role (the two executors already hold `EXECUTOR_ROLE`). So a cash token needs no change to `PolicyGatedERC20Upgradeable`. Policy goes in rules. Privileged workflow goes in contracts that hold the token's existing roles. The one token-level item is a thin template.

| Need (assessment 4.3) | Where it goes | Touches the base? |
|---|---|---|
| D1 decimals | A thin template `DepositToken`: `IntentToken` plus a `decimals` initializer argument. About 40 lines | No. A new template |
| D2 reference on mint and burn | A `MintController` holds `MINTER_ROLE` and `BURNER_ROLE`, requires a `ref` and emits it | No |
| D3 case reference on freeze and forced transfer | An `EnforcementController` holds `AGENT_ROLE`, requires a case id and emits it | No |
| D4 role split | The controllers: a freezer role and a clawback role on the controller, which is the only holder of `AGENT_ROLE` on the token. It also forwards `LockupRule.setLockup`, which reads `AGENT_ROLE` on the token | No |
| D5 supply cap | `SupplyCapRule` on `MINT` | No |
| D6 issuance switch | `IssuanceSwitchRule` on `MINT` and `BURN` | No |
| D9 ERC-7943 | Open. It adds functions to the token, so it is the one item here that would touch it | Only if chosen |
| Scoped mandates instead of locks | Signed intents already name an executor, a deadline and a start time, and `DvPExecutor` settles without escrow | No |

Limits to know before choosing this. The reference lives in the controller's event and is tied to the token's `Transfer` or `ForcedTransfer` by the transaction. The hook's `ctx.ref` stays zero for mint, burn and forced moves, so a rule cannot read it; if a rule must, that is a base change. The plain `mint` and `forcedTransfer` stay callable by whoever still holds the roles, so a controller only binds if it is the sole holder, which `assertHandedOver` can pin. The controllers are new trust points and need their own tests, audit and attestation review.

### C-1 as built (2026-10-23, awaiting review)

Contracts, Solidity tests, the freeze and size pins and the reproducibility manifest. No Ignition, no TypeScript test, no docs (C-2). Branch `credential-layer`, cut from `24b7798`, in the worktree `/Users/address0/dev/gated-token-stack-credential`. Nothing is committed.

**New code.**
- `contracts/interfaces/Quals.sol`, `ICredentialRegistry.sol`, `ICredentialRule.sol`.
- `contracts/identity/CredentialRegistry.sol` (409 lines, 11,082 bytes deployed) and `contracts/hooks/rules/CredentialRule.sol` (141 lines, 3,275 bytes). The limit is 24,576.
- `contracts/test/MockERC1271Wallet.sol`, a contract account for the ERC-1271 attester tests.
- Tests next to the code: `CredentialRegistry.t.sol`, `CredentialRule.t.sol`, `CredentialRuleIntegration.t.sol`, `CredentialRuleVaults.t.sol`, and `contracts/test/halmos/CredentialRegistryHalmos.t.sol`.
- Changed: `Errors.sol` (`CREDENTIAL_EXPIRED`, `RECEIVER_NOT_ELIGIBLE` appended), `InterfaceFreeze.t.sol`, `ContractSizes.t.sol`, `scripts/verify-reproducible.ts` (two manifest entries).

**Differences from the plan.** Each is my call, and you can overrule any of them.
1. The signed `Credential` carries the attester id (six fields in the EIP-712 type). ERC-1271 cannot recover a signer, so the registry must be told whose account to ask.
2. `profileOf` tests for a block before it tests for `NONE`. The plan listed `NONE` first. An address the guardian blocked before it had any record reads `BLOCKED`, so "a guardian block always reads BLOCKED" has no exception.
3. Killed attesters are a `uint64` mask in the registry, not a flag in each attester's slot, so one read serves both parties of a movement. `attesterAt` still returns `killed`.
4. `blockSubject`, `clearGuardianBlock`, `killAttester` and `reviveAttester` do nothing, and emit nothing, when they change nothing. A guardian script can be repeated safely.
5. `setStatus(ACTIVE)` needs a `validUntil` strictly in the future, as `set` does. A record still reads `ACTIVE` through its last second but cannot be restored in that second.

**Tests, red first (rule 5).** Against stubs (every registry function reverting, the rule approving everything): 15 passing, 120 failing. The 15 are what a stub can satisfy: accept cases for an approve-all rule, and plain `AccessControl` behaviour. My first stubs failed every `setUp`, which showed 21 failing contracts and 0 passing and hid the count, so I made them permissive enough for `setUp` to run.

**Green.** 170 new Solidity tests: `CredentialRegistry.t.sol` 93 (including three stateful invariants at 256 runs, and a test that the handler reaches both a write and a rejection), `CredentialRule.t.sol` 42, `CredentialRuleIntegration.t.sol` 24, `CredentialRuleVaults.t.sol` 10 (seven on the 7540 vault, three on the 4626 vault), and one more in `InterfaceFreeze.t.sol` for the `Quals` bits. Fuzz tests use `bound`; no Solidity test uses `vm.assume`. The integration tests use the real token, hook, registry and rule, and compare `canTransfer`, `canExecute` and `isUserAllowed` with the real call for each standing.

**Gates, on the final tree.**
- `npx hardhat test`: **962 passing (877 Solidity, 85 TypeScript)**, 0 failing. The baseline at `24b7798`, run from a clean export, is 792 (707, 85). Isolated profile: 877 passing.
- `forge fmt --check`, `solhint --max-warnings 0` and `tsc` clean. Aderyn 0 findings. upgrades-core 3 of 3 (the new contracts are not upgradeable).
- Slither: **0 results** (379 contracts, 97 detectors). The first run found 6: four `incorrect-equality` on comparisons of the status enum, two `unused-return` on a tuple that is only partly used. Neither is a defect. I added inline suppressions with the reason on the line above, in the style of the other rules, and changed nothing else.
- Halmos: five new properties pass (one is a control), and the 13 existing ones still pass. Planted bugs: Halmos gives counterexamples for three of the four I tried; the fourth (a direct write that stores `issuedAt` as zero) is caught by the invariant and the unit tests, not by Halmos. The first version of the stale-credential property was vacuous: every path reverted because of the overwrite rule, not because of the staleness. The control property exposed it, and both now use one attester.
- `verify:reproducible`: 18 contracts identical across the two production builds, the default profile and forge. The 16 existing contracts have runtime and creation code identical to the build of `24b7798` (compared artifact by artifact). The manifest grew from 16 to 18.

**Mutation run.** 56 mutants (34 on the registry, 22 on the rule), run in three scratch copies: 56 killed, none survived. 23 were killed by exactly one test, which are the sharp boundaries (the lapse second, the 65th attester, each role gate). The invariants alone catch four of the registry mutants. One of them, a write that drops the guardian block, escaped until the handler kept its own record of the blocks, because the invariant had been reading the flag the mutant deletes. The list is fixed and not exhaustive.

**Gas** (forge `--isolate`, 21,000 intrinsic included, ordinary movement between existing holders, same token and hook, a throwaway bench in scratch):

| Rule set | transfer | mint | burn |
|---|---|---|---|
| A: `IdentityRule` over a mock registry | 73,499 | 86,779 | 73,285 |
| B: `IdentityRule` over `CredentialRegistry` | 78,023 | 90,041 | 76,547 |
| C: `CredentialRule` | 81,626 | 93,196 | 76,828 |

C over A: +8,127 on a transfer, +6,417 on a mint, +3,543 on a burn. Decision 17 expected +11,000 to +15,000 and set the stop line at +20,000, so the plan did not stop. Registry writes: `set` 58,203 (new address) and 41,138 (rewrite), `setStatus` 35,430, `blockSubject` 32,430. The signed `register` was not measured.

**For the review.**
- Revoking a signed credential that nobody has submitted yet: `setStatus` needs a record, so the attester cannot touch it directly. It can write a record and block it (which raises `issuedAt` past the credential's), or the guardian can block the address. `validUntil` bounds the exposure either way.
- Under the plain `IdentityRule` over this registry, a lapsed or exit-only holder cannot send (tested). Exit-only behaviour exists only with `CredentialRule`.
- `register` is open to anyone, by design: the holder or a relayer pays the gas.
- The new contracts use no transient storage, so they do not depend on the Cancun decision.
- Next, C-2: Ignition (`Components`, `Tokens`, `roles.ts`, `Activate`), the TypeScript fixtures and `credentials.test.ts`, the docs, and the brief edits you must approve.

### C-1 rebased onto the review items and ported (2026-10-25)

The owner chose to wait for S0 and S1, then port C-1. S0 to S5 and two follow-up fixes have landed on `fund-layer` (`a4f237d`), so `credential-layer` was rebased onto it. The old tip is kept as the local ref `backup/credential-layer-c1-8b09efb`.

- **Rebase.** C-1 is now `3d48032`. Five files conflicted, all because both sides appended or because the other session removed lines: `PLAN.md`, `Errors.sol`, `InterfaceFreeze.t.sol`, `ContractSizes.t.sol` and `scripts/verify-reproducible.ts`. Both sides were kept, except in the manifest (`LockupRule` is gone, `HolderRestrictionRule` and `MinPositionRule` are in, `CredentialRule` is added) and in the size test (an import the other side removed). `3d48032` does not pass its tests on its own: three type errors in the tests, and the rule answers the new probes with `BaseRule`'s default. The next commit fixes both.
- **The rule.** `CredentialRule` overrides `checkSend(token, account)` and `checkReceive(token, account)`, which the review items added to `IComplianceRule` and which feed the token's `canSend` and `canReceive`. `BaseRule` answers `TRANSFER_OK` to both, so without the overrides the rule compiles and says yes to an account with no credential or a lapsed one (six tests fail). `check` is built on the same two helpers, so a probe and `check` cannot disagree: the interface requires it, and a fuzz test pins it. The enforcement burn stays in `check`, since it depends on the operator.
- **The tests.** `TransferContext` has eight fields (`ref` and `deadline` are gone); `canTransfer` with a reason is `canTransferWithReason`; `isUserAllowed` is `canReceive`; the vault tests build the shared `ComplianceHook(registry)` and pass the rules to `initialize` and `deploy`. Five new unit tests pin the probes against `check`, and the integration tests now assert `canSend` and `canReceive` on the token, the lapsed and the blocked holder included.
- **Result.** `npx hardhat test`: 1186 passing (1090 Solidity, 96 TypeScript), 0 failing. The other session's 915 Solidity tests are untouched; the 175 new ones are C-1's 170 and the five probe tests. The other gates (Slither, Halmos, the mutation run, reproducibility, gas, the isolated profile) are re-run on the final tree at the end of C-2, which includes this port.

### C-2 as built (2026-10-25, awaiting review)

Deployment, TypeScript tests and docs, on top of C-1 as rebased and ported above. Branch `credential-layer` is at `cd51112` (C-2, committed 2026-10-25 with its files staged by name: 23 modified and 2 new, `docs/credentials.md` and `test/nodejs/credentials.test.ts`), over `9a8e43a` (the port), in the worktree `/Users/address0/dev/gated-token-stack-credential`. Nothing is pushed.

**Deployment.**
- `Components` deploys `CredentialRegistry(deployer, guardian)` and `CredentialRule(registry)`, and no longer takes `identityRegistry`. Its parameters are `governance`, `council`, `guardian`, `minDelay`. `IdentityRule` is not deployed, so the council still attests six rules (`CredentialRule` where `IdentityRule` was). `IdentityRule` stays in the repo and the reproducibility manifest.
- `roles.ts`: `credentialRule` first in all three `RULE_ORDER` lists, and a `QUALS` copy of `Quals.sol` (the Solidity bits are pinned by `InterfaceFreeze.t.sol`, so a change there fails the build before the two copies can disagree).
- `Activate`: `addAttester(kycAttester, kycAllowedQuals)` while the deployer is the registry's admin, then `setPolicy(token, KYC, 0, 0, 1)` for each token (the same "KYC from attester 0 and nothing more" the identity check meant), `RECOVERY_ROLE` on the registry to the recovery timelock, and `DEFAULT_ADMIN_ROLE` on the registry to the main timelock with the deployer renouncing. The hand-over waits for the attester and the policies, so no token is handed over unconfigured.
- Registry code is reviewed by the council, not attested (like `Fund` and `ProxyDeployer`). The runbook has the council read `REGISTRY()`, the registry's code, its admin and its attester list before it attests the rule.

**TypeScript.** `fixtures.ts` has the demo attester (`kyc`), `verify` and `deverify` helpers, `STATUS`, `COUNTRY`, and the credentialled holders, recovery account and 7540 vault (`KYC | INFRA`). `assertHandedOver` now also checks: the registry's admin is the main timelock, the recovery timelock holds exactly `RECOVERY_ROLE` on it, the guardian holds only `GUARDIAN_ROLE`, the deployer holds nothing, one attester (the KYC provider, not killed), the rule reads this registry and is attested, and every token's policy is `KYC` from attester 0. New `credentials.test.ts` (8 tests): the deployment wiring; eligible and ineligible holders with probes and pre-flight agreeing; a credential signed with viem and submitted by a stranger (a replay and a forgery fail); expiry on the real clock; a guardian block lifted only by the recovery timelock; killing and reviving an attester; a policy change by the timelock deciding who may receive; event decoding. `parity.test.ts` gets five conditions (sender and receiver exit-only, sender and receiver lapsed, sender blocked by the guardian) across its four operations: 20 tests. The other six test files change only their identity set-up.

**Docs.** New `docs/credentials.md`. Edited: `README.md`, `SECURITY.md` (scope, the attester trust assumption), and in `docs/`: `README`, `architecture`, `roles`, `transfer-checks`, `flows-token`, `flows-vaults`, `flows-dvp`, `money`, `governance-and-deployment` (runbook, sequence diagram, rule-order table, a warning not to drop the credential rule from a list). A fresh agent checked the diff against the code and found 22 things: 5 wrong, 7 stale, 10 nits. I checked each against the code and fixed all of them except three nits (generic "verified account" wording in `transfer-checks.md`, a missing `RECOVERY_ROLE` bullet that predates this work, and a list that puts `CredentialRule` and `IdentityRule` side by side). The Mermaid diagrams, the internal links and anchors were checked by the same agent and are clean. SECURITY.md also gets the credential layer's inline suppressions (section 4) and three mutation rows (section 5).

**Behaviour the owner should know about** (all were in the C-1 design; the docs now say them):
- A holder whose credential lapsed, or whose attester was killed, can send, burn and redeem, and cannot receive. Under `IdentityRule` they could do none of these.
- The issuer's enforcement burn (operator holds `BURNER_ROLE`) now passes the sender check even for a blocked or unknown holder. Under `IdentityRule` that burn was refused with `SENDER_NOT_VERIFIED`. `forcedTransfer` into an eligible account stays the other way out.
- A redemption payout to a lapsed controller goes through; to a blocked or unknown one it does not.

**Gates, on the final tree (the working tree with C-2).**
- `npx hardhat test`: **1214 passing (1090 Solidity, 124 TypeScript)**, 0 failing. At the port it was 1186 (1090, 96): the 28 more are the 8 in `credentials.test.ts` and the 20 parity tests. Isolated profile: 1090 passing.
- `forge fmt --check`, `solhint --max-warnings 0`, `tsc`: clean. Aderyn: 0 findings. Slither: 0 results (420 contracts, 97 detectors). upgrades-core: 3 of 3.
- Halmos: all pass, 21 properties in five suites (the five registry properties among them).
- `verify:reproducible`: 19 contracts identical across the two production builds (17 on `a4f237d` plus the two new ones). The 17 existing manifest entries (runtime code, creation hash, immutable slots) are identical to those of a clean export of `a4f237d`, built the same way and compared entry by entry on 2026-10-26; only `CredentialRegistry` and `CredentialRule` are new.
- Mutation run: **62 mutants, 62 killed, none survived** (34 on the registry, 22 on the rule, and 6 new ones on the `checkSend` and `checkReceive` probes the port added), in three scratch copies of the final tree. 23 were killed by exactly one test, which are the sharp boundaries. Deployment wiring: **7 of 7 killed** (no policy set, a policy that asks for no bits, a policy that trusts no attester 0, a registry not handed to the timelock, no recovery role on the registry, the credential rule last in the order, an attester allowed to assert nothing), by `credentials.test.ts` and `deployment.test.ts`. The lists are fixed, not exhaustive.

**Gas** (forge `--isolate`, 21,000 intrinsic included, a transfer between existing holders, same token and hook, re-measured on this tree with a throwaway bench in scratch):

| Rule set | transfer | mint | burn |
|---|---|---|---|
| A: `IdentityRule` over a mock registry | 72,461 | 85,205 | 71,957 |
| B: `IdentityRule` over `CredentialRegistry` | 76,985 | 88,467 | 75,219 |
| C: `CredentialRule` | 80,640 | 91,613 | 75,604 |

C over A: +8,179 on a transfer, +6,408 on a mint, +3,647 on a burn. Registry writes are unchanged from C-1: `set` 58,203 (new) and 41,138 (rewrite), `setStatus` 35,430, `blockSubject` 32,430. The signed `register` (a stranger submits an attester's EIP-712 credential; each call its own transaction, 21,000 included, measured 2026-10-26 on a copy of the `cd51112` tree): 68,239 for a new subject and 51,174 for a rewrite with an ECDSA attester, and 69,249 for a new subject with an ERC-1271 attester. The ERC-1271 figure uses `MockERC1271Wallet`, which only recovers one key, so a Safe or an HSM front costs more by whatever its `isValidSignature` does. That is about 10,000 above the direct `set` (58,203 and 41,138), the price of the hash and the signature check.

**Not done or not checked.**
- Nothing is pushed.
- The deployment mutants and the mutation run ran in scratch copies, not in CI. CI is not run.
- Track B is not started.

**Proposed brief edits** (the brief is the standing instruction file, so these need your OK and are **not applied**):
1. §3 layout: add `identity/  CredentialRegistry.sol  CredentialRegistry.t.sol`; add `CredentialRule.sol` to `hooks/rules/`; add `ICredentialRegistry`, `ICredentialRule` and `Quals` to the interfaces line; add `MockERC1271Wallet.sol` to `test/`.
2. §5 reason codes: append `CREDENTIAL_EXPIRED` and `RECEIVER_NOT_ELIGIBLE` (2026-10-23).
3. §6 initial rule set: the demo lists start with `CredentialRule` where they say `IdentityRule`; add a `CredentialRule` bullet: a sender must be able to leave (registry standing `ACTIVE`, `EXIT_ONLY` or `LAPSED`) except on `MINT` and `FORCED` (not checked) and an enforcement `BURN`; a receiver must be `ACTIVE` and meet the token's policy, unless `BURN`; a lapsed receiver gets `CREDENTIAL_EXPIRED`, a token without a policy admits no receiver; state lives in `CredentialRegistry` (immutable, reviewed, not attested), so the rule has no `after_`; keep the `IdentityRule` bullet and mark it "not in the demo lists".
4. §4 or §6: one line for the registry's guardian (`blockSubject`, `killAttester`) and its recovery path (`clearGuardianBlock`, `reviveAttester`, `revokeRole(GUARDIAN_ROLE)` by the recovery timelock).
5. §7: "verified holder", "verified recovery account" and "`to` must pass identity" become "must pass the token's policy".

## `ProxyDeployer` checks the first implementation (planned 2026-10-26, built and committed 2026-10-27)

Source: finding 1 of the audit of the token, hook and policy contracts (2026-10-26, rated low; the page is `docs/gated-token.html`, section "Audit"). On 2026-10-26 the owner asked for this plan. On 2026-10-27 the owner approved D1 to D4 as recommended and confirmed that no `ProxyDeployer` is live; the work is built and described under "Result" at the end of this section.

### Goal

`ProxyDeployer.deploy` creates a token proxy over any `_implementation` and then trusts the token's own answers: `policyHook()`, `rules(token)` and `symbol()`. An implementation the council never reviewed can give all three correctly. Today an implementation's attestation is enforced on chain only when a token is upgraded (`_authorizeUpgrade`). For a first deployment it is a council step in the runbook, which `docs/governance-and-deployment.md` says in two places ("Place a new token" row, and the `deploy` section).

Only the owner can call `deploy`: the deployer account until `Activate`, the timelock after it. The aim is that "only attested code runs" also holds at the first deployment, with the same registry question the other three gates ask (hook, rules, upgrade).

The check cannot live in the token. The initialiser is the implementation's own code, so a hostile implementation would simply not run it. Only the deployer can ask the registry before the proxy exists.

### What changes

1. `ProxyDeployer` gets an immutable `REGISTRY`. The constructor becomes `(initialOwner, registry)`, and a zero registry reverts.
2. `deploy` reverts with `ProxyDeployer_ImplementationNotAttested(implementation)` unless `REGISTRY.isAttested(_implementation, IMPLEMENTATION)`. Order inside `deploy`: the salt check and the salt write, both as today, then this check, then CREATE2 and everything after it. That keeps the salt error first for an already used symbol, keeps every write before every external call (so it should not need a new Aderyn suppression; C-1 confirms with a run), and a revert still undoes the salt write.
3. Only if D2 is accepted: after initialisation `deploy` also requires `IPolicyGated(_proxy).registry() == REGISTRY`, else `ProxyDeployer_RegistryMismatch(expected, actual)`.
4. Nothing else moves. `predict` and the CREATE2 address do not change: they depend on the deployer's address, the symbol and the implementation, and the deployer's own address comes from its sender and nonce, not its code. The check reads the registry at deploy time only, like the other gates: revoking an attestation later leaves running tokens alone.

### Decisions for the owner (recommendation first)

| # | Question | Recommendation | Alternative |
|---|---|---|---|
| D1 | `IProxyDeployer.sol` is frozen (rule 4). Reopen it to add the getter `REGISTRY()` and the errors `ProxyDeployer_ImplementationNotAttested`, `ProxyDeployer_ZeroAddress` (and `ProxyDeployer_RegistryMismatch` with D2), and re-pin the interface id in `InterfaceFreeze.t.sol` (now `0xcedb15bb`)? | Yes. The getter matches `IComplianceHook` and `IFund`, and lets the post-deploy check read it. Errors do not change the id; the getter does, and the new id is taken from the selectors with `cast` and checked against solc's value, as for the other pins. | Errors only, no getter. The id stays. The registry is public on the contract but not in the interface. |
| D2 | Also require the new token's `registry()` to equal `REGISTRY`? | Yes. Without it the owner could pass the implementation check and still initialise the token against another registry that attests its own hook and rules. One view call and one error. | No. The finding is only about the implementation. |
| D3 | Is the registry fixed at construction? | Fixed, as in `ComplianceHook` and `Fund`. | A setter is one more power for the timelock to hold. |
| D4 | Migration. | None, because the repo records no live `ProxyDeployer` (this file, "Finding: bytecode depends on the compile job": "none exists yet"). Please confirm none is live. | If one is, deploy a new one owned by the timelock and leave the old one unused. Its token addresses are unaffected. |

### Files touched (why rule 3 applies)

- Contracts: `contracts/deploy/ProxyDeployer.sol`, `contracts/interfaces/IProxyDeployer.sol` (D1).
- Pins and sizes: `contracts/test/InterfaceFreeze.t.sol`, `contracts/test/ContractSizes.t.sol`.
- Unit tests: `contracts/deploy/ProxyDeployer.t.sol`.
- Call sites of the constructor, each passing its registry and, where the test deploys through the deployer without having attested the implementation, attesting it first: `DvPExecutor.t.sol`, `IntentToken.t.sol`, `Gated4626Vault.t.sol`, `Gated7540Vault.t.sol`, `MaxHoldersRule.t.sol`, `FundIntegration.t.sol`.
- Deployment: `ignition/modules/Components.ts` (the module already has `registry`), `test/nodejs/fixtures.ts` (`deployGatedCashToken`), `test/nodejs/deployment.test.ts`.
- Docs and notes: `docs/governance-and-deployment.md` (the "Place a new token" row, the `deploy` section, the runbook's attestation step), `SECURITY.md` (section 3 item 1, and a mutation row in section 5), `docs/gated-token.html` (finding 1, the glossary line on "attested", the note under the registry figure), `docs/README.md` ("Checked against"). `README.md` line 71 ("Attested code only") becomes true as written and needs no edit.

About 19 files, 11 of them Solidity. The deployment flow itself is unchanged: the council already attests the implementations after `Components` and before `Activate`.

### Tests first (red run shown before the implementation)

In `ProxyDeployer.t.sol`:
1. `test_WhenTheImplementationIsNotAttested_ItRevertsAndNothingIsDeployed`, and the symbol is still free afterwards.
2. `testFuzz_WhenTheImplementationIsAttestedAsAnotherKind_ItReverts`, with the kind bounded to `NONE`, `HOOK` and `RULE`.
3. `test_WhenTheImplementationHasNoCode_ItRevertsAsNotAttested` (today it reverts inside the proxy constructor, with another error).
4. `test_WhenTheSymbolWasUsedAndTheImplementationIsNotAttested_SaltUsedWins`.
5. `test_WhenTheImplementationIsAttested_ItDeploysAsBefore`. The existing tests keep passing with the registry passed in.
6. `test_WhenTheRegistryIsZero_ItReverts` and `test_ItRecordsTheRegistry`.
7. With D2: `test_WhenTheTokenNamesAnotherRegistry_ItRevertsAndNothingIsDeployed`.

In `deployment.test.ts`: an `Activate` over an implementation the council did not attest stops before any role is granted, in the shape of the existing test for an unattested rule.

Mutants, recorded in `SECURITY.md` section 5: the check removed; the check after CREATE2; the wrong kind compared; the check placed before the salt check; the constructor ignoring its registry; with D2, the registry check removed.

### Verification

`npx hardhat test` in both runners (baseline at `a148d2f`: 1011 passing, 915 Solidity and 96 Node, plus the new tests), `npm run lint:sol`, `slither .`, `npm run aderyn`, and `npm run verify:reproducible`. `ProxyDeployer`'s creation code changes, so its reference build changes with it. `ContractSizes` should stay far under the limit. `npm run validate:upgrades` and Halmos are unaffected: `ProxyDeployer` is not upgradeable and has no symbolic property.

### What it does not solve

- An owner that can grant itself `ATTESTER_ROLE`. After `Activate` that is the timelock, so it is delayed and visible, not prevented.
- What attestation means. It covers one deployed implementation's code (UUPS puts `address(this)` in the code), not the quality of the council's review.
- Tokens already deployed. The check runs at deploy time only.
- `Fund` is still not attested (`SECURITY.md` section 2).

### Order of work after approval

1. Owner answers D1 to D4.
2. Interface and pin (D1), then the tests above, with the red run shown.
3. Implementation, then the call sites and the Ignition module.
4. Both runners, lint, Slither, Aderyn, reproducibility, the mutants.
5. Docs and notes, and finding 1 on `docs/gated-token.html` marked fixed with the commit.
6. Stop for review. Nothing is committed or pushed without an instruction.

### Result (2026-10-27)

Built as planned with D1 to D4 as recommended. `ProxyDeployer` holds an immutable `REGISTRY` (constructor `(initialOwner, registry)`, zero reverts with `ProxyDeployer_ZeroAddress`). `deploy` asks `REGISTRY.isAttested(implementation, IMPLEMENTATION)` after the salt check and the salt write and before CREATE2, and right after the initialiser it requires `token.registry() == REGISTRY` (D2), before the hook, rule and symbol checks. `IProxyDeployer` gained `REGISTRY()` and the three errors; its id is re-pinned to `0xc8982ea0` (was `0xcedb15bb`; the old id XOR `REGISTRY()`'s selector `0x06433b1b`, from `cast sig`, matched by solc).

Red run first, against a signature-only stub (constructor and getter, no check) so the tests compiled: Solidity 917 passing and 10 failing, Node 96 passing and 1 failing, each failure the missing check. The pin was run red on its own before the interface changed.

Where it differs from the plan:
- The wrong-kind fuzz covers `HOOK` and `RULE` only. The registry refuses to attest `NONE`, so `NONE` is the unattested test.
- The real-registry cases (unattested, wrong kind, no code, a second unattested instance of the template, and an attested happy path) are a second contract in `ProxyDeployer.t.sol`, `ProxyDeployerIntegration_RealRegistry`. The unit contract also checks that `deploy` asks the registry about the implementation as `IMPLEMENTATION` (`vm.expectCall`) and that the symbol deploys once the implementation is attested.
- Two existing unit tests that made the registry refuse everything now refuse the hook only, since a blanket refusal now stops at the implementation first.
- `DvPExecutor.t.sol` had two more deploys through a deployer built elsewhere (`DvPExecutorFundIntegration`), over implementations nobody attested. The first full run caught them; they now attest first, as the deployment does.
- `docs/architecture.md` (the `ProxyDeployer` row) was also updated, so that `docs/README.md`'s "Checked against" line stays true.

Verification: `npx hardhat test` 1024 passing (927 Solidity, 97 Node), `npm run lint:sol` and `forge fmt --check` clean, `slither .` 0 results with no new suppression, `npm run aderyn` 0 findings, `npm run verify:reproducible` passes (17 contracts identical across the builds, `TokenProxy` matches the code `ProxyDeployer` embeds; `ProxyDeployer` now has one immutable slot in the manifest, the registry). Mutants: 8 of 8 caught, recorded in `SECURITY.md` section 5. The check moved after CREATE2 is caught by one test only, the implementation with no code, because a revert removes the proxy either way.

Docs: on 2026-10-27, before the merge of `credential-layer`, seven fresh agents checked the nine `docs/*.md` pages, `README.md`, `SECURITY.md` and `docs/gated-token.html` claim by claim against the code (about 2,100 claims). Every reported mismatch in the Markdown files was confirmed against the merged code and fixed (`docs/credentials.md`, which the merge added, was not part of that check), including the README runbook and deviations, which now describe the new checks. The brief's §4 list of where attestation is enforced still does not name `ProxyDeployer.deploy`; the brief is the owner's to change, and the README deviations record it.

## Cleanup: nothing kept for a deployment that never happened (2026-10-27)

The owner, 2026-10-27: "the code was never deployed so clean everything we can to avoid any confusion", after an inventory of unused code and files. Recorded here before the change (rule 3); the owner asked for it to be done, not stopped for review.

- `IdentityRule` is no longer deployed: the credential layer replaced it in every list. It leaves production: the rule, `IIdentityRule` and `IdentityRule.t.sol` are deleted, and the tests that only need a simple identity gate use `contracts/test/MockIdentityRule.sol`, the same logic as a test mock. The tests of `IdentityRule` reading the credential registry go with it. `IIdentityRegistry` stays: `CredentialRegistry` implements it (`isVerified`) for integrators.
- `MaxHoldersRule` is deleted with `IMaxHoldersRule`, its tests and its deployment in `Components`: no token lists it, and the fund-wide cap is `FundHoldersRule`. Tests that used it as the cap move to `FundHoldersRule` where they test another contract's behaviour at a full cap, and are deleted where they tested only the removed rule.
- Files: the empty `.gitkeep` placeholders in folders that have files, `.npmignore` (the package is private), four `export` keywords in `fixtures.ts` on helpers only that file uses, and the local, git-ignored `docs/superpowers/` folder with its `.gitignore` line. PLAN.md keeps the decisions those notes informed.
- The brief, `README.md` and `SECURITY.md` follow. `docs/*.md` is replaced by the HTML pages right after, so it is not edited for this.

## Docs as HTML pages (2026-10-27)

The owner asked for the docs to be rebuilt as HTML for product people and curious readers, accurate to the code, with one page per contract and one for the whole protocol. Decisions: only `docs/*.md` becomes HTML (README.md, SECURITY.md, PLAN.md and CLAUDE.md stay Markdown); GitHub Pages publishes `docs/` from `main`; the set is an overview (`docs/index.html`), one page per contract (`docs/contracts/`, 20 pages), four topic pages (`roles`, `movement`, `deployment`, `money`) and the security review (`review`); the earlier explainer and token-and-policy pages are folded in. The pages describe the code only as it is, with no history.

Built by seven writing agents from a shared template and stylesheet (`docs/assets/site.css`: one palette, every text colour at least 4.5:1 on every background in both themes), then checked claim by claim by seven separate agents against the code; every reported mismatch was confirmed in the code before it was fixed. A consistency check confirms every page uses the same stylesheet, fonts, navigation and footer, has no inline styles or colour literals, and has no broken links or anchors.

## Five behaviours found while writing the docs: confirmed, with proposals (2026-10-27; B1, B2 and B4 built)

The owner asked to confirm each behaviour with a test and to propose fixes before changing any code. Each test below passes today: it pins the behaviour as the code has it. No contract is changed.

### B1. A forced transfer out of the 7540 escrow strands the last pending redemption

- **What happens.** Every pending redemption's shares sit in one balance at the vault's own address; `pendingShares` is booked per controller. `forcedTransfer` (base, `AGENT_ROLE`) can move tokens out of any address, the vault's included, without touching the booking. The earlier fulfilments still settle from the pool; the last controller's `fulfillRedeem`, `rejectRedeemRequest` and `recoverRedeemRequest` all revert with `ERC20InsufficientBalance(vault, 0, n)`. The only way out is to force the shares back.
- **Test.** `Gated7540VaultUnit_PooledEscrow.test_WhenTheAgentForcesSharesOutOfTheEscrow_TheLastPendingRedemptionCannotSettle`.
- **Options.**
  - **A (recommended).** The 7540 vault refuses `forcedTransfer` whose `from` is the vault itself, with its existing `Gated7540Vault_Unsupported()`, as it already does for the issuer `mint` and `burn`. Escrowed shares then move only through the per-controller paths: fulfil, reject, `recoverRedeemRequest`. Needs `virtual` on the base's `forcedTransfer` (the base's `burn` is already `virtual` for the same reason). No interface change.
  - B. Keep it, and track the total pending so a forced transfer cannot take the pool below it: a new storage field kept in step by four functions, for a power nobody needs.
  - C. Document only: an agent error, undone by forcing the shares back.

### B2. A frozen amount on the 7540 escrow cannot target a controller

- **What happens.** `setFrozenTokens(vault, n)` freezes part of the pool, not anyone's request. The fulfiller has no `BURNER_ROLE`, so a fulfilment's burn may take only unfrozen shares, and a reject is a plain transfer. Whichever fulfilment or reject comes last and needs the frozen part is refused with `ERC7943InsufficientUnfrozenBalance`, whoever it belongs to. Freezing 30 meant for bob blocks alice's 50 if bob's settles first.
- **Test.** `Gated7540VaultUnit_PooledEscrow.test_WhenPartOfThePooledEscrowIsFrozen_TheLastFulfilmentIsBlockedWhoeverItIs` (and the existing `Gated7540VaultUnit_FrozenEscrow` tests, which freeze the whole pool).
- **Options.**
  - **A (recommended, with B1's A).** The 7540 vault refuses `setFrozenTokens` on its own address, with `Gated7540Vault_Unsupported()`. To hold one controller's pending redemption, the fulfiller does not fulfil it, or the agent moves it with `recoverRedeemRequest` (per controller, FORCED, to a quarantine account). Needs `virtual` on the base's `setFrozenTokens`. The two `Gated7540VaultUnit_FrozenEscrow` tests become "freezing the escrow reverts". `recoverRedeemRequest`'s `_releaseFrozen(address(this), …)` then never releases anything but still checks the balance; it can stay. No interface change.
  - B. A per-controller hold on pending redemptions (`holdRedeemRequest(controller)` blocking fulfil and reject): new function, storage and interface surface.
  - C. Document only.
  - ERC-7943 note for A: `forcedTransfer` and `setFrozenTokens` are the standard's functions; refusing them for one address (the vault itself) is a token-level restriction that tooling calling them on the vault would see as a revert.

### B3. A settlement window can be changed but not cleared

- **What happens.** `setWindow` refuses an empty day mask (`SettlementWindowRule_InvalidWindow`) and there is no clear function. The rule fails closed when unconfigured, so a cleared window would block every intent rather than switch the rule off. To stop windowing a token, its admin takes the rule out of the list with `setRules`.
- **Test.** `RuleSetIntegration_SettlementWindow.test_WhenTheWindowRuleIsTakenOutOfTheList_IntentsSettleOutsideTheWindow` (and the existing `test_WhenTheDayMaskIsEmpty_ItReverts`).
- **Proposal: no change.** It is the fail-closed design; halting intents is what pause is for. The pages already say how to turn it off.

### B4. No contract enforces a minimum timelock delay

- **What happens.** `GovernanceTimelock` accepts any initial delay (0 included), and an operation of the timelock on itself can lower it with `updateDelay`, after the current delay. Only the deployment default (7 days) and the post-deploy check stand behind "at least 7 days".
- **Test.** `GovernanceTimelockUnitTest.test_WhenGovernanceLowersTheDelay_NothingStopsItBelowSevenDays`.
- **Options.**
  - **A (recommended).** `GovernanceTimelock` enforces a 7-day floor in its constructor and in an `updateDelay` override, reverting with a new `GovernanceTimelock_DelayBelowFloor(delay, floor)`. The floor stays an internal constant, so the interface id does not change; the new error is an addition to the frozen `IGovernanceTimelock` (owner decision). The main timelock is where the upgrade, hook and rule powers live, so this is where holders rely on the delay. The recovery timelock (plain OpenZeppelin, powers that only undo the guardian) is left as it is.
  - B. Same floor on the recovery timelock too: a small subclass instead of the plain OpenZeppelin contract, one more contract to deploy and attest-check.
  - C. No change: lowering the delay is itself a delayed, public operation that the guardian can cancel.

### B5. `RECOVERY_ROLE` revokes `CANCELLER_ROLE` from governance too

- **What happens.** On the main timelock the recovery timelock may revoke `CANCELLER_ROLE` from any holder. OpenZeppelin makes every proposer a canceller, so that includes the governance multisig, not only the guardian. On the tokens, executors and credential registry it may revoke `GUARDIAN_ROLE` from any holder, which is the role itself.
- **Test.** `GovernanceTimelockUnitTest.test_WhenRecoveryRevokesGovernancesCancelRight_ItIsRevoked`.
- **Proposal: no change.** The recovery timelock's only proposer and executor is governance, so this is governance removing its own cancel right after a 7-day delay; nobody else gains a power. Limiting it to "the guardian" would need the timelock to know which account that is.

### If the recommendations are accepted

- Code: `PolicyGatedERC20Upgradeable` (`virtual` on `forcedTransfer` and `setFrozenTokens`), `Gated7540Vault` (two overrides), `GovernanceTimelock` (floor), `IGovernanceTimelock` (one error).
- Tests first: the two `PooledEscrow` tests and the two `FrozenEscrow` tests become "it reverts with `Gated7540Vault_Unsupported`" (plus the agent's `recoverRedeemRequest` as the way to move one controller's escrow); the delay test becomes "below 7 days reverts", in the constructor and in `updateDelay`; mutants for each check.
- Docs: the 7540 vault, base, roles, money, governance timelock and deployment pages, README's delay note, SECURITY.md section 3.
- Verification: both runners, lint, Slither, Aderyn, `verify:reproducible`, `validate:upgrades` (the base and vault change bytecode).

### Result (2026-10-27)

The owner accepted B1, B2 and B4 and kept B3 and B5 unchanged. Before the code, B1's option A turned out to strand any shares that reach the vault outside a request (a holder's plain transfer, a claim or recovery naming the vault), which only the agent's forced transfer could rescue. The owner chose instead to protect only what is booked:

- `Gated7540Vault` keeps `pendingRedeemShares`, the shares booked to pending redemptions across every controller, raised by `requestRedeem` and lowered by fulfilment, reject and recovery. `forcedTransfer` out of the vault's own address may take only the surplus above it (`Gated7540Vault_ExceedsSurplus(requested, surplus)`, a new error in `IGated7540Vault`). `setFrozenTokens` on the vault's address reverts with `Gated7540Vault_Unsupported()`.
- The base's `forcedTransfer` and `setFrozenTokens` are `public virtual` (they were `external`), so the vault can override them and call the base; solhint's ordering moved them after the external functions.
- `GovernanceTimelock` refuses a delay below 7 days in its constructor and in `updateDelay` (`GovernanceTimelock_DelayBelowFloor(delay, floor)`, a new error in `IGovernanceTimelock`), after OpenZeppelin's caller check. The interface ids do not change.
- Tests first, red run 8 failing. The two `FrozenEscrow` tests and the two behaviour-pinning escrow tests are replaced by `Gated7540VaultUnit_Escrow` (7 tests including a fuzz); the delay test by five floor tests and a fuzz. Mutants 12 of 12 (one survived first, a test was added), recorded in `SECURITY.md` section 5.
- `npx hardhat test` 1145 passing; lint, fmt, the type check, Slither (0), Aderyn (0), `verify:reproducible` and `validate:upgrades` pass. README, SECURITY section 3 and the brief describe the new rules; the HTML pages follow in their own change, pinned to the merged commit.
- Merged as `1708ddf` (PR #6). The check of the HTML pages then found that the vault's two overrides ran the escrow rule before the role check, so a caller without `AGENT_ROLE` got the escrow error. Both overrides now carry `onlyRole(AGENT_ROLE)`, tested first and with its mutant caught; 1146 passing.

## One stack per issuer, legos, and vaults that invest (planned 2026-10-30, code built by 2026-11-01)

Source: the owner, 2026-10-30, after an assessment of the code at `0350937`. A client may want only one token, one vault or one NFT, and the vaults should be able to invest. The owner's answer on where vault money goes: **on-chain and to a custodian.** Later the same day the owner parked the NFT, asked for the whole stack to be simple legos, deployed together or alone, and said to think about everything as if we are the issuer and our clients, investors and funds use the code. Nothing below is built. The decisions are at the end of this section.

### Starting point

- Baseline at `0350937`: `1146 passing (1021 solidity, 125 nodejs)`, CI green. Deployed sizes against the 24,576 limit: `Gated7540Vault` 23,988 (588 left), `Gated4626Vault` 18,552 (6,024 left), `IntentToken` 17,945 (6,631 left).
- `Components` and `Activate` always deploy 17 contracts and 3 proxies. One product needs about 10 of those 20. The contracts already allow it (`Gated4626Vault.t.sol:377` deploys one vault alone); the scripts do not.
- `Gated4626Vault` has no function that moves assets except a redemption, so the money cannot be invested. `Gated7540Vault` sends fulfilled assets to one `custody` address and takes each price from the fulfiller with no limit. Neither has adapters, caps, an allocator or fees. A vault takes one ERC-20, fixed at initialisation.
- The policy judges the shares and not the cash: `withdraw` and `redeem` pay assets to any `receiver` (OpenZeppelin's `_withdraw`, `Gated7540Vault.sol:771`).
- No NFT exists. `TransferContext.id` is reserved for one.

### Not in this work

- Several issuers on one stack: each issuer runs its own (P1).
- Code from other vault projects. Rule 15 cannot take a copyleft licence and rule 1 keeps us on OpenZeppelin, so everything here is written by us.
- A lending-market adapter, a tokenised-fund adapter, automatic allocation on deposit, forced or in-kind exit, per-period dealing limits (P11) and, until the owner reversed it on 2026-11-02, pro-rata redemption gates, fiat handling inside a vault (clients pay with the cash token, P25), request cancellation, investor-level fee equalisation, proof of reserves.
- For the NFT: signed intents and DvP, the `Fund` holder cap, `MinPositionRule`, permit, royalties, enumeration.

### The lego rules

These apply to everything in this section, and the existing stack is held to them too.

1. **One job, one sentence.** If the sentence needs "and", split the contract. A lego that passes about 300 lines of code gets looked at again.
2. **Small plugs.** A lego knows a neighbour only through a small interface.
3. **Optional means unplugged.** An optional lego left out is the zero address, and the lego above it still works. One `if`, never a mode.
4. **No shared state.** A lego keeps its own data. Roles live on the token or vault and legos ask for them live, so there is one place to grant and one hand-over.
5. **Swap, do not upgrade.** Only tokens and vaults are proxies. Everything else is immutable and attested, and a change is a new deployment and a timelock swap (rule 12). A lego's defining settings are immutables where possible, so the attested codehash covers them.
6. **Alone or together, the same code.** There is no protocol mode. Every combination is a profile with its own deployment test.

The existing stack already follows these: the hook and rules plug in by list, the executors by role, `Fund` through one rule. What does not yet: the deploy scripts and a token that always carries intents (step 1), and the code the two vaults duplicate (step 3).

### Seen from the issuer

The issuer runs the stack, and investors and funds are its clients. Every power below sits with the issuer except a fund manager's, and one function must never hold two roles that check each other.

| Who | On-chain | Issuer function | Client? |
|---|---|---|---|
| Change control | Governance multisig, proposes on the timelock | Change board with risk and technology | |
| Code review | Security council, `ATTESTER_ROLE` on the registry | Second line: security and model validation, independent of the developers | |
| Emergency stop | `GUARDIAN_ROLE` | 24/7 operations or security centre | |
| Recovery | Recovery timelock | A separate quorum, so that a compromised guardian can be removed | |
| Onboarding | KYC attester on `CredentialRegistry` | Compliance onboarding, fed by the customer system | |
| Enforcement | `AGENT_ROLE` | Compliance and legal, acting on an order | |
| Issuance | `MINTER_ROLE`, `BURNER_ROLE` | Treasury operations, driven by the issuer's ledger | |
| Investing | `ALLOCATOR_ROLE` on one vault | Portfolio manager, or a **fund client's** manager, limited by that vault's caps and validators | Yes |
| NAV maker | `REPORTER_ROLE` | Fund administration | |
| NAV checker | `CHECKER_ROLE` | Risk, or the depositary function | |
| Settlement | `OPERATOR_ROLE` on the executors | Settlement operations, paying the gas | |
| Investors | Holders and controllers | Clients, using the issuer's app | Yes |

What this changes:

- **One stack per issuer, many products (P1).** One set of timelocks, one guardian, one credential registry, one hook. A client is verified once and can hold every product, and blocking a sanctioned address applies everywhere, which is what an issuer wants. A fund's money stays apart in its own `Portfolio` (P12). Someone who wants one product alone deploys the core and one product, with the same code.
- **Launching a product does not wait (P26).** It adds a proxy over attested code and touches nothing that exists, so `ProxyDeployer` stays with an operations multisig instead of moving to the timelock. A timelock delay still protects what can hurt existing holders: upgrades, the hook, rule lists, roles, adapters, raised caps and fee models.
- **Caps and validators are the fund's mandate.** A fund client's manager can invest only where the issuer allowed, up to the limits it set. That is the oversight a depositary has to perform, enforced by the contract.
- **Clients pay with our own cash token (P25).** An `IntentToken` limited to customers, at its ledger's decimals: take payment off-chain and mint, burn and pay out on the way back. It is the asset of every vault and the cash leg of `DvPExecutor`, so wires work with no fiat code in a vault. Vaults, portfolios and accounts hold the `INFRA` bit and clients the `CUSTOMER` bit. It must meet the rules that apply to holding client money.
- **Custody before on-chain yield.** The money sits with the issuer or its custodians, so `GuardedAccount` comes before `ERC4626Adapter`, and the 4626 comes last.
- **Clients do not need wallets or gas (P24).** With one address per client in the issuer's custody, holder caps count clients rather than wallets, so entity ids can wait. The cost is concentration: a custody compromise is the worst case.
- **Confidentiality decides the chain (P23).** On a public chain anyone can see each client's balances and movements. No contract fixes that. The code needs an EVM with Cancun: the base uses transient storage.

### Step 1: deployment profiles (TypeScript, plus one small token contract; built 2026-10-30, awaiting review)

A module cannot branch on `m.getParameter`, which is a future at build time, so the module builders take a description of what to deploy.

```ts
type Product = { key: string; template: "GatedToken" | "IntentToken" | "Gated4626Vault" | "Gated7540Vault"; name: string; symbol: string; rules: RuleKey[]; decimals?: number; fund?: string };
```

- **`Core`, once per issuer:** both timelocks, the registry, the hook, `ProxyDeployer`, the credential registry and the rules in use. The council attests them, and one implementation per template, once: every product over a template shares that implementation.
- **`Product`, once per product:** a proxy through `ProxyDeployer`, its rule list, its configuration and its roles, then its admin handed to the timelock, as `Activate` does today. It runs with the operations multisig as deployer (P26), so the first product and the fiftieth follow the same path, and a later one does not wait. A product that lists `fundHoldersRule` names its fund, and never touches it.
- **`Fund`, once per fund:** a `Fund` and the `FundHoldersRule` that points at it, run by the operations account, each with its own cap. The council attests the rule, as it does any rule.
- **`FundOpen`, once per fund, after its first classes are placed:** installs the rule, sets the cap, registers the classes in order and moves the fund to the timelock. A later class launches through `Product` like any other and is inert until a timelock operation registers it, because a new class changes the room existing investors have under the cap.
- `ignition/profiles.ts` names the combinations in the table in step 3. `full` is today's demo: the core and three products, with the same order and the same rule lists.
- `contracts/tokens/GatedToken.sol`: the base and its decimals, fixed at initialisation (P3), used for a cash token with a policy that asks for the `CUSTOMER` or `INFRA` bit, with its `.t.sol`. `IntentToken` is the same token plus the intent mixin.
- `fixtures.ts`: `deployCore`, `deployProduct` and `assertHandedOver(stack, products)`, which checks what the products contain. Existing tests keep passing on `full`.
- **The delay (P26).** The timelock delay is 24 hours, set at deployment on both timelocks, and `GovernanceTimelock`'s floor becomes a constant of 1 hour. Rule 13, the brief, `Components.ts`, the hand-over check, the timelock's tests and the docs follow.

Tests first, in `deployment.test.ts`: the core and one product deploy and pass the hand-over check, with exactly the expected contracts; a second product launches after hand-over, with no wait, and leaves the first alone; a client verified once can hold both; a block applies to both; a product over an unattested implementation is refused; a vault whose asset is a gated cash token works end to end. A rule list that a template cannot use throws when the module is built.

Done when: those pass, the runbook in `README.md` and `docs/deployment.html` describe core and products, and the brief's §8 Phase 7 says so.

**Result (2026-10-30).** Built on branch `step-1-core-products`, in PR #9, and corrected the same day after the outside review (L-1, L-2 below). `GatedToken` is 15,300 bytes, against `IntentToken`'s 17,945. A deployment of one product is the core plus that product: 9 contracts and a proxy for a plain token. Red runs first: Solidity 3 failing (the timelock refused 24 hours, and the token was a stub), Node 10 failing; then for the correction Solidity 3 and Node 5. Then `npx hardhat test` 1178 passing (1037 Solidity, 141 Node). Mutants 32 of 32 caught, in `SECURITY.md` section 5.

Where it differs from the plan:
- One more small module: `CoreHandover` sits after the council step, because the core must be attested before its roles and hand-over run.
- **A fund is its own lego (review finding L-1).** The first version held one `Fund` in the core, registered classes from `Product` and moved the fund to the timelock in a `FundHandover` module. After that a later class reverted at `registerClass`, leaving a live proxy with the operations account as its admin and its symbol used up, and an issuer could run only one fund. So `Product` no longer touches a fund and cannot half-fail on one, and an issuer has as many funds as it wants. Until `FundOpen` runs the operations account owns the fund, so a first class does not wait either.
- **Decimals (review finding L-2).** A `GatedToken` takes its decimals at initialisation, in ERC-7201 storage at `gated.storage.GatedToken`, 18 unless the product states otherwise. A cash token at its ledger's 2 decimals gives a 4626 over it 8, where it would have had 24. Taking the extra argument means `memory` strings, as the 7540 already does, which costs the 1,532 bytes above; the token has room.
- The operations account is whichever account runs Ignition, for example an MPC custody wallet whose policy engine requires two approvers. It is not a Safe, because Ignition cannot sign through one. Step 4b's hand-over check covers this as a named exception.
- `vault7540` exists today with a plain fulfiller and custody; step 3b changes it.
- `deployProduct(s, product)` takes the stack, and `assertHandedOver(stack)` checks the products the stack holds.
- `PROFILE` and `PRODUCT` choose the profile and product for the `hardhat ignition deploy` command.

The HTML pages are not updated yet. They pin the commit they describe, so they follow in their own change once this one has a commit, as they did for the escrow rules. They still say 7 days and name `Components` and `Activate`.

### Step 2: `Gated721` (parked by the owner, 2026-10-30)

Reopened by the owner on 2026-11-05: the plan that replaces this one is "The NFT template" near the end of this file, re-derived from the code at `ce7c6c4`. What follows is kept as the design of 2026-10-30, and parts of it no longer hold (the transient kind slots and `_consumePending` were removed in #11; P2 and P4 were renumbered when step 3 was rewritten).

Not to be built until the owner reopens it. What follows is kept as the design for that day. While it is parked, the base split, the `IPolicyGated` re-pin and the `nft` profile do not apply.

**The split.** The ERC-20 base cannot be inherited by an ERC-721: `_update` has another shape, and frozen amounts have another meaning. The generic part moves to an abstract `contracts/base/PolicyGatedCoreUpgradeable.sol`: role constants, pause and unpause, the hook pointer and `_setHook`, `registry`, `revokeRole`, `_authorizeUpgrade`, the transient kind slots and `_consumePending`, `_inferKind`, `_accountAllowed`, and the init that grants roles and installs hook and rules. `PolicyGatedERC20Upgradeable` keeps `_update`, `_moveAs`, `_mintAs`, frozen amounts, `_check`, `_context`, `_canTransfer`, `_mintProbe`, mint, burn, `forcedTransfer` and `setFrozenTokens`.

- Behaviour does not change. Existing tests pass with edits only to pins and storage locations (nothing is deployed, so the layout is free: the core gets its own ERC-7201 location, and `frozen` stays with the ERC-20 base).
- `canSend` and `canReceive` stay thin wrappers on each token over the core's `_accountAllowed`, because both ERC-7943 interfaces declare them and `IERC7943Fungible`'s id must stay `0x3edbb4c4`.
- Interfaces: a new `IPolicyGatedCore` takes `pause`, `unpause`, `setPolicyHook`, `policyHook` and `registry` with their events and errors; `IPolicyGated` inherits it and its id is re-pinned (P2). Event topics do not change.
- The split is its own commit, before any NFT code. `Gated7540Vault` must stay under the limit; if it does not, stop and report.

**The token.** `contracts/tokens/Gated721.sol`, one concrete contract on `ERC721URIStorageUpgradeable` and the core, implementing ERC-7943's non-fungible interface (`0xbf1ef5fe`).

| Function | Who | Note |
|---|---|---|
| `mint(to, tokenId, uri)` | `MINTER_ROLE` | Plain `_mint`, no receiver callback |
| `burn(from, tokenId)` | `BURNER_ROLE` | Enforcement: may take a frozen token and clears the freeze |
| `forcedTransfer(from, to, tokenId)` | `AGENT_ROLE` | May take a frozen token and clears the freeze; `Frozen` before `Transfer`; `ForcedTransfer` and the base's `ForcedTransferBy` equivalent |
| `setFrozenTokens(account, tokenId, frozen)` | `AGENT_ROLE` | A bool per token, as the standard says; may name a token the account does not hold |
| `setTokenURI(tokenId, uri)` | `AGENT_ROLE` | Corrects metadata (P4) |
| `canTransfer`, `canTransferWithReason`, `getFrozenTokens`, `canSend`, `canReceive` | anyone | `canTransfer` leaves ownership to ERC-721, as the standard does, and is false for a frozen token or a policy rejection. `canTransferWithReason` says why the write would revert, ownership included |

- One `_update(to, tokenId, auth)` builds the context: `id = tokenId`, `amount = 1`, `extra = abi.encode(balanceOf(from), balanceOf(to))`. It runs the same order as the ERC-20: pause (except FORCED), frozen token (except FORCED and a burner's burn), hook, move, `afterTransfer`.
- A frozen token reverts with the standard's `ERC7943InsufficientUnfrozenBalance(account, tokenId)`, reason `INSUFFICIENT_UNFROZEN`. A policy rejection is `PolicyGated_TransferRejected(reason)`.
- `ProxyDeployer`, `ComplianceHook`, `CredentialRule`, `HolderRestrictionRule` and `SettlementWindowRule` take no change. That comes from reading them and the integration test must prove it. New profile `nft`; the profile check refuses `minPositionRule` and `fundHoldersRule` on it.

Tests first, `Gated721.t.sol`: every role gate; freeze, forced and burn with the `Frozen` order; a hook rejection changes nothing; pre-flight parity with the write; ids from solc against the standard's; upgrade checks; a reentrant `onERC721Received`; invariant that a holder can move exactly its unfrozen tokens. `RuleSetIntegration`: real hook, real rules, deployed through `ProxyDeployer`. Also `InterfaceFreeze`, `ContractSizes`, and `verify-reproducible.ts`'s list.

### Step 3: vaults that invest

Rewritten on 2026-10-30. The owner asked for institution-grade vaults from the best available ideas, written as our own code, made of simple legos that can be deployed together or alone. Nothing below is built. The sizes were measured on a throwaway copy that was then deleted.

**The legos**

```
                                 optional                    optional
investor ⇄ Gated4626Vault ────────────────────▶ Portfolio ⇄ ERC4626Adapter ⇄ any outside 4626
investor ⇄ Gated7540Vault ⇄ NavDesk ──────────▶ Portfolio ⇄ GuardedAccount ⇄ a custodian, a strategy
                              │ optional                        │
                              FeeModel                     CallValidators
```

| Lego | Its one job | Plugged into | Needed? |
|---|---|---|---|
| `GatedVaultBase` (abstract) | Holds what both vaults share | Both vaults | Always |
| `Gated4626Vault` | Issues shares with instant deposit and exit | Hook | Works alone |
| `Gated7540Vault` | Issues shares dealt in periods at one price | Hook, a settler | Needs `NavDesk` |
| `NavDesk` | Turns a reported value into an approved price, on a schedule | One 7540 vault | Required by a 7540 |
| `Portfolio` | Holds the money and limits where it may go | One vault | Optional |
| `ERC4626Adapter` | Holds one on-chain vault's shares and reads their value | Portfolio | Optional |
| `GuardedAccount` | Runs only the calls its validators allow | Portfolio | Optional |
| `ERC20CallValidator`, `ERC4626CallValidator` | Checks one call's parameters | `GuardedAccount` | Optional |
| `FeeModel` | Computes a period's fee | `NavDesk` or a 4626 | Optional |

**What the issuer launches.** Every row is a product on the same core, with the rules it lists. Someone who wants one product alone deploys the core and that row.

| Product | Legos | Profile |
|---|---|---|
| A plain token | `GatedToken` | `token` |
| A cash token | `IntentToken`, at its ledger's decimals | `token` |
| A fund whose money sits with one custodian | `Gated7540Vault`, `NavDesk` (cash account is the custodian) | `vault7540` |
| A fund with several custodians, a mandate and fees | + `Portfolio`, `GuardedAccount`, validators, `FeeModel` | `managed-fund` |
| A gated vault, money stays in it | `Gated4626Vault` | `vault4626` |
| Liquid yield in on-chain vaults | + `Portfolio`, `ERC4626Adapter` | `vault4626-invest` |
| Everything | All of it | `full` |

**Who owns the money.** Both vaults use priced money the same way: it goes to the vault's `Portfolio`, which decides where it goes through adapters. There are two kinds of money, and they never mix.

| Money | Belongs to | Where it sits | Who keeps the record |
|---|---|---|---|
| A pending deposit, claimable redemption cash (7540 only) | One investor | The 7540 vault, checked by the balance audit | The vault's `Request` per controller |
| Priced, working money | The vault as a whole | The `Portfolio` and its adapters | Share balances |

The `Portfolio` therefore has one owner, its vault, and no record per investor. A second per-investor record would be a second ledger that must always agree with the first, which rule 4 forbids. What differs between the vaults is the timing and the price, not the path:

| | `Gated4626Vault` | `Gated7540Vault` |
|---|---|---|
| Money reaches the `Portfolio` | At each deposit | At settlement, only the net |
| Price | Live, with a rate limit | Approved per period |
| It may invest in | On-chain only | On-chain, custodians, strategies |
| Money comes back | Instantly, if liquid | The desk raises it before proposing |

There is one `Portfolio` per vault (P12). Two vaults that want the same on-chain strategy each hold their own position in the target. One does not invest in the other: a gated 4626 whose price is stale still answers `totalAssets()` with its last value, so an `ERC4626Adapter` over it would read that value as fresh (outside review, flaw 4).

**Does `Gated7540Vault` inherit `Gated4626Vault`? No.** Of the 12 functions the 4626 defines, only `mint`, `burn`, `decimals` and `_update` are the same in the 7540. The 7540 would have to override the other 8 and claim to be a synchronous vault while its previews revert. Inheritance would add work and hide a false claim. Both inherit `GatedVaultBase` instead: those four functions and the cash check, with one `GatedVault_Unsupported` error.

**The cash check (P4).** On `withdraw` and `redeem` in both vaults, a `receiver` other than the owner (4626) or the controller (7540) must pass the policy as the receiver of an enforcement move, the zero-amount FORCED probe `recoverClaimable` uses. A holder paying itself is not checked, because a holder whose credential lapsed or whose attester was killed must still be able to leave. The brief's §6, `SECURITY.md:176` and `CredentialRuleVaults.t.sol` pin that and stay as they are. On the 7540, `requestRedeem` runs the same probe on a `controller` other than the owner; otherwise a holder could name a lapsed address as controller, and that address, paying itself, would collect the cash.

**The payer check (P16).** Money coming in gets the same probe. A payer other than the receiver (`deposit` and `mint` on the 4626) or the controller (`requestDeposit` on the 7540) must pass the policy. A receiver paying for itself is already judged by the mint probe. A custodian depositing for clients therefore needs its own credential, which replaces the earlier decision not to check the caller (`SECURITY.md:140`).

**The token's own address (outside review, item 3.4).** Today a 7540 vault needs a credential of its own to hold its escrow, so when that credential lapses every `requestRedeem` reverts with `CREDENTIAL_EXPIRED`. `CredentialRule` will pass `_account == _token` on both sides: on receive, so the escrow takes shares, and on send, so a settlement burn and a reject can move them out. `MinPositionRule` and `FundHoldersRule` already exempt that address. Stopping a vault stays with `pause()` and `HolderRestrictionRule`. A vault whose asset is gated still needs a credential on that asset's policy, because there it is an ordinary holder. The cost: a holder can now send tokens to the token's own address by mistake, and the agent recovers them with `forcedTransfer`, which on the 7540 is the case the surplus rule already allows. Step 3a also stops the test setup credentialing every 7540 vault (`fixtures.ts:313`) and keeps that only where the asset is gated, so the suite proves a vault works with no credential of its own. It also changes the brief's §7 and the runbook's KYC step (`README.md:222`), which say the attester credentials the vault (outside review of `016a005`).

#### `Gated7540Vault`: dealing periods (P5)

One period is open and requests join it. Everyone in a period gets the same price, settled in one transaction however many investors there are, and each investor claims later.

- `closePeriod()` (`SETTLER_ROLE`) closes the open period and opens the next. It reverts while an earlier closed period is unsettled, so at most one is closed.
- `requestDeposit` and `requestRedeem` keep their signatures and keep returning request id 0, which ERC-7540 defines as aggregated per controller, so the `IERC7540*` interfaces do not change. A controller's settled request rolls into its claimable amounts first. A controller with a request in an earlier unsettled period waits until it settles (`Gated7540Vault_EarlierRequestUnsettled`).
- `settlePeriod(nav, fee, cash, feeRecipient)` (`SETTLER_ROLE`, not while paused). The price takes the 4626's own form, so `decimals()` becomes the asset's plus 6. With `supply = totalSupply() + unclaimedShares`: shares for all deposits are `deposits × (supply + 1e6) / (nav + 1)`, assets for all redemptions are `redemptions × (nav + 1) / (supply + 1e6)`, both rounded down. The virtual amounts stop a donation inflating the price, and the extra decimals keep them from moving an honest one: across the whole fund they move value by `price − 1` smallest asset units, whatever its size. At a price of 10.00 on a 2-decimal asset that is 9 cents, which is 0.9 bps of a $1,000 fund and 0.0009 bps of a $1m one. It also means the first period needs no special case. Checked with a script on 2026-10-30, with a 1-unit first investor donating $1,000 before a victim's $1,000 period: in this form the victim keeps 99.99% and the attacker loses half the donation. The outside review found the earlier form of this plan (1e6 on both sides) pulled the price towards 1.00, −98 bps on a 2-decimal token holding $1m. Its proposed fix, exact NAV with par for an empty vault, is not taken: the victim gets 0 shares and the attacker doubles the money. It burns the redeemed escrow, then nets: only the difference between deposits and `assets + fee` moves to or from `cash`, so subscriptions pay redemptions. It pays the fee, then reverts unless the vault holds at least pending deposits plus claimable redemption cash (`Gated7540Vault_BalanceAudit`).
- Claims look the same from outside: `deposit`, `mint`, `redeem`, `withdraw`, with the existing eligibility checks. Given what was paid, the other side rounds down; given what is owed, the paid side rounds up. Shares are still minted at the claim, so every rule behaves as today (the minimum, the cap), and no rule judging an investor can block a whole period's settlement. The escrow burn does go through the hook, so freezing or locking the vault's own address with `HolderRestrictionRule` stops settlement, and that is a deliberate stop; its credential plays no part (step 3a). Rounding each claim down leaves at most one share unit per investor per period in `unclaimedShares`, for good. That is accepted, with a test that bounds it: 1,000 investors dealing daily for 10 years leave 3.65m units, against 1e20 units in 100m shares at 12 decimals, under a billionth of a basis point (outside review, flaw 3).
- `rejectDepositRequest`, `rejectRedeemRequest` and `recoverRedeemRequest` take `AGENT_ROLE` while the request's period is open. In a closed period they take `SETTLER_ROLE`, so `NavDesk` decides when (below). After settlement the agent uses `recoverClaimable`.
- One `Request { period, pending, paid, owed }` model and one set of private helpers serve both sides. This is what makes it fit, and it removes four near-identical claim bodies.
- Gone: `fulfillDeposit`, `fulfillRedeem`, `custody`, `setCustody`, `CustodyChanged`, `Fulfilled`, `FULFILLER_ROLE`, and `recoverRedeemRequest`'s `_releaseFrozen(address(this), …)`, which is dead code now that the escrow cannot be frozen. New: `SETTLER_ROLE`, `closePeriod`, `settlePeriod`, `openPeriod()`, `settledPeriod()`, `PeriodSettled(period, nav, supply, deposits, shares, redemptions, assets, fee)`, which is the on-chain NAV history.
- Kept: operators, gating `max*`, the escrow and its surplus rule, the refusal to freeze the escrow, indicative `totalAssets` and `convertTo*`, now counting unclaimed shares. `recoverClaimable` also lowers `unclaimedShares` by what it delivers, because its mint raises `totalSupply()` and those shares would otherwise count twice.

Measured on the throwaway copy, with the cash check, without the new getters and event: **24,228 bytes, 348 left.** Three getters and the 8-argument event measured another 242 on today's vault, 147 of it the getters, and one `dealingState()` view returning all three should cost less. The fixes above are not measured, so expect it to sit at or over the limit without a lever. Moving code into `GatedVaultBase` saves nothing, because each vault still contains it, and `_releaseFrozen` saves only 10. Removing OpenZeppelin's 4626 parent saves 240 bytes and removes the 8 unreachable-code warnings, since the 7540 overrides almost all of that parent (P13). 100 optimizer runs saved about 530 on an earlier version, but changes every contract's gas and bytecode, so it is the last resort. Per-period dealing limits cost another 225 and stay out of the first version (P11).

#### `NavDesk`: from a reported value to an approved price

Immutable, one per 7540 vault. It holds no money and has no role table: it asks the vault live. Immutable: `VAULT`. Timelock settings: `portfolio` (attested, or zero; when plugged it is both the cash account and the source of on-chain value), `custodianAccount` (the cash account when no portfolio is plugged; it approves the vault to pull), `periodLength`, `cooldown` (constants: at least 1 hour, at most 3 days), `maxReportAge`, `feeModel` (attested, or zero). Adding a `Portfolio` later is one timelock operation.

| Step | Function | Who | What it enforces |
|---|---|---|---|
| 1 | `closePeriod()` | Anyone, once `periodLength` has passed | Nobody chooses the cut-off |
| 2 | `propose(reported, reportHash, asOf, moves)` | `REPORTER_ROLE` | One at a time. `asOf` is not before the cut-off and not in the future, so a price is always struck after requests close. `moves` equals the source's count, so money crossing between reported and on-chain after the valuation cannot count twice. The source's prices are fresh. `nav = reported + pricedValue() - fee`, and it must be above zero while shares exist. The NAV, the fee, the new high-water mark, `reportHash`, the cash account and the fee recipient are frozen, because a timelock change can land inside the cooldown |
| 3 | `accept(proposalHash)` | `CHECKER_ROLE`, never the proposer | Two people on every price (P6). The hash covers the period, the NAV, the fee, the mark, `reportHash`, the cash account and the fee recipient, so a replaced proposal cannot pick up an approval meant for another |
| - | `cancel()` | `GUARDIAN_ROLE` or `CHECKER_ROLE` | Any time before execution |
| 4 | `execute()` | Anyone, after the cooldown and acceptance | The report is not older than `maxReportAge`. Calls `settlePeriod` with the frozen numbers. Reverts if the cash account is short, so the desk raises cash before proposing |

`reported` is one number covering everything not priced on-chain; the breakdown goes in the off-chain NAV pack that `reportHash` commits to. Because the price is frozen at the proposal, a move during the cooldown does not change it; the cooldown is when the guardian and checker look at it. If nothing can be approved, the period stays closed and new requests wait in the next one, which is a dealing suspension: nobody trades at a wrong price, and a large real loss takes hours rather than a timelock delay.

**A stuck period cannot trap a request.** A loss, an outage, a pause or short cash can all stop settlement. `refundRequest(controller, isDeposit)` and `recoverRequest(controller, to)` (`AGENT_ROLE`) forward to the vault's reject and recover, and work only with no proposal pending and the period closed for longer than `maxReportAge`. So cash that was never invested can always go back, one controller at a time, and because no price is on the table nobody can use a refund as a free option on a known price.

Replacing a `NavDesk`: with no proposal pending, one timelock batch swaps `SETTLER_ROLE` and calls the successor's one-shot `adopt(oldDesk)`, which reads the high-water mark, the fee clocks and the last cut-off live at that moment, so nothing is charged twice however long the timelock took.

**Result (2026-11-01), row 7.** `Gated7540Vault` deals in periods, with no `fulfill*`, `custody` or `FULFILLER_ROLE`, and `NavDesk` is built standing beside it. The 7540 no longer inherits OpenZeppelin's 4626 (P13), so the 8 "unreachable code" warnings are gone. It measures 24,320 bytes: a first build came to 24,701, and writing a `Request` through one helper rather than at five places saved 343; removing the full-claim branch, which a mutant showed changes nothing because `mulDiv(x, y, x)` is exact, saved 38. What the build settled:

- `Request` and `Book` are per side, `mapping(bool => ...)`, so one set of helpers serves deposits and redemptions. A `Request` is two slots, as agreed, with `toUint128` at the request and at the settlement, so a period whose claims could not be booked refuses at settlement, not at one investor's claim.
- A rejected request leaves its period's book, in either state of the period, so a refund out of a closed period is not priced.
- In a test with a 1-unit first investor and a $1,000 donation before a victim's $1,000 period, the victim gains and the attacker loses a third of the donation (the 2026-10-30 script's setup gave a half). The bound that matters is pinned: the victim keeps at least 99.98%.
- The fee is passed through and paid, and `NavDesk` passes zero until `FeeModel` arrives in row 8.
- From a parallel review: `maxReportAge` below `cooldown` would make every report stale before it could execute, so it is refused (`NavDesk_ReportAgeBelowCooldown`), and the NatSpec now says `nav` leaves out what the vault holds. No module deploys a `NavDesk` yet; `Product.ts` grants `SETTLER_ROLE` to a parameter until row 10.

Tests first: 134 failing against stubs in the vault's `closePeriod` and the desk's `propose`, then 2 for the age check. The test file's non-vacuity check now asks for each family of actions, because a rare action misses the odd run out of 256 by chance, and the handler takes requests back less often so that more of them live to settle.

#### `Portfolio`: where the money may go

Immutable, one per vault. Holds idle money. It asks the vault for roles live. Immutable: `VAULT`, `ASSET`, `ACCEPTS_REPORTED` (false for a 4626 vault, which refuses a portfolio that says otherwise). It gives its vault an allowance at construction.

| Action | Who | Delay |
|---|---|---|
| `addAdapter` (attested, this portfolio, this asset), `removeAdapter`, raise a cap, `writeOffAdapter`, `migrateTo` | The vault's `DEFAULT_ADMIN_ROLE` (the timelock) | The timelock delay (P26) |
| `allocate`, `deallocate`, `setLiquidityAdapter` | `ALLOCATOR_ROLE` | None, within caps |
| `deallocate`, lower a cap | `GUARDIAN_ROLE` | None (P7) |
| `raise(assets)`: pull a shortfall from the liquidity adapter | The vault | None |

- **Where money can go.** To an installed adapter, to the vault, or by a timelock operation to an attested successor for the same vault. Nowhere else.
- **Caps.** Each adapter names its risk ids at construction: one for itself and any it shares, for example one custodian. Each id has an absolute cap in assets and a relative cap as a share of the vault's `totalAssets()`. Checked on allocate only, so exits can push an id above its relative cap. Allocations move by the amount moved, never below zero, and for a priced adapter by the change in its value across the call. At most 8 adapters.
- **Plug to the vault and `NavDesk`.** `pricedValue()` (idle money plus every priced adapter), `priceFresh()`, `moves()` (counts allocations and deallocations), `liquidAssets()`.
- **An adapter that cannot be priced.** A failed read gives 0 with `fresh()` false, and that never counts as a loss: `priceFresh()` is false, dealing stops, and the last value stands.
- **What empty means.** A priced adapter is empty when it is fresh and its `value()` is zero. A reported adapter's money can be off-chain, so `value()` says nothing about it: it is empty when its on-chain balance and its allocation are both zero. `removeAdapter` needs an empty adapter, so an outage cannot orphan a position.
- **Write-off (P10).** `writeOffAdapter` (timelock) takes an adapter off the list and clears its allocation. A priced adapter qualifies only while it is not fresh, and the loss counts from the next accrual. A reported adapter qualifies at any time, which is how a custodian's loss clears the cap it left behind; its value was always the report, so the NAV does not move. The adapter keeps what it holds, and `writtenOff()` stays true for good. Adding it back brings the value in under the normal rules: at once through the next report or read on a 7540, under the rate limit on a 4626.
- **A position already there.** A priced adapter's value counts against its caps when it is installed, and it must be readable, so a position cannot come back from a write-off outside them; going over reverts until the timelock raises the cap (outside review of the portfolio, P-2). A reported adapter's money can be off-chain, so it comes back at zero, and the timelock sets its caps knowing that.
- **Replacing a `Portfolio`.** `migrateTo(successor)` needs no adapter installed. It moves the idle money. A timelock batch runs it with the plug change. A reported adapter's `PORTFOLIO` is immutable, so money still at a custodian is returned to the successor off-chain and appears in the next report.

**Result (2026-10-30), awaiting review.** Built standing alone: `contracts/portfolio/Portfolio.sol` (11,479 bytes) and `ERC4626Adapter.sol` (2,146 bytes), with `IPortfolio`, `IAdapter` and `IERC4626Adapter`. No vault plugs one in yet, so no vault behaves differently. The tests run against a real vault's roles, a real registry and a real ERC-4626 target. What the build settled:

- `deallocate(assets)` names no receiver: an adapter pays only its own portfolio, so the path cannot be pointed elsewhere.
- The registry is read from the vault at call time, because a lego that names its vault can be built before the vault exists.
- One `setCaps(id, absolute, relativeBps)`: the admin sets anything, the guardian may only lower. A zero absolute cap allows nothing, and 10,000 basis points is no relative limit, so a vault with no assets yet can still allocate under an absolute cap.
- An adapter that names no risk is refused, because it would sit outside every cap. One that named an id twice only reaches that cap sooner and unwinds to zero, so `riskIds` documents "each once" and no check was added (outside review, P-4).
- `pricedValue()` reverts in the middle of a move, when the money is in neither place or in both, so nothing can price against a half-finished transfer. `allocate` reads the vault's total before taking the guard, because a plugged vault's total will ask the portfolio.
- `AttestKind` gains `PORTFOLIO` and `ADAPTER` only. The compiler checks an enum's range wherever it is encoded, so every contract that uses it changes by that one number and no size changes: one byte in the four templates, `ProxyDeployer`, `Fund` and `ComplianceHook`, nine bytes in `PolicyRegistry`. Nothing is deployed, so nothing migrates. On a live stack an appended value would change the codehash of each of those, so it would be part of an upgrade and a new attestation.

Tests first: 24 failing against stubs, then 10 failing for the review's fixes. `npx hardhat test`: `1300 passing (1159 solidity, 141 nodejs)`, and the isolated profile passes 1159. Slither 0, Aderyn 0, `validate:upgrades` 4 of 4, `verify:reproducible` 20 contracts identical, mutants 87 of 87: 78 before the review's fixes, with the ones on the changed lines rerun after them, and 9 new. The first mutant run left 2 alive, a price stale before a call that recovers during it and a priced adapter that charges on the way out, and each now has a test. Another left one alive that showed a condition did nothing, and the condition is gone.

Not done here: plugging it into a vault (3b and 3e), its deployment module and the `ALLOCATOR_ROLE` hand-over check, the Halmos property on caps, and the HTML pages.

#### Adapters

`IAdapter`: `allocate(assets)`, `deallocate(assets)`, `value()`, `liquid()`, `fresh()`, `reported()`, `riskIds()`, `PORTFOLIO()`, `asset()`. Each is immutable and attested.

- **`ERC4626Adapter`.** Immutable `PORTFOLIO` and `TARGET`. Deposits into the target, withdraws to the portfolio, values with `previewRedeem` of its whole balance, and reads liquidity with `maxWithdraw`. Not reported. This reaches any outside ERC-4626 vault as an ordinary depositor. Some vaults' `max*` always return 0 by design while their `withdraw` and `redeem` work, so against such a target `liquid()` reads 0: a 4626 holder's instant exit is limited to idle money, and the desk keeps that buffer. Standard vaults report real liquidity. A 7540 is unaffected, since the desk raises cash before it proposes. The council reads the target's curator and caps before attesting, because the codehash covers the target's address and not its behaviour, and it does not attest an adapter whose target is a gated vault of ours.
- **`GuardedAccount`.** Runs strategies and custody with one contract. `execute(Call[] calls)` (`ALLOCATOR_ROLE`, atomic) makes plain calls only: no delegatecall, no value, no modules, no ERC-7579 and no ERC-4337. Each call needs a permission for its target and function, and the permission's validator must accept the parameters. **No validator means refused**, so nothing passes by omission. `setPermission(target, selector, validator)` is timelock and attested; `revokePermission` is timelock or guardian. Reported, so it refuses a `Portfolio` that does not accept reported adapters. `deallocate` pays only from its own balance to its portfolio.
- **`ERC20CallValidator`.** Immutable `who` and `maxPerCall`: allows `transfer` to exactly that address or `approve` of exactly that spender, up to that amount, and nothing else. All settings are immutables, so the attested codehash covers them. A custodian is a `GuardedAccount` with one permission: the asset's `transfer` with a validator naming the custodian. The custodian returns money by sending it to the account.
- **`ERC4626CallValidator`.** Allows `deposit`, `mint`, `withdraw`, `redeem` when the receiver and owner are the calling account.

#### `FeeModel`

Immutable, no storage, one view: `quote(grossNav, supply, mark, markAge, feeAge)` returns `(fee, newMark, markMoved)`. Immutables: management rate, performance rate, hurdle rate, hard or soft hurdle, recipient, each under a constant ceiling (50% performance, 5% a year management). Changing fees means deploying a new one and a timelock swap, and the attested codehash covers the rates. The caller keeps `mark`, the time the mark last moved and the time of the last fee.

- **Management fee:** the gross value × rate × `feeAge` / one year.
- **Performance fee (P14):** the hurdle compounds from when the mark last moved: `hurdled = mark × (1 + hurdle rate × markAge / one year)`. Below `hurdled`, no fee and the mark stays. Above it, a hard hurdle charges `rate × (gross - hurdled)`, a soft hurdle charges `min(rate × (gross - mark), gross - hurdled)`, and the mark moves to the price after fees, which is never below `hurdled`. The cap is a full catch-up: the investor keeps everything up to `hurdled`, then the manager takes what is above it until it has its rate of the whole gain, so net value never falls as gross rises (outside review, flaw 2). Because the hurdle runs on `markAge` and not on the time since the last call, it cannot be cleared by slicing a gain across many periods or calls, and it does not matter who calls. The price is measured after the management fee.
- **Starting mark:** the opening price, so the first gain is measured from there and principal is never charged.
- **No shares:** with `supply` at zero it returns no fee and the mark unchanged, so value donated before the first period is not charged, and the caller restarts both clocks, so the first investors do not pay for time before they arrived. A fund that empties and reopens keeps its old mark while its price restarts at par, which only favours the new investors, and that is accepted (outside review of `016a005`).

Fees are paid in assets, so no shares are minted and the policy and the holder cap are not touched (P9). It must not revert on any input.

#### `Gated4626Vault` with a `Portfolio`

With none plugged it behaves exactly as today. `setPortfolio` (timelock) checks the attestation, `VAULT()`, that the portfolio refuses reported adapters, and that the old one is empty. It forwards the vault's balance to the new portfolio and adds that amount to `last`. A first plug so starts from the money the vault held, and a replacement keeps its price, because `migrateTo` has already moved the money and a donation to the new portfolio counts only under the rate limit. It also reads the old portfolio's `writtenOff()` and keeps the answer, because a successor starts clear (outside review of the portfolio, P-1 and P-3). Once plugged the vault holds no working money:

- `_deposit` forwards the assets to the portfolio. `_withdraw` calls `raise`, pulls, then pays.
- `totalAssets() = min(pricedValue() - feesOwed, last + last × elapsed × maxRate)`, with the subtraction stopping at zero: after a near-total loss the fees owed can exceed the value, and ERC-4626 says `totalAssets` must not revert (outside review of `016a005`). Losses count at once, gains are limited, and none count again in the same block. Deposits and withdrawals move `last` by exactly their amount. A donation cannot jump the price. `maxRate` is raised by the timelock and lowered by the guardian, and plugging a portfolio must set it. This limit lives here because this is the only vault with a live price; `NavDesk` has the checker and cooldown instead.
- While `priceFresh()` is false, `totalAssets()` returns the last counted value, and deposits and withdrawals stop.
- Once its portfolio has written off an adapter (`writtenOff()`), the vault is exit-only: `maxDeposit` and `maxMint` are zero for good (P15). Someone depositing at the written-down price would otherwise take part of any recovery from the holders who bore the loss, and a recovery counts only under the rate limit. New money goes to a new vault.
- `maxWithdraw` and `maxRedeem` are limited by `liquidAssets()`, so `redeem(maxRedeem(o))` still succeeds.
- With a `FeeModel` plugged, each accrual quotes it on the counted value, so fees are charged only on gains that have passed the rate limit, and adds to `feesOwed`; `collectFees()` pays the recipient from idle money.

**Result (2026-11-01), row 8.** `GuardedAccount`, `ERC20CallValidator` and `ERC4626CallValidator` (3c), `FeeModel` on `NavDesk` (3d), and the 4626 with a `Portfolio` (3e). `AttestKind` gains `VALIDATOR` and `FEE_MODEL`. Sizes: `Gated4626Vault` 23,282, `NavDesk` 9,624, `GuardedAccount` 4,189, `FeeModel` 1,380. Skipping `reported()` behind `ACCEPTS_REPORTED` takes `pricedValue()` from 19,860 to 14,292 gas with 8 mock adapters. What the build settled:

- `totalAssets` includes the fee due now, and every deposit and withdrawal counts first, so a price quoted by a preview is the price paid. `accrue()` is public and emits `Accrued`.
- `maxRedeem` compares in assets before converting: converting the liquid assets to shares rounds down, and left dust stuck in a position that was wholly liquid. A test found that.
- A proposal freezes the mark's clock too (`markMovedAt`), and the hash covers it. `lastFeeAt` moves to the proposal's time at execution, so the gap between proposing and executing is charged next time.
- A first plug of a fee model starts the mark at `convertToAssets(1e18)`, the current price, rather than the opening price the plan named. On a fund that already has gains the opening price would charge those gains, and on a new fund the two are the same.
- A model replaced with fees owed pays them to the new recipient, so the batch that swaps it collects first. That is recorded in `SECURITY.md`.
- `GuardedAccount.setPermission` refuses its own portfolio, vault and self, and `allocate` is a no-op for the portfolio to call: the money waits there until the allocator sends it on.

Tests first: 51 failing against stubs. Mutants: 106 in the first run, with 8 alive. Two showed code that did nothing, a `Math.max` in `FeeModel` and a length check in `ERC4626CallValidator`, and both are gone. Five were missing tests, which now exist: the management and performance fees added together, the 4626's mark, its clock restarting with no shares, fees owed not counted again, and the rate limit's clock running through an outage. One is equivalent: at exactly the hurdle `<` and `<=` both charge nothing. Rerun on the changed lines: 8 of 8.

#### Attestation and deployment

`AttestKind` gains `PORTFOLIO` and `ADAPTER` (built), then `VALIDATOR` and `FEE_MODEL` with their legos, each appended so existing values keep their numbers (P2). `setPortfolio`, `addAdapter`, `setPermission` and `setFeeModel` enforce them. `SETTLER_ROLE` is a plain role grant, since checking it in the vault would spend its margin, so the hand-over check pins the holder and `NavDesk.isWired()` shows it to monitors.

A lego that names its vault is built before the vault exists: `ProxyDeployer.predict(symbol, implementation)` gives the address, and the council attests the product's legos before the launch. A profile gains optional `nav`, `portfolio`, `adapters` and `fees` sections, and the product module plugs only what is listed, while the operations multisig is still admin. `assertHandedOver` checks `SETTLER_ROLE`, `REPORTER_ROLE`, `CHECKER_ROLE` and `ALLOCATOR_ROLE` explicitly, since these ids live outside the vault's role scan, and that the reporter, the checker and the allocator are three different accounts. Adding a lego later is a timelock operation.

#### Built in this order, one PR each, stopping for review after each

The owner asked on 2026-10-30 to see the `Portfolio` first, and nothing in it depends on 3a or 3b, so it comes first, standing alone over today's vaults. Plugging it in follows with 3b and 3e.

| # | Content | Result |
|---|---|---|
| 3p | `Portfolio` and `ERC4626Adapter`, standing alone | Where a vault's money may go, tested against a real vault's roles and a real ERC-4626 target. No vault sends it money yet |
| 3a | `GatedVaultBase`, the cash check, the payer check and the token's own address in `CredentialRule` | Money in and money out are both screened, and a vault's own credential cannot stop it |
| 3b | `Gated7540Vault` dealing periods and `NavDesk` | A real fund with one custodian (`vault7540`) |
| 3c | `GuardedAccount` and the two validators, on the 7540 | Several custodians and a mandate (`managed-fund`) |
| 3d | `FeeModel` on `NavDesk` | The fund charges fees |
| 3e | The 4626 with a `Portfolio`, fees on the 4626 | On-chain investing (`vault4626-invest`) |

#### Tests first

3b rewrites the 7540's test file and helpers: 78 lines of `Gated7540Vault.t.sol` use the old functions, with smaller changes in `CredentialRuleVaults.t.sol`, `FundIntegration.t.sol`, `FundInvariant.t.sol`, `vaults.test.ts`, `fund.test.ts`, `fixtures.ts`, `Product.ts` and `roles.ts`. New mocks: `MockERC4626Target` and a variant whose `max*` return 0, `MockReentrantTarget`, `MockRevertingTarget`.

- **Cash check:** a lapsed holder and a holder of a killed attester still redeem to themselves; a payment to an uncredentialed third party reverts on both vaults; a credentialed third party is paid; `requestRedeem` naming a lapsed controller reverts. **Payer check:** an uncredentialed payer is refused on both vaults; a credentialed custodian paying for a client works; a receiver paying for itself is unaffected. **The token's own address:** with the vault's credential lapsed, blocked or never issued, `requestRedeem`, a reject and the escrow burn all work, on both `check` and the account-level answers; a vault still needs a credential on a gated asset; shares sent to the token's own address by mistake come back through `forcedTransfer`.
- **Periods:** a whole cycle; two investors in one period get one price, and investors in different periods get their own; a request after the cut-off joins the next period; a controller waits while an earlier request is unsettled; reject and recover only while open; netting in both directions and at exactly zero; the balance audit fires when money is missing. **The price:** away from 1.00, at 2, 6 and 18 asset decimals and at small and large NAVs, all of `supply` valued at the period's price stays within `|price − 1| + 1` smallest asset units of `nav`, and `decimals()` is the asset's plus 6. **The inflation attack:** a 1-unit first investor donates to the portfolio and to the custodian before a victim's period, and the victim keeps its value. **A stuck period:** total loss, outage, pause and short cash each leave every request refundable once `maxReportAge` has passed, and `refundRequest` refuses while a proposal is pending and before that time. Fuzz: the sum of all claims never exceeds what the period booked, and falls short by at most one unit per investor; `recoverClaimable` leaves `supply` unchanged. Invariant: the vault always holds pending deposits plus claimable redemption cash. Gas: `settlePeriod` costs the same for 1 investor and 200.
- **`NavDesk`:** each gate, with `asOf` at the exact cut-off, a stale report, a wrong `moves`, the proposer accepting its own proposal, execution before the cooldown and without acceptance, cancel by each role, a proposal over a total loss, and `adopt` after a long timelock delay charging nothing twice.
- **`Portfolio`:** every gate reads the vault live, and a revoked guardian loses its powers at once; caps at the exact boundary, shared ids, allocate only; refused adapters (unattested, wrong portfolio, wrong asset, reported on a 4626); money moves only along the listed paths; an outage holds the value, and after recovery the price is what it was; `removeAdapter` refuses during an outage and on a reported adapter with money or an allocation; a write-off counts the loss on a priced adapter, leaves the NAV alone on a reported one, and adding either back works, with a priced position counted against its caps at once; `writtenOff()` stays set; a reentrant target and a reverting target.
- **`GuardedAccount` and validators:** no validator refuses; each validator's boundary (`maxPerCall`, the wrong address, every other function); `transferFrom` and `increaseAllowance` refused; a revoked permission refuses at once; a call to the portfolio or vault refused; atomic failure; custody out and back.
- **`FeeModel`:** fuzz that it never reverts and that a fee never exceeds the gross value; no performance fee below the mark; hard against soft at the hurdle; fuzz that the net price never falls as the gross rises, and is never below `hurdled` once a fee is charged; a steady return below the hurdle pays no performance fee however many periods it is split into, and the same on the 4626 however many calls; the first gain is measured from the opening price; the frozen fee is the fee paid; with no shares there is no fee and the mark stays, even with value present, and the first investors pay nothing for time before they arrived.
- **4626 with a portfolio:** a withdrawal above idle uses the liquidity adapter; `redeem(maxRedeem(o))` succeeds and one more reverts; a target outage stops deposits and withdrawals; a donation cannot pass the limit; `setPortfolio` on a vault holding money keeps the price; after a write-off deposits stay closed and exits work; replacing the portfolio keeps the price and the exit-only state; with a target that reports no liquidity, exit is limited to idle money; a loss below the fees owed reads as zero, and `totalAssets` and `maxRedeem` do not revert. Fuzz: a round trip in one block never profits.
- **Each profile:** deploys alone, passes the hand-over check, and contains exactly its legos.
- **Node:** both flows end to end with event decoding, rebuilding the NAV history from `PeriodSettled`.
- **Mutants**, recorded in `SECURITY.md` section 5: each gate, cap, freshness check, money path, the rounding, the netting, the balance audit, the forward-pricing check, the checker-not-proposer check, the cash check and its exemption. **Halmos:** the sum of claims against the booked total, and an allocation never passes a cap on allocate.

### Step 4: what an institution will ask for

Added on 2026-10-30 after an assessment against what regulated institutions work under. A codebase cannot be compliant on its own: a regulator judges the legal terms, the operators, the chain and the code together. This step covers the code. Step 5 covers the rest.

| # | Gap | Design | Decision |
|---|---|---|---|
| 4a | Every record publishes a country on-chain, and no rule reads it | Remove `country` from `Record`, `Credential`, `CredentialSet`, `profileOf` and the EIP-712 type. Name jurisdiction groups as qualification bits, for example `US_PERSON` or `EEA`, in `Quals` bits 8 to 15. A token's existing `requireAny` and `forbidAny` already express an offering restriction, so no new rule is needed. The attester publishes only what a policy needs, not where someone lives | P18 |
| 4b | A stolen minter key mints without limit, and nothing requires two people on mint, burn or forced transfer | `SupplyCapRule`: refuses a `MINT` above a per-token cap set by the token's admin; FORCED mints are exempt; on tokens only, because it would refuse the vaults' mint probe. `assertHandedOver` requires `MINTER_ROLE`, `BURNER_ROLE` and `AGENT_ROLE` to be held by a Safe with a threshold of at least 2, unless the profile names an exception, for example an MPC custody wallet whose policy engine does the same job | P17 |
| 4c | A plain transfer carries no reference to the issuer's message | `ExecutedOnlyRule`: refuses `TRANSFER`, so every movement between holders is a signed intent with its `ref` (the ISO 20022 message hash) and goes through an executor. About 30 lines, optional. Originator and beneficiary data stay off-chain, in the issuer's own message | P22 |
| 4d | No dividends, coupons or record dates, while rights to cash flows are part of what a token can represent | `Distributor`: immutable, one per token, one job: pays a funded distribution to holders. The record is a Merkle root of `(holder, amount)` built off-chain at the record date. A maker and a different checker approve it, then holders claim with a proof. A holder who may not receive cannot claim. Unclaimed money returns to the issuer after an expiry. The token gains no snapshots or checkpoints, so it stays small and transfers cost the same. Built when the first bond or equity client needs it | P19 |
| 4e | Clients' holdings are not the issuer's exposure, but its own seed money, warehousing and market-making are. Offering clients on-chain yield also brings suitability and product-approval duties | A `managed-fund` profile: `Gated7540Vault`, `NavDesk`, `Portfolio` and custodian `GuardedAccount`s only. The profile check refuses `ERC4626Adapter` and any validator that reaches a non-custody target. The issuer can launch `vault4626-invest` as a separate product once risk has approved it and any exposure of its own is classified with its regulator | P21 |

A lapsed holder can still transfer out (`SECURITY.md:176`), deliberately, so that a holder can always leave. An issuer's AML team may prefer redemption only. It needs no code: an attester can set a holder's status to blocked, and an agent can freeze it (P20).

Tests first, as for every rule: `SupplyCapRule.t.sol` and `ExecutedOnlyRule.t.sol` (accept, each reject, fuzz, view-ness, integration with a real hook); `Distributor.t.sol` (a proof for the wrong holder, a double claim, a blocked holder, the expiry, the checker not being the maker, and a sum of claims above the funding); `CredentialRegistry.t.sol` and every fixture updated for the removed field, with the EIP-712 type re-pinned; the hand-over check refusing a single-signer role holder and accepting a named exception.

### Step 5: before real money (the owner's, not built here)

We are the issuer, so this falls on us. The country is not yet known, and the rules differ by country.

- **Legal.** A legal review showing the rights are enforceable and settlement is final, and terms for every product. Whether the chain is the legal register or a copy of one must be decided.
- **Ring-fencing.** A fund's assets must stay out of reach if the issuer fails. Contracts can keep them apart, but only the legal structure protects them.
- **The cash token.** The rules on holding client money, and the record of each customer's balance.
- **Regulator.** Tell the regulator before acting, classify each asset the issuer is exposed to, and accept that it can override us.
- **Our own operational rules.** The issuer is the regulated operator, so ICT risk management, incident reporting, resilience testing and an exit plan from the chain are ours under the local rules. Custody, cloud and node suppliers are our third parties.
- **Daily reconciliation.** On-chain supply and positions against the issuer's ledger, with client statements and regulatory reports built from the events.
- **Insider risk.** Signers drawn from functions that check each other, and surveillance over the events. A maker and a checker from one team defeat the design.
- **Written procedures.** AML, sanctions and travel-rule process, key management and business continuity. None is written today, and the docs never mention AML, sanctions or the travel rule. Test coverage and a bug bounty are also missing.
- **An external audit** of everything, which must include the vaults, the credential layer and every new lego: the 2026-10-26 review left out the first two.

### What this does not solve

- **A custodian's honesty.** A report is a claim, and the hash only proves which report was used. It does not prove the money exists.
- **A maker and checker who collude.** The cooldown, the guardian's cancel and the published hash make that harder and traceable. They do not prevent it.
- **A custodian that does not return money.** That risk stays off-chain.
- **A run.** A redemption gate, built in #25, limits what may leave a 7540 in one period, net of deposits, as a share of all shares (`NavDesk.setRedemptionGate`, the timelock; zero is off). Past it every request is filled at the same fraction and the rest carries to the next period. With the gate off, or when the cash the desk can raise does not cover even the part the gate lets through, settlement cannot run and dealing stops for everyone until it can.
- **A total loss.** With nothing to count and shares outstanding, dealing stops. Unsettled requests can still be refunded. Beyond that it is a wind-down, not a state the contracts recover from.
- **A gap in a `GuardedAccount`'s permissions.** It is the most dangerous new lego. Default deny, one narrow validator per call and a timelock on every grant reduce that, and only a review of each permission set closes it. An `approve` gives the spender up to what it allows.
- **Fairness between investors on the performance fee.** One high-water mark per vault, no investor-level equalisation, so someone entering below the mark pays no performance fee until it is passed.
- **Target liquidity.** A 4626 holder's exit is limited to idle money plus what the liquidity adapter can return, which is nothing against a target that reports no liquidity.
- **Bad choices within limits.** The desk can pick a poor but allowed allocation. The timelock decides what is allowed.
- **Who holds `SETTLER_ROLE`.** The timelock can grant it to any address, and that holder sets any price and can name any `cash` account, so it can pull from any wallet that has approved the vault. That is delayed and visible, not prevented, and an upgrade through the timelock could do the same.
- **The investor cap while requests are open (P27, accepted for the first version).** A full `requestRedeem` frees the investor's slot while the shares are still unburned, and `requestDeposit` reserves none, so a reject or a second claim can revert with `MAX_HOLDERS`. The agent's recovery always works, and then counts the investor above the cap. A redemption gate makes this last longer, because a queued investor stays out of the count for as long as they queue.
- **A wrong report inside the checker's approval.** Two people can approve a wrong price, and a correction moves it back. Whoever dealt in between keeps the difference.
- **`redeem(maxRedeem(o))` with a minimum.** On a 4626 limited by liquidity, with a minimum position set, the remainder can fall below the minimum and the exact call reverts.

### Decisions for the owner (recommendation first)

P2 to P22 were answered by the owner on 2026-10-30, every row as recommended, with the reasoning of P21 updated when the owner said to think as the issuer. P1 changed on the same instruction, and P26 and P27 were decided the same day. P23 and P24 were answered as recommended on 2026-11-01, and P25 with both options, product by product. No code depends on the three. The last column stays as the record of what was not taken.

| # | Question | Recommendation | Alternative |
|---|---|---|---|
| P1 | One stack per issuer, or one per client? | **Changed by the owner's instruction of 2026-10-30, replacing "one stack per client".** One stack per issuer, with many products inside. A client is verified once, a block applies everywhere, and each fund keeps its own `Portfolio`. | One stack per client or fund. Full isolation, with many copies to run and a client verified once per stack. |
| P2 | Reopen the freeze (rule 4) for: `IGated7540Vault` rewritten; new functions on `IGated4626Vault`; four appended `AttestKind` values; new interfaces for the new legos; `GatedVault_Unsupported`? | Yes, one reopening per row of step 3, each pinned in `InterfaceFreeze.t.sol`. Deployed code does not exist, so nothing migrates. | None that keeps this design. |
| P3 | A plain `GatedToken` template? | Yes, about 30 lines over the base. A client who wants one token gets no signed-intent code, and `IntentToken` becomes the same token plus one mixin. | `IntentToken` with `EXECUTOR_ROLE` left empty. No new contract, more code in every token. |
| P4 | Must the receiver of redemption cash pass the policy? | Yes when the receiver is someone else. A holder paying itself is exempt. A client's omnibus or settlement account needs a credential. | Leave it open and record it as accepted in `SECURITY.md`. |
| P5 | Dealing periods instead of per-investor fulfilment? | Yes. One price for everyone, one transaction however many investors, no desk timing or favouring, netting. An investor with an unsettled earlier request waits until it settles. It rewrites the 7540's core, so it is the highest audit priority. | Keep per-investor fulfilment with a fixed price per round. Far less change, and the desk still picks who deals in which round. |
| P6 | Two people on every price? | Yes: maker and checker every time. It is what an institution expects, and it removes the tolerance logic entirely. Two signers are needed every dealing day. | A checker only above a tolerance. Fewer signers, more code, and small moves get one pair of eyes. |
| P7 | Does the guardian get powers that reduce risk (pull money back, lower caps and the max rate), plus cancelling a price and revoking a call permission? | Yes. They only reduce risk, so "the guardian can only stop things" still holds. | A separate sentinel role, or none, which leaves pause as the only fast response. |
| P8 | Reported prices only behind the 7540? | Yes. On an instant vault a stale price is free money for whoever notices first. | None recommended. |
| P9 | Fees in assets, with a high-water mark and a hurdle, in an immutable `FeeModel`? | Yes. Simple, no policy interaction, and the terms institutions expect. | Fee shares, which need a credentialed recipient and a free holder slot. Or no hurdle, which is less code and fewer terms to offer. |
| P10 | What happens to an on-chain adapter that can never be priced again? | A timelock write-off, with the delay as public notice. Holders take the loss and the vault deals again. A reported adapter's value is reported and approved by two people, so its write-off only clears the cap it left behind. | Suspension until it answers. Nobody takes a loss they did not choose, and the whole vault may stay frozen forever. |
| P11 | Left out of the first version: per-period dealing limits, pro-rata redemption gates, a forced exit. Agreed? | Yes. Limits cost 225 of the 7540's 348 spare bytes, and gates need requests that part-settle across periods. **Gates reversed by the owner, 2026-11-02:** size must not decide this. See the redemption gate section. Limits and a forced exit stay out until a product asks for them. | Add limits now and accept 123 spare bytes, before the new getters and event. |
| P12 | One `Portfolio` per vault, or one shared by several? | **Decided by the owner, 2026-10-30: one per vault.** A shared one would need an internal ledger between vaults, one vault's exit would drain another's liquidity, and a 4626 would inherit reported prices, which P8 rules out. Two vaults that want the same on-chain strategy each hold their own position in the target. | Not taken. |
| P13 | How does the 7540 fit the size limit? | Drop OpenZeppelin's 4626 parent from the 7540 only, as an exception to rule 10. It saves 240 bytes, removes dead inheritance and its 8 compiler warnings, and touches no other contract. | 100 optimizer runs. Saves about 530 and keeps rule 10, but changes every contract's gas and bytecode. |
| P14 | How does the hurdle work over time? | It compounds from when the mark last moved, and the mark moves only when a performance fee is charged. A slow fund pays no performance fee, and it cannot be gamed by frequent calls. | It restarts each period. Simpler to explain, but a return below the hurdle can still pay a performance fee. |
| P15 | What can a 4626 do after a write-off? | Exit only, for good. Nobody buys a recovery from the holders who took the loss. New money goes to a new vault. | Deposits reopen at the written-down price. The vault lives on, and a depositor in the trough takes a share of any recovery. |
| P16 | Who may pay into a vault? | A payer other than the receiver or controller must pass the policy. Source of funds is the first AML question. A custodian needs a credential. | Leave it open, as today, and rely on off-chain screening. |
| P17 | How are mint, burn and forced transfer limited? | `SupplyCapRule` on tokens, and a hand-over check that those roles sit with a Safe of at least 2 signers, or a named exception. No new money-moving contract, and issuers keep their own approval tools. | An on-chain maker-checker lego for enforcement actions, with a delay. Stronger and self-enforcing, but one more contract to audit and slower in an emergency. |
| P18 | How is jurisdiction expressed? | Qualification bits, and remove `country`. No new rule, and fewer personal details on a public chain. Whether an address with a credential is still personal data is for counsel. | Keep `country` and build a `JurisdictionRule`. Finer control, and every holder's country stays public. |
| P19 | How are distributions paid? | A `Distributor` with an approved Merkle root, built when the first bond or equity client needs it. No change to the token. | Checkpoints in the token, so the record is on-chain. No off-chain step, and more gas on every transfer and more bytes in every token. |
| P20 | Can a lapsed holder still transfer? | Yes, as built, and documented. The tools to stop one exist: block or freeze. | A per-token switch in `CredentialRule`. More code, and a holder may have no way to leave a token that has no redemption. |
| P21 | Should managed funds exclude on-chain yield by default? | Yes, through the `managed-fund` profile. Clients' holdings are not the issuer's exposure, but its own seed money and market-making are, and clients bring suitability and product-approval duties. `vault4626-invest` stays available as a separate product once risk has approved it. | Offer it from the start and classify case by case. |
| P22 | Build `ExecutedOnlyRule`? | Yes, as an optional rule of about 30 lines. It ties every holder-to-holder movement to the issuer's message. | Leave plain transfers open and reconcile off-chain. |
| P23 | Which chain? | **Decided by the owner, 2026-11-01:** a permissioned EVM with Cancun. It avoids publishing client balances and movements, and the issuer chooses the validators. It gives up public lending vaults and public stablecoins, which `managed-fund` leaves out anyway. | A public chain or L2. Reaches public liquidity, with client positions public unless a privacy layer is added, and validators outside the issuer's control. |
| P24 | Who holds clients' keys? | **Decided by the owner, 2026-11-01:** custody by the issuer by default, one address per client, in MPC or HSM. Clients need no wallet or gas. Institutions can bring their own wallet with a credential. A custody compromise is the worst case. | Clients hold their own keys. Less custody risk, but clients need wallets and gas, a lost key becomes a forced-transfer case, and vault entry goes through signed entry. |
| P25 | What do clients pay with? | **Decided by the owner, 2026-11-01: both, product by product.** Our own cash token, an `IntentToken` limited to customers, whose DvP cash leg settles by signed intent; an external stablecoin where a product calls for one. No code changes: a vault names its asset at deployment, `DvPExecutor` settles either form (`executeDvPGated`, `executeDvP3009`), and `SignedEntry` takes `permit` or ERC-3009. Two limits: a stablecoin without ERC-3009 can be a vault's asset but not a DvP cash leg, and with P23 it has to be bridged or issued on the permissioned chain. Our own token brings the rules on holding client money, and an external one brings another issuer's risk. | Only one of the two. |
| P26 | How long is the timelock delay, and what waits for it? | **Decided by the owner, 2026-10-30: 24 hours,** replacing 7 days. Set at deployment, with a constant floor of 1 hour so that a compromised governance cannot take it to zero. The guardian has a day to cancel a bad change. A product launch does not wait at all. | 48 hours, for more cancel time. Or keep 7 days for upgrades only, which needs a second timelock. |
| P27 | Does an investor with an open request count under a fund's investor cap? | **Decided by the owner, 2026-10-30: accept the first version as it is** (outside review, items 3.2 and 3.3). The agent rejects deposits near the cap, a monitor watches the count going over it, and recovery always works. No cheap contract fix exists: the 7540 has almost no room and settlement cannot loop over investors. Whether a redeeming investor still counts as a holder remains a question for counsel, and a different answer reopens this row. Since 2026-11-02 the vault's room is no reason on its own (see the redemption gate section); the rest of this answer stands. | Count an investor until the redemption settles, and reserve a slot at `requestDeposit`. The count is always exact, and it needs its own design in `Fund` and per-request bookkeeping in a vault with no room. |

### Agreed order (owner, 2026-10-30)

Set after three sessions assessed the stack and checked each other's findings. One PR each, tests first, stopping for review after each. Merging is the owner's.

| # | What | Why here | Evidence |
|---|---|---|---|
| 1 | 3p, `Portfolio` and `ERC4626Adapter` (PR #11) | Built | Result above |
| 2 | Remove `_KIND_SLOT`, `_REF_SLOT`, `_DEADLINE_SLOT` and `_consumePending`. `_moveAs` and `_mintAs` pass their arguments to one `_move` | Room for 3b before it is needed, and it removes the hidden channel between `_moveAs` and `_update` | On `8835283`: 7540 23,988 to 23,636 bytes. With a mocked hook, warm: plain transfer -216 gas, forced and executed -1,595 |
| 3 | `canExecute(intent, sig, executor)`: check the role and the binding against the argument, and add a reason for a zero `to`. Reopens `ITransferIntent` | Pre-flight must not lie before more is built on it | Tests on `8835283`: true for a caller with no role while the call reverts; `WRONG_EXECUTOR` for a stranger on an intent the named executor could run; true for a zero `to` when the rules agree, while the call reverts |
| 4 | `Portfolio.allocate(adapter, assets, minAdded)`: revert when a priced adapter's value grows by less | An allocator approves what it sends, and the target decides what comes back | `_added` can be 0 today and the call succeeds |
| 5 | `IntentToken` takes its decimals, as `GatedToken` does | The cash token must be signable and at the ledger's precision, and neither template is both | `GatedToken` has no `executeTransfer`, so it cannot be a DvP cash leg; `IntentToken` is fixed at 18 |
| 6 | 3a | The vault's credential stops mattering before 3b rewrites the escrow | Plan above |
| 7 | 3b, with `Request` packed into two slots and safe casts, and `NavDesk.accept(proposalHash)` | The first time a vault sends money to a `Portfolio` | Plan above |
| 8 | 3c, 3d, 3e. In 3e, skip `reported()` behind `ACCEPTS_REPORTED`, and measure it | `pricedValue()` becomes a hot path only there. A 4626's portfolio refuses reported adapters, so one immutable check replaces those calls | `pricedValue()` on `8835283`: 47,967 gas with 8 adapters, 19,217 with 3 |
| 9 | Signed vault entry, as its own lego | An investor with its own wallet can enter with one signature, and a relayer pays the gas. No vault changes | Today `requestDeposit` needs the owner or an operator on-chain |
| 10 | Step 4, then the HTML pages, then an external audit | Auditors need current pages, and writing them after step 4 writes them once | |

**Row 2's tests come first, and they are new.** With the slots removed the whole suite passed unedited, but that proves little: no test covers a forced move to or from the zero address, and the token's guard is tested only from `transfer` (`IntentToken.t.sol:408`). So: both zero checks in `_moveAs` and the one in `_mintAs`, the guard from `forcedTransfer` and `executeTransfer`, and a mutant for each. `_move` is `internal virtual` and documented as the place a template extends, because `_update` no longer sees FORCED or EXECUTED moves. **Result (2026-10-31).** Built with those tests first. `npx hardhat test`: `1309 passing (1168 solidity, 141 nodejs)`, Slither 0, Aderyn 0, mutants 9 of 9.

**Row 9, result (2026-11-01).** `SignedEntry` is built as planned, with no vault bytes changed. An investor signs an `Entry` and the cash by `permit` or ERC-3009, and a relayer submits both. The cash nonce is `keccak256(abi.encode(address(this), entryHash))`, as `DvPExecutor` does, so an authorization pays for one entry. On a 7540 it names the investor as controller and itself as owner, and it refuses a signed minimum, which a request could not honour. Tests first: 21 failing against stubs. Tests also prove exits need no lego, through the share token's `permit` and `multicall`, and a viem test signs both messages off-chain. `npx hardhat test` on this commit alone: see the PR. Slither 0, Aderyn clear on this code, mutants 20 of 20.

**Row 10's step 4, result (2026-11-01).** The code of step 4 is built; the HTML pages and the external audit that row 10 names next are not code and are not done.

- 4a: a record holds no country. `Record`, `Credential`, `CredentialSet`, `profileOf` and the EIP-712 type lose it, and `Quals` names `US_PERSON` (bit 8) and `EEA` (bit 9), which `requireAny` and `forbidAny` already read. `ICredentialRegistry` re-pinned to `0xd224eb70`.
- 4b: `SupplyCapRule` judges MINT only, fails closed with no cap, and compares before subtracting. `assertHandedOver` refuses `MINTER_ROLE`, `BURNER_ROLE`, `AGENT_ROLE` and a desk-less fund's `SETTLER_ROLE` on anything but a Safe with a threshold of at least 2, unless the profile's `singleSigners` names the role. The settler is my addition to the plan's list: without a desk that account sets any price alone. The demo profiles name all four, so a real deployment has to state its own.
- 4c: `ExecutedOnlyRule` refuses TRANSFER, on an `IntentToken` only.
- 4d: `Distributor` as planned. P19 said to build it when the first bond or equity client needs it: the contract and its tests are here, to be reviewed with everything else, and there is no deployment module until then.
- 4e: `Legos.ts` builds a product's legos against `ProxyDeployer.predict`, the council attests them and `Product.ts` plugs what the profile lists while the operations account is admin. New or changed profiles: `vault7540` now has a desk, `managed-fund` and `vault4626-invest`. `full` keeps a plain settler account so that a test can price at will. A profile cannot express an `ERC4626CallValidator` at all, and a custodian lego is one `ERC20CallValidator` naming one address, so the plan's "any validator that reaches a non-custody target" is refused by the shape of the type, and `assertUsable` refuses an adapter on a custody-only fund. Adding a lego after launch stays a timelock operation.

Tests for the rules and the `Distributor` came first (16 failing against stubs); `legos.test.ts` was written alongside the modules, so its red run is the mutants below rather than a run before the code. 67 mutants, all caught: 34 in the contracts and 33 in the deployment and the check. `hardhat.config.ts` gives the local network 24 accounts, because each function now has its own key.

Halmos: `PortfolioHalmos` proves an allocation never passes a cap, and the three bugs planted for it each give a counterexample. **The other property the plan asked for, that a period's claims never pass what it booked, is not in.** I wrote it on the real vault and on `Math.mulDiv` alone, with the total and the price concrete: neither yices nor z3 finished in 150 seconds on the arithmetic alone, and the vault version did not finish in 400. CI's Halmos step has no solver timeout, so it would hang there. `testFuzz_TheSumOfClaimsNeverExceedsTheBookAndFallsShortByAtMostOneUnitEach`, `testFuzz_TheCashClaimsNeverExceedTheBookAndTheVaultCanPayThem` and the invariants in `Gated7540Vault.t.sol` carry it.

**Rows 3, 4 and 5, result (2026-10-31).** Built tests first, in one PR because each CI run costs about 75 minutes on the private repo. Row 3: `canExecute(intent, sig, executor)` answers for the named account, whoever asks: `NOT_EXECUTOR` first, then the call's own checks, with `ZERO_RECEIVER` new, and the rules see that account as the operator. Red run: 8 failing against a stub. Row 4: `allocate(adapter, assets, minAdded)` reverts with `Portfolio_ShortAllocation`; a reported adapter's `_added` is what was sent, so the same check covers it with no branch. Row 5: `IntentToken` keeps its decimals in its own ERC-7201 slot (`0x403ba4…6700`), copied from `GatedToken` rather than shared, because two ten-line copies are simpler than an abstract parent. Red run for rows 4 and 5: 8 failing against stubs. `ITransferIntent` re-pinned to `0xf81fba59`, `IPortfolio` to `0x61d1b676`. `npx hardhat test`: `1324 passing (1182 solidity, 142 nodejs)`, isolated 1182, Slither 0, Aderyn 0, `validate:upgrades` 4 of 4, `verify:reproducible` 20 contracts, mutants 16 of 16. The first full run failed one node test that still pinned the old answer, a pre-flight that did not check the role, and it now asserts the new one.

**Row 6, result (2026-10-31).** `GatedVaultBase` holds `mint`, `burn` and the probe, and both vaults use it. It does not hold `decimals` or `_update`: those exist only because of the OpenZeppelin diamond, and the 7540 loses that in row 7. Tests first: 26 failing against a stub. `GatedVaultBase.t.sol` runs with no credential on either vault, and `fixtures.ts` credentials a 7540 only where its asset is a gated product. `npx hardhat test`: `1363 passing (1221 solidity, 142 nodejs)`, isolated 1221, Slither 0, Aderyn 0, `validate:upgrades` 4 of 4, `verify:reproducible` 20 contracts, mutants 14 of 14. Sizes: 7540 23,790 (+154), 4626 18,354 (+182), `CredentialRule` 3,531. The pre-flight parity matrix gained a `payer` column, because `maxDeposit` names only the receiver and so cannot say a payer will be refused.

**Review fixes (2026-10-31), from the whole-stack assessment.** Two low findings, tests first (4 failing). The recovery timelock was a plain OpenZeppelin `TimelockController`, so governance could schedule `updateDelay(0)` on it once and then unpause and remove the guardian with no delay, against rule 13 and §4 ("same delay"): `GovernanceTimelock` now accepts a zero recovery address (no `RECOVERY_ROLE` holder) and `Core` deploys it for both timelocks, the hand-over check asserts the two run the same code and nobody holds `RECOVERY_ROLE` on the recovery one, and a node test schedules a sub-floor delay on it and sees `GovernanceTimelock_DelayBelowFloor`. `GovernanceTimelock_ZeroAddress` was left unused in the interface, and went with the last review items below. `Fund.setRule` checked attestation only, and every `FundHoldersRule` shares one `ruleId` and codehash, so another fund's rule could be installed and count into that fund while `isClassIntact` read intact: it now requires `IFundHoldersRule(rule).FUND() == address(this)`, with `Fund_RuleForAnotherFund(rule, fund)` appended to `IFund` (an error, so the interface id is unchanged). Not fixed here, recorded in the assessment: `NavDesk` does not require `maxReportAge >= cooldown`; `settlePeriod`'s NAV must exclude the vault's own balance and nothing says so; `Product.ts` grants `SETTLER_ROLE` to a plain account and no module deploys a `NavDesk`. All three have since been fixed: the age check and the note in row 7, the desk and the settler check in row 10.

**Left out, with the reason.**

- A static `TransferContext`: about 3,300 gas across five rules, but it gives up the append-only `extra` (rule 14), so every later field would change the interface and force new rules and a new hook.
- Folding `wantsAfter()` into `beforeTransfer`: under 850 gas, and it departs from the draft ERC's call order.
- A rule list stored as contract code: about 3,700 gas at four rules, but it adds `CREATE` and assembly to the hook.
- A packed adapter slot in `Portfolio`: row 8 gets the saving on the hot path with one check.
- Packing the transient slots: row 2 removes them.
- An early FORCED exit in `CredentialRule`: a forced move must still judge its receiver.

**Held items, closed on 2026-11-01.** The owner asked for everything pending to be settled, and these stay as they are.

- An enforcement burn as FORCED with `to == 0`: not done. It removes three `hasRole` lookups in rules, but a burn from a frozen sender would then pass, which reverses an earlier decision, and its byte cost is not measured.
- A bitmap for nonces: not done. It saves about 14,600 gas per nonce for a signer who picks them inside one word and costs about 300 for a random one, and random nonces are what the brief asks for. The bool map of 2026-10-16 stays (see the top of this file).
- A token argument on the draft ERC's `wantsAfterTransfer`: a question for that draft, not for this repo.

**The last review items, settled on 2026-11-01.** Tests first: 4 failing, one of them reading a count of 3 against a cap of 2.

- A pause now stops money going out of a portfolio. `Portfolio.allocate` and `GuardedAccount.execute` revert while the vault is paused (`Portfolio_VaultPaused`, `GuardedAccount_VaultPaused`, errors, so no interface id moves). Before, a stolen allocator key could keep sending money to an adapter or a custodian through a pause, and the guardian had to lower each cap and revoke each permission instead. `deallocate` still works, for the guardian too. The cost: a permission that pulls money back through `execute`, such as a target's `redeem`, waits for the unpause, and no deployment profile grants one. Neither lego has a role table or a pause of its own: each asks the vault at call time.
- `FundHoldersRule.after_` leaves before it joins, so a net-zero move at a full fund no longer emits a count above the cap for a monitor to read.
- `GovernanceTimelock_ZeroAddress` is removed: nothing throws it, and its comment had become untrue. The owner's instruction reopens rule 4 for it.
- `Fund.setRule`'s new read of `FUND()` is a view call, suppressed in Aderyn with that reason, like the registry read above it. `Fund`'s NatSpec names `FundOpen`.
- No change, on purpose: `ProxyDeployer` and `Fund` keep one-step `Ownable`. A two-step transfer would make the timelock schedule an accept for every fund, which puts its delay into a launch, against P26. The post-deploy check pins each owner, and a mistaken `ProxyDeployer` transfer costs a new deployer, not money.
- No change, on purpose: a token that returns malformed data to `IntentExecutor.executeBatch` reverts the batch without naming the index. Batches are atomic and nothing moves, so only the shape of the error is lost.

`npx hardhat test`: `1724 passing (1554 solidity, 170 nodejs)`. Mutants 15 of 15, after two that removed a hand-over check survived and each got a test. The check now compares the two timelocks' code first, because its role reads would only revert on another contract.

### Order of work after approval

1. Done. The owner told the code to be built in the agreed order and answered P23 to P25 on 2026-11-01. None of the code depends on those answers: it runs on any EVM with Cancun.
2. Step 1, then each row of step 3, then each row of step 4, each on its own short-lived branch from `main`: interface changes, tests with the red run shown, implementation, both runners, lint, fmt, the type check, Slither, Aderyn, `validate:upgrades`, `verify:reproducible`, the mutants.
3. Docs in the same step: the brief, `README.md` and `SECURITY.md`. The HTML pages wait for row 10 of the agreed order, while the repo is private and the site is offline: a page for each new lego, the affected topic pages, the pin in the footers, and a fresh claim check.
4. Stop for review after each. Nothing is committed, pushed or merged without an instruction.

## CI time: Slither on the contracts that ship (2026-11-01)

A CI run took about 70 minutes, and `slither .` was 55 of them. It compiled and analysed every test contract, and `slither.config.json` then dropped every finding in them. The owner asked whether parallel jobs would help. They would not: this is one single-threaded process, and each extra job bills its own setup.

- `npm run slither` builds without the `.t.sol` files and `contracts/test/`, then runs Slither on that build. Measured here on the same code: 727 s and 5.1 GB before, 10.5 s and 0.6 GB after, 514 contracts down to 144.
- It loses nothing on shipped code. With all 59 suppressions removed from the shipped contracts, both runs report the same 56 findings, across 14 detectors and 22 files, and both exit non-zero. All 76 shipped files are in the narrower build, and no test or mock is.
- The swap step is gone, because it existed for Slither's memory.
- `concurrency` cancels a PR's run when a newer push replaces it. Runs on `main` finish.
- Not done: splitting the tests and the reproducibility check into more jobs. Measured on the first run after this change (17 minutes, the analysis job the longest), it would save about 3 minutes and bill another job's setup.

## Sixteen code problems found while writing the HTML pages (2026-11-01)

Writing the pages against `60c1de3`, and checking them claim by claim, found these. Nothing is deployed, so no money was ever at risk. The owner said to fix them before the pages land. The interfaces reopen only for three new errors, one reworded error and NatSpec: no function changes, so no interface id moves, and `InterfaceFreeze.t.sol` shows it.

Can cost holders money after one mistake or one odd event:

| # | What happens today | Fix |
|---|---|---|
| 1 | `migrateTo` and `setPortfolio` must run in one batch and nothing enforces it. In the gap `totalAssets()` reads 0 and anyone's `accrue()` writes `last = 0` for good. | `migrateTo` marks the portfolio, and `priceFresh()` reads false from then on. The vault holds its price and stops dealing until the replacement. `migrateTo` can run again, to send on anything that arrived since. |
| 2 | During an outage with nothing idle, `pricedValue()` reads 0, so `setPortfolio` passes with no write-off. The position is left behind and deposits open at about zero. | `setPortfolio` refuses while the old portfolio has an adapter on its list (`Gated4626Vault_PortfolioNotEmpty`). The way out of an outage is the write-off, which leaves the vault exit-only. |
| 3 | A read of nothing with `fresh()` true writes `last = 0`, which never recovers, and deposits stay open at about zero. | While the value net of fees reads nothing, a value was counted and shares exist, `accrue` writes nothing and the `max*` views are 0. `totalAssets()` still reads 0, because the read is what it is. When the value returns it counts under the limit from `last`. A first fee model plugged meanwhile takes its mark from `last`, not from that zero. A vault drained to dust shares has counted nothing (`last == 0`) and a vault with no shares has nobody to protect, so both keep taking deposits. |
| 4 | `ERC4626Adapter` uses `try`, which does not catch a target with no code or short return data. Every read reverts, so the adapter can never come off, and only a vault upgrade gets out. | A checked `staticcall` that reads one word, so any failure is an outage and the write-off works. |
| 5 | `NavDesk`: a first `setFeeModel` during a cooldown, or a plug before `adopt` from a feeless desk: the mark of 0 overwrites the plug's, and the next quote charges performance on the whole price. | `execute` leaves the mark and the clocks alone when the proposal had no model. `adopt` takes the old mark only if there is one, and the fee clock only if the old desk has a model. NatSpec says to plug, then adopt. |
| 15 | `setPortfolio` restarts the limit's clock, so the gain the limit had already allowed is dropped and the next depositor buys that much cheap. | A replacement keeps the clock. The next count allows what it would have allowed anyway, so nothing has to be counted before `migrateTo`. The rate passed to `setPortfolio` applies to that time, as `setMaxRate` during an outage does. |
| 16 | A price struck with value and no shares is far above par while the mark stays, so the next count or period charges a performance fee on principal. On a desk a stranger's 1-unit donation to the portfolio costs 100 of an unchanged 1,000 at 20%, and only a new desk resets the mark. On a 4626 the last holder's rounding leaves `last = 1`, and the next investor loses 92 of 1,000 with no checker in the way. Found while validating an outside list, which reported the desk's half. | With no shares nothing is anyone's. The 4626 counts zero and the desk proposes a value of zero, whatever is reported or sits in the portfolio, so the next investors buy at par, and the mark restarts at par. What is left counts for them: on a 4626 under the limit, on a desk in the next price. Refusing to propose, as that list suggested, would let the same donation stop the first period being priced. Dust shares left behind are the same shape, and two small changes close them. A mark never starts below par: a model plugged after a loss with one dust share left would otherwise charge the next investor about 10%, and getting back to par recovers principal anyway. And the mark moves to the price after what was actually charged: with a charge that rounds to nothing it stopped part of the way, and the next investor paid up to 0.75% of principal at a 20% rate and 5.56% at 50%. An exact model of both finds no fee on the next investor's principal. The cost is that a gain sliced into calls too small to pay a whole unit pays nothing, a rounding error per call: under 3 raw units while the supply is under 1e18 share units, and about one price unit above that. |

Smaller:

| # | What happens today | Fix |
|---|---|---|
| 6 | `NavDesk.hashOf` leaves out `asOf`, so an approval carries over to the same numbers on a later report. | The hash covers `asOf`. |
| 7 | `NavDesk.execute` does not compare the period (needs a second settler). | `NavDesk_WrongPeriod(proposed, closed)`. |
| 8 | `maxRate` has no upper bound, and overflow jams the vault. | `Gated4626Vault_RateTooHigh(rate)` above 1e9 basis points a year. The bound is there for the arithmetic only, and leaves the timelock room to raise the rate after a low read. |
| 9 | `kycAllowedQuals` defaults to 255, so the default attester cannot assert `US_PERSON` or `EEA`, and a `forbidAny` on them refuses nobody. | The default is 1023, the ten named bits. |
| 10 | `SupplyCapRule` does not answer ERC-165 for `ISupplyCapRule`. | It does, as the older rules do. |
| 11 | A fee model with a zero recipient strands `feesOwed`. | `FeeModel_ZeroRecipient` on any zero recipient. |
| 12 | `Gated4626Vault.collectFees` runs through a pause. | `whenNotPaused`. |
| 13 | `setPortfolio` and `NavDesk.setSettings` do not compare `ASSET()`. | They refuse another asset. |
| 14 | `SignedEntry`: a wrong `asynchronous` flag on a 7540 where the router is the controller of a settled request claims those shares and strands the investor's cash. | `SignedEntry_CashNotTaken(left)` when the allowance is not back to zero. An allowance and not a balance, because anyone can send the router a balance and stop every entry. |

Fix 3 differs from what the owner first read ("a first non-zero read counts from zero"). Writing nothing is simpler and stricter: no read can jump the price, and it also rescues a plug that named the wrong successor, as the money can still follow it.

Fix 11 is what makes fix 5 sound: a proposal's `feeRecipient` is zero only when no model was plugged.

Not fixed, on purpose:

- A read that is low and not zero still counts at once, with deposits open at that price, and recovers at `maxRate`. That is the agreed design, and the council reads each target before attesting it. During a read of nothing, a donor can turn it into a low read with 1 unit more than the fees owed. In a run a stranger's one unit took a holder's 1,000 to a value of 1, still 1 a year after the target got its money back, and a buyer paying 1,000 got about 500 million shares for each of the holder's. It needs a target that reads nothing or very little while it is still fresh. The owner decided on 2026-11-01: a fall of more than half in one count closes deposits for good, as a write-off does, because someone depositing at that price would take part of any recovery from the holders who bore the fall. It takes effect when the fall is counted, and the `max*` views and `exitOnly()` say so before that, so a glitch nobody counts closes nothing. A read of nothing is not counted, so it closes nothing and `exitOnly()` reads false through it, while dealing stays stopped. The stranger can still write the price down, and cannot buy from the vault at that price: the timelock raises the rate to bring the value back. Falls of half or less in one count still leave deposits open at that price, and falls with a count between them do not add up. So a donation of half the counted value or more during a read of nothing does not close deposits: in a run, 500 donated and 100,000 deposited took the holder's 1,000 to about 505 once the target had recovered, and left the depositor about 495 ahead. New money after a close needs a new vault. Anything else about how a fund suspends dealing stays the owner's call.
- The four items left for the owner: a relayed exit by permit is an allowance; caps measure the change in value, not the cash sent; killing an attester does not protect its stored blocks; `assertHandedOver` is a test fixture, and nothing runs it on a live network.

Order of work: the three errors and NatSpec, tests with the red run, the fixes, every gate and the mutants, the stale lines in `SECURITY.md`, `CLAUDE.md`, the README and the NatSpec, one PR from `main`. Then the pages: re-pin them and re-check the sentences these fixes change.

## HTML pages at `babef08` (2026-11-02)

Row 10's pages, written against `60c1de3` and pinned to `babef08` after the fixes those checks led to: 39 pages, 13 of them new (`GatedToken`, `GatedVaultBase`, `NavDesk`, `FeeModel`, `Distributor`, `Portfolio`, `ERC4626Adapter`, `GuardedAccount`, `ERC20CallValidator`, `ERC4626CallValidator`, `SupplyCapRule`, `ExecutedOnlyRule`, `SignedEntry`), the others rewritten. A contract change after this pin changes the footers and the sentences it touches.

- Ten agents wrote from the code. Ten others then checked about 4,200 claims against it, many with throwaway forge tests: 21 wrong, 122 misleading, 19 unsupported, all applied. Three more checked the 308 changed passages: 23 misleading and 1 unsupported, applied by hand.
- A lint outside the repo compares each page's head, nav, footer and links, and every identifier in a `<code>` tag, with the code at the pin, and flags any function, event or error of a contract that its page does not mention. A headless browser measured each page at phone width and each figure's text against its box.
- `site.css` gains one rule, so that a long identifier wraps instead of widening the page on a phone.
- The owner chose GitHub Pro, so the repo stays private and Pages publishes `docs/` from `main`. The site itself is public, as GitHub offers private publishing only on Enterprise Cloud. Source links on the site need access to the repo.
- Three more checks read what the fixes changed on the pages: 11, then 17, then 14 findings, all applied. The last 14 have had the lint and a read by hand, and no further independent check. The last check also found `exitOnly()` reading true through a read of nothing and false again when the value returned, fixed in #22 before these pages landed.

## Redemption gate and a second contract for the 7540 (planned and approved by the owner 2026-11-02)

The owner said on 2026-11-02 that contract size must not make the code worse: build what the product should have, then decide how to handle the size. P11 left pro-rata gates out over a few hundred bytes. This section reverses that for gates and makes room in the 7540 in a way that keeps its attestation and its role model.

Baseline at `7a03cde`: `1792 passing (1622 solidity, 170 nodejs)`. The sizes under "What was measured instead" come from a throwaway copy, in which the gate was built to measure its size and had no tests. What the build measured is in "As built" at the end of this section.

### What a fund gets

A fund can set the most that may leave in one period, as a share of the fund. When a period's redemptions pass that level, every request in the period is filled at the same fraction. The rest stays in the queue, stays invested, and deals at the next period's price.

An example at a level of 10%, at a flat price, ignoring the virtual shares. The fund has 1,000,000 shares worth 1,000,000, the first period's deposits are 20,000, holder A asks to redeem 200,000 shares and holder B 100,000, and nobody else asks for anything after that.

| Period | Shares in the fund | Limit | Queue | Filled | A and B get out | Carried |
|---|---|---|---|---|---|---|
| N | 1,000,000 | 100,000 + 20,000 the deposits buy = 120,000 | 300,000 | 40% | 80,000 and 40,000 | 180,000 |
| N+1 | 900,000 | 90,000 | 180,000 | 50% | 60,000 and 30,000 | 90,000 |
| N+2 | 810,000 | 81,000 | 90,000 | 90% | 54,000 and 27,000 | 9,000 |
| N+3 | 729,000 | 72,900 | 9,000 | 100% | 6,000 and 3,000 | 0 |

In period N the cash account funds 100,000: 120,000 paid out less 20,000 paid in, which is exactly 10% of the fund.

### Why not a rule

The suggestion was a rule of about 40 lines capping the shares that enter the escrow per period. It is first-come: the fastest holders exit in full, and everyone else is refused with no place in a queue. In a run that rewards the race a gate exists to stop. ERC-7540 also asks that requests of one id become claimable at one pro-rata rate, which is what this design does. Not built.

### The vault is told how much, and not why

`settlePeriod` gains a limit. It takes the smaller of the book and the limit, and `type(uint256).max` means no limit, so a settler with no gate deals exactly as today. There is no new revert path and no policy in the vault (rule 11).

```solidity
_s.redemptions = $.books[_period][false].paid;
_s.redeemed = Math.min(_s.redemptions, _redeemLimit);
_s.assets = Math.mulDiv(_s.redeemed, _nav + 1, _s.supply + _VIRTUAL_SHARES);
if (_s.redeemed != _s.redemptions) {
  uint128 _carried = (_s.redemptions - _s.redeemed).toUint128();
  $.books[_period][false].carried = _carried;
  // At most one period is closed, so the next one is the open one.
  $.books[_period + 1][false].paid += _carried;
}
$.pendingRedeemShares -= _s.redeemed;
```

`settlePeriod` burns `redeemed`, not the whole book, and `_net` pays on the assets of `redeemed`. `Book` gains `uint128 carried`, which a full fill leaves at zero. The carried shares stay in the escrow, in `totalSupply()` and in `pendingRedeemShares`, so they still count in the price, pay the fund's fees, and stay out of reach of `forcedTransfer`'s surplus.

Every path already reads a controller through `_request`, so only the roll changes. The claims, `_join`, `_takePending`, `recoverClaimable` and every view follow it:

```solidity
_r = $.requests[_controller][_isDeposit];
uint64 _settled = $.settledPeriod;
while (_r.period != 0 && _r.period <= _settled) {
  Book memory _book = $.books[_r.period][_isDeposit];
  uint128 _carried = Math.mulDiv(_r.pending, _book.carried, _book.paid).toUint128();
  _r.paid += _r.pending - _carried;
  _r.owed += Math.mulDiv(_r.pending, _book.owed, _book.paid).toUint128();
  _r.pending = _carried;
  _r.period = _carried == 0 ? 0 : _r.period + 1;
}
```

A full fill gives today's numbers: nothing carries and the loop ends after one pass. A deposit is always a full fill. A book written before `carried` existed reads as filled, so an upgrade in place cannot pay a settled redemption twice.

**Rounding.** What each controller carries, `floor(pending × carried / paid)`, rounds down, so the parts sum to no more than the next book holds. A reject of a carried part can therefore never underflow that book. What is owed rounds down and sums to no more than the assets, so `claimableCash` is never short. Each gated period can leave up to (controllers − 1) share units in the next book that nobody owns. They burn at the next full fill, and a share unit is a millionth of the asset's smallest unit at par.

### The desk holds the policy

The level lives in `NavDesk`, because the vault must not know why a limit is what it is, and a later desk can apply a different policy without touching the vault.

- `redemptionGate`: the level in basis points of all shares, unclaimed ones included. `setRedemptionGate` takes the vault's `DEFAULT_ADMIN_ROLE` (the timelock), emits `RedemptionGateSet`, and refuses more than 10,000 with `NavDesk_InvalidGate`. Zero is off, as a minimum position's is.
- `propose` works out the limit: `supply × level / 10,000 + deposits × (supply + 1e6) / (nav + 1)`, both rounded down. The second part is exactly the shares the period's deposits buy at this price, so the measure is net of deposits: real money coming in pays the exits it allows. With the gate off the limit is `type(uint256).max`.
- `Proposal` gains `redeemLimit`, `hashOf` covers it, `ProposalMade` carries it, and `execute` passes it to `settlePeriod`. A timelock change inside the cooldown does not move a price on the table, like every other figure in a proposal.
- The reporter passes nothing for it, so two people cannot starve exits while taking deposits. Nothing moves the inputs while a proposal is on the table: the closed book can only shrink through `refundRequest` and `recoverRequest`, which need no proposal on the table, and neither a claim nor a recovery changes `supply`.
- `adopt` copies the level from the old desk, because a replacement that forgot it would silently lift a gate. A later timelock call can still change it.

**Decisions taken here, stated to the owner on 2026-11-02 and not objected to:** the gate is net of deposits; a carried part has no priority over new requests. **My decisions:** the gate applies mechanically whenever the level is passed, with no discretion to invoke it, because the level is meant to be fixed in the offering documents. The guardian gets no power over it, because it can already stop dealing by cancelling a proposal. One level per period.

### What an investor sees

No new function. `pendingRedeemRequest` shows the carried part, and `claimableRedeemRequest`, `maxRedeem` and `maxWithdraw` show the part taken, which is how ERC-7540 keeps the two apart. A holder cannot withdraw a carried part themselves, as no request can be cancelled today. The agent's `rejectRedeemRequest` hands it back under the full policy, and `recoverRedeemRequest` is the path if that is blocked. `PeriodSettled` gains `_redeemed`, so the history shows both what was asked and what was taken.

### The second contract

The 7540 keeps every function by name and hands the settlement and recovery functions to a fixed second contract that it creates in its constructor.

- `contracts/vaults/Gated7540Common.sol`: abstract, on `GatedVaultBase`. The structs, the constants, the storage accessor, `_request` and `_store`, so the two cannot disagree on the layout.
- `contracts/vaults/Gated7540Settlement.sol`: `closePeriod`, `settlePeriod`, `rejectDepositRequest`, `rejectRedeemRequest`, `recoverClaimable` and `recoverRedeemRequest`, with `_takePending`, `_strike` and `_net`.
- `Gated7540Vault`: everything an investor or an operator calls stays here and runs directly. It stays `is IGated7540Vault`, so the compiler still checks the whole interface. Each moved function is one line that delegatecalls `SETTLEMENT_LOGIC` through OpenZeppelin's `Address.functionDelegateCall`, with the calldata unchanged and a typed error passed back as it came.

```solidity
/// @inheritdoc IGated7540Vault
function recoverClaimable(address, address) external {
  _toSettlement();
}
```

**Why it keeps the attestation.** `SETTLEMENT_LOGIC` is an immutable of the implementation, set by `new` in its constructor. The implementation's codehash therefore pins the address, nobody chooses the contract, and its code cannot change. There is no new role, no new storage and no admin function. An upgrade goes through the same timelock to an attested implementation, and that implementation creates its own second contract. The second contract is not a lego: it is not attested on its own and it cannot be swapped alone.

**Called directly it does nothing.** Its own storage is empty, so no account holds a role there and nobody can be granted one; it has no initializer; `upgradeToAndCall` is `onlyProxy`. It holds no money. The base's functions in it cannot be reached from the vault, because the vault forwards only the six named selectors and has no fallback.

**The checks that must learn about it.**

- `scripts/verify-reproducible.ts` adds it to the deployed list and fails unless the 7540's creation code embeds its artifact's creation code, the same check `ProxyDeployer` has for `TokenProxy`.
- `assertHandedOver` compares its deployed code with the artifact, with its own address in the `__self` slot.
- `ContractSizes.t.sol` adds its runtime size and the 7540's creation code against EIP-3860's 49,152.
- `validate:upgrades` needs annotations on the immutable, the vault's constructor, the hand-off and the second contract's missing initializer.

**What it costs, said plainly.**

- This is `delegatecall` inside a UUPS implementation, a pattern OpenZeppelin does not ship, though the call itself is its own (rule 10). The auditors must read the two contracts as one.
- The second contract carries a copy of the base no vault can call. A contract with the same parents and no functions of its own is 12,806 bytes.
- The vault's creation code becomes about 40 KB of 49.1 KB, and deploying it takes about 8.6 million gas against about 5.3 million today. If either ever stops fitting, the second contract is deployed first and its address passed to the constructor, which keeps the same pin at the price of one more deployment step.
- The moved functions pay about 3,000 to 3,700 more gas. Investor paths pay at most 35.

### What was measured instead

Deployed bytes of the 7540 at `7a03cde`, against 24,576.

| Layout | Vault | Room | Second contract |
|---|---|---|---|
| Today, no gate | 24,320 | 256 | none |
| Gate only | 24,806 | 230 over | none |
| Gate, IR optimiser | 28,562 | 3,986 over | none |
| Gate, 100 optimizer runs | 24,318 | 258 | none |
| Gate, a selector table, recovery moved | 25,582 | 1,006 over | 15,925 |
| Gate, fixed contract, recovery moved | 23,592 | 984 | 15,925 |
| **Gate, fixed contract, recovery and settlement moved** | **21,712** | **2,864** | **18,247** |

- **A selector table the admin can edit.** It costs 2,027 bytes, more than moving the recovery functions frees. Adding a function is an upgrade by another name, so it would need its own timelock and attestation path. The attested codehash would stop saying what a proxy runs, and each launch would write one entry per selector. Refused.
- **100 optimizer runs.** It changes every contract's gas and bytecode, and leaves 258 bytes, so the next feature brings us back here. Refused.
- **The IR optimiser.** It makes the 7540 bigger, so the "via-ir fallback" noted earlier was wrong. Corrected above.
- **An external share token (ERC-7575).** Cleaner in the long run, but a far larger rewrite (the escrow's exemptions in the rules, the enforcement special cases, the roles on the token), and it does nothing for the 4626. Keep it for a fund with several assets.

**Evidence for the chosen layout.** On a throwaway copy, without the gate, with both groups moved and no test or deployment module changed: `1792 passing (1622 solidity, 170 nodejs)`, upgrades 5 of 5, Slither 0, Aderyn 0 with two inline annotations. Halmos, the reproducible build and gas were not run on it.

### Interfaces this reopens

The owner's approval of this plan is the instruction rule 4 asks for. `InterfaceFreeze.t.sol` is re-pinned for each.

| Interface | Change |
|---|---|
| `IGated7540Vault` | `settlePeriod` gains `_redeemLimit`. `PeriodSettled` gains `_redeemed`. New views `periodBook(_period, _isDeposit)`, which returns paid, owed and carried and lets the desk read a period's deposits, and `SETTLEMENT_LOGIC()`. |
| `INavDesk` | `Proposal` gains `redeemLimit`, which changes `hashOf`'s selector. `ProposalMade` gains `_redeemLimit`. New `redemptionGate()`, `setRedemptionGate`, `RedemptionGateSet`, `NavDesk_InvalidGate`. |
| `IGated4626Vault` | New event `DepositsClosed(_counted, _last)`, below. |

**The 4626's closing event.** A count that finds the value fallen by more than half closes deposits for good and emits nothing specific, against rule 16. `_accrue` emits `DepositsClosed` when it flips the flag from false, and only then. The other flip, in `setPortfolio`, needs none: it carries a write-off forward, which already has `AdapterWrittenOff`, and `PortfolioSet` marks the call. About 100 bytes of the 476 free, an estimate.

**Deployment.** The `Nav` profile type gains an optional `redemptionGateBps`, and `Product` calls `setRedemptionGate` when it is set. No shipped profile sets one, as the level is each product's own, from its offering documents. A test deploys `vault7540` with one, which covers the wiring. `assertHandedOver` pins it.

### Known limits

- **Over-requesting.** A holder who expects a gate can ask for more than they want, to get a bigger slice. Only the agent can hand back a carried part, which is the deterrent, and it is not a complete one.
- **A dormant controller walks.** The roll passes one period at a time until the first full fill, 5,979 gas per gated period as measured, so about 5,000 gated periods in a row fit a block of 30 million. A test pins it below 7,000. I looked at a running product instead of a walk: it needs no loop, but it loses precision as it shrinks towards zero and needs scale tracking. The walk is simpler and its cost falls only on the controller who waited.
- **A fund winding down never finishes under a gate.** The level is a share of what remains, so when everyone is leaving the queue shrinks by the same fraction each period. The timelock sets the level to zero for a wind-down.
- **P27 lasts longer.** See the row above.
- **A low level slows every exit.** The timelock can set one, delayed and visible, like any other setting. A compromised governance stays out of scope.
- **A plain settler can pass any limit.** It can already refuse to settle, and the hand-over check refuses that role on a single key unless the profile names the exception.

### What size no longer decides

| Item | Answer now |
|---|---|
| P11, pro-rata gates | Reversed, above. |
| P11, per-period dealing limits and a forced exit | Still out, because no product asks for them, not because of size. |
| P13, no OpenZeppelin 4626 parent on the 7540 | Stays. The vault would still override almost all of it and claim to be synchronous while its previews revert. |
| P27, the investor cap while requests are open | The vault's room is no longer a reason. The other one stands: settlement cannot loop over investors, and leaving at the claim would need the vault to reach into `Fund`. Counsel's view decides whether to reopen it. |
| `dealingState()` in place of three getters | Stays. It reads better, and nothing wants them apart. |
| The vault not checking who holds `SETTLER_ROLE`, which `SECURITY.md` put down to size | Stays, for another reason now written there: a desk is not attested, so the vault could not tell one from any other account. Attesting desks would make that check possible, and no product asks for it. |
| The 4626's closing event | Added, above. |

**Counting an entity with several wallets: not built, on its merits.** It costs the vaults nothing, as it would live in a rule, `Fund` and the registry. Under issuer custody (P24) a client has one address. A client with two wallets counts twice, which reaches the cap early and never breaches it. The unsafe case, one shared address holding for many clients, is avoided by that custody and is counsel's otherwise. Build it when a product needs it.

### Not in this work

A gate on the 4626, which has no batch to fill pro rata and whose `maxRedeem` already stops at its liquid assets. Two levels at once, such as monthly and quarterly, which is a new desk with the vault unchanged. Limits on deposits. Priority for carried parts. Cancellation by a holder. Moving anything out of the 4626 or the tokens.

**What does not change.** The base, the rules, `ComplianceHook`, `Fund`, `Portfolio`, `FeeModel`, `SignedEntry`, `Distributor` and the executors. The investor paths of the 7540.

### Build order

Tests first, the failing run shown, in three pull requests, each landed by squash on green.

1. **The split, with no change in behaviour.** New tests: each moved function called directly on the second contract reverts; a moved function through `multicall`; a settlement after an upgrade keeps its state and uses the new contract; the size guards. No existing test changes, apart from the interface id that `SETTLEMENT_LOGIC()` re-pins, so the existing suite is the proof. Gas of the moved functions measured, and the deployment gas.
2. **The gate, the desk and the 4626 event.** The call sites of `settlePeriod` (about 40) gain the limit, and six `PeriodSettled` expectations gain a field. New tests:
   - Vault: one fraction across controllers (fuzzed); burn, escrow and cash on `redeemed`; a carried part at the next price; limit zero, equal and above the book; a dormant controller against an active one; a new request on a carried part, and one refused while the carried part sits in a closed period; a reject and a recovery of a carried part, under each role; `recoverClaimable` leaves a carried part alone; every view against the state after a write; carried parts against the next book, and owed against the assets (fuzzed); an invariant run on `pendingRedeemShares`, the escrow and the balance; the gas of a walk.
   - Desk: the limit formula with the example above; net outflow within the level (fuzzed); a level changed inside the cooldown; a stale hash refused; bounds and role; `adopt`.
   - Fund: a queued investor's place in the count, pinning what P27 accepts.
   - 4626: `DepositsClosed` once, at the flip, and not on a fall of half or less.
   - Node: `managed-fund` end to end through the desk, decoding `PeriodSettled`.
3. **The pages.** `Gated7540Vault`, `NavDesk`, `Gated4626Vault`, `BaseRule`, `FeeModel`, `Portfolio`, `index`, `money`, `movement`, `deployment`, `review` and `roles` where they say what settlement does, a new page for the second contract, and a new pin across every footer, with a fresh check of the changed claims.

Each code pull request updates `CLAUDE.md` (§1, §3, §4, §7 and rule 4's reopening note), `README.md`, `SECURITY.md` and this file.

**Done means:** `npx hardhat test` in both runners and in isolation, the lint, `forge fmt`, the type check, Slither 0, Aderyn 0 read by hand, Halmos, `validate:upgrades`, `verify:reproducible`, and planted bugs by hand (the rounding direction, the carry dropped or sent to the wrong period, the whole book burned, `carried` not stored, the limit left out of the hash, gross instead of net, `adopt` not copying, a hand-off to the wrong selector). A Halmos proof of the two-controller rounding bound is attempted; if the solver does not finish, the report says so and the fuzz stands.

### As built

**The split, with no change in behaviour.** Tests first: 18 ran against a stub, 11 failed and 7 passed, the 7 describing what the vault already did. No existing test changed apart from the interface id `SETTLEMENT_LOGIC()` re-pins.

Measured against `main` at `7a03cde`, on the node tests of the vaults and legos:

| | `main` | The split |
|---|---|---|
| `Gated7540Vault` runtime | 24,320 (256 free) | 21,579 (2,997 free) |
| `Gated7540Settlement` runtime | none | 17,558 |
| `Gated7540Vault` creation code | 24,569 | 39,522 of 49,152 |
| Deploying the implementation | 5,338,964 gas | 8,578,334 gas |
| `closePeriod` | 37,417 | 40,785 |
| `settlePeriod` | 121,794 | 125,542 |
| `rejectDepositRequest` | 55,995 | 58,864 |
| `rejectRedeemRequest` | 135,519 | 139,011 |
| `recoverRedeemRequest` | 175,258 | 178,859 |
| `requestDeposit` | 203,465 | 203,487 |
| `requestRedeem` | 201,540 | 201,575 |
| `deposit` claim | 213,892 | 213,914 |
| `mint` claim, `redeem` claim | 142,403, 120,133 | unchanged |

Two things differ from the plan above, both simpler. The hand-off uses OpenZeppelin's `Address.functionDelegateCall`, which the base already carries through `Multicall`, in place of hand-written assembly. The second contract has no constructor, because with no initializer there is nothing to lock.

**The gate, the desk and the 4626's event.** Tests first: 30 of the new tests failed against stubs. A fresh agent then read the code with no sight of this plan's reasoning, and ran 3,000 random sequences of 48 operations and one of 1,500 steps, with books, escrow and cash checked after every step. It found no fault in the accounting, and two things:

- A book that stored what was `taken` read as "nothing taken" on a period settled before the field existed, so an upgrade in place would have paid settled redemptions twice, or bricked a controller on an empty next book. Nothing is deployed, but the fix is simpler code. The book stores what was `carried`, so zero means filled, the roll needs no branch for the deposit side, and a full fill writes nothing extra. The second contract also reports its own template id, so a proxy cannot be moved onto it even if it were attested by mistake.
- A fund everyone has left keeps a few share units of rounding dust, so `_supply == 0` is never true again. The reporter must then propose a value of at least 1, and `FeeModel` prices that at about half an asset per share, against par's millionth of one. The mark jumps there and no performance fee is charged for the rest of the fund's life. Investors lose nothing. This is on `main` too, and it is not part of this work.

Two things differ from the plan above. No shipped profile sets a level. The walk costs 5,979 gas per period, not the 5,000 I worked out.

Measured against the split, on the node tests of the vaults and legos with the new tests left out, so with no gate in play:

| | The split | With the gate |
|---|---|---|
| `Gated7540Vault` runtime | 21,579 | 21,908 (2,668 free) |
| `Gated7540Settlement` runtime | 17,558 | 18,001 (6,575 free) |
| `Gated7540Vault` creation code, limit 49,152 | 39,522 | 40,294 |
| `Gated4626Vault` runtime | 24,100 | 24,193 (383 free) |
| `NavDesk` runtime | 10,320 | 11,363 |
| Deploying the 7540's implementation | 8,578,334 gas | 8,745,154 gas |
| `settlePeriod` | 125,542 | 126,537 |
| `requestDeposit`, `requestRedeem` | 203,487, 201,575 | 205,694, 203,712 |
| `deposit`, `mint`, `redeem` claims | 213,914, 142,403, 120,133 | 216,705, 145,173, 122,899 |
| `NavDesk.propose`, `execute` | 235,319, 182,062 | 260,117, 185,651 |

`npx hardhat test`: `1851 passing (1678 solidity, 173 nodejs)`. Isolated 1678 passing, Slither 0, Aderyn 0, Halmos 22 of 22, `validate:upgrades` 5 of 5, `verify:reproducible` 30 contracts. Planted bugs by hand: 29 of 29 caught on the first version, and 11 of 11 on the lines the `carried` change rewrote. No Halmos proof of the rounding bound was attempted: the two-controller bound is plain algebra and is fuzzed, and the plan's earlier Halmos property on the sum of a period's claims was dropped because no solver finishes it.

## HTML pages at `d903344` (2026-11-02)

The third pull request of the section above: 41 pages, 2 of them new (`Gated7540Settlement`, `Gated7540Common`), pinned to `d903344`. The contracts have not changed since that commit.

- One agent wrote from the code and ran both worked examples. A different agent then checked about 320 claims by hand, by script all 302 cited test names and every link and anchor, and re-ran the worked examples, the test count, the sizes and the deployment gas in a copy. It found 3 wrong, 6 misleading, 1 unsupported and 2 that described history, all applied.
- One of those was the walk's cost. The 6,541 gas measured earlier was on the version of the book that stored `taken`. On the final code it is 5,979, measured again, so about 5,000 gated periods in a row fit a block of 30 million. The plan, the brief and the test's comment are corrected with the pages. Another was the second contract's copy of the base, which is 12,806 bytes, not about 15 KB.
- The lint outside the repo and the headless check at phone width were run on the result. These fixes have had no further independent check.

## Dust in a fund everyone has left (planned and approved by the owner 2026-11-04)

The review of #25 found this on the desk, and an outside list on 2026-11-04 confirmed it and showed the same state on the 4626. Baseline at `dced280`: `1851 passing (1678 solidity, 173 nodejs)`. The runs below were on a throwaway copy of `dced280`, with tests that are not in the repository.

### What goes wrong

Each deposit claim on the 7540 rounds down, so a fund whose investors have all left can keep a few share units in `unclaimedShares`. The desk's case for no shares asks for `_supply == 0`, which is then never true again. A value of zero reverts with `NavDesk_ZeroNav`, so the reporter must propose at least 1, and `FeeModel` prices one raw unit over one share unit at `1e18`, against par's `1e12`. The charge rounds to nothing and the mark moves there. In a run with one unit left, the mark went from about `1.09e12` to `1e18`, and a fund that then tripled paid no performance fee at 20%. Plugging the model again keeps the mark. Only a new desk that does not `adopt` the old one starts again, at the current price.

The 4626 reaches the same state through a holder alone in the vault, the very first one included. `redeem(shares - 1)` left one share unit and one raw unit counted, the next count moved the mark to `1e18`, and a fund that then tripled paid no fee. It needs no reporter or checker, as anyone can call `accrue()`, and once others have joined only everyone leaving or an upgrade clears it. Rounding alone is milder there: `withdraw(maxWithdraw)` after a 10% gain left 851,851 units and a mark of 1.17 times par.

Investors lose nothing. The fee recipient loses the performance fee.

### The change

Fewer share units than one raw unit of the asset buys at par (`_VIRTUAL_SHARES`, `1e6`) count as no shares, everywhere the two contracts ask. Below it, all holders together own less than one raw unit at par. At it or above, the least value a reporter can propose, 1, prices at par or below, so the mark cannot jump.

- `NavDesk.propose`: `_supply < _VIRTUAL_SHARES` in place of `_supply == 0` for the gross value, and `_supply >= _VIRTUAL_SHARES` in place of `_supply != 0` for `NavDesk_ZeroNav`. `_quote`: the same test for the mark and its clock.
- `Gated4626Vault._counting`: `totalSupply() < _VIRTUAL_SHARES` in place of `totalSupply() == 0`. `_dealingStopped`: `totalSupply() >= _VIRTUAL_SHARES` in place of `totalSupply() != 0`, so dust does not stop dealing during a read of nothing, as no shares does not today (`test_WithNoSharesAReadOfNothingDoesNotStopDeposits`).

`FeeModel`, the 7540, its second contract and every storage layout stay as they are. A first plug of a fee model needs nothing: whatever mark it starts with, the 4626's next count, which comes before any deposit, and the desk's next proposal set it to par. A dust holder can still leave: redeeming the last unit on the 4626 paid 0 and burned it.

In the trial (without the `_dealingStopped` line), one unit of dust had the next investor buy at par, and a fund that then tripled paid 400 of fee on 1,000 invested, on the desk and on the 4626. The 465 existing tests in `NavDesk.t.sol`, `Gated4626VaultPortfolio.t.sol`, `Gated4626Vault.t.sol`, `Gated7540Vault.t.sol`, `Gated7540Settlement.t.sol` and `FeeModel.t.sol` still passed. The whole suite was not run.

**Known limit.** A holder who leaves the largest dust on purpose, 999,999 units, or on a 4626 mints that many into an empty vault for one raw unit, has the next investor pay as little as about half par with the mark at par, so the first doubling pays no performance fee: in the trial, none at 1.9 times and 200 rather than 400 at 3 times. It costs the fee recipient once, not for the rest of the fund's life. A higher threshold would shrink this and set more aside, and `1e6` is where one raw unit prices at par. A test pins it.

### The 4626's management fee on a small or low-decimal fund: no code change

The same list said `_accrue` restarts `lastFeeAt` on every count, even when the management fee rounds to nothing. That is true. Its example is not: `1e10 × 100 × 12 / (1e4 × 31,536,000)` is 38, not 0, and a count every 12 seconds for a day took `$10,000` from 273,972 raw units of fee to 273,600. The loss is under one raw unit per count, and only one count a block matters, as a second one has no time to charge. For a dollar token with 6 decimals that is at most about `$2.63` a year on 12-second blocks and `$31.54` on 1-second ones. With 2 decimals it is a cent a block, and someone calling `accrue()` every 12 seconds keeps a fund of up to about `$2.6m` at 100 bps from paying any management fee: in the trial, `1e8` raw units paid 0 in a day rather than 2,739.

Its fix, holding the clock while the fee rounds to nothing, is not taken. Time builds up while the fund is small and is charged to whoever arrives next: 1,000 raw units sat for 30 days, `$10m` arrived, and 12 seconds later the fund owed `$8,219` rather than `$0.04`. All 94 existing tests in `Gated4626VaultPortfolio.t.sol` passed with that fix, so nothing pins this today. This work adds the test that does, and a test of the limit as it stands, and writes the limit into `SECURITY.md` and the pages. A product with a management fee on a low-decimal asset should take it into account.

The list's third item, a unit given during a read of nothing, is the owner's decision of 2026-11-01 and is already written down, and the 4626's page already says a pause does not stop `accrue()`. Nothing changes for it.

### Interfaces

NatSpec only, moving no id: `IGated4626Vault`'s description and `INavDesk.propose` say "with no shares", and gain "or fewer than `1e6` share units". The owner's approval of this plan is the instruction rule 4 asks for. `InterfaceFreeze.t.sol` stays as it is.

### Tests, written first

- **Desk** (`NavDesk_NoShares`): one unit of dust after everyone leaves proposes a value of zero with the mark at par, the next investor buys at par, and a later gain pays the performance fee; 999,999 units strike at zero, while 1,000,000 still revert `NavDesk_ZeroNav` on zero and keep the mark; whatever is reported with dust strikes at par (fuzzed); the redemption limit with dust and a gate on; the known limit.
- **4626** (`Gated4626VaultPortfolio_Fees`, `_Counting`): a holder alone leaving one unit, then a count, keeps the mark at par, and the next investor buys at par and pays on a later gain; the same boundary at 999,999 and 1,000,000; the dust holder can still redeem; a read of nothing with dust does not stop deposits; for any dust below `1e6` and anything left in the portfolio, the next investor buys at par or below and pays no performance fee on principal (fuzzed).
- **4626 management fee:** new money does not pay for time before it arrived, which passes today and is shown failing against the rejected fix, planted by hand; a count that rounds to no fee restarts the clock, which pins the limit.

### Pull requests

1. **The code**, with its tests, `CLAUDE.md` §7 (the two sentences on no shares, and "above zero while shares exist"), `SECURITY.md` (the bullet on no shares, the management-fee limit, a row of planted bugs) and this file.
2. **The pages**: `NavDesk`, `Gated4626Vault`, `money` and `review` (the open item becomes fixed, and the management-fee limit joins the open list), re-pinned to the first pull request's commit, with the changed claims checked again.

**Done means:** `npx hardhat test` in both runners and in isolation, the lint, `forge fmt`, the type check, Slither 0, Aderyn 0 read by hand, Halmos, `validate:upgrades`, `verify:reproducible`, the size guards, and planted bugs by hand: `<=` for `<`, the threshold one unit off, the gross value changed without the zero check and the reverse, the mark's clock left on `== 0`, `_dealingStopped` left on `!= 0`, and the 4626's fee clock held while the fee is zero.

**Not in this work.** Clearing a mark already stuck on a 4626 that others have joined, since nothing is deployed. A fee model that prices with the virtual shares, which would close the known limit and needs a new attested model.

### As built

As planned, with one test more than the plan listed: at exactly `1e6` share units a read of nothing still stops dealing, which pins `_dealingStopped`'s boundary. Tests first: 9 of the new tests failed against the unchanged code, and the 5 that describe what the code already did passed (a million units still count on both, the last units can be redeemed, and the two management-fee tests).

`npx hardhat test`: `1866 passing (1693 solidity, 173 nodejs)`. Isolated 1693 passing, Slither 0, Aderyn 0, Halmos 22 of 22, `validate:upgrades` 5 of 5, `verify:reproducible` 30 contracts, lint, format, types. Planted bugs by hand: 13, of which 11 were caught at first. The two survivors, the gross value one unit off and the mark's clock left on `== 0`, were tests that proposed zero and did not read the clock; both are tightened and now catch them.

`Gated4626Vault` is 24,213 bytes, 20 more, with 363 free. `NavDesk` is 11,379, 16 more.


## HTML pages at `bfb424e` (2026-11-05)

The second pull request of the section above. The 41 pages are pinned to `bfb424e`. `NavDesk`, `Gated4626Vault`, `FeeModel`, `money` and `review` changed where they described the case of no shares, and `review` records the outside list of 2026-11-04 and the two limits it leaves open.

- One agent checked about 95 changed claims against the code and found 8 problems: three places that said the next investor buys at par where dust has them pay as little as about half par; a jump overstated for large dust, also in two code comments and `SECURITY.md`; "up to half par", which reads the wrong way; the 4626's mint route to the same dust, as one raw unit buys 999,999 share units in an empty vault (run by hand); the source of the first open row; three claims about the list that nothing recorded; the CI runs still naming `d903344`'s; and a claim about the 4626's clocks that its tests did not show. Each was checked by hand and applied. These fixes have had the lint and no further independent check.
- The contracts change only in those two comments, so the pin holds.

## The repository's name out of the files (planned and approved by the owner 2026-11-05)

The owner asked for every mention of this repository, and of its name, to come out of the files. At `33dd064` they are in:

- All 41 HTML pages: 351 links through the repository's address on GitHub. 349 point at a file or folder at `bfb424e`, mostly from each page's list of sources, and two at pull requests 21 and 22.
- `README.md`: the title, and the address of the published pages, which carries the owner's handle and the repository's name.
- `PLAN.md`: the decision of 2026-10-16 naming the project's folder, and the link to PR #9.
- `package.json` and `package-lock.json`: the package's name, the same words written as one.

What changes:

1. **Pages.** Each link is taken off and its text stays as it reads now: the path in `<code>` for 346 of them, and "README runbook", a test file's name and "pull request 21" or "22" for the other five. The footer already names the commit. The repository is private, so a reader of the published pages cannot follow those links anyway; a reader with access finds each file by its path at that commit. Relative links would not do: Pages publishes only `docs/`, so they would break on the site.
2. **`README.md`.** The title becomes "Gated Token Stack". The documentation line keeps its pointer to `docs/index.html` and loses the address.
3. **`PLAN.md`.** The 2026-10-16 decision reads "The project is its own git repo." PR #9 stays named, without the address.
4. **The package's name** becomes `gated-token-stack`, after the project's title, in `package.json` and in the two name fields of the lock. The package is `private` and nothing reads its name: the contracts, their bytecode, the tests and the deployment modules do not change.
5. **The page lint**, which lives outside the repository, checks that every path the pages cite in `<code>` exists at the pin, in place of checking the links.
6. **The review page goes too**, as the owner asked while this was being built: `docs/review.html` is deleted, with the "Security review" entry in every page's navigation, its card on the overview, and the overview's sentence pointing at it, which keeps "Nothing here has had an external audit." `Gated7540Settlement`'s page linked to its list of what no review has covered; that item now says so itself. The `.pill` style, used only by that page, goes with it. Open question 3 below pointed at the page and now points at `SECURITY.md`, which holds the same two limits.

Left as they are:

- `LICENSE`: "Requests for permission" points at the owner's GitHub profile, not at this repository, and the licence needs a way to ask. It changes only if the owner says so.
- The mentions of `urwa-policy` in this file: a different repository.
- Git history, earlier commit messages and pull request bodies on GitHub keep the name. Changing them means rewriting `main`, which nobody has asked for.
- The repository's name on GitHub, and with it the address the published pages will have once Pages is on. Only renaming the repository, or a custom domain, changes that, and both are the owner's call.

Checks: the page lint at 40 pages with no errors; `npx hardhat test`, lint and format; and `git grep` for the name and the handle finding only `LICENSE`.

## The outside list of 2026-11-05 (planned 2026-11-05; approved by the owner the same day: "A, build it")

An outside list, author not recorded, named eleven findings and five optimizations at `11f8ca5`. Each was read against the code, and the ones a reading could not settle were run as throwaway tests, not committed.

### What holds

| # | Finding | Verdict | Evidence |
|---|---|---|---|
| F1 | A soft hurdle's catch-up is lost when a count lands inside the band | True | Mark 1.00, a 10% hurdle after a year, 20% rate: one count at 1.125 charges 0.025e12; a count at 1.1001 then one at 1.125 charge 0.00508e12 in all, 80% less. A hard hurdle charges 0.005e12 either way. On a 4626 `accrue()` is anyone's and every deposit and withdrawal counts, so a soft hurdle there works as a hard one. Investors lose nothing; the fee recipient does. Not documented. |
| F2 | A priced adapter whose target answers but does not pay is stuck | True | A target that refuses `withdraw` and still answers `previewRedeem`: `deallocate` reverts, `removeAdapter` is `Portfolio_NotEmpty`, `writeOffAdapter` is `Portfolio_StillPriced`, and with the adapter on the list the portfolio cannot be replaced. |
| F3 | `adopt` and the fee model, in either order | Partly | The order is documented in `INavDesk` (plug first). The list's fix, `if (lastFeeAt == 0)`, would charge for time a model was switched off, so it is not taken. New and true: a proposal made on the new desk before `adopt`, executed after it, writes its own mark over the adopted one; with a lower mark the same gain is charged twice. |
| F5 | The mark moves when the performance fee rounds to nothing | True, bounded | A 3-unit gain on a 10,000 vault moves the mark and charges 0. The loss is under one raw unit per count, the bound `SECURITY.md` gives the management fee, which it does not say for this one. The mark moves on purpose (`FeeModel.sol`'s comment). |
| F6 | The 7540's `maxDeposit` and `maxRedeem` overstate a request that rounds to nothing | True | With `owed == 0` and `paid > 0` both return `paid`, and claiming it reverts with `Gated7540Vault_ZeroAmount`, which ERC-4626 forbids of a `max*`. |
| F8 | `canTransfer(0, 0, x)` reads true on a list without `CredentialRule` | True in the base | With a hook that accepts everything it is true and `TRANSFER_OK`, while `mint(address(0))` reverts. Every shipped profile lists `CredentialRule` first, which refuses it. |
| F9 | `Fund`'s monitor reverts on a class whose hook has no code | True | A class whose `policyHook()` returns zero makes `isClassIntact` and `firstBrokenClass` revert, though the comment says a failing hook answers false. Shipped code cannot install such a hook. |
| F10 | `Distributor.approve` after expiry; `cancelEntry` of a used nonce | True, minor | The late approval pulls the funding, which anyone can then sweep back to the funder. The cancel emits `EntryCancelled` for an entry that already ran. |
| F11 | Gaps in `assertHandedOver` | True | It does not ask that no known account and not the zero address hold `PROPOSER_ROLE` or `EXECUTOR_ROLE` on either timelock beyond governance, nor that the validators are attested, the accounts' permissions and the portfolio's caps are what the profile names. |

### What does not

- **F7** is false: `bytes4` of calldata shorter than four bytes pads with zeros, and `ERC4626CallValidator.validate` returns false for empty, 1-byte and 3-byte data (run).
- **F4** is the documented design: with no shares the next investor buys at par and what is left counts for them under the rate limit; a 1-unit first deposit only keeps that release slow until real money arrives, and nobody gains.
- **The optimizations.** `MerkleProof.verifyCalldata` in `Distributor.claim` is taken. Not taken: the `Distribution` packing, which is false (three addresses, a `uint64` and a `bool` need six slots however they are ordered); `this.registry()`, as `registry()` is external and an internal getter in the base would change every template for two timelock-only setters; skipping the second count in a deposit, whose suggested form changes what the `maxDeposit` view answers after an earlier count in the block; packing `NavDesk` and the two short cuts in `Portfolio` and `ComplianceHook`, all on paths that run once a period or less.

### What changes, in two pull requests and then the pages

**First pull request: the small fixes.** Tests first; each failing run shown.

1. **F2.** A priced adapter qualifies for `writeOffAdapter` when it cannot be priced or cannot pay out what it is priced at: `!fresh() || liquid() < value()`. ERC-4626 has `maxWithdraw` read 0 while withdrawals are disabled, so a paused or blocking target qualifies, and a healthy one still does not. A target that answers `maxWithdraw` wrongly is still stuck, which goes in `SECURITY.md`. NatSpec in `IPortfolio`.
2. **F3.** `adopt` refuses while this desk has a proposal on the table (`NavDesk_CannotAdopt`). And the order stops mattering: `adopt` records that it took the old desk's fee clock, and a first plug after it keeps that clock instead of restarting it; any later plug, after the model was switched off, restarts it as now. One private flag beside `_adopted`. NatSpec in `INavDesk`.
3. **F6.** `maxDeposit` and `maxRedeem` return 0 when what is owed is 0.
4. **F8.** The pre-flight refuses a mint to the zero address with `ZERO_RECEIVER`, an existing reason, so `canTransfer` is false and `canTransferWithReason` names it.
5. **F9.** `_listsInstalledRule` answers false for a token or a hook with no code.
6. **F10.** `Distributor.approve` refuses after the expiry (`Distributor_Expired`); `cancelEntry` refuses a used nonce (`SignedEntry_NonceUsed`), as `cancelIntent` does. Both errors exist.
7. **F11.** `assertHandedOver` asks the timelock roles of the zero address and every known account, that each validator is attested as `VALIDATOR`, and that the accounts' permissions and the portfolio's caps are the profile's.
8. **`verifyCalldata`** in `Distributor.claim`.
9. **F5** goes in `SECURITY.md` beside the management fee, with its bound.

**Second pull request: F1.** A full catch-up needs to know what was already paid inside the band. The fix that follows the list (move the mark by the gain settled) restarts the hurdle's clock, so the next count would charge the whole catch-up with the price at the hurdle; it is not taken. The options:

- **A. Carry what was paid (recommended).** The caller keeps `paidSince`, the performance fee per `1e18` share units since the mark last moved, and passes it to `quote`. A soft hurdle's target is `min(rate × (price + paidSince − mark), price + paidSince − hurdled)`, and it charges the target less `paidSince`. While the catch-up is incomplete the mark and its clock stay and `paidSince` grows; once complete the mark moves to the price after fees, its clock restarts and `paidSince` returns to 0. Worked on the list's figures: 0.0001 at 1.1001, then about 0.0249 at 1.125, about 0.025 in all, as one count would charge (less only the hurdle's growth between the two counts). A price that falls back keeps what was paid, and a later rise charges only the rest. A hard hurdle is unchanged. Cost: `IFeeModel.quote` takes and returns one more value, so its id moves and `InterfaceFreeze.t.sol` is re-pinned; the 4626 appends one field to its ERC-7201 storage (upgrade-safe) with a getter; `NavDesk` stores it, freezes it in `Proposal` (so the proposal hash covers it), and `adopt` copies it; `FeeModel` gets a new codehash for the council. `CLAUDE.md` §7 describes the new rule.
- **B. Charge the catch-up only once it completes.** No new state and no interface change: inside the band a soft hurdle charges nothing and leaves the mark, and at the first count where `rate × (price − mark) ≤ price − hurdled` it charges `rate × (price − mark)`. The list's path then charges 0.025. A holder who leaves inside the band pays no performance fee, and a fund that never clears the band pays none on that gain.
- **C. Drop the soft hurdle.** The constructor refuses it. Smallest, and it removes a product feature.

**Then the pages**, pinned to the second pull request's commit: `FeeModel`, `Portfolio`, `NavDesk`, `Gated7540Vault`, `Fund`, `Distributor`, `SignedEntry`, `PolicyGatedERC20Upgradeable` and `deployment` where they describe what changes.

### For the owner

1. F1: A, B or C.
2. Rule 4: NatSpec in `IPortfolio` and `INavDesk` for the first pull request, no id moving; with A, also `IFeeModel` (its id moves), `INavDesk.Proposal` and one getter in `IGated4626Vault`.

Checks for each pull request: the full suite, the isolated run, lint and format, Slither, Aderyn, Halmos, `validate:upgrades`, `verify:reproducible`, planted bugs by hand, and the sizes of the contracts that change.

The owner chose A and said to build it, which is read as the rule 4 instruction for the interface edits listed above.

### As built: the small fixes

As planned, with these differences:

- **F3.** A first plug keeps the adopted clock only in the block of the adoption, the batch the timelock runs, in either order. With the clock kept until any later plug, the time the new desk dealt with no model, and the periods it settled meanwhile, would have been charged. A plug in a later operation starts the clock, as before.
- **F2.** `test_APricedAdapterThatCanStillBeReadCannotBeWrittenOff` read a mock whose liquidity defaults to zero, which now qualifies; it sets the liquidity to the value and is renamed for what it shows.
- **F6.** `test_WhenOwedRoundedToNothing_TheAmountsStillClear` pinned `maxDeposit` at the amount that bought nothing; it now reads the booked amount from `claimableDepositRequest`, before and after `recoverClaimable`.
- **F11.** The account's permission is asked by its target and function; a `GuardedAccount` keeps no list of its permissions, so the check cannot show there is no other. The custodian's address is a deployment parameter the profile does not name, so it is not compared.
- `ISignedEntry` and `IDistributor` are unchanged: both errors existed, and their NatSpec still holds.

Tests first: 9 failing for F2, F6, F9 and F10, 3 for F3 and F8, 4 for F11; three desk tests describing what it already did passed, and pin it. The same-block form of the adopt-then-plug test came after that run; the planted bug that restores the old plug, which always restarts the clock, fails it. `npx hardhat test`: `1888 passing (1711 solidity, 177 nodejs)`. Isolated 1711 passing; lint, format and types; Slither 0; Aderyn 0; Halmos 22 of 22; `validate:upgrades` 5 of 5; `verify:reproducible` 30 contracts. Planted bugs: 23 of 23 caught (`SECURITY.md`, section 5). Sizes: `Gated4626Vault` 24,287 bytes (289 free), `Gated7540Vault` 22,015, `NavDesk` 11,457, `Portfolio` 12,062, `IntentToken` 17,990.

### As built: the soft hurdle's catch-up (option A)

As planned. `IFeeModel.quote` takes `paidSince` and returns `newPaidSince`; the 4626 appends `paidSinceMark` to its ERC-7201 storage with a getter, and the desk stores it, freezes it in `Proposal` after `markMovedAt`, hashes it and adopts it with the mark. Both restart it at zero with the mark when fewer than `1e6` share units are left.

- **A hard hurdle uses the same rule.** What was paid since the mark moved comes off what is due. It is zero unless a soft model was swapped for a hard one inside its band, and then the hard one does not charge again for what the soft one took.
- **A band charge that rounds to nothing changes nothing**, where a completed one still moves the mark to the price, as `SECURITY.md` explains.
- `FeeModel.quote` was too deep for the stack with the new value, so the performance fee moved to `_performanceFee`, and the due amount to `_dueSinceTheMark`.

Tests first: the signature changed first with the old behaviour (153 passing), then 7 model tests failed, then 3 desk tests and the 4626 test failed with the getters in place and nothing stored. One desk test failed for the wrong reason first: the suite's `_close` warps to a day after the last cut-off, back from the year the test had advanced, so those tests close the period directly. `npx hardhat test`: `1904 passing (1727 solidity, 177 nodejs)`. Isolated, lint, format, types, Slither 0, Aderyn 0, Halmos 22 of 22, `validate:upgrades` 5 of 5 and `verify:reproducible` 30 contracts ran at 1,902 tests, before the two tests for the planted bugs' survivors, which touch only test files. Planted bugs: 17, 14 caught at first; two survivors are now caught and one is equivalent (`SECURITY.md`, section 5). Interface ids re-pinned: `IFeeModel` `0xefb71fde`, `INavDesk` `0x17066f0f`, `IGated4626Vault` `0x7c5d7975`. Sizes: `Gated4626Vault` 24,384 bytes (192 free), `NavDesk` 11,792, `FeeModel` 1,580.

## HTML pages at `ce7c6c4` (2026-11-05)

The pull request after #31 and #32. The 40 pages are pinned to `ce7c6c4`, and change where they describe what those two changed: the write-off rule (`Portfolio`, `Gated4626Vault`, `money`), `adopt` and the fee clock, and the carried catch-up (`NavDesk`, `FeeModel`, `Gated4626Vault`, `money`), the 7540's `max*` (`Gated7540Vault`), the pre-flight on a mint to the zero address (`PolicyGatedERC20Upgradeable`, `movement`), the fund's monitor (`Fund`), `approve` and `cancelEntry` (`Distributor`, `SignedEntry`), and the hand-over check (`deployment`, `GovernanceTimelock`).

- One agent checked about 95 changed claims against the code and found 11 problems: the zero address opens only `EXECUTOR_ROLE` on OpenZeppelin's timelock; the check asks named accounts about proposer and executor only; two unchanged sentences that the fixes made false, on the first plug and on when the mark moves; two lists of the model's inputs missing `paidSince`; two citations that did not show what they were cited for; the worked example's second count keeps the same hurdle; the 7540's zero reads apply to one side; and `canTransfer` returns no reason. Each was checked by hand and applied. These fixes have had the lint and no further independent check.
- The contracts do not change, so the pin holds.

## The NFT template (planned 2026-11-05; approved by the owner the same day: "A, build it")

Source: the owner, 2026-11-05: "I want to have several templates to provide to my clients, by creating different products", an NFT among them, built with only the contracts it needs, with tests. This reopens step 2 above, re-derived from the code at `ce7c6c4`. Nothing is built.

### What the NFT reuses unchanged

Read from the code, and to be proven by the integration test:

- **`ComplianceHook`** asks a token only `hasRole(DEFAULT_ADMIN_ROLE, …)` in `setRules`, and accepts `afterTransfer` from the token it names. It never reads an amount.
- **`ProxyDeployer.deploy`** asks the new proxy `registry()`, `policyHook()` and `symbol()`, which an ERC-721 with the core has under the same selectors.
- **`CredentialRule`** and **`HolderRestrictionRule`** read `from`, `to`, `kind` and `operator`, ask the token `hasRole`, and never read `amount`, `id` or `extra`. Who may hold the NFT, and each holder's lockup and address freeze, work as they do on a token.
- **`PolicyRegistry`**, both timelocks, `CredentialRegistry`: unchanged.

Refused on the NFT, by the profile check in `ignition/profiles.ts`:

- `MinPositionRule`: a minimum of NFTs held means nothing for unique items.
- `FundHoldersRule`: `Fund.registerClass` asks ERC-165 for `IPolicyGated` and reads `totalSupply`, which a plain ERC-721 has not.
- `SupplyCapRule`: it reads `IERC20.totalSupply`.
- `SettlementWindowRule` and `ExecutedOnlyRule`: already refused on every template without intents.

### The token

`contracts/tokens/Gated721.sol`, one concrete contract on `ERC721URIStorageUpgradeable`, with the same parents as the ERC-20 base otherwise (`AccessControlUpgradeable`, `PausableUpgradeable`, `MulticallUpgradeable`, `UUPSUpgradeable`, `ReentrancyGuardTransient`). It implements ERC-7943's non-fungible interface (Final, id `0xbf1ef5fe`). No permit, no enumeration, no royalties, no intents, no DvP.

| Function | Who | Note |
|---|---|---|
| `mint(to, tokenId, uri)` | `MINTER_ROLE` | Plain `_mint`: no receiver callback, so no re-entry on issuance |
| `burn(tokenId)` | `BURNER_ROLE` | Enforcement: may take a frozen token and clears the freeze. No holder burn, as on the ERC-20 base |
| `forcedTransfer(from, to, tokenId)` | `AGENT_ROLE` | Clears the freeze first; `Frozen(from, tokenId, false)` before `Transfer`; then the standard's `ForcedTransfer` and our `ForcedTransferBy` |
| `setFrozenTokens(account, tokenId, frozen)` | `AGENT_ROLE` | A bool per account and token, overwritten as the standard says; may name a token the account does not hold |
| `setTokenURI(tokenId, uri)` | `AGENT_ROLE` | Corrects metadata; OpenZeppelin emits ERC-4906's `MetadataUpdate` |
| `pause`, `unpause`, `setPolicyHook`, `revokeRole`, upgrades | as on the ERC-20 base | Guardian stops only; timelock and recovery timelock as in brief §4 |
| `canTransfer`, `canTransferWithReason`, `canSend`, `canReceive`, `getFrozenTokens` | anyone | `canTransferWithReason` runs the write's path minus the write, ownership included |

The movement path, one `_move` as on the ERC-20 base:

1. ERC-721's own checks first: the token exists and `from` owns it, and the caller is the owner or approved (`ERC721IncorrectOwner`, `ERC721InsufficientApproval`). A forced transfer and a burn skip the approval check, as `_update` with `auth == 0` does.
2. Paused rejects everything except FORCED.
3. A frozen token rejects everything except FORCED and a burn by `BURNER_ROLE`, with the standard's `ERC7943InsufficientUnfrozenBalance(account, tokenId)` and reason `INSUFFICIENT_UNFROZEN`.
4. The hook, with `id = tokenId`, `amount = 1`, `operator = msg.sender` and `extra = abi.encode(fromCount, toCount)`, the holdings before the move. A rejection is `PolicyGated_TransferRejected(reason)`.
5. The move, then `afterTransfer` if the hook wants it, inside the guard.

`safeTransferFrom` calls `onERC721Received` after the move and after `afterTransfer`, outside the guard. The state is final by then, and a receiver that calls back into the token takes the same path as anyone.

Pre-flight: `canTransferWithReason(from, to, tokenId)` says `NOT_TOKEN_OWNER` when `ownerOf(tokenId) != from`. That one appended reason covers a transfer by a non-owner, a burn of a token that does not exist, and a mint of an id that already exists (its owner is not the zero address). It does not take the caller, so approval is not judged, as the ERC-20 base does not judge an allowance. `canTransfer` is the standard's bool. Whether it may leave ownership to ERC-721, as the ERC-20 base leaves a balance shortfall, is checked against the Final text when the tests are written, and the test pins the answer.

### The one decision: share the core, or copy it

The ERC-20 base cannot be inherited: `_update` has another shape, frozen amounts are another type, and `IPolicyGated` inherits `IERC7943Fungible`, whose `setFrozenTokens(address,uint256)` and `getFrozenTokens(address)` an NFT cannot implement. The part that has nothing to do with amounts is about 150 lines: the role constants, pause and unpause with the recovery path, the hook pointer and its attestation check, `registry`, `revokeRole` for the recovery role, `_authorizeUpgrade` with the template check, the account-level answers behind `canSend` and `canReceive`, `_inferKind`, and the init that grants roles and installs the hook and rules.

- **A. Share it (recommended).** Move that part into an abstract `contracts/base/PolicyGatedCoreUpgradeable.sol` with its own ERC-7201 location for `registry` and `hook`; `frozen` stays with the ERC-20 base. One copy of the code that governs every template, so a fix lands once and the audit reads it once, and a later ERC-1155 reuses it. The core declares the logic as internal functions and each template keeps its external functions as thin wrappers, so `IPolicyGated`'s functions and id stay as they are if the compiler allows it; if it does not, `IPolicyGated` inherits a new `IPolicyGatedCore` and its id is re-pinned in `InterfaceFreeze.t.sol`. Event topics and error selectors do not move either way. The cost is a change to the shipped base before any NFT code, its own pull request, behaviour unchanged and every existing test passing with edits only to pins and storage locations (nothing is deployed, so the layout is free). Stop condition: `Gated4626Vault` has 192 bytes free today; if the split pushes it over, stop and report.
- **B. Copy it.** `Gated721` carries its own copy of that part and touches no shipped contract. Smallest change today. Two copies of the governance code to audit and to keep in step, and the copy grows with every template.

### Interfaces (rule 4)

All new or appended, needing the owner's instruction:

- `IERC7943NonFungible.sol`: the standard's interface as written, its id pinned at `0xbf1ef5fe`.
- `IGated721.sol`: `mint`, `burn`, `pause`, `unpause`, `setPolicyHook`, `policyHook`, `registry`, `canTransferWithReason`, `setTokenURI`; `ForcedTransferBy(from, to, tokenId, agent)`. Errors and `PolicyHookChanged` keep the names and signatures of `IPolicyGated`, so integrators decode both families the same way.
- `Errors.sol`: `NOT_TOKEN_OWNER` appended.
- With A, possibly `IPolicyGatedCore`, as above.

### Deployment

`Gated721` joins `Template` and `IMPLEMENTATION_KEY` (`nftImpl`) in `ignition/profiles.ts`, `Core` deploys its implementation when a profile lists one, and `Product` grants it `MINTER_ROLE` and `BURNER_ROLE` as it does a token's. Its `initialize(name, symbol, admin, guardian, registry, hook, rules)` takes the arguments `Product` already passes to a template without decimals or an asset. New profile `nft`: one `Gated721` with `credentialRule` and `holderRestrictionRule`. `assertHandedOver` and the post-deploy check cover it as they cover a token.

### Tests, written first

- `contracts/tokens/Gated721.t.sol`, with a mocked hook (`vm.mockCall` and `vm.expectCall`): every role gate; mint, burn and transfer reach the hook with the zero addresses, `id`, `amount = 1` and the counts in `extra`; a hook rejection changes nothing; a frozen token cannot be moved by its owner or an approved operator, a forced transfer and a burner's burn clear it with `Frozen` before `Transfer`, and a freeze may name a token the account does not hold; pause blocks all but FORCED, the guardian cannot unpause, the recovery role can; `setPolicyHook` and upgrades refuse an unattested target and another template; pre-flight parity with the write, fuzzed with `bound`; a re-entrant `onERC721Received`; `multicall`; ERC-165 ids from solc against `0xbf1ef5fe`, ERC-721, ERC-721 metadata and ERC-4906; an invariant that a frozen token moves only by a forced transfer or a burner's burn.
- Integration: the real hook, `CredentialRule` and `HolderRestrictionRule`, deployed through `ProxyDeployer`: an unverified receiver is refused, a locked holder cannot transfer and the agent can still force, an address freeze stops sending and receiving, and every refusal compares pre-flight with the write.
- `test/nodejs/products.test.ts`: the `nft` profile deploys and passes the hand-over check, a client verified once holds both the NFT and a token, and the profile check throws on the four refused rules.
- `InterfaceFreeze.t.sol`, `ContractSizes.t.sol`, `scripts/verify-reproducible.ts`'s list, `validate:upgrades`.

### Pull requests

- With A: the core split first, alone; then `Gated721` with its profile; then the HTML pages, pinned to the merged commit.
- With B: `Gated721` with its profile; then the pages.

Checks for each: the full suite, the isolated run, lint and format, Slither, Aderyn, Halmos, `validate:upgrades`, `verify:reproducible`, and the sizes.

### Not in this work: an account per NFT that holds gated tokens

The owner asked on 2026-11-05 whether each NFT could have its own account (ERC-6551 token-bound accounts) that holds gated tokens. Not built, on its merits:

- **Control moves where no gated token can see it.** The gated token's holder of record is the account. Selling the NFT hands control of everything in it to the buyer, and no gated token moves, so none of its rules runs: the buyer's credential, the seller's lockup, the fund's investor cap, the minimum position and the settlement window are all skipped. Every gated token's pre-flight would still say the right thing about the account and nothing about who controls it.
- **The account cannot hold a true credential.** Its eligibility is its owner's, and the owner changes with every NFT transfer. A credential on the account's address cannot follow that.
- **Enforcement splits in two.** A freeze or forced transfer on the gated token acts on the account; a forced transfer of the NFT, by another token's agent, moves control of tokens whose own agent never acted.
- **It is the call surface `GuardedAccount` exists to prevent.** A token-bound account runs any call its NFT's owner asks for. Its implementation would need its own attestation, and the standard's registry lets anyone create accounts over any implementation.
- **Known failure modes.** An owner can empty the account while a sale of the NFT is pending, and an NFT owned by its own account locks both for good.
- **Little to gain here.** With issuer custody (P24) and a permissioned chain (P23), the open composability these accounts are for is not on offer anyway.

If a product needs a position of gated tokens that changes hands as one unit, the sound shape is an escrow lego over one gated token named at construction, plus a rule on the NFT that asks that token whether the receiver could hold it. Even then the underlying token's holder cap and minimum see the escrow, not the owners, so it must never wrap a fund class with a cap. It gets its own plan when a product asks for it.

### As built: the core split

The owner answered "A, build it" on 2026-11-05, which is read as the rule 4 instruction for the interfaces this section lists. As planned, with these differences:

- **`IPolicyGated`'s id moved**, from `0x02331726` to `0xcebd0f8c`, and `IPolicyGatedCore` is `0xcc8e18aa`; the two XOR to the old id, so nothing was added or lost. Thin wrappers would have kept the old id, but then the core would have to emit events and errors declared in `IPolicyGated`, and an ERC-721 would emit the fungible interface's declarations. No event topic or error selector moved.
- **Solidity does not find an inherited member through a type name**, so tests that named `IPolicyGated.PolicyGated_TransferRejected`, `IPolicyGated.policyHook` and the like now name `IPolicyGatedCore`. Calls on an instance, `IPolicyGated(token).policyHook()`, are unchanged.
- **The ERC-20 base has no initializer of its own.** Its only state is the frozen amounts, which start at zero. The upgrades validator counts only parent initializers that contain statements, so `Gated4626Vault`, which expands the parents around `__ERC4626_init`, could satisfy neither a composite one nor an empty one. Each template now calls `__ERC20_init`, `__ERC20Permit_init` and `__PolicyGatedCore_init`, and the validator stays fully on.
- **Storage.** The core keeps `registry` and `hook` at `gated.storage.PolicyGatedCore` (`0x24cd…f100`). The ERC-20 location `gated.storage.PolicyGatedERC20` keeps only `frozen`, so the one test that clears the hook slot names the core's location.

Checks: `npx hardhat test` `1904 passing (1727 solidity, 177 nodejs)`, the same count as at `ce7c6c4`; lint, format and types; `validate:upgrades` 5 of 5; Slither 0; Aderyn 0; Halmos 22 of 22; `verify:reproducible` 30 contracts.

| Deployed size, bytes | `ce7c6c4` | After the split |
|---|---|---|
| `GatedToken` | 14,994 | 15,033 |
| `IntentToken` | 17,990 | 18,029 |
| `Gated4626Vault` | 24,384 | 24,402 (174 free) |
| `Gated7540Vault` | 22,015 | 22,054 |
| `Gated7540Settlement` | 18,075 | 18,118 |

### As built: `Gated721`

As planned, with these differences and details:

- **`ERC721Upgradeable._update` is overridden to check approval before the policy.** OpenZeppelin checks it inside the same function, so the override reads the owner, checks approval, then takes `_move`, which calls the parent's `_update` with no caller once the checks pass. An unapproved caller gets ERC-721's error and the hook is never asked.
- **`mint` and `burn` check existence before the move.** OpenZeppelin's `_mint` reports an existing token only after the update, which would ask the hook about a transfer, and its `_burn` reports a missing one only after asking about a mint to the zero address.
- **`canTransfer` leaves ownership to ERC-721.** The Final text says it must not return false for non-permissioned checks such as a balance or an allowance, and it does check the frozen status, so `canTransfer(stranger, …)` reads true while `canTransferWithReason` says `NOT_TOKEN_OWNER`.
- **Events.** `ForcedTransferBy` and the standard's `ForcedTransfer` have the fungible templates' signatures and topics; the standard's NFT `ForcedTransfer` indexes the token id. `Frozen(account, tokenId, frozenStatus)` has its own topic.
- **Interfaces.** `IERC7943NonFungible` (`0xbf1ef5fe`, from the standard's selectors) and `IGated721` (`0x94f4fff1`) are new, and `NOT_TOKEN_OWNER` is appended to `Errors.sol`, all pinned in `InterfaceFreeze.t.sol`.
- **Four Aderyn lows are suppressed inline with their reasons:** the storage constant read in assembly, the plain `_mint` (no receiver callback on issuance), `_requireOwned` called for its revert, and the previous owner `super._update` returns, which the caller already read.
- **Deployment.** `Gated721` joined `Template` (`nftImpl`), the `nft` profile, `Product`'s minter and burner grants, the fixtures and `verify-reproducible`'s list. The profile check refuses `minPositionRule`, `fundHoldersRule` and `supplyCapRule` on it, as well as the two rules that need intents. `legos.test.ts` deploys every profile, so `nft` passes the hand-over check there too.

Tests first: against a stub that skipped every check, 29 of the 74 tests in `Gated721.t.sol`, `InterfaceFreeze.t.sol` and `ContractSizes.t.sol` failed: every policy, freeze and pre-flight case. The 45 that passed were role gates, ERC-721's own checks and the pins. The three deployment tests failed before the profile existed. Three planted bugs were each caught: the burner's freeze exemption removed (1 failing), approval checked after the hook (2 failing), and `canTransfer` counting ownership (1 failing).

Checks: `npx hardhat test` `1973 passing (1794 solidity, 179 nodejs)`; lint, format and types; `validate:upgrades` 6 of 6; Slither 0; Aderyn 0; Halmos 22 of 22; `verify:reproducible` 31 contracts. `Gated721` is 15,621 bytes; no other contract changed in this step.

Left: the HTML pages for the core and `Gated721`, pinned to the merged commit, in their own pull request.

### Outside review of `Gated721` (2026-11-05)

The owner passed on three findings and said to fix the first.

1. **Burn pre-flight: fixed.** `_canTransfer` took the sender as a burn's operator, as the ERC-20 base does, where holders and vaults burn their own shares. The NFT has no holder burn, so the burner's pre-flight about a frozen or locked holder's token said `INSUFFICIENT_UNFROZEN` or `LOCKED` while `burn` succeeded. A burn's operator is now the caller, as a mint's is, and the caller's role is not judged, as for a mint. Asked from the burner's address, the pre-flight agrees with `burn`. The ERC-20 base is unchanged: the vaults' `maxRedeem` asks about a holder's own burn. NatSpec only in `IGated721`; its id did not move. Tests first: 3 failing, among them a new fuzz of the burn pre-flight against `burn`.
2. **Balance rules on the NFT: no change.** The context carries `amount = 1` and the balances in `extra`, and `MinPositionRule` compares before it subtracts, so nothing underflows. What holds is that only the profile check refuses `MinPositionRule`, `FundHoldersRule` and `SupplyCapRule` on a `Gated721`; a timelock `setRules` could still list them. The first then counts tokens, the second refuses every movement with `NOT_FUND_CLASS`, and the third reverts every mint and its pre-flight, as the NFT has no `totalSupply`. Each fails closed or means nothing.
3. **`IPolicyGated` casts in `BaseRule` and `ProxyDeployer`: not changed.** The selectors are those of `IPolicyGatedCore`, so behaviour is the same, and changing the source would change every rule's codehash for readability alone.

Checks: `npx hardhat test` `1975 passing (1796 solidity, 179 nodejs)`; lint, format and types; `validate:upgrades` 6 of 6; Slither 0; Aderyn 0; Halmos 22 of 22; `verify:reproducible` 31 contracts. `Gated721` is 15,639 bytes.

### Pages and the follow-up list (2026-11-05)

The pages landed in #36 (`379db88`), with two new ones, `PolicyGatedCoreUpgradeable` and `Gated721`. An outside list after it found stale counts and gaps, and the follow-up pull request fixes the ones that hold:

- **The pages.** The number of reason codes and profiles; the `nft` row of the hook's rule lists; `assertUsable`'s refusals on an NFT in two more places; five templates in `TokenProxy`, whose upgrade check is the core's; the money page's "every template is an ERC-20".
- **The Markdown files.** In `README.md`, the architecture, the file table, the grants and the NFT's burn pre-flight; in `SECURITY.md`, the scope, the reopening of the interfaces, the suppressions and a mutation row for `Gated721`; in the brief, `NOT_TOKEN_OWNER` among the appended reason codes.
- **Two tests, so `SECURITY.md`'s evidence holds.** `Gated721.t.sol` gains `test_WhenEtherIsSent_ItReverts` and `test_TheErc7201LocationHoldsTheFreezes`, which every other template already has in its own form. A wrong location constant planted in the contract fails the second.
- **Not taken from the list:** a mutation count of 56 for `Gated721`, which no run here produced. The mutation row records the planted bugs that were run. The list also named a `PolicyGatedCoreUpgradeable.t.sol`, which does not exist: the core is tested through each template.

A separate check of the follow-up's 35 changed claims found 1 wrong and 2 unsupported, all applied.

## Every page and the Markdown files checked at `6fc1953` (2026-11-05)

The owner asked for the cleaning and a final review of all the docs once `Gated721` had landed.

- **Cleaning.** The nine local branches left from #12 to #20 were deleted: each was the pre-rebase copy of a merged pull request, so `main` is the only branch, here and on GitHub. Every gate passed on `main`: lint, format, build, typecheck, 1977 tests (1798 Solidity, 179 Node.js), the isolated profile, Slither and Aderyn with 0 findings, Halmos, upgrade safety (6 of 6) and the reproducible build.
- **The check.** Fourteen separate checkers read every claim in the 42 pages, `README.md`, `CLAUDE.md` and `SECURITY.md` against the code, about 4,400 claims: 42 problems in the pages, `README.md` and `SECURITY.md`, every one confirmed in the code and applied, and one name on the `Gated721` page made to match the other pages. The pages keep their pin, `9526fc7`: only a test file changed since.
- **What they were.** Stale sizes and counts (the 7540's second contract, the contracts on the overview, the fields the desk's proposal hash covers); refusals or cases left out (`approve`'s expiry, a period whose limit takes no redemptions, `Gated721` in the incident runbook); test citations that showed less than the sentence said; two runs off the repository cited as evidence, removed; and in `SECURITY.md`, analyser suppressions in the source that its tables did not name, or named in the wrong function.
- **A second check** of the 45 changed lines found 2 more, applied.
- **The brief.** Four places in `CLAUDE.md` differ from the code: §4 shows `pause`, `setPolicyHook`, `policyHook` and `registry` on `IPolicyGated`, which now has them through `IPolicyGatedCore`, and §5's ERC-165 list leaves out `IPolicyGatedCore`, `IGated721` and `IERC7943NonFungible`; §5 calls 721 a future template; rule 4's list of reopenings leaves out 2026-10-17, 10-22 and 10-27; and rule 15 says every source file carries the licence line, which the TypeScript and shell sources do not. The brief is the owner's, so these wait for the owner's word.

## The brief brought in line with the code (approved by the owner 2026-11-05: "Yes, update it")

The four places the review of `6fc1953` found in `CLAUDE.md`:

- §4 shows `IPolicyGatedCore` (pause, unpause, the hook pointer, the registry, `PolicyHookChanged` and the four `PolicyGated_*` errors) and `IPolicyGated is IERC7943Fungible, IPolicyGatedCore` with `mint`, `burn`, `canTransferWithReason` and `ForcedTransferBy`, as the interfaces are.
- §5: `TransferContext.id` is the token id on `Gated721`, whose amount is then 1, and only 1155 is future. The ERC-165 list names `IPolicyGatedCore`, and what `Gated721` answers instead of `IPolicyGated`.
- Rule 4 names the reopenings of 2026-10-17, 2026-10-22, 2026-10-24 and 2026-10-27 that `InterfaceFreeze.t.sol` dates.
- Rule 15: the 25 TypeScript and shell sources gain `SPDX-License-Identifier: UNLICENSED` on their first line (after the shebang in `scripts/fetch-tool.sh`), so the rule holds as written.

## Every contract deployable alone or as a whole (planned 2026-11-06; approved by the owner the same day: "Yes, as recommended")

The owner, 2026-11-05: "I might want to deploy as a single contract each of them or as a whole." A product always sits on a core (the timelocks, the registry, the shared hook, `ProxyDeployer`), so alone means one product on a core of its own, or added to a core that already runs. The contracts do not change: this is deployment code, its tests and the docs.

### What works today

`token` (`GatedToken`), `nft` (`Gated721`), `vault4626`, `vault7540`, `managed-fund`, `vault4626-invest` and `full` each deploy a core and their products, and `test/nodejs/products.test.ts` runs the first four alone. A later product launches on a running core (`one core, many products`), but only one whose template, rules and executors that core already deployed.

### The gaps

1. **`IntentToken` alone.** It is deployed only inside `full`, as a class of the fund with both executors.
2. **A later product the core was not built for.** `Core` deploys only what its profile's products use. An issuer that started with `token` and later wants a vault, an NFT, an intent token or a rule it has not used has no module that adds the missing implementation, rule or executor to the core it runs: running another profile's `Core` builds a second core, with new timelocks, a new registry and a new hook.
3. **`SignedEntry`** has no module.
4. **`Distributor`** has no module. The brief says it waits for the first product with cash flows; the owner's instruction asks for it now.

### What changes

1. **`intent` profile.** One `IntentToken` with the plain rules (`CredentialRule`, `HolderRestrictionRule`) and the executors decision 1 picks. `assertUsable` already covers it.
2. **The core in two parts.** `Core` keeps the parts every issuer has once (the two timelocks, the registry, the hook, `ProxyDeployer`) and the parts a profile uses move into a module that takes those addresses as parameters (`CoreParts`: the credential registry and rule, the other rules, one implementation per template, the executors). A whole deployment runs both, so its addresses and the hand-over check stay as they are. Adding to a running core runs `CoreParts` with only what is missing: the council attests the new rules and implementations as it does today, and a `PartsHandover` gives the new executors their operator, recovery and guardian and hands them to the timelock. A part the core already has is never deployed twice; the module throws when asked to, before anything is sent. A credential rule cannot be added to a core that has none without a credential registry, so that case deploys both, as `Core` does today.
3. **`SignedEntry`.** It takes no constructor argument, holds no money and no role, and serves every vault of the chain. A `SignedEntry` module deploys it once per issuer, alone or with a core, when a profile asks for it. A vault accepts it only if its policy does, so the KYC attester credentials its address like any payer, outside the module, as the runbook already says for holders.
4. **`Distributor`.** One per token, its only argument the token. `Legos` deploys it against `ProxyDeployer.predict`, like the other legos, for a product that sets `distributor: true`, and `Product` grants the token's `DISTRIBUTION_MAKER_ROLE` and `CHECKER_ROLE` to the accounts the parameters name, before the hand-over. It is not attested, as the desk is not: it holds money only between an approval and the claims, and acts by roles the token grants.
5. **The post-deploy check.** For `SignedEntry`, the code at its address is the artifact's. For a `Distributor`, `TOKEN()` is its product, the maker and the checker are different accounts, and no account the stack knows holds either role besides them. The role scan reads a token's roles from the token's ABI, which does not name `DISTRIBUTION_MAKER_ROLE`, so the check asks for it by name. Adding parts to a running core: the stack still passes the check afterwards.
6. **Tests first** (`test/nodejs/products.test.ts`, `deployment.test.ts`): the intent token alone; a `token` core that later takes a vault, an NFT and an intent token with its executors, each passing the hand-over check; asking `CoreParts` for a part the core has throws; a signed entry on a vault deployed by the modules; a distribution proposed, approved and claimed on a deployed token; and the check refusing a distributor naming another token, one maker who is also the checker, and a stray maker.
7. **Docs.** `README.md` runbook and profiles, `docs/deployment.html` (the stages, the profiles, the check), the `SignedEntry` and `Distributor` pages (how each is deployed), and a re-pin. In the brief, §1 item 8 ("no deployment module yet") and Phase 7, which are the owner's to approve with this plan.

### Decisions for the owner (recommendation first)

| # | Question | Recommendation | Alternative |
|---|---|---|---|
| 1 | Which executors does the `intent` profile deploy? | Both, the intent executor and the DvP executor, as in `full`: an intent token's point is a signed movement, and a trade against cash is the main one | The intent executor alone, and DvP added later through `CoreParts` |
| 2 | One `SignedEntry` per issuer, or one per vault? | One per issuer: it has no state about a vault and no role, so one serves them all, and one credential admits it everywhere | One per vault, so each fund credentials its own |
| 3 | On a 7540 with a desk, the token's `CHECKER_ROLE` is the price checker. A `Distributor` on that vault asks the same role. | Accept it, and have the check refuse a maker who is also the checker: the same person approves prices and distributions, never their own | A role of its own for distribution approvals, which changes `Distributor` and its interface (rule 4) |
| 4 | Split `Core` as in point 2? | Yes: it is the one way to add a template to a running core without a second set of timelocks | Leave `Core` whole and accept that an issuer picks every template it will ever use on day one (`full`) |

### Size

Ignition modules and profiles, the fixture, two test files, and the docs. No contract, interface or test in Solidity changes.

### As built

- **The four answers as recommended.** `intent` deploys both executors; one `SignedEntry` per issuer; a distributor's checker is the `checker` account, the desk's where there is one; `Core` is split.
- **The split.** `deployParts` in `ignition/parts.ts` deploys the parts, and `Core` calls it for its profile, so a whole deployment has the same contracts and addresses as before. `corePartsModule(parts, present)` throws when `parts` is empty or names a part in `present`. `handOverParts`, in the same file, holds the credential registry's and the executors' steps, and `CoreHandover` calls it; `partsHandoverModule` throws when there is nothing to hand over. `partsOf` and `missingParts` in `profiles.ts` give a profile's parts by key. The command-line entries are `ignition/modules/CoreParts.ts` and `PartsHandover.ts`: `CORE_HAS` must list the running core's parts exactly, both take the same list, and an unset `CORE_HAS` throws, because an empty one would read every part as missing and deploy a second credential registry. The library sits outside `ignition/modules` so the tests import it without building a module from the environment.
- **`SignedEntry` is a part, not a module of its own.** It deploys through `CoreParts`, alone on a running core or with `Core` for a profile that sets `signedEntry`, which is simpler than a third module for one contract with no constructor argument. The plan said a module.
- **The check reads code with the immutables left out.** `isRelease` blanks the artifact's immutable positions on both sides and compares, then checks the immutables another way: a sample entry's `entryHash` must equal the EIP-712 hash for `SignedEntry`, version `1`, this chain and this address, which reads every domain immutable, and a distributor's `TOKEN()` must be its product. The plan named the code comparison for the signed entry only; the distributor gets it too, because a funder approves the distributor and a substitute could take the funding.
- **The pages follow in their own pull request,** pinned to this one's merge commit: they cite `CoreParts.ts` and `PartsHandover.ts`, which do not exist at the pages' current pin. `README.md`, the brief and this file change here.
- **A separate review** of the change found 8 problems, all fixed: the signed entry's domain was not really checked (`eip712Domain()` reports the chain and the address live), an unset `CORE_HAS` would have deployed every part again, `PartsHandover` could run empty, the tests imported a module file that builds from the environment, and four wording points in `README.md` and the brief. Two of its points are page points and go with the pages.
- **A fixture lesson.** `loadFixture` rewinds the chain but returns the same object, so a test that adds parts deploys its own stack.
- **Tests:** seven new in `products.test.ts`, written first and failing on the missing module. `npx hardhat test`: `1984 passing (1798 solidity, 186 nodejs)`. Ten planted bugs in the modules (a present part not refused, an executor left with the deployer, a missing operator, the signed entry or the DvP executor left out, the maker's grant missing or given to the checker, no checker without a desk, the distributor naming another address, `CoreHandover` skipping the parts): 10 of 10 caught.

## HTML pages at `8eb16b0` (2026-11-07)

The pages pull request after #40, which merged as `8eb16b0`. All 42 pages are pinned to it. `deployment` gains a section on adding parts to a running core (`CoreParts`, `PartsHandover`, `CORE_HAS` and what it trusts), the signed entry in `Core`, the distributor among the legos and its grants, the `intent` profile (eight profiles), and the check's rows for the signed entry and the distributor. `SignedEntry`, `Distributor`, `roles`, `index` and `money` say how each is deployed now; `ComplianceHook` lists the `intent` profile's rules; both executor pages name `intent` and `CoreParts`. The two page points from #40's review are in: the signed entry's check is described as a sample `entryHash`, and `CORE_HAS` as an exact list.

## Input checks in the deploy scripts, from an outside list (approved by the owner 2026-11-07: "Yes, fix them first")

An outside list against `8eb16b0` raised seven points that hold, all low. Six change here; the seventh is kept.

1. **`coreHas()` refuses a list that names nothing or names an unknown key.** `CORE_HAS=""` or `" , "` was read as an empty list, which deploys every part again, a second credential registry among them: the case the unset check exists for. A mistyped key (`GatedToken` for `gatedImpl`) was ignored and its part deployed again. Entries are trimmed; an empty result throws, and so does a key that is neither a core contract (`timelock`, `recoveryTimelock`, `registry`, `hook`, `proxyDeployer`, `credentialRegistry`) nor a part (`PART_KEYS` in `ignition/profiles.ts`: the rule keys, the implementation keys, `executor`, `dvpExecutor`, `signedEntry`).
2. **`assertUsable` refuses `executors` on anything but an `IntentToken`**, which made `Core` deploy an executor and `Product` grant it `EXECUTOR_ROLE` on a token that cannot run intents, and **`decimals` on anything but a `GatedToken` or an `IntentToken`**, which `Product` ignored. `assertUsable` runs when `Legos` or `Product` is built, as before: `Core` does not call it, so for such a profile `Core` still deploys the executor, and nothing is granted on it.
3. **`SECURITY.md`:** the deployment scope names `ignition/parts.ts`, `CoreParts.ts` and `PartsHandover.ts`, and the mutation table gains the row for #40's ten planted bugs and one for this change's.
4. **`README.md`:** the `Legos` step says a product with a distributor runs it too.
5. **This file:** open question 4 no longer says the NFT pages are to follow; they landed in #36.

Kept: `Legos` takes the same predicted address as `vault` (desk, portfolio) and `product` (distributor). A distributor can sit on a plain token, where `vault` is the wrong word, and renaming a parameter would change what operators pass today.

Tests first: the refusals in `test/nodejs/products.test.ts` (`coreHas`) and `test/nodejs/legos.test.ts` (`assertUsable`), shown failing before the change.

As built: the six tests failed first (5 `assertUsable` cases, and the `coreHas` test on `CORE_HAS=""`), each with "Missing expected exception". `npx hardhat test`: `1989 passing (1798 solidity, 191 nodejs)`; typecheck and format clean. Nine planted bugs, all caught (listed in `SECURITY.md` §5). The pages, pinned to `8eb16b0`, still say `CORE_HAS` is refused only when unset and list `assertUsable`'s refusals without these two; they change with the next re-pin.
## Each issuer chooses its KYC registry (planned 2026-11-07; approved by the owner the same day: "ok go for it! lets finish it")

The owner, 2026-11-07: "The shared registry could be deployed by us, and then whoever uses our whole deployment is using our things automatically whoever deploys solo "pieces" can connect to our centralRegistry, but upgrades should be individual", then "I think it should be their choice, of which Registries to use", then "go for it" on the assessment below.

### What the code already allows, and what it does not

- `CredentialRule` takes its `CredentialRegistry` in its constructor, and `Product` takes each rule's address as a parameter, so a token can already read any registry. The modules cannot: `deployParts` always deploys a new registry and rule when a product lists `credentialRule`, `handOverParts` always configures and hands over that registry, and `assertHandedOver` refuses any registry that is not the core's own (the main timelock must be its admin, the recovery timelock must hold `RECOVERY_ROLE` on it, it must have exactly one attester).
- A token's `PolicyRegistry` is fixed at `initialize`, and the hook and `ProxyDeployer` must name the same one. It stays each core's own: sharing it would hand another council every install and upgrade on the issuer's tokens, against "upgrades should be individual". Same code has the same codehash, so a solo issuer's council can attest on the strength of a published review.
- Upgrades are already individual: each token is its own proxy, `UPGRADER_ROLE` sits with its own core's main timelock, and the upgrade must be attested in that core's own `PolicyRegistry`. Nothing changes there.

### The assessment the owner agreed to

Choosing a registry is choosing whose governance decides the token's investors' eligibility, so the choice is explicit and checked:

1. The registry's admin adds attesters, changes what each may assert and which account signs under an attester id (`setAttesterAccount`). A token's policy trusts ids, so that admin decides who does KYC for the token. Its guardian blocks an investor or kills an attester with no delay, on every token reading the registry. The council's attestation of the rule covers the registry's address, not its governance.
2. One registry per token: `CredentialRule`'s `ruleId` is fixed (`CredentialRule.v1`) and the hook refuses two rules with one id, and a rule list is a conjunction. Accepting investors from either of two registries would need a new rule. Not in this change.
3. Records are public; a shared registry links one address across issuers.
4. Whether an issuer may rely on another's KYC is a legal question for the issuers, not something the code settles.

### What changes

No contract and no interface. Deployment scripts, the check, tests and docs.

1. **The profile.** `Profile.credentials?: "own" | "external"`, default `"own"`, which is today's behaviour, so every shipped profile and the whole deployment are unchanged. With `"external"`, the deployment's parameters name the existing rule (`credentialRule`) and the governance the issuer accepts: `credentialAdmin` (the account expected to hold `DEFAULT_ADMIN_ROLE` on the registry) and `credentialGuardian` (the one expected to hold `GUARDIAN_ROLE`). The registry's address is read from the rule's `REGISTRY()`, never given separately, so the two cannot disagree. One choice per deployment: the check pins one registry per core. (`Product` already takes the rule as a parameter, so a product on another registry is possible by hand; the modules do not offer it, as nobody asked.)
2. **`partsOf`** leaves `credentialRule` out with `"external"`, so `Core` and `CoreParts` deploy no registry and no rule, and `CoreHandover` and `PartsHandover` make no credential calls (they act only on the parts deployed). `assertUsable` is unchanged.
3. **The council step.** With `"external"` the council attests the named rule as `RULE` in its own `PolicyRegistry` (the codehash is the one any other council attested), after reading the registry's code and who governs it, which the README runbook says.
4. **`Product`** is unchanged: it sets each token's policy on the named rule, as the token's admin, and the policy names which of that registry's attesters the token trusts.
5. **The post-deploy check**, for `"external"`:
   - the product lists the named rule, the rule is attested as `RULE` here, and its `REGISTRY()` is a `CredentialRegistry` (its code compared with the release's);
   - `credentialAdmin` holds `DEFAULT_ADMIN_ROLE` and `credentialGuardian` holds `GUARDIAN_ROLE` on it;
   - none of this core's named accounts, its main timelock or its recovery timelock holds any role on it, and the registry is left out of the core's own admin and recovery pins;
   - each product's policy trusts at least one attester, and every attester its bitmap names exists and is not killed (with `"own"` the existing one-attester check stays);
   - each product's `policyOf` equals its profile's, as today.
6. **Tests** (`test/nodejs/products.test.ts`, one stack per test, since `loadFixture` shares objects):
   - a whole deployment with its own registry, then a solo issuer's `token` core with `"external"` naming that registry's rule: the solo core has no `CredentialRegistry` or `CredentialRule` of its own, and one investor credentialed once holds both issuers' tokens;
   - the cost made visible: the registry's guardian blocks that investor, and both issuers' tokens refuse to deliver to it;
   - upgrades stay individual: the solo issuer's timelock upgrades its token to a newly attested implementation while the other issuer's token keeps its implementation, and neither timelock holds `UPGRADER_ROLE` on the other's token;
   - the check refuses: a rule reading another registry, a registry whose admin or guardian is not the named one, this core's timelock or deployer holding a role on the external registry, a policy trusting no attester, and a policy trusting a killed or missing attester;
   - `partsOf` with `"external"` has no `credentialRule`, and `CoreHandover` builds with no credential call.
7. **Docs.** `README.md` (runbook: the choice, the parameters, the council's reading, the check bullets), `PLAN.md` as built, and the brief's Phase 7 and §6 `CredentialRule` paragraph, which are the owner's to approve with this plan: one sentence each saying a core may use an existing credential registry it names, with its governance named and checked. The pages follow in their own pull request, pinned to the merge commit.

### Done when

`npx hardhat test` passes in both runners with the new tests, typecheck, lint and format are clean, the new tests fail when the change is reverted (each new check is shown to catch its planted fault), and a separate review of the code and the added claims finds nothing open.

### Not in this change

A shared `PolicyRegistry`; a rule that accepts either of two registries; a product-by-product choice in the modules; a separate upgrader per fund manager inside one core.

### As built

As planned, with no contract or interface change. `Profile.credentials` and the `partsOf` exclusion are in `ignition/profiles.ts`; `Core`, `CoreParts`, `CoreHandover` and `PartsHandover` needed no code change, only a sentence each in `Core` and `CoreHandover`. The check is `assertHandedOver` in `test/nodejs/fixtures.ts`, whose launch has the council attest the named rule and attaches the registry from the rule's `REGISTRY()`; `addParts` keeps the profile's choice. Three differences from the plan:

- The attester check (at least one, each existing and not killed) applies to the core's own registry too, which the one-attester check already implied for the default policy.
- The check compares the registry's code with the release's, not the rule's: the council attested the rule, and the hook check pins the rule each product lists.
- The tests share one fixture (a `full` deployment, then the solo `token` core on its rule) where nothing changes the stack object, and deploy their own stack where something does (a part added, a policy or rule the deployment refuses).

Tests (`test/nodejs/products.test.ts`, "an issuer on another issuer's credential registry"): the solo core has no registry or rule, and one investor credentialed once holds both issuers' tokens; a later product on it adds its implementation and still no registry; the registry's guardian blocks an investor and both issuers' tokens refuse delivery; the solo timelock upgrades its token while the other issuer's tokens keep theirs, and neither timelock holds `UPGRADER_ROLE` on the other's tokens; the check refuses a named admin or guardian that does not hold its role, a stack registry the rule does not read, a rule that is not the named one, a role granted to this core's timelock on the registry, a policy trusting no attester, a missing one or a killed one, and a rule over a registry that is not the release's. `CoreHandover` takes no `credentialRegistry` parameter for the solo core, which shows it makes no credential call. The six first tests failed before the change (`ComplianceHook_NotAttested`: the solo core still built its own registry, and the named rule was never attested). `npx hardhat test`: `1996 passing (1798 solidity, 198 nodejs)`; typecheck and format clean. Twelve planted bugs, all caught (listed in `SECURITY.md` §5); the first run left one alive (parts added to an external core ignoring the choice), and the test for a later product on the solo core was added for it.

A separate review found no bug. From it: the check refuses an external profile whose stack attached no registry, the tests also plant a grant to the recovery timelock, and the README says that the registry's admin can kill an attester too and that an issuer adds its own profile for this.

Left as limits: the check runs at deployment, so it does not stop the registry's admin granting a role later; it does not pin who holds `RECOVERY_ROLE` on the external registry, a power the registry's admin already governs. The pages follow in their own pull request.

## The Paris build (branch `paris`, 2026-11-13)

The owner asked for a branch that runs on an EVM at Paris: no transient storage (EIP-1153), no `MCOPY` and no `PUSH0`. The design, the interfaces and every interface id are unchanged. This reverses "Cancun is accepted" (2026-10-23, P23) for this branch only.

### What needed Cancun

| Where | What | Answer |
|---|---|---|
| `PolicyGatedCoreUpgradeable`, `Portfolio`, `DvPExecutor` | OpenZeppelin's `ReentrancyGuardTransient` | The storage guard: `ReentrancyGuardUpgradeable` on the templates (its own ERC-7201 slot, set in the initialiser, so no layout moves), `ReentrancyGuard` on the two immutable contracts. Same error, same behaviour, one storage write and its refund on each guarded call |
| OpenZeppelin 5.6.1 | `MCOPY` in `Bytes` (through `Strings`, so every EIP-712 contract), `SignatureChecker`, `Memory` (through `ERC4626Upgradeable`) and `Arrays` (through `EnumerableSet`) | Pinned to 5.3.0, the newest release whose files used here have no Cancun opcode (5.4.0's `SignatureChecker` already imports `Bytes`) |
| Compiler | `evmVersion: cancun` | `paris` in `hardhat.config.ts` and `foundry.toml`; solc stays 0.8.30, optimizer 200 runs |

### What 5.3.0 changed in our code

- **`GovernanceTimelock`.** In 5.3.0 `updateDelay` is external and `_minDelay` is private, so a subclass cannot call it and then check the floor. The contract keeps the delay itself: `updateDelay` repeats OpenZeppelin's caller check and event and adds the floor, and `getMinDelay`, the only reader in `TimelockController`, returns that value. Same errors, same event, same order of checks.
- **`TokenProxy`.** 5.3.0's `ERC1967Proxy` accepts empty init data, so the `_unsafeAllowUninitialized` override is gone. The argument for safety is the same: `ProxyDeployer` creates and initialises in one transaction.
- **`ERC4626Adapter`.** `LowLevelCall` does not exist in 5.3.0. `_ask` makes the same bounded static call in a few lines of assembly: one word copied to the scratch space, a failure or a short answer is no answer.

### Size

Paris has no one-byte `PUSH0`, which cost `Gated4626Vault` about 590 bytes: 25,286 against the 24,576 limit. The vault stays one contract with the same behaviour. Measured savings, at 200 runs:

| Change | Bytes |
|---|---|
| One `_requireAttested` for the two attestation checks, calling `registry()` internally (now `public`, same ABI) | 307 (with the next row) |
| One `_entryClosed` for `maxDeposit` and `maxMint` | |
| `_hasAdapters` reads the offset and length of `adapters()` and never decodes the list | about 286 |
| One `_priceFresh`, `_pricedValue` and `_writtenOff` for reads made from several functions | about 290 |
| `setPortfolio` takes the vault's balance from OpenZeppelin's `totalAssets()` | 97 |

Result: **24,305 bytes, 271 left.** Refused: fewer optimizer runs (1 run fits with 175 left and changes every contract), the IR pipeline (measured larger), and a second contract for the 4626.

### Verified

`npx hardhat test`: 1996 passing (1798 solidity, 198 nodejs) on the Paris build. Format, lint, typecheck, `validate:upgrades` (6 of 6) and `verify:reproducible` (31 contracts identical) pass.

### Limits

- A token already deployed from the Cancun build has no reentrancy flag written; the guard reads zero as not entered, so an upgrade onto this build would still work, but no such upgrade was tested.
- OpenZeppelin 5.3.0 lacks what 5.4.0 to 5.6.1 changed. Reviewed on 2026-11-13 (below): nothing this code needs.
- The pages in `docs/` were edited where they named the transient guard, 5.6.1 or the proxy override; their pin to a commit was not moved.

### OpenZeppelin 5.3.0 against 5.6.1 (reviewed 2026-11-13)

Method: the import closure of the contracts that ship is 71 OpenZeppelin files. Each was diffed against 5.6.1 with comments and pragmas left out: 37 are identical, 33 differ, and one, `ReentrancyGuardUpgradeable`, no longer exists there (its flag moved into `ReentrancyGuard`). The changelogs of 5.4.0, 5.5.0, 5.6.0 and 5.6.1 and the library's published advisories were read beside the diffs.

| Change in a later release | Where this code meets it | Verdict |
|---|---|---|
| Advisory GHSA-9rcw-c2f9-2j55 (low): `Bytes.lastIndexOf` reads out of bounds, 5.2.0 until 5.4.0. The only advisory whose range covers 5.3.0 | `Bytes` is not in the closure at 5.3.0 | Not affected |
| 5.5.0 fix: `ERC165Checker.supportsERC165` said yes for a target that reverts on the `0xffffffff` query | `Fund.registerClass`, the only use | No effect on the templates, which answer false. It matters only for a contract that answers true for `IPolicyGated` and reverts on the invalid id, which the owner would have to register on purpose, and the checks after it (the hook lists the rule, supply zero) still run |
| 5.6.0: `ERC721._setApprovalForAll` refuses a zero owner | `Gated721` never calls the internal function, and the public one uses the caller | Not reachable |
| 5.6.0: `ERC1967Proxy` refuses empty init data unless `_unsafeAllowUninitialized` is overridden | `TokenProxy` overrode it to allow that, so both builds deploy the proxy empty and `ProxyDeployer` initialises it in the same call | Same behaviour |
| By 5.6.1 `SignatureChecker` reads only one word of an ERC-1271 answer; 5.3.0 copies the whole answer | `IntentSettled`, `SignedEntry`, `CredentialRegistry` | Hardening this build lacks. A contract signer can answer with a long payload and make the check cost gas, paid by whoever submits and bounded by the gas they give. It cannot change the verdict. The pre-flights (`canExecute`) show the cost before sending |
| 5.5.0: `ERC4626.maxWithdraw` is `previewRedeem(maxRedeem(owner))` | `Gated4626Vault` overrides `maxWithdraw` | No effect |
| 5.6.0: `ERC4626` gains `_transferIn` and `_transferOut` | Not used | No effect |
| 5.5.0: `ReentrancyGuard` moves its flag to the ERC-7201 slot `ReentrancyGuardUpgradeable` already uses in 5.3.0 | The templates | A later return to a newer release finds the flag in the same slot |
| 5.6.0: `Strings.escapeJSON` escapes every control character; `MerkleProof` multiproofs allocate later | Neither function is called (`Distributor` uses `verifyCalldata`) | No effect |
| `SafeERC20`, `Address`, `Create2`, `Math`, `Proxy`, `ShortStrings`, `EIP712Upgradeable`, `ECDSA`, `MessageHashUtils`, `EnumerableSet`, `Arrays`, `TimelockController`, `UUPSUpgradeable`, `MulticallUpgradeable`, `ERC20PermitUpgradeable`, `ERC721URIStorageUpgradeable` | Throughout | Rewrites in assembly, added functions, visibility and import paths. Read line by line: the same results for the same inputs. `Initializable` is identical |

Nothing here is a fix this code needs, so the pin to 5.3.0 costs one piece of hardening, the bounded ERC-1271 read. The review covers the files as released; it is no substitute for following the library's advisories from here on, since a fix that lands after 5.6.1 will not reach a pin at 5.3.0 by itself.

## ERC-8473 conformance (planned and built 2026-11-13)

Branch `erc8473-conformance`, cut from `paris` (`3010880`). This section is the plan the brief's rule 3 asks for before a change across files, as the owner approved it; "As built" at its end says what was done and what was not.

### Goal

Every token template is an ERC-8473 token and `ComplianceHook` is an ERC-8473 policy, as the draft stands in its pull request (head `cf6e212`, read on 2026-11-13). Done means: the selectors and ERC-165 ids in the draft's table are the ones `InterfaceFreeze.t.sol` pins, the draft's token, check, installation and policy requirements each have a test that fails without the change, and every gate passes.

### What already conforms

`TRANSFER_OK` is `keccak256('TRANSFER_OK')`; the five kinds and their encoding; the context's field types and order; checks made by `STATICCALL`; the policy address read once per movement; check, then balances, then the transfer event, then the callback; the reentrancy guard on the movement path; every movement refused with no policy; `Frozen` before `Transfer` on a forced move; `afterTransfer` accepted only from the token the context names; `canExecute` building the context as the execution does; no installation from a constructor; `canTransfer` false when both accounts are zero; escrowed shares returned as a `TRANSFER`.

### Gaps and the change for each

| # | Draft requirement | Today | Change |
|---|---|---|---|
| G1 | `checkTransfer`, `wantsAfterTransfer` on the policy; `policy()` and `PolicyChanged` on the token | `beforeTransfer`, `wantsAfter`, `policyHook()`, `PolicyHookChanged` | `IPolicyHook` gives way to `IERC8473Policy`, written here with the draft's ABI. `IPolicyGatedCore` inherits `IERC8473`: `policy()`, `setPolicy(newPolicy, data)`, `PolicyChanged`. The context's `id` and `extra` become `tokenId` and `data`, which moves no selector. `IComplianceRule` keeps `check`, `after_` and `wantsAfter`: it is the hook's own boundary, outside the ERC |
| G2 | Ids `0x9cb56a99` (policy) and `0x0505c8c9` (token); a token refuses a policy that does not answer its id | Other ids; attestation only | Both answer the draft's ids. `_setPolicy` asks `supportsInterface(0x9cb56a99)` beside the attestation and the registry match |
| G3 | The token SHOULD revert with `ERC8473PolicyRejected(reason)` | `PolicyGated_TransferRejected(reason)` | Adopt the draft's error (decision D5). The brief's rule 7 is amended to name it |
| G4 | A movement that takes tokens without the holder directing it is `FORCED`; for `BURN` neither the token's own checks nor the policy may read `operator` | `burn(from, amount)` by `BURNER_ROLE` is labelled `BURN`; the base and three rules exempt it by asking whether `operator` holds the role | `burn` announces `FORCED` with `to` zero, the case section 5 of the brief reserved. `_takesFrozenTokens` becomes `kind == FORCED`. `CredentialRule`, `MinPositionRule` and `HolderRestrictionRule` drop their `hasRole(BURNER_ROLE, operator)` reads: their `FORCED` exemptions already cover it. `canTransfer`'s burner exception goes. Two behaviours change, see D2 |
| G5 | The token calls `onInstall(token, previous, data)` on every installation, after `policy()` returns the new policy; a revert undoes the installation; no movement or installation may begin while it runs | No such call; the initialiser calls `hook.setRules` | `_setPolicy` sets the pointer, emits, then calls `onInstall`, under the reentrancy guard. `ComplianceHook.onInstall` accepts only the token itself. Non-empty `data` is the ordered rule list, installed as `setRules` does today, so the initialiser's separate `setRules` call goes. Empty `data` keeps the list the hook already holds for the token |
| G6 | On every installation a policy sets all state it derives from the token's movements, or reverts; it keeps none from an earlier installation | The fund's investor count is kept across hook replacements on purpose | See D3. The hook's `onInstall` calls a new `onInstall(token, previousPolicy)` on each rule in the list; `BaseRule`'s does nothing. `FundHoldersRule`'s accepts when the class's supply is zero, or when the previous policy listed this same rule for the token, so no movement went unseen; otherwise it reverts |
| G7 | `canSend`, `canReceive` and `canTransfer` never revert: a policy that reverts, runs out of gas, answers fewer than 32 bytes or has no code reads false. At most 32 bytes copied | High-level calls, which revert in each of those cases | One private helper in the core makes the bounded static call and returns the reason, or a rejecting `CHECK_UNAVAILABLE` (appended reason code). The views and the movement path both use it; the movement path reverts on anything but `TRANSFER_OK`, as today |
| G8 | `canSend(address(0))` and `canReceive(address(0))` are true without calling the policy | The hook is asked | `_accountAllowed` returns true for the zero address first, before the pause |
| G9 | In `canTransfer` the operator is `from`, zero for a mint | The caller, for a mint | `_canTransfer` passes `_from` always. After G4 no shipped rule reads the operator of a mint |
| G10 | `wantsAfterTransfer` does not depend on the caller | The shared hook reads the calling token's rule list | See D4 |
| G11 | For every kind but `FORCED`, `checkTransfer` rejects when `checkSend(from)` or `checkReceive(to)` rejects | Fuzzed for a plain transfer only, one way | Not known to be a gap. `RuleSetIntegration.t.sol` gains the same fuzz for `MINT`, `BURN` and `EXECUTED`, over every shipped rule list. Whatever it finds is fixed in the rule, and reported before it is fixed |
| G12 | Recommended reason names: `SENDER_NOT_ELIGIBLE`, `LOCKED_UP`, `WINDOW_CLOSED`, `KIND_NOT_ALLOWED`, `CHECK_UNAVAILABLE` | `SENDER_NOT_VERIFIED`, `LOCKED`, `OUTSIDE_SETTLEMENT_WINDOW`, `TRANSFER_NOT_EXECUTED` | See D6. Optional in the draft |

### Decisions for the owner

- **D1. Reopen the frozen interfaces.** G1, G2, G3 and G5 change `contracts/interfaces/`: `IPolicyHook` (replaced), `IPolicyGatedCore`, `IComplianceHook`, `IComplianceRule` (one function added), `Errors.sol` (one code appended). Every id that includes a changed member moves and `InterfaceFreeze.t.sol` is re-pinned. Rule 4 needs the instruction.
- **D2. Two behaviours change when an enforcement burn becomes `FORCED`.** Today a burner's burn is refused while the token is paused and refused from an address `HolderRestrictionRule` has frozen, where the documented route is `forcedTransfer` to a quarantine account. As `FORCED` it passes both, like `forcedTransfer` does. Option A: accept both, so every enforcement action behaves alike. Option B: keep the frozen-sender refusal by having `HolderRestrictionRule` refuse a `FORCED` movement to zero from a frozen address. I recommend A: one rule for all enforcement, and no reason a regulator's burn should fail where its transfer succeeds.
- **D3. The fund's count across installations.** The draft's policy requirement 16 says a policy must not keep movement-derived state from an earlier installation, and its rationale says a policy may "rebuild or verify" that state. A count of investors cannot be rebuilt on-chain, so G6 verifies continuity and refuses otherwise. That follows the rationale and not the letter of requirement 16. As the draft's author you can make the two agree; I recommend wording requirement 16 to allow state that the policy verifies was observed without a gap.
- **D4. `wantsAfterTransfer()` on a shared policy.** It takes no argument and may not read the caller, so a policy serving many tokens cannot answer for one of them. Option A: amend the draft to `wantsAfterTransfer(address token)`, which moves the policy's id. Option B: `ComplianceHook` answers true always and its `afterTransfer` returns early for a token with no after-rules, at one extra call a movement. I recommend A in the draft, and B here until the draft settles, since B conforms to both texts.
- **D5. The rejection error.** Adopt `ERC8473PolicyRejected` and drop `PolicyGated_TransferRejected`, or keep ours, which the draft allows. I recommend adopting it: 13 test files, 11 TypeScript files and 43 pages name the old one, and they are touched by G1 anyway.
- **D6. Reason names.** Renaming changes the `bytes32` values, which the brief says are never renamed. Nothing is deployed, so this is the cheapest moment. I recommend adopting the draft's five names and keeping every other code as it is.
- **D7. Where this lands.** The branch is cut from `paris`, the build being deployed. If `main` stays the Cancun build, the same commits apply there, apart from the size step below.

### Size comes first

G5 and G7 add code to the shared core, which every template inherits. `Gated4626Vault` has 271 bytes left on the Paris build. Step 1 therefore measures what the core change adds, on a throwaway commit. If the 4626 does not fit, its fee and rate-limit accounting move to a second contract reached by delegatecall, as `Gated7540Settlement` already is, in its own change and before anything else here. The design is not cut to fit.

### Steps

Each step ends with its check; the next does not start until it passes.

1. Measure the core change's bytes on every template. Check: a table of sizes before and after; the 4626 decision above is made on it.
2. Interfaces (after D1): `IERC8473Policy.sol`, `IERC8473.sol`, `IPolicyGatedCore`, `IComplianceHook`, `IComplianceRule`, `Errors.sol`. Check: `InterfaceFreeze.t.sol` fails on the old pins and passes on the draft's selectors and ids, written into the test from the draft's table by hand.
3. Tests, written first and shown failing: one per requirement in the gap table, in `PolicyGatedERC20Upgradeable.t.sol`, `Gated721.t.sol`, `ComplianceHook.t.sol` and `RuleSetIntegration.t.sol`, with `contracts/test/` mocks for a policy that reverts, answers short, has no code and re-enters during `onInstall`. The G11 fuzz is part of this step and its result is reported before step 5.
4. Core, fungible base and `Gated721`: G1 to G5 and G7 to G9. Check: the step 3 token tests pass; the whole Solidity suite passes.
5. `ComplianceHook`, `BaseRule` and the rules: G4's rule side, G5, G6, G10, and what G11 found. Check: the step 3 policy tests pass.
6. `ProxyDeployer` (the init data now carries the rule list through `onInstall`), the Ignition modules, the post-deploy check and `test/nodejs`. Check: `npx hardhat test`, both runners.
7. The brief (sections 4, 5 and 6, rules 7 and 14), `README.md`, `SECURITY.md`, the pages and their Markdown copies. Check: no page names a member that no longer exists (`grep` for the old names returns nothing outside history sections).
8. Gates: format, lint, typecheck, Slither, Aderyn, Halmos, `validate:upgrades`, `verify:reproducible`, the size test.

### Reach, measured on `3010880`

| Name | Contracts | Solidity tests | TypeScript | Docs and brief |
|---|---|---|---|---|
| `IPolicyHook` | 21 | 17 | 0 | 10 |
| `policyHook` | 10 | 11 | 3 | 14 |
| `wantsAfter()` | 8 | 10 | 0 | 23 |
| `beforeTransfer` | 4 | 7 | 0 | 18 |
| `PolicyGated_TransferRejected` | 10 | 13 | 11 | 43 |
| `extra` | 5 | 15 | 0 | 1 |

The counts are files. The read of whether the operator holds the burner role is in 5 contract files.

### Not covered by this plan

- The draft's reference tests are not ported: they are written against its example token. Step 3 writes the stack's own.
- An ERC-1155 template, and so the draft's batch rule.
- An adapter that presents an ERC-3643 compliance contract as a policy.

### As built (2026-11-13)

The owner accepted the seven recommendations on 2026-11-13 ("Yes, start"): D1 the interfaces reopened; D2 option A; D3 verify continuity, with the draft's wording to follow; D4 option B here and A proposed for the draft; D5 the draft's error; D6 the draft's four names; D7 the branch stays on `paris`.

**Size, measured first.** A throwaway version of the core change added about 220 bytes to each fungible template. As built:

| Contract | Before | After | Left |
|---|---|---|---|
| `Gated4626Vault` | 24,305 | 24,556 | 20 |
| `Gated7540Vault` | 22,832 | 23,126 | 1,450 |
| `IntentToken` | 18,915 | 19,120 | 5,456 |
| `Gated721` | 16,055 | 16,220 | 8,356 |
| `GatedToken` | 15,692 | 15,980 | 8,596 |
| `ComplianceHook` | 4,173 | 4,832 | 19,744 |

The 4626 fits, by 20 bytes, so the second contract was not built here. It has no room for a fix: moving its fee and rate-limit accounting to a second contract, as the 7540 has, is the next change this branch needs before anything else touches the vault.

**What each gap became.**

- **G1, G2, G3.** `contracts/interfaces/IERC8473.sol` and `IERC8473Policy.sol`, written here with the draft's ABI; `IPolicyHook.sol` is gone. `IPolicyGatedCore` inherits `IERC8473`. The setter is `installPolicy(newPolicy, data)`, not `setPolicy`, because `CredentialRule` already has a `setPolicy` for its own credential policy and the draft calls the act an installation. New error `PolicyGated_NotAPolicy(target)` for a contract that does not answer `0x9cb56a99`. `InterfaceFreeze.t.sol` pins the seven selectors and two ids copied by hand from the draft's table, and the compiled interfaces match them.
- **G4.** `burn` announces `FORCED` with a zero receiver on the fungible base and on `Gated721`. The base's frozen bound is `kind == FORCED`. `CredentialRule`, `MinPositionRule` and `HolderRestrictionRule` lost their `BURNER_ROLE` reads and the constant. `CredentialRule` judges a receiver whenever `to` is not zero. This also closes a weakness `SECURITY.md` listed: a burner that redeemed its own vault shares passed its own lockup and minimum.
- **G5.** `_installPolicy` in the core, private and under the reentrancy guard: attestation, registry match, interface id, set, `PolicyChanged`, `onInstall`. The initialiser passes `abi.encode(rules)` as the data, or nothing. `ComplianceHook.onInstall` accepts only the token, installs a list from non-empty data, and calls each rule's `onInstall`.
- **G6.** `IComplianceRule.onInstall(token, previousPolicy)`; `BaseRule`'s is empty. `FundHoldersRule`'s is a view: it returns when the class's `totalSupply()` is zero or the previous policy's `rules(token)` holds this rule, and otherwise reverts with the new `FundHoldersRule_CountNotCurrent(token)`. It writes nothing, so it has no caller check.
- **G7.** `_ask(policy, call)` in the core: one static call, one word copied to the scratch space, `CHECK_UNAVAILABLE` on any failure. Both the views and `_move` go through it, so a movement whose policy cannot be asked reverts with `ERC8473PolicyRejected(CHECK_UNAVAILABLE)` and the policy's own revert data is no longer bubbled. `wantsAfterTransfer` and `afterTransfer` stay high-level calls, which revert as the draft's token rule 4 asks.
- **G8, G9.** As planned.
- **G10.** `ComplianceHook.wantsAfterTransfer()` is `pure` and true. A token's after mask is no longer visible through it, so the hook's tests observe the mask through `afterTransfer`.
- **G11.** No gap. `RuleSetIntegration_PolicyRequirement4` fuzzes TRANSFER, EXECUTED, MINT and BURN over senders, receivers, freezes, lockups and operators against the hook, and `CredentialRule.t.sol` already pinned `check` as the two account answers in order; both pass. Not covered by a fuzz: a list with `FundHoldersRule`, whose account answers are the class check that `check` returns first, read by hand.
- **G12.** `SENDER_NOT_ELIGIBLE`, `LOCKED_UP`, `WINDOW_CLOSED`, `KIND_NOT_ALLOWED`, and `CHECK_UNAVAILABLE` appended. `RECEIVER_NOT_VERIFIED` keeps its name beside `RECEIVER_NOT_ELIGIBLE`: they are two different reasons here, and the draft's list has one.

**Install order, fixed after the build (2026-11-13).** Writing the pages turned up a gap in G6: `ComplianceHook.onInstall` stored a new list before telling the rules, so a class with a supply that installed the hook it already had, with data adding the fund rule, passed the rule's check, because the previous policy was that same hook and already answered with the new list. `onInstall` now tells every rule first, attesting each rule from the data before calling it, and stores the list after. `test_WhenTheSameHookIsInstalledWithANewList_TheRulesAreToldBeforeTheListIsStored` failed before the change (the rule saw 2 rules, not 1). A list set through `setRules` still calls no rule's `onInstall`: dropping the fund rule and adding it back that way leaves the count behind, which `Fund.isClassIntact` and `firstBrokenClass` are there to show.

**Tests first.** The 16 token tests in `PolicyGatedUnit_Erc8473` were run against the renamed, unchanged code: 15 failed and the interface-id one passed. The 9 hook tests in `ComplianceHookUnit_OnInstall`: 7 failed against the stub. Then the change, then 25 older tests that described the old behaviour were rewritten to the new one, each named for what it now says.

**Not done.**

- **The pages**: done later the same day, see "The pages" below.
- **The 4626's second contract**, above.
- **The draft itself.** D3 and D4 ask for two changes to the draft's text, in its own repository.
- **An upgrade from a deployed token.** A token deployed before this change has its hook installed without `onInstall` having run; nothing is deployed, so no migration is written.

**Verified.** `npx hardhat test`: 2022 passing (1824 solidity, 198 nodejs). Format, lint and typecheck clean. Slither 0 results, Aderyn 0 findings, Halmos 22 of 22 checks, `validate:upgrades` 6 of 6, `verify:reproducible` 31 contracts identical. The size test passes with the 4626 at 24,556 bytes.

## The 4626's second contract (2026-11-13)

On branch `erc8473-conformance`, after the conformance change left `Gated4626Vault` 20 bytes under the limit. The owner asked for the split on 2026-11-13.

**Design, as the 7540 has it.** Nothing an investor calls moves, and no behaviour changes.

- `Gated4626Common` (abstract; `ERC4626Upgradeable` + `GatedVaultBase`): the storage struct and its ERC-7201 accessor, the constants, and the accounting both contracts need (`_accrue`, `_counting`, `_dealingStopped`, `_fellTooFar` and the two portfolio reads), with the overrides the inheritance needs.
- `Gated4626Management` (is `Gated4626Common`): `setPortfolio`, `setMaxRate`, `setFeeModel` and `collectFees`, with the helpers only they use. These are the timelock's, the guardian's or an occasional caller's, so the cost of a hand-off falls on few calls.
- `Gated4626Vault` keeps the four names and hands each to `MANAGEMENT_LOGIC` by delegatecall, unchanged, passing back a revert as it came. Its constructor creates the second contract, so the attested codehash pins the address, each implementation has its own, and it has no role, storage or admin function of its own. Reached directly it does nothing.

**Interface.** `IGated4626Vault` gains `MANAGEMENT_LOGIC()`, as `IGated7540Vault` has `SETTLEMENT_LOGIC()`; its id is re-pinned. No other interface changes.

**Steps.** Tests first in `Gated4626Management.t.sol` (wiring, direct calls, hand-off, upgrade), shown failing. Then the three contracts. Then `ContractSizes.t.sol`, `scripts/verify-reproducible.ts` (the vault embeds the second contract's creation code), the post-deploy check in `test/nodejs/fixtures.ts`, the brief, `README.md`, `SECURITY.md`. Then every gate.

**Done means** every existing vault test passes untouched, and the vault has real room.

**As built.** As designed, in `contracts/vaults/Gated4626Common.sol`, `Gated4626Management.sol` and the slimmed `Gated4626Vault.sol`. The code moved without being rewritten: the functions' bodies are the ones the vault had, with events and errors named through `IGated4626Vault`.

| Contract | Deployed size | Left under 24,576 | Creation code |
|---|---|---|---|
| `Gated4626Vault`, before | 24,556 | 20 | 24,809 |
| `Gated4626Vault`, after | 22,836 | 1,740 | 43,987 |
| `Gated4626Management` | 20,754 | 3,822 | 20,815 |

- The vault's creation code now carries the second contract's, as the 7540's does. An EVM at Paris has no limit on it; `ContractSizes.t.sol` still holds both vaults under the 49,152 bytes a later EVM allows, so the same code deploys there.
- The room gained is 1,720 bytes, not more: the four functions were small, and the counting stays in both contracts because deposits and withdrawals need it. More room would mean moving `_deposit` and `_withdraw` paths, which investors call, and that was not done.
- `_MAX_RATE_BPS` lives in the second contract, its only user (Slither's one finding on the first cut).
- Tests first: `Gated4626Management.t.sol` did not compile before the contract existed, since the vault had no `MANAGEMENT_LOGIC`. It has 18 tests: wiring, direct calls on the second contract, the hand-off through the vault, and upgrades. The 141 tests in the two existing vault test files pass untouched.
- `IGated4626Vault` id `0x7c5d7975` became `0xecc03c50`. `ContractSizes.t.sol`, `scripts/verify-reproducible.ts` and the post-deploy check in `test/nodejs/fixtures.ts` now cover the second contract as they cover the 7540's.
- The pages: done later the same day, see "The pages" below.

**Verified.** `npx hardhat test`: 2040 passing (1842 solidity, 198 nodejs). Format, lint and typecheck clean. Slither 0 results, Aderyn 0 findings, Halmos 22 of 22 checks, `validate:upgrades` 7 of 7, `verify:reproducible` 32 contracts identical, with `Gated4626Management` matching the creation code `Gated4626Vault` embeds.

## The pages, for ERC-8473 and the 4626's second contract (2026-11-13)

Asked for by the owner on 2026-11-13, on branch `erc8473-conformance`.

**What was done.** 44 pages, two of them new (`Gated4626Management`, `Gated4626Common`), each with its Markdown copy in `docs/md`. A script applied the renames to 26 pages. Five writers then rewrote the behaviour, each on its own pages and from one brief of facts taken from the code: the movement page; the overview and the three other topic pages; the base, token, deploy and governance pages; the hook and rule pages; the vault pages and the two new ones. Four separate checkers, who had not written the pages, checked every changed passage against the code and read each page through: 15 corrections, 30 pages clean. Seven diagrams had text changed and one arrow moved; none lost a box, and the edited ones were looked at in a browser. The footers pin `6ef0d4e` on `erc8473-conformance`, the last commit that changed the contracts. `md_check`: 44 pages, 0 problems.

**What the pages found in the code.**

- The install order in `ComplianceHook.onInstall`, fixed (see "Install order" above).
- Comments that still described the burner-role reads, the context's old field names and the initialiser calling `setRules`, in six contracts and interfaces, and a test whose name said the opposite of what it checks. Corrected.
- My own comment on `Gated4626Management.setFeeModel` said the model could be removed. It cannot: the vault requires an attested model. Corrected.

**An outside review, pasted by the owner while the pages were being written.** Its page findings were all of pages not yet rewritten at the moment it looked; each cited statement was searched for afterwards and none remains. Its other points:

- Same-hook reinstall passing the fund rule's check: fixed, above.
- `SECURITY.md` section 4 behind the code: true. The Slither table lacked `reentrancy-events` on `ProxyDeployer.deploy` and `GuardedAccount.execute`, and the Aderyn table lacked the delegatecall-target finding on both vaults and the 4626's hand-off. Every inline suppression in the contracts that ship was compared with the tables by script; they agree now.
- Stale `id` and `extra` in `Gated721.sol` and its test: corrected.
- **`setRules` calls no rule's `onInstall`: left as it is (owner decision, 2026-11-13).** A list set through `setRules` can drop the fund rule and take it back, or add it to a class that already has holders, and the count then lacks the movements in between. Telling the rules from `setRules` too would refuse that, by the same reasoning as an installation. It was not done, because it changes behaviour the tests pin and it closes a door: today a class whose list dropped the rule by mistake gets it back with one `setRules`, and with the check it could not, until the class is empty. It would also need the rule to accept a successor of the same fund, since replacing a fund's rule goes through `setRules` on classes that have holders (`FundIntegration.t.sol`). The pages and `SECURITY.md` state the gap as a limit, and `Fund.isClassIntact` and `firstBrokenClass` show a class whose list lacks the rule. The owner chose to keep it a documented limit: a mistaken drop stays recoverable with one call, and the monitor is the control.

**Not covered.** The worked numbers on `money.html` and `FeeModel.html` were not recomputed, and statements about the Ignition modules and the TypeScript checks were spot-checked, not re-derived. The footers name a commit of this branch: when the branch lands on `main` by squash, the commit changes and the footers need the new one.

## The Aderyn gate is removed (owner decision, 2026-11-14)

Aderyn was retired upstream on 2026-11-13: its README says it is no longer maintained and has no supported install
path, and the binaries were deleted from every release, 0.6.8 included. `scripts/fetch-tool.sh aderyn` then answered
404, and the CI analysis job stopped there, before Halmos, the upgrade check and the reproducible build. The owner
chose to drop the gate rather than build the tool from its source in CI.

**Removed.** The two Aderyn steps in `ci.yml` and the job's name; the `aderyn` script in `package.json` and
`scripts/aderyn-gate.ts`; the two rows in `tools.lock` and the install rule in `scripts/fetch-tool.sh`; the
`.gitignore` line for its report; the commands, the supply-chain row and the mutation row in `SECURITY.md`, and the
commands in `README.md`.

**Kept.** The inline `aderyn-ignore` comments in the contracts and `aderyn.toml`, as the record of what was accepted
while the gate ran, with the tables in `SECURITY.md` section 4. No contract changes, so no bytecode, codehash or page
pin moves. Nothing checks those comments any longer.

**State.** Aderyn's last run, on `259d82b` with a binary installed before the retirement, had 0 findings. Slither is
the static-analysis gate.

## The multi-token template, `Gated1155` (planned and built on `main` 2026-11-19, ported to this line the same day; the pages are not done)

Source: the owner, 2026-11-19: "lets plan to build a Gated1155 I saw 7943 has a IERC7943MultiToken". Derived from the code at `38fdbc1` on `main`, ERC-7943's Final text, the ERC-8473 draft's movement rules and OpenZeppelin 5.6.1's `ERC1155Upgradeable`. The six decisions the first version of this plan left open are settled below, from the two standards.

### What the standards ask

- **ERC-7943, multi-token.** `IERC7943MultiToken` has six functions: `forcedTransfer(from, to, tokenId, amount)`, `setFrozenTokens(account, tokenId, amount)`, `getFrozenTokens(account, tokenId)`, `canSend(account)`, `canReceive(account)` and `canTransfer(from, to, tokenId, amount)`. Its id is `0x41c4fbad`, which the XOR of those six selectors confirms. Events `ForcedTransfer(from, to, tokenId, amount)` and `Frozen(account, tokenId, amount)`; error `ERC7943InsufficientUnfrozenBalance(account, tokenId, amount, unfrozen)`. The rules are the fungible ones for each token id: a frozen amount may exceed the balance, `canTransfer` validates the unfrozen amount and must not return false for a balance, and an enforcement action that takes frozen tokens lowers the frozen amount and emits `Frozen` before the transfer event. The base standard may be ERC-1155 or ERC-6909, and the text says nothing about batches or receiver callbacks. The plan was written from a summary of the page, so step 1 copies the interface from the Final text and pins the id.
- **ERC-8473, batches (movement rule 10).** The items of a batch are processed in the order given, and for each item the token checks, changes balances, emits that item's transfer event and notifies the policy, all before the next item is checked. An ERC-1155 token therefore emits one `TransferSingle` for each item. One rejected item reverts the whole batch. Rule 7: `afterTransfer` completes before any call to the recipient.

### What it reuses unchanged

- **`PolicyGatedCoreUpgradeable`**: roles, guardian, pause and the recovery path, the policy pointer and `installPolicy`, the registry, the upgrade checks, the account-level answers, `_inferKind` and `_ask`. This is what the core was split out for.
- **`ComplianceHook`**, **`PolicyRegistry`**, both timelocks, **`CredentialRegistry`**: they never read an amount or a token id.
- **`TransferContext`**: `tokenId` is the id and `amount` the amount, with `data = abi.encode(fromBalance, toBalance)` for that id before the move. Brief §5 already names this use.
- **`ProxyDeployer`**: it asks the new proxy for `registry()`, `policy()` and `symbol()`. ERC-1155 has no `symbol()`, so the template adds `name()` and `symbol()`, set at initialisation, as most ERC-1155 collections do.

### The rules on a multi-token

No shipped rule reads `ctx.tokenId`, and every rule keys its configuration and state by `ctx.token` alone. So on a `Gated1155` one rule list and one configuration judge every id alike.

| Rule | On a `Gated1155` |
|---|---|
| `CredentialRule` | Works. Who may hold is decided for the contract, the same for every id |
| `HolderRestrictionRule` | Works. A lockup or an address freeze covers a holder's every id |
| `MinPositionRule` | Works for each id, since it reads the balances in `data`, but with one minimum for every id. Allowed, and a product whose ids have different units leaves it out |
| `SupplyCapRule` | Refused by the profile check. It calls `totalSupply()`, which here is the sum over every id |
| `FundHoldersRule` | Refused. `Fund.registerClass` asks ERC-165 for `IPolicyGated`, and the fund counts one balance for each class |
| `SettlementWindowRule`, `ExecutedOnlyRule` | Refused, as on every template without intents |

### The token

`contracts/tokens/Gated1155.sol`, one concrete contract on OpenZeppelin's `ERC1155Upgradeable` and the core, with the guard `ReentrancyGuardTransient` on this line. No permit (ERC-1155 has none), no intents, no DvP, no vault over it.

| Function | Who | Note |
|---|---|---|
| `mint(to, tokenId, amount)` | `MINTER_ROLE` | A `MINT` through the hook, then the receiver callback when `to` is a contract (D4) |
| `burn(from, tokenId, amount)` | `BURNER_ROLE` | Enforcement, announced as `FORCED`: no approval, may take frozen tokens, not stopped by the pause. No holder burn, as on the other tokens |
| `forcedTransfer(from, to, tokenId, amount)` | `AGENT_ROLE` | Takes frozen tokens as needed and never more than the balance; `Frozen` before `TransferSingle`; then the standard's `ForcedTransfer` and our `ForcedTransferBy`, which here carries the id too and so has its own topic |
| `setFrozenTokens(account, tokenId, amount)` | `AGENT_ROLE` | An absolute frozen amount for each account and id; may exceed the balance |
| `setURI(tokenId, uri)` | `AGENT_ROLE` | Metadata for one id; emits ERC-1155's `URI` |
| `safeTransferFrom`, `safeBatchTransferFrom`, `setApprovalForAll` | holders and their operators | ERC-1155's own |
| `canTransfer`, `canTransferWithReason`, `canSend`, `canReceive`, `getFrozenTokens` | anyone | As on the ERC-20 base, for one id |
| pause, `installPolicy`, roles, upgrades, `multicall` | as on every template | From the core |

No issuer batch functions: a role holder batches `mint`, `burn` or `forcedTransfer` with `multicall`, as on the other templates.

**The movement path.** OpenZeppelin's `_update(from, to, ids, values)` applies a whole batch and then emits one `TransferBatch`, and its balances are private to it. The override loops over the items, and for each one calls a single `_move`, which is guarded against reentrancy:

1. ERC-1155's own checks come first: approval in `safeTransferFrom` before `_update` is reached, and equal array lengths.
2. Paused rejects every kind except `FORCED`.
3. The amount must fit the unfrozen balance of that id, for every kind except `FORCED`. Within the balance but above the unfrozen part reverts with `ERC7943InsufficientUnfrozenBalance(account, tokenId, amount, unfrozen)`; above the balance reverts with ERC-1155's `ERC1155InsufficientBalance`.
4. The hook, with the context above. A rejection is `ERC8473PolicyRejected(reason)`, and a policy that cannot be asked is `CHECK_UNAVAILABLE`.
5. The move, by calling the parent's `_update` with that one item, which emits its `TransferSingle`.
6. `afterTransfer`, if the hook wants it.

An id that appears twice in a batch is two movements, each seeing the balances the earlier one left. An empty batch makes no movement and asks nobody. The receiver callback runs once after the last item, outside the guard, with the state final: `onERC1155Received` for one item and `onERC1155BatchReceived` for a batch, as OpenZeppelin calls them (D4).

**Pre-flights.** `canTransferWithReason(from, to, tokenId, amount)` runs the write's path for one item minus the write, with the operator simulated as `from` and zero for a mint. `canTransfer` is the standard's bool with the fungible exception: an amount above the balance reads true when nothing is frozen on that id. No pre-flight takes a batch; an integrator asks about each item, and for a batch that names an id twice the later answers depend on the earlier moves.

### Decisions, settled from the standards (2026-11-19)

The owner, 2026-11-19: "read the ERC8473 and try to comply, find the best answers to keep the code following the same idea, and comply with finance laws". The draft was read in full at `667f261` of its repository, and ERC-1155's rules from a summary of its page, which step 1 checks against the text. The answers:

- **D1. One policy for the contract.** Neither standard leaves room for anything else at account level: ERC-7943's `canSend(account)` and `canReceive(account)` and the draft's `checkSend(token, account)` and `checkReceive(token, account)` take no token id, so who may hold cannot differ by id and still be told to an integrator. Every shipped rule already keys by the token alone, so the hook and the rules stay as they are. An id is a series of one instrument under the same eligibility terms. Instruments with different investors, selling restrictions or holder limits are separate contracts.
- **D2. Supply and a URI for each id.** `ERC1155SupplyUpgradeable` and `ERC1155URIStorageUpgradeable`. Step 5 of the agreed order reconciles on-chain supply and positions with the issuer's ledger every day, and that needs the issued amount of each series readable on-chain, not rebuilt from events. Supply is updated inside the same item's move, so it is current when `afterTransfer` runs (token rule 14).
- **D3. Batches item by item.** The draft's token rule 10 requires it, and ERC-1155 allows several `TransferSingle` events for one batch and requires the array order. Not a choice.
- **D4. Receiver callbacks on every path into a contract.** ERC-1155 calls a mint a specialised transfer that must follow the receiver rules, and says a non-standard transfer function must still call the hook on a receiver that implements it. So `mint` and `forcedTransfer` make the callback, as OpenZeppelin's `_mint` and `_safeTransferFrom` do, and a contract without the receiver interface is refused. The draft's rule 7 is met because the callback comes after `afterTransfer`, outside the guard. A batch makes one `onERC1155BatchReceived` after its last item, which ERC-1155 recommends for a batch. A burn makes none. Not a choice either.
- **D5. `main` first, then `paris`.** The port follows in the same work, before the pages, in its own pull request into `paris`. Only the guard and its initialiser differ.
- **D6. Two new interface files**, `IERC7943MultiToken.sol` and `IGated1155.sol`. No existing interface or id changes and no new reason code. The owner's message above is read as the rule 4 instruction for these two files; the review of this plan is where to say otherwise.

### Conformance to ERC-8473, point by point

| The draft | `Gated1155` |
|---|---|
| Kinds, in order | `forcedTransfer` and the burner's `burn` are `FORCED`; `mint` is `MINT`; ERC-1155's two transfer functions are `TRANSFER` and can be nothing else. No `BURN` and no `EXECUTED` path exists: the template has no holder burn and no intents |
| Context | `tokenId` and `amount` are the item's; `operator` is the caller; `data` is that id's two balances before the move, in the encoding the other templates use, so a shared rule reads the same words. The `data` argument of ERC-1155's transfer functions never reaches the policy: it goes to the receiver callback alone |
| Token rules 1 and 2 | Nothing changes before the check except earlier items of the same batch, and nothing but the policy is called between the check and the move. The enforcement paths lower the frozen amount first, which the draft allows for `FORCED` |
| Rules 4, 5 and 11 | From the core: one policy address for each movement, `CHECK_UNAVAILABLE` for a policy that cannot be asked, and no policy means no movement |
| Rules 6 and 7 | `afterTransfer` after each item's `TransferSingle`, before the next item and before any receiver callback |
| Rules 8 and 9 | The checks are static calls, and each item's `_move` holds the guard |
| Rule 10 | The batch path above |
| Rule 12 | The token's own checks are the pause and the frozen amount of that id, and neither reads the caller |
| Rule 13 | An enforcement action lowers the frozen amount by exactly the frozen part it takes and emits `Frozen` before `TransferSingle`. The policy still judges the receiver |
| Rule 14 | `balanceOf`, `totalSupply(id)` and `getFrozenTokens` do not revert in the middle of a batch |
| Check rules 1 to 5 | `canSend` and `canReceive` from the core. `canTransfer` simulates a `TRANSFER`, a `MINT` or a `BURN` with `from` as the operator, is false when both addresses are zero, validates the unfrozen amount when something is frozen and does not fail for a balance. A `BURN` asked about is answered as a holder's would be, although no function here makes one, as on `Gated721` |
| Installation rules | From the core, unchanged |
| ERC-165 | `0x0505c8c9`, `0x41c4fbad`, ERC-1155 and its metadata extension |

A zero amount and a transfer to oneself are movements, and the policy is asked about each. Nothing here needs a change to the draft.

### What the law needs from this template

A codebase is not compliant on its own (step 4 of the agreed order says so): a regulator judges the terms, the operators, the chain and the code together, and the points below are for counsel to confirm for each product. This is what the code gives them, and where it stops.

- **Who may hold.** Every movement, issuance and enforcement included, asks `CredentialRule` about the receiver, for every id. No path delivers to an account that is not eligible.
- **One contract, one set of terms.** Eligibility, lock-up and freezes are the contract's, not an id's. A product whose series differ in who may buy them, in where they may be sold or in their holding period uses one contract for each set of terms. The profile check cannot see this, so it is a rule for whoever designs the product.
- **Holder limits.** No shipped rule caps the holders of an id or of the contract: `FundHoldersRule` counts across a fund's separate tokens and is refused here. An instrument with a legal limit on its number of holders must not be issued on `Gated1155` until a cap rule for it exists.
- **Lock-ups.** `HolderRestrictionRule` locks a holder for every id at once. That is never looser than a lock-up on one series and can be stricter. A product with a holding period for each series uses one contract for each, or waits for a rule that reads the id.
- **Freezes and orders.** An agent freezes an amount of one id for one holder, freezes an address for every id through the rule, forces a transfer of one id and burns one id, each with an event that names the account and, for a forced transfer, the agent. A sanctioned address can neither send nor receive any id.
- **The register.** One event for each movement, in order, and the issued amount of each id on-chain, so the register and the daily reconciliation rebuild from the chain without interpreting batches. Whether the chain is the register or a copy of it is step 5's question, as for every template.
- **Operator approvals.** `setApprovalForAll` lets a holder name an operator for all its ids. The operator's transfers are judged on the sender and the receiver like any other, and the policy must not judge the operator on a `TRANSFER` (policy requirement 6). The token does not restrict approvals: that would be a decision about who inside the template (rule 11). Under issuer custody (P24) the approvals are the custodian's to give.
- **Personal data.** The URI of an id is public. It describes the series and must hold nothing about a holder.
- **Payment data.** Originator and beneficiary details stay off-chain, as on the other templates: the draft forbids caller data in the context of a `TRANSFER`.

### Deployment

`Gated1155` joins `Template` and `IMPLEMENTATION_KEY` (`multiImpl`) in `ignition/profiles.ts`; `Core` deploys its implementation when a profile lists one; `Product` grants its minter and burner as it does a token's. Its `initialize(name, symbol, admin, guardian, registry, hook, rules)` takes the arguments `Gated721`'s takes. New profile `multi`: one `Gated1155` with `credentialRule` and `holderRestrictionRule`. The profile check refuses the four rules in the table. `assertHandedOver` and the post-deploy check cover it as they cover a token.

### Tests, written first

- `contracts/tokens/Gated1155.t.sol`, with a mocked hook: every role gate; mint, burn and transfer reach the hook with the zero addresses, the id, the amount and that id's balances in `data`; a rejection changes nothing; frozen amounts for each id (above the balance, a holder moves exactly the unfrozen part, enforcement lowers the frozen amount by exactly the frozen part taken, `Frozen` before `TransferSingle`); a freeze on one id leaves another id free; pause and the recovery path; `installPolicy` and upgrades refuse an unattested target and another template; pre-flight parity with the write, fuzzed with `bound`; ERC-165 ids from solc against `0x41c4fbad` and ERC-1155's.
- Batches: the hook is asked once for each item in order, each with the balances the earlier items left; one `TransferSingle` for each item and no `TransferBatch`; a rejected third item reverts the first two; an id named twice; an empty batch; unequal arrays.
- Callbacks: `mint`, `forcedTransfer` and both transfer functions call the receiver hook on a contract, after `afterTransfer`; a contract without the receiver interface is refused on each; a batch makes one batch callback; a burn makes none.
- Reentrancy: a receiver that calls back from `onERC1155Received` and from `onERC1155BatchReceived`, and a rule that calls back during `afterTransfer` in the middle of a batch.
- Invariants: for each id, the sum of balances equals `totalSupply(id)`, and a holder moves at most the unfrozen balance.
- Integration: the real hook with `CredentialRule` and `HolderRestrictionRule`, deployed through `ProxyDeployer`, every refusal comparing the pre-flight with the write. Whether the fuzz of `canTransfer` against `canSend` and `canReceive` in `RuleSetIntegration.t.sol` extends to this template is decided there.
- `test/nodejs/products.test.ts`: the `multi` profile deploys and passes the hand-over check, and the profile check throws on the refused rules.
- `InterfaceFreeze.t.sol`, `ContractSizes.t.sol`, `scripts/verify-reproducible.ts`'s list, `validate:upgrades`. Halmos: the frozen-amount path for one id, if the existing harness extends to it without a new model.

Planted bugs, each to be caught by a test: the unfrozen check skipped for the second item of a batch; `afterTransfer` called once after a batch and not after each item; `Frozen` emitted after `TransferSingle`; `canTransfer` returning false for a balance.

### Steps

1. Interfaces and the brief: `IERC7943MultiToken` copied from the Final text, `IGated1155`, their ids pinned, and CLAUDE.md §3, §4 and §5 naming the template. ERC-1155's rules on minting to a contract, on non-standard transfer functions and on a batch callback after single events are read in the text, and D4 is reopened if they differ from the summary. Verify: the freeze test fails before the pins and passes after.
2. Tests first, against a stub that skips every check, with the failing run shown.
3. `Gated1155`. Verify: `npx hardhat test`, both runners; the planted bugs; the size.
4. Deployment: the profile, `Core`, `Product`, the fixtures and the lists. Verify: the `multi` profile passes the hand-over check.
5. Gates: format, lint, typecheck, Slither, Halmos, `validate:upgrades`, `verify:reproducible`.
6. The port to `paris`, in its own pull request into `paris`, never merged into `main`.
7. The pages (`Gated1155`, the interface, and the pages that list the templates) with their Markdown copies, on each line, pinned to that line's merged commit.

### Not in this work

- Rules that read the id: a lock-up, a supply cap or a holder cap for each id. They can only add to `checkTransfer`; the account-level answers stay the contract's.
- A reference to a legal order in the `data` of a `FORCED` movement, which the draft allows. No template passes one today.
- Intents, DvP and vaults over a multi-token. `DvPExecutor` settles ERC-20 legs only.
- ERC-6909 as the base. ERC-7943 allows it, and it is the lighter standard, with no callbacks and no batches; the owner asked for ERC-1155.
- A fund whose classes are ids of one contract. `Fund` counts investors across separate tokens, and a class as an id would need the fund layer rewritten.

### As built on `main` (2026-11-19)

The owner approved the plan on 2026-11-19 ("Yes, start"). Steps 1 to 5 are done on this line; steps 6 and 7 are not.

- **Step 1, the texts.** ERC-7943 and ERC-1155 were read in their own text. Two details differed from the summary the plan was written from, and the interface follows the text: `tokenId` is indexed in `ForcedTransfer` and in `Frozen`, and `ERC7943CannotTransfer` carries the amount. D4 stands: ERC-1155 says a mint is a specialised transfer that follows the receiver rules, and that a non-standard transfer function follows them too when the receiver implements the interface and SHOULD revert when it does not, which is what `mint` and `forcedTransfer` do. A batch may emit several `TransferSingle`, and the batch callback is the one the text recommends for a batch.
- **Interfaces.** `IERC7943MultiToken` (`0x41c4fbad`, which solc computes from the file) and `IGated1155` (`0xc12446d8`: mint, burn, setURI, name, symbol, canTransferWithReason). Three new topics pinned. No existing id or topic moved. The freeze test failed on the unpinned values and passes with them.
- **The token.** `contracts/tokens/Gated1155.sol`, 17,384 bytes as first built (the 15,700 first written here was wrong). As planned, with nothing added: `ERC1155SupplyUpgradeable`, `ERC1155URIStorageUpgradeable` and the core; `_update` loops the items through one guarded `_move`.
- **Tests.** `Gated1155.t.sol`, 95 tests: 85 unit with a mocked or a recording policy, 2 invariants and 8 through the real hook, `CredentialRule` and `HolderRestrictionRule`, deployed by `ProxyDeployer`. Against a stub with no checks 56 of the first 94 failed. The fuzz of `canTransfer` against `canSend` and `canReceive` is in this file, for this template, and `RuleSetIntegration.t.sol` is unchanged.
- **Planted bugs.** The items of a batch after the first moved without any check; `afterTransfer` for the last item of a batch only; the frozen amount lowered after the transfer event; `canTransfer` counting the balance: 7, 4, 3 and 3 tests fail.
- **Deployment.** Template `Gated1155`, part `multiImpl`, profile `multi`. The profile check refuses `fundHoldersRule` and `supplyCapRule` on it, and `windowRule` and `executedOnlyRule` as on every template without intents; `minPositionRule` is allowed. `products.test.ts` deploys the profile, moves a batch and checks the refusals, and the test that deploys every profile covers its hand-over check.
- **Not done.** Halmos has no property for this template: the existing harness models the proxied `IntentToken`, and a frozen-amount property here needs a model of its own. The port to `paris` (step 6) and the pages with their Markdown copies (step 7) follow.

### The port to `paris` (2026-11-19)

The plan and the template were written on `main` and are carried here by cherry-pick; where the text above says "this line" it means `main`. On this line:

- **The contract** is the same file, byte for byte in source. It names no guard: `nonReentrant` comes from the core, which here is `ReentrancyGuardUpgradeable`, initialised by the core's own initialiser. OpenZeppelin 5.3.0 has the same `ERC1155SupplyUpgradeable`, `ERC1155URIStorageUpgradeable` and `ERC1155Utils`, and none of them, nor its `ERC1155Upgradeable`, uses `MCOPY` or transient storage. Its `ERC1155Upgradeable` is not the same as 5.6.1's: it chooses the receiver callback by the length of the batch (see the review below), which the token's own `safeBatchTransferFrom` now decides. It is 17,861 bytes here.
- **The test** expects `ReentrancyGuard.ReentrancyGuardReentrantCall` where `main` expects the transient guard's error. Nothing else differs.
- **The brief** keeps this line's Phase 7 text, with the `multi` profile named in it.
- **Not done.** The pages, on each line, once each line's change is merged.

### Review of 2026-11-19

The owner passed on a review of both pull requests the day they were opened. Each finding was checked against the code before anything changed.

- **An empty batch reached the receiver. Confirmed, fixed.** `safeBatchTransferFrom` with no items ran no loop, so no pause and no policy were consulted, and OpenZeppelin then made the batch callback on the receiver, with the caller's data. Anyone, also while the token was paused, could make the token call a contract of their choice. The token now overrides `safeBatchTransferFrom`: OpenZeppelin's approval and zero-address checks, `_update`, and the batch callback only when the batch has at least one item. An empty batch still succeeds and still changes nothing; it now calls nobody. Two tests failed before the fix, on both lines: an empty batch from a stranger to a receiver contract, and the same while paused.
- **A batch of one item got the single callback on `paris`. Confirmed, fixed by the same override.** OpenZeppelin 5.3.0 chooses the callback by the length of the batch, so a batch of one called `onERC1155Received`; 5.6.1 calls `onERC1155BatchReceived`, which is what ERC-1155 asks of `safeBatchTransferFrom`. The override names the batch callback itself, so the two lines behave alike and the source stays the same file. One test failed before the fix on `paris` and passed on `main`.
- **D4 stands.** `mint` and `forcedTransfer` make the receiver callback, unlike `Gated721`, whose mint and forced transfer make none: ERC-1155 has no transfer without it. What follows for operations: a contract that is to receive this token by any path, a custody wallet or a recovery account included, must implement `IERC1155Receiver`, or the movement reverts.
- **`SupplyCapRule` is refused by the profile check only.** `FundHoldersRule` is refused on-chain as well, because `Fund.registerClass` asks for `IPolicyGated`. Nothing on-chain refuses `SupplyCapRule`: the hook accepts any attested list, and `ERC1155SupplyUpgradeable` answers `totalSupply()` with the sum of every id, so a timelock `setRules` that listed the rule would cap that sum and not any one id. Not changed: the rule is not this template's, and a cap for each id is a new rule (see "Not in this work").
- **Comments.** The core's NatSpec now names this template. `IERC8473Policy`'s comment on `tokenId` still names only the ERC-721: the file is frozen (rule 4) and waits for the owner's word.
- **Sizes.** After the fix the token is 17,461 bytes on `main` and 17,861 on `paris`.
- **Tests.** `Gated1155.t.sol` has 98 tests on both lines.
## `setRules` tells the rules it adds (planned and built on `main` 2026-11-19; the port to `paris` and the pages are not done)

Source: an outside assessment the owner passed on 2026-11-19, which named this gap again, and the owner's "Yes, both" to planning it. Derived from the code at `38fdbc1`. It reopens the owner decision of 2026-11-13 recorded under "ERC-8473 conformance": "`setRules` calls no rule's `onInstall`: left as it is".

### The gap

`ComplianceHook.onInstall` calls `onInstall(token, previousPolicy)` on every rule of the list before the list goes live, and `FundHoldersRule` uses that call to refuse a class that has a supply unless the policy the token consulted until now listed the rule. `setRules` stores a list without calling any rule. So a timelock `setRules` can drop the fund rule from a class, movements then go uncounted, and a second `setRules` takes the rule back with `Fund.holderCount()` and the class masks no longer matching the balances. Nothing reverts. `Fund.isClassIntact` shows the class as broken only between the two calls.

### Why it was left, and what answers each reason

The decision of 2026-11-13 gave three reasons. Each needs an answer before this is built.

| Reason then | Answer now |
|---|---|
| It changes behaviour the tests pin | True. The tests that drop a rule and take it back change with the behaviour, and each is listed in the build's notes when found |
| It closes a door: a class whose list dropped the rule by mistake gets it back with one `setRules`, and with the check it could not until the class is empty | That door is the gap. Taking the rule back after uncounted movements is exactly the wrong count. See decision R3 for what replaces it |
| Replacing a fund's rule goes through `setRules` on classes that have holders, so the rule would have to accept a successor of the same fund | Decision R2: the rule accepts when the previous list held any rule of the same fund |

### Decisions

| # | Decision | Why |
|---|---|---|
| R1 | `setRules` calls `onInstall(token, address(this))` on every rule of the new list that the list it replaces does not hold, before it stores the new list. A rule that stays is not called. The whole new list is validated first: its length, each rule's attestation and no two rules with one `ruleId`; only then is any rule called, and only then is the list stored | The previous policy for a list change is the hook itself, which still answers `rules(token)` with the old list while the rules are asked, the same order `onInstall` already keeps. A rule that stays has nothing new to confirm |
| R2 | `FundHoldersRule.onInstall` accepts when the class has no supply, or the previous list holds a rule whose `FUND()` is this rule's fund. Today it accepts only itself in that list. The other rules of a list have no `FUND()`, so the rule compares the address with its own first and asks `FUND()` only of a rule that answers the `IFundHoldersRule` id through ERC-165; a rule that does not answer is passed over, never a revert | While any rule of the fund is listed, every movement of the class is either counted, when that rule is the one the fund has installed, or refused with `NOT_FUND_CLASS`, when it is not. So the count missed nothing, whichever of the fund's rules was listed. This keeps the replacement of a fund's rule working on classes with holders, and applies to a hook replacement as well as to `setRules` |
| R3 | No way back for a class that ran without the rule: it gets the rule again when its supply is zero. `Fund.isClassIntact` and `firstBrokenClass` stay the monitor | A recount needs the full holder list, which nothing on-chain can prove complete; the earlier `MaxHoldersRule` seed was removed for that reason. **Open for the owner:** the alternative is a timelock function on `Fund` that reads each named account's balance, corrects its mask and the count, and marks the class as current once, so that the rule's `onInstall` accepts it. It puts the completeness of the list on the timelock. Not in this plan unless asked |
| R4 | The token's own first installation is unchanged: the initialiser reaches `_setRules` through the hook's `onInstall`, which already tells every rule, so no rule is told twice | `setRules` is the external function; the internal one stays as it is |
| R5 | No interface changes. `IComplianceRule.onInstall` and `IFundHoldersRule.FUND()` exist | Rule 4 |

A rule's `onInstall` is not `view` in the interface, so `setRules` makes a call that may write before it stores the list. The rule is attested before it is called, `setRules` accepts only the token or its admin, and the hook's own `onInstall` already has this shape and its Slither note. The call from `setRules` gets the same note.

### As built on `main` (2026-11-19)

The owner passed on the review's go-ahead for this plan on 2026-11-19, with R3 as written. Entities are not started.

- **One change to R1, found in the tests.** The previous policy a rule is given is not always the hook: it is the policy the token consults at that moment, `token.policy()`, asked live. They are the same when the hook is the token's policy. They differ when a new hook is prepared with `setRules` for a token that still consults the old one, which is how a hook is replaced (`FundIntegration.t.sol`, the twin hook): the rule then asks the old hook, which lists it, and is asked again by `installPolicy`. With the hook itself as the previous policy that preparation would have been refused for every class with holders.
- **The hook.** `setRules` is `_validate`, `_tellAdded`, `_store`; `_setRules`, which the hook's own `onInstall` uses, is `_validate` then `_store`, unchanged in what it does. No interface changed, and `IComplianceHook`'s NatSpec for `setRules` does not mention the call yet: the file is frozen.
- **The rule.** `FundHoldersRule.onInstall` accepts itself or, through ERC-165, another rule whose `FUND()` is its fund.
- **Tests.** Eleven new: seven on the hook, three on the rule, and one on the fund with real contracts, a class with holders that drops the rule and cannot take it back. Seven failed before the change. One existing test changed with the behaviour: `test_WhenAClassAlreadyHasSupply_ItCannotBeRegistered` set its scene by taking the rule back on a class with a supply, which is now refused one step earlier; it asserts that refusal and that registration then fails for the unlisted rule. `Fund.t.sol` still covers the fund's own supply check.
- **Planted bugs.** The rules told after the list is stored; every rule told, not only the added ones; the fund rule accepting a rule of any fund: 7, 1 and 1 tests fail.
- **Gates.** `npx hardhat test`: 2151 passing (1952 solidity, 199 nodejs). Format, lint and typecheck clean, Slither 0 results, `validate:upgrades` 8 of 8, `verify:reproducible` 33 contracts identical.
- **Not done.** The port to `paris` and the pages.

### Steps, as planned

1. Tests first, shown failing: `setRules` adding a rule calls its `onInstall` with the hook as the previous policy, before the list is stored; a rule that stays is not called; a rule that reverts leaves the old list; dropping the fund rule from a class with holders and taking it back reverts with `FundHoldersRule_CountNotCurrent`; replacing the fund's rule by a successor on a class with holders passes; a rule of another fund in the previous list does not count.
2. `ComplianceHook.setRules` and `FundHoldersRule.onInstall`.
3. `SECURITY.md`, the brief (§6, dispatcher rule 4 and the fund rule's paragraph) and this file: the gap becomes a closed item, and R3's limit is stated.
4. Gates, then the port to `paris`, then the pages on each line.

### The port to `paris` (2026-11-19)

Carried here by cherry-pick; where the text above says "this line" it means `main`. The contracts and the tests are the same files. The brief keeps this line's sentence on the reentrancy guard, with the new sentence on `setRules` added to it. `npx hardhat test`: 2152 passing (1953 solidity, 199 nodejs). Format, lint and typecheck clean, Slither 0 results, `validate:upgrades` 8 of 8, `verify:reproducible` 33 contracts identical. Not done: the pages.

## Entities in the credential registry (planned and built on `main` 2026-11-19; the port to `paris` is not done)

Source: the same assessment, and the owner's "Yes, both". Derived from the code at `38fdbc1`. It reopens `ICredentialRegistry` and `IFund`, which rule 4 freezes: nothing here is built until the owner says so. `IFundHoldersRule` gains nothing, so its id does not move.

### What is missing

`SECURITY.md` says it: "Entities are not modelled: one wallet is one holder." An institution with a custody wallet, a trading wallet and a rotated key takes three places under a fund's investor cap, and a statutory cap counts investors, not addresses. The registry's `Record` uses 184 of its 256 bits, so there is room to name the investor without a second storage read.

### Decisions

| # | Decision | Why |
|---|---|---|
| N1 | `Record` gains `uint48 entity`. Zero means none: the wallet is its own investor, as today. The number is opaque and chosen by the attester; it says nothing about who the investor is | It fits the spare 72 bits, so `profileOf` still reads one slot |
| N2 | An entity belongs to the attester that wrote it. The key an investor is counted under is the attester's id and the entity number together, 56 bits | Two attesters number their investors independently. With one live attester for an address, which is today's rule, the record's attester gives the scope |
| N3 | The attester writes the entity with the credential: `set` takes it, and the signed `Credential` carries it, which changes `CREDENTIAL_TYPEHASH` | The party that verified the investor is the one that knows two wallets are the same investor. Signed, so a relayer cannot change it |
| N4 | New view `entityKeyOf(subject)`, from the stored record whatever its standing. A lapsed or exit-only record keeps its entity | The count must not move because a credential expired |
| N5 | A `Fund` is built with the registry it reads, or with none. With none it counts wallets, as today | A fund over an external registry names that one. Funds without a credential layer keep working. The constructor checks through ERC-165 that a registry it is given answers this version's `ICredentialRegistry` id, so a fund cannot be built over an older registry that has no `entityKeyOf` |
| N6 | `Fund` counts distinct keys. For each key it keeps how many of its wallets hold a class, and each holding wallet remembers the key it was counted under, in the spare bits of its existing word | A wallet leaving must lower the key it raised, even if the registry has changed since. No new storage slot for a wallet; one counter for each entity |
| N7 | A new investor is a receiver whose key has no wallet holding any class. A transfer between two wallets of one entity is never capped. At a full cap the net-zero case holds only when the sender's key has that one wallet and that wallet holds that one class | The cap is about investors |
| N8 | `Fund.rekey(account)`, callable by anyone: when a holding wallet's key in the registry differs from the one it was counted under, it moves the wallet to the new key and corrects the count | An attester can link or unlink a wallet while it holds. The function only makes the fund agree with the registry, so it needs no role. Until it is called, a newly linked wallet is counted twice, which errs on the strict side, and an unlinked one is not counted separately, which a monitor on `CredentialSet` catches |
| N9 | `rekey` and a FORCED movement may put the count above the cap, where nobody new is admitted, as today | Same rule as the lowered cap |
| N10 | No block by entity in this version. The guardian blocks wallets, as today | An entity block is one more cold storage read for each party on every transfer, about 4,200 gas, for an action the guardian can already take wallet by wallet. **Open for the owner** |
| N11 | `MinPositionRule` and any future limit on a position stay per wallet | Summing an entity's wallets needs the wallet list on-chain. Not in this work |
| N12 | No country in the record | The standing decision: a jurisdiction group is a qualification bit. A country would publish more about each investor |

### Counting rules, fixed before the build

A review of this plan on 2026-11-19 named four cases the decisions above left unsaid. Each was checked against `Fund.sol` at `38fdbc1` and is right. They are part of the specification.

| # | Rule | Why |
|---|---|---|
| N13 | A wallet is counted when it holds at least one class and is not exempt. Only a counted wallet has a cached key and a place in its key's counter. `holderCount()` is the number of counted wallets with key zero plus the number of keys whose counter is above zero | One definition for `join`, `leave`, `setExempt` and `rekey` to keep |
| N14 | Key zero is a wallet on its own: entity zero, or a fund built with no registry. It never uses the counter; its wallet moves the count directly. A key is zero only then, because a non-zero entity fills the low 48 bits | Otherwise every wallet with no entity would be one investor |
| N15 | `setExempt(wallet, true)` on a holding wallet takes it out of its cached key's counter, lowers the count if that was the key's last wallet, or directly for key zero, and clears the cached key. `setExempt(wallet, false)` on a holding wallet reads the key from the registry, caches it and counts the wallet as `join` would | Today the function moves the count by one for the wallet. With entities an exempt wallet left in a counter would let a second wallet of the entity in without the count rising |
| N16 | The sender's side of a decision reads the key the sender was counted under, never the registry: at a full cap the sender leaves the fund when that key is zero or its counter is one, the wallet holds only this class and the amount is its whole balance. The receiver's side reads the registry, because `join` will count it under that key | `leave` lowers the cached key. If `check` read the registry for the sender, an attester's change not yet followed by `rekey` would make the pre-flight and the write disagree, and could put the count above the cap on a plain transfer |
| N17 | `leave` clears the cached key with the wallet's last class. Every test of "holds nothing" in `Fund.sol` masks the class bits, and every test of "exempt" the exempt bit, since the word now carries the key as well | Today the code compares the whole word with zero |
| N18 | `rekey` does nothing for an exempt wallet, for one that holds no class and for one whose key has not changed | Nothing is counted for them |
| N19 | `setStatus`, `blockSubject` and `clearGuardianBlock` leave the entity as it is. `entityKeyOf` answers zero for an address with no record and for a record with entity zero | Pinned by tests, so a later change cannot move a count through a status |

### What it costs

- **Privacy.** An entity number shows publicly that two wallets belong to one investor, although not which. An investor that does not want its wallets linked keeps entity zero and takes one place for each wallet.
- **Gas.** On a movement to a wallet that holds no class, one more call from the fund to the registry, whose record the credential rule has already read, and one more storage read for the key's counter. Nothing more on a movement between wallets that already hold. To be measured in step 1 against today's 63,389 for a transfer through the standard list.
- **Interfaces.** `ICredentialRegistry` (the record, `set`, the credential, the event, the new view), `IFund` (constructor, `admission`, `rekey`, a new event) and the pinned ids and topics of each. `CredentialRule` reads `profileOf` and does not change.
- **An external registry** must be this version for a fund to count entities over it. Over an older one the fund is built with no registry.

### As built on `main` (2026-11-19)

The owner approved the plan on 2026-11-19 ("Merge both when CI is green, then build entities"), with N10 left out and the second live attester put off.

- **Gas base, step 1.** One fund class behind the credential rule and the fund rule, two transfers in one transaction: 83,548 gas to an address that holds nothing and 32,362 between two holders.
- **Interfaces.** `ICredentialRegistry` (`0x5f51feac`): `entity` in `Record` and in `Credential`, a fourth argument to `set`, a sixth to `CredentialSet`, and `entityKeyOf`. `IFund` (`0xa7306593`): `CREDENTIALS`, `rekey`, `countedWith`, `countedKeyOf`, `HolderKeyUpdated` and `Fund_NotACredentialRegistry`. `IFundHoldersRule` is unchanged. The freeze test failed on both ids and on the event's topic before they were pinned.
- **One change to the plan.** `admission` is as it was. The rule asks a new view, `Fund.countedWith(account)`, and only when it needs to: for a receiver that holds nothing and is not exempt, and for a sender at a full cap. It answers for a counted account from the key it was counted under, and for any other from the registry's key now, which is N16 in one function. Folding it into `admission` would have cost every transfer to an existing holder a cold read.
- **The registry.** The entity is stored with the record and signed with the credential; `entityKeyOf` is the attester's id above the entity number, and zero for no entity. Fourteen tests, eight failing against a stub that ignored the entity.
- **The fund and the rule.** As N5 to N9 and N13 to N18. The key sits in the 56 bits above the class bits of an account's word; a counter for each key that is not zero. `FundEntities.t.sol`: 26 tests on the real registry, credential rule, fund rule and hook, 15 failing against a stub, and two invariants over random movements, links, rekeys and exemptions. Three more unit tests on the rule.
- **Planted bugs.** Every address counted on its own; the key kept when the last class goes; a sender judged by its address alone; an exemption moving the count without the key; `rekey` always moving the count; the sender's side reading the registry; the receiver's investor ignored; the key without the attester; the entity kept when the attester writes zero: 13, 4, 3, 2, 3, 3, 5, 6 and 3 tests fail.
- **Gas after.** The same two transfers: 87,632 to an address that holds nothing and names no entity (+4,084, the two questions to the registry), 32,395 between two holders (+33), and 111,884 to an address that holds nothing and names an entity nobody held under yet (+28,336, most of it the first write of that entity's counter and the event).
- **Deployment.** The `Fund` module takes `credentials`; the fixtures pass the core's registry, or zero for a core with none; the post-deploy check compares `CREDENTIALS()`. One node test through the real deployment: two addresses of one entity count once, and a later link is followed by `rekey`.
- **Pages.** Eight pages changed for entities, with their Markdown copies; none carries a commit id.
- **Gates.** `npx hardhat test`: 2197 passing (1997 solidity, 200 nodejs). Format, lint and typecheck clean, Slither 0 results, `validate:upgrades` 8 of 8, `verify:reproducible` 33 contracts identical.
- **Halmos, added after the merge (2026-11-19).** `FundKeyHalmos` in `FundHalmos.t.sol`: over two addresses, with a registry stub whose keys the run sets, the count is the investors among the counted addresses by the key each was counted under after any three operations (a join, a leave, an exemption or its removal, a key change in the registry, a `rekey`); the same after any two when both addresses start under one key; and after a `rekey` of both, each counted address is under the registry's key. Three planted bugs each fail two of the three. The same change corrects two page sentences that said a one-unit deposit to an empty receiver takes an investor's place: it does only when the receiver's investor is not counted yet.

### The port to `paris` (2026-11-19)

Carried here by cherry-pick; where the text above says "this line" it means `main`, and the gas figures were measured there. The contracts, the tests and the pages are the same files; the brief keeps this line's Phase 7 text. `npx hardhat test`: 2198 passing (1998 solidity, 200 nodejs). Format, lint and typecheck clean, Slither 0 results, `validate:upgrades` 8 of 8, `verify:reproducible` 33 contracts identical. Not done: a Halmos property for the count by key.

### A second live attester for one address: not in this plan

The assessment also asks that an investor hold records from two attesters at once. Today a second attester writes only after the first is killed. The two ways to lift that, and why neither is planned yet:

- **A record for each attester.** The credential rule would read a mask of who attested the address and then one record for each of those attesters the policy trusts: usually one more read than today, and more for an address with several.
- **One record, with the bits each attester added.** Killing one attester must remove only its bits, so the record needs to keep who set which, which no longer fits one slot.

The way that works today costs nothing: the attester of record takes the second verification off-chain and writes the union, within the bits it is allowed. **Open for the owner:** whether a real second attester is expected soon enough to design for it now. N2 would then need the entity to be scoped differently.

### Steps

1. Measure a transfer to a new holder and between holders on the code as it is, so each later number has its base.
2. Interfaces and the brief (§6's fund rule and credential rule paragraphs), with the freeze test re-pinned and shown failing first.
3. Registry: tests first, then the record, `set`, `register`, the event and `entityKeyOf`.
4. Fund and `FundHoldersRule`: tests first, with the invariant of N13 after any sequence of movements, exemptions, registry changes and rekeys, and the parity of `check` with the write while a rekey is outstanding (N16), then the code.
5. Deployment: the `Fund` module's registry parameter, the profiles, the post-deploy check, the node tests.
6. Gates, the measured gas written here, then the port to `paris`, then the pages on each line.

## The pages, for `Gated1155` and `setRules` (2026-11-19)

Step 7 of the multi-token plan and the last step of the `setRules` plan. Written on `main` and carried here by cherry-pick: on this line each page keeps this line's build sentences, and where the text below says `75aa171` and #53 it means `main`.

- **New page.** `docs/contracts/Gated1155.html`, on the model of the `Gated721` page, with three sections of its own: the batch, the receiver callback and the errors of a refused movement.
- **Changed pages.** Twenty: the five root pages and fifteen contract pages. `Gated1155` and the `multi` profile appear wherever the templates and the profiles are listed, the overview's drawing has the sixth template, and every page that described `setRules`, the hook's `onInstall` or the fund rule's install check states the behaviour as it is now.
- **How they were checked.** A subagent drafted them against the source; I read the new page whole and checked the claims it flagged as unsure against the contracts. Every test named on the pages exists. `md_check.py`: 45 pages, 0 problems. The pages carry no commit id: the owner had the footers that named one removed on 2026-11-19, with the one id in `SECURITY.md`.
- **Left as found.** The pause table on the roles page lists `transfer` and `transferFrom` under "every product", which the two non-fungible templates do not have. Older than this work.
- **Also here.** Two corrections to the entities plan above, from its second review: the registry check in `Fund`'s constructor (N5), and two reopened interfaces, not three.

## An ecosystem on a private chain: assessment and plan (2026-11-19, nothing built)

Source: an outside assessment of the whole stack the owner passed on 2026-11-19, with "I want to plan the changes" and "do a full honest assessment, study how to integrate and implement the best solutions for each change and let's guarantee after that it is a nice improvement against the actual version". Derived from the code at `0f90907` on `main`. It proposes thirteen changes in four groups, for the step from one issuer with a few funds to many products on one private chain. Each is assessed below against the code, given the design that fits this stack, and a measure that says whether it improved on what exists. Nothing here is built, and nothing is built until the owner picks.

### The target: one operator, a private Besu chain

A second note from the owner the same day fixed the target: one operator runs every validator and node of a private Besu chain, with no gas price. That is the `paris` line, so each change below is built on `main`, ported to `paris` as always, and judged on `paris` where the two differ. It changes four things in the plan.

- **One core serves the whole chain.** A single operator is the one governance, so E5's split into a chain core and issuer cores is not needed: the `Core` that exists is already the shared one, and every fund, note or series is a `Product` run. What is left of E5 is the limit that one `ProxyDeployer` takes each symbol once, which now covers the whole chain.
- **No second attester.** The operator's own compliance function gathers its vendors' answers and writes one record for an address. E10 is dropped, and the one-slot read stays.
- **No gas price** means the measure that matters is execution time and state growth, not cost. The benchmark still counts calls, slots and gas, which stand in for both, and step 0 gains a run on a local Besu network of the `paris` build.
- **The operator runs the keepers.** Holders' addresses are the operator's own custody wallets or its clients'. So a claim, a payout and a rekey can each be pushed by a keeper, which makes E2 and E3 more useful and adds E13 and E14.

### What the assessment gets right, and what it misses

- **Right about the limits.** Settlement of a trade exists for `IntentToken` only, one trade for each transaction, with no partial fill. A frozen amount is one number that only the agent sets. A vault has its own portfolio. Every intent's nonce takes a storage slot for ever. One address has one live attester.
- **Already done.** Its first identity item, entities, landed on 2026-11-19 (#57, #58).
- **Smaller than it looks.** Four of the thirteen need little or no contract code here: the shared runtime is a deployment mode, the cash token is a profile, master and feeder funds can be composed from parts that exist, and the pool of relayers is an operations matter.
- **Not shown.** "Two to three times the throughput" from a fused policy is a guess. What is measured: a transfer between two holders of a fund class with four rules makes 15 calls and costs 39,425 gas; to a new holder, 19 calls and 88,671 gas. On a chain with no gas price the limit is execution time and state growth, and neither has been measured on Besu.

### How "better than today" is decided

No change is kept on an argument alone. Step 0 of this plan is a benchmark every later change is held to.

1. **A benchmark file**, `contracts/test/Bench.t.sol`, that runs fixed flows and records for each the calls, the storage slots written and the gas. Not a gate at first: `npm run bench` prints a table, and the table is copied here. Built on 2026-11-19.
2. **The flows:** a transfer between holders and to a new holder (four rules, a fund class); an executed intent; a trade through `DvPExecutor` in both forms; a 4626 deposit and redeem; a 7540 request, settlement of a period with 1 and with 100 investors, and a claim; a signed entry; a distribution claim.
3. **The base,** from `npm run bench` on `main` at the commit that added it (Cancun, the default test profile). Each flow's preparation runs in the same transaction, so what it touched is warm; the numbers compare two versions of the stack and are not what a first transaction costs.

| Flow | Calls | Slots written | Gas |
|---|---|---|---|
| transfer: between holders, 4 rules, fund class | 15 | 2 | 39,329 |
| transfer: to a new holder, 4 rules, fund class | 19 | 4 | 88,575 |
| intent: executeTransfer through IntentExecutor | 13 | 3 | 102,004 |
| intent: executeTransfer, the nonce next to a used one | 13 | 3 | 102,004 |
| dvp: gated cash | 22 | 6 | 185,329 |
| dvp: erc-3009 cash | 22 | 8 | 196,503 |
| 4626: deposit | 14 | 4 | 62,140 |
| 4626: redeem | 14 | 4 | 42,220 |
| 7540: requestDeposit | 10 | 6 | 135,290 |
| 7540: settlePeriod, 1 investor | 5 | 11 | 60,521 |
| 7540: settlePeriod, 100 investors | 5 | 11 | 60,532 |
| 7540: claim deposit | 22 | 7 | 124,720 |
| signed entry: 4626 with permit | 24 | 12 | 240,115 |
| distribution: claim | 11 | 4 | 82,403 |

   The first two rows were first measured by hand at 39,425 and 88,671; the file reads its addresses into locals before it starts counting, which is the 96 gas between them. The fixtures are the existing integration ones: rows 1, 2 and 13 run on the real credential and fund rules, and rows 3 to 11 on the fixtures' identity mock in place of the credential rule, so their totals are a little below a production list's. Settling a period costs the same for 1 investor and for 100.

4. **The rule for each change:** it names the flow it improves and by how much before it is built; it is kept only if the number is met; no other flow may get worse by more than 2% in gas or by one call, unless the change says so and why; and every existing gate stays green: the suites, the invariants, Halmos, Slither, sizes, upgrade safety, the reproducible build, with planted bugs for the new code.
5. **What the benchmark cannot say:** throughput on Besu. A change justified by throughput (E11 below) needs a run on a Besu network before it is kept.

### The changes, in the order proposed

**Tier 1: small, clear, no open design.**

| # | Change | Verdict and design | Touches | Kept if |
|---|---|---|---|---|
| E1 | Nonces in a bitmap | **Do.** `IntentSettledUpgradeable` keeps `nonceUsed(signer, nonce)` and the `bytes32` nonce as they are, and stores the nonce as bit `nonce & 0xff` of word `nonce >> 8`. A signer that numbers its nonces densely uses one slot for 256 intents; a random nonce still works and costs what it does today. No interface changes. `SignedEntry` gets the same | the mixin's storage (no deployment exists, so no migration), `SignedEntry`, tests, the signing helper | 256 intents with dense nonces write 1 nonce slot, not 256, and an executed intent on a used word costs at least 12,000 gas less |
| E2 | A distribution pushed in batches | **Do.** `claim` already pays any holder, whoever calls. Add `claimBatch(id, holders, amounts, proofs)`, open to anyone, which skips a holder that already claimed or may not receive and says so in an event, so one bad row does not stop a payout. The payment itself can fail too: `claim` asks the share token whether the holder may receive, but the money is another token, and when that one is gated (the cash token of E4) a holder it refuses reverts the transfer. So the batch tries each payment, and a row whose payment fails is skipped, left unclaimed and named in the event. A bad proof, a row above the funding, a distribution not approved or expired still revert the whole batch: those are the caller's errors. `Multicall` would revert the whole batch on one row | `Distributor`, `IDistributor` (reopened) | 100 holders paid in one transaction, for less gas than 100 claims; a holder the share token or the cash token refuses leaves the other 99 paid and can still claim later; a bad proof reverts the batch |
| E3 | Signed exits | **Do.** `SignedExit`, the mirror of `SignedEntry`: immutable, no roles, no money between calls. The holder signs where the cash goes and the least it accepts, with the share token's `permit`. On a 4626 the lego redeems to the signed receiver. On a 7540 it files the request, and claims for a controller that made it an operator once. Today's exit, a permit and a `multicall`, trusts the relayer with where the cash goes | new contract and interface, `Core` and `CoreParts`, tests | a relayer can submit an exit and cannot change its receiver or its minimum; the entry flow's numbers do not move |
| E4 | A cash token | **Do as a profile, not a contract.** A `cash` profile: an `IntentToken` with `CredentialRule` and `SupplyCapRule`, minter and burner held by the issuer's payment operations. It already settles in `DvPExecutor`, pays into vaults, funds a `NavDesk` and a `Distributor`, and enters through `SignedEntry` by `permit`. ERC-3009 on our own token is not needed for any of that; add it only if an outside system requires it | `ignition/profiles.ts`, node tests, pages | the profile deploys, passes the post-deploy check, and each of the five uses is shown in a test |
| E5 | One core for the chain | **Nothing to build for one operator; a deployment mode if a second issuer ever joins.** With one operator the existing `Core` is the chain's: one registry, one hook, one credential registry, one set of implementations, and a `Product` run for each instrument. For a second issuer with its own governance the design is a split, with no contract change expected: the hook has no admin and asks each token's own admin, rules take their settings from each token's roles, and each issuer would bring its own timelocks, guardian and `ProxyDeployer`. To decide now: one deployer takes each symbol once, so a ticker reused for a rolled note needs a new symbol or a second deployer | pages; Ignition only if a second issuer joins | twenty products of mixed templates launch on one core with no timelock wait and pass the post-deploy check |
| E6 | Master and feeder funds | **Prove before building.** A feeder vault whose `Portfolio` holds an `ERC4626Adapter` into a master `Gated4626Vault`, each class with its own `FeeModel` and rule list, is this structure from parts that exist. Write the integration test and a profile first. Code follows only for a gap the test finds; the known candidates are a master that deals in periods, which the adapter cannot enter, and the master's limit on counted gains reaching the feeders late | a test, a profile, pages; contracts only if the test fails | two classes over one master: a gain in the master reaches both prices in proportion, each class charges its own fee, and the money sits in one place |
| E13 | Claims that arrive on their own | **Do with what exists, and add no signature path yet.** After a period settles, a keeper that a controller made its operator can claim the shares or the cash to that controller: the 7540 has `setOperator`, and an operator's claim to the controller itself passes the third-party check. On this chain the grant is one transaction at onboarding, which costs the wallet nothing. A signed `setOperator` would reopen the vault's interface and add code to a contract near its size limit, so it waits for a wallet that cannot send that transaction. An operator is a full delegate under ERC-7540, so the keeper is a contract that can do nothing but claim to the controller: `SignedExit` (E3) carries that function, open to anyone, taking a list of controllers. A claim can fail for one controller, a deposit claim below the minimum position or into a full fund for instance, so the batch skips that controller with an event and delivers the rest. Tests pin that this entry point can only claim, and only to the controller itself: it can file no request and name no other receiver | E3's lego, the onboarding runbook, pages | after `NavDesk.execute`, one keeper transaction delivers every controller's claim; one controller whose claim is refused does not hold back the others; and the keeper can send nothing anywhere else |
| E14 | The control plane | **Do, off-chain.** The post-deploy check is a function inside the test fixtures. Move it to a script that runs against a live network and exits non-zero, and add keepers for `Fund.rekey` (from `CredentialSet`), `NavDesk.closePeriod` and `execute`, `collectFees`, `claimBatch` and the claims of E13, and a reconciler that compares each cash token's supply with the ledger it mirrors and each fund's count with its cap. No contract changes | `scripts/`, the node tests that already call the check, the runbook | the check runs against a deployed stack from the command line; each keeper is shown in a node test doing its one job and nothing else |

**Tier 2: new legos, a design to settle first.**

| # | Change | Verdict and design | Touches | Kept if |
|---|---|---|---|---|
| E7 | Encumbrance | **Do, with the seizure redesigned.** "The holder may move only what is not pledged" is a policy decision, so by rule 11 it is a rule. `EncumbranceRule`: liens keyed by token, holder and lien id, each with a beneficiary and an amount; the holder creates one, only the beneficiary releases it; the rule refuses any movement, a redemption included, that would leave the holder with less than its pledged total, and exempts FORCED. Its decision reads the balances and the pledged total and nothing else, so it does not depend on the operator and a pre-flight agrees with the write. The first version of this row had the beneficiary seize under an allowance from the holder. A review showed two faults, both real: the holder can revoke an allowance after drawing the loan, and letting the beneficiary's own transfer through means a rule that reads the operator (dispatcher rule 6) and a lien that an ordinary payment to the lender would lower. Two designs remain. **(a) A scoped enforcement lego, preferred:** an immutable `LienAgent` that holds `AGENT_ROLE` on the token and has one power, to lower a lien and force exactly that amount from the holder to the lien's beneficiary when the beneficiary calls. The holder cannot revoke it, the tokens stay the holder's until default, so its distributions and its place in a fund's count stay too, and the rule needs no exception because FORCED is already exempt. Its cost is an `AGENT_ROLE` held by a contract, which the timelock grants and the council reviews. **(b) An escrow:** pledged tokens move to a `LienVault`. Seizure is then a plain transfer and `maxRedeem` is exact, but the vault is the holder of record: a distribution's list has to look through it, and a fund's count sees the vault, the same question as a 7540's escrow. To settle before any code: (a) or (b). Limit of (a) to state: `maxRedeem` does not know a lien, as it does not know a minimum | new rule and interface, the lego, a reason code, tests, pages | two lenders hold liens on one holder and neither can touch the other's; the holder cannot move pledged tokens, cannot stop a seizure, and can move the rest; a payment from the holder to its lender leaves the lien as it was; a transfer with the rule listed and no lien costs at most one cold read more |
| E8 | Orders, fills and batches | **Do, as a new executor beside `DvPExecutor`.** A partial fill cannot come from an intent: its nonce is spent once and its amount is fixed. So `OrderSettlement`: a party signs an order on the executor's own domain (what it gives, what it takes, the least or the most it accepts, a counterparty or anyone, an expiry, a nonce) and gives the executor an allowance, by `permit` for the ERC-20 templates. The executor keeps `filled[orderHash]`, checks every fill against both orders, and pulls both sides. `settleBatch` takes many fills atomically and names the failing one. It works on `GatedToken` and on both vaults' shares with no token change; the hook sees a TRANSFER with the executor as operator. A token that trades here must not list `ExecutedOnlyRule`, which refuses a TRANSFER; an `IntentToken` under that rule keeps `DvPExecutor`. A `Gated1155` series can be a leg from the start, with the token id in the order and `setApprovalForAll` to the executor given at onboarding, so fixed-income series fill in parts without a third executor; that approval covers every id the holder has, and the signed order is what bounds the executor. Netting of a whole cycle is a second phase: the executor would have to hold tokens between legs or move only net amounts, and proving on-chain that the nets respect every order is the hard part | new executor and interface, role and pause as the others, `Core`, tests, pages | 100 fills settle in one transaction for less gas each than 100 DvP trades; an order fills in parts up to its amount and never past it; a fill worse than a signed limit reverts; shares of both vaults and a `Gated1155` series trade against cash |

**Tier 3: decide later, on evidence or advice.**

| # | Change | Verdict | What would decide it |
|---|---|---|---|
| E9 | Omnibus accounts | **A legal question first.** Today a pooled account is either one investor or, exempted, none. The small design is a weight: the fund counts a named account as the number of beneficial owners its holder declares. A qualification bit for such accounts costs nothing to reserve now (ten of 32 are used) and lets a token's policy admit or refuse them. Whether a declared number satisfies a statutory look-through is for counsel | counsel's answer; then about the size of the exemption path |
| E10 | A second live attester | **Dropped for this target.** One operator writes one record for an address. If several issuers ever share the registry, the design that keeps the common read at one slot is an identity record as today plus a second slot of endorsements, read only when the first does not meet the policy | several issuers on one registry |
| E11 | A fused policy, for the cash token first | **Measure first.** One contract in place of the hook and its rules removes most of the 15 calls, but it either copies the rules' state, which then has to be current at every installation, or still calls out for it. Build a spike for the cash token's short list, and keep it only if a transfer costs at least 35% less and a Besu run shows the throughput | the benchmark, then a Besu run |
| E12 | Netting of a cycle | **After E8.** See E8 | E8 in use, and a desk that wants it |

**Not code.** A pool of relayers: both executors already take many operators, and an intent's nonce belongs to its signer, not to the relayer, so several relayers can submit at once today. It belongs in the runbook.

### Order and dependencies

Step 0, the benchmark, comes first and is small. Then, in the order proposed:

1. **One pass over the frozen surface, before any outside audit:** E1 (nonces), E2 (`claimBatch`, the only existing interface reopened) and E3 with E13 (`SignedExit` and the keeper's claim).
2. **The rail and the desk:** E4 (the cash profile), then E8 (orders, fills and batches).
3. **Operations:** E14 (the control plane), alongside the chain itself.
4. **Capital:** E6 (master and feeder, test first), then E7 (encumbrance).
5. **On evidence:** E11 (a fused policy), E12 (netting), E9 (omnibus).

E12 needs E8, E13 needs E3, E11 needs step 0 and a Besu run. Each change is its own pull request on `main` with its port to `paris`, tests first, and its row in the benchmark table. Settings of the chain itself (block time, the storage format, which nodes validate and which serve) are the operator's and are not in this repository.

### The first pass, as built on `main` (2026-11-19): E1 and E2

The owner passed on the go-ahead for step 0 and the first pass on 2026-11-19. E3 with E13 followed the same day and has its own section below.

- **E1, nonces in a bitmap.** `IntentSettledUpgradeable` and `SignedEntry` keep a nonce as bit `nonce & 0xff` of word `nonce >> 8`. No interface changed; `nonceUsed` and the `bytes32` nonce are as they were. Five tests: 256 nonces of one word share one slot, in the mixin and in the signed entry, which failed before the change; a used nonce spends no other, fuzzed over the nonce, its neighbours in the word, the next word and another signer; two nonces of a word are each spent once.
- **E2, `claimBatch`.** As in the row above, with the row logic in one function so the batch and the stack both fit. `IDistributor` reopened: `claimBatch`, the `ClaimSkip` enum and `DistributionClaimSkipped`; the freeze test failed on the id before the re-pin. Eleven tests, ten failing against a stub: each of the three reasons to pass a row over, a holder named twice, the four reverts of the whole batch, an empty batch, and a hundred holders in one transaction.
- **Planted bugs.** A whole word spent by one nonce, in the mixin and in the signed entry; the word ignored; the nonce never marked; a refused payment left as claimed; a holder already paid paid again; a bad proof passed over; the token's refusal ignored: 3 and 2, 11, 11, 1, 4, 1 and 1 tests fail.
- **Against the benchmark.** Three rows were added for these two changes. Every other row moved by at most 154 gas (0.19%) and by no call.

| Flow | Before | After |
|---|---|---|
| intent: executeTransfer, the nonce next to a used one | 13 calls, 3 slots, 102,004 gas | 13, 3, 82,123 |
| intent: executeTransfer through IntentExecutor (a nonce in a fresh word) | 13, 3, 102,004 | 13, 3, 102,023 |
| distribution: claim | 11, 4, 82,403 | 11, 4, 82,557 |
| distribution: 100 claims, one by one | 1,100 calls, 400 slots, 6,487,454 gas (after the change; `claim` is as it was) | the same |
| distribution: claimBatch, 100 holders | no such function | 1,001 calls, 400 slots, 4,938,738 gas |

  E1's number was 12,000 gas less on a used word: it is 19,881 less here, where the word was written in the same transaction and is warm. In a later transaction the schedule gives about 17,100 less (a write to a slot that already holds a value, against a write to an empty one). In state, 256 numbered nonces take one slot where they took 256. E2's number was less gas than 100 claims: 24% less in the calls themselves, before the 100 transactions' own base cost.
- **Gates.** `npx hardhat test`: 2227 passing (2027 solidity, 200 nodejs). Format, lint and typecheck clean, Slither 0 results, Halmos 22 of 22 on this branch, `validate:upgrades` 8 of 8, `verify:reproducible` 33 contracts identical.
- **Not done.** No node test drives `claimBatch` through the deployed stack. The signing helpers still draw random nonces; numbering them is the client's choice. The port to `paris`.

### The first pass, as built on `main` (2026-11-19): E3 with E13

- **The contract.** `SignedExit`, immutable, no roles, with `ISignedExit` (a new interface, id `0x5ef9720f`, and four event topics, pinned). An exit is the holder's signed `Exit` and the share token's `permit`; a 4626 pays the signed receiver from the vault, and a 7540 gets a request with the holder as controller. `claimFor(vault, controllers)` is E13: open to anyone, it claims a settled deposit's shares and a settled redemption's cash to each controller itself, and passes over a claim the vault refuses with the vault's own error in the event. Its nonces are one bit each, as in E1.
- **What the review asked for, and where it is pinned.** One refused controller does not hold back the others: `test_AControllerThatDidNotAllowItIsPassedOverAndTheOthersAreServed`, `test_AControllerThePolicyRefusesIsPassedOverAndTheOthersAreServed`. The entry point with no signature can only claim, and only to the controller: `test_ItLeavesAPendingRequestAloneAndFilesNone`, and the two delivery tests check that the caller and the contract end with nothing.
- **Tests.** `SignedExit.t.sol`, 22 tests on real vaults behind the real credential registry, rule and hook; 19 of the first 21 failed against a stub. The freeze test failed on the unpinned id. One node test: the part joins a running core alone, a holder leaves a 4626 through it by a relayer, and the post-deploy check refuses a stack that lost it.
- **Planted bugs.** A deposit claim sent to the caller; a redemption's cash sent to the caller; the minimum not checked; the signature not checked; a request allowed to name another receiver; the nonce not spent; the cash sent to the holder whatever was signed; the deadline not checked: 3, 1, 1, 1, 1, 2, 2 and 1 tests fail.
- **Deployment.** Part `signedExit`, profile flag `signedExit`, in `Core` and `CoreParts`; the post-deploy check compares its code with the release and a sample exit's hash with the one a holder signs for the chain and the address.
- **Against the benchmark.** Two rows added, and no existing row moved by a single gas: a signed exit from a 4626 makes 17 calls, writes 8 slots and costs 122,177 gas; `claimFor` for ten controllers with a settled deposit each makes 141 calls, writes 50 slots and costs 657,340 gas. The exit is a function that did not exist, so its number is a base for later, not a gain; what it buys is in the tests, a relayer that cannot change the receiver or the minimum.
- **Found while writing the page.** On a 7540 the three-argument `redeem` is a claim, so an exit signed as synchronous for a 7540 is a signed claim of settled cash to the signed receiver, for a holder that made the contract its operator. It needs the holder's signature and the vault judges the receiver, so nothing is opened; it was unstated and untested. It is now in the interface's NatSpec, the brief and `SECURITY.md`, and pinned by `test_OnA7540ASynchronousExitIsASignedClaimThatNeedsTheHoldersLeave`.
- **Pages.** A page for `SignedExit` and nine pages changed, with the Markdown copies (46 pages). The new page's figure was looked at in a browser; the overview drawing has no room for another box and names the contract in its caption.
- **Gates.** `npx hardhat test`: 2251 passing (2050 solidity, 201 nodejs) before the test above was added, and that file then passed alone with 22. Format, lint and typecheck clean, Slither 0 results, Halmos 22 of 22, `validate:upgrades` 8 of 8, `verify:reproducible` 34 contracts identical.
- **Not done.** No signed `setOperator`: a controller makes the contract its operator with a transaction of its own, as the plan decided. No Halmos property. The port to `paris`.

### The second pass, as built on `main` (2026-11-19): E4, the cash profile

The owner approved the second pass on 2026-11-19 ("Yes, start"). E8 is not built yet.

- **A profile and no contract.** `cash` in `ignition/profiles.ts`: one `IntentToken` with six decimals, `CredentialRule` and `SupplyCapRule`, both executors. It does not list `ExecutedOnlyRule`, because a plain transfer is how every other part takes and pays it.
- **The five uses, on real contracts.** `IntentTokenAsCash.t.sol`, seven tests: the cap bounds the minter; a 4626 takes it only once the vault holds a credential; an investor enters that vault through `SignedEntry` by the token's `permit`; a 7540 deals in it through a cash account that holds a credential; a distributor is funded and pays in it, passing over a holder that may not receive; and a security settles against it through `DvPExecutor`. They passed as written: nothing in the contracts had to change, which is the finding.
- **What it shows that was not written down.** Every contract that holds the cash is a holder of a gated token: a vault, the signed entry, a distributor and a fund's cash account each need a credential on it. `SignedEntry` and the vault's own page said so for a gated asset; the distributor's did not.
- **The profile.** A node test deploys it with `cashSupplyCap`, checks the decimals, the cap, both executors' role, a mint above the cap refused and a plain transfer allowed; the test that deploys every profile runs the post-deploy check on it.
- **No benchmark row.** No contract changed, so no flow moved.
- **Gates.** `npx hardhat test`: 2260 passing (2058 solidity, 202 nodejs). Format, lint and typecheck clean. Slither, upgrade safety and the reproducible build were not rerun locally: no contract changed.
- **Not done.** ERC-3009 on the stack's own token, by decision: nothing here needs it.
- **On `paris`.** Carried by cherry-pick; the brief keeps this line's deployment text. `npx hardhat test`: 2261 passing (2059 solidity, 202 nodejs); format and typecheck clean.
### The first pass on `paris` (2026-11-19): step 0, E1 and E2

Carried here by cherry-pick with no conflict; where the text above says "this line" it means `main`, and its numbers are `main`'s. The contracts, the tests and the pages are the same files. This is the line the target runs, so its own base is recorded. The guard here is in storage, which is the two more slots written on most rows.

| Flow | Calls | Slots written | Gas |
|---|---|---|---|
| transfer: between holders, 4 rules, fund class | 15 | 4 | 42,687 |
| transfer: to a new holder, 4 rules, fund class | 19 | 6 | 91,965 |
| intent: executeTransfer through IntentExecutor | 13 | 5 | 106,075 |
| intent: executeTransfer, the nonce next to a used one | 13 | 5 | 106,075 |
| dvp: gated cash | 22 | 12 | 196,083 |
| dvp: erc-3009 cash | 22 | 12 | 203,938 |
| 4626: deposit | 14 | 6 | 65,829 |
| 4626: redeem | 14 | 6 | 45,929 |
| 7540: requestDeposit | 10 | 6 | 135,796 |
| 7540: settlePeriod, 1 investor | 5 | 11 | 61,357 |
| 7540: settlePeriod, 100 investors | 5 | 11 | 61,368 |
| 7540: claim deposit | 22 | 9 | 128,365 |
| signed entry: 4626 with permit | 24 | 14 | 241,913 |
| distribution: claim | 11 | 4 | 82,708 |

After E1 and E2, on this line: an executed intent next to a used nonce costs 86,184 gas, from 106,075; a `claimBatch` of 100 holders costs 4,973,956 against 6,516,678 for 100 claims; no other row moved by more than 153 gas or by a call. `npx hardhat test`: 2228 passing (2028 solidity, 200 nodejs). Format, lint and typecheck clean, Slither 0 results, Halmos 22 of 22, `validate:upgrades` 8 of 8, `verify:reproducible` 33 contracts identical.

E3 with E13 followed, carried the same way; the brief keeps this line's deployment text. On this line a signed exit from a 4626 costs 123,620 gas and `claimFor` for ten controllers 664,720, and no existing row moved. `npx hardhat test`: 2253 passing (2052 solidity, 201 nodejs). Format, lint and typecheck clean, Slither 0 results, Halmos 22 of 22, `validate:upgrades` 8 of 8, `verify:reproducible` 34 contracts identical.

### E8 in detail: `OrderSettlement` (design, 2026-11-19, nothing built)

The row above gives the shape. This is the design to review before any code, with the decisions that are the owner's marked.

**What it is.** An immutable executor beside `DvPExecutor`, with the same governance as the other two: `OPERATOR_ROLE` submits, the guardian pauses, the timelock or the recovery timelock unpauses, a reentrancy guard on its one entry point. It is not attested and holds no role on any token: it moves a party's tokens only under an allowance that party gave it, and only as that party's signed order allows. It never holds tokens.

**An order.** Signed by its maker on the executor's EIP-712 domain:

| Field | Meaning |
|---|---|
| `maker` | Who signs, gives and receives |
| `giveToken`, `giveId`, `giveAmount` | What the maker gives, at most. `giveId` is zero for an ERC-20 and the token id for a `Gated1155` |
| `takeToken`, `takeId`, `takeAmount` | What the maker takes for the whole `giveAmount`, at least. The two amounts are the maker's limit price |
| `giveIs1155`, `takeIs1155` | Which kind each side is. An ERC-721 is not supported: it has no amount to fill in parts |
| `taker` | The only counterparty allowed, or zero for anyone |
| `allOrNothing` | When set, the order is filled in one fill for its whole amount or not at all |
| `nonce`, `validAfter`, `deadline` | As in an intent. The nonce makes the order unique and is what `cancelOrder` spends, one bit as in E1 |

The maker receives at its own address. An order names no other receiver: a third-party receiver would have to be judged, and the stack's own rule for that is in the vaults, not here.

**A fill.** The operator submits two orders that cross, their signatures, and two amounts: `x` of the first order's give token and `y` of the second's. The executor checks, for each order: the window, the nonce not cancelled, the signature (ECDSA or ERC-1271), the taker if named, that the two orders name each other's tokens and ids, that this fill does not take the order past its `giveAmount`, and its limit:

- the first maker gives `x` and must receive at least `ceil(x × take / give)` of its own terms, so `y` must be at least that;
- the second maker gives `y` and must receive at least `ceil(y × take / give)` of its terms, so `x` must be at least that.

Both are `Math.mulDiv(amount, take, give, Math.Rounding.Ceil)`, whose product is 512 bits wide, so two 18-decimal amounts cannot overflow it.

A fill is refused before any of that when it is degenerate: either amount zero; an order with a zero `giveAmount` or `takeAmount`; both orders from one maker, which would otherwise fail later on the balance check with the wrong error; an order that gives and takes the same token and id; or a token id that is not zero on a side that is not an ERC-1155.

Rounding is always against the counterparty, so no sequence of small fills pays a maker less than its price. Then `filled[orderHash] += amount` for both, and two transfers: `x` from the first maker to the second, `y` from the second to the first. For an ERC-20 the executor checks that the receiver's balance rose by exactly the amount, as `DvPExecutor` does for cash, so a token that takes a fee on transfer cannot settle here.

**What the token sees.** A plain `transferFrom`, or a `safeTransferFrom` of a `Gated1155`: a TRANSFER with the executor as operator. Every rule judges the two parties as on any transfer, and no rule reads the operator. So a token that lists `ExecutedOnlyRule` cannot trade here, and `SettlementWindowRule`, which judges EXECUTED only, does not apply: a product that wants signed intents and a window keeps `DvPExecutor`.

**A batch.** `settle(Fill[])` runs the fills in order, atomically. A fill that fails reverts the batch with its index and the cause, as `IntentExecutor.executeBatch` does. A later fill of the same order sees what the earlier ones filled.

**Cancelling.** `cancelOrder(nonce)` by the maker, any time; a cancelled order fills no further, and what it filled stays. Revoking the allowance stops it too. What is filled is kept for each order's hash, and what is cancelled for each maker's nonce. So two different orders a maker signs with one nonce can both fill, each up to its own amount, and one `cancelOrder` cancels both: a maker that wants an order to replace another signs them with the same nonce and cancels, and otherwise gives each order its own.

**A pre-flight.** `canFill(fill)` returns the first reason a fill would be refused by the executor's own checks, and for one of the stack's tokens the token's own `canTransferWithReason`, which counts the balance and gives the reason; ERC-7943's plain `canTransfer` answers true above the balance when nothing is frozen and gives no reason, so it is the fallback only for a token that answers the standard's id and has no reasoned pre-flight. It does not check allowances or balances of a token that is not one of the stack's, and says so.

**What an operator can and cannot do.** It chooses which orders meet, in what amounts, and at what price between the two limits; the difference between the limits goes where it chooses. It cannot move anything outside a signed order, past an order's amount, worse than an order's limit, to anyone but the two makers, or after a cancel, an expiry or a pause.

**Decisions for the owner.**

| # | Question | Proposed |
|---|---|---|
| O1 | Who decides the price between two limits | The operator, by the amounts it submits. Both limits hold. The alternative, always the older order's price, needs the executor to know which order rested, which it cannot |
| O2 | A fee to the venue | None in this version. A fee is a third transfer and a signed field; it can be added as a new order type later |
| O3 | Who may submit | `OPERATOR_ROLE`, as the other executors. Open to anyone would make the signed orders a public book; on this chain the desk matches |
| O4 | `Gated1155` series as a leg | Yes, from the start. It costs two flags and one branch for each transfer |
| O5 | A receiver other than the maker | No. See above |
| O6 | Vault shares against vault shares, or any two tokens | Allowed: an order names two tokens, and nothing says one is cash |

**Kept if.** A fill, both orders new, costs no more gas than a `dvp: gated cash` trade in the benchmark (185,329 on `main`); a batch of 100 fills costs less for each fill than that; an order fills in parts up to its amount and never past it; a fill worse than a signed limit reverts; shares of both vaults and a `Gated1155` series each settle against the cash token of E4; every existing benchmark row within the 2% bar. A fuzzed invariant, not Halmos, which cannot reason about a symbolic `mulDiv` here: over any sequence of fills of one order, the total given is at most `giveAmount` and the total received is at least the limit for the total given.

**Steps.** Interface and brief; tests first against a stub, shown failing; the executor; `Core` and `CoreParts` part `orderSettlement` with the profile's executor list; benchmark rows; planted bugs; the Halmos property; pages; gates; the port to `paris`.

**As built on `main` (2026-11-19).**

- **The contract.** `OrderSettlement` with `IOrderSettlement` (a new interface, id `0xb48f6d63`, two event topics, pinned; the freeze test failed on the unpinned id). 9,279 bytes. As designed, with the four notes of the review below.
- **Tests.** `OrderSettlement.t.sol`, 38 tests on real tokens behind the real credential registry, rule and hook; 36 of the first 37 failed against a stub. A fill in full and in parts; an order larger than its counterpart left open; a price between two limits and none outside them; rounding against the counterparty; all-or-nothing, a named taker, the window, a changed order; each degenerate fill; cancelling, two orders with one nonce, cancelling while paused; the roles, the pause and the recovery path; a maker the policy refuses, an amount above the balance in the pre-flight, a missing allowance, a token that keeps a fee, a token that calls back; a 4626's shares and a `Gated1155` series against cash; a batch and its failing index; a fuzz over sequences of fills of one order; amounts near 256 bits; the EIP-712 hash. Every refusal is asserted against `canFill` as well as `settle`.
- **Planted bugs.** The limit rounded down; the limit not checked; what an order filled not recorded; an order filled past its amount; the signature not checked; a cancelled order still filling; the named taker ignored; the received amount not checked; the second leg sent to its own maker; ids not compared when orders cross; all-or-nothing ignored; the deadline not checked; `settle` open to anyone; `settle` not paused: 1, 2, 8, 4, 1, 2, 1, 1, 18, 1, 1, 1, 1 and 1 tests fail.
- **Deployment.** Part and profile flag `orderSettlement`, built with the deployer as admin and handed over as the other two executors are: the operator gets `OPERATOR_ROLE`, the recovery timelock `RECOVERY_ROLE`, the timelock the admin. The post-deploy check covers its roles with the other executors', its code against the release, and a sample order's hash. A node test adds it to a running core and compares the hash of an order signed with viem.
- **Against the benchmark, and one number missed.**

| Flow | Calls | Slots written | Gas |
|---|---|---|---|
| dvp: gated cash, the bar | 22 | 6 | 185,367 |
| orders: one fill, both orders new | 28 | 6 | 191,072 |
| orders: 100 fills in one batch | 2,701 | 600 | 12,742,759 |

  A fill in a batch of a hundred costs 127,428 gas, 31% less than a DvP trade, and no existing row moved. A single first fill costs 3% more than a DvP trade, so "no more gas than a `dvp: gated cash` trade" is not met. The difference is one thing, measured: the check that an ERC-20 receiver's balance rose by exactly the amount, two balance reads for each leg. Without it the same fill costs 185,245 gas in 20 calls, under the bar. The check is kept as built, because it is what refuses a token that keeps part of a transfer and nothing else here would. **O7, decided on 2026-11-20:** the check stays and the 3% on a lone fill is accepted.
- **Gates.** `npx hardhat test`: 2300 passing (2097 solidity, 203 nodejs), before one test and one check were added and run on their own. Format, lint and typecheck clean, Slither 0 results, Halmos 25 of 25, `validate:upgrades` 8 of 8, `verify:reproducible` 35 contracts identical.
- **Pages.** A page for `OrderSettlement` and ten pages changed. The same change removes nine "at this commit" phrases left on the pages and corrects two sentences the cash profile had made false: the hook's page and the supply cap's page said no profile lists `SupplyCapRule`.
- **Not done.** The fuzzed property stands in for a Halmos one, as planned. A fill of a 7540's shares is not tested on its own; they are an ERC-20 as a 4626's are.
- **On `paris`.** Carried by cherry-pick. The executor uses this line's storage reentrancy guard, and its page says so; the brief keeps this line's deployment text. Here a DvP trade costs 196,101 gas, a lone first fill 201,590, which is 2.8% more, and a fill in a batch of a hundred 135,282, which is 31% less; no existing row moved. `npx hardhat test`: 2302 passing (2099 solidity, 203 nodejs). Format, lint and typecheck clean, Halmos 25 of 25, `validate:upgrades` 8 of 8, `verify:reproducible` 35 contracts identical. Slither raised one finding here that the other line's build does not, the balance read around a leg, which is the check itself; it is documented in the source on both lines, and Slither then reports 0 results.

**Review of this design (2026-11-19).** The owner passed on a review that answers O1 to O6 as proposed and adds four notes, each checked and right, and each now in the text above: 512-bit limit arithmetic; the degenerate fills refused up front; what a nonce cancels against what a hash fills; and the reasoned pre-flight for the stack's own tokens. It also points out why O1 is safe with O2 and O5 as they are: with no fee and no receiver but the makers, whatever lies between two limits goes to one of the two makers and never to the operator. On E7 the same review recommends the escrow; that choice is still the owner's.

### Decisions and review, 2026-11-19

The owner passed on a reviewer's answers and four notes the same day. The answers settle three questions; the notes were each checked against the code and are right, and the rows above carry them.

- **The bar:** the rule of step 0 stands: the named number met, and no other flow worse by more than 2% in gas or by one call.
- **A reused ticker:** no second deployer. A rolled instrument takes a new series symbol, or is a token id of a `Gated1155`.
- **Omnibus accounts:** stay in tier 3, for counsel.
- **Go-ahead:** step 0, then the first pass: E1, E2, and E3 with E13.
- **The notes:** the seizure in E7 (redesigned above); a gated cash token refusing one holder in E2; skipping one controller in E13 and pinning that the keeper only claims to the controller; `Gated1155` and `ExecutedOnlyRule` in E8; and a wrong reference in step 0, corrected.

### Decisions of 2026-11-20

The owner passed on a note on 2026-11-20 with three answers. The merges it also names wait for the owner's own word.

- **O7:** the received-amount check in `OrderSettlement` stays, and a lone first fill at 3% above its bar is accepted. Batches are the intended use and are 31% under it, and the check is what lets the contract take any ERC-20 and not only the stack's own.
- **The third pass is E14,** the control plane. Its design is below.
- **E7 is the escrow,** `LienVault`, so that no contract holds `AGENT_ROLE` on a token. Its design is below, with what the escrow costs, which the row above gave in one sentence and is more than that.

Both designs are for review. Nothing in them is built.

### E14 in detail: the control plane (design, 2026-11-20, nothing built)

No contract changes, so no interface is reopened and no benchmark row can move. What is built is TypeScript under `scripts/`, with viem and Node and no new dependency.

**What exists.** The post-deploy check is `assertHandedOver` in `test/nodejs/fixtures.ts`, about 400 lines. It takes a stack that a test deployed in the same process: contract objects, the profile, the parameters and the test wallets, and it stops at the first failed assertion. Nothing runs it against a deployed network. No keeper and no reconciler exists.

**1. The check, against a live network.**

- The check moves out of the fixtures into `scripts/lib/check.ts`, unchanged in what it asserts. It collects every failure and returns the list, where today it throws on the first: a person reading a failed check on a live stack needs all of them at once.
- `assertHandedOver` stays in the fixtures as a wrapper that fails a test when the list is not empty, so every node test that calls it today runs the same code the command runs. No assertion is dropped or weakened in the move; the review checks that by the planted faults the node tests already carry (a stack that lost its signed exit, a role on a single key, a broken class), which must still fail.
- A loader builds the check's input for a live stack: the addresses from the Ignition deployment folder, the profile by name, the parameters file the deployment used, and the named accounts from those parameters. The check reads the test wallets for addresses only, so the loader needs no key.
- The command: `npm run check -- --network <name> --deployment <id> --profile <name> --parameters <file>`. Read-only. It prints each failure on a line and exits 0 when there is none, 1 when there is any, and 2 when its input cannot be used (no such deployment, a profile that does not match what is deployed).

**2. Keepers.** Each is one file under `scripts/keepers/` with one function that reads the chain and returns the calls to send, and a thin command that sends them. Each runs once and exits; what schedules it is the operator's. Each reads before it sends, so a second run right after the first sends nothing, and two copies running at once waste a transaction and break nothing.

| Keeper | Sends | When | Who may call it on-chain |
|---|---|---|---|
| `rekey` | `Fund.rekey(account)` | an account holds a class and `countedKeyOf(account)` is not the registry's `entityKeyOf(account)`; candidates come from `CredentialSet` since the last run | anyone |
| `dealing` | `NavDesk.closePeriod()`, `NavDesk.execute()` | `periodLength` has passed; a proposal is accepted and its cooldown is over | anyone |
| `fees` | `Gated4626Vault.collectFees()` | fees are owed and idle money can pay some | anyone |
| `payout` | `Distributor.claimBatch(id, …)` in chunks | a distribution is approved, from the list its root was built from, leaving out rows already claimed | anyone |
| `claims` | `SignedExit.claimFor(vault, controllers)` in chunks | after `PeriodSettled`, for controllers with something claimable that made the contract their operator | anyone |

  Every one of these functions is open to anyone, checked in the interfaces. So the keeper's key holds no role on anything, and the most a stolen one can do is send these same calls. That is stated in the pages and pinned in each keeper's test. The key is read through `hardhat-keystore` (rule 8).

  No keeper proposes or accepts a price, approves a distribution, or writes a credential: those are people, two of them where the contract asks for two.

  Chunk sizes are parameters. From the benchmark, 100 rows of `claimBatch` cost 4.9 million gas and ten controllers of `claimFor` 0.66 million, so the defaults are 100 and 50; the chain's block limit is the operator's.

**3. The reconciler.** One read-only command, `npm run reconcile`, that prints what it finds and exits non-zero on any mismatch:

- each cash token's `totalSupply()` against the ledger's figure, read from a JSON file the operator's ledger writes (`{ token: supply }`); the ledger itself is outside this repository;
- each fund: `holderCount()` at or below `holderCap()`, and `firstBrokenClass()` the zero address;
- each 7540: the vault's balance of its asset at least pending deposits plus claimable redemption cash, which is the audit `settlePeriod` runs, read between settlements;
- each distributor: a distribution past its expiry with money still in it;
- when E7 exists: each `LienVault`'s balance of a token at least what its liens book.

**Tests.** Node tests on a deployed profile, one for each keeper: the state that calls for it, one run, the one effect; the list of transactions it sent holds only the selectors and targets of its row; a second run sends nothing. The reconciler: a clean stack reads clean, and each mismatch is planted and named. The check: the loader's object passes on a stack deployed by Ignition, and one test starts a local node, deploys, and runs the command as a process against an intact stack and a broken one, for the exit codes. If that last test adds more than a minute to the suite it is run in CI only.

**Pages.** `deployment.html` gains the command where it describes the post-deploy check, and a new page describes the keepers and the reconciler: what each sends, that none holds a role, and what happens when one stops (nothing is lost: every call can be sent late, and by anyone).

**Decisions for the owner.**

| # | Question | Proposed |
|---|---|---|
| K1 | A keeper that runs once, or a process that stays up | Once. A scheduler is the operator's, and a process that stays up needs supervision this repository should not own |
| K2 | How the ledger's figure arrives | A JSON file. A connector to a ledger is not in this repository |
| K3 | Dependencies | None new: viem and Node |
| K4 | Where a failure goes | Standard output and the exit code. Alerting is the operator's |

**Kept if.** The check runs against a deployed stack from the command line and fails on each fault the node tests plant; each keeper is shown doing its one job, sending nothing else, and nothing on a second run; no assertion of today's check is lost; every gate stays green. No benchmark row: no contract changes.

**Steps.** The check moved and returning a list, with the node tests unchanged and passing; the loader and the command; the five keepers, each test first; the reconciler; pages; gates; the port to `paris`, which should be a plain cherry-pick as no contract differs.

### E7 in detail: `LienVault`, the escrow (design, 2026-11-20, nothing built)

The row for E7 above left two designs. The owner's note of 2026-11-20 takes the escrow. This is that design, and it starts with what the choice costs, because three of the costs were not in the row.

**What it is.** An immutable contract with no role table. A holder moves tokens into it under a lien that names a beneficiary. While they are there, only the beneficiary decides: it releases them back to the holder, or takes them. The vault holds no role on any token and is installed nowhere, so it is not attested. On each token it is an ordinary holder and needs a credential on that token's policy, as a vault that holds gated cash does. No rule, no reason code, no change to a token, and no interface reopened: one new interface, `ILienVault`.

**What the escrow gives over the scoped agent.**

- No `AGENT_ROLE` on a contract. A fault in the lego can lose only what was pledged into it, never a holder's unpledged tokens.
- A transfer costs nothing more: no rule is listed, so no existing flow can move.
- `maxRedeem` and every pre-flight are exact with no change: pledged tokens are not in the holder's balance.
- A pledge cannot be undone by the holder, by construction and not by a rule's bookkeeping.

**What it costs. Each is real, and none is fixed by this design alone.**

1. **The vault is the holder of record.** A distribution's list is built off-chain from balances at the record date, so its builder has to read the vault's liens and credit each pledgor, or the vault would be paid. The contract gives the view for that; the look-through itself is a step in the operator's process and is nowhere enforced on-chain.
2. **A fund's count.** `FundHoldersRule` sees the vault as an account. If the fund exempts it, as it must for the vault not to take a slot, a holder that pledges its whole position leaves the count while it still owns the position, and a new investor can take its place; when the lien is released at a full fund, the holder is a new investor and the release is refused with `MAX_HOLDERS` until a slot is free. If the fund does not exempt it, every pledgor together counts once. Either way the count on-chain is of holders of record and can be below the number of owners. The scoped agent has no such gap, because pledged tokens never leave the holder. This is the same question as an omnibus account (E9), and for a fund with a statutory cap it is counsel's. Proposed: exempt the vault, state the limit, and have the reconciler report every counted fund's pledgors that hold no class outside the vault, so the operator sees the true number.
3. **A locked holder cannot pledge.** A pledge is a plain transfer, and `HolderRestrictionRule` refuses one from a holder inside its lockup. Under the scoped agent a locked holder could pledge, since nothing moves. A lockup is when a holder is most likely to want to borrow against a position.
4. **A token that takes only signed intents cannot be pledged.** `ExecutedOnlyRule` refuses the plain transfer in and out. Not supported in this version.
5. **Enforcement reaches a pooled balance.** The vault's balance of a token is every pledgor's together, as a 7540's escrow is. The token's `forcedTransfer` out of the vault, or a frozen amount set on it, cannot name a pledgor, and the vault cannot stop the token's agent as the 7540 does for its own escrow. So the vault has its own entry point for that, below, and the agent's runbook says to use it. A forced transfer straight out of the vault would leave liens the balance no longer covers; the reconciler's last line is the check for that.
6. **A minimum position.** The vault has to be exempt from `MinPositionRule` on each token, as any pooling account. A pledge that would leave the holder with dust is refused by the rule, correctly. A lien smaller than the minimum cannot be seized by a beneficiary that holds nothing, which nobody can know when the lien is made.

**The contract.**

| Function | Who | What |
|---|---|---|
| `pledge(token, amount, beneficiary)` | the holder | Pulls `amount` under the holder's allowance, checks the vault's balance rose by exactly that, opens a lien and returns its id |
| `increase(lienId, amount)` | the lien's pledgor | Adds to it, the same way |
| `release(lienId, amount)` | the beneficiary | Sends `amount` back to the pledgor, a plain transfer the token's policy judges |
| `seize(lienId, amount)` | the beneficiary | Sends `amount` to the beneficiary, a plain transfer the token's policy judges |
| `assign(lienId, newBeneficiary)` | the beneficiary | Hands the lien to another account |
| `recover(lienId, to)` | the token's `AGENT_ROLE`, asked at call time | Sends what the lien holds to `to` and closes it: the enforcement path for one pledgor's tokens |
| `lienOf(lienId)`, `pledgedOf(token, pledgor)`, `totalPledged(token)` | views | For the list builder, the reconciler and a lender |

- A lien is `{ token, pledgor, beneficiary, amount }` under an id from a counter. A holder can have many, to one lender or to several; each is touched only by its own beneficiary.
- **Seizing needs nothing but the beneficiary's call.** A default is a fact off-chain, and the vault cannot judge it. The holder trusts the beneficiary with the pledged amount and no more, which is what a pledge with control is. A date after which seizure opens would say nothing about a default.
- **Nothing here is forced.** `release` and `seize` are plain transfers, so the pause, a freeze, a credential and the minimum all apply to the receiver. A beneficiary the policy no longer admits cannot seize; `assign` is its way out, to an account that is admitted. A pledgor the policy no longer admits cannot be released to; the tokens stay until it is admitted again or the agent recovers them.
- **`recover` asks the token** whether the caller holds its `AGENT_ROLE`, as the legos ask the vault. For a token with no such role the call fails, so the function does nothing there. It moves by a plain transfer too, so `to` passes the policy.
- **ERC-20 only in this version.** A `Gated1155` series as collateral needs the receiver callbacks and an id in the lien; it is the same contract with one more branch and can follow.
- A reentrancy guard on every function that moves tokens. No pause of its own: the token's pause already stops every movement in and out.
- No signed path. On this chain a wallet's own transaction costs nothing, so the holder sends an `approve` to the token and then `pledge` itself.

**Decisions for the owner.**

| # | Question | Proposed |
|---|---|---|
| L1 | The fund's count (cost 2) | Exempt the vault, state the limit, report it in the reconciler. To confirm with counsel before a fund with a statutory cap lists the vault |
| L2 | A locked holder (cost 3) | Accept: it cannot pledge. If that is not acceptable, the escrow is the wrong design for that product and the scoped agent is the one that works |
| L3 | Who may seize | The beneficiary alone, at any time |
| L4 | `assign` | Yes |
| L5 | `Gated1155` series | Later |
| L6 | One vault for the core, or one for each token | One for the core, as `SignedEntry`: a part `lienVault` and a profile flag |

**Tests, written first.** On real tokens behind the real credential registry, rules and hook: two lenders with liens on one holder, neither able to touch the other's; the holder unable to move, redeem or reclaim pledged tokens; release and seizure in parts and never past the amount; a payment from the holder to its lender leaving the lien as it was; each caller that is not the one named, refused; a beneficiary the policy refuses unable to seize, and able after `assign`; a release to a frozen pledgor refused and the tokens kept; `recover` by the agent, by anyone else, and on a token with no roles; a token that keeps a fee refused at `pledge`; a token that calls back; 4626 and 7540 shares pledged, with `maxRedeem` exact; a fund class with the vault exempt, showing cost 2 as it is: the count falls on a full pledge and a release at a full fund is refused; a locked holder refused, showing cost 3. An invariant: for every token, the vault's balance is at least `totalPledged(token)`, and `totalPledged` is the sum of its liens, over any sequence of calls. That invariant is small enough for a Halmos property as well.

**Kept if.** Two lenders hold liens on one holder and neither can touch the other's; the holder cannot move pledged tokens and cannot stop a seizure, and can move the rest; a payment from the holder to its lender leaves the lien as it was; no existing benchmark row moves by a single gas, since no token and no rule changes; three rows are added as a base: a pledge, a release and a seizure.

**Steps.** The owner's answers to L1 to L6; interface and brief; tests first against a stub, shown failing; the contract; the part and the profile flag, with the post-deploy check; benchmark rows; planted bugs; the Halmos property; the reconciler's line; pages; gates; the port to `paris`.

### The third pass, as built on `main` (2026-11-20): E14, the control plane

The owner approved it on 2026-11-20 ("Yes, build E14"). No contract changed: it is TypeScript under `scripts/`, with viem and Node and no new dependency.

- **The check.** `handoverFailures` in `scripts/lib/check.ts` is the fixture's check, moved with every assertion as it was. It now runs in parts and returns a line for each part that failed. The fixture's `assertHandedOver` is a wrapper that fails a test unless the list is empty, so the 43 places the node tests call it, the planted faults among them, run the code the command runs; all 203 node tests passed unchanged after the move.
- **Different from the design, three things.**
  1. **A part names its first fault, not every fault.** Inside a part the assertions still stop at the first, because later lines read what earlier ones established. Two faults in two parts are both named; two in one part, the first. If the recovery timelock is not the timelock's code the check stops there, as before.
  2. **A stack file, not Ignition's journal.** The journal names its entries after contracts (`Core_full#GovernanceTimelock`), not after the keys the modules return and the later modules take. The operator already carries those keys from stage to stage as parameters, so the command reads one JSON file of them: the profile's name, the named accounts, the core, the funds, the products, the legos and the parameters.
  3. **Settings in the environment, not flags.** `hardhat run` passes a script no arguments of its own, and the modules already take `PROFILE`, `PRODUCT` and `FUND` this way. So `STACK=stack.json npm run check -- --network <name>`, and `JSON=1` for the JSON output the review asked for.
- **The commands.** `npm run check`, `npm run keeper` (`KEEPER=rekey|dealing|fees|payout|claims`) and `npm run reconcile`. Exit codes: 0, 1 when the stack is not as it should be, 2 on input that cannot be used. A keeper exits 0 whatever it sent.
- **Keepers.** One file each under `scripts/keepers/`, a function that reads the chain and returns the calls that are due. The runner tries each call without sending it, sends those that would succeed and names the rest. `rekey` and `claims` read logs in ranges of 5,000 blocks from `FROM_BLOCK`, as the review asked. `payout` and `claims` try each row or controller alone first, so one the contract would pass over never reaches a transaction and a second run does not send it again.
- **The reconciler.** As designed, with the review's two lines for a 4626 with a portfolio. **One line is weaker than designed:** a 7540 has no view of what it owes on settled redemptions not yet claimed, so the reconciler compares the vault's balance with the deposits waiting for a price and no more. Reading the rest needs a view on the vault, which is a contract change and was not made.
- **Tests.** `test/nodejs/control.test.ts`, 12 tests, all failing against stubs first ("not built"). The check passes from a stack file and as a command, names faults in three different parts at once, and exits 2 on nine kinds of unusable input. Each keeper: the state that calls for it, the one effect, the transactions its account sent read back from the blocks (targets and selectors), and nothing on a second run. The reconciler: a clean stack, a wrong supply, a fund above its cap, an expired distribution with money in it and the same one after a sweep.
- **Run as processes.** Against a local node over HTTP, with the demo stack deployed on it: `npm run check` printed that the stack is as its profile says and exited 0; with a wrong operations account it named the fault and exited 1, in prose and as JSON; with a missing file it exited 2; the reconciler and two keepers ran and exited 0. Done by hand, once; no test starts a node.
- **Planted faults,** thirteen, each failing at least one test: a part that swallows its failure; an address with no code accepted; a rekey for a key that did not move, and for an account that holds no class; an execution tried inside the cooldown; a close tried over a closed period; fees collected when none is owed; a paid row sent again; a refused row sent anyway; a claim tried for a controller that did not allow it; a cap read one too high; a swept distribution still reported; a failed check exiting 0. Three of them first passed, because the runner's own try caught what the keeper should not have proposed; the tests now assert that a run leaves nothing out when nothing is due.
- **Not planted, so not shown by a test:** a broken class, a 7540 short of its pending deposits, an exit-only vault and a stale price in the reconciler. Each is one comparison of a view; the clean case of each runs.
- **Pages.** The deployment page describes the command, the stack file and the exit codes, and has a new section for the keepers and the reconciler, with the Markdown copy. It is a section and not a new page: a new top-level page would change the navigation of all 47. The new section was not looked at in a browser.
- **Against the benchmark.** No row: no contract changed.
- **Gates.** `npx hardhat test`: 2313 passing (2098 solidity, 215 nodejs). Typecheck clean. Slither, Halmos, upgrade safety and the reproducible build were not rerun locally: no Solidity file changed.
- **On this line.** The port is the same two commits, with one conflict in the brief, resolved by keeping this line's wording and adding the sentence. `npx hardhat test`: 2314 passing (2099 solidity, 215 nodejs). Typecheck clean. The planted faults and the run against a local node were done on `main` only; the scripts are the same files.
- **Not done.** No CI job runs the check against a live chain. A keeper for `accrue()` on a 4626, so fees are collected only once something has counted them.

### Review of both designs, 2026-11-20

The owner passed on a review of the two designs the same day. It answers K1 to K4 and L1 to L6 as proposed, and adds five notes. Each was checked against the code.

- **E14, three additions, all built:** log queries in ranges with a first block, because a node may refuse a wide `eth_getLogs`; JSON output on the check and the reconciler; and `exitOnly()` and the portfolio's `priceFresh()` in the reconciler for a 4626 with a portfolio. One correction to the note: `priceFresh()` is the portfolio's function and not the vault's, so the reconciler reads it there.
- **E7, two additions, for when it is built:**
  1. Every function that changes a lien refuses a zero address and a zero amount: `pledge`, `increase`, `release`, `seize`, `assign` and `recover`. A zero `newBeneficiary` in `assign` would leave a lien nobody can release or seize, so that one matters most.
  2. `recover` moves by a plain transfer and not a forced one, as the vault holds no `AGENT_ROLE`. So it needs the token unpaused and a receiver the policy admits. The review says it works when the pledgor or the beneficiary is frozen or blocked: that is right, because neither is a party to that transfer, the vault sends and `to` receives. To state in the interface and the page.
- **L2, a locked holder.** Accepted: it cannot pledge. The review gives a legal reason, that a lockup restricts a seizure anyway. That is a question for counsel and is not relied on here; the reason recorded is the one in the design, no `AGENT_ROLE` on a contract.
- **Order.** E14 now, then E6 (master and feeder, test first), then E7.

### Review of the control plane as built, 2026-11-20

The owner passed on a second review, of the code in the two pull requests. Each finding was checked against the code; all three hold, and each is fixed with a test written first. No contract changed.

- **A, `FROM_BLOCK` as a moving cursor.** The page told an operator to pass the block the last run stopped at. For `claims` that loses a controller for good: a request filed before the cursor and settled after it is never read again. The reconciler had the same fault for distributions proposed before it. Fixed two ways. The reconciler reads no logs now: a distributor numbers its distributions from 1 and none has an empty root, so it reads them one by one. `claims` has no such view to read, so the code and the page say what `FROM_BLOCK` may be: fixed at the oldest 7540's first block for `claims`; for `rekey`, moved forward only past a run that left nothing out. `LOG_CHUNK` is the answer to a node that refuses a wide range.
- **B, a stack file that leaves things out.** A file with no `funds`, no credential registry or no products made the check skip those parts and exit 0, and a file with some of them missing failed on a missing value with a message nobody could act on. `loadStack` now refuses, with exit 2, a file that leaves out what a placed product needs: a rule it lists, an executor it names, its fund, the registry its credential rule reads, a class of a listed fund. A product not placed yet is still allowed, as a core is checked before its products exist; the command names those products (`unplaced`), and does not print that the stack is as its profile says. Not taken from the review: refusing a file with no products.
- **C, lines with no failing test, and proofs.** The four reconciler lines the build left unplanted now each have a test in which the line is reported: a class that dropped its fund's rule, a 7540 short of its waiting deposits, a stale price, an exit-only vault. All four passed as written, so the lines were right and untested. A payout list whose proof is not a list of 32-byte words is refused with exit 2.
- **Kept as they are, and now stated on the page:** a keeper exits 0 when it left calls out, so its watcher reads `skipped`; a payout batch is tried whole, so a list that sums above the distribution's total leaves a batch out; the 7540 line counts waiting deposits only.
- **Tests.** `control.test.ts` has 15 tests, from 12. Five of the new assertions failed before the fixes: the JSON's new fields twice, the incomplete file, the core alone, the proof.
- **Gates.** `npx hardhat test`: 2317 passing (2099 solidity, 218 nodejs) on this line. Typecheck clean; 47 pages, no problems.

### E6, the test first (2026-11-20)

`contracts/vaults/MasterFeeder.t.sol` builds the structure from the parts that exist and changes no contract: a master `Gated4626Vault` whose portfolio invests in an outside vault, and two classes, each a `Gated4626Vault` whose portfolio holds one `ERC4626Adapter` into the master. One registry, one hook, one `CredentialRule`; the master admits `Quals.FUND` only, class A anyone identified, class B professionals. 16 tests.

**What holds, with no code:**

- **One place.** After the allocator's calls every unit sits in the outside vault. The classes' adapters are the master's only holders, in proportion to what each class put in.
- **In proportion.** A gain in the master reaches both prices by the same ratio, and the classes together never count more than the master. A loss reaches both at once. A fall of more than half closes the master and each class, and holders still leave.
- **Own fee, own policy.** Each class charges its own `FeeModel` (1% of the value on one, 20% of the gain on the other) and neither moves the other's price. The master charges nothing. Each class admits only its own investors, and no investor can enter the master.
- **Leaving.** A holder redeems from a class in one call, through the master to the outside vault. A fuzzed round trip through both levels never profits.

**What a deployment must do, which the test pins:**

- **Two credentials on the master for each class.** The adapter holds the master's shares, so the master's policy must admit it. The adapter withdraws to its portfolio, a receiver other than the owner, so §7's third-party check judges the portfolio too. Without the second, a class can invest and cannot leave, and its `maxRedeem` does not say so.
- **Fees wait for the allocator.** A class keeps no idle money, so `collectFees()` pays nothing until the allocator deallocates the amount from the master.
- **Count a class as often as the master.** The limit on counted gains grows from the last count without compounding. With equal limits, a class counted less often than the master trails it by the compounding (3,600 against 3,630 after two years at 10% in the test) until the gain is all counted. It never runs ahead. An `accrue()` keeper, already listed as not done under E14, closes it.

**The gap the test found.** While the outside vault cannot be read, the master holds its last price and stops dealing. Its `previewRedeem` still answers, so the class's adapter reads as fresh, and the class goes on dealing at a price the master itself will not deal at. Money that arrives stays idle in the class, and idle money is paid out. In `test_WhileTheMasterCannotPriceAClassStillDeals` the outside vault loses half and then cannot be read: a newcomer deposits 1,000 at the old price, an earlier holder redeems 1,000 whole from that money, and when the price returns the newcomer holds 500. On the master alone neither call would have gone through. `ERC4626Adapter` is right as it is for an outside vault: it cannot know that a target holds a price. The same holds for any target that can hold its price, not only a master of ours.

The candidate named in the row, a master that deals in periods, was not tested: an `ERC4626Adapter` deposits and withdraws in one call and a 7540 has neither. A feeder over a 7540 master would hold a request, which is a reported position, and an instant class cannot take one.

**Questions for the owner:**

| # | Question | Proposed |
|---|---|---|
| M1 | How does a class stop when its master cannot price? | A new adapter, `Gated4626Adapter`: `ERC4626Adapter` whose `fresh()` is also false while the target's portfolio says `priceFresh()` is false. It reads `portfolio()` on the target and `priceFresh()` on that, both existing views, so it reopens no interface (it implements `IERC4626Adapter`). The class then holds its price and stops dealing exactly as the master does, and a guardian needs to do nothing. The alternative is operational: the guardian pauses each class when the reconciler reports the master's price stale. That depends on someone acting in time, and the harm is done in one block |
| M2 | Does the limit's lag need code? | No. Count the classes with the master, by the `accrue()` keeper. Raising a class's limit above the master's would also close it and weakens the class's own protection against a donation |
| M3 | A profile and pages now, or after M1? | After M1, so the profile deploys the adapter it should and the pages describe one structure. The profile is `master-feeder`: one master with a portfolio, two classes, the credentials above for each class, a `FeeModel` per class |

**If M1 is yes, the steps:** tests first (`Gated4626Adapter.t.sol`: fresh follows the target's portfolio, a target with no portfolio reads as `ERC4626Adapter` does, a target that cannot be asked is not fresh; and the gap test above turned round, the class stopping with the master), then the contract, its size line, the `Legos` module's choice of adapter, the profile, the pages with their Markdown copies, and the port to `paris`.

**Gates.** `npx hardhat test`: 2329 passing (2114 solidity, 215 nodejs). No contract changed, so Slither, Halmos, upgrade safety and the reproducible build were not rerun.

### Interfaces this would reopen

`IDistributor` (E2). New interfaces only for E3, E7 (`ILienVault`; with the escrow there is no rule and no reason code) and E8. E1, E4, E5, E6, E13 and E14 reopen none.

### What this plan does not claim

That the stack then runs a market at any given rate. The benchmark compares the stack with itself. Throughput and state growth over a year are measured on a Besu network; step 0 adds a local one for the `paris` build, and what it shows on a laptop is a ratio between two versions, not a production figure.

## Open questions for the owner
1. One stack per issuer, legos, and vaults that invest: no code waits on an answer. Counsel's view on P27 and the issuer's country belong to the legal work in step 5, and only a different view on P27 would reopen a contract.
2. Credential layer: none left. On 2026-10-30 the owner confirmed decisions 11, 12, 13, 15, 16 and 17 as built (17 at the measured +8,179 gas on a transfer). Decision 14 is moot, since `IdentityRule` was removed in the cleanup. Decisions 8 and 9 are recorded in the credential section's table.
3. Redemption gate and the second contract: built and landed in #24 and #25. Open from its review: dust in a fund everyone has left ends the performance fee. Fixed in #27; the pages at `bfb424e` describe it. What it leaves, dust left on purpose and the 4626's management fee on a small or low-decimal fund, is in `SECURITY.md`.
4. The NFT template: answered 2026-11-05, A, and built (the core split and `Gated721`); its pages landed in #36.
5. `setRules` tells the rules it adds: built on 2026-11-19 with R3 as written, no recount. Open: one sentence in `IComplianceHook`'s NatSpec for `setRules`, a frozen file.
6. Entities in the credential registry: built on 2026-11-19 without N10. Still open: whether a second live attester for one address is expected, which would change how an entity is scoped.
7. A review of both plans (2026-11-19) recommends: build both; keep R3 as written, with no recount; leave N10 out; put off the second attester. These are a reviewer's recommendations and decide nothing; items 5 and 6 stay the owner's.
8. The ecosystem plan (2026-11-19): step 0 and the first pass (E1, E2, E3 with E13) are approved. E7 is the escrow by the note of 2026-11-20 (item 11). Open: counsel's view on omnibus accounts (E9).
9. `OrderSettlement` (E8): built with O1 to O6 as proposed, and O7 decided on 2026-11-20: the received-amount check stays.
10. The control plane (E14): K1 to K4 answered as proposed on 2026-11-20, and built.
11. `LienVault` (E7), the escrow: L1 to L6 answered as proposed on 2026-11-20, with two additions recorded above. Not built; it follows E6. Still counsel's: L1, the count of a fund with a statutory cap that lists the vault.
12. Master and feeder (E6): the test is written and found one gap, a class that deals while its master cannot price. Open: M1 to M3 in "E6, the test first".
