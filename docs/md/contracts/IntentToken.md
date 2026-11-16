[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Token

# IntentToken

The gated token with signed transfers: an ERC-20 whose movements pass the policy hook, and whose holders can also sign a transfer for an approved executor to settle. It adds almost nothing of its own: a setup function, its decimals and the name of its template.

- **contracts/tokens/IntentToken.sol**
- upgradeable: **UUPS**, behind a **TokenProxy**
- admin: **the main timelock**, after hand-over
- implementation attested as **IMPLEMENTATION**

<a id="in-one-minute"></a>

> ### In one minute
>
> This is the template for a permissioned token whose transfers the issuer can settle: a holder signs, an approved executor submits, and the rules decide. Of the stack's templates it is the one that can be a leg of a delivery-versus-payment trade. Everything it does comes from two shared pieces: [the base](PolicyGatedERC20Upgradeable.md), which keeps balances and roles, gives the issuer its enforcement tools and asks the policy hook about each movement, and [the intent mixin](IntentSettledUpgradeable.md), which adds signed transfers.
>
> A holder can also use a plain `transfer`, unless the product lists `ExecutedOnlyRule`. If a product needs none of this, [`GatedToken`](GatedToken.md) is the same base without the mixin.

<a id="how"></a>
## What the token is made of

The token's address is a **proxy**: a small contract that holds all the state (balances, roles, frozen amounts, used intent nonces) and runs the shared implementation code for every call. That code is three layers on top of OpenZeppelin. Each movement, whatever its kind, asks the one shared **hook**, which runs this token's rules in order and stops at the first refusal.

> **Diagram.** The token's structure. A TokenProxy at the token's address holds the state and delegates every call to the IntentToken implementation, which the council attested. The implementation has four layers: IntentToken with initialize, decimals and templateId; IntentSettledUpgradeable with executeTransfer, canExecute and cancelIntent; PolicyGatedERC20Upgradeable over the shared PolicyGatedCoreUpgradeable, with \_move, mint, burn, forcedTransfer and pause; and the OpenZeppelin parents. The base layer calls the shared ComplianceHook with checkTransfer and gets a reason code back. In the demo stack the hook runs five rules for this token, in order: CredentialRule, MinPositionRule, HolderRestrictionRule, SettlementWindowRule and FundHoldersRule.
>
> **One proxy, three layers of code, one rule list.** The proxy is the token; the implementation is shared code behind it. The hook is shared by every token of the deployment and keeps a separate ordered list for each. The list shown is the demo stack's; each product states its own. After the balances move, the base also calls the hook's `afterTransfer`, which runs the rules that want it.

1. **[`TokenProxy`](TokenProxy.md)** is the proxy. Its address follows from `ProxyDeployer`'s address, the symbol and the implementation, so it is known before the token exists. Changing the code behind it is a governance upgrade.
2. **`IntentToken`** itself adds `initialize`, `decimals` and `templateId`, and a constructor that locks the implementation so that only proxies can be set up. The decimals are fixed at setup, in the token's own ERC-7201 namespace (`gated.storage.IntentToken`), and an upgrade keeps them (`test_AnUpgradeKeepsTheDecimals`). For a cash token they are the precision of its ledger; the `Product` deployment module uses 18 when a product states none.
3. **[`IntentSettledUpgradeable`](IntentSettledUpgradeable.md)** adds signed intents, settled by an executor as EXECUTED.
4. **[`PolicyGatedERC20Upgradeable`](PolicyGatedERC20Upgradeable.md)** adds everything else: ERC-20, roles, mint, burn, forced transfer, frozen amounts, pause, permit, multicall, upgrades, and the one movement path that asks the hook.

<a id="rules"></a>
## Its rules

Each product states its rule list, and the token hands the list to the hook when it is set up, as the data of the hook's installation. The table shows the list the demo stack uses (`RULE_ORDER` in `ignition/modules/roles.ts`, the `full` profile). The credential check comes first, and the minimum position right after it, so that when a minimum is set the rules that follow judge real positions rather than dust. The fund's cap comes last. A product can list fewer, and can add [`SupplyCapRule`](SupplyCapRule.md) or [`ExecutedOnlyRule`](ExecutedOnlyRule.md).

| # | Rule | What it checks on this token | How a product sets it up |
|---|---|---|---|
| 1 | [`CredentialRule`](CredentialRule.md) | The receiver holds an active credential that this token's policy accepts (not asked on the burner's burn, which has no receiver). The sender must be known to the credential registry and not blocked, except on a mint or a forced movement, which the burner's burn is. | `setPolicy(token, requireAll, requireAny, forbidAny, attesters)`. Unless the product states a policy: the KYC qualification from attester 0. |
| 2 | [`MinPositionRule`](MinPositionRule.md) | A movement may not leave the sender or the receiver holding more than zero and less than the token's minimum position. Forced movements, which the burner's burn is, and accounts the token's admin lists are exempt. | `setMinPosition(token, minPosition)`, 0 unless a parameter says otherwise, which switches the rule off. |
| 3 | [`HolderRestrictionRule`](HolderRestrictionRule.md) | Per-holder lockups and address freezes. | Nothing at launch. The agent sets them holder by holder (`setLockup`, `setFrozen`). |
| 4 | [`SettlementWindowRule`](SettlementWindowRule.md) | An executed intent passes inside a daily UTC window, on enabled weekdays. Other kinds are not judged. | `setWindow(token, windowOpen, windowClose, windowDays)` from the deployment parameters. |
| 5 | [`FundHoldersRule`](FundHoldersRule.md) | The cap on distinct investors across the classes of a [`Fund`](Fund.md). | The fund registers the token as a class (`registerClass`), in `FundOpen` or a later timelock operation. |

