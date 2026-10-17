# Vault flows

Two vaults hold an ERC-20 asset and issue shares. The shares are gated tokens, so every share movement goes through the hook like any other balance change. The asset leg is an ordinary ERC-20 transfer and is never sent to the hook.

| | `Gated4626Vault` | `Gated7540Vault` |
|---|---|---|
| Pattern | ERC-4626, synchronous | ERC-7540, request then fulfil then claim |
| Who sets the price | OpenZeppelin's formula from the vault's asset balance and share supply | the fulfiller, per fulfilment, as an assets-to-shares pair |
| Share decimals | asset decimals + 6 | asset decimals |
| Assets sit in | the vault | the vault while a deposit is pending, then custody. For redemptions the vault holds the fulfiller's assets until the controller claims |

Money movements are laid out step by step in [money.md](money.md).

## `Gated4626Vault`

### Deposit and mint

```mermaid
sequenceDiagram
  participant U as Caller
  participant V as Gated4626Vault
  participant A as Asset (ERC-20)
  participant H as Hook
  U->>V: deposit(assets, receiver)
  V->>V: maxDeposit(receiver), asks canTransfer(0, receiver, 1)
  Note over V: assets above the max reverts ERC4626ExceededMaxDeposit
  V->>V: shares = previewDeposit(assets), rounded down
  V->>A: transferFrom(caller, vault, assets)
  V->>V: _mint(receiver, shares), kind MINT, operator is the caller
  V->>H: beforeTransfer
  H-->>V: TRANSFER_OK
  V->>H: afterTransfer, if a rule wants it
  V-->>U: shares, event Deposit
```

`mint(shares, receiver)` is the same with `maxMint`, `previewMint` (assets rounded up) and the same MINT step.

Only the receiver of the shares is checked by `IdentityRule`. The caller who pays the assets is not. `MaxHoldersRule` applies if the receiver is a new holder. The caller must have approved the vault on the asset. The asset is pulled before the shares are minted, so a rejection by the hook reverts the whole call, asset transfer included.

### Withdraw and redeem

```mermaid
sequenceDiagram
  participant U as Caller
  participant V as Gated4626Vault
  participant A as Asset (ERC-20)
  participant H as Hook
  U->>V: redeem(shares, receiver, owner)
  V->>V: maxRedeem(owner), asks canTransfer(owner, 0, 1)
  Note over V: shares above the max reverts ERC4626ExceededMaxRedeem
  V->>V: assets = previewRedeem(shares), rounded down
  V->>V: caller is not owner? spend the owner's share allowance
  V->>V: _burn(owner, shares), kind BURN, operator is the caller
  V->>H: beforeTransfer
  H-->>V: TRANSFER_OK
  V->>H: afterTransfer, if a rule wants it
  V->>A: transfer(receiver, assets)
  V-->>U: assets, event Withdraw
```

`withdraw(assets, receiver, owner)` is the same with `maxWithdraw` and `previewWithdraw` (shares rounded up).

`IdentityRule` needs `owner` verified. `LockupRule` rejects a locked owner. The frozen amount cannot be redeemed. The `receiver` of the assets is not checked by anything.

### The `max*` functions

These are how the vault reports what the hook will allow. Integrators are expected to call them before depositing or redeeming. `deposit`, `mint`, `withdraw` and `redeem` check the matching `max*` first, so for a non-zero amount a policy rejection appears as `ERC4626ExceededMaxDeposit`, `ERC4626ExceededMaxMint`, `ERC4626ExceededMaxWithdraw` or `ERC4626ExceededMaxRedeem` with a max of 0, not as `PolicyGated_TransferRejected`. A zero-amount call passes the max check. It reverts with `PolicyGated_TransferRejected` if the token is paused, or if the hook rejects a zero-amount movement: an unverified party (`IdentityRule`), or a locked owner on `redeem` or `withdraw` (`LockupRule`). `MaxHoldersRule` passes zero amounts, so a receiver blocked only by a full holder cap succeeds with a zero-amount `deposit` or `mint`. An allowed party also succeeds and moves nothing.

