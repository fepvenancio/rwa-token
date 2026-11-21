# Gated Token Stack

Permissioned ERC-20 templates for institutional real-world assets. Every balance movement goes through one
mechanical base and an external, replaceable policy hook made of small, attested rules. One template adds
executor-settled transfers: the holder signs an EIP-712 intent, and an executor settles it. A `DvPExecutor` settles a
share trade against cash in one transaction. A `Fund` groups several of these tokens as share classes and counts its
investors across them.

**Documentation:** the HTML pages in [`docs/`](docs/index.html): an overview, one page per contract, and pages on roles,
a single movement, deployment and governance, and where the money sits.

> **Proprietary.** Copyright (c) 2026 Filipe Venancio. All rights reserved. See [LICENSE](LICENSE). No use, copying,
> modification or deployment without prior written permission.

## Architecture

```
PolicyGatedCoreUpgradeable         core: roles, guardian and recovery, pause, hook pointer, registry, upgrade checks (UUPS)
        ▲
        ├── PolicyGatedERC20Upgradeable   fungible base: accounting, frozen amounts, enforcement
        │        ▲                        every movement → TransferContext → hook.checkTransfer → balances → afterTransfer
        │        │
        │   GatedToken                                the base and nothing else
        │   IntentToken (+ IntentSettledUpgradeable)  holder-signed EIP-712 TransferIntent, settled by EXECUTOR_ROLE
        │   Gated4626Vault (ERC-4626, gated max*, decimals offset 6), Gated7540Vault (ERC-7540 async, dealt in periods, escrow, settled by a NavDesk)
        │
        ├── Gated721                      ERC-721, a metadata URI per token; ERC-7943 freeze per account and token
        │
        └── Gated1155                     ERC-1155, a supply and a URI per token id; ERC-7943 frozen amount per account and id;
                                          a batch is its items in order, each one checked, moved and reported on its own

ComplianceHook (one per deployment, immutable) ──► per token, an ordered list of ≤16 attested IComplianceRule (first
                                                 rejection wins); a token installs its own list when it is initialised
CredentialRegistry (per core, or a named one)    who vouched for an address, what it is, until when, and its standing
CredentialRule, MinPositionRule, HolderRestrictionRule, SettlementWindowRule, SupplyCapRule, ExecutedOnlyRule
                                                 hook-agnostic, shared across tokens; per-token config authorised live by
                                                 the token's own roles
Fund (one per fund, owned by the timelock)       its classes, investor count and per-investor class mask
FundHoldersRule (one per fund)                   the rule in every class's hook that feeds the fund and enforces its cap
PolicyRegistry (one per deployment, immutable)  codehash allowlist: HOOK / RULE / IMPLEMENTATION / PORTFOLIO /
                                                 ADAPTER / VALIDATOR / FEE_MODEL
IntentExecutor (immutable)                       replaceable, role-gated submitter: execute + atomic executeBatch; refuses
                                                 an intent that states a consideration (it cannot enforce a payment)
DvPExecutor (immutable)                          role-gated: settles a share trade against cash, both legs or neither
OrderSettlement (immutable)                      role-gated: settles signed orders in parts and in batches, under allowances
SignedEntry (immutable)                          enters a vault on one signature, a relayer paying the gas
SignedExit (immutable)                           leaves a vault on signatures; delivers a 7540's settled claims
Portfolio (one per vault, immutable)             where the vault's money may go: idle, or adapters within caps
GuardedAccount, ERC4626Adapter                   the adapters: a custodian's account with default-deny calls, an outside vault
NavDesk (one per 7540 vault, immutable)          a reported value becomes a price two people approved, on a schedule; holds the redemption gate's level
FeeModel (immutable)                             one view: the fee on a gross value, with a high-water mark and a hurdle
Distributor (one per token, immutable)           pays holders from an approved, funded Merkle root
```

