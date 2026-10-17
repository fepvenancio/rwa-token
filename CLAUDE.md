# Gated Token Stack — Build Brief

Drop this file in the repo root as `CLAUDE.md`. It is the standing instruction set for every Claude Code session in this project.

## 1. What we are building

A family of permissioned ERC-20-derived templates for institutional RWAs. All share one base that guarantees access control on mint, burn and transfer, exposes standard enforcement primitives (forced transfer / clawback, freeze, pause), and routes every policy decision (identity, jurisdiction, lock-ups, holder caps, settlement windows) through an external, overridable hook made of small rules. One template adds executor-settled transfers: holder-signed EIP-712 intents executed by an EXECUTOR role.

```
PolicyGatedERC20Upgradeable          abstract base: roles, enforcement core, _update → hook
        ▲
   ┌────┴──────────────┬────────────────────┬────────────────────┐
IntentToken         Gated4626Vault       Gated7540Vault       (later: Gated3643, 721/1155)
(+IntentSettled)    OZ ERC4626 + base    async request/claim + base
```

Separate contracts, separate concerns:

1. Base — accounting, roles, enforcement primitives, hook pointer. The only thing that cannot be hot-swapped.
2. Policy hook — one `IPolicyHook` per token (`ComplianceHook`), timelocked replacement, dispatching to an ordered list of `IComplianceRule`.
3. Mixins — `IntentSettled` (EIP-712 intents, nonces, `executeTransfer`). Opt-in per template.
4. Executor — `IntentExecutor`: role-gated caller that validates and submits intents. Replaceable. Grows into multi-leg DvP later.

## 2. Non-negotiable rules

1. OpenZeppelin v5 (`@openzeppelin/contracts`, `@openzeppelin/contracts-upgradeable`) only. No Solady. No other libs without asking.
2. No refactors outside the task you were given.
3. Before any change touching more than one file, write or update `PLAN.md` and stop for review.
4. `contracts/interfaces/*.sol` are frozen after Phase 1. Changing them requires an explicit instruction.
5. Every contract ships with a `.t.sol` next to it. Tests are written before implementation and the failing run is shown.
6. Run `npx hardhat test` (both runners) before reporting any task as done. Paste the summary line.
7. `transfer()` never returns `true` without moving balance. Rejections revert with a typed error carrying a `bytes32` reason.
8. No secrets in `.env`. Use `hardhat-keystore`.
9. Solidity `^0.8.28` pragma, exact version pinned in config (0.8.30 unless told otherwise), `evmVersion: "cancun"`.
10. Mirror OZ's own patterns (`ERC20Permit`, `EIP712Upgradeable`, `AccessControlUpgradeable`, `ERC4626Upgradeable`) rather than inventing.
11. No business logic in the base. If you write an `if` about who, where or when inside the base or a template, stop — it is a rule.
12. Hooks and rules are immutable contracts, never proxies. They are installed only if their `codehash` is attested in the `PolicyRegistry`. Changing one means deploying a new one and swapping.
13. Base upgrades fix bugs; features migrate. Any upgrade goes through the timelock (≥7 days) and must target an implementation attested in the registry.
14. Events and reason codes are part of the frozen interface. Extend `TransferContext` only through `extra`.
15. Proprietary code, all rights reserved: any use requires the owners' approval. Every source file carries `// SPDX-License-Identifier: UNLICENSED`, and `package.json` has `"license": "UNLICENSED"` and `"private": true`. Do not add, suggest or switch to an open-source license. Do not change this rule without an explicit instruction.
16. Wonderland Solidity standards (handbook.wonderland.xyz → Development/Solidity, Testing):
    - Lint with the Wonderland `.solhint.json`. Format with `forge fmt` using the `[fmt]` profile in `foundry.toml`: 2-space indent, single quotes, 120 columns.
    - Interfaces are separate from contracts. Events, errors, structs and enums are defined in the interface.
    - Errors are named `<Contract>_<Name>`. Events are past tense and emitted on every state change.
    - Constants and immutables are `UPPER_SNAKE`. Private and internal state, locals, arguments and return names are `_camelCase`.
    - Named imports only, via `remappings.txt` (`interfaces/…`, `contracts/…`). Order: external libraries → internal libraries → interfaces → contracts.
    - Full NatSpec on every item (`@param`/`@return`, `@inheritdoc` on overrides).
    - Unit tests isolate the unit with `vm.mockCall` + `vm.expectCall`. Integration tests cover happy and sad paths. Fuzz with `bound`, never `vm.assume`.

    Where this conflicts with the brief, the brief wins: tests sit next to the contract (rule 5), and ERC-7201 storage structs and the `$` pointer stay in the contract, as in OZ (rule 10).