Until the credential policy is set, the credential rule refuses every receiver except the token's own address. Until a fund registers the token, the fund rule refuses every movement with `NOT_FUND_CLASS`. `Product` grants the minter's role after the configuration, so the settings are in place before anyone can mint.

<a id="deployment"></a>
## Who places it

The `Core` module deploys one `IntentToken` implementation for the issuer, and the security council attests it. Each product is then one run of the `Product` module by the operations account, which owns `ProxyDeployer`, so a launch has no timelock wait.

1. **Place.** `ProxyDeployer.deploy(symbol, implementation, initData, hook, expectedRules)`, where `initData` is the `initialize` call with the operations account as admin. `ProxyDeployer` refuses an implementation the council has not attested, and reverts unless the token names its registry, uses the given hook, the hook holds exactly those rules in that order, and the symbol matches. See [`ProxyDeployer`](ProxyDeployer.md).
2. **Configure.** While the operations account is the token's admin, it sets the policy, the minimum, the supply cap and the window, each if the product lists that rule.
3. **Grant roles.** See the table below. `EXECUTOR_ROLE` goes to the executors the product names, and to no one else in the module.
4. **Hand over.** The main timelock receives `DEFAULT_ADMIN_ROLE` and the operations account renounces its own. From then on, a change to the rule list, a role change or an upgrade is a timelock operation.

Outside this module, the KYC attester has to issue a credential to each holder before anyone can receive the token. In the demo stack the token is called "Intent Token" with the symbol `INT`. See [Deployment and governance](../deployment.md).

<a id="roles"></a>
## Who holds what after hand-over

| Role | Holder | Used for |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Main timelock | Every role grant, the hook, the rule list and the rules' policy settings, unpausing |
| `GUARDIAN_ROLE` | Guardian multisig, from `initialize` | Pausing, with no delay |
| `RECOVERY_ROLE` | Recovery timelock | Exactly unpausing and revoking `GUARDIAN_ROLE` |
| `UPGRADER_ROLE` | Main timelock | Upgrades to attested code of this template |
| `MINTER_ROLE` | The minter account | `mint` |
| `BURNER_ROLE` | The burner account | `burn`, a forced movement, which may take frozen tokens |
| `AGENT_ROLE` | The agent account | Forced transfers, frozen amounts, holder lockups and freezes |
| `EXECUTOR_ROLE` | The executors the product names: `IntentExecutor`, `DvPExecutor` or both | Settling signed intents |

The post-deploy check, off-chain, confirms the named executors hold `EXECUTOR_ROLE` and that none of the deployment's wallets does, so that a signed intent is submitted through one of them. It does not ask about an executor the product does not name.

<a id="choosing"></a>
## When a product chooses it

- The issuer's settlement system runs transfers, and a holder authorises each with a signature and pays no gas.
- Transfers must carry an off-chain reference (`ref`), or run in settlement hours. `SettlementWindowRule` judges EXECUTED movements, so it has nothing to judge on another template.
- Every movement between holders has to be a signed intent: list `ExecutedOnlyRule` and name an executor, as the "Signed Note" in `test/nodejs/legos.test.ts` does.
- The token has to settle against cash through the [`DvPExecutor`](DvPExecutor.md). It calls `executeTransfer` on each gated leg, and `IntentToken` is the template that has that function.