| Path | Contents |
|---|---|
| `contracts/interfaces/` | Frozen ABI: `IPolicyGatedCore`, `IPolicyGated`, `IERC7943Fungible`, `IERC7943NonFungible`, `IERC7943MultiToken`, `IGated721`, `IGated1155`, `ITemplated`, `IERC8473`, `IERC8473Policy`, `IComplianceRule`, `IComplianceHook`, `IPolicyRegistry`, `ITransferIntent`, `IIntentExecutor`, `IIntentExecutorBatch`, `IDvPExecutor`, `IERC3009`, `IIdentityRegistry`, `ICredentialRegistry`, `ICredentialRule`, `Quals`, `IMinPositionRule`, `IHolderRestrictionRule`, `ISettlementWindowRule`, `ISupplyCapRule`, `IExecutedOnlyRule`, `IFund`, `IFundHoldersRule`, `IProxyDeployer`, `IGovernanceTimelock`, `IGatedVaultBase`, `IGated4626Vault`, `IGated7540Vault`, `IPortfolio`, `IAdapter`, `IERC4626Adapter`, `IGuardedAccount`, `ICallValidator`, `IERC20CallValidator`, `INavDesk`, `IFeeModel`, `ISignedEntry`, `ISignedExit`, `IDistributor`, `IERC7540Operator` / `IERC7540Deposit` / `IERC7540Redeem` / `IERC7575` (spec-exact ids), `Errors.sol` (reason codes) |
| `contracts/base/` | `PolicyGatedCoreUpgradeable`, `PolicyGatedERC20Upgradeable` |
| `contracts/governance/` | `PolicyRegistry`, `GovernanceTimelock` |
| `contracts/identity/` | `CredentialRegistry` |
| `contracts/deploy/` | `ProxyDeployer`, `TokenProxy` |
| `contracts/mixins/`, `contracts/tokens/` | `IntentSettledUpgradeable`, `GatedToken`, `IntentToken`, `Gated721`, `Gated1155` |
| `contracts/hooks/` | `ComplianceHook`, `BaseRule`, `rules/` `CredentialRule`, `MinPositionRule`, `HolderRestrictionRule`, `SettlementWindowRule`, `FundHoldersRule` (in the recommended order), `SupplyCapRule`, `ExecutedOnlyRule` |
| `contracts/fund/` | `Fund` |
| `contracts/portfolio/` | `Portfolio`, `ERC4626Adapter`, `GuardedAccount`, `ERC20CallValidator`, `ERC4626CallValidator`: where one vault's money may go |
| `contracts/nav/` | `NavDesk`, `FeeModel`: a 7540's price and the fee on it |
| `contracts/distribution/` | `Distributor`: dividends and coupons |
| `contracts/intents/` | `IntentExecutor`, `DvPExecutor`, `OrderSettlement`, `SignedEntry`, `SignedExit` |
| `contracts/vaults/` | `GatedVaultBase`, which both vaults inherit, `Gated4626Vault`, `Gated7540Vault`, and each vault's second contract, which its implementation creates: `Gated7540Settlement`, to which the 7540 hands its settlement and recovery functions, and `Gated4626Management`, to which the 4626 hands plugging a portfolio, the rate limit, the fee model and paying fees; with `Gated7540Common` and `Gated4626Common`, which each pair shares |
| `contracts/test/` | Test helpers and mocks, interface-freeze and contract-size guards, Halmos properties |

Every contract except the abstract `BaseRule`, `PolicyGatedCoreUpgradeable`, `Gated7540Common` and `Gated4626Common` has its `.t.sol` next to it; those four are tested through the contracts that inherit them. [`PLAN.md`](PLAN.md) tracks phases and decisions;
[`CLAUDE.md`](CLAUDE.md) is the build brief.

## Security model

The audit package (scope, suppressions, mutation results, findings an auditor should know first) is indexed in
[`SECURITY.md`](SECURITY.md).

The delays below are the timelocks' `minDelay`, 24 hours by default in `Core`. Both timelocks are `GovernanceTimelock`
and refuse less than 1 hour, at deployment and in `updateDelay` (`GovernanceTimelock_DelayBelowFloor`); the recovery
timelock is deployed with no recovery of its own. The post-deploy check asserts at least 24 hours on both and that the
two run the same code.

