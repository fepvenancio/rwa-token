[Overview](index.md) · [Contracts](index.md#contracts) · [Who can do what](roles.md) · [One movement](movement.md) · [Deployment and governance](deployment.md) · [Where the money sits](money.md)

[Overview](index.md) / Governance

# Who can do what

Every privileged power in the system is a named role on a named contract, the ownership of one, an entry in the credential registry's attester list, or a call open only to one other contract. A holder can also approve a spender, and on a 7540 an operator, over its own position. This page lists who holds each power once the deployment is finished, what it allows and what it does not, how long it waits, and what still works while something is paused.

- holders set by **ignition/modules**
- delay: **24 hours** by default, floor **1 hour**, on both timelocks
- guardian: **stop-only**
- checked by **npm run check** (scripts/lib/check.ts)

[In one minute](#in-one-minute) · [Authority map](#map) · [Who holds what](#holders) · [On tokens and vaults](#tokens) · [Legos](#legos) · [On the other contracts](#others) · [The guardian](#guardian) · [The recovery path](#recovery) · [The delay](#delay) · [During a pause](#pause) · [Why](#why) · [Limits](#limits)

<a id="in-one-minute"></a>

> ### In one minute
>
> A **role** is a permission an account holds on one contract (OpenZeppelin `AccessControl`). A **timelock** is a contract that runs a call only after the call has been public for a fixed delay, so anyone can see a change coming and react. After deployment the deployer holds nothing. The main timelock administers every product (a token or vault), the executors and both registries, and owns each fund, so a change of policy or code, and a role grant, waits at least the delay: 24 hours by default, and never below the contract's 1-hour floor. An **operations account** launches further products with no wait, and that launch changes nothing that exists. Day-to-day work, such as issuing, enforcing and allocating, belongs to operational accounts and takes effect at once. A price on a desk waits out the desk's cooldown from its proposal. The **guardian**, meant to be a multisig, can stop things at once but cannot start anything. A second timelock, the recovery timelock, can lift a pause, clear a guardian block, revive an attester, remove the guardian, and take away any account's right to cancel on the main timelock. Beyond itself it has no other power. A lowered cap or rate or a revoked permission is restored by the main timelock.

<a id="map"></a>
## Authority map

Two kinds of power. Above the line, everything goes through a timelock: governance proposes, waits out the delay, then executes, and the target contract sees the timelock as the caller. Below the line, each account acts directly and at once, but only within its narrow job.

> **Diagram.** Authority map. Above the line: the governance multisig schedules and executes on the recovery timelock and on the main timelock. The recovery timelock can unpause products and executors, revoke GUARDIAN_ROLE on those and on the credential registry, clear a guardian block, revive an attester, and revoke CANCELLER_ROLE on the main timelock. The main timelock is admin of each product, the executors, both registries and itself, the only upgrader of products, owner of each fund once it has opened, and the admin that the hook, the rules, a portfolio, a desk and a guarded account ask for. The guardian can cancel pending operations on the main timelock. Below the line, acting at once: the guardian pauses and blocks and can bring money back and lower limits; the security council attests and revokes code; the KYC attester writes credentials; the operations account deploys products; the agent forces transfers, freezes amounts, sets lockups and address freezes; the minter and burner mint and burn on token templates, the NFT and the multi-token included; the operator submits through the executors and the order settlement; the settler, a desk, closes and settles periods; the reporter and checker propose, accept and cancel a price; the allocator allocates and makes guarded calls; the distribution maker and checker propose and approve distributions.
>
> **Above the line power waits. Below it power acts at once but is narrow.** The red dashed line is the guardian's one power over the main timelock: it can cancel any operation that has not run yet. Holders act on their own balances directly and are not drawn.

<a id="holders"></a>
## Who holds what after deployment

These are the holders that the Ignition modules set up. "Multisig" here says what each account is meant to be: the modules take an address and do not check. The contracts do not forbid other holders: whoever holds `DEFAULT_ADMIN_ROLE` on a contract can grant and revoke every other role on it, because no contract here changes OpenZeppelin's default role admin. After the hand-over that is the main timelock, so any further holder waits for its delay.

| Holder | Where | Role | Set by |
|---|---|---|---|
| Main timelock | each product | `DEFAULT_ADMIN_ROLE`, `UPGRADER_ROLE` | `Product` grants both, and the operations account renounces its admin role. The module grants nobody else `UPGRADER_ROLE`. |
| Main timelock | `PolicyRegistry` | `DEFAULT_ADMIN_ROLE` | the registry's constructor, in `Core` |
| Main timelock | `CredentialRegistry`, each executor | `DEFAULT_ADMIN_ROLE` | `CoreHandover` grants it, then the deployer renounces |
| Main timelock | itself | `DEFAULT_ADMIN_ROLE` | OpenZeppelin's `TimelockController` constructor makes every timelock its own admin |
| Main timelock | each `Fund` | owner | `FundOpen` calls `transferOwnership` |
| Recovery timelock | each product | `RECOVERY_ROLE` | `Product` |
| Recovery timelock | each executor, `CredentialRegistry` | `RECOVERY_ROLE` | `CoreHandover` |
| Recovery timelock | main timelock | `RECOVERY_ROLE` | the `GovernanceTimelock` constructor |
| Recovery timelock | itself | `DEFAULT_ADMIN_ROLE` | OpenZeppelin's constructor. Nobody holds `RECOVERY_ROLE` on the recovery timelock. |
| Governance multisig | main timelock | `PROPOSER_ROLE`, `EXECUTOR_ROLE`, `CANCELLER_ROLE` | `Core` names it proposer and executor; OpenZeppelin's constructor also makes every initial proposer a canceller |
| Governance multisig | recovery timelock | `PROPOSER_ROLE`, `EXECUTOR_ROLE` | `Core`; `CoreHandover` revokes the canceller role OpenZeppelin gave it, so nobody can cancel there |
| Guardian multisig | each product | `GUARDIAN_ROLE` | the product's initialiser |
| Guardian multisig | each executor, `CredentialRegistry` | `GUARDIAN_ROLE` | their constructors |
| Guardian multisig | main timelock | `CANCELLER_ROLE` | `CoreHandover`. It holds nothing on the recovery timelock. |
| Security council | `PolicyRegistry` | `ATTESTER_ROLE` | the registry's constructor |
| KYC provider | `CredentialRegistry` | attester 0: an entry in the registry's attester list, not an `AccessControl` role | `CoreHandover` calls `addAttester`. It may assert the ten named qualification bits unless the `kycAllowedQuals` parameter says otherwise. |
| Operations account | `ProxyDeployer` | owner | `CoreHandover`. It also owns a fund until `FundOpen` and administers a product until the end of its `Product`, and afterwards holds nothing on either. |
| Agent (the issuer's compliance desk) | each product | `AGENT_ROLE` | `Product` |
| Minter, burner (the issuer) | each `GatedToken`, `IntentToken`, `Gated721` and `Gated1155` | `MINTER_ROLE`, `BURNER_ROLE` | `Product`. No module grants them on a vault. |
| `IntentExecutor`, `DvPExecutor` | each `IntentToken` that names them | `EXECUTOR_ROLE` | `Product` |
| Operator (an issuer or relayer key) | each executor, and the `OrderSettlement` if the core has one | `OPERATOR_ROLE` | `CoreHandover` |
| A `NavDesk`, or the `settler` account where there is none | each `Gated7540Vault` | `SETTLER_ROLE` | `Product`. With no desk the account sets any price alone, which only the `full` test profile does. |
| Reporter, checker (fund administration, and a second function) | each vault with a desk | `REPORTER_ROLE`, `CHECKER_ROLE` | `Product` |
| Allocator (the fund manager) | each vault with a portfolio | `ALLOCATOR_ROLE` | `Product` |
| The `distributionMaker` and `checker` accounts | a token with a `Distributor` | `DISTRIBUTION_MAKER_ROLE`, `CHECKER_ROLE` | `Product`, for a product that sets `distributor`. The checker is the same account that approves a desk's prices on a vault with one. For a distributor added after launch the main timelock grants both, except `CHECKER_ROLE` on a vault with a desk, which the checker already holds. |

Until `CoreHandover` finishes, the deployer administers the credential registry, the executors and both timelocks, and owns `ProxyDeployer`. [Deployment and governance](deployment.md#handover) has the order. For a credential registry or an executor added to a running core, `PartsHandover` makes the grants and the hand-over that the table credits to `CoreHandover`. A core that reads an existing credential registry has none of its own: the `CredentialRegistry` rows then describe whoever governs that registry, and the deployment names its admin and guardian ([Using an existing credential registry](deployment.md#external)).

### Who must not hold a sensitive role on a single key

The post-deploy check refuses `MINTER_ROLE`, `BURNER_ROLE`, `AGENT_ROLE` and `SETTLER_ROLE` on an account that does not answer `getThreshold()` with 2 or more, as a Safe that requires at least two signatures does. A profile can name any of the four in `singleSigners` to except it, for example for an MPC custody wallet whose policy engine does the same job. All eight shipped profiles name all four, because they are demo stacks, so a real deployment has to state its own. This is the check's rule, not the contracts': a token accepts any holder its admin grants. The check does not read a Safe's signers, and CI runs it on a local chain only. [What it asserts, and who runs it](deployment.md#check).

<a id="tokens"></a>
## On tokens and vaults

All six templates, [`GatedToken`](contracts/GatedToken.md), [`IntentToken`](contracts/IntentToken.md), [`Gated721`](contracts/Gated721.md), [`Gated1155`](contracts/Gated1155.md), [`Gated4626Vault`](contracts/Gated4626Vault.md) and [`Gated7540Vault`](contracts/Gated7540Vault.md), share these roles through the core [`PolicyGatedCoreUpgradeable`](contracts/PolicyGatedCoreUpgradeable.md). The table gives the fungible functions; `Gated721`'s take a token id instead of an amount, and `Gated1155`'s a token id and an amount, as the next table shows.

| Role and holder | Can | Cannot, or only with limits |
|---|---|---|
| `DEFAULT_ADMIN_ROLE`<br>main timelock | Grant and revoke every role. `installPolicy`. `unpause()`. It is also the "token admin" that the hook asks before `setRules`, that the rules ask before their settings, and that a portfolio, a guarded account and a desk ask. | A hook must be attested as `HOOK`, name the token's registry and answer the policy interface id (`PolicyGated_NotAttested`, `PolicyGated_HookRegistryMismatch`, `PolicyGated_NotAPolicy`). The registry itself has no setter. |
| `UPGRADER_ROLE`<br>main timelock | `upgradeToAndCall(implementation, data)` | The implementation must be attested as `IMPLEMENTATION` and report the same `templateId()` (`PolicyGated_NotAttested`, `Templated_WrongTemplate`). |
| `MINTER_ROLE`<br>minter, on token templates | `mint(to, amount)`, which runs the hook as a MINT | The receiver must pass the rules. Refused while paused. On both vaults this function reverts for every caller (`GatedVault_Unsupported`): shares come only from deposits, deposit claims and the agent's `recoverClaimable`, which delivers claimable shares as a FORCED mint. |
| `BURNER_ROLE`<br>burner, on token templates | `burn(from, amount)` with no allowance, a FORCED move with no receiver that works while paused. It may take frozen tokens and lowers the frozen amount by the part it takes. The holder's lockup, address freeze, standing and minimum position do not stop it. | Never more than the balance (`ERC20InsufficientBalance`). It still runs the hook, so a token with no rules refuses it. Reverts on both vaults for every caller. No rule reads the role: the kind decides, so an account that holds the role and moves its own tokens is judged like any holder. |
| `AGENT_ROLE`<br>agent | `forcedTransfer(from, to, amount)`, a FORCED move that works while paused and may take frozen tokens. `setFrozenTokens(account, amount)`. On `HolderRestrictionRule`, `setLockup` and `setFrozen` for this token. | The receiver of a forced move is still judged: it needs a credential the token's policy accepts and must not be address-frozen. |
| `GUARDIAN_ROLE`<br>guardian multisig | `pause()`, with no delay. [What else the role allows](#guardian), on a 4626 and on a vault's legos. | Cannot unpause, grant roles, change the hook or upgrade. |
| `RECOVERY_ROLE`<br>recovery timelock | `unpause()` and `revokeRole(GUARDIAN_ROLE, account)` | Nothing else: it is not a role admin, so it cannot grant, and every other revocation needs the role's admin. |
| No role: any account | `transfer`, `transferFrom`, `approve`, `permit`, `multicall`, `renounceRole` for itself. | Every balance movement goes through the hook. `multicall` runs each inner call with the caller as sender, so each needs the role it would need alone. |

### What each template adds

| Template | Who | What |
|---|---|---|
| `Gated721` | `MINTER_ROLE` | `mint(to, tokenId, uri)`, a MINT of one item with its metadata URI. |
|  | `BURNER_ROLE` | `burn(tokenId)`, with no approval, a FORCED move with no receiver that works while paused. It may take an item frozen for its owner and clears that freeze. |
|  | `AGENT_ROLE` | `forcedTransfer(from, to, tokenId)`, `setFrozenTokens(account, tokenId, frozenStatus)`, a freeze of one item for one account, and `setTokenURI(tokenId, uri)`. |
|  | The owner, or an approved operator | `transferFrom` and `safeTransferFrom`, judged as TRANSFER. |
|  | Any account | `setApprovalForAll` for itself, and `approve` of an item it owns or is approved for all of. There is no `permit`. |
| `Gated1155` | `MINTER_ROLE` | `mint(to, tokenId, amount)`, a MINT of an amount of one token id. A receiver that is a contract gets ERC-1155's callback and must accept. |
|  | `BURNER_ROLE` | `burn(from, tokenId, amount)`, with no approval, a FORCED move with no receiver that works while paused. It may take frozen tokens of that id and lowers the frozen amount by the part it takes. |
|  | `AGENT_ROLE` | `forcedTransfer(from, to, tokenId, amount)`, `setFrozenTokens(account, tokenId, amount)`, a frozen amount of one token id for one account, and `setURI(tokenId, uri)`. |
|  | The holder, or an operator approved for all | `safeTransferFrom` and `safeBatchTransferFrom`, judged as TRANSFER, one item at a time. |
|  | Any account | `setApprovalForAll` for itself. There is no approval for one token id and no `permit`. |
| `IntentToken` | `EXECUTOR_ROLE`<br>the executor contracts it names | `executeTransfer(intent, sig)` runs a holder-signed intent as an EXECUTED move. Only an intent that names this executor, or names none and states no consideration (`WRONG_EXECUTOR`, `CONSIDERATION_NEEDS_EXECUTOR`). The token checks the signature, so the executor cannot change any field. |
|  | Any account | `cancelIntent(nonce)` for its own nonces. |
| `Gated4626Vault` | `DEFAULT_ADMIN_ROLE` | `setPortfolio(portfolio, rate)`, `setFeeModel`, and `setMaxRate` in either direction. A portfolio or fee model must be attested (`Gated4626Vault_NotAttested`). |
|  | `GUARDIAN_ROLE` | `setMaxRate` to the same rate or a lower one. A higher one reverts with `Gated4626Vault_Unauthorized`. |
|  | Any account | `deposit`, `mint`, `withdraw`, `redeem`, which the rules judge as MINT and BURN. `accrue`, and `collectFees`, which pays the recipient the fee model names, not while paused. A payer or a cash receiver other than the party itself must pass the policy (`GatedVault_ThirdPartyNotEligible`). |
| `Gated7540Vault` | `SETTLER_ROLE`<br>its `NavDesk` | `closePeriod` and `settlePeriod(nav, fee, cash, feeRecipient, redeemLimit)`. The vault takes whatever price and limit it is given and can pull from any cash account that approved it, so this role sets the price and how much of a period's redemptions it takes. Once a request's period has closed: `rejectDepositRequest`, `rejectRedeemRequest`, `recoverRedeemRequest`. These run in [`Gated7540Settlement`](contracts/Gated7540Settlement.md), on the vault's role table. |
|  | `AGENT_ROLE` | The same three while the request's period is open; once it has closed they revert with `AccessControlUnauthorizedAccount`, and with a desk the agent goes through `NavDesk.refundRequest` and `recoverRequest`. `recoverClaimable` at any time. `forcedTransfer` out of the vault's own address takes only shares not booked to a pending redemption (`Gated7540Vault_ExceedsSurplus`), and `setFrozenTokens` refuses the vault's own address (`GatedVault_Unsupported`). |
|  | A controller or its operator | Claims: `deposit`, `mint`, `redeem`, `withdraw` (`Gated7540Vault_Unauthorized` otherwise). |
|  | An owner, or its operator | `requestDeposit` pulling that owner's assets. `requestRedeem` taking that owner's shares, which a spender with an allowance can also do. |
|  | Any account | `setOperator` for itself. An operator is a full delegate, so an owner should approve only someone it would trust with the assets. |

<a id="legos"></a>
## Contracts that ask the vault or token

These have no role table of their own, and none is a proxy. Each names its vault or token and, the adapter apart, calls `hasRole` on it at call time for the caller. So moving a role on the vault moves the power here, with nothing else to update, and revoking `GUARDIAN_ROLE` on the vault also ends the guardian's powers on its legos. `ALLOCATOR_ROLE`, `REPORTER_ROLE`, `CHECKER_ROLE` and `DISTRIBUTION_MAKER_ROLE` are held on the vault or token, and the vault has no getter for them: the constant is on the lego.

| Contract | Role on its vault or token, or caller | What |
|---|---|---|
| [`Portfolio`](contracts/Portfolio.md)<br>asks its vault; `Portfolio_Unauthorized` | `DEFAULT_ADMIN_ROLE` | `addAdapter`, `removeAdapter`, `writeOffAdapter`, `migrateTo`, and `setCaps` in either direction. |
|  | `GUARDIAN_ROLE` | `setCaps` when neither cap rises. `deallocate`, which brings money back to the portfolio. |
|  | `ALLOCATOR_ROLE` | `allocate`, with the allocation under the caps and not while the vault is paused (`Portfolio_VaultPaused`). `deallocate`. `setLiquidityAdapter`. |
|  | The vault itself | `raise`, which pulls from the liquidity adapter what a withdrawal needs. |
| [`GuardedAccount`](contracts/GuardedAccount.md)<br>asks its vault; `GuardedAccount_Unauthorized` | `ALLOCATOR_ROLE` | `execute`, not while the vault is paused (`GuardedAccount_VaultPaused`), and only calls with a permission whose validator accepts them (`GuardedAccount_CallRefused`). |
|  | `DEFAULT_ADMIN_ROLE` | `setPermission`, with an attested validator (`GuardedAccount_NotAttested`) and not naming the portfolio, the vault or the account itself (`GuardedAccount_ForbiddenTarget`). |
|  | `DEFAULT_ADMIN_ROLE` or `GUARDIAN_ROLE` | `revokePermission` |
|  | Its portfolio | `allocate`, `deallocate` |
| [`ERC4626Adapter`](contracts/ERC4626Adapter.md) | Its portfolio | `allocate`, `deallocate` (`ERC4626Adapter_OnlyPortfolio`). It asks the vault for nothing. |
| [`Gated4626Adapter`](contracts/Gated4626Adapter.md) | Its portfolio | The same two, by the same code. It reads its target, a master vault, and holds no role on it. |
| [`NavDesk`](contracts/NavDesk.md)<br>asks its vault; `NavDesk_Unauthorized` | `DEFAULT_ADMIN_ROLE` | `setSettings`, `setFeeModel`, `setRedemptionGate`, `adopt`. |
|  | `REPORTER_ROLE` | `propose` |
|  | `CHECKER_ROLE` | `accept`, but not a proposal the same account made (`NavDesk_SelfAccept`). `cancel`. |
|  | `GUARDIAN_ROLE` | `cancel`, any time before execution. It cannot set the redemption gate (`test_TheGuardianCannotSetTheLevel`). |
|  | `AGENT_ROLE` | `refundRequest` and `recoverRequest`, with no proposal on the table and the period closed for longer than `maxReportAge` (`NavDesk_NotStuck`). |
|  | Any account | `closePeriod`, once `periodLength` has passed. `execute`, after acceptance and the `cooldown`, with a report no older than `maxReportAge`. The desk acts on the vault through its own `SETTLER_ROLE`, which `isWired()` reports. |
| [`Distributor`](contracts/Distributor.md)<br>asks its token; `Distributor_Unauthorized` | `DISTRIBUTION_MAKER_ROLE` | `propose` |
|  | `CHECKER_ROLE` | `approve`, but not a distribution the same account proposed (`Distributor_SelfApproval`). Approving pulls the funding. |
|  | Any account | `claim`, which pays the holder a proof names, if the token's `canReceive` says yes. `claimBatch`, the same for many holders at once, passing over a holder that cannot be paid now. `sweep`, after the expiry, which returns what is left to the funder. |

`CHECKER_ROLE` is the same role id on `NavDesk` and `Distributor`. On a vault that has both, one holder can check both prices and distributions.

<a id="others"></a>
## On the other contracts

| Contract | Who | What |
|---|---|---|
| [`IntentExecutor`](contracts/IntentExecutor.md), [`DvPExecutor`](contracts/DvPExecutor.md) | `OPERATOR_ROLE` | Submit: `execute` and `executeBatch`, or `executeDvPGated` and `executeDvP3009`. Only while the executor is not paused (`EnforcedPause`). |
|  | `GUARDIAN_ROLE` | `pause()` |
|  | `DEFAULT_ADMIN_ROLE` or `RECOVERY_ROLE` | `unpause()`. Anyone else gets `AccessControlUnauthorizedAccount(caller, DEFAULT_ADMIN_ROLE)`. |
|  | `DEFAULT_ADMIN_ROLE` | Grant and revoke roles. `RECOVERY_ROLE` may also revoke `GUARDIAN_ROLE`, and nothing else. |
| [`OrderSettlement`](contracts/OrderSettlement.md) | `OPERATOR_ROLE` | Submit: `settle(fills)`, a batch of fills of orders the makers signed. Only while it is not paused (`EnforcedPause`). It holds no role on any token: each leg is a TRANSFER under the maker's allowance. |
|  | `GUARDIAN_ROLE` | `pause()` |
|  | `DEFAULT_ADMIN_ROLE` or `RECOVERY_ROLE` | `unpause()`. Anyone else gets `AccessControlUnauthorizedAccount(caller, DEFAULT_ADMIN_ROLE)`. |
|  | `DEFAULT_ADMIN_ROLE` | Grant and revoke roles. `RECOVERY_ROLE` may also revoke `GUARDIAN_ROLE`, and nothing else. |
|  | Any account | `cancelOrder(nonce)` for its own nonces, also while paused. A maker's own `approve` or `setApprovalForAll` on a token is what lets a fill move its tokens. |
| [`PolicyRegistry`](contracts/PolicyRegistry.md) | `ATTESTER_ROLE` | `attest(codehash, kind, uri)`, `revoke(codehash)`. No delay. |
|  | `DEFAULT_ADMIN_ROLE` | Manage the attesters. |
| [`CredentialRegistry`](contracts/CredentialRegistry.md) | An attester in its list that is not killed | `set(subject, validUntil, quals, entity)`, within the bits it may assert, over an empty address, a record it wrote or a killed attester's record. The entity names the investor the address belongs to, in the attester's own numbering, and a fund built over the registry counts investors by it. `setStatus` only on a record it wrote. |
|  | Any account | `register(credential, sig)`, with a credential signed by an attester that is not killed. The entity is part of what the attester signed. |
|  | `GUARDIAN_ROLE` | `blockSubject(subject)`. `killAttester(id)`, which the admin may also call. |
|  | `DEFAULT_ADMIN_ROLE` or `RECOVERY_ROLE` | `clearGuardianBlock(subject)`, `reviveAttester(id)`. |
|  | `DEFAULT_ADMIN_ROLE` | `addAttester`, `setAttesterAccount`, `setAttesterQuals`, roles. `RECOVERY_ROLE` may also revoke `GUARDIAN_ROLE`. |
| [`ComplianceHook`](contracts/ComplianceHook.md) | The token itself, or the holder of `DEFAULT_ADMIN_ROLE` on that token | `setRules(token, rules)`. The hook has no roles of its own: it asks the token at call time (`ComplianceHook_NotTokenAdmin` otherwise). `afterTransfer` is open only to the token the context names, and `onInstall` only to the token it names (`ComplianceHook_OnlyToken`). |
| Rules | The holder of `DEFAULT_ADMIN_ROLE` on the token | `CredentialRule.setPolicy`, `SettlementWindowRule.setWindow`, `MinPositionRule.setMinPosition` and `setExempt`, `SupplyCapRule.setSupplyCap`. Each rule asks the token at call time. |
|  | The holder of `AGENT_ROLE` on the token | `HolderRestrictionRule.setLockup`, `setFrozen`. |
|  | The hook the token has installed | `after_` (`ComplianceRule_OnlyHook`), which `FundHoldersRule` uses to record investors. |
|  | Nobody | `FundHoldersRule` has no settings, because its cap and exemptions live in the fund. `ExecutedOnlyRule` has no settings at all. |
| [`Fund`](contracts/Fund.md) | Owner: the operations account until `FundOpen`, then the main timelock | `registerClass`, `setRule`, `setHolderCap`, `setExempt`, and OpenZeppelin's `transferOwnership` and `renounceOwnership`. |
|  | The installed rule | `join`, `leave` (`Fund_OnlyRule`). |
|  | Any account | `rekey(account)`, which moves a counted address to the entity key the credential registry gives it at that moment. It can move the count by one, also above the cap, and changes nothing else. |
| [`ProxyDeployer`](contracts/ProxyDeployer.md) | Owner: the operations account | `deploy`, with no delay, and OpenZeppelin's `transferOwnership` and `renounceOwnership`. The main timelock has no power here. |
| [Main timelock](contracts/GovernanceTimelock.md) | `PROPOSER_ROLE`, `EXECUTOR_ROLE`, `CANCELLER_ROLE` | `schedule`, `execute`, `cancel` and their batch forms. Proposer and executor: governance. Cancellers: governance and the guardian. |
|  | The timelock itself | `updateDelay`, `grantRole`, `revokeRole`, through its own operations. |
|  | `RECOVERY_ROLE` | `revokeRole(CANCELLER_ROLE, account)`, for any holder, and nothing else. |
| Recovery timelock | Governance | Proposer and executor. Nobody holds `CANCELLER_ROLE` or `RECOVERY_ROLE` on it. It administers itself, through its own operations. |
| No roles | Any account | [`FeeModel`](contracts/FeeModel.md), [`ERC20CallValidator`](contracts/ERC20CallValidator.md) and [`ERC4626CallValidator`](contracts/ERC4626CallValidator.md) are views with no gate. [`SignedEntry`](contracts/SignedEntry.md) has no roles: anyone can submit an entry the investor signed, and `cancelEntry` covers the caller's own nonces. [`SignedExit`](contracts/SignedExit.md) has no roles either: anyone can submit an exit the holder signed with `exitWithPermit`, anyone can call `claimFor`, which delivers a 7540's settled claims to each controller that made it its operator, and `cancelExit` covers the caller's own nonces. [`TokenProxy`](contracts/TokenProxy.md) forwards to its implementation. |

Some words mean several things in this code. `OPERATOR_ROLE` on an executor is the key that submits signed intents; `ctx.operator` in a movement's context is whoever called the token, such as the holder, a spender, the agent, the minter or an executor; and `setOperator` on the 7540 vault approves a full delegate of a controller. `EXECUTOR_ROLE` on a timelock runs its operations, and on an `IntentToken` it runs signed intents.

<a id="guardian"></a>
## The guardian: stop-only

Every power the guardian has is a way to stop something or reduce it, and all of them work with no delay.

| Call | On | What it stops | Undone by |
|---|---|---|---|
| `pause()` | Each product | Every balance movement except FORCED ones. Each product has its own pause. | `unpause()`: main or recovery timelock |
| `pause()` | `IntentExecutor`, `DvPExecutor`, `OrderSettlement` | The operator's submissions through that executor. | `unpause()`: main or recovery timelock |
| `cancel(id)` | Main timelock | Any operation not yet executed, including one whose delay has passed. Holds `CANCELLER_ROLE`. | Governance schedules it again, or removes the right through [recovery](#recovery) |
| `blockSubject(subject)` | `CredentialRegistry` | An address, under `CredentialRule`. It cannot send or receive. Only an enforcement move can take tokens out of it, a forced transfer or the burner's burn, and nothing can deliver tokens to it, not even a forced transfer. | `clearGuardianBlock`: main or recovery timelock |
| `killAttester(id)` | `CredentialRegistry` | An attester. Every credential it wrote reads as exit-only: the holder can leave but not receive. | `reviveAttester`: main or recovery timelock |
| `cancel()` | `NavDesk` | A price proposal not yet executed. | The reporter proposes again |
| `setCaps` | `Portfolio` | How much may go to a risk: it may lower either cap and raise neither. | Main timelock raises it |
| `deallocate` | `Portfolio` | A position: it brings money back from an installed adapter to the portfolio, and nowhere else. It works while the vault is paused. | The allocator allocates again |
| `revokePermission` | `GuardedAccount` | A call the account could make. | Main timelock, by `setPermission` |
| `setMaxRate` | `Gated4626Vault` | How fast the counted value may rise: it may keep or lower the rate, to zero if it chooses. | Main timelock raises it |

It cannot schedule or execute timelock operations, unpause, change a hook or a rule list, grant roles or upgrade. On the credential registry it cannot unblock, revive, add an attester or write a credential. It holds nothing on the recovery timelock, the policy registry, a fund or `ProxyDeployer`. A stolen guardian key can therefore halt the system and shut accounts out. It cannot take assets, mint shares or admit anyone. Stopping still costs something: a halt can last until a timelock acts, and a rate of zero or money brought back keeps a fund from counting or earning a gain until someone reverses it.

<a id="recovery"></a>
## The two timelocks and the recovery path

Both timelocks are [`GovernanceTimelock`](contracts/GovernanceTimelock.md). The main one is where every change goes. Its `cancel` does not look at what an operation does, so the guardian could cancel a scheduled `unpause`, or its own removal, again and again. The recovery timelock is the way around it. Governance proposes and executes there, it has the same delay by default and the same floor, and nobody holds `CANCELLER_ROLE` on it, so what it schedules runs.

> **Diagram.** The recovery path. 1: the guardian pauses a product at once. 2: governance schedules unpause on the main timelock. 3: the guardian cancels it. 4: governance schedules a batch on the recovery timelock. The batch waits at least the delay and nobody can cancel it. 5: governance executes the batch. 6: the recovery timelock unpauses the products and executors and revokes the guardian's GUARDIAN_ROLE. 7: it revokes the guardian's CANCELLER_ROLE on the main timelock.
>
> **A guardian that vetoes can be removed, and the pause lifted, after one delay.** The batch in step 4 can unpause every product and the executors, revoke `GUARDIAN_ROLE` on each of them and on the credential registry, revoke the guardian's `CANCELLER_ROLE` on the main timelock, and clear guardian blocks or revive attesters in the credential registry. `governance.test.ts` runs such a batch on the products, the executors and the main timelock. `credentials.test.ts` runs `clearGuardianBlock` and `reviveAttester` through the recovery timelock, each in its own batch.

`RECOVERY_ROLE` allows those calls and nothing else. It is deliberately not a role admin, because a role admin could also grant. Instead the products and the executors accept it in `unpause()` next to `DEFAULT_ADMIN_ROLE`; their `revokeRole` override, and the credential registry's, let it revoke `GUARDIAN_ROLE`; the main timelock's lets it revoke `CANCELLER_ROLE`; and the credential registry also accepts it in `clearGuardianBlock` and `reviveAttester`. A test schedules forbidden calls through it, such as granting a role, revoking `AGENT_ROLE`, swapping a hook, upgrading or proposing on the main timelock, and each one fails with `AccessControlUnauthorizedAccount`. It holds nothing on the policy registry, and a fund or `ProxyDeployer` does not know it.

Each `unpause` in a recovery batch must target a contract that is paused when the batch runs, or `ExpectedPause` reverts the whole batch. Until the batch runs, the guardian keeps all its powers. The recovery path bounds the guardian, not governance: a compromised governance multisig proposes on both timelocks and is out of scope for this control.

<a id="delay"></a>
## The delay

A timelock operation can run no sooner than the delay it was scheduled with, and that delay must be at least the timelock's `getMinDelay()` (`TimelockInsufficientDelay`). The proposer may choose a longer one, and a later change of the minimum does not move operations already scheduled. `Core` gives both timelocks the same `minDelay` parameter, 24 hours by default. Both refuse less than 1 hour, at deployment and in `updateDelay` (`GovernanceTimelock_DelayBelowFloor`). The 24 hours is not a contract rule: the post-deploy check asserts `getMinDelay()` is at least that on both when it runs. Changing a delay is itself one of that timelock's operations, because `updateDelay` accepts only the timelock as caller.

| Waits for a timelock | Takes effect at once |
|---|---|
| Unpause. Replacing a hook (`installPolicy`) or a rule list (`setRules`). Rule settings: credential policy, settlement window, minimum position and exemptions, supply cap. A fund's rule, cap, exemptions and later classes. Upgrades. Every role grant and revocation. Attester list changes in the credential registry. Adding, removing or writing off an adapter, raising a cap, granting a permission, plugging in a portfolio or a fee model, raising a 4626's rate, a desk's settings and its replacement. | Guardian: every power [above](#guardian). Council: attest, revoke. KYC attester: credentials. Operations account: placing a product. Agent: forced transfers, frozen amounts, lockups, address freezes, 7540 recoveries. Minter, burner and operator: their daily work. Allocator: moving money under caps on the allocation and through validators. Distribution maker and checker: proposing and approving. Holders: their own movements. |

A desk has its own wait, which is no timelock: a price runs only after a `cooldown` of 1 hour to 3 days from its proposal, in which the guardian or a checker can cancel it.

<a id="pause"></a>
## During a pause

A product's pause is one check at the start of every balance movement, before the frozen-balance check and before the hook. It lets one kind through: an enforcement move, by the agent, by the burner with `burn` or, for `recoverRedeemRequest` once the request's period has closed, by `SETTLER_ROLE`. Calls that move no balance are not affected unless they check the pause themselves.

> **Diagram.** While a product is paused, a movement of kind TRANSFER, EXECUTED, MINT or BURN is rejected with ERC8473PolicyRejected(PAUSED). A FORCED movement continues to the frozen-balance check and the hook.
>
> **Only an enforcement move gets past a pause.** `forcedTransfer`, and the 7540 vault's two recoveries, which announce the FORCED kind, still run the rules, so the receiver must still hold a credential and must not be address-frozen. The burner's `burn` announces FORCED too, and has no receiver to judge.

| Where | Entry point | While paused |
|---|---|---|
| Every product | `transfer`, `transferFrom` | reverts `ERC8473PolicyRejected(PAUSED)` |
|  | `forcedTransfer` | works |
|  | `setFrozenTokens`, `approve`, and `permit` where the template has it | works: no balance moves |
|  | `canTransfer`, `canTransferWithReason`, `canSend`, `canReceive` | `false`; `canTransferWithReason` gives the reason `PAUSED`. `canSend` and `canReceive` stay `true` for the zero address |
|  | `installPolicy`, `upgradeToAndCall`, `grantRole`, `revokeRole` | works, for their role holders |
|  | `unpause` | main or recovery timelock only; on a product that is not paused it reverts `ExpectedPause` |
| `Gated721` | `mint`, `safeTransferFrom` | reverts `ERC8473PolicyRejected(PAUSED)` |
|  | `burn` | works: FORCED |
|  | `setTokenURI`, `setApprovalForAll` | works: nothing moves |
| `Gated1155` | `mint`, `safeTransferFrom`, `safeBatchTransferFrom` with at least one item | reverts `ERC8473PolicyRejected(PAUSED)` |
|  | `burn` | works: FORCED |
|  | `setURI`, `setApprovalForAll` | works: nothing moves |
| `GatedToken`, `IntentToken` | `mint` | reverts `ERC8473PolicyRejected(PAUSED)` |
|  | `burn` | works: FORCED |
|  | `executeTransfer`, on `IntentToken` | an intent that passes its own checks reverts `ERC8473PolicyRejected(PAUSED)`; `canExecute` says `PAUSED` |
|  | `cancelIntent`, on `IntentToken` | works |
| `Gated4626Vault` | `deposit`, `mint` | a non-zero amount reverts `ERC4626ExceededMaxDeposit` or `ERC4626ExceededMaxMint`, because `maxDeposit` and `maxMint` return 0 |
|  | `withdraw`, `redeem` | a non-zero amount reverts `ERC4626ExceededMaxWithdraw` or `ERC4626ExceededMaxRedeem` |
|  | the same four with 0 | reverts `ERC8473PolicyRejected(PAUSED)` |
|  | `collectFees` | reverts `EnforcedPause()` |
|  | `accrue`, `setPortfolio`, `setFeeModel`, `setMaxRate` | works: none checks the pause |
| `Gated7540Vault` | `requestDeposit` | reverts `Gated7540Vault_ControllerNotEligible(PAUSED)` |
|  | `requestRedeem` | reverts `ERC8473PolicyRejected(PAUSED)` |
|  | `closePeriod` | works: a period can close during a pause |
|  | `settlePeriod` | reverts `EnforcedPause()` |
|  | `rejectDepositRequest` | works: it moves the asset only, no shares |
|  | `rejectRedeemRequest` | reverts `ERC8473PolicyRejected(PAUSED)`; the shares stay in escrow |
|  | `recoverRedeemRequest`, `recoverClaimable` | works: FORCED |
|  | `deposit`, `mint` (claims) | reverts `Gated7540Vault_ControllerNotEligible(PAUSED)` |
|  | `redeem`, `withdraw` (claims) | reverts `EnforcedPause()` |
|  | `setOperator` | works |
| `NavDesk`, its vault paused | `closePeriod`, `propose`, `accept`, `cancel` | works: none checks the pause |
|  | `execute` | reverts `EnforcedPause()`, from the vault; the proposal stays on the table |
|  | `refundRequest`, `recoverRequest` | works for a deposit's refund and a recovery; a redemption's refund reverts `ERC8473PolicyRejected(PAUSED)` |
| `Portfolio`, `GuardedAccount`, the vault paused | `Portfolio.allocate` | reverts `Portfolio_VaultPaused` |
|  | `GuardedAccount.execute` | reverts `GuardedAccount_VaultPaused`. So a permission that pulls money back through `execute` waits for the unpause. |
|  | `Portfolio.deallocate`, `setCaps`, and the admin's calls | works: a pause stops `allocate` and `GuardedAccount.execute`. Money still comes back by `deallocate`, and still leaves the portfolio by `migrateTo`. |
| `Distributor`, its token paused | `claim` | reverts `Distributor_HolderMayNotReceive`, because `canReceive` is false |
|  | `propose`, `approve`, `sweep` | works: none checks the pause |
| `SignedEntry`, the vault paused | `enterWithPermit`, `enterWith3009` | reverts with the vault's error for a deposit or a request |
| `SignedExit`, the vault paused | `exitWithPermit` | reverts with the vault's error for a redemption or a request |
|  | `claimFor` | does not revert and delivers nothing: the vault refuses each claim, which is skipped with `ClaimSkipped` and stays with the vault |
| An executor paused | `IntentExecutor.execute`, `executeBatch` | reverts `EnforcedPause()` |
|  | `DvPExecutor.executeDvPGated`, `executeDvP3009` | reverts `EnforcedPause()`; the two pre-flights answer `PAUSED` |
|  | `OrderSettlement.settle` | reverts `EnforcedPause()`; `canFill` does not check the pause |
|  | `OrderSettlement.cancelOrder` | works |
| A token paused, its executor not | `IntentExecutor.execute`, `executeBatch` | `execute` passes the token's `ERC8473PolicyRejected(PAUSED)` through unchanged; `executeBatch` wraps it in `IntentExecutor_BatchItemFailed(index, reason)` |
|  | `DvPExecutor` trades | reverts `DvPExecutor_LegFailed(leg, reason)`, with the token's revert data as `reason` |
|  | `OrderSettlement` fills | reverts `OrderSettlement_TransferFailed(index, secondLeg, reason)`, with the token's revert data as `reason` |

The registries, the hook, the rules, the funds and `ProxyDeployer` have no pause, so a product can launch and its settings can change while another is paused. In the credential registry the guardian's equivalent is blocking an address or killing an attester. [The incident runbook](deployment.md#incident) puts the pause, the agent's enforcement and the resume in order.

<a id="why"></a>
## Why it is built this way

- **Stopping is fast, starting is slow.** The guardian can only stop or reduce, so the one account that acts at once across everything cannot move value out or loosen policy. Undoing a pause, a block, a killed attester, a lowered cap or rate or a revoked permission waits for a timelock and is public while it waits. A cancelled price is proposed again by the reporter, and money brought back is allocated again by the allocator.
- **A second timelock bounds the first one's cancellers.** Cancelling on the main timelock is blind to what is cancelled, so the guardian could block its own removal. The recovery timelock has no cancellers and only the narrow powers to undo a guardian, so governance keeps a path the guardian cannot block.
- **Rules, the hook and the legos have no roles of their own.** They ask the token or vault at call time who holds a role. One shared rule instance can serve every token, and moving a token's admin role moves who configures its policy, with nothing else to update. The post-deploy check asserts that no rule exposes `hasRole` or `owner`.
- **Launching needs no timelock, changing does.** The operations account can place a product at once because that touches nothing that exists. It holds nothing on a product once its launch ends.
- **Only the timelock upgrades.** `UPGRADER_ROLE` goes to the main timelock alone, and an upgrade must target reviewed code of the same template.
- **Executors are contracts, not keys.** `EXECUTOR_ROLE` on an `IntentToken` goes to executor contracts, so a signed intent runs through code that the guardian can pause and that checks what it submits.
- **Two people on a price or a distribution.** `NavDesk` and `Distributor` each refuse an approval from the account that proposed, because the vault or token takes what they send.
- **No expiring pause.** Nothing in the code ends a pause by time. Only a timelock lifts it, so a security control does not turn into a timer.

<a id="limits"></a>
## What the roles do not guarantee

- **Nothing on chain makes an account a multisig.** Governance, the guardian, the council and the operations account are addresses given to the modules. The post-deploy check asks for a threshold on four roles only, on the accounts it is told about.
- **There is no list of holders on chain.** The contracts do not enumerate a role's holders, so a complete list comes from `RoleGranted` and `RoleRevoked` events, and the check sees only the accounts it is given.
- **The agent's power is large and immediate.** A stolen agent key can force any holder's tokens to an account the policy accepts, and set frozen amounts, lockups and freezes, with no delay, until the timelock revokes the role. On a 7540 it can also pay a controller's claimable redemption cash, and deliver its claimable shares, to any account the policy accepts (`recoverClaimable`). The guardian's pause does not stop a forced move or this.
- **The burner's power is not stopped by a pause.** A stolen burner key can destroy any holder's balance on a token, any item on a `Gated721` or any amount of any token id on a `Gated1155`, with no delay. `burn` is a FORCED move, so the guardian's pause does not stop it, and neither does a lockup, an address freeze or a frozen amount. The remedy is for the timelock to revoke `BURNER_ROLE`.
- **The minter's power is bounded only by the rules.** A stolen minter key can mint to any eligible account. `SupplyCapRule` limits that where a product lists it, and no shipped profile does.
- **Who holds `SETTLER_ROLE` sets the price and the redemption limit.** The vault takes whatever `settlePeriod` is given and does not check the holder. The role belongs with a desk, and the timelock can grant it to anyone: that is delayed and visible, not prevented.
- **An attester decides who may hold.** A stolen attester key can credential any address that no other live attester has a record for, with any bit it may assert, for every token whose policy trusts it, until the guardian kills it. It also says which addresses are one investor: giving an address the entity of an investor a fund already counts admits that address at a full fund without the count rising.
- **The council attests with no delay.** It takes the timelock to install attested code on an existing product, but the operations account can launch a product over any implementation the council has attested, so a launch has only those two checks.
- **A stolen operations key cannot be locked out by the timelock.** `ProxyDeployer` answers to its owner alone. [What that means for later products](deployment.md#limits).

<a id="connected"></a>
## Connected to

- [GovernanceTimelock](contracts/GovernanceTimelock.md): Both timelocks: a one-hour floor on the delay, and one recovery power.
- [PolicyGatedCoreUpgradeable](contracts/PolicyGatedCoreUpgradeable.md): The core every template shares, which defines the token roles, the pause and `unpause`.
- [CredentialRegistry](contracts/CredentialRegistry.md): Attesters, the guardian's block and kill, and the recovery calls.
- [IntentExecutor](contracts/IntentExecutor.md): The operator's route to `executeTransfer`, with its own pause.
- [NavDesk](contracts/NavDesk.md): Where the reporter, the checker and the guardian meet over a price.
- [Portfolio](contracts/Portfolio.md): Where the allocator moves money and the guardian can bring it back.
- [Deployment and governance](deployment.md): How the roles are handed over and how policy changes later.

<a id="source"></a>
## Source and tests

- Role grants: `Core.ts`, `CoreHandover.ts`, `PartsHandover.ts` and `handOverParts` in `ignition/parts.ts`, `Product.ts`, `FundOpen.ts`; role ids in `roles.ts`; exceptions in `profiles.ts`
- Hand-over check: `handoverFailures` in `scripts/lib/check.ts`, run by `npm run check` and by the fixture's `assertHandedOver`
- Role gates in code: `PolicyGatedCoreUpgradeable.sol`, `PolicyGatedERC20Upgradeable.sol`, `IntentSettledUpgradeable.sol`, `Gated721.sol`, `Gated1155.sol`, `Gated4626Vault.sol`, `Gated4626Management.sol`, `Gated7540Vault.sol`, `Gated7540Settlement.sol`, `PolicyRegistry.sol`, `GovernanceTimelock.sol`, `CredentialRegistry.sol`, `IntentExecutor.sol`, `DvPExecutor.sol`, `OrderSettlement.sol`, `Portfolio.sol`, `GuardedAccount.sol`, `NavDesk.sol`, `Distributor.sol`, `ComplianceHook.sol`, and the rules' setters, which ask the token's roles
- Tests: `test/nodejs/governance.test.ts` (the delay, the guardian's veto and the recovery batch), `test/nodejs/legos.test.ts` (what the hand-over check refuses), `GovernanceTimelock.t.sol`, and behaviour while paused in `Gated7540Vault.t.sol`, `Gated4626Vault.t.sol`, `NavDesk.t.sol`, `Portfolio.t.sol` and `GuardedAccount.t.sol`
