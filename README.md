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
CredentialRegistry (one per deployment)          who vouched for an address, what it is, until when, and its standing
CredentialRule, MinPositionRule, HolderRestrictionRule, SettlementWindowRule, MaxHoldersRule   hook-agnostic, shared across
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
| `contracts/interfaces/` | Frozen ABI: `IPolicyGated`, `IERC7943Fungible`, `ITemplated`, `IPolicyHook`, `IComplianceRule`, `IComplianceHook`, `IPolicyRegistry`, `ITransferIntent`, `IIntentExecutor`, `IIntentExecutorBatch`, `IDvPExecutor`, `IERC3009`, `IIdentityRule`, `IIdentityRegistry`, `ICredentialRegistry`, `ICredentialRule`, `Quals`, `IMinPositionRule`, `IHolderRestrictionRule`, `ISettlementWindowRule`, `IMaxHoldersRule`, `IFund`, `IFundHoldersRule`, `IProxyDeployer`, `IGovernanceTimelock`, `IGated4626Vault`, `IGated7540Vault`, `IERC7540Operator` / `IERC7540Deposit` / `IERC7540Redeem` / `IERC7575` (spec-exact ids), `Errors.sol` (reason codes) |
| `contracts/base/` | `PolicyGatedERC20Upgradeable` |
| `contracts/governance/` | `PolicyRegistry`, `GovernanceTimelock` |
| `contracts/identity/` | `CredentialRegistry` |
| `contracts/deploy/` | `ProxyDeployer`, `TokenProxy` |
| `contracts/mixins/`, `contracts/tokens/` | `IntentSettledUpgradeable`, `IntentToken` |
| `contracts/hooks/` | `ComplianceHook`, `BaseRule`, `rules/` `CredentialRule`, `IdentityRule`, `MinPositionRule`, `HolderRestrictionRule`, `SettlementWindowRule`, `MaxHoldersRule`, `FundHoldersRule` (in the recommended order; the demo lists no `IdentityRule` and no `MaxHoldersRule`) |
| `contracts/fund/` | `Fund` |
| `contracts/intents/` | `IntentExecutor`, `DvPExecutor` |
| `contracts/vaults/` | `Gated4626Vault`, `Gated7540Vault` |
| `contracts/test/` | Test helpers and mocks, interface-freeze and contract-size guards, Halmos properties |

Every contract except the abstract `BaseRule` has its `.t.sol` next to it. [`PLAN.md`](PLAN.md) tracks phases and decisions;
[`CLAUDE.md`](CLAUDE.md) is the build brief.

## Security model

The audit package (scope, suppressions, mutation results, findings an auditor should know first) is indexed in
[`SECURITY.md`](SECURITY.md).