| Power | Holder | Delay | Can |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | TimelockController | ≥ 24 hours | grant/revoke every role, `unpause`, `installPolicy`, change the token's rule list on the hook, manage attesters |
| `GUARDIAN_ROLE` | multisig | none | `pause` the token and cancel pending main-timelock operations. **It can only stop things:** no unpause, no upgrades, no role or hook changes, and no veto over its own removal (see `RECOVERY_ROLE`) |
| `RECOVERY_ROLE` | recovery timelock | ≥ 24 hours | on every token, vault and both executors: `unpause` and revoke `GUARDIAN_ROLE`; on the main timelock: revoke `CANCELLER_ROLE`; on the credential registry: revoke `GUARDIAN_ROLE`, clear a guardian block, revive an attester. Nothing else. Governance proposes and executes; nobody can cancel |
| `UPGRADER_ROLE` | timelock | ≥ 24 hours | upgrade, only to an implementation attested as `IMPLEMENTATION` |
| `MINTER_ROLE` / `BURNER_ROLE` | issuer | none | mint, and burn (an enforcement action: it takes frozen tokens and is not stopped by the pause) |
| `AGENT_ROLE` | issuer | none | `forcedTransfer` (clawback; bypasses pause, frozen tokens and the sender's address freeze, still policy-checked: an address-frozen receiver refuses it), `setFrozenTokens`; on the 7540 vault, `recoverRedeemRequest` (one controller's escrow → recovery account whose credential the token's policy accepts; out of the vault's own address `forcedTransfer` takes only shares not booked to a pending redemption, and the vault's address cannot be frozen) and `recoverClaimable` (claimable assets and shares → recovery account whose credential the token's policy accepts, even while paused or at a full cap) |
| `EXECUTOR_ROLE` | `IntentExecutor` and `DvPExecutor` contracts | none | settle holder-signed intents that name no executor or name that executor. `IntentExecutor` settles only intents that state no consideration; `DvPExecutor` settles trades. Neither can alter an intent |
| `OPERATOR_ROLE` (executors) | issuer / relayer keys | none | submit intents via `execute` / `executeBatch` (all-or-nothing), or trades via `executeDvPGated` / `executeDvP3009` (both legs or neither) |
| `GUARDIAN_ROLE` (executors) | multisig | none | pause an executor only; the timelock or the recovery timelock unpauses |
| `ATTESTER_ROLE` (registry) | security council | none | attest / revoke codehashes |
| `GUARDIAN_ROLE` (credential registry) | multisig | none | block an address or kill an attester, and nothing else; the main or recovery timelock undoes it |
| attester (credential registry) | KYC provider, an account in the registry (≤ 64) | none | write a credential for an address within the qualification bits it may assert, or sign one that anyone submits; it can overwrite only an empty address, a record it wrote, or a killed attester's, and change the status only of records it wrote. The compromise limits are on the [`CredentialRegistry` page](docs/contracts/CredentialRegistry.html#compromise) |
| token `DEFAULT_ADMIN_ROLE` → rules | timelock | ≥ 24 hours | set a token's credential policy, its minimum position and its exemptions, its settlement window and its supply cap |
| `ProxyDeployer` owner | operations account | none | place a new product, only over an attested implementation. It touches nothing that exists |
| `Fund` owner | timelock | ≥ 24 hours | register a class, set the fund's rule and investor cap, exempt an account. Only the installed rule records which classes an account holds |
| token `AGENT_ROLE` → rules | issuer | none | set or clear per-holder lockups, freeze or unfreeze a holder (`HolderRestrictionRule`) |
| `ALLOCATOR_ROLE` (on a vault, asked by its `Portfolio` and `GuardedAccount`s) | fund manager | none | send money to an installed adapter within caps (not while the vault is paused), bring it back, choose the liquidity adapter |
| `SETTLER_ROLE` (7540 vault) | a `NavDesk` | none | close and settle periods; take a request back once its period has closed |
| `REPORTER_ROLE`, `CHECKER_ROLE` (on a vault, asked by its `NavDesk`) | fund administration; risk or the depositary | none | propose a price; accept or cancel one. An account cannot accept its own proposal |
| `DISTRIBUTION_MAKER_ROLE`, `CHECKER_ROLE` (on a token, asked by its `Distributor`) | corporate actions; a second function | none | propose a distribution; approve one and pull its funding. An account cannot approve its own |

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
  policy rejection reverts with ERC-8473's `ERC8473PolicyRejected(bytes32 reason)`, also when the policy cannot be asked
  (`CHECK_UNAVAILABLE`), the token's own frozen shortfall (an
  amount within the balance) with the standard's `ERC7943InsufficientUnfrozenBalance`, and an amount above the balance
  with the base's `ERC20InsufficientBalance`; `transfer` never returns `false`.
- **Pre-flight parity.** `canTransferWithReason` and `canExecute` run the same checks as the state-changing path.
  `canTransfer` runs them too, except that ERC-7943 forbids it to fail on a balance check: an amount above the balance
  reads true when the hook accepts it and nothing is frozen on the sender, and the write reverts with
  `ERC20InsufficientBalance`. No pre-flight depends on who asks, and none reverts: a hook that cannot be asked reads false.
  Use `canTransferWithReason` to learn whether a movement will succeed. `canSend` and `canReceive` are the
  account-level questions (ERC-7943): `canSend` is false while paused, for an account with no credential or a blocked one, an address-frozen account,
  a locked holder (a lapsed holder can send) and a token that is not a fund class; `canReceive` is false while paused, for an account without an active
  credential that the token's policy accepts, an address-frozen account and a token that is not a fund class. The fund's investor cap is not in them: ERC-7943 says
  the account questions must not encode quantitative rules (it names balance checks and amount limits), and we read the
  cap the same way, so it decides a movement only. For a plain transfer through the shipped rules `canTransfer` is not true
  while either answer is false, but not for every kind: an enforcement burn passes for a locked holder while `canSend`
  says `LOCKED_UP`. The vaults' `maxDeposit` and `maxMint` probe a mint of a very large amount instead.
