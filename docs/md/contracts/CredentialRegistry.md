[Overview](../index.md) · [Contracts](../index.md#contracts) · [Who can do what](../roles.md) · [One movement](../movement.md) · [Deployment and governance](../deployment.md) · [Where the money sits](../money.md)

[Contracts](../index.md#contracts) / Identity and fund

# CredentialRegistry

The record of who vouched for each address: which attester, what the address is, until when, and whether it may still send and receive. [CredentialRule](CredentialRule.md) reads it on each movement of a token that lists the rule.

- **contracts/identity/CredentialRegistry.sol**
- immutable, **not a proxy**, one per core
- admin: **the main timelock** after `CoreHandover`
- not attested: the **CredentialRule** that reads it is

<a id="in-one-minute"></a>

> ### In one minute
>
> Before an address can receive a token, someone the issuer trusts has to vouch for it. That someone is an **attester**: for example the issuer's own KYC function or an outside KYC provider. The registry keeps one short record per address: which attester vouched, a set of qualification flags (identity checked, professional investor, fund, licensed institution, a jurisdiction group and so on), an expiry date and a standing. It stores no names, no documents and no country.
>
> The main design choice is that a holder can get out unless someone deliberately blocks them. When a record expires, or its attester is shut down, the holder can still sell or redeem but cannot receive more. An explicit block is what stops a holder from sending. The guardian can block an address or shut down an attester at once; undoing either takes a timelock, a contract that runs governance decisions after a public delay.

<a id="how"></a>
## How it works: a standing, worked out when asked

Each address has one stored record, and its stored status is `NONE`, `ACTIVE`, `EXIT_ONLY` or `BLOCKED`. `CredentialRule` does not read the stored status. It asks `profileOf(subject)`, which works out the **standing** at that moment from the stored status, the expiry, the guardian's block flag and whether the attester has been killed. That is how `LAPSED` exists without anyone writing it: it is an `ACTIVE` record whose `validUntil` has passed.

> **Diagram.** The standing of an address. NONE means never written. An attester's set or register makes it ACTIVE. The attester that wrote the record moves it between ACTIVE, EXIT_ONLY and BLOCKED with setStatus. When validUntil passes, an ACTIVE record reads LAPSED without any transaction, and a fresh write renews it. A killed attester makes its records read EXIT_ONLY, and a guardian block makes any address read BLOCKED; neither is written into the status.
>
> **Four stored statuses and one worked out.** Solid arrows are an attester's writes: its own transaction or, for `register`, a credential it signed, which anyone can submit. Dashed arrows change nothing in the status: the standing changes because time passed, the attester was killed or the guardian blocked the address. The guardian's block is a separate flag on the record.

1. **Written as ACTIVE.** An attester's `set`, or a signed credential submitted with `register`, writes the record as `ACTIVE`, with a `validUntil` in the future and only bits the attester is allowed to assert. A fresh write makes a record `ACTIVE` again, if the writer is allowed to overwrite it (see [Attesters](#attesters)).
2. **The attester changes its own record.** `setStatus(subject, status)` sets `EXIT_ONLY` or `BLOCKED` at any time, and `ACTIVE` only while `validUntil` is still in the future (`CredentialRegistry_ValidityInPast`). `NONE` and `LAPSED` are refused (`CredentialRegistry_InvalidStatus`).
3. **Lapsing takes no transaction.** An `ACTIVE` record reads `ACTIVE` through the last second of its `validUntil` and `LAPSED` from the next one. The attester renews it with a fresh write.
4. **Two overrides, applied when read.** A killed attester makes its records read `EXIT_ONLY`. A guardian block makes the address read `BLOCKED` whatever is stored, even an address that was never written. Neither changes the stored status, so after a revive or a cleared block the record reads as it would have without them: a record past its expiry then reads `LAPSED`, and a record another attester wrote over in the meantime stays theirs.

<a id="resolution"></a>
## The order in which a standing is worked out

`profileOf(subject)` returns the standing with the stored bits and attester id. It asks four questions in a fixed order and stops at the first yes.

> **Diagram.** How profileOf resolves a standing. First, if the guardian blocked the address or the stored status is BLOCKED, the answer is BLOCKED. Second, if the address was never written, NONE. Third, if the attester that wrote it is killed, EXIT_ONLY. Fourth, if the stored status is ACTIVE and the current time is past validUntil, LAPSED. Otherwise the stored status, ACTIVE or EXIT_ONLY.
>
> **A block beats everything, then a kill beats an expiry.** A holder whose attester is killed reads `EXIT_ONLY` even after its expiry, and a holder the guardian blocked reads `BLOCKED` whatever its attester does.

What each standing allows is decided by [`CredentialRule`](CredentialRule.md), the rule that reads the registry. Other rules in a token's list can still refuse a movement this table allows, and the rule does not judge the token's own address on either side.

| Standing | May send, burn, redeem | May receive |
|---|---|---|
| `ACTIVE` | yes | yes, if the token's policy accepts the record |
| `EXIT_ONLY` | yes | no |
| `LAPSED` | yes | no |
| `BLOCKED` | no, except the two enforcement actions, the burner's `burn` and the agent's `forcedTransfer` | no |
| `NONE` | no, with the same two exceptions | no |

<a id="record"></a>
## The record

One record per address, in one storage slot. It holds flags: no names, no evidence, no hashes of personal data, and no country. The link from an address to a person stays with the attester.

| Field | Type | Meaning |
|---|---|---|
| `validUntil` | `uint64` | Unix seconds. In the future when the record is written as `ACTIVE`. The record reads `LAPSED` after it. |
| `status` | `Status` | The stored status: `NONE` (never written), `ACTIVE`, `EXIT_ONLY` or `BLOCKED`. `LAPSED` is not stored. |
| `quals` | `uint32` | The qualification bits, below. |
| `attester` | `uint8` | The id of the attester that wrote the record. |
| `issuedAt` | `uint64` | When the record was issued. It does not go down for one address. |
| `guardianBlock` | `bool` | Set by the guardian. `clearGuardianBlock` clears it, and writes by attesters keep it. |

### Qualification bits

The bits are named in `Quals.sol`. The registry does not interpret them: an attester sets the bits it vouches for, and each token's policy says which it needs. Bits 10 to 15 are reserved for later shared meanings, and bits 16 to 31 are free for a deployment's own use. The names are conveniences, not legal categories. What a bit means in law is for the attester and its counsel to define.

| Bit | Name | Meant for |
|---|---|---|
| 0 | `KYC` | Identity verified by the attester |
| 1 | `PROFESSIONAL` | A professional client or investor (for example MiFID II) |
| 2 | `QUALIFIED` | A qualified or accredited investor |
| 3 | `INSTITUTIONAL` | An institutional investor or eligible counterparty |
| 4 | `FUND` | A fund holding on its own account |
| 5 | `LICENSED` | A licensed financial institution |
| 6 | `CUSTOMER` | A customer of the token's issuer |
| 7 | `INFRA` | A vault, escrow, treasury or other address that holds tokens for the system |
| 8 | `US_PERSON` | A US person, for an offering that restricts or targets them |
| 9 | `EEA` | A person in the European Economic Area, for an offering that restricts or targets them |

**A jurisdiction group is a bit.** A record has no country field. An offering that restricts or targets a group reads that group's bit through the token's policy in [`CredentialRule`](CredentialRule.md) (`requireAny` or `forbidAny`), so it needs no rule of its own, and the attester publishes only what a policy needs.

A bit has to be within the attester's allowed bits to be written. `CoreHandover` adds the first attester with `kycAllowedQuals`, which is 1023 by default: the ten named bits, 0 to 9. A write that asserts any other bit reverts with `CredentialRegistry_QualsNotAllowed` until the deployment passes a wider value or the main timelock calls `setAttesterQuals`.

<a id="attesters"></a>
## Attesters

An attester is an account allowed to write records, within a set of qualification bits. It is not a role: it is an entry in the registry's own list, which `DEFAULT_ADMIN_ROLE` manages.

- **Added in order, not reused.** `addAttester` gives ids 0, 1, 2 and so on, for at most `MAX_ATTESTERS` (64) attesters. The list only grows, so a later attester does not take an earlier id, and with it the records written under that id.
- **One account, one attester.** The account can be a plain key or a contract account such as a multisig, which signs through ERC-1271. An account that is already an attester is refused, for a fresh entry and for a rotation (`CredentialRegistry_AttesterExists`).
- **Allowed bits.** A write that asserts a bit outside the attester's `allowedQuals` reverts (`CredentialRegistry_QualsNotAllowed`). Changing the allowed bits does not touch records already written.
- **Who may overwrite a record.** An attester may write over a record if the address has none, the same attester wrote it, or the attester that wrote it is killed (`CredentialRegistry_RecordOwnedByAnotherAttester` otherwise). Two providers vouching for one address therefore do not silently replace each other. Changing a record's status is for the attester that wrote it (`CredentialRegistry_NotRecordAttester`).
- **Killed.** `killAttester`, by the guardian with no delay or by the admin, the main timelock of the core that deployed the registry. From then on the attester's `set`, `setStatus` and signed credentials revert with `CredentialRegistry_AttesterKilled`, its records read `EXIT_ONLY` (except those that read `BLOCKED`), and another attester may write over them. The kill flags of all attesters share one 64-bit word, so checking both parties of a movement adds one cold storage read, not two.
- **Revived.** `reviveAttester`, by the main timelock or the recovery timelock. It clears the kill bit and nothing else: the account and the allowed bits are as they were, and the records it still owns are resolved as if it had not been killed.

<a id="signed"></a>
## The signed path: credentials anyone can submit

An attester does not have to send a transaction for each holder. It can sign a credential off chain, as EIP-712 typed data, and anyone can submit it with `register(credential, signature)`: the holder, the issuer's back office or a relayer. Whoever submits pays the gas, and the attester's key stays off the hot path.

- **Domain**: name `CredentialRegistry`, version `1`, the chain id and the registry's address
- **Type**: `Credential(address subject,uint64 validUntil,uint32 quals,uint64 issuedAt,uint8 attester)`
- **Signature**: checked against the attester's current account: ECDSA for a key, ERC-1271 for a contract account. The credential names its attester id, so the registry knows which account to ask.

`register` runs these checks in order:

1. The attester id exists (`CredentialRegistry_UnknownAttester`) and is not killed (`CredentialRegistry_AttesterKilled`).
2. `issuedAt` is not in the future (`CredentialRegistry_IssuedInFuture`).
3. The signature is valid for the attester's account (`CredentialRegistry_BadSignature`).
4. `issuedAt` is strictly above the `issuedAt` stored for the address (`CredentialRegistry_StaleCredential`).
5. The same checks as `set`: the address is not zero (`CredentialRegistry_ZeroAddress`), the bits are allowed, `validUntil` is in the future, and no other attester that is not killed owns the record. The record is then written as `ACTIVE` with the credential's `issuedAt`.

The `issuedAt` rule is what makes the signed path safe. A credential can be submitted once, because a replay is not newer than itself. An older credential does not undo a later direct write or status change, because `set` and `setStatus` both set `issuedAt` to the block's time. An attester that wants to withdraw a credential nobody has submitted yet writes the address directly, which makes each credential issued up to that moment stale, and can then block the address with `setStatus`. A newer credential from the same attester can lift that attester's own block (`test_WhenTheAttesterIssuesANewerCredentialAfterItsOwnBlock_ItLiftsIt`). It does not lift a guardian block.

<a id="guardian"></a>
## The guardian's two powers, and how they are undone

The guardian multisig holds `GUARDIAN_ROLE` on this contract, a role separate from the one on the tokens, granted in the constructor. It can do two things here, both at once, with no delay: block an address (`blockSubject`) and kill an attester (`killAttester`).

- A block is a separate flag on the record, not a status. It works on an address that was never written, so a later write is born blocked.
- No attester can lift it: `set` and `register` keep the flag, and `setStatus(subject, ACTIVE)` changes the stored status underneath it (`test_WhenAGuardianBlockIsSet_SetStatusActiveDoesNotClearIt`).
- `clearGuardianBlock` lifts it, called by the main timelock (`DEFAULT_ADMIN_ROLE`) or the recovery timelock (`RECOVERY_ROLE`), each after its delay. `reviveAttester` undoes a kill, with the same two callers.
- The recovery timelock is needed because the guardian can cancel operations on the main timelock, and could therefore cancel its own unblock there. Nobody can cancel on the recovery timelock. For the same reason the recovery timelock may remove the guardian (`revokeRole(GUARDIAN_ROLE, account)`). It can do those three things here and nothing else, and it cannot grant a role (`test_WhenRecoveryTriesToGrant_ItReverts`).

<a id="roles"></a>
## Roles, as deployed

The constructor takes the admin and the guardian and refuses a zero address for either (`CredentialRegistry_ZeroAddress`). `Core` deploys the registry, when a product of the profile lists `CredentialRule`, with the deployer as admin. The council reads its code before it attests the rule; at that step the deployer is still its admin and it has no attester. `CoreHandover` then adds the attester, grants `RECOVERY_ROLE` to the recovery timelock and `DEFAULT_ADMIN_ROLE` to the main timelock, and the deployer renounces its own. A core that reads an existing registry deploys none and hands none over; its post-deploy check asserts that the admin and the guardian the deployment names hold their roles on that registry ([Using an existing credential registry](../deployment.md#external)).

| Role | Held by | May |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | The deployer until `CoreHandover`, then the main timelock | Add attesters, rotate their accounts, change their allowed bits, kill and revive them, clear a guardian block, grant and revoke roles. It does not write records itself. |
| `GUARDIAN_ROLE` | The guardian multisig, from the constructor | Block an address and kill an attester. |
| `RECOVERY_ROLE` | The recovery timelock, granted by `CoreHandover` | Clear a guardian block, revive an attester, revoke `GUARDIAN_ROLE`. |
| An attester (not a role) | One account at hand-over: the `kycAttester` parameter, id 0 | Write records and change the status of its own. |

The post-deploy check pins the result when it is run: one attester, the KYC function, not killed; the guardian holds only `GUARDIAN_ROLE`; the recovery timelock holds only `RECOVERY_ROLE`; the deployer and the operations account hold nothing.

<a id="isverified"></a>
## isVerified

The registry also answers `isVerified(user)` from `IIdentityRegistry`, the one-question view that an identity registry such as ERC-3643's offers. It is true only when the standing is `ACTIVE`, and it says nothing about any token's policy. No contract that ships calls it. `CredentialRule` reads `profileOf` instead, because a yes-or-no answer does not tell a holder who may still leave (`EXIT_ONLY`, `LAPSED`) from one who may not (`BLOCKED`, `NONE`). The registry reports both interfaces through ERC-165.

<a id="compromise"></a>
## If an attester is compromised

The registry trusts an attester's call or signature. Whoever controls an attester's key can do what that attester can do, until it is stopped.

### What it can write

- `ACTIVE` records, directly or as signed credentials anyone can submit, for an address that has no record, whose record it wrote itself, or whose attester is killed. It chooses the expiry.
- Only bits within its own `allowedQuals`.
- A different status on the records it wrote: `EXIT_ONLY` or `BLOCKED`, which stops those holders receiving or, for `BLOCKED`, sending; or `ACTIVE` again while the record is valid.

### What limits it

- **The bits it may assert.** Set by the main timelock; another bit reverts with `CredentialRegistry_QualsNotAllowed`.
- **Each token's trusted-attester bitmap.** A token whose policy does not list the attester's id admits none of its records as a receiver.
- **Other attesters' records.** It cannot overwrite or change a record another attester wrote while that attester is not killed.
- **The guardian.** `killAttester` stops it at once, and `blockSubject` stops an address it vouched for. It cannot clear a guardian block.

After a kill, the holders it vouched for read `EXIT_ONLY`: they can leave, and cannot receive. Holders it had set to `BLOCKED` read `BLOCKED`, because a stored block beats a kill. Another attester can write over its records, and that write makes such a holder read `ACTIVE` unless the guardian has blocked it too. The agent's `forcedTransfer` and the burner's `burn` still work on a blocked holder. Then the main timelock rotates the attester's account with `setAttesterAccount`, which makes signatures by the previous key fail. `reviveAttester` changes nothing but the kill flag, so the account is rotated before the attester is revived.

<a id="functions"></a>
## What it can do

| Function | Who can call | What it does |
|---|---|---|
| `set(subject, validUntil, quals)` | An attester that is not killed | Writes the record as `ACTIVE`, with `issuedAt` set to the block's time. Keeps a guardian block. Emits `CredentialSet`. Reverts with `CredentialRegistry_NotAnAttester`, `CredentialRegistry_ZeroAddress`, `CredentialRegistry_AttesterKilled`, `CredentialRegistry_QualsNotAllowed`, `CredentialRegistry_ValidityInPast` or `CredentialRegistry_RecordOwnedByAnotherAttester`. |
| `register(credential, signature)` | Anyone | Writes a record an attester signed off chain, with the credential's `issuedAt`. Emits `CredentialSet`. Reverts as in [the signed path](#signed). |
| `setStatus(subject, status)` | The attester that wrote the record, while not killed | Sets the stored status to `ACTIVE`, `EXIT_ONLY` or `BLOCKED`, and `issuedAt` to the block's time. Does not clear a guardian block. Emits `StatusSet`. Reverts with `CredentialRegistry_NotAnAttester`, `CredentialRegistry_InvalidStatus`, `CredentialRegistry_AttesterKilled`, `CredentialRegistry_NoRecord`, `CredentialRegistry_NotRecordAttester`, or `CredentialRegistry_ValidityInPast` for `ACTIVE`. |
| `blockSubject(subject)` | `GUARDIAN_ROLE` | Sets the guardian block, with no delay. Does nothing if already set. Emits `SubjectBlocked`. |
| `clearGuardianBlock(subject)` | `DEFAULT_ADMIN_ROLE` or `RECOVERY_ROLE` | Clears the guardian block. Does nothing if not set. Emits `SubjectUnblocked`. |
| `addAttester(account, allowedQuals)` | `DEFAULT_ADMIN_ROLE` | Adds an attester under the next id and returns the id. Emits `AttesterAdded`. Reverts with `CredentialRegistry_ZeroAddress`, `CredentialRegistry_AttesterExists` or `CredentialRegistry_TooManyAttesters`. |
| `setAttesterAccount(id, account)` | `DEFAULT_ADMIN_ROLE` | Rotates the attester's key. Its records stay, and signatures by the previous account stop working at once. Emits `AttesterAccountSet`. Reverts with `CredentialRegistry_UnknownAttester`, `CredentialRegistry_ZeroAddress` or `CredentialRegistry_AttesterExists`. |
| `setAttesterQuals(id, allowedQuals)` | `DEFAULT_ADMIN_ROLE` | Changes the bits the attester may assert. Records already written keep their bits. Emits `AttesterQualsSet`. Reverts with `CredentialRegistry_UnknownAttester`. |
| `killAttester(id)` | `GUARDIAN_ROLE` or `DEFAULT_ADMIN_ROLE` | Stops the attester writing and makes its records read `EXIT_ONLY`. Does nothing if already killed. Emits `AttesterKilled`. Reverts with `CredentialRegistry_UnknownAttester`. |
| `reviveAttester(id)` | `DEFAULT_ADMIN_ROLE` or `RECOVERY_ROLE` | Clears the kill and nothing else. Does nothing if not killed. Emits `AttesterRevived`. Reverts with `CredentialRegistry_UnknownAttester`. |
| `revokeRole(role, account)` | The role's admin; `RECOVERY_ROLE` for `GUARDIAN_ROLE` only | OpenZeppelin `AccessControl`, with one addition: the recovery timelock may remove the guardian. |
| `grantRole(role, account)`, `renounceRole(role, account)` | The role's admin; the holder | OpenZeppelin `AccessControl`, unchanged. |
| `profileOf(subject)` | Anyone (read-only) | The standing at this moment, with the stored bits and attester id. |
| `isVerified(user)` | Anyone (read-only) | True only when the standing is `ACTIVE`. |
| `recordOf(subject)` | Anyone (read-only) | The stored record as written, not resolved. |
| `attesterAt(id)`, `attesterCount()`, `attesterIdOf(account)` | Anyone (read-only) | An attester's account, allowed bits and kill flag (`CredentialRegistry_UnknownAttester` for an id that does not exist); how many exist; the id of an account. |
| `credentialHash(credential)`, `eip712Domain()` | Anyone (read-only) | The digest an attester signs, and the signing domain, so a client needs to derive neither. |
| `GUARDIAN_ROLE()`, `RECOVERY_ROLE()`, `DEFAULT_ADMIN_ROLE()`, `CREDENTIAL_TYPEHASH()`, `MAX_ATTESTERS()`, `hasRole`, `getRoleAdmin`, `supportsInterface` | Anyone (read-only) | The constants, the role table, and ERC-165 for `ICredentialRegistry`, `IIdentityRegistry` and the `AccessControl` interfaces. |

Role checks revert with OpenZeppelin's `AccessControlUnauthorizedAccount`.

| Event | Emitted when |
|---|---|
| `CredentialSet(subject, attester, validUntil, quals, issuedAt)` | A record is written as `ACTIVE`, by `set` or `register` |
| `StatusSet(subject, attester, status)` | An attester changes the status of its record |
| `SubjectBlocked(subject, guardian)` | The guardian blocks an address that was not blocked |
| `SubjectUnblocked(subject, by)` | A timelock clears a block that was set |
| `AttesterAdded(id, account, allowedQuals)` | An attester is added |
| `AttesterAccountSet(id, previous, account)` | An attester's key is rotated |
| `AttesterQualsSet(id, allowedQuals)` | An attester's allowed bits change |
| `AttesterKilled(id, by)` | An attester that was not killed is killed |
| `AttesterRevived(id, by)` | A killed attester is revived |

The calls that do nothing (blocking twice, clearing a block that is not there, killing twice, reviving an attester that is not killed) emit nothing. Role changes emit OpenZeppelin's `RoleGranted` and `RoleRevoked`.

<a id="why"></a>
## Why it is built this way

- **Flags stored, standing worked out on read.** Expiry, kills and blocks are applied by `profileOf`, so the rule does no time or trust arithmetic and an expiry needs no transaction. Three invariant tests hold this together: `invariant_IssuedAtNeverDecreases`, `invariant_ActiveIsAlwaysWithinValidity` and `invariant_AGuardianBlockAlwaysReadsBlocked`.
- **Getting out is the default.** A lapsed record and a killed attester both leave the holder able to sell, burn and redeem. An explicit block, by the attester or the guardian, is what stops a holder from sending.
- **The guardian can only stop.** It blocks and kills with no delay; lifting a block and reviving an attester go through a timelock, and the recovery timelock is there so that the guardian cannot keep its own block in place by cancelling the unblock.
- **One registry per core.** A client is verified once and can hold each of the issuer's products whose policy accepts the record, and a block applies across them (`products.test.ts`).
- **Ids are not reused.** A killed attester's records do not come back to life under a later attester that happens to get the same id.
- **Not a proxy.** The registry is not upgradeable. A change to the record's layout means a fresh registry, a rule that reads it, and a `setRules` on each token.
- **Not attested itself.** The council attests `CredentialRule`, whose code hash covers the registry's address as an immutable but not the registry's code. So the council reads the registry's code before it attests the rule, and after hand-over the post-deploy check asserts that the main timelock is its admin and that it has one attester, the KYC function.

<a id="limits"></a>
## What it does not do

- **It verifies no KYC.** It records what an attester says, and holds no proof that the checks behind a record took place. A compromised attester key can credential an address for each token whose policy trusts that attester, with each bit the attester may assert.
- **A lapse does not stop funds already held.** A holder whose credential lapsed, or whose attester was killed, can still send, burn and redeem. That is deliberate. The controls for that are a block, [`HolderRestrictionRule`](HolderRestrictionRule.md)'s freeze and lockup, and `forcedTransfer`.
- **The bitmap is about receivers.** The sender check in `CredentialRule` reads the standing and not which attester wrote the record, so an existing holder can leave whichever attester vouched.
- **It does not model entities.** One address is one holder. Nothing links two wallets of one client.
- **It does not interpret a bit.** It stores what the attester asserts, within the allowed bits, and whether that is right in law is off-chain.
- **It does not keep things private.** No field and no event carries a name or evidence, but the flags are public on chain, and a jurisdiction or a qualification bit can still say something about a customer. Whether an address with a credential is still personal data is for counsel.
- **It does not remove attesters.** A kill stops one, and its entry stays. After 64 entries `addAttester` reverts with `CredentialRegistry_TooManyAttesters`.
- **A registry read by several cores has one governance.** Its admin chooses the attesters and its guardian blocks and kills for every token that reads it, whichever core the token is on.
- **The attester's writes have no delay.** `set`, `register` and `setStatus` take effect at once: for receiving, across each token whose policy trusts the attester; for sending, across each token that lists `CredentialRule`, whether or not its policy trusts the attester.

<a id="connected"></a>
## Connected to

- [CredentialRule](CredentialRule.md): The rule that reads the registry and applies each token's policy to the receiver.
- [GovernanceTimelock](GovernanceTimelock.md): The main timelock is the registry's admin after hand-over, and the recovery timelock undoes the guardian here.
- [Who can do what](../roles.md): The guardian, the two timelocks and the attester across the whole system.
- [Deployment and governance](../deployment.md): Where the registry is created, given its attester and handed to the timelock.

<a id="source"></a>
## Source and tests

- Contract: `contracts/identity/CredentialRegistry.sol`, interfaces `ICredentialRegistry.sol` and `IIdentityRegistry.sol`, bits in `Quals.sol`
- Deployment: `ignition/modules/Core.ts` and `CoreHandover.ts`
- Tests: `CredentialRegistry.t.sol` (each function, the resolution order, signing by a key and by an ERC-1271 contract, and the three invariants above), and `test/nodejs/credentials.test.ts` (through the real deployment: a credential signed with viem and submitted by a stranger, a lapse on the real clock, a block lifted by the recovery timelock, an attester killed and revived)

---

Describes the contracts at commit `0f8b72f` on `erc8473-main`.
