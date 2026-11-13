[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Governance and deployment

# TokenProxy

The contract each token actually is. It holds the token's balances and settings at a fixed address, and runs the token's code from a separate implementation contract. It is OpenZeppelin's standard proxy with a single setting changed.

- **contracts/deploy/TokenProxy.sol**
- upgradeable proxy: **OpenZeppelin ERC1967Proxy**
- no admin of its own: upgrades need the token's **UPGRADER_ROLE**
- not attested: its implementation is

<a id="in-one-minute"></a>

> ### In one minute
>
> A proxy is a small contract with a permanent address that keeps the data and borrows its behaviour from another contract, the implementation. Holders, wallets and explorers deal with the proxy's address. Upgrading a token means pointing its proxy at other code; the balances stay where they are. OpenZeppelin's proxy normally insists on being set up in the same step that creates it. TokenProxy relaxes that one rule, because the [ProxyDeployer](ProxyDeployer.md) needs to create it first and set it up a moment later, still inside the same transaction, so that the token's address does not depend on its settings. No one can act in between.

<a id="how"></a>
## How it works

The proxy has no token logic. On each call it runs the implementation's code with a `delegatecall`: the code executes as if it were the proxy's own, reading and writing the proxy's storage. The one thing the proxy code itself deals with is the implementation's address, in the standard ERC-1967 slot `0x3608…2bbc`, which anyone can read with `eth_getStorageAt`.

> **Diagram.** Inside one transaction, ProxyDeployer creates the TokenProxy with CREATE2 and empty setup data, so the proxy stores the implementation address and runs nothing. ProxyDeployer then calls it with the setup data; the proxy delegatecalls initialize on the implementation, which sets admin, guardian, registry and hook in the proxy's storage and installs the rules. ProxyDeployer then checks the registry, hook, rule list and symbol. Each later call goes to the proxy, which delegatecalls the implementation so the code runs on the proxy's storage.
>
> **Created empty, set up in the same transaction.** The proxy exists without its settings only between two steps that ProxyDeployer takes back to back inside one transaction. If the setup or a later check fails, the whole transaction reverts and no proxy is left at the address.

1. **Create.** ProxyDeployer creates the proxy with CREATE2 and the arguments `(implementation, "")`. The constructor stores the implementation in the ERC-1967 slot and, because the data is empty, calls nothing. The implementation must have code (`ERC1967InvalidImplementation`), though through ProxyDeployer an address with no code has already failed the attestation check.
2. **Set up.** ProxyDeployer calls the proxy with the token's `initialize` call data. The proxy runs it through the implementation, and the token comes up with its admin, guardian, registry, hook and rule list.
3. **Check.** ProxyDeployer reads the token back and reverts unless it came up as the call expected ([ProxyDeployer](ProxyDeployer.md)).
4. **Serve.** From then on, calls to the token's address are forwarded to the current implementation.

<a id="override"></a>
## The one override, and why it is safe here

OpenZeppelin's `ERC1967Proxy`, in the pinned release 5.3.0, accepts empty setup data. A proxy left without its settings could be set up by whoever calls it first, so `TokenProxy` is safe only as `ProxyDeployer` uses it: created and set up in one transaction. `TokenProxy` adds nothing to OpenZeppelin's proxy.

The reason is the token's address. CREATE2 derives the address from the deployer's address, a salt and the creation code with its arguments. ProxyDeployer uses the hash of the symbol as the salt and passes the implementation as the one non-empty argument. If the setup data went into the creation code too, the address would change with each admin, guardian, hook or rule in it. With empty data, the address depends on the deployer, the symbol and the implementation, so it can be published and watched before the token exists.

It is safe because of how ProxyDeployer uses it:

- **No gap.** ProxyDeployer creates the proxy and calls it with the setup data in the same function, and the constructor calls out to nothing. So nobody can set the token up first.
- **No leftovers.** If the setup or a later check fails, the whole call reverts and no contract stays at the address.
- **No other proxy counts.** A `TokenProxy` deployed any other way sits at a different address, because CREATE2 addresses include the deployer's own address, and none of ProxyDeployer's checks ran on it. It is not one of this system's tokens.
- **The code behind it cannot be set up directly.** Each of the five token templates calls `_disableInitializers()` in its constructor, so the implementation contract itself cannot be initialised; proxies running it can.

<a id="upgrade"></a>
## Upgrades go through the token

The tokens use UUPS (the universal upgradeable proxy standard, ERC-1822): the upgrade function is part of the implementation's code, and the proxy has no admin and no upgrade function of its own. So the rules for upgrading sit with the token's other rules, in the shared core's `_authorizeUpgrade` ([`PolicyGatedCoreUpgradeable`](PolicyGatedCoreUpgradeable.md#upgrades)), which every template contains.

> **Diagram.** An upgrade, step by step. The caller calls upgradeToAndCall on the token. If it does not hold UPGRADER_ROLE, it reverts with AccessControlUnauthorizedAccount. If the new implementation is not attested as IMPLEMENTATION, it reverts with PolicyGated_NotAttested. If its templateId differs from the token's, it reverts with Templated_WrongTemplate. If it is not UUPS code for the ERC-1967 slot, OpenZeppelin reverts. Otherwise the slot is written, Upgraded is emitted and the optional data runs. The address and balances stay; the code changes.
>
> **Three checks of the token's own, then OpenZeppelin's.** Steps 1 to 3 are `_authorizeUpgrade` in the shared core; step 4 and the write are OpenZeppelin's UUPS code, which also reverts with `ERC1967InvalidImplementation` when the new code has no `proxiableUUID`. A new implementation that reports no template id is refused at step 3, with no typed error. OpenZeppelin's `onlyProxy` check runs before step 1 and reverts with `UUPSUnauthorizedCallContext` if the call does not come through an active proxy.

- **Who.** `Product` grants `UPGRADER_ROLE` to the main timelock and to no one else, and the post-deploy check asserts it among the accounts the stack knows. So as deployed, an upgrade is scheduled, waits out the delay, and can be cancelled by the guardian before it runs. The recovery timelock cannot upgrade.
- **What.** An implementation the security council attested. Each deployment of an implementation has its own code hash, so each one needs its own attestation, even when built from identical source.
- **Which template.** An attested vault implementation is refused under an intent token, and the reverse: each template reports its own `templateId()` and the token compares it with its own.
- **Ether.** `upgradeToAndCall` is the one payable function behind the proxy, and it refuses ether too: with empty data OpenZeppelin reverts with `ERC1967NonPayable`, and with data the delegated call lands in a function that is not payable (`test_WhenTheUpgraderAttachesEther_TheUpgradeReverts`).

<a id="functions"></a>
## What it can do

The proxy has a constructor and a forwarding fallback, nothing else. The upgrade function lives in the implementation, as UUPS prescribes. Its one internal function is the override.

| Function | Who can call | What it does |
|---|---|---|
| `constructor(implementation, data)` | Whoever deploys it. `ProxyDeployer` passes empty data | Stores the implementation and emits `Upgraded`. Runs `data` through the implementation if non-empty; with empty data runs nothing, which is the one change from OpenZeppelin. Reverts with `ERC1967InvalidImplementation` if the implementation has no code. |
| Any other call (fallback) | Anyone | Forwards the call to the implementation with `delegatecall`. The token's own role and policy checks decide, and its reverts come back to the caller. |
| `upgradeToAndCall(newImplementation, data)` | The token's `UPGRADER_ROLE` | Not in the proxy: the implementation's UUPS code, reached through the fallback. Points the proxy at other code after the checks above. |

<a id="why"></a>
## Why it is built this way

- **OpenZeppelin's proxy, one documented override.** Nothing about forwarding or storage layout is written here; the one change is the function OpenZeppelin provides for it.
- **A predictable address.** The council can compute each token's address from the symbol and the implementation before deployment, and the deployment can be compared with it ([Deployment and governance](../deployment.md)).
- **UUPS, so the proxy holds no power.** The proxy has no admin to secure. Who may upgrade, and to what, is decided by the token's roles and the registry, the same way as other things about the token.
- **The token's data does not move.** An upgrade replaces code. The token's balances, roles, frozen amounts and settings stay in the proxy's storage at the same address.

<a id="limits"></a>
## What it does not do

- **The override is not limited to ProxyDeployer.** Anyone can deploy a `TokenProxy` with empty data, and that proxy sits open until someone initialises it. It is safe here because such a proxy is not one of this system's tokens. Holders and integrators should take addresses from the issuer's list.
- **It checks nothing itself.** The proxy has no view on what it forwards. The checks are in the implementation, so the gate on the implementation is what protects a token: the attestation, the template check and `UPGRADER_ROLE`.
- **An upgrade can run code.** The `data` in `upgradeToAndCall` runs through the new implementation on the token's storage. The attestation covers that implementation's code, not the data of a particular call; that is for whoever reviews the timelock operation.
- **It is not attested.** Gates check the implementation behind it, not the proxy. Its creation code is built into `ProxyDeployer`, and an address computed with `predict` depends on it.

<a id="connected"></a>
## Connected to

- [ProxyDeployer](ProxyDeployer.md): Creates each system token's proxy and sets it up in the same transaction.
- [PolicyGatedCoreUpgradeable](PolicyGatedCoreUpgradeable.md): The code every template shares, with the upgrade check.
- [PolicyRegistry](PolicyRegistry.md): Attests the implementations a proxy may run.
- [GovernanceTimelock](GovernanceTimelock.md): The holder of `UPGRADER_ROLE` as deployed.

<a id="source"></a>
## Source and tests

- Contract: `contracts/deploy/TokenProxy.sol`. It has no interface of its own.
- Tests: `TokenProxy.t.sol` (empty and non-empty setup data), `ProxyDeployer.t.sol`, the upgrade tests in `PolicyGatedERC20Upgradeable.t.sol`, `Gated721.t.sol` and `IntentToken.t.sol` (template refusal, state kept, ether refused), `test/nodejs/governance.test.ts` (upgrades through the real timelock) and `deployment.test.ts` (each token at the address computed off-chain)

---

Describes the contracts at commit `4a906cc` on `main`.