| Function | Returns |
|---|---|
| `maxDeposit(receiver)`, `maxMint(receiver)` | 0 if `canTransfer(0, receiver, 1)` is not `TRANSFER_OK` (so also 0 when paused). Otherwise `type(uint256).max` |
| `maxRedeem(owner)` | 0 if `canTransfer(owner, 0, 1)` is not `TRANSFER_OK`. Otherwise `balanceOf(owner) - getFrozen(owner)` |
| `maxWithdraw(owner)` | `convertToAssets(maxRedeem(owner))`, rounded down. It never promises more than `withdraw` can burn |

The probe uses amount 1, so it answers about the account's status. It does not test the exact amount. The `preview*` functions stay pure conversions and do not consult the hook.

`mint(address,uint256)` and `burn(address,uint256)` from the base always revert with `Gated4626Vault_Unsupported`. Shares come only from deposits and go only through redemptions. `forcedTransfer` and `setFrozen` still work on shares for the agent.

Code: `Gated4626Vault.maxDeposit`, `maxMint`, `maxRedeem`, `maxWithdraw`, `_decimalsOffset`; OpenZeppelin `ERC4626Upgradeable.deposit`, `_deposit`, `_withdraw`.

## `Gated7540Vault`

A controller's requests add up under one entry. The request id is always 0. For each controller the vault keeps:

| | Deposit side | Redemption side |
|---|---|---|
| waiting | `pendingAssets` | `pendingShares` |
| fulfilled, waiting for the claim | `claimableAssets` and `claimableShares` | `claimableShares` and `claimableAssets` |

A controller can have both pending and claimable amounts at the same time.

### Deposit: request, fulfil, claim

```mermaid
sequenceDiagram
  participant O as Owner or its operator
  participant V as Gated7540Vault
  participant A as Asset (ERC-20)
  participant F as Fulfiller (FULFILLER_ROLE)
  participant C as Custody address
  participant H as Hook
  participant K as Controller or its operator

  O->>V: requestDeposit(assets, controller, owner)
  V->>V: assets non-zero? controller non-zero? caller is owner or operator of owner?
  V->>V: canTransfer(0, controller, 1) must be TRANSFER_OK
  V->>V: pendingAssets of controller up
  V->>A: transferFrom(owner, vault, assets)
  Note over V,A: owner must have approved the vault on the asset

  F->>V: fulfillDeposit(controller, assets, shares)
  V->>V: pendingAssets down, claimableAssets and claimableShares up
  V->>V: lastPrice = assets x 10^decimals / shares, rounded down
  V->>A: transfer(custody, assets)
  A-->>C: assets

  K->>V: deposit(assets, receiver, controller)
  V->>V: canTransfer(0, controller, 1) must be TRANSFER_OK
  V->>V: shares from the claimable ratio, rounded down
  V->>V: _mint(receiver, shares), kind MINT
  V->>H: beforeTransfer, then afterTransfer if a rule wants it
```

- **Request.** The caller must be `owner` or an operator `owner` approved with `setOperator`. Checks run in this order: assets not zero, controller not zero, caller allowed, then the controller must be able to receive shares (`Gated7540Vault_ControllerNotEligible(reason)` otherwise). There is no cancel, so the vault refuses assets from a controller that could not hold the shares. That includes a full holder cap: if the controller holds no shares and the cap is reached, the request reverts with reason `MAX_HOLDERS`. Assets are pulled from `owner`. They sit in the vault until the fulfiller acts.
- **Fulfil.** The fulfiller picks both numbers: how many pending assets it fulfils and how many shares they buy. The checks run in this order: both numbers non-zero (`Gated7540Vault_ZeroAmount`), something pending for the controller (`Gated7540Vault_NothingPending`), then `assets` not above `pendingAssets` (`Gated7540Vault_ExceedsPending`). It can fulfil a request in several parts. The assets go straight to `custody`. The vault emits `Fulfilled(controller, true, price, assets, shares, fulfiller)`. No hook call happens here and pause does not block it.
- **Claim.** Only the controller or an operator of it can claim (`Gated7540Vault_Unauthorized` otherwise). The controller is checked again at claim time with the same probe as `maxDeposit`, `canTransfer(0, controller, 1)`, so a controller that lost verification after the fulfilment cannot claim (`Gated7540Vault_ControllerNotEligible(reason)`), even to a verified receiver. The caller picks the `receiver` of the shares. The shares are minted through the hook as `MINT` with `receiver` as `to`, so the receiver is checked too.

