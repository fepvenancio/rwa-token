// SPDX-License-Identifier: UNLICENSED
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

import { toFunctionSelector, zeroAddress } from "viem";

import { activeProduct, activeProfile, assertUsable, type Caps, DEFAULT_POLICY, type Product } from "../profiles.js";
import { ROLES } from "./roles.js";

/** The one function a custodian's `GuardedAccount` may call on the asset. */
const TRANSFER = toFunctionSelector("transfer(address,uint256)");

/**
 * Once per product, run by the operations account, which owns `ProxyDeployer` and needs no timelock: a launch only adds a
 * proxy over attested code and touches nothing that exists. The first product and the fiftieth follow this same path.
 *
 * `ProxyDeployer` reverts unless the hook ends up holding exactly the listed rules for the new token, so every later step
 * runs only for a token that came up as intended. Then:
 *
 * 1. Configure while the operations account is the token's admin: its credential policy, settlement window, minimum
 *    position (with the profile's lien vault exempt from it) and supply cap, each if the product lists that rule, and the legos `Legos` deployed and the council attested:
 *    the portfolio's adapters, caps and permissions, and the desk or the vault's plugs. A product never touches a fund, so
 *    its launch cannot fail on one: a class is inert, with every movement refused, until `FundOpen` or a timelock operation
 *    registers it.
 * 2. Grant the token's roles, after the configuration; UPGRADER_ROLE goes to the timelock only. A product with a
 *    `Distributor` grants its maker and its checker on the token, which the distributor asks at call time.
 * 3. Hand over: DEFAULT_ADMIN_ROLE to the timelock, and the operations account renounces.
 *
 * Outside this module: the KYC attester must credential every holder, a vault whose asset is gated needs a credential
 * that token's policy accepts, and a feeder class needs two on its master, for its adapter and for its portfolio.
 */
export function productModule(product: Product, lienVault = false) {
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
      product.template === "Gated4626Vault" || product.template === "Gated7540Vault"
        ? [p("asset"), ...base]
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
      // The escrow pools every pledgor's tokens, so a minimum cannot judge it, as it cannot judge any pooling account.
      if (lienVault) configured.push(m.call(minPositionRule, "setExempt", [token, p("lienVault"), true], { id: "lien_vault_exempt", after: [deployed] }));
    }
    if (product.rules.includes("supplyCapRule")) {
      const supplyCapRule = m.contractAt("SupplyCapRule", p("supplyCapRule"));
      configured.push(m.call(supplyCapRule, "setSupplyCap", [token, m.getParameter<bigint>("supplyCap")], { after: [deployed] }));
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

    // The legos, plugged in under the same admin rights. The vault-side plugs refuse what the council has not attested.
    const portfolio = product.portfolio === undefined ? undefined : m.contractAt("Portfolio", p("portfolio"));
    const desk = product.nav === undefined ? undefined : m.contractAt("NavDesk", p("navDesk"));
    if (portfolio !== undefined) {
      // Every adapter names its own risk id, and the caps are set against that.
      const install = (template: "GuardedAccount" | "ERC4626Adapter", name: string, caps: Caps) => {
        const adapter = m.contractAt(template, p(name), { id: name });
        const added = m.call(portfolio, "addAdapter", [adapter], { id: `add_${name}`, after: [deployed] });
        const riskId = m.staticCall(adapter, "RISK_ID", [], 0, { id: `risk_${name}` });
        configured.push(added, m.call(portfolio, "setCaps", [riskId, caps.absoluteCap, caps.relativeCapBps], { id: `caps_${name}`, after: [added] }));
        return adapter;
      };
      for (const custodian of product.portfolio?.custodians ?? []) {
        const account = install("GuardedAccount", `account_${custodian.key}`, custodian);
        configured.push(
          m.call(account, "setPermission", [p("asset"), TRANSFER, p(`validator_${custodian.key}`)], { id: `permit_${custodian.key}`, after: [deployed] }),
        );
      }
      // A `Gated4626Adapter` is an `ERC4626Adapter`, and this module reads only `RISK_ID` from it.
      for (const target of product.portfolio?.targets ?? []) install("ERC4626Adapter", `adapter_${target.key}`, target);
    }
    if (desk !== undefined) {
      const { periodLength, cooldown, maxReportAge } = product.nav!;
      if (portfolio !== undefined) {
        configured.push(m.call(desk, "setSettings", [portfolio, zeroAddress, periodLength, cooldown, maxReportAge], { after: [deployed] }));
      }
      if (product.fees !== undefined) configured.push(m.call(desk, "setFeeModel", [p("feeModel")], { after: [deployed] }));
      if (product.nav!.redemptionGateBps !== undefined) {
        configured.push(m.call(desk, "setRedemptionGate", [product.nav!.redemptionGateBps], { after: [deployed] }));
      }
    } else if (portfolio !== undefined) {
      const vault = m.contractAt("Gated4626Vault", proxy, { id: "vaultPlugs" });
      const plugged = m.call(vault, "setPortfolio", [portfolio, product.portfolio!.maxRateBps!], { after: [deployed] });
      configured.push(plugged);
      if (product.fees !== undefined) configured.push(m.call(vault, "setFeeModel", [p("feeModel")], { after: [plugged] }));
    }

    // 2. Roles.
    const grant = (key: string, role: string, to: unknown) =>
      m.call(token, "grantRole", [role, to as string], { id: `${key}_grant`, after: [deployed, ...configured] });
    const granted = [
      grant("agent", ROLES.AGENT, p("agent")),
      grant("upgrader", ROLES.UPGRADER, timelock),
      grant("recovery", ROLES.RECOVERY, p("recoveryTimelock")),
    ];
    if (product.template === "GatedToken" || product.template === "IntentToken" || product.template === "Gated721" || product.template === "Gated1155") {
      granted.push(grant("minter", ROLES.MINTER, p("minter")), grant("burner", ROLES.BURNER, p("burner")));
    }
    if (product.template === "Gated7540Vault") granted.push(grant("settler", ROLES.SETTLER, desk ?? p("settler")));
    if (desk !== undefined) granted.push(grant("reporter", ROLES.REPORTER, p("reporter")));
    // One checker approves the desk's prices and the distributions, never a price or a distribution of its own.
    if (desk !== undefined || product.distributor === true) granted.push(grant("checker", ROLES.CHECKER, p("checker")));
    if (product.distributor === true) granted.push(grant("distribution_maker", ROLES.DISTRIBUTION_MAKER, p("distributionMaker")));
    if (portfolio !== undefined) granted.push(grant("allocator", ROLES.ALLOCATOR, p("allocator")));
    if (product.executors?.includes("intent")) granted.push(grant("executor", ROLES.EXECUTOR, p("executor")));
    if (product.executors?.includes("dvp")) granted.push(grant("dvp_executor", ROLES.EXECUTOR, p("dvpExecutor")));

    // 3. Hand over, strictly after every call that needs the admin rights.
    const handed = m.call(token, "grantRole", [ROLES.DEFAULT_ADMIN, timelock], { id: "admin_grant", after: granted });
    m.call(token, "renounceRole", [ROLES.DEFAULT_ADMIN, operations], { id: "admin_renounce", after: [handed] });

    return { token };
  });
}

export default productModule(activeProduct(), activeProfile().lienVault === true);