- **Pause.** A guardian pause blocks every balance movement except FORCED ones (`forcedTransfer`, the issuer's `burn`, and the 7540 vault's `recoverRedeemRequest` and `recoverClaimable`), so the issuer's mint too. Enforcement
  during a pause is `forcedTransfer` to a quarantine account, or `burn`. This differs from the
  ERC-3643 reference token, whose agents can also mint while paused (the incident runbook in [Deployment and governance](docs/deployment.html) shows what a pause stops here).
  A vault's pause also stops `Portfolio.allocate` and `GuardedAccount.execute`, and `deallocate` still brings money back.
- **Fund monitor.** `Fund.firstBrokenClass()` names the first class whose hook no longer lists the fund's rule, which the
  hook cannot know; the post-deploy check asserts it is the zero address. Alert too when `holderCount()` is above
  `holderCap()`: a recovery from a 7540 vault can put it there, and the agent should reject deposit requests near
  the cap (see [SECURITY.md](SECURITY.md)).
- **Reentrancy.** `_move` is `nonReentrant` (transient storage), so no hook or rule can move balances during a
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

One core per issuer, then one product at a time, so an issuer runs many products on one set of timelocks, one guardian, one
hook and one credential registry, and a client is verified once. A core may instead read an existing credential registry,
another issuer's (**Using an existing credential registry**, below). Someone who wants one product alone deploys the core and
that product, with the same code. `ignition/profiles.ts` names the combinations: `token`, `nft` (one ERC-721, a certificate or a note per token), `multi` (one ERC-1155, several series of one instrument), `intent` (one intent token with both executors), `cash` (the money of a deployment: an intent token with six decimals, a credential rule and a supply cap), `vault4626`, `vault7540` (a fund with one custodian and a desk),
`managed-fund` (custodians, a mandate and fees, no on-chain yield), `vault4626-invest` (an instant vault investing through a
portfolio), `master-feeder` (a master vault and two feeder classes with their own investors and fees), and `full`, which keeps a plain settler account so that a test can price at will.
`PROFILE` chooses one for `hardhat ignition deploy`, and `PRODUCT` one of its products; `full` and its first product are the
defaults. Each module takes the addresses the earlier ones produced as parameters. `test/nodejs/fixtures.ts` runs this
exact sequence on the local network, playing the council and the KYC attester, and ends with the post-deploy checks below.

1. **`Core`** (deployer):
   - the recovery timelock (`GovernanceTimelock` with no recovery of its own, 24 hours, governance multisig as proposer
     and executor),
     then the main timelock (`GovernanceTimelock`: 24 hours, proposer **and** executor the governance multisig only;
     OpenZeppelin also makes every proposer a canceller, so governance can cancel there too, and `CoreHandover` adds the
     guardian; the recovery timelock may revoke `CANCELLER_ROLE` there). The deployer is the admin of both until `CoreHandover`;
   - the `PolicyRegistry`: admin = timelock, attester = council;
   - the one shared `ComplianceHook`, whose only immutable is the registry;
   - `ProxyDeployer` (owner = deployer until `CoreHandover`, registry = the `PolicyRegistry`);
   - and only what the profile's products use:
     - the `CredentialRegistry` (admin = deployer until `CoreHandover`, guardian = the guardian multisig) and the `CredentialRule` that reads it, unless the profile reads an existing registry;
     - each other listed rule: `MinPositionRule`, `HolderRestrictionRule`, `SettlementWindowRule`, `SupplyCapRule`, `ExecutedOnlyRule`;
     - one implementation per template, shared by every product of that template;
     - `IntentExecutor` and `DvPExecutor` (neither is attested);
     - the one `OrderSettlement`, if the profile sets `orderSettlement` (not attested; no role on any token);
     - the one `SignedEntry`, if the profile sets `signedEntry` (not attested; no role and no money).
     - the one `SignedExit`, if the profile sets `signedExit` (not attested; no role and no money).
     - the one `LienVault`, if the profile sets `lienVault` (not attested; no role; it holds pledged tokens, so the attester
       credentials it on each token that may be pledged).

   Parameters: `governance`, `council`, `guardian`, `minDelay`. These parts are `deployParts` in `ignition/parts.ts`, which
   also adds parts to a core that already runs (below).
