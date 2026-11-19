[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Identity and fund

# Fund

One fund, several share classes. `Fund` keeps what no single class can know: which tokens are its classes, how many distinct investors hold any of them, and which classes each address holds.

- **contracts/fund/Fund.sol**
- immutable, **not a proxy**, one per fund
- owner: **the operations account**, then **the main timelock** after `FundOpen`
- not attested: the **FundHoldersRule** that points at it is

<a id="in-one-minute"></a>

> ### In one minute
>
> A fund can issue several classes of shares, and here each class is its own token with its own balances. In the demo deployment the three classes are a token settled through signed intents, an instant vault and a request-and-claim vault. A fund may be allowed only so many investors in total, counted across its classes. No class token can count that alone, because it sees its own holders and no others.
>
> `Fund` is the shared record. It knows the fund's classes, which of them each address holds, and how many distinct investors that makes. An investor in three classes counts once. So does an investor that holds through several addresses, when the credential registry the fund reads gives those addresses one entity. It decides nothing itself: [FundHoldersRule](FundHoldersRule.md), a rule listed on each class, reads it to apply the cap and tells it when someone starts or stops holding a class.

<a id="how"></a>
## How it works: one word per address, one count for the fund

Classes are numbered from 1 in the order they were registered, and class `n` owns bit `n - 1` of an account's class mask. Each account's state is one storage word: the class bits at the bottom, above them the key the account is counted under (see [Investors, not addresses](#entities)), and an "exempt" flag at the top. The fund's installed rule, the investor count and the cap share another word.

> **Diagram.** An example state of a fund with three classes: INT as class 1 (bit 0), gFUND as class 2 (bit 1) and gASYNC as class 3 (bit 2). Alice holds all three, so her mask is 7 and she counts once. Bob holds class 1, mask 1, counts once. A treasury holds class 2 but is exempt, mask 2, not counted. The gASYNC vault holds shares of pending redemptions at its own address, but a class is not recorded, mask 0. Carol sold her last class, mask 0, not counted. The fund's shared slot holds the installed rule, the count of 2 and a cap of 3.
>
> **Many classes per investor, one count per fund.** An example state. Alice's mask is 7 (bits 0, 1 and 2), and she is one investor. The treasury's class bit is recorded but its exempt flag keeps it out of the count. The vault's own address gets no bit, so shares waiting in its escrow are not an investor. No address here names an entity, so each counted address is one investor.

1. **A counted address** is an account that holds at least one class and is not exempt. **An investor** is a counted address on its own, or all the counted addresses of one entity together. It counts once, however many classes and addresses it holds through.
2. **A class does not count itself.** [`Gated7540Vault`](Gated7540Vault.md) holds the shares of pending redemptions at its own address. `join` ignores a class token joining itself, so the escrow is not recorded and needs no exemption.
3. **The count moves at the edges.** It rises when an investor's first address gets its first class bit while not exempt, and falls when its last counted address loses its last one. A second class, an extra unit of one already held, or another address of an entity that is already counted, writes nothing to the count.
4. **The shared word.** The installed rule, the count and the cap sit in one storage slot, so the rule reads all three at once, and the first count write is not a write to an empty slot.

<a id="entities"></a>
## Investors, not addresses

A cap on investors counts people and institutions, and one of them can hold through several addresses. The fund is built with the address of a [`CredentialRegistry`](CredentialRegistry.md), `CREDENTIALS()`, and asks it for each address's entity key, `entityKeyOf(account)`: the attester's id and the attester's number for the investor, or zero when the address stands alone. A fund built with the zero address asks nobody, and every key is zero.

- **The key is read when counting starts.** When an address starts being counted, on its first class or when its exemption ends, the fund reads its key from the registry and stores it in the address's state word. `countedKeyOf(account)` returns it; it is zero for an address on its own and for one that is not counted.
- **What the count is.** `holderCount()` is the number of counted addresses with key zero, plus the number of keys that have at least one counted address. For each key the fund keeps how many counted addresses it has. Two addresses of one entity count once (`test_WhenTwoAddressesOfOneEntityHold_TheyCountOnce`), also when they hold different classes (`test_WhenOneEntityHoldsTwoClassesThroughTwoAddresses_ItCountsOnce`). Addresses with no entity each count on their own (`test_WhenAddressesNameNoEntity_EachCountsOnItsOwn`), and the same number from two attesters is two investors (`test_WhenTwoAttestersUseTheSameEntityNumber_TheyAreTwoInvestors`).
- **An address leaves the key it was counted under.** When it loses its last class or is exempted, the fund lowers the stored key, whatever the registry says by then, and clears it. The investor leaves the count when its last counted address does (`test_WhenOneAddressOfAnEntityLeaves_TheInvestorStaysUntilTheLastOneLeaves`).
- **A standing does not move the count.** The registry answers the key from the stored record, so a holder whose credential lapsed keeps its key, and can still leave (`test_WhenACredentialLapses_TheCountStaysAndTheHolderCanLeave`).
- **An exempt address has no place in its entity.** It is not counted, so the next address of that entity to hold starts the investor (`test_WhenAnExemptAddressOfAnEntityHolds_TheNextAddressOfThatEntityIsCounted`).

### When the registry changes under a holder: rekey

An attester can link or unlink an address while it holds a class. The fund does not hear of it: the address stays counted under the key it has. `rekey(account)` brings the fund into line. Anyone may call it, because it only makes the fund agree with the registry. It moves a counted address from the key it was counted under to the key the registry gives it at that moment, and the count moves if that ends one investor or starts another, and stays when it does both or neither (`test_WhenAnAddressMovesBetweenTwoEntitiesThatBothHold_TheCountStays`). It does nothing for an address that holds no class, for an exempt one, and for one whose key has not changed (`test_WhenNothingChanged_RekeyDoesNothing`, `test_WhenTheAddressIsExempt_RekeyDoesNothing`).

- **Linked and not rekeyed: counted apart.** Two holding addresses that the attester links afterwards are still two investors until each is rekeyed, so the count errs on the strict side (`test_WhenTwoHoldingAddressesAreLinked_RekeyCountsThemOnce`).
- **Unlinked and not rekeyed: counted together.** A holding address the attester unlinks is still counted with its former entity until it is rekeyed. The rekey can put the count above the cap, where nobody new is admitted (`test_WhenAHoldingAddressIsUnlinked_RekeyCountsItApartEvenAboveTheCap`). A monitor on the registry's `CredentialSet` event sees the change and calls `rekey`.

`countedWith(account)` is the question [`FundHoldersRule`](FundHoldersRule.md) asks. For a counted address it is the number of counted addresses under the key it was counted under, itself included: one for an address on its own. For an address that is not counted it is the number of counted addresses under the key the registry gives it at that moment: zero for an address on its own. So a receiver that holds nothing is a new investor exactly when the answer is zero, and a sender is its investor's last address exactly when the answer is one.

<a id="journey"></a>
## One investor across three classes

The sequence an integration test runs on one fund with the three templates registered as classes 1, 2 and 3 (`test_WhenAnInvestorLeavesEveryClass_TheCountReturnsToZeroOnlyAfterTheLastOne`). Each movement reaches the fund through [`FundHoldersRule`](FundHoldersRule.md) after the balances have moved. A class's rule list decides whether it reaches the fund at all.

| Movement | Kind | What the rule tells the fund | Alice's mask | Investors |
|---|---|---|---|---|
| The minter mints INT to Alice | MINT | `join(INT, Alice)`: her first class | 1 | 1 |
| Alice deposits into the gFUND vault | MINT | `join(gFUND, Alice)` | 3 | 1 |
| Alice claims her settled gASYNC deposit | MINT | `join(gASYNC, Alice)` | 7 | 1 |
| The burner burns all her INT | FORCED | `leave(INT, Alice)` | 6 | 1 |
| Alice redeems all her gFUND shares | BURN | `leave(gFUND, Alice)` | 4 | 1 |
| Alice requests redemption of all her gASYNC shares, which move to the vault's escrow | TRANSFER | `leave(gASYNC, Alice)`, then `join(gASYNC, vault)`, which the fund ignores because the vault is the class itself | 0 | 0 |

When that period is later settled, the shares are burnt from the escrow, and the count does not move: the escrow was not an investor (`test_WhenARedemptionIsSettled_TheBurnFromTheEscrowChangesNothing`).

<a id="register"></a>
## Registering a class

Four conditions decide whether a token can become a class: the caller is the owner, the token reports ERC-165 support for `IPolicyGated`, the interface of a fungible gated token (a `Gated721` and a `Gated1155` do not report it), its current hook lists the fund's installed rule, and its total supply is zero. `registerClass(token)` runs them with the housekeeping checks, in this order:

1. The caller is the owner (`OwnableUnauthorizedAccount`).
2. The token is not the zero address (`Fund_ZeroAddress`) and is not already a class (`Fund_AlreadyRegistered`).
3. The fund has fewer than `MAX_CLASSES`, 32, classes (`Fund_TooManyClasses`). The mask has a bit for each.
4. A rule is installed (`Fund_RuleNotSet`).
5. The token reports ERC-165 support for `IPolicyGated` (`Fund_NotPolicyGated`).
6. The token's current hook lists the installed rule for it (`Fund_RuleNotListed`). A token whose hook cannot answer fails here too, with the revert of that call.
7. The token's total supply is zero (`Fund_ClassHasSupply`). A class with holders the fund did not see would start with a wrong count. This also means a fund has no seed step: there is no function that sets a count or a mask.

Registration is permanent; there is no function to remove a class. Until a token that lists the rule is registered, `FundHoldersRule` rejects each movement on it with `NOT_FUND_CLASS`, so such a token has no balance before the fund can record it. The calls to the token and its hook are read-only (`FundUnit_CallsAreStatic`).

<a id="writers"></a>
## Who may change the record

The fund's state is shared by each of its classes, so a token that merely names itself in a movement must not reach it. Two gates stand in the way:

- **From the installed rule.** `join` and `leave` revert for any other caller (`Fund_OnlyRule`). The rule in turn accepts `after_` from whichever hook the token named in the call has installed.
- **For a registered class.** `join` and `leave` revert for a token that is not a class (`Fund_NotAClass`). A fake token with its own fake hook can get past the rule's hook check, and is stopped here.

Two other paths move the count, each by at most one: the owner's `setExempt`, for an account that holds a class, and `rekey`, which anyone may call and which only moves a counted address to the key the credential registry gives it. No function lets the owner set a class mask, a key or the count directly.

<a id="cap"></a>
## The cap and the exemptions

- **The cap.** `setHolderCap` stores it and leaves the count alone. Lowering it below the current count does not remove anyone: existing investors keep their classes, can trade among themselves and can leave, and while the count is above the cap the rule admits nobody new. A cap of 0 admits no new investor. The count and the cap are 48-bit numbers. The fund holds the numbers and [`FundHoldersRule`](FundHoldersRule.md) applies them.
- **Exemptions.** An exempt account, such as a treasury, does not count and does not trigger the cap. Its class bits are still recorded, so if the owner ends the exemption while it holds a class, it is counted at once, under the key the registry gives it then. When an exemption starts on an account that holds a class, the account leaves the key it was counted under, and the count falls if that was the investor's last counted address (`test_WhenOneAddressOfAnEntityIsExempted_TheInvestorStaysWhileAnotherHolds`). Exempting an account that holds nothing changes only the flag.
- **Not checked by the fund.** Neither change looks at the classes or the rule, and ending an exemption can put the count above the cap. So can a `rekey`.

<a id="rule-change"></a>
## Installing and changing the rule

`setRule(rule)` has three conditions: the rule is not zero (`Fund_ZeroAddress`), it is attested as `RULE` in the fund's registry (`Fund_NotAttested`), and its `FUND()` is this fund (`Fund_RuleForAnotherFund`). The last one matters because another fund's rule is attested too, and a hook accepts a rule by its attestation and its `ruleId`, which every `FundHoldersRule` shares. Only the fund can tell that a rule counts into another fund's state (`test_WhenARealRuleOfAnotherFundIsInstalled_Reverts`).

It takes effect at once: from then on only that rule may call `join` and `leave`. The count and the masks stay where they are, and the incoming rule starts from them. But each class's hook lists its rules by address. A class whose list still names the outgoing rule sends it each movement, and that rule, seeing from `admission` that it is not the installed one, rejects each movement of the class with `NOT_FUND_CLASS`, forced transfers and burns included. The pre-flight calls give the same answer and the fund's state does not change, but the class is closed until its list names the installed rule.

So the change goes through the main timelock as one batch: `setRule` on the fund and, for each registered class, `setRules` on its hook with the rule swapped in the class's list. The hook tells the incoming rule in that call, and the rule accepts on a class with holders because the list it replaces names another rule of the same fund. A second rule instance for the same fund has the same code hash as the first, because the fund's address is its one immutable, so it is already attested.

<a id="monitor"></a>
## The monitor: isClassIntact and firstBrokenClass

The cap lives in the fund, but it applies to a class only while that class's rule list in the hook names the fund's installed rule. The hook accepts a list of attested rules without knowing about the fund, so it does not notice when a list loses the fund's rule. The fund can check.

| View | Answer |
|---|---|
| `isClassIntact(token)` | True when the token is a registered class and its current hook's `rules(token)` lists the installed rule. False otherwise, including when the call to the token or to its hook reverts, and when either has no code (`test_WhenTheHookHasNoCode_TheClassIsNotIntactAndTheViewDoesNotRevert`, `test_WhenTheTokenHasNoCode_TheClassIsNotIntactAndTheViewDoesNotRevert`). |
| `firstBrokenClass()` | The first registered class, in registration order, that is not intact; the zero address when none is broken. One call, at most 32 classes. |

They report three situations and prevent none of them: the fund's rule dropped from a class's list (the class runs uncapped and the fund's count goes stale), the fund's rule replaced while a list still names the outgoing one (the class fails closed with `NOT_FUND_CLASS`), and a class's hook swapped for one that does not list the rule. They read the list as it stands, so once a dropped rule is listed again they report that class as intact, whatever moved in between. The post-deploy check asserts that `firstBrokenClass()` is the zero address, and a monitor should poll it.

<a id="owner"></a>
## Who owns it at each stage

A fund is not part of the core: an issuer has as many as it has funds, each with its own contract, rule and cap. The deployment modules take it through these stages.

| Stage | Owner | What happens |
|---|---|---|
| `Fund` module | The operations account, named in the constructor | Deploys the fund and the `FundHoldersRule` that points at it. The module's `credentials` parameter is the credential registry the fund reads, or the zero address. The council reads the fund's code and owner, then attests the rule. |
| `Product` module, per class | The operations account | Places the class with the rule in its list. It does not touch the fund, so a launch cannot fail on one. The fund's rule refuses each movement of the class (`NOT_FUND_CLASS`). |
| `FundOpen` module | The operations account, then the main timelock | `setRule`, `setHolderCap`, `registerClass` for each first class in the order given, and last `transferOwnership` to the main timelock. |
| After that | The main timelock | A later class, a rule change, a cap or an exemption is a timelock operation, because each can change the room existing investors have under the cap. A later class launches through `Product` like any other, and the fund's rule refuses its movements until `registerClass` runs. |

The post-deploy check asserts that each fund's owner is the timelock, its rule is the attested one and names it, its cap is the intended one, its `CREDENTIALS()` is the credential registry of its core, or the zero address when the core has none, and its classes are the ones it opened with, in order.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `registerClass(token)` | The owner | Adds a class under the next number, permanently. Emits `ClassRegistered(token, index)`. See [Registering a class](#register). |
| `setRule(rule)` | The owner | Installs the rule that may write. Emits `RuleSet(previous, rule)`. See [Installing and changing the rule](#rule-change). |
| `setHolderCap(cap)` | The owner | Sets the investor cap. Does not touch the count. Emits `HolderCapSet(previous, cap)`. Reverts with OpenZeppelin's `SafeCastOverflowedUintDowncast` above `type(uint48).max`. |
| `setExempt(account, exempt)` | The owner | Sets or clears the exempt flag. An account that holds a class stops being counted, under the key it was counted under, or starts being counted, under the key the registry gives it then, and the count follows. Emits `ExemptSet` when the flag changes. Reverts with `Fund_ZeroAddress` for the zero address. |
| `join(token, account)` | The installed rule | Records that the account holds the class. Does nothing for the class itself or a class already held. A non-exempt account with no class yet starts being counted, under the key the registry gives it then, and the count rises if that starts an investor. Reverts with `Fund_OnlyRule` or `Fund_NotAClass`. |
| `leave(token, account)` | The installed rule | Records that the account has stopped holding the class. Does nothing if it did not hold it. A non-exempt account that loses its last class stops being counted and its key is cleared, and the count falls if that was the last counted address of its investor. Reverts with `Fund_OnlyRule` or `Fund_NotAClass`. |
| `rekey(account)` | Anyone | Moves a counted account from the key it was counted under to the key the credential registry gives it at that moment, and moves the count if that ends one investor or starts another. Does nothing for an account that is not counted or whose key has not changed. Can put the count above the cap. Emits `HolderKeyUpdated`. |
| `admission(token, account)` | Anyone (read-only) | What the rule needs in one call: the class number (0 if not a class), the account's mask, its exempt flag, the count, the cap and the installed rule. |
| `isClassIntact(token)`, `firstBrokenClass()` | Anyone (read-only) | The monitor, above. |
| `positionsOf(account)` | Anyone (read-only) | The classes the account holds and its balance in each. It calls each held class token, so it is meant for off-chain reads. |
| `heldClasses(account)`, `isExempt(account)` | Anyone (read-only) | The account's mask, without the exempt flag; the flag. |
| `countedWith(account)` | Anyone (read-only) | How many counted addresses share the account's investor. For a counted account, under the key it was counted under, itself included. For any other account, under the key the registry gives it at that moment; zero for an address on its own. |
| `countedKeyOf(account)` | Anyone (read-only) | The key the account is counted under; zero when it stands alone or is not counted. |
| `holderCount()`, `holderCap()`, `rule()` | Anyone (read-only) | The investor count (counted addresses on their own, plus the entity keys with at least one counted address), the cap, the installed rule. |
| `classCount()`, `classAt(index)`, `classIndexOf(token)` | Anyone (read-only) | How many classes; the token of a class number (`Fund_ClassOutOfRange` outside 1 to `classCount()`); the number of a token, 0 when it is not a class. |
| `MAX_CLASSES()`, `REGISTRY()`, `CREDENTIALS()`, `supportsInterface(id)` | Anyone (read-only) | 32; the policy registry that must attest the rule, fixed at construction; the credential registry asked for each address's entity, or the zero address, fixed at construction; ERC-165 for `IFund`. |
| `owner()` | Anyone (read-only) | The account that configures the fund. |
| `transferOwnership(newOwner)`, `renounceOwnership()` | The owner | OpenZeppelin `Ownable`, in one step. Emits `OwnershipTransferred`. Renouncing would freeze the configuration for good: no later class, rule, cap or exemption. |

The constructor takes the owner, the policy registry and the credential registry. It refuses a zero policy registry (`Fund_ZeroAddress`). The credential registry may be the zero address, and the fund then counts every address on its own. Any other must answer the `ICredentialRegistry` interface id through ERC-165, or the constructor reverts with `Fund_NotACredentialRegistry` (`test_WhenTheRegistryDoesNotAnswerTheInterface_ItReverts`, `test_WhenTheRegistryHasNoCode_ItReverts`).

| Event | Emitted when |
|---|---|
| `ClassRegistered(token, index)` | A class is registered, with its number |
| `RuleSet(previous, rule)` | The installed rule is set |
| `HolderCapSet(previous, cap)` | The cap is set |
| `ExemptSet(account, exempt)` | An account's exempt flag changes |
| `HolderClassesUpdated(account, classes)` | The set of classes an account holds changes; carries the mask after the change |
| `HolderKeyUpdated(account, key)` | The key an account is counted under changes: it starts being counted under a key that is not zero, it stops being counted under one (the event then carries zero), or `rekey` moves it |
| `HolderCountUpdated(count)` | The investor count changes; carries the count after the change |

Together with the class tokens' own `Transfer` events, `HolderClassesUpdated`, `HolderKeyUpdated` and `HolderCountUpdated` are the register of investors, so the fund keeps no list of holders on chain.

<a id="why"></a>
## Why it is built this way

- **State in the fund, policy in the rule.** The fund records and the rule decides. Replacing the rule keeps the count and the masks, because they do not live in the rule.
- **One word per account, one for the fund.** A class mask, the key and the exempt flag fit one storage word, and the rule, the count and the cap share another, so the rule's first question costs one call (`admission`). It asks `countedWith` as well only for a receiver that holds no class and is not exempt.
- **The key is remembered, not read again.** An address leaves the key it was counted under, so a change in the registry cannot make the fund lower a key it did not raise. For the same reason the rule judges a sender by the stored key, and its pre-flight agrees with the write while a registry change waits for a `rekey` (`test_WhenTheRegistryUnlinksASenderAndNobodyRekeys_TheDecisionStillFollowsTheCount`).
- **Key zero is an address on its own.** It does not use a counter, so addresses with no entity are not one shared investor.
- **Supply must be zero at registration.** The fund cannot discover holders it did not see, so a class joins before anyone holds it, and the count is right from the first unit.
- **Balances are not added up.** `positionsOf` returns each class's balance separately, because units of different classes are not comparable.
- **Owned, with one-step transfer.** Like [`ProxyDeployer`](ProxyDeployer.md), the fund is `Ownable`. A fixed admin would force a timelock operation, and its delay, onto the first deployment, and a two-step transfer would make the timelock schedule an accept for each fund. The post-deploy check pins the owner.
- **Not attested itself.** The council attests `FundHoldersRule`, whose code hash covers the fund's address as an immutable but not the fund's code. So the council reads the fund's code and owner before attesting the rule.
- **Tested as a whole.** An invariant test drives random holder and enforcement actions across the three templates: `invariant_ClassBitsMatchBalances`, `invariant_CountIsTheNumberOfNonExemptInvestors` and `invariant_NoOneElseIsRecorded`. A second one adds entity links, exemptions and rekeys over a real credential registry: `invariant_TheCountIsTheInvestorsAmongTheCountedAddresses` and `invariant_TheClassBitsFollowTheBalances`.

<a id="limits"></a>
## What it does not do

- **It does not stop a class dropping the rule.** The hook accepts a list without `FundHoldersRule`, and then the class stops counting investors and stops enforcing the cap. The monitor detects it, and nothing prevents it (`test_WhenAClassDropsTheFundRule_ItIsUncappedAndTheMonitorNamesIt`). The same is true of a swap to a hook whose list for the class lacks the rule. A swap to a hook that lists the rule is refused by the rule's `onInstall` with `FundHoldersRule_CountNotCurrent` when the class has a supply and the hook it leaves lists no rule of the fund. A `setRules` that names the rule again on such a class is refused the same way, so a class that dropped the rule gets it back only when it is empty, and there is no recount (`test_WhenAClassWithHoldersDropsTheFundRule_ItCannotTakeItBack`).
- **It does not repair a gap.** While a class's list lacks the rule its movements are not recorded, and no function sets a mask directly. A seller in the gap stays counted until a later full exit, or until the fund's owner exempts it with `setExempt`, which takes it out of the count. A buyer with no other class stays uncounted, with the cap treating it as new, until it takes up another class, or its balance reaches zero and it receives again.
- **The cap is not an absolute ceiling on the count.** A forced move is exempt from the cap and still counted, so the agent's recovery of a stranded position can put the count above the cap, where it stays until investors leave. Ending an exemption can do the same, and so can a `rekey` of an address the attester unlinked. A monitor should alert when `holderCount()` is above `holderCap()`.
- **It holds no place for an open request.** A full `requestRedeem` on a 7540 class takes the investor out of the count while the shares wait in the escrow, and `requestDeposit` reserves nothing. If the fund fills up meanwhile, a reject that returns the shares, or a deposit claim, is refused with `MAX_HOLDERS` (`test_WhenARejectedRedemptionReturnsSharesToAnInvestorWhoWasReplaced_TheFundCapAppliesAndRecoveryIsCounted`). The agent's recovery path still works. Whether a redeeming investor still counts as a holder is for counsel.
- **It does not judge the size of a position.** One unit of a class is a holder. Without a minimum position on the class, 1 wei to an empty, credentialed account takes an investor slot. [`MinPositionRule`](MinPositionRule.md) closes that where it is listed with a non-zero minimum.
- **It does not know people.** It knows addresses and the entity an attester gave each. Two addresses of one client count once only when their records carry the same entity from the same attester; otherwise they count twice. An omnibus address counts once. The count is only as meaningful as the credentials behind it.
- **It does not follow the registry by itself.** Until someone calls `rekey`, a holding address the attester has since linked is still counted apart, and one it has since unlinked is still counted with its former entity. A monitor on `CredentialSet` catches both.
- **Linking is public and optional.** An entity number shows on chain that two addresses are one investor. An investor that keeps entity zero takes one place per address.
- **A fund with no registry counts addresses.** So does a fund over a registry that does not answer this version's `ICredentialRegistry` id: the constructor refuses that registry, so such a fund is built with the zero address (`test_WhenTheFundReadsNoRegistry_TwoAddressesOfOneEntityAreTwoInvestors`). The registry is fixed at construction.
- **Only the count is by entity.** [`MinPositionRule`](MinPositionRule.md) and every other rule judge an address. Nothing adds up an entity's positions.
- **It does not re-check a class after registration.** The rule, the class's hook and its list can all change later. The views report the result; they change nothing.
- **The monitor views assume well-formed answers.** `isClassIntact` and `firstBrokenClass` answer false or name the class when a call to the token or hook reverts, or when either has no code. A token or a hook that answers malformed data makes them revert, as no `catch` reaches a failure to decode an answer. Such a hook would have to be attested first.
- **It has no list of holders.** The register is rebuilt off-chain from events. `positionsOf` answers for one account at a time.

<a id="connected"></a>
## Connected to

- [FundHoldersRule](FundHoldersRule.md): The rule that reads the fund to apply the cap, and the one allowed to write it once installed.
- [CredentialRegistry](CredentialRegistry.md): Gives each address its entity key, which the fund counts investors by.
- [ComplianceHook](ComplianceHook.md): Holds each class's rule list, which the monitor reads.
- [Gated7540Vault](Gated7540Vault.md): The class whose escrow is its own address, not counted as an investor.
- [PolicyRegistry](PolicyRegistry.md): Must attest the rule before the fund installs it.
- [GovernanceTimelock](GovernanceTimelock.md): The fund's owner once its first classes are registered.
- [Deployment and governance](../deployment.md): How the fund is created, opened and handed to the timelock.

<a id="source"></a>
## Source and tests

- Contract: `contracts/fund/Fund.sol`, interface `IFund.sol`
- Deployment: `ignition/modules/Fund.ts` and `FundOpen.ts`
- Tests: `Fund.t.sol` (each function, the shared slot, a fuzz model of the count, the monitor), `FundIntegration.t.sol` (one fund with the three templates as classes: counting, the cap, registration, the vault escrow, rule and hook replacement, the monitor), `FundInvariant.t.sol` (the three invariants above), `FundEntities.t.sol` (a fund over a real credential registry: the constructor, counting by entity, the cap, `rekey`, exemptions, a fund with no registry, and the two invariants above), `test/nodejs/fund.test.ts` (through the real deployment, including two addresses of one entity, a later link followed by `rekey`, and the timelock batch that replaces the rule) and `products.test.ts` (an issuer with two funds)
