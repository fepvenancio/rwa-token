# rwa-token — Gated Token Stack

Permissioned ERC-20 templates for institutional real-world assets. Every balance movement goes through one
mechanical base and an external, replaceable policy hook made of small, attested rules. One template adds
executor-settled transfers: the holder signs an EIP-712 intent, and an executor settles it. A `DvPExecutor` settles a
share trade against cash in one transaction. A `Fund` groups several of these tokens as share classes and counts its
investors across them.

> **Proprietary.** Copyright (c) 2026 Filipe Venancio. All rights reserved. See [LICENSE](LICENSE). No use, copying,
> modification or deployment without prior written permission.

## Architecture

```
PolicyGatedERC20Upgradeable        base: accounting, roles, enforcement, guardian, hook pointer (UUPS)
        ▲                                 every movement → TransferContext → hook.beforeTransfer → balances → afterTransfer
        │
IntentToken (+ IntentSettledUpgradeable)  holder-signed EIP-712 TransferIntent, settled by EXECUTOR_ROLE
Gated4626Vault (ERC-4626, gated max*, decimals offset 6), Gated7540Vault (ERC-7540 async, escrow, fulfiller)

ComplianceHook (one per deployment, immutable) ──► per token, an ordered list of ≤16 attested IComplianceRule (first
                                                 rejection wins); a token installs its own list when it is initialised
IdentityRule, MinPositionRule, HolderRestrictionRule, SettlementWindowRule, MaxHoldersRule   hook-agnostic, shared across
                                                 tokens; per-token config authorised live by the token's own roles
Fund (one per fund, owned by the timelock)       its classes, investor count and per-investor class mask
FundHoldersRule (one per fund)                   the rule in every class's hook that feeds the fund and enforces its cap
PolicyRegistry (one per deployment, immutable)  codehash allowlist: HOOK / RULE / IMPLEMENTATION
IntentExecutor (immutable)                       replaceable, role-gated submitter: execute + atomic executeBatch; refuses
                                                 an intent that states a consideration (it cannot enforce a payment)
DvPExecutor (immutable)                          role-gated: settles a share trade against cash, both legs or neither
```

| Path | Contents |
|---|---|
| `contracts/interfaces/` | Frozen ABI: `IPolicyGated`, `IERC7943Fungible`, `ITemplated`, `IPolicyHook`, `IComplianceRule`, `IComplianceHook`, `IPolicyRegistry`, `ITransferIntent`, `IIntentExecutor`, `IIntentExecutorBatch`, `IDvPExecutor`, `IERC3009`, `IIdentityRule`, `IIdentityRegistry`, `IMinPositionRule`, `IHolderRestrictionRule`, `ISettlementWindowRule`, `IMaxHoldersRule`, `IFund`, `IFundHoldersRule`, `IProxyDeployer`, `IGovernanceTimelock`, `IGated4626Vault`, `IGated7540Vault`, `IERC7540Operator` / `IERC7540Deposit` / `IERC7540Redeem` / `IERC7575` (spec-exact ids), `Errors.sol` (reason codes) |
| `contracts/base/` | `PolicyGatedERC20Upgradeable` |
| `contracts/governance/` | `PolicyRegistry`, `GovernanceTimelock` |
| `contracts/deploy/` | `ProxyDeployer`, `TokenProxy` |
| `contracts/mixins/`, `contracts/tokens/` | `IntentSettledUpgradeable`, `IntentToken` |
| `contracts/hooks/` | `ComplianceHook`, `BaseRule`, `rules/` `IdentityRule`, `MinPositionRule`, `HolderRestrictionRule`, `SettlementWindowRule`, `MaxHoldersRule`, `FundHoldersRule` (in the recommended order; the demo lists no `MaxHoldersRule`) |
| `contracts/fund/` | `Fund` |
| `contracts/intents/` | `IntentExecutor`, `DvPExecutor` |
| `contracts/vaults/` | `Gated4626Vault`, `Gated7540Vault` |
| `contracts/test/` | Test helpers and mocks, interface-freeze and contract-size guards, Halmos properties |

Every contract has its `.t.sol` next to it. [`PLAN.md`](PLAN.md) tracks phases and decisions;
[`CLAUDE.md`](CLAUDE.md) is the build brief.

## Security model

The audit package (scope, suppressions, mutation results, findings an auditor should know first) is indexed in
[`SECURITY.md`](SECURITY.md).

