[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Settlement and distribution

# SignedExit

Lets a holder with its own wallet leave a vault without sending a transaction: the holder signs, and a relayer submits and pays the gas. It also lets anyone deliver what a 7540 vault owes a controller that allowed it, to that controller and to nobody else.

- **contracts/intents/SignedExit.sol**
- immutable, **not a proxy**
- **no roles**, no owner: anyone can submit an exit or deliver a claim
- not attested; one per issuer, from **Core** or **CoreParts**

<a id="in-one-minute"></a>

> ### In one minute
>
> Leaving a vault normally takes the holder's own transactions, and the network fee (gas) that goes with them. With this contract the holder signs instead, and someone else, a relayer, submits what was signed and pays the gas. There are two signed messages: the exit, which says which vault, how many shares, where the cash goes, the least it accepts and when; and the share token's own `permit`, which lets this contract take the shares. In one transaction the contract checks the exit and calls the vault. On a 4626 vault the shares are redeemed and the vault pays the signed receiver there and then. On a 7540 vault a redemption request is filed with the holder as its controller. A relayer can delay what it holds, but it cannot change it. The contract does one thing without a signature: `claimFor`, which anyone can call, claims a settled deposit's shares and a settled redemption's cash from a 7540 vault for a controller that made this contract its operator, and the controller is always the receiver. It is the mirror of [SignedEntry](SignedEntry.md). No vault has code for it, it has no roles, and neither shares nor cash stay in it.

<a id="how"></a>
## How an exit runs

The holder signs off-chain and hands both signatures to a relayer. The relayer needs no role, no credential, no share and no asset. It calls `exitWithPermit`.

> **Diagram.** The holder signs two messages off-chain, the exit and the share token's permit, and gives them to a relayer. The relayer calls exitWithPermit on SignedExit. SignedExit checks the deadline, validAfter, the nonce, that a request names no minimum and no other receiver, and the holder's signature, otherwise it reverts, and then spends the nonce. It calls permit on the vault, which is the share token, with the holder as owner and itself as spender, and ignores a failure. It calls redeem with the signed receiver and the holder as owner, or requestRedeem with the holder as controller and owner. The vault judges the holder, and a receiver that is not the holder, or reverts. On a 4626 the vault pays the cash to the signed receiver, and SignedExit reverts if it is less than minAssets. On a 7540 there is no cash yet: the shares wait in escrow under the holder as controller. SignedExit then emits ExitExecuted.
>
> **One transaction, in this order.** A revert at any step undoes all of it, the spent nonce included, so a refused exit can be submitted again until its deadline (`test_FewerAssetsThanAcceptedIsRefusedAndNothingMoves`). One failure is tolerated on purpose: a `permit` that fails is ignored, and the call that follows then needs an allowance already in place. The drawing shows the cash reaching the holder, which is the case when the holder names itself as receiver. The vault pays the receiver itself, so nothing passes through this contract: after an exit it holds no share and no asset, and neither does the relayer (`test_ARelayerSubmitsAndTheCashGoesToTheSignedReceiver`).

<a id="signatures"></a>
## The two signatures

The exit and the permit are separate messages because they are addressed to separate contracts. The exit states what the holder wants, and this contract reads it. The share token does not read an exit: to let this contract take the holder's shares, it needs a message in its own format.

### First: the exit

An EIP-712 typed message, shown to the holder field by field. Its domain is name `SignedExit`, version `1`, the chain id and this contract's address, so a signature for one deployment or chain does not work on another (`test_TheHashIsTheEip712DigestOfTheExit`). `exitHash(exit)` returns the hash that is signed. The signature is checked with OpenZeppelin's `SignatureChecker`, which accepts a plain key's signature, and a contract wallet's through ERC-1271.

| Field | What it says |
|---|---|
| `holder` | Who owns the shares and signs. On a 7540 it is also the controller of the request. |
| `vault` | The vault, which is also the share token the permit is for. |
| `shares` | The shares to redeem, or to put into a request. |
| `receiver` | Where the cash goes on a 4626. On a 7540 it must be the holder: a request pays nobody, and the cash comes at the claim. |
| `minAssets` | The least the holder accepts on a 4626. On a 7540 it must be zero. |
| `asynchronous` | True for a 7540, where the exit files a request. False for a 4626, where it redeems. |
| `nonce` | A value the holder chooses, usable once per holder. It is kept as one bit, bit `nonce & 0xff` of word `nonce >> 8`, so nonces numbered one after the other share a storage slot, 256 to a slot (`test_WhenAHolderUsesTheNoncesOfOneWord_TheyShareOneStorageSlot`). |
| `validAfter`, `deadline` | The window, inclusive at both ends. A `validAfter` of zero means no lower bound. |

### Second: the share permit

The vault's share token has ERC-2612 `permit`, signed on the share token's own domain. The holder signs itself as owner, this contract as spender, the exit's `shares` as value, the exit's `deadline`, and the token's next permit nonce. The contract passes those values and the relayer's `v`, `r`, `s` to `permit`, then calls the vault, which spends the allowance.

- **A permit that fails is ignored.** Anyone can submit a signed permit to the token first. The exit still runs, on the allowance that permit set (`test_APermitSubmittedFirstDoesNotStopTheExit`). With no permit and no allowance the vault's call reverts with the share token's own error.
- **A permit is not bound to one exit.** It sets an allowance to this contract, and this contract spends an allowance only on an exit the holder signed.
- **Contract wallets.** The share token's `permit` accepts a plain key's signature alone, so a contract wallet approves this contract beforehand, which is a transaction, and the failed `permit` is ignored.

<a id="vaults"></a>
## On a 4626 and on a 7540

### A 4626: a redemption

With `asynchronous` false, the contract calls `redeem(shares, receiver, holder)`. The shares are burnt at the vault's price in that block, the vault pays the signed receiver, and the call returns how much.

Then it compares: less than `minAssets` reverts with `SignedExit_TooFewAssets(minAssets, assets)`, nothing moves and the nonce stays unused (`test_FewerAssetsThanAcceptedIsRefusedAndNothingMoves`). Exactly `minAssets` passes (`test_ExactlyTheMinimumPasses`). A `minAssets` of zero is allowed and sets no floor.

The holder can name another receiver (`test_TheHolderCanNameAnotherEligibleReceiver`). The vault then applies the check it applies to every receiver of redemption cash that is not the owner of the shares: the receiver must pass the vault's policy, or the call reverts with `GatedVault_ThirdPartyNotEligible(account, reason)` (`test_AReceiverThePolicyRefusesIsRefusedByTheVault`, [GatedVaultBase](GatedVaultBase.md)).

### A 7540: a request

With `asynchronous` true, the contract calls `requestRedeem(shares, holder, holder)`: the holder is the controller and the owner. The shares move into the vault's escrow, the call returns zero assets, and neither this contract nor the relayer has a request (`test_ARelayerFilesTheRequestWithTheHolderAsController`). The request joins the period open at that moment.

**A signed minimum is refused** with `SignedExit_MinimumOnARequest` (`test_ARequestNamingAMinimumIsRefused`), and **a receiver other than the holder** with `SignedExit_ReceiverOnARequest` (`test_ARequestNamingAnotherReceiverIsRefused`), both before the signature is checked. A request has no price yet and pays nobody, so the contract will not appear to promise either. The holder's protection is the period's approved price.

The cash comes at the claim, once the period has settled: the holder claims in a transaction of its own, or makes this contract its operator and anyone delivers it with [`claimFor`](#claims).

The `asynchronous` flag has to match the vault. True on a 4626 reverts, because a 4626 has no `requestRedeem`. False on a 7540 calls the three-argument `redeem`, which there is a claim of settled redemption cash with the holder as controller. The vault allows that call only from the controller or its operator, and a share allowance does not open it, so it reverts with `Gated7540Vault_Unauthorized` and nothing moves. If the holder has made this contract its operator, the vault allows the call, and it is a claim the holder signed: the signed shares of the holder's settled redemption, paid to the signed receiver, under the vault's own checks and the signed `minAssets`.

<a id="claims"></a>
## `claimFor`: delivering a 7540's settled claims

On a 7540 vault the shares of a settled deposit and the cash of a settled redemption wait at the vault until someone claims them. The vault lets the controller claim, or an operator the controller approved with `setOperator`. A controller that makes this contract its operator lets anyone deliver its claims, and pay the gas for it. `claimFor(vault, controllers)` needs no signature and takes a list, so one transaction can serve many controllers.

1. **The deposit side.** For each controller the contract reads `claimableDepositRequest(0, controller)`. If it is not zero, it calls `deposit(assets, controller, controller)` for the whole amount: the shares are minted to the controller (`test_AnyoneDeliversTheSharesOfASettledDepositToItsController`).
2. **The redemption side.** It reads `claimableRedeemRequest(0, controller)`. If it is not zero, it calls `redeem(shares, controller, controller)` for the whole amount: the vault pays the cash to the controller (`test_AnyoneDeliversTheCashOfASettledRedemptionToItsController`).
3. **A claim that went through** emits `ClaimDelivered(vault, controller, isDeposit, amount)`, where `amount` is the shares minted or the assets paid, and counts one towards the number the function returns.
4. **A claim the vault refuses is skipped.** Each call to the vault is in a `try`. A revert emits `ClaimSkipped(vault, controller, isDeposit, reason)`, with the vault's revert data as `reason`, the claim stays with the vault, and the loop goes on to the next.

- **A controller that gave no leave is skipped.** The vault reverts with `Gated7540Vault_Unauthorized` for a controller that did not make this contract its operator. That controller keeps its claim and the others are served (`test_AControllerThatDidNotAllowItIsPassedOverAndTheOthersAreServed`).
- **A controller the policy refuses is skipped.** The vault re-runs its policy checks at every claim. A controller that may not receive at that moment keeps its claim with the vault and does not hold back the others. Once it may receive again, a later `claimFor` delivers it (`test_AControllerThePolicyRefusesIsPassedOverAndTheOthersAreServed`). If it stays blocked, the agent's `recoverClaimable` on the vault is the path.
- **The receiver is always the controller.** The function takes no receiver. The caller gets nothing, and nothing stays in this contract.
- **It files no request and touches no pending one.** A request that has not settled is left alone (`test_ItLeavesAPendingRequestAloneAndFilesNone`). With nothing to claim, nothing happens and no event is emitted (`test_WithNothingToClaimNothingHappens`).
- **The vault is the caller's choice.** The contract keeps no list of vaults. It holds nothing of its own and keeps no state for a claim, so a counterfeit vault gains nothing from it.

Making this contract an operator is a grant of trust in its code. Under ERC-7540 an operator is a full delegate: the vault would let it file requests for the controller and name any receiver for its claims. This contract is immutable, and the one thing it does without the holder's signature is claimFor, which claims in full to the controller itself. A holder that does not want to rely on that does not make it an operator, and claims for itself.

<a id="relayer"></a>
## What a relayer can and cannot do with a signature it holds

The relayer is trusted with nothing but timing. An exit does not name its relayer, so all of this also holds for anyone who sees the signatures, for instance in the queue of pending transactions.

### Delay it: yes

| It tries to | What happens |
|---|---|
| Hold the exit back | **It can.** Nothing forces it to submit, and the exit stays valid until `deadline`. On a 4626 the price in the block it lands is what counts, down to `minAssets`. On a 7540 the request joins whichever period is open then. |
| Not submit at all | **It can.** The exit lapses at its deadline, and nothing has moved. |
| Beat a cancellation | **It can.** `cancelExit` is an ordinary transaction from the holder. An exit that lands first executes. |
| Submit outside the window | **Refused.** `SignedExit_Expired` after the deadline, `SignedExit_NotYetValid` before `validAfter` (`test_BeforeItsWindowAndAfterItsDeadlineItIsRefused`). |

### Front-run it: harmless to the exit

Front-running means seeing a transaction before it is included and getting another one in ahead of it.

| Someone tries to | What happens |
|---|---|
| Copy the signatures and submit first | The exit runs exactly as signed and the receiver the holder named gets the cash. The slower transaction reverts with `SignedExit_NonceUsed` and its sender loses the gas (`test_AReplayIsRefused`). |
| Submit the `permit` directly to the share token first | The exit still runs, on the allowance the permit set (`test_APermitSubmittedFirstDoesNotStopTheExit`). |
| Spend the nonce to block the exit | **Refused.** The nonce is written after the holder's signature passes, and a later failure undoes the write (`test_FewerAssetsThanAcceptedIsRefusedAndNothingMoves`). `cancelExit` writes under its caller's address, so someone else cancelling does nothing to the holder's nonce (`test_ACancelledExitIsRefusedAndOnlyItsHolderCancels`). |
| Move a 4626's price just ahead of the exit | `minAssets` is the protection: below it, `SignedExit_TooFewAssets` and nothing moves. With `minAssets` at zero there is no protection. A failed exit costs the holder nothing, but a price moved on purpose can keep it from landing. |

### Change it: no

| It tries to | What happens |
|---|---|
| Change a field: the receiver, the minimum, the shares, the vault, the window, the flag | **Refused.** The hash differs, so the signature does not match: `SignedExit_BadSignature` (`test_ARelayerCannotChangeTheReceiverTheMinimumOrTheShares`), unless the changed field trips an earlier check first (a deadline already past, a `validAfter` still to come, a minimum or another receiver on a request). |
| Send the cash or the request elsewhere | **No way to.** On a 4626 the cash goes to the signed `receiver`. On a 7540 the controller is the signed `holder`. |
| Submit it twice | **Refused.** `SignedExit_NonceUsed` (`test_AReplayIsRefused`). |
| Take the holder's shares with no exit | **No way to.** The allowance is to this contract, not to the relayer, and the contract calls the vault only after an exit's checks, for the signed shares, even when the holder has given it a larger allowance. |
| Take a cut | **No way to.** The contract pays its caller nothing, and the vault pays the receiver directly. How a relayer is paid is outside this contract. |
| Use `claimFor` to take a claim | **No way to.** The receiver of a claim is its controller. |

What a relayer does choose is the permit's `v`, `r`, `s`, because the exit does not cover them. With different values the failed permit is ignored, and the exit then needs an allowance already in place or it reverts.

A relayer can hold an exit back, so a short deadline is the holder's control, and on a 4626 so is a minAssets above zero.

<a id="without"></a>
## An exit without this contract

A relayed exit also works with the share token alone: the holder signs a `permit` that names the relayer as spender, and the relayer submits it with `redeem` or `requestRedeem` through the token's `multicall` ([shown on the SignedEntry page](SignedEntry.md#exits)). That route asks more trust. The permit is an allowance to the relayer and says nothing about where the cash goes, so the relayer picks the receiver or the controller. Here the allowance is to this contract, and the holder signs the receiver and the least it accepts.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `exitWithPermit(exit, exitSig, v, r, s)` | Anyone | Checks the exit, tries the share token's permit (a failure is ignored), then redeems to the signed receiver on a 4626 or files a redemption request under the holder on a 7540. Returns the assets paid, zero for a request. |
| `claimFor(vault, controllers)` | Anyone | For each controller, claims the shares of a settled deposit and the cash of a settled redemption on a 7540 vault, in full, to that controller. A claim the vault refuses is skipped. Returns how many claims were delivered. |
| `cancelExit(nonce)` | Anyone, for their own nonces | Marks the nonce used under the caller's address, so an exit signed with it cannot execute. It reverts with `SignedExit_NonceUsed` if the nonce was already used, by an exit that ran or an earlier cancel (`test_ACancelledExitIsRefusedAndOnlyItsHolderCancels`). It does not touch an allowance on the share token. |
| `exitHash(exit)` | Anyone (read-only) | The EIP-712 hash the holder signs. |
| `nonceUsed(holder, nonce)` | Anyone (read-only) | Whether a nonce was used or cancelled. |
| `eip712Domain()` | Anyone (read-only) | OpenZeppelin `EIP712`: the domain fields, for a wallet to read. The domain does not change, so `EIP712DomainChanged` does not fire. |

| Error or event | When |
|---|---|
| `ExitExecuted(exitHash, holder, vault, shares, assets)` | An exit ran. `assets` is zero for a request. |
| `ExitCancelled(holder, nonce)` | Someone called `cancelExit`, under their own address. |
| `ClaimDelivered(vault, controller, isDeposit, amount)` | `claimFor` delivered a claim: the shares of a settled deposit, or the assets of a settled redemption. |
| `ClaimSkipped(vault, controller, isDeposit, reason)` | The vault refused a claim. `reason` is what the vault reverted with, and the claim stays with the vault. |
| `SignedExit_Expired()` | After the deadline. |
| `SignedExit_NotYetValid()` | Before `validAfter`. |
| `SignedExit_NonceUsed()` | The nonce was used or cancelled. |
| `SignedExit_MinimumOnARequest()` | A request names a minimum. |
| `SignedExit_ReceiverOnARequest()` | A request names a receiver other than the holder. |
| `SignedExit_BadSignature()` | The exit's signature is not the holder's. |
| `SignedExit_TooFewAssets(minAssets, assets)` | A redemption paid less than the holder accepted. |

The checks run in the order of the table, from `SignedExit_Expired` to `SignedExit_BadSignature`, before any call to the vault. In `exitWithPermit` the errors of the vault arrive unwrapped, apart from a failed `permit`, which is ignored. In `claimFor` they arrive as the `reason` of `ClaimSkipped`.

<a id="why"></a>
## Why it is built this way

- **No vault changes.** The contract uses what a vault already has: the share token's `permit`, `redeem`, `requestRedeem` and ERC-7540 operators. Every policy decision stays in the vault's own rule list.
- **No roles.** The holder's signature carries all the authority for an exit, and a controller's own `setOperator` for a claim, so there is nothing for an owner or an operator of this contract to do. The relayer is whoever submits.
- **The holder signs where the cash goes.** A permit alone is an allowance, and whoever holds it decides the rest. The signed exit fixes the receiver and the least the holder accepts, so the relayer is left with timing.
- **The vault pays the receiver.** Neither shares nor cash pass through this contract, so there is nothing in it to take and nothing to sweep.
- **A failed permit is tolerated.** A signed permit sits in public while it waits, and anyone can submit it directly. If that made the exit fail, anyone could stop an exit for the price of one transaction.
- **The nonce is spent before any call to the vault.** A vault that calls back into this contract during the exit cannot repeat it, and a claim keeps no state here, so the contract has no reentrancy guard.
- **It refuses a minimum and a receiver on a request** rather than accept what it could not honour.
- **A refused claim is skipped, not fatal.** One controller that gave no leave, or that the policy blocks, would otherwise stop the delivery to every other controller in the list.

<a id="limits"></a>
## What it does not do

- **No list of vaults.** The holder signs a vault address, and the contract calls that address and no other, for the permit and for the redemption or the request. An exit signed for a counterfeit vault moves nothing in a genuine one.
- **A minimum protects on a 4626 only.** On a 7540 the holder files without knowing the price, and relies on the period's approved price.
- **The receiver still passes the vault's check.** The contract is no way around the policy: a receiver that is not the holder must be one the vault's policy accepts, and the holder's own shares are judged as on any redemption or request, with the vault's pause, freezes and lockups.
- **An operator is a full delegate.** A controller that makes this contract its operator trusts its immutable code to do nothing with that but `claimFor` and what the holder signs.
- **`claimFor` skips what the vault refuses.** The claim waits at the vault, until the controller allows this contract, the policy lets the controller receive, the controller claims for itself, or the agent's `recoverClaimable` delivers it. A caller learns of a skip from the returned count and the `ClaimSkipped` events.
- **Claims go to the controller only.** A controller that wants its cash paid elsewhere claims for itself and names the receiver.
- **Cancelling takes a transaction**, so it needs gas, and it can lose the race with the relayer. It does not revoke an allowance on the share token.
- **A permit takes a plain key.** A contract wallet can sign the exit, and has to approve this contract with a transaction.
- **No payment to the relayer**, and no way to name one.
- **It does not replace the plain route.** An exit by a share `permit` and `multicall` still works without this contract, and then the relayer is trusted with where the cash goes.
- **Nothing from the modules but the deployment.** `Core` deploys one when the profile sets `signedExit`, and `CoreParts` adds one to a running core. It is not attested and gets no role, and no shipped profile sets `signedExit`. The post-deploy check compares its code with the release's and checks that a sample exit hashes under its own EIP-712 domain.

<a id="connected"></a>
## Connected to

- [SignedEntry](SignedEntry.md): Its mirror: entering a vault on signed messages.
- [Gated4626Vault](Gated4626Vault.md): Where an exit is a redemption, and `minAssets` applies.
- [Gated7540Vault](Gated7540Vault.md): Where an exit is a request under the holder, and where operators and claims are defined.
- [GatedVaultBase](GatedVaultBase.md): The third-party check a receiver other than the holder has to pass.
- [NavDesk](NavDesk.md): Approves the price that protects a 7540 request.
- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): Gives a share token the `permit` this contract uses.
- [CredentialRule](CredentialRule.md): The usual reason a vault accepts or refuses a receiver or a claim.

<a id="source"></a>
## Source and tests

- Contract: `contracts/intents/SignedExit.sol`, interface `ISignedExit.sol`
- Tests: `SignedExit.t.sol` (a redemption and a request on real vaults, the receiver and the vault's check on it, the minimum, the window, replay, cancelling, a permit submitted first, the nonce bitmap, claims delivered and skipped, and the hash) and `test/nodejs/products.test.ts` (one added to a running core, a wallet signs both messages and a relayer submits them on a deployed vault, and the check refusing a stack that lost it)
- Deployment: `ignition/parts.ts`, used by `Core.ts` and `CoreParts.ts`; the check in `assertHandedOver`, `test/nodejs/fixtures.ts`
