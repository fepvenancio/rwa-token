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
2. Policy hook — one `ComplianceHook` shared by every token of a deployment (one attested codehash), holding an ordered list of `IComplianceRule` for each token. A token installs its initial list when it is initialised; later changes to the list, and replacing the hook itself, go through the timelock.
3. Mixins — `IntentSettled` (EIP-712 intents, nonces, `executeTransfer`). Opt-in per template.
4. Executors — `IntentExecutor`: role-gated caller that validates and submits intents that state no consideration. Replaceable. `DvPExecutor`: role-gated, settles a share trade against cash atomically from two signed legs, the cash being a gated token or an ERC-3009 token. Replaceable. More than two legs later.

## 2. Non-negotiable rules

1. OpenZeppelin v5 (`@openzeppelin/contracts`, `@openzeppelin/contracts-upgradeable`) only. No Solady. No other libs without asking.
2. No refactors outside the task you were given.
3. Before any change touching more than one file, write or update `PLAN.md` and stop for review.
4. `contracts/interfaces/*.sol` are frozen after Phase 1. Changing them requires an explicit instruction. (The owner reopened them on 2026-10-23 for the review items S0 to S4 and froze them again; `InterfaceFreeze.t.sol` pins every interface id and event topic.)
5. Every contract ships with a `.t.sol` next to it. Tests are written before implementation and the failing run is shown.
6. Run `npx hardhat test` (both runners) before reporting any task as done. Paste the summary line.
7. `transfer()` never returns `true` without moving balance. Rejections revert with a typed error. A policy rejection is `PolicyGated_TransferRejected(bytes32 reason)`; the token's own frozen-balance check (an amount within the balance but above the unfrozen balance) is the standard's `ERC7943InsufficientUnfrozenBalance(account, amount, unfrozen)`, and an amount above the balance is the base standard's `ERC20InsufficientBalance`. (Amended 2026-10-24.)
8. No secrets in `.env`. Use `hardhat-keystore`.
9. Solidity `^0.8.28` pragma, exact version pinned in config (0.8.30 unless told otherwise), `evmVersion: "cancun"`.
10. Mirror OZ's own patterns (`ERC20Permit`, `EIP712Upgradeable`, `AccessControlUpgradeable`, `ERC4626Upgradeable`) rather than inventing.
11. No business logic in the base. If you write an `if` about who, where or when inside the base or a template, stop — it is a rule.
12. Hooks and rules are immutable contracts, never proxies. They are installed only if their `codehash` is attested in the `PolicyRegistry`. Changing one means deploying a new one and swapping.
13. Base upgrades fix bugs; features migrate. Any upgrade goes through the timelock (≥7 days) and must target an implementation attested in the registry.
14. Events and reason codes are part of the frozen interface. Extend `TransferContext` only through `extra`, whose layout is fixed in §5.
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
  interfaces/   IPolicyGated.sol  IERC7943Fungible.sol  ITemplated.sol  IPolicyHook.sol  IComplianceHook.sol  IComplianceRule.sol  IPolicyRegistry.sol  ITransferIntent.sol  IIntentExecutor.sol  IIntentExecutorBatch.sol  IDvPExecutor.sol  IERC3009.sol  Errors.sol  (+ one per rule, the two vaults, IFund, IProxyDeployer, IGovernanceTimelock, IIdentityRegistry, ICredentialRegistry, ICredentialRule, Quals and the ERC-7540 and ERC-7575 interfaces)
  base/         PolicyGatedERC20Upgradeable.sol  PolicyGatedERC20Upgradeable.t.sol
  governance/   PolicyRegistry.sol  GovernanceTimelock.sol  (+ .t.sol)
  identity/     CredentialRegistry.sol  CredentialRegistry.t.sol
  deploy/       ProxyDeployer.sol  TokenProxy.sol  (+ .t.sol)
  mixins/       IntentSettledUpgradeable.sol  IntentSettledUpgradeable.t.sol
  tokens/       IntentToken.sol  IntentToken.t.sol
  vaults/       Gated4626Vault.sol  Gated7540Vault.sol  (+ .t.sol)
  hooks/        ComplianceHook.sol  ComplianceHook.t.sol  BaseRule.sol
  hooks/rules/  CredentialRule.sol  IdentityRule.sol  MinPositionRule.sol  HolderRestrictionRule.sol  SettlementWindowRule.sol  MaxHoldersRule.sol  FundHoldersRule.sol  (+ .t.sol, RuleSetIntegration.t.sol)
  fund/         Fund.sol  Fund.t.sol
  intents/      IntentExecutor.sol  IntentExecutor.t.sol  DvPExecutor.sol  DvPExecutor.t.sol
  test/         Helpers.sol  PolicyGatedHarness.sol  MockReentrantRule.sol  MockIdentityRegistry.sol  MockAsset.sol  MockERC3009Token.sol  MockReentrantCashToken.sol  MockReentrantGatedToken.sol  MockFakeSecurityToken.sol  MockStatefulToken.sol  MockStatefulFund.sol  MockERC1271Wallet.sol  InterfaceFreeze.t.sol  ContractSizes.t.sol  halmos/
