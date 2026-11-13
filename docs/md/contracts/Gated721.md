[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Token

# Gated721

The NFT template. Each token is one item, with its own owner and its own metadata URI. Every movement of a token asks the same policy hook and rules as the other templates before it happens.

- **contracts/tokens/Gated721.sol**
- upgradeable: **UUPS**, behind a **TokenProxy**
- admin: **the main timelock**, after hand-over
- implementation attested as **IMPLEMENTATION**

<a id="in-one-minute"></a>

> ### In one minute
>
> A product for unique items: a certificate, a note with its own terms, a receipt for something held elsewhere. The terms live in the metadata the URI points to; the token records who owns each item and lets the issuer correct the URI.
>
> It is an ERC-721 built on [`PolicyGatedCoreUpgradeable`](PolicyGatedCoreUpgradeable.md), so its roles, guardian, pause, hook and upgrade checks are the same code as every other template's. Who may hold an item, and each holder's lockup and freeze, come from the rules the product lists, as on a fungible token. It also speaks ERC-7943's interface for NFTs: the agent can force an item to another holder and freeze one item for one account.

<a id="how"></a>
## How a movement is decided

Transfers and mints reach OpenZeppelin's `_update`, which the token overrides. A forced transfer and the burner's `burn` go straight to the token's movement path, `_move`, as FORCED. The checks run in this order:

1. **ERC-721's own checks.** On a transfer, the caller must be the owner or approved for the item (`ERC721InsufficientApproval`, or `ERC721NonexistentToken` for a token that does not exist), and the hook is not asked (`test_WhenTheCallerIsNotApproved_ErcSevenTwentyOneRevertsBeforeTheHookIsAsked`). A transfer to the zero address reverts with `ERC721InvalidReceiver`. `mint` refuses an id that exists, and `burn` one that does not, before the hook is asked. On a transfer, a `from` that is not the owner reverts with `ERC721IncorrectOwner`, which OpenZeppelin checks after the move: when the pause, the freeze or the hook refuses first, that is the revert, judged against the real owner. `forcedTransfer` checks `from` up front, before the pause, the freeze and the hook.
2. **Pause.** While paused, every kind except FORCED is refused with `ERC8473PolicyRejected(PAUSED)`. That stops transfers and mints. A forced transfer and the burner's `burn` pass (`test_WhenPaused_TransfersAndMintsAreRejectedAndTheEnforcementBurnPasses`).
3. **The freeze.** An item frozen for its owner cannot be moved by the owner or an approved operator: `ERC7943InsufficientUnfrozenBalance(owner, tokenId)`. A FORCED movement may take it: a forced transfer or the burner's `burn`. See [Freezes](#freeze).
4. **The hook decides.** `checkTransfer(ctx)` returns `TRANSFER_OK` or a reason, and anything else reverts with `ERC8473PolicyRejected(reason)`. The call goes through [the core's `_ask`](PolicyGatedCoreUpgradeable.md#asking): a hook that reverts, runs out of gas, answers fewer than 32 bytes or has no code gives the reason `CHECK_UNAVAILABLE`.
5. **The item moves** with OpenZeppelin's logic, which clears its approval and emits `Transfer`.
6. **After the move,** `afterTransfer(ctx)` runs if the hook's `wantsAfterTransfer()` is true, which the shared hook's always is, inside the token's reentrancy guard: a hook or rule that starts another movement reverts with `ReentrancyGuardReentrantCall` (`test_WhenTheHookCallsBackIntoTheToken_TheGuardRefusesIt`).

`safeTransferFrom` calls the receiver's `onERC721Received` after all of that, outside the guard. A receiver that moves the item on from there takes the same path as anyone, and a refusal of that second move undoes both (`test_WhenTheReceiverForwardsTheTokenFromItsCallback_ThePolicyJudgesThatMoveToo`). `mint` calls no receiver.

<a id="context"></a>
## What the hook is told

The same `TransferContext` as a fungible token's, so the same hook and the same rule instances serve both.

| Field | Value |
|---|---|
| `token` | The NFT's own address |
| `from`, `to` | Owner and receiver; zero on a mint and a burn respectively |
| `tokenId` | The token id |
| `amount` | Always 1 |
| `operator` | The caller: the owner or an approved operator, the minter, the burner, or the agent. In a pre-flight it is `from` |
| `kind` | TRANSFER from `transferFrom` and `safeTransferFrom`, MINT from `mint`, FORCED from `forcedTransfer` and `burn`. The NFT has no holder burn, so no item moves as BURN: that kind appears only in a pre-flight with a zero `to`. There is no EXECUTED: the NFT has no signed intents. |
| `data` | `abi.encode(fromBalance, toBalance)`: how many items each side held before the move, zero for the zero address |

The tests compare the context with what each route sends: `test_WhenTheOwnerTransfers_TheHookSeesATransferWithTheHoldings`, `test_WhenAnApprovedOperatorTransfers_TheOperatorIsInTheContext`, `test_WhenTheMinterMints_TheHookSeesAMintOfOneAndTheTokenHasItsUri`, `test_WhenTheBurnerBurns_ThePolicySeesAForcedMovementToZeroAndTheTokenIsGone` and `test_WhenTheAgentForces_TheHookSeesAForcedMoveAndBothEventsCarryTheToken`.

<a id="rules"></a>
## Which rules fit an NFT

| Rule | On a `Gated721` |
|---|---|
| [`CredentialRule`](CredentialRule.md) | Works as on any token: who may receive an item, and that a sender may leave. The `nft` profile lists it. |
| [`HolderRestrictionRule`](HolderRestrictionRule.md) | Works as on any token: a holder's lockup and an address freeze. The `nft` profile lists it. |
| [`MinPositionRule`](MinPositionRule.md) | Refused by the profile check. On chain it would count items, which means nothing for unique ones. |
| [`FundHoldersRule`](FundHoldersRule.md) | Refused by the profile check. A `Fund` registers only a token that reports `IPolicyGated`, which the NFT does not, so on chain the rule would refuse every movement with `NOT_FUND_CLASS`. |
| [`SupplyCapRule`](SupplyCapRule.md) | Refused by the profile check. It reads an ERC-20 `totalSupply`, which the NFT does not have, so on chain the rule's check of a mint would revert: every mint would revert with `ERC8473PolicyRejected(CHECK_UNAVAILABLE)`, and the pre-flight of one would read false with that reason. |
| [`SettlementWindowRule`](SettlementWindowRule.md), [`ExecutedOnlyRule`](ExecutedOnlyRule.md) | Refused, as on every template without signed intents. |

<a id="freeze"></a>
## Freezes

ERC-7943's freeze for NFTs is a yes or no for one account and one token id. The agent sets it with `setFrozenTokens(account, tokenId, frozenStatus)`, which overwrites the previous value and emits `Frozen(account, tokenId, frozenStatus)`. It may name an item the account does not hold (`test_WhenTheAccountDoesNotHoldTheToken_TheFreezeIsStillRecorded`), and an item that later reaches that account arrives frozen (`test_WhenTheTokenReachesAnAccountFrozenForIt_ItArrivesFrozen`). A freeze for another account does not stop the owner.

- **The owner and approved operators** cannot move a frozen item (`test_WhenFrozen_NeitherTheOwnerNorAnApprovedOperatorCanMoveIt`).
- **Enforcement clears it.** `forcedTransfer` and `burn` clear the owner's freeze of that item before the move, emitting `Frozen(owner, tokenId, false)` before `Transfer`, as ERC-7943 asks. If the hook then refuses, the whole call reverts and the freeze stays (for `burn`: `test_WhenTheHookRejects_TheTokenAndItsFreezeStay`).
- **The invariant** `invariant_AHolderMovesExactlyItsUnfrozenTokens` drives random transfers, freezes, forced transfers and burns, and checks that an owner's transfer succeeds exactly when the item is not frozen for it, and that enforcement always clears the freeze it takes.
- **An address freeze is a different tool:** it is `HolderRestrictionRule`'s, in the hook, and stops an account sending or receiving any item. It does not stop enforcement out of the account: the rule exempts FORCED on the sender's side, so the burner's `burn` and a `forcedTransfer` to a receiver that is not frozen both pass.

<a id="preflight"></a>
## Asking before moving

`canTransferWithReason(from, to, tokenId)` runs the checks of the path without moving anything. A zero `from` reads as a mint and a zero `to` as a burn; both zero reads `ZERO_RECEIVER`. The operator is `from`, which is the zero address for a mint, so the answer does not depend on who asks (`test_WhenAnyoneAsksAboutABurn_TheOperatorIsTheSender`). No pre-flight simulates FORCED, so none predicts `burn` or `forcedTransfer`. A burn asked about is answered as a holder's own burn would be, which the NFT does not have: a frozen item or a holder's lockup refuses it, whoever asks, while `burn` itself still takes the item (`test_WhenTheBurnerAsksAboutBurningAFrozenToken_ItGetsTheHoldersAnswerAndTheBurnStillPasses`, `test_WhenTheHolderIsLocked_TheBurnerCanStillBurn`). `burn` succeeds exactly when the hook accepts the forced movement, frozen or not, paused or not (`testFuzz_TheEnforcementBurnFollowsThePolicyAlone`). Approval is not judged.

| Situation | `canTransferWithReason` | `canTransfer` |
|---|---|---|
| The owner, nothing frozen, hook accepts | true, `TRANSFER_OK` | true |
| `from` is not the owner (for a mint: the id exists) | false, `NOT_TOKEN_OWNER` | true, if nothing else refuses |
| The item is frozen for `from` | false, `INSUFFICIENT_UNFROZEN` | false |
| Paused | false, `PAUSED` | false |
| A rule refuses | false, the rule's reason | false |

`canTransfer` is ERC-7943's yes or no. The standard says it must not answer no for a non-permissioned check such as a balance or an allowance, so it leaves ownership to ERC-721, while it does count the freeze (`test_WhenFromIsNotTheOwner_OnlyTheReasonedPreflightSaysSo`, `test_WhenFrozen_NeitherTheOwnerNorAnApprovedOperatorCanMoveIt`). `testFuzz_ThePreflightAgreesWithTheWrite` fuzzes the sender, the freeze, the pause and the hook's answer, and compares `canTransferWithReason` with a real transfer.

`canSend(account)` and `canReceive(account)` are the account questions. They are true for the zero address, and the hook is not asked. For any other account they are false while paused, with no hook, or when the hook cannot be asked, and otherwise the hook's account answers.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `initialize(name, symbol, admin, guardian, registry, hook, _initialRules)` | Once per proxy; `ProxyDeployer` runs it in the transaction that creates the proxy | Sets the name and symbol, then the core: roles, registry, hook and the rule list. See [the core's setup](PolicyGatedCoreUpgradeable.md#setup). |
| `mint(to, tokenId, uri)` | `MINTER_ROLE` | Creates the item for `to` with its URI, decided as MINT. An existing id reverts with `ERC721InvalidSender(0)`, a zero receiver with `ERC721InvalidReceiver`. Emits `Transfer`, then ERC-4906's `MetadataUpdate`. |
| `burn(tokenId)` | `BURNER_ROLE` | Destroys the item without approval, clearing its owner's freeze first, also while paused. Decided as FORCED with a zero receiver. A missing id reverts with `ERC721NonexistentToken`. |
| `forcedTransfer(from, to, tokenId)` | `AGENT_ROLE` | Moves the item without the owner's consent, also while paused, clearing its freeze first. Decided as FORCED, so the rules still judge the receiver. Emits `Transfer`, then `ForcedTransfer(from, to, tokenId)` and `ForcedTransferBy(from, to, tokenId, agent)`. Returns `true`. |
| `setFrozenTokens(account, tokenId, frozenStatus)` | `AGENT_ROLE` | Sets the freeze of one item for one account. Returns `true`. Works while paused. |
| `setTokenURI(tokenId, uri)` | `AGENT_ROLE` | Replaces an existing item's URI and emits `MetadataUpdate`. A missing id reverts with `ERC721NonexistentToken`. |
| `transferFrom`, `safeTransferFrom` | The owner, or an operator approved for the item or for all | OpenZeppelin's ERC-721, decided as TRANSFER. |
| `approve`, `setApprovalForAll` | `approve`: the owner, or an operator approved for all (anyone else gets `ERC721InvalidApprover`). `setApprovalForAll`: any account, for itself | OpenZeppelin's ERC-721. Approvals move nothing, so the hook is not asked. |
| `getFrozenTokens(account, tokenId)`, `canTransfer`, `canTransferWithReason`, `canSend`, `canReceive` | Anyone (read-only) | The freeze and the pre-flight answers above. |
| `ownerOf`, `balanceOf`, `tokenURI`, `getApproved`, `isApprovedForAll`, `name`, `symbol` | Anyone (read-only) | OpenZeppelin's ERC-721 reads. |
| `templateId()` | Anyone (read-only) | `keccak256('Gated721')` |
| Pause, hook, roles, upgrades, `multicall` | From [the core](PolicyGatedCoreUpgradeable.md#functions). An agent can freeze and force in one `multicall` (`test_WhenTheAgentBatchesCalls_MulticallRunsThemAsTheAgent`). |  |

`supportsInterface` answers true for `IGated721` (`0x94f4fff1`), `IERC7943NonFungible` (`0xbf1ef5fe`), `IPolicyGatedCore`, `IERC8473` (`0x0505c8c9`), ERC-721, its metadata extension, ERC-4906, `IAccessControl` and `IERC165`, and false for `IPolicyGated` and the fungible `0x3edbb4c4` (`test_WhenQueried_ItSupportsItsInterfacesAndNotTheFungibleOnes`). `ForcedTransferBy` has the fungible templates' signature and topic. The standard's NFT `ForcedTransfer` has the fungible one's topic, but indexes the token id.

<a id="why"></a>
## Why it is built this way

- **The same hook, not a second one.** One attested hook serves every token of a deployment, with a rule list per token. The rules read who, which kind and who is driving, so the account-based ones serve an NFT unchanged.
- **ERC-721 checks first.** An unapproved caller gets ERC-721's error, and the policy is asked only about the real owner's movement.
- **A plain mint.** Issuance calls no receiver, so no receiver code runs between the mint and the URI being set. The hook's `afterTransfer` is called in between and runs the listed rules that want it; neither rule the `nft` profile lists does.
- **Pre-flights that do not depend on who asks.** The operator simulated is `from`, zero for a mint, so every caller gets the same answer. Enforcement is not simulated: `burn` and `forcedTransfer` are the issuer's own actions.

<a id="limits"></a>
## What it does not do

- **No signed transfers and no delivery versus payment.** An item moves by a transaction of its owner or an approved operator, or by the agent.
- **No holder burn.** `burn` needs `BURNER_ROLE`.
- **No enumeration, no supply, no royalties, no `permit`.** A list of items is read from the `Transfer` events.
- **The refusal of an unusable rule is off-chain.** `assertUsable` in `ignition/profiles.ts` stops it when the module is built. `ComplianceHook.setRules` accepts any attested rule, so a timelock operation could still list one, with the effects in [the table above](#rules).
- **It cannot be a fund class.** `Fund` registers fungible gated tokens only.
- **The metadata is off-chain.** The token stores a URI and checks nothing about what it points to.

<a id="connected"></a>
## Connected to

- [PolicyGatedCoreUpgradeable](PolicyGatedCoreUpgradeable.md): The roles, pause, hook and upgrade checks it shares.
- [GatedToken](GatedToken.md): The plain fungible template on the same core.
- [ComplianceHook](ComplianceHook.md): Runs this token's rules on every movement.
- [CredentialRule](CredentialRule.md): Who may hold an item.
- [HolderRestrictionRule](HolderRestrictionRule.md): Each holder's lockup and address freeze.
- [ProxyDeployer](ProxyDeployer.md): Places the NFT and checks it came up as expected.
- [Deployment and governance](../deployment.md): The `nft` profile, and how a product is handed over.

<a id="source"></a>
## Source and tests

- Contract: `contracts/tokens/Gated721.sol`; interfaces `IGated721.sol`, `IERC7943NonFungible.sol`, `IPolicyGatedCore.sol`; the reason `NOT_TOKEN_OWNER` in `Errors.sol`
- Deployment: `ignition/profiles.ts` (the `nft` profile, `assertUsable`), `ignition/modules/Product.ts`
- Tests: `Gated721.t.sol` (unit tests with a mocked hook, the invariant, and an integration on the real hook, `CredentialRule` and `HolderRestrictionRule` through `ProxyDeployer`), `test/nodejs/products.test.ts` (the deployed `nft` profile, a client verified once holding a token and an NFT, the refused rules)

---

Describes the contracts at commit `6ef0d4e` on `erc8473-conformance`.
