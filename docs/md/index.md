[Overview](index.md) · [Contracts](index.md#contracts) · [Who can do what](roles.md) · [One movement](movement.md) · [Deployment and governance](deployment.md) · [Where the money sits](money.md)

Overview

# Gated Token Stack

Tokens for fund shares and other real-world assets, where a policy decides who may hold them. Each token keeps its own books and its emergency powers, and asks a separate, replaceable set of compliance rules before a balance changes.

- **39 contracts** in contracts/ (interfaces and test mocks aside)
- Solidity **0.8.30**, OpenZeppelin **5.6.1**
- ERC-20, ERC-721, **ERC-7943**, ERC-8473, ERC-4626, ERC-7540
- licence: **UNLICENSED**, proprietary
- **no external audit** yet

<a id="in-one-minute"></a>

> ### In one minute
>
> An issuer of fund shares usually may sell only to approved investors, and must be able to act on an account: pause the token during an incident, hold back part of a balance, or move tokens out of an account. A plain ERC-20 token lets anyone send to anyone and has none of these powers. Here every token keeps the books and the powers, and hands each question about who may hold, send or receive to one outside contract, the hook. The hook asks a short list of small contracts, the rules, and the first rule that says no stops the movement. Rules can be replaced through governance without touching the token or its address.
>
> Around that core sit optional parts: executors that run signed transfers, vaults that deal at once or at an approved price, a portfolio that limits where a vault's money may go, and a contract that pays distributions. An issuer deploys one core and adds products one at a time. Nothing here has had an external audit.

<a id="problem"></a>
## The problem it solves

Real-world assets on a chain need things a plain token does not give. Who may hold them is decided by someone outside the chain: an identity provider, the issuer's onboarding. The issuer needs enforcement powers. The policy changes over time: a type of investor is added, a lockup starts, a fund limits its number of investors. And a fund needs a price someone has approved, and limits on where its money may go.

The stack answers with a split. The token is a standard ERC-20 that refuses to move a balance unless its hook says yes. The hook is shared by every token of a deployment and keeps an ordered list of rules for each token. Each rule answers one question, such as "does the receiver hold a credential this token accepts" or "would this leave a balance below the minimum". Every token also implements ERC-7943, a standard interface for permissioned tokens, so outside tools can ask it `canTransfer`, `canSend` and `canReceive` before they send. Every token and the hook also implement ERC-8473, a draft standard that sits behind ERC-7943 and names the policy contract a token asks.

Everything else is a separate contract a product opts into. A product that is one plain token deploys none of the vault, portfolio or pricing contracts.

<a id="layers"></a>
## The layers

Seven groups of contracts, each with one job. The tokens sit in the middle. Above them is what calls them on someone's behalf, and below them what they ask and where their money goes.

> **Diagram.** How the contracts connect. Above the tokens: Distributor asks a token hasRole and canReceive. IntentExecutor and DvPExecutor call executeTransfer on IntentToken. SignedEntry calls deposit on Gated4626Vault and requestDeposit on Gated7540Vault. NavDesk calls closePeriod and settlePeriod on Gated7540Vault, and quote on FeeModel. The tokens are five templates. Four are fungible, GatedToken, IntentToken, Gated4626Vault and Gated7540Vault, on one base, PolicyGatedERC20Upgradeable; IntentToken adds the mixin IntentSettledUpgradeable and both vaults add GatedVaultBase. The fifth, Gated721, is an NFT. All five share PolicyGatedCoreUpgradeable, which holds the roles, the pause, the hook pointer and the upgrade checks. Each product is a TokenProxy over one template, placed by ProxyDeployer. Below the tokens: a token calls checkTransfer and afterTransfer on the shared ComplianceHook, which calls check and after\_ on the rules in the token's list: CredentialRule, MinPositionRule, HolderRestrictionRule, SettlementWindowRule, FundHoldersRule, SupplyCapRule and ExecutedOnlyRule, all extending BaseRule. CredentialRule calls profileOf on CredentialRegistry. FundHoldersRule calls admission, join and leave on Fund. A vault's money goes in and out of its Portfolio, which calls allocate and deallocate on ERC4626Adapter and GuardedAccount; GuardedAccount calls validate on ERC20CallValidator or ERC4626CallValidator. At the bottom, governance and deployment: PolicyRegistry, GovernanceTimelock as main and recovery timelock, ProxyDeployer and TokenProxy.
>
> **The policy sits outside the token, and everything around it is opt-in.** Arrows are calls between contracts. The grid of rules shows no order: each token has its own ordered list, and lists only the rules its product needs. Not drawn: `Gated4626Management` and `Gated4626Common`, which run as part of the 4626 vault, and `Gated7540Settlement` and `Gated7540Common`, which run as part of the 7540 vault; `PolicyRegistry` is asked whenever attested code is installed, and never on a transfer; the main timelock holds the admin role on each token; `DvPExecutor` can also take cash from an ERC-3009 token outside the stack; `Distributor` serves one token, of any template, and `Legos` deploys it for a product that asks; `NavDesk` reads its vault's `Portfolio` for a value.

| Layer | Contracts | What it does |
|---|---|---|
| Token | `PolicyGatedCoreUpgradeable`, `PolicyGatedERC20Upgradeable`, `IntentSettledUpgradeable`, `GatedToken`, `IntentToken`, `Gated721` | Keeps balances, roles, the pause, frozen amounts and forced transfers. Every balance change goes through one internal function, `_move`, which asks the hook. `GatedToken` is the fungible base alone. `IntentToken` adds the mixin that runs transfers a holder signed. `Gated721` is an NFT with a metadata URI per token. It shares the core with the others, so the roles, the pause, the hook and the upgrade checks are the same code. |
| Vaults | `GatedVaultBase`, `Gated4626Vault`, `Gated4626Management`, `Gated4626Common`, `Gated7540Vault`, `Gated7540Settlement`, `Gated7540Common`, `NavDesk`, `FeeModel` | Vault shares are gated tokens too. The 4626 deposits and redeems at once, and hands its four management functions to a second contract its implementation creates. The 7540 deals in periods, one price for everyone in a period, and hands settlement and recovery to a second contract its implementation creates. `NavDesk` turns a reported value into that price and can hold a redemption gate, and `FeeModel` works out a fee for a desk or a 4626. |
| Portfolio | `Portfolio`, `ERC4626Adapter`, `GuardedAccount`, `ERC20CallValidator`, `ERC4626CallValidator` | Where one vault's money may go. The portfolio holds the idle money and sends it to installed adapters, under caps on their allocation. An adapter is an on-chain vault position or a guarded account for a custodian or a strategy, whose calls are limited by validators. |
| Policy | `ComplianceHook`, `BaseRule`, `CredentialRule`, `MinPositionRule`, `HolderRestrictionRule`, `SettlementWindowRule`, `FundHoldersRule`, `SupplyCapRule`, `ExecutedOnlyRule` | Decides whether a movement may happen. One hook for the whole deployment, an ordered list of at most 16 rules per token. Each rule returns a reason code. A token with no rules has every movement refused. |
| Identity and fund | `CredentialRegistry`, `Fund` | `CredentialRegistry` records what attesters (identity providers) say about each address: who vouched for it, its qualification bits, until when, and its standing. `CredentialRule` reads it. `Fund` groups several tokens as share classes and counts distinct investors across them, and `FundHoldersRule` enforces the cap. |
| Governance and deployment | `PolicyRegistry`, `GovernanceTimelock`, `ProxyDeployer`, `TokenProxy` | Admin powers sit behind a delay, 24 hours by default with a floor of one hour. The security council records which code it reviewed. A guardian can stop things at once. `ProxyDeployer` places each token at an address that depends on the deployer, the symbol and the implementation, sets it up in the same transaction and checks it came up as expected. |
| Settlement and distribution | `IntentExecutor`, `DvPExecutor`, `SignedEntry`, `Distributor` | Act on what someone signed or approved in advance. `IntentExecutor` runs signed transfers. `DvPExecutor` settles shares against cash in one transaction, so neither side moves without the other. `SignedEntry` lets an investor enter a vault on signed messages while a relayer submits them and pays the gas. `Distributor` pays a funded distribution that holders claim with a proof. |

<a id="life"></a>
## The life of a transfer

Every balance change takes the same path: a transfer, a mint, a burn, a forced transfer, an executed intent, a vault deposit or redemption. Here is a holder's plain `transfer`. [One movement](movement.md) follows each step in full.

> **Diagram.** A transfer in five steps. The holder calls transfer. The token builds the context: kind, amount and both balances. The token runs its own checks: pause and unfrozen balance. The hook asks the rules in order and the first no wins. The balances move, then afterTransfer reaches after\_ on the rules that asked for it. A no from the token's checks or from a rule reverts the call with ERC8473PolicyRejected or a balance error, and nothing changes.
>
> **Two places can say no, and both undo the whole call.** The token's own checks run first, then the rules. A movement changes a balance only if it passes both.

1. **The holder calls `transfer(to, amount)`.** OpenZeppelin's `_update` routes every ordinary transfer, mint and holder's burn into one internal function, `_move`. A forced transfer and an executed intent enter it through `_moveAs`, an enforcement mint through `_mintAs`, and the burner's `burn` calls it directly, each naming its kind.
2. **The token describes the movement.** It works out the kind (here TRANSFER) and builds the context the rules will see: the sender, the receiver, the amount, the account that called, and both balances before the move.
3. **The token runs its own checks.** While the token is paused, only forced movements pass. The amount must fit in the sender's unfrozen balance, the part the agent has not held back; a forced movement may take frozen tokens, up to the balance. The forced movements are a forced transfer, `burn`, which only a `BURNER_ROLE` holder can call, and the 7540 vault's two recoveries.
4. **The hook asks the token's rules in order.** Each product has its own list. The demo profile `full` lists `CredentialRule` (the sender may leave, the receiver holds a credential the token accepts), `MinPositionRule`, `HolderRestrictionRule` (address freeze and lockup), `SettlementWindowRule` on the intent token (executed intents only), and `FundHoldersRule` (the fund's investor cap). The first rule that answers anything but `TRANSFER_OK` stops the movement, and the call reverts with `ERC8473PolicyRejected(reason)`.
5. **The balances move, then `afterTransfer` runs.** The hook tells the rules that asked for it about the finished movement, through `after_`. `FundHoldersRule` is the one shipped rule that asks: it tells `Fund` when the sender stops holding this class and when the receiver starts.

