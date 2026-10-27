# Credentials

Who may hold a token, and for how long. `CredentialRegistry` records, for each address, which attester vouched for it, what it is, until when, and its standing. `CredentialRule` applies a policy to that record, token by token. The token, the hook and the other rules do not know the registry exists: it is one more rule in the list ([transfer-checks.md](transfer-checks.md#credentialrule)).

`IdentityRule` asked one yes-or-no question per address. This layer answers four more: who said so, what the address is (a customer, a professional investor, a fund, a bank, infrastructure), when the statement ends, and whether the holder may still leave. The last one matters most. A holder whose verification lapses must be able to sell or redeem, so a lapsed holder can send and cannot receive.

What it does not do: store names, evidence or hashes of personal data (the link from an address to a person stays with the attester); verify a W3C credential on chain; count investors by anything but address; apply a rule by country. Section "What it leaves out" says more.

## The record

One storage slot per address, 25 bytes:

| Field | Meaning |
|---|---|
| `validUntil` | Unix seconds. Non-zero and in the future when the record is written as `ACTIVE` |
| `status` | `ACTIVE`, `EXIT_ONLY` or `BLOCKED` as the attester last set it; `NONE` when never written. `LAPSED` is only ever returned, never stored |
| `quals` | A bitmask of qualifications, below |
| `country` | ISO 3166-1 numeric. Stored for later rules; no rule reads it yet |
| `attester` | The id of the attester that wrote the record |
| `issuedAt` | When the attester issued it. Only ever rises for one address |
| `guardianBlock` | Set by the guardian. Cleared only by the main or the recovery timelock |

The qualification bits are fixed in `contracts/interfaces/Quals.sol` and pinned by `InterfaceFreeze.t.sol`. The registry never interprets them; a token's policy says which it needs.

| Bit | Name | Meant for |
|---|---|---|
| 0 | `KYC` | Identity verified by the attester |
| 1 | `PROFESSIONAL` | A professional client or investor (for example MiFID II) |
| 2 | `QUALIFIED` | A qualified or accredited investor |
| 3 | `INSTITUTIONAL` | An institutional investor or eligible counterparty |
| 4 | `FUND` | A fund holding on its own account |
| 5 | `BANK` | A regulated credit institution |
| 6 | `CUSTOMER` | A customer of the bank that issues the token |
| 7 | `INFRA` | A vault, escrow, treasury or other address that holds tokens for the system |

Bits 8 to 15 are reserved for later shared meanings and 16 to 31 are free for a deployment. Retail is the absence of the higher bits, not a bit of its own. What a bit means in law is for the attester and its counsel to define; the names are conveniences, and a bank should have their wording reviewed before relying on them.

## Standings

`profileOf(address)` resolves the standing at the time of the call, in this order:

| Order | Condition | Standing |
|---|---|---|
| 1 | `guardianBlock` is set, or the stored status is `BLOCKED` | `BLOCKED` |
| 2 | The address was never written | `NONE` |
| 3 | The attester that wrote it is killed | `EXIT_ONLY` |
| 4 | The stored status is `ACTIVE` and `block.timestamp > validUntil` | `LAPSED` |
| 5 | Otherwise | the stored status |

A record reads `ACTIVE` through its last second. It returns the standing with the stored `quals`, `country` and attester id, and `isVerified(address)` is true only for `ACTIVE`, so the registry also works behind `IdentityRule` (where a lapsed or exit-only holder has no way out).

| Standing | May send, burn, redeem | May receive |
|---|---|---|
| `ACTIVE` | yes | yes, if the token's policy accepts it |
| `EXIT_ONLY` | yes | no |
| `LAPSED` | yes | no |
| `BLOCKED` | no, except the issuer's enforcement burn and the agent's `forcedTransfer` | no |
| `NONE` | no, with the same exceptions | no |

## Who writes

| Who | May do | May not |
|---|---|---|
| An attester (`set`, `setStatus`) | Write a record as `ACTIVE` within the bits it is allowed to assert, with `validUntil` in the future. Change the status of a record it wrote to `ACTIVE`, `EXIT_ONLY` or `BLOCKED` | Assert a bit outside its mask. Touch a record another active attester wrote. Clear a guardian block. Write once killed |
| Anyone (`register`) | Submit a credential an attester signed off chain | Submit one that is not newer than the stored record, is issued in the future, or whose signature does not match the attester's account |
| The guardian | Block an address (`blockSubject`) or kill an attester (`killAttester`), with no delay | Unblock, revive, add an attester or write a record |
| The main timelock (`DEFAULT_ADMIN_ROLE`) | Add an attester, rotate its account, change the bits it may assert, kill it. Clear a block. Revive an attester | Write a record |
| The recovery timelock (`RECOVERY_ROLE`) | Clear a block, revive an attester, and revoke `GUARDIAN_ROLE`, and nothing else | Grant any role, add or kill an attester |

The recovery timelock can undo the guardian because the guardian holds `CANCELLER_ROLE` on the main timelock and could cancel an unblock scheduled there. Nobody can cancel on the recovery timelock ([roles.md](roles.md#what-the-guardian-can-do)).

An attester may overwrite a record only if the address has none, the same attester wrote it, or the attester that wrote it is killed. Two providers vouching for one address therefore do not silently replace each other.

### The signed path

The attester signs EIP-712 typed data and anyone submits it with `register(credential, signature)`, so the holder or a relayer pays the gas and the attester's key stays off the hot path. The signature is checked with ECDSA or, for a contract account such as a Safe or an HSM front, ERC-1271.

- Domain: name `CredentialRegistry`, version `1`, the chain id and the registry's address.
- Type: `Credential(address subject,uint64 validUntil,uint32 quals,uint16 country,uint64 issuedAt,uint8 attester)`. It names the attester, because ERC-1271 cannot recover a signer.
- `credentialHash(credential)` returns the digest, and `eip712Domain()` the domain, so a client can sign without deriving either off chain.
- `issuedAt` must be above the stored one and not in the future. A credential can therefore never overwrite a newer write, a status change or a block, and replaying one reverts.

A W3C verifiable credential stays off chain. The attester's service verifies the holder's credential, or its own KYC record, and signs this record. The registry verifies nothing else. To revoke a signed credential that nobody has submitted, the attester writes a record for the address and blocks it (which raises `issuedAt` past the credential's), or the guardian blocks the address; `validUntil` limits the exposure either way.

## The token's policy

`CredentialRule.setPolicy(token, requireAll, requireAny, forbidAny, attesters)`, set by the token's `DEFAULT_ADMIN_ROLE`. A receiver is eligible when its standing is `ACTIVE`, its attester is in the `attesters` bitmap, it holds every bit of `requireAll`, it holds at least one bit of `requireAny` when that is not zero, and it holds no bit of `forbidAny`. A token with `attesters == 0` admits no receiver; holders can still leave.

| Token | `attesters` | `requireAll` | `requireAny` | Effect |
|---|---|---|---|---|
| The demo's three tokens | attester 0 | `KYC` | none | Anyone the demo KYC attester vouches for |
| A bank's deposit token | the bank's KYC attester | `KYC` and `CUSTOMER` | none | Only the bank's own customers. An address of the bank's infrastructure passes only if the attester also gives it `CUSTOMER` |
| A fund class for professionals | the bank's and a provider's attesters | `KYC` | `PROFESSIONAL`, `INSTITUTIONAL`, `BANK`, `FUND`, `INFRA` | No retail receiver. A vault or treasury passes through `INFRA` |

The second and third rows are examples of what a policy can say; the deployment in this repo sets only the first.

## Operations

| To | Do | Waits |
|---|---|---|
| Onboard a holder | The attester calls `set(address, validUntil, quals, country)`, or signs a credential that anyone submits | No |
| Renew a holder | The same attester writes again | No |
| Stop a holder receiving, but let them leave | `setStatus(address, EXIT_ONLY)` | No |
| Stop a holder entirely | `setStatus(address, BLOCKED)`, or the guardian's `blockSubject` | No |
| Lift an attester's own block | `setStatus(address, ACTIVE)`, while `validUntil` is in the future | No |
| Lift a guardian block | `clearGuardianBlock`, by the main timelock or the recovery timelock | The timelock's delay |
| Add an attester, or change its allowed bits | The main timelock | The delay |
| Rotate an attester's key | `setAttesterAccount(id, newAccount)`, by the main timelock. Records stay; signatures by the old account stop working | The delay |
| Stop an attester at once | The guardian's `killAttester`. Its holders become `EXIT_ONLY` | No |
| Bring it back | `reviveAttester`, by the main or the recovery timelock | The delay |
| Change a token's policy | `setPolicy`, by the token's admin | The delay, after hand-over |

At most 64 attesters exist, and an id is never reused, so a record can never be taken over by a new attester that reuses an old id. During `Activate` the deployer holds the registry's admin role and adds the first attester, then the registry goes to the timelock like everything else ([governance-and-deployment.md](governance-and-deployment.md)).

## What it leaves out

- **Entities.** One wallet is one holder. An omnibus wallet of a custodian counts once in a holder cap, and one investor with two wallets counts twice. A wallet-to-entity map would fix both and is not built.
- **Country.** It is stored and returned. No rule reads it.
- **Evidence and personal data.** None is stored, and no event carries any. The address-to-person link stays with the attester. A flag such as a country or a qualification can still identify a customer under bank-secrecy rules, and on a public chain it is visible.
- **The registry's own code.** The council attests the rule, and the rule's codehash covers the registry's address and not its code. The council reads the registry before it attests the rule.
- **Trust in the attester.** An attester that is compromised can vouch for any address, for every token that trusts it. The limits are the bits it may assert, the token's attester bitmap, and the guardian's `killAttester`. The registry has no proof of the KYC itself.

Code: `CredentialRegistry.profileOf`, `set`, `register`, `setStatus`, `blockSubject`, `clearGuardianBlock`, `addAttester`, `setAttesterAccount`, `killAttester`, `reviveAttester`, `credentialHash`, `_write`; `CredentialRule.check`, `checkSend`, `checkReceive`, `setPolicy`; `ignition/modules/Activate.ts`.
