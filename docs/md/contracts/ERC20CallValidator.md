[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Portfolio

# ERC20CallValidator

Judges a token call for a [GuardedAccount](GuardedAccount.md): a `transfer` to one address, or an `approve` of one spender, up to one amount per call. It refuses everything else.

- **contracts/portfolio/ERC20CallValidator.sol**
- immutable, **no storage**
- attested as **VALIDATOR**

<a id="in-one-minute"></a>

> ### In one minute
>
> A [GuardedAccount](GuardedAccount.md) permission says which function of which contract may be called, and this contract says with which parameters. It holds two settings, the one address allowed (`WHO`) and the most one call may name (`MAX_PER_CALL`), both immutable, so the attested code hash covers the exact address and amount. A custodian is an account with one permission, the asset's `transfer`, judged by one of these naming the custodian.

<a id="how"></a>
## What it accepts and refuses

`validate(account, target, data)` returns true or false. It looks at `data` alone: the account and the target are ignored, because the permission already names the target. It checks the length first, then the selector, then decodes the two arguments.

| The call data | Answer | Test |
|---|---|---|
| `transfer(WHO, amount)` with `amount` up to `MAX_PER_CALL`, zero included | true | `testFuzz_ATransferToTheOneAddressUpToTheAmountPasses` |
| `approve(WHO, amount)` with `amount` up to `MAX_PER_CALL`, zero included | true | `testFuzz_AnApprovalOfTheOneSpenderUpToTheAmountPasses` |
| Either of those with one more than `MAX_PER_CALL` | false | `test_OneAboveTheAmountIsRefused` |
| Either of those naming any other address | false | `testFuzz_AnyOtherAddressIsRefused` |
| `transferFrom`, which is longer | false | `test_TransferFromIsRefused` |
| Another function of the same shape, such as `increaseAllowance` or `mint` | false | `test_AnyOtherFunctionWithTheSameShapeIsRefused` |
| Any length but 68 bytes, including extra bytes after a valid call | false | `testFuzz_AnyOtherLengthIsRefused`, `test_ExtraDataIsRefused` |
| Too short to hold a selector, or empty | false, with no revert | `test_TooShortIsRefusedRatherThanReverting` |
| 68 bytes and the right selector, with non-zero bits in the unused upper part of the address word | reverts | None at this commit |

The last row is the one case that does not return false. The call has the right length and selector, so it reaches the decoder, and the decoder refuses a malformed address by reverting with no data. `GuardedAccount.execute` then reverts with that empty revert in place of `GuardedAccount_CallRefused`. Nothing runs either way.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `validate(account, target, data)` | Anyone (read-only) | The answer above. It is a view, so it changes nothing. |
| `WHO()`, `MAX_PER_CALL()` | Anyone (read-only) | The one address allowed, and the most one call may name. |
| The constructor | The deployer | Takes `(who, maxPerCall)` and reverts with `ERC20CallValidator_ZeroAddress` on a zero address. A `maxPerCall` of zero is accepted, and then only zero amounts pass. |

<a id="why"></a>
## Why it is built this way

- **An exact length.** Extra bytes after a valid call cannot pass unread.
- **The selector is read here as well.** `increaseAllowance` has the same arguments as `approve`, so a check on the arguments alone would pass it.

<a id="limits"></a>
## What it does not do

- **It does not keep a total.** It has no storage, so `MAX_PER_CALL` applies to each call. Several transfers, in one batch or many, can send more. The portfolio's [caps](Portfolio.md#caps) limit what reaches the account.
- **It does not separate `transfer` from `approve`.** It accepts both. Which one an account may make depends on the permission's selector: the deployment module grants only `transfer` for a custodian.
- **It does not look at the token.** The permission names the target, and the validator would accept the same call on any token it was attached to.
- **An approval is not undone by a revoke.** See the [GuardedAccount page](GuardedAccount.md#limits).

<a id="connected"></a>
## Connected to

- [GuardedAccount](GuardedAccount.md): Calls it before each call a permission covers.
- [ERC4626CallValidator](ERC4626CallValidator.md): The other validator, for entering and leaving an outside vault.
- [PolicyRegistry](PolicyRegistry.md): Where its code hash must be attested as `VALIDATOR`.

<a id="source"></a>
## Source and tests

- Contract: `contracts/portfolio/ERC20CallValidator.sol`, interfaces `IERC20CallValidator.sol` and `ICallValidator.sol`
- Tests: `ERC20CallValidator.t.sol`, and through an account in `GuardedAccount.t.sol`
