// SPDX-License-Identifier: UNLICENSED
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

import { activeProfile, partsOf, type Profile } from "../profiles.js";
import { handOverParts } from "../parts.js";
import { ROLES } from "./roles.js";

/**
 * Stage 2, once per issuer, after the council has attested the core. It takes the addresses `Core` produced as parameters.
 *
 * 1. Configure what only the deployer can: the first KYC attester.
 * 2. Grant the core's roles: the guardian becomes a timelock canceller; the recovery timelock gets RECOVERY_ROLE on the
 *    credential registry (clear a guardian block, revive an attester, revoke GUARDIAN_ROLE) and on the executors (unpause
 *    and revoke GUARDIAN_ROLE); the executors get their operator.
 * 3. Hand over: DEFAULT_ADMIN_ROLE to the timelock on the credential registry and the executors, and the deployer
 *    renounces everywhere. `ProxyDeployer` goes to the operations account: products then launch without waiting.
 *
 * Steps 1 to 3 for the credential registry and the executors are `handOverParts`, which `PartsHandover` also runs for parts
 * added to a running core. A core on an external credential registry has none of its own to configure or hand over.
 *
 * Next: a `Fund` for each fund and a `Product` for each product, run by the operations account, then a `FundOpen` for each
 * fund.
 */
export function coreHandoverModule(profile: Profile) {
  return buildModule(`CoreHandover_${profile.id}`, (m) => {
    const deployer = m.getAccount(0);
    const p = (name: string) => m.getParameter<string>(name);

    const timelock = m.contractAt("GovernanceTimelock", p("timelock"));
    const recoveryTimelock = m.contractAt("GovernanceTimelock", p("recoveryTimelock"), { id: "recoveryTimelock" });
    const proxyDeployer = m.contractAt("ProxyDeployer", p("proxyDeployer"));

    const canceller = m.call(timelock, "grantRole", [ROLES.CANCELLER, p("guardian")], { id: "timelock_canceller_grant" });
    const after = [canceller, ...handOverParts(m, partsOf(profile), timelock, recoveryTimelock)];

    m.call(timelock, "renounceRole", [ROLES.DEFAULT_ADMIN, deployer], { id: "timelock_admin_renounce", after });
    // The recovery timelock has no cancellers: OZ made governance one as a proposer, so revoke it, then renounce.
    const noCancellers = m.call(recoveryTimelock, "revokeRole", [ROLES.CANCELLER, p("governance")], {
      id: "recovery_no_cancellers",
    });
    m.call(recoveryTimelock, "renounceRole", [ROLES.DEFAULT_ADMIN, deployer], {
      id: "recovery_admin_renounce",
      after: [noCancellers],
    });
    m.call(proxyDeployer, "transferOwnership", [p("operations")], { id: "proxyDeployer_owner" });

    return {};
  });
}

export default coreHandoverModule(activeProfile());