| Power | Holder | Delay | Can |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | TimelockController | ≥ 7 days | grant/revoke every role, `unpause`, `setPolicyHook`, change the token's rule list on the hook, manage attesters |
| `GUARDIAN_ROLE` | multisig | none | `pause` the token and cancel pending main-timelock operations. **It can only stop things:** no unpause, no upgrades, no role or hook changes, and no veto over its own removal (see `RECOVERY_ROLE`) |
| `RECOVERY_ROLE` | recovery timelock | ≥ 7 days | on every token, vault and both executors: `unpause` and revoke `GUARDIAN_ROLE`; on the main timelock: revoke `CANCELLER_ROLE`. Nothing else. Governance proposes and executes; nobody can cancel |
| `UPGRADER_ROLE` | timelock | ≥ 7 days | upgrade, only to an implementation attested as `IMPLEMENTATION` |
| `MINTER_ROLE` / `BURNER_ROLE` | issuer | none | mint, and burn (enforcement burns can take frozen tokens) |
| `AGENT_ROLE` | issuer | none | `forcedTransfer` (clawback; bypasses pause, frozen tokens and the sender's address freeze, still policy-checked: an address-frozen receiver refuses it), `setFrozenTokens`; on the 7540 vault, `recoverRedeemRequest` (escrow → verified recovery account) and `recoverClaimable` (claimable assets and shares → verified recovery account, even while paused or at a full cap) |
| `EXECUTOR_ROLE` | `IntentExecutor` and `DvPExecutor` contracts | none | settle holder-signed intents that name no executor or name that executor. `IntentExecutor` settles only intents that state no consideration; `DvPExecutor` settles trades. Neither can alter an intent |
| `OPERATOR_ROLE` (executors) | bank / relayer keys | none | submit intents via `execute` / `executeBatch` (all-or-nothing), or trades via `executeDvPGated` / `executeDvP3009` (both legs or neither) |
| `GUARDIAN_ROLE` (executors) | multisig | none | pause an executor only; the timelock unpauses |
| `ATTESTER_ROLE` (registry) | security council | none | attest / revoke codehashes |
| token `DEFAULT_ADMIN_ROLE` → rules | timelock | ≥ 7 days | set a token's minimum position and its exemptions and its settlement window; where a class lists `MaxHoldersRule`, its holder cap and seed |
| `Fund` owner | timelock | ≥ 7 days | register a class, set the fund's rule and investor cap, exempt an account. Only the installed rule records which classes an account holds |
| token `AGENT_ROLE` → rules | issuer | none | set or clear per-holder lockups, freeze or unfreeze a holder (`HolderRestrictionRule`) |
| `FULFILLER_ROLE` (7540 vault) | bank | none | fulfil deposits/redemptions at off-chain NAV; reject pending requests |

- **Attested code only.** Hooks, rules and implementations are installed only if their runtime codehash is attested.
  Attestation is checked at install time; revoking it later does not silently change a live token.
- **Attestation covers code, not the rule list; the list is governed by the timelock.** The hook's only immutable is its
  registry, so one attested codehash serves every token of the deployment. Each token's ordered rule list lives in
  storage; each rule is attested on its own, and only the token's admin (the timelock after the hand-over), or the token
  itself while it is being initialised, can set the list. Only the timelock can install another hook, which must name the
  token's own registry.
- **Immutable policy components.** Hooks and rules are never proxies. Changing one means deploying a new one and
  swapping it in through the timelock. The hook's registry is `immutable`, so it is part of the attested codehash.
- **Upgrades stay on their template.** `_authorizeUpgrade` requires an implementation attested as `IMPLEMENTATION` and the
  same `templateId()`: an `IntentToken` proxy cannot be moved onto a vault implementation.
- **Fail closed.** `TRANSFER_OK` is non-zero, a hook with no rules rejects everything (`NO_RULES`), and a token that is
  not a registered class of its fund, or whose hook lists a rule the fund has replaced, rejects everything
  (`NOT_FUND_CLASS`). Every
  policy rejection reverts with `PolicyGated_TransferRejected(bytes32 reason)`, and the token's own frozen shortfall with
  the standard's `ERC7943InsufficientUnfrozenBalance`; `transfer` never returns `false`.
- **Pre-flight parity.** `canTransferWithReason`, `canTransfer` and `canExecute` run the same checks as the state-changing
  path. `canSend` and `canReceive` are the account-level questions (ERC-7943): `canSend` is false while paused, for an
  address-frozen account and for a locked holder; `canReceive` is false while paused, for an address-frozen account and,
  at a full holder cap, for an account that is not yet a holder.
- **Pause.** A guardian pause blocks every balance movement except FORCED ones (`forcedTransfer`, and the 7540 vault's `recoverRedeemRequest` and `recoverClaimable`), so the issuer's mint and burn too. Enforcement
  during a pause is `forcedTransfer` to a quarantine account, and the burn waits for the unpause. This differs from the
  ERC-3643 reference token, whose agents can mint, burn and force while paused (checked 2026-10-23; see the governance page
  in `docs/`).
- **Fund monitor.** `Fund.firstBrokenClass()` names the first class whose hook no longer lists the fund's rule, which the
  hook cannot know; the post-deploy check asserts it is the zero address.
- **Reentrancy.** `_update` is `nonReentrant` (transient storage); rules cannot call back into the token.
- **Reproducible builds.** solc 0.8.30, cancun, optimizer 200 runs, and no metadata hash, in both Hardhat and forge.
  Every codehash and CREATE2 address can be recomputed from the source at a tag; CI fails if two clean builds disagree.
- **Deployment.** One implementation per template, deployed and attested once, with one proxy per token. Each
  implementation deployment has its own codehash, because UUPS stores `address(this)` in an immutable. Each proxy sits
  at a CREATE2 address fixed before it exists, `ProxyDeployer` initialises it in the same transaction, and it refuses to
  finish unless the shared hook is installed and holds exactly the rules the deployer expected for that token (see the
  runbook below).

## Deployment runbook

Two Ignition modules in `ignition/modules/`, with one security-council step between them. `Activate` takes the addresses
`Components` produced as parameters. `test/nodejs/fixtures.ts` runs this exact sequence on the local network, playing the
council and the identity provider, and ends with the post-deploy checks below.

1. **`Components`** (deployer):
   - the recovery timelock (plain OZ `TimelockController`, ≥ 7 days, governance multisig as proposer and executor),
     then the main timelock (`GovernanceTimelock`: ≥ 7 days, proposer **and** executor the governance multisig only;
     the recovery timelock may revoke `CANCELLER_ROLE` there). The deployer is the admin of both until `Activate`;
   - the `PolicyRegistry`: admin = timelock, attester = council;
   - the one shared `ComplianceHook`, whose only immutable is the registry;
   - the shared rules: `IdentityRule`, `MinPositionRule`, `HolderRestrictionRule`, `SettlementWindowRule`, `MaxHoldersRule`
     (deployed and attested, listed on no token) and the `FundHoldersRule` that points at the fund;
   - one implementation per template, `ProxyDeployer` (owner = deployer), `IntentExecutor` and `DvPExecutor` (neither is attested);
   - the `Fund` (owner = deployer).

   Parameters: `governance`, `council`, `guardian`, `identityRegistry`, `minDelay`.
2. **Council step.** Attest only when two independent sources agree:
   - **Reproduce:** check out the release tag and run `npm ci && npm run verify:reproducible`. This builds from clean
     several ways, fails unless they all agree, and writes `release-build/manifest.json`.
   - **Compare with the published reference:** the release's `release-build-<tag>.tar.gz`, attached by the release
     workflow, after checking its `.sha256`. Its `manifest.json` must equal yours, contract by contract.
   - **Compare with the chain:** for each rule, the hook and each implementation, take the manifest's `runtime` code, fill
     its `immutableSlots` with the bytes at the same positions in the deployed code, and confirm those bytes are the
     expected constructor arguments (e.g. `IdentityRule`'s identity registry; the hook's registry; an implementation's own
     address). Then confirm the keccak256 of the result equals `extcodehash`.
   - For `FundHoldersRule`, also read the `Fund` it points at (`FUND()`): the rule's codehash covers the fund's address,
     not the fund's code. Check the fund's runtime code against the manifest's `Fund` entry, filling its `immutableSlots`
     (the registry address) as for the rules, and that its `owner()` is the deployer. `Fund` itself is not attested.
   - Then `attest(codehash, RULE | HOOK | IMPLEMENTATION, auditUri)` for each. The record for the change board reads:
     computed from the source at tag X, matched the release build, matched the chain.

   The hook has no token binding: its codehash is the same for every token, so one attestation of one hook covers the
   deployment. The rule lists are not part of any attestation; each token's initialiser installs its list, and
   `ProxyDeployer` and the post-deploy check compare it with `RULE_ORDER` (`ignition/modules/roles.ts`).

   Also compute where each token will live, before it exists:
   `CREATE2(ProxyDeployer, salt = keccak256(utf8(symbol)), initCode = TokenProxy.creationCode ++ abi.encode(implementation, ""))`,
   with `TokenProxy.creationCode` from the manifest's `TokenProxy.creation`. `ProxyDeployer.predict(symbol,
   implementation)` returns the same address. Builds carry no metadata hash, so this code is the same in every clean
   build at the tag, and `verify:reproducible` checks that `ProxyDeployer` embeds exactly it.
3. **`Activate`** (deployer):
   - `ProxyDeployer.deploy(symbol, implementation, initData, hook, expectedRules)` for each token. The init data carries the
     token's rule list, which the token installs on the shared hook itself; `deploy` initialises in the same transaction,
     then checks that the hook is installed, that it holds exactly `expectedRules` for the new token, and the symbol. A
     symbol can be used once; a reverted deploy (a hook that names another registry, an unattested rule, a failed
     `initialize`) leaves no proxy and does not use up the symbol. Every later call waits for all three deploys, so one
     token that fails its checks grants nothing anywhere;
   - configure: the settlement window, and each token's minimum position (parameters `intentMinPosition`,
     `fundMinPosition` and `asyncFundMinPosition`; 0, the default, switches the rule off). There is no per-class holder cap
     and no escrow exemption to set: the fund counts investors across classes, and the 7540 vault is the token itself,
     which neither the fund rule nor the minimum counts;
   - configure the fund (parameter `fundHolderCap`): install its rule, set its cap, then register the three tokens as
     classes 1 to 3, one after another. Registration refuses a hook that does not list the rule and a token that has
     supply, so a mis-built list stops `Activate` before any role is granted;
   - grant roles: MINTER, BURNER and AGENT to the issuer's accounts, EXECUTOR on `IntentToken` to `IntentExecutor` and `DvPExecutor`, FULFILLER to the
     bank, OPERATOR on both executors to the relayer, **UPGRADER to the timelock only**, CANCELLER on the timelock to the guardian;
   - hand over: DEFAULT_ADMIN_ROLE to the timelock on every token and on both executors; the deployer renounces it there
     and on the timelock; `ProxyDeployer` and `Fund` ownership move to the timelock, so any later token is placed, and
     any later class registered, through governance (schedule `deploy`, wait out the delay, execute).
4. **Identity provider:** verify the 7540 vault, which escrows pending redemptions.
5. **Post-deploy checks** (the fixture's `assertHandedOver`):
   - the deployer holds no role on either timelock, the registry, the tokens or either executor;
   - the timelock holds DEFAULT_ADMIN_ROLE everywhere and is the only UPGRADER;
   - every token's `policyHook()` is the hook the council attested, that hook's `REGISTRY()` is the registry, and its
     `rules(token)` equals `RULE_ORDER` for that token. A second hook on the same registry carries the same attested
     codehash and passes `ProxyDeployer`; this check is what refuses it;
   - the guardian can cancel main-timelock operations but cannot propose or execute them, and holds nothing on the
     recovery timelock;
   - the recovery timelock holds exactly `RECOVERY_ROLE` on each token, vault, both executors and the main timelock,
     nothing elsewhere, and has no cancellers (governance's automatic one is revoked in `Activate`);
   - the DvP executor's operator and guardian are the stack's, and `EXECUTOR_ROLE` on `IntentToken` is held by the two
     executors and by no account the stack knows about;
   - no rule exposes `hasRole` or `owner`: rules take their authority from the token's roles at call time;
   - `ProxyDeployer.owner()` and `Fund.owner()` are the timelock;
   - the fund's rule is the attested `FundHoldersRule`, whose `FUND()` is the fund, its cap is the intended one, its
     classes 1 to 3 are the three tokens, in that order, and every class is intact (`firstBrokenClass()` is the zero
     address);
   - `getMinDelay() ≥ 7 days` on both timelocks.

   The recovery timelock's proposer and executor is the governance multisig. A compromised governance multisig is
   out of scope for this control, by design: recovery bounds the guardian, not governance.

## Commands

Requires Node 24 (CI pins 24.21.0). Foundry v1.8.1, Python 3.12 with `ci/requirements.txt` (slither, halmos) and the
pinned Aderyn binary are needed only for the analysis commands.

```bash
npm ci
```

```bash
npm test              # Hardhat 3: Solidity (unit, fuzz, invariants, size + freeze guards) and node:test runners
```

```bash
npm run lint:sol      # solhint (Wonderland config), fails on any warning
```

```bash
npm run typecheck
```

```bash
npm run fmt:check     # forge fmt (Wonderland profile in foundry.toml)
```

```bash
slither .             # static-analysis gate; accepted findings in slither.config.json and inline
```

```bash
scripts/fetch-tool.sh aderyn   # installs the sha256-pinned Aderyn release binary (tools.lock) into .tools/bin
```

```bash
npm run aderyn        # second static-analysis gate (Cyfrin Aderyn); exclusions in aderyn.toml, the rest inline
```

```bash
pip install --require-hashes -r ci/requirements.txt   # slither + halmos with every dependency hash-pinned
```

```bash
npm run test:halmos   # symbolic properties: nonce/signature, frozen-balance, intent executor-binding, fund and DvP paths
```

```bash
npm run validate:upgrades   # OZ upgrades-core over a Foundry build with storage layouts
```

```bash
npm run verify:reproducible # identical bytecode across clean Hardhat (production, default) and forge builds; writes release-build/
```

CI runs the reproducibility check on pull requests into `main`. On a `v*` tag, `.github/workflows/release.yml` reruns it
and attaches `release-build-<tag>.tar.gz` (manifest plus in-scope build-info, with its sha256) to the release as the
council's reference.

CI (`.github/workflows/ci.yml`) runs all of the above on every push and pull request, except the reproducibility check
(pull requests into `main` and tags only).

## Deviations from the brief

The brief is in [`CLAUDE.md`](CLAUDE.md). Where the code intentionally differs, it is recorded here:

- **More interface files.** Brief §3 names the core ones and says the rest follow: Wonderland standards give every
  contract an interface. Structs and enums live inside their interfaces, so there is no `Types.sol`.
- **Interfaces reopened once.** The owner reopened `contracts/interfaces/` on 2026-10-23 for the review items (a shared
  hook, balances in `TransferContext.extra`, ERC-7943 Final, the template id, two new rules). They are frozen again at the
  ids and topics pinned in `InterfaceFreeze.t.sol`; [`PLAN.md`](PLAN.md) records each change.
- **Error naming.** Errors follow `<Contract>_<Name>`, e.g. `PolicyGated_TransferRejected(bytes32)`. Event
  parameters are `_camelCase`; topics are unaffected.
- **ERC-7943 Final.** `IPolicyGated` inherits `IERC7943Fungible` and the token advertises its id (`0x3edbb4c4`). The
  reasoned pre-flight is a second name, `canTransferWithReason`, and `ForcedTransferBy` carries the agent next to the
  standard's `ForcedTransfer`. The token's own frozen shortfall reverts the standard's
  `ERC7943InsufficientUnfrozenBalance`; policy rejections keep `PolicyGated_TransferRejected`.
- **Extra reason codes.** `NO_HOOK`, `NO_RULES` and `NOT_FUND_CLASS` are appended.
- **Fund layer.** `Fund`, `FundHoldersRule`, `IFund` and `IFundHoldersRule` are not in the brief. [`PLAN.md`](PLAN.md)
  records the design and the proposed brief edits.
- **Two known departures from ERC-7943's text** (checked against the Final text on 2026-10-24; [`PLAN.md`](PLAN.md) records
  both with options, and neither is changed yet):
  - `canReceive` answers the holder cap (`MaxHoldersRule`, `FundHoldersRule`): an account that is not yet a holder reads
    false at a full cap. The standard says `canSend` and `canReceive` must not encode quantitative rules, and that
    `canTransfer` must perform the `canReceive` check on the receiver; here a full-balance transfer to such an account
    still passes `canTransfer` (the net-zero exception of the cap), so the two answers disagree.
  - A plain transfer of more than the balance reverts with `ERC7943InsufficientUnfrozenBalance` and `canTransfer` returns
    false for it. The standard says `canTransfer` must not fail on balance checks, and that the base standard's error
    should be used when the amount exceeds the whole balance.
- **`canTransferWithReason` scope.** It, and the boolean `canTransfer`, model holder-driven movements, with the operator
  set to `from`. A simulated burn respects frozen tokens, except that a sender holding `BURNER_ROLE` is bounded by its
  balance, as the write is. The enforcement paths `burn` and `forcedTransfer` release frozen tokens first.
- **Duplicate rules.** A duplicate `ruleId` reuses `ComplianceHook_DuplicateRule`, so the frozen ABI is unchanged.
- **7540 operators are full delegates** (review L-5, owner decision): the code follows ERC-7540, so an approved
  operator can also create requests that pull the owner's assets or shares under any controller. Owners should approve
  only custodians they would trust with the assets. The brief previously said "claims only" and was corrected.
- **Deployment contracts.** `ProxyDeployer` and `TokenProxy` (in `contracts/deploy/`) are not in the brief. `TokenProxy`
  is OZ's `ERC1967Proxy` with only OZ's documented `_unsafeAllowUninitialized` override, so that it can be created
  without init data. That keeps its CREATE2 address independent of the hook; `ProxyDeployer` initialises it in the same
  transaction.
