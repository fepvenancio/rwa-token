[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Vaults

# Gated7540Settlement

The settlement and recovery code of a [Gated7540Vault](Gated7540Vault.md), in a second contract. The vault keeps every function by name and hands six of them here, where they run on the vault's own storage with the vault's own caller. Reached directly, this contract acts on empty storage of its own and touches no vault.

- **contracts/vaults/Gated7540Settlement.sol**
- created by: **the implementation's constructor**
- one per implementation, **not a proxy**
- not attested on its own: the implementation's codehash fixes its **address**
- no role holders, no money

<a id="in-one-minute"></a>

> ### In one minute
>
> A contract on this chain may hold at most 24,576 bytes of code (EIP-170). `Gated7540Vault` with part fills does not fit in that: `PLAN.md` measured it at 24,806 bytes built as one contract. So six functions live here: closing a period, settling it, the two rejects and the two recoveries.
>
> An investor sees no difference. It calls the vault's address, the functions keep their names, and the events come from the vault. For anyone deciding how far to trust the vault, the question is whether this opens a new way to change what the vault does. The implementation's constructor creates this contract, so its address is written into the code the security council attests. The second contract has no role, no storage and no admin function of its own. Changing it takes what changing the vault takes: an upgrade through the timelock to an attested implementation, which brings its own second contract.

<a id="how"></a>
## How a call reaches it

A vault is a proxy: a small contract that keeps the address, the balances and the roles, and runs shared code with a `delegatecall`. That code is the implementation. A `delegatecall` runs another contract's code as if it were the caller's own. The vault's implementation does the same once more for these six functions.

> **Diagram.** How a call reaches the second contract. An investor or operator calls the vault's address, the TokenProxy, which holds the storage, the roles, the shares and the money. The proxy delegatecalls the Gated7540Vault implementation, and requests and claims run there. A role holder also calls the vault's address. The proxy delegatecalls the implementation, and the implementation delegatecalls Gated7540Settlement for closePeriod, settlePeriod, the two rejects and the two recoveries. All of it runs on the vault's storage: the caller stays the caller, the events come from the vault's address, and a revert comes back as it came.
>
> **Two hand-offs, one set of books.** A role check in the second contract asks the vault's role table, because that is the storage it runs on. So the holders are the vault's, and nothing here keeps a list of its own.

1. **The vault names the function.** Each of the six is one line on `Gated7540Vault`. It passes the call data, unchanged, to `SETTLEMENT_LOGIC` with OpenZeppelin's `Address.functionDelegateCall`, and a typed error comes back as it came (`test_WhenAMovedFunctionReverts_TheTypedErrorComesBack`). The vault states the whole of `IGated7540Vault`, so the compiler checks that nothing is missing.
2. **It acts on the vault.** It writes the vault's storage (`test_WhenAMovedFunctionRuns_ItWritesTheVaultsStorage`) and its events come from the vault's address (`test_WhenAMovedFunctionRuns_TheEventComesFromTheVault`). A caller without the role gets the usual error naming that caller (`test_WhenCalledWithoutTheRole_TheErrorNamesTheCaller`), and a batch through the vault's `multicall` keeps the caller too (`test_WhenBatched_MovedFunctionsKeepTheCaller`).
3. **Only these six.** The vault has no fallback, so a function it does not name reverts (`test_WhenASelectorIsUnknown_ItReverts`). What an investor or an operator calls runs on the vault itself: requests, claims, `setOperator` and the views.

<a id="fixed"></a>
## What is fixed, and what checks it

The vault's `SETTLEMENT_LOGIC()` gives the address. It is an immutable of the implementation, set in its constructor with `new Gated7540Settlement()`.

| What | What fixes it | What checks it |
|---|---|---|
| Which contract the vault hands to | The immutable is part of the implementation's code, so the codehash the council attests covers the address. No function sets it. | [`PolicyRegistry`](PolicyRegistry.md), asked at `ProxyDeployer.deploy` and at every upgrade. Each implementation creates its own (`test_WhenTwoImplementationsAreDeployed_EachCreatesItsOwn`). |
| Which functions go there | The vault's own named functions, in that same attested code. | The same attestation, and `test_WhenASelectorIsUnknown_ItReverts`. |
| The code at that address | Not the attested hash: a codehash covers an address, not the code that lives there. Once deployed the code stays: this contract is not a proxy, its `upgradeToAndCall` refuses to run, and it has no `selfdestruct`. | `npm run verify:reproducible` fails unless the vault's creation code embeds this contract's creation code. `assertHandedOver` reads the address from the product and compares the code there with the artifact, with its own address in the `__self` slot. |
| Where each figure is stored | One definition, in [`Gated7540Common`](Gated7540Common.md), which both contracts inherit. | The compiler: neither contract declares the layout itself. |
| Who may call | The vault's role table. There is no role, list or setter of this contract's own that a vault reads. | `test_WhenCalledWithoutTheRole_TheErrorNamesTheCaller`, and the role tests in `Gated7540Vault.t.sol`. |

The comparison of the code needs someone to run it. `assertHandedOver` lives in the test fixtures, and on a live chain an operator has to run it against each real product ([the post-deploy check](../deployment.md#check)).

<a id="direct"></a>
## What it cannot do when reached directly

Anyone can call this contract's address. It then runs on its own storage, which holds no roles, no requests and no balances.

- **Nobody holds a role on it, and nobody can be granted one.** It has no initializer, so no account ever became its admin (`test_WhenTheVaultsAdminGrantsARoleOnIt_ItReverts`). Closing, settling and recovering claimable balances revert for want of the role, even for the vault's own settler and agent (`test_WhenTheSettlerClosesAPeriodOnIt_ItReverts`, `test_WhenTheSettlerSettlesOnIt_ItReverts`, `test_WhenTheAgentRecoversClaimableOnIt_ItReverts`).
- **Nothing is pending on it.** The rejects and `recoverRedeemRequest` revert with `Gated7540Vault_NothingPending` (`test_WhenTheAgentRejectsOnIt_NothingIsPending`).
- **It cannot be upgraded.** `upgradeToAndCall` reverts with `UUPSUnauthorizedCallContext` (`test_WhenUpgradedDirectly_ItReverts`).
- **It has no investor functions.** `requestDeposit` and `requestRedeem` are not there (`test_WhenAnInvestorCallsIt_TheFunctionIsNotThere`).
- **It holds no money, and no vault can be moved onto it.** It has no `receive` function and no payable function that runs. `templateId()` is its own, so a vault's upgrade onto it reverts with `Templated_WrongTemplate` even if someone attested it by mistake (`test_WhenUpgradedOntoTheSecondContract_ItIsRefused`).

It inherits the base token for its internals, so the base's external functions exist on it too. A stranger can write an allowance into its own storage. That storage belongs to no vault and means nothing. Through a vault those functions cannot be reached here, because the vault forwards only the six.

<a id="functions"></a>
## What it can do

Each runs through the vault, as described on the [`Gated7540Vault`](Gated7540Vault.md#functions) page.

| Function | Who can call, through the vault | What it does |
|---|---|---|
| `closePeriod()` | `SETTLER_ROLE` | Closes the open period and opens the next. Emits `PeriodClosed`. |
| `settlePeriod(nav, fee, cash, feeRecipient, redeemLimit)` | `SETTLER_ROLE`, not while paused | Strikes one price for the closed period, books it, burns the shares taken, nets the cash, pays the fee and audits the balance. Past `redeemLimit` the rest carries to the next period. Emits `PeriodSettled`. |
| `rejectDepositRequest(controller)` | `AGENT_ROLE` while the request's period is open, `SETTLER_ROLE` once it has closed | Returns the whole pending deposit to the controller. Emits `DepositRequestRejected`. |
| `rejectRedeemRequest(controller)` | The same | Returns the whole pending redemption to the controller as a plain TRANSFER. Emits `RedeemRequestRejected`. |
| `recoverRedeemRequest(controller, to)` | The same | Moves the whole pending redemption to `to` as FORCED. Emits `RedeemRequestRecovered`. |
| `recoverClaimable(controller, to)` | `AGENT_ROLE` | Delivers everything claimable to `to`: shares as a forced mint, assets as a transfer. Emits `ClaimableRecovered`. |
| `templateId()` | Anyone (read-only), directly on this contract | `keccak256('Gated7540Settlement')`, not the vault's. Through a vault, the same selector answers with the vault's own. |

Its one immutable is `__self`, which OpenZeppelin's `UUPSUpgradeable` keeps: its own address. It has no constructor and no state variable of its own. It declares no events or errors of its own: it uses the vault's, from `IGated7540Vault` and the base token.

<a id="upgrade"></a>
## An upgrade

Nothing changes this contract alone. An upgrade moves the proxy to a new implementation, which the council has attested and which reports the same template id. That implementation created its own second contract when it was deployed, so the vault's `SETTLEMENT_LOGIC()` answers with the new address and the new code acts on the same state (`test_WhenUpgraded_TheNewLogicActsOnTheOldState`). A period's book with nothing in `carried` reads as filled, and a full fill writes nothing there (`test_WhenAPeriodIsFilledInFull_NothingIsWrittenAsCarried`).

<a id="why"></a>
## Why it is built this way

- **Fixed in the constructor, not looked up in a table.** A table of selectors an admin can edit would make adding a function an upgrade by another name, and the attested codehash would stop saying what a proxy runs. Here it does, down to the address.
- **One deployment and one attestation.** Deploying the implementation creates the second contract, so the modules have no extra step and the council no extra kind of code to attest.
- **Investor paths stay on the vault.** Requests, claims and views run there with no hand-off.
- **Settlement and recovery, as a group.** Their callers are role holders on occasional calls, so the extra gas of a hand-off falls on few calls.
- **A shared parent for the layout.** Two copies of a storage struct could drift apart. One parent cannot.

<a id="limits"></a>
## What it costs

- **Two contracts to read as one.** This is `delegatecall` inside a UUPS implementation, a pattern OpenZeppelin does not ship, though the call itself is theirs. `npm run validate:upgrades` passes because the hand-off, the immutable, the constructor and the missing initializer carry `@custom:oz-upgrades-unsafe-allow` annotations: the tool is told to allow them, and does not prove them safe.
- **An unreachable copy of the base.** Its runtime code is 18,462 bytes, against the vault's 22,315. Most of it is the base it inherits, and no vault can call that code's external functions.
- **A larger deployment.** The vault's creation code carries this contract's, for 41,162 bytes against the 49,152 that EIP-3860 allows (`test_WhenDeployed_TheVaultsWithASecondContractFitTheEip3860Limit`).
- **Some gas on each hand-off.** `PLAN.md` estimates about 3,000 to 3,700 more gas on a handed call, and at most 35 on an investor's call.
- **No fix without an upgrade.** A bug here is fixed the way a bug in the vault is: through the timelock, to a newly attested implementation.
- **Not reviewed.** No review has covered this contract, and nothing here has had an external audit.

<a id="connected"></a>
## Connected to

- [Gated7540Vault](Gated7540Vault.md): Creates this contract, names its six functions, and holds the state they act on.
- [Gated7540Common](Gated7540Common.md): The storage and the request roll the two contracts share.
- [NavDesk](NavDesk.md): Holds `SETTLER_ROLE` on the vault and makes the calls that end up here.
- [PolicyRegistry](PolicyRegistry.md): Attests the implementation whose code holds this contract's address.
- [TokenProxy](TokenProxy.md): The proxy each vault is, and the first of the two hand-offs.
- [Deployment and governance](../deployment.md): Where the attestation, the reproducible build and the post-deploy check sit.

<a id="source"></a>
## Source and tests

- Contract: `contracts/vaults/Gated7540Settlement.sol`, specified in `IGated7540Vault.sol`
- Tests: `Gated7540Settlement.t.sol` (the wiring, direct calls, the hand-off, upgrades, part fills, the walk and rounding), `Gated7540Vault.t.sol` (settlement and recovery through the vault), `ContractSizes.t.sol` (the runtime and creation-code limits)
- Checks: `scripts/verify-reproducible.ts`, `assertHandedOver` in `test/nodejs/fixtures.ts`