Claim arithmetic, with `full` meaning the request equals everything claimable on that side:

| Call | Reverts if | Result |
|---|---|---|
| `deposit(assets, receiver, controller)` | `assets > claimableAssets` (`Gated7540Vault_ExceedsClaimable`); computed shares are 0 (`Gated7540Vault_ZeroAmount`) | shares = `claimableShares` if full, else `floor(assets x claimableShares / claimableAssets)` |
| `mint(shares, receiver, controller)` | `shares > claimableShares` | assets used = `claimableAssets` if full, else `ceil(shares x claimableAssets / claimableShares)` |

`deposit(assets, receiver)` and `mint(shares, receiver)` with two arguments claim with the caller as controller.

Rounding favours the vault. A full claim clears the amounts exactly.

### Deposit: reject

`rejectDepositRequest(controller)` by the fulfiller sends the controller's whole `pendingAssets` back with an asset `transfer` to the controller, emits `DepositRequestRejected`, and sets `pendingAssets` to 0. The assets go to the controller, not to the owner who paid. It does not touch amounts that are already claimable. It reverts with `Gated7540Vault_NothingPending` if there is nothing pending.

### Redemption: request, fulfil, claim

```mermaid
sequenceDiagram
  participant O as Owner, its operator, or a spender
  participant V as Gated7540Vault
  participant H as Hook
  participant F as Fulfiller (FULFILLER_ROLE)
  participant A as Asset (ERC-20)
  participant K as Controller or its operator

  O->>V: requestRedeem(shares, controller, owner)
  V->>V: not owner and not its operator? spend ERC-20 share allowance
  V->>V: pendingShares of controller up
  V->>V: _transfer(owner, vault, shares), kind TRANSFER
  V->>H: beforeTransfer, then afterTransfer if a rule wants it
  Note over V,H: pause, frozen, identity of owner and vault, lockup of owner

  F->>V: fulfillRedeem(controller, shares, assets)
  V->>V: pendingShares down, claimableShares and claimableAssets up
  V->>V: lastPrice = assets x 10^decimals / shares, rounded down
  V->>V: _burn(vault, shares), kind BURN
  V->>H: beforeTransfer, then afterTransfer if a rule wants it
  V->>A: transferFrom(fulfiller, vault, assets)
  Note over F,A: the fulfiller must have approved the vault on the asset

  K->>V: redeem(shares, receiver, controller)
  V->>V: canTransfer(controller, 0, 0) must be TRANSFER_OK
  V->>V: assets from the claimable ratio, rounded down
  V->>A: transfer(receiver, assets)
```

- **Request.** `shares` and `controller` must be non-zero. If the caller is neither `owner` nor an operator of `owner`, the vault spends the caller's ERC-20 share allowance from `owner`. The shares move from `owner` to the vault as an ordinary `TRANSFER`, so the same checks apply as for a transfer: pause, frozen balance, `IdentityRule` on the owner and on the vault, `LockupRule` on the owner. The vault must therefore be verified by the identity registry. `Activate` also exempts the vault from the holder cap, so escrow never fills a slot.
- **Fulfil.** The fulfiller picks `shares` and the `assets` they pay. The checks are the same as for a deposit fulfilment: both non-zero, something pending, and `shares` not above `pendingShares`. The escrowed shares are burned as `BURN` from the vault. Then the vault pulls `assets` from the fulfiller's wallet with `transferFrom`. While the token is paused the burn is rejected, so fulfilment waits.
- **Claim.** `redeem` and `withdraw` pay the assets to a `receiver` the caller picks. They move no shares, because the burn already happened. Before paying, they check the controller with a zero-amount burn probe, `canTransfer(controller, 0, 0)`: the controller's identity and any lockup on it, without the frozen-balance check (the controller usually holds no shares by now). A controller that lost verification after the fulfilment cannot collect (`Gated7540Vault_ControllerNotEligible(reason)`). The `receiver` of the assets is not checked; the agent's `recoverClaimable` covers a controller that must not be paid. They revert with `EnforcedPause` while paused.

