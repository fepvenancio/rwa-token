# Documentation

These pages explain how the contracts in `contracts/` work and how they are deployed. They describe what the code does. Where the build brief ([CLAUDE.md](../CLAUDE.md)) or the [README](../README.md) says something different, the code is right, and the page follows the code.

Checked against: CHECKED_AGAINST_PLACEHOLDER

## Which page answers what

| Question | Page |
|---|---|
| What are the contracts, and how do they connect? | [architecture.md](architecture.md) |
| Who can call what, and who holds each role after deployment? | [roles.md](roles.md) |
| What happens inside a transfer? Why was it rejected? | [transfer-checks.md](transfer-checks.md) |
| How do I mint, burn, sign an intent, claw back, freeze or pause? | [flows-token.md](flows-token.md) |
| How do the two vaults work, call by call? | [flows-vaults.md](flows-vaults.md) |
| Where do tokens and assets sit at each step? How is the price set? | [money.md](money.md) |
| How does the policy change after launch? How is a token deployed? | [governance-and-deployment.md](governance-and-deployment.md) |

Read them in that order the first time. Each page stands alone after that.

Other documents in the repo: [README.md](../README.md) has the security model summary, the deployment runbook and the commands. [SECURITY.md](../SECURITY.md) is the audit package. [PLAN.md](../PLAN.md) is the decision log.

## Terms

| Term | Meaning here |
|---|---|
| Token | A proxy running `IntentToken`, `Gated4626Vault` or `Gated7540Vault`. Vault shares are tokens too |
| Movement | Any change to a token balance: transfer, mint, burn, forced transfer, executed intent |
| Hook | The `ComplianceHook` bound to one token. The token asks it about every movement |
| Rule | A small contract the hook calls, with `check` (a view) and `after_`. Examples: `IdentityRule`, `LockupRule` |
| Kind | How the hook sees a movement: `TRANSFER`, `EXECUTED`, `FORCED`, `MINT`, `BURN` |
| Context | The `TransferContext` struct the token builds for each movement and passes to the hook and rules |
| Reason code | A `bytes32` returned instead of `TRANSFER_OK` to reject a movement. Listed in `contracts/interfaces/Errors.sol` |
| Attested | A runtime codehash recorded in `PolicyRegistry` as `HOOK`, `RULE` or `IMPLEMENTATION` |
| Timelock | OpenZeppelin's `TimelockController`. It holds the admin powers after deployment |
| Guardian | A multisig that can pause tokens and the executor, and cancel timelock operations. It can do nothing else |
| Council | The security council multisig, holder of `ATTESTER_ROLE` on the registry |
| Agent | The holder of `AGENT_ROLE`: forced transfers, freezes, lockups, redemption recovery |
| Operator | Three different things. See [roles.md](roles.md) |
| Intent | A transfer the holder signs (EIP-712) and an executor submits |
| Frozen | An amount of a holder's balance that the holder cannot move, set by the agent |
| Controller | In `Gated7540Vault`, the account that owns a request's bookkeeping and makes the claim |
| Fulfiller | The holder of `FULFILLER_ROLE` on `Gated7540Vault`. It decides price and timing of fulfilments |
| Custody | In `Gated7540Vault`, the address that receives the assets of fulfilled deposits |

## Conventions

- Each section ends with a `Code:` line naming the contracts and functions it was written from. They name functions, not line numbers, so they survive edits. To check a claim, open the named function.
- Reason codes, roles, events and errors appear in code font, spelled as in the source.
- "Raw units" means the token's smallest unit. Amounts in whole units say so.
- Diagrams are Mermaid, which GitHub renders.
