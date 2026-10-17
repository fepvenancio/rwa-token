# Security and audit preparation

Proprietary code (see [`LICENSE`](LICENSE)). Report suspected vulnerabilities privately to the repository owner,
Filipe Venancio; do not open public issues.

This file collects what an external auditor receives, so the audit scope is not reconstructed from git history. Each
item links to where it is maintained; this file only indexes and summarises.

## 1. Audit package

| Item | Where |
|---|---|
| Brief: architecture, rules, phase scope | [`CLAUDE.md`](CLAUDE.md) |
| Security model: roles, delays, invariants | [`README.md` → Security model](README.md#security-model) |
| Deployment runbook, including the council procedure | [`README.md` → Deployment runbook](README.md#deployment-runbook) |
| Deviations from the brief | [`README.md` → Deviations from the brief](README.md#deviations-from-the-brief) |
| Decision log, owner decisions, review validations | [`PLAN.md`](PLAN.md) |
| Static-analysis suppressions and their reasons | §4 below |
| Mutation-testing results | §5 below |
| Findings that contradict reasonable assumptions | §3 below |
| Reference build for the audited tag | GitHub release `release-build-<tag>.tar.gz` (from `.github/workflows/release.yml`): `manifest.json` plus build-info for in-scope sources only; no tests, mocks or OZ-rooted jobs |

**Audited revision:** a `v*` tag. Its reference build is reproducible from the source at that tag
(`npm ci && npm run verify:reproducible`) and must match the published archive.

## 2. Scope

In scope, all under `contracts/` (`.t.sol` files and `contracts/test/` are test code):

| Area | Contracts |
|---|---|
| Base | `base/PolicyGatedERC20Upgradeable` |
| Templates | `tokens/IntentToken`, `vaults/Gated4626Vault`, `vaults/Gated7540Vault` |
| Mixin | `mixins/IntentSettledUpgradeable` |
| Policy | `hooks/ComplianceHook`, `hooks/BaseRule`, `hooks/rules/{Identity,Lockup,SettlementWindow,MaxHolders}Rule` |
| Governance | `governance/PolicyRegistry`, `governance/GovernanceTimelock` (the main timelock: OZ `TimelockController` plus a revoke-`CANCELLER_ROLE`-only `RECOVERY_ROLE`) |
| Settlement | `intents/IntentExecutor` |
| Deployment | `deploy/ProxyDeployer`, `deploy/TokenProxy` |
| Interfaces | `interfaces/*` (frozen; ERC-165 ids, event topics and reason codes pinned by `contracts/test/InterfaceFreeze.t.sol`) |

Also in scope: `ignition/modules/{Components,Tokens,Activate,roles}.ts`, which carry the deployment order, role grants,
the hand-over to the timelock and each token's rule list (`RULE_ORDER`).

Out of scope: OpenZeppelin 5.6.1 (`@openzeppelin/contracts`, `-upgradeable`; `TimelockController` is used unmodified for the recovery timelock and as the base of `GovernanceTimelock`),
the external identity registry (`IIdentityRegistry` is an assumption about it), and test mocks.

Build: solc 0.8.30, `evmVersion: cancun`, optimizer 200 runs, no metadata hash, the same in Hardhat and forge.

## 3. Things that differ from what you might assume

1. **CREATE2 alone cannot place a token before its hook.** A hook binds to its token in an immutable (`TOKEN`), and a
   token is initialised with an attested hook. CREATE2 over `ERC1967Proxy(impl, initData)` would make the address
   depend on `initData`, which contains the hook, so it would be circular. `ProxyDeployer` instead CREATE2s
   `TokenProxy(impl, "")` with salt `keccak256(symbol)`, so the address depends only on the deployer, the symbol and the
   implementation. `deploy`:
   - is owner-only. The address does not cover the init data, so anyone else could otherwise occupy it with their own
     admin. Ownership moves to the timelock in `Activate`;
   - reverts *before* creating the proxy unless `hook.TOKEN()` is the predicted address;
   - initialises in the same transaction;
   - checks the installed hook and the symbol;
   - allows each symbol once.

   A reverted deploy leaves no proxy and does not use up the symbol. Tests: `contracts/deploy/ProxyDeployer.t.sol`,
   `test/nodejs/deployment.test.ts`.
2. **`TokenProxy` overrides `_unsafeAllowUninitialized()` to return true.** OZ 5.6's `ERC1967Proxy` refuses empty init
   data to prevent proxies left open for anyone to initialise first. The override is the extension point OZ documents
   for code that initialises another way. Here, `ProxyDeployer` initialises in the same transaction that creates the
   proxy, so no uninitialised `TokenProxy` of this system exists after any transaction. A `TokenProxy` deployed by any
   other route is not one of this system's tokens. Pinned by tests:
   - a failed `initialize` leaves no code at the address;
   - re-initialising a deployed token reverts.
3. **A hook's attestation covers its code and binding, not its rule set.**
   - `ADMIN`, `REGISTRY` and `TOKEN` are immutables inside the attested codehash; the ordered rule list lives in
     storage.
   - So the council attests *this hook for this token*: one attestation per token, not per hook type.
   - A twin with the same immutables but other rules shares that codehash and passes `ProxyDeployer`'s binding check.
   - Controls:
     - each rule is attested on its own and re-checked by the hook constructor and by `setRules`;
     - only the timelock can change the list or install another hook;
     - the runbook has the council read `rules()` and record the reviewed hook addresses;
     - the post-deploy check asserts every token runs the recorded hook and that `rules()` equals `RULE_ORDER`.
   - Test: a twin with only `MaxHoldersRule` is attested, `Activate` installs it, and the post-deploy check rejects it.

Further limits recorded during review:

- **`canExecute` cannot check signatures.** The frozen interface has no signature parameter. Integrators pre-flight a
  signature with `verifyTypedData` against the chain-reported ERC-5267 domain (`intents.test.ts`).
- **Pre-flight answers for the latest block; a write lands in the next one.** At a time boundary (lockup end, window
  close, intent deadline) they can differ by one second (`time.test.ts`).
- **7540 operators are full delegates** (review L-5). Per ERC-7540, an approved operator can create requests that pull
  the owner's assets or shares under any controller, not only claim. Owners should approve only custodians they would
  trust with the assets. Pinned by `test_WhenAnOperatorRequestsUnderItsOwnController_ItIsAFullDelegatePerErc7540`.
- **Dust cap griefing is accepted** (review L-1). Anyone can deposit 1 wei into the 4626 vault for a verified, empty
  receiver and take a holder slot, and 1 wei sent to an exiting holder breaks an exact-balance exit. Mitigation for
  now: the agent cleans up dust (forced transfer or burn) and monitoring watches slot usage. Planned: `MinPositionRule`,
  a per-token minimum, attested like the other rules. Requiring a verified caller on vault mints was rejected because
  it would break custodians depositing for clients.
- **The holder cap is a ratchet** (review L-4: prose corrected, behaviour unchanged). A full-balance move to a new
  holder passes only when `count <= cap`, and any other new holder only when `count < cap`. So above a lowered cap no
  new holder is admitted, net-zero swaps included, until the count comes back down. Existing holders can still
  transfer among themselves and exit. Pinned by
  `MaxHoldersRule.t.sol::test_WhenTheCountIsAboveALoweredCap_ANetZeroMoveIsStillRejected`.
- **Revoking an attestation does not affect live tokens.** Attestation is checked at install and upgrade time only.
  The guardian pauses while the timelock removes the component.
- **`totalAssets` of the 7540 vault is indicative** (the last fulfilment price); `preview*` revert, as ERC-7540
  requires.
- **solc prints 8 "unreachable code" warnings inside OZ's `ERC4626Upgradeable`.** The code after the 7540 vault's
  always-reverting `preview*` overrides is unreachable.

## 4. Static-analysis suppressions

Slither 0.11.5 runs as a CI gate with 0 findings. Project-wide exclusions (`slither.config.json`):

| Detector | Reason |
|---|---|
| `naming-convention` | Wonderland style uses `_camelCase` for parameters and internals |
| `assembly` | ERC-7201 storage accessors only |
| `timestamp` | Intent deadlines, lockups and settlement windows are time-based by specification |
| `calls-loop` | The hook calls at most 16 attested rules |

Inline suppressions (each carries its reason on the line above, in the source):

| Location | Detector | Reason |
|---|---|---|
| `PolicyGatedERC20Upgradeable` `forcedTransfer` | `reentrancy-events` | Event after `afterTransfer`; re-entry is blocked by `_update`'s guard and the hook is attested |
| `IntentSettledUpgradeable` `executeTransfer` | `reentrancy-events` | Same as above |
| `PolicyGatedERC20Upgradeable` `canTransfer`, `isUserAllowed` | `incorrect-equality` | Compares a reason code with a constant, not a balance |
| `MaxHoldersRule` `after_`, `check` | `incorrect-equality` | Exact equalities define a holder (post-move balance == amount ⇔ was 0) |
| `SettlementWindowRule` | `weak-prng` | Calendar arithmetic on the timestamp, not randomness |
| `ComplianceHook` `_setRules` | `uninitialized-local` | The after-mask starts at zero by design |
| `Gated7540Vault` | `missing-inheritance` | `IERC7575` re-declares inherited ERC-4626 functions; conformance pinned by ERC-165 id `0x2f0a18c5` |
| `Gated7540Vault` `requestDeposit` | `arbitrary-send-erc20` | `owner` is the caller or an approved operator. Fuzzed: a non-operator with a victim owner reverts and moves nothing. Removing the guard fails 2 tests |
| `ProxyDeployer` `deploy` | `unused-return` | `initialize` returns nothing; success is checked by the post-init assertions |
| `TokenProxy` `_unsafeAllowUninitialized` | `dead-code` | Called from `ERC1967Proxy`'s constructor; Slither does not trace it through the override |

Aderyn 0.6.8 (Cyfrin) runs as a second CI gate (`npm run aderyn`, 0 findings), from the sha256-pinned release binary
(§6). First run: 5 high and 13 low
detector types. One real fix: `ProxyDeployer`'s constructor parameter shadowed `Ownable._owner` and was renamed. Every
other finding is acknowledged below. Where a finding is a real property rather than a false positive, a test pins it.

Project-wide exclusions (`aderyn.toml`):

| Detector | Reason |
|---|---|
| `centralization-risk` | Privileged roles are the product; each is held by the timelock, guardian, council or issuer |
| `push-zero-opcode` | `evmVersion` is pinned to cancun; the target chain must support it (PUSH0, TSTORE, MCOPY) |
| `unspecific-solidity-pragma` | Brief rule 9 mandates `^0.8.28`; the exact compiler is pinned in config |
| `uninitialized-local-variable` | `for (uint256 _i; ...)` loop counters and zero-start bitmasks |
| `unused-import` | solhint already flags unused imports; Aderyn misses imports used only by `@inheritdoc` |

Inline acknowledgements (reason on the line above each `aderyn-ignore`):

| Detector | Where | Verdict | Evidence |
|---|---|---|---|
| `contract-locks-ether` (high) | `IntentToken`, `Gated4626Vault`, `Gated7540Vault`, `TokenProxy` | False positive: no path accepts ETH. There is no `receive` or payable function, `upgradeToAndCall` with empty data rejects value (`ERC1967NonPayable`), and with data the value is delegated into a non-payable function | `IntentTokenIntegration_Ether`, `Gated4626VaultUnit_Ether`, `Gated7540VaultUnit_Ether` |
| `reentrancy-state-change` (high) | `LockupRule`, `SettlementWindowRule`, `MaxHoldersRule` | False positive: the token is called through view interfaces, which compile to STATICCALL, so nothing the token does can change any state | `*Unit_TokenCallsAreStatic`: a token whose reads write makes every rule entry point revert, while a direct call to it succeeds (control) |
| `arbitrary-transfer-from` (high) | `Gated7540Vault.requestDeposit` | Same as Slither's `arbitrary-send-erc20` (§4 above) | Fuzzed victim-owner test; removing the guard fails 2 tests |
| `abi-encode-packed-hash-collision` (high) | `ProxyDeployer._initCodeHash` | False positive: only the second operand varies; the first is fixed creation code | Fuzzed `predict` formula test; off-chain CREATE2 test |
| `storage-array-memory-edit` (high) | `SettlementWindowRule.check`, `isOpen` | False positive: a read-only copy of a storage struct into memory | Window tests |
| `unused-state-variable` | `Gated7540Vault` ERC-7201 location | False positive: read in assembly | `Gated7540VaultUnit_Storage`: the formula equals the constant and the slot holds custody and `lastPrice` |
| `unchecked-return` | `_grantRole` in constructors and initialisers; `Address.functionCall` in `ProxyDeployer` | `_grantRole` returns false only if the role is already held; `initialize` returns nothing | Role and deploy tests |
| `costly-loop`, `require-revert-in-loop` | `ComplianceHook._setRules`, `IntentExecutor.executeBatch` | By design: at most 16 rules, and invalid rules must fail closed; batches are atomic | Hook and batch tests |
| `literal-instead-of-constant` | calendar arithmetic; `10 ** decimals()` | Calendar constants; `decimals()` is read at runtime | Window and vault tests |
| `empty-block`, `modifier-used-only-once` | `BaseRule.after_`, `__IntentSettled_init`, `onlyAdmin` | By design | n/a |

solhint (Wonderland config, `--max-warnings 0`):
- `style-guide-casing` is disabled on getters of `UPPER_SNAKE` constants and immutables and on OZ-style `__X_init`
  functions;
- `no-unused-vars` is disabled on imports used only by `@inheritdoc`;
- `private-vars-leading-underscore` is disabled in `Errors.sol`, where reason codes are public constants read as
  `Reasons.X`.

## 5. Mutation-testing results

Each row is a bug deliberately planted, the run that caught it, then restored from git.

| Area | Planted bug | Caught by |
|---|---|---|
| Halmos (proxied `IntentToken`) | nonce not consumed; cancel not recorded; frozen check skipped; burn not releasing frozen | the matching symbolic property, each |
| Executor | batch made best-effort | 3 tests |
| `MaxHoldersRule` | exit decrement dropped; self-transfer skip dropped; exemption ignored on decrement | invariant (real token, 4 actors) and unit tests |
| `Gated4626Vault` | `maxRedeem` ignores frozen; `maxWithdraw` rounds up; `decimalsOffset` = 0 | 3 tests; rounding test; inflation test (victim-loss bound) |
| `Gated7540Vault` | withdraw shares rounded down; mint assets rounded down; reject keeps pending; recovery keeps pending; operator guard removed | 1+ tests each; invariant `escrow == Σ pending` |
| Phase 6 (TS) | executor hand-over skipped; `canExecute` skips the hook; NAV price rounds up; deadline exclusive | 46 / 8 / 1 / 1 failing |
| `ProxyDeployer` | no hook-binding check; no salt check | unit test + Ignition tamper test; unit test |
| Ignition `Activate` | UPGRADER to an ops account; deployer keeps timelock admin; deployer keeps `ProxyDeployer` ownership; hooks built with rules reversed | 54 / 54 / 55 / 55 failing |
| upgrades-core | upgrade-unsafe state initialiser | `validate` FAILED |
| Aderyn gate | one inline suppression removed | `npm run aderyn` fails (1 high) |
| 7540 invariant handler | an action silently turned into a no-op | `afterInvariant` fails (every action must execute in every run) |
| `Gated7540Vault` access | controller/operator check removed from `redeem`, `withdraw`, `_claimMint`, `_claimDeposit`; `FULFILLER_ROLE` removed from `fulfillRedeem`, `rejectRedeemRequest`, `fulfillDeposit`, `rejectDepositRequest`; `whenNotPaused` removed from `withdraw` | 1 to 2 tests each (`Gated7540VaultUnit_ClaimAccess` and others). Before the 2026-10-17 review, 6 of these 9 survived |
| `Gated7540Vault.requestDeposit` | eligibility checked on the owner instead of the controller | `test_WhenAVerifiedOwnerRequestsForAnUnverifiedController_ItIsRefused`, the only test where owner differs from controller |
| Base transient context | kind slot not cleared after a movement | 3 tests (forced-then-plain, executed-then-plain, and others) |
| `Gated7540Vault` escrow (L-2) | `rejectRedeemRequest` or `recoverRedeemRequest` stops releasing frozen escrow | 1 test each (`Gated7540VaultUnit_FrozenEscrow`) |
| `Gated7540Vault` price (L-3) | the minimum price of 1 removed | 3 tests (`Gated7540VaultUnit_ZeroPrice` and the fulfilment fuzz) |
| `Gated7540Vault` claims (M-3) | deposit-claim, mint-claim, redeem or withdraw eligibility check removed; `maxRedeem` back to pause-only; `recoverClaimable` without the recipient check; enforcement mint downgraded to a plain MINT; payout probe with amount 1 | 1 to 11 tests each (`Gated7540VaultIntegration_Claimable`). The amount-1 probe breaks 11, since it would block payouts to controllers holding no shares |
| `Gated7540Vault` reject (M-2) | rejected shares returned as FORCED again (the old R2) | 5 tests, including the steering attack at a full cap, the paused reject and the frozen escrow |
| Recovery timelock (M-1) | base or executor `revokeRole` lets RECOVERY_ROLE revoke any role, or not the guardian; recovery cannot `unpause`; `GovernanceTimelock` lets it revoke any role, or not CANCELLER | 1 to 2 tests each (`PolicyGatedUnit_Recovery`, `IntentExecutorUnit_Recovery`, `GovernanceTimelockUnitTest`) |
| Recovery deployment (M-1) | `Activate` skips the executor's RECOVERY_ROLE, or leaves governance as a recovery-timelock canceller | The hand-over check, which pins the recovery timelock's exact role set and its lack of cancellers (59 TS tests fail) |
| Base enforcement | `forcedTransfer` keeps frozen tokens | `invariant_FrozenNeverExceedsBalance` and 2 unit tests. With the old no-op handler, the invariant missed it |
| Base transient context | ref slot not cleared | Not killable: an equivalent mutant. The ref is read only when the kind slot is set, and every movement that sets the kind rewrites the ref first |
| Reproducibility | metadata hash re-enabled | `verify:reproducible`: every contract differs across jobs |

## 6. Toolchain supply chain

Everything CI fetches at run time is pinned, and verified wherever the distribution allows:

| Component | Pin | Verification |
|---|---|---|
| GitHub Actions (`checkout`, `setup-node`, `setup-python`) | Full commit SHA, release tag in a comment | Git object identity |
| Node, Python | Exact versions (24.21.0, 3.12.15) | Fetched by the SHA-pinned setup actions |
| npm packages | `package-lock.json` | Lockfile integrity (sha512); `npm ci --ignore-scripts`, so no package install script runs; forge-std pinned to a git commit |
| Slither, Halmos and all 61 Python dependencies | `ci/requirements.txt` | `pip install --require-hashes` |
| forge 1.8.1 | `tools.lock` | sha256 checked by `scripts/fetch-tool.sh`; also checked once against GitHub's asset digest, Foundry's `.sha256` and its sigstore attestation (`gh attestation verify`) |
| Aderyn 0.6.8 | `tools.lock` | sha256 checked by `scripts/fetch-tool.sh`; also checked once against GitHub's asset digest and Aderyn's `.sha256`. Aderyn publishes no attestation. The npm package, whose installer downloaded the binary unverified, was removed |
| solc 0.8.30 | `hardhat.config.ts`, `foundry.toml` | Downloaded by Hardhat, forge and Aderyn, each verifying against soliditylang.org's published hashes |

Tamper checks: one changed character in a `tools.lock` hash makes `fetch-tool.sh` fail. Corrupted hashes in
`ci/requirements.txt` make pip refuse the install. The suite passes on an `--ignore-scripts` install.

## 7. Verification commands

```bash
npm ci
```

```bash
npm test
```

```bash
npm run lint:sol
```

```bash
slither .
```

```bash
scripts/fetch-tool.sh aderyn
```

```bash
npm run aderyn
```

```bash
npm run test:halmos
```

```bash
npm run validate:upgrades
```

```bash
npm run verify:reproducible
```

Tool versions: Node 24.21.0, Python 3.12.15, Hardhat 3.20.0, Foundry v1.8.1, slither 0.11.5, Aderyn 0.6.8, halmos 0.3.3,
`@openzeppelin/upgrades-core` 1.46.0. CI (`.github/workflows/ci.yml`) runs all of them on every push, except `verify:reproducible`, which runs on
pull requests into `main` and, through `release.yml`, on every `v*` tag. Mythril is not used: it has no Cancun support
(TSTORE/TLOAD/MCOPY).