2. **Council step.** Attest only when two independent sources agree:
   - **Reproduce:** check out the release tag and run `npm ci && npm run verify:reproducible`. This builds from clean
     several ways, fails unless they all agree, and writes `release-build/manifest.json`.
   - **Compare with the published reference:** the release's `release-build-<tag>.tar.gz`, attached by the release
     workflow, after checking its `.sha256`. Its `manifest.json` must equal yours, contract by contract.
   - **Compare with the chain:** for each rule, the hook and each implementation, take the manifest's `runtime` code, fill
     its `immutableSlots` with the bytes at the same positions in the deployed code, and confirm those bytes are the
     expected constructor arguments (e.g. `CredentialRule`'s credential registry; the hook's registry; an implementation's own
     address). Then confirm the keccak256 of the result equals `extcodehash`.
   - For `CredentialRule`, also read the `CredentialRegistry` it points at (`REGISTRY()`): the rule's codehash covers the
     registry's address, not the registry's code. Check the registry's runtime code against the manifest's
     `CredentialRegistry` entry, filling its `immutableSlots` as for the rules, that its admin is the deployer and its
     guardian the guardian multisig, and that it has no attester yet (`CoreHandover` adds the first). It is not attested.
   - Then `attest(codehash, RULE | HOOK | IMPLEMENTATION, auditUri)` for each. The record for the change board reads:
     computed from the source at tag X, matched the release build, matched the chain.

   The hook has no token binding: its codehash is the same for every token, so one attestation of one hook covers the
   deployment. The rule lists are not part of any attestation; each token's initialiser installs its list, and
   `ProxyDeployer` and the post-deploy check compare it with the product's list in `ignition/profiles.ts`.

   Also compute where each token will live, before it exists:
   `CREATE2(ProxyDeployer, salt = keccak256(utf8(symbol)), initCode = TokenProxy.creationCode ++ abi.encode(implementation, ""))`,
   with `TokenProxy.creationCode` from `TokenProxy`'s build-info in `release-build/build-info/`, whose keccak256 is the
   manifest's `TokenProxy.creationKeccak`. `ProxyDeployer.predict(symbol,
   implementation)` returns the same address. Builds carry no metadata hash, so this code is the same in every clean
   build at the tag, and `verify:reproducible` checks that `ProxyDeployer` embeds exactly it.
3. **`CoreHandover`** (deployer):
   - configure the credential layer (parameter `kycAttester`, the KYC function's account, and optionally `kycAllowedQuals`,
     1023 by default, the ten named qualification bits): add it to the registry as attester 0;
   - grant the core's roles: CANCELLER on the timelock to the guardian, RECOVERY on the credential registry and on each
     executor to the recovery timelock, OPERATOR on each executor to the relayer;
   - hand over: DEFAULT_ADMIN_ROLE to the timelock on the credential registry and on each executor; the deployer renounces it
     there and on both timelocks; `ProxyDeployer` ownership moves to the operations account (parameter `operations`).

   **Adding to a running core.** A later product whose template, rules or executors the core lacks gets them without a
   second core. `CoreParts` (any account; parameter `guardian`) deploys every part of the profile that `CORE_HAS` does not
   list, so `CORE_HAS` must list the core's parts exactly, by key and separated by commas; it throws when `CORE_HAS` is
   unset or nothing is missing. Then the council attests the new rules and implementations as in step 2, then
   `PartsHandover` (the same account, the same `CORE_HAS`) does for the new credential registry and executors what this
   step does, before the product's `Legos` and `Product`. Another profile's `Core` would build a second set of timelocks,
   registry and hook.

   **Using an existing credential registry.** An issuer may read another core's `CredentialRegistry` instead of deploying
   its own, so an investor credentialed once there can hold both issuers' tokens. Its profile in `ignition/profiles.ts`
   sets `credentials: "external"` (no shipped profile does, so the issuer adds its own): `Core` and `CoreParts` then deploy no registry and no `CredentialRule`, and `CoreHandover` and
   `PartsHandover` configure none. The parameters name the existing rule (`credentialRule`; its `REGISTRY()` is the
   registry, so the two cannot disagree) and the governance the issuer accepts over that registry: `credentialAdmin`, the
   account that holds `DEFAULT_ADMIN_ROLE` there, and `credentialGuardian`, the one that holds `GUARDIAN_ROLE`. Choosing a
   registry gives those accounts a say over the issuer's tokens. The admin adds attesters, sets what each may assert and
   which account signs under each id, so it decides who does KYC for every token whose policy trusts those ids; the guardian,
   and the admin too, kill an attester, and the guardian blocks an investor, with no delay, on every token that reads the
   registry. Records are public, so
   one address is linked across the issuers that read them, and whether an issuer may rely on another's KYC is for the
   issuers to settle, not the code. The council reads that registry as in step 2 (its code against the manifest, its admin
   and guardian the named ones, its attesters) and attests the named rule as `RULE` in its own `PolicyRegistry`: the same
   codehash any other council attested. Each product's policy names which of that registry's attesters it trusts.
   Everything else stays the issuer's own: its timelocks, its `PolicyRegistry`, its hook and its upgrades. A token lists one
   `CredentialRule` (its `ruleId` is fixed, and a hook takes one rule per id), so it reads one registry.
4. **`Fund`** (the operations account), once per fund, if the products use one: a `Fund` (owner = the operations account) and
   the `FundHoldersRule` that points at it. An issuer has as many as it has funds, each with its own cap, and `FUND` chooses one
   for `hardhat ignition deploy`. Its `credentials` parameter is the core's credential registry, so that an investor's
   several addresses count once, or the zero address to count every address on its own. Then the council attests the rule as in step 2, after reading the `Fund` it points at
   (`FUND()`): the rule's codehash covers the fund's address, not the fund's code. Check the fund's runtime code against the
   manifest's `Fund` entry, filling its `immutableSlots` (the registry address) as for the rules, and that its `owner()` is the
   operations account. `Fund` itself is not attested.
5. **`Legos`, then `Product`** (the operations account), once per product. The first and the fiftieth follow this same path,
   and none waits for a timelock, because a launch only adds a proxy over attested code. A product with a desk, a portfolio,
   fees or a distributor first runs `Legos`, which builds them against `ProxyDeployer.predict(symbol, implementation)`, because each names its
   vault or token: the `NavDesk`, the `Portfolio`, a `GuardedAccount` and `ERC20CallValidator` per custodian, an `ERC4626Adapter` per
   outside vault, the `FeeModel`, and the `Distributor` of a product that sets `distributor` (parameters `vault`, `product`,
   `asset`, `feeRecipient`, `custodianAccount` for a desk with no portfolio, `custodian_<key>`, `target_<key>`). The council
   then attests them: the portfolio as `PORTFOLIO`, each account and adapter as `ADAPTER`, each validator as `VALIDATOR`, the
   fee model as `FEE_MODEL`. The desk and the distributor are not attested: the desk acts by the role `Product` grants it,
   and the distributor for the maker and the checker `Product` grants on the token. `Product` takes the desk's, the portfolio's, the adapters' and the fee model's addresses as parameters and does this:
   - `ProxyDeployer.deploy(symbol, implementation, initData, hook, expectedRules)`. The init data carries the
     token's rule list, which the token installs on the shared hook itself. `deploy` first refuses an implementation
     that its registry has not attested as `IMPLEMENTATION`. It initialises in the same transaction, then checks that the
     token names that registry, that the hook is installed, that it holds exactly `expectedRules` for the new token, and
     the symbol. A symbol can be used once; a reverted deploy (an unattested implementation, a token or hook that names
     another registry, an unattested rule, a failed `initialize`) leaves no proxy and does not use up the symbol. Every later
     call waits for it, so a token that fails its checks grants nothing;
   - configure what the product lists: its credential policy ("`KYC` from attester 0" unless the profile states another; until
     a token has its policy its rule admits no receiver), its settlement window, its minimum position (parameter
     `minPosition`; 0, the default, switches the rule off), its supply cap (parameter `supplyCap`; none admits no mint), and
     its legos: the portfolio's adapters, caps and permissions, and the desk's or the vault's plugs. A product that lists the fund rule names its fund, and takes that
     fund's rule as the parameter `fundHoldersRule`, but never touches the fund, so a launch cannot fail on one. Nothing is set
     for the escrow: the 7540 vault is the token itself, which neither the fund rule nor the minimum counts;
   - grant roles: AGENT to the issuer's account, **UPGRADER to the timelock only**, RECOVERY to the recovery timelock; MINTER and
     BURNER on a `GatedToken`, `IntentToken`, `Gated721` or `Gated1155`; EXECUTOR on an `IntentToken` to the executors the product names; SETTLER on a
     7540 vault to its `NavDesk`, and REPORTER and CHECKER to two different accounts; ALLOCATOR on a vault with a portfolio to
     the fund manager; with a distributor, DISTRIBUTION_MAKER to the `distributionMaker` account and CHECKER to the `checker`,
     the same account that approves a desk's prices;
   - hand over: DEFAULT_ADMIN_ROLE to the timelock, and the operations account renounces it.
6. **`FundOpen`** (the operations account), once per fund, after its first classes are placed (parameters `fundContract`,
   `fundHoldersRule`, `holderCap`, `timelock` and a `class_<key>` for each class): install the rule, set the cap, register the
   classes in order and move `Fund` ownership to the timelock. Registration refuses a hook that does not list the rule and a
   token that has supply. A class has no supply until then, because every movement on it is refused with `NOT_FUND_CLASS`.

   Any later class or rule change goes through governance (schedule, wait out the delay, execute), because either can
   change the room existing investors have under the cap. A later class launches through `Product` like any other, handed
   to the timelock and inert until `registerClass` runs.
7. **KYC attester:** credential every holder (`CredentialRegistry.set`, or a signed credential that anyone submits). A
   vault needs no credential for its own shares, because `CredentialRule` does not judge a token's own address, but a
   vault whose asset is a gated token needs a credential that token's policy accepts. So does a custodian depositing for
   clients, anyone paid a client's redemption cash, and the `SignedEntry`, which pays for the investor.
8. **Post-deploy checks** (`STACK=stack.json npm run check -- --network <name>`; the tests run the same function through
   the fixture's `assertHandedOver`). The stack file, the exit codes, the keepers (`npm run keeper`) and the reconciler
   (`npm run reconcile`) are described in [Deployment and governance](docs/deployment.html#check):
   - the deployer and the operations account hold no role on either timelock, the policy registry, the core's own credential registry, the products or the executors;
   - the timelock holds DEFAULT_ADMIN_ROLE everywhere and is the only UPGRADER;
   - every product's `policy()` is the hook the council attested, that hook's `REGISTRY()` is the registry, and its
     `rules(token)` equals the rule list in the product's profile. A second hook on the same registry carries the same attested
     codehash and passes `ProxyDeployer`; this check is what refuses it;
   - the guardian can cancel main-timelock operations but cannot propose or execute them, and holds nothing on the
     recovery timelock; on each timelock no known account but governance proposes or executes, and the zero address,
     which would open a role to anyone, holds no proposer, executor or canceller role;
   - the credential rule reads the stack's registry and is attested, and each product's policy is the one in its profile
     and trusts at least one attester, each of which exists and is not killed. With the core's own registry, its guardian
     holds only `GUARDIAN_ROLE` and it has one attester, the KYC function. With an existing one, the rule is the one the
     parameters name, the registry is the release's code, `credentialAdmin` holds `DEFAULT_ADMIN_ROLE` and
     `credentialGuardian` holds `GUARDIAN_ROLE` there, and no other role there is held by one of the stack's named accounts
     or by either of the core's timelocks;
   - the recovery timelock holds exactly `RECOVERY_ROLE` on each product, the executors, the core's own credential registry and the main timelock,
     nothing elsewhere, and has no cancellers (governance's automatic one is revoked in `CoreHandover`);
   - each executor's operator and guardian are the stack's, and `EXECUTOR_ROLE` on an `IntentToken` is held by the
     executors it names and by no account the stack knows about;
   - no rule exposes `hasRole` or `owner`: rules take their authority from the token's roles at call time;
   - `ProxyDeployer.owner()` is the operations account;
   - each fund's owner is the timelock, its rule is the attested `FundHoldersRule` whose `FUND()` is that fund, its cap is the
     intended one, its classes are the ones it opened with, in order, and every class is intact (`firstBrokenClass()` is the
     zero address);
   - a product's legos name it and are wired as its profile says: the desk alone holds `SETTLER_ROLE`, the portfolio and the
     fee model are plugged in and attested, the adapters are the listed ones, each attested, the reporter, the checker and
     the allocator are different accounts, each custodian's account lets its attested validator judge the asset's
     `transfer` up to the profile's amount, and every risk has the profile's caps;
   - `MINTER_ROLE`, `BURNER_ROLE`, `AGENT_ROLE` and a desk-less fund's `SETTLER_ROLE` sit with a Safe of at least 2 signers,
     unless the profile's `singleSigners` names the role, for example for an MPC custody wallet whose policy engine does the same
     job. The demo profiles name all four, so a real deployment has to state its own;
   - the `SignedEntry`, where the profile asks for one, is the release's code with its own EIP-712 domain;
   - the `SignedExit`, the same;
   - a product's `Distributor` is the release's code and names that product, and its maker and its checker are different
     accounts, each the only known account with its role;
   - `getMinDelay() ≥ 24 hours` on both timelocks.

   The recovery timelock's proposer and executor is the governance multisig. A compromised governance multisig is
   out of scope for this control, by design: recovery bounds the guardian, not governance.

## Commands

Requires Node 24 (CI pins 24.21.0). Foundry v1.8.1 and Python 3.12 with `ci/requirements.txt` (slither, halmos)
are needed only for the analysis commands.

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
npm run slither       # static-analysis gate on the contracts that ship; accepted findings in slither.config.json and inline
```