## 3. Repo layout

```
contracts/
  interfaces/   IPolicyGated.sol  IPolicyHook.sol  IComplianceRule.sol  IPolicyRegistry.sol  ITransferIntent.sol  IIntentExecutor.sol  IIntentExecutorBatch.sol  Errors.sol
  base/         PolicyGatedERC20Upgradeable.sol  PolicyGatedERC20Upgradeable.t.sol
  governance/   PolicyRegistry.sol  PolicyRegistry.t.sol
  mixins/       IntentSettledUpgradeable.sol  IntentSettledUpgradeable.t.sol
  tokens/       IntentToken.sol  IntentToken.t.sol
  vaults/       Gated4626Vault.sol  Gated7540Vault.sol  (+ .t.sol)
  hooks/        ComplianceHook.sol  ComplianceHook.t.sol  BaseRule.sol
  hooks/rules/  IdentityRule.sol  SettlementWindowRule.sol  MaxHoldersRule.sol  LockupRule.sol  (+ .t.sol)
  intents/      IntentExecutor.sol  IntentExecutor.t.sol
  test/         MockAcceptHook.sol  MockRejectHook.sol  MockReentrantRule.sol  MockIdentityRegistry.sol  MockAsset.sol
test/nodejs/    *.test.ts   (viem + node:test: EIP-712 signing, settlement flows, vault flows)
ignition/modules/
PLAN.md
```

## 4. Base: roles and enforcement core (`PolicyGatedERC20Upgradeable`)

Shaped on ERC-7943 (uRWA, Last Call) so external tooling (compliance engines, explorers) can discover it via ERC-165. Implements `IPolicyGated`:

```solidity
interface IPolicyGated {
    // ---- enforcement primitives (role-gated, 7943-aligned names) ----
    function mint(address to, uint256 amount) external;                              // MINTER_ROLE
    function burn(address from, uint256 amount) external;                            // BURNER_ROLE
    function forcedTransfer(address from, address to, uint256 amount) external;      // AGENT_ROLE; unfreezes as needed
    function setFrozen(address user, uint256 amount) external;                       // AGENT_ROLE; absolute frozen amount
    function getFrozen(address user) external view returns (uint256);
    function pause() external;                                                       // PAUSER_ROLE
    function unpause() external;                                                     // PAUSER_ROLE

    // ---- read path for integrators ----
    function canTransfer(address from, address to, uint256 amount) external view returns (bool ok, bytes32 reason);
    function isUserAllowed(address user) external view returns (bool);
    function policyHook() external view returns (address);

    // ---- governance ----
    function setPolicyHook(address newHook) external;                                // onlyTimelock; newHook must be registry-attested
    function registry() external view returns (address);                             // immutable after init

    event ForcedTransfer(address indexed from, address indexed to, uint256 amount, address indexed agent);
    event Frozen(address indexed user, uint256 amount);
    event PolicyHookChanged(address indexed oldHook, address indexed newHook);
}
```

The base also implements ERC-2612 `permit` (`ERC20PermitUpgradeable`); it shares the EIP-712 domain with `IntentSettled`.

**Roles.** `DEFAULT_ADMIN_ROLE` = TimelockController. `MINTER_ROLE`, `BURNER_ROLE`, `AGENT_ROLE`, `UPGRADER_ROLE`, `EXECUTOR_ROLE` (only used by `IntentSettled`). Role admins all resolve to the timelock.

