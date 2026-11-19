// SPDX-License-Identifier: UNLICENSED
/**
 * The parts of a core that follow from its products, and their hand-over. `Core` and `CoreHandover` use them for a whole
 * deployment; `ignition/modules/CoreParts.ts` and `PartsHandover.ts` use them to add parts to a core that already runs.
 * Kept out of the module files, which build their default export from the environment when imported.
 */
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import type { CallableContractFuture, ContractCallFuture, IgnitionModuleBuilder, NamedArtifactContractDeploymentFuture } from "@nomicfoundation/ignition-core";

import { IMPLEMENTATION_KEY, PART_KEYS, type Template } from "./profiles.js";
import { ROLES } from "./modules/roles.js";

/** The contract each rule part deploys. `credentialRule` also deploys the `CredentialRegistry` it reads. */
const RULE_CONTRACTS: Record<string, string> = {
  minPositionRule: "MinPositionRule",
  holderRestrictionRule: "HolderRestrictionRule",
  windowRule: "SettlementWindowRule",
  supplyCapRule: "SupplyCapRule",
  executedOnlyRule: "ExecutedOnlyRule",
};

/** The template each implementation part deploys. */
const TEMPLATE_OF = Object.fromEntries(Object.entries(IMPLEMENTATION_KEY).map(([template, key]) => [key, template as Template]));

/**
 * Deploys the parts named, inside the module being built: `Core` for a whole deployment, `CoreParts` for a running core.
 * The credential registry and the executors take the deployer as their admin until a hand-over gives it to the timelock.
 */
export function deployParts(m: IgnitionModuleBuilder, parts: readonly string[]) {
  const deployer = m.getAccount(0);
  const guardian = m.getParameter<string>("guardian");
  const used: Record<string, NamedArtifactContractDeploymentFuture<string>> = {};
  for (const part of parts) {
    if (part === "credentialRule") {
      used.credentialRegistry = m.contract("CredentialRegistry", [deployer, guardian]);
      used.credentialRule = m.contract("CredentialRule", [used.credentialRegistry]);
    } else if (RULE_CONTRACTS[part] !== undefined) used[part] = m.contract(RULE_CONTRACTS[part]);
    else if (TEMPLATE_OF[part] !== undefined) used[part] = m.contract(TEMPLATE_OF[part]);
    else if (part === "executor") used.executor = m.contract("IntentExecutor", [deployer, guardian]);
    else if (part === "dvpExecutor") used.dvpExecutor = m.contract("DvPExecutor", [deployer, guardian]);
    else if (part === "signedEntry") used.signedEntry = m.contract("SignedEntry");
    else if (part === "signedExit") used.signedExit = m.contract("SignedExit");
    else throw new Error(`${part} is not a part of a core`);
  }
  return used;
}

/**
 * Adds parts to a core that already runs, for a product it was not built for: a rule, a template's implementation, an
 * executor, the signed entry or the signed exit. The timelocks, the registry, the hook and `ProxyDeployer` stay as they are, so the new
 * product joins the issuer's one stack. `present` is what the core already has, and naming a part in it throws. The
 * command line computes `parts` as what `CORE_HAS` does not list, so `CORE_HAS` must list the core's parts exactly. Run by
 * any account, which administers the new credential registry and executors only until `PartsHandover`.
 *
 * Next: the council attests the new rules and implementations, then `PartsHandover`, then the product.
 */
export function corePartsModule(parts: readonly string[], present: readonly string[]) {
  if (parts.length === 0) throw new Error("nothing to add: the core has every part these products need");
  for (const part of parts) if (present.includes(part)) throw new Error(`${part} is already in the core`);
  return buildModule(`CoreParts_${parts.join("_")}`, (m) => deployParts(m, parts));
}

type Contract = CallableContractFuture<string>;

/**
 * The hand-over of the parts that have an admin, inside the module being built: `CoreHandover` for a whole deployment,
 * `PartsHandover` for parts added to a running core. The credential registry gets its first attester and the recovery
 * timelock's RECOVERY_ROLE; each executor gets its operator and RECOVERY_ROLE; then DEFAULT_ADMIN_ROLE goes to the timelock
 * and the deployer renounces. Returns the calls that need the deployer's rights, which a caller's own hand-over must follow.
 */