The cost is more to run and review: `EXECUTOR_ROLE`, the executor contracts and their operator key, and the mixin's code. A product with none of the needs above should use [`GatedToken`](GatedToken.md#choosing), where the comparison is set out side by side. The choice is made at launch: an upgrade must keep the template.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `constructor()` | Runs once, when the implementation is deployed | Disables the initialiser on the implementation itself, so only a proxy can be set up. |
| `initialize(name, symbol, decimals, admin, guardian, registry, hook, _initialRules)` | Once per proxy; `ProxyDeployer` runs it in the transaction that creates the proxy | Sets the name (also the EIP-712 domain name), symbol and decimals, grants `DEFAULT_ADMIN_ROLE` to `admin` and `GUARDIAN_ROLE` to `guardian`, fixes the registry, installs the hook after checking it, and passes it `abi.encode(_initialRules)` as the installation's data, which the hook installs as this token's rule list. An empty list sends empty data and installs none, and the hook then refuses every movement (`test_WhenTheHookIsDeployedWithoutRules_EveryMovementIsRejected`). Reverts with `PolicyGated_ZeroAddress`, `PolicyGated_NotAttested`, `PolicyGated_HookRegistryMismatch`, `PolicyGated_NotAPolicy`, the hook's own refusals of a rule list (`ComplianceHook_NotAttested`, `ComplianceHook_TooManyRules`, `ComplianceHook_DuplicateRule`), or `InvalidInitialization` on a second call. |
| `decimals()` | Anyone (read-only) | The decimals given at setup. |
| `templateId()` | Anyone (read-only) | Returns `keccak256('IntentToken')`. An upgrade must target code that reports the same id. |
| Everything else | From [the base](PolicyGatedERC20Upgradeable.md#functions) (transfers, mint, burn, forced transfer, frozen amounts, pause, pre-flights, hook, multicall, roles, upgrades, and their events and errors) and [the mixin](IntentSettledUpgradeable.md#functions) (signed intents). |  |

The token takes no ether. Its one payable function is `upgradeToAndCall`, and that reverts when value is sent (`test_WhenTheUpgraderAttachesEther_TheUpgradeReverts`).

<a id="why"></a>
## Why it is built this way

- **A template is a name and a setup function.** The behaviour lives in the shared base and the mixin, so each template behaves the same where they overlap, and a fix in the base reaches each template through its own attested upgrade.
- **The template id keeps a token on its own code.** An attestation says the code has been reviewed; `templateId()` says what it is for. An upgrade of this token to an attested vault implementation is refused with `Templated_WrongTemplate` (`test_WhenUpgradedToAVaultImplementationThatIsAttested_ItIsRefused`).
- **Live with its policy from the start.** The rules are installed by `initialize` in the transaction that creates the proxy, and `ProxyDeployer` checks the result in that same transaction (`test_WhenDeployed_ThePolicyIsAlreadyInstalled`), so no call finds the token without its rules.
- **Each implementation deployment needs its own attestation.** UUPS code records its own address, so two deployments of the same source have different code hashes, and the council attests each one it allows (`test_WhenAnImplementationIsRedeployed_ItNeedsItsOwnAttestation`).

<a id="limits"></a>
## What it does not do

- **A window does not bind a plain transfer.** `SettlementWindowRule` judges EXECUTED movements only. On a token that lists it without `ExecutedOnlyRule`, as the demo stack's list does, a holder who passes the other rules can use `transfer` outside the window.
- **Signed-only needs a working executor.** With `ExecutedOnlyRule` listed, holders can move only through an account that holds `EXECUTOR_ROLE`. If none does, or the executor is paused, movement between holders stops; mints, burns and forced moves still pass that rule.
- **It cannot change template or decimals.** The upgrade check refuses other templates, and no function sets the decimals after setup.
- **It adds no policy.** With no rules installed the hook refuses every movement. Everything else the base and the mixin leave out applies here too: see [the base's limits](PolicyGatedERC20Upgradeable.md#limits) and [the mixin's limits](IntentSettledUpgradeable.md#limits).

<a id="connected"></a>
## Connected to

- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): The base: balances, roles, enforcement and the movement path.
- [IntentSettledUpgradeable](IntentSettledUpgradeable.md): The mixin for signed intents.
- [GatedToken](GatedToken.md): The same base without signed transfers.
- [IntentExecutor](IntentExecutor.md): Submits signed intents that state no payment.
- [DvPExecutor](DvPExecutor.md): Settles a share trade against its cash in one transaction.
- [ProxyDeployer](ProxyDeployer.md): Places the token and checks it came up as expected.
- [TokenProxy](TokenProxy.md): The proxy at the token's address.
- [ComplianceHook](ComplianceHook.md): Runs the token's rules on every movement.
- [Deployment and governance](../deployment.md): How a product is placed, configured and handed over.

<a id="source"></a>
## Source and tests

- Contract: `contracts/tokens/IntentToken.sol`, interface `ITemplated.sol`
- Deployment: `ignition/modules/roles.ts` (`TOKENS`, `RULE_ORDER`), `ignition/profiles.ts`, `ignition/modules/Core.ts`, `ignition/modules/Product.ts`
- Tests: `IntentToken.t.sol` (the token with a real registry, hook and `ProxyDeployer` and a mock identity rule: the policy installed at deploy, decimals, enforcement, intents, reentrancy, upgrades refused across templates, no ether), `test/nodejs/deployment.test.ts` (the full deployment: each token's rule list in order, the minimum off) and `test/nodejs/legos.test.ts` (a token that moves by signed intent alone)

---

Describes the contracts at commit `0f8b72f` on `erc8473-main`.
