[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Escrow

# LienVault

Holds tokens a holder has pledged. Each amount sits under a lien that names a beneficiary, and only the beneficiary decides whether it goes back to the holder or to itself.

- **contracts/escrow/LienVault.sol**
- immutable, **not a proxy**
- **not attested**: it is installed nowhere
- **no roles**, and no role on any token
- ERC-20 tokens only

<a id="in-one-minute"></a>

> ### In one minute
>
> A holder that borrows against its tokens gives the lender control over them without giving them away. Here it does that by moving them into this contract, under a **lien**: a record of the token, the holder (the pledgor), the lender (the beneficiary) and the amount. From then on the holder cannot move them, because they are not in its balance. The beneficiary can send them back (`release`), take them (`seize`) or hand the lien to someone else (`assign`). The contract cannot know whether a loan is in default, so it does not ask: the holder trusts the beneficiary with the pledged amount and with nothing else. The contract holds no role on any token, so a fault in it can lose only what was pledged into it.

<a id="how"></a>
## How it works

1. **Pledge.** The holder approves the vault on the token, then calls `pledge(token, amount, beneficiary)`. The vault pulls the amount and opens a lien with the next id, from 1. It reverts unless its balance rose by exactly the amount, so a token that keeps a fee is refused (`test_ATokenThatKeepsAFeeIsRefused`). `increase(lienId, amount)` adds to a lien, and only its pledgor can.
2. **While it is pledged.** The holder can move the rest of its balance and nothing of the pledged part (`test_TheHolderCannotMoveWhatItPledgedAndCanMoveTheRest`). Every pre-flight on the token is exact with no change to the token: pledged shares of a vault are not in `maxRedeem` (`test_PledgedSharesAreNotRedeemableAndMaxRedeemIsExact`). A payment from the holder to its lender leaves the lien as it was.
3. **Release or seize.** The beneficiary calls `release(lienId, amount)`, which pays the pledgor, or `seize(lienId, amount)`, which pays the beneficiary. Either can be in parts and never past what the lien holds. A lien that holds nothing is closed: its id answers `LienVault_NoLien` from then on, and ids are never used again.
4. **Several lenders.** A holder can have many liens, to one lender or to several. Each is touched only by its own beneficiary (`test_TwoLendersHoldLiensOnOneHolderAndNeitherTouchesTheOthers`).

**Nothing here is forced.** Every movement in and out is a plain transfer, which the token's policy judges like any other. The vault is an ordinary holder of each token, so it needs whatever that token's policy asks of a holder: a credential, given by the attester.

| When | What happens |
|---|---|
| The token is paused | Nothing enters or leaves, `recover` included (`test_NothingLeavesWhileTheTokenIsPaused`). |
| The policy no longer admits the beneficiary | It cannot seize. It can `assign` the lien to an account the policy admits, which then can (`test_ABeneficiaryThePolicyRefusesCannotSeizeAndCanAfterAssigning`). |
| The pledgor is frozen or no longer admitted | A release to it reverts and the tokens stay under the lien (`test_AReleaseToAFrozenPledgorIsRefusedAndTheTokensStay`). The beneficiary can still seize. |
| The holder is inside a lockup | It cannot pledge: a pledge is a transfer, and `HolderRestrictionRule` refuses it (`test_AHolderInsideItsLockupCannotPledge`). |
| The token takes signed intents only (`ExecutedOnlyRule`) | It cannot be pledged. Not supported. |

<a id="enforcement"></a>
## Enforcement on pledged tokens

The vault's balance of a token is every pledgor's together. The token's own `forcedTransfer` out of the vault cannot say whose tokens it takes, and it leaves liens the balance no longer covers. So the vault has its own path: `recover(lienId, to)`, for an account that holds the token's `AGENT_ROLE`, which the vault asks the token at the moment of the call. It moves everything the lien holds to `to` and closes the lien.

- **It is a plain transfer too.** The vault holds no role, so it cannot force anything. The token must be unpaused and its policy must admit `to` (`test_ARecoveryToAnAccountThePolicyRefusesIsRefused`).
- **It works when the pledgor and the beneficiary are both frozen or blocked.** Neither is a party to that transfer: the vault sends and `to` receives (`test_TheTokensAgentRecoversALienWhenThePledgorAndTheBeneficiaryAreBothRefused`).
- **On a token with no such role it does nothing.** The call to the token reverts (`test_OnATokenWithNoRolesNobodyRecovers`).

An agent that uses `forcedTransfer` on the vault's address anyway is caught by the [reconciler](../deployment.md#operations), which names a token of which the vault holds less than its liens book.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `pledge(token, amount, beneficiary)` | Any holder, for its own tokens | Pulls the amount under the caller's allowance and opens a lien. Returns its id. |
| `increase(lienId, amount)` | The lien's pledgor | Adds to the lien. |
| `release(lienId, amount)` | The lien's beneficiary | Sends the amount back to the pledgor. |
| `seize(lienId, amount)` | The lien's beneficiary, at any time | Sends the amount to the beneficiary. |
| `assign(lienId, newBeneficiary)` | The lien's beneficiary | Hands the lien to another account. |
| `recover(lienId, to)` | A holder of the token's `AGENT_ROLE` | Sends everything the lien holds to `to` and closes it. |
| `lienOf(lienId)`, `lienCount()` | Anyone (read-only) | One lien, all zero once closed; and how many were ever opened, so ids run from 1 to that. |
| `pledgedOf(token, pledgor)`, `totalPledged(token)` | Anyone (read-only) | What one holder has pledged of a token over all its liens, and what all liens on the token hold. |

Any other caller gets `LienVault_Unauthorized`. A zero address, a zero amount, or the vault itself named as a beneficiary or a recovery account gets `LienVault_InvalidValue`: none of those could ever act on a lien (`test_AZeroValueIsRefusedEverywhere`). An amount above what the lien holds gets `LienVault_ExceedsLien`. Each change emits one event: `LienOpened`, `LienIncreased`, `LienReleased`, `LienSeized`, `LienAssigned`, `LienRecovered`.

<a id="why"></a>
## Why it is built this way

- **An escrow, not a rule.** The other design keeps pledged tokens in the holder's balance and gives a contract `AGENT_ROLE` to seize them. Then a fault in that contract reaches every holder's tokens. Here it reaches only what was pledged.
- **The beneficiary alone, with no date and no proof.** A default is a fact off-chain. A date after which seizure opens would say nothing about one.
- **The books change before the tokens move,** and every function holds a reentrancy guard, so a token that calls back in the middle of a transfer finds the lien already lowered and the door shut (`test_ABeneficiaryCannotReenterFromTheTokensCallback`).
- **No pause of its own.** A token's pause already stops every movement in and out.

<a id="limits"></a>
## What it does not do

- **It does not keep the holder on the register.** The vault is the holder of record of what it holds. Whoever builds a distribution's list from balances reads the liens and credits each pledgor, or the vault would be paid. That look-through is a step in the operator's process and nothing on-chain enforces it.
- **It does not keep a fund's count true.** A fund exempts the vault, so a holder that pledges its whole position leaves the count while it still owns the position, and another investor can take its place. When the lien is then released at a full fund, the release is refused with `MAX_HOLDERS` until a slot is free. The count on-chain is of holders of record. The reconciler reports the number with the pledgors added. For a fund with a cap in law, that gap is a question for counsel before the fund lists the vault.
- **It does not let a locked holder pledge,** as above.
- **It does not promise a small lien can be taken.** The vault is exempt from a token's minimum position. A lender that holds nothing cannot seize a lien smaller than the minimum, and nobody can know that when the lien is made.
- **It does not judge a seizure.** A beneficiary can take what its lien holds at any time, for any reason.
- **It does not hold NFTs or multi-token series.** ERC-20 only in this version.
- **It has no signed path.** The holder sends its own `approve` and its own `pledge`.

<a id="connected"></a>
## Connected to

- [PolicyGatedERC20Upgradeable](PolicyGatedERC20Upgradeable.md): The tokens it holds, whose policy judges every movement in and out and whose agent may recover a lien.
- [Fund](Fund.md): Exempts the vault from its count, with the gap that leaves.
- [MinPositionRule](MinPositionRule.md): Exempts the vault on each token, as any pooling account.
- [Distributor](Distributor.md): Its list is built off-chain, and must look through the vault to the pledgors.

<a id="source"></a>
## Source and tests

- Contract: `contracts/escrow/LienVault.sol`, interface `ILienVault.sol`
- Tests: `LienVault.t.sol` on a real token behind the credential registry, its rule, the holder restriction rule and the hook, with `invariant_TheBalanceCoversTheLiensAndTheSumsAgree`; `contracts/test/halmos/LienVaultHalmos.t.sol`; and `test/nodejs/lien.test.ts` for the part, the check, the fund's count, the minimum and the reconciler
