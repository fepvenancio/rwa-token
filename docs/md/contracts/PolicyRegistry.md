[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Governance and deployment

# PolicyRegistry

The list of reviewed code. For each code hash the security council has reviewed, it records what that code may be installed as. Each place that installs a hook, a rule, a token implementation, a portfolio, an adapter, a validator or a fee model asks it first.

- **contracts/governance/PolicyRegistry.sol**
- immutable, **not a proxy**, one per core
- admin: **the main timelock**; attester: **the security council**
- not attested: it is the list itself

<a id="in-one-minute"></a>

> ### In one minute
>
> Every deployed contract has a code hash: a fingerprint of its code. Change one byte and the fingerprint changes. The security council reads a piece of code, then writes its fingerprint here together with what it is for. When something is plugged into the system, such as a token's implementation, its hook or its rules, or a vault's portfolio or fee model, the contract doing the install asks the registry one question: is this exact code on the list, for this purpose? If not, the install reverts. The registry is asked at that moment and not again. Taking a fingerprint off the list later does not switch off what is already running; governance replaces the component as a separate step.

<a id="how"></a>
## How it works

The registry stores one kind per code hash. The kinds are the values of `AttestKind`: `HOOK`, `RULE`, `IMPLEMENTATION`, `PORTFOLIO`, `ADAPTER`, `VALIDATOR` and `FEE_MODEL`, with `NONE` meaning nothing is stored. `isAttested(target, kind)` reads the code hash of the address it is given and compares the stored kind with the kind asked for. Fourteen calls in the system ask it, and no token movement does.

> **Diagram.** Fourteen install calls ask the registry. For HOOK: the token initialiser through \_installPolicy, and installPolicy. For RULE: ComplianceHook.setRules, ComplianceHook.onInstall when it is given a rule list, and Fund.setRule. For IMPLEMENTATION: ProxyDeployer.deploy and the upgrade check. For PORTFOLIO: Gated4626Vault.setPortfolio, NavDesk.setSettings and Portfolio.migrateTo. For ADAPTER: Portfolio.addAdapter. For VALIDATOR: GuardedAccount.setPermission. For FEE_MODEL: Gated4626Vault.setFeeModel and NavDesk.setFeeModel. Each asks isAttested with the target and the kind. The registry maps code hashes to kinds. The security council attests and revokes; the main timelock manages who holds ATTESTER_ROLE.
>
> **Fourteen calls, one question.** Each install asks whether the target's code hash is on the list for one kind, and reverts with its own error if it is not. The table below names each error and the main other checks; each contract's page has them all. Placing a token passes through three kinds in one transaction: the implementation (`ProxyDeployer.deploy`), the hook (the token's initialiser) and every rule in its first list (the initialiser passes it as the data of the hook's installation, and the hook installs it in `onInstall` when it is not empty).

| Kind | Where it is asked, and who can make that call | Reverts with | What the same call also checks |
|---|---|---|---|
| `HOOK` | The token's initialiser (`_installPolicy`), which runs inside `ProxyDeployer.deploy` | `PolicyGated_NotAttested` | The hook's `REGISTRY()` is the token's own registry (`PolicyGated_HookRegistryMismatch`), and the hook answers the id of `IERC8473Policy` (`PolicyGated_NotAPolicy`). |
| `HOOK` | `installPolicy`: the token's `DEFAULT_ADMIN_ROLE` | `PolicyGated_NotAttested` | The same two checks. |
| `RULE` | `ComplianceHook.setRules`: the token itself, or a holder of its `DEFAULT_ADMIN_ROLE` | `ComplianceHook_NotAttested` | The caller (`ComplianceHook_NotTokenAdmin`), at most 16 rules (`ComplianceHook_TooManyRules`), one rule per `ruleId` (`ComplianceHook_DuplicateRule`). Each rule in the list is asked about, and one unattested rule reverts the whole call. |
| `RULE` | `ComplianceHook.onInstall`, when its data carries a rule list: the token itself, from its initialiser or from `installPolicy` | `ComplianceHook_NotAttested` | The caller is the token (`ComplianceHook_OnlyToken`), and the same limits on the list as `setRules`. Empty data installs no list and asks nothing. |
| `RULE` | `Fund.setRule`: the fund's owner | `Fund_NotAttested` | The rule's `FUND()` is this fund (`Fund_RuleForAnotherFund`). |
| `IMPLEMENTATION` | `ProxyDeployer.deploy`: its owner, the operations account | `ProxyDeployer_ImplementationNotAttested` | Asked before the proxy is created. After setup it compares the token's registry with its own, and the token's hook, rule list and symbol with the call ([ProxyDeployer](ProxyDeployer.md)). |
| `IMPLEMENTATION` | `_authorizeUpgrade`, inside `upgradeToAndCall`: the token's `UPGRADER_ROLE` | `PolicyGated_NotAttested` | The new implementation reports the token's own `templateId()` (`Templated_WrongTemplate`), so an attested vault implementation is refused under an intent token. |
| `PORTFOLIO` | `Gated4626Vault.setPortfolio`: the vault's `DEFAULT_ADMIN_ROLE` | `Gated4626Vault_NotAttested` | The portfolio names this vault and accepts no reported adapter (`Gated4626Vault_PortfolioRefused`). |
| `PORTFOLIO` | `NavDesk.setSettings`: the vault's `DEFAULT_ADMIN_ROLE` | `NavDesk_PortfolioRefused` | The portfolio names the desk's vault. A zero address means no portfolio and is not asked about. |
| `PORTFOLIO` | `Portfolio.migrateTo`: the vault's `DEFAULT_ADMIN_ROLE` | `Portfolio_NotAttested` | No adapter is installed (`Portfolio_AdaptersInstalled`), and the successor has the same vault and asset (`Portfolio_WrongVault`, `Portfolio_WrongAsset`). |
| `ADAPTER` | `Portfolio.addAdapter`: the vault's `DEFAULT_ADMIN_ROLE` | `Portfolio_NotAttested` | The adapter names this portfolio and its asset (`Portfolio_WrongPortfolio`, `Portfolio_WrongAsset`), among others on the [Portfolio](Portfolio.md) page. |
| `VALIDATOR` | `GuardedAccount.setPermission`: the vault's `DEFAULT_ADMIN_ROLE` | `GuardedAccount_NotAttested` | The target is not the account's portfolio, its vault or the account itself (`GuardedAccount_ForbiddenTarget`). |
| `FEE_MODEL` | `Gated4626Vault.setFeeModel`: the vault's `DEFAULT_ADMIN_ROLE` | `Gated4626Vault_NotAttested` | The vault has a portfolio (`Gated4626Vault_NoPortfolio`). |
| `FEE_MODEL` | `NavDesk.setFeeModel`: the vault's `DEFAULT_ADMIN_ROLE` | `NavDesk_FeeModelRefused` | A zero address removes the model and is not asked about. |

The registry each one asks is fixed. A token stores its registry at initialisation and has no setter. [`ComplianceHook`](ComplianceHook.md), [`Fund`](Fund.md) and [`ProxyDeployer`](ProxyDeployer.md) hold it as the immutable `REGISTRY`. [`Portfolio`](Portfolio.md), [`GuardedAccount`](GuardedAccount.md) and [`NavDesk`](NavDesk.md) ask their vault for its `registry()` at the moment of the call.

The council attests in three steps of a deployment: after `Core` the rules, the hook and the implementations; after each `Fund` module that fund's `FundHoldersRule`; after each `Legos` module the portfolio, the adapters, the validators and the fee model ([Deployment and governance](../deployment.md)). `attest` and `revoke` wait for no timelock: they are the council's own actions.

<a id="codehash"></a>
## What a code hash covers

A code hash is the hash of a contract's runtime code, and that code includes the values of its `immutable` variables. It does not include storage. Several things follow from that, and each shapes how the system is deployed.

- **Identical code shares one attestation.** Two contracts with the same runtime code have the same hash, so attesting one attests both (`test_WhenAnotherContractHasTheSameCode_ItReturnsTrue`).
- **The shared hook.** [`ComplianceHook`](ComplianceHook.md)'s one immutable is its registry, so one attestation covers the hook every token uses, and any other hook built on the same registry carries the same hash. A token refuses a hook that names another registry. The rule list each token runs lives in the hook's storage, which the hash does not cover, so [`ProxyDeployer`](ProxyDeployer.md) and the post-deploy check compare each token's list, and the check also compares the hook instance.
- **Each implementation needs its own attestation.** OpenZeppelin's UUPS code stores the implementation's own address in an immutable, so each deployment of a token implementation has a different hash, even from identical source (`test_WhenAnotherInstanceOfTheTemplateIsNotAttested_ItReverts`).
- **Rules that point at another contract.** [`CredentialRule`](CredentialRule.md) holds its credential registry's address as an immutable, and [`FundHoldersRule`](FundHoldersRule.md) holds its fund's. The hash covers those addresses, not the code at them, so the council reads the contract each one points at before it attests the rule. Each fund's rule has its own hash and its own attestation.
- **Lego settings.** A `FeeModel`'s rates and recipient, an `ERC20CallValidator`'s one address and amount, and a `Portfolio`'s vault, asset and `ACCEPTS_REPORTED` are immutables, so the hash covers them. Instances with different settings each need their own attestation, and instances with the same settings share one: a successor `Portfolio` with the same three settings carries its predecessor's attestation. A portfolio's caps and adapter list are storage and are not covered.

<a id="install-time"></a>
## What revoking does and does not do

No token asks the registry when tokens move. The registry is read when a component is installed, and not again for that install. So `revoke` changes nothing that is already running. What it does is refuse the same code from then on, at every gate of that kind:

- A hook, rule, portfolio, adapter, validator or fee model that was revoked stays where it is and keeps working.
- A proxy over a revoked implementation keeps running that code. `ProxyDeployer.deploy` and an upgrade to it revert.
- `setRules`, and `onInstall` with a rule list, ask about each rule in the list they are given, so a later change to a token's list reverts if that list still names a revoked rule.
- The post-deploy check reads the registry for the fund's rule, the credential rule and each product's portfolio, adapters and fee model, so running it again after a revoke fails on those. That check runs off-chain, and nothing on chain acts on its result.

If a revoke reached running tokens, it would have to do one of two things to each token that runs the revoked code: skip that check, so a rule silently stops applying, or fail every movement. Asking at install time leaves that decision to governance. The guardian can pause the affected tokens at once, and the main timelock replaces the component, which waits out its delay. A pause does not stop a forced transfer, which still runs the hook and its rules.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `attest(codehash, kind, uri)` | `ATTESTER_ROLE` (the security council) | Puts a code hash on the list as `kind`. `uri` points to the review record and is not read by any contract. Emits `Attested(codehash, kind, attester, uri)`. Reverts with `PolicyRegistry_InvalidKind` for `NONE`, `PolicyRegistry_InvalidCodehash` for the zero hash or the hash of empty code, and `PolicyRegistry_AlreadyAttested(codehash)` if the hash already has a kind. |
| `revoke(codehash)` | `ATTESTER_ROLE` | Takes a code hash off the list. Emits `AttestationRevoked(codehash, attester)`. Reverts with `PolicyRegistry_NotAttested(codehash)` if it has no kind. |
| `isAttested(target, kind)` | Anyone (read-only) | Whether the kind stored for `target`'s code hash is `kind`. False for `NONE` and for an address with no code. |
| `kindOf(codehash)` | Anyone (read-only) | The kind stored for a code hash, or `NONE`. |
| `grantRole`, `revokeRole` | `DEFAULT_ADMIN_ROLE` (the main timelock) | OpenZeppelin `AccessControl`: decides who holds `ATTESTER_ROLE` and who administers the registry. Reverts with `AccessControlUnauthorizedAccount` for anyone else. |
| `renounceRole` | The holder of the role | Gives up one's own role. |
| `hasRole`, `getRoleAdmin`, `ATTESTER_ROLE()`, `DEFAULT_ADMIN_ROLE()` | Anyone (read-only) | Read the role table and the role ids. |
| `supportsInterface(id)` | Anyone (read-only) | ERC-165: true for `IPolicyRegistry` and the `AccessControl` interfaces. |

The constructor takes the admin and the first attester and refuses a zero address for either (`PolicyRegistry_ZeroAddress`). `Core` passes the main timelock and the council, so the registry is under governance from its first block. Role changes emit OpenZeppelin's `RoleGranted` and `RoleRevoked`.

<a id="why"></a>
## Why it is built this way

- **One immutable list per core.** The registry is not a proxy and has no setter beyond its roles, so the list of reviewed code is not something an upgrade can swap.
- **By code, not by address.** An attestation follows the bytes the council read, immutables included. The council publishes where the review is through `uri`, and the `Attested` and `AttestationRevoked` events record who did what.
- **One kind per hash.** A hash is a hook or a rule, not both. Changing its kind takes a revoke first, then a fresh attestation, so the change shows in the events.
- **Empty hashes are refused.** An address with no code has a code hash of zero or the hash of empty code. `attest` refuses both, so an empty address does not pass a gate.
- **Hooks and rules are plain contracts.** A proxy's code hash is the hash of the small forwarding contract, not of the code it forwards to, so attesting one would vouch for whatever it points at later. Changing a hook or a rule means deploying other code, having it attested, and installing it. Token implementations are the one kind behind a proxy: their gate is the upgrade itself, and the template check keeps a token on its own template.
- **No authority in storage.** Anyone can deploy a copy of attested code and give the copy different storage, and the copy carries the same attestation. So what matters for security sits in the code or its immutables. Rules keep no owner or role of their own: they ask the token's roles at the moment of the call (`IAccessControl(token).hasRole`), and the post-deploy check asserts that a rule exposes no `hasRole` or `owner`.
- **Separate duties.** The council attests and revokes. The main timelock, with its delay, decides who sits on the council. An attestation installs nothing: each gate has its own caller.

<a id="limits"></a>
## What it does not do

- **It does not review anything.** An attestation is the council's statement. The registry does not read the record behind `uri`, and nothing on chain checks that a review took place.
- **It does not watch what is running.** See [what revoking does](#install-time). A revoke is a signal and a stop on further installs. Removing the component is a separate governance action.
- **It does not see storage or the code at an address.** It says nothing about a token's rule list, a portfolio's caps, what a credential registry or a fund does, or how an adapter's target behaves.
- **It does not stop copies.** A second hook on the same registry has the attested hash and passes the token's check. The post-deploy check is what refuses it (`ProxyDeployer` compares with the hook named in the call, not with the one the council reviewed).
- **It does not list everything.** Nothing installs [`CredentialRegistry`](CredentialRegistry.md), [`Fund`](Fund.md), [`NavDesk`](NavDesk.md), the executors, [`SignedEntry`](SignedEntry.md), [`Distributor`](Distributor.md), `ProxyDeployer`, [`GovernanceTimelock`](GovernanceTimelock.md) or [`TokenProxy`](TokenProxy.md) by code hash, so they are not attested. The council reads the first two before it attests the rule that points at them.
- **It does not limit the council.** A holder of `ATTESTER_ROLE` can attest any hash at once. That the council is a multisig is a deployment choice, not something the contract checks. An attestation alone changes nothing that exists, but `ProxyDeployer.deploy` asks only for its owner and an attested implementation, so a bad attestation together with the operations key can place a token over that code. The issuer's published list of addresses and the post-deploy check are the controls there.
- **The guardian has no role here** as deployed, and the recovery timelock holds none. The post-deploy check pins the second and does not ask about the guardian on this contract. Removing a council member goes through the main timelock.

<a id="connected"></a>
## Connected to

- [ProxyDeployer](ProxyDeployer.md): Asks about the implementation before it creates a token.
- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): The token base: asks about the hook at setup and on `installPolicy`, and about the implementation on upgrade.
- [ComplianceHook](ComplianceHook.md): Asks about each rule in a token's list when the list is installed.
- [Fund](Fund.md): Asks about the fund-wide holder rule when it is set.
- [Portfolio](Portfolio.md): Asks about each adapter it adds and the successor it migrates to.
- [GuardedAccount](GuardedAccount.md): Asks about each validator a permission names.
- [Gated4626Vault](Gated4626Vault.md): Asks about the portfolio and the fee model it plugs in.
- [NavDesk](NavDesk.md): Asks about the portfolio and the fee model in its settings.
- [GovernanceTimelock](GovernanceTimelock.md): The main timelock: the registry's admin.
- [Deployment and governance](../deployment.md): The council's steps between the deployment modules.

<a id="source"></a>
## Source and tests

- Contract: `contracts/governance/PolicyRegistry.sol`, interface `IPolicyRegistry.sol`
- Tests: `PolicyRegistry.t.sol` (attest, revoke, kinds, empty hashes, shared code, role gates). The gates are tested where they live: `PolicyGatedERC20Upgradeable.t.sol`, `ComplianceHook.t.sol`, `Fund.t.sol`, `ProxyDeployer.t.sol`, `Portfolio.t.sol`, `GuardedAccount.t.sol`, `Gated4626VaultPortfolio.t.sol` and `NavDesk.t.sol`. Through the real deployment: `test/nodejs/deployment.test.ts` (an unattested implementation or rule stops the product), `governance.test.ts` (an upgrade to unattested code is refused at execution) and `legos.test.ts` (the post-deploy check fails after a revoke).

---

Describes the contracts at commit `75aa171` on `main`.