```bash
pip install --require-hashes -r ci/requirements.txt   # slither + halmos with every dependency hash-pinned
```

```bash
npm run test:halmos   # symbolic properties: nonce/signature, frozen-balance, intent executor-binding, minimum-position, credential registry, fund, portfolio caps and DvP paths
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
  in the context's token-built data, ERC-7943 Final, the template id, two new rules); then the shared core and the ERC-721
  template (2026-11-05); the latest is ERC-8473 (2026-11-13: its names and ids, `onInstall`, and four reason names). They are frozen again at the ids and topics pinned there; [`PLAN.md`](PLAN.md) records each change.
- **Error naming.** Errors follow `<Contract>_<Name>`, e.g. `PolicyGated_NotAttested(address,uint8)`; the errors of the standards keep the standards' names (`ERC8473PolicyRejected`, `ERC7943InsufficientUnfrozenBalance`). Event
  parameters are `_camelCase`; topics are unaffected.
- **ERC-7943 Final.** `IPolicyGated` inherits `IERC7943Fungible` and the token advertises its id (`0x3edbb4c4`). The
  reasoned pre-flight is a second name, `canTransferWithReason`, and `ForcedTransferBy` carries the agent next to the
  standard's `ForcedTransfer`. The token's own frozen shortfall (an amount within the balance) reverts the standard's
  `ERC7943InsufficientUnfrozenBalance`, and an amount above the balance the base's `ERC20InsufficientBalance`; policy
  rejections revert with ERC-8473's `ERC8473PolicyRejected`.
- **ERC-8473 (uRWA Policy, draft).** Every template is an ERC-8473 token and `ComplianceHook` an ERC-8473 policy: the
  token answers `0x0505c8c9`, the hook `0x9cb56a99`, and the selectors are the draft's. The draft is not final, so these
  ids can still move with it. Two readings are ours. `wantsAfterTransfer()` takes no token and may not read the caller,
  so the shared hook answers true for everyone. The fund's investor count is kept across installations, and
  `FundHoldersRule.onInstall` goes live only when it can tell that no movement went unseen.
- **Extra reason codes.** `NO_HOOK`, `NO_RULES` and `NOT_FUND_CLASS` are appended.
- **`canTransfer` follows the standard where `canTransferWithReason` does not.** ERC-7943 (Final, checked 2026-10-24)
  says `canTransfer` must not return false on a balance check and must validate the unfrozen amount. It does not say
  which clause wins for an amount above the balance while something is frozen; `canTransfer` reads it as the draft ERC's
  reference does, so a one-unit freeze turns that answer false. So `canTransfer` reads true for an amount above the
  balance when the hook accepts it and nothing is frozen on the sender, and false when a frozen amount keeps the amount from the unfrozen balance, above the balance too. The
  write reverts with `ERC7943InsufficientUnfrozenBalance` for an amount within the balance and
  `ERC20InsufficientBalance` above it. `canTransferWithReason` says no to every shortfall, with
  `INSUFFICIENT_UNFROZEN`, so for a balance shortfall it and `canExecute` say what the write does, and the boolean does
  not. [`PLAN.md`](PLAN.md) records the decision.
- **`canTransferWithReason` scope.** It, and the boolean `canTransfer`, model holder-driven movements, with the operator
  set to `from`, which is zero for a mint, so the answer does not depend on who asks. A simulated burn is a holder's
  and respects frozen tokens. The enforcement paths `burn` and `forcedTransfer` are FORCED: they release frozen tokens
  first, the pause does not stop them, and no pre-flight predicts them. `Gated721` and `Gated1155` have no holder burn, so a burn
  asked about there is answered as a holder's would be, although `burn` takes frozen tokens.
- **Duplicate rules.** A duplicate `ruleId` reuses `ComplianceHook_DuplicateRule`, so the frozen ABI is unchanged.
- **7540 operators are full delegates** (review L-5, owner decision): the code follows ERC-7540, so an approved
  operator can also create requests that pull the owner's assets or shares under any controller. Owners should approve
  only custodians they would trust with the assets.
- **Deployment contracts.** Brief §3 lists `ProxyDeployer` and `TokenProxy` (in `contracts/deploy/`) and §4 lists
  `ProxyDeployer.deploy` among the attestation checks, but the brief does not describe the two contracts. `TokenProxy`
  is OZ's `ERC1967Proxy` with only OZ's documented `_unsafeAllowUninitialized` override, so that it can be created
  without init data. That keeps its CREATE2 address independent of the hook; `ProxyDeployer` initialises it in the same
  transaction.
