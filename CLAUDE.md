# Executor-Settled Permissioned Token — Build Brief

Drop this file in the repo root as `CLAUDE.md`. It is the standing instruction set for every Claude Code session in this project.

## 1. What we are building

A permissioned ERC-20 where transfers are **holder-signed intents executed by an EXECUTOR role**, with compliance and identity enforced through **external policy hooks**. Reference implementation for a possible future ERC; for now it is a well-tested library.

Three layers, kept separate:

1. **Token** — `IntentToken`: OZ v5 upgradeable ERC-20 (UUPS). Plain `transfer`/`transferFrom` are gated by the policy hook like any 3643-style token. Adds executor-settled transfers.
2. **Policy hook** — one `IPolicyHook` address per token, timelocked replacement. Compliance, identity, sanctions, settlement-window checks live in hook implementations, never in the token.
3. **Executor** — `IntentExecutor`: role-gated contract that validates an EIP-712 `TransferIntent` signature and calls the token. Later extended to multi-leg atomic DvP.

## 2. Non-negotiable rules

1. OpenZeppelin v5 (`@openzeppelin/contracts`, `@openzeppelin/contracts-upgradeable`) only. No Solady. No other libs without asking.
2. No refactors outside the task you were given. Do not "improve" adjacent code.
3. Before any change touching more than one file, write or update `PLAN.md` and stop for review.
4. `contracts/interfaces/*.sol` are frozen after Phase 1. Changing them requires an explicit instruction.
5. Every contract ships with a `.t.sol` next to it. Tests are written **before** implementation and the failing run is shown.
6. Run `npx hardhat test` (both runners) before reporting any task as done. Paste the summary line.
7. `transfer()` must never return `true` without moving balance. If the hook rejects, revert with a typed error.
8. No secrets in `.env`. Use `hardhat-keystore`.
9. Solidity `^0.8.28` (pin exact in config), `evmVersion: "cancun"`.
10. Follow OZ's own patterns as the oracle. When unsure how to do nonces/domains/roles, mirror `ERC20Permit`, `EIP712Upgradeable`, `AccessControlUpgradeable`.

## 3. Repo layout

```
contracts/
  interfaces/   ITransferIntent.sol  IPolicyHook.sol  IIntentExecutor.sol  Errors.sol
  token/        IntentToken.sol  IntentToken.t.sol
  hooks/        IdentityHook.sol  ComplianceHook.sol  hooks.t.sol
  intents/      IntentExecutor.sol  IntentExecutor.t.sol
  test/         MockRejectHook.sol  MockAcceptHook.sol  MockIdentityRegistry.sol
test/nodejs/    *.test.ts   (viem + node:test: EIP-712 signing, settlement flows)
ignition/modules/
PLAN.md
```

## 4. Interfaces (Phase 1 target — implement exactly, then freeze)

```solidity
struct TransferIntent {
    address from;
    address to;
    uint256 amount;
    bytes32 nonce;      // ERC-3009-style random nonce, bitmap-tracked
    uint256 deadline;   // unix seconds, inclusive
    bytes32 ref;        // off-chain reference (ISO 20022 msgId hash / bizId)
}

interface ITransferIntent {
    event IntentExecuted(bytes32 indexed intentHash, address indexed from, address indexed to, uint256 amount, address executor, bytes32 ref);
    event IntentCancelled(bytes32 indexed intentHash, address indexed from, bytes32 nonce);

    function canExecute(TransferIntent calldata intent) external view returns (bool ok, bytes32 reason);
    function executeTransfer(TransferIntent calldata intent, bytes calldata sig) external returns (bytes32 intentHash);
    function cancelIntent(bytes32 nonce) external;
    function intentHash(TransferIntent calldata intent) external view returns (bytes32);
    function nonceUsed(address signer, bytes32 nonce) external view returns (bool);
}

interface IPolicyHook {
    /// MUST be view. Returns its own selector on accept; reverts with a typed error carrying the bytes32 reason otherwise.
    function beforeTransfer(address from, address to, uint256 amount, address operator, bytes calldata hookData) external view returns (bytes4);
    function afterTransfer(address from, address to, uint256 amount, address operator, bytes calldata hookData) external returns (bytes4);
    function permissions() external view returns (bool before, bool after_);
}

interface IIntentExecutor {
    function execute(address token, TransferIntent calldata intent, bytes calldata sig) external returns (bytes32);
}
```

