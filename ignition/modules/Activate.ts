import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

import { ROLES, RULE_ORDER, TOKENS } from "./roles.js";

/**
 * Stage 2 of 2. Deploys each token through `ProxyDeployer` with the shared hook and the token's rules (`RULE_ORDER`) in
 * its init data. The token installs the rules on the hook itself, and `ProxyDeployer` reverts unless the hook ends up
 * holding exactly those rules for it, so every later step (configuration, roles, hand-over) runs only for tokens that
 * came up as intended. Then:
 *
 * 1. Configure while the deployer is the tokens' admin: the settlement window and each token's minimum position (the
 *    `*MinPosition` parameters, 0 by default, which switches the rule off). There is no per-class holder cap and no
 *    escrow exemption to set: the fund counts investors across classes, and the 7540 vault is the token itself, which
 *    neither the fund rule nor the minimum counts. The fund is configured the same way while the deployer owns it: install its rule, set its cap, then register the
 *    three tokens as classes one after another, so class numbers 1 to 3 are intent, fund, asyncFund. Until a class is
 *    registered every movement on it is rejected, so no balance exists before it is.
 * 2. Grant the operational roles, after the registrations; UPGRADER_ROLE goes to the timelock only; the guardian becomes a timelock canceller;
 *    the recovery timelock gets RECOVERY_ROLE (unpause and revoke GUARDIAN_ROLE only) on every token and both executors.
 *    The intent token's EXECUTOR_ROLE goes to the intent executor and to the DvP executor, and to no one else.
 * 3. Hand over: DEFAULT_ADMIN_ROLE to the timelock on the tokens and both executors; the deployer renounces everywhere,
 *    and `ProxyDeployer` and `Fund` ownership move to the timelock.
 *
 * Outside this module: the identity provider must verify the 7540 vault (it escrows pending redemptions). A gated cash
 * token for the DvP executor is a separate instrument, not deployed here: its administrator grants the DvP executor
 * EXECUTOR_ROLE on it, which for a timelock-administered token is a governance operation.
 */
