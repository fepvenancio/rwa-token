import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import type { NamedArtifactContractDeploymentFuture } from "@nomicfoundation/ignition-core";

import { activeProfile, IMPLEMENTATION_KEY, type Profile } from "../profiles.js";

/**
 * Stage 1, once per issuer. Everything that does not depend on a product:
 *
 * - The recovery timelock (plain OZ TimelockController, governance as proposer and executor) and the main timelock
 *   (`GovernanceTimelock`: proposer and executor are the governance multisig only; the recovery timelock may revoke
 *   CANCELLER_ROLE there and nothing else). The deployer is the admin of both only until `CoreHandover` finishes.
 * - The registry, administered by the timelock from the start, and the one shared `ComplianceHook` that every product
 *   uses. Its only immutable is the registry, so the council attests one codehash for all of them, and each product's
 *   rules are installed by the product itself when it is placed.
 * - `ProxyDeployer`, which `CoreHandover` moves to the operations account.
 *
 * Then only what the profile's products use:
 *
 * - The `CredentialRegistry` (administered by the deployer until `CoreHandover`) and the `CredentialRule` that reads it.
 *   The rule's codehash covers the registry's address and not its code, so the council reads the registry's code, its
 *   admin and its attester list before it attests the rule.
 * - Each other listed rule, and one implementation per template: every product of a template shares it.
 * - The intent executor and the DvP executor, if a product names them (administered by the deployer until
 *   `CoreHandover`). Neither is attested: neither is a hook, a rule or an implementation, and each token authorises it by
 *   granting it EXECUTOR_ROLE.
 *
 * A fund is not part of the core: an issuer has as many as it needs, each with its own `Fund` module.
 *
 * Next: the council attests the rules, the hook and the implementations, then `CoreHandover`, then a `Fund` for each fund
 * and a `Product` for each product.
 */
export function coreModule(profile: Profile) {
  const rules = new Set(profile.products.flatMap((product) => product.rules));
  const templates = new Set(profile.products.map((product) => product.template));
  const executors = new Set(profile.products.flatMap((product) => product.executors ?? []));

  return buildModule(`Core_${profile.id}`, (m) => {
    const deployer = m.getAccount(0);
    const governance = m.getParameter<string>("governance");
    const council = m.getParameter<string>("council");
    const guardian = m.getParameter<string>("guardian");
    const minDelay = m.getParameter<bigint>("minDelay", 24n * 3_600n);

    // The recovery timelock (same delay, governance proposes and executes, no cancellers, guardian holds nothing)
    // can only unpause and remove the guardian everywhere; deployed first so the main timelock can name it.
    const recoveryTimelock = m.contract("TimelockController", [minDelay, [governance], [governance], deployer], {
      id: "recoveryTimelock",
    });
    const timelock = m.contract("GovernanceTimelock", [minDelay, [governance], [governance], deployer, recoveryTimelock]);
    const registry = m.contract("PolicyRegistry", [timelock, council]);
    const hook = m.contract("ComplianceHook", [registry]);
    const proxyDeployer = m.contract("ProxyDeployer", [deployer, registry]);

    const used: Record<string, NamedArtifactContractDeploymentFuture<string>> = {};
    if (rules.has("credentialRule")) {
      used.credentialRegistry = m.contract("CredentialRegistry", [deployer, guardian]);
      used.credentialRule = m.contract("CredentialRule", [used.credentialRegistry]);
    }
    if (rules.has("minPositionRule")) used.minPositionRule = m.contract("MinPositionRule");
    if (rules.has("holderRestrictionRule")) used.holderRestrictionRule = m.contract("HolderRestrictionRule");
    if (rules.has("windowRule")) used.windowRule = m.contract("SettlementWindowRule");
    if (rules.has("supplyCapRule")) used.supplyCapRule = m.contract("SupplyCapRule");
    if (rules.has("executedOnlyRule")) used.executedOnlyRule = m.contract("ExecutedOnlyRule");
    for (const template of templates) used[IMPLEMENTATION_KEY[template]] = m.contract(template);
    if (executors.has("intent")) used.executor = m.contract("IntentExecutor", [deployer, guardian]);
    if (executors.has("dvp")) used.dvpExecutor = m.contract("DvPExecutor", [deployer, guardian]);

    return { timelock, recoveryTimelock, registry, hook, proxyDeployer, ...used };
  });
}

export default coreModule(activeProfile());
