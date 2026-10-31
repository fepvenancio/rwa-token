import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

import { activeProduct, assertUsable, DEFAULT_POLICY, type Product } from "../profiles.js";
import { ROLES } from "./roles.js";

/**
 * Once per product, run by the operations account, which owns `ProxyDeployer` and needs no timelock: a launch only adds a
 * proxy over attested code and touches nothing that exists. The first product and the fiftieth follow this same path.
 *
 * `ProxyDeployer` reverts unless the hook ends up holding exactly the listed rules for the new token, so every later step
 * runs only for a token that came up as intended. Then:
 *
 * 1. Configure while the operations account is the token's admin: its credential policy, settlement window and minimum
 *    position, each if the product lists that rule. A product never touches a fund, so its launch cannot fail on one: a
 *    class is inert, with every movement refused, until `FundOpen` or a timelock operation registers it.
 * 2. Grant the token's roles, after the configuration; UPGRADER_ROLE goes to the timelock only.
 * 3. Hand over: DEFAULT_ADMIN_ROLE to the timelock, and the operations account renounces.
 *
 * Outside this module: the KYC attester must credential a 7540 vault (it escrows pending redemptions) and every holder,
 * and a vault whose asset is gated needs a credential that token's policy accepts.
 */
export function productModule(product: Product) {
  assertUsable(product);

  return buildModule(`Product_${product.key}`, (m) => {
    const p = (name: string) => m.getParameter<string>(name);
    const operations = p("operations");
    const guardian = p("guardian");
    const registry = p("registry");
    const hook = p("hook");
    const timelock = p("timelock");
    const ruleList = product.rules.map((rule) => p(rule));

    const proxyDeployer = m.contractAt("ProxyDeployer", p("proxyDeployer"));
    const implementation = m.contractAt(product.template, p("implementation"), { id: "implementation" });

    const base = [product.name, product.symbol, operations, guardian, registry, hook, ruleList];
    const initArgs =
      product.template === "Gated4626Vault"
        ? [p("asset"), ...base]
        : product.template === "Gated7540Vault"
          ? // The 7540 initialiser takes the custody after the rules.
            [p("asset"), ...base, p("custody")]
          : product.template === "GatedToken" || product.template === "IntentToken"
            ? // Both token templates take their decimals after the symbol.
              [product.name, product.symbol, product.decimals ?? 18, ...base.slice(2)]
            : base;
    const data = m.encodeFunctionCall(implementation, "initialize", initArgs, { id: "init" });
    const deployed = m.call(proxyDeployer, "deploy", [product.symbol, implementation, data, hook, ruleList], { id: "deploy" });
    const proxy = m.readEventArgument(deployed, "ProxyDeployed", "_proxy", { id: "proxy" });
    const token = m.contractAt(product.template, proxy, { id: "token" });

    // 1. Configure. Rules authorise these against the token's DEFAULT_ADMIN_ROLE, still held by the operations account.
    const configured: ReturnType<typeof m.call>[] = [];
    if (product.rules.includes("credentialRule")) {
      const policy = product.policy ?? DEFAULT_POLICY;
      const credentialRule = m.contractAt("CredentialRule", p("credentialRule"));
      configured.push(
        m.call(credentialRule, "setPolicy", [token, policy.requireAll, policy.requireAny, policy.forbidAny, policy.attesters], {
          after: [deployed],
        }),
      );
    }
    if (product.rules.includes("minPositionRule")) {
      const minPositionRule = m.contractAt("MinPositionRule", p("minPositionRule"));
      configured.push(
        m.call(minPositionRule, "setMinPosition", [token, m.getParameter<bigint>("minPosition", 0n)], { after: [deployed] }),
      );
    }
    if (product.rules.includes("windowRule")) {
      const windowRule = m.contractAt("SettlementWindowRule", p("windowRule"));
      configured.push(
        m.call(
          windowRule,
          "setWindow",
          [token, m.getParameter<number>("windowOpen"), m.getParameter<number>("windowClose"), m.getParameter<number>("windowDays")],
          { after: [deployed] },
        ),
      );
    }

    // 2. Roles.
    const grant = (key: string, role: string, to: unknown) =>
      m.call(token, "grantRole", [role, to as string], { id: `${key}_grant`, after: [deployed, ...configured] });
    const granted = [
      grant("agent", ROLES.AGENT, p("agent")),
      grant("upgrader", ROLES.UPGRADER, timelock),
      grant("recovery", ROLES.RECOVERY, p("recoveryTimelock")),
    ];
    if (product.template === "GatedToken" || product.template === "IntentToken") {
      granted.push(grant("minter", ROLES.MINTER, p("minter")), grant("burner", ROLES.BURNER, p("burner")));
    }
    if (product.template === "Gated7540Vault") granted.push(grant("fulfiller", ROLES.FULFILLER, p("fulfiller")));
    if (product.executors?.includes("intent")) granted.push(grant("executor", ROLES.EXECUTOR, p("executor")));
    if (product.executors?.includes("dvp")) granted.push(grant("dvp_executor", ROLES.EXECUTOR, p("dvpExecutor")));

    // 3. Hand over, strictly after every call that needs the admin rights.
    const handed = m.call(token, "grantRole", [ROLES.DEFAULT_ADMIN, timelock], { id: "admin_grant", after: granted });
    m.call(token, "renounceRole", [ROLES.DEFAULT_ADMIN, operations], { id: "admin_renounce", after: [handed] });

    return { token };
  });
}

export default productModule(activeProduct());
