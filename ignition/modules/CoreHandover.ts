import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

import { activeProfile, type Profile } from "../profiles.js";
import { ROLES } from "./roles.js";

/**
 * Stage 2, once per bank, after the council has attested the core. It takes the addresses `Core` produced as parameters.
 *
 * 1. Configure what only the deployer can: the first KYC attester, and the fund's rule and cap.
 * 2. Grant the core's roles: the guardian becomes a timelock canceller; the recovery timelock gets RECOVERY_ROLE (unpause
 *    and revoke GUARDIAN_ROLE only) on the credential registry, where it also clears a guardian block and revives an
 *    attester, and on the executors; the executors get their operator.
 * 3. Hand over: DEFAULT_ADMIN_ROLE to the timelock on the credential registry and the executors, and the deployer
 *    renounces everywhere. `ProxyDeployer` and the fund go to the operations account: products then launch without
 *    waiting, and `FundHandover` moves the fund to the timelock once its classes are in.
 *
 * Next: a `Product` for each product, run by the operations account.
 */
export function coreHandoverModule(profile: Profile) {
  const rules = new Set(profile.products.flatMap((product) => product.rules));
  const executors = new Set(profile.products.flatMap((product) => product.executors ?? []));

  return buildModule(`CoreHandover_${profile.id}`, (m) => {
    const deployer = m.getAccount(0);
    const p = (name: string) => m.getParameter<string>(name);
    const guardian = p("guardian");
    const operations = p("operations");

    const timelock = m.contractAt("GovernanceTimelock", p("timelock"));
    const recoveryTimelock = m.contractAt("TimelockController", p("recoveryTimelock"), { id: "recoveryTimelock" });
    const proxyDeployer = m.contractAt("ProxyDeployer", p("proxyDeployer"));

    const configured: ReturnType<typeof m.call>[] = [];
    const granted: ReturnType<typeof m.call>[] = [];
    /** Grants the role, and later hands the contract's admin to the timelock. */
    const administered: { key: string; contract: Parameters<typeof m.call>[0] }[] = [];

    const grant = (key: string, contract: Parameters<typeof m.call>[0], role: string, to: unknown) =>
      granted.push(m.call(contract, "grantRole", [role, to as string], { id: `${key}_grant` }));

    grant("timelock_canceller", timelock, ROLES.CANCELLER, guardian);

    if (rules.has("credentialRule")) {
      const credentials = m.contractAt("CredentialRegistry", p("credentialRegistry"));
      // The one attester is the bank's KYC function, id 0. It may assert the eight named qualification bits unless the
      // deployment narrows that.
      configured.push(
        m.call(credentials, "addAttester", [p("kycAttester"), m.getParameter<number>("kycAllowedQuals", 255)]),
      );
      grant("credentials_recovery", credentials, ROLES.RECOVERY, recoveryTimelock);
      administered.push({ key: "credentials", contract: credentials });
    }

    if (executors.has("intent")) {
      const executor = m.contractAt("IntentExecutor", p("executor"));
      grant("executor_operator", executor, ROLES.OPERATOR, p("operator"));
      grant("executor_recovery", executor, ROLES.RECOVERY, recoveryTimelock);
      administered.push({ key: "executor", contract: executor });
    }
    if (executors.has("dvp")) {
      const dvpExecutor = m.contractAt("DvPExecutor", p("dvpExecutor"));
      grant("dvp_operator", dvpExecutor, ROLES.OPERATOR, p("operator"));
      grant("dvp_recovery", dvpExecutor, ROLES.RECOVERY, recoveryTimelock);
      administered.push({ key: "dvpExecutor", contract: dvpExecutor });
    }

    if (rules.has("fundHoldersRule")) {
      const fund = m.contractAt("Fund", p("fundContract"));
      const ruleSet = m.call(fund, "setRule", [p("fundHoldersRule")]);
      const capSet = m.call(fund, "setHolderCap", [m.getParameter<bigint>("fundHolderCap")]);
      m.call(fund, "transferOwnership", [operations], { id: "fund_owner", after: [ruleSet, capSet] });
    }

    // Hand over, strictly after every call that needs the deployer's admin rights.
    const after = [...configured, ...granted];
    for (const { key, contract } of administered) {
      const handed = m.call(contract, "grantRole", [ROLES.DEFAULT_ADMIN, timelock], { id: `${key}_admin_grant`, after });
      m.call(contract, "renounceRole", [ROLES.DEFAULT_ADMIN, deployer], { id: `${key}_admin_renounce`, after: [handed] });
    }
    m.call(timelock, "renounceRole", [ROLES.DEFAULT_ADMIN, deployer], { id: "timelock_admin_renounce", after });
    // The recovery timelock has no cancellers: OZ made governance one as a proposer, so revoke it, then renounce.
    const noCancellers = m.call(recoveryTimelock, "revokeRole", [ROLES.CANCELLER, p("governance")], {
      id: "recovery_no_cancellers",
    });
    m.call(recoveryTimelock, "renounceRole", [ROLES.DEFAULT_ADMIN, deployer], {
      id: "recovery_admin_renounce",
      after: [noCancellers],
    });
    m.call(proxyDeployer, "transferOwnership", [operations], { id: "proxyDeployer_owner" });

    return {};
  });
}

export default coreHandoverModule(activeProfile());