Semantics to spec in NatSpec and enforce in tests:

- `canExecute` MUST run the same `beforeTransfer` check as `executeTransfer`. Pre-flight never lies.
- `executeTransfer` callable only by `EXECUTOR_ROLE`. Executor cannot alter the intent, only execute or not.
- Nonces are per-signer, random, single-use. Cancel marks the nonce used.
- Deadline check is `block.timestamp <= deadline`.
- EIP-712 domain: name = token name, version `"1"`, chainId, verifyingContract. Use `EIP712Upgradeable`.
- `beforeTransfer` is called via `staticcall` semantics (it is `view`). `afterTransfer` runs after balances update, inside `ReentrancyGuardTransient`.
- Hook address is read once per execution into a local; a registry change mid-tx cannot alter the outcome.
- Hook replacement goes through `TimelockController`. Emits `PolicyHookChanged(old, new)`.
- Reason codes: `bytes32` constants in `Errors.sol`, ERC-1594 style (`TRANSFER_OK`, `SENDER_NOT_VERIFIED`, `RECEIVER_NOT_VERIFIED`, `COMPLIANCE_REJECTED`, `INTENT_EXPIRED`, `NONCE_USED`, `BAD_SIGNATURE`).
- ERC-165 for all three interfaces.

## 5. Phases

Each phase: update `PLAN.md` → tests → impl → `npx hardhat test` → stop for review.

**Phase 0 — scaffold**
`npx hardhat --init` (TypeScript, ESM, node:test + viem). Add OZ v5. Configure solc pin, cancun, optimizer profile. Add `hardhat-keystore`. Commit lockfile.

**Phase 1 — interfaces + errors**
Write the four interface files from §4 with full NatSpec. No implementation. Freeze.

**Phase 2 — token**
`IntentToken`: `ERC20Upgradeable` + `EIP712Upgradeable` + `AccessControlUpgradeable` + `UUPSUpgradeable` + `ReentrancyGuardTransient`. Single `_update` override that calls the policy hook. Executor-settled path. Tests: unit, fuzz on amount/nonce/deadline, invariants (`sum(balances) == totalSupply`; no execution without valid sig; cancelled nonce never executes; hook reject ⇒ no balance change).

**Phase 3 — hooks**
`IdentityHook` (adapter over an `IIdentityRegistry` with `isVerified(address)`), `ComplianceHook` (ordered list of `IComplianceRule`, first failure wins), mocks. Tests: ordering, short-circuit, permissions flags respected, hook cannot reenter token.

**Phase 4 — executor**
`IntentExecutor` with `EXECUTOR_ROLE`, calls `token.executeTransfer`. Tests: role gating, replay, expired, wrong domain/chainId, cancel-before-execute race, signature malleability.

**Phase 5 — viem integration**
`test/nodejs/`: `signTypedData` → execute; same cases as Phase 4 from the TypeScript side; event decoding; `canExecute` parity with `executeTransfer`.

**Phase 6 — deploy + security**
Ignition module deploying proxies + timelock. `npx @openzeppelin/upgrades-core validate` on artifacts. Slither clean (document any accepted findings).

## 6. Hardhat 3 specifics

- Solidity tests: `.t.sol` files, Foundry-style `setUp()` / `test*` / `testFuzz*` / `invariant*`. Cheatcodes via `forge-std` `Test`.
- No inline NatSpec fuzz config; no fixture cheatcodes. Use config for fuzz runs.
- `npx hardhat test solidity` / `npx hardhat test nodejs` / `npx hardhat test` for both.
- ESM project: `.ts` imports with explicit extensions where required; `node:test` + `viem` from `hardhat/viem` via `network.connect()`.
- Stack traces and `console.log` work in `.t.sol`.

## 7. Definition of done (per phase)

1. `PLAN.md` reflects what was built.
2. All tests pass in both runners; output pasted.
3. New contracts have NatSpec on every external function.
4. No interface drift (diff `contracts/interfaces/` against Phase 1 is empty).
5. No files touched outside the phase scope.
