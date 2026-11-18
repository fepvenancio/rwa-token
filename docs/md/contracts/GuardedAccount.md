[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Portfolio

# GuardedAccount

A [Portfolio](Portfolio.md) adapter that makes outside calls, and only the calls its validators allow. A custodian or a strategy is one of these with a small set of permissions.

- **contracts/portfolio/GuardedAccount.sol**
- immutable, **not a proxy**
- attested as **ADAPTER**
- **reported**: **reported()** is true
- plain calls: **no delegatecall, no value**
- no role table: it **asks the vault**

<a id="in-one-minute"></a>

> ### In one minute
>
> Some of a fund's money has to leave the chain, or go through a contract no adapter was written for. An ordinary wallet could do that, and could also do anything else. This account does only what has been written down. Each call needs a permission for that exact contract and function, and the permission's validator, a small attested contract, must accept the parameters. No permission means refused. The timelock grants permissions, the guardian can revoke one at once, the timelock can revoke one after its delay, and the allocator makes the calls. Its money can sit off-chain, so its value comes from a report, which means it can only join a portfolio that accepts reported adapters. `SECURITY.md` calls it the most dangerous lego in the stack, and a review of each permission set is what closes that.

<a id="how"></a>
## How a call is judged

`execute(calls)` takes a list of calls, each a `Call` with a `target` and `data`. It is all or nothing: if any call is refused or fails, nothing in the batch happens (`test_AllOrNothing`).

> **Diagram.** The execute call, step by step. The allocator calls execute. If the caller lacks the vault's ALLOCATOR_ROLE, it reverts with GuardedAccount_Unauthorized. If the vault is paused, it reverts with GuardedAccount_VaultPaused. Then for each call in order: it reads the selector, the first four bytes of the data or zero if the data is shorter. If there is no validator for this target and selector, or the validator does not accept the parameters, it reverts with GuardedAccount_CallRefused. Otherwise it emits CallMade and makes a plain call with no value and no delegatecall. If the call fails, its error comes back and the whole batch is undone.
>
> **Two gates per call.** The permission says which function of which contract, and the validator says which parameters. A validator that reverts rather than answering also stops the batch, with the validator's revert in place of `GuardedAccount_CallRefused`: nothing runs either way. The validator is called as a view, so it cannot change state.

- **Plain calls.** The call goes through OpenZeppelin's `Address.functionCall`, with zero value. A target with no code fails with `AddressEmptyCode` (`test_ItCanCallANonExistentContractOnlyByFailing`), and a failing call's own error comes back, or `FailedCall` if it gave none. `test_AFailingCallBubblesItsError` checks only that the batch reverts. The account has no delegatecall, no modules, no payable function and no `receive` function.
- **Short data.** Data under 4 bytes reads as the selector zero, and with no permission at that selector it is refused (`test_DataTooShortForASelectorIsRefused`). A permission set at selector zero would hand such a call to its validator. The two shipped validators refuse it.
- **Same function, other contract.** A permission covers one target and one selector. Another function of that contract, or the same function of another contract, is refused (`test_AnotherFunctionOfAPermittedContractIsRefused`, `test_TheSameFunctionOfAnotherContractIsRefused`).

<a id="permissions"></a>
## Permissions

`validatorOf(target, selector)` holds the table. Zero means refused, so a function passes only because someone listed it.

- **Granting: `setPermission(target, selector, validator)`.** The vault's `DEFAULT_ADMIN_ROLE`, which is the timelock after the hand-over. The guardian cannot grant (`test_TheGuardianCannotGrant`). The validator must be attested as `VALIDATOR` in the registry the vault names (`GuardedAccount_NotAttested`), and one attested as anything else is refused (`test_AValidatorAttestedAsSomethingElseIsRefused`). It emits `PermissionSet(target, selector, validator)`.
- **Accounts that cannot be named.** The account's own portfolio, its own vault and the account itself, as the target of a permission (`GuardedAccount_ForbiddenTarget`, `test_ItsOwnPortfolioVaultAndSelfCannotBeNamed`). These are the contracts that govern the account. Every other contract can be named, so the review of each permission set is what decides.
- **Revoking: `revokePermission(target, selector)`.** The vault's `DEFAULT_ADMIN_ROLE` or `GUARDIAN_ROLE`, with effect on the next call (`test_ARevokedPermissionRefusesAtOnce`). It has no pause check, so it works while the vault is paused. It emits `PermissionRevoked(target, selector)`.
- **Making calls.** The vault's `ALLOCATOR_ROLE`, asked live, so a revoked allocator stops at once (`test_ARevokedAllocatorStopsAtOnce`).

<a id="custodian"></a>
## A custodian is one permission

A custodian is expressed as a `GuardedAccount` with one permission: the asset's `transfer`, judged by an [ERC20CallValidator](ERC20CallValidator.md) that names the custodian. The `managed-fund` deployment profile builds exactly this for each custodian, and `test/nodejs/legos.test.ts` runs it end to end.

> **Diagram.** A custodian as a GuardedAccount. The allocator moves money from the portfolio to the account with allocate, under caps on its allocation. The allocator then calls execute, and the account makes a transfer to the custodian, which the ERC20CallValidator judges: the one address it names, up to its amount per call. The custodian sends money back to the account by its own decision. The allocator or the guardian moves the account's balance to the portfolio with deallocate.
>
> **Three moves, each with its own control.** The caps limit what reaches the account, the validator limits where it goes next, and `deallocate` takes only what the account holds. The dashed return is not a contract's doing.

1. **Build.** Deploy `ERC20CallValidator(_who, _maxPerCall)`, naming the custodian, and `GuardedAccount(_portfolio, _riskId, _sharedRiskId)`. The council attests the validator as `VALIDATOR` and the account as `ADAPTER`.
2. **Plug in.** The vault's admin calls `addAdapter(account)` and `setCaps(riskId, absoluteCap, relativeCapBps)` on the portfolio, and `setPermission(asset, transfer, validator)` on the account.
3. **Send to the account.** The allocator calls the portfolio's `allocate(_adapter, _assets, _minAdded)`, naming the account. The money sits at the account, and `liquid()` shows it. The account's `allocate` does nothing but check its caller.
4. **Send to the custodian.** The allocator calls `execute` with one `transfer(custodian, amount)` on the asset. A transfer to anyone else is refused (`test_WhenTheValidatorRefuses_SoDoesTheAccount`).
5. **Value it.** The portfolio's `pricedValue()` leaves this money out (`test_CustodyOutAndBack`), and the [NavDesk](NavDesk.md) report carries it (`test/nodejs/legos.test.ts`).
6. **Bring it back.** The custodian sends money to the account. The allocator or the guardian then calls the portfolio's `deallocate(account, assets)`.

<a id="deallocate"></a>
## What `deallocate` can do, and what a pause stops

The account's `deallocate(assets)` can be called by its portfolio alone (`GuardedAccount_Unauthorized`), and pays the portfolio from the account's own balance. It reaches no further. Money at a custodian cannot be deallocated: the asset's transfer reverts on the shortfall (`test_MoneyAtTheCustodianCannotBeDeallocated`). The custodian has to send it to the account first.

A pause on the vault stops `execute`, after the role check (`test_WhileTheVaultIsPaused_ItRefusesAndNothingMoves`, `test_WhileTheVaultIsPaused_AStrangerStillGetsTheRoleError`). It does not stop `setPermission`, `revokePermission` or `deallocate`, so the guardian can bring the account's balance back while paused (`test_WhileTheVaultIsPaused_TheGuardianStillBringsItsBalanceBack`). A permission that pulls money back through `execute`, such as a target's `redeem`, waits for the unpause. No deployment profile grants one.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `execute(calls)` | The vault's `ALLOCATOR_ROLE`, not while paused | Makes the calls, atomically. `GuardedAccount_Unauthorized`, `GuardedAccount_VaultPaused`, `GuardedAccount_CallRefused(target, selector)`. Emits `CallMade(target, selector, data)` for each. |
| `setPermission(target, selector, validator)` | The vault's `DEFAULT_ADMIN_ROLE` | Allows a function of a contract, judged by an attested validator. `GuardedAccount_ForbiddenTarget`, `GuardedAccount_NotAttested`. Emits `PermissionSet`. |
| `revokePermission(target, selector)` | The vault's `DEFAULT_ADMIN_ROLE` or `GUARDIAN_ROLE` | Removes a permission. Emits `PermissionRevoked`. |
| `allocate(assets)` | The portfolio | Checks its caller and does nothing else: the money stays until the allocator sends it on. |
| `deallocate(assets)` | The portfolio | Pays the portfolio from the account's own balance. |
| `liquid()` | Anyone (read-only) | The account's own balance of the asset. It does not include what a custodian holds. |
| `value()`, `fresh()`, `reported()` | Anyone (read-only) | Zero, true and true, at all times. The value is in the report. |
| `riskIds()`, `asset()` | Anyone (read-only) | `RISK_ID`, plus `SHARED_RISK_ID` when it is not zero, and the portfolio's asset. |
| `validatorOf(target, selector)` | Anyone (read-only) | The validator for a function of a contract. Zero means refused. |
| `PORTFOLIO()`, `VAULT()`, `RISK_ID()`, `SHARED_RISK_ID()` | Anyone (read-only) | The settings fixed at construction. |
| The constructor | The deployer | Takes `(_portfolio, _riskId, _sharedRiskId)`. `GuardedAccount_ZeroAddress` on a zero portfolio, `GuardedAccount_NoRiskId` on a zero risk, and `GuardedAccount_ReportedNotAccepted` if the portfolio's `ACCEPTS_REPORTED` is false (`test_AnOnChainOnlyPortfolioIsRefused`). It reads the vault and the asset from the portfolio. |

<a id="why"></a>
## Why it is built this way

- **Refused unless listed.** A forgotten function stays closed. Nothing passes by omission.
- **A permission and a validator.** The timelock's grant says which function, and the validator's attested code says which parameters. A validator's settings are immutables, so the attested code hash covers the exact address and amount.
- **A slow grant and a fast revoke.** Adding a power goes through the timelock's delay. Taking one away needs no delay, and the guardian can do that.
- **No delegatecall.** A delegatecall runs another contract's code with this account's balance and storage, so no check on the parameters could bound it.
- **`deallocate` names no receiver.** The way back through the adapter interface leads to the portfolio and nowhere else.
- **Reported, not priced.** Its money can leave the chain, so the chain cannot price it. A 4626 refuses it for that reason, as the [Portfolio page](Portfolio.md#priced-and-reported) explains.

<a id="limits"></a>
## What it does not do

- **It cannot make a bad permission safe.** It makes whatever calls its permissions allow. Default deny, one narrow validator per call and a timelock on every grant reduce the danger, and only a review of each permission set closes it. A validator's code hash covers its settings, not how the target behaves.
- **It cannot recover money from a custodian.** A custodian that does not return money is an off-chain risk no contract covers.
- **An approval outlives a pause and a revoke.** If a permission allows `approve`, the spender can draw up to that amount at any later time. Pausing the vault or revoking the permission leaves the allowance in the asset.
- **A per-call limit is not a total.** `MAX_PER_CALL` applies to each call, so a batch of several transfers can send more. The caps on what reaches the account are the limit on the total.
- **It does not ask the portfolio.** An account taken off the list, by removal or by write-off, keeps its permissions, and `execute` still works on what it holds until the permissions are revoked. A written-off account also holds its balance out of reach of `deallocate` until it is added back.
- **The forbidden list looks at the target of a call, not at who a call pays.** `setPermission` would accept the asset's `transfer` with a validator that names the portfolio or the vault as its one address. Money sent to the portfolio that way raises `pricedValue()` without changing `moves` or the allocation. No deployment profile does this, and the council's review of the validator is the control.
- **It does not value anything.** `value()` is zero at all times. What the position is worth is in the report, and a report is a claim.

<a id="connected"></a>
## Connected to

- [Portfolio](Portfolio.md): Sends money here under caps on its allocation, and takes it back with `deallocate`.
- [ERC20CallValidator](ERC20CallValidator.md): One address, one amount per call: the custodian's validator.
- [ERC4626CallValidator](ERC4626CallValidator.md): Lets an account enter and leave an outside vault, with everything coming back to it.
- [NavDesk](NavDesk.md): Approves the report that carries this account's value.
- [Gated7540Vault](Gated7540Vault.md): The vault a reported adapter can sit behind, through its desk.
- [PolicyRegistry](PolicyRegistry.md): Where the account and each validator must be attested.

<a id="source"></a>
## Source and tests

- Contract: `contracts/portfolio/GuardedAccount.sol`, interfaces `IGuardedAccount.sol` and `IAdapter.sol`
- Tests: `GuardedAccount.t.sol` (a real portfolio and registry over a mock vault, including `test_ItRunsAStrategyThroughAnOutsideVaultAndKeepsTheShares`), and `test/nodejs/legos.test.ts` (the `managed-fund` profile, money to a custodian and back)

---

Describes the contracts at commit `01024e9` on `main`.