test/nodejs/    *.test.ts   (viem + node:test: EIP-712 signing, settlement flows, vault flows)
ignition/modules/
PLAN.md
```

## 4. Base: roles and enforcement core (`PolicyGatedERC20Upgradeable`)

Implements ERC-7943 (uRWA, Final) so external tooling (compliance engines, explorers) can discover it via ERC-165: `IPolicyGated` is `IERC7943Fungible` (id `0x3edbb4c4`, the XOR of the standard's six selectors) plus what the standard does not cover:

```solidity
// ERC-7943 Final, inherited
interface IERC7943Fungible is IERC165 {
    function forcedTransfer(address from, address to, uint256 amount) external returns (bool);    // AGENT_ROLE; takes frozen tokens as needed
    function setFrozenTokens(address account, uint256 amount) external returns (bool);           // AGENT_ROLE; absolute frozen amount, may exceed the balance
    function getFrozenTokens(address account) external view returns (uint256);
    function canSend(address account) external view returns (bool);                               // account level: the hook's checkSend
    function canReceive(address account) external view returns (bool);                            // account level: the hook's checkReceive
    function canTransfer(address from, address to, uint256 amount) external view returns (bool);

    event ForcedTransfer(address indexed from, address indexed to, uint256 amount);
    event Frozen(address indexed account, uint256 amount);
    error ERC7943CannotSend(address account);
    error ERC7943CannotReceive(address account);
    error ERC7943CannotTransfer(address from, address to, uint256 amount);
    error ERC7943InsufficientUnfrozenBalance(address account, uint256 amount, uint256 unfrozen);
}

interface IPolicyGated is IERC7943Fungible {
    // ---- issuance, pause ----
    function mint(address to, uint256 amount) external;                              // MINTER_ROLE
    function burn(address from, uint256 amount) external;                            // BURNER_ROLE; an enforcement action: no allowance, may take frozen tokens
    function pause() external;                                                       // GUARDIAN_ROLE
    function unpause() external;                                                     // timelock or recovery timelock

    // ---- read path for integrators ----
    function canTransferWithReason(address from, address to, uint256 amount) external view returns (bool ok, bytes32 reason);
    function policyHook() external view returns (address);

    // ---- governance ----
    function setPolicyHook(address newHook) external;                                // onlyTimelock; newHook must be registry-attested and name the token's registry
    function registry() external view returns (address);                             // fixed at init

