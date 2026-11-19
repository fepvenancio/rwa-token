[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Vaults

# GatedVaultBase

What the two vault templates share. Vault shares appear and disappear only through the vault's own flows, and on its deposit, redemption and claim calls an account that pays or is paid on behalf of another must pass the token's policy.

- **contracts/vaults/GatedVaultBase.sol**
- abstract: **inherited, not deployed alone**
- extends **PolicyGatedERC20Upgradeable**
- used by **Gated4626Vault** and **Gated7540Vault**

<a id="in-one-minute"></a>

> ### In one minute
>
> A vault has two legs. The shares are a gated token, so the policy judges whoever receives them or gives them up. The money is an ordinary ERC-20 transfer, and the policy does not see it. Left at that, an account the policy refuses could pay for someone else's shares, or collect someone else's redemption cash.
>
> This contract closes that gap. When the account paying, or the account being paid, is not the investor itself, it has to pass the token's policy or the call reverts with `GatedVault_ThirdPartyNotEligible`. An investor paying itself is not judged, so a holder whose credential has lapsed can still leave. The contract also turns off the base token's issuer `mint` and `burn`, because vault shares come and go through deposits and redemptions.

<a id="how"></a>
## How the check works

The policy sees the share leg of every vault call, because share movements go through the [hook](ComplianceHook.md). The check here covers the asset leg, where one account pays or is paid on behalf of another.

> **Diagram.** The two legs of a vault call, and where the check sits. Entering: a payer sends the asset to the vault, which is not hooked, and the vault gives shares to the receiver as a MINT that the hook judges. If the payer is not the receiver, the payer must pass the enforcement probe or the call reverts with GatedVault_ThirdPartyNotEligible. Leaving: the owner gives up shares as a BURN that the hook judges, and the vault sends the asset to a receiver, which is not hooked. If that receiver is not the owner, it must pass the enforcement probe or the call reverts with the same error.
>
> **The hook sees the shares, the probe covers the money.** The drawing is the 4626, and the 7540 has the same two legs. On the 7540 the entering leg splits between a request and a claim, and the leaving leg between a request, a settlement and a claim: the owner's shares leave as a TRANSFER into the escrow at the request, which is where the hook judges the owner, and the BURN at settlement is of the escrow. The table below names the account judged in each call.

The internal function `_requireThirdPartyEligible(account, party)` does the work. If `account` and `party` are the same address it returns at once. Otherwise it runs the enforcement probe on `account` and, on anything other than `TRANSFER_OK`, reverts with `GatedVault_ThirdPartyNotEligible(account, reason)`.

| Vault | Call | Account judged | Not judged when it is |
|---|---|---|---|
| [4626](Gated4626Vault.md) | `deposit(assets, receiver)`, `mint(shares, receiver)` | The caller, who pays | `receiver`, which the mint judges anyway |
| 4626 | `withdraw(assets, receiver, owner)`, `redeem(shares, receiver, owner)` | `receiver`, who gets the cash | `owner` |
| [7540](Gated7540Vault.md) | `requestDeposit(assets, controller, owner)` | `owner`, who pays | `controller`, which the mint probe judges in the same call |
| 7540 | `requestRedeem(shares, controller, owner)` | `controller`, who will collect | `owner` |
| 7540 | `redeem(shares, receiver, controller)`, `withdraw(assets, receiver, controller)` | `receiver`, who gets the cash | `controller` |

The `requestRedeem` check exists because of the claim row below it. A controller collecting for itself skips the third-party check at the claim and is judged only by the burn probe, which a lapsed account passes, so without this check a holder could name a lapsed address as controller and that address would collect the cash.

<a id="probes"></a>
## Three questions asked without moving anything

The vaults ask the policy about an account through three probes. Each one builds a movement that nobody performs and sends it through the base token's checks and the hook, the same path a real movement takes, without the write. The amount and the kind of the pretend movement decide which rules have an opinion.

| Probe | Pretend movement | While paused | Used for |
|---|---|---|---|
| **Enforcement probe**<br>`_enforcementProbe(account)`, here | FORCED of 0 from `address(0)` to the account | Still answers: FORCED passes a pause | The third-party check above, and the recovery account of the 7540's `recoverClaimable` |
| **Mint probe**<br>`_mintProbe(receiver)`, in the base token | MINT of `type(uint128).max` to the account | `PAUSED` | `maxDeposit` and `maxMint` on both vaults, and on the 7540 `requestDeposit` and the deposit claims |
| **Burn probe**<br>`_canTransfer(account, address(0), 0)`, in the base token | BURN of 0 from the account | `PAUSED` | `maxRedeem` on both vaults, and on the 7540 `maxWithdraw` and the redemption claims |

This is how the rules a vault can list answer each probe, read from each rule's `check`. A token's list decides which of these apply. The token's own address is not judged by `CredentialRule` on either side, which is what lets a 7540 hold its escrow with no credential of its own.

| Rule | Enforcement probe | Mint probe | Burn probe |
|---|---|---|---|
| [`CredentialRule`](CredentialRule.md) | The account must be `ACTIVE` and meet the token's policy. Otherwise `CREDENTIAL_EXPIRED`, `RECEIVER_NOT_VERIFIED` or `RECEIVER_NOT_ELIGIBLE`. |  | `ACTIVE`, `EXIT_ONLY` and `LAPSED` pass. Otherwise `SENDER_NOT_ELIGIBLE`. |
| [`HolderRestrictionRule`](HolderRestrictionRule.md) | The account must not be address-frozen (`RECEIVER_FROZEN`). A lockup does not matter. |  | `SENDER_FROZEN`, then `LOCKED_UP` |
| [`MinPositionRule`](MinPositionRule.md) | Passes: FORCED is exempt. | Passes while the minimum is at most `type(uint128).max`. | Passes: an amount of zero is not judged. |
| [`FundHoldersRule`](FundHoldersRule.md) | `NOT_FUND_CLASS` if the vault is not a registered class under this rule. The amount is zero, so the cap does not apply. | `NOT_FUND_CLASS` as before, and `MAX_HOLDERS` for a new investor at a full fund. | `NOT_FUND_CLASS` as before. The cap does not apply to a burn. |

[`SupplyCapRule`](SupplyCapRule.md) would refuse the very large mint, so listing it would turn a vault's `maxDeposit` and `maxMint` to 0 for everyone; the deployment profiles refuse that combination when the module is built (`assertUsable`), not the contract. [`SettlementWindowRule`](SettlementWindowRule.md) and [`ExecutedOnlyRule`](ExecutedOnlyRule.md) have no opinion on these kinds, and the profiles keep them off vaults as well.

<a id="max"></a>
## What the `max*` views can say, and what they cannot

ERC-4626 and ERC-7540 let a vault say how much an account may deposit or redeem. Integrators read these numbers before they call, so the policy shows through them. They are useful and they have edges.

### They can say

- The vault is paused: every `max*` reads 0.
- The named account would be refused for who it is. On the deposit side: no acceptable credential, or an address freeze. On the redeem side: an unknown or blocked credential, an address freeze, or a lockup.
- A new investor would not fit in a full fund: the mint probe's amount is not zero, so the cap sees a new holder.

### They cannot say

- **Anything about a second account.** Each view takes one address. `maxDeposit(receiver)` says nothing about whether the payer would pass, and `maxRedeem(owner)` says nothing about whether the receiver of the cash would pass. A holder's redemption to an uncredentialed account reverts with `GatedVault_ThirdPartyNotEligible` (`test_WhenARedemptionPaysAnUncredentialedThirdParty_ItIsRefused`), although `maxRedeem`, which looks only at the holder, reads the whole position. To ask about the other account, read `canReceive(account)`, which for the rules a vault lists gives the probe's answer while the vault is not paused, or simulate the call.
- **Whether your amount will pass.** The probes use fixed amounts. A deposit that would leave a position below the minimum reverts with `BELOW_MIN_POSITION` although `maxDeposit` reads `type(uint256).max` (`test_WhenAMinimumIsSet_MaxDepositForAnEmptyReceiverIsStillTheFullRange`, `test_WhenADepositWouldLeaveDust_ItRevertsWithTheReasonAndTheMinimumDepositWorks`). The size of a real movement is judged when it happens.
- **Why the answer is 0.** For a policy reason, ask `canTransferWithReason(address(0), receiver, amount)` or `canTransferWithReason(owner, address(0), amount)`, with the amount you mean to move. Some causes of a 0 are outside it: on a 4626 with a portfolio, `priceFresh()` false, `exitOnly()` true for a deposit, or nothing in `liquidAssets()` for a redemption, and on a 7540, nothing claimable.
- **A limit on the size of a position.** A rule that bounded it, such as a supply cap or a maximum balance, would refuse the very large mint and read 0 for every account. None of the rules a vault lists does this.

The vaults' `max*` do not use `canReceive`. That answer takes no amount and leaves the investor cap out, so a new investor at a full fund would read as eligible while a mint to it is refused.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `mint(address, uint256)`, `burn(address, uint256)` | Anyone, to no effect | The base token's issuer functions, overridden to revert with `GatedVault_Unsupported`, even for a holder of `MINTER_ROLE` or `BURNER_ROLE`. |
| `_enforcementProbe(account)` | The vault templates (internal) | The token's policy on `account` receiving under an enforcement move: `TRANSFER_OK` or a reason code. |
| `_requireThirdPartyEligible(account, party)` | The vault templates (internal) | Returns if the two are the same address, and otherwise reverts unless `account` passes the probe. |

| Error | When |
|---|---|
| `GatedVault_ThirdPartyNotEligible(account, reason)` | A payer, a receiver of redemption cash, or a named controller fails the probe. |
| `GatedVault_Unsupported()` | The issuer `mint` and `burn`, and on the 7540 a frozen amount on the escrow (`setFrozenTokens` on the vault's own address). |

The contract adds no state, no event and no role. Everything else a vault inherits is the base token's: see [`PolicyGatedERC20Upgradeable`](PolicyGatedERC20Upgradeable.md).

<a id="why"></a>
## Why it is built this way

- **A FORCED probe of zero.** The question is who the account is, not whether a particular movement fits. FORCED skips the pause, the amount of zero skips the cap and the minimum, and neither touches a frozen balance. What is left is the policy on who may receive under an enforcement move. A forced transfer's recipient has to pass the same test, so one rule covers both.
- **A holder paying itself is not judged.** A holder whose credential lapsed, or whose attester was killed, must still be able to leave (`test_WhenTheHolderHasLapsed_ItRedeemsToItselfAndNotToAStranger`, `test_WhenTheAttesterWasKilled_TheHolderStillRedeemsToItself`). A lapsed account cannot use that to pay anyone else: a lapsed payer for another account is refused with `CREDENTIAL_EXPIRED` (`test_WhenALapsedPayerDepositsForAClient_ItSaysItLapsed`).
- **A receiver paying for itself is not asked twice.** The mint already judges it (`test_AReceiverPayingForItselfIsNotAskedAboutAgain`).
- **A custodian can still act for clients, if it has a credential.** A credentialed account paying for a client is allowed, and the client gets the shares (`test_WhenACredentialedCustodianPaysForAClient_TheClientGetsTheShares`). [`SignedEntry`](SignedEntry.md) is one such payer, so it needs a credential as well.
- **Issuer mint and burn revert.** With them, an issuer role could change the share supply with no assets moving, and the price would stop meaning what it says.

<a id="limits"></a>
## What it does not do

- **It checks an address, at the moment of the call.** Nothing here looks at a payer's source of funds beyond its credential, and nothing follows the cash after it leaves.
- **It does not judge the caller as such.** It judges the account the money comes from or goes to. A spender with an allowance can redeem for an owner with no credential of its own when the cash goes to the owner (`test_WhenASpenderRedeemsForTheOwner_TheCashGoesToTheOwnerUnjudged`), and on the 7540 an operator is not judged while the owner it acts for is (`test_WhenAnOperatorRequestsFromAnUncredentialedPayer_ItIsRefused` shows the owner refused; the operator in it holds a credential).
- **It answers with the rules the token lists.** The probes have no opinion of their own. A token whose list has no credential rule would pass an uncredentialed third party, and a token with an empty list refuses everything (`NO_RULES`).
- **It does not hook the asset.** A gated asset applies its own policy to its own transfers. A vault holding one is an ordinary holder of it and needs a credential there (`test_WhenTheAssetIsGated_TheVaultIsAnOrdinaryHolderOfItAndNeedsACredential`).
- **It does not cover every way money moves.** Nothing here stops an account sending the asset straight to the vault, which on a 4626 with no portfolio moves the price. The fee recipient, a settlement's cash account and a controller refunded by `rejectDepositRequest` are not judged.

<a id="connected"></a>
## Connected to

- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): The base token: the hook path, the mint probe and the pre-flights this contract builds on.
- [Gated4626Vault](Gated4626Vault.md): The instant vault, and its gating-aware `max*`.
- [Gated7540Vault](Gated7540Vault.md): The request and claim vault, dealt in periods.
- [CredentialRule](CredentialRule.md): What decides most probes: who may hold, and why a lapsed holder can still leave.
- [SignedEntry](SignedEntry.md): A third-party payer by design, judged like any other.
- [One movement](../movement.md): The path every real share movement takes through the token and the hook.

<a id="source"></a>
## Source and tests

- Contract: `contracts/vaults/GatedVaultBase.sol`, interface `IGatedVaultBase.sol`
- Tests: `GatedVaultBase.t.sol` (both vaults behind the real `CredentialRule` and `HolderRestrictionRule`, and a 7540 over a gated asset)

---

Describes the contracts at commit `18e60b3` on `paris`.
