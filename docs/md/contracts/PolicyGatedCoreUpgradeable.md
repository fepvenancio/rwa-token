[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Token

# PolicyGatedCoreUpgradeable

The part of every template that does not depend on what the token counts. It holds the roles, the guardian and the recovery path, the pause, the hook pointer and the upgrade checks, so the fungible templates and the NFT run the same code for them.

- **contracts/base/PolicyGatedCoreUpgradeable.sol**
- abstract: **runs inside each token**, behind its proxy
- extended by **PolicyGatedERC20Upgradeable** and **Gated721**
- attested as part of **each template implementation**

<a id="in-one-minute"></a>

> ### In one minute
>
> Every token in the stack has the same governance: a timelock that administers the roles, a guardian that can only stop things, a recovery timelock the guardian cannot block, one attested hook, and upgrades only to reviewed code of the same template. That code lives here, once. [`PolicyGatedERC20Upgradeable`](PolicyGatedERC20Upgradeable.md), the base of the four fungible templates, extends it with balances and frozen amounts. [`Gated721`](Gated721.md) extends it with tokens and a freeze per token.
>
> The core moves nothing itself. Each template has its own movement path, which reads the hook from here and asks it about every movement. A fix to the core reaches each template through that template's own attested upgrade.

<a id="split"></a>
## What is in the core, and what each template adds

|  | The core | `PolicyGatedERC20Upgradeable` | `Gated721` |
|---|---|---|---|
| What is counted | Nothing | Balances and a supply (ERC-20, with `permit`) | Tokens, each with an owner and a metadata URI (ERC-721) |
| Roles | The six role ids, `revokeRole` with the recovery exception, and OpenZeppelin `AccessControl` | The core's |  |
| Pause | `pause` by the guardian, `unpause` by either timelock | The core's; each template's own path decides what a pause refuses |  |
| Hook and registry | The hook pointer, `setPolicyHook` with its checks, and the registry fixed at setup | The core's |  |
| Upgrades | `_authorizeUpgrade`: the role, the attestation and the template id | The core's; each template names its own `templateId()` |  |
| Account answers | The logic behind `canSend` and `canReceive` | Each declares the two functions, as both ERC-7943 interfaces do, and calls the core |  |
| Freezes | None | An amount per account | A yes or no per account and token |
| Movement path and pre-flights | None | `_move`, `canTransfer`, `canTransferWithReason` | Its own `_move` and pre-flights |
| Issuance and enforcement | None | `mint(to, amount)`, `burn(from, amount)`, `forcedTransfer`, `setFrozenTokens` | `mint(to, tokenId, uri)`, `burn(tokenId)`, `forcedTransfer`, `setFrozenTokens`, `setTokenURI` |
| Interfaces it reports | `IPolicyGatedCore` (`0xcc8e18aa`), `IAccessControl`, `IERC165` | Adds `IPolicyGated`, `IERC7943Fungible` (`0x3edbb4c4`), `IERC20`, `IERC20Permit` | Adds `IGated721`, `IERC7943NonFungible` (`0xbf1ef5fe`), ERC-721, its metadata extension, and ERC-4906 |

`IPolicyGated` and `IGated721` both inherit `IPolicyGatedCore`. So `PolicyHookChanged` and the errors `PolicyGated_NotAttested`, `PolicyGated_HookRegistryMismatch`, `PolicyGated_TransferRejected` and `PolicyGated_ZeroAddress` have the same topic and selectors on every template, and an integrator decodes them the same way.

<a id="setup"></a>
## Setup

A template's `initialize` first sets up its token parent, then calls `__PolicyGatedCore_init(admin, guardian, registry, hook, rules)`. That function sets up OpenZeppelin's `AccessControl`, `Pausable` and `Multicall`, then the core's own state:

1. A zero `admin`, `guardian` or `registry` reverts with `PolicyGated_ZeroAddress`.
2. The registry is stored. There is no setter, so it is fixed from here on.
3. `DEFAULT_ADMIN_ROLE` goes to `admin`, the operations account in a launch, which later hands it to the main timelock. `GUARDIAN_ROLE` goes to `guardian`.
4. The hook is installed with the checks of [Replacing the hook](#hook), and `PolicyHookChanged(0, hook)` is emitted.
5. If the rule list is not empty, the token calls `setRules(token, rules)` on the hook, so it is live with its policy from the transaction that creates it. An empty list installs none, and the hook then refuses every movement.

`Gated4626Vault` calls the parents' setup functions one by one, because ERC-4626's setup sits between ERC-20's and `permit`'s, and ends with `__PolicyGatedCore_init_unchained`, the last step above alone. `npm run validate:upgrades` fails on a missing or repeated parent setup call, and warns on one out of order.

<a id="roles"></a>
## Roles, the guardian and recovery

No role has an admin of its own, so `DEFAULT_ADMIN_ROLE` grants and revokes every role; after hand-over that is the main timelock. The table gives what the core itself gates. Each template gates its own functions with the same ids.

| Role | In the core | In the templates |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Grant and revoke roles, `setPolicyHook`, `unpause` | The hook and the rules ask a token whether a caller holds it before they accept that token's rule list or settings. On `Gated4626Vault` it also plugs a portfolio and a fee model and raises the rate limit, and a vault's portfolio, guarded accounts and desk ask the vault for it |
| `GUARDIAN_ROLE` | `pause`, at once, and nothing else here | `Gated4626Vault` also lets it lower the rate limit |
| `RECOVERY_ROLE` | Exactly `unpause` and `revokeRole(GUARDIAN_ROLE, account)` | Nothing more |
| `UPGRADER_ROLE` | Upgrades, to attested code of the same template | Nothing more |
| `AGENT_ROLE`, `MINTER_ROLE`, `BURNER_ROLE` | Defined here, gate nothing here | Forced transfers and freezes, mint, burn, and on `Gated721` the metadata URI. On `Gated7540Vault` the agent also rejects and recovers requests. [Who can do what](../roles.md#tokens) lists every function |

**The guardian can only stop things.** It cannot unpause, change the hook, grant a role or upgrade. **The recovery timelock** exists because a guardian that cancels governance operations could cancel its own removal: `revokeRole` lets a `RECOVERY_ROLE` holder revoke `GUARDIAN_ROLE`, passes every other revocation to the role's admin, and `unpause` accepts it beside the admin. The tests pin it on both families: `test_WhenRecoveryRevokesAnyOtherRole_ItReverts` on the ERC-20 base and `test_WhenTheRecoveryTimelockRevokesTheGuardian_ItCanRevokeNothingElse` on `Gated721`. See [Who can do what](../roles.md).

<a id="hook"></a>
## Replacing the hook

`setPolicyHook(_newHook)` needs `DEFAULT_ADMIN_ROLE`. The hook must not be zero (`PolicyGated_ZeroAddress`), its code hash must be attested as `HOOK` in the token's registry (`PolicyGated_NotAttested`), and it must name the same registry (`PolicyGated_HookRegistryMismatch`), because a hook shared by several tokens checks their rules against its own registry. The swap does not copy the token's rule list: the timelock sets it on the new hook with `setRules`, and until then that hook refuses the token's movements with `NO_RULES`.

Each template's movement path reads the hook once per movement, so the hook that approves a movement is the one that sees its `afterTransfer`.

<a id="upgrades"></a>
## Upgrades

Each token is a UUPS proxy. `_authorizeUpgrade` checks, in order: the caller holds `UPGRADER_ROLE`; the target's code hash is attested as `IMPLEMENTATION` (`PolicyGated_NotAttested`); and the target reports the same `templateId()` (`Templated_WrongTemplate`). So a `Gated721` cannot be moved onto a fungible template's code even when that code is attested (`test_WhenTheImplementationIsAnotherTemplate_TheUpgradeIsRefused`), and the reverse holds too. OpenZeppelin then checks that the target is a UUPS implementation and emits `Upgraded`.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `pause()` | `GUARDIAN_ROLE` | Pauses the token. Each template's movement path then refuses every kind except FORCED, and a template can refuse other functions while paused too, such as a vault's settlement, its fee collection or a 7540 claim. See [what a pause leaves possible](../roles.md#pause). |
| `unpause()` | `DEFAULT_ADMIN_ROLE` or `RECOVERY_ROLE` | Lifts the pause. Anyone else gets `AccessControlUnauthorizedAccount(caller, DEFAULT_ADMIN_ROLE)`. |
| `setPolicyHook(_newHook)` | `DEFAULT_ADMIN_ROLE` | Replaces the hook after the checks above. |
| `policyHook()`, `registry()` | Anyone (read-only) | The current hook, and the registry fixed at setup. |
| `revokeRole(role, account)` | The role's admin; `RECOVERY_ROLE` for `GUARDIAN_ROLE` | OpenZeppelin's, with the recovery exception. `grantRole`, `renounceRole`, `hasRole` and `getRoleAdmin` are OpenZeppelin's. |
| `upgradeToAndCall(newImplementation, data)` | `UPGRADER_ROLE` | Points the proxy at other code, after the checks above. |
| `multicall(data)` | Anyone; each inner call keeps the caller's roles | Several calls on the token in one transaction, all or none. Not payable. |
| `supportsInterface(interfaceId)` | Anyone (read-only) | True for `IPolicyGatedCore`, `IAccessControl` and `IERC165`; each template adds its own. |
| `templateId()` | Anyone (read-only) | Declared here, defined by each template: `keccak256` of its name. |

| Event or error | When |
|---|---|
| `PolicyHookChanged(_oldHook, _newHook)` | At setup, with `_oldHook` zero, and on `setPolicyHook` |
| `Paused`, `Unpaused`, `RoleGranted`, `RoleRevoked`, `Upgraded` | OpenZeppelin's events |
| `PolicyGated_ZeroAddress()` | A zero admin, guardian, registry or hook at setup, or a zero hook in `setPolicyHook` |
| `PolicyGated_NotAttested(target, kind)` | A hook not attested as `HOOK`, or an upgrade target not attested as `IMPLEMENTATION` |
| `PolicyGated_HookRegistryMismatch(_hookRegistry, _tokenRegistry)` | A hook that names another registry |
| `PolicyGated_TransferRejected(reason)` | Declared here; each template's movement path reverts with it when the pause or the hook refuses |
| `Templated_WrongTemplate(newImplementation, expected, actual)` | An upgrade target of another template |
| `AccessControlUnauthorizedAccount`, `EnforcedPause`, `ExpectedPause`, `InvalidInitialization` | OpenZeppelin's errors for a missing role, a pause while paused, an unpause while not paused, and a second setup |

<a id="why"></a>
## Why it is built this way

- **One copy of the governance code.** The paths that let the guardian stop things and the recovery timelock undo it are the ones an attacker would aim at. Keeping them in one contract means one review, and a fix that every template takes.
- **The movement path stays in the template.** What a movement is differs: an amount with a frozen part, or one token with a yes or no freeze. Each template builds its own context and checks, and asks the one hook the core points to.
- **Namespaced storage.** The registry and the hook pointer live in the core's ERC-7201 namespace, `gated.storage.PolicyGatedCore`. The frozen amounts live in `gated.storage.PolicyGatedERC20`, and the NFT's freezes in `gated.storage.Gated721`.
- **The registry is asked at install time.** A hook is checked when it is installed, an implementation when it is upgraded to. A later withdrawal of an attestation does not change a running token: governance removes the component, and the guardian can pause meanwhile.

<a id="limits"></a>
## What it does not do

- **It cannot be deployed on its own.** It is abstract: there is no core proxy, only templates that contain it.
- **It holds no policy.** Who may hold a token, and when, is the hook's rules. The core only knows which hook to ask.
- **It does not look at who holds a role.** A single key can hold any role unless the deployment's checks refuse it. See [Deployment and governance](../deployment.md).

<a id="connected"></a>
## Connected to

- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): The fungible base built on the core.
- [Gated721](Gated721.md): The NFT template built on the core.
- [ComplianceHook](ComplianceHook.md): The hook the core points to.
- [PolicyRegistry](PolicyRegistry.md): Asked when a hook or an implementation is installed.
- [GovernanceTimelock](GovernanceTimelock.md): Both timelocks that administer the roles.
- [Who can do what](../roles.md): Every role holder after hand-over.

<a id="source"></a>
## Source and tests

- Contract: `contracts/base/PolicyGatedCoreUpgradeable.sol`; interfaces `IPolicyGatedCore.sol`, `ITemplated.sol`
- Tests: through each template, in `PolicyGatedERC20Upgradeable.t.sol` (role gates, the guardian and recovery, the hook checks, upgrades, multicall) and `Gated721.t.sol` (the same for the NFT); the ids are pinned in `InterfaceFreeze.t.sol`

---

Describes the contracts at commit `4a906cc` on `main`.
