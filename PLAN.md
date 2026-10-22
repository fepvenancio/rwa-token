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

## Open questions for the owner
1. None.