<a id="choices"></a>
## Three design choices

- **The policy lives outside the token.** The token's code has no opinion about who, where or when. A policy change is a different rule list on the hook, not a token upgrade, so the token keeps its address, balances and history.
- **Installed code must be attested.** Hooks, rules, implementations, portfolios, adapters, validators and fee models are each checked against `PolicyRegistry`, where the security council records the code hash of what it reviewed. A token checks its hook and each upgrade; the hook checks each rule; `ProxyDeployer` checks a token's first implementation; a portfolio checks its adapters; `Fund` checks its rule. The registry is asked at install time, so withdrawing an attestation does not change a running token.
- **Authority waits, and the fast power can only stop.** Changes to a product's rule list, roles and code go through a timelock, 24 hours by default and with a floor of one hour. The guardian can pause at once and cancel queued changes, and cannot unpause, change the rules or upgrade. A second timelock can unpause and remove the guardian, so the guardian cannot block its own removal. A launch is the exception: the operations account places a product with no wait, because a launch adds a proxy over attested code and touches nothing that exists.

<a id="glossary"></a>
## Glossary

- **token**: A contract that holds balances and asks its hook before each movement. The stack has five templates: four ERC-20s, `GatedToken`, `IntentToken`, `Gated4626Vault` and `Gated7540Vault`, and one ERC-721, `Gated721`.
- **template**: One kind of token, with its own implementation and its own `templateId`. An upgrade to an implementation that reports another template is refused.
- **mixin**: A contract that adds one ability to a template. `IntentSettledUpgradeable` adds signed intents, and `IntentToken` is the template that uses it.
- **proxy**: A small contract that keeps a token's address and storage and runs the code of another contract, the implementation, for each call. Each token is a `TokenProxy` (OpenZeppelin's `ERC1967Proxy`). The upgrade function sits in the implementation (the UUPS pattern).
- **implementation**: The shared code of one template, deployed once per core and used by each proxy of that template. Its constructor disables setup, so a proxy is what gets set up.
- **product**: One token an issuer launches: a proxy over a template, with its own rule list and policy.
- **profile**: A named combination of products in `ignition/profiles.ts`, from one plain token (`token`), one NFT (`nft`) or one intent token with both executors (`intent`) to the demo (`full`): an intent token and both vaults as three classes of one fund, with both executors. The demo has no desk, portfolio or fee model; `managed-fund` and `vault4626-invest` show those.
- **hook**: The contract a token asks before each balance change. Here it is `ComplianceHook`, one per deployment, holding an ordered rule list for each token.
- **rule**: A small contract that answers one policy question about a movement with a reason code, such as `TRANSFER_OK` or `RECEIVER_FROZEN`. One instance serves each token whose list names it, and any setting it keeps is kept per token.
- **reason code**: A `bytes32` answer, the hash of a name like `LOCKED_UP`. They are listed in `contracts/interfaces/Errors.sol` and on [One movement](movement.md).
- **kind**: What sort of movement it is: TRANSFER (a holder's transfer), EXECUTED (a signed intent run by an executor), FORCED (an enforcement move: the agent's, the burner's `burn`, or on a 7540 the settler's recovery of a redemption in a closed period), MINT or BURN (a holder's own burn, such as a vault redemption). Rules decide differently per kind.
- **attested**: The security council recorded a contract's code hash in `PolicyRegistry` as a reviewed `HOOK`, `RULE`, `IMPLEMENTATION`, `PORTFOLIO`, `ADAPTER`, `VALIDATOR` or `FEE_MODEL`. It is checked when the contract is installed. A code hash covers an immutable address, not the code at that address.
- **guardian**: A multisig that can stop things and reduce risk, and nothing else: pause the tokens and the executors with no delay, cancel operations waiting in the main timelock, cancel a proposed price, pull a portfolio's money back, lower its caps, lower a 4626's rate limit, and revoke a guarded account's permission. On the credential registry it can block an address or switch off an attester.
- **timelock**: A contract that holds admin powers and runs a queued operation after a delay. The main timelock administers the products and the contracts around them. The recovery timelock is the same contract with no recovery role of its own; outside itself it can unpause, remove the guardian, take away any account's right to cancel on the main timelock, and undo the guardian's actions on the credential registry, and nothing more.
- **operations account**: The account that owns `ProxyDeployer` and runs product launches. It is a product's admin during its launch and hands that to the timelock at the end of it.
- **intent**: A transfer a holder signs off-chain (an EIP-712 message): amount, receiver, deadline, a random single-use nonce, and optionally which executor may run it and what the holder is to receive in return.
- **executor**: An account holding `EXECUTOR_ROLE` on an intent token, the role that runs an intent. A product names the ones it uses: `IntentExecutor`, `DvPExecutor` or both.
- **relayer**: An account that submits someone else's signature and pays the gas.
- **DvP**: Delivery versus payment: the shares and the cash move in the same transaction, or neither moves. `DvPExecutor` does this from two signed legs.
- **cash leg**: The side of a DvP trade that pays. It is a signed intent on a gated cash token, or an ERC-3009 authorization on a token outside the stack. `DvPExecutor` runs it first, and the other side is the securities leg.
- **fund**: A `Fund` contract: a set of share-class tokens with one investor count and one cap across them.
- **class**: One token registered in a fund. An investor who holds three classes counts once.
- **credential**: The record an attester (an identity provider) keeps for an address in `CredentialRegistry`: who vouched for it, its qualification bits, until when it is valid, and its standing. A jurisdiction is a qualification bit, not a country field.
- **frozen amount**: The part of an account's balance that the agent holds back on a token (`setFrozenTokens`). The holder can move the rest. It is not the same as an address freeze, which `HolderRestrictionRule` keeps and which stops the address from sending or receiving.
- **minimum position**: A per-token minimum balance kept by `MinPositionRule`: a transfer, intent, mint or holder's burn may not leave an account holding more than zero and less than the minimum. Forced moves, which include the burner's burns, and exempt accounts are outside it. A minimum of 0 switches it off.
- **escrow**: Tokens a contract holds on someone's behalf. `Gated7540Vault` holds the shares of pending redemptions at its own address.
- **controller**: In ERC-7540, the account a request belongs to, which may claim it or let an approved operator do so.
- **dealing period**: On `Gated7540Vault`, the stretch of time whose requests are dealt together. One period is open and requests join it. Everyone in a period gets one price, set in one transaction, and each investor claims later.
- **cut-off**: The moment a dealing period closes, with `closePeriod`. A request after it waits for the next period. Through `NavDesk`, anyone can call it once `periodLength` has passed.
- **net asset value**: NAV: what a fund's assets are worth after fees, in units of its asset. `settlePeriod` deals a period at the NAV it is given, which leaves out what the vault itself holds (pending deposits and claimable redemption cash).
- **redemption gate**: The most of a fund that may leave in one period, net of what comes in, set on `NavDesk` as a level. Past it every request in the period is filled at the same fraction, and the rest carries to the next period, stays invested and deals at that period's price.
- **maker and checker**: Two different accounts behind one decision: one proposes and the other approves. `NavDesk` asks this of each price, and `Distributor` of each distribution.
- **portfolio**: A `Portfolio` contract, one per vault: holds the vault's idle money and sends it to installed adapters, under caps on their allocation.
- **adapter**: The plug between a portfolio and one place money can go. `ERC4626Adapter` holds a position in an on-chain vault, and `GuardedAccount` serves a custodian or a strategy.
- **priced value**: What the contracts can read on-chain: a portfolio's idle money plus what its priced adapters say they hold (`pricedValue`).
- **reported value**: A figure the vault's reporter states for money the chain cannot see, such as money with a custodian. `NavDesk.propose` takes it with the hash of the report behind it. The hash proves which report was used, not that the money exists.
- **distribution**: A payment to one token's holders. `Distributor` holds a Merkle root of who is owed what, built off-chain at the record date, and each holder claims with a proof.

<a id="contracts"></a>
## The contracts

One page per contract: what it is for, how it works, what it can do, and its tests.

### Token

- [PolicyGatedCoreUpgradeable](contracts/PolicyGatedCoreUpgradeable.md): What every template shares, whatever it counts: the roles, the guardian and recovery, the pause, the hook pointer and the upgrade checks.
- [PolicyGatedERC20Upgradeable](contracts/PolicyGatedERC20Upgradeable.md): The base every fungible token and vault extends: balances, frozen amounts, forced transfers, and the one path that asks the hook.
- [IntentSettledUpgradeable](contracts/IntentSettledUpgradeable.md): The mixin for transfers a holder signs and an account with `EXECUTOR_ROLE` runs.
- [GatedToken](contracts/GatedToken.md): The base and nothing else: a gated ERC-20 at the decimals its ledger uses, with no signed intents.
- [IntentToken](contracts/IntentToken.md): A gated ERC-20 with signed intents, at the decimals its ledger uses.
- [Gated721](contracts/Gated721.md): A gated NFT: a certificate or a note per token, judged by the same hook and rules, with a freeze per token.

### Vaults

- [GatedVaultBase](contracts/GatedVaultBase.md): What both vaults share: the issuer's `mint` and `burn` revert, and a third party in a deposit or redemption must pass the token's policy.
- [Gated4626Vault](contracts/Gated4626Vault.md): An ERC-4626 vault whose shares are a gated token. It can invest through a portfolio, with a limit on how fast its counted value may rise.
- [Gated4626Management](contracts/Gated4626Management.md): The 4626's second contract: plugging a portfolio, the rate limit, the fee model and paying fees run there, on the vault's storage. The implementation creates it, and nobody can swap it alone.
- [Gated4626Common](contracts/Gated4626Common.md): The storage and the counting those two share, so they cannot disagree on the layout.
- [Gated7540Vault](contracts/Gated7540Vault.md): An ERC-7540 vault dealt in periods: investors request, one settlement prices the whole period, and each investor claims later. A settlement can take part of the redemptions, at one fraction for all.
- [Gated7540Settlement](contracts/Gated7540Settlement.md): The 7540's second contract: closing, settling, rejecting and recovering run there, on the vault's storage. The implementation creates it, and nobody can swap it alone.
- [Gated7540Common](contracts/Gated7540Common.md): The storage and the request roll those two share, so they cannot disagree on the layout.
- [NavDesk](contracts/NavDesk.md): Turns a reported value into an approved price for one 7540 vault: one account proposes, a different one accepts, and a cooldown leaves time to cancel. It holds the fund's redemption gate, if it has one.
- [FeeModel](contracts/FeeModel.md): Works out a management fee and a performance fee from rates fixed at deployment, with no storage of its own.

### Portfolio

- [Portfolio](contracts/Portfolio.md): Where one vault's money may go: held idle here, sent to installed adapters under caps on their allocation, returned to the vault, paid to the fee model's `RECIPIENT` by a 4626's `collectFees`, or moved by a timelock operation to an attested successor.
- [ERC4626Adapter](contracts/ERC4626Adapter.md): Holds a portfolio's position in one ERC-4626 vault as an ordinary depositor, priced on-chain.
- [GuardedAccount](contracts/GuardedAccount.md): An adapter for a custodian or a strategy, whose value is reported. It makes a call only if a validator allows it.
- [ERC20CallValidator](contracts/ERC20CallValidator.md): Allows `transfer` to one address, or `approve` of one spender, up to one amount per call.
- [ERC4626CallValidator](contracts/ERC4626CallValidator.md): Allows `deposit`, `mint`, `withdraw` and `redeem` when the money and shares come back to the calling account.

### Policy

- [ComplianceHook](contracts/ComplianceHook.md): The one hook a deployment shares. An ordered rule list per token; the first rule to say no wins.
- [BaseRule](contracts/BaseRule.md): The parent of every rule: default answers, and the guard that lets only a token's installed hook call `after_`.
- [CredentialRule](contracts/CredentialRule.md): Who may hold: reads the credential registry and applies the token's policy to a receiver. A sender needs a standing that lets it leave.
- [MinPositionRule](contracts/MinPositionRule.md): Refuses a movement that would leave an account with more than zero and less than the token's minimum.
- [HolderRestrictionRule](contracts/HolderRestrictionRule.md): Per-holder lockups and address freezes, set by the token's agent.
- [SettlementWindowRule](contracts/SettlementWindowRule.md): Executed intents settle inside the token's daily UTC window, on the weekdays it enables.
- [FundHoldersRule](contracts/FundHoldersRule.md): Caps the number of distinct investors across a fund's classes.
- [SupplyCapRule](contracts/SupplyCapRule.md): Refuses a mint above a per-token cap, to limit what a stolen minter key can do.
- [ExecutedOnlyRule](contracts/ExecutedOnlyRule.md): Refuses a plain transfer, so a holder can send tokens to another account only by a signed intent. A forced transfer still passes.

### Identity and fund

- [CredentialRegistry](contracts/CredentialRegistry.md): One record per address: which attester vouched for it, its qualification bits, until when, and its standing.
- [Fund](contracts/Fund.md): Lists a fund's share classes and counts distinct investors across them.

### Governance and deployment

- [PolicyRegistry](contracts/PolicyRegistry.md): The list of code hashes the security council has attested, and as what kind.
- [GovernanceTimelock](contracts/GovernanceTimelock.md): OpenZeppelin's timelock with a one-hour floor on its delay. The main and the recovery timelock are both this contract.
- [ProxyDeployer](contracts/ProxyDeployer.md): Places each token at a predictable address, refuses an unattested implementation, and refuses to finish unless the token came up as expected.
- [TokenProxy](contracts/TokenProxy.md): The proxy every token is: OpenZeppelin's `ERC1967Proxy`, created without setup data.

### Settlement and distribution

- [IntentExecutor](contracts/IntentExecutor.md): Submits signed intents that state no payment, one at a time or as an all-or-nothing batch.
- [DvPExecutor](contracts/DvPExecutor.md): Settles shares against cash in one transaction from two signed legs.
- [SignedEntry](contracts/SignedEntry.md): Lets an investor enter a vault on signed messages while a relayer submits them and pays the gas.
- [Distributor](contracts/Distributor.md): Pays one token's holders a funded distribution from a Merkle root that a maker proposes and a different checker approves.

### Topics

- [Who can do what](roles.md): The roles, who holds each one after deployment, and what each can and cannot do.
- [One movement](movement.md): Everything that happens when a balance changes: kinds, checks, rules, reason codes and errors.
- [Deployment and governance](deployment.md): How one core and then each product are put in place, and how policy and code change later.
- [Where the money sits](money.md): Which contract holds the assets, the shares and the cash at each step.

<a id="source"></a>
## Source

- Repository: `README.md` (setup and commands) and `SECURITY.md` (audit preparation)
- Contracts: `contracts/`, interfaces in `contracts/interfaces/`
- Deployment: `ignition/modules/` (`Core.ts`, `CoreHandover.ts`, `CoreParts.ts`, `PartsHandover.ts`, `Fund.ts`, `Legos.ts`, `Product.ts`, `FundOpen.ts` and `roles.ts`), the parts of a core in `ignition/parts.ts`, and the combinations in `ignition/profiles.ts`

---

Describes the contracts at commit `ea062b5` on `erc8473-main`.
