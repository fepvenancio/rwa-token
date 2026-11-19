[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Vaults

# NavDesk

Sets the price a request-and-claim vault deals at. Once a period has ended, one account proposes a value, a different account accepts it, and after a cooldown anyone can put it through. If no price can be approved, dealing waits and the requests can go back. It also holds the fund's redemption gate, if the fund has one.

- **contracts/nav/NavDesk.sol**
- immutable code, **not a proxy**
- one per **Gated7540Vault**
- holds the vault's **SETTLER_ROLE**
- no role table: it asks the vault
- not attested: it acts by the role it holds

<a id="in-one-minute"></a>

> ### In one minute
>
> A [Gated7540Vault](Gated7540Vault.md) deals in periods: requests collect during a period, then all of them deal at one price, worked out from the fund's net asset value (NAV). The vault takes whatever value its `SETTLER_ROLE` holder gives it, so that role goes to this contract, which puts a process around the number.
>
> The cut-off comes on a schedule, not when someone decides. One account proposes a value, with a stated date that may not be before requests closed, and a different one accepts it, the numbers are fixed at the proposal, and a cooldown gives the guardian time to cancel. If nothing can be approved, the period stays closed and nobody deals, and after a while the agent can send the requests back.
>
> Money does not pass through the desk, and it keeps no list of roles: it asks the vault each time. A price is still a claim. The contract proves which report was used, not that the money exists.
>
> The desk can also hold a [redemption gate](#gate): the most of the fund that may leave in one period, net of what comes in. The timelock sets the level, the desk works out a limit from it when a price is proposed, and the limit is frozen with the price. Past it, every request is filled at the same fraction and the rest waits for the next period.

<a id="how"></a>
## One period, from cut-off to settlement

Four calls take a period from open to settled. The two that carry judgement need a role. The two that carry out what the schedule or the approval has already decided can be made by anyone, so a dealing cycle does not wait for one operator.

> **Diagram.** The cycle of one period. A period is open and requests join it. Anyone calls closePeriod once periodLength has passed, and the period is closed with nothing on the table while the next one takes requests. A holder of REPORTER_ROLE calls propose and the numbers are frozen, with the cooldown clock starting at proposedAt. A holder of CHECKER_ROLE who is not the proposer calls accept. Anyone calls execute once the cooldown is over and the report is not stale, and the period settles at one price through settlePeriod. If the vault reverts, the whole call is undone and the proposal stays on the table. From either the proposed or the accepted state, a holder of GUARDIAN_ROLE or CHECKER_ROLE can call cancel, which goes back to a closed period with nothing on the table, and the reporter can propose again. If nothing is approved, dealing waits, and after lastCutoff plus maxReportAge with nothing on the table a holder of AGENT_ROLE can call refundRequest and recoverRequest, one controller at a time.
>
> **One period through the desk.** Anyone can close and execute. The two middle steps need a role on the vault. A cancel returns to a closed period with nothing on the table, and a period left there becomes a dealing suspension, where the box at top right is what the agent can do.

1. **Cut-off.** Anyone can call `closePeriod()` once `periodLength` has passed since `lastCutoff`. Before that it reverts with `NavDesk_PeriodNotOver`. It records the current time as `lastCutoff`, emits `CutOff` and closes the vault's open period, which opens the next, so requests made from then on join the next period. The vault reverts with `Gated7540Vault_PeriodUnsettled` while an earlier closed period is unsettled, so at most one period is closed at a time.
2. **Proposal.** A holder of the vault's `REPORTER_ROLE` calls `propose(_reported, _reportHash, _asOf, _moves)`. Only one proposal can be on the table (`NavDesk_ProposalPending`), and there must be a closed period to price (`NavDesk_NoClosedPeriod`). The desk works out the value, the fee and the [redemption limit](#gate), and freezes everything in a `Proposal`. It emits `ProposalMade` with the reported part, the on-chain part, the value, the fee, the report hash, `asOf` and the limit.
3. **Acceptance.** A holder of `CHECKER_ROLE` calls `accept(_proposalHash)`. It reverts for the account that proposed (`NavDesk_SelfAccept`), for a hash that is not the one on the table (`NavDesk_ProposalMismatch`), with nothing on the table (`NavDesk_NoProposal`) and on a second acceptance (`NavDesk_AcceptanceWrong`). It emits `ProposalAccepted`.
4. **Cooldown.** `execute` reverts until `proposedAt + cooldown`. The clock starts at the proposal, not at the acceptance. Until execution, a holder of `GUARDIAN_ROLE` or `CHECKER_ROLE` can call `cancel()`, accepted or not. That deletes the proposal, emits `ProposalCancelled` and leaves the mark and the fee clocks where they were. The reporter can then propose again, and the approval does not carry over (`test_AnApprovalDoesNotCarryOverToAReplacement`).
5. **Execution.** Anyone can call `execute()` once the proposal is accepted (`NavDesk_AcceptanceWrong` before that), the cooldown is over (`NavDesk_TooEarly`), the report is not too old (`NavDesk_StaleReport`) and the period it priced is still the closed one (`NavDesk_WrongPeriod(proposed, closed)`, or `NavDesk_NoClosedPeriod` with none closed). The desk deletes the proposal. If the proposal was made with a fee model, the desk stores its `mark`, `markMovedAt` and `paidSinceMark` and sets `lastFeeAt` to `proposedAt`. Then it emits `ProposalExecuted` and calls the vault's `settlePeriod` with the frozen numbers. If that call reverts, all of this is undone and the proposal stays on the table. That happens, for example, when the vault is paused (`EnforcedPause`), when the cash account is short, and when the desk has lost its role (`test_WhenTheDeskLosesTheRole_ExecutionReverts`).

<a id="value"></a>
## How the value is worked out

The value is fixed at `propose`, from three parts:

*propose*

```
gross = _reported + pricedValue()      // pricedValue() is 0 with no portfolio; gross is 0 under 1e6 share units
fee   = the fee model's quote on gross // 0 with no model, and 0 under 1e6 share units
nav   = gross - fee
```

- **The reported part** is one number for everything not priced on-chain, in the asset's units. Its breakdown is in the off-chain NAV pack, and `_reportHash` is the hash of that pack. It leaves out what the vault itself holds, because that money belongs to investors with open requests and claims.
- **The on-chain part** comes from the plugged [Portfolio](Portfolio.md): its `pricedValue()` is its idle money plus every priced adapter. Reported adapters are left out of it, because their value is in the report. A plugged portfolio is also the cash account. With none, `custodianAccount` is the cash account, and with neither `propose` reverts with `NavDesk_NoCashAccount`.
- **The fee** comes from the plugged [FeeModel](FeeModel.md), quoted on the gross value with all shares (unclaimed ones included), the `mark`, two ages and `paidSinceMark`, the performance fee paid since the mark last moved. A period that ends inside a soft hurdle's catch-up leaves the mark where it was and carries what it charged, so the period that completes the catch-up charges what one period would have (`test_APeriodInsideTheBandLeavesTheMarkAndCarriesWhatItCharged`, `test_TheNextPeriodChargesWhatOnePeriodWould`). With no shares, or fewer than `1e6` share units, there is no fee, the mark restarts at par, `paidSinceMark` returns to zero and both clocks restart when the proposal executes (`test_WhenEveryoneHasLeftWhatWasPaidRestarts`), so the first investors pay neither on their principal nor for time before they arrived (`test_WithNoSharesThereIsNoFeeAndTheClocksRestart`, `test_TheMarkRestartsAtParWhenEveryoneHasLeft`).
- **No shares, no value.** Unclaimed shares count as shares (`test_UnclaimedSharesStillHaveAValue`). Fewer than `1e6` of them, claimed or not, count as none: one unit of the asset buys `1e6` share units at par, so between them they own less than that unit, and on a few of them the least value that could be proposed would price them up to a million times above par and move the mark where no later gain reaches it. Then nothing is anyone's (`test_DustLeftByTheClaimsStrikesAtParAndTheFeeStillWorks`, `test_FewerThanAMillionShareUnitsCountAsNoShares`, `testFuzz_WhateverIsReportedOnDustStrikesAtPar`). The gross value is zero whatever is reported or sits in the portfolio, so the period strikes at par, or for as little as about half par when the dust is close to `1e6` units. The desk does not refuse to propose, as a stranger's donation to the portfolio could then stop the period (`test_ADonationToThePortfolioWithNoSharesStrikesAtPar`). What is left goes to the investors who come in, in the next price. `ProposalMade` still shows what was reported and priced.
- **Zero.** A value of zero reverts with `NavDesk_ZeroNav` while `1e6` share units or more exist, unclaimed ones included (`test_AMillionShareUnitsStillHaveAValue`). Below that it is accepted (`test_AValueOfZeroIsFineWithNoShares`).

The vault then deals the whole period at that value in one transaction. With `supply` being `totalSupply() + unclaimedShares`, all deposits buy `deposits × (supply + 1e6) / (nav + 1)` shares and the redemptions it takes receive `redeemed × (nav + 1) / (supply + 1e6)` assets, each rounded down. Only the difference between deposits and what must be paid out moves to or from the cash account. The [Gated7540Vault](Gated7540Vault.md) page has the rest.

### The conditions on time and on moves

| Name | The rule | If it fails |
|---|---|---|
| `asOf` | When the reporter says the report was struck. Checked at `propose`: not before `lastCutoff` and not in the future. The contract checks this stated date, not when the value was worked out. Exactly at the cut-off is accepted (`test_AReportAtExactlyTheCutOffIsAccepted`). | `NavDesk_ReportOutOfWindow` |
| `moves` | Checked at `propose`: it must equal the portfolio's `moves()`, the count of times money has crossed between the portfolio and an adapter, and 0 with no portfolio. A proposal that states the count its report was struck against therefore reverts if `moves()` has changed since, so an allocation or deallocation after the valuation does not count twice (`test_AMoveAfterTheValuationCannotCountTwice`). The contract cannot tell whether the stated count is the one the report used. | `NavDesk_MovesChanged(_expected, _actual)` |
| `priceFresh()` | Checked at `propose`, with a portfolio: every priced adapter must be readable, because one that cannot be read counts as zero in `pricedValue()`. | `NavDesk_PriceNotFresh` |
| `cooldown` | Between `MIN_COOLDOWN` (1 hour) and `MAX_COOLDOWN` (3 days) when set. `execute` needs the current time at or after `proposedAt + cooldown`. | `NavDesk_InvalidCooldown(_cooldown)` when set, `NavDesk_TooEarly` at `execute` |
| `maxReportAge` | Not zero and not below `cooldown` when set. `execute` needs the current time at or before `asOf + maxReportAge`, so the age is measured from the report, not from the proposal (`test_AReportAtExactlyTheMaximumAgePasses`). | `NavDesk_ZeroValue` or `NavDesk_ReportAgeBelowCooldown(_maxReportAge, _cooldown)` when set, `NavDesk_StaleReport` at `execute` |
| `periodLength` | Not zero when set. The next cut-off is allowed from `lastCutoff + periodLength`. | `NavDesk_ZeroValue` when set, `NavDesk_PeriodNotOver` at `closePeriod` |

> **Diagram.** The times of one proposal on a line. The cut-off, lastCutoff, comes first. asOf falls between lastCutoff and proposedAt, and outside that stretch propose reverts with NavDesk_ReportOutOfWindow. From proposedAt until proposedAt plus cooldown, execute reverts with NavDesk_TooEarly. From then until asOf plus maxReportAge, execute may run. After that it reverts with NavDesk_StaleReport.
>
> **The times of one proposal.** `accept` and `cancel` can land anywhere from `proposedAt` until `execute` runs. An older `asOf` moves the right-hand end of the window to the left. If `asOf + maxReportAge` falls before `proposedAt + cooldown` the window is empty, and the proposal has to be cancelled.

<a id="gate"></a>
## The redemption gate

A fund can limit how much leaves in one period. The level is `redemptionGate`, in basis points of all shares, unclaimed ones included. It starts at zero, which is off: a settlement takes every redemption (`test_ItStartsOffAndTakesEverything`). `setRedemptionGate(_gateBps)` takes the vault's `DEFAULT_ADMIN_ROLE`, which after hand-over is the timelock, so a change is delayed and public. It emits `RedemptionGateSet(_gateBps)` and refuses more than 10,000, the whole fund, with `NavDesk_InvalidGate(_gateBps)` (`test_TheLevelStopsAtTheWholeFund`). The guardian cannot set it (`test_TheGuardianCannotSetTheLevel`).

The vault knows nothing of the level. `propose` works out a limit in shares, and `execute` passes it to `settlePeriod`. Past that limit the vault fills every request at one fraction and carries the rest. [What a holder sees](Gated7540Vault.md#part-fills) is on the vault's page, with a worked example that `test_AQueueClearsInFourPeriodsAtATenthOfTheFund` runs through this desk.

*propose, with a level above zero*

```
limit = supply × level / 10,000  +  deposits × (supply + 1e6) / (nav + 1)   // each part rounded down

// supply: all shares, unclaimed ones included
// deposits: what the closed period's deposits paid, from the vault's periodBook
// with the level at zero, the limit is type(uint256).max
```

- **It is net of deposits.** The second part is exactly the shares the period's deposits buy at this price, so real money coming in pays the exits it allows, and the level measures what leaves less what comes in. At 10% of 1,000,000 shares with 20,000 of deposits at par, the limit is 120,000. If the redemptions reach it, the cash account funds 100,000: a tenth of the fund. Measured in shares at one price, what leaves on net never passes the level (`testFuzz_NoMoreThanTheLevelLeavesOnNet`).
- **The reporter has no say.** `propose` takes no limit, so a reporter and a checker cannot shut exits while taking deposits, or open them wider than the level. The value it reports does enter the second part, as the price the deposits buy at, which is the price everyone in the period deals at.
- **It applies by itself.** Nobody decides to invoke it. When a period's redemptions are below the limit they are filled in full (`test_WhenTheRedemptionsAreBelowTheLimit_TheyAreFilled`), and when they pass it they are cut back.
- **It is frozen with the price.** The limit is in the `Proposal`. A level changed inside the cooldown moves nothing on the table, and the next proposal reads the new level (`test_ALevelChangedInsideTheCooldownMovesNothingOnTheTable`). Nothing else moves the figures it came from while a proposal is on the table: the closed book changes only through `refundRequest` and `recoverRequest`, which need an empty table, and a claim or a recovery leaves the number of shares the same.
- **It is in the hash.** `hashOf` covers `redeemLimit` and `ProposalMade` carries it, so a checker approves that limit, and an approval of another is refused (`test_TheHashCoversTheLimit`, `test_AnApprovalOfAnotherLimitIsRefused`).
- **A replacement keeps it.** `adopt` copies the level from the desk it replaces, because a replacement that forgot it would lift a gate with nobody deciding to (`test_AReplacementDeskKeepsTheLevel`). The timelock can change it afterwards.
- **A fund winding down sets it to zero.** The level is a share of what remains. When everyone is leaving, the queue shrinks by the same fraction each period and does not finish. Set to zero, the next price takes the whole queue. A level of zero means no limit. It does not mean that nothing may leave.

<a id="frozen"></a>
## What a proposal freezes, and what the hash covers

`propose` writes these fields once. Until `execute` or `cancel`, only `acceptedAt` changes. A later change of settings, fee model, redemption gate or cash account does not reach them, because a timelock change can land inside the cooldown (`test_ASettingChangedInTheCooldownDoesNotChangeTheProposal`, `test_TheFrozenFeeIsTheFeePaid`).

| Field of `Proposal` | What it is | In the hash |
|---|---|---|
| `period` | The period it prices; 0 with nothing on the table | yes |
| `nav` | The net asset value | yes |
| `fee` | The fee, in assets | yes |
| `mark` | The high-water mark after this price, in assets per 1e18 share units | yes |
| `markMovedAt` | When the mark last moved, as of this price | yes |
| `paidSinceMark` | The performance fee paid since the mark last moved, after this price, in assets per 1e18 share units; a soft hurdle's catch-up counts it | yes |
| `reportHash` | The hash of the off-chain NAV pack | yes |
| `cash` | The cash account: receives net inflow and funds net outflow | yes |
| `feeRecipient` | Who the fee goes to, read from the fee model at the proposal | yes |
| `asOf` | When the reporter says the report was struck; the report's age runs from here | yes |
| `redeemLimit` | The most shares this period may take from its redemptions; `type(uint256).max` with the gate off | yes |
| `proposedAt` | When it was proposed; the cooldown runs from here | no |
| `proposer` | The reporter, who may not also accept it | no |
| `acceptedAt` | When the checker accepted it; 0 until then | no |

`hashOf(_proposal)` is `keccak256(abi.encode(...))` over the eleven fields marked yes. `test_TheHashCoversEveryFrozenField` changes nine in turn, `test_TheProposalHashCoversWhatWasPaid` changes `paidSinceMark` and `test_TheHashCoversTheLimit` changes `redeemLimit`. `accept` takes that hash, so an approval given for one set of numbers cannot land on another. The reported and on-chain parts are not stored in the proposal: they are in the `ProposalMade` event.

**The report's date is in the hash.** A proposal cancelled and made again with the same numbers and a later `asOf` carries another hash, so an acceptance sent for the first cannot land on the second (`test_AnApprovalDoesNotCarryOverToALaterReportWithTheSameNumbers`). With the same `asOf` too, the hash is the same, and so is everything it approves.

**Not frozen.** `cooldown` and `maxReportAge` are not part of a proposal. `execute` reads them when it runs, so a settings change inside the cooldown does reach a proposal on the table: a shorter cooldown lets it run sooner, and a lower `maxReportAge` can make it stale. No test in the repository pins these two.

<a id="stuck"></a>
## When nothing can be approved

If no price gets through, the period stays closed. That is a dealing suspension: nobody trades at a wrong price. It can come from a report that does not arrive, a checker who refuses, a portfolio price that cannot be read, a total loss, a pause or short cash.

While it lasts, `closePeriod` reverts because the vault allows one closed period at a time, later requests collect in the open period, and a controller with a request in the closed period cannot add to that side until it is settled or released (`Gated7540Vault_EarlierRequestUnsettled`).

Once the current time is past `lastCutoff + maxReportAge` and no proposal is on the table, a holder of the vault's `AGENT_ROLE` can take requests out of the closed period, one controller at a time. Earlier, or with no closed period, the call reverts with `NavDesk_NotStuck`. With a proposal on the table it reverts with `NavDesk_ProposalPending`. Requiring an empty table means the agent alone cannot release against a price on the table. A checker or the guardian who cancels first empties it, and the cancelled price stays public in `ProposalMade`, so those roles acting together can release a controller against a known price.

| Call | What the vault does | During a pause |
|---|---|---|
| `refundRequest(_controller, true)` | `rejectDepositRequest`: the whole pending deposit goes back to the controller. | Works (`test_WhilePaused_ADepositIsRefundedAndARedemptionRecovered`) |
| `refundRequest(_controller, false)` | `rejectRedeemRequest`: the escrowed shares go back to the controller as a plain TRANSFER, so the token's rules apply, and a refusal reverts the call. | Reverts, like any plain transfer |
| `recoverRequest(_controller, _to)` | `recoverRedeemRequest`: the escrowed shares move to `_to` as FORCED. The rules still judge `_to` as a receiver. This is the path when a refund is blocked. | Works |

Each emits `RequestReleased(_controller, _isDeposit, _to)`. The desk can make these calls because it holds `SETTLER_ROLE`, which is what the vault asks for on a request in a closed period. A request in the open period is out of its reach, since the vault asks for `AGENT_ROLE` there. The agent rejects that one on the vault directly (`test_ARequestInTheOpenPeriodIsNotTheDesks`).

A release does not settle the period. It stays closed until a price is approved for it, even with nothing left in its book. After a total loss no price can be proposed while `1e6` share units or more exist, and every request in the closed period can still go back (`test_AfterATotalLoss_EveryRequestIsRefundable`). The contracts have no wind-down path beyond that.

<a id="replace"></a>
## Replacing a desk

The desk's code cannot be upgraded. To change it, the vault's `DEFAULT_ADMIN_ROLE` (the timelock, after hand-over) runs one batch with a successor desk built for the same vault:

1. **Move the role.** Revoke `SETTLER_ROLE` from the outgoing desk and grant it to the successor, on the vault.
2. **Take over the clocks and the level.** Call `adopt(_oldDesk)` on the successor. It runs once and refuses a desk that names another vault or has a proposal on the table, and refuses while the successor has a proposal of its own, which executed later would write its mark over the adopted one (`NavDesk_CannotAdopt`, `test_ThisDeskWithAProposalPendingCannotAdopt`). It reads `lastCutoff` from the outgoing desk at that moment, `mark`, `markMovedAt` and `paidSinceMark` if that desk has a mark, and `lastFeeAt` if it has a fee model, so nothing is charged twice however long the timelock took (`test_ADeskThatAdoptsChargesNothingTwice`). It also copies `redemptionGate`, over any level set on the successor before it, and emits `RedemptionGateSet` and `DeskAdopted`.
3. **Set what it does not copy.** The schedule, the portfolio and the custodian account come from the successor's constructor and `setSettings`, and the fee model from `setFeeModel`.

**Plug the fee model in the same batch.** A first plug in the block of `adopt`, before or after it, keeps the fee clock `adopt` took. A first plug in a later operation restarts `lastFeeAt`, as the successor dealt with no model in between. The table has what each order leaves.

| Outgoing desk | Order in the batch | Result on the successor |
|---|---|---|
| Has a fee model | `setFeeModel`, then `adopt` | The adopted values overwrite the ones the plug set. The mark and both clocks carry on (`test_PluggingThenAdoptingTakesTheOldDesksClocks`). |
| Has a fee model | `adopt`, then `setFeeModel` | The mark and both clocks carry on, as in the other order (`test_AdoptingThenPluggingTakesTheOldDesksClocks`). |
| Has a fee model | `adopt`, then `setFeeModel` in a later operation | The mark and its clock carry on, and `lastFeeAt` restarts at the plug, so the time the successor dealt with no model is not charged (`test_APlugAfterTheAdoptingBatchStartsTheFeeClock`). |
| Never had a fee model | `setFeeModel`, then `adopt` | The plug's mark and clocks stay, as that desk has none to pass on (`test_AdoptingFromADeskThatNeverChargedKeepsThePlug`). |
| Had a fee model, taken off | `setFeeModel`, then `adopt` | The mark and its clock carry on, so no gain pays twice. `lastFeeAt` stays at the plug, so no time without a model is charged (`test_AdoptingFromADeskWithItsModelOffTakesTheMarkAndNotTheFeeClock`). |
| Had a fee model, taken off | `adopt`, then `setFeeModel` | The mark carries on, and `lastFeeAt` starts at the plug (`test_AdoptingFromADeskWithItsModelOffThenPluggingStartsTheFeeClock`). |

<a id="functions"></a>
## What it can do

Signatures use the parameter names of `INavDesk`. Every role is asked of the vault at call time, and a caller without it gets `NavDesk_Unauthorized(_caller)`.

| Function | Who can call | What it does |
|---|---|---|
| `closePeriod()` | Anyone, once `periodLength` has passed | Cuts off the open period on the vault. Emits `CutOff(_at)`. |
| `propose(_reported, _reportHash, _asOf, _moves)` | `REPORTER_ROLE` | Puts a price on the table. Emits `ProposalMade`. |
| `accept(_proposalHash)` | `CHECKER_ROLE`, not the proposer | Approves the proposal on the table, by its hash. Emits `ProposalAccepted`. |
| `cancel()` | `GUARDIAN_ROLE` or `CHECKER_ROLE` | Deletes the proposal on the table. Emits `ProposalCancelled`. |
| `execute()` | Anyone, after acceptance and the cooldown | Settles the period at the frozen numbers, if it is still the closed one (`NavDesk_WrongPeriod(proposed, closed)`). Emits `ProposalExecuted`. |
| `refundRequest(_controller, _isDeposit)` | `AGENT_ROLE`, in a stuck period | Forwards the vault's reject of one controller's pending request. Emits `RequestReleased`. |
| `recoverRequest(_controller, _to)` | `AGENT_ROLE`, in a stuck period | Forwards the vault's recovery of one controller's pending redemption. Emits `RequestReleased`. |
| `setSettings(_portfolio, _custodianAccount, _periodLength, _cooldown, _maxReportAge)` | `DEFAULT_ADMIN_ROLE` | Changes the settings, with the bounds above. A portfolio must be attested as `PORTFOLIO` in the registry the vault names and must name this vault and its asset (`NavDesk_PortfolioRefused`). Emits `SettingsChanged`. |
| `setFeeModel(_feeModel)` | `DEFAULT_ADMIN_ROLE` | Plugs a fee model, or zero for none. It must be attested as `FEE_MODEL` (`NavDesk_FeeModelRefused(_feeModel)`). A first plug restarts `lastFeeAt`, except in the block of an `adopt` that took the outgoing desk's fee clock, which it keeps, and, with a `mark` of 0, starts the mark at the vault's `convertToAssets(1e18)`, or at par if that is lower, so a gain made before the plug is not charged and getting back to par pays no performance fee (`test_AFirstPlugBelowParStartsTheMarkAtPar`). A swap keeps the mark and the clocks. Emits `FeeModelSet`. |
| `setRedemptionGate(_gateBps)` | `DEFAULT_ADMIN_ROLE` | Sets the [level](#gate), up to 10,000 basis points; zero is off (`NavDesk_InvalidGate(_gateBps)` above that). A proposal on the table keeps the limit it froze. Emits `RedemptionGateSet`. |
| `adopt(_oldDesk)` | `DEFAULT_ADMIN_ROLE`, once | Takes over the cut-off, the redemption gate's level and, where the outgoing desk has them, the mark, what was paid since it moved, and the fee clock. Refuses while either desk has a proposal on the table. Emits `RedemptionGateSet` and `DeskAdopted`. |
| `proposal()`, `hashOf(_proposal)` | Anyone (read-only) | The proposal on the table, and the hash `accept` takes for a proposal. |
| `isWired()` | Anyone (read-only) | Whether this desk holds the vault's `SETTLER_ROLE`. It is there for monitors. |
| `VAULT()`, `portfolio()`, `custodianAccount()`, `periodLength()`, `cooldown()`, `maxReportAge()`, `lastCutoff()`, `redemptionGate()`, `feeModel()`, `mark()`, `markMovedAt()`, `paidSinceMark()`, `lastFeeAt()` | Anyone (read-only) | The vault, the settings, the last cut-off, the redemption gate's level, and the fee state. |
| `MIN_COOLDOWN()`, `MAX_COOLDOWN()`, `REPORTER_ROLE()`, `CHECKER_ROLE()` | Anyone (read-only) | The cooldown bounds, and the two role ids it defines. The roles are held on the vault. |

The constructor takes the vault, the custodian account and the schedule, with the same bounds as `setSettings`. A zero vault reverts with `NavDesk_ZeroValue`. A portfolio can be plugged only through `setSettings`. The other errors of `INavDesk` are in the sections above, each next to the check that raises it.

<a id="why"></a>
## Why it is built this way

- **The cut-off is on a schedule.** A person who picked the moment could pick it knowing where the price stood. Here the earliest moment follows from the last cut-off, and any account can make the call from then on.
- **The price comes after the cut-off.** `asOf` cannot be stated earlier than `lastCutoff`, so with an honest report an investor who files a request does not know the price it will deal at.
- **Two accounts on every price.** The reporter proposes and a different account accepts, and the acceptance names the exact numbers through the hash.
- **The numbers freeze at the proposal.** A timelock change can land inside the cooldown, and the checker's approval should hold for what the checker saw.
- **The level is on the desk, not the vault.** The vault is told how many shares to take and has no policy of its own. A later desk can apply another policy with the vault unchanged.
- **The level is mechanical.** It is meant to be fixed in a fund's offering documents, so applying it needs no decision, and the guardian gets no power over it. The guardian can already stop dealing by cancelling a proposal.
- **No role table.** Asking the vault each time means a revoked reporter stops at once (`test_ARevokedReporterStopsAtOnce`) and a replaced desk needs no new grants for its people.
- **The fee clock stops at the proposal, not at execution.** `lastFeeAt` becomes `proposedAt`, so the time between the proposal and its execution is charged by the next price and not lost. A cancel moves nothing, so nothing is charged twice (`test_ACancelledProposalChargesNothing`).
- **It is not attested.** Nothing installs it by code hash and money does not pass through it. It acts by the role the vault gives it, and the post-deploy check pins that role.

In a deployment, `Legos` builds the desk against the vault's predicted address. `Product` grants the desk `SETTLER_ROLE`, grants `REPORTER_ROLE` and `CHECKER_ROLE` on the vault, plugs the portfolio and the fee model where the profile has them, and sets the level where the product's `nav` states `redemptionGateBps`. The `vault7540` and `managed-fund` profiles use a period of 1 day, a cooldown of 1 day and a maximum report age of 3 days. No shipped profile states a level: each product takes its own from its documents. See [Deployment and governance](../deployment.md).

<a id="limits"></a>
## What it does not do

- **It does not prove the value.** `reportHash` shows which report was used, not that the money exists, and there is no limit on how far a value can move from the last one. A reporter and a checker who collude can approve a wrong price, and whoever dealt in between keeps the difference when it is corrected. The cooldown, the guardian's cancel and the published hash make that harder and traceable.
- **It does not stop another settler.** The vault takes whatever `settlePeriod` is given, from any holder of `SETTLER_ROLE`, and the timelock can grant that role to anyone. The vault does not check the holder. `isWired()` says only that this desk holds the role, and the post-deploy check asserts that no other account it knows about does. Another settler also names its own `redeemLimit`, whatever level the desk holds.
- **It does not settle a period it did not price.** A proposal names a period and `settlePeriod` takes no period number, so `execute` compares the two. If a second settler has dealt that period, `execute` reverts with `NavDesk_WrongPeriod(proposed, closed)` once another is closed (`test_WhenAnotherPeriodIsClosedNow_ItReverts`), and with `NavDesk_NoClosedPeriod` until then (`test_WhenNoPeriodIsClosedNow_ItReverts`). Cancelling is the way out.
- **It tells two addresses apart, not two people.** The check is that the caller is not the proposer. The post-deploy check asserts that the reporter and the checker are different accounts.
- **The cooldown does not run from the acceptance.** A checker who accepts after the cooldown is over allows `execute` in the same block. The cancel window is the time since the proposal, whoever accepted it and when.
- **It does not re-check `moves` or the portfolio's price at `execute`.** Both are checked at `propose`. Money the allocator moves during the cooldown does not invalidate the proposal, and the frozen value stands.
- **It does not check the cash account in advance.** When a settlement needs money from the cash account and the account is short or has not approved the vault, `execute` reverts, so cash is raised before proposing (`test_WhenTheCashAccountIsShort_ThePeriodStaysClosedAndTheRequestsGoBack`).
- **An unexecutable proposal still blocks a release.** A stale proposal stays on the table, and the release path reverts with `NavDesk_ProposalPending` until a guardian or a checker cancels it. The agent cannot cancel.
- **It does not overwrite a first plug.** A proposal made with no fee model froze no fee state, so `execute` leaves the mark and the clocks alone, a model plugged during the cooldown keeps what its plug set, and the frozen fee of zero is paid (`test_AFirstPlugDuringACooldownKeepsItsMarkAndChargesNoPrincipal`, `test_WithNoModelExecutingLeavesTheFeeStateAlone`).
- **A gate slows every exit.** The timelock can set a low level, delayed and visible, and a low level keeps holders queued. A compromised governance is outside what the code defends against.
- **A gate does not stop over-requesting.** A holder who expects a gate can ask for more than it wants, to get a bigger slice. Only a role can hand back a carried part, which is the deterrent, and not a complete one.
- **One level, per period, on redemptions.** There are no two levels at once, such as monthly and quarterly, and no limit on deposits.
- **Dust left on purpose costs the fee on one doubling.** A holder who leaves just under `1e6` share units has the next investor pay as little as about half par with the mark at par, so the first doubling pays no performance fee (`test_TheLargestDustCostsTheFeeOnTheFirstDoubling`). Investors lose nothing.
- **It does not run itself.** `closePeriod` and `execute` need someone to call them, and the next period counts from the moment of the call, so a late call moves later cut-offs later.
- **It serves one vault, of one kind.** The deployment profiles allow a desk on a 7540 only (`assertUsable`), and `VAULT` is fixed at construction.

<a id="connected"></a>
## Connected to

- [Gated7540Vault](Gated7540Vault.md): The vault it prices. It holds the roles the desk asks about, and it deals the period.
- [FeeModel](FeeModel.md): Quotes the fee on the gross value. The desk keeps the mark and the clocks.
- [Portfolio](Portfolio.md): When plugged, both the cash account and the source of the on-chain value.
- [PolicyRegistry](PolicyRegistry.md): Must attest a portfolio or a fee model before the desk takes it.
- [Where the money sits](../money.md): Follows the money through a settlement.
- [Who can do what](../roles.md): The reporter, the checker, the guardian and the agent, across the stack.

<a id="source"></a>
## Source and tests

- Contract: `contracts/nav/NavDesk.sol`, interface `INavDesk.sol`
- Tests: `NavDesk.t.sol` (a real vault behind a real hook, with a desk holding `SETTLER_ROLE`), and `test/nodejs/legos.test.ts` (a deployed desk through whole cycles, and the post-deploy check)
