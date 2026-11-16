[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Policy

# CredentialRule

Decides who may hold a token. It reads each party's standing in the credential registry, lets a holder who may leave send, and admits as a receiver only an active address whose record fits the token's own policy.

- **contracts/hooks/rules/CredentialRule.sol**
- immutable, **not a proxy**
- policy set per token by the token's **DEFAULT_ADMIN_ROLE**
- attested as **RULE**
- ruleId: **keccak256('CredentialRule.v1')**

<a id="in-one-minute"></a>

> ### In one minute
>
> Every token checks a list of rules before a balance moves, and this rule comes first in every list the deployment profiles name. It asks two questions. May the sender leave? Yes, unless the registry says nobody ever vouched for the sender or the sender is blocked. May the receiver come in? Only if an attester the token trusts has vouched for it, the record is current, and its qualification flags fit what the token asks for, for example "identity checked, and a professional investor".
>
> Each token has its own policy, set by its own administrator, so one rule serves an open token and a professionals-only fund class side by side. A token with no policy admits no receiver. The rule keeps no list of holders. The [CredentialRegistry](CredentialRegistry.md) is the record.

<a id="how"></a>
## How a movement is decided

The token's [compliance hook](ComplianceHook.md) calls `check(ctx)` with the movement's context: the token, the sender, the receiver, the amount, the account driving the movement (the operator) and its kind. The rule checks the sender leg, then the receiver leg, and returns `TRANSFER_OK` or a reason code. It reads the registry once per party it judges, and not at all for the token's own address.

> **Diagram.** The check, in order. 1: for MINT and FORCED the sender leg is skipped. 2: for the other kinds, if the sender is not the token itself and reads NONE or BLOCKED, SENDER_NOT_ELIGIBLE. 3: if the receiver is the zero address, on a holder's burn or the burner's FORCED burn, there is no receiver, so TRANSFER_OK. 4: if the receiver is the token itself, TRANSFER_OK. 5: if the token has no policy, RECEIVER_NOT_ELIGIBLE. 6: if the receiver reads LAPSED, CREDENTIAL_EXPIRED. 7: if the receiver reads anything but ACTIVE, RECEIVER_NOT_VERIFIED. 8: if its attester is not trusted or its bits do not fit the policy, RECEIVER_NOT_ELIGIBLE. Otherwise TRANSFER_OK.
>
> **Sender first, then receiver; the first refusal is the answer.** Red boxes are refusals, which the token turns into `ERC8473PolicyRejected(reason)`. The line on the left is the skip for `MINT`, which has no sender, and `FORCED`, whose sender is not checked. Step 3 is a holder's `BURN` or the burner's `FORCED` burn.

1. **The sender may leave.** Any standing except `NONE` and `BLOCKED` lets an address send: `ACTIVE`, `EXIT_ONLY` and `LAPSED`. The sender's bits and attester do not matter, and neither does the token's policy.
2. **The enforcement burn is not judged.** The burner's `burn` reaches the rule as `FORCED` with no receiver, so neither leg applies, whatever the sender's standing. A `BURN` is a holder's own, a vault redemption, and its sender must be able to leave, whoever the operator is.
3. **The token's own address is not judged.** On either side, the token's own address passes without a registry read. A [`Gated7540Vault`](Gated7540Vault.md) holds its escrow at that address, and a credential there could lapse and stop every redemption.
4. **The receiver must be active and accepted.** The token's policy is read first, so a token with no policy answers `RECEIVER_NOT_ELIGIBLE` for everyone else. Then the standing: `LAPSED` and every other standing except `ACTIVE` are refused with different codes. Then the policy itself.

<a id="kinds"></a>
## What it does for each kind of movement

Zero amounts are checked like any other, and a move from an account to itself checks both legs.

| Kind | Sender leg | Receiver leg |
|---|---|---|
| TRANSFER | must be able to leave | must be `ACTIVE` and accepted by the policy |
| EXECUTED | the signer of the intent must be able to leave | the same as a transfer |
| FORCED | not checked: the agent and the burner can take tokens from a blocked holder | checked when there is one: the agent can move tokens only to an accepted receiver, or to the token's own address. The burner's `burn` has no receiver |
| MINT | none: a mint has no sender | checked |
| BURN | must be able to leave, whoever the operator is | none: a burn has no receiver |

The rule does not look at the caller, the spender or the executor, and it asks the token for no role. On the vaults, a deposit is a `MINT` of shares and a 4626 redemption a `BURN`. A 7540 redemption request is a `TRANSFER` of the shares into the vault's own address, so its sender leg applies and its receiver leg passes. So on the vaults a holder whose record lapsed can redeem but cannot deposit, and a blocked holder can do neither. On a 7540, a settled deposit claimed after a lapse is refused and the agent's `recoverClaimable` is the way out, and a blocked controller cannot collect a payout.

<a id="account-checks"></a>
## The account questions

ERC-7943, the standard the tokens implement, has two account-level questions with no amount: `canSend(account)` and `canReceive(account)`. The token answers them by asking the hook, which asks every rule and stops at the first refusal. Both answers are true for the zero address, which the hook is not asked about, and false for any other account while the token is paused.

- `checkSend(token, account)` is the sender leg: `TRANSFER_OK` for `ACTIVE`, `EXIT_ONLY` and `LAPSED`, and for the token's own address; `SENDER_NOT_ELIGIBLE` otherwise.
- `checkReceive(token, account)` is the receiver leg under that token's policy: `TRANSFER_OK`, `RECEIVER_NOT_ELIGIBLE`, `CREDENTIAL_EXPIRED` or `RECEIVER_NOT_VERIFIED`.

`check` is built from the same two pieces, and a fuzz test pins the relation: for a transfer or an executed intent, `check` is the send answer, then the receive answer; for a burn it is the send answer, whoever the operator is; for a mint or a forced transfer it is the receive answer. So `canSend` reads false for a blocked holder although the agent's `forcedTransfer` can still move its tokens. [`Distributor`](Distributor.md) refuses a claim from a holder for whom `canReceive` is false, so a holder whose credential lapsed cannot claim until it is renewed.

<a id="config"></a>
## The token's policy, and what happens without one

Each token has one policy in the rule, stored under the token's address. It says which records the token accepts from a receiver. `setPolicy` replaces the whole of it.

| Field | Type | A receiver passes when |
|---|---|---|
| `attesters` | `uint64` | bit `i` is set for the id `i` of the attester that wrote its record. **Zero means no policy, and that admits nobody.** |
| `requireAll` | `uint32` | it holds every one of these bits; zero asks for nothing |
| `requireAny` | `uint32` | it holds at least one of these bits; zero skips the test |
| `forbidAny` | `uint32` | it holds none of these bits; zero forbids nothing |

The bits are the qualification bits of the [registry's record](CredentialRegistry.md), named in `Quals.sol`: bit 0 `KYC`, bit 1 `PROFESSIONAL` and so on. A record holds no country. A jurisdiction group is a bit too (`US_PERSON`, `EEA`), so an offering closed to a group sets that bit in `forbidAny`.

| Where | `attesters` | `requireAll` | `requireAny` | `forbidAny` | Who can receive |
|---|---|---|---|---|---|
| `DEFAULT_POLICY`, for a product that states none | attester 0 | `KYC` | none | none | Any address with an `ACTIVE` record from attester 0 that carries `KYC` |
| A professionals-only class (a vault test) | attester 0 | `KYC` | `PROFESSIONAL` | none | Addresses with both bits. The vault's escrow still works, because the token's own address is not judged. |

### Who sets it

`setPolicy` asks the token, at the moment of the call, whether the caller holds the token's `DEFAULT_ADMIN_ROLE`. While a product launches that is the operations account, and the `Product` module calls `setPolicy` with the product's policy, or `DEFAULT_POLICY`, before it hands the token over. After the hand-over it is the main timelock, so a policy change is a governance operation with its delay. Because the policy is stored under the token's address, a fake token can authorise anyone to set a policy, but only its own: no other token's policy changes (a test pins this). The call to the token is read-only, so a token cannot change state while it answers.

### Not configured: it fails closed

Until a token has a policy, the rule admits no receiver, so no holder can be minted a balance before the token is configured. Zero `attesters` does not switch the rule off. The token's own address is the one exception, because the rule passes it before it reads the policy.

Removing a policy (`attesters` set to 0) closes the token to every other receiver, existing holders included. A transfer, a signed intent and a mint are refused with `RECEIVER_NOT_ELIGIBLE`. Holders can still leave through a burn, which has no receiver: a 4626 redemption, or the burner's burn. A 7540 `requestRedeem` also still passes this rule, because its receiver is the vault's own address.

<a id="reasons"></a>
## Reason codes

| Code | Leg | When |
|---|---|---|
| `SENDER_NOT_ELIGIBLE` | sender | The sender reads `NONE` or `BLOCKED`, and the kind is `TRANSFER`, `EXECUTED` or `BURN`. |
| `RECEIVER_NOT_ELIGIBLE` | receiver | The token has no policy; or the receiver is `ACTIVE` but its attester is not in the bitmap or its bits do not fit. |
| `CREDENTIAL_EXPIRED` | receiver | The receiver's record lapsed: it can still send, burn and redeem, but not receive. |
| `RECEIVER_NOT_VERIFIED` | receiver | The receiver reads `NONE`, `EXIT_ONLY` or `BLOCKED`. |

When both legs would fail, the sender's code is the one returned. A write that is refused reverts with `ERC8473PolicyRejected(reason)`, and the token's pre-flight calls (`canTransferWithReason`, and `canExecute` for a signed intent) return the same code without moving anything.

<a id="enforcement"></a>
## Enforcement still works on a blocked holder

A blocked holder, or an address with no record at all, cannot send. The issuer's two enforcement tools still pass this rule:

- **A burn by the burner.** The burner's `burn` is `FORCED` with no receiver, so neither leg judges it. A holder's own `BURN`, a vault redemption, is refused for such a holder, whoever the operator is.
- **A forced transfer by the agent.** `FORCED` skips the sender leg, so the agent's `forcedTransfer` can take the tokens. The receiver is still checked, so the tokens can go only to an address the token accepts, or to its own address.

Passing this rule does not mean every other rule agrees: a later rule in the token's list, a freeze for example, can still refuse the movement.

<a id="order"></a>
## Where it sits, and who lists it

Every product in every profile of `ignition/profiles.ts` lists it, and lists it first: the three products of the demo deployment (`full`, through `RULE_ORDER`) ahead of the minimum position, the holder restrictions, the settlement window on the intent token, and the fund's investor cap; and every other profile's product (through `PLAIN_RULES`) ahead of the holder restrictions.

The `Core` module deploys one `CredentialRegistry` and one rule reading it, if a product lists the rule. `CoreHandover` adds one attester, the issuer's KYC function, as id 0. The post-deploy check (`assertHandedOver`) asserts that the rule reads the deployment's registry, that it is attested, and that each product's policy is the one in its profile. A core can instead read an existing registry: it deploys neither, and its council attests the rule the parameters name, whose `REGISTRY` is immutable, so the rule fixes the registry ([Using an existing credential registry](../deployment.md#external)). Outside the modules, the KYC attester writes a record for every holder. A vault needs no record for its own shares, but a vault whose asset is a gated token is an ordinary holder of that asset and needs a record its policy accepts.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `setPolicy(token, requireAll, requireAny, forbidAny, attesters)` | The token's `DEFAULT_ADMIN_ROLE`, asked live | Replaces the token's whole policy. `attesters == 0` removes it. Emits `PolicySet(token, requireAll, requireAny, forbidAny, attesters)`. Reverts with `CredentialRule_OnlyTokenAdmin(token, caller)`. |
| `check(ctx)` | Anyone (read-only); the hook in practice | The decision above. |
| `checkSend(token, account)` | Anyone (read-only) | The sender leg for an account. The token matters only in that its own address passes. |
| `checkReceive(token, account)` | Anyone (read-only) | The receiver leg for an account, under that token's policy. |
| `policyOf(token)` | Anyone (read-only) | The token's policy; all zero when not set. |
| `REGISTRY()` | Anyone (read-only) | The registry the rule reads, fixed at construction. The constructor refuses the zero address (`CredentialRule_ZeroAddress`). |
| `after_(ctx)` | The hook of `ctx.token` | The empty default from [`BaseRule`](BaseRule.md). The hook does not call it, because `wantsAfter()` is false. |
| `onInstall(token, previousPolicy)` | Anyone; the hook when a token installs it | The empty default from `BaseRule`: the rule keeps no state derived from movements. |
| `ruleId()`, `wantsAfter()`, `supportsInterface(id)` | Anyone (read-only) | `keccak256('CredentialRule.v1')`; false; ERC-165 for `ICredentialRule`, `IComplianceRule` and `IERC165`. |

<a id="why"></a>
## Why it is built this way

- **Getting out is the default.** The sender leg asks only whether the address may leave. A holder whose record lapsed, or whose attester was killed, can still sell, redeem and settle a signed intent. It takes an explicit block to stop it, and even then the issuer can burn or force.
- **No running state.** The rule stores each token's policy and nothing else. The registry is the state, so a rule taken out of a list and put back misses nothing.
- **One instance for every token.** The policy is stored per token and authorised by that token's own admin, so one attested contract serves every token in the deployment.
- **The registry is pinned by the attestation.** `REGISTRY` is an immutable, so its address is part of the code the council attested. That pins which registry the rule reads, not that registry's code, which the council reads before it attests the rule.
- **Few reads.** One registry read per party the rule judges, and no call to the token on a movement. The registry works out the standing, so the rule does no time or trust arithmetic.

<a id="limits"></a>
## What it does not do

- **It verifies nobody.** It applies what the registry says, and the registry records what an attester says. A compromised attester key can credential any address for every token whose policy trusts that attester, with any bit the attester may assert. The limits are the attester's allowed bits, the token's bitmap and required bits, and the registry guardian's `killAttester` and `blockSubject`. A record's validity is no limit here: the attester chooses `validUntil`, and the registry sets no ceiling on it.
- **A lapse does not stop funds already held.** A holder whose credential lapsed, or whose attester was killed, can still send, burn and redeem. To stop those funds, the tools are a block in the registry (the guardian's `blockSubject`, or for a lapsed holder the attester's `setStatus`; a killed attester's `setStatus` reverts with `CredentialRegistry_AttesterKilled`), the address freeze and the lockup of [`HolderRestrictionRule`](HolderRestrictionRule.md), the token's `setFrozenTokens`, and `forcedTransfer`.
- **The token's own address is open.** A holder can send a token to the token's own address by mistake, and the rule will not stop it. The agent recovers it with `forcedTransfer`. Stopping a vault stays with `pause()` and `HolderRestrictionRule`.
- **One wallet is one holder.** Entities are not modelled.
- **It does not judge a third party.** A spender or an executor needs no credential here. The vaults' own check on third parties (`GatedVault_ThirdPartyNotEligible`) asks the token's whole list about a zero-amount `FORCED` move to that account, and that reaches this rule's receiver leg.
- **The first attester's default bits stop at bit 9.** `CoreHandover` lets it assert `kycAllowedQuals`, 1023 by default, which covers the ten named bits. A policy that reads a bit above 9 (10 to 15 are reserved, 16 to 31 are a deployment's own) needs that parameter widened. Otherwise no record from that attester carries it, and a `forbidAny` on it refuses nobody.

<a id="connected"></a>
## Connected to

- [CredentialRegistry](CredentialRegistry.md): The records this rule reads: standings, bits, attesters, the guardian's block.
- [ComplianceHook](ComplianceHook.md): The shared hook that asks this rule first in every deployed list.
- [BaseRule](BaseRule.md): The parent of every rule, with the default `after_` this rule keeps.
- [One movement](../movement.md): Where this rule sits among all the checks a movement meets.

<a id="source"></a>
## Source and tests

- Contract: `contracts/hooks/rules/CredentialRule.sol`, interface `ICredentialRule.sol`, reason codes in `Errors.sol`
- Tests: `CredentialRule.t.sol` (each leg, each kind, the enforcement burn, the policy tests, the token's own address, a fuzz model of the whole table, the account questions against `check`), `CredentialRuleIntegration.t.sol` (on a real token, with pre-flight parity, lapses, blocks and signed intents), `CredentialRuleVaults.t.sol` (both vaults), and `test/nodejs/credentials.test.ts` (through the real deployment)

---

Describes the contracts at commit `e728b81` on `erc8473-main`.
