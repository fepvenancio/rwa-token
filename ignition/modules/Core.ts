// SPDX-License-Identifier: UNLICENSED
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

import { activeProfile, partsOf, type Profile } from "../profiles.js";
import { deployParts } from "../parts.js";

/** The recovery timelock's own recovery argument: nobody holds RECOVERY_ROLE on it. */
const NO_RECOVERY = "0x0000000000000000000000000000000000000000";

/**
 * Stage 1, once per issuer. Everything that does not depend on a product:
 *
 * - The recovery timelock (`GovernanceTimelock` with no recovery of its own, so the one-hour floor holds on it too;
 *   governance as proposer and executor) and the main timelock (`GovernanceTimelock`: proposer and executor are the
 *   governance multisig only; the recovery timelock may revoke CANCELLER_ROLE there and nothing else). The deployer is
 *   the admin of both only until `CoreHandover` finishes.
 * - The registry, administered by the timelock from the start, and the one shared `ComplianceHook` that every product
 *   uses. Its only immutable is the registry, so the council attests one codehash for all of them, and each product's
 *   rules are installed by the product itself when it is placed.
 * - `ProxyDeployer`, which `CoreHandover` moves to the operations account.
 *
 * Then only what the profile's products use, through `deployParts` (`CoreParts`), which also adds a part to a core that
 * already runs:
 *
 * - The `CredentialRegistry` (administered by the deployer until `CoreHandover`) and the `CredentialRule` that reads it.
 *   The rule's codehash covers the registry's address and not its code, so the council reads the registry's code, its
 *   admin and its attester list before it attests the rule.
 * - Each other listed rule, and one implementation per template: every product of a template shares it.
 * - The intent executor and the DvP executor, if a product names them (administered by the deployer until
 *   `CoreHandover`). Neither is attested: neither is a hook, a rule or an implementation, and each token authorises it by
 *   granting it EXECUTOR_ROLE.
 * - The `SignedEntry`, if the profile asks for it. It holds no money and no role, and a vault accepts it as a payer only if
 *   its policy does.
 *
 * A fund is not part of the core: an issuer has as many as it needs, each with its own `Fund` module.
 *
 * Next: the council attests the rules, the hook and the implementations, then `CoreHandover`, then a `Fund` for each fund
 * and a `Product` for each product.
 */
export function coreModule(profile: Profile) {
  return buildModule(`Core_${profile.id}`, (m) => {
    const deployer = m.getAccount(0);
    const governance = m.getParameter<string>("governance");
    const council = m.getParameter<string>("council");
    const minDelay = m.getParameter<bigint>("minDelay", 24n * 3_600n);

    // The recovery timelock (same delay and the same floor, governance proposes and executes, no cancellers, guardian
    // holds nothing) can only unpause and remove the guardian everywhere; deployed first so the main timelock can name
    // it. It has no recovery of its own, hence the zero address.
    const recoveryTimelock = m.contract("GovernanceTimelock", [minDelay, [governance], [governance], deployer, NO_RECOVERY], {
      id: "recoveryTimelock",
    });
    const timelock = m.contract("GovernanceTimelock", [minDelay, [governance], [governance], deployer, recoveryTimelock]);
    const registry = m.contract("PolicyRegistry", [timelock, council]);
    const hook = m.contract("ComplianceHook", [registry]);
    const proxyDeployer = m.contract("ProxyDeployer", [deployer, registry]);

    return { timelock, recoveryTimelock, registry, hook, proxyDeployer, ...deployParts(m, partsOf(profile)) };
  });
}

export default coreModule(activeProfile());