export function handOverParts(m: IgnitionModuleBuilder, parts: readonly string[], timelock: Contract, recoveryTimelock: Contract) {
  const deployer = m.getAccount(0);
  const p = (name: string) => m.getParameter<string>(name);
  const calls: ContractCallFuture<string, string>[] = [];
  const administered: { key: string; contract: Contract }[] = [];
  const grant = (key: string, contract: Contract, role: string, to: unknown) =>
    calls.push(m.call(contract, "grantRole", [role, to as string], { id: `${key}_grant` }));

  if (parts.includes("credentialRule")) {
    const credentials = m.contractAt("CredentialRegistry", p("credentialRegistry"));
    // The one attester is the issuer's KYC function, id 0. It may assert the ten named qualification bits unless the
    // deployment narrows that.
    calls.push(m.call(credentials, "addAttester", [p("kycAttester"), m.getParameter<number>("kycAllowedQuals", 1023)]));
    grant("credentials_recovery", credentials, ROLES.RECOVERY, recoveryTimelock);
    administered.push({ key: "credentials", contract: credentials });
  }
  if (parts.includes("executor")) {
    const executor = m.contractAt("IntentExecutor", p("executor"));
    grant("executor_operator", executor, ROLES.OPERATOR, p("operator"));
    grant("executor_recovery", executor, ROLES.RECOVERY, recoveryTimelock);
    administered.push({ key: "executor", contract: executor });
  }
  if (parts.includes("dvpExecutor")) {
    const dvpExecutor = m.contractAt("DvPExecutor", p("dvpExecutor"));
    grant("dvp_operator", dvpExecutor, ROLES.OPERATOR, p("operator"));
    grant("dvp_recovery", dvpExecutor, ROLES.RECOVERY, recoveryTimelock);
    administered.push({ key: "dvpExecutor", contract: dvpExecutor });
  }

  // Hand over, strictly after every call that needs the deployer's admin rights.
  for (const { key, contract } of administered) {
    const handed = m.call(contract, "grantRole", [ROLES.DEFAULT_ADMIN, timelock], { id: `${key}_admin_grant`, after: calls });
    m.call(contract, "renounceRole", [ROLES.DEFAULT_ADMIN, deployer], { id: `${key}_admin_renounce`, after: [handed] });
  }
  return calls;
}

/**
 * After `CoreParts` and the council's attestations, run by the account that ran `CoreParts`: the new parts' roles and their
 * hand-over to the timelock, as `CoreHandover` does for a whole deployment. Rules, implementations, the signed entry and the signed exit
 * have no admin, so they need nothing here.
 */
export function partsHandoverModule(parts: readonly string[]) {
  if (parts.length === 0) throw new Error("nothing to hand over: no part was added");
  return buildModule(`PartsHandover_${parts.join("_")}`, (m) => {
    const timelock = m.contractAt("GovernanceTimelock", m.getParameter<string>("timelock"));
    const recoveryTimelock = m.contractAt("GovernanceTimelock", m.getParameter<string>("recoveryTimelock"), { id: "recoveryTimelock" });
    handOverParts(m, parts, timelock, recoveryTimelock);
    return {};
  });
}

/** The contracts every core has, which `CORE_HAS` may also name. */
const CORE_CONTRACTS: readonly string[] = ["timelock", "recoveryTimelock", "registry", "hook", "proxyDeployer", "credentialRegistry"];

/**
 * The parts a running core has, from `CORE_HAS` (keys separated by commas), for the command line. A list that is unset or
 * names nothing is refused: it would read every part as missing and deploy them all again, a second credential registry
 * among them. So is an unknown key, which would leave its part read as missing.
 */
export function coreHas(): string[] {
  const listed = (process.env.CORE_HAS ?? "").split(",").map((part) => part.trim()).filter((part) => part !== "");
  if (listed.length === 0) throw new Error("CORE_HAS must list the running core's parts, separated by commas");
  for (const part of listed) {
    if (!CORE_CONTRACTS.includes(part) && !PART_KEYS.includes(part)) throw new Error(`${part} is not a part of a core`);
  }
  return listed;
}
