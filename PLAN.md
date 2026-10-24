# PLAN

Status: **v0.2.0 released (2026-10-18): review fixes M-1, M-2, M-3, L-2, L-3; L-4 and L-5 documented; L-1 accepted. Change-board page published.**

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
- **V2 (owner reversed, 2026-10-17): ESCROW.** `requestRedeem` *transfers* the shares to the vault, as a TRANSFER, so the lockup, frozen, identity and pause checks all apply. They are BURNed at fulfilment. Brief §7 stays as written. The vault address must be registered as a verified holder in the identity registry (a bank-controlled contract, normal practice in ERC-3643 deployments).
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

There is no `docs/` folder. The README has the security model and the deployment runbook. Nothing explains how the contracts connect, or follows a holder, an operator or the bank through a flow. The request: an architecture page, plus diagrams of the user flows, the roles, the money and how the protocol works, exact against the code.

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

## Review items, built before the first deployment (plan 2026-10-23; decisions made, S0 built, waits for review)

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
| RD7 | `MinPositionRule` | **Yes, zero means off.** The post-move balance of each non-zero side must be zero or at least the minimum, so no dust is left behind on either side. FORCED exempt; a holder's burn is checked. Ordered right after the identity rule and before the holder rules, so the counts only ever see real positions. This closes L-1 | Exempt, confirmed by the owner: the token itself (the 7540 escrow, without which a redeem request below the minimum would be refused) and accounts the token's admin lists. A new reason `BELOW_MIN_POSITION` |
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
| S3 | The rules: `HolderRestrictionRule`, `MinPositionRule`; `MaxHoldersRule` and `FundHoldersRule` adapted to the context. Gas probe re-run |
| S4 | The fund views; the Ignition modules and fixtures (shared hook deployment, the new `RULE_ORDER`, the post-deploy checks) |
| S5 | Docs, `SECURITY.md`, `README.md`, the brief (`CLAUDE.md` §1, §4, §5, §6 and the rule list), the pause runbook, the amendment to the draft ERC for RD2, `InterfaceFreeze` re-pinned, reproducibility |

### What this changes in frozen files

By step: S1 `IPolicyHook`, `IComplianceRule`, `IComplianceHook` and the semantics of `TransferContext.extra`; S2 `IPolicyGated` and the ERC-165 id of every template; S4 `IFund`. New files, built in S0: `IERC7943Fungible`, `ITemplated`, `IHolderRestrictionRule`, `IMinPositionRule`, and three appended reason codes in `Errors.sol`. `ILockupRule` goes in S3. Every implementation, hook and rule codehash changes, which is free before the first deployment. `InterfaceFreeze.t.sol` is re-pinned in each step's commit.

### S0 as built (2026-10-23, working tree, not committed)

The owner's S0 was: the specification, the interface edits and the re-pinned `InterfaceFreeze.t.sol`, one commit, tree green. All of it cannot be one green commit. Changing `IPolicyGated`, `IPolicyHook`, `IComplianceRule` and `IComplianceHook` breaks every contract and test that implements or calls them (`TransferContext` alone appears in 23 contract and test files, and the shared hook is a rewrite of `ComplianceHook`). Making that compile would pull S1 and S2 into S0. So S0 is built in the additive form, which stays green:

- The specification above, final.
- Four new interface files: `IERC7943Fungible` (the Final text), `ITemplated`, `IHolderRestrictionRule`, `IMinPositionRule`, with full NatSpec.
- Three appended reasons in `Errors.sol`: `BELOW_MIN_POSITION`, `SENDER_FROZEN`, `RECEIVER_FROZEN`.
- `InterfaceFreeze.t.sol` pins the four ids (`0x3edbb4c4`, `0x7aa77f29`, `0x3abb7c85`, `0x44ac9195`, computed with `cast sig`; the first is the standard's own and `type(IERC7943Fungible).interfaceId` reproduced it), the event topics and the three reasons.

Tests first: the pins were added before the files and the run failed to compile (`HHE902`, the import of `IERC7943Fungible.sol` could not be resolved), then passed once the files existed. `forge fmt --check` and `solhint` are clean. Both runners: 792 passing (707 Solidity, 85 TypeScript), unchanged, since the pins live in existing tests.

"Re-freeze" then means: the specification here is frozen for S1 to S5, and the new interface files are frozen by their pins. Each existing interface changes in one commit together with the code that implements it and its new pin.

### S1 as built (2026-10-24, working tree, not committed)

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

### Not in this plan

A `JurisdictionRule`, amount-level lockups, an ERC-3643 read adapter, ERC-1066 style reason codes, a recovery address for identity re-keying. The assessment calls them secondary, and none of them changes what the items above build.

## Open questions for the owner
1. DvP: decisions D1 to D8 are recorded in the DvP section (D8: Option B; D6 revised for the `IntentExecutor` refusal). I-1, E-1, E-2 and the refusal are built and wait for your review.
2. Nothing on `fund-layer` is pushed, and the DvP section is not committed. Push, or open a pull request, only when you say. The branch carries PR #2's commit `d3574df` until PR #2 merges.