| Call | Reverts if | Result |
|---|---|---|
| `redeem(shares, receiver, controller)` | `shares > claimableShares` (`Gated7540Vault_ExceedsClaimable`); computed assets are 0 (`Gated7540Vault_ZeroAmount`) | assets = `claimableAssets` if full, else `floor(shares x claimableAssets / claimableShares)` |
| `withdraw(assets, receiver, controller)` | `assets > claimableAssets` | shares used = `claimableShares` if full, else `ceil(assets x claimableShares / claimableAssets)` |

### Redemption: reject and recover

Both return the escrowed shares without a fulfilment and clear the controller's whole `pendingShares`. They differ in how the shares move.

| | `rejectRedeemRequest(controller)` | `recoverRedeemRequest(controller, to)` |
|---|---|---|
| Caller | `FULFILLER_ROLE` | `AGENT_ROLE` |
| Shares go to | the controller | `to`, which must not be the zero address |
| Moved as | `TRANSFER`: the full policy applies | `FORCED`: an enforcement action |
| Event | `RedeemRequestRejected` | `RedeemRequestRecovered(controller, to, shares, agent)` |
| Use | the bank declines the request | the reject is blocked, e.g. the controller lost verification, the holder cap is full, or the escrow is frozen |

A reject is an ordinary transfer from the vault to the controller, so pause, the frozen balance on the escrow, `LockupRule` and `MaxHoldersRule` all apply, and `IdentityRule` needs the controller verified. If any of them refuses, the reject reverts with `PolicyGated_TransferRejected(reason)`, nothing changes, and the shares stay in escrow until the agent recovers them.

This matters because the controller is named by whoever made the request, and it can be a different account from the owner who escrowed the shares. A reject must not be a way to move shares to a new holder past a full cap. Before v0.2.0 a reject was `FORCED`, which skipped the cap and the pause; the 2026-10-17 review showed a holder could use that, and it was reversed (owner decision M-2).

A recovery is `FORCED`: it ignores pause and `LockupRule`, and `MaxHoldersRule` does not apply its cap (but still counts the new holder). `IdentityRule` still needs `to` verified. If the agent has frozen part of the vault's own balance, the recovery lowers that frozen amount first, as `forcedTransfer` does.

### What pause stops

| Call | While paused |
|---|---|
| `requestDeposit` | rejected: `Gated7540Vault_ControllerNotEligible(PAUSED)` |
| `requestRedeem` | rejected: `PolicyGated_TransferRejected(PAUSED)` |
| `fulfillDeposit` | works. No hook call and no pause check |
| `fulfillRedeem` | rejected: `PolicyGated_TransferRejected(PAUSED)` |
| `rejectDepositRequest` | works. It is an asset transfer |
| `rejectRedeemRequest` | rejected: `PolicyGated_TransferRejected(PAUSED)`. It is a plain `TRANSFER` |
| `recoverRedeemRequest`, `recoverClaimable` | work. Enforcement moves ignore pause |
| `deposit`, `mint` (claims) | rejected: `Gated7540Vault_ControllerNotEligible(PAUSED)`, from the claim-time controller check |
| `redeem`, `withdraw` (claims) | rejected: `EnforcedPause` |
| `setOperator`, `setCustody` | work |

### Operators

`setOperator(operator, approved)` records that the caller approves `operator`. The same approval is used in two places:

- as `owner`: the operator can call `requestDeposit` and `requestRedeem` for that account. For `requestDeposit` it moves the owner's assets into the vault, which still needs the owner's asset allowance to the vault. For `requestRedeem` it needs no share allowance.
- as `controller`: the operator can claim with `deposit`, `mint`, `redeem` and `withdraw`, and chooses the `receiver`.

