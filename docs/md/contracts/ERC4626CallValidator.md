[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Portfolio

# ERC4626CallValidator

Judges a vault call for a [GuardedAccount](GuardedAccount.md): `deposit`, `mint`, `withdraw` and `redeem`, when the receiver and the owner are the calling account. Money and shares come back to the account, and everything else is refused.

- **contracts/portfolio/ERC4626CallValidator.sol**
- immutable, **no settings**
- attested as **VALIDATOR**

<a id="in-one-minute"></a>

> ### In one minute
>
> This lets a [GuardedAccount](GuardedAccount.md) run a strategy through an outside ERC-4626 vault without being able to send the shares or the money anywhere else. It has no settings: each permission names the vault, and this contract compares the receiver and the owner with the account making the call. With no settings there is one code hash, so one attestation covers every copy. At this commit no deployment profile deploys it, and `test_ItRunsAStrategyThroughAnOutsideVaultAndKeepsTheShares` shows it in use.

<a id="how"></a>
## What it accepts and refuses

`validate(account, target, data)` returns true or false. It ignores the target, and reads the selector first, then the length, then the arguments. A call too short to hold a selector is padded with zeros for the comparison, matches nothing and returns false.

| The call data | Answer | Test |
|---|---|---|
| `deposit(assets, receiver)` or `mint(shares, receiver)`, 68 bytes, with `receiver` the account | true | `test_EntryToTheAccountPasses` |
| `withdraw(assets, receiver, owner)` or `redeem(shares, receiver, owner)`, 100 bytes, with `receiver` and `owner` both the account | true | `test_ExitToTheAccountFromTheAccountPasses` |
| An entry to any other receiver | false | `testFuzz_EntryToAnyoneElseIsRefused` |
| An exit to any other receiver | false | `testFuzz_ExitToAnyoneElseIsRefused` |
| An exit from any other owner | false | `testFuzz_ExitFromAnyoneElseIsRefused` |
| Any other function, such as `transfer` or `approve` | false | `test_AnyOtherFunctionIsRefused` |
| One of the four functions at any other length, including extra bytes after a valid call | false | `test_AWrongLengthIsRefused` |
| Too short to hold a selector, or empty | false, with no revert | `test_AWrongLengthIsRefused` |
| The right selector and length, with non-zero bits in the unused upper part of an address word | reverts | None at this commit |

The last row is the one case that does not return false. The call reaches the decoder, which refuses a malformed address by reverting with no data, and `GuardedAccount.execute` reverts with that in place of `GuardedAccount_CallRefused`. Nothing runs either way.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `validate(account, target, data)` | Anyone (read-only) | The answer above. It is pure: it reads nothing but its arguments, and has no constructor, storage, events or errors. |

<a id="why"></a>
## Why it is built this way

- **The account is the only allowed receiver and owner.** So an allocator with this permission can move a position in and out of the vault, and neither the shares nor the money can leave the account through it.

<a id="limits"></a>
## What it does not do

- **It does not limit the amount.** A `deposit` also needs an allowance, which takes a separate `approve` permission, judged for example by an [ERC20CallValidator](ERC20CallValidator.md) naming the vault.
- **It does not look at the target.** A permission names the contract. The validator reads parameters and has no view of whether that contract is an honest ERC-4626 vault, or whether it pays the receiver it was given.
- **It does not get money past a pause.** A pause on the vault stops `GuardedAccount.execute`, so a `withdraw` or `redeem` through this permission waits for the unpause.
- **It does not bring money to the portfolio.** The money returns to the account, and the portfolio's `deallocate` then takes it from there.

<a id="connected"></a>
## Connected to

- [GuardedAccount](GuardedAccount.md): Calls it before each call a permission covers.
- [ERC20CallValidator](ERC20CallValidator.md): The other validator, for the approval a deposit needs.
- [PolicyRegistry](PolicyRegistry.md): Where its code hash must be attested as `VALIDATOR`.

<a id="source"></a>
## Source and tests

- Contract: `contracts/portfolio/ERC4626CallValidator.sol`, interface `ICallValidator.sol`
- Tests: `ERC4626CallValidator.t.sol`, and through an account in `GuardedAccount.t.sol`

---

Describes the contracts at commit `4a906cc` on `main`.
