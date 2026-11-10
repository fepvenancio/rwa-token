[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Vaults

# Gated7540Vault

An ERC-7540 vault that deals in periods. Investors file requests into the open period, the period closes, everyone in it gets one price in one transaction however many investors there are, and each investor claims the result later. The shares are a gated token.

- **contracts/vaults/Gated7540Vault.sol**
- upgradeable: **UUPS** behind a TokenProxy
- admin: **the main timelock**
- implementation attested as **IMPLEMENTATION**
- share decimals: **the asset's plus 6**
- priced by: **a NavDesk** holding SETTLER_ROLE
- settlement code: **Gated7540Settlement**

<a id="in-one-minute"></a>

> ### In one minute
>
> Many funds cannot settle a subscription the moment it arrives, because the price is worked out later, off chain. ERC-7540 is the standard vault for that: the investor files a request, the fund settles it, and the investor claims the result. Here requests are gathered into dealing periods, as a fund dealing daily would gather its subscriptions and redemptions up to a cut-off.
>
> When a period closes, the holder of `SETTLER_ROLE` names its net asset value, normally through a [`NavDesk`](NavDesk.md) that needs two people on every price. One transaction prices the whole period. Subscriptions pay redemptions first, and only the difference moves to or from a cash account. Each investor then claims when it likes: shares are minted at the claim, so every compliance rule still applies, and one investor's problem cannot block a settlement. An agent (`AGENT_ROLE`, the enforcement role) can take a request back or deliver what an investor cannot claim itself.
>
> A settlement can take only part of a period's redemptions. Every request is then filled at the same fraction, and the rest stays invested and deals at the next period's price ([part fills](#part-fills)). The vault is told how many shares to take and not why: a `NavDesk` holds the level. Settlement and recovery run in a second contract, [`Gated7540Settlement`](Gated7540Settlement.md), which the implementation creates and nobody can swap alone. An investor calls this vault either way and sees no difference.

<a id="how"></a>
## The dealing cycle

Three names matter. The **owner** is the account whose assets or shares a request takes. The **controller** is the account the request is booked under: it claims the result, and the eligibility checks are about it. The **receiver** is picked at the claim and gets the shares or the assets. One account is often all three.

One period is open at a time, and at most one is closed waiting for its price. The first period is number 1.

> **Diagram.** Two consecutive periods. Period 5 is open and requests join it. closePeriod, by SETTLER_ROLE, closes period 5 and opens period 6. While period 5 is closed, its requests stay pending, a controller with a request in it waits, and a second close reverts. settlePeriod, by SETTLER_ROLE, gives period 5 one price, burns the escrowed shares it takes, carries any others into period 6, nets cash, pays the fee and audits the balance. Period 5 is then settled and investors claim whenever they like. dealingState reads open 5 settled 4, then open 6 settled 4, then open 6 settled 5. Rejects and recoverRedeemRequest belong to AGENT_ROLE while the period is open and to SETTLER_ROLE once it has closed.
>
> **Nobody's request is priced before the cut-off.** A request made after `closePeriod` joins the next period (`test_ARequestAfterTheCutOffJoinsTheNextPeriod`). A period with nothing in it settles too (`test_AnEmptyPeriodSettlesAndChangesNothing`). Redemptions a settlement does not take carry into the next period and deal at its price ([part fills](#part-fills)).

1. **Request a deposit.** `requestDeposit(assets, controller, owner)`, called by the owner or an operator of the owner. In this order it refuses zero assets (`Gated7540Vault_ZeroAmount`), a zero controller (`Gated7540Vault_ZeroAddress`), and a caller who may not act (`Gated7540Vault_Unauthorized(caller)`). The controller must pass the [mint probe](GatedVaultBase.md#probes), a check that it could hold shares at all (`Gated7540Vault_ControllerNotEligible(reason)`), and an owner other than the controller must pass the [third-party check](GatedVaultBase.md#how) (`GatedVault_ThirdPartyNotEligible`). The assets move from the owner into the vault. Emits `DepositRequest`.
2. **Request a redemption.** `requestRedeem(shares, controller, owner)`, called by the owner, an operator of the owner, or an account with the owner's share allowance, which it spends. A controller other than the owner must pass the third-party check. The shares move from the owner to the vault's own address, where they wait in escrow until the request is settled, as an ordinary TRANSFER through the hook, so pause, the owner's frozen amount, credential, lockup, address freeze and minimum position apply. Emits `RedeemRequest`.
3. **Requests add up per controller.** The request id is always 0. A second request from a controller in the same period adds to the first (`test_TwoRequestsInTheOpenPeriodAdd`). If its earlier request is in a closed, unsettled period it reverts with `Gated7540Vault_EarlierRequestUnsettled(period)` (`test_AControllerWaitsWhileAnEarlierRequestIsUnsettled`). There is no way for an investor to cancel.
4. **Close.** `closePeriod()` opens the next period and emits `PeriodClosed(period)`. It reverts with `Gated7540Vault_PeriodUnsettled(period)` while an earlier closed period is unsettled, so at most one is closed. With a [`NavDesk`](NavDesk.md) holding the role, anyone can call the desk's `closePeriod()` once `periodLength` has passed, so no role picks the moment: the earliest one follows from the last cut-off, and the first successful call from then on sets it.
5. **Settle.** `settlePeriod(nav, fee, cash, feeRecipient, redeemLimit)` deals the closed period, as described [below](#settle). With a desk, its `execute()` makes this call after a reporter proposes, a different person accepts and a cooldown passes.
6. **Claim.** `deposit(assets, receiver, controller)` or `mint(shares, receiver, controller)` takes the shares; `redeem(shares, receiver, controller)` or `withdraw(assets, receiver, controller)` takes the cash. The controller or its operator calls, and picks the receiver. The two-argument `deposit(assets, receiver)` and `mint(shares, receiver)` claim for the caller as controller.

<a id="price"></a>
## One price for a period

A settlement takes the net asset value of the fund, `nav`, what all its shares are worth together, and prices everything in the period from it. `nav` leaves out what the vault itself holds, which is pending deposits and claimable redemption cash: that money belongs to investors, waiting to be invested or waiting to be paid out. `supply` is every share at that value: the share supply, including every escrowed share, whether this settlement burns it or carries it, plus shares bought in earlier periods and not yet claimed.

```
supply   = totalSupply() + unclaimedShares
redeemed = the smaller of redemptions and redeemLimit

shares for all deposits     = deposits × (supply + 1e6) / (nav + 1)
assets for the shares taken = redeemed × (nav + 1) / (supply + 1e6)

both rounded down
```

This is the form an ERC-4626 uses, with `1e6` virtual shares and one virtual unit of the asset that nobody owns. As a result **`decimals()` is the asset's decimals plus 6**: a 6-decimal asset gives 12-decimal shares, and one smallest asset unit buys `1e6` smallest share units at par (`testFuzz_TheSharesTakeTheAssetsDecimalsPlusSix`).

- **The first period needs no special case.** With `nav` and `supply` at zero the formula gives par (`test_TheFirstPeriodNeedsNoSpecialCase`).
- **A donation does not inflate the price.** A first investor of one unit who adds 1,000 to the value before a victim's 1,000 period gets less than it gave: the victim keeps its value and the attacker loses at least a third of the donation (`test_TheInflationAttackFails`).
- **The virtual amounts cost almost nothing.** Across a whole fund they move the value by about the price minus one, in smallest asset units, with the price in assets per whole share. At 2 decimals and a price of 10, a fund of 1,000 loses nine cents (`test_AtTwoDecimalsAndAPriceOfTenTheFundLosesNineCents`). A fuzz test bounds the effect more loosely across prices and decimals, by the price in smallest asset units per whole share (`testFuzz_AtAnyPriceAndDecimalsTheVirtualAmountsMoveTheValueByAtMostThePrice`).
- **The indicative views use the last settlement.** `convertToShares` and `convertToAssets` apply the same formulas with the last settled value and supply, and `totalAssets()` is all shares, unclaimed included, at that price. They are not what the vault holds: the invested money is elsewhere. `previewDeposit`, `previewMint`, `previewRedeem` and `previewWithdraw` revert with `Gated7540Vault_AsyncOnly`, as ERC-7540 requires.

<a id="settle"></a>
## What a settlement does

The cost of a settlement does not grow with the number of investors, because it writes one total per side of the period (`test_SettlementCostsTheSameFor1InvestorAnd200`). Each investor's own figure is worked out from those totals when it is read.

> **Diagram.** settlePeriod step by step, each step able to revert the whole call. One: the caller must hold SETTLER_ROLE and the vault must not be paused, else AccessControlUnauthorizedAccount or EnforcedPause. Two: a period must be closed, else Gated7540Vault_NoClosedPeriod. Three: strike the price, take the smaller of the period's redemptions and the limit, book it, carry the rest into the next period and emit PeriodSettled; amounts that do not fit 128 bits revert with SafeCastOverflowedUintDowncast. Four: burn the shares taken through the hook, else PolicyGated_TransferRejected; with none taken there is no burn. Five: net. If deposits exceed assets plus fee, send the difference to the cash account. If assets plus fee exceed deposits, pull the difference from the cash account, which can fail with the asset's own ERC20InsufficientBalance or ERC20InsufficientAllowance. If equal, nothing moves. Six: pay the fee to feeRecipient if the fee is not zero. Seven: the vault must hold at least pending deposits plus claimable cash, else Gated7540Vault_BalanceAudit.
>
> **One transaction.** Red boxes are the reverts, and a revert undoes all of it: the period stays closed and every request stays pending (`test_WhenTheCashAccountIsShort_SettlementReverts`).

- **Netting.** Subscriptions pay redemptions, so the cash account only sees the difference. It receives net inflow and funds net outflow, and to fund outflow it must have approved the vault. Tests cover each direction, the equal case where no transfer happens at all, and a fee larger than the deposits (`test_WhenDepositsExceedRedemptions_OnlyTheDifferenceGoesToTheCashAccount`, `test_WhenRedemptionsExceedDeposits_OnlyTheDifferenceComesFromTheCashAccount`, `test_WhenTheyAreEqual_NothingMoves`, `test_AFeeAboveTheDepositsComesFromTheCashAccount`). The settler names the account in each call. With a [`NavDesk`](NavDesk.md) it is the desk's portfolio or custodian account.
- **The limit.** `redeemLimit` is the most shares this settlement takes from the period's redemptions, and `type(uint256).max` takes them all. The vault does not ask why. [What a smaller limit does](#part-fills).
- **The balance audit.** After the money moves, the vault must hold at least the assets of its pending deposits plus the cash booked for settled redemptions. It reverts with `Gated7540Vault_BalanceAudit(held, owed)` otherwise, for example with an asset that delivers less than it was asked to (`test_WhenMoneyIsMissingAfterwards_TheBalanceAuditFires`). Requests already filed in the next open period are part of what it must still hold.
- **The event.** `PeriodSettled(period, nav, supply, deposits, shares, redemptions, redeemed, assets, fee)` is emitted before the burn. See [what it lets a reader rebuild](#history).

<a id="claims"></a>
## Requests and claims

Each controller has one record per side, deposit and redemption: `Request { period, pending, paid, owed }`.

| Field | Deposit side | Redemption side | Read with |
|---|---|---|---|
| `period` | The period holding `pending`; 0 with nothing pending. |  | No getter |
| `pending` | Assets requested, not yet settled | Shares requested and not yet taken, in escrow, a carried part included | `pendingDepositRequest`, `pendingRedeemRequest` |
| `paid` | Assets settled and not yet claimed. They have already gone to redemptions, the fee or the cash account. | Shares settled and not yet claimed. They have already been burned. | `claimableDepositRequest`, `maxDeposit`; `claimableRedeemRequest`, `maxRedeem` (the two `max*` read 0 when nothing is owed) |
| `owed` | Shares those assets bought, not yet minted | Assets those shares pay, held in the vault | `maxMint`; `maxWithdraw` |

**A settled request rolls when read.** Settlement does not touch any investor's record. Once a request's period is settled, every read works out what that period took from it. The part it carried is `floor(pending × period's carried / period's paid)`. The rest of `pending` goes to `paid`, and `floor(pending × period's owed / period's paid)` goes to `owed`. What carried becomes `pending` in the next period, and the read goes on until it reaches a period not yet settled or nothing is left (`test_ClaimableDoesNotDependOnTheRollHavingBeenWritten`, `test_TheViewsSayWhatAWriteWouldStore`). With nothing carried, as on every deposit, one pass ends it. The next request or claim writes that down. Amounts from different periods blend in one `paid` and `owed` (`test_ASettledRequestRollsIntoTheClaimableAmountsAtTheNextRequest`).

**A claim can take part of what is claimable.** Given what was paid, the other side rounds down. Given what is owed, the paid side rounds up. A claim of everything clears the pair exactly, because there is nothing left to round (`test_WhenClaimedInTwoStepsByAssets_SharesNeverExceedTheBook`, `test_WhenMintingPartially_TheAssetsRoundUp`, `test_WhenRedeemingPartially_TheAssetsRoundDown`, `test_WhenWithdrawingPartially_TheSharesRoundUp`).

| Claim | Takes | Works out | If the result is zero |
|---|---|---|---|
| `deposit(assets, …)` | `assets` of `paid` | shares delivered = `floor(assets × owed / paid)` | Reverts `Gated7540Vault_ZeroAmount` |
| `mint(shares, …)` | `shares` of `owed` | assets used = `ceil(shares × paid / owed)` | Delivered: it is owed either way |
| `redeem(shares, …)` | `shares` of `paid` | assets paid = `floor(shares × owed / paid)` | Reverts `Gated7540Vault_ZeroAmount` |
| `withdraw(assets, …)` | `assets` of `owed` | shares used = `ceil(assets × paid / owed)` | Delivered: it is owed either way |

A zero input reverts with `Gated7540Vault_ZeroAmount` on all four, and a claim above what is claimable with `Gated7540Vault_ExceedsClaimable(requested, claimable)`. A failed claim consumes nothing. Because `mint` and `withdraw` round up, they can use one side of the pair up first; the rest of the other side is then delivered against zero.

**Shares are minted at the claim.** A settlement makes no shares. It adds them to `unclaimedShares`, read with `dealingState()`, and the claim mints them to the receiver as a MINT through the hook. So every rule behaves as it does on any mint, an investor who has become ineligible is refused at its own claim, and no rule judging an investor can block a whole period's settlement. A fund's investor count changes at the claim as well.

**`unclaimedShares` counts in the price.** Those shares have been paid for, so `supply` includes them. A claim lowers `unclaimedShares` and raises `totalSupply()` by the same amount, so `supply` does not move. The roll rounds each controller down, which leaves at most one share unit per controller per period in `unclaimedShares` for good (`testFuzz_TheSumOfClaimsNeverExceedsTheBookAndFallsShortByAtMostOneUnitEach`). 1,000 investors dealing daily for 10 years would leave 3.65 million units against 100 million shares at 12 decimals, under a billionth of a basis point (`test_TheUnclaimableRoundingIsNegligible`). The same rounding leaves at most one asset unit per controller per period in the vault on the redemption side (`testFuzz_TheCashClaimsNeverExceedTheBookAndTheVaultCanPayThem`).

<a id="example"></a>
## One investor, from request to claim

Alice invests in period 2 and leaves in period 3. The asset has 6 decimals, so the shares have 12. Figures below are in whole units and show every digit, so that the rounding is visible. "Assets held" is the vault's balance of the asset. Every figure is the contract's own output for these calls, run against the code at this commit. No limit applies: `type(uint256).max` as `redeemLimit` takes all of a period's redemptions.

**Before.** In period 1 Bob deposited 1,000,000 into an empty vault at a value of 0, and bought 1,000,000 shares. `dealingState()` reads open 2, settled 1, nothing unclaimed.

| # | What happens | Alice's request | `totalSupply()` | `unclaimedShares` | Assets held |
|---|---|---|---|---|---|
| 1 | `requestDeposit(10500e6, alice, alice)`, in period 2. Alice's 10,500 move into the vault. In the same period Dan requests 10,000 and Erin 21,500, and Bob requests to redeem 20,000 shares, which move to the vault's own address. | Deposit side: period 2, pending 10,500 | 1,000,000 | 0 | 42,000 |
| 2 | `closePeriod()`. Period 3 opens. If Alice asked to add to her deposit request now, it would revert, naming period 2. | Unchanged: still pending | 1,000,000 | 0 | 42,000 |
| 3 | `settlePeriod(1050000e6, 500e6, cash, feeRecipient, type(uint256).max)`. The fund is worth 1,050,000 after a fee of 500, a price of 1.05. Worked out below: the escrow is burned, 500 goes to the fee recipient, 20,500.000001 goes to the cash account, and the vault keeps Bob's cash. | Rolls when read: paid 10,500, owed 10,000.000000000476 | 980,000 | 40,000.000000001904 | 20,999.999999 |
| 4 | `deposit(4000e6, alice, alice)`. A partial claim. Alice receives `floor(4,000 × owed / 10,500)` = 3,809.523809523990 shares, as a MINT through the hook. | paid 6,500, owed 6,190.476190476486 | 983,809.523809523990 | 36,190.476190477914 | 20,999.999999 |
| 5 | `deposit(6500e6, alice, alice)`. The rest. It clears exactly: she receives 6,190.476190476486 and holds 10,000.000000000476 shares. | paid 0, owed 0 | 990,000.000000000476 | 30,000.000000001428 | 20,999.999999 |
| 6 | The others claim. Dan receives 9,523.809523809977 shares and Erin 20,476.190476191450. Bob collects his 20,999.999999. Rounding each of the three deposits down left one share unit, which stays unclaimed. | Unchanged | 1,020,000.000000001903 | 0.000000000001 | 0 |
| 7 | `requestRedeem(10000000000000476, alice, alice)`, in period 3. Then the period closes and `settlePeriod(1122000e6, 0, cash, feeRecipient, type(uint256).max)` runs: the fund is worth 1,122,000, a price of 1.10. Her shares go to the vault and are burned at settlement. Nobody deposited in this period, so the cash account pays her whole 10,999.999999. | Redemption side: paid 10,000.000000000476, owed 10,999.999999 | 1,010,000.000000001427 | 0.000000000001 | 10,999.999999 |
| 8 | `redeem(10000000000000476, alice, alice)`. She receives 10,999.999999. She put in 10,500. | paid 0, owed 0 | 1,010,000.000000001427 | 0.000000000001 | 0 |

*Step 3, from the formulas*

```
supply   = 1,000,000 shares + 0 unclaimed                    (raw: 1e18)
deposits = 10,500 + 10,000 + 21,500 = 42,000                 (raw: 42000e6)

shares   = 42000e6 × (1e18 + 1e6) / (1050000e6 + 1)          = 40,000.000000001904 shares
assets   = 20000e12 × (1050000e6 + 1) / (1e18 + 1e6)         = 20,999.999999

out      = assets + fee = 20,999.999999 + 500                = 21,499.999999
net      = deposits − out = 42,000 − 21,499.999999           = 20,500.000001 to the cash account

audit    : held 20,999.999999 ≥ pending 0 + claimable 20,999.999999

Alice    : owed = 10500e6 × 40,000.000000001904 / 42000e6    = 10,000.000000000476 shares
```

At 1.05 an exact price would buy 40,000 shares and pay Bob 21,000. The virtual amounts move the first figure by about two billionths of a share, and rounding down takes one smallest unit from the second. Alice's result in step 8 is short of 11,000 by one smallest unit in the same way. Step 7's `supply` is 1,020,000.000000001904: the 1,000,000 of step 3, less Bob's 20,000, plus the 40,000.000000001904 bought, and the unit left in `unclaimedShares` is still part of it.

<a id="part-fills"></a>
## When a settlement takes only part

A fund can limit how much leaves in one period. `settlePeriod` takes the smaller of the period's redemptions and `redeemLimit`. If that is less than the period's redemptions, every request in the period is filled at the same fraction, and the rest stays in the queue, stays invested and deals at the next period's price. The vault does not know why the limit is what it is. A [`NavDesk`](NavDesk.md#gate) works it out from a level the timelock sets.

### An example at a tenth of the fund

A level of 10%, at a flat price, leaving out the virtual shares. The fund has 1,000,000 shares worth 1,000,000. The first period's deposits are 20,000, holder A asks to redeem 200,000 shares and holder B 100,000, and nobody asks for anything after that. The limit is a tenth of the fund's shares, plus the shares the period's deposits buy, so the level measures what leaves net of what comes in.

| Period | Shares in the fund | Limit | Queue | Filled | A and B get out | Carried |
|---|---|---|---|---|---|---|
| N | 1,000,000 | 100,000 + 20,000 = 120,000 | 300,000 | 40% | 80,000 and 40,000 | 180,000 |
| N+1 | 900,000 | 90,000 | 180,000 | 50% | 60,000 and 30,000 | 90,000 |
| N+2 | 810,000 | 81,000 | 90,000 | 90% | 54,000 and 27,000 | 9,000 |
| N+3 | 729,000 | 72,900 | 9,000 | 100% | 6,000 and 3,000 | 0 |

> **Diagram.** The queue in each of the four periods, split into what was filled and what carried. Period N: a queue of 300,000, with 120,000 filled and 180,000 carried. Period N+1: 180,000, with 90,000 filled and 90,000 carried. Period N+2: 90,000, with 81,000 filled and 9,000 carried. Period N+3: 9,000, all filled.
>
> **The queue clears in four periods.** In period N the cash account funds 100,000: 120,000 paid out less the 20,000 paid in, which is a tenth of the fund. `test_AQueueClearsInFourPeriodsAtATenthOfTheFund` runs this through a desk at a thousandth of the size, in smallest units, and checks the limit, the queue and the shares after each period.

### What a holder sees

The standard's pair of views keeps the two parts apart, and each answers for the controller alone.

| View | After a part fill it shows |
|---|---|
| `pendingRedeemRequest` | The part carried, still in escrow and waiting. |
| `claimableRedeemRequest`, `maxRedeem` | The shares taken and not yet claimed; `maxRedeem` reads 0 when they pay nothing. |
| `maxWithdraw` | The assets those shares pay, at the price of the period that took them. |
| `periodBook(period, isDeposit)` | One side of one period: what its requests gave, carried shares included (`paid`), what that bought (`owed`), and what settlement left for the next period (`carried`). It reads the same for anyone. |
| `PeriodSettled` | `redemptions` is what was asked, carried shares included, and `redeemed` what was taken. |

Pinned by `test_WhenLimited_EveryRequestFillsAtOneFraction`, `test_WhenLimited_OnlyThePartTakenBurnsAndIsPaid`, `test_WhenLimited_TheEventSaysWhatWasAskedAndWhatWasTaken` and `test_WhenLimited_TheBooksSayWhatWasTakenAndWhatCarried`. A limit of zero takes nothing and carries everything (`test_WhenTheLimitIsZero_NothingLeavesAndEverythingCarries`), and a limit at or above the book fills every request (`testFuzz_WhenTheLimitCoversTheBook_EveryRequestIsFilled`). A deposit is always filled whole.

### What happens to the part carried

- **It stays in the fund.** The shares stay in escrow, in `totalSupply()` and in `pendingRedeemShares`, so they count in the next price and share its rise or fall, and a forced transfer cannot reach them (`test_WhenLimited_TheCarriedSharesStayOutOfAForcedTransfersReach`).
- **It deals at the next period's price,** not at the price that filled the first part (`test_TheCarriedPartDealsAtTheNextPeriodsPrice`).
- **It has no priority.** It joins the next period's book, and a new request in that period is filled at the same fraction.
- **A controller that waits loses nothing.** It ends exactly where one that claims each period ends (`test_ADormantControllerEndsWhereAnActiveOneDoes`). Its next read walks the settled periods one at a time. That cost 5,979 gas per gated period when measured, and a Node test holds it below 7,000, so about 5,000 gated periods in a row fit a block of 30 million. The cost falls only on calls about that controller, because a settlement writes one total per side however many are waiting.
- **The rounding stays inside the books.** What each controller carries rounds down, so what is taken from it rounds up, and the parts add up to no more than the next book holds. What is owed rounds down too. Each gated period can leave up to one share unit per controller, less one, in the next book with nobody's name on it (`testFuzz_TheCarriedPartsNeverExceedTheNextBook`, `testFuzz_EveryCarriedPartCanBeHandedBack`, `testFuzz_TheVaultCanPayEveryClaimAfterAGate`). Those units burn when a settlement takes the whole book.

### What a holder cannot do

- **Take a carried part back.** There is no cancel. The agent can hand it back as a plain transfer while its period is open (`test_TheAgentCanHandBackACarriedPartWhileItsPeriodIsOpen`), the settler once that period has closed (`test_OnceTheCarriedPartsPeriodCloses_OnlyTheSettlerCanHandItBack`), and `recoverRedeemRequest` is the path when that is blocked (`test_TheAgentCanRecoverACarriedPart`). The part already taken stays claimable, and `recoverClaimable` leaves a carried part alone (`test_RecoveringClaimableLeavesACarriedPartAlone`).
- **Add to a request while the carried part sits in a closed period.** It reverts with `Gated7540Vault_EarlierRequestUnsettled` (`test_ANewRequestWaitsWhileTheCarriedPartSitsInAClosedPeriod`). In the open period a new request joins it (`test_ANewRequestJoinsACarriedPartInTheOpenPeriod`).
- **Get ahead by being quick.** A request filed early in a period is filled at the same fraction as one filed late. Asking for more than it wants does get a holder a bigger slice, which the limits below come back to.

<a id="escrow"></a>
## The escrow is the vault's own address

Shares waiting for redemption sit in one balance at the vault's address, shared by every controller. The vault is the token itself, and the rules treat that address specially: [`CredentialRule`](CredentialRule.md) does not judge it (a credential there could lapse and stop every redemption), [`FundHoldersRule`](FundHoldersRule.md) does not count it, and [`MinPositionRule`](MinPositionRule.md) exempts it, so an escrow below the minimum is fine (`test_TheVaultNeedsNoCredentialToHoldItsEscrow`, `test_WhenTheVaultIsBlocked_TheEscrowStillWorksEndToEnd`, `test_WhenTheEscrowHoldsLessThanTheMinimum_TheRedeemLifecycleStillRuns`).

- **Forced transfers stop at the booked total.** The vault keeps the total of shares booked to pending redemptions. `forcedTransfer` out of its own address may take only the shares above that, such as shares a holder sent there by mistake, and reverts with `Gated7540Vault_ExceedsSurplus(requested, surplus)` otherwise (`test_WhenTheAgentForcesBookedSharesOutOfTheEscrow_ItReverts`, `test_WhenSharesReachTheEscrowOutsideARequest_TheAgentCanForceOnlyThoseOut`). A carried part stays in that total.
- **No frozen amount on it.** `setFrozenTokens` on the vault's own address reverts with `GatedVault_Unsupported`, since a frozen amount there could not name a controller (`test_WhenTheAgentFreezesTheEscrow_ItReverts`). To hold one controller's redemption, reject or recover it (`test_ToHoldOneRedemption_TheAgentRecoversItAndTheOthersStillSettle`).
- **An investor's count changes at the request.** An owner who escrows its whole balance stops holding the class at once, and if it holds no other class of the fund, the fund's investor count drops before any settlement (`test_WhenARedemptionIsRequested_TheEscrowIsNeverCountedAndTheInvestorLeavesAtTheTransfer`).
- **A gated asset is different.** If the vault's asset is itself a gated token, the vault is an ordinary holder of that asset and needs a credential on its policy (`test_WhenTheAssetIsGated_TheVaultIsAnOrdinaryHolderOfItAndNeedsACredential`).

<a id="reject-recover"></a>
## Reject and recover

A request does not have to end in a claim. There is no cancel for the investor, so a role takes a request back. Which role depends on the period: `AGENT_ROLE` while the request's period is open, and `SETTLER_ROLE` once it has closed, so that a request cannot leave a period being priced unless whoever prices it says so. Once a request is settled in full, nothing is pending and these revert with `Gated7540Vault_NothingPending` (`test_OnceSettled_NothingIsPendingToReject`). A part that carried is still pending, and these act on it. Each runs in [`Gated7540Settlement`](Gated7540Settlement.md), on this vault's storage.

> **Diagram.** The states of one controller's request on each side, and the ways out. Deposit side: Pending, assets waiting in the vault, becomes Claimable when the period is settled, then Claimed through deposit or mint by the controller. From Pending, rejectDepositRequest sends the assets back to the controller. From Claimable, recoverClaimable by the agent mints the shares to a recovery account. Redemption side: Pending, shares in escrow, becomes Claimable as a settlement takes it, and what a settlement does not take stays Pending in the next period; then Claimed through redeem or withdraw. From Pending, rejectRedeemRequest sends the shares back to the controller, and recoverRedeemRequest moves them to a recovery account as FORCED. From Claimable, recoverClaimable by the agent pays the assets to a recovery account.
>
> **Rejects above, recoveries below.** Rejects and `recoverRedeemRequest` act on pending amounts, and their caller depends on the period, as in the table. `recoverClaimable` acts on claimable amounts, and one call clears both sides of a controller (`test_WhenBothSidesAreClaimable_OneRecoveryClearsBoth`). Orange boxes are enforcement actions.

| Function | Who can call | Sends | How it moves |
|---|---|---|---|
| `rejectDepositRequest(controller)` | Period open: `AGENT_ROLE`. Closed: `SETTLER_ROLE`. | The whole pending deposit, to the controller, not to an owner who paid for it. Emits `DepositRequestRejected`. | An asset transfer. No hook. |
| `rejectRedeemRequest(controller)` | The same | The whole pending redemption, a carried part included, to the controller. Emits `RedeemRequestRejected`. | A TRANSFER from the vault through the hook: the whole policy applies. |
| `recoverRedeemRequest(controller, to)` | The same | The whole pending redemption, a carried part included, to `to`. Emits `RedeemRequestRecovered`. | FORCED: passes pause, lockup, the minimum and the fund cap. `to` must still pass the credential check and not be address-frozen. |
| `recoverClaimable(controller, to)` | `AGENT_ROLE`, whatever the period | Everything claimable on both sides, to `to`. Emits `ClaimableRecovered`. | The enforcement probe on `to` (`Gated7540Vault_RecipientNotEligible`), then the shares as a FORCED mint and the assets as a plain transfer. |

- **A rejected request leaves the period's book,** so the period settles without it, whether the reject came before or after the close (`test_WhenARequestIsRejected_ThePeriodSettlesWithoutIt`, `test_WhenRejectedOutOfAClosedPeriod_ThePeriodSettlesWithoutIt`). The controller can then request again (`test_WhenRejected_TheControllerCanRequestAgain`).
- **A redemption reject is an ordinary transfer.** Returning shares to the controller runs the whole policy: pause, an address freeze on the vault itself, the controller's credential, address freeze and minimum, and the fund cap if it would be a new investor. So naming a new investor as controller and having the request rejected fails the same way a direct transfer would (`test_WhenAHolderNamesANewControllerAtAFullCap_TheRejectCannotBypassTheCap`).
- **When a reject cannot go through,** it reverts and the shares stay in escrow (`test_WhenTheControllerWasDeverified_TheRejectRevertsAndTheSharesStayEscrowed`). `recoverRedeemRequest` then moves them to an account that passes the policy (`test_WhenTheControllerWasDeverified_TheAgentRecoversToAVerifiedAccount`).
- **`recoverClaimable` covers what is already settled:** a controller that became ineligible after settlement, a deposit stranded because the fund filled up before the claim (`test_WhenACapFilledAfterSettlement_TheAgentDeliversTheStrandedShares`), a claim that would leave a position below the minimum (`test_WhenAClaimWouldLeaveDust_TheClaimRevertsAndTheAgentCanRecover`), or an `owed` that rounded to nothing (`test_WhenOwedRoundedToNothing_TheAmountsStillClear`). It works while paused and at a full cap. It lowers `unclaimedShares` by what it delivers, because its mint raises `totalSupply()`, so `supply` does not move (`testFuzz_RecoveringClaimableSharesLeavesTheSupplyUnchanged`). A request still pending stays pending (`test_APendingRequestStaysWhenTheClaimableIsRecovered`). With nothing claimable it reverts with `Gated7540Vault_NothingClaimable`.
- **With a desk holding `SETTLER_ROLE`,** the closed-period column runs through it. [`NavDesk`](NavDesk.md)'s `refundRequest` and `recoverRequest` forward to these functions for an `AGENT_ROLE` holder, with no proposal on the table and the period closed for longer than `maxReportAge`.

<a id="eligibility"></a>
## What is checked at each step

A lot can change between a request and its claim, so the vault asks again at the claim. It uses the probes explained on [`GatedVaultBase`](GatedVaultBase.md), pretend movements that run the checks without the write: the mint probe on the controller asks whether it could hold shares at all, and the burn probe, a burn of 0, asks who it is without looking at a balance.

| Step | What is checked | Fails with |
|---|---|---|
| `requestDeposit` | The mint probe on the controller. With the rules a fund lists: not paused, an `ACTIVE` credential the vault's policy accepts, address not frozen, room in the fund if it would be a new investor. Then, if the owner is someone else, the enforcement probe on the owner. | `Gated7540Vault_ControllerNotEligible(reason)`, `GatedVault_ThirdPartyNotEligible(account, reason)` |
| `requestRedeem` | If the controller is someone else, the enforcement probe on the controller. Then the escrow TRANSFER: credential not missing or blocked, address not frozen, not locked up, nothing or at least the minimum left, within the unfrozen balance. | `GatedVault_ThirdPartyNotEligible(account, reason)`, `PolicyGated_TransferRejected(reason)`, `ERC7943InsufficientUnfrozenBalance`, `ERC20InsufficientBalance` |
| `settlePeriod` | The BURN from the vault's own address, if it takes any redemptions. No investor is judged. | `PolicyGated_TransferRejected(reason)` |
| `deposit`, `mint` claims | The mint probe on the controller, then the real MINT to the receiver through the hook, which also judges the minimum position. | `Gated7540Vault_ControllerNotEligible(reason)`, `PolicyGated_TransferRejected(reason)` |
| `redeem`, `withdraw` claims | Not paused. The burn probe on the controller: a credential not missing or blocked (a lapsed one passes), address not frozen, not locked up. Then, if the receiver is someone else, the enforcement probe on the receiver. | `EnforcedPause`, `Gated7540Vault_ControllerNotEligible(reason)`, `GatedVault_ThirdPartyNotEligible(account, reason)` |

- **The controller, not only the receiver.** A claim is refused for an ineligible controller even when it names an eligible receiver (`test_WhenTheControllerIsDeVerifiedAfterADepositIsSettled_TheClaimIsRefused`), and a verified owner cannot open a deposit request for an unverified controller (`test_WhenAVerifiedOwnerRequestsForAnUnverifiedController_ItIsRefused`).
- **Lapsed and blocked are different.** With the real [`CredentialRule`](CredentialRule.md), a lapsed controller can still request a redemption and collect its payout, but cannot request or claim a deposit (`test_WhenTheControllerHasLapsed_ItCanRequestARedemptionButNotADeposit`, `test_WhenTheControllerHasLapsed_ItCanStillClaimItsRedemptionPayout`, `test_WhenASettledDepositIsClaimedAfterTheLapse_ItIsRefusedAndTheAgentRecoversIt`). A blocked controller cannot collect (`test_WhenTheGuardianBlocksTheController_ItCannotCollectItsPayout`).
- **Why the payout probe burns nothing.** The controller's shares went into escrow and were burned at settlement, so it usually holds none (`test_WhenTheControllerHoldsNoShares_ThePayoutIsStillAllowed`). A lockup on the controller holds the payout until it ends (`test_WhenTheControllerIsLockedUp_ThePayoutWaitsForTheUnlock`).
- **The minimum position is judged at the claim.** A request cannot know how many shares it will buy, and the mint probe's amount is above any minimum up to `type(uint128).max`, so a fresh controller is not refused for size (`test_WhenAMinimumIsSet_AFreshControllerCanRequestAndClaimTheMinimum`). If the shares claimed, added to what the receiver holds, come to less than the minimum, the claim reverts with `PolicyGated_TransferRejected(BELOW_MIN_POSITION)` and the claimable amounts stay.
- **`max*` follow the probes.** `maxDeposit` and `maxMint` are the controller's claimable assets and shares, or 0 if the mint probe fails. `maxRedeem` and `maxWithdraw` are its claimable shares and assets, or 0 if the burn probe fails. A request so small that it bought no shares, or a redemption that pays nothing, reads 0 on both views of its side, `maxDeposit` and `maxMint` or `maxRedeem` and `maxWithdraw`, because a claim of it would revert with `Gated7540Vault_ZeroAmount`; `claimableDepositRequest` and `claimableRedeemRequest` still show what is booked, and `recoverClaimable` clears it (`test_WhenARequestBuysNoShares_NothingReadsAsClaimable`, `test_WhenARedemptionPaysNothing_NothingReadsAsClaimable`, `test_WhenOwedRoundedToNothing_TheAmountsStillClear`). A pause makes all four 0. They describe claims, not new requests.

<a id="stops"></a>
## What stops settlement

Each of these reverts `settlePeriod` and leaves the period closed and its requests pending.

- **A pause.** `EnforcedPause` (`test_WhenPaused_SettlingReverts`). `closePeriod` has no pause check, so a period can still close during one.
- **A refused burn, when the settlement takes redemptions.** A freeze on the vault's own address in [`HolderRestrictionRule`](HolderRestrictionRule.md) gives `SENDER_FROZEN` (`test_WhenTheVaultItselfIsFrozen_SettlementStops`), and a lockup there gives `LOCKED`. A period with deposits only, or a limit of zero, has no burn and settles regardless. A vault that is not a class under the fund's installed rule gives `NOT_FUND_CLASS`.
- **The cash account, when money must come from it.** Short of funds or without an allowance: the asset's `ERC20InsufficientBalance` or `ERC20InsufficientAllowance` (`test_WhenTheCashAccountIsShort_SettlementReverts`, `test_WhenTheCashAccountHasNotApproved_SettlementReverts`).
- **The balance audit.** `Gated7540Vault_BalanceAudit(held, owed)`.
- **Figures too large to book.** A `nav`, a supply or a period's total that does not fit 128 bits reverts with `SafeCastOverflowedUintDowncast` (a `nav` of `type(uint256).max` panics first), so one period alone cannot overflow a controller's claim.
- **Nobody calling it.** The contract sets no deadline. With a [`NavDesk`](NavDesk.md), a period stays closed until a price is proposed, accepted and executed, which amounts to a dealing suspension.

While a period waits, the rest carries on. Claims from earlier periods work, requests join the open period unless the controller has one on that side in the closed period, and rejects and recoveries run. No rule judging an investor can stop a settlement, because no investor is judged in it.

<a id="history"></a>
## What `PeriodSettled` lets a reader rebuild

Each settlement emits `PeriodSettled(period, nav, supply, deposits, shares, redemptions, redeemed, assets, fee)`, so the fund's price history is on chain. `test/nodejs/vaults.test.ts` rebuilds it from decoded events.

- **The price:** `nav` over `supply`, and each period's result from the event alone, by the two formulas above.
- **The share count from period to period:** the next event's `supply` is this one's `supply − redeemed + shares`. Claims and `recoverClaimable` move shares between `unclaimedShares` and `totalSupply()` without changing the sum.
- **The cash flow:** `deposits − assets − fee` is what went to the cash account, and a negative figure is what came from it. `fee` is the fee paid.
- **The queue:** `redemptions` is what was asked and `redeemed` what was taken. `redemptions − redeemed` carried, and is part of the next event's `redemptions`.

It does not say who the cash account or the fee recipient was, what report the value came from, or what each investor got. For one investor, take its requests from `DepositRequest` and `RedeemRequest` and apply `floor(pending × shares / deposits)` or `floor(pending × assets / redemptions)`. On the redemption side `floor(pending × (redemptions − redeemed) / redemptions)` of it carries, and is its `pending` in the next period. `deposits` and `redemptions` are net of rejects, so read `DepositRequestRejected`, `RedeemRequestRejected` and `RedeemRequestRecovered` as well. The report behind a value is in the desk's own events.

<a id="pause"></a>
## Pause, entry point by entry point

The guardian's `pause()` stops every share movement except a forced one. The vault's functions feel it in different ways, depending on whether they move shares and how they check.

| Call | While paused | Why |
|---|---|---|
| `requestDeposit` | refused: `Gated7540Vault_ControllerNotEligible(PAUSED)` | The mint probe sees the pause. |
| `requestRedeem` | refused: `PolicyGated_TransferRejected(PAUSED)` | The escrow transfer. |
| `closePeriod` | works | No movement and no pause check. |
| `settlePeriod` | refused: `EnforcedPause()` | OpenZeppelin's `whenNotPaused`. |
| `rejectDepositRequest` | works | An asset transfer only. |
| `rejectRedeemRequest` | refused: `PolicyGated_TransferRejected(PAUSED)` | An ordinary share transfer. The shares stay in escrow. |
| `deposit`, `mint` claims | refused: `Gated7540Vault_ControllerNotEligible(PAUSED)` | The mint probe on the controller, after the caller check. |
| `redeem`, `withdraw` claims | refused: `EnforcedPause()` | `whenNotPaused`, checked first. |
| `recoverRedeemRequest`, `recoverClaimable` | work | Forced moves pass a pause, and the asset leg is not hooked. |
| `forcedTransfer`, `setFrozenTokens`, `setOperator` | work | A forced move, and no movement. |
| `maxDeposit`, `maxMint`, `maxRedeem`, `maxWithdraw` | read 0 | Both probes see the pause. |

<a id="operators"></a>
## Operators

An operator is an account that a controller or owner approved with `setOperator(operator, approved)`, which sets or clears the approval for the caller and emits `OperatorSet(controller, operator, approved)`. The same approval counts in two places.

| The approval is given by | The operator can |
|---|---|
| an owner | Call `requestDeposit` and `requestRedeem` for it. A deposit request still needs the owner's asset allowance for the vault. A redemption request needs no share allowance (`test_WhenAnOperatorRequests_NoAllowanceIsNeeded`). |
| a controller | Claim for it with `deposit`, `mint`, `redeem` and `withdraw`, and choose the receiver (`test_WhenAnApprovedOperatorClaims_ItSucceeds`). |

Operators are full delegates, as ERC-7540 defines them. An operator of an owner can open a request under any controller, its own included, that takes the owner's assets or shares, subject to the third-party check. A test pins this, so that nobody narrows it by accident (`test_WhenAnOperatorRequestsUnderItsOwnController_ItIsAFullDelegatePerErc7540`). An account should approve only operators it would trust with its assets and shares. Without an approval a deposit request reverts with `Gated7540Vault_Unauthorized(caller)`, and a redemption request needs a share allowance, as with an ERC-20 `transferFrom`.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `requestDeposit(assets, controller, owner)` | The owner or its operator | Takes `assets` from the owner into the vault, pending for the controller in the open period. Returns request id 0. Reverts: `Gated7540Vault_ZeroAmount`, `Gated7540Vault_ZeroAddress`, `Gated7540Vault_Unauthorized(caller)`, `Gated7540Vault_ControllerNotEligible(reason)`, `Gated7540Vault_EarlierRequestUnsettled(period)`, `GatedVault_ThirdPartyNotEligible`, and `SafeCastOverflowedUintDowncast` for an amount above 128 bits. |
| `requestRedeem(shares, controller, owner)` | The owner, its operator, or a spender with share allowance | Moves `shares` from the owner into escrow, pending for the controller in the open period. Returns request id 0. Reverts: `Gated7540Vault_ZeroAmount`, `Gated7540Vault_ZeroAddress`, `ERC20InsufficientAllowance`, `Gated7540Vault_EarlierRequestUnsettled(period)`, `GatedVault_ThirdPartyNotEligible`, `PolicyGated_TransferRejected(reason)`, `ERC7943InsufficientUnfrozenBalance`, `ERC20InsufficientBalance`. |
| `closePeriod()` | `SETTLER_ROLE` | Closes the open period and opens the next. Emits `PeriodClosed(period)`. Reverts: `Gated7540Vault_PeriodUnsettled(period)`. |
| `settlePeriod(nav, fee, cash, feeRecipient, redeemLimit)` | `SETTLER_ROLE`, not while paused | Deals the closed period at one price ([above](#settle)), taking at most `redeemLimit` shares from its redemptions ([part fills](#part-fills)). Emits `PeriodSettled`. Reverts: `EnforcedPause`, `Gated7540Vault_NoClosedPeriod`, `Gated7540Vault_BalanceAudit(held, owed)`, `PolicyGated_TransferRejected(reason)`, the asset's errors. |
| `deposit(assets, receiver, controller)`, `mint(shares, receiver, controller)` | The controller or its operator | Claims settled deposit shares: mints them to the receiver. Emits `Deposit(controller, receiver, assets, shares)`. Reverts: `Gated7540Vault_Unauthorized`, `Gated7540Vault_ControllerNotEligible`, `Gated7540Vault_ZeroAmount`, `Gated7540Vault_ExceedsClaimable(requested, claimable)`, `PolicyGated_TransferRejected(reason)`. |
| `deposit(assets, receiver)`, `mint(shares, receiver)` | The caller, as controller | The same claim, for the caller's own request. Reverts: As above, without `Gated7540Vault_Unauthorized`. |
| `redeem(shares, receiver, controller)`, `withdraw(assets, receiver, controller)` | The controller or its operator | Claims settled redemption cash: pays it to the receiver. Emits `Withdraw(caller, receiver, controller, assets, shares)`. Reverts: `EnforcedPause`, `Gated7540Vault_Unauthorized`, `Gated7540Vault_ControllerNotEligible`, `GatedVault_ThirdPartyNotEligible`, `Gated7540Vault_ZeroAmount`, `Gated7540Vault_ExceedsClaimable`. |
| `rejectDepositRequest(controller)`, `rejectRedeemRequest(controller)` | `AGENT_ROLE` while the period is open; `SETTLER_ROLE` once closed | Returns the whole pending request to the controller ([above](#reject-recover)). Emits `DepositRequestRejected(controller, assets)` or `RedeemRequestRejected(controller, shares)`. Reverts: `Gated7540Vault_NothingPending`, and for the redemption `PolicyGated_TransferRejected(reason)`. |
| `recoverRedeemRequest(controller, to)` | The same | Moves the whole pending redemption's shares to `to`, as FORCED. Emits `RedeemRequestRecovered(controller, to, shares, agent)`. Reverts: `Gated7540Vault_ZeroAddress`, `Gated7540Vault_NothingPending`, `PolicyGated_TransferRejected(reason)`. |
| `recoverClaimable(controller, to)` | `AGENT_ROLE` | Delivers everything claimable to `to`: the deposit shares as a forced mint, the redemption assets as a transfer. Emits `ClaimableRecovered(controller, to, assets, shares, agent)`. Reverts: `Gated7540Vault_ZeroAddress`, `Gated7540Vault_RecipientNotEligible(reason)`, `Gated7540Vault_NothingClaimable`. |
| `forcedTransfer(from, to, amount)` | `AGENT_ROLE` | The base token's forced move. From the vault's own address, only shares above the booked total. Reverts: `Gated7540Vault_ExceedsSurplus(requested, surplus)`. |
| `setFrozenTokens(account, amount)` | `AGENT_ROLE` | The base token's frozen amount, on any address except the vault's own. Reverts: `GatedVault_Unsupported`. |
| `setOperator(operator, approved)`, `isOperator(controller, operator)` | Anyone, for itself; anyone (read-only) | Approves or revokes an operator for the caller, and reads an approval. |
| `maxDeposit`, `maxMint`, `maxRedeem`, `maxWithdraw` | Anyone (read-only) | The controller's claimable amounts on that side, or 0 if its probe fails or the side buys or pays nothing. |
| `pendingDepositRequest`, `claimableDepositRequest`, `pendingRedeemRequest`, `claimableRedeemRequest` | Anyone (read-only) | The controller's figures. The request id argument is ignored. |
| `dealingState()` | Anyone (read-only) | The open period, the last settled period, and `unclaimedShares`. A period is closed when `settled + 1` is below `open`. |
| `periodBook(period, isDeposit)` | Anyone (read-only) | One side of one period: `paid`, net of rejects, with carried shares on the redemption side; `owed`, what that bought; `carried`, what settlement left for the next period. |
| `convertToShares`, `convertToAssets`, `totalAssets` | Anyone (read-only) | Indicative values at the last settlement's price. |
| `previewDeposit`, `previewMint`, `previewRedeem`, `previewWithdraw` | Anyone | Revert, as ERC-7540 requires of an asynchronous vault. Reverts: `Gated7540Vault_AsyncOnly`. |
| `share()`, `asset()`, `decimals()` | Anyone (read-only) | The share token (for ERC-7575: the vault itself), the asset, and the asset's decimals plus 6. |
| `SETTLER_ROLE()` | Anyone (read-only) | The role that closes and settles: `keccak256('SETTLER_ROLE')`. |
| `SETTLEMENT_LOGIC()` | Anyone (read-only) | The second contract, [`Gated7540Settlement`](Gated7540Settlement.md), which six functions are handed to. An immutable of the implementation. |
| `mint(address, uint256)`, `burn(address, uint256)` | Anyone, to no effect | The base token's issuer functions ([`GatedVaultBase`](GatedVaultBase.md)). Reverts: `GatedVault_Unsupported`. |
| `initialize` | Once, in the transaction that creates the proxy | Takes the asset, name, symbol, admin, guardian, registry, hook and rules. Sets up the base token, the hook and the rule list, the asset, and the share decimals, and opens period 1. [`ProxyDeployer`](ProxyDeployer.md) makes this call. Reverts: `Gated7540Vault_ZeroAddress` for the asset. |
| `supportsInterface`, `templateId()` | Anyone (read-only) | ERC-165, adding the ERC-7540 operator, deposit and redeem ids and ERC-7575 to what the base token reports; and `keccak256('Gated7540Vault')`, which an upgrade must match. |

`closePeriod`, `settlePeriod`, the two rejects and the two recoveries are named here and run in [`Gated7540Settlement`](Gated7540Settlement.md), on this vault's storage, with its caller. The rest is the base token's: share transfers, `pause` (`GUARDIAN_ROLE`), `unpause` (the main timelock or the recovery timelock), roles, upgrades, `multicall` and the pre-flights. See [`PolicyGatedERC20Upgradeable`](PolicyGatedERC20Upgradeable.md). Other contracts ask this vault's role table too: `NavDesk` for `REPORTER_ROLE` and `CHECKER_ROLE`, and `Portfolio` for `ALLOCATOR_ROLE`. The two remaining events are `DepositRequest(controller, owner, 0, sender, assets)` and `RedeemRequest(controller, owner, 0, sender, shares)`, and every share movement also emits the token's `Transfer`.

<a id="why"></a>
## Why it is built this way

- **Periods, with one price.** A fund deals at a value struck after a cut-off, so with an honest report nobody can choose to buy or sell knowing the price. Pricing a period rather than each request gives everyone in it the same price (`test_TwoInvestorsInOnePeriodGetOnePrice`) and keeps the gas of a settlement flat.
- **Not OpenZeppelin's ERC-4626.** It would have to override almost all of it and claim to be a synchronous vault while its previews revert. ERC-7540 is already request and claim, so the vault implements it directly and takes the base token from [`PolicyGatedERC20Upgradeable`](PolicyGatedERC20Upgradeable.md).
- **The price in the form a 4626 uses.** The virtual amounts stop a donation inflating the price, and the extra digits keep them from moving an honest one. There is no separate first-deposit case to get wrong.
- **Netting.** Subscriptions paying redemptions means less money moving to and from custody, and a settlement that needs no cash at all when the two match.
- **Shares at the claim.** A settlement that minted to each investor would cost more with each one, and one ineligible investor could stop it.
- **A fraction, not first come.** A cap on the shares entering the escrow would let the fastest holders out in full and refuse everyone else with no place in a queue, which rewards the race a limit exists to stop. A fraction of the book treats every request in the period alike, and the standard's two views keep the filled part and the waiting part apart.
- **The vault is told how much, and not why.** `settlePeriod` takes a number and has no policy of its own, so a later desk can apply another policy with the vault unchanged.
- **Two contracts.** One contract's code is limited to 24,576 bytes, and this vault with part fills is above that. [The second contract's page](Gated7540Settlement.md) says what fixes it in place and what it costs.
- **No cancel, so a check at the door.** The investor cannot take a deposit request back, so the vault refuses a request whose controller could not hold the shares at all, rather than take assets it could not turn into shares.
- **Rejects follow the policy, recoveries are enforcement.** A redemption reject is an ordinary transfer, so it cannot carry shares past a pause or a full fund. The recoveries are forced moves, and the account they deliver to must still pass.
- **The settler on a closed period.** The value being struck assumes a known list of requests. Taking one out needs the role that prices the period, which with a desk also means the conditions the desk sets.
- **Attested code only.** The vault is a proxy: a small contract that keeps the address and the balances and runs shared code, its implementation. An upgrade must target an implementation that the [`PolicyRegistry`](PolicyRegistry.md) attests, meaning a holder of the registry's `ATTESTER_ROLE` recorded its code hash, and that reports the same template id. Tests show the vault refusing attested `IntentToken` and `Gated4626Vault` implementations with `Templated_WrongTemplate`; an implementation that is not attested is refused before that, with `PolicyGated_NotAttested`. There is no `receive` function. The one payable function is the inherited `upgradeToAndCall`, which only `UPGRADER_ROLE` can call and which refuses ETH when the upgrade carries no call.

<a id="limits"></a>
## What it does not do

- **It does not check the price or the limit.** Whoever holds `SETTLER_ROLE` sets any `nav`, any fee and any `redeemLimit`, names the addresses that receive net inflow and the fee, and can pull net outflow from any account with an allowance for the vault, an investor's included. The vault compares that with nothing. So the role belongs to a [`NavDesk`](NavDesk.md), where a different person checks every price. A deployment profile with no desk gives the role to a plain account, which sets any price alone; the profile's own comment says that is for a test stack.
- **It does not let an investor set a price limit or leave a queue.** A request carries no minimum price and no expiry, and an investor cannot cancel one. A controller with a request in a closed period waits for it. Another account can file a request under a controller that passes the token's policy, for as little as one unit: on the deposit side it pays and must pass the policy itself, on the redeem side it gives up shares. Once that period has closed the controller's own requests on that side revert with `Gated7540Vault_EarlierRequestUnsettled` until the period settles or the request is taken back.
- **It does not force a settlement.** Nothing on the vault makes a closed period settle. An investor's way out of a period that stays closed is a role acting on its behalf.
- **It does not hold a place in the fund.** The investor cap does not reserve room for an open request. A full `requestRedeem` takes the investor out of the count while the shares wait unburned, and `requestDeposit` reserves nothing. If the fund fills up meanwhile, a reject that returns the shares, or a deposit claim, is refused with `MAX_HOLDERS`. The agent's recovery still works, and delivering to an account that holds nothing puts the count above the cap until investors leave (`test_WhenARejectedRedemptionReturnsSharesToAnInvestorWhoWasReplaced_TheFundCapAppliesAndRecoveryIsCounted`). The mitigation is operational: rejecting deposit requests near the cap, and a monitor on `Fund.holderCount()` against `Fund.holderCap()`. A queued investor stays out of the count for as long as the queue lasts, and is counted again if its shares are handed back (`test_AQueuedInvestorIsOutOfTheCountUntilHandedBack`).
- **It does not tell a real request from a large one.** A holder who expects a limit can ask for more than it wants, to get a bigger slice. Only a role can hand back a carried part, which is the deterrent, and not a complete one.
- **It does not return a rejected deposit to the payer.** The assets go to the controller, which matters when an owner paid for someone else (`test_WhenADepositIsRejected_TheAssetsReturnToTheController`).
- **It does not take out assets sent to it by mistake.** The audit only requires the vault to hold at least what it owes. No function moves the surplus, and it counts for nothing in a settlement. Shares sent by mistake are different: `forcedTransfer` takes those.
- **It does not say what the money is doing.** `convertToShares`, `convertToAssets` and `totalAssets()` are at the last settled price, and the vault does not hold the invested money. Where the cash account sends it is outside this contract.
- **It does not keep running totals within 128 bits.** One controller's `paid` or `owed`, added up over the periods it leaves unclaimed, can pass 128 bits (about 3.4e38 units), which makes reads and claims on that side and `recoverClaimable` for that controller revert, and a settlement can take the supply past 128 bits, after which every later settlement reverts.
- **It is not a synchronous vault.** The previews revert, so an integrator written for plain ERC-4626 needs the request and claim path. `supportsInterface` reports the ERC-7540 and ERC-7575 ids and not the plain ERC-4626 id.

<a id="connected"></a>
## Connected to

- [GatedVaultBase](GatedVaultBase.md): The third-party check, the probes and the reverting issuer functions.
- [Gated7540Settlement](Gated7540Settlement.md): The second contract: closing, settling, rejecting and recovering run there, on this vault's storage.
- [Gated7540Common](Gated7540Common.md): The storage and the request roll the two contracts share.
- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): The base token the shares are: roles, freezes, pause, forced moves and the hook path.
- [NavDesk](NavDesk.md): Holds `SETTLER_ROLE`, turns a reported value into an approved price, and works out the limit from the level it holds.
- [FeeModel](FeeModel.md): The fee a desk passes to `settlePeriod`.
- [Portfolio](Portfolio.md): With one plugged into the desk, the cash account and the on-chain part of the value.
- [SignedEntry](SignedEntry.md): Files a deposit request from an investor's two signed messages, the entry and the cash, with a relayer paying the gas.
- [ComplianceHook](ComplianceHook.md): Runs the vault's rule list on every share movement and probe.
- [CredentialRule](CredentialRule.md): Who may become a controller, who may still collect, and why the escrow needs no credential.
- [FundHoldersRule](FundHoldersRule.md): The fund-wide investor cap that can strand a settled deposit.
- [Gated4626Vault](Gated4626Vault.md): The instant vault, where a deposit settles in one transaction.
- [Where the money sits](../money.md): Every place an asset can be, across both vaults.
- [Who can do what](../roles.md): The settler, the agent, the guardian and the timelocks.

<a id="source"></a>
## Source and tests

- Contract: `contracts/vaults/Gated7540Vault.sol`, with `Gated7540Settlement.sol` and `Gated7540Common.sol`, interface `IGated7540Vault.sol`, and the standard's interfaces `IERC7540Deposit.sol`, `IERC7540Redeem.sol`, `IERC7540Operator.sol` and `IERC7575.sol`
- Tests: `Gated7540Vault.t.sol` (periods, netting, the price, claims and rounding, the escrow, rejects and recoveries with a mocked hook; integration with the real holder-restriction and fund rules and a minimum position; invariants on what the vault holds and owes), `Gated7540Settlement.t.sol` (the hand-off, part fills, the walk and rounding), `GatedVaultBase.t.sol` (third parties, and the escrow behind the real `CredentialRule`), `CredentialRuleVaults.t.sol` (lapsed and blocked controllers), `FundIntegration.t.sol` (the escrow and the fund's investor count, a deposit stranded by a full fund), `NavDesk.t.sol` (the desk driving a real vault), and `test/nodejs/vaults.test.ts` (request, settle and claim from TypeScript, the cost of a walk, and the price history rebuilt from `PeriodSettled` events)

---

Describes the contracts at commit `4a906cc` on `main`.