**Guardian** (built into the base, by default). `GUARDIAN_ROLE`, held by a multisig, is the only power with no delay. It can: `pause()`; and cancel any pending timelock operation (it holds the timelock's `CANCELLER_ROLE`). It cannot `unpause()`, change the hook, grant roles, or upgrade — those are timelock-only. Asymmetry is deliberate: the guardian can only stop things. `PAUSER_ROLE` is therefore replaced by `GUARDIAN_ROLE` for `pause()`; `unpause()` is `onlyTimelock`. Guardian membership changes go through the timelock.

**Recovery timelock** (owner decision M-1). A guardian that could cancel its own removal would not be stop-only, so a second `TimelockController` (same ≥7-day delay, governance multisig as proposer and executor, no cancellers, guardian holds nothing on it) holds `RECOVERY_ROLE`. On every token, vault and the executor that role allows exactly `unpause()` and `revokeRole(GUARDIAN_ROLE, …)`; on the main timelock (`GovernanceTimelock`, an OZ subclass) exactly `revokeRole(CANCELLER_ROLE, …)`. It cannot grant roles, change hooks, upgrade, or propose on the main timelock. Governance keeps a path the guardian cannot block; the guardian can still stop everything else. A compromised governance multisig is out of scope for this control, by design. No expiring pause: it would turn a security control into a timer.

**Policy registry** (one per deployment, `PolicyRegistry`). Immutable contract. Maps `codehash → attested kind` (`HOOK`, `RULE`, `IMPLEMENTATION`). `ATTESTER_ROLE` (security council multisig) attests after review and revokes; `DEFAULT_ADMIN_ROLE` (timelock) manages attesters. Checks are by `extcodehash` of the target, so targets must be plain contracts (rule 12). Enforced at:

* `setPolicyHook(newHook)` — `isAttested(newHook, HOOK)`.
* `ComplianceHook` constructor (`initialRules`) and `setRules(rules)` — `isAttested(rule, RULE)` for every rule.
* `_authorizeUpgrade(newImpl)` — `isAttested(newImpl, IMPLEMENTATION)`.

Attestation is checked at install time only. Revocation emits `AttestationRevoked(codehash)` and does not alter running tokens; governance removes the component, guardian can pause meanwhile. This avoids a revoke silently dropping a check or bricking transfers.

**What the base enforces itself** (mechanical, not policy): paused ⇒ reject everything except `kind == FORCED`; `balanceOf(from) - frozen(from) >= amount` for all kinds except `FORCED` and `BURN` by agent; role checks at entry points; registry attestation at install/upgrade; ERC-20 arithmetic; hook pointer and timelock.

**What the base delegates** (everything else): the hook, via a single `_update` override that builds a `TransferContext` and calls `beforeTransfer`, moves balances, then `afterTransfer`. Mint and burn pass `address(0)` so issuance and supply rules are rules too. `FORCED` still runs the hook; rules decide exemptions (e.g. `IdentityRule` requires `to` verified even on forced).

## 5. Interfaces (Phase 1 — implement exactly, then freeze)

```solidity
enum TransferKind { TRANSFER, EXECUTED, FORCED, MINT, BURN }

struct TransferContext {
    address token;
    address from;        // address(0) on MINT
    address to;          // address(0) on BURN
    uint256 id;          // 0 for fungibles; tokenId / id for future 721/1155 templates
    uint256 amount;
    address operator;    // msg.sender into the token: holder, spender, agent, minter, or executor
    TransferKind kind;
    bytes32 ref;         // intent.ref for EXECUTED, else 0
    uint256 deadline;    // intent.deadline for EXECUTED, else 0
    bytes   extra;       // reserved; empty today
}

interface IPolicyHook {
    /// MUST be view. Returns TRANSFER_OK or a reason code. Never reverts on a policy decision.
    function beforeTransfer(TransferContext calldata ctx) external view returns (bytes32 reason);
    /// Called after balances move, only if wantsAfter(). Inside the token's reentrancy guard.
    function afterTransfer(TransferContext calldata ctx) external;
    function wantsAfter() external view returns (bool);
}

interface IComplianceRule {
    function check(TransferContext calldata ctx) external view returns (bytes32 reason);
    function after_(TransferContext calldata ctx) external;      // onlyHook
    function wantsAfter() external view returns (bool);
    function ruleId() external pure returns (bytes32);
}

struct TransferIntent {
    address from;
    address to;
    uint256 amount;
    bytes32 nonce;       // ERC-3009-style random nonce, tracked per signer in a used/unused map
    uint256 deadline;    // inclusive
    bytes32 ref;         // off-chain reference (ISO 20022 msgId hash / bizId)
}

interface ITransferIntent {
    event IntentExecuted(bytes32 indexed intentHash, address indexed from, address indexed to, uint256 amount, address executor, bytes32 ref);
    event IntentCancelled(address indexed from, bytes32 indexed nonce);

    function canExecute(TransferIntent calldata intent) external view returns (bool ok, bytes32 reason);
    function executeTransfer(TransferIntent calldata intent, bytes calldata sig) external returns (bytes32 intentHash);  // EXECUTOR_ROLE
    function cancelIntent(bytes32 nonce) external;
    function intentHash(TransferIntent calldata intent) external view returns (bytes32);
    function nonceUsed(address signer, bytes32 nonce) external view returns (bool);
}

interface IIntentExecutor {
    function execute(address token, TransferIntent calldata intent, bytes calldata sig) external returns (bytes32);
}

enum AttestKind { NONE, HOOK, RULE, IMPLEMENTATION }

interface IPolicyRegistry {
    event Attested(bytes32 indexed codehash, AttestKind kind, address indexed attester, string uri);
    event AttestationRevoked(bytes32 indexed codehash, address indexed attester);

    function attest(bytes32 codehash, AttestKind kind, string calldata uri) external;   // ATTESTER_ROLE; uri → audit report
    function revoke(bytes32 codehash) external;                                         // ATTESTER_ROLE
    function isAttested(address target, AttestKind kind) external view returns (bool);  // compares target.codehash
    function kindOf(bytes32 codehash) external view returns (AttestKind);
}
```

Semantics to spec in NatSpec and enforce in tests:

* `canTransfer` / `canExecute` run the exact same path as the state-changing call minus the write. Pre-flight never lies.
* `executeTransfer` only by `EXECUTOR_ROLE`. Executor cannot alter the intent, only execute or not.
* Nonces per-signer, random, single-use. Cancel marks the nonce used. Deadline check `block.timestamp <= deadline`.
* EIP-712 domain: name = token name, version `"1"`, chainId, verifyingContract. `EIP712Upgradeable`.
* Hook address read once per `_update` into a local; mid-tx changes cannot alter the outcome.
* Reason codes in `Errors.sol`, ERC-1594 style: `TRANSFER_OK`, `PAUSED`, `INSUFFICIENT_UNFROZEN`, `SENDER_NOT_VERIFIED`, `RECEIVER_NOT_VERIFIED`, `OUTSIDE_SETTLEMENT_WINDOW`, `MAX_HOLDERS`, `LOCKED`, `INTENT_EXPIRED`, `NONCE_USED`, `BAD_SIGNATURE`.
* ERC-165 for `IPolicyGated`, `IPolicyHook`, `IComplianceRule`, `IPolicyRegistry`, `ITransferIntent`, plus the matching ERC-7943 fungible interface ID where the function set overlaps.
* Events and reason codes are frozen with the interfaces. New reason codes may be appended, never renamed or renumbered.
* FORCED with `from == address(0)` is an enforcement mint; rules treat it as FORCED (exempt from cap, pause, lockup) and still require `to` verified. FORCED with `to == address(0)` is reserved and currently unused. The base announces it with `_mintAs(to, amount, kind)`; `_moveAs` never sees `from == address(0)`.

## 6. Hook development — every policy check is a rule

**Topology.** One `ComplianceHook` per token (per-instrument rule sets). Rules are the unit developers write; the hook is the dispatcher. Rules must key any storage by `ctx.token` so one deployment can serve many tokens. Rules are hook-agnostic: `BaseRule.onlyHook(ctx)` accepts whichever hook `ctx.token` currently has installed (`IPolicyGated(ctx.token).policyHook()`). So one attested instance serves every token and survives hook replacement, and its codehash does not depend on any hook. This is sound only because state is keyed by `ctx.token`: a fake token can authorise writes to its own key and nothing else. `ruleId` is the rule type, and a hook accepts one instance per `ruleId`; a second configuration of the same logic needs a distinct id (e.g. `IdentityRule.secondary.v1`).

**Dispatcher rules (`ComplianceHook`).**

1. Iterate rules in order; return on first non-`TRANSFER_OK`.
2. `check` is called with `staticcall` semantics. A rule that mutates state in `check` fails tests.
3. `after_` runs only for rules with `wantsAfter()`, after balances moved, inside the token's `ReentrancyGuardTransient`.
4. Hard cap 16 rules. The initial rule set is passed to the constructor, so the token is live with its policy at deploy. Later changes replace the whole ordered set atomically with `setRules` (`onlyTimelock`). Both paths emit `RuleSetChanged(bytes32[] ruleIds)` and revert unless every rule satisfies `registry.isAttested(rule, RULE)`. An empty set fails closed (`NO_RULES`).
5. Rule list loaded into memory once per call.
6. Rules may make view calls to the token (`balanceOf`, `hasRole`, `policyHook`, `getFrozen`). State-changing calls are forbidden and blocked by the guard; `MockReentrantRule` proves it.

**Writing a new rule.**

1. `contracts/hooks/rules/<Name>Rule.sol` inheriting `BaseRule` (`ruleId`, `wantsAfter` default false, `onlyHook(ctx)` on `after_`).
2. Implement `check`. Read your own storage, registries injected at construction, and view functions of `ctx.token`. Per-token configuration is authorised live by the token's own roles (`IAccessControl(token).hasRole`): `DEFAULT_ADMIN_ROLE` for policy parameters, `AGENT_ROLE` for per-holder operational data.
3. Add reason codes to `Errors.sol` if new.
4. `<Name>Rule.t.sol`: accept, each reject, fuzz, view-ness.
5. Integration test registering the rule in `ComplianceHook`, asserting `canTransfer`/`canExecute` agree with the state-changing call.
6. Update `PLAN.md` with purpose and position in the order.

**Initial rule set (Phase 4).**

* `IdentityRule` — `isVerified(from)` unless MINT; `isVerified(to)` unless BURN. Applies to FORCED.
* `SettlementWindowRule` — EXECUTED only. A daily UTC window `[open, close)` (overnight when `open > close`) plus a weekday mask (Mon = 0, `MON_TO_FRI` default; weekday = `((ts / 1 days) + 3) % 7`). An overnight session belongs to the day it opened. Installed but unconfigured fails closed.
* `MaxHoldersRule` — `wantsAfter()`; maintains the holder count per token (holder = balance > 0; zero amounts never add one). A move to an existing holder is never capped. A full-balance move to a new holder is a net-zero change and passes when count <= cap; any other move to a new holder passes when count < cap. When the count is above a lowered cap, no new holder is admitted, net-zero or not, until the count is back down to the cap (a full-balance move) or below it (any other new holder): a lowered cap is a ratchet, so the register can only shrink while over it. Existing holders can still transfer among themselves and exit. FORCED is exempt from the cap but still counted. `cap == 0` fails closed. `seedHolderCount` (token admin) is only legitimate while the rule is not active. `setExemptHolder(token, account, bool)` (token admin): exempt accounts (7540 escrow vault, treasury) never count and never trigger the cap, the seed excludes them, and the count follows an exemption change on a current holder.
* `LockupRule` — per-(token, holder) unlock timestamp set by the token's `AGENT_ROLE` (a past or present timestamp clears it); rejects TRANSFER/EXECUTED and holder-initiated BURN (vault redemptions) before it; exempts FORCED, MINT, and BURN whose operator holds the token's `BURNER_ROLE` (enforcement).

## 7. Vault templates

`Gated4626Vault` = OZ `ERC4626Upgradeable` + `PolicyGatedERC20Upgradeable`. Shares are the gated ERC-20; `deposit`/`mint` to `receiver` arrive at the hook as `MINT`, `withdraw`/`redeem` as `BURN`, so identity gating on vault entry/exit is automatic. The asset leg is an ordinary ERC-20 pull/push and is not hooked. Resolve the `_update` diamond explicitly (`override(ERC20Upgradeable, PolicyGatedERC20Upgradeable)`).

**Gating-aware `max*` (both vaults).** This is how ERC-4626 expresses permissioning and what integrators check before calling. `maxDeposit(receiver)` / `maxMint(receiver)` return `0` when paused or when `canTransfer(address(0), receiver, 1)` is not OK. `maxRedeem(owner)` is `balanceOf(owner) - getFrozen(owner)` and returns `0` when paused or when `canTransfer(owner, address(0), 1)` is not OK. `maxWithdraw(owner)` is always `_convertToAssets(maxRedeem(owner), Math.Rounding.Floor)`, never `super.maxWithdraw(owner)` minus the frozen value, so rounding can never promise more assets than `withdraw` can deliver (`previewWithdraw` rounds shares up). `preview*` stay pure conversions; the gating lives in `max*`. Tests assert the meaningful form: a blocked receiver has `maxDeposit == 0` and the smallest deposit reverts (an allowed receiver's `maxDeposit` is `type(uint256).max`, and even `deposit(0)` reverts for a blocked one); redemptions keep the exact form, `redeem(maxRedeem(o))` succeeds and `redeem(maxRedeem(o) + 1)` reverts.

`Gated7540Vault` — implement against the EIP-7540 interface (OZ does not ship one): `requestDeposit`/`requestRedeem` record pending claims per controller; a `FULFILLER_ROLE` (the bank) fulfils; `deposit`/`redeem` claim into gated shares (`MINT`/`BURN` through the hook). 7540 is already request/claim, so do not add `IntentSettled` on top of it — the request is the intent and `FULFILLER_ROLE` is the executor. 7540 operators are full delegates per the standard; owners should approve only custodians they'd trust with the assets (owner decision L-5: an operator can also create requests that pull the owner's assets or shares under any controller). The escrowing vault is registered as a verified, `MaxHoldersRule`-exempt holder. `FULFILLER_ROLE` can `rejectDepositRequest` / `rejectRedeemRequest` (assets back; shares back to the controller as a plain TRANSFER, so cap, pause, lockup and freeze all apply; if blocked, the reject reverts and the agent uses `recoverRedeemRequest`; owner decision M-2, reversing R2). If the controller was de-verified, `AGENT_ROLE` uses `recoverRedeemRequest(controller, to)`, an enforcement action. It clears the pending bookkeeping and FORCED-moves the escrow to a verified recovery account, emitting `RedeemRequestRecovered`. Every fulfilment emits `Fulfilled(controller, isDeposit, price, assets, shares, fulfiller)`, where `price` is assets per `10**decimals()` shares (never below 1). `convertTo*` use the last price, and `totalAssets` is indicative. Compliance holds after fulfilment: deposit claims re-run `canTransfer(address(0), controller, 1)` (as `maxDeposit`), and redemption payouts re-run a zero-amount burn probe `canTransfer(controller, address(0), 0)` (identity, lockup, pause; `maxRedeem`/`maxWithdraw` use it too). `recoverClaimable(controller, to)` (`AGENT_ROLE`) pays claimable redemption assets to `to` and delivers claimable deposit shares to `to` as an enforcement mint; `to` must pass identity; it works while paused and at a full cap (the stranded-deposit case) and emits `ClaimableRecovered(controller, to, assets, shares, agent)`. This added function is the one post-freeze change to `IGated7540Vault` (re-pinned).

## 8. Phases

Each phase: update `PLAN.md` → tests → impl → `npx hardhat test` → stop for review.

* **Phase 0 — scaffold.** `npx hardhat --init` (TypeScript, ESM, node:test + viem). OZ v5. Solc pin, cancun, optimizer profile. `hardhat-keystore`. Lockfile committed.
* **Phase 1 — interfaces + errors.** §4 and §5 verbatim with NatSpec. Freeze.
* **Phase 2 — registry + base.** `PolicyRegistry` (immutable, tests: attest/revoke/kind, codehash comparison, role gates). `PolicyGatedERC20Upgradeable`: `ERC20PermitUpgradeable` + `AccessControlUpgradeable` + `PausableUpgradeable` + `UUPSUpgradeable` + `ReentrancyGuardTransient`, enforcement core, guardian, `_update` → hook. Tests with mock hooks: every entry point's role gate; guardian can pause and cannot unpause; `setPolicyHook` and `_authorizeUpgrade` reject unattested targets; frozen math; forced unfreezes; mint/burn reach hook with zero addresses; hook reject ⇒ no state change; `permit`; invariants `sum(balances) == totalSupply`, `frozen(u) <= balanceOf(u)`.
* **Phase 3 — IntentSettled + IntentToken + executor.** EIP-712, per-signer used-nonce map (random nonces chosen by the signer's HSM/client, independent of executor state), `executeTransfer`, `cancelIntent`. `IntentExecutor` (immutable; `OPERATOR_ROLE` submits, guardian pauses, timelock unpauses; forward-only) holding the token's `EXECUTOR_ROLE`, with atomic `executeBatch` in the separate `IIntentExecutorBatch`. Tests: replay, expired, wrong domain/chainId, cancel race, malleability, role gating, `canExecute` parity.
* **Phase 4 — hooks.** `ComplianceHook`, `BaseRule`, initial rules, mocks. Ordering, short-circuit, reentrancy, cap.
* **Phase 5 — vaults.** `Gated4626Vault`, `Gated7540Vault`. Share mint/burn gated; gating-aware `max*`; 7540 request/fulfil/claim lifecycle; operator semantics.
* **Phase 6 — viem integration.** `signTypedData` → execute; vault flows; event decoding; pre-flight parity from the TypeScript side.
* **Phase 7 — deploy + security.** Ignition module: registry → attest implementations/hook/rules (one implementation per template, deployed and attested once, one proxy per token; UUPS gives each implementation deployment its own codehash) → timelock (≥7d, guardian as canceller) → proxies → roles → guardian multisig. `npx @openzeppelin/upgrades-core validate`. Slither clean (`slither .`, accepted findings documented in `slither.config.json` and inline). Halmos on the nonce/signature and frozen-balance paths (`npm run test:halmos`; verified on 2026-10-16 that it runs on the proxied token with transient storage and kills planted bugs). **No Mythril:** it has no Cancun support (TSTORE/TLOAD/MCOPY), so it cannot analyse `ReentrancyGuardTransient` or the transient context slots.

## 9. Hardhat 3 specifics

* `.t.sol` files, Foundry-style `setUp()` / `test*` / `testFuzz*` / `invariant*`, `forge-std` `Test`.
* No inline NatSpec fuzz config; no fixture cheatcodes. Fuzz runs via config.
* `npx hardhat test solidity` / `npx hardhat test nodejs` / `npx hardhat test`.
* ESM project; `node:test` + `viem` via `network.create()` (a fresh, isolated connection) or `network.getOrCreate()` (reuse one). `network.connect()` is `@deprecated` in Hardhat 3.20 and will be removed.
* Toolbox-viem (hardhat-viem 3.0.10, hardhat-viem-assertions 3.1.4):
  * `const { viem, networkHelpers } = await network.create()`.
  * Contracts: `viem.deployContract`, `viem.getContractAt`.
  * Clients: `viem.getPublicClient`, `viem.getWalletClients`.
  * Assertions: `viem.assertions.revertWithCustomErrorWithArgs`, `emitWithArgs`, `balancesHaveChanged`.
* Verify APIs against `node_modules/hardhat` typings and `.agents/skills/hardhat*`, not memory or older docs.

## 10. Definition of done (per phase)

1. `PLAN.md` reflects what was built.
2. All tests pass in both runners; output pasted.
3. NatSpec on every external function.
4. `contracts/interfaces/` unchanged since Phase 1.
5. No files touched outside the phase scope.
