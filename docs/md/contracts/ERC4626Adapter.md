[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Portfolio

# ERC4626Adapter

Holds a [Portfolio](Portfolio.md)'s position in one on-chain ERC-4626 vault, as an ordinary depositor. Its value is read from that vault, so the portfolio can count it without a report.

- **contracts/portfolio/ERC4626Adapter.sol**
- immutable, **not a proxy**
- attested as **ADAPTER**
- **priced**: **reported()** is false
- no roles, **one caller** for money

<a id="in-one-minute"></a>

> ### In one minute
>
> A portfolio does not talk to outside vaults itself. An outside ERC-4626 vault held as a priced position is called the target, and the portfolio reaches it through one of these. When the portfolio sends money, the adapter deposits it into the target and keeps the shares. When the portfolio asks for money back, the adapter withdraws and the target pays the portfolio directly. The adapter has no owner and no settings that change: the portfolio, the target and the risk ids are fixed at deployment, so the attested code hash covers them. That hash covers the target's address and not how the target behaves, so the contract leaves the target's behaviour to the council's decision to attest.

<a id="how"></a>
## How it works

1. **Money in: `allocate(assets)`.** The portfolio has just sent `assets` to the adapter. The adapter approves the target for exactly that amount with `forceApprove`, then calls `deposit(assets, address(this))`. The shares stay with the adapter, and a standard target leaves no allowance behind (`test_AllocatingDepositsWhatItWasSentAndLeavesNoAllowance`).
2. **Money out: `deallocate(assets)`.** The adapter calls `withdraw(assets, PORTFOLIO, address(this))`. The target burns the adapter's shares and pays the portfolio, and the function takes no receiver (`test_DeallocatingPaysOnlyThePortfolio`). The portfolio measures what arrived, and reverts with `Portfolio_ShortReturn` if it is short.
3. **Its worth: `value()`.** What the shares it holds would redeem for at the target's own price: `previewRedeem(balanceOf(address(this)))` on the target.
4. **Its risks: `riskIds()`.** Always `RISK_ID`, which is `keccak256(abi.encode('ERC4626Adapter', target))`, so it follows the target. Also `SHARED_RISK_ID` if that is not zero, for a [cap](Portfolio.md#caps) shared with other adapters.

What `value()`, `fresh()` and `liquid()` say depends on how the target answers. A failed read is treated as no answer, not as a loss: `fresh()` goes false, which stops dealing on a 4626 and stops a price being proposed at the desk.

| The target | Its value | Fresh | Liquid |
|---|---|---|---|
| Answers normally | The `previewRedeem` of its shares | true | The target's `maxWithdraw` for the adapter |
| Answers, and reports no liquidity | As above | true (`test_LiquidReadsTheTargetsLimit`) | 0 |
| Reverts on the read | 0 | false (`test_AFailedReadIsZeroAndNotFresh`) | 0 |
| Has no code, or answers with less than one word | 0 | false (`test_ATargetWithNoCodeIsZeroAndNotFresh`, `test_ATargetThatReturnsTooLittleIsZeroAndNotFresh`) | 0 |

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `allocate(assets)` | The portfolio, or `ERC4626Adapter_OnlyPortfolio` | Deposits into the target what it was sent. |
| `deallocate(assets)` | The portfolio, or `ERC4626Adapter_OnlyPortfolio` | Withdraws from the target, paid to the portfolio. |
| `value()`, `fresh()`, `liquid()` | Anyone (read-only) | What the position is worth, whether that could be read, and what could be returned at that moment. |
| `riskIds()`, `asset()`, `reported()` | Anyone (read-only) | The risks it counts against, the target's asset, and false for `reported()`. |
| `PORTFOLIO()`, `TARGET()`, `RISK_ID()`, `SHARED_RISK_ID()` | Anyone (read-only) | The settings fixed at construction. |
| The constructor | The deployer | Takes `(_portfolio, _target, _sharedRiskId)`, reverts with `ERC4626Adapter_ZeroAddress` on a zero portfolio or target, and asks the target for its `asset()`. |

It emits no events of its own. The portfolio's `Allocated` and `Deallocated` record each move.

<a id="why"></a>
## Why it is built this way

- **Every setting is an immutable.** Change the portfolio, the target or the shared risk and the code hash changes, so the council's attestation covers exactly this position (`test_TheCodehashCoversTheSettings`).
- **An exact approval for each deposit.** A standard target pulls what it was approved for, so it holds no standing allowance between moves.
- **A failed read is not a loss.** Marking a position to zero because a target is briefly unreachable would let someone buy cheap. Holding the last price and stopping dealing does not.

<a id="limits"></a>
## What it does not do

- **It does not judge the target's price.** `fresh()` means the reads succeeded, not that the number is right. A target that answers with a wrong price reads as fresh. On a 4626 a rate limit bounds how fast a gain can count, and a loss counts at once.
- **It does not cover the target's behaviour.** The code hash fixes the target's address. A target that can be upgraded can change after the review.
- **It does not check what a deposit returned.** The adapter reads nothing back from the shares it receives. The portfolio's `_minAdded` is the floor, and the allocator chooses it.
- **It does not promise `liquid()`.** That is what the target's `maxWithdraw` says. If the target delivers less, the `withdraw` or the portfolio's check reverts.
- **It does not move anything else.** No function moves a balance of the asset held by the adapter itself, and `value()` does not count one, so the asset sent straight to it stays there. Target shares sent to it do count in `value()`. It has no function to claim rewards or move other tokens.
- **It does not look at a pause.** The portfolio's `allocate` does that, and the adapter's `deallocate` runs whenever the portfolio asks.

<a id="connected"></a>
## Connected to

- [Portfolio](Portfolio.md): The one contract that moves money through it, and that counts its value.
- [Gated4626Vault](Gated4626Vault.md): An instant vault can invest only through priced adapters such as this.
- [PolicyRegistry](PolicyRegistry.md): Where its code hash must be attested as `ADAPTER`.
- [GuardedAccount](GuardedAccount.md): The other adapter: reported, for money that can sit off-chain.

<a id="source"></a>
## Source and tests

- Contract: `contracts/portfolio/ERC4626Adapter.sol`, interfaces `IERC4626Adapter.sol` and `IAdapter.sol`
- Tests: `ERC4626Adapter.t.sol`, `Portfolio.t.sol` (`PortfolioIntegrationTest`, with a real target), `Gated4626VaultPortfolio.t.sol`, and `test/nodejs/legos.test.ts`

---

Describes the contracts at commit `18e60b3` on `paris`.
