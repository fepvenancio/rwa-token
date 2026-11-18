[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Policy

# SettlementWindowRule

Opening hours for executor-settled transfers. An intent carried out by an executor settles only inside the token's daily window, in UTC, on the weekdays the token enables. Every other kind of movement ignores the window.

- **contracts/hooks/rules/SettlementWindowRule.sol**
- immutable, **not a proxy**
- set per token by the token's **DEFAULT_ADMIN_ROLE**
- attested as **RULE**
- ruleId: **keccak256('SettlementWindowRule.v1')**

<a id="in-one-minute"></a>

> ### In one minute
>
> On an [IntentToken](IntentToken.md) a holder can sign a transfer in advance (an intent) and let an executor carry it out, alone or as one side of a trade against cash. This rule gives those settlements opening hours, for example 09:00 to 17:00 UTC, Monday to Friday. Outside the hours the executor's call is refused with `WINDOW_CLOSED`, and the signed intent can be settled later, until its own deadline. The holder's own transfers, mints, burns and the agent's forced transfers are not affected. A token that lists the rule but has no hours set refuses every executor settlement.

<a id="how"></a>
## How the window works over a week

A window is three numbers: `open` and `close`, each a second of the UTC day (0 to 86399), and `dayMask`, seven bits for the weekdays, bit 0 for Monday up to bit 6 for Sunday. `MON_TO_FRI` is `0x1F`. The diagram shows the same mask with two windows: one inside the day, one across midnight.

> **Diagram.** One week, Monday to Sunday, with the MON_TO_FRI mask, so Monday to Friday are enabled. A same-day window from 09:00 to 17:00 UTC is open in the middle of each enabled day and not on Saturday or Sunday. An overnight window from 22:00 to 02:00 UTC opens at 22:00 on each enabled day and runs to 02:00 the next morning, so Friday's session runs into Saturday until 02:00, while Monday from 00:00 to 02:00 is closed because Sunday is not enabled.
>
> **An overnight session belongs to the day it opened.** Each column is one UTC day from 00:00 to 24:00; shaded bars are open. With `open < close` the window is open from `open` (included) to `close` (excluded) on each enabled day. With `open > close` it opens on an enabled day and runs past midnight to `close`, even into a day that is off, and no session opens on a day that is off. The dashed red slots are the Sunday session that does not open.

1. **Which day.** The rule takes the block's timestamp. The day number is `timestamp / 86400`, the second of the day is `timestamp % 86400`, and the weekday is `(day + 3) % 7`, with Monday as 0. Day 0, 1 January 1970, was a Thursday, which is 3 when Monday is 0.
2. **Same-day window** (`open < close`): open when today's bit is set and `open <= second < close`.
3. **Overnight window** (`open > close`): open when today's bit is set and `second >= open`, or when yesterday's bit is set and `second < close`. Yesterday is `(weekday + 6) % 7`.
4. **No window.** A token with no window set (a `dayMask` of 0) is not open at any time.

| Worked example | Value |
|---|---|
| Timestamp | `1791763200`, Monday 12 October 2026, 00:00 UTC |
| Day number | `1791763200 / 86400 = 20738` |
| Weekday | `(20738 + 3) % 7 = 0`, Monday |

<a id="kinds"></a>
## What it does for each kind of movement

| Kind | What the rule checks |
|---|---|
| TRANSFER | nothing: passes at any time |
| EXECUTED | the window must be open at the block's timestamp; otherwise `WINDOW_CLOSED`, the one reason code, and the answer at any time while no window is set |
| FORCED | nothing: passes at any time, the enforcement mint included |
| MINT | nothing: passes at any time |
| BURN | nothing: passes at any time |

Executed movements come from `executeTransfer` on the intent token, which [`IntentExecutor`](IntentExecutor.md) calls for single intents and for atomic batches, and [`DvPExecutor`](DvPExecutor.md) calls for a leg on a token that supports intents. The token reverts a refused settlement with `ERC8473PolicyRejected(WINDOW_CLOSED)`. `IntentExecutor`'s `execute` passes that error on, its `executeBatch` wraps it in `IntentExecutor_BatchItemFailed(index, reason)`, and `DvPExecutor` wraps it in `DvPExecutor_LegFailed(leg, reason)`.

The pre-flight `canExecute` runs the same rule with the same kind, so it says `WINDOW_CLOSED` before an executor submits a call that would fail. `canTransfer` and `canTransferWithReason` ask about a plain transfer, so they do not see the window.

<a id="account"></a>
## The account questions

`checkSend` and `checkReceive` answer `TRANSFER_OK` for every account: they are the [`BaseRule`](BaseRule.md) defaults. Time is not a property of an account, so `canSend` and `canReceive` ignore the window.

<a id="config"></a>
## Who sets the hours, and what happens before they do

The rule asks the token at call time whether the caller holds `DEFAULT_ADMIN_ROLE`, through a read-only call. While a product launches that is the operations account, and the `Product` module calls `setWindow` with the parameters `windowOpen`, `windowClose` and `windowDays`, which have no defaults. The test deployment uses 09:00 to 17:00 UTC with `MON_TO_FRI`. After the hand-over the main timelock is the admin, so changing the hours is a governance operation with its delay.

**Not configured: it fails closed.** A `dayMask` of 0 means no window, and with no window every `EXECUTED` movement is refused rather than allowed at any time. Zero is not off here. Other kinds pass, set or not.

<a id="order"></a>
## Where it sits, and who lists it

One product lists it at this commit: the intent token of the demo deployment (`full`, through `RULE_ORDER`), fourth in its list, after the credential check, the minimum position and the holder restrictions, and before the fund's investor cap. The vaults have no executed transfers, and `assertUsable` in `ignition/profiles.ts` throws when a module is built that lists it on anything but an `IntentToken`. The hook itself would accept it on any token, where it would judge nothing.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `setWindow(token, open, close, dayMask)` | The token's `DEFAULT_ADMIN_ROLE` | Sets the token's window, replacing any earlier one. `open` and `close` must each be below 86400 and differ, and `dayMask` must be non-zero and fit in 7 bits, or it reverts with `SettlementWindowRule_InvalidWindow`. Emits `WindowSet(token, open, close, dayMask)`. Reverts with `SettlementWindowRule_OnlyTokenAdmin(token, caller)` for anyone else. |
| `check(ctx)` | Anyone (read-only); the hook in practice | `TRANSFER_OK` for every kind but `EXECUTED`; for `EXECUTED`, `TRANSFER_OK` inside the window and `WINDOW_CLOSED` outside it. |
| `isOpen(token, timestamp)` | Anyone (read-only) | Whether the token's window is open at a given timestamp, past or future; false when no window is set. A fuzz test pins that it agrees with `check`. |
| `windowOf(token)` | Anyone (read-only) | The token's `open`, `close` and `dayMask`; a `dayMask` of 0 means no window. |
| `MON_TO_FRI()` | Anyone (read-only) | `0x1F`, the mask for Monday to Friday. |
| `checkSend`, `checkReceive` | Anyone (read-only) | `TRANSFER_OK` for every account. |
| `after_(ctx)` | The hook of `ctx.token` | The empty default. The hook does not call it, because `wantsAfter()` is false. |
| `onInstall(token, previousPolicy)` | Anyone; the hook when a token installs it | The empty default: the rule keeps no state derived from movements. |
| `ruleId()`, `wantsAfter()`, `supportsInterface(id)` | Anyone (read-only) | `keccak256('SettlementWindowRule.v1')`; false; ERC-165 for `ISettlementWindowRule`, `IComplianceRule` and `IERC165`. |

<a id="why"></a>
## Why it is built this way

- **Executor settlement is what is scheduled.** The window governs the movements an executor carries out on a holder's behalf. A holder's own transfer, an issuance, a redemption and an enforcement action pass at any time.
- **Plain arithmetic on the timestamp.** No time zones and no calendar contract: the weekday follows from the timestamp alone, in UTC, so every node computes the same answer and the rule stays read-only.
- **A session runs to its close.** An overnight session that opened on an enabled day closes at its stated time, even past midnight into a day that is off, and a day that is off does not open one. Tests pin both cases.
- **It fails closed.** Listing the rule without setting hours refuses every executor settlement rather than allowing them at any time.
- **One instance for every token.** Windows are stored per token and authorised by that token's own admin.

<a id="limits"></a>
## What it does not do

- **It does not hold plain transfers to the hours.** On a token that lists this rule alone, a holder's `transfer` passes outside the window. [`ExecutedOnlyRule`](ExecutedOnlyRule.md) is the rule that refuses plain transfers. No profile lists the two together at this commit.
- **A window cannot be cleared.** `setWindow` refuses a `dayMask` of 0, so once a token has hours they can be changed but not removed. To stop applying the rule, the token's admin takes it out of the token's list on the hook.
- **It cannot be open all day.** `open` and `close` must differ and both be below 86400, so a window leaves at least one second of each day closed. A token that wants no hours leaves the rule out.
- **It has no holiday calendar.** A closed public holiday that falls on an enabled weekday is open as far as the rule knows.
- **It judges block time.** The rule reads the timestamp of the block the settlement lands in, not the time the intent was signed or submitted. A pre-flight answers for the latest block and a write lands in a later one, so near a boundary the two can give different answers. How far apart they are depends on the chain's block time and on how long the transaction waits. `open` is included and `close` is not: with the overnight window above, Monday 22:00:00 is open and 21:59:59 is not; Tuesday 01:59:59 is still Monday's session and 02:00:00 is closed.

<a id="connected"></a>
## Connected to

- [IntentToken](IntentToken.md): The template this rule is for, the one whose movements can be `EXECUTED`.
- [IntentSettledUpgradeable](IntentSettledUpgradeable.md): Where signed intents are checked and executed as `EXECUTED` movements.
- [IntentExecutor](IntentExecutor.md): Submits single intents and atomic batches; refused outside the window.
- [DvPExecutor](DvPExecutor.md): Settles a leg on a token that supports intents as an executed movement, so the window applies to it.
- [ComplianceHook](ComplianceHook.md): Asks this rule in the intent token's list.
- [BaseRule](BaseRule.md): The parent this rule inherits its defaults from.

<a id="source"></a>
## Source and tests

- Contract: `contracts/hooks/rules/SettlementWindowRule.sol`, interface `ISettlementWindowRule.sol`
- Tests: `SettlementWindowRule.t.sol` (validation, every kind, an unconfigured token, same-day and overnight windows with their edges, `isOpen` agreeing with `check`), `RuleSetIntegration.t.sol` (intents refused outside the window while plain transfers pass, and the rule taken out of the list) and `test/nodejs/time.test.ts` (the window is open from open to close on weekdays only)

---

Describes the contracts at commit `01024e9` on `main`.
