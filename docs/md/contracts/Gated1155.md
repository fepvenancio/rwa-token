[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Token

# Gated1155

The multi-token template. One contract holds many token ids, each with its own balances, supply and metadata URI. Every movement of an amount of an id asks the same policy hook and rules as the other templates before it happens.

- **contracts/tokens/Gated1155.sol**
- upgradeable: **UUPS**, behind a **TokenProxy**
- admin: **the main timelock**, after hand-over
- implementation attested as **IMPLEMENTATION**

<a id="in-one-minute"></a>

> ### In one minute
>
> A product for several series of one instrument in one contract. Each series is a token id with its own supply, and all of them are under one set of eligibility terms.
>
> It is an ERC-1155, with OpenZeppelin's supply and URI extensions, built on [`PolicyGatedCoreUpgradeable`](PolicyGatedCoreUpgradeable.md), so its roles, guardian, pause, hook and upgrade checks are the same code as every other template's. One policy judges every id alike: who may hold, and each holder's lockup and freeze, come from the rules the product lists, and those rules do not read the token id. It also speaks ERC-7943's interface for multi-tokens: the agent can force an amount of an id to another holder and freeze an amount of one id for one account.

<a id="how"></a>
## How a movement is decided

Transfers and mints reach OpenZeppelin's `_update`, which the token overrides to take the items one at a time. A forced transfer and the burner's `burn` go straight to the token's movement path, `_move`, as FORCED. For each item the checks run in this order:

1. **ERC-1155's own checks.** On a transfer, the caller must be the holder or approved for all of the holder's tokens (`ERC1155MissingApprovalForAll`), and the hook is not asked (`test_WhenTheCallerIsNotApproved_Erc1155RevertsBeforeTheHookIsAsked`). A zero receiver reverts with `ERC1155InvalidReceiver` and a zero sender with `ERC1155InvalidSender`. A batch whose two arrays differ in length reverts with `ERC1155InvalidArrayLength`.
2. **Pause.** While paused, every kind except FORCED is refused with `ERC8473PolicyRejected(PAUSED)`. That stops transfers, batches and mints. A forced transfer and the burner's `burn` pass (`test_WhenPaused_TransfersAndMintsAreRejectedAndTheEnforcementBurnPasses`, `test_WhenPaused_TheBatchIsRejected`).
3. **The balance and the frozen amount.** The amount must fit in the sender's unfrozen balance of that id. An amount above the balance reverts with ERC-1155's `ERC1155InsufficientBalance`, and the hook is not asked (`test_WhenTheAmountIsAboveTheBalance_ItRevertsWithErc1155sErrorWithoutAskingTheHook`). An amount within the balance but above its unfrozen part reverts with `ERC7943InsufficientUnfrozenBalance(account, tokenId, amount, unfrozen)`. A FORCED movement may take frozen tokens, never more than the balance. See [Freezes](#freeze).
4. **The hook decides.** `checkTransfer(ctx)` returns `TRANSFER_OK` or a reason, and anything else reverts with `ERC8473PolicyRejected(reason)`. The call goes through [the core's `_ask`](PolicyGatedCoreUpgradeable.md#asking): a hook that reverts, runs out of gas, answers fewer than 32 bytes or has no code gives the reason `CHECK_UNAVAILABLE`. A zero amount and a transfer to oneself are movements too, and the hook is asked about each (`test_WhenTheAmountIsZeroOrTheReceiverIsTheSender_ThePolicyIsStillAsked`).
5. **The amount moves** with OpenZeppelin's logic, which updates the supply of the id and emits `TransferSingle`.
6. **After the move,** `afterTransfer(ctx)` runs if the hook's `wantsAfterTransfer()` is true, which the shared hook's always is, inside the token's reentrancy guard: a hook or rule that starts another movement reverts with `ReentrancyGuardReentrantCall` (`test_WhenThePolicyCallsBackInTheMiddleOfABatch_TheGuardRefusesIt`). The supply of the id already counts the move when it runs (`test_WhenTheSupplyIsReadDuringAfterTransfer_ItAlreadyCountsTheMint`).

<a id="batch"></a>
## A batch is its items in order

`safeBatchTransferFrom` takes the items in the order given. Each one is checked, moved, announced with its own `TransferSingle` and reported to the policy before the next one is checked. No `TransferBatch` is emitted (`test_WhenABatchMoves_ThePolicyIsAskedAboutEachItemInOrder`, `test_WhenABatchMoves_EachItemEmitsItsOwnTransferSingleAndNoTransferBatch`, `test_WhenABatchMoves_AfterTransferFollowsEachItemBeforeTheNextMoves`).

- **A later item sees what the earlier ones left.** An id named twice is two movements, and the second is judged against the balance after the first (`test_WhenAnIdIsNamedTwice_TheSecondItemSeesTheBalancesTheFirstLeft`, `test_WhenAnIdNamedTwiceExceedsTheBalance_TheSecondItemRevertsTheBatch`).
- **One refused item reverts the whole batch.** The items before it are undone (`test_WhenThePolicyRejectsALaterItem_TheEarlierItemsAreUndone`, `test_WhenALaterItemIsAboveItsUnfrozenBalance_TheBatchReverts`).
- **An empty batch moves nothing.** It asks no policy, emits nothing and calls nobody, also while paused (`test_WhenTheBatchIsEmpty_NobodyIsAskedAndNothingIsEmitted`, `test_WhenPaused_AnEmptyBatchCallsNobody`).
- **The issuer has no batch functions.** A role holder batches `mint`, `burn` or `forcedTransfer` with the core's `multicall`, and each call is a movement of its own.

<a id="callback"></a>
## The receiver callback

When the receiver is a contract, the token calls ERC-1155's receiver function on it after the movement, outside the reentrancy guard, with the balances final. It does so on every path into a contract: both transfer functions, `mint` and `forcedTransfer`. A contract that answers anything but acceptance, or has no `IERC1155Receiver` function to answer with, reverts the call with `ERC1155InvalidReceiver` (`test_WhenTheReceivingContractHasNoReceiverInterface_EveryPathRefusesIt`). A burn calls nobody.

| Path | Callback | When |
|---|---|---|
| `safeTransferFrom` | `onERC1155Received`, with the caller's `data` | After the item's `afterTransfer` |
| `safeBatchTransferFrom` | One `onERC1155BatchReceived`, with the caller's `data`, also when the batch has one item. None for an empty batch | Once, after the last item's `afterTransfer` |
| `mint` | `onERC1155Received`, with empty data and the minter as operator | After the mint's `afterTransfer` |
| `forcedTransfer` | `onERC1155Received`, with empty data and the agent as operator | Last, after `ForcedTransfer` and `ForcedTransferBy` |
| `burn` | None |  |

The tests are in `Gated1155Unit_Callbacks`: `test_WhenAMintGoesToAContract_ItIsCalledAfterAfterTransfer`, `test_WhenAForcedTransferGoesToAContract_ItIsCalledAfterAfterTransfer`, `test_WhenABatchGoesToAContract_ItGetsOneBatchCallbackAfterTheLastItem`, `test_WhenABatchOfOneGoesToAContract_ItGetsTheBatchCallback` and `test_WhenAnEmptyBatchGoesToAContract_NoCallbackIsMade`. The token's own `safeBatchTransferFrom` decides the batch callback itself: an empty batch calls nobody, so no caller can make the token call a contract with data of its choosing.

A receiver that moves the tokens on from its callback takes the same path as anyone, and a refusal of that second move undoes both (`test_WhenTheReceiverForwardsFromItsCallback_ThePolicyJudgesThatMoveToo`, `test_WhenTheReceiverForwardsABatchFromItsCallback_EachItemIsJudgedAgain`). The `data` of a transfer goes to the receiver alone and never to the policy (`test_WhenTheTransferCarriesData_ItReachesTheReceiverAndNotThePolicy`).

<a id="context"></a>
## What the hook is told

The same `TransferContext` as the other templates', one for each item, so the same hook and the same rule instances serve them all.

| Field | Value |
|---|---|
| `token` | The multi-token's own address |
| `from`, `to` | Sender and receiver; zero on a mint and a burn respectively |
| `tokenId` | The token id of the item |
| `amount` | The amount of that id |
| `operator` | The caller: the holder or an approved operator, the minter, the burner, or the agent. In a pre-flight it is `from` |
| `kind` | TRANSFER from `safeTransferFrom` and `safeBatchTransferFrom`, MINT from `mint`, FORCED from `forcedTransfer` and `burn`. The template has no holder burn, so nothing moves as BURN: that kind appears only in a pre-flight with a zero `to`. There is no EXECUTED: the template has no signed intents. |
| `data` | `abi.encode(fromBalance, toBalance)`: each side's balance of that id before the move, zero for the zero address |

The tests compare the context with what each route sends: `test_WhenTheHolderTransfers_TheHookSeesATransferWithTheIdsBalances`, `test_WhenAnApprovedOperatorTransfers_TheOperatorIsInTheContext`, `test_WhenTheMinterMints_TheHookSeesAMintOfTheIdAndTheSupplyRises`, `test_WhenTheBurnerBurns_ThePolicySeesAForcedMovementToZeroAndTheSupplyFalls` and `test_WhenTheAgentForces_TheHookSeesAForcedMoveAndBothEventsCarryTheIdAndTheAmount`.

<a id="rules"></a>
## Which rules fit a multi-token

No shipped rule reads `tokenId`, and each keys its settings and state by the token's address. So one rule list and one set of settings judge every id of the contract alike.

| Rule | On a `Gated1155` |
|---|---|
| [`CredentialRule`](CredentialRule.md) | Works as on any token: who may receive, and that a sender may leave, the same for every id. The `multi` profile lists it. |
| [`HolderRestrictionRule`](HolderRestrictionRule.md) | Works as on any token: a holder's lockup or address freeze covers every id it holds (`test_WhenTheHolderIsLocked_ItCanSendNoIdAndTheAgentCanStillForce`). The `multi` profile lists it. |
| [`MinPositionRule`](MinPositionRule.md) | Allowed by the profile check. It reads the two balances in `data`, which here are balances of the item's id, so it judges the position in each id, with one minimum for all of them. |
| [`FundHoldersRule`](FundHoldersRule.md) | Refused by the profile check. A `Fund` registers only a token that reports `IPolicyGated`, which the multi-token does not, so on chain the rule would refuse every movement with `NOT_FUND_CLASS`. A list can add the rule only while the contract's total supply is zero. |
| [`SupplyCapRule`](SupplyCapRule.md) | Refused by the profile check, and only by it. The rule reads `totalSupply()`, which here is the sum over every id, so on chain it would cap the mints of all ids together. |
| [`SettlementWindowRule`](SettlementWindowRule.md), [`ExecutedOnlyRule`](ExecutedOnlyRule.md) | Refused, as on every template without signed intents. |

<a id="freeze"></a>
## Freezes

ERC-7943's freeze for multi-tokens is an amount for one account and one token id. The agent sets it with `setFrozenTokens(account, tokenId, amount)`, which overwrites the previous value and emits `Frozen(account, tokenId, amount)` (`test_WhenTheAgentFreezes_ItEmitsFrozenAndOverwrites`). It may exceed the balance (`test_WhenTheAmountExceedsTheBalance_ItIsStillRecorded`). A freeze of one id leaves the account's other ids free (`test_WhenOneIdIsFrozen_AnotherIdIsFree`).

- **The holder and its operators** can move the unfrozen balance of an id and no more: the balance less the frozen amount, or nothing when the frozen amount is the larger (`test_WhenPartIsFrozen_TheHolderAndItsOperatorMoveExactlyTheUnfrozenPart`, `test_WhenTheFrozenAmountExceedsTheBalance_NothingMovesAndAnAmountAboveTheBalanceIsErc1155s`).
- **Enforcement takes frozen tokens as needed.** `forcedTransfer` and `burn` lower the frozen amount by exactly the part of the amount that was frozen, emitting `Frozen` with the new amount before `TransferSingle`, as ERC-7943 asks. An action that stays within the unfrozen balance leaves the frozen amount alone. If the hook then refuses, the whole call reverts and the frozen amount stays (`test_WhenTheBurnTakesFrozenTokens_TheFrozenAmountFallsByThePartTakenBeforeTheTransferEvent`, `test_WhenTheFrozenAmountExceedsTheBalance_ItLosesExactlyWhatLeaves`, `test_WhenTheBurnStaysWithinTheUnfrozenBalance_TheFrozenAmountStays`, `test_WhenTheHookRejects_TheBalanceAndTheFrozenAmountStay`).
- **The invariants** `invariant_AHolderMovesAtMostItsUnfrozenBalance` and `invariant_TheBalancesOfEachIdAddUpToItsSupply` drive random transfers, freezes, mints, forced transfers and burns over three ids. They check that a holder moves up to its unfrozen balance of an id and no more, that enforcement lowers the frozen amount by exactly the frozen part it takes, and that the balances of each id add up to its supply.
- **An address freeze is a different tool:** it is `HolderRestrictionRule`'s, in the hook, and stops an account sending or receiving any id. It does not stop enforcement out of the account: the rule exempts FORCED on the sender's side. A frozen receiver cannot receive even by force (`test_WhenTheReceiverIsFrozenByTheRule_ItCannotReceiveEvenByForce`).

<a id="preflight"></a>
## Asking before moving

`canTransferWithReason(from, to, tokenId, amount)` runs the checks of the path for one item without moving anything. A zero `from` reads as a mint and a zero `to` as a burn; both zero reads `ZERO_RECEIVER`, and the hook is not asked (`test_WhenBothAddressesAreZero_ItReadsFalseWithoutAskingTheHook`). The operator is `from`, which is the zero address for a mint, so the answer does not depend on who asks (`testFuzz_WhenAnyoneAsks_TheOperatorSimulatedIsTheSender`). No pre-flight simulates FORCED, so none predicts `burn` or `forcedTransfer`. A burn asked about is answered as a holder's own burn would be, which the template does not have: a frozen amount or a holder's lockup refuses it, whoever asks, while `burn` itself still takes the tokens (`test_WhenTheBurnerAsksAboutBurningFrozenTokens_ItGetsTheHoldersAnswerAndTheBurnStillPasses`, `test_WhenTheHolderIsLocked_TheBurnerCanStillBurn`). `burn` of an amount within the balance succeeds exactly when the hook accepts the forced movement, frozen or not, paused or not (`testFuzz_TheEnforcementBurnFollowsThePolicyAlone`). Approval and the receiver callback are not judged. No pre-flight takes a batch: ask about each item, and when a batch names an id twice the later answers depend on the earlier moves.

| Situation | `canTransferWithReason` | `canTransfer` |
|---|---|---|
| The amount fits the unfrozen balance, hook accepts | true, `TRANSFER_OK` | true |
| The amount is above the balance, and nothing of that id is frozen for `from` | false, `INSUFFICIENT_UNFROZEN` | true, if nothing else refuses |
| The amount is above the unfrozen balance, and some of that id is frozen for `from` | false, `INSUFFICIENT_UNFROZEN` | false |
| Paused | false, `PAUSED` | false |
| A rule refuses | false, the rule's reason | false |

`canTransfer` is ERC-7943's yes or no. The standard says it must not answer no for a balance check and must count the frozen amount. So with nothing frozen an amount above the balance reads true when the policy accepts it, and the write reverts with `ERC1155InsufficientBalance`; while part of the id is frozen, an amount above the unfrozen balance reads false (`test_WhenTheAmountIsAboveTheBalanceAndNothingIsFrozen_OnlyTheReasonedPreflightSaysSo`, `test_WhenPartOfTheIdIsFrozen_AnAmountAboveTheUnfrozenBalanceReadsFalse`, `testFuzz_CanTransferIsNeverFalseForABalance`). `testFuzz_ThePreflightAgreesWithTheWrite` fuzzes the sender, the amount, the frozen amount, the pause and the hook's answer, and compares `canTransferWithReason` with a real transfer.

`canSend(account)` and `canReceive(account)` are the account questions. They take no token id, so they answer for the contract. They are true for the zero address, and the hook is not asked. For any other account they are false while paused, with no hook, or when the hook cannot be asked, and otherwise the hook's account answers. Through the shipped rules, `canTransfer` is never true while either account answer is false (`testFuzz_CanTransferIsNotTrueWhileAnAccountAnswerIsFalse`).

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `initialize(name, symbol, admin, guardian, registry, hook, _initialRules)` | Once per proxy; `ProxyDeployer` runs it in the transaction that creates the proxy | Sets the name and symbol, then the core: roles, registry, hook and the rule list. See [the core's setup](PolicyGatedCoreUpgradeable.md#setup). |
| `mint(to, tokenId, amount)` | `MINTER_ROLE` | Creates an amount of the id for `to`, decided as MINT. A zero receiver reverts with `ERC1155InvalidReceiver`. Emits `TransferSingle`, then calls a receiving contract. |
| `burn(from, tokenId, amount)` | `BURNER_ROLE` | Destroys an amount of the id without approval, taking frozen tokens as needed, also while paused. Decided as FORCED with a zero receiver. A zero `from` reverts with `ERC1155InvalidSender`, and an amount above the balance with `ERC1155InsufficientBalance`, before the hook is asked. |
| `forcedTransfer(from, to, tokenId, amount)` | `AGENT_ROLE` | Moves an amount of the id without the holder's consent, also while paused, taking frozen tokens as needed. Decided as FORCED, so the rules still judge the receiver. Emits `TransferSingle`, then `ForcedTransfer(from, to, tokenId, amount)` and `ForcedTransferBy(from, to, tokenId, amount, agent)`, then calls a receiving contract. Returns `true`. |
| `setFrozenTokens(account, tokenId, amount)` | `AGENT_ROLE` | Sets the frozen amount of one id for one account. Returns `true`. Works while paused. |
| `setURI(tokenId, uri)` | `AGENT_ROLE` | Replaces the metadata URI of one id and emits ERC-1155's `URI` for that id (`test_WhenTheAgentSetsTheUri_ItEmitsUriForThatIdAlone`). |
| `safeTransferFrom`, `safeBatchTransferFrom` | The holder, or an operator approved for all | ERC-1155's transfers, each item decided as TRANSFER. |
| `setApprovalForAll` | Any account, for itself | OpenZeppelin's ERC-1155. An approval moves nothing, so the hook is not asked. |
| `getFrozenTokens(account, tokenId)`, `canTransfer`, `canTransferWithReason`, `canSend`, `canReceive` | Anyone (read-only) | The frozen amount and the pre-flight answers above. |
| `balanceOf`, `balanceOfBatch`, `isApprovedForAll`, `uri`, `totalSupply(id)`, `totalSupply()`, `exists` | Anyone (read-only) | OpenZeppelin's ERC-1155 reads, with the supply of each id and of all ids together. `uri` is empty for an id whose URI was never set. |
| `name()`, `symbol()` | Anyone (read-only) | The collection's name and symbol, set at initialisation. ERC-1155 has neither; `ProxyDeployer` reads the symbol. |
| `templateId()` | Anyone (read-only) | `keccak256('Gated1155')` |
| Pause, hook, roles, upgrades, `multicall` | From [the core](PolicyGatedCoreUpgradeable.md#functions). An agent can freeze and force in one `multicall` (`test_WhenTheAgentBatchesCalls_MulticallRunsThemAsTheAgent`). |  |

`supportsInterface` answers true for `IGated1155` (`0xc12446d8`), `IERC7943MultiToken` (`0x41c4fbad`), `IPolicyGatedCore`, `IERC8473` (`0x0505c8c9`), ERC-1155, its metadata URI extension, `IAccessControl` and `IERC165`, and false for `IPolicyGated`, the fungible `0x3edbb4c4` and the NFT `0xbf1ef5fe` (`test_WhenQueried_ItSupportsItsInterfacesAndNotTheOtherTemplates`). `ForcedTransfer`, `ForcedTransferBy` and `Frozen` carry the token id and the amount, so none shares a topic with the other templates' events. The standard indexes the token id in `ForcedTransfer` and `Frozen`.

<a id="errors"></a>
## What a refused movement reverts with

| Cause | Error |
|---|---|
| The amount is above the sender's balance of the id | ERC-1155's `ERC1155InsufficientBalance(sender, balance, needed, tokenId)` |
| The amount is within the balance but above its unfrozen part, on a movement that is not FORCED | `ERC7943InsufficientUnfrozenBalance(account, tokenId, amount, unfrozen)` |
| The pause, a rule's refusal, or a hook that cannot be asked | `ERC8473PolicyRejected(reason)` |

A hook that answers `INSUFFICIENT_UNFROZEN` when the token finds no shortfall is a policy decision, and reverts with `ERC8473PolicyRejected` (`test_WhenTheHookBorrowsTheFrozenCodeWithNoShortfall_ItIsAPolicyRejection`). While paused, the pause is the first refusal, so a transfer above the balance reverts with `ERC8473PolicyRejected(PAUSED)`.

<a id="why"></a>
## Why it is built this way

- **The same hook, not a second one.** One attested hook serves every token of a deployment, with a rule list per token. The rules read who, which kind and the balances in the context, so they serve a multi-token unchanged.
- **One policy for the contract.** The account questions of ERC-7943 and ERC-8473, `canSend`, `canReceive`, `checkSend` and `checkReceive`, take no token id, so who may hold cannot differ by id and still be told to an integrator.
- **Items one at a time.** ERC-8473 has a token check, move, announce and report each item of a batch before the next, and ERC-1155 allows a `TransferSingle` for each. A register rebuilt from the events reads one movement per event.
- **A supply for each id.** The issued amount of each series is readable on chain, and it is current when `afterTransfer` runs.
- **A callback on every path into a contract, after the policy.** ERC-1155 has a mint and a non-standard transfer follow its receiver rules, so `mint` and `forcedTransfer` make the callback too. It comes after `afterTransfer` and outside the guard.
- **Pre-flights that do not depend on who asks.** The operator simulated is `from`, zero for a mint, so every caller gets the same answer. Enforcement is not simulated: `burn` and `forcedTransfer` are the issuer's own actions.

<a id="limits"></a>
## What it does not do

- **No terms per id.** Eligibility, lockup and address freeze are the contract's. Series that differ in who may hold them, or in their holding period, are separate contracts. No shipped rule reads the token id.
- **No cap on holders or on supply.** The profile check refuses `FundHoldersRule` and `SupplyCapRule` on this template, and no other shipped rule caps the holders or the supply of an id.
- **No signed transfers and no delivery versus payment.** An amount moves by a transaction of its holder or an approved operator, or by the agent.
- **No vault over it.** The vault templates issue ERC-20 shares over an ERC-20 asset.
- **No holder burn.** `burn` needs `BURNER_ROLE`.
- **No approval for one id, no `permit`, no royalties.** `setApprovalForAll` names an operator for all of a holder's ids, and the token does not restrict it.
- **The refusal of an unusable rule is off-chain.** `assertUsable` in `ignition/profiles.ts` stops it when the module is built. `ComplianceHook.setRules` judges no combination of attested rules, so a timelock operation could still list one, with the effects in [the table above](#rules).
- **It cannot be a fund class.** `Fund` registers fungible gated tokens only.
- **The metadata is off-chain.** The token stores a URI for each id and checks nothing about what it points to.

<a id="connected"></a>
## Connected to

- [PolicyGatedCoreUpgradeable](PolicyGatedCoreUpgradeable.md): The roles, pause, hook and upgrade checks it shares.
- [GatedToken](GatedToken.md): The plain fungible template on the same core.
- [Gated721](Gated721.md): The NFT template on the same core.
- [ComplianceHook](ComplianceHook.md): Runs this token's rules on every movement.
- [CredentialRule](CredentialRule.md): Who may hold any id.
- [HolderRestrictionRule](HolderRestrictionRule.md): Each holder's lockup and address freeze, for every id.
- [ProxyDeployer](ProxyDeployer.md): Places the multi-token and checks it came up as expected.
- [Deployment and governance](../deployment.md): The `multi` profile, and how a product is handed over.

<a id="source"></a>
## Source and tests

- Contract: `contracts/tokens/Gated1155.sol`; interfaces `IGated1155.sol`, `IERC7943MultiToken.sol`, `IPolicyGatedCore.sol`
- Deployment: `ignition/profiles.ts` (the `multi` profile, `assertUsable`), `ignition/modules/Product.ts`
- Tests: `Gated1155.t.sol` (unit tests with a mocked hook or a recording policy, the two invariants, and an integration on the real hook, `CredentialRule` and `HolderRestrictionRule` through `ProxyDeployer`), `InterfaceFreeze.t.sol` (the two interface ids and the three event topics), `test/nodejs/products.test.ts` (the deployed `multi` profile with a batch across two ids, the refused rules, and `minPositionRule` accepted)

---

Describes the contracts at commit `75aa171` on `main`.
