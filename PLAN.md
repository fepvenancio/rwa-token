# PLAN

Status: **Phase 0 — scaffold (done, awaiting review)**

## Phase 0 — scaffold

### Goal
An empty Hardhat 3 project that compiles and runs both test runners green, with the toolchain pinned per CLAUDE.md §2 and §6. No product contracts yet.

### Versions (checked against npm on 2026-10-16)
| Package | Version |
|---|---|
| hardhat | 3.20.0 |
| @nomicfoundation/hardhat-toolbox-viem | 5.0.7 |
| @nomicfoundation/hardhat-keystore | 3.1.2 |
| @openzeppelin/contracts | 5.6.1 |
| @openzeppelin/contracts-upgradeable | 5.6.1 |
| forge-std | v1.16.2 (git dep from `hardhat --init`, commit pinned in lockfile) |
| viem / typescript / hardhat-ignition | 2.57.7 / 6.0.3 / 3.1.9 (from template, pinned exactly) |
| solc | **0.8.30**, pinned exactly (conservative choice); source pragmas `^0.8.28` |

Decisions (2026-10-16): git repo is `rwaToken/` itself. solc is 0.8.30. Mythril and Halmos are dropped from Phase 6: Mythril 0.24.8 has no TSTORE/TLOAD/MCOPY support, so it can't analyse `ReentrancyGuardTransient` under cancun, and Halmos is covered well enough by fuzz/invariant tests. Phase 6 = Slither + `upgrades-core validate`.

All npm deps are pinned exactly (no `^`) in `package.json`.

### Steps
1. **Git.** `rwaToken/` is not its own repo right now. It sits untracked inside `/Users/address0/Documents/Repos`, which is a repo with no commits. Proposal: `git init -b main` inside `rwaToken/` so the project has its own history. *(Needs confirmation, see Open questions.)*
   → verify: `git rev-parse --show-toplevel` prints `.../rwaToken`.
2. **Init.** Run `npx hardhat --init` and pick Hardhat 3, the TypeScript node:test + viem template, ESM. Then delete the sample `Counter.sol`, `Counter.t.sol`, sample test and sample ignition module. They don't belong in the layout in §3.
   → verify: `npx hardhat --version` prints 3.20.0.
3. **Deps.** `npm i -E @openzeppelin/contracts@5.6.1 @openzeppelin/contracts-upgradeable@5.6.1 @nomicfoundation/hardhat-keystore@3.1.2`.
4. **`hardhat.config.ts`**:
   - `solidity.profiles.default`: `version: "0.8.37"`, `evmVersion: "cancun"`, optimizer off (fast test builds).
   - `solidity.profiles.production`: same, plus optimizer `enabled: true, runs: 200`. No `viaIR` unless a later phase needs it.
   - Register `hardhat-keystore`. Any future RPC URL or key goes in as `configVariable(...)`, which the keystore resolves. No `.env`.
   - Fuzz runs set in config (`test.solidity.fuzz.runs`, start at 256), not in inline NatSpec.
5. **Layout.** Create empty dirs from §3 with `.gitkeep`: `contracts/{interfaces,token,hooks,intents,test}`, `test/nodejs`, `ignition/modules`.
6. **Smoke tests.** These are temporary and get deleted at the start of Phase 1:
   - `contracts/test/Smoke.t.sol` imports `forge-std/Test.sol` and one OZ upgradeable import, and asserts `true`. This proves remappings and solc work.
   - `test/nodejs/smoke.test.ts` calls `network.connect()` and reads `chainId` through viem. This proves the node runner works.
7. **`.gitignore`**: `node_modules`, `artifacts`, `cache`, `types`, `coverage`, `ignition/deployments/chain-31337`, `.env*`, `.repo-audit/`, `.letta/`, `.DS_Store`.
8. **Verify.** Run `npx hardhat test` and paste the summary line.
9. **Commit** `package.json`, `package-lock.json`, the config, `.gitignore`, `CLAUDE.md`, `PLAN.md` and the skeleton. Message: `chore: phase 0 scaffold`.

### Done when
- `npx hardhat test` passes both runners and the output is pasted.
- solc is pinned exactly, evm is cancun, and the lockfile is committed.
- Nothing exists outside the §3 layout except standard config files.

### Open questions
1. **Git root.** Should I `git init` inside `rwaToken/`, or do you want it committed into the parent `Repos` repo? I recommend `git init` inside `rwaToken/`.
2. **solc pin.** 0.8.37 is the latest release. Should I use it, or a more conservative one, for example 0.8.30?
3. **`hardhat --init` is interactive.** I can drive it through your terminal tab, or hand-write the same files the template produces. I recommend running the real init so the output is canonical.

### As built (deviations from the steps above)
- **`network.create()`, not `network.connect()`.** `connect` is `@deprecated` in Hardhat 3.20 ("will be removed in a future version"). CLAUDE.md §6 still says `connect()`.
- **Keystore.** `hardhat-keystore` is already registered by `hardhat-toolbox-viem`. It's also listed explicitly in `package.json` and `plugins` so the dependency is intentional and pinned.
- **Template extras.** Kept `.agents/skills/` and the `.claude -> .agents` symlink (official Hardhat 3 / viem reference skills) and `.npmignore`. Removed `AGENTS.md`, because its layout conflicts with CLAUDE.md §3. Also removed `README.md`, `scripts/`, and the Counter contract/tests/ignition samples.
- **Networks.** Dropped the template's `hardhatOp` / `sepolia` examples. Phase 6 adds networks via `configVariable` (keystore-resolved).
- **Fuzz config.** `test.solidity.fuzz.runs = 256`. Invariant settings are left at defaults until Phase 2 needs them.
- **Expected solc warning.** solc warns about `tstore` in OZ `TransientSlot.sol`. This is the reentrancy-guard case the warning itself calls safe.

### Verification
```
npx hardhat test   →  2 passing (1 solidity, 1 nodejs)
npx tsc --noEmit   →  clean
```