| Power | Holder | Delay | Can |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | TimelockController | ≥ 7 days | grant/revoke every role, `unpause`, `setPolicyHook`, change the token's rule list on the hook, manage attesters |
| `GUARDIAN_ROLE` | multisig | none | `pause` the token and cancel pending main-timelock operations. **It can only stop things:** no unpause, no upgrades, no role or hook changes, and no veto over its own removal (see `RECOVERY_ROLE`) |
| `RECOVERY_ROLE` | recovery timelock | ≥ 7 days | on every token, vault and both executors: `unpause` and revoke `GUARDIAN_ROLE`; on the main timelock: revoke `CANCELLER_ROLE`; on the credential registry: revoke `GUARDIAN_ROLE`, clear a guardian block, revive an attester. Nothing else. Governance proposes and executes; nobody can cancel |
| `UPGRADER_ROLE` | timelock | ≥ 7 days | upgrade, only to an implementation attested as `IMPLEMENTATION` |
| `MINTER_ROLE` / `BURNER_ROLE` | issuer | none | mint, and burn (enforcement burns can take frozen tokens) |
| `AGENT_ROLE` | issuer | none | `forcedTransfer` (clawback; bypasses pause, frozen tokens and the sender's address freeze, still policy-checked: an address-frozen receiver refuses it), `setFrozenTokens`; on the 7540 vault, `recoverRedeemRequest` (escrow → recovery account whose credential the token's policy accepts) and `recoverClaimable` (claimable assets and shares → recovery account whose credential the token's policy accepts, even while paused or at a full cap) |
| `EXECUTOR_ROLE` | `IntentExecutor` and `DvPExecutor` contracts | none | settle holder-signed intents that name no executor or name that executor. `IntentExecutor` settles only intents that state no consideration; `DvPExecutor` settles trades. Neither can alter an intent |
| `OPERATOR_ROLE` (executors) | bank / relayer keys | none | submit intents via `execute` / `executeBatch` (all-or-nothing), or trades via `executeDvPGated` / `executeDvP3009` (both legs or neither) |
| `GUARDIAN_ROLE` (executors) | multisig | none | pause an executor only; the timelock or the recovery timelock unpauses |
| `ATTESTER_ROLE` (registry) | security council | none | attest / revoke codehashes |
| `GUARDIAN_ROLE` (credential registry) | multisig | none | block an address or kill an attester, and nothing else; the main or recovery timelock undoes it |
| attester (credential registry) | KYC provider, an account in the registry (≤ 64) | none | write a credential for an address within the qualification bits it may assert, or sign one that anyone submits; it can overwrite only an empty address, a record it wrote, or a killed attester's, and change the status only of records it wrote. The compromise limits are in [`docs/credentials.md`](docs/credentials.md) |
| token `DEFAULT_ADMIN_ROLE` → rules | timelock | ≥ 7 days | set a token's credential policy, its minimum position and its exemptions and its settlement window; where a class lists `MaxHoldersRule`, its holder cap and seed |
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
  policy rejection reverts with `PolicyGated_TransferRejected(bytes32 reason)`, the token's own frozen shortfall (an
  amount within the balance) with the standard's `ERC7943InsufficientUnfrozenBalance`, and an amount above the balance
  with the base's `ERC20InsufficientBalance`; `transfer` never returns `false`.
- **Pre-flight parity.** `canTransferWithReason` and `canExecute` run the same checks as the state-changing path.
  `canTransfer` runs them too, except that ERC-7943 forbids it to fail on a balance check: an amount above the balance
  reads true when the hook accepts it and no frozen amount is in the way (nothing frozen, or a burn by a sender that
  holds `BURNER_ROLE`), and the write reverts with `ERC20InsufficientBalance`.
  Use `canTransferWithReason` to learn whether a movement will succeed. `canSend` and `canReceive` are the
  account-level questions (ERC-7943): `canSend` is false while paused, for an account with no credential or a blocked one, an address-frozen account,
  a locked holder (a lapsed holder can send) and a token that is not a fund class; `canReceive` is false while paused, for an account without an active
  credential that the token's policy accepts, an address-frozen account and a token that is not a fund class. The holder caps are not in them: ERC-7943 says the
  account questions must not encode quantitative rules (it names balance checks and amount limits), and we read a cap the
  same way, so a cap decides a movement only. For a plain transfer through the shipped rules `canTransfer` is not true
  while either answer is false, but not for every kind: an enforcement burn passes for a locked holder while `canSend`
  says `LOCKED`. The vaults' `maxDeposit` and `maxMint` probe a mint of a very large amount instead.
