# PLAN

Status: **Phase 1 interfaces FROZEN (2026-10-16). Imported stack integrated through partial Phases 2–4. Next: Phase 3 `IntentExecutor`, then the Phase 4 rules.**

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

### Open questions for the owner
1. **Push target.** `fepvenancio/rwa-token` is public; the code is proprietary (rule 15). Make it private before pushing, or push as-is?
