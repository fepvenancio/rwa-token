# Security and audit preparation

Proprietary code (see [`LICENSE`](LICENSE)). Report suspected vulnerabilities privately to the repository owner,
Filipe Venancio; do not open public issues.

This file collects what an external auditor receives, so the audit scope is not reconstructed from git history. Each
item links to where it is maintained; this file only indexes and summarises.

## 1. Audit package

| Item | Where |
|---|---|
| Brief: architecture, rules, phase scope | [`CLAUDE.md`](CLAUDE.md) |
| Security model: roles, delays, invariants | [`README.md` → Security model](README.md#security-model) |
| Deployment runbook, including the council procedure | [`README.md` → Deployment runbook](README.md#deployment-runbook) |
| Deviations from the brief | [`README.md` → Deviations from the brief](README.md#deviations-from-the-brief) |
| Decision log, owner decisions, review validations | [`PLAN.md`](PLAN.md) |
| Static-analysis suppressions and their reasons | §4 below |
| Mutation-testing results | §5 below |
| Findings that contradict reasonable assumptions | §3 below |
| Reference build for the audited tag | GitHub release `release-build-<tag>.tar.gz` (from `.github/workflows/release.yml`): `manifest.json` plus build-info for in-scope sources only; no tests, mocks or OZ-rooted jobs |

**Audited revision:** a `v*` tag. Its reference build is reproducible from the source at that tag
(`npm ci && npm run verify:reproducible`) and must match the published archive.

## 2. Scope

In scope, all under `contracts/` (`.t.sol` files and `contracts/test/` are test code):

| Area | Contracts |
|---|---|
| Base | `base/PolicyGatedERC20Upgradeable` |
| Templates | `tokens/GatedToken`, `tokens/IntentToken`, `vaults/Gated4626Vault`, `vaults/Gated7540Vault`, with `vaults/Gated7540Common` and `vaults/Gated7540Settlement` (created by the implementation's constructor; its codehash pins the address, and the post-deploy check compares the code with the release) |
| Mixin | `mixins/IntentSettledUpgradeable` |
| Policy | `hooks/ComplianceHook` (one per deployment, shared by every token), `hooks/BaseRule`, `hooks/rules/{Credential,MinPosition,HolderRestriction,SettlementWindow,FundHolders,SupplyCap,ExecutedOnly}Rule` |
| Credentials | `identity/CredentialRegistry` (immutable, not a proxy, not attested; the `CredentialRule` codehash covers its address, not its code) |
| Fund | `fund/Fund` (not a proxy, not attested; the `FundHoldersRule` codehash covers its address, not its code) |
| Governance | `governance/PolicyRegistry`, `governance/GovernanceTimelock` (the main timelock: OZ `TimelockController` plus a revoke-`CANCELLER_ROLE`-only `RECOVERY_ROLE`) |
| Settlement | `intents/IntentExecutor`, `intents/DvPExecutor` (neither is a proxy, and neither is attested: each token authorises an executor by granting it `EXECUTOR_ROLE`), `intents/SignedEntry` (immutable, no roles: a vault judges it as any other payer) |
| Deployment | `deploy/ProxyDeployer`, `deploy/TokenProxy` |
| Portfolio | `portfolio/Portfolio`, `portfolio/ERC4626Adapter`, `portfolio/GuardedAccount` (immutable, attested as `PORTFOLIO` and `ADAPTER`), `portfolio/ERC20CallValidator`, `portfolio/ERC4626CallValidator` (attested as `VALIDATOR`) |
| Pricing | `nav/NavDesk` (immutable, not attested: it acts by the `SETTLER_ROLE` it holds), `nav/FeeModel` (immutable, attested as `FEE_MODEL`) |
| Distribution | `distribution/Distributor` (immutable, one per token, not attested: it holds its own funding and asks the token for roles) |
| Interfaces | `interfaces/*` (frozen; ERC-165 ids, event topics and reason codes pinned by `contracts/test/InterfaceFreeze.t.sol`; the owner has reopened them on instruction, most recently 2026-10-23 to 24 for the review items, 2026-10-27 for `IProxyDeployer` 2026-10-30 for the portfolio lego and a renamed `Quals` bit, and 2026-11-01 for three errors and NatSpec, moving no id, and they are frozen again) |

Also in scope: `ignition/modules/{Core,CoreHandover,Fund,Legos,Product,FundOpen,roles}.ts` and `ignition/profiles.ts`, which carry
the deployment order, role grants, the hand-over to the timelock and each product's rule list.

Out of scope: OpenZeppelin 5.6.1 (`@openzeppelin/contracts`, `-upgradeable`; `TimelockController` is the base of `GovernanceTimelock`, which both timelocks are),
the KYC attesters' off-chain verification, and test mocks.

Build: solc 0.8.30, `evmVersion: cancun`, optimizer 200 runs, no metadata hash, the same in Hardhat and forge.

## 3. Things that differ from what you might assume

1. **A token's address is fixed by its symbol, not by its configuration.** CREATE2 over `ERC1967Proxy(impl, initData)`
   would make the address depend on `initData` (admin, guardian, hook, rules), so changing any of them would move the
   token. `ProxyDeployer` instead CREATE2s `TokenProxy(impl, "")` with salt `keccak256(symbol)`, so the address depends
   only on the deployer, the symbol and the implementation, and the council can compute it off-chain. `deploy`:
   - is owner-only. The address does not cover the init data, so anyone else could otherwise occupy it with their own
     admin. Ownership moves to the operations account in `CoreHandover`, so a product launches without a timelock delay;
   - refuses, before it creates the proxy, an implementation that its registry (fixed at construction) has not attested
     as `IMPLEMENTATION` (`ProxyDeployer_ImplementationNotAttested`). The token cannot check this itself: its
     initialiser is the implementation's own code;
   - initialises in the same transaction (the token installs its rule list on the shared hook in its initialiser);
   - checks that the token names the deployer's registry (`ProxyDeployer_RegistryMismatch`), that the hook is installed,
     that it holds exactly the rules the deployer expected for the new token (`ProxyDeployer_RulesMismatch`), and the
     symbol;
   - allows each symbol once.

   A reverted deploy leaves no proxy and does not use up the symbol. Tests: `contracts/deploy/ProxyDeployer.t.sol`,
   `test/nodejs/deployment.test.ts`.
2. **`TokenProxy` overrides `_unsafeAllowUninitialized()` to return true.** OZ 5.6's `ERC1967Proxy` refuses empty init
   data to prevent proxies left open for anyone to initialise first. The override is the extension point OZ documents
   for code that initialises another way. Here, `ProxyDeployer` initialises in the same transaction that creates the
   proxy, so no uninitialised `TokenProxy` of this system exists after any transaction. A `TokenProxy` deployed by any
   other route is not one of this system's tokens. Pinned by tests:
   - a failed `initialize` leaves no code at the address;
   - re-initialising a deployed token reverts.
3. **A hook's attestation covers its code, not any token's rule list.**
   - The hook's only immutable is `REGISTRY`, inside the attested codehash. One attestation of one hook covers every
     token of the deployment, and a second instance on the same registry shares that codehash.
   - Each token's ordered rule list is storage, keyed by token. A contract can set the list of its own address and of no
     other (a token does it in its initialiser); anyone else needs that token's `DEFAULT_ADMIN_ROLE`, asked live.
   - Controls:
     - each rule is attested on its own and re-checked by `setRules`;
     - after the initialiser, only the token's admin (the timelock) can change the list, and only the timelock can
       install another hook, which must name the token's own registry (`PolicyGated_HookRegistryMismatch`);
     - `ProxyDeployer` reverts unless the hook holds exactly the expected rules for the new token;
     - the post-deploy check asserts every token runs the one recorded hook and that its list equals the product's `rules`.
   - Tests: a second hook on the same registry is attested through the shared codehash, `Product` completes on it, and
     the post-deploy check refuses it; a hook on another registry is refused by the token before anything is created
     (`deployment.test.ts`).

Further limits recorded during review:

- **`canExecute` takes the account that would call, so the answer does not depend on who asks.** It says
  `NOT_EXECUTOR` first when that account lacks `EXECUTOR_ROLE`, then runs the checks `executeTransfer` runs, with that
  account as the rules' operator. An intent that names an executor pre-flights true only for that account: for any
  other, once the deadline and nonce checks pass, it returns `WRONG_EXECUTOR` (`intents.test.ts`).
- **The token does not enforce a stated consideration.** An intent can state what its signer is to receive
  (`considerationToken`, `considerationAmount`). The token hashes both fields into the digest the holder signs and reads
  them only to reject an intent that states a consideration without naming an executor
  (`CONSIDERATION_NEEDS_EXECUTOR`). Only the executor the intent names can enforce the payment, if its code does.
  `DvPExecutor` does. `IntentExecutor` moves one token and cannot enforce a payment, so it refuses an intent that
  states one, naming it or not, with `IntentExecutor_ConsiderationNotSupported(index)` before the token is called
  (`test_WhenTheIntentNamesTheIntentExecutorAndStatesAPayment_ItIsRefusedAndNothingMoves`). Without that, a signer who
  read a payment in the message and did not check which contract the `executor` field names would see the shares
  move without it. The token's `canExecute` does not see this refusal: it belongs to the executor.
- **What the DvP executor trusts, and what it does not** ([`DvPExecutor` page](docs/contracts/DvPExecutor.html)). An operator chooses
  which signed legs to pair, when to submit, and the token addresses, and cannot redirect value: each party's signature
  covers the other party, the amounts, both tokens and the executor, the mirror check ties the two together, and for an
  ERC-3009 cash leg the buyer's nonce commits to the whole securities intent and to the security token's address.
  The address matters. With the bare intent hash as the nonce, an operator could pair the buyer's authorization with a
  substituted security token that reports the genuine hash and delivers nothing
  (`test_WhenAnOperatorSubstitutesACounterfeitSecurityToken_TheAuthorizationIsRefused`). There is no on-chain allowlist
  of tokens: a party who signs a trade that names a counterfeit token loses to it. In the ERC-3009 form the buyer's
  wallet shows an opaque nonce and cannot show what the buyer receives.
- **DvP pre-flight limits.** It does not check `OPERATOR_ROLE`. For an
  ERC-3009 cash token it cannot check the buyer's signature or the token's pause and blocklist. Legs on tokens that share
  policy state, such as two classes of one fund, are each checked against the state before either has run, so a swap
  that the first leg turns into a new investor can pass pre-flight and fail on the second leg
  (`test_WhenTheFundIsAboveItsLoweredCap_ASwapOfTwoClassesPassesPreflightAndFailsOnTheSecondLeg`).
- **ERC-3009 is a Draft, and its token is outside the hook.** The executor was written against Circle's FiatToken v2.2,
  which has the `bytes` signature overload of `receiveWithAuthorization`; that overload has to be present on any token
  and chain it is used with. A blocklisted executor, buyer or seller, or a paused cash token, fails the whole trade. A
  fee-on-transfer cash token fails the trade: usually in the payout, with the cash token's own `ERC20InsufficientBalance`
  because the executor received less than it must pay, and with `DvPExecutor_CashNotConserved` when a stray balance
  in the executor covers the shortfall or the fee falls on the payout alone. Anything sent to the executor by mistake
  stays there: it has no sweep.
- **Pre-flight answers for the latest block; a write lands in the next one.** At a time boundary (lockup end, window
  close, intent deadline, intent `validAfter`) they can differ by one second (`time.test.ts`).
- **7540 operators are full delegates** (review L-5). Per ERC-7540, an approved operator can create requests that pull
  the owner's assets or shares under any controller, not only claim. Owners should approve only custodians they would
  trust with the assets. Pinned by `test_WhenAnOperatorRequestsUnderItsOwnController_ItIsAFullDelegatePerErc7540`.
- **Dust and the investor cap** (review L-1). A payer the policy accepts can deposit 1 wei into the 4626 vault for a credentialed, empty receiver
  and take a fund investor slot, and 1 wei sent to an exiting holder breaks an exact-balance exit.
  `MinPositionRule` closes the slot grab where it is listed with a non-zero minimum: a transfer or mint that would leave an account between 0
  and the minimum is refused (`BELOW_MIN_POSITION`), as is an exit that would leave such a remainder. It does not stop 1
  wei being sent to an existing holder at or above the minimum, and an exit of the old exact balance then reverts with
  `BELOW_MIN_POSITION`; the holder exits the current balance (`maxRedeem`). It is off by default (a
  minimum of 0), and a product sets none unless `Product` is given one. Where none is set, the mitigation is
  operational: the agent cleans up dust (forced transfer or burn) and monitoring watches slot usage. FORCED and an enforcement
  burn are exempt, so an agent can still leave a remainder.
- **The fund's investor cap is a ratchet** (review L-4). A new investor passes when `count < cap`, or when
  `count == cap` and the move empties the sender's only class (net zero). So above a lowered cap no new investor is
  admitted, net-zero moves included, until the count comes back down. Existing investors can still move among
  themselves and exit. Pinned by
  `FundHoldersRule.t.sol::test_WhenTheCountIsAboveALoweredCap_ANetZeroMoveIsStillRejected`.
- **The investor cap does not hold a place for an open 7540 request** (outside review, 3.2 and 3.3; accepted by the owner
  for the first version, decision P27). A full `requestRedeem` takes the investor out of the count while the shares wait
  unburned in the escrow, and `requestDeposit` reserves no place. So when the fund fills up meanwhile, a reject that returns
  the shares, or a deposit claim, is refused with `MAX_HOLDERS`. The agent's recovery always works, and delivering to an
  account that holds nothing puts the count above the cap, where it stays until investors leave. The mitigation is
  operational: the agent rejects deposit requests near the cap, and a monitor alerts when `Fund.holderCount()` is
  above `Fund.holderCap()`. Whether a redeeming investor still counts as a holder is for counsel. Pinned by
  `FundIntegration.t.sol::test_WhenARejectedRedemptionReturnsSharesToAnInvestorWhoWasReplaced_TheFundCapAppliesAndRecoveryIsCounted`
  and `Gated7540Vault.t.sol::test_WhenACapFilledAfterSettlement_TheAgentDeliversTheStrandedShares`.
- **Dropping the fund rule from a class's list un-caps it silently.** The hook accepts any attested list, and nothing in it
  knows about the fund, so a list without `FundHoldersRule` stops the class from counting investors and from enforcing
  the cap (a fourth investor gets in at a full cap, and the fund's count does not know). Replacing the rule in the fund
  without updating the lists has the opposite effect: every class fails closed (`NOT_FUND_CLASS`) until its list names the
  new rule. `Fund.isClassIntact(token)` and `Fund.firstBrokenClass()` report both; the post-deploy check asserts none is
  broken, and monitoring should poll `firstBrokenClass()`. They detect, they do not prevent. A test drops the rule through
  the timelock and shows the cost (`fund.test.ts`, `FundIntegration_Integrity`).
- **Account-level answers are not movement answers.** `canSend` and `canReceive` take no amount and no kind. `canSend` is
  false for an address-frozen (`HolderRestrictionRule`) or a locked holder, although `forcedTransfer` still passes the rules for both and an enforcement burn
  passes for a locked one. `canReceive` is false for an account without an active credential that the token's policy accepts (a lapsed one included), an address-frozen account and a token that is not a fund class; the holder
  caps are not in it (ERC-7943 keeps quantitative rules out), so a new holder at a full cap reads true and the cap refuses
  the movement. The vaults' `maxDeposit` and `maxMint` and the 7540 request and deposit-claim checks probe a mint of a very large
  amount (`type(uint128).max`), and `maxRedeem` and the 7540 redemption claims a burn of nothing, so none of them reads a
  minimum position up to `type(uint128).max` as a block.
  A rule that bounded the size of a position (a supply cap, a maximum balance) would refuse the mint probe and zero
  `maxDeposit` and `maxMint`; none of the shipped rules does.
- **Money does not reach or leave a vault through someone the policy refuses** (`GatedVaultBase`). A payer other than the
  receiver or controller, a receiver of redemption cash other than the owner or controller, and on the 7540 a controller
  other than the shares' owner must pass the zero-amount enforcement probe (`GatedVault_ThirdPartyNotEligible`). So a
  custodian depositing for clients needs a credential. A holder paying itself is not judged, so a lapsed holder can
  leave, and a holder cannot name a lapsed address as controller to get round that. The `max*` views name one account,
  so they do not say any of this. The probe is judged when the money moves: nothing checks a payer's source of funds
  beyond its credential.
- **A token's own address is not judged by `CredentialRule`,** on either side. A 7540's escrow is that address, and a
  credential there could lapse or be blocked and stop every redemption. Stopping a vault stays with `pause()` and
  `HolderRestrictionRule`, and a freeze on the vault's own address stops its escrow. A vault whose asset is gated is an
  ordinary holder of that asset and needs a credential there. The cost: a holder can send a token to the token's own
  address by mistake, and the agent recovers it with `forcedTransfer`.
- **Credentials: the attester decides who may hold, and a lapse stops only receiving.** `CredentialRegistry` records what an
  attester says and verifies no KYC. A compromised attester key can credential any address for every token whose policy
  trusts that attester, with any bit the attester may assert. The limits are the attester's allowed bits, the token's
  attester bitmap and required bits (`setPolicy`), `validUntil`, and the guardian's `killAttester` (its holders become
  exit-only at once) and `blockSubject`. A holder whose credential lapsed, or whose attester was killed, can still send,
  burn and redeem and cannot receive; only a blocked or unknown holder cannot send. That is deliberate (a holder must be
  able to leave), so a lapse does not stop funds already held: the address freeze, the lockup and `forcedTransfer` do.
  An enforcement burn (operator holds `BURNER_ROLE`) passes the sender check, so the issuer can burn from a blocked
  holder. The council attests `CredentialRule`, whose codehash covers the registry's address and not its code, so it
  reads the registry (code, admin, attester list) first. Entities are not modelled: one wallet is one holder. Pinned by
  `CredentialRegistry.t.sol`, `CredentialRule.t.sol` and `test/nodejs/credentials.test.ts`.
- **A pause blocks mint and burn as well.** Only FORCED movements pass: `forcedTransfer`, and the 7540 vault's `recoverRedeemRequest` and `recoverClaimable`. Enforcement during a pause is `forcedTransfer`
  to a quarantine account (holding an active credential the token's policy accepts, never address-frozen: the freeze on a receiver applies to FORCED), and the
  burn waits for the unpause. The ERC-3643 reference token differs: its agents can mint, burn and force while paused
  (checked 2026-10-23; the ERC-3643 text itself was not checked).
- **`canTransfer` can say yes where the write reverts.** ERC-7943 forbids `canTransfer` to fail on a balance check, so an
  amount above the balance reads true when the hook accepts it and no frozen amount is in the way (nothing frozen, or a
  burn by a sender that holds `BURNER_ROLE`), and the write reverts with the base's `ERC20InsufficientBalance`. While
  part of the balance is frozen, an amount above the unfrozen balance reads false: the standard asks `canTransfer` to
  validate the unfrozen amount, but does not say which rule wins above the balance, and this follows the draft ERC's
  reference, so a one-unit freeze flips the answer. `canTransferWithReason` and `canExecute` make no exception and say
  no with `INSUFFICIENT_UNFROZEN`. An integrator that wants to know whether a movement will succeed should call those.
- **A `BURNER_ROLE` holder's own burns are enforcement burns.** The rules ask the operator, not the intent: a burner who
  redeems its own shares through a vault passes its own lockup and minimum (a probe showed a locked holder redeeming in
  full). It does not pass its own frozen tokens (the vault's `maxRedeem` stops at the unfrozen balance) or its own address
  freeze. Burner accounts are issuer service accounts; do not also use one as an investor.
- **A frozen remainder below the minimum makes `maxRedeem` overstate.** `maxRedeem` is the unfrozen balance, and the minimum
  judges the whole balance. A holder whose frozen amount is above zero and below the minimum cannot redeem all of
  `maxRedeem`: the frozen remainder would be left behind and the redemption reverts with `BELOW_MIN_POSITION`. The holder
  redeems less, or the agent lowers the frozen amount first. Pinned by `test_WhenAFrozenRemainderBelowTheMinimumWouldStay_RedeemingAllOfMaxRedeemReverts`.
- **A below-minimum 7540 claim reverts.** A request cannot know how many shares it will buy, so a fresh controller is not
  refused for size. If the shares claimed, added to what the receiver already holds, come to less than the minimum, the claim reverts with `BELOW_MIN_POSITION` and
  the claimable stays until the agent's `recoverClaimable` (an enforcement mint, exempt) delivers it, or the agent
  rejects the request while its period is open.
- **The 7540 escrow is pooled, and enforcement on it is per controller.** Pending redemptions are booked per
  controller, but their shares sit in one balance at the vault's own address. `forcedTransfer` out of that address may
  take only the shares above the booked total (`Gated7540Vault_ExceedsSurplus`): shares that reached the vault outside
  a request. `setFrozenTokens` on it reverts (`GatedVault_Unsupported`), since a frozen amount there could not name
  a controller. One controller's redemption is rejected, or moved with `recoverRedeemRequest`. Tooling
  that calls `setFrozenTokens` on the vault's address, or forces booked shares out of it, sees a revert. Pinned by
  `Gated7540VaultUnit_Escrow`.
- **The timelocks wait 24 hours by default, and each has a floor of 1 hour.** `GovernanceTimelock` refuses less
  than the floor at deployment and in `updateDelay` (`GovernanceTimelock_DelayBelowFloor`). The post-deploy check asserts
  at least 24 hours on both timelocks at hand-over. So the guardian has a day to cancel a bad change, and governance can
  later lower the main delay to 1 hour through a delayed operation. The recovery timelock is the same contract, and its
  powers only undo the guardian's. Pinned by `GovernanceTimelockUnitTest`.
- **The operations account places products without a delay.** It owns `ProxyDeployer`, because a launch only adds a proxy
  over attested code and touches nothing that exists. A stolen operations key can still place a token over an attested
  implementation with its own admin, and can use up a symbol. It cannot change an existing product, and such a token is
  not one the issuer published: holders and integrators should take addresses from the issuer's list. The post-deploy
  check is the fixture `assertHandedOver`, which every test deployment runs; nothing yet points it at a live network, so
  running it on each real product needs its own tooling. Recovery from a stolen key is a new `ProxyDeployer`, which changes where later tokens land.
- **Revoking an attestation does not affect live tokens.** Attestation is checked at install and upgrade time only.
  The guardian pauses while the timelock removes the component.
- **`totalAssets` of the 7540 vault is indicative** (all shares at the last settlement's value); `preview*` revert, as
  ERC-7540 requires.
- **A `GuardedAccount` is the most dangerous lego in the stack.** It makes whatever calls its permissions allow. Default deny, one narrow validator per call and a timelock on every grant reduce that, and only a review of each permission set closes it. An `approve` gives the spender up to what it allows, and a validator's codehash covers its settings, not the target's behaviour. A custodian that does not return money is an off-chain risk no contract covers.
- **Fees on a 4626 are charged on the counted value,** so a gain pays only once it has passed the rate limit, and a holder can drain idle money ahead of fees owed: `collectFees` pays what idle money allows, not while paused, and holders come first. A loss below the fees owed reads as zero. A fee model replaced with fees still owed pays them to the new model's recipient, so a timelock batch collects first.
- **A signed entry's minimum protects only on a 4626.** A 7540 request has no price yet, so `SignedEntry` refuses a request that names one, and the investor's protection is the period's approved price. A permit is not bound to one entry the way an ERC-3009 authorization is: a permit left unspent can pay for another entry of the same investor, which that investor also signed. A relayer can hold a signed entry back until its deadline, so a short deadline is the investor's control; `cancelEntry` needs a transaction.
- **Who holds `SETTLER_ROLE` sets the price.** The vault takes whatever `settlePeriod` is given, and the holder can name any
  cash account that approved the vault. So the role belongs to a `NavDesk`, where two people approve every price and a
  cooldown gives the guardian time to cancel. The timelock can grant it to anyone: that is delayed and visible, not
  prevented. The vault does not check the holder: a desk is not attested, so the vault could not tell one from any other
  account. `NavDesk.isWired()` shows it to monitors and the hand-over check pins it. The holder also names how many shares
  a settlement takes from the redemptions, which through a desk is worked out from the level the timelock set.
- **A redemption gate slows every exit.** The timelock sets the level on the desk, delayed and visible, and a low one keeps
  holders queued. The level is a share of what remains, so a fund winding down must set it to zero or the queue only
  shrinks by the same fraction each period. A holder cannot withdraw a carried part: the agent can hand it back. A holder
  who expects a gate can ask for more than they want, to get a bigger slice. That is the deterrent's limit, not a fault in
  the arithmetic.
- **A queued investor is out of a fund's count (P27).** Under a gate this lasts until the queue reaches them.
- **A price is a claim.** `reportHash` proves which report was used, not that the money exists. A maker and a checker who
  collude can approve a wrong price, and whoever dealt in between keeps the difference when it is corrected. The cooldown,
  the guardian's cancel and the published hash make that harder and traceable.
- **A stuck period is a dealing suspension.** A loss, an outage, a pause or short cash can all stop settlement, and then new
  requests wait in the next period. After `maxReportAge` with nothing on the table, the agent can send requests in the
  closed period back through `NavDesk.refundRequest` and `recoverRequest`, one controller at a time. Beyond that a total
  loss is a wind-down, which the contracts do not recover from.
- **Rounding each claim leaves dust.** Each claim on a period's shares rounds down, so at most one share unit per investor per
  period stays in `unclaimedShares`, for good: 3.65m units for 1,000 investors dealing daily for 10 years, under a billionth
  of a basis point of 100m shares at 12 decimals. A controller whose whole request rounds to nothing keeps a claimable
  amount that buys nothing; `recoverClaimable` clears it.

- **A credential holds no country.** A record has qualification bits, a validity and a standing. A jurisdiction group is a
  bit (`Quals.US_PERSON`, `Quals.EEA`), which a token's `requireAny` and `forbidAny` already read, so an offering restriction
  needs no rule, and the attester publishes only what a policy needs. Whether an address with a credential is still personal
  data is for counsel.
- **A supply cap limits a stolen minter key, and only that.** `SupplyCapRule` judges `MINT`, so the agent's enforcement mint
  (`FORCED`) is exempt, and the timelock can raise the cap. On a token with no cap set it admits no mint. It is on tokens only,
  because it would refuse the mint a vault's `maxDeposit` probes with. Pinned by `SupplyCapRule.t.sol`.
- **What the hand-over check asks of a Safe.** It reads `getThreshold()` and wants at least 2. It does not read who the
  signers are, and a demo profile names every sensitive role as an exception, so a real deployment must state its own.
  A desk-less fund's settler sets any price alone: that is the `full` profile, for tests, and the check refuses it elsewhere
  unless the profile names it. Pinned by `test/nodejs/legos.test.ts`.
- **A distribution's root is a claim.** The contract proves a holder is in a tree two people approved, not that the tree is
  right: a wrong record date or a wrong amount is paid as approved, up to the funded total, and a claim above what is left
  is refused (`Distributor_OverFunding`). A holder who may not receive cannot claim, so the money waits for them until the
  expiry and then returns to the funder. Nothing pays a holder automatically, so a holder who never claims gets nothing.
  `Distributor.t.sol` pins each.
- **What a `Portfolio` trusts.** It sends money only to adapters attested as `ADAPTER` for this portfolio and this asset,
  and each risk's caps bound how much. An adapter's codehash covers its target's address and not the target's behaviour,
  so a bad target can lose what was allocated to it. The council reads the target before attesting, and that review is the
  only control on the target itself. The portfolio gives its vault an unlimited allowance at construction, so whoever can
  upgrade the vault (the timelock) could take the idle money; the delay makes that public. Pinned by
  `Portfolio.t.sol::test_ItStoresItsSettingsAndLetsTheVaultPullTheIdleMoney`.
- **A 4626's portfolio is replaced in one batch: `migrateTo`, then `setPortfolio`.** Nothing forces the batch, so a portfolio
  that has sent its money on gives no price from then on, and the vault holds its price and stops dealing until the plug.
  `setPortfolio` refuses while the old portfolio has an adapter on its list or holds anything, so a position that cannot be
  read must be written off first, which leaves the vault exit-only. A replacement keeps the limit's clock, so the next count
  allows what it would have allowed anyway, at the rate the call names. Pinned by
  `Gated4626VaultPortfolio.t.sol::Gated4626VaultPortfolio_Replacement`.
- **A read of nothing stops a 4626, and a fall of more than half closes its deposits.** While the value net of fees reads nothing although holders
  have a value counted, `totalAssets()` reads zero, nothing is written down and deposits and withdrawals stop, so a holder
  cannot sell for nothing, nobody buys for nothing, and the value can come back under the limit. A write-off that leaves
  nothing is one too: there is nothing to redeem until money comes back. A low read that is not
  nothing counts at once, and recovers at `maxRate`. A count that finds the value fallen by more than half closes deposits
  for good, as a write-off does, and the views say so before that count, so a glitch nobody counts closes nothing. A read of
  nothing is not counted, so it closes nothing and `exitOnly()` reads false through it. A fall of half or less leaves
  deposits open at that price, and falls with a count between them do not add up: the council reads each target before it
  attests. During a read of nothing a donor can make it a low read, with one unit more than the fees
  owed, which writes the price down: a holder's 1,000 reads as 1, and stays there a year after the target gets its money back
  unless the timelock raises `maxRate`. It needs a target that reads nothing or very little while it is still fresh. The vault
  takes no deposit at that price, because deposits close at that count. A donation of half the counted value or more does
  not close them: in a run, 500 donated and 100,000 deposited took the holder's 1,000 to about 505 once the target had
  recovered, and left the depositor about 495 ahead. New money after a close needs a new vault. Pinned by
  `test_AReadOfNothingIsNotWrittenDownAndDealingStops`, `test_AValueBelowTheFeesOwedIsAlsoAReadOfNothing` and
  `Gated4626VaultPortfolio_LargeFall`.
- **With no shares nothing is anyone's.** A price struck on what is left would sit far above a mark at par, and the next count or period would charge a performance fee on the next investor's principal. So a 4626 counts zero and a desk proposes a value of zero, whatever is reported or sits in the portfolio, the next investor buys at par, and the mark restarts at par. What is left goes to them: on a 4626 under the limit, on a desk in the next price. A desk does not refuse to propose, because a stranger's donation could then stop the period. Shares left behind are not this case. A count before the entry moves the mark to the price after what it actually charged, so a charge that rounds to nothing moves it to the whole price, and the next investor is not charged a performance fee on what they pay in, to within a few raw units: that costs the fee recipient, and not the investor. A mark never starts below par, because below par a dust share would have the next investor buy above the mark, so a fund plugging a model after a loss pays no performance fee on the way back to par. Pinned by `NavDesk.t.sol::NavDesk_NoShares`, `test_WhenTheLastHolderLeavesDustTheNextInvestorPaysNoFeeOnPrincipal`, `testFuzz_WithNoSharesAnythingLeftStillStrikesAtPar`, `testFuzz_DustSharesDoNotChargeTheNextInvestorOnPrincipal`, `testFuzz_DustSharesAfterALossDoNotChargeTheNextInvestorOnPrincipal` and `test_AFirstPlugBelowParStartsTheMarkAtPar`.
- **A portfolio's caps are checked on allocate and on install.** An exit can leave a risk above its relative cap, a gain
  in a target can take the real position above a cap while its allocation stays put, and lowering a cap leaves what is
  already allocated where it is. Pinned by
  `Portfolio.t.sol::test_ItWorksAboveALoweredCap`. A priced adapter's value counts at install, so a position cannot come
  back from a write-off outside its caps (`test_AddingAPositionBackCannotTakeExposurePastTheCap`). A reported adapter's money
  can be off-chain, so it comes back at zero, and caps cannot see what a custodian still holds: the timelock must set them
  knowing that when it adds one back (`test_AReportedAdapterStartsAtZeroWhateverItHolds`).
- **A pause stops money going out of a portfolio, not coming back.** While the vault is paused `Portfolio.allocate` and
  `GuardedAccount.execute` revert, and `deallocate` still works, for the guardian too. So a permission that pulls money back
  through `execute`, such as a target's `redeem`, waits for the unpause; no deployment profile grants one. Money a custodian
  holds comes back off-chain. Pinned by `Portfolio.t.sol::PortfolioUnit_WhileThePauseHolds` and
  `GuardedAccount.t.sol::test_WhileTheVaultIsPaused_ItRefusesAndNothingMoves`.
- **`ProxyDeployer` and `Fund` transfer ownership in one step.** A two-step transfer would make the timelock schedule an
  accept for every fund, which puts its delay into a launch. The post-deploy check pins each owner, and a mistaken
  `ProxyDeployer` transfer costs a new deployer, not money.
- **`IntentExecutor.executeBatch` names the failing index only for a failure it can catch.** A token that returns malformed
  data reverts the whole batch with no index. Batches are atomic, so nothing moves.
- **`pricedValue()` can read low and can revert.** An adapter that cannot be read counts as zero, so a reader must check
  `priceFresh()` as well. In the middle of a move the money is in neither place or in both, so `pricedValue()` reverts
  then, which stops anything pricing against a half-finished transfer. Pinned by
  `Portfolio.t.sol::test_NothingCanReadThePriceDuringAnAllocation` and `test_NothingCanReadThePriceDuringADeallocation`.

## 4. Static-analysis suppressions

Slither 0.11.5 runs as a CI gate with 0 findings, on the contracts that ship: `npm run slither` leaves tests and mocks out of the build. Project-wide exclusions (`slither.config.json`):

| Detector | Reason |
|---|---|
| `naming-convention` | Wonderland style uses `_camelCase` for parameters and internals |
| `assembly` | ERC-7201 storage accessors only |
| `timestamp` | Intent deadlines and `validAfter`, lockups and settlement windows are time-based by specification |
| `calls-loop` | The hook calls at most 16 attested rules |

Inline suppressions (each carries its reason on the line above, in the source):

| Location | Detector | Reason |
|---|---|---|
| `PolicyGatedERC20Upgradeable` `forcedTransfer` | `reentrancy-events` | Event after `afterTransfer`; re-entry is blocked by `_move`'s guard and the hook is attested |
| `IntentSettledUpgradeable` `executeTransfer` | `reentrancy-events` | Same as above |
| `PolicyGatedERC20Upgradeable` `canTransferWithReason`, `canTransfer`, `_update`, `_accountAllowed`, `_takesFrozenTokens` | `incorrect-equality` | Compares a reason code, or a movement kind, with a constant, not a balance |
| `FundHoldersRule` `after_`, `_senderLeavesFund` | `incorrect-equality` | Same definition of a holder, for a class balance |
| `FundHoldersRule` `_senderLeavesFund`, `_classReason` | `unused-return` | Only the fields the call needs are read from `admission`; `_senderLeavesFund` needs the sender's classes and exemption, since the rest was read for the receiver, and `_classReason` needs the class number and the installed rule |
| `CredentialRegistry` `profileOf`, `isVerified` | `incorrect-equality` | Compares an enum standing with a constant, not a balance. The lapse itself is a strict `>` on the time, so a record reads `ACTIVE` through its last second |
| `CredentialRule` `_sendReason`, `_receiveReason` | `unused-return` | Only the standing decides for a sender; the bits and the attester matter for a receiver |
| `Fund` `positionsOf` | `uninitialized-local` | The class count and the entries written start at zero by design |
| `HolderRestrictionRule` `setLockup` | `uninitialized-local` | The stored unlock time starts at zero, the value of a cleared lockup |
| `Gated7540Settlement` `settlePeriod` | `reentrancy-no-eth`, `boolean-cst`, `arbitrary-send-erc20` | The book is written before the burn and `_net` writes no state: what Slither reads as a write is the storage pointer. A boolean mapping key is not a misused constant. The settler names the cash account, and only one that approved the vault can be pulled from; the role belongs to a `NavDesk`, and `SETTLER_ROLE` is timelock-granted |
| `Distributor.approve` | `arbitrary-send-erc20` | It pulls from the funder a maker named and a different checker approved, and only an account that approved this contract can be pulled from |
| `NavDesk` | `incorrect-equality`, `unused-return`, `uninitialized-local` | Zero means nothing on the table, nothing accepted or no mark yet, not a balance. The unclaimed shares say nothing about whether a period is stuck, and the supply nothing about which period is closed. Of a period's book, the limit wants only what its deposits paid. A proposal is filled in a field at a time |
| `ERC4626CallValidator` | `unused-state` | Slither does not see a constant used as a slice's bound |
| `SignedEntry` | `arbitrary-send-erc20`, `arbitrary-send-erc20-permit`, `reentrancy-events`, `unused-return` | The investor signed the entry naming these assets, checked first. What it bought is known only after the vault's call, and the nonce was spent before it. A 7540 request returns the aggregated id, 0, which says nothing |
| `GuardedAccount` `execute` | `unused-return` | A permission is a timelock decision and the validator has judged the parameters, so what the call returns is not needed |
| `Gated4626Vault` `collectFees`, `_withdraw` | `arbitrary-send-erc20` | The portfolio gave this vault an allowance at construction, for this; the recipient is the one the attested model names |
| `Gated7540Vault` `initialize` | `reentrancy-benign`, `reentrancy-events` | The initialiser installs the token's rules on the shared hook, after writing the vault's own state (the asset, the decimals, the first period). The hook is attested, cannot re-enter `initialize`, and never reads that state; only the admin and the guardian hold a role yet |
| `SettlementWindowRule` | `weak-prng` | Calendar arithmetic on the timestamp, not randomness |
| `ComplianceHook` `_setRules` | `uninitialized-local` | The after-mask starts at zero by design |
| `Portfolio` `_allocate`, `_deallocate` | `reentrancy-benign`, `reentrancy-events`, `reentrancy-balance` | The guard is held, the adapter is attested, and what the move changed can only be measured after the call: the balance read before it is the point of the comparison. A reentrant target is refused (`test_AReentrantTargetCannotAllocateAgainMidCall`) |
| `Portfolio` `allocate`, `_deallocate`, `removeAdapter` | `incorrect-equality` | A zero test on a caller's argument, and the definition of an empty adapter. A donation only delays a removal until the allocator brings it back |
| `Portfolio` `_takeOff`, `ERC4626Adapter` `allocate`, `deallocate`, `_ask` | `unused-return` | The list removal is false only if the adapter was not there, which the caller has checked; the portfolio measures what a target move changed; a read needs only the first word of the answer |
| `Gated7540Vault` | `missing-inheritance` | `IERC7575` re-declares inherited ERC-4626 functions; conformance pinned by ERC-165 id `0x2f0a18c5` |
| `Gated7540Vault` `requestDeposit` | `arbitrary-send-erc20` | `owner` is the caller or an approved operator. Fuzzed: a non-operator with a victim owner reverts and moves nothing. Removing the guard fails 2 tests |
| `ProxyDeployer` `deploy` | `unused-return` | `initialize` returns nothing; success is checked by the post-init assertions |
| `DvPExecutor` `canExecuteDvPGated`, `canExecuteDvP3009` | `unused-return` | The token's `ok` is `reason == TRANSFER_OK`, so the reason carries it |
| `TokenProxy` `_unsafeAllowUninitialized` | `dead-code` | Called from `ERC1967Proxy`'s constructor; Slither does not trace it through the override |

Aderyn 0.6.8 (Cyfrin) runs as a second CI gate (`npm run aderyn`, 0 findings), from the sha256-pinned release binary
(§6). First run: 5 high and 13 low
detector types. One real fix: `ProxyDeployer`'s constructor parameter shadowed `Ownable._owner` and was renamed. Every
other finding is acknowledged below. Where a finding is a real property rather than a false positive, a test pins it.

Project-wide exclusions (`aderyn.toml`):

| Detector | Reason |
|---|---|
| `centralization-risk` | Privileged roles are the product; each is held by the timelock, guardian, council or issuer |
| `push-zero-opcode` | `evmVersion` is pinned to cancun; the target chain must support it (PUSH0, TSTORE, MCOPY) |
| `unspecific-solidity-pragma` | Brief rule 9 mandates `^0.8.28`; the exact compiler is pinned in config |
| `uninitialized-local-variable` | `for (uint256 _i; ...)` loop counters and zero-start bitmasks |
| `unused-import` | solhint already flags unused imports; Aderyn misses imports used only by `@inheritdoc` |

Inline acknowledgements (reason on the line above each `aderyn-ignore`):

| Detector | Where | Verdict | Evidence |
|---|---|---|---|
| `contract-locks-ether` (high) | `GatedToken`, `IntentToken`, `Gated4626Vault`, `Gated7540Vault`, `TokenProxy` | False positive: no path accepts ETH. There is no `receive` or payable function, `upgradeToAndCall` with empty data rejects value (`ERC1967NonPayable`), and with data the value is delegated into a non-payable function | `GatedTokenIntegrationTest::test_WhenEtherIsSent_ItReverts`, `IntentTokenIntegration_Ether`, `Gated4626VaultUnit_Ether`, `Gated7540VaultUnit_Ether` |
| `reentrancy-state-change` (high) | `HolderRestrictionRule`, `MinPositionRule`, `SettlementWindowRule`, `CredentialRule.setPolicy` and `_checkSender`, `Fund.registerClass`, `Fund.setRule`, `Portfolio.writeOffAdapter` | False positive: the token, the hook, the fund or the registry is called through view interfaces, which compile to STATICCALL, so nothing it does can change any state | `*Unit_TokenCallsAreStatic` for the rules, `FundHoldersRuleUnit_TokenAndFundCallsAreStatic` and `FundUnit_CallsAreStatic` for the fund layer, `test_AnAdapterThatWritesDuringARead_MakesTheCallRevert` for the portfolio: a callee whose reads write makes the entry point revert, while a quiet callee succeeds (control) |
| `arbitrary-transfer-from` (high) | `Gated7540Vault.requestDeposit` | Same as Slither's `arbitrary-send-erc20` (§4 above) | Fuzzed victim-owner test; removing the guard fails 2 tests |
| `arbitrary-transfer-from` (high) | `Distributor.approve` | Same as Slither's `arbitrary-send-erc20` (§4 above) | `Distributor.t.sol::test_ItPullsTheFundingAndEmits`, `test_TheMakerCannotApproveItsOwn` |
| `abi-encode-packed-hash-collision` (high) | `ProxyDeployer._initCodeHash` | False positive: only the second operand varies; the first is fixed creation code | Fuzzed `predict` formula test; off-chain CREATE2 test |
| `storage-array-memory-edit` (high) | `SettlementWindowRule.check`, `isOpen` | False positive: a read-only copy of a storage struct into memory | Window tests |
| `reentrancy-state-change` | `Gated7540Vault.initialize` (the asset's `decimals()`), `NavDesk.adopt` (the old desk's views), `NavDesk.setFeeModel`, `Distributor.claim`, `SupplyCapRule.setSupplyCap` | View interfaces, compiled to STATICCALL | |
| `reentrancy-state-change` | `Gated4626Vault` `setPortfolio`, `setFeeModel`, `collectFees` | View interfaces on attested components, compiled to STATICCALL | |
| `require-revert-in-loop` | `Gated7540Common._request` | The walk is one controller's own request, so a revert in it could only fail that controller's own call | `testFuzz_TheVaultCanPayEveryClaimAfterAGate` |
| `require-revert-in-loop` | `GuardedAccount.execute` | All or nothing, by design: a batch that moves money must not half-run | `test_AllOrNothing` |
| `unsafe-erc20-operation` | `ERC20CallValidator.validate` | It only reads the selectors and moves no tokens | |
| `unsafe-casting` | `Gated7540Vault._claim` | Neither part exceeds what the request holds, each being a share of it at most | `testFuzz_TheSumOfClaimsNeverExceedsTheBookAndFallsShortByAtMostOneUnitEach` |
| `state-no-address-check` | `NavDesk._setSettings` | Zero is a choice for both: no portfolio, or a portfolio to be plugged | `test_WithNoCashAccount_ItReverts` |
| `unused-state-variable` | `GatedToken` and `Gated7540Vault` ERC-7201 locations | False positive: read in assembly | `GatedTokenIntegrationTest::test_TheErc7201LocationHoldsTheDecimals` and `Gated7540VaultUnit_Storage`: the formula equals the constant and the slot holds the decimals, or the asset |
| `unchecked-return` | `EnumerableSet.remove` in `Portfolio`; `deposit` and `withdraw` in `ERC4626Adapter`; `_grantRole` in constructors and initialisers (`CredentialRegistry` included), and `_revokeRole` in the `revokeRole` overrides of the base, `GovernanceTimelock`, both executors and `CredentialRegistry` (it returns false only if the role was not held, and either way the account ends up without it); `Address.functionCall` in `ProxyDeployer`; `_executeLeg` in `DvPExecutor` | `_grantRole` returns false only if the role is already held; `initialize` returns nothing; the cash leg's digest is not needed and the securities leg's digest was read before the call | Role, deploy and DvP tests |
| `costly-loop`, `require-revert-in-loop` | `ComplianceHook._setRules`, `IntentExecutor.executeBatch`, `Portfolio._addAllocation`, `_subtractAllocation` | By design: at most 16 rules, and invalid rules must fail closed; batches are atomic; an adapter names only a few risks, and a move past any cap fails whole | Hook, batch and portfolio tests |
| `literal-instead-of-constant` | calendar arithmetic; `10 ** decimals()` | Calendar constants; `decimals()` is read at runtime | Window and vault tests |
| `empty-block`, `modifier-used-only-once` | `BaseRule.after_`, `__IntentSettled_init`, `Fund.onlyRule`, the two empty `catch` blocks of `Fund._listsInstalledRule` | By design; in the fund views a token or a hook that fails is a broken class, and the answer is `false` | `FundUnit_ClassIntegrity` |
| `unsafe-casting` | `ComplianceHook._setRules`, `HolderRestrictionRule.setLockup`, `Portfolio._addAllocation`, `_subtractAllocation` | Each narrowing follows an explicit bound: at most 16 rules and a 16-bit mask; a range check against 64 bits; an allocation at most the 120-bit cap | Hook tests; `HolderRestrictionRuleUnit_SetLockup`; `testFuzz_ARiskAlwaysEqualsTheSumOfItsAdapters` |
| `unused-error` | `IERC7943Fungible` | The standard's `ERC7943CannotSend`, `ERC7943CannotReceive` and `ERC7943CannotTransfer` are part of the interface the token inherits; the token reverts with `PolicyGated_TransferRejected` and `ERC7943InsufficientUnfrozenBalance` instead | n/a |

solhint (Wonderland config, `--max-warnings 0`):
- `style-guide-casing` is disabled on getters of `UPPER_SNAKE` constants and immutables and on OZ-style `__X_init`
  functions;
- `no-unused-vars` is disabled on imports used only by `@inheritdoc`;
- `private-vars-leading-underscore` is disabled in `Errors.sol`, where reason codes are public constants read as
  `Reasons.X`.

## 5. Mutation-testing results

Each row is a bug deliberately planted, the tests that caught it, then the file restored from git. Rows before 2026-10-30 name `Components` and `Activate`, now `Core`, `CoreHandover` and `Product`. Counts are the failing tests in the run that recorded the row. The shared hook's own authority (who may call `setRules`, the per-token keying, `afterTransfer` from the token only) is pinned by unit and integration tests, not by a planted-bug row.

| Area | Planted bug | Caught by |
|---|---|---|
| Halmos (proxied `IntentToken`) | nonce not consumed; cancel not recorded; frozen check skipped; burn not releasing frozen | the matching symbolic property, each |
| Executor | batch made best-effort | 3 tests |
| `IntentExecutor` refusal of a stated consideration (2026-10-23) | `execute` never refuses; the check ignores the amount, or the token, or needs both; `executeBatch` never refuses, or names the wrong position; `execute` refuses only after calling the token | 2 to 7 tests each |
| `DvPExecutor` (2026-10-23) | pause, role or reentrancy guard dropped on either entry point; each of the seven mirror conditions dropped; the two legs swapped; each of the five authorization conditions dropped, and the bare-hash nonce; the executor's or the seller's cash check dropped, and the seller's balance read before the pull; the securities leg never run; the seller never paid; the pre-flight legs swapped, either window edge moved, the pause ignored | 1 to 18 tests each. Halmos catches the dropped mirror conditions, the dropped securities leg, the dropped nonce, payer, value and token conditions, and the dropped executor cash check. Two weaknesses in the first tests showed up and were fixed: a reentrancy test that passed with the guard removed (`vm.expectRevert` does not compare the data of a low-level call), and a gated-path guard with no test |
| DvP deployment (2026-10-23) | `Activate` skips the DvP executor's EXECUTOR_ROLE on the intent token, its OPERATOR_ROLE or its RECOVERY_ROLE, or its hand-over; grants the operator key EXECUTOR_ROLE on the intent token; gives the DvP operator role to the minter | the post-deploy check, which pins the DvP executor's roles and the set of EXECUTOR_ROLE holders (the deployment tests fail). Dropping the check of stray EXECUTOR_ROLE holders is caught by the governance test that grants one |
| Intent revision (2026-10-23) | consideration check dropped, or applied to the amount only, or to the token only; executor comparison dropped; `validAfter` check dropped, or made exclusive; signature dropped from `canExecute`; executor check moved before the nonce check; a field left out of the hash | 2 to 7 tests each. Dropping the consideration check or the executor comparison is also caught by the matching Halmos property (`check_considerationWithoutExecutorNeverExecutes`, `check_intentNamingAnotherExecutorNeverExecutes`). The order mutant first survived and `test_WhenTheNonceIsUsedAndTheExecutorIsWrong_NonceUsedWins` was added |
| `PolicyGatedERC20Upgradeable._releaseFrozen` | `>` weakened to `>=`, so a frozen amount that already fits is rewritten and `Frozen` emitted | survived the whole suite; `test_WhenTheFrozenAmountStillFits_ItIsLeftAlone` was added and now catches it |
| `Gated4626Vault` | `maxRedeem` ignores frozen; `maxWithdraw` rounds up; `decimalsOffset` = 0 | 3 tests; rounding test; inflation test (victim-loss bound) |
| `Gated7540Vault` | withdraw shares rounded down; mint assets rounded down; reject keeps pending; recovery keeps pending; operator guard removed | 1+ tests each; invariant `escrow == Σ pending` |
| Phase 6 (TS) | executor hand-over skipped; `canExecute` skips the hook; NAV price rounds up; deadline exclusive | 46 / 8 / 1 / 1 failing |
| `ProxyDeployer` | no hook-binding check; no salt check | unit test + Ignition tamper test; unit test |
| `ProxyDeployer` implementation check (2026-10-27, finding 1 of the 2026-10-26 review) | the check removed; the check moved after CREATE2; the wrong kind asked (`HOOK`); the check moved before the salt check; the constructor not storing its registry; the zero-registry check removed; the token-registry check removed; `Components` passing the timelock as the registry | 8 of 8. The seven contract bugs fail 7, 1, 5, 1, 25, 1 and 1 of the 30 `ProxyDeployer.t.sol` tests. `deployment.test.ts` fails 1, 9, 10 and 10 of its 10 tests for the check removed, the wrong kind, the registry not stored and the timelock in `Components`. The check moved after CREATE2 is caught only by the implementation with no code: a revert undoes the proxy either way, so the order shows only in the error a bad implementation gets |
| Portfolio lego (2026-10-30) | Every role gate, on all nine entry points; each `addAdapter` refusal and the attested kind; a priced adapter installed unreadable, a reported one required to be readable, a held position left uncounted, a reported adapter counted at install, the install skipping the relative cap or its event hiding the allocation; a write-off not remembered, a removal counted as one, adding back clearing the flag; each `removeAdapter` and `writeOffAdapter` condition, and what taking an adapter off must clear; the guardian raising either cap; both caps removed or off by one; a stale price before and during a call; a priced move counting what was sent rather than the change in value; the floor at zero; the reentrancy guard and the mid-move price guard; each `raise` and `migrateTo` condition; what `pricedValue`, `priceFresh` and `liquidAssets` count; the adapter's gates, its receiver, its leftover allowance, its risk ids and a failed read counted as fresh | 87 of 87 caught, by `Portfolio.t.sol` and `ERC4626Adapter.t.sol` |
| One movement path (2026-10-31) | Each of the three zero-address checks removed; the guard removed from `_move`; the kind, the ref or the deadline dropped from `_moveAs`; the kind dropped from `_mintAs`; every plain movement read as a transfer | 9 of 9 caught, by `PolicyGatedERC20Upgradeable.t.sol`, `IntentToken.t.sol` and `IntentSettledUpgradeable.t.sol` |
| Core and products (2026-10-30) | The timelock floor at 7 days, 2 hours or zero; `GatedToken` reporting another template, its implementation left initialisable, ignoring the decimals it is given, reporting 18 whatever it was given, or keeping them at another location; the default delay at 7 days or 23 hours; `Core` always deploying the window rule; `ProxyDeployer` left with the deployer or moved to the timelock; the deployer keeping the timelock admin; the guardian not made a canceller; the operations account keeping a product's admin, or the admin going elsewhere; UPGRADER to the agent; RECOVERY skipped; a product's stated policy ignored, or its decimals ignored, or a plain token defaulting to 6; MINTER not granted on a plain token; the window rule allowed on any template; a fund rule without a fund accepted, or a fund without the fund rule; every fund opening with every class; a fund starting with the deployer; opening without installing the rule or setting the cap; a fund left with the operations account; classes opening in reverse order | 32 of 32 caught, by `GatedToken.t.sol`, `GovernanceTimelock.t.sol`, `products.test.ts` and `deployment.test.ts` |
| Ignition `Activate` | UPGRADER to an ops account; deployer keeps timelock admin; deployer keeps `ProxyDeployer` ownership | 54 / 54 / 55 failing |
| upgrades-core | upgrade-unsafe state initialiser | `validate` FAILED |
| Aderyn gate | one inline suppression removed | `npm run aderyn` fails (1 high) |
| 7540 invariant handler | every action of a family silently turned into a no-op | `afterInvariant` fails (each family must execute in every run) |
| `Gated7540Vault` access | controller/operator check removed from `redeem`, `withdraw`, `_claimMint`, `_claimDeposit`; the settler's and the agent's roles removed from settlement and rejects; `whenNotPaused` removed from `withdraw` | 1 to 2 tests each (`Gated7540VaultUnit_ClaimAccess` and others). Before the 2026-10-17 review, 6 of these 9 survived |
| `Gated7540Vault.requestDeposit` | eligibility checked on the owner instead of the controller | `test_WhenAVerifiedOwnerRequestsForAnUnverifiedController_ItIsRefused`, the only test where owner differs from controller |
| `Gated7540Vault` claims (M-3) | deposit-claim, mint-claim, redeem or withdraw eligibility check removed; `maxRedeem` back to pause-only; `recoverClaimable` without the recipient check; enforcement mint downgraded to a plain MINT; payout probe with amount 1 | 1 to 11 tests each (`Gated7540VaultIntegration_Claimable`). The amount-1 probe breaks 11, since it would block payouts to controllers holding no shares |
| `Gated7540Vault` reject (M-2) | rejected shares returned as FORCED | tests including the steering attack at a full cap and the paused reject |
| Recovery timelock (M-1) | base or executor `revokeRole` lets RECOVERY_ROLE revoke any role, or not the guardian; recovery cannot `unpause`; `GovernanceTimelock` lets it revoke any role, or not CANCELLER. On `DvPExecutor` (2026-10-23): the same three, and `pause` open to anyone | 1 to 2 tests each (`PolicyGatedUnit_Recovery`, `IntentExecutorUnit_Recovery`, `DvPExecutorUnit_Roles`, `GovernanceTimelockUnitTest`) |
| Recovery deployment (M-1) | `Activate` skips the executor's RECOVERY_ROLE, or leaves governance as a recovery-timelock canceller | The hand-over check, which pins the recovery timelock's exact role set and its lack of cancellers (59 TS tests fail) |
| Base enforcement | `forcedTransfer` keeps frozen tokens | 2 unit tests |
| Reproducibility | metadata hash re-enabled | `verify:reproducible`: every contract differs across jobs |
| Base (2026-10-24, review item S2) | the release takes the whole amount from the frozen amount; it forgets to emit `Frozen`; a zero unfrozen balance rejects a zero amount; an enforcement burn, or a forced transfer, no longer exempt from the frozen check; the template check dropped; `canSend` ignores pause; `canReceive` asks about sending; `setFrozenTokens` refuses above the balance; the unfrozen shortfall reverts as a policy rejection; `forcedTransfer` drops `ForcedTransferBy`, or returns false; `supportsInterface` forgets the standard's id; `canTransfer` ignores the unfrozen amount | 14 of 14, each by at least one test. Before the final fixes two real gaps showed: a pre-flight whose sender held `BURNER_ROLE` could report an amount above the balance as allowed, and a hook returning `INSUFFICIENT_UNFROZEN` for a mint was relabelled with the standard's error and a zero account; each got a test first |
| `HolderRestrictionRule`, `MinPositionRule` (2026-10-24, S3) | freeze or lockup ignored, on the sender or the receiver; FORCED, or the enforcement burner, no longer exempt; the lockup boundary moved; `checkSend` or `checkReceive` always accepting; the agent or admin check dropped; the two settings overwriting each other; the 64-bit range check dropped; the minimum compared with `<=` on either side; the token itself, a listed account or an enforcement burn no longer exempt; self-moves and zero amounts judged | 23 of 24 by a test; the 24th, dropping the `min == 0` early return, is an equivalent mutant (the checks after it accept at 0; it only saves gas) |
| Halmos, `MinPositionRule` (2026-10-24, S3) | the receiver or sender comparison weakened; the remainder guard dropped; FORCED not exempt; the amount guard dropped | 5 of 5, each by a symbolic property (the exact decision for a transfer, never reverting for any kind, FORCED never rejected) |
| Mint probe, cap out of `checkReceive` (2026-10-24, finding 1) | the probe amount one wei or zero; `Gated4626Vault.maxDeposit` probing one wei; `maxMint` of the 4626 vault, and `requestDeposit`, `maxDeposit` or the deposit-claim check of the 7540 vault, ignoring the probe; `FundHoldersRule` answering the cap in `checkReceive`; `canReceive` ignoring pause; the mint probe asking the sender side | 10 of 10 |
| `canTransfer` and the write on a balance shortfall (2026-10-24, finding 4) | the write never using the base error, using it at the balance too, or using it for every shortfall; `canTransfer` counting a pure balance shortfall; `canTransferWithReason` leaving it to the base; the frozen amount ignored in `canTransfer`'s test, or another account's frozen amount asked; enforcement kinds not excluded from it; the ignored shortfall skipping the hook; the shortfall boundary moved to `<=`; the strict `_check` made lenient (`canExecute`, the 7540 checks) | 11 of 11 |
| `Fund` views (2026-10-24, S4) | an unregistered token passing; the registration ignored; the first or the last class skipped; a failing hook or token counted as listed; the wrong comparison; the last broken class returned instead of the first | 8 of 8 |
| `HolderRestrictionRule.checkSend` lockup (2026-10-24) | lock ignored; `<=` at the boundary; lock reported before the freeze; freeze ignored; `checkReceive` refusing a locked account; the comparison reversed | 6 of 6 |
| `CredentialRegistry` (2026-10-25) | the lapse never returned, or at `>=`; a guardian block or a killed attester ignored; `isVerified` true for any record; the stale-credential, future-`issuedAt`, signature, validity-in-the-future (on `set` and on `setStatus(ACTIVE)`) or qualification-mask check dropped, or the validity boundary moved; a write that drops the guardian block; a status change that keeps `issuedAt`, or a direct write that stores it as zero; the overwrite rule dropped, or a killed attester's record not replaceable; `clearGuardianBlock` or `reviveAttester` open to anyone; the recovery role able to revoke any role or kill an attester; a duplicate attester account allowed, on add or on rotation, or the old account kept; `setStatus` by another attester, by a killed one, on a missing record or with `NONE` or `LAPSED`; block, unblock and kill not idempotent; the 65th attester allowed; the signed hash omitting the attester | 34 of 34. 21 by exactly one test (the lapse second, the 65th attester, each role gate, each no-op). One (a write that drops the guardian block) escaped the invariants until the handler kept its own record of the blocks |
| `CredentialRule` (2026-10-25) | the enforcement-burn exemption widened to any burn or any kind, dropped, or looked up for every sender; a blocked, unknown or lapsed sender judged wrongly; zero amounts skipped; `FORCED` or `MINT` checking the sender; `BURN` checking the receiver; an unset policy admitting; the lapsed reason removed; an exit-only receiver admitted; the attester bitmap or its shift, `requireAll`, `requireAny` or `forbidAny` dropped or weakened; `setPolicy` unauthenticated, dropping a field or keyed by the sender; the receiver or the sender read from the wrong side; `checkSend` or `checkReceive` always accepting, ignoring the token's policy or reading the wrong side | 28 of 28. 2 by exactly one test |
| Ignition credential wiring (2026-10-25) | no policy set on the tokens; a policy that asks for no bits, or trusts no attester 0; the registry not handed to the timelock; no `RECOVERY_ROLE` on the registry; the credential rule last in the order; an attester allowed to assert nothing | 7 of 7, by `credentials.test.ts` and `deployment.test.ts` (1 to 15 failing) |
| `Gated7540Vault` escrow, `GovernanceTimelock` floor (2026-10-27) | the surplus check removed, or ignoring the booked total, or at `>=`; the booked total not raised by `requestRedeem`, or not lowered by `fulfillRedeem`, the reject or the recovery; a freeze on the vault's address allowed; the timelock floor removed from the constructor or from `updateDelay`, or at `<=`; the floor checked before OpenZeppelin's caller check; the vault's escrow check run before the role check | 13 of 13, by `Gated7540VaultUnit_Escrow` and `GovernanceTimelockUnitTest`. The `<=` floor first survived, and `test_WhenGovernanceSetsTheDelayToExactlySevenDays_ItApplies` was added; the role order was found by the docs check and fixed with `test_WhenACallerWithoutTheAgentRoleNamesTheEscrow_TheRoleCheckAnswers` |
| `Gated7540Vault` dealing periods (2026-11-01) | no virtual shares or asset in the price, unclaimed shares left out of the supply; a second close, settling an open period or while paused; the balance audit gone or off by one either way; net inflow or outflow not moved, the fee unpaid or left out of the net, the escrow not burned; no wait for an earlier request; the book not raised or not lowered; each reject and recovery role; a claim or a recovery leaving `unclaimedShares` or the cash owed unchanged; each rounding direction; a request rolling before it settles; each booked total not lowered; the decimals and the first period | 38 of 39 caught. The survivor was the full-claim branch, which changes nothing because `mulDiv(x, y, x)` is exact, so the branch was removed |
| `SignedEntry` (2026-11-01) | each window end, the nonce, the signature, the minimum at its boundary, a minimum on a request, the investor as receiver and controller, the permit tolerance, the cash nonce's binding, cancelling | 20 of 20 caught |
| `GuardedAccount`, validators, `FeeModel`, the 4626 with a `Portfolio` (2026-11-01) | each role and refusal in the account; each validator's boundary; each cap, branch and clock in the fee model and each place a desk or vault keeps its result; every plug check, the rate limit, the outage stop, exit-only, the liquidity limit, the money paths | 106 run. Of the 8 alive, 2 were code that did nothing, now removed; 5 were missing tests, now written; 1 is equivalent, `<` and `<=` at exactly the hurdle both charge nothing. Rerun on those lines: 8 of 8 |
| `NavDesk` (2026-11-01) | each role, each time boundary at both sides, the table and stuck checks, each setting's bound and attestation, `adopt`'s checks, what the hash covers, the portfolio left out of the value, a stale price, the move count | 49 of 49 caught, 3 of them added with the review's age check and the cut-off event |
| `SupplyCapRule`, `ExecutedOnlyRule`, `Distributor` (2026-11-01) | the cap judging every kind, refusing at the cap, reverting when lowered below the supply, set by anyone or not stored; the wrong kind refused, or none; each role, value, window end and refusal in the distributor, a proof or a leaf that means less, claims not counted or above the funding, a sweep early, unapproved, twice or to the caller. 34 mutants, including the credential type without its bits, all caught | |
| Ignition legos and the hand-over check (2026-11-01) | each grant and plug in `Product` dropped (settler, reporter, checker, allocator, the desk's portfolio and fee model, the 4626's fee model, the caps, the permission, the supply cap); a 7540's portfolio refusing reported money, a desk with no cash account, a validator naming the wrong account; each clause of the hand-over check; each refusal in `assertUsable`. 33 mutants, all caught | |
| Halmos, `Portfolio.allocate` (2026-11-01) | the absolute cap dropped, the relative cap dropped, a second risk not checked | the symbolic property fails on each |
| The pause on a portfolio, the fund's count order, the recovery timelock's floor, a fund's own rule (2026-11-01) | `allocate` or `execute` ignoring a pause, running only while paused, or asking the pause before the role; a pause also stopping `deallocate`; the receiver joining before the sender leaves; a fund taking another fund's rule, or swapping the refusal's arguments; a zero recovery granted the role, a real one not; `Core` deploying a plain recovery timelock; the check not comparing the two timelocks, or letting someone hold recovery on the recovery one | 15 of 15 caught. The last two survived at first, and each got a test |
| The fifteen fixes found while writing the pages (2026-11-01) | the mark on a migrated portfolio set or read; the adapter list or the value not checked on a replacement; each term of a read of nothing dropped or moved; `accrue` writing through it; the first mark from `totalAssets()`; the adapter's success or size check dropped or off by one, or a failed first read ignored; `execute` always or never writing the fee state; `adopt` always or never taking the mark or the fee clock, or dropping the mark's clock; `asOf` out of the hash; the period not compared; the rate ceiling dropped or moved by one on either path; `ISupplyCapRule` not answered; a zero recipient accepted with no rate; fees through a pause; the asset not compared by the vault or the desk; the cash not checked; a replacement restarting the clock, or a first plug not starting it | 37 planted, 36 caught at first. The survivor, a failed first read ignored, was a missing test, written and now caught |
| With no shares, nothing counts, and the mark (2026-11-01) | on the 4626 the branch gone, what is there counted, the mark or its clock not restarted, par off by the offset, the mark's clock ignoring a move; on the desk the whole value, the report or the portfolio's part taken, unclaimed shares left out of the supply, the mark not restarted, par off; a first mark below par or always par on either, or from `totalAssets()` on the 4626; the model's mark at the charge and not the payment, staying when nothing is paid, or ignoring the payment | 20 planted, 18 caught at first. The two survivors, a first mark always par and one from `totalAssets()` on the 4626, were missing tests, written and now caught |
| A large fall closes deposits (2026-11-01) | a count not closing them; the views not looking; half counted as more than half; a limit of a quarter or of three quarters; no shares read as a fall; never a fall; the stored close or a write-off forgotten by the view | 9 planted, 8 caught at first. The survivor, a write-off forgotten by the view, was a missing test, written and now caught |
| A read of nothing does not read as closed (2026-11-02) | zero read as a fall; the old condition back; a value of one read as no fall; half counted as more than half; never a fall; the stored close or a write-off hidden by a read of nothing; a count writing through one; deposits open through one | 9 planted, all caught |

## 6. Toolchain supply chain

Everything CI fetches at run time is pinned, and verified wherever the distribution allows:

| Component | Pin | Verification |
|---|---|---|
| GitHub Actions (`checkout`, `setup-node`, `setup-python`) | Full commit SHA, release tag in a comment | Git object identity |
| Node, Python | Exact versions (24.21.0, 3.12.15) | Fetched by the SHA-pinned setup actions |
| npm packages | `package-lock.json` | Lockfile integrity (sha512); `npm ci --ignore-scripts`, so no package install script runs; forge-std pinned to a git commit |
| Slither, Halmos and their dependencies, 61 Python packages in all | `ci/requirements.txt` | `pip install --require-hashes` |
| forge 1.8.1 | `tools.lock` | sha256 checked by `scripts/fetch-tool.sh`; also checked once against GitHub's asset digest, Foundry's `.sha256` and its sigstore attestation (`gh attestation verify`) |
| Aderyn 0.6.8 | `tools.lock` | sha256 checked by `scripts/fetch-tool.sh`; also checked once against GitHub's asset digest and Aderyn's `.sha256`. Aderyn publishes no attestation. The npm package, whose installer downloaded the binary unverified, was removed |
| solc 0.8.30 | `hardhat.config.ts`, `foundry.toml` | Downloaded by Hardhat, forge and Aderyn, each verifying against soliditylang.org's published hashes |

Tamper checks: one changed character in a `tools.lock` hash makes `fetch-tool.sh` fail. Corrupted hashes in
`ci/requirements.txt` make pip refuse the install. The suite passes on an `--ignore-scripts` install.

## 7. Verification commands

```bash
npm ci
```

```bash
npm test
```

```bash
npm run lint:sol
```

```bash
npm run slither
```

```bash
scripts/fetch-tool.sh aderyn
```

```bash
npm run aderyn
```

```bash
npm run test:halmos
```

```bash
npm run validate:upgrades
```

```bash
npm run verify:reproducible
```

Tool versions: Node 24.21.0, Python 3.12.15, Hardhat 3.20.0, Foundry v1.8.1, slither 0.11.5, Aderyn 0.6.8, halmos 0.3.3,
`@openzeppelin/upgrades-core` 1.46.0. CI (`.github/workflows/ci.yml`) runs all of them on every pull request and every push to `main`, except `verify:reproducible`, which runs on
pull requests into `main` and, through `release.yml`, on every `v*` tag. Mythril is not used: it has no Cancun support
(TSTORE/TLOAD/MCOPY).
