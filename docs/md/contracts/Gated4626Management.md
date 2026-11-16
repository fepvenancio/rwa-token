[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Vaults

# Gated4626Management

The management code of a [Gated4626Vault](Gated4626Vault.md), in a second contract. The vault keeps every function by name and hands four of them here, where they run on the vault's own storage with the vault's own caller. Reached directly, this contract acts on empty storage of its own and touches no vault.

- **contracts/vaults/Gated4626Management.sol**
- created by: **the implementation's constructor**
- one per implementation, **not a proxy**
- not attested on its own: the implementation's codehash fixes its **address**
- no role holders, no money

<a id="in-one-minute"></a>

> ### In one minute
>
> A contract on this chain may hold at most 24,576 bytes of code (EIP-170). Four functions of `Gated4626Vault` that no investor calls live here, which leaves the vault room under that limit: plugging a portfolio, the rate limit, the fee model and paying fees.
>
> An investor sees no difference. It calls the vault's address, the functions keep their names, and the events come from the vault. For anyone deciding how far to trust the vault, the question is whether this opens a new way to change what the vault does. The implementation's constructor creates this contract, so its address is written into the code the security council attests. The second contract has no role, no storage and no admin function of its own. Changing it takes what changing the vault takes: an upgrade through the timelock to an attested implementation, which brings its own second contract.

<a id="how"></a>
## How a call reaches it

A vault is a proxy: a small contract that keeps the address, the balances and the roles, and runs shared code with a `delegatecall`. That code is the implementation. A `delegatecall` runs another contract's code as if it were the caller's own. The vault's implementation does the same once more for these four functions.

> **Diagram.** How a call reaches the second contract. An investor calls the vault's address, the TokenProxy, which holds the storage, the roles, the shares and the money. The proxy delegatecalls the Gated4626Vault implementation, and deposits and redemptions run there. The timelock, the guardian, or anyone paying out fees also calls the vault's address. The proxy delegatecalls the implementation, and the implementation delegatecalls Gated4626Management for setPortfolio, setMaxRate, setFeeModel and collectFees. All of it runs on the vault's storage: the caller stays the caller, the events come from the vault's address, and a revert comes back as it came.
>
> **Two hand-offs, one set of books.** A role check in the second contract asks the vault's role table, because that is the storage it runs on. So the holders are the vault's, and nothing here keeps a list of its own.

1. **The vault names the function.** Each of the four is one line on `Gated4626Vault`. It passes the call data, unchanged, to `MANAGEMENT_LOGIC` with OpenZeppelin's `Address.functionDelegateCall`, and a typed error comes back as it came (`test_WhenAMovedFunctionReverts_TheTypedErrorComesBack`). The vault states the whole of `IGated4626Vault`, so the compiler checks that nothing is missing.
2. **It acts on the vault.** It writes the vault's storage (`test_WhenAMovedFunctionRuns_ItWritesTheVaultsStorage`) and its events come from the vault's address (`test_WhenAMovedFunctionRuns_TheEventsComeFromTheVault`). The money a first plug forwards leaves the vault, not this contract (`test_WhenAPlugForwardsTheVaultsBalance_ItLeavesTheVault`). A caller without the role gets the usual error naming that caller (`test_WhenCalledWithoutTheRole_TheErrorNamesTheCaller`), the guardian asked about the rate is the vault's (`test_WhenTheGuardianLowersTheRate_ItIsTheVaultsGuardianThatIsAsked`), and a batch through the vault's `multicall` keeps the caller too (`test_WhenBatched_MovedFunctionsKeepTheCaller`).
3. **Only these four.** The vault has no fallback, so a function it does not name reverts. What an investor calls runs on the vault itself: `deposit`, `mint`, `withdraw`, `redeem`, `accrue`, share transfers and the views.

<a id="fixed"></a>
## What is fixed, and what checks it

The vault's `MANAGEMENT_LOGIC()` gives the address (`test_WhenQueried_TheVaultNamesContractCode`). It is an immutable of the implementation, set in its constructor with `new Gated4626Management()`.

| What | What fixes it | What checks it |
|---|---|---|
| Which contract the vault hands to | The immutable is part of the implementation's code, so the codehash the council attests covers the address. No function sets it. | [`PolicyRegistry`](PolicyRegistry.md), asked at `ProxyDeployer.deploy` and at every upgrade. Each implementation creates its own (`test_WhenTwoImplementationsAreDeployed_EachCreatesItsOwn`). |
| Which functions go there | The vault's own named functions, in that same attested code. | The same attestation. |
| The code at that address | Not the attested hash: a codehash covers an address, not the code that lives there. Once deployed the code stays: this contract is not a proxy, its `upgradeToAndCall` refuses to run, and it has no `selfdestruct`. | `npm run verify:reproducible` fails unless the vault's creation code embeds this contract's creation code. `assertHandedOver` reads the address from the product and compares the code there with the artifact, with its own address in the `__self` slot. |
| Where each figure is stored | One definition, in [`Gated4626Common`](Gated4626Common.md), which both contracts inherit. | The compiler: neither contract declares the layout itself. |
| Who may call | The vault's role table. There is no role, list or setter of this contract's own that a vault reads. | `test_WhenCalledWithoutTheRole_TheErrorNamesTheCaller`, and the role tests in `Gated4626VaultPortfolio.t.sol` (`testFuzz_OnlyTheAdminPlugs`, `testFuzz_OnlyTheAdminPlugsAModel`, `test_TheRateLimitIsRaisedByTheAdminAndLoweredByTheGuardian`). |

The comparison of the code needs someone to run it. `assertHandedOver` lives in the test fixtures, and on a live chain an operator has to run it against each real product ([the post-deploy check](../deployment.md#check)).

<a id="direct"></a>
## What it cannot do when reached directly

Anyone can call this contract's address. It then runs on its own storage, which holds no roles, no portfolio, no fee model and no balances.

- **Nobody holds a role on it, and nobody can be granted one.** It has no initializer, so no account ever became its admin (`test_WhenTheVaultsAdminGrantsARoleOnIt_ItReverts`). Plugging a portfolio and setting a fee model revert for want of the role, even for the vault's own admin (`test_WhenTheVaultsAdminPlugsAPortfolioOnIt_ItReverts`, `test_WhenTheVaultsAdminSetsAFeeModelOnIt_ItReverts`). Setting the rate reverts with `Gated4626Vault_Unauthorized` for the vault's admin and for its guardian (`test_WhenTheVaultsAdminOrGuardianSetsTheRateOnIt_ItReverts`).
- **There are no fees on it.** It has no fee model, so `collectFees` reverts with `Gated4626Vault_NoFeeModel` (`test_WhenAnyoneCollectsFeesOnIt_ThereIsNoFeeModel`).
- **It cannot be upgraded.** `upgradeToAndCall` reverts with `UUPSUnauthorizedCallContext` (`test_WhenUpgradedDirectly_ItReverts`).
- **It takes no deposit.** It has no asset and no policy, so a deposit into it reverts and no share is issued (`test_WhenAnInvestorDepositsIntoIt_ItReverts`).
- **It holds no money, and no vault can be moved onto it.** It has no `receive` function and no payable function that runs. `templateId()` is its own, so a vault's upgrade onto it reverts with `Templated_WrongTemplate` even if someone attested it by mistake (`test_WhenUpgradedOntoTheSecondContract_ItIsRefused`).

It inherits the base token and OpenZeppelin's vault for its internals, so their external functions exist on it too. A stranger can write an allowance into its own storage. That storage belongs to no vault and means nothing. Through a vault those functions cannot be reached here, because the vault forwards only the four.

<a id="functions"></a>
## What it can do

Each runs through the vault, as described on the [`Gated4626Vault`](Gated4626Vault.md#functions) page.

| Function | Who can call, through the vault | What it does |
|---|---|---|
| `setPortfolio(portfolio, maxRateBps)` | `DEFAULT_ADMIN_ROLE` | Plugs a portfolio, or replaces one. The rate must be above zero and at most 1e9 basis points a year. The portfolio must be attested as `PORTFOLIO`, name this vault and its asset, and refuse reported adapters. One already plugged must have no adapter on its list and price at zero, and if it has written off an adapter the vault stays exit-only. A first plug starts the limit's clock. The vault's own balance of the asset is added to `last` and sent to the portfolio. Emits `PortfolioSet` and `MaxRateSet`. |
| `setMaxRate(maxRateBps)` | `DEFAULT_ADMIN_ROLE`, up to 1e9 basis points a year. `GUARDIAN_ROLE`, at or below the present rate. | Counts the value at the outgoing rate when a price can be used, then sets the limit on how fast the counted value may rise. Emits `MaxRateSet`. Anyone else gets `Gated4626Vault_Unauthorized(caller)`, and a rate above the ceiling `Gated4626Vault_RateTooHigh(maxRateBps)`. |
| `setFeeModel(feeModel)` | `DEFAULT_ADMIN_ROLE` | Plugs or replaces the fee model. It needs a portfolio (`Gated4626Vault_NoPortfolio`) and a model attested as `FEE_MODEL`, and counts first. A first plug starts the fee clock, and starts the mark at the last counted price, or at par if that is lower. Emits `FeeModelSet`. |
| `collectFees()` | Anyone, not while paused | Counts, then pays the fee model's `RECIPIENT()` the smaller of the fees owed and the portfolio's idle money, from the portfolio. Emits `FeesCollected`. With no model it reverts with `Gated4626Vault_NoFeeModel`. |
| `templateId()` | Anyone (read-only), directly on this contract | `keccak256('Gated4626Management')`, not the vault's. Through a vault, the same selector answers with the vault's own. |

Its one immutable is `__self`, which OpenZeppelin's `UUPSUpgradeable` keeps: its own address. It has no constructor and no state variable of its own. Its one constant is the ceiling on the rate, 1e9 basis points a year, which only this contract reads. It declares no events or errors of its own: it uses the vault's, from `IGated4626Vault` and the base token.

<a id="upgrade"></a>
## An upgrade

Nothing changes this contract alone. An upgrade moves the proxy to a new implementation, which the council has attested and which reports the same template id. That implementation created its own second contract when it was deployed, so the vault's `MANAGEMENT_LOGIC()` answers with the new address and the new code acts on the same state: the portfolio and the last counted value stay, and the rate can be set through it (`test_WhenUpgraded_TheNewLogicActsOnTheOldState`).

<a id="why"></a>
## Why it is built this way

- **Fixed in the constructor, not looked up in a table.** A table of selectors an admin can edit would make adding a function an upgrade by another name, and the attested codehash would stop saying what a proxy runs. Here it does, down to the address.
- **One deployment and one attestation.** Deploying the implementation creates the second contract, so the modules have no extra step and the council no extra kind of code to attest.
- **Investor paths stay on the vault.** Deposits, redemptions, `accrue` and the views run there with no hand-off.
- **Management, as a group.** Their callers are the timelock, the guardian or an occasional caller paying out fees, so the extra gas of a hand-off falls on few calls.
- **A shared parent for the layout and the counting.** Two copies of a storage struct, or of the count, could drift apart. One parent cannot.

<a id="limits"></a>
## What it costs

- **Two contracts to read as one.** This is `delegatecall` inside a UUPS implementation, a pattern OpenZeppelin does not ship, though the call itself is theirs. `npm run validate:upgrades` passes because the hand-off, the immutable, the constructor and the missing initializer carry `@custom:oz-upgrades-unsafe-allow` annotations: the tool is told to allow them, and does not prove them safe.
- **An unreachable copy of the base.** Most of its code is the base token and the vault logic it inherits, and no vault can call that code's external functions.
- **The counting is in both.** Deposits and withdrawals count the value on the vault, and three of the four functions count it here, so both contracts carry that code.
- **A larger deployment.** The vault's creation code carries this contract's. A test holds it under the 49,152 bytes that EIP-3860 allows (`test_WhenDeployed_TheVaultsWithASecondContractFitTheEip3860Limit`).
- **Some gas on each hand-off.** Each of the four calls takes one more `delegatecall`. An investor's call takes none.
- **No fix without an upgrade.** A bug here is fixed the way a bug in the vault is: through the timelock, to a newly attested implementation.
- **Not reviewed.** No review has covered this contract, and nothing here has had an external audit.

<a id="connected"></a>
## Connected to

- [Gated4626Vault](Gated4626Vault.md): Creates this contract, names its four functions, and holds the state they act on.
- [Gated4626Common](Gated4626Common.md): The storage and the counting the two contracts share.
- [Portfolio](Portfolio.md): What `setPortfolio` plugs, and where `collectFees` pays from.
- [FeeModel](FeeModel.md): What `setFeeModel` plugs, and whose recipient `collectFees` pays.
- [PolicyRegistry](PolicyRegistry.md): Attests the implementation whose code holds this contract's address.
- [TokenProxy](TokenProxy.md): The proxy each vault is, and the first of the two hand-offs.
- [Deployment and governance](../deployment.md): Where the attestation, the reproducible build and the post-deploy check sit.

<a id="source"></a>
## Source and tests

- Contract: `contracts/vaults/Gated4626Management.sol`, specified in `IGated4626Vault.sol`
- Tests: `Gated4626Management.t.sol` (the wiring, direct calls, the hand-off and upgrades), `Gated4626VaultPortfolio.t.sol` (plugging, the rate and fees through the vault), `ContractSizes.t.sol` (the runtime and creation-code limits)
- Checks: `scripts/verify-reproducible.ts`, `assertHandedOver` in `test/nodejs/fixtures.ts`

---

Describes the contracts at commit `0f8b72f` on `erc8473-main`.
