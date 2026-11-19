[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Policy

# SupplyCapRule

A ceiling on what can be minted. A mint that would take a token's supply above its cap is refused, so a stolen minter key cannot mint without limit.

- **contracts/hooks/rules/SupplyCapRule.sol**
- immutable, **not a proxy**
- cap set per token by the token's **DEFAULT_ADMIN_ROLE**
- attested as **RULE**
- ruleId: **keccak256('SupplyCapRule.v1')**

<a id="in-one-minute"></a>

> ### In one minute
>
> A token's minter can create new units. If that key is stolen, nothing else in the token limits how many. This rule gives each token a ceiling: a mint that would take the total supply above the cap is refused with `ABOVE_SUPPLY_CAP`. Transfers, burns and enforcement moves are not judged, so holders keep moving at the cap. The token's administrator sets the cap, and raising it after hand-over is a delayed governance operation.
>
> A token that lists the rule and sets no cap admits no mint: zero here is a cap of zero, not off. The rule goes on tokens and not on vaults, because a vault asks its rules about a very large mint to learn whether a receiver is allowed in, and a cap would answer no for everybody.

<a id="how"></a>
## How a mint is judged

1. **Not a mint: pass.** For every kind but `MINT`, `check(ctx)` returns `TRANSFER_OK` and asks the token nothing.
2. **Read the cap and the supply.** The cap is the rule's own record for `ctx.token`. The supply comes from the token's `totalSupply()`, a read-only call.
3. **Compare before subtracting.** If the supply is already above the cap, or the amount is above `cap - supply`, the answer is `ABOVE_SUPPLY_CAP`. A mint up to the cap exactly passes. Because the rule compares before it subtracts, no amount and no lowered cap can make it revert.

<a id="kinds"></a>
## What it does for each kind of movement

| Kind | What the rule does |
|---|---|
| TRANSFER | passes; not judged |
| EXECUTED | passes; not judged |
| FORCED | passes; not judged, an enforcement mint included |
| MINT | judged against the cap: `ABOVE_SUPPLY_CAP`, the one reason code, when the supply is above the cap or the amount does not fit under it |
| BURN | passes; not judged |

The token reverts a refused mint with `ERC8473PolicyRejected(ABOVE_SUPPLY_CAP)`, and `canTransferWithReason(address(0), to, amount)` says the same without moving anything.

<a id="account"></a>
## The account questions

`checkSend` and `checkReceive` answer `TRANSFER_OK` for every account: they are the [`BaseRule`](BaseRule.md) defaults. A cap is quantitative, and ERC-7943 keeps quantitative rules out of the account questions. So at a full cap `canReceive` still reads true, and the mint is refused.

<a id="config"></a>
## Who sets the cap, and what zero means

**Zero is a cap of zero, not off: it fails closed.** A token that lists the rule and has set no cap refuses every mint of a non-zero amount. A token that wants no cap leaves the rule out of its list.

`setSupplyCap` asks the token at call time whether the caller holds `DEFAULT_ADMIN_ROLE`, through a read-only call. While a product launches that is the operations account, and the `Product` module calls `setSupplyCap` with the `supplyCap` parameter, which has no default in the module. After the hand-over the main timelock is the admin, so raising a cap waits out its delay. A cap below the supply stops further mints and takes nothing back.

<a id="order"></a>
## Where it sits, and who lists it

The demo deployment does not list it, and neither does any other profile in `ignition/profiles.ts` at this commit, so it has no set position. A product asks for it by naming `supplyCapRule` in its `rules`. The `Core` module then deploys it, and the council attests it before the product can list it. A test does this with a `GatedToken` listing `credentialRule` then `supplyCapRule`.

<a id="vaults"></a>
## Why it is for tokens and not for vaults

Both vault templates decide whether a receiver is allowed in by asking the rules about a mint of a very large amount, `type(uint128).max`. They use a large amount so that an investor cap sees a new investor and a minimum position does not read as a block. A supply cap would see that same mint and refuse it, for every receiver, unless the cap were at least the supply plus that amount. On a vault that would mean:

- `maxDeposit` and `maxMint` read 0 for everybody.
- On [`Gated4626Vault`](Gated4626Vault.md), a deposit above zero reverts with OpenZeppelin's `ERC4626ExceededMaxDeposit`, and a mint above zero with `ERC4626ExceededMaxMint`.
- On [`Gated7540Vault`](Gated7540Vault.md), `requestDeposit` and the deposit claim revert with `Gated7540Vault_ControllerNotEligible(ABOVE_SUPPLY_CAP)`.

`assertUsable` in `ignition/profiles.ts` throws "a vault cannot use supplyCapRule" when a module is built. That check is in the deployment tooling. On chain, the hook accepts any attested rule on any token.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `setSupplyCap(token, cap)` | The token's `DEFAULT_ADMIN_ROLE` | Sets the token's cap. Emits `SupplyCapSet` with the token, the previous cap and the one set. Reverts with `SupplyCapRule_OnlyTokenAdmin(token, caller)` for anyone else. |
| `supplyCap(token)` | Anyone (read-only) | The token's cap; 0 when not set. |
| `check(ctx)` | Anyone (read-only); the hook in practice | The decision above: `TRANSFER_OK` or `ABOVE_SUPPLY_CAP`. |
| `checkSend`, `checkReceive` | Anyone (read-only) | `TRANSFER_OK` for every account. |
| `after_(ctx)` | The hook of `ctx.token` | The empty default. The hook does not call it, because `wantsAfter()` is false. |
| `onInstall(token, previousPolicy)` | Anyone; the hook when a token installs it | The empty default: the rule keeps no state derived from movements. |
| `ruleId()`, `wantsAfter()`, `supportsInterface(id)` | Anyone (read-only) | `keccak256('SupplyCapRule.v1')`; false; ERC-165 for `ISupplyCapRule`, `IComplianceRule` and `IERC165` (`test_ItAnswersForItsInterfaces`). |

<a id="why"></a>
## Why it is built this way

- **The limit sits outside the key it limits.** The minter holds `MINTER_ROLE` and cannot change the cap. That takes `DEFAULT_ADMIN_ROLE`, which after hand-over is the timelock, whose delay gives the guardian time to cancel.
- **Failing closed.** A cap nobody set refuses mints, so a token that lists the rule does not run with an unlimited minter because a setting was forgotten.
- **One instance for every token.** Caps are stored per token and authorised by that token's own admin.

<a id="limits"></a>
## What it does not do

- **It is not a rate limit.** A stolen minter key can still mint in one call up to whatever room is left under the cap.
- **It caps the supply, not the total ever minted.** The rule reads `totalSupply()` at the moment of the mint, so units burned free room for further mints.
- **It takes nothing back.** Lowering a cap below the supply stops further mints and leaves existing balances as they are.
- **`FORCED` is exempt.** An enforcement mint is not judged. At this commit `Gated7540Vault.recoverClaimable` is the only function that makes one, so on a `GatedToken` or an `IntentToken` no such route exists.
- **A zero-amount mint can pass.** With the supply at or below the cap, including an unset cap at zero supply, a mint of 0 passes this rule. It creates nothing.

<a id="connected"></a>
## Connected to

- [GatedToken](GatedToken.md): A template this rule is for, with an issuer's `mint` behind `MINTER_ROLE`.
- [IntentToken](IntentToken.md): The other token template this rule can go on.
- [ComplianceHook](ComplianceHook.md): Holds each token's list and asks this rule on a movement.
- [BaseRule](BaseRule.md): The parent this rule inherits its defaults from.
- [Gated4626Vault](Gated4626Vault.md): Where the large mint probe behind `maxDeposit` runs.

<a id="source"></a>
## Source and tests

- Contract: `contracts/hooks/rules/SupplyCapRule.sol`, interface `ISupplyCapRule.sol`, reason codes in `Errors.sol`
- Tests: `SupplyCapRule.t.sol` (who sets it, up to the cap and one above, a fuzz test of the supply already there, a lowered cap, no cap set, every other kind, on a real hook and token with a stolen minter key stopping at the cap) and `test/nodejs/legos.test.ts` (a cap set at launch through the modules, and the module refusing the rule on a vault)

---

Describes the contracts at commit `6ef0d4e` on `erc8473-conformance`.
