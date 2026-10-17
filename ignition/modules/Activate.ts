import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

import { ROLES, TOKENS } from "./roles.js";

/**
 * Stage 3 of 3. Deploys each token through `ProxyDeployer`, which reverts before creating the proxy unless the hook is
 * bound to it, so every later step (configuration, roles, hand-over) runs only for correctly bound tokens. Then:
 *
 * 1. Configure while the deployer is the tokens' admin: settlement window, holder caps, the 7540 escrow exemption.
 * 2. Grant the operational roles; UPGRADER_ROLE goes to the timelock only; the guardian becomes a timelock canceller.
 * 3. Hand over: DEFAULT_ADMIN_ROLE to the timelock on the tokens and the executor; the deployer renounces everywhere.
 *
 * Outside this module: the identity provider must verify the 7540 vault (it escrows pending redemptions).
 */
export default buildModule("Activate", (m) => {
  const deployer = m.getAccount(0);
  const p = (name: string) => m.getParameter<string>(name);
  const timelockAddress = p("timelock");
  const guardian = p("guardian");
  const registry = p("registry");
  const asset = p("asset");

  const timelock = m.contractAt("TimelockController", timelockAddress);
  const proxyDeployer = m.contractAt("ProxyDeployer", p("proxyDeployer"));
  const executor = m.contractAt("IntentExecutor", p("executor"));
  const windowRule = m.contractAt("SettlementWindowRule", p("windowRule"));
  const maxHoldersRule = m.contractAt("MaxHoldersRule", p("maxHoldersRule"));
  const cap = m.getParameter<bigint>("holderCap");

  // Every token deploy; all configuration and roles wait for all of them, so one mis-bound hook grants nothing anywhere.
  const deploys: ReturnType<typeof m.call>[] = [];

  /** Deploys one token; `initArgs` must carry the symbol and hook that `ProxyDeployer` checks. */
  const deployToken = <Name extends "IntentToken" | "Gated4626Vault" | "Gated7540Vault">(
    key: keyof typeof TOKENS,
    name: Name,
    initArgs: (symbol: ReturnType<typeof p>, hook: ReturnType<typeof p>) => Parameters<typeof m.encodeFunctionCall>[2],
  ) => {
    const symbol = m.getParameter<string>(`${key}Symbol`, TOKENS[key].symbol);
    const hook = p(`${key}Hook`);
    const implementation = m.contractAt(name, p(`${key}Impl`), { id: `${key}_impl` });
    const data = m.encodeFunctionCall(implementation, "initialize", initArgs(symbol, hook), { id: `${key}_init` });
    const deployed = m.call(proxyDeployer, "deploy", [symbol, implementation, data, hook], { id: `${key}_deploy` });
    deploys.push(deployed);
    const proxy = m.readEventArgument(deployed, "ProxyDeployed", "_proxy", { id: `${key}_proxy` });
    return m.contractAt(name, proxy, { id: `${key}_token` });
  };

  const base = (key: keyof typeof TOKENS, symbol: ReturnType<typeof p>, hook: ReturnType<typeof p>) => [
    m.getParameter<string>(`${key}Name`, TOKENS[key].name),
    symbol,
    deployer,
    guardian,
    registry,
    hook,
  ];

  const intent = deployToken("intent", "IntentToken", (symbol, hook) => base("intent", symbol, hook));
  const fund = deployToken("fund", "Gated4626Vault", (symbol, hook) => [asset, ...base("fund", symbol, hook)]);
  const asyncFund = deployToken("asyncFund", "Gated7540Vault", (symbol, hook) => [
    asset,
    ...base("asyncFund", symbol, hook),
    p("custody"),
  ]);
  const tokens = { intent, fund, asyncFund };

  // 1. Configure. Rules authorise these against the token's DEFAULT_ADMIN_ROLE, still held by the deployer.
  const configured = [
    m.call(
      windowRule,
      "setWindow",
      [intent, m.getParameter<number>("windowOpen"), m.getParameter<number>("windowClose"), m.getParameter<number>("windowDays")],
      { after: deploys },
    ),
    ...Object.entries(tokens).map(([key, token]) =>
      m.call(maxHoldersRule, "setCap", [token, cap], { id: `${key}_cap`, after: deploys }),
    ),
    m.call(maxHoldersRule, "setExemptHolder", [asyncFund, asyncFund, true], { after: deploys }),
  ];

  // 2. Roles.
  const grant = (key: string, contract: (typeof tokens)[keyof typeof tokens] | typeof executor | typeof timelock, role: string, to: unknown) =>
    m.call(contract, "grantRole", [role, to as string], { id: `${key}_grant`, after: deploys });
  const granted = [
    grant("intent_minter", intent, ROLES.MINTER, p("minter")),
    grant("intent_burner", intent, ROLES.BURNER, p("burner")),
    grant("intent_executor", intent, ROLES.EXECUTOR, executor),
    grant("asyncFund_fulfiller", asyncFund, ROLES.FULFILLER, p("fulfiller")),
    ...Object.entries(tokens).flatMap(([key, token]) => [
      grant(`${key}_agent`, token, ROLES.AGENT, p("agent")),
      grant(`${key}_upgrader`, token, ROLES.UPGRADER, timelock),
    ]),
    grant("executor_operator", executor, ROLES.OPERATOR, p("operator")),
    grant("timelock_canceller", timelock, ROLES.CANCELLER, guardian),
  ];

  // 3. Hand over, strictly after every call that needs the deployer's admin rights.
  const after = [...configured, ...granted];
  for (const [key, contract] of [...Object.entries(tokens), ["executor", executor] as const]) {
    const handed = m.call(contract, "grantRole", [ROLES.DEFAULT_ADMIN, timelock], { id: `${key}_admin_grant`, after });
    m.call(contract, "renounceRole", [ROLES.DEFAULT_ADMIN, deployer], { id: `${key}_admin_renounce`, after: [handed] });
  }
  m.call(timelock, "renounceRole", [ROLES.DEFAULT_ADMIN, deployer], { id: "timelock_admin_renounce", after });

  return { intent, fund, asyncFund };
});
