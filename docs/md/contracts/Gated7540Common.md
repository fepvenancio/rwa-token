[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Vaults

# Gated7540Common

What [Gated7540Vault](Gated7540Vault.md) and [Gated7540Settlement](Gated7540Settlement.md) share: the storage they both act on, and how a controller's request reads. Abstract, so it runs only as part of those two.

- **contracts/vaults/Gated7540Common.sol**
- abstract: **inherited, not deployed alone**
- extends **GatedVaultBase**
- no external functions

<a id="in-one-minute"></a>

> ### In one minute
>
> Two contracts run on one vault's storage, so they have to agree on exactly where each figure lives. If each kept its own copy of the layout, the copies could drift apart, and one contract would read what the other wrote as something else. So the layout is written once, here, and both inherit it. The same goes for the one piece of arithmetic both need: how a controller's request reads once settlements have touched its period.

<a id="functions"></a>
## What it holds

| Item | What it is |
|---|---|
| `Request { period, pending, paid, owed }` | One controller's request on one side. `period` holds `pending`, and is 0 with nothing pending. `paid` is settled and not yet claimed, and `owed` is what that buys. |
| `Book { paid, owed, carried }` | One side of one period, which `periodBook` reads. `paid` is what its requests gave, net of rejects. `owed` is what that bought at settlement. `carried` is what settlement left for the next period, on the redemption side. Zero means it took it all. |
| `Gated7540Storage` | The vault's ERC-7201 storage, at the location of `gated.storage.Gated7540Vault`: the asset, the share decimals, the open and settled periods, the last value and supply, `unclaimedShares`, `pendingDeposits`, `claimableCash`, `pendingRedeemShares`, and the maps of requests, books and operators. `Gated7540VaultUnit_Storage` pins the location. |
| `_request(controller, isDeposit)` | A controller's request with every settled period rolled in. Every read and write of a request goes through it. It writes nothing. |
| `_store(controller, isDeposit, request)` | Writes a controller's request. |
| `_getGated7540Storage()` | The pointer to that storage. |
| `_SETTLER_ROLE`, `_VIRTUAL_SHARES` | `keccak256('SETTLER_ROLE')`, and the `1e6` virtual shares of the price. |

<a id="roll"></a>
## How a request reads

A settlement writes one total per side of a period, and touches no controller's record. So each read works out a controller's share of the settled periods from those totals, one period at a time, starting where its record stands.

*\_request, in words close to the code*

```
while the request has a period, and that period is settled:
    carried  = floor(pending × book.carried / book.paid)
    paid    += pending − carried
    owed    += floor(pending × book.owed / book.paid)
    pending  = carried
    period   = next period if carried is not zero, otherwise none
```

- **A full fill ends after one pass.** Nothing carries, so the deposit side and any settlement with no limit in the way read in one step.
- **A controller that waited walks.** It ends where one that claimed each time ends (`test_ADormantControllerEndsWhereAnActiveOneDoes`), and the views say what a write would store (`test_TheViewsSayWhatAWriteWouldStore`). A gated period walked cost 5,979 gas when measured, and a test holds it below 7,000 (`test/nodejs/vaults.test.ts`). About 5,000 gated periods in a row fit a block of 30 million. The cost falls only on calls about that controller.
- **Rounding stays on the safe side.** What each controller carries rounds down, so the parts add up to no more than the next book holds and a reject of one cannot underflow it. What is owed rounds down too, so it adds up to no more than the assets (`testFuzz_TheCarriedPartsNeverExceedTheNextBook`, `testFuzz_TheVaultCanPayEveryClaimAfterAGate`).

<a id="connected"></a>
## Connected to

- [Gated7540Vault](Gated7540Vault.md): Inherits it, for requests, claims and views.
- [Gated7540Settlement](Gated7540Settlement.md): Inherits it, for settlement and recovery.
- [GatedVaultBase](GatedVaultBase.md): Its parent: the third-party check and the probes.

<a id="source"></a>
## Source and tests

- Contract: `contracts/vaults/Gated7540Common.sol`
- Tests: it has no test file of its own, being abstract. It is tested through `Gated7540Vault.t.sol` and `Gated7540Settlement.t.sol`.

---

Describes the contracts at commit `6ef0d4e` on `erc8473-conformance`.
