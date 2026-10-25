# Documentation

These pages explain how the contracts in `contracts/` work and how they are deployed. They describe what the code does. Where the build brief ([CLAUDE.md](../CLAUDE.md)) or the [README](../README.md) says something different, the code is right, and the page follows the code.

Checked against: the contracts and Ignition modules of release `v0.2.0` (commit `ca88619`), plus the `MaxHoldersRule` seeding change merged in PR #1 (commit `b6f8e9b`), plus the fund layer (`Fund`, `FundHoldersRule` and their Ignition steps) and the intent revision (`executor`, `validAfter` and the consideration fields on `TransferIntent`, `canExecute` taking the signature) and the DvP executor (`DvPExecutor` and its Ignition steps), plus the review items on the `fund-layer` branch up to commit `f3a8295`: the one shared `ComplianceHook`, the balances in `TransferContext.extra`, the ERC-7943 Final token face, the template check on upgrades, `multicall`, `HolderRestrictionRule` and `MinPositionRule`, the `Fund` monitor views and the demo rule lists, plus the change after `f3a8295` that takes the holder caps out of `canReceive` and gives the vaults a mint probe of a very large amount, plus the change after that which makes the token revert with `ERC20InsufficientBalance` for an amount above the balance and has `canTransfer` leave a balance shortfall to the base standard, as ERC-7943 asks. The pages describe the code as it stands, including the case where `canTransfer` and `canTransferWithReason` differ, a balance shortfall with no frozen amount in the way (the README records it). If a later commit changes it, these pages may be out of date.

## Which page answers what

| Question | Page |
|---|---|
| What are the contracts, and how do they connect? | [architecture.md](architecture.md) |
| How does a fund count its investors across share classes? | [architecture.md](architecture.md#the-fund) and [transfer-checks.md](transfer-checks.md#fundholdersrule) |
| Who can call what, and who holds each role after deployment? | [roles.md](roles.md) |
| What happens inside a transfer? Why was it rejected? | [transfer-checks.md](transfer-checks.md) |
| How do I mint, burn, sign an intent, claw back, freeze or pause? | [flows-token.md](flows-token.md) |
| How do the two vaults work, call by call? | [flows-vaults.md](flows-vaults.md) |
| Where do tokens and assets sit at each step? How is the price set? | [money.md](money.md) |
| How does a share trade settle against cash, atomically? | [flows-dvp.md](flows-dvp.md) |
| How does the policy change after launch? How is a token deployed? What do I do in an incident? | [governance-and-deployment.md](governance-and-deployment.md), and [its incident runbook](governance-and-deployment.md#incident-runbook-pause-enforce-resume) |

Read them in that order the first time. Each page stands alone after that.

Other documents in the repo: [README.md](../README.md) has the security model summary, the deployment runbook and the commands. [SECURITY.md](../SECURITY.md) is the audit package. [PLAN.md](../PLAN.md) is the decision log.

## Terms

| Term | Meaning here |
|---|---|
| Token | A proxy running `IntentToken`, `Gated4626Vault` or `Gated7540Vault`. Vault shares are tokens too |
| Movement | Any change to a token balance: transfer, mint, burn, forced transfer, executed intent |
| Hook | The `ComplianceHook`, one per deployment and shared by every token, with an ordered rule list for each token. The token asks it about every movement |
| Fund | The `Fund` contract: the classes of one fund, how many distinct investors hold any of them, and which classes each investor holds |
| Class | A token registered in a fund. Any of the three templates can be a class |
| Rule | A small contract the hook calls, with `check` (a view) and `after_`. Examples: `IdentityRule`, `HolderRestrictionRule` |
| Kind | How the hook sees a movement: `TRANSFER`, `EXECUTED`, `FORCED`, `MINT`, `BURN` |
| Context | The `TransferContext` struct the token builds for each movement and passes to the hook and rules |
| Reason code | A `bytes32` returned instead of `TRANSFER_OK` to reject a movement. Listed in `contracts/interfaces/Errors.sol` |
| Attested | A runtime codehash recorded in `PolicyRegistry` as `HOOK`, `RULE` or `IMPLEMENTATION` |
| Main timelock | `GovernanceTimelock`, OpenZeppelin's `TimelockController` with one added recovery power. It holds the admin powers after deployment |
| Recovery timelock | A second, plain `TimelockController`. As deployed, nobody can cancel its operations. Through `RECOVERY_ROLE` it can only unpause the tokens and the executors, revoke `GUARDIAN_ROLE` on them, and revoke `CANCELLER_ROLE` on the main timelock |
| Guardian | The account, a multisig in a real deployment, that can pause tokens and the executors and cancel operations on the main timelock. It can do nothing else, and the recovery timelock can remove it |
| Council | The security council, a multisig in a real deployment, holder of `ATTESTER_ROLE` on the registry |
| Agent | The holder of `AGENT_ROLE`: forced transfers, freezes, lockups, and in `Gated7540Vault` recovery of pending redemptions and of claimable amounts |
| Operator | Three different things. See [roles.md](roles.md) |
| Intent | A transfer the holder signs (EIP-712) and an executor submits. It can name the only executor allowed to run it and state what the signer is to receive for it |
| DvP | Delivery versus payment: a share trade against cash, both legs in one transaction, through `DvPExecutor`. The cash is a gated token or an ERC-3009 token |
| Frozen | An amount of a holder's balance that the holder cannot move. The agent sets it, and it may exceed the balance, in which case nothing can be moved. Enforcement actions (`burn`, forced transfers, the 7540 vault's recovery of pending redemptions) lower it by the part of the amount they take from it. It can stay above the balance. Not the same as an address freeze, which `HolderRestrictionRule` keeps and which stops an account from sending or receiving |
| Minimum position | The smallest balance an account may be left holding above zero, kept per token by `MinPositionRule` (0 is off) |
| Account-level answer | What `canSend` and `canReceive` say about one account, with no amount and no kind: the hook's `checkSend` and `checkReceive`. They hold no quantitative rule (a holder cap, a minimum): the vaults' `maxDeposit` and `maxMint` probe a mint of a very large amount instead |
| Controller | In `Gated7540Vault`, the account that owns a request's bookkeeping. The claim is made by the controller or by an operator it approved |
| Fulfiller | The holder of `FULFILLER_ROLE` on `Gated7540Vault`. It decides price and timing of fulfilments |
| Custody | In `Gated7540Vault`, the address that receives the assets of fulfilled deposits |

## Conventions

- Most sections that describe code end with a `Code:` line naming the contracts and functions they were written from. They name functions, not line numbers, so they survive edits. To check a claim, open the named function.
- Reason codes, roles, events and errors appear in code font, spelled as in the source.
- "Raw units" means the token's smallest unit. Amounts in whole units say so.
- Diagrams are Mermaid, which GitHub renders.
