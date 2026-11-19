[Overview](index.md) · [Contracts](index.md#contracts) · [Who can do what](roles.md) · [One movement](movement.md) · [Deployment and governance](deployment.md) · [Where the money sits](money.md)

[Overview](index.md) / Governance

# Deployment and governance

An issuer deploys one core, then each product on top of it. The core goes through a security review and hands its admin powers to a timelock. A product launches with no wait over reviewed code and ends with its admin powers at the same timelock. After that, a change to a product's policy, code or roles waits in public for the delay, and an incident follows a fixed order: stop, enforce, resume.

- once per issuer: **Core, CoreHandover**
- per fund: **Fund, FundOpen**
- per product: **Legos, Product**
- a part a running core lacks: **CoreParts, PartsHandover**
- delay: **24 hours** by default, floor 1 hour
- post-deploy check: **assertHandedOver**

[In one minute](#in-one-minute) · [Going live](#live) · [Core](#core) · [Council step](#council) · [Hand-over](#handover) · [Adding to a core](#adding) · [Existing KYC registry](#external) · [Funds and products](#products) · [Rule lists](#rule-order) · [Profiles](#profiles) · [Post-deploy check](#check) · [Changing policy](#changes) · [Watching](#watching) · [Incident runbook](#incident) · [Why](#why) · [Limits](#limits)

<a id="in-one-minute"></a>

> ### In one minute
>
> Deployment uses Hardhat Ignition, a tool that runs a scripted list of contract deployments and calls. An issuer runs one **core**: two timelocks, the list of reviewed code (`PolicyRegistry`), one shared hook, `ProxyDeployer`, and the rules and implementations its products use. A **timelock** is a contract that runs a call only after it has been public for a fixed delay. The security council reviews the code and **attests** it: it records each contract's code fingerprint (its codehash) in the registry. `CoreHandover` then removes the deployer and gives `ProxyDeployer` to an **operations account**, which launches each **product** (one token or vault) with no wait, because a launch only adds a proxy over attested code and touches nothing that exists. Each launch ends with that product's admin powers at the main timelock. From then on, a change to its code, rules or roles is scheduled by governance, waits at least the delay (24 hours by default) in public, and runs unless someone cancels it. The check that all of this came out as intended, `assertHandedOver`, runs in CI against a local chain. On a live chain an operator has to run it.

<a id="live"></a>
## Going live

Six Ignition modules and three steps outside them. The test fixtures `deployProfile` and `deployStack` in `test/nodejs/fixtures.ts` run this sequence on a local chain, playing the council and, where a test needs holders, the KYC attester, so the Node tests start from a real deployment.

> **Diagram.** Going live in nine steps. Once per issuer: 1, the deployer runs Core. 2, the security council attests the rules, the hook and the implementations. 3, the deployer runs CoreHandover, which ends with the main timelock as admin and the operations account as owner of ProxyDeployer. Per fund and per product, run by the operations account with no timelock wait: 4, Fund, after which the council attests the fund's rule. 5, Legos, for a product that has any, after which the council attests all of them except the desk and the distributor. 6, Product. 7, FundOpen, which ends with the fund owned by the main timelock. After the modules: 8, the KYC attester credentials each holder. 9, the post-deploy check assertHandedOver reads the chain; CI runs it on a local chain and on a live chain an operator has to run it.
>
> **No step in going live waits for a timelock.** The delay starts to apply to each thing as it is handed over: the core at step 3, a product at the end of step 6, a fund at the end of step 7. Steps 4 to 7 repeat for each fund and each product, on the same core.

| Step | Who runs it | Waits for a timelock | What it leaves behind |
|---|---|---|---|
| `Core` | Deployer, account 0 of the run | No | The core's contracts. The deployer is temporary admin of both timelocks, the core's own credential registry if it has one, and the executors, and owns `ProxyDeployer`. |
| Council step | Security council, with `ATTESTER_ROLE` | No: `attest` has no delay | The rules, the hook and the implementations on the list of reviewed code. |
| `CoreHandover` | Deployer | No | The deployer holds nothing. The main timelock administers the core, and the operations account owns `ProxyDeployer`. |
| `Fund` | Operations account; then the council attests the rule | No | A `Fund` the operations account owns, and its `FundHoldersRule`. |
| `Legos` | Operations account; then the council attests | No | The product's desk, portfolio, adapters, validators, fee model and distributor, built against the product's predicted address. |
| `Product` | Operations account, as owner of `ProxyDeployer` | No | A live proxy administered by the main timelock. The operations account holds nothing on it. |
| `FundOpen` | Operations account, as owner of the fund | No. From here a later class or a change to the fund waits for the delay. | The fund with its rule, cap and first classes, owned by the main timelock. |
| Credentials | KYC attester, in `CredentialRegistry` | No | Each holder's record. A vault needs none for its own shares, because `CredentialRule` does not judge a token's own address. A vault whose asset is a gated token needs one that token's policy accepts, and so does a third party that pays into a vault or receives its redemption cash, [`SignedEntry`](contracts/SignedEntry.md) included. |
| `assertHandedOver` | CI on a local chain; an operator on a live one ([details](#check)) | No: it sends no transaction | Nothing. It throws on the first thing that is not as the profile says. |

<a id="core"></a>
## The core: `Core`

Everything that does not depend on a product. Its parameters are `governance`, `council`, `guardian` and `minDelay`, which is 24 hours unless stated. The first five rows always deploy. The rest follow from the profile: a rule only if a product lists it, an implementation only if a product uses that template, an executor only if a product names it, and a `SignedEntry` only if the profile sets `signedEntry`. These parts are `deployParts` in `ignition/parts.ts`, which also [adds parts to a core that already runs](#adding). A `FundHoldersRule` is not part of the core, because each one points at its own fund.

| Contract | Constructor arguments | What it is set up as |
|---|---|---|
| Recovery timelock, a [`GovernanceTimelock`](contracts/GovernanceTimelock.md) | `minDelay, [governance], [governance], deployer, 0` | Deployed first, so the main timelock can name it. Governance proposes and executes. The zero address means nobody holds `RECOVERY_ROLE` over it. It has the same one-hour floor as the main one. |
| Main timelock, a `GovernanceTimelock` | `minDelay, [governance], [governance], deployer, recoveryTimelock` | Its constructor gives the recovery timelock `RECOVERY_ROLE`. The deployer is admin of both timelocks until `CoreHandover`. |
| [`PolicyRegistry`](contracts/PolicyRegistry.md) | `timelock, council` | Administered by the main timelock from the start. The council attests. |
| [`ComplianceHook`](contracts/ComplianceHook.md) | `registry` | The one hook every product uses. It has no admin and no rules yet: each product installs its own list. |
| [`ProxyDeployer`](contracts/ProxyDeployer.md) | `deployer, registry` | Places each product at a predictable address. The deployer owns it until `CoreHandover`. |
| [`CredentialRegistry`](contracts/CredentialRegistry.md), [`CredentialRule`](contracts/CredentialRule.md) | `deployer, guardian`; `credentialRegistry` | If a product lists the credential rule, unless the profile reads an [existing registry](#external). The registry has no attester yet. |
| [`MinPositionRule`](contracts/MinPositionRule.md), [`HolderRestrictionRule`](contracts/HolderRestrictionRule.md), [`SettlementWindowRule`](contracts/SettlementWindowRule.md), [`SupplyCapRule`](contracts/SupplyCapRule.md), [`ExecutedOnlyRule`](contracts/ExecutedOnlyRule.md) | none | Each one that a product lists, one instance shared by every product that lists it. Settings are kept per token. |
| [`GatedToken`](contracts/GatedToken.md), [`IntentToken`](contracts/IntentToken.md), [`Gated721`](contracts/Gated721.md), [`Gated1155`](contracts/Gated1155.md), [`Gated4626Vault`](contracts/Gated4626Vault.md), [`Gated7540Vault`](contracts/Gated7540Vault.md) | none | One implementation per template used: the shared code behind every product of that template. Their constructors lock them, so only proxies can be initialised. Each vault's constructor also creates its second contract, [`Gated4626Management`](contracts/Gated4626Management.md) for the 4626 and [`Gated7540Settlement`](contracts/Gated7540Settlement.md) for the 7540, so that needs no step of its own. |
| [`IntentExecutor`](contracts/IntentExecutor.md), [`DvPExecutor`](contracts/DvPExecutor.md) | `deployer, guardian` | Each one that a product names. Not attested: neither is a hook, a rule or an implementation. A token authorises an executor by granting it `EXECUTOR_ROLE`. |
| [`SignedEntry`](contracts/SignedEntry.md) | none | One per issuer, if the profile sets `signedEntry`, for every vault of the issuer. Not attested, with no role and no admin. A vault accepts it as a payer only once it holds a credential the vault's policy accepts. |

<a id="council"></a>
## The council step

The council attests in three places in the sequence, each time with a link to its review (`attest(codehash, kind, uri)`), and none of them waits for a timelock:

- after `Core`: each rule as `RULE`, the hook as `HOOK` and each implementation as `IMPLEMENTATION`;
- after each `Fund`: its `FundHoldersRule` as `RULE`. A class cannot list the rule before that, because the hook refuses an unattested rule;
- after each `Legos`: the portfolio as `PORTFOLIO`, each guarded account and adapter as `ADAPTER`, each validator as `VALIDATOR` and the fee model as `FEE_MODEL`. The desk is not attested: it holds no money and acts by the role `Product` grants it. Nor is a `Distributor`: it acts for the maker and the checker `Product` grants on its token, and the post-deploy check compares its code with the release's.

The README runbook describes the procedure: rebuild from the release tag with `npm run verify:reproducible`, compare with the published build and with the code on chain, then attest.

A codehash covers a contract's code including its immutable values, such as an address fixed at construction, but not the code that lives at that address. So the council also reads what these contracts point at:

- the hook's `REGISTRY()`, which must be the deployment's registry;
- the credential registry behind `CredentialRule`: its code. At that step the deployer is still its admin and it has no attester, and the post-deploy check asserts its admin and its one attester after hand-over. The registry is not attested. A core on an [existing registry](#external) deploys neither: the council reads that registry's code, its admin, its guardian and its attesters, and attests the rule the parameters name;
- the fund behind `FundHoldersRule`: its code and its owner. The fund is not attested;
- the outside vault behind an [`ERC4626Adapter`](contracts/ERC4626Adapter.md). That reading is the only control on the target itself.

A vault implementation points at its second contract the same way. Its codehash fixes the address, `SETTLEMENT_LOGIC()` on a 7540 and `MANAGEMENT_LOGIC()` on a 4626, and not the code there. `npm run verify:reproducible` fails unless the vault's creation code embeds that contract's creation code, and the post-deploy check compares the code at the address with the artifact.

Every deployment of a UUPS implementation has its own codehash, because OpenZeppelin's `UUPSUpgradeable` stores the implementation's own address as an immutable. A redeployed hook or rule with the same constructor arguments shares the codehash of the attested one, and `attest` refuses a second attestation of it (`PolicyRegistry_AlreadyAttested`). So two instances of the same code cannot be told apart by attestation, which is why the post-deploy check pins the instance.

<a id="handover"></a>
## The hand-over

Hand-over happens in three places: `CoreHandover` for the core, the end of each `Product` for that product, and the end of each `FundOpen` for that fund. [Who can do what](roles.md#holders) lists every holder afterwards.

`CoreHandover` takes the addresses `Core` produced as parameters, plus the accounts `governance`, `guardian`, `operations`, `operator` and `kycAttester`. It runs as the deployer, in this order:

1. **Configure.** `CredentialRegistry.addAttester(kycAttester, kycAllowedQuals)` makes the KYC function attester 0. `kycAllowedQuals` is 1023 unless stated, which is the ten named qualification bits.
2. **Grant.** The guardian gets `CANCELLER_ROLE` on the main timelock. The recovery timelock gets `RECOVERY_ROLE` on the credential registry and on each executor. The `operator` account gets `OPERATOR_ROLE` on each executor.
3. **Hand over.** On the credential registry and each executor, `grantRole(DEFAULT_ADMIN_ROLE, timelock)` and then the deployer's `renounceRole`. On the main timelock the deployer only renounces, because OpenZeppelin makes every timelock its own admin. On the recovery timelock it first revokes the `CANCELLER_ROLE` that OpenZeppelin gives governance as a proposer, so nobody can cancel there, and then renounces. `ProxyDeployer.transferOwnership(operations)` moves the deployer to the operations account.

Governance keeps `CANCELLER_ROLE` on the main timelock, next to the guardian. The renounce calls run only after the calls that need the deployer's rights, so a failed step leaves those rights in place. The steps for the credential registry and the executors are `handOverParts` in `ignition/parts.ts`, which `PartsHandover` runs too. A core on an [existing registry](#external) has no registry of its own, so there is no attester to add and no role on a registry to grant or hand over, and it needs no `kycAttester`.

<a id="adding"></a>
## Adding to a running core

A later product can need a part the core was not built with: the implementation of a template no earlier product used, a rule no earlier product listed, an executor, or the signed entry. Another profile's `Core` would build a second set of timelocks, a second registry and a second hook. Two modules add only the missing parts, and leave the timelocks, the registry, the hook and `ProxyDeployer` as they are, so the product joins the issuer's one stack.

1. **`CoreParts`.** Any account, with the parameter `guardian`. `CORE_HAS` lists the parts the core has, by key and separated by commas, and the module deploys every part of the profile that it does not list, with the same constructor arguments `Core` uses. So `CORE_HAS` must list the core's parts exactly. The module throws when `CORE_HAS` is unset or names nothing, because an empty list would deploy every part again, a second credential registry among them; when it names a key that is not a part of a core, which would leave that part read as missing; and when nothing is missing.
2. **Council step.** The council attests each new rule as `RULE` and each new implementation as `IMPLEMENTATION`, as after `Core`.
3. **`PartsHandover`.** The account that ran `CoreParts`, with the same `PROFILE` and `CORE_HAS`, so that it computes the parts that were added. For a new credential registry and new executors it does what `CoreHandover` does: the first KYC attester, `RECOVERY_ROLE` to the recovery timelock, `OPERATOR_ROLE` to the operator, then `DEFAULT_ADMIN_ROLE` to the main timelock, and the account renounces. Rules, implementations and the signed entry have no admin, so it does nothing for them. It throws when no part was added.
4. **The product.** `Legos` and `Product`, as for any product.

The keys are the rule keys (`credentialRule`, `minPositionRule`, `holderRestrictionRule`, `windowRule`, `supplyCapRule`, `executedOnlyRule`), the implementation keys (`gatedImpl`, `intentImpl`, `nftImpl`, `multiImpl`, `fundImpl`, `asyncFundImpl`), `executor`, `dvpExecutor` and `signedEntry`. `credentialRule` brings its `CredentialRegistry`, unless the profile reads an [existing registry](#external), when neither is a part. `CORE_HAS` may also name the core's contracts: `timelock`, `recoveryTimelock`, `registry`, `hook`, `proxyDeployer`, and `credentialRegistry` for a core that deployed its own. The modules do not read the chain to learn what the core has: a `CORE_HAS` that leaves out a part the core has deploys a second one.

<a id="external"></a>
## Using an existing credential registry

A core may read another core's `CredentialRegistry` instead of deploying its own, so an investor credentialed once there can hold both issuers' tokens. The profile sets `credentials: "external"`; the default, `"own"`, is what the rest of this page describes. No shipped profile sets it, so the issuer adds its own profile to `ignition/profiles.ts`. `Core` and `CoreParts` then deploy no registry and no `CredentialRule`, and `CoreHandover` and `PartsHandover` configure none. Three parameters take their place.

| Parameter | What it names |
|---|---|
| `credentialRule` | The existing [`CredentialRule`](contracts/CredentialRule.md). Its `REGISTRY()` is the registry the core reads, so the rule and the registry cannot disagree. The council attests it as `RULE` in the core's own `PolicyRegistry`: the same codehash another council attested. |
| `credentialAdmin` | The account the issuer accepts as holder of `DEFAULT_ADMIN_ROLE` on that registry. |
| `credentialGuardian` | The account the issuer accepts as holder of `GUARDIAN_ROLE` there. |

**What the issuer hands over.** Choosing a registry gives its governance a say over the issuer's tokens. The admin adds attesters, and sets the bits each may assert and the account that signs under each id, so it decides who does KYC for every token whose policy trusts those ids. The guardian, and the admin too, can kill an attester, and the guardian can block an investor, with no delay, on every token that reads the registry. Its attesters also say which addresses are one investor, and the issuer's funds, built over that registry, count by it. Records are public, so one address is linked across every issuer that reads them. Whether an issuer may rely on another's KYC is for the issuers to settle, not the code.

**What stays the issuer's own.** Its timelocks, its `PolicyRegistry`, its hook and its upgrades, and each product's policy, which names the attesters of that registry it trusts. A token lists one `CredentialRule`, because the rule's `ruleId` is fixed and a hook takes one rule per id, so it reads one registry.

**Before and after.** The council reads that registry as it would its own (its code, its admin and guardian, its attesters) before it attests the rule. The [post-deploy check](#check) then asserts that the rule is the one the deployment names, that the registry's code is the release's, and that the named admin and guardian hold their roles there.

<a id="products"></a>
## Funds and products

All four modules here are run by the operations account, and none waits for a timelock. `PROFILE` chooses the profile for `hardhat ignition deploy`, `PRODUCT` one of its products and `FUND` one of its funds. `full`, its first product and its first fund are the defaults.

### `Fund`: once per fund

A [`Fund`](contracts/Fund.md) owned by the operations account, and the [`FundHoldersRule`](contracts/FundHoldersRule.md) that points at it. An issuer has as many as it has funds, each with its own investor cap. The module's parameters are `operations`, the fund's first owner, `registry`, the policy registry, and `credentials`: the credential registry the fund asks for each address's entity, so that an investor with several addresses counts once, or the zero address, which makes the fund count every address on its own. The fund's constructor refuses a credential registry that does not answer the `ICredentialRegistry` interface id (`Fund_NotACredentialRegistry`), and the choice is fixed at construction.

<a id="legos"></a>
### `Legos`: once per product that has any

A desk and a portfolio name their vault, and a distributor its token, so they are built before it exists: `ProxyDeployer.predict(symbol, implementation)` gives the address. What a lego fixes at construction is in its codehash: the vault, an adapter's target, a validator's address and limit, a fee model's rates. A portfolio's caps and adapters and a guarded account's permissions are set later, by the vault's admin, and no attestation covers them.

| Lego | When | Constructor arguments | Attested as |
|---|---|---|---|
| [`Portfolio`](contracts/Portfolio.md) | The product states a portfolio | `vault, asset` and whether it accepts reported adapters, which is true exactly for a 7540 | `PORTFOLIO` |
| [`GuardedAccount`](contracts/GuardedAccount.md) | One per custodian | `portfolio, riskId, 0`, the risk id being the `keccak256` of `custodian:` followed by the custodian's `key` in the profile | `ADAPTER` |
| [`ERC20CallValidator`](contracts/ERC20CallValidator.md) | One per custodian | The custodian's address and `maxPerCall` | `VALIDATOR` |
| `ERC4626Adapter` | One per outside vault | `portfolio, target, 0` | `ADAPTER` |
| [`NavDesk`](contracts/NavDesk.md) | The product states a schedule | `vault, cash, periodLength, cooldown, maxReportAge`: `cash` is `custodianAccount` with no portfolio and zero with one | Not attested |
| [`FeeModel`](contracts/FeeModel.md) | The product states fees | `feeRecipient, managementBps, performanceBps, hurdleBps, softHurdle` | `FEE_MODEL` |
| [`Distributor`](contracts/Distributor.md) | The product sets `distributor`, on any template | `product`, the token it pays the holders of | Not attested |

### `Product`: once per product

The operations account owns `ProxyDeployer`, so a launch waits for no timelock. Each stage waits for the one before it.

> **Diagram.** The order inside Product. 1, ProxyDeployer.deploy places the proxy and refuses unattested code and a wrong rule list; every later call waits for it. 2, while the operations account is the token's admin, configure its rule settings and its legos. 3, grant the token's roles, after the configuration, including a distributor's maker and checker. 4, hand over: the admin role to the main timelock, and the operations account renounces it.
>
> **A token that fails its checks grants nothing.** Configuration waits for the deploy, grants wait for configuration, and the hand-over waits for the grants, because each needs the operations account's admin rights. A failed deploy leaves no proxy and does not use up the symbol.

| Stage | Calls | Why |
|---|---|---|
| Deploy | `ProxyDeployer.deploy(symbol, implementation, initData, hook, rules)`. `initData` is the token's `initialize` with the operations account as admin, the guardian, the registry, the hook and the rule list. A vault also takes the `asset`, and a token its `decimals` (18 unless stated). | The token installs the shared hook while it is initialised, with its rule list as the installation's data, and the hook's `onInstall` installs that list for the token. `ProxyDeployer` refuses an unattested implementation (`ProxyDeployer_ImplementationNotAttested`), and afterwards a wrong registry, hook, rule list or symbol (`ProxyDeployer_RegistryMismatch`, `ProxyDeployer_HookNotInstalled`, `ProxyDeployer_RulesMismatch`, `ProxyDeployer_SymbolMismatch`). A symbol works once (`ProxyDeployer_SaltUsed`). |
| Configure | For each rule the product lists: `CredentialRule.setPolicy` (`KYC` from attester 0 unless the profile states a policy), `MinPositionRule.setMinPosition` (parameter `minPosition`, 0 unless stated), `SupplyCapRule.setSupplyCap` (parameter `supplyCap`), `SettlementWindowRule.setWindow`. For its legos: `Portfolio.addAdapter` and `setCaps`, `GuardedAccount.setPermission` for the asset's `transfer`, then `NavDesk.setSettings`, `setFeeModel` and, where the product's `nav` states `redemptionGateBps`, `setRedemptionGate`, or `Gated4626Vault.setPortfolio` and `setFeeModel`. | Rules and legos ask the token whether the caller is its admin, which the operations account still is. Until a token has a policy its credential rule admits no receiver (`RECEIVER_NOT_ELIGIBLE`). The plugs refuse what the council has not attested. |
| Grant | `AGENT_ROLE` to the `agent`, `UPGRADER_ROLE` to the main timelock, `RECOVERY_ROLE` to the recovery timelock. `MINTER_ROLE` and `BURNER_ROLE` on a `GatedToken`, an `IntentToken`, a `Gated721` or a `Gated1155`. `SETTLER_ROLE` on a 7540, to its desk, or to the `settler` account if it has none. `REPORTER_ROLE` with a desk. `CHECKER_ROLE` with a desk or a distributor, to the one `checker` account. `DISTRIBUTION_MAKER_ROLE` with a distributor, to the `distributionMaker` account. `ALLOCATOR_ROLE` with a portfolio. `EXECUTOR_ROLE` to the executors the product names. | Operational roles exist only on tokens that came up as reviewed. |
| Hand over | `grantRole(DEFAULT_ADMIN_ROLE, timelock)`, then `renounceRole(DEFAULT_ADMIN_ROLE, operations)`. | After this the operations account can change nothing on the product. |

A product that lists the fund rule takes that rule as a parameter and does not touch the fund, so its launch cannot fail on one. Until the fund registers it, every movement on it is refused with `NOT_FUND_CLASS`, so it stays at zero supply.

### `FundOpen`: once per fund, after its first classes

`Fund.setRule` and `setHolderCap`, then `registerClass` for each class, each after the one before, so the class numbers do not depend on scheduling. Then `transferOwnership(timelock)`. Registration refuses a token whose hook does not list the fund's rule (`Fund_RuleNotListed`) and a token that has supply (`Fund_ClassHasSupply`). From here a later class launches through `Product` like any other, and is inert until a timelock operation registers it.

<a id="rule-order"></a>
## Each product's rules

A product's profile states its ordered list, and the hook asks the rules in that order and stops at the first rejection. `RULE_ORDER` in `ignition/modules/roles.ts` holds the lists of the `full` profile. The other eight profiles list `CredentialRule` then `HolderRestrictionRule`. No shipped profile lists `SupplyCapRule` or `ExecutedOnlyRule`: a profile asks for them by name.

| Product in `full` | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| `IntentToken`<br>"Intent Token", `INT` | `CredentialRule` | `MinPositionRule` | `HolderRestrictionRule` | `SettlementWindowRule` | `FundHoldersRule` |
| `Gated4626Vault`<br>"Gated Fund", `gFUND` | `CredentialRule` | `MinPositionRule` | `HolderRestrictionRule` | `FundHoldersRule` |  |
| `Gated7540Vault`<br>"Gated Async Fund", `gASYNC` | `CredentialRule` | `MinPositionRule` | `HolderRestrictionRule` | `FundHoldersRule` |  |

- **Credential first:** who may hold at all.
- **Minimum position second:** with a minimum set, the rules after it see real positions, except after a forced move, a burner's burn or a move involving an exempt account.
- **Settlement window on the intent token only:** it judges EXECUTED moves, and the vaults have none.
- **The fund rule last:** the investor count that matters is fund-wide, across the classes.

The hash of a token's symbol is its CREATE2 salt, so the symbol, with the implementation and the `ProxyDeployer`, decides the token's address.

<a id="profiles"></a>
## The profiles

`ignition/profiles.ts` names nine combinations, and what `Core` deploys follows from the profile. Every profile deploys the two timelocks, the policy registry, the hook, `ProxyDeployer` and the credential registry (a profile of the issuer's own can [read an existing one](#external) instead), then the rules its products list and one implementation per template they use, and what the last column says.

| Profile | Products | Rules | Legos and the rest |
|---|---|---|---|
| `token` | One `GatedToken`, `GTK` | `CredentialRule`, `HolderRestrictionRule` | No legos, no fund, no executor. |
| `nft` | One `Gated721`, `gNOTE` | The same two | No legos, no fund, no executor. |
| `multi` | One `Gated1155`, `gSER` | The same two | No legos, no fund, no executor. |
| `intent` | One `IntentToken`, `INT` | The same two | `IntentExecutor` and `DvPExecutor`, both with `EXECUTOR_ROLE` on the token. No legos, no fund. |
| `vault4626` | One `Gated4626Vault`, `gFUND` | The same two | No legos. The vault keeps its own money. |
| `vault7540` | One `Gated7540Vault`, `gASYNC` | The same two | A `NavDesk` with a daily period, a one-day cooldown and a report good for three days. Its cash account is the `custodianAccount` parameter: a fund with one custodian. |
| `managed-fund` | One `Gated7540Vault`, `mFUND` | The same two | The same desk schedule. A `Portfolio` that accepts reported adapters. Two `GuardedAccount`s, each with an `ERC20CallValidator` and its own caps. A `FeeModel`: 1% management, 10% performance, a hard 3% hurdle. It sets `custodyOnly`, which refuses an outside vault at build time. |
| `vault4626-invest` | One `Gated4626Vault`, `iFUND` | The same two | A `Portfolio` that refuses reported adapters. One `ERC4626Adapter`. A rate limit of 10% a year (`maxRateBps` 1000). A `FeeModel`: 0.5% management, 10% performance, no hurdle. |
| `full` | `IntentToken` `INT`, `Gated4626Vault` `gFUND`, `Gated7540Vault` `gASYNC`, as three classes of one fund | The lists above | A `Fund` and its `FundHoldersRule`. `IntentExecutor` and `DvPExecutor`, both with `EXECUTOR_ROLE` on the intent token. No desk: a plain `settler` account holds `SETTLER_ROLE` and sets any price alone, so a test can price at will. It is the default profile, and it is for tests. |

No profile states a `redemptionGateBps`, as the level is each product's own, from its documents. `test/nodejs/legos.test.ts` deploys `vault7540` with one, which covers the wiring.

No profile sets `signedEntry` or a product's `distributor`: a profile asks for them by name, as the profiles built in `test/nodejs/products.test.ts` do.

All nine set `singleSigners` to `DEMO_SIGNERS`, which names all four sensitive roles as exceptions to the post-deploy check's refusal of a single key ([see below](#check)). They are demo stacks: a real deployment has to state its own.

A product that makes no sense throws when its `Legos` or `Product` module is built, before that module sends a transaction (`assertUsable`). `Core`, `CoreHandover` and `Fund` do not call it, so they can already have run. It refuses:

- `windowRule` or `executedOnlyRule` on anything but an `IntentToken`, `supplyCapRule` on a vault, `minPositionRule`, `fundHoldersRule` or `supplyCapRule` on a `Gated721`, and `fundHoldersRule` or `supplyCapRule` on a `Gated1155`;
- a desk on anything but a 7540, and a portfolio on anything but a vault;
- a portfolio behind a 7540 with no desk to price it;
- on a 4626 with a portfolio, a custodian, or no rate limit;
- fees on anything but a vault, on a 7540 with no desk, or on a 4626 with no portfolio;
- an outside vault on a `custodyOnly` product;
- executors on anything but an `IntentToken`, the only template that runs signed intents;
- `decimals` on anything but a `GatedToken` or an `IntentToken`: a vault's follow its asset, and an NFT and a multi-token have none;
- `fundHoldersRule` with no fund named, and a fund named without `fundHoldersRule`.

<a id="check"></a>
## The post-deploy check

`assertHandedOver` is a function in `test/nodejs/fixtures.ts`. It makes read calls and `getCode` calls and sends no transaction, and it throws on the first thing that is not as the profile says.

**Who runs it.** The fixture calls it at the end of every deployment, so every Node test that deploys a stack runs it on Hardhat's in-process chain, and CI's `test` job runs those tests with `npm test` on each pull request and each push to `main`. That shows the modules produce a stack that passes. It says nothing about a chain in production: no CI job, no `package.json` script and no module points it at a live network, and it has no command of its own. After a live deployment, and after each later product, an operator must run it, giving it the real addresses, the product list and the named accounts the way the fixture does.

**What "named" means.** The roles here keep no list of holders, so the check can only ask about accounts it is told about: the deployer, governance, the council, the guardian, the operations account and the operational accounts of the deployment. A role granted to any other address is not seen.

| About | What it asserts |
|---|---|
| The deployer and the operations account | Neither holds any role that a `*_ROLE()` getter names, on either timelock, the policy registry, the core's own credential registry, the products or the executors. The getters are read from each contract's ABI, so a role added later is covered. |
| The main timelock | It holds `DEFAULT_ADMIN_ROLE` on itself, the policy registry, the core's own credential registry, the products and the executors, so the line above is not vacuous. The guardian holds its `CANCELLER_ROLE` and neither `PROPOSER_ROLE` nor `EXECUTOR_ROLE`. No named account but governance proposes or executes on it. `getMinDelay()` is at least 24 hours. |
| Both timelocks | The zero address holds no `PROPOSER_ROLE`, `EXECUTOR_ROLE` or `CANCELLER_ROLE`: OpenZeppelin's timelock lets anyone execute once the zero address holds `EXECUTOR_ROLE`. |
| The recovery timelock | It runs exactly the same code as the main timelock. It holds exactly `RECOVERY_ROLE` on the main timelock, each product, the executors and the core's own credential registry, nothing on the policy registry, and exactly `DEFAULT_ADMIN_ROLE` on itself. Governance is its proposer and executor. No named account can cancel there, the guardian holds nothing on it, and no named account, not itself and not the main timelock holds `RECOVERY_ROLE` on it. `getMinDelay()` is at least 24 hours. |
| Upgrades | The main timelock holds `UPGRADER_ROLE` on each product, and no named account does. |
| Hook and rules | The hook's `REGISTRY()` is the stack's registry. Each product's `policy()` is that exact instance. Each product's `rules(token)` equals the list in its profile, in order. No rule's ABI exposes `hasRole` or `owner`. |
| Executors | The operator holds exactly `OPERATOR_ROLE` and the guardian exactly `GUARDIAN_ROLE` on each. On each `IntentToken`, the executors the product names hold `EXECUTOR_ROLE`, and no named account does. |
| `ProxyDeployer` | The operations account owns it. |
| Each fund | The main timelock owns it. `rule()` is the fund's rule, that rule's `FUND()` points back, and the rule is attested as `RULE`. The cap is the intended one. `CREDENTIALS()` is the stack's credential registry, or the zero address when the stack has none. `classCount()` and `classAt(i)` are the classes it opened with, in order, each intact, and `firstBrokenClass()` is the zero address. |
| Credentials | `CredentialRule` reads the stack's registry and is attested as `RULE`. Each product's `policyOf` equals its profile's policy and trusts at least one attester, and each attester it trusts exists and is not killed. With the core's own registry, the guardian holds exactly `GUARDIAN_ROLE` on it and there is one attester, the KYC account. With an [existing one](#external), the rule is the one `credentialRule` names, the registry's code is the release's `CredentialRegistry`, `credentialAdmin` holds `DEFAULT_ADMIN_ROLE` and `credentialGuardian` holds `GUARDIAN_ROLE` there, and no other role there is held by a named account or by either of the core's timelocks. |
| A vault's second contract | The code at a 7540's `SETTLEMENT_LOGIC()` is the `Gated7540Settlement` artifact's, and the code at a 4626's `MANAGEMENT_LOGIC()` is the `Gated4626Management` artifact's, each with its own address in the `__self` slot. An implementation's attestation fixes only the address. |
| Each product's legos | The reporter, the checker and the allocator it uses are different accounts. With a desk: the desk's `VAULT()` is this product, its `redemptionGate()` is the level the product's `nav` states, or zero with none, and `SETTLER_ROLE` sits with the desk, `REPORTER_ROLE` with the reporter and `CHECKER_ROLE` with the checker, and with no other named account. With a portfolio: its `VAULT()` is this product, it is plugged in (the desk's or the vault's `portfolio()`) and attested as `PORTFOLIO`, `ALLOCATOR_ROLE` sits with the allocator and no other named account, and `adapters()` is the built list, each attested as `ADAPTER`. Each custodian's validator is attested as `VALIDATOR`, judges the asset's `transfer` for its account (`validatorOf`) and allows the profile's `maxPerCall`, and every custodian's and target's risk has the profile's caps. With fees: the fee model is plugged in and attested as `FEE_MODEL`. |
| The signed entry | Where the profile sets `signedEntry`, or the stack has one: its code is the `SignedEntry` artifact's, its immutables left out, and `entryHash` of a sample entry equals the EIP-712 hash for the domain `SignedEntry`, version `1`, this chain and this address, so the domain separator it signs under is built from those four. |
| Each product's distributor | Where the product sets `distributor`: its code is the `Distributor` artifact's, its immutables left out, and its `TOKEN()` is this product. The `distributionMaker` and the `checker` are different accounts, and each is the only named account with its role on the token. |
| The single-key refusal | For `MINTER_ROLE`, `BURNER_ROLE`, `AGENT_ROLE` and `SETTLER_ROLE`: if the deployment's `minter`, `burner`, `agent` or `settler` account holds the role on a product, it must answer `getThreshold()` with 2 or more, as a Safe that requires at least two signatures does. An account with no such function fails. A profile can name a role in `singleSigners` to except it, for example for an MPC custody wallet whose policy engine does the same job. A product with a desk passes on the settler, because the `settler` account does not hold the role there. |

Tests pin that it refuses: a deployer left holding a role, a twin hook on the same registry ("runs another hook"), a recovery timelock running other code, `RECOVERY_ROLE` granted on the recovery timelock, a stray `EXECUTOR_ROLE`, a stray settler beside a desk, a desk that names another vault or does not hold the role, a reporter who is also the checker, a sensitive role on a single key, a Safe of one signer, a portfolio, fee model or validator whose attestation was revoked, a custodian's permission or a risk's caps not as the profile says, a timelock role held by the zero address, a proposer role held by a named account other than governance, a stack that lost its signed entry, a distributor that names another token, a distribution maker who is also the checker, and a stray maker. With an existing credential registry it refuses a named admin or guardian that does not hold its role, a registry or a rule other than the named one, a role on that registry granted to either timelock, a stack with no registry at all, a policy that trusts no attester, a missing one or a killed one, and a rule over a registry whose code is not the release's. It also throws when a delay is below 24 hours, although the contract accepts anything from 1 hour.

### What it does not check

- A role held by an address it was not told about, as above.
- Who holds `GUARDIAN_ROLE` on a product. It pins the guardian on the executors and the core's own credential registry only, and on an existing registry only that the named `credentialGuardian` holds `GUARDIAN_ROLE`: another holder it does not know of passes, as does another admin.
- An existing credential registry after the check has run. Its admin can grant a role, add an attester or change what one may assert later, and nothing here sees that until the check runs again. It does not say who holds `RECOVERY_ROLE` there: like every other role there, it only refuses it to the accounts it knows.
- Whether governance, the guardian, the operations account or the operator is a multisig. Only the four roles above are asked for a threshold, and a Safe's signers are not read.
- Which implementation a proxy points at, and whether the hook is attested: `ProxyDeployer` and the token's initialiser checked those at launch, and the check does not read them again.
- Settings beyond the legos'. It reads each custodian's one permission and every risk's caps, but not whether an account has any other permission (an account keeps no list of them), a custodian's address, a desk's schedule, a fee model's rates or a minimum position.
- Whether the `SignedEntry` holds a credential. Until the KYC attester gives it one that a vault's policy accepts, that vault refuses it as a payer.

<a id="changes"></a>
## Changing the policy later

After the hand-over a change to an existing product takes one path through the main timelock. What differs is the call at the end and the check that guards it. Launching another product does not take this path: the operations account does that at once.

> **Diagram.** The change path. 1, code not yet attested is deployed and the council attests it. 2, governance schedules one batch on the main timelock. 3, it waits at least the minimum delay, in public as CallScheduled, and a canceller, the guardian or governance, can stop it. 4, governance executes it with the timelock as the caller. The batch ends in one of seven kinds of call: replace a rule list, replace the hook, change the fund's rule, upgrade a product, register a later class, settings and roles, or change a lego. Each has its own check.
>
> **One path for each change to what exists.** The batch is public for the whole delay as the timelock's `CallScheduled` events, and the guardian can cancel it in that time. Several calls to one token can also go as one `token.multicall`, which is atomic and runs each call with the timelock as sender.

### Replace a product's rule list

`hook.setRules(token, rules)` replaces the whole ordered list of one token in one call and leaves every other token alone. The caller must be the token itself or hold `DEFAULT_ADMIN_ROLE` on it, which the hook asks the token at call time (`ComplianceHook_NotTokenAdmin`). Each rule must be attested as `RULE` (`ComplianceHook_NotAttested`), at most 16 (`ComplianceHook_TooManyRules`), and no two may share a `ruleId` (`ComplianceHook_DuplicateRule`). Before it stores the list, the hook calls `onInstall(token, policy)` on every rule the replaced list did not hold, naming the policy the token consults at that moment, and a rule may refuse with its own error. Any failure keeps the list as it was. An empty list is accepted and rejects every movement with `NO_RULES`. The hook emits `RuleSetChanged` with the token and the rule ids.

Two things to avoid. Dropping `CredentialRule` without an equivalent: no other shipped rule checks who the holder is, and the hook does not warn. Dropping `FundHoldersRule` from a class that has holders: the fund stops hearing about that class's movements, the cap stops applying to it and its investor count goes stale. The rule cannot be listed for that class again while it has a supply: `setRules` tells the rule, which reverts with `FundHoldersRule_CountNotCurrent`, and there is no recount. To have a minimum in force from the moment `MinPositionRule` is listed, put `setMinPosition` before `setRules` in the same batch.

### Replace the hook

One hook serves every product, and each product moves by its own `installPolicy(replacement, data)`. A second `ComplianceHook(registry)` on the same registry has the attested codehash already, so it needs no attestation of its own. A token's list reaches the replacement in one of two ways. The batch calls `replacement.setRules(token, list)` first, with the timelock as the token's admin, and then `token.installPolicy(replacement, data)` with empty data, which keeps the list the replacement already holds. In that first call the replacement tells each rule of the list, naming the hook the token still consults as the previous policy. Or the data is `abi.encode(list)`, and the replacement's `onInstall` installs that list as `setRules` would. With empty data the list is set first, because a token whose hook holds no list for it rejects every movement with `NO_RULES`. `installPolicy` checks that the hook is attested as `HOOK` (`PolicyGated_NotAttested`), names the token's registry (`PolicyGated_HookRegistryMismatch`) and answers the policy interface id (`PolicyGated_NotAPolicy`). It stores the hook, emits `PolicyChanged` and calls the hook's `onInstall`, which calls `onInstall` on every rule in the token's list. If any of these reverts, the token keeps the hook it had. The rules need no change: they accept `after_` from whichever hook the token reports. A fund class's list must still name the fund's current rule. For a class that has supply, `FundHoldersRule` also requires that the outgoing hook listed it, or another rule of the same fund, for that class, or the installation reverts with `FundHoldersRule_CountNotCurrent`.

### Change the fund's rule

The investor count and each investor's classes live in [`Fund`](contracts/Fund.md), not in the rule, so a replacement rule starts with the right numbers. What changes is who may write them: after `fund.setRule(rule)`, only that rule may call `join` and `leave`. A class whose list still names the rule it replaced is closed: that rule sees it is not the installed one and rejects every movement of the class with `NOT_FUND_CLASS`, forced ones included. So the change is one batch: `fund.setRule(rule)` and, for every registered class, `hook.setRules(class, list)` with the rule swapped. `setRule` requires the rule to be attested as `RULE` (`Fund_NotAttested`) and to name this fund (`Fund_RuleForAnotherFund`).

### Upgrade a product

Deploy the implementation; the council attests it as `IMPLEMENTATION`; governance schedules `token.upgradeToAndCall(implementation, data)`. `_authorizeUpgrade` requires `UPGRADER_ROLE` (the main timelock), the attestation, and that the implementation reports the token's own `templateId()`, so an attested vault implementation offered to an `IntentToken` proxy is refused with `Templated_WrongTemplate`. The template ids are `keccak256` of the template's name and carry no version. State lives in ERC-7201 namespaced storage, so upgraded code keeps reading the same fields; `npm run validate:upgrades` runs OpenZeppelin's upgrade-safety check.

### Add a product or a class

Another product needs no timelock: the operations account runs `Legos` and `Product` again. If the core lacks the product's implementation, one of its rules or an executor it names, `CoreParts` and `PartsHandover` add them first ([above](#adding)). If the product is a class of a fund that has opened, the timelock then calls `fund.registerClass(token)` while its supply is zero and its list names the fund's rule. A later implementation needs the council's attestation first.

### Settings and roles

Credential policy, settlement window, minimum position and its exemptions and supply cap are set on the rules by the token's admin. The fund's cap and exemptions, the attesters of the core's own credential registry and every role change are called by the main timelock too. So are the legos' changes: `Portfolio.addAdapter`, `removeAdapter`, `writeOffAdapter`, `migrateTo` and raising a cap; `GuardedAccount.setPermission`; `Gated4626Vault.setPortfolio`, `setFeeModel` and raising `setMaxRate`; `NavDesk.setSettings`, `setFeeModel`, `setRedemptionGate` and `adopt`. Replacing a desk is one batch that swaps `SETTLER_ROLE` and calls the successor's `adopt` with the desk it replaces. Among the policy inputs, the agent's lockups and address freezes on `HolderRestrictionRule`, the KYC attester's credentials, and the guardian's blocks and attester kills on the credential registry take effect at once.

<a id="watching"></a>
## Watching the policy

The hook accepts any list of attested rules, and `Fund.setRule` does not look at the classes. So a list could leave out the fund's rule, or the fund's rule could change under lists that still name the one it replaced. These reads report such a state. They prevent nothing, and the repository ships no monitor that polls them.

| Read | What the answer means |
|---|---|
| `fund.firstBrokenClass()` | The zero address when every registered class lists the fund's installed rule. Otherwise the first class, in registration order, that does not, or whose token or hook could not be asked. |
| `fund.isClassIntact(token)` | `true` when the token is a registered class and its hook lists the installed rule. |
| `fund.holderCount()`, `fund.holderCap()` | A count above the cap comes from a lowered cap, from lifting an exemption from an account that holds a class, from a `rekey` of a holding address the attester unlinked from its entity, or from a forced delivery, such as a recovery from a 7540 vault into an account that held nothing. The rule admits no further investor until the count comes back down, apart from a forced move. |
| `hook.rules(token)` | The token's ordered list, to compare with the last approved one. A dropped `CredentialRule` shows only here. |
| `token.paused()`, `executor.paused()` | Whether the guardian has stopped it. |
| `desk.isWired()` | Whether the desk holds `SETTLER_ROLE` on its vault. The vault does not check who holds that role, and the holder sets the price. |
| `portfolio.priceFresh()`, `portfolio.writtenOff()` | `priceFresh()` is false when an adapter's price cannot be read, or once the money has gone to a successor, which stops deposits and withdrawals on a 4626. `writtenOff()` is true once an adapter was written off, which leaves a 4626 exit-only. So does a fall of more than half in one count, which `exitOnly()` on the vault shows. |

To watch rather than poll: `RuleSetChanged` on the hook, `PolicyChanged` on a token, `RuleSet` on the fund, `CredentialSet` on the credential registry when it changes the entity of an address that holds a fund class (the fund follows only once someone calls `fund.rekey(account)`), `AttestationRevoked` on the registry, and before any change through the timelock, its `CallScheduled`.

<a id="incident"></a>
## Incident runbook: pause, enforce, resume

The order for an incident on one product: stop it, move what must be moved, resume. A **quarantine account** is an account prepared in advance to receive tokens taken from a holder.

> **Diagram.** Incident sequence. 1, the guardian pauses the token at once; only FORCED moves pass. 2, the agent force-transfers the holder's tokens to the quarantine account. 3, governance schedules unpause on the main timelock. The delay passes, and the guardian could cancel. 4, governance executes. 5, the main timelock unpauses the token. 6, on a GatedToken, IntentToken, Gated721 or Gated1155, the burner burns from the quarantine account; the burn is FORCED, so it also passes during the pause.
>
> **Enforcement does not wait for the unpause.** A FORCED movement is the one kind a pause lets through: `forcedTransfer`, the burner's `burn`, and on the 7540 vault `recoverRedeemRequest` and `recoverClaimable`. The burn is drawn last and passes during the pause too. Step 6 exists on `GatedToken` and `IntentToken`, on `Gated721`, where `forcedTransfer` and `burn` take a token id instead of an amount, and on `Gated1155`, where they take a token id and an amount; the vaults' role `burn` always reverts (`GatedVault_Unsupported`), so their shares leave the quarantine account by an ordinary redemption.

1. **Pause.** The guardian calls `pause()` on the product, with no delay. Every movement except FORCED is rejected with `PAUSED`, the issuer's `mint` included, and a vault's `max*` functions return 0. Calls that move no balance still work: `setFrozenTokens`, and the agent's `setLockup` and `setFrozen`. Each product and each executor has its own `pause()`. [Every entry point while paused](roles.md#pause).
2. **Stop the rest, where it applies.** The guardian's other powers, also with no delay: `cancel` a pending operation on the main timelock; `blockSubject` an address or `killAttester` in the core's own credential registry; `NavDesk.cancel` a price not yet executed; `Portfolio.deallocate` to bring money back from an adapter to the portfolio; lower a cap with `Portfolio.setCaps`; `GuardedAccount.revokePermission`; lower a 4626's rate with `setMaxRate`. A paused vault's portfolio refuses `allocate` and its guarded accounts refuse `execute` on their own. [The guardian's powers in full](roles.md#guardian).
3. **Enforce.** The agent calls `forcedTransfer(holder, quarantine, amount)`. It ignores the sender's credential, address freeze, lockup and minimum position, and may take frozen tokens, lowering the frozen amount by the part it takes. The receiver is still judged: `quarantine` needs an active credential the token's policy accepts (`RECEIVER_NOT_VERIFIED`, `CREDENTIAL_EXPIRED`, `RECEIVER_NOT_ELIGIBLE`) and must not be address-frozen (`RECEIVER_FROZEN`). On a fund class a forced move is exempt from the investor cap but still counted. On the 7540 vault, `recoverClaimable` and `recoverRedeemRequest` also work while paused. Once a request's period has closed, `recoverRedeemRequest` needs `SETTLER_ROLE`, so with a desk the agent goes through `NavDesk.recoverRequest`, which needs no proposal on the table and the period closed for longer than `maxReportAge`. Several enforcement calls can go in one `multicall`. On a `GatedToken` or `IntentToken` the burner's `burn(holder, amount)` is the other enforcement move: it is FORCED too, so it passes the pause, and it destroys the tokens where they are, with no receiver to judge.
4. **Resume.** The token stays paused until `unpause()`, which accepts `DEFAULT_ADMIN_ROLE` or `RECOVERY_ROLE`: the main timelock or the recovery timelock, each after its delay. Plan for a pause of at least that delay, 24 hours by default. If the guardian cancels the unpause on the main timelock, governance uses [the recovery path](roles.md#recovery), which nobody can cancel.
5. **Burn what sits in quarantine.** On a `GatedToken` or `IntentToken` the burner calls `burn(quarantine, amount)`, during the pause or after it. It is a FORCED movement: the pause, the sender's address freeze, lockup and credential, and the minimum position do not stop it, and it may take frozen tokens, lowering the frozen amount by the part it takes.

Prepare the quarantine account before it is needed:

- The KYC attester credentials it with the bits the token's policy asks for and renews it before it lapses: a lapsed account cannot receive, so a forced move into it would fail with `CREDENTIAL_EXPIRED`.
- The agent does not address-freeze it with `setFrozen`, because a frozen receiver refuses forced moves too. To keep it from sending, use `setLockup`: a lockup does not stop a forced move or the burner's burn. On a vault class its exit is its own redemption, which a lockup stops, so the agent clears the lockup first.
- On a fund class, governance can exempt it from the investor count in advance with `fund.setExempt(quarantine, true)`, a timelock operation, so it has to be done ahead of the incident.

A holder who is address-frozen can be emptied either way. `forcedTransfer` and the burner's `burn` are both FORCED, and a sender's freeze does not stop a FORCED movement. `forcedTransfer` needs a receiver that passes the policy, and `burn` has none. On a vault, where the role's `burn` reverts, `forcedTransfer` is the way out of such an account.

<a id="why"></a>
## Why it is built this way

- **One core, many products.** An issuer runs its products on one set of timelocks, one guardian, one hook and one credential registry, so a client is verified once, and someone who wants one product alone runs the core and that product with the same code. A core can instead read another core's registry, so a client verified there is verified for it too, under that registry's governance ([above](#external)). A later product that needs a part the core lacks adds only that part.
- **No wait for a launch.** A launch only adds a proxy over attested code and sets settings under its own token's key. A timelock delay would slow every launch and protect nothing that exists, so the operations account owns `ProxyDeployer`.
- **Review between the stages.** The hook's only immutable is the registry and it holds no rules until a token installs them, so its codehash depends on no product. The council can attest it, the rules and the implementations once, before any product exists, and each product is then created against attestations that already exist.
- **Install-time checks, not run-time ones.** The registry is asked when a hook, a rule list, a fund's rule, a product, an upgrade, or a portfolio, adapter, validator or fee model is installed. Withdrawing an attestation later does not silently change a running token; governance removes the component, and the guardian can pause meanwhile.
- **Nothing granted until everything checks out.** Configuration, grants and the hand-over each wait for the stage before, so a mis-built token or rule list stops before any operational role exists.
- **Classes registered at zero supply.** A token can join a fund only before it has any balance, and until it is registered its fund rule rejects every movement, so the fund has seen every holder there is.
- **A check after the hand-over.** Attestation cannot tell two instances of the same code apart, and the rule lists live in the hook's storage, outside any codehash. The post-deploy check pins both.
- **Changes in one batch.** Steps that would leave a token closed or uncounted in between, such as a hook swap and its lists, or a fund rule and its classes, go in one timelock batch, so no movement can fall between them.

<a id="limits"></a>
## What it does not do

- **The post-deploy check is not automatic on a live chain.** CI runs it on a local one. [It sees only the accounts it is given](#check).
- **The operations account is powerful and has no delay.** A stolen key can place a token over an attested implementation with its own admin, and can use up a symbol. It cannot change an existing product, and such a token is not one the issuer published, so holders and integrators should take addresses from the issuer's list. The timelock has no power over `ProxyDeployer`: recovery from a stolen key is a further `ProxyDeployer`, which changes where later tokens land.
- **Ownership of `ProxyDeployer` and `Fund` moves in one step.** A two-step transfer would make the timelock schedule an accept for every fund, and leave the operations account owning the fund for the delay. A mistaken transfer has no undo. Both also inherit OpenZeppelin's `renounceOwnership`.
- **The 24-hour delay is a default, not a contract rule.** The contract's floor is 1 hour. Governance can lower a delay to that floor through a delayed operation of that timelock, and the check, if run again, would then fail.
- **The modules do not credential anyone.** They add the first attester and stop. Every holder, a vault over a gated asset and a third-party payer need a credential from outside the modules.
- **An existing credential registry is governed elsewhere.** A core that reads one cannot undo its guardian's block or its admin's choice of attesters. Through the main timelock it can change which attesters its products' policies trust, or list another attested `CredentialRule`.
- **`CoreParts` trusts `CORE_HAS`.** It does not read the chain, so a list that leaves out a part the core has deploys a second one.
- **A distributor for a product already handed over needs the timelock.** `Legos` can deploy it, but `Product` grants its maker and checker only at launch: later, the main timelock grants `DISTRIBUTION_MAKER_ROLE` on the token, and `CHECKER_ROLE` too unless the token is a vault with a desk, whose checker already holds that role.
- **Nothing stops a bad list or a bad grant.** The hook accepts any attested rules that do not themselves refuse to go live, and the timelock can grant `SETTLER_ROLE` to anyone. Those changes are delayed and public, not prevented.
- **Revoking an attestation changes nothing that is running.** It only stops the next install.
- **A compromised governance multisig is out of scope.** It proposes and executes on both timelocks. The guardian can cancel on the main one and not on the recovery one. The recovery path bounds the guardian, not governance.

<a id="connected"></a>
## Connected to

- [Who can do what](roles.md): Every role holder after the hand-over, and every entry point during a pause.
- [ProxyDeployer](contracts/ProxyDeployer.md): How each product is placed and checked.
- [PolicyRegistry](contracts/PolicyRegistry.md): The list of reviewed code the council writes to.
- [ComplianceHook](contracts/ComplianceHook.md): The shared hook and its per-token rule lists.
- [Fund](contracts/Fund.md): Classes, the investor count, and the monitor views.
- [GovernanceTimelock](contracts/GovernanceTimelock.md): The contract both timelocks run, with its one-hour floor.
- [NavDesk](contracts/NavDesk.md): The lego a 7540 product deals through.
- [Portfolio](contracts/Portfolio.md): The lego that says where a vault's money may go.

<a id="source"></a>
## Source and tests

- Modules: `Core.ts`, `CoreHandover.ts`, `CoreParts.ts`, `PartsHandover.ts`, `Fund.ts`, `Legos.ts`, `Product.ts`, `FundOpen.ts`, `roles.ts`
- The parts of a core and their hand-over: `ignition/parts.ts`
- Profiles: `ignition/profiles.ts`
- Council step and post-deploy check: `stages` and `assertHandedOver` in `test/nodejs/fixtures.ts`; procedure in the README runbook; the CI job in `.github/workflows/ci.yml`
- Tests: `deployment.test.ts` (rule order, a twin hook, an unattested rule or implementation stopping a product), `products.test.ts` (one core and many products, an intent token alone, funds, a later class, adding parts to a running core, a signed entry, a distribution, an issuer on another issuer's credential registry), `legos.test.ts` (the legos by profile, what the hand-over check refuses, products that do not build), `governance.test.ts` (upgrades, hook and rule changes, pause and recovery)