The ERC-7540 standard treats operators as full delegates, and so does the code: an approved operator can also open requests that pull the owner's assets or shares under any controller, its own included. Owners should approve only custodians they would trust with the assets (owner decision L-5; a test pins this so nobody narrows it to claims).

### Prices and views

- `lastPrice()` is assets per `10**decimals()` shares at the last fulfilment, rounded down and never below 1. It starts at `10**decimals()`, which is 1:1.
- `convertToShares` and `convertToAssets` use `lastPrice`. `totalAssets()` is `convertToAssets(totalSupply)`, rounded down. It is indicative: the assets are in custody, not in the vault.
- Claims do not use `lastPrice`. They use each controller's own claimable ratio.
- `previewDeposit`, `previewMint`, `previewRedeem` and `previewWithdraw` always revert with `Gated7540Vault_AsyncOnly`, as ERC-7540 requires.
- `maxDeposit` and `maxMint` return the controller's claimable assets and shares, or 0 if the controller could not receive shares. `maxRedeem` and `maxWithdraw` return the claimable shares and assets, or 0 if the payout probe `canTransfer(controller, 0, 0)` refuses (paused, unverified, locked), so they match what `redeem` and `withdraw` will do.
- `pendingDepositRequest`, `claimableDepositRequest`, `pendingRedeemRequest` and `claimableRedeemRequest` ignore the request id.
- `mint(address,uint256)` and `burn(address,uint256)` from the base always revert with `Gated7540Vault_Unsupported`.

### States

Deposit side, for one controller:

```mermaid
stateDiagram-v2
  direction LR
  [*] --> Pending: requestDeposit
  Pending --> Pending: requestDeposit adds more
  Pending --> Claimable: fulfillDeposit
  Pending --> [*]: rejectDepositRequest
  Claimable --> [*]: deposit or mint claims all
  Claimable --> [*]: recoverClaimable (agent)
```

Redemption side, for one controller:

```mermaid
stateDiagram-v2
  direction LR
  [*] --> Pending: requestRedeem
  Pending --> Pending: requestRedeem adds more
  Pending --> Claimable: fulfillRedeem
  Pending --> [*]: rejectRedeemRequest
  Pending --> [*]: recoverRedeemRequest
  Claimable --> [*]: redeem or withdraw claims all
  Claimable --> [*]: recoverClaimable (agent)
```

Partial fulfilments and partial claims leave a controller with amounts in more than one state.

### Compliance after fulfilment

Fulfilled amounts are claimable, but compliance still applies to them (owner decision M-3, v0.2.0):

- **Claims are checked again.** A deposit claim re-runs `canTransfer(0, controller, 1)` and a redemption payout re-runs `canTransfer(controller, 0, 0)`, as described above. A controller that lost verification, or was locked, after its request was fulfilled cannot claim.
- **The agent can recover claimable balances.** `recoverClaimable(controller, to)` (`AGENT_ROLE`) pays the controller's claimable redemption assets to `to` and delivers its claimable deposit shares to `to` as an enforcement mint (`FORCED` with `from` = 0). `to` must pass `IdentityRule`; typically it is custody, the treasury, or the controller's own verified recovery account. It clears every claimable amount for the controller and emits `ClaimableRecovered(controller, to, assets, shares, agent)`. It reverts with `Gated7540Vault_NothingClaimable` if there is nothing claimable and `Gated7540Vault_RecipientNotEligible(reason)` if `to` fails the identity check.
- **Stranded deposits.** If the holder cap fills up after a deposit was fulfilled, the controller's own claim reverts with `MAX_HOLDERS`. The enforcement mint is exempt from the cap (the new holder is still counted), so the agent can deliver the shares. It also works while the token is paused.

Code: `Gated7540Vault.requestDeposit`, `requestRedeem`, `fulfillDeposit`, `fulfillRedeem`, `rejectDepositRequest`, `rejectRedeemRequest`, `recoverRedeemRequest`, `recoverClaimable`, `_claimDeposit`, `_claimMint`, `_requireDepositClaimEligible`, `_payoutReason`, `redeem`, `withdraw`, `_recordPrice`, `setOperator`; base `_mintAs`.