export default buildModule("Activate", (m) => {
  const deployer = m.getAccount(0);
  const p = (name: string) => m.getParameter<string>(name);
  const timelockAddress = p("timelock");
  const guardian = p("guardian");
  const registry = p("registry");
  const hook = p("hook");
  const asset = p("asset");
  const rules = {
    identityRule: p("identityRule"),
    minPositionRule: p("minPositionRule"),
    holderRestrictionRule: p("holderRestrictionRule"),
    windowRule: p("windowRule"),
    fundHoldersRule: p("fundHoldersRule"),
  };

  const timelock = m.contractAt("GovernanceTimelock", timelockAddress);
  const recoveryTimelock = m.contractAt("TimelockController", p("recoveryTimelock"), { id: "recoveryTimelock" });
  const proxyDeployer = m.contractAt("ProxyDeployer", p("proxyDeployer"));
  const executor = m.contractAt("IntentExecutor", p("executor"));
  const dvpExecutor = m.contractAt("DvPExecutor", p("dvpExecutor"));
  const windowRule = m.contractAt("SettlementWindowRule", p("windowRule"));
  const minPositionRule = m.contractAt("MinPositionRule", p("minPositionRule"));
  const fundContract = m.contractAt("Fund", p("fundContract"));
  const fundCap = m.getParameter<bigint>("fundHolderCap");

  // Every token deploy; all configuration and roles wait for all of them, so one token that fails its checks grants
  // nothing anywhere.
  const deploys: ReturnType<typeof m.call>[] = [];

  /** Deploys one token; `initArgs` must carry the symbol, the hook and the rules that `ProxyDeployer` checks. */
  const deployToken = <Name extends "IntentToken" | "Gated4626Vault" | "Gated7540Vault">(
    key: keyof typeof TOKENS,
    name: Name,
    initArgs: (
      symbol: ReturnType<typeof p>,
      ruleList: ReturnType<typeof p>[],
    ) => Parameters<typeof m.encodeFunctionCall>[2],
  ) => {
    const symbol = m.getParameter<string>(`${key}Symbol`, TOKENS[key].symbol);
    const ruleList = RULE_ORDER[key].map((rule) => rules[rule]);
    const implementation = m.contractAt(name, p(`${key}Impl`), { id: `${key}_impl` });
    const data = m.encodeFunctionCall(implementation, "initialize", initArgs(symbol, ruleList), { id: `${key}_init` });
    const deployed = m.call(proxyDeployer, "deploy", [symbol, implementation, data, hook, ruleList], {
      id: `${key}_deploy`,
    });
    deploys.push(deployed);
    const proxy = m.readEventArgument(deployed, "ProxyDeployed", "_proxy", { id: `${key}_proxy` });
    return m.contractAt(name, proxy, { id: `${key}_token` });
  };

  const base = (key: keyof typeof TOKENS, symbol: ReturnType<typeof p>, ruleList: ReturnType<typeof p>[]) => [
    m.getParameter<string>(`${key}Name`, TOKENS[key].name),
    symbol,
    deployer,
    guardian,
    registry,
    hook,
    ruleList,
  ];

  const intent = deployToken("intent", "IntentToken", (symbol, ruleList) => base("intent", symbol, ruleList));
  const fund = deployToken("fund", "Gated4626Vault", (symbol, ruleList) => [asset, ...base("fund", symbol, ruleList)]);
  // The 7540 initialiser takes the custody after the rules.
  const asyncFund = deployToken("asyncFund", "Gated7540Vault", (symbol, ruleList) => [
    asset,
    ...base("asyncFund", symbol, ruleList),
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
      m.call(minPositionRule, "setMinPosition", [token, m.getParameter<bigint>(`${key}MinPosition`, 0n)], {
        id: `${key}_min`,
        after: deploys,
      }),
    ),
  ];

  // The fund: rule and cap first, then each class in turn (a chain, so the numbering never depends on scheduling).
  const ruleSet = m.call(fundContract, "setRule", [p("fundHoldersRule")], { after: deploys });
  const capSet = m.call(fundContract, "setHolderCap", [fundCap], { after: deploys });
  const registered: ReturnType<typeof m.call>[] = [];
  let previous: ReturnType<typeof m.call>[] = [ruleSet, capSet];
  for (const [key, token] of Object.entries(tokens)) {
    const registration = m.call(fundContract, "registerClass", [token], { id: `${key}_register`, after: previous });
    registered.push(registration);
    previous = [registration];
  }

  // 2. Roles.
  const grant = (
    key: string,
    contract:
      | (typeof tokens)[keyof typeof tokens]
      | typeof executor
      | typeof dvpExecutor
      | typeof timelock
      | typeof recoveryTimelock,
    role: string,
    to: unknown,
  ) =>
    m.call(contract, "grantRole", [role, to as string], { id: `${key}_grant`, after: [...deploys, ...registered] });
  const granted = [
    grant("intent_minter", intent, ROLES.MINTER, p("minter")),
    grant("intent_burner", intent, ROLES.BURNER, p("burner")),
    grant("intent_executor", intent, ROLES.EXECUTOR, executor),
    grant("intent_dvp_executor", intent, ROLES.EXECUTOR, dvpExecutor),
    grant("asyncFund_fulfiller", asyncFund, ROLES.FULFILLER, p("fulfiller")),
    ...Object.entries(tokens).flatMap(([key, token]) => [
      grant(`${key}_agent`, token, ROLES.AGENT, p("agent")),
      grant(`${key}_upgrader`, token, ROLES.UPGRADER, timelock),
    ]),
    grant("executor_operator", executor, ROLES.OPERATOR, p("operator")),
    grant("dvp_operator", dvpExecutor, ROLES.OPERATOR, p("operator")),
    grant("timelock_canceller", timelock, ROLES.CANCELLER, guardian),
    // M-1: the recovery timelock may unpause and remove the guardian on every token and both executors (the main
    // timelock already names it in its constructor for CANCELLER_ROLE revocation).
    ...Object.entries(tokens).map(([key, token]) => grant(`${key}_recovery`, token, ROLES.RECOVERY, recoveryTimelock)),
    grant("executor_recovery", executor, ROLES.RECOVERY, recoveryTimelock),
    grant("dvp_recovery", dvpExecutor, ROLES.RECOVERY, recoveryTimelock),
  ];

  // 3. Hand over, strictly after every call that needs the deployer's admin rights.
  const after = [...configured, ...granted];
  for (const [key, contract] of [
    ...Object.entries(tokens),
    ["executor", executor] as const,
    ["dvpExecutor", dvpExecutor] as const,
  ]) {
    const handed = m.call(contract, "grantRole", [ROLES.DEFAULT_ADMIN, timelock], { id: `${key}_admin_grant`, after });
    m.call(contract, "renounceRole", [ROLES.DEFAULT_ADMIN, deployer], { id: `${key}_admin_renounce`, after: [handed] });
  }
  m.call(timelock, "renounceRole", [ROLES.DEFAULT_ADMIN, deployer], { id: "timelock_admin_renounce", after });
  // The recovery timelock has no cancellers: OZ made governance one as a proposer, so revoke it, then renounce.
  const noCancellers = m.call(recoveryTimelock, "revokeRole", [ROLES.CANCELLER, p("governance")], {
    id: "recovery_no_cancellers",
    after: deploys,
  });
  m.call(recoveryTimelock, "renounceRole", [ROLES.DEFAULT_ADMIN, deployer], {
    id: "recovery_admin_renounce",
    after: [noCancellers],
  });
  // Any later token goes through governance: the deployer EOA can no longer place one.
  m.call(proxyDeployer, "transferOwnership", [timelock], { id: "proxyDeployer_owner", after: deploys });
  // The fund is configured, so it goes to governance too: a later class or rule change is a timelock operation.
  m.call(fundContract, "transferOwnership", [timelock], { id: "fund_owner", after: registered });

  return { intent, fund, asyncFund };
});