- **Pause.** A guardian pause blocks every balance movement except FORCED ones (`forcedTransfer`, and the 7540 vault's `recoverRedeemRequest` and `recoverClaimable`), so the issuer's mint and burn too. Enforcement
  during a pause is `forcedTransfer` to a quarantine account, and the burn waits for the unpause. This differs from the
  ERC-3643 reference token, whose agents can mint, burn and force while paused (checked 2026-10-23; see the governance page
  in `docs/`).
- **Fund monitor.** `Fund.firstBrokenClass()` names the first class whose hook no longer lists the fund's rule, which the
  hook cannot know; the post-deploy check asserts it is the zero address.
- **Reentrancy.** `_update` is `nonReentrant` (transient storage), so no hook or rule can move balances during a
  movement; `check` is called as a view, and rules are attested.
- **Reproducible builds.** solc 0.8.30, cancun, optimizer 200 runs, and no metadata hash, in both Hardhat and forge.
  Every codehash and CREATE2 address can be recomputed from the source at a tag; CI fails if two clean builds disagree.
- **Deployment.** One implementation per template, deployed and attested once, with one proxy per token. Each
  implementation deployment has its own codehash, because UUPS stores `address(this)` in an immutable. Each proxy sits
  at a CREATE2 address fixed before it exists. `ProxyDeployer` refuses an implementation its registry has not attested
  as `IMPLEMENTATION`, initialises the proxy in the same transaction, and refuses to finish unless the token names that
  registry and the hook is installed and holds exactly the rules the deployer expected for that token (see the runbook
  below).

## Deployment runbook

Two Ignition modules in `ignition/modules/`, with one security-council step between them. `Activate` takes the addresses
`Components` produced as parameters. `test/nodejs/fixtures.ts` runs this exact sequence on the local network, playing the
council and the KYC attester, and ends with the post-deploy checks below.

1. **`Components`** (deployer):
   - the recovery timelock (plain OZ `TimelockController`, ≥ 7 days, governance multisig as proposer and executor),
     then the main timelock (`GovernanceTimelock`: ≥ 7 days, proposer **and** executor the governance multisig only;
     the recovery timelock may revoke `CANCELLER_ROLE` there). The deployer is the admin of both until `Activate`;
   - the `PolicyRegistry`: admin = timelock, attester = council;
   - the one shared `ComplianceHook`, whose only immutable is the registry;
   - the `CredentialRegistry` (admin = deployer until `Activate`, guardian = the guardian multisig);
   - the shared rules: `CredentialRule` (reads that registry), `MinPositionRule`, `HolderRestrictionRule`, `SettlementWindowRule`, `MaxHoldersRule`
     (the last is deployed and attested, listed on no token) and the `FundHoldersRule` that points at the fund;
   - one implementation per template, `ProxyDeployer` (owner = deployer, registry = the `PolicyRegistry`), `IntentExecutor` and `DvPExecutor` (neither is attested);
   - the `Fund` (owner = deployer).

   Parameters: `governance`, `council`, `guardian`, `minDelay`.
2. **Council step.** Attest only when two independent sources agree:
   - **Reproduce:** check out the release tag and run `npm ci && npm run verify:reproducible`. This builds from clean
     several ways, fails unless they all agree, and writes `release-build/manifest.json`.
   - **Compare with the published reference:** the release's `release-build-<tag>.tar.gz`, attached by the release
     workflow, after checking its `.sha256`. Its `manifest.json` must equal yours, contract by contract.
   - **Compare with the chain:** for each rule, the hook and each implementation, take the manifest's `runtime` code, fill
     its `immutableSlots` with the bytes at the same positions in the deployed code, and confirm those bytes are the
     expected constructor arguments (e.g. `CredentialRule`'s credential registry; the hook's registry; an implementation's own
     address). Then confirm the keccak256 of the result equals `extcodehash`.
   - For `FundHoldersRule`, also read the `Fund` it points at (`FUND()`): the rule's codehash covers the fund's address,
     not the fund's code. Check the fund's runtime code against the manifest's `Fund` entry, filling its `immutableSlots`
     (the registry address) as for the rules, and that its `owner()` is the deployer. `Fund` itself is not attested.
   - For `CredentialRule`, also read the `CredentialRegistry` it points at (`REGISTRY()`): the rule's codehash covers the
     registry's address, not the registry's code. Check the registry's runtime code against the manifest's
     `CredentialRegistry` entry, filling its `immutableSlots` as for the rules, that its admin is the deployer and its
     guardian the guardian multisig, and that it has no attester yet (`Activate` adds the first). It is not attested.
   - Then `attest(codehash, RULE | HOOK | IMPLEMENTATION, auditUri)` for each. The record for the change board reads:
     computed from the source at tag X, matched the release build, matched the chain.

   The hook has no token binding: its codehash is the same for every token, so one attestation of one hook covers the
   deployment. The rule lists are not part of any attestation; each token's initialiser installs its list, and
   `ProxyDeployer` and the post-deploy check compare it with `RULE_ORDER` (`ignition/modules/roles.ts`).

   Also compute where each token will live, before it exists:
   `CREATE2(ProxyDeployer, salt = keccak256(utf8(symbol)), initCode = TokenProxy.creationCode ++ abi.encode(implementation, ""))`,
   with `TokenProxy.creationCode` from `TokenProxy`'s build-info in `release-build/build-info/`, whose keccak256 is the
   manifest's `TokenProxy.creationKeccak`. `ProxyDeployer.predict(symbol,
   implementation)` returns the same address. Builds carry no metadata hash, so this code is the same in every clean
   build at the tag, and `verify:reproducible` checks that `ProxyDeployer` embeds exactly it.
3. **`Activate`** (deployer):
   - `ProxyDeployer.deploy(symbol, implementation, initData, hook, expectedRules)` for each token. The init data carries the
     token's rule list, which the token installs on the shared hook itself. `deploy` first refuses an implementation
     that its registry has not attested as `IMPLEMENTATION`. It initialises in the same transaction, then checks that the
     token names that registry, that the hook is installed, that it holds exactly `expectedRules` for the new token, and
     the symbol. A symbol can be used once; a reverted deploy (an unattested implementation, a token or hook that names
     another registry, an unattested rule, a failed `initialize`) leaves no proxy and does not use up the symbol. Every later call waits for all three deploys, so one
     token that fails its checks grants nothing anywhere;
   - configure the credential layer (parameter `kycAttester`, the KYC provider's account, and optionally `kycAllowedQuals`,
     255 by default): add it to the registry as attester 0, and give each token the policy "`KYC` from attester 0 and
     nothing more". Until a token has its policy its rule admits no receiver;
   - configure: the settlement window, and each token's minimum position (parameters `intentMinPosition`,
     `fundMinPosition` and `asyncFundMinPosition`; 0, the default, switches the rule off). There is no per-class holder cap
     and no escrow exemption to set: the fund counts investors across classes, and the 7540 vault is the token itself,
     which neither the fund rule nor the minimum counts;
   - configure the fund (parameter `fundHolderCap`): install its rule, set its cap, then register the three tokens as
     classes 1 to 3, one after another. Registration refuses a hook that does not list the rule and a token that has
     supply, so a mis-built list stops `Activate` before any role is granted;
   - grant roles: MINTER and BURNER on `IntentToken` and AGENT on every token to the issuer's accounts, EXECUTOR on
     `IntentToken` to `IntentExecutor` and `DvPExecutor`, FULFILLER to the bank, OPERATOR on both executors to the
     relayer, **UPGRADER to the timelock only**, CANCELLER on the timelock to the guardian, RECOVERY on every token, on
     the credential registry and on both executors to the recovery timelock;
   - hand over: DEFAULT_ADMIN_ROLE to the timelock on every token, on the credential registry and on both executors; the deployer renounces it there
     and on both timelocks; `ProxyDeployer` and `Fund` ownership move to the timelock, so any later token is placed, and
     any later class registered, through governance (schedule `deploy`, wait out the delay, execute).
4. **KYC attester:** credential the 7540 vault, which escrows pending redemptions, and then every holder
   (`CredentialRegistry.set`, or a signed credential that anyone submits).
5. **Post-deploy checks** (the fixture's `assertHandedOver`):
   - the deployer holds no role on either timelock, the policy registry, the credential registry, the tokens or either executor;
   - the timelock holds DEFAULT_ADMIN_ROLE everywhere and is the only UPGRADER;
   - every token's `policyHook()` is the hook the council attested, that hook's `REGISTRY()` is the registry, and its
     `rules(token)` equals `RULE_ORDER` for that token. A second hook on the same registry carries the same attested
     codehash and passes `ProxyDeployer`; this check is what refuses it;
   - the guardian can cancel main-timelock operations but cannot propose or execute them, and holds nothing on the
     recovery timelock;
   - the credential registry's guardian holds only `GUARDIAN_ROLE`; it has one attester, the KYC provider, not killed;
     the credential rule reads that registry and is attested; each token's policy is `KYC` from attester 0;
   - the recovery timelock holds exactly `RECOVERY_ROLE` on each token, vault, both executors, the credential registry and the main timelock,
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
npm run test:halmos   # symbolic properties: nonce/signature, frozen-balance, intent executor-binding, minimum-position, credential registry, fund and DvP paths
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

CI (`.github/workflows/ci.yml`) runs all of the above on every pull request and every push to `main`, except the
reproducibility check, which runs on pull requests into `main` and, through `release.yml`, on `v*` tags.

## Deviations from the brief

The brief is in [`CLAUDE.md`](CLAUDE.md). Where the code intentionally differs, it is recorded here:

- **More interface files.** Brief §3 names the core ones and says the rest follow: Wonderland standards give every
  contract an interface. Structs and enums live inside their interfaces, so there is no `Types.sol`.
- **Interfaces reopened.** The owner has reopened `contracts/interfaces/` on instruction several times, and
  `InterfaceFreeze.t.sol` dates each re-pin. The largest was the review items (2026-10-23 to 24: a shared hook, balances
  in `TransferContext.extra`, ERC-7943 Final, the template id, two new rules); the latest is `IProxyDeployer.REGISTRY()`
  (2026-10-27). They are frozen again at the ids and topics pinned there; [`PLAN.md`](PLAN.md) records each change.
- **Error naming.** Errors follow `<Contract>_<Name>`, e.g. `PolicyGated_TransferRejected(bytes32)`. Event
  parameters are `_camelCase`; topics are unaffected.
- **ERC-7943 Final.** `IPolicyGated` inherits `IERC7943Fungible` and the token advertises its id (`0x3edbb4c4`). The
  reasoned pre-flight is a second name, `canTransferWithReason`, and `ForcedTransferBy` carries the agent next to the
  standard's `ForcedTransfer`. The token's own frozen shortfall (an amount within the balance) reverts the standard's
  `ERC7943InsufficientUnfrozenBalance`, and an amount above the balance the base's `ERC20InsufficientBalance`; policy
  rejections keep `PolicyGated_TransferRejected`.
- **Extra reason codes.** `NO_HOOK`, `NO_RULES` and `NOT_FUND_CLASS` are appended.
- **`canTransfer` follows the standard where `canTransferWithReason` does not.** ERC-7943 (Final, checked 2026-10-24)
  says `canTransfer` must not return false on a balance check and must validate the unfrozen amount. It does not say
  which clause wins for an amount above the balance while something is frozen; `canTransfer` reads it as the draft ERC's
  reference does, so a one-unit freeze turns that answer false. So `canTransfer` reads true for an amount above the
  balance when the hook accepts it and no frozen amount is in the way (nothing frozen, or a burn by a sender that holds
  `BURNER_ROLE`), and false when a frozen amount keeps the amount from the unfrozen balance, above the balance too. The
  write reverts with `ERC7943InsufficientUnfrozenBalance` for an amount within the balance and
  `ERC20InsufficientBalance` above it. `canTransferWithReason` says no to every shortfall, with
  `INSUFFICIENT_UNFROZEN`, so for a balance shortfall it and `canExecute` say what the write does, and the boolean does
  not. [`PLAN.md`](PLAN.md) records the decision.
- **`canTransferWithReason` scope.** It, and the boolean `canTransfer`, model holder-driven movements, with the operator
  set to `from`. A simulated burn respects frozen tokens, except that a sender holding `BURNER_ROLE` is bounded by its
  balance in the reasoned answer, as the write is. The enforcement paths `burn` and `forcedTransfer` release frozen tokens first.
- **Duplicate rules.** A duplicate `ruleId` reuses `ComplianceHook_DuplicateRule`, so the frozen ABI is unchanged.
- **7540 operators are full delegates** (review L-5, owner decision): the code follows ERC-7540, so an approved
  operator can also create requests that pull the owner's assets or shares under any controller. Owners should approve
  only custodians they would trust with the assets. The brief previously said "claims only" and was corrected.
- **Deployment contracts.** Brief §3 lists `ProxyDeployer` and `TokenProxy` (in `contracts/deploy/`) without
  describing them, and brief §4 does not list `ProxyDeployer.deploy` among the places attestation is checked: it refuses
  an implementation not attested as `IMPLEMENTATION` and a token that names another registry. `TokenProxy`
  is OZ's `ERC1967Proxy` with only OZ's documented `_unsafeAllowUninitialized` override, so that it can be created
  without init data. That keeps its CREATE2 address independent of the hook; `ProxyDeployer` initialises it in the same
  transaction.