    event ForcedTransferBy(address indexed from, address indexed to, uint256 amount, address indexed agent);
    event PolicyHookChanged(address indexed oldHook, address indexed newHook);
    error PolicyGated_NotAttested(address target, AttestKind kind);
    error PolicyGated_HookRegistryMismatch(address hookRegistry, address tokenRegistry);
    error PolicyGated_TransferRejected(bytes32 reason);
    error PolicyGated_ZeroAddress();
}
```

`forcedTransfer` emits the standard's `ForcedTransfer` and our `ForcedTransferBy`, which keeps the agent. Frozen tokens: the frozen amount may exceed the balance (ERC-7943 requires that it be allowed), and a holder can move only `balance - frozen` (zero when the frozen amount is the larger). `forcedTransfer`, and a `burn` by a `BURNER_ROLE` holder, are enforcement: they may take frozen tokens, never more than the balance, and lower the frozen amount by exactly the part of the amount that was frozen (`Frozen` is emitted before `Transfer`).

The base also implements ERC-2612 `permit` (`ERC20PermitUpgradeable`); it shares the EIP-712 domain with `IntentSettled`. It inherits `MulticallUpgradeable` (not payable, the sender is preserved), so one role holder can batch role-gated calls atomically; there are no bespoke batch functions on the tokens. Each template reports its own `templateId()` (`ITemplated`: `keccak256` of its name, unversioned), which the upgrade check compares.

**Roles.** `DEFAULT_ADMIN_ROLE` = TimelockController. `MINTER_ROLE`, `BURNER_ROLE`, `AGENT_ROLE`, `UPGRADER_ROLE`, `EXECUTOR_ROLE` (only used by `IntentSettled`). Role admins all resolve to the timelock.

**Guardian** (built into the base, by default). `GUARDIAN_ROLE`, held by a multisig, is the only power with no delay. It can: `pause()`; and cancel any pending timelock operation (it holds the timelock's `CANCELLER_ROLE`). It cannot `unpause()`, change the hook, grant roles, or upgrade — those are timelock-only. Asymmetry is deliberate: the guardian can only stop things. `PAUSER_ROLE` is therefore replaced by `GUARDIAN_ROLE` for `pause()`; `unpause()` is `onlyTimelock`. Guardian membership changes go through the timelock.

**Recovery timelock** (owner decision M-1). A guardian that could cancel its own removal would not be stop-only, so a second `TimelockController` (same ≥7-day delay, governance multisig as proposer and executor, no cancellers, guardian holds nothing on it) holds `RECOVERY_ROLE`. On every token, vault and executor that role allows exactly `unpause()` and `revokeRole(GUARDIAN_ROLE, …)`; on the main timelock (`GovernanceTimelock`, an OZ subclass) exactly `revokeRole(CANCELLER_ROLE, …)`; on the credential registry exactly `clearGuardianBlock`, `reviveAttester` and `revokeRole(GUARDIAN_ROLE, …)`. (The registry has its own guardian, whose only powers are `blockSubject` and `killAttester`, with no delay, and the same recovery path undoes them.) It cannot grant roles, change hooks, upgrade, or propose on the main timelock. Governance keeps a path the guardian cannot block; the guardian can still stop everything else. A compromised governance multisig is out of scope for this control, by design. No expiring pause: it would turn a security control into a timer.

**Policy registry** (one per deployment, `PolicyRegistry`). Immutable contract. Maps `codehash → attested kind` (`HOOK`, `RULE`, `IMPLEMENTATION`). `ATTESTER_ROLE` (security council multisig) attests after review and revokes; `DEFAULT_ADMIN_ROLE` (timelock) manages attesters. Checks are by `extcodehash` of the target, so targets must be plain contracts (rule 12). Enforced at:

* `setPolicyHook(newHook)` and the initialiser — `isAttested(newHook, HOOK)`, and `newHook.REGISTRY()` must be the token's own registry, because a shared hook vets rules against its own.
* `ComplianceHook.setRules(token, rules)` (also how a token installs its initial rules) — `isAttested(rule, RULE)` for every rule.
* `_authorizeUpgrade(newImpl)` — `isAttested(newImpl, IMPLEMENTATION)`, and `ITemplated(newImpl).templateId()` must equal the proxy's own, so a proxy cannot be moved onto another template.

Attestation is checked at install time only. Revocation emits `AttestationRevoked(codehash)` and does not alter running tokens; governance removes the component, guardian can pause meanwhile. This avoids a revoke silently dropping a check or bricking transfers.

**What the base enforces itself** (mechanical, not policy): paused ⇒ reject everything except `kind == FORCED`; the amount must fit in the unfrozen balance for every kind except `FORCED` and a `BURN` by a `BURNER_ROLE` holder, which may take frozen tokens but never more than the balance (`canTransferWithReason` and `canExecute` apply the same bound; `canTransfer` is the one exception, see §5); role checks at entry points; registry attestation at install/upgrade; the template check on upgrade; ERC-20 arithmetic; hook pointer and timelock.

**What the base delegates** (everything else): the hook, via a single `_update` override that builds a `TransferContext` (with both balances before the move in `extra`) and calls `beforeTransfer`, moves balances, then `afterTransfer`. Mint and burn pass `address(0)` so issuance and supply rules are rules too. `FORCED` still runs the hook; rules decide exemptions (e.g. `IdentityRule` requires `to` verified even on forced).

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
    bytes   extra;       // abi.encode(fromBalance, toBalance): the balances before the move, zero for address(0), for every kind.
                         // EXECUTED continues it: abi.encode(fromBalance, toBalance, ref, deadline), ref and deadline from the intent
}

interface IPolicyHook {
    /// MUST be view. Returns TRANSFER_OK or a reason code. Never reverts on a policy decision.
    function beforeTransfer(TransferContext calldata ctx) external view returns (bytes32 reason);
    /// Called after balances move, only if wantsAfter(). Inside the token's reentrancy guard.
    function afterTransfer(TransferContext calldata ctx) external;
    function wantsAfter() external view returns (bool);
    /// Account-level answers behind canSend / canReceive. MUST be view; MUST NOT depend on an amount or encode a quantitative rule.
    function checkSend(address token, address account) external view returns (bytes32 reason);
    function checkReceive(address token, address account) external view returns (bytes32 reason);
}

interface IComplianceRule {
    function check(TransferContext calldata ctx) external view returns (bytes32 reason);
    function after_(TransferContext calldata ctx) external;      // onlyHook
    function wantsAfter() external view returns (bool);
    function ruleId() external pure returns (bytes32);
    function checkSend(address token, address account) external view returns (bytes32 reason);     // BaseRule: TRANSFER_OK
    function checkReceive(address token, address account) external view returns (bytes32 reason);  // BaseRule: TRANSFER_OK
}

struct TransferIntent {
    address from;
    address to;
    uint256 amount;
    bytes32 nonce;       // ERC-3009-style random nonce, tracked per signer in a used/unused map
    uint256 deadline;    // inclusive
    bytes32 ref;         // off-chain reference (ISO 20022 msgId hash / bizId)
    address executor;    // the only executor allowed to run it; zero = any EXECUTOR_ROLE holder
    uint256 validAfter;  // inclusive; zero = no lower bound
    address considerationToken;   // what the signer is to receive for this leg; signed, never enforced by the token
    uint256 considerationAmount;
}

interface ITransferIntent {
    event IntentExecuted(bytes32 indexed intentHash, address indexed from, address indexed to, uint256 amount, address executor, bytes32 ref);
    event IntentCancelled(address indexed from, bytes32 indexed nonce);

    function canExecute(TransferIntent calldata intent, bytes calldata sig) external view returns (bool ok, bytes32 reason);
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

* `canTransferWithReason` / `canExecute` run the exact same path as the state-changing call minus the write. Pre-flight never lies. (`canTransfer` returns the bool of ERC-7943; the reason is in `canTransferWithReason`.)
* `canTransfer` is that path with one exception, from ERC-7943: it MUST NOT return false for a balance check, so an amount above the balance reads true when the hook accepts it and no frozen amount is in the way (nothing frozen on `from`, or a burn by a sender that holds `BURNER_ROLE`, which may take frozen tokens), while `canTransferWithReason` says `INSUFFICIENT_UNFROZEN` and the write reverts with `ERC20InsufficientBalance`. It MUST also validate the unfrozen amount, so while part of the balance is frozen an amount above the unfrozen balance reads false, above the balance too (the write then still reverts with the base error); the standard does not say which clause wins above the balance, and this follows the draft ERC's reference. A frozen amount is not in the way of a `BURNER_ROLE` sender's burn, so that burn above the balance reads true like any balance shortfall; the same sender's plain transfer still counts frozen tokens.
* `canSend(account)` / `canReceive(account)` are the account-level questions: the hook's `checkSend` / `checkReceive` for this token, false while paused and when the token has no hook. They take no amount and no quantitative rule: ERC-7943 says they must not encode quantitative rules and names balance checks and amount limits, and we read a holder cap and a minimum the same way, so those are `check`'s alone. The standard also has `canTransfer` perform the `canSend` check on `from` and the `canReceive` check on `to`. Here `canTransfer` runs the movement path instead, and for a plain transfer through the shipped rules it is not true while either answer is false (`RuleSetIntegration.t.sol` fuzzes that one way). A rule's account answer agrees with its `check` for the kinds the rule does not exempt, so `canSend` can be false for an unverified, a frozen or a locked holder although `forcedTransfer` still passes, and an enforcement burn passes for a locked holder while `canSend` says `LOCKED`. The vaults' `maxDeposit` and `maxMint` do not use `canReceive`: they probe a mint (§7).
* Rules read the balances from `extra` and derive the balances after the move from `amount`; on the movement path they make no call back into the token for them.
* `executeTransfer` only by `EXECUTOR_ROLE`. Executor cannot alter the intent, only execute or not.
* Nonces per-signer, random, single-use. Cancel marks the nonce used. Deadline check `block.timestamp <= deadline`; `validAfter` check `block.timestamp >= validAfter`.
* Executor binding (owner decision, 2026-10-23): an intent with a non-zero `executor` executes only from that account (`WRONG_EXECUTOR`). A non-zero `considerationToken` or `considerationAmount` requires a non-zero `executor` (`CONSIDERATION_NEEDS_EXECUTOR`). The token never reads the consideration beyond that check; only the named executor enforces the payment. The checks run in the order deadline, nonce, consideration, executor, `validAfter`, signature, then the hook, in both `canExecute` and `executeTransfer`. They are checks on the signed message, like the deadline and the nonce, so they stay in the mixin (rule 11).
* EIP-712 domain: name = token name, version `"1"`, chainId, verifyingContract. `EIP712Upgradeable`.
* Hook address read once per `_update` into a local; mid-tx changes cannot alter the outcome.
* DvP (owner decision, 2026-10-23): `DvPExecutor` runs two signed legs atomically, the cash leg first, and has no entry point that runs one leg alone. The legs must mirror: the parties are swapped, each amount is the other leg's stated consideration, each stated consideration token is the other leg's token, and the two tokens differ (`DvPExecutor_LegsDoNotMatch`, and `LEGS_DO_NOT_MATCH` in its pre-flights). For an ERC-3009 cash leg the buyer's authorization is payable to the executor and its nonce is `keccak256(abi.encode(securityToken, intentHash))`, never the bare hash: the executor cannot tell an honest token's hash from a counterfeit's. The executor must end with the cash balance it started with, and the payout must raise the seller's balance by exactly the price. A failing leg reverts with `DvPExecutor_LegFailed(leg, reason)`. `IntentExecutor` cannot enforce a payment, so it refuses any intent whose `considerationToken` or `considerationAmount` is non-zero, in `execute` and `executeBatch`, with `IntentExecutor_ConsiderationNotSupported(index)`.
* Reason codes in `Errors.sol`, ERC-1594 style: `TRANSFER_OK`, `PAUSED`, `INSUFFICIENT_UNFROZEN`, `SENDER_NOT_VERIFIED`, `RECEIVER_NOT_VERIFIED`, `OUTSIDE_SETTLEMENT_WINDOW`, `MAX_HOLDERS`, `LOCKED`, `INTENT_EXPIRED`, `NONCE_USED`, `BAD_SIGNATURE`; appended 2026-10-23: `WRONG_EXECUTOR`, `INTENT_NOT_YET_VALID`, `CONSIDERATION_NEEDS_EXECUTOR`, `LEGS_DO_NOT_MATCH`; appended 2026-10-24: `BELOW_MIN_POSITION`, `SENDER_FROZEN`, `RECEIVER_FROZEN`; appended with the credential layer: `CREDENTIAL_EXPIRED`, `RECEIVER_NOT_ELIGIBLE`.
* ERC-165 for `IPolicyGated`, `IPolicyHook`, `IComplianceRule`, `IPolicyRegistry`, `ITransferIntent`, and for `IERC7943Fungible` (`0x3edbb4c4`), which `IPolicyGated` inherits.
* Events and reason codes are frozen with the interfaces. New reason codes may be appended, never renamed or renumbered.
* FORCED with `from == address(0)` is an enforcement mint; rules treat it as FORCED (exempt from cap, pause, lockup) and still require `to` verified. FORCED with `to == address(0)` is reserved and currently unused. The base announces it with `_mintAs(to, amount, kind)`; `_moveAs` never sees `from == address(0)`.

## 6. Hook development — every policy check is a rule

**Topology.** One `ComplianceHook` per deployment, shared by every token; its only immutable is `REGISTRY`, so the council attests one codehash for all of them, and each token has its own ordered rule list in it (per-instrument rule sets). A new class costs one `setRules`, not a hook. Rules are the unit developers write; the hook is the dispatcher. Rules must key any storage by `ctx.token` so one deployment can serve many tokens. Rules are hook-agnostic: `BaseRule.onlyHook(ctx)` accepts whichever hook `ctx.token` currently has installed (`IPolicyGated(ctx.token).policyHook()`). So one attested instance serves every token and survives hook replacement, and its codehash does not depend on any hook. This is sound only because state is keyed by `ctx.token`: a fake token can authorise writes to its own key and nothing else. `ruleId` is the rule type, and a hook accepts one instance per `ruleId`; a second configuration of the same logic needs a distinct id (e.g. `IdentityRule.secondary.v1`).

**Dispatcher rules (`ComplianceHook`).**

1. Iterate rules in order; return on first non-`TRANSFER_OK`.
2. `check` is called with `staticcall` semantics. A rule that mutates state in `check` fails tests.
3. `after_` runs only for rules with `wantsAfter()`, after balances moved, inside the token's `ReentrancyGuardTransient`.
4. Hard cap 16 rules per token. A token's initial rule set is passed to its initialiser, which installs the hook and then calls `hook.setRules(address(this), rules)`, so the token is live with its policy at deploy and the hook has no admin of its own. Later changes replace a token's whole ordered set atomically with `setRules(token, rules)`, callable by the token itself or by whoever holds the token's `DEFAULT_ADMIN_ROLE` (asked live: the timelock). Both paths emit `RuleSetChanged(token, ruleIds)` and revert unless every rule satisfies `registry.isAttested(rule, RULE)`. An empty set fails closed (`NO_RULES`). `afterTransfer` is accepted only from the token it names, and `ProxyDeployer.deploy` reverts unless the hook ends up holding exactly the rules the deployer expected for the new token.
5. Rule list loaded into memory once per call.
6. Rules may make view calls to the token (`balanceOf`, `hasRole`, `policyHook`, `getFrozenTokens`); the balances are in `extra`, so on the movement path no rule reads them from the token, though `after_` still asks `policyHook()` and a burn still asks for a role. State-changing calls are forbidden and blocked by the guard; `MockReentrantRule` proves it.
7. `checkSend` / `checkReceive` iterate the same list and return on the first rejection; they serve `canSend` and `canReceive` only, and a rule's account answer must not encode a quantitative rule.

**Writing a new rule.**

1. `contracts/hooks/rules/<Name>Rule.sol` inheriting `BaseRule` (`ruleId`, `wantsAfter` default false, `onlyHook(ctx)` on `after_`).
2. Implement `check`, and `checkSend` / `checkReceive` if the rule has an account-level opinion (no amount and no quantitative rule; the `BaseRule` default accepts; they must agree with `check` for the kinds the rule does not exempt, see §5). Read your own storage, registries injected at construction, and view functions of `ctx.token`. `check` must not revert for any `amount`, including one above `fromBalance` in `extra`: the write does not offer the hook such an amount, but `canTransfer` does, so compare before you subtract. Per-token configuration is authorised live by the token's own roles (`IAccessControl(token).hasRole`): `DEFAULT_ADMIN_ROLE` for policy parameters, `AGENT_ROLE` for per-holder operational data.
3. Add reason codes to `Errors.sol` if new.
4. `<Name>Rule.t.sol`: accept, each reject, fuzz, view-ness.
5. Integration test registering the rule in `ComplianceHook`, asserting `canTransferWithReason`/`canExecute` agree with the state-changing call.
6. Update `PLAN.md` with purpose and position in the order.

**Initial rule set (Phase 4, with the review items of 2026-10-24).** The demo deployment lists, in this order: for the intent token `CredentialRule`, `MinPositionRule`, `HolderRestrictionRule`, `SettlementWindowRule`, `FundHoldersRule`; for both vaults the same without the window. The minimum comes right after the credential rule so that, with a minimum set, the rules after it see real positions (FORCED, exempt accounts and burner burns can still leave dust).

* `CredentialRule` — asks a `CredentialRegistry` (immutable, reviewed by the council and not attested; the rule's codehash covers its address, not its code) what it knows about each party, and applies the token's policy (`requireAll`, `requireAny`, `forbidAny`, a bitmap of trusted attesters, set by the token's `DEFAULT_ADMIN_ROLE`) to the receiver. A sender must be able to leave, which is a standing of `ACTIVE`, `EXIT_ONLY` or `LAPSED`; it is not checked on MINT and FORCED, and a BURN whose operator holds `BURNER_ROLE` (enforcement) passes. A receiver must be `ACTIVE` and meet the policy, unless BURN; a lapsed receiver gets `CREDENTIAL_EXPIRED`, an `ACTIVE` one the policy rejects gets `RECEIVER_NOT_ELIGIBLE`, and a token with no policy admits no receiver. So a holder whose credential lapses, or whose attester is killed, can still send, burn and redeem and cannot receive. The state is in the registry, so the rule has no `after_`. A forced transfer still needs `to` eligible.
* `IdentityRule` — not in the demo lists; for a deployment that keeps identity data in an external registry. `isVerified(from)` unless MINT or FORCED; `isVerified(to)` unless BURN. A forced transfer still needs `to` verified. It gives a holder whose verification lapses no way out.
* `SettlementWindowRule` — EXECUTED only. A daily UTC window `[open, close)` (overnight when `open > close`) plus a weekday mask (Mon = 0, `MON_TO_FRI` default; weekday = `((ts / 1 days) + 3) % 7`). An overnight session belongs to the day it opened. Installed but unconfigured fails closed.
* `MinPositionRule` — per-token minimum position set by the token's `DEFAULT_ADMIN_ROLE`; 0 is off. After a movement the receiver must hold at least the minimum, and the sender must hold zero or at least the minimum, so no dust is left behind and no dust can open a holder slot (this closes the slot grab of L-1 wherever the rule is listed with a non-zero minimum; 1 wei sent to an existing holder still lands). Applies to TRANSFER, EXECUTED, MINT and holder-initiated BURN. Exempt: FORCED, the token itself (the 7540 escrow), accounts the token's admin lists, and a BURN whose operator holds `BURNER_ROLE` (asked only when a burn would leave dust). Zero amounts and self-moves are not judged. No sum can overflow, so the rule never reverts on arithmetic. Reason `BELOW_MIN_POSITION`. A rule left in a token's list with the minimum at 0 still costs about 9,200 gas per transfer, so a token that wants no minimum leaves it out.
* `MaxHoldersRule` — not in the demo lists (the investor count that matters for a fund is fund-wide, see `FundHoldersRule`); it stays available, deployed and attested, for a class with a limit of its own. `wantsAfter()`; maintains the holder count per token (holder = balance > 0; zero amounts never add one). A move to an existing holder is never capped. A full-balance move to a new holder is a net-zero change and passes when count <= cap; any other move to a new holder passes when count < cap. When the count is above a lowered cap, no new holder is admitted, net-zero or not, until the count is back down to the cap (a full-balance move) or below it (any other new holder): a lowered cap is a ratchet, so the register can only shrink while over it. Existing holders can still transfer among themselves and exit. FORCED is exempt from the cap but still counted. `cap == 0` fails closed. `seedHolderCount` (token admin) is only legitimate while the rule is not active. `setExemptHolder(token, account, bool)` (token admin): exempt accounts (7540 escrow vault, treasury) never count and never trigger the cap, the seed excludes them, and the count follows an exemption change on a current holder.
* `HolderRestrictionRule` — per-(token, holder) lockup and address freeze set by the token's `AGENT_ROLE`, in one storage word (`uint64 unlockTime`, `bool frozen`). The lockup (a past or present timestamp clears it) rejects TRANSFER/EXECUTED and holder-initiated BURN (vault redemptions) with `LOCKED` before it, and exempts FORCED, MINT, and BURN whose operator holds the token's `BURNER_ROLE` (enforcement). The freeze rejects a frozen sender in every kind except FORCED (`SENDER_FROZEN`; a burn, even the burner's, is refused, so the enforcement route out of a frozen account is `forcedTransfer` to a quarantine account) and a frozen receiver in every kind except BURN (`RECEIVER_FROZEN`; a mint and a forced transfer into it are refused, so a quarantine account is never frozen). `checkSend` answers the freeze and then the lockup, `checkReceive` the freeze: `canSend` is false for a frozen or a locked holder.
* `FundHoldersRule` (fund layer) — `wantsAfter()`; caps the distinct investors across the share classes of one `Fund`. The count and each investor's class mask live in `Fund` (state), not in the rule (policy), so a replaced rule keeps the count. An investor is a non-exempt account holding at least one class, counted once however many. A move to an existing investor, a burn and FORCED are never capped (FORCED is still counted); a new investor passes when count < cap, or when count == cap and the move empties the sender's only class (net zero); above a lowered cap nobody new is admitted. `cap == 0` fails closed. A token that is not a registered class of the fund, or a rule that is not the fund's installed one, is rejected on every movement with `NOT_FUND_CLASS`. `checkSend` and `checkReceive` answer only that class check: the cap is `check`'s alone, so a new investor at a full fund reads eligible at account level, and a mint or a partial transfer to it is refused with `MAX_HOLDERS`. The class itself (the 7540 escrow) never counts. `Fund.isClassIntact(token)` and `Fund.firstBrokenClass()` are the monitor: a class is intact when it is registered and its hook still lists the fund's installed rule (a hook accepts any attested list, so dropping the rule un-caps the class silently, and replacing the rule leaves every class failing closed until its list names the new one). Unlike the other rules its state is shared by every class, so it is sound only because the fund accepts `join` and `leave` from the installed rule alone, and only for a registered class (`registerClass`: owner, ERC-165 `IPolicyGated`, hook lists the rule, supply zero), which also means no seed exists.

## 7. Vault templates

`Gated4626Vault` = OZ `ERC4626Upgradeable` + `PolicyGatedERC20Upgradeable`. Shares are the gated ERC-20; `deposit`/`mint` to `receiver` arrive at the hook as `MINT`, `withdraw`/`redeem` as `BURN`, so identity gating on vault entry/exit is automatic. The asset leg is an ordinary ERC-20 pull/push and is not hooked. Resolve the `_update` diamond explicitly (`override(ERC20Upgradeable, PolicyGatedERC20Upgradeable)`).

**Gating-aware `max*` (both vaults).** This is how ERC-4626 expresses permissioning and what integrators check before calling. `maxDeposit(receiver)` / `maxMint(receiver)` return `0` when paused or when a mint of a very large amount to `receiver` would be rejected (`_mintProbe`: the base's `_canTransfer(address(0), receiver, type(uint128).max)`; identity, freeze, the holder caps). The amount is not zero, so a holder cap sees a new holder and refuses it, and it is above any minimum position up to `type(uint128).max`, so such a minimum does not read as a block (a one-wei probe would). A rule that bounded the size of a position (a supply cap, a maximum balance) would refuse the probe and zero `max*`; none of the shipped rules does. `maxRedeem(owner)` is the unfrozen balance (`balanceOf(owner) - getFrozenTokens(owner)`, zero when frozen exceeds it) and returns `0` when paused or when a burn of nothing from `owner` would be rejected (`canTransfer(owner, address(0), 0)`: identity, freeze, lockup); the size of a real redemption is judged when it burns. `maxWithdraw(owner)` is always `_convertToAssets(maxRedeem(owner), Math.Rounding.Floor)`, never `super.maxWithdraw(owner)` minus the frozen value, so rounding can never promise more assets than `withdraw` can deliver (`previewWithdraw` rounds shares up). `preview*` stay pure conversions; the gating lives in `max*`. Tests assert the meaningful form: a blocked receiver has `maxDeposit == 0` and the smallest deposit reverts (an allowed receiver's `maxDeposit` is `type(uint256).max`, and even `deposit(0)` reverts for a receiver that identity or a freeze blocks, while a holder cap does not judge a zero amount; with a minimum set, an empty receiver's `maxDeposit` is still `type(uint256).max` and a deposit below the minimum reverts with `BELOW_MIN_POSITION`); redemptions keep the exact form, `redeem(maxRedeem(o))` succeeds (except where a minimum is set and a frozen amount below it would stay behind: the minimum judges the whole balance, `maxRedeem` the unfrozen part) and `redeem(maxRedeem(o) + 1)` reverts.

`Gated7540Vault` — implement against the EIP-7540 interface (OZ does not ship one): `requestDeposit`/`requestRedeem` record pending claims per controller; a `FULFILLER_ROLE` (the bank) fulfils; `deposit`/`redeem` claim into gated shares (`MINT`/`BURN` through the hook). 7540 is already request/claim, so do not add `IntentSettled` on top of it — the request is the intent and `FULFILLER_ROLE` is the executor. 7540 operators are full delegates per the standard; owners should approve only custodians they'd trust with the assets (owner decision L-5: an operator can also create requests that pull the owner's assets or shares under any controller). The escrowing vault must pass the token's policy as a receiver (the demo's KYC attester credentials it); being the token itself, it is never counted by `FundHoldersRule` or judged by `MinPositionRule` (where a class lists `MaxHoldersRule`, its admin must exempt the vault there with `setExemptHolder(token, token, true)`). `FULFILLER_ROLE` can `rejectDepositRequest` / `rejectRedeemRequest` (assets back; shares back to the controller as a plain TRANSFER, so cap, pause, lockup, freeze and minimum all apply; if blocked, the reject reverts and the agent uses `recoverRedeemRequest`; owner decision M-2, reversing R2). If the controller can no longer receive (blocked, lapsed or exit-only), `AGENT_ROLE` uses `recoverRedeemRequest(controller, to)`, an enforcement action. It clears the pending bookkeeping and FORCED-moves the escrow to a recovery account that passes the token's policy, emitting `RedeemRequestRecovered`. Every fulfilment emits `Fulfilled(controller, isDeposit, price, assets, shares, fulfiller)`, where `price` is assets per `10**decimals()` shares (never below 1). `convertTo*` use the last price, and `totalAssets` is indicative. Compliance holds after fulfilment: `requestDeposit` and the deposit claim re-run the mint probe `maxDeposit` uses, and redemption payouts re-run a zero-amount burn probe `canTransfer(controller, address(0), 0)` (identity, freeze, lockup, pause; the 4626 `maxRedeem` uses the same probe). A request cannot know how many shares it will buy, so a fresh controller is not refused for size: if the shares claimed, added to what the receiver already holds, come to less than the minimum, the claim reverts with `BELOW_MIN_POSITION` and the claimable stays, until the agent's `recoverClaimable` (an enforcement mint, exempt) delivers it or the fulfiller rejects the request before fulfilling. `recoverClaimable(controller, to)` (`AGENT_ROLE`) pays claimable redemption assets to `to` and delivers claimable deposit shares to `to` as an enforcement mint; `to` must pass the token's policy; it works while paused and at a full cap (the stranded-deposit case) and emits `ClaimableRecovered(controller, to, assets, shares, agent)`. This added function is the one post-freeze change to `IGated7540Vault` (re-pinned).

## 8. Phases

Each phase: update `PLAN.md` → tests → impl → `npx hardhat test` → stop for review.

* **Phase 0 — scaffold.** `npx hardhat --init` (TypeScript, ESM, node:test + viem). OZ v5. Solc pin, cancun, optimizer profile. `hardhat-keystore`. Lockfile committed.
* **Phase 1 — interfaces + errors.** §4 and §5 verbatim with NatSpec. Freeze.
* **Phase 2 — registry + base.** `PolicyRegistry` (immutable, tests: attest/revoke/kind, codehash comparison, role gates). `PolicyGatedERC20Upgradeable`: `ERC20PermitUpgradeable` + `AccessControlUpgradeable` + `PausableUpgradeable` + `UUPSUpgradeable` + `ReentrancyGuardTransient`, enforcement core, guardian, `_update` → hook. Tests with mock hooks: every entry point's role gate; guardian can pause and cannot unpause; `setPolicyHook` and `_authorizeUpgrade` reject unattested targets; frozen math; forced unfreezes; mint/burn reach hook with zero addresses; hook reject ⇒ no state change; `permit`; invariants `sum(balances) == totalSupply`, and a holder can move exactly the unfrozen balance (the frozen amount may exceed the balance).
* **Phase 3 — IntentSettled + IntentToken + executor.** EIP-712, per-signer used-nonce map (random nonces chosen by the signer's HSM/client, independent of executor state), `executeTransfer`, `cancelIntent`. `IntentExecutor` (immutable; `OPERATOR_ROLE` submits, guardian pauses, timelock unpauses; forward-only) holding the token's `EXECUTOR_ROLE`, with atomic `executeBatch` in the separate `IIntentExecutorBatch`. Tests: replay, expired, wrong domain/chainId, cancel race, malleability, role gating, `canExecute` parity.
* **Phase 4 — hooks.** `ComplianceHook` (shared, rules per token), `BaseRule`, initial rules, mocks. Ordering, short-circuit, reentrancy, cap.
* **Phase 5 — vaults.** `Gated4626Vault`, `Gated7540Vault`. Share mint/burn gated; gating-aware `max*`; 7540 request/fulfil/claim lifecycle; operator semantics.
* **Phase 6 — viem integration.** `signTypedData` → execute; vault flows; event decoding; pre-flight parity from the TypeScript side.
* **Phase 7 — deploy + security.** Ignition modules: `Components` (the timelocks, ≥7d; the registry; the one shared hook; the rules; one implementation per template; `ProxyDeployer`; the executors; the fund) → the council attests the rules, the hook and the implementations once (UUPS gives each implementation deployment its own codehash) → `Activate` (one proxy per token through `ProxyDeployer`, with its rule list in the init data; per-token configuration; roles, the guardian becoming a timelock canceller; hand-over to the timelock). The post-deploy check pins each token's hook and rule list and asserts every fund class is intact (`firstBrokenClass()` is the zero address). `npx @openzeppelin/upgrades-core validate`. Slither clean (`slither .`, accepted findings documented in `slither.config.json` and inline). Halmos on the nonce/signature and frozen-balance paths (`npm run test:halmos`; verified on 2026-10-16 that it runs on the proxied token with transient storage and kills planted bugs). **No Mythril:** it has no Cancun support (TSTORE/TLOAD/MCOPY), so it cannot analyse `ReentrancyGuardTransient` or the transient context slots.

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
