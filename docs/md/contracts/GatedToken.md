[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Token

# GatedToken

The plain gated token: the shared base with its own decimals, and no signed transfers. Holders move it with ordinary ERC-20 calls, and each movement still has to pass the policy hook.

- **contracts/tokens/GatedToken.sol**
- upgradeable: **UUPS**, behind a **TokenProxy**
- admin: **the main timelock**, after hand-over
- implementation attested as **IMPLEMENTATION**

<a id="in-one-minute"></a>

> ### In one minute
>
> This is the simplest token in the stack. Everything it does comes from [`PolicyGatedERC20Upgradeable`](PolicyGatedERC20Upgradeable.md) and the core it extends: balances, roles, mint, burn, forced transfer, frozen amounts, pause, and one movement path that asks the policy hook about each movement. The contract itself adds a setup function, its decimals and the name of its template.
>
> It suits a product whose holders send their own transactions: a bond or a note, a fund share class, or a cash token that a vault takes as its asset. Compared with [`IntentToken`](IntentToken.md) it has no signed intents, no executor role and nothing extra to operate. What it gives up is settlement by the issuer: signed transfers, settlement hours and delivery versus payment.

<a id="how"></a>
## What the token is made of

The token's address is a **proxy**, which holds all the state and runs shared implementation code for every call. That code is the base plus this small contract.

1. **[`TokenProxy`](TokenProxy.md)** is the proxy. [`ProxyDeployer`](ProxyDeployer.md) places it at an address that follows from the deployer, the symbol and the implementation, and sets it up in the same transaction.
2. **`initialize`** takes the name and symbol, the decimals, the admin, the guardian, the registry, the hook and the initial rule list. It sets up OpenZeppelin's ERC-20 and `permit`, then the [shared core](PolicyGatedCoreUpgradeable.md#setup), which grants the admin and guardian roles, fixes the registry, checks and installs the hook, and passes it the rule list as the installation's data, so the hook installs the rules for this token in its `onInstall`.
3. **`decimals()`** returns the value given at setup, kept in the token's own ERC-7201 namespace (`gated.storage.GatedToken`). No function changes it. For a cash token it is the precision of its ledger. Any `uint8` is accepted (`testFuzz_ItReportsTheDecimalsItWasGiven`), and the `Product` deployment module uses 18 when a product states none.
4. **`templateId()`** returns `keccak256('GatedToken')`. An upgrade must target attested code that reports the same id, so a `GatedToken` cannot be moved onto another template's code (`test_WhenUpgradedToAnotherTemplate_ItReverts`).

On chain it is placed like any product: the operations account calls `ProxyDeployer`, configures the rules the product lists, grants `AGENT_ROLE`, `MINTER_ROLE` and `BURNER_ROLE` to their accounts, `UPGRADER_ROLE` to the main timelock and `RECOVERY_ROLE` to the recovery timelock, hands `DEFAULT_ADMIN_ROLE` to the main timelock, and renounces its own. The `token` profile in `ignition/profiles.ts` lists [`CredentialRule`](CredentialRule.md) and [`HolderRestrictionRule`](HolderRestrictionRule.md); a product can list others. See [Deployment and governance](../deployment.md).

<a id="choosing"></a>
## GatedToken or IntentToken

The two templates share the base, and take the same arguments in `initialize`. The enforcement tools, the pre-flights, `permit`, `multicall` and the upgrade check are the same in both. The difference is one mixin, [`IntentSettledUpgradeable`](IntentSettledUpgradeable.md), and what follows from it.

|  | `GatedToken` | `IntentToken` |
|---|---|---|
| How a holder moves tokens | Sends `transfer`, or lets a spender use `transferFrom` after `approve` or a signed `permit` | The same, or signs an intent that an executor submits, so the holder pays no gas |
| Movement kinds | TRANSFER MINT FORCED. The burner's `burn` is FORCED, and a holder has no burn, so nothing moves as BURN | Those, and EXECUTED |
| Signed-intent functions and `ITransferIntent` | None (`test_ItOffersTheStandardsAndNoSignedIntents`) | `executeTransfer`, `canExecute`, `cancelIntent` and the rest |
| Off-chain reference on a transfer | None | `ref`, signed by the holder, in the event and the context |
| Settlement hours (`SettlementWindowRule`) | The rule judges EXECUTED only, so it would judge nothing here. `Product` refuses to list it. | Can list it. It binds signed intents, not a plain `transfer`. |
| Signed-only movement (`ExecutedOnlyRule`) | It would refuse every plain transfer with no other route left. `Product` refuses to list it. | Can list it. |
| A leg of a [`DvPExecutor`](DvPExecutor.md) trade | No: the executor calls `executeTransfer` on each gated leg | Yes: either leg of `executeDvPGated`, the security leg of `executeDvP3009` |
| Extra to run and review | Nothing | `EXECUTOR_ROLE`, the executor contracts it names, their operator key, and the mixin's code |
| `templateId()` | `keccak256('GatedToken')` | `keccak256('IntentToken')` |

### Choose GatedToken when

- Holders or their custodians send their own transactions and pay their own gas.
- The issuer does not need to control when a transfer settles, or to tie each transfer to an off-chain message.
- The token does not settle against another in one transaction through an executor.
- You want the smallest code and the fewest parties to review. The tests place it as a corporate bond, a note with a supply cap, the share classes of a fund, and a cash token behind a vault.

### Choose IntentToken when

- The issuer's settlement system runs transfers, and a holder authorises each with a signature.
- Transfers must carry an off-chain reference, or run in settlement hours.
- Every movement between holders has to be a signed intent (`ExecutedOnlyRule`).
- The token has to settle against cash in delivery versus payment, or be the gated cash in one.

**The choice is made at launch.** The upgrade check refuses the other template's code, so a `GatedToken` does not gain signed transfers by upgrading to `IntentToken`. A token that later needs them is a second product, and moving holders across is outside these contracts.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `constructor()` | Runs once, when the implementation is deployed | Disables the initialiser on the implementation itself, so only a proxy can be set up (`test_TheImplementationCannotBeInitialised`). |
| `initialize(name, symbol, decimals, admin, guardian, registry, hook, _initialRules)` | Once per proxy; `ProxyDeployer` runs it in the transaction that creates the proxy | Sets the name (also the EIP-712 domain name), symbol and decimals, grants `DEFAULT_ADMIN_ROLE` to `admin` and `GUARDIAN_ROLE` to `guardian`, fixes the registry, installs the hook after checking it, and passes it `abi.encode(_initialRules)` as the installation's data, which the hook installs as this token's rule list. An empty list sends empty data and installs none, and the hook then refuses every movement. Reverts with `PolicyGated_ZeroAddress`, `PolicyGated_NotAttested`, `PolicyGated_HookRegistryMismatch`, `PolicyGated_NotAPolicy`, the hook's own refusals of a rule list (`ComplianceHook_NotAttested`, `ComplianceHook_TooManyRules`, `ComplianceHook_DuplicateRule`), or `InvalidInitialization` on a second call. |
| `decimals()` | Anyone (read-only) | The decimals given at setup. |
| `templateId()` | Anyone (read-only) | Returns `keccak256('GatedToken')`. |
| Everything else | From [the base](PolicyGatedERC20Upgradeable.md#functions): transfers, mint, burn, forced transfer, frozen amounts, pause, pre-flights, hook, multicall, roles, upgrades, and its events and errors. |  |

The token takes no ether. It has no `receive` function and no payable function of its own, and `upgradeToAndCall` rejects value (`test_WhenEtherIsSent_ItReverts`, and the base's `ERC1967NonPayable`).

<a id="why"></a>
## Why it is built this way

- **A template is a name and a setup function.** The behaviour lives in the base, so `GatedToken`, `IntentToken` and the vaults behave alike where they overlap, and a fix in the base reaches each template through its own attested upgrade.
- **Decimals are per token, not per template.** A cash token has to match its ledger's precision, and one implementation serves every product of a template. So the value is set at setup and kept in the proxy's storage.
- **A separate template, not a switch.** Leaving out the intent code means there is no executor role to guard on a token that has no use for one, and no flag in the base to get wrong.
- **Live with its policy from the start.** The rules are installed by `initialize` in the transaction that creates the proxy, and `ProxyDeployer` checks the result in that same transaction (`test_WhenPlaced_ItIsLiveWithItsPolicy`).

<a id="limits"></a>
## What it does not do

- **No signed transfers.** A holder's `permit` signs an allowance, not a transfer. It names a spender, a value and a deadline, and the spender then chooses the receiver with `transferFrom`, which moves as a plain TRANSFER with no reference.
- **No control over when a transfer settles.** A holder who passes the rules can move whenever the token is not paused. The issuer's ways to stop movement are the pause, the rules and the enforcement tools.
- **The refusal of an unusable rule is off-chain.** `assertUsable` in `ignition/profiles.ts` stops a `GatedToken` product that lists `SettlementWindowRule` or `ExecutedOnlyRule`, when the module is built. On chain, `ComplianceHook.setRules` accepts any attested rule, so a timelock operation could still list one: the window rule would judge nothing, and `ExecutedOnlyRule` would refuse every plain transfer.
- **It adds no policy.** With no rules installed the hook refuses every movement. Everything else the base leaves out applies here too: see [the base's limits](PolicyGatedERC20Upgradeable.md#limits).

<a id="connected"></a>
## Connected to

- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): The base: balances, roles, enforcement and the movement path.
- [IntentToken](IntentToken.md): The same base with signed transfers.
- [ProxyDeployer](ProxyDeployer.md): Places the token and checks it came up as expected.
- [TokenProxy](TokenProxy.md): The proxy at the token's address.
- [ComplianceHook](ComplianceHook.md): Runs this token's rules on every movement.
- [Gated4626Vault](Gated4626Vault.md): A vault can take a gated cash token as its asset.
- [Deployment and governance](../deployment.md): How a product is placed, configured and handed over.

<a id="source"></a>
## Source and tests

- Contract: `contracts/tokens/GatedToken.sol`, interface `ITemplated.sol`
- Deployment: `ignition/profiles.ts` (`assertUsable`, the `token` profile), `ignition/modules/Product.ts`
- Tests: `GatedToken.t.sol` (the token with a real registry, hook and `ProxyDeployer` and a mock identity rule: setup, decimals, no intent entry point, enforcement, upgrades, no ether), `test/nodejs/products.test.ts` (the deployed `token` profile, a later product, a cash token behind a vault, fund classes), `test/nodejs/legos.test.ts` (a supply cap at launch, unusable rule lists)

---

Describes the contracts at commit `6ef0d4e` on `erc8473-conformance`.
