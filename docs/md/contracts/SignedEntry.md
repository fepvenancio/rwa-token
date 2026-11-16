[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Settlement and distribution

# SignedEntry

Lets an investor with its own wallet enter a vault without sending a transaction: the investor signs, and a relayer submits and pays the gas. The vault sees an ordinary third-party payer, and its policy decides whether to accept it.

- **contracts/intents/SignedEntry.sol**
- immutable, **not a proxy**
- **no roles**, no owner: anyone can submit an entry
- not attested; one per issuer, from **Core** or **CoreParts**

<a id="in-one-minute"></a>

> ### In one minute
>
> Entering a vault normally takes the investor's own transactions, and the network fee (gas) that goes with them. With this contract the investor signs instead, and someone else, a relayer, submits what was signed and pays the gas. The short description is "one signature", because the investor sends no transaction. There are in fact two signed messages: the entry, which says where, how much, the least it accepts and when; and the cash, which lets this contract pull the money. In one transaction the contract checks the entry, pulls the cash and pays the vault. On a 4626 vault the shares go to the investor there and then. On a 7540 vault a request is filed with the investor as its controller. A relayer can delay what it holds, but it cannot change it. No vault has code for this: the contract is one more payer, it needs a credential on the vault's policy, it has no roles, and an entry whose flag matches a genuine vault leaves no money in it. Leaving a vault needs no such contract.

<a id="how"></a>
## How an entry runs

The investor signs off-chain and hands both signatures to a relayer. The relayer needs no role, no credential and no asset. It calls `enterWithPermit` or `enterWith3009`, depending on the form of the cash signature.

> **Diagram.** The investor signs two messages off-chain, the entry and the cash, and gives them to a relayer. The relayer calls enterWithPermit or enterWith3009 on SignedEntry. SignedEntry checks the deadline, validAfter, the nonce, that a request names no minimum and the investor's signature, otherwise it reverts, and then spends the nonce. It reads the asset from the vault. It pulls the cash from the investor through the cash token, by permit and transferFrom, or by receiveWithAuthorization. It approves the vault for the assets and calls deposit with the investor as receiver, or requestDeposit with the investor as controller and itself as owner. The vault judges the investor and this payer and takes the cash, or reverts. On a 4626 the shares are minted to the investor, and SignedEntry reverts if they are fewer than minShares. On a 7540 there are no shares yet, only a request under the investor. SignedEntry reverts if the vault left any of its allowance unspent, and then emits EntryExecuted.
>
> **One transaction, in this order.** A revert at any step undoes all of it, the spent nonce included, so a refused entry can be submitted again until its deadline. One failure is tolerated on purpose: a `permit` that fails is ignored, and the pull that follows then needs an allowance already in place. On an entry whose flag matches a genuine vault, neither the entry's cash nor an allowance to the vault stays in the contract (`test_ItHoldsNothingAfterwards`). A vault that leaves any of its allowance unspent makes the entry revert with `SignedEntry_CashNotTaken(left)`, so nothing stays. A counterfeit that does not pull does it, and so does a 7540 entered with the wrong flag when someone has named this contract the controller of a settled request (below).

<a id="signatures"></a>
## The two signatures

The entry and the cash are separate messages because they are addressed to separate contracts. The entry states what the investor wants, and this contract reads it. The cash token does not read an entry: to let this contract take the investor's money, it needs a message in its own format.

### First: the entry

An EIP-712 typed message, shown to the investor field by field. Its domain is name `SignedEntry`, version `1`, the chain id and this contract's address, so a signature for one deployment or chain does not work on another. `entryHash(entry)` returns the hash that is signed. A contract wallet can sign it too, through ERC-1271 (`test_AContractWalletSigns`).

| Field | What it says |
|---|---|
| `investor` | Who pays, and who receives the shares or controls the request. It is one account: an entry has no separate receiver. |
| `vault` | The vault. The asset is not signed: the contract asks the vault for it when the entry runs. |
| `assets` | The amount to pay. |
| `minShares` | The least the investor accepts on a 4626. On a 7540 it must be zero. |
| `asynchronous` | True for a 7540, where the entry files a request. False for a 4626, where it deposits. |
| `nonce` | A random value the investor chooses, usable once per investor. |
| `validAfter`, `deadline` | The window, inclusive at both ends. A `validAfter` of zero means no lower bound. |

### Second: the cash

The investor picks one of two forms, depending on what the vault's asset supports. Both are signed on the cash token's own domain. With an asset that has neither, the investor has to `approve` this contract beforehand, which is a transaction.

|  | ERC-2612 | ERC-3009 |
|---|---|---|
| The token's function | `permit` | `receiveWithAuthorization`, in the form that takes the signature as `bytes`. The ERC-3009 draft itself specifies `v`, `r`, `s`, and a token with only that form cannot use this entry point |
| Entry point | `enterWithPermit(entry, entrySig, v, r, s)` | `enterWith3009(entry, entrySig, cashSig)` |
| What it does | Sets an allowance, then the contract calls `transferFrom` | Moves the money to its payee, who must be the caller |
| What the investor signs | The investor as owner, this contract as spender, the entry's `assets` as value, the entry's `deadline`, and the token's next permit nonce | The investor as `from`, this contract as `to`, the entry's `assets` as value, its `validAfter` and `deadline` as the window, and `cashNonce(entry)` as the nonce |
| Tied to this entry? | No. It sets an allowance that a different entry of the same investor can spend | Yes. The nonce is derived from the entry, so the token refuses it for any other |
| If it is already used | A `permit` someone else submitted first does not stop the entry: only the allowance matters | The token refuses the used nonce. The payee is this contract, so nobody can submit it except through an entry |
| Window | The entry's window, inclusive at both ends (`test_AtTheDeadline_ItPasses`) | ERC-3009 excludes both ends, so the token refuses the authorization in the second of the entry's `deadline`, and in the second of a non-zero `validAfter` |
| Contract wallets | An OpenZeppelin `permit` accepts a plain key's signature alone, so a contract wallet approves this contract beforehand and the failed `permit` is ignored | The `bytes` signature form lets the token check ERC-1271, on a token that implements it |

**`cashNonce(entry)`** returns `keccak256(abi.encode(address(this), entryHash(entry)))`. The contract computes the same value when it calls the token, so a signature over any other nonce does not verify and the token reverts (`test_AnAuthorizationForAnotherEntryIsRefused`). The authorization pays for this entry and no other. `test/nodejs/products.test.ts` signs both messages from a wallet with `signTypedData`, reading the nonce from `cashNonce`, and a relayer that holds no asset submits them.

<a id="vaults"></a>
## On a 4626 and on a 7540

### A 4626: a deposit

With `asynchronous` false, the contract calls `deposit(assets, investor)`. The shares are minted to the investor at the vault's price in that block, and the call returns how many.

Then it compares: fewer than `minShares` reverts with `SignedEntry_TooFewShares(minShares, shares)`, nothing moves and the nonce stays unused (`test_FewerSharesThanAcceptedIsRefusedAndNothingMoves`). Exactly `minShares` passes. A `minShares` of zero is allowed and sets no floor.

### A 7540: a request

With `asynchronous` true, the contract calls `requestDeposit(assets, investor, itself)`: the investor is the controller, and this contract is the owner that pays. The call returns zero shares (`test_OnARequestItFilesUnderTheInvestorAsController`). The request joins the period open at that moment.

**A signed minimum is refused** with `SignedEntry_MinimumOnARequest`, before the signature is checked. A request has no price yet, so a minimum could not be honoured, and the contract will not appear to promise one. The investor's protection is the period's approved price.

The investor claims the shares once the period has settled, in a transaction of its own or through an operator it approved with `setOperator`. This contract does not claim. If the vault rejects the request, `rejectDepositRequest` pays the assets to the controller, the investor, and not to this contract.

The `asynchronous` flag has to match the vault. True on a 4626 reverts, because a 4626 has no `requestDeposit`. False on a 7540 calls the two-argument `deposit`, which is a claim in the caller's own name, and this contract files its requests in the investor's, so that normally reverts too and nothing moves. If someone has named this contract as the controller of a settled request, that claim would succeed and take no cash, so the entry reverts with `SignedEntry_CashNotTaken(left)`, the allowance the vault left unspent, and nothing moves (`test_WhenTheVaultDoesNotTakeTheCash_NothingHappens`). It reads the allowance and not a balance, because anyone can send this contract a balance.

<a id="payer"></a>
## An ordinary third-party payer

No vault has code for this contract. When it calls `deposit` or `requestDeposit`, the vault sees a payer that is not the receiver or controller, and it applies the rule it applies to every such payer: the payer must pass a zero-amount probe of the vault's policy, or the call reverts with `GatedVault_ThirdPartyNotEligible(account, reason)` ([GatedVaultBase](GatedVaultBase.md)).

- **So it needs a credential on each vault's policy.** Without one the vault refuses it (`test_WithoutACredential_TheVaultRefusesIt`). Anyone can deploy an instance, and each instance is judged by its address. If the asset is itself a gated token, this contract holds it for the length of the call, so it needs to pass the asset's policy as well.
- **The investor is judged too.** On a 4626 an investor the policy refuses has a `maxDeposit` of zero, the call reverts with `ERC4626ExceededMaxDeposit`, and the investor keeps its cash (`test_AnInvestorThePolicyRefusesIsRefused`). On a 7540 it reverts with `Gated7540Vault_ControllerNotEligible(reason)`.
- **The vault's other conditions apply as on any deposit**: its pause, its minimum position, and on a 7540 a controller with a request in an earlier unsettled period waits (`Gated7540Vault_EarlierRequestUnsettled`).

<a id="relayer"></a>
## What a relayer can and cannot do with a signature it holds

The relayer is trusted with nothing but timing. An entry does not name its relayer, so all of this also holds for anyone who sees the signatures, for instance in the queue of pending transactions.

### Delay it: yes

| It tries to | What happens |
|---|---|
| Hold the entry back | **It can.** Nothing forces it to submit, and the entry stays valid until `deadline`. On a 4626 the price in the block it lands is what counts, down to `minShares`. On a 7540 the request joins whichever period is open then. |
| Not submit at all | **It can.** The entry lapses at its deadline, and nothing has moved. |
| Beat a cancellation | **It can.** `cancelEntry` is an ordinary transaction from the investor. An entry that lands first executes. |
| Submit outside the window | **Refused.** `SignedEntry_Expired` after the deadline (`test_AfterTheDeadline_ItReverts`), `SignedEntry_NotYetValid` before `validAfter` (`test_BeforeItIsValid_ItReverts`). |

### Front-run it: harmless to the entry

Front-running means seeing a transaction before it is included and getting another one in ahead of it.

| Someone tries to | What happens |
|---|---|
| Copy the signatures and submit first | The entry runs exactly as signed and the investor gets what it signed for. The slower transaction reverts with `SignedEntry_NonceUsed` and its sender loses the gas (`test_AReplayIsRefused`). |
| Submit the `permit` directly to the cash token first | The entry still runs, on the allowance the permit set (`test_APermitSomeoneElseSubmittedFirstDoesNotStopIt`). |
| Spend the nonce to block the entry | **Refused.** The nonce is written after the investor's signature passes, and a later failure undoes the write (`test_FewerSharesThanAcceptedIsRefusedAndNothingMoves`). `cancelEntry` writes under its caller's address, so someone else cancelling does nothing to the investor's nonce (`testFuzz_SomeoneElseCancellingDoesNothing`). |
| Move a 4626's price just ahead of the entry | `minShares` is the protection: below it, `SignedEntry_TooFewShares` and nothing moves. With `minShares` at zero there is no protection. A failed entry costs the investor nothing, but a price moved on purpose can keep it from landing. |

### Change it: no

| It tries to | What happens |
|---|---|
| Change a field: the vault, the amount, the minimum, the window, the flag | **Refused.** The hash differs, so the signature does not match: `SignedEntry_BadSignature` (`test_AnEntryChangedAfterSigningIsRefused`), unless the changed field trips an earlier check first (a deadline already past, a `validAfter` still to come, a minimum on a request). |
| Send the shares or the request elsewhere | **No way to.** The one account named is `investor`, which is the signer, the payer and the receiver or controller. |
| Submit it twice | **Refused.** `SignedEntry_NonceUsed` (`test_AReplayIsRefused`). |
| Use an authorization with another entry | **Refused.** The token rejects the nonce (`test_AnAuthorizationForAnotherEntryIsRefused`). |
| Pull the investor's cash with no entry | **No way to.** The contract's one pull comes after the entry's checks, for the signed amount, even when the investor has given it a larger allowance. |
| Take a cut | **No way to.** The contract pays its caller nothing, and the whole amount goes to the vault (`test_ItHoldsNothingAfterwards`). How a relayer is paid is outside this contract. |

What a relayer does choose is how the cash arrives, because the entry does not cover the cash arguments:

- **A different `v`, `r`, `s`.** The failed permit is ignored, and the entry then needs an allowance already in place, or it reverts with the cash token's own error, `ERC20InsufficientAllowance` on an OpenZeppelin token (`test_WithNoPermitAndNoAllowance_ItReverts`).
- **A permit left unspent.** A permit is not bound to an entry, so an allowance left standing can pay for another entry of the same investor. That other entry still has to be one the investor signed.
- **The other route.** An entry signed with an authorization can run on a standing allowance through `enterWithPermit`. The amount and everything else stay as signed, and the authorization then stays unspent and useless, because its entry's nonce is gone.

A relayer can hold an entry back, so a short deadline is the investor's control, and on a 4626 so is a minShares above zero.

<a id="exits"></a>
## Exits need no such contract

The vault's share token already has what a relayed exit takes: ERC-2612 `permit`, and `multicall`, which runs several of the token's own functions in one transaction with the sender preserved. A holder signs one message, the share token's `permit`, naming the relayer as spender for the shares. The relayer calls `multicall` on the vault with two calls:

```
vault.multicall([
  permit(holder, relayer, shares, deadline, v, r, s),
  redeem(shares, holder, holder)            // a 4626: the cash reaches the holder in this transaction
])

vault.multicall([
  permit(holder, relayer, shares, deadline, v, r, s),
  requestRedeem(shares, holder, holder)     // a 7540: files a redemption request under the holder
])
```

The relayer needs no credential, because the vault judges the receiver of the cash or the controller and not the caller (`test_ARelayerRedeemsOnAHoldersSignatureAndTheCashGoesToTheHolder`, `test_ARelayerFilesARedemptionOnAHoldersSignature`). On a 7540 the holder later claims the cash with `redeem(shares, receiver, controller)`, which takes the controller or an operator it approved.

If someone submits the permit first, the `multicall` reverts on the spent permit nonce. The relayer then sends the `redeem` or `requestRedeem` alone, because the allowance is in place.

This route asks more trust than an entry. A share permit is an allowance to the relayer. It says how many shares and the last moment it can be submitted, and it does not say what happens to them. Once submitted, the allowance has no end date: it stands until it is spent or the holder resets it. In the calls above it is the relayer who names the holder. It could name another account as receiver or controller, or use transferFrom, and the cash or the shares would go there, as long as that account passes the token's policy (a receiver or controller that does not reverts with GatedVault_ThirdPartyNotEligible(account, reason)). An exit through a relayer needs a relayer the holder trusts with those shares.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `enterWithPermit(entry, entrySig, v, r, s)` | Anyone | Checks the entry, tries the permit (a failure is ignored), pulls the cash by `transferFrom` and pays the vault. Returns the shares received, zero for a request. |
| `enterWith3009(entry, entrySig, cashSig)` | Anyone | Checks the entry, pulls the cash by `receiveWithAuthorization` with `cashNonce(entry)`, and pays the vault. Returns the shares received, zero for a request. |
| `cancelEntry(nonce)` | Anyone, for their own nonces | Marks the nonce used under the caller's address, so an entry signed with it cannot execute. It reverts with `SignedEntry_NonceUsed` if the nonce was already used, by an entry that ran or an earlier cancel (`test_AnEntryThatRanCannotBeCancelled`, `test_CancellingTwiceReverts`). It touches neither an allowance nor an authorization on the cash token. |
| `entryHash(entry)` | Anyone (read-only) | The EIP-712 hash the investor signs. |
| `cashNonce(entry)` | Anyone (read-only) | The nonce an ERC-3009 authorization for this entry must carry. |
| `nonceUsed(investor, nonce)` | Anyone (read-only) | Whether a nonce was used or cancelled. |
| `eip712Domain()` | Anyone (read-only) | OpenZeppelin `EIP712`: the domain fields, for a wallet to read. The domain does not change, so `EIP712DomainChanged` does not fire. |

| Error or event | When |
|---|---|
| `EntryExecuted(entryHash, investor, vault, assets, shares)` | An entry ran. `shares` is zero for a request. |
| `EntryCancelled(investor, nonce)` | Someone called `cancelEntry`, under their own address. |
| `SignedEntry_Expired()` | After the deadline. |
| `SignedEntry_NotYetValid()` | Before `validAfter`. |
| `SignedEntry_NonceUsed()` | The nonce was used or cancelled. |
| `SignedEntry_MinimumOnARequest()` | A request names a minimum. |
| `SignedEntry_BadSignature()` | The entry's signature is not the investor's. |
| `SignedEntry_CashNotTaken(left)` | The vault left `left` of its allowance unspent. |
| `SignedEntry_TooFewShares(minShares, shares)` | A deposit bought fewer shares than the investor accepted. |

The checks run in the order of the table, from `SignedEntry_Expired` to `SignedEntry_BadSignature`, before any cash moves. The errors of the cash token and the vault arrive unwrapped, apart from a failed `permit`, which is ignored.

<a id="why"></a>
## Why it is built this way

- **No vault changes.** A vault already has a rule for third-party payers. Making this contract one of them keeps every policy decision in the vault's own rule list, and an issuer who does not want it gives it no credential.
- **No roles.** The investor's signature carries all the authority, so there is nothing for an owner or an operator to do. The relayer is whoever submits.
- **A failed permit is tolerated.** A signed permit sits in public while it waits, and anyone can submit it directly. If that made the entry fail, anyone could stop an entry for the price of one transaction.
- **The authorization's nonce comes from the entry.** It is the same device as the [DvPExecutor](DvPExecutor.md)'s nonce, and it makes the authorization useless for anything but this entry.
- **The nonce is spent before any call that can change state.** A vault or a token that calls back into this contract during the entry cannot repeat it, so the contract has no reentrancy guard.
- **It refuses a minimum on a request** rather than accept one it could not honour.

<a id="limits"></a>
## What it does not do

- **No list of vaults.** The investor signs a vault address, and the contract trusts what that vault reports. The asset is read from the vault when the entry runs. An investor who signs an entry for a counterfeit vault loses what its cash signature, or a standing allowance to this contract, lets that vault take, up to the signed amount.
- **A permit is not bound to one entry**, and permits run in order. An ERC-2612 permit carries the token's next sequential nonce, so a second permit does not work until the first is spent; its failure is ignored, and the entry then reverts for lack of allowance. An allowance, once set, stands until it is spent or the investor resets it on the cash token.
- **A minimum protects on a 4626 only.** On a 7540 the investor files without knowing the price, and relies on the period's approved price.
- **Cancelling takes a transaction**, so it needs gas, and it can lose the race with the relayer. It does not revoke an allowance.
- **No claims.** A 7540's shares take a later call by the investor or its operator.
- **No payment to the relayer**, and no way to name one.
- **No credential from the modules.** `Core` deploys one when the profile sets `signedEntry`, and `CoreParts` adds one to a running core, but no module credentials it, and no shipped profile sets `signedEntry`. The KYC attester gives it a credential that each vault's policy accepts. The post-deploy check compares its code with the release's and checks that a sample entry hashes under its own EIP-712 domain.
- **No sweep.** It has no function to move tokens sent to it by mistake. A gated token's agent can still take its own token out with `forcedTransfer`.

<a id="connected"></a>
## Connected to

- [GatedVaultBase](GatedVaultBase.md): The third-party check this contract has to pass as a payer.
- [Gated4626Vault](Gated4626Vault.md): Where an entry is a deposit, and `minShares` applies.
- [Gated7540Vault](Gated7540Vault.md): Where an entry is a request under the investor.
- [NavDesk](NavDesk.md): Approves the price that protects a 7540 request.
- [CredentialRule](CredentialRule.md): The usual reason a vault accepts or refuses this contract and the investor.
- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): Gives a share token the `permit` and the `multicall` that a relayed exit uses.
- [DvPExecutor](DvPExecutor.md): Ties an ERC-3009 payment to one signed instruction in the same way.

<a id="source"></a>
## Source and tests

- Contract: `contracts/intents/SignedEntry.sol`, interfaces `ISignedEntry.sol` and `IERC3009.sol`
- Tests: `SignedEntry.t.sol` (both cash forms on real vaults, the window ends, replay, cancelling, the minimum, a contract wallet, the third-party check, and the two relayed exits) and `test/nodejs/products.test.ts` (a wallet signs both messages and a relayer submits them, on a deployed vault; one added to a running core and used; a whole deployment that asks for one, and the check refusing a stack that lost it)
- Deployment: `ignition/parts.ts`, used by `Core.ts` and `CoreParts.ts`; the check in `assertHandedOver`, `test/nodejs/fixtures.ts`

---

Describes the contracts at commit `ea062b5` on `erc8473-main`.
