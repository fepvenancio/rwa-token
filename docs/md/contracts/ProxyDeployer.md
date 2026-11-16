[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Governance and deployment

# ProxyDeployer

Places each token. It puts the token at an address anyone can work out in advance, sets it up in the same transaction, and reverts unless the token came up on reviewed code and the deployer's own registry, with the hook, rules and symbol the call expected.

- **contracts/deploy/ProxyDeployer.sol**
- immutable, **not a proxy**
- owner: **the operations account** after `CoreHandover`
- not attested: nothing installs it by code hash

<a id="in-one-minute"></a>

> ### In one minute
>
> A token here is a small proxy contract that points at shared, reviewed code (its implementation). Anyone could deploy such a proxy. What makes a token one of this system's is how it was placed: through this contract, by its owner, and with five things checking out. The code behind it is reviewed, the token uses the same registry of reviewed code, it uses the shared compliance hook named in the call, that hook holds the exact list of rules the call expected, and the token's symbol is the one its address was computed from. If a check fails, nothing is created and the symbol stays free. An operations account owns this contract, so a product launches without waiting for a timelock: a launch adds one proxy over attested code and touches nothing that exists.

<a id="how"></a>
## How a token is placed

The owner calls `deploy(symbol, implementation, initData, hook, expectedRules)`. The steps run in this order, and any failure undoes the whole call, including the step that marked the symbol as used.

> **Diagram.** The deploy call, step by step. The owner calls deploy. If the symbol was used, it reverts with ProxyDeployer_SaltUsed. Otherwise it marks the symbol used, asks the registry whether the implementation is attested as IMPLEMENTATION and reverts with ProxyDeployer_ImplementationNotAttested if not, creates the proxy with CREATE2, runs the token's initialiser, then checks that the token names the deployer's registry, that the token's hook is the one named in the call, that the hook holds exactly the expected rules in order, and that the token reports the symbol. Each check has its own revert. If all pass it emits ProxyDeployed.
>
> **Nine steps, one transaction.** Red boxes are the reverts. Because a revert undoes the whole call, a failed deploy leaves no contract at the address and the symbol can be used again once the problem is fixed. The initialiser in step 5 can revert too, for example on an unattested hook or rule.

1. **One symbol, one token.** The symbol's hash is the CREATE2 salt, and each salt can be used once, with any implementation (`ProxyDeployer_SaltUsed(salt)`). This check comes before the attestation check (`test_WhenTheSymbolWasUsedAndTheImplementationIsNotAttested_SaltUsedWins`).
2. **Reviewed code only.** Before a proxy exists, the deployer asks its registry whether the implementation's code hash is attested as `IMPLEMENTATION` (`ProxyDeployer_ImplementationNotAttested(implementation)`). This check has to live here: the token's own setup function is the implementation's code, so code nobody reviewed could leave out a check of its own. An address with no code fails this check too.
3. **Set up in the same transaction.** The proxy is created without setup data, then the deployer calls it with `initData` straight away. Nobody can get in between and set it up first. In that call the token's initialiser installs the hook and passes it the rule list as the installation's data. The hook's `onInstall` accepts that only from the token, and installs the list for it (`test_WhenInitialising_TheTokenInstallsItsRulesOnTheHookAsItself`).
4. **Read back and compare.** The token must name the deployer's registry (`ProxyDeployer_RegistryMismatch(expected, actual)`), its hook must be the `hook` argument (`ProxyDeployer_HookNotInstalled(expected, installed)`), the hook must hold exactly `expectedRules` for it, same length and same order (`ProxyDeployer_RulesMismatch(hook, proxy)`), and the token must report the symbol the salt came from (`ProxyDeployer_SymbolMismatch(expected, actual)`).

<a id="owner"></a>
## Who owns it, and why a launch does not wait

`Core` creates the deployer with the deployer account as its owner. `CoreHandover` moves ownership to the operations account (the `operations` parameter), and it stays there. The timelock does not own it.

The `Product` module runs as the operations account, and the first product and the fiftieth take the same path. `deploy` needs no timelock operation, because a launch only adds a proxy over code the council already attested and changes nothing that exists. In the same module run the operations account is the token's first admin: it configures the token, grants its roles, gives `DEFAULT_ADMIN_ROLE` to the main timelock and renounces its own. From there on that token answers to the timelock, and the operations account holds nothing on it.

What a launch does still need comes from elsewhere: the council must already have attested the implementation, the hook and each rule in the list, or the call reverts. A token that names a fund does not touch the fund, and stays inert until it is registered ([Fund](Fund.md)).

<a id="address"></a>
## The address is known before the token exists

The token's address depends on three things: this deployer's own address, the token's symbol, and the implementation. It does not depend on the setup data, which carries the admin, the guardian, the hook and the rules. So the address can be computed, published and monitored before anything is deployed, and changing an admin or a rule in the plan does not move the token. The `Legos` module relies on this: a desk or a portfolio names its vault, so it is built against the address the vault will have.

`predict(symbol, implementation)` returns the address. It is CREATE2 with salt `keccak256(bytes(symbol))` over the creation code of [`TokenProxy`](TokenProxy.md) with arguments `(implementation, "")`, the same formula anyone can run off-chain.

The other side of that: a different implementation, or a different deployer, gives a different address for the same symbol. Each implementation deployment has its own address, so a plan that changes implementation changes where the token lands, and so does replacing this contract.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `deploy(symbol, implementation, initData, hook, expectedRules)` | The owner | Places and sets up a token, with the checks above, and returns its address. Emits `ProxyDeployed(salt, proxy, implementation, hook)`. Reverts with `OwnableUnauthorizedAccount` for anyone else. |
| `predict(symbol, implementation)` | Anyone (read-only) | The address the token will have. It does not say whether the token exists. |
| `saltUsed(salt)` | Anyone (read-only) | Whether a symbol's salt has been used. |
| `REGISTRY()` | Anyone (read-only) | The registry of reviewed code, fixed when the deployer was created. |
| `owner()` | Anyone (read-only) | The account allowed to deploy. |
| `transferOwnership(newOwner)` | The owner | OpenZeppelin `Ownable`, in one step. Emits `OwnershipTransferred`. Refuses the zero address (`OwnableInvalidOwner`). |
| `renounceOwnership()` | The owner | OpenZeppelin `Ownable`. Would disable `deploy` for good. |

The constructor takes the owner and the registry. It refuses a zero registry (`ProxyDeployer_ZeroAddress`) and a zero owner (`OwnableInvalidOwner`). There is no setter for the registry.

<a id="why"></a>
## Why it is built this way

- **Only the owner can deploy.** The address does not cover the setup data, so without the gate anyone could take a token's address first, with the same symbol and implementation but their own admin.
- **An operations account, not the timelock.** Placing a token changes nothing that exists, so a timelock delay would slow each launch and would not protect an existing holder. The changes that do affect existing products stay with the timelock.
- **One-step ownership, on purpose.** `ProxyDeployer` and [`Fund`](Fund.md) use plain `Ownable`. A two-step transfer would make the timelock schedule an accept for every fund, and leave the operations account owning the fund for the delay. The post-deploy check pins each owner, and a mistaken `ProxyDeployer` transfer costs a fresh deployer, not money.
- **The registry is fixed at construction.** So no one can point the deployer at a different list of reviewed code.
- **The registry is read when the token is placed, not later.** Like the other places that ask the registry, a later revoke does not touch a token that already exists.
- **It holds no roles and no funds.** After the setup call it has no power over the token it created.

<a id="limits"></a>
## What it does not check

- **It compares the token with the call, not with the plan.** It knows the hook and rule list passed in the call. It does not know which hook instance the council reviewed, or the rule order a profile intended. A second hook on the same registry carries the same attested hash and passes here. The post-deploy check is what refuses it ([Deployment and governance](../deployment.md)).
- **It does not look at who the admin is.** The setup data names the token's admin and guardian, and the deployer does not read them. So a stolen operations key can place a token over an attested implementation with its own admin, and can use up a symbol. It cannot change a product or a fund already handed to the timelock; until then it is the admin of a token in its launch run and the owner of a fund not yet opened. A token it places is not one the issuer published, so holders and integrators should take addresses from the issuer's list. The post-deploy check, `assertHandedOver`, lives in the test fixtures and nothing in the repository runs it against a live deployment, so the issuer has to run it on each real product.
- **A stolen key has one recovery.** Ownership is not under a timelock, so the way out is a fresh `ProxyDeployer`, which changes where later tokens land.
- **A symbol is used for good.** Once a token is placed, that symbol stays used on this deployer with any implementation, even if the token is abandoned.
- **It is not itself attested.** Nothing installs it by code hash, and nothing on chain checks the deployed copy. Its code is in the release manifest, and `verify:reproducible` checks that the build embeds the `TokenProxy` creation code that fixes each token's address.

<a id="connected"></a>
## Connected to

- [TokenProxy](TokenProxy.md): The proxy each token is, created by `deploy`.
- [PolicyRegistry](PolicyRegistry.md): The list of reviewed code the deployer asks about each implementation.
- [ComplianceHook](ComplianceHook.md): The shared hook whose rule list the deployer reads back.
- [GovernanceTimelock](GovernanceTimelock.md): Takes over each token at the end of its launch, and does not own the deployer.
- [Deployment and governance](../deployment.md): Where the deployer fits in the deployment modules.

<a id="source"></a>
## Source and tests

- Contract: `contracts/deploy/ProxyDeployer.sol`, interface `IProxyDeployer.sol`
- Deployment: `ignition/modules/Core.ts` (creates it), `CoreHandover.ts` (moves it to the operations account) and `Product.ts` (calls `deploy`)
- Tests: `ProxyDeployer.t.sol` (unit tests with a mocked registry, and integration tests with the real `PolicyRegistry`), `test/nodejs/deployment.test.ts` (an unattested implementation or rule stopping the product, each token at the address computed off-chain), `governance.test.ts` (the operations account placing a token at once) and `products.test.ts` (nobody but the operations account can place a product)

---

Describes the contracts at commit `ea062b5` on `erc8473-main`.
