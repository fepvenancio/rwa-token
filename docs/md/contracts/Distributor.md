[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Settlement and distribution

# Distributor

Pays one token's holders a funded distribution, such as a dividend or a coupon. A maker proposes a list, a different checker approves it and the approval pulls the money in, holders claim with a proof, and what is left returns to the funder after an expiry.

- **contracts/distribution/Distributor.sol**
- immutable, **not a proxy**
- one per token
- no role table: it asks the token
- not attested
- deployed by **Legos** for a product that asks

<a id="in-one-minute"></a>

> ### In one minute
>
> To pay a dividend or a coupon, someone has to know who was owed what on the record date. Keeping that inside the token would add a cost to every transfer. Here the list is built off-chain at the record date, and only its Merkle root goes on-chain: one hash that commits to the whole list and lets each line be proved on its own. The token gains no snapshots and its transfers cost the same.
>
> Two accounts must agree on the root, and the second one's approval pulls the money in, so a distribution that can be claimed is one that was paid for. A holder, or anyone on its behalf, claims with a proof, and the money goes only to the holder. The contract pays nothing on its own: someone has to submit each holder's line, one by one or many at a time with `claimBatch`, and a holder whose line nobody submits by the expiry gets nothing from this distribution, and the money goes back to the funder. The root proves which list was used, not that the list is right.

<a id="how"></a>
## One distribution, step by step

> **Diagram.** Where the money goes in one distribution. A maker with DISTRIBUTION_MAKER_ROLE proposes it, and no money moves. A checker with CHECKER_ROLE, who is not the maker, approves it, and the approval pulls the total from the funder into the Distributor. Anyone can then claim for a holder up to the expiry, and the holder is paid the amount in its line. After the expiry anyone can sweep, and what is left goes back to the funder.
>
> **Where the money goes.** Dashed lines are the two role-gated calls, and solid lines are money. The checker's call is what pulls the total from the funder.

1. **Build the list, off-chain.** At the record date the issuer works out what each holder is owed and builds a Merkle tree of those lines. The token is not involved.
2. **Propose.** A holder of the token's `DISTRIBUTION_MAKER_ROLE` calls `propose(_root, _asset, _total, _expiry, _funder)`. It reverts with `Distributor_InvalidValue` for a zero root, asset, total or funder, or an expiry that is not in the future. It records the caller as the maker, returns an id counting up from 1, and emits `DistributionProposed`. No money moves.
3. **Approve.** A holder of the token's `CHECKER_ROLE` calls `approve(_id)`. It reverts, in this order, for an id that does not exist (`Distributor_NotApproved`), on a second approval (`Distributor_AlreadyApproved`), after the expiry (`Distributor_Expired`, `test_AfterTheExpiryNothingIsApproved`; at the expiry itself it can still be approved, as a claim can still be made, `test_AtTheExpiryItCanStillBeApproved`) and for the account that proposed this distribution (`Distributor_SelfApproval`). It marks the distribution approved, emits `DistributionApproved` and pulls the total from the funder. A funder without the money or the allowance makes the whole call revert (`test_AFunderShortOfMoneyStopsTheApproval`).
4. **Claim.** Anyone can call `claim(_id, _holder, _amount, _proof)`, and the money goes to `_holder` (`testFuzz_AnyoneSubmitsAndTheMoneyGoesToTheHolder`). The checks run in this order: approved (`Distributor_NotApproved`), not past the expiry (`Distributor_Expired`), not yet claimed (`Distributor_AlreadyClaimed`), the token's `canReceive(_holder)` (`Distributor_HolderMayNotReceive(_holder)`), the proof (`Distributor_BadProof`), and an amount within what is left of the total (`Distributor_OverFunding`). It then records the claim, emits `DistributionClaimed` and pays.
5. **Claim many.** Anyone can call `claimBatch(_id, _holders, _amounts, _proofs)` to pay many lines in one transaction (`test_AHundredHoldersArePaidInOneTransaction`). It checks the distribution once, then each line as `claim` does, with one difference: a line that cannot be paid now does not stop the others. A holder already paid, a holder the token says may not receive, and a holder the asset itself refuses, as a gated cash token refuses an account it does not accept, are each passed over with `DistributionClaimSkipped`, and the last two stay unclaimed and can be paid later (`test_AHolderAlreadyPaidIsPassedOverAndTheOthersArePaid`, `test_AHolderWhoMayNotReceiveTheTokenIsPassedOverAndCanClaimLater`, `test_AHolderTheAssetRefusesIsPassedOverAndCanClaimLater`). A wrong proof or a line above what is left of the funding is the submitter's error and reverts the whole batch (`test_ABadProofRevertsTheWholeBatch`, `test_ARowAboveWhatIsLeftRevertsTheBatch`).
6. **Sweep.** After the expiry anyone can call `sweep(_id)`, which sends the total less what was claimed to the funder and emits `DistributionSwept`. It reverts before then (`Distributor_NotExpired`) and on a distribution that was not approved (`Distributor_NotApproved`). A second sweep pays nothing (`test_ASecondSweepPaysNothing`). The expiry is the last moment to claim: at that exact time a claim passes and a sweep reverts (`test_AtTheExpiryAClaimPassesAndAfterItIsRefused`, `test_BeforeTheExpiryItReverts`).

<a id="root"></a>
## What the root must contain

The contract never sees the list. These are what the list has to be for the claims to work as intended, and only the first is checked, line by line, when someone claims.

- **The right leaf format.** Each line is one `address` and one `uint256`, the holder and its amount in the asset's smallest unit. The leaf is `keccak256(bytes.concat(keccak256(abi.encode(holder, amount))))`, the double hash of OpenZeppelin's `StandardMerkleTree`, and a claim checks it with `MerkleProof.verifyCalldata`.
- **One line per holder.** `hasClaimed` is kept per distribution and holder, so a second line for the same holder cannot be claimed (`Distributor_AlreadyClaimed`).
- **Amounts that add up to the total.** A list that sums above the total pays first come, first served, and the claim that would pass the total reverts (`test_ClaimsCannotPassTheFunding`). A list that sums below it leaves the rest to be swept back.
- **The address that should be paid.** The money goes to the address in the line. A line that names a custodian or another contract pays that account.
- **A decision on who counts as a holder.** The list is whatever the issuer builds. On a [Gated7540Vault](Gated7540Vault.md), for example, shares waiting to be redeemed sit in escrow at the vault's own address, and shares bought but not yet claimed are in nobody's balance, so a plain reading of balances does not give the entitlements.

<a id="holders"></a>
## What a frozen, unverified or paused holder experiences

`claim` asks the token one question about the holder: `canReceive(_holder)`. It does not read the holder's balance, frozen amount or lockup. `canReceive` is false while the token is paused or has no hook. Otherwise it follows the hook's `checkReceive`, which goes through the token's rules and stops at the first refusal. A hook that holds no rules for the token refuses too (`NO_RULES`). So the answer depends on the token's rule list. With `CredentialRule` and `HolderRestrictionRule` listed:

| The holder or the token | `canReceive` | What a claim does |
|---|---|---|
| The token is paused | false | Reverts with `Distributor_HolderMayNotReceive(_holder)`, for every holder and every distribution of this token. Claims work again after the unpause, up to each expiry. `propose`, `approve` and `sweep` do not ask and keep working. |
| No credential (`NONE`), or blocked (`BLOCKED`) | false | Reverts with the same error. The rule's reason is `RECEIVER_NOT_VERIFIED`. |
| Credential lapsed (`LAPSED`), or its attester killed (`EXIT_ONLY`) | false | Reverts with the same error, although this holder can still send and exit. The rule's reason is `CREDENTIAL_EXPIRED` for a lapse and `RECEIVER_NOT_VERIFIED` for the other. A renewed credential lets the claim through, up to the expiry. |
| An `ACTIVE` credential the token's policy does not accept | false | Reverts with the same error. The rule's reason is `RECEIVER_NOT_ELIGIBLE`. A token with no policy set gives that reason for every holder. |
| Address-frozen: `setFrozen` on `HolderRestrictionRule` | false | Reverts with the same error until the freeze is lifted. The rule's reason is `RECEIVER_FROZEN`. |
| Tokens frozen: `setFrozenTokens` on the token | true | Paid. The frozen amount concerns the token balance, which a claim does not touch. |
| Under a lockup: `setLockup` on `HolderRestrictionRule` | true | Paid. A lockup stops sending (`canSend` is false), not receiving. |
| Sold its tokens after the record date | true | Paid, if nothing above applies. The list decides, not the balance. |
| Bought its tokens after the record date | true | Reverts with `Distributor_BadProof`: it is not in the list. |

On a fund class, `FundHoldersRule` answers too: false for every holder on a token that is not a registered class. The investor cap is not part of the answer, so a full fund does not stop a claim.

**A block delays, and the expiry does not wait.** A holder who is blocked can claim once the block is lifted (`test_AHolderWhoMayNotReceiveCannotClaim`). After the expiry the claim reverts with `Distributor_Expired`, and `sweep` sends that holder's share back to the funder with the rest, including when the block was a pause that outlasted the expiry. Paying that holder is then a matter for a further distribution or for the issuer off-chain.

`Distributor.t.sol` mocks the token's `canReceive`. So this table rests on the code of the base and the rules, and not on a test in the repository.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `propose(_root, _asset, _total, _expiry, _funder)` | The token's `DISTRIBUTION_MAKER_ROLE` | Records a distribution and returns its id. Emits `DistributionProposed`. Reverts with `Distributor_InvalidValue`. |
| `approve(_id)` | The token's `CHECKER_ROLE`, not this distribution's maker | Approves it and pulls the funding. Emits `DistributionApproved`. Reverts with `Distributor_NotApproved`, `Distributor_AlreadyApproved`, `Distributor_Expired` or `Distributor_SelfApproval`. |
| `claim(_id, _holder, _amount, _proof)` | Anyone | Pays a holder's line, to the holder. Emits `DistributionClaimed`. Reverts as listed above. |
| `claimBatch(_id, _holders, _amounts, _proofs)` | Anyone | Pays many holders' lines in one transaction, each to its holder, and returns how many it paid. A line is passed over, with `DistributionClaimSkipped` and a reason, when its holder was already paid, may not receive the token now, or the asset refuses the payment; that holder can still claim later. Arrays of different lengths (`Distributor_InvalidValue`), a proof that does not match, a line above what is left of the funding, and a distribution not approved or expired revert the whole batch. |
| `sweep(_id)` | Anyone, after the expiry | Sends what is left to the funder. Emits `DistributionSwept`. Reverts with `Distributor_NotExpired` or `Distributor_NotApproved`. |
| `distributionOf(_id)`, `hasClaimed(_id, _holder)` | Anyone (read-only) | A `Distribution` (its root, asset, total, claimed, expiry, maker, funder and whether approved), and whether a holder has claimed. |
| `TOKEN()`, `DISTRIBUTION_MAKER_ROLE()`, `CHECKER_ROLE()` | Anyone (read-only) | The token, fixed at construction (a zero token reverts with `Distributor_InvalidValue`), and the two role ids. The roles are held on the token. |

A caller without the role gets `Distributor_Unauthorized(_caller)`.

<a id="why"></a>
## Why it is built this way

- **The record is off-chain and the root on-chain.** The token needs no checkpoints, so it stays small and a transfer costs the same whether or not the token pays distributions. The price of that is that the record is a claim made by the people who approve it.
- **The approval pulls the funding.** Once a distribution can be claimed, the money for it is in the contract.
- **Each distribution keeps its own count.** Distributions in one asset share a balance, and `claimed` cannot pass `total`, so a list that sums too high cannot take another distribution's money.
- **Anyone can submit a claim.** A relayer or the issuer can pay the gas for a holder, and the money still goes only to the holder.
- **The token's policy decides who may be paid.** Asking `canReceive` means a frozen or unverified address is not paid while that holds, without this contract knowing any rule.
- **No role table.** Roles are asked of the token at call time, so the token's `DEFAULT_ADMIN_ROLE` (the timelock, after hand-over) manages them in one place.

<a id="limits"></a>
## What it does not do

- **It does not check the list.** A wrong record date or a wrong amount is paid as approved, up to the funded total.
- **It does not pay anyone automatically.** A holder who does not claim by the expiry gets nothing from this distribution.
- **An approved distribution cannot be cancelled.** There is no function for it. The direct stop is the token's `pause()`, which stops claims on every distribution of the token along with the token's ordinary movements, and the money comes back only after the expiry. A proposal that is never approved stays recorded, with no money in it.
- **It does not move a holder's line.** A holder who lost its key, or whose tokens were moved with `forcedTransfer`, stays in the list at the same address.
- **It tells two addresses apart, not two people.** The check is that the checker is not this distribution's maker. An account holding both roles can approve another maker's distribution. `CHECKER_ROLE` here is the same role id as on [NavDesk](NavDesk.md), so on a vault with a desk the same accounts check prices and distributions.
- **It does not limit a funder's allowance.** Any distribution a maker and a checker approve can draw on an allowance the funder has given this contract, up to that distribution's total and in that asset. A funder that approves only the amount of the distribution in hand limits this.
- **It does not check what the asset does.** It trusts the amounts of a transfer and does not compare balances, so a fee-on-transfer asset would leave less than the total, and claims could then draw on another distribution's money in that asset. If the asset is itself a gated token, this contract is an ordinary holder of it: it needs what that token's policy asks of a receiver, and each payment is judged by that token's rules as well.
- **`Product` grants its roles at launch only.** `Legos` deploys it for a product that sets `distributor`, and `Product` grants `DISTRIBUTION_MAKER_ROLE` to the `distributionMaker` account and `CHECKER_ROLE` to the `checker`, the account that also approves a desk's prices. No shipped profile sets `distributor`. For a product already handed over, the grants are a timelock operation. The post-deploy check compares its code with the release's, reads its `TOKEN()`, and refuses a maker who is also the checker.

<a id="connected"></a>
## Connected to

- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): Answers `canReceive` and holds the two roles. It gains no snapshots.
- [CredentialRule](CredentialRule.md): Decides whether a holder's credential allows it to receive.
- [HolderRestrictionRule](HolderRestrictionRule.md): An address freeze stops a claim, and a lockup does not.
- [FundHoldersRule](FundHoldersRule.md): Answers for a fund class. The investor cap is not part of the answer.
- [Who can do what](../roles.md): The maker and the checker, across the stack.

<a id="source"></a>
## Source and tests

- Contract: `contracts/distribution/Distributor.sol`, interface `IDistributor.sol`
- Tests: `Distributor.t.sol` (unit tests with a real asset and a mocked token) and `test/nodejs/products.test.ts` (on a deployed token: a maker proposes, a different checker approves and funds it, a holder claims; the check refusing a distributor that names another token, a maker who is also the checker, and a stray maker)
- Deployment: `ignition/modules/Legos.ts` (deploys it), `Product.ts` (grants its roles)
