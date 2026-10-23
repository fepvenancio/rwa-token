import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

import { RULE_ORDER, TOKENS } from "./roles.js";

/**
 * Stage 2 of 3. One `ComplianceHook` per token, bound to the address `ProxyDeployer` will put that token at:
 * CREATE2 over `TokenProxy(implementation, "")` with salt `keccak256(symbol)`. Its admin is the timelock and its
 * initial rules are passed to the constructor, which checks that each one is attested (council step 1 must be done).
 *
 * `TOKEN` is an immutable, so each hook's codehash covers the token it serves: the council attests this hook for this
 * token, one attestation per token. Next: council step 2 (attest the hooks, after reading `hook.rules()`), then
 * `Activate`.
 */
export default buildModule("Tokens", (m) => {
  const timelock = m.getParameter<string>("timelock");
  const registry = m.getParameter<string>("registry");
  const proxyDeployer = m.contractAt("ProxyDeployer", m.getParameter<string>("proxyDeployer"));
  const rules = {
    identityRule: m.getParameter<string>("identityRule"),
    lockupRule: m.getParameter<string>("lockupRule"),
    windowRule: m.getParameter<string>("windowRule"),
    maxHoldersRule: m.getParameter<string>("maxHoldersRule"),
    fundHoldersRule: m.getParameter<string>("fundHoldersRule"),
  };

  const hookFor = (key: keyof typeof TOKENS, implementation: string) => {
    const symbol = m.getParameter<string>(`${key}Symbol`, TOKENS[key].symbol);
    const token = m.staticCall(proxyDeployer, "predict", [symbol, m.getParameter<string>(implementation)], 0, {
      id: `${key}_predict`,
    });
    const ruleList = RULE_ORDER[key].map((name) => rules[name]);
    return m.contract("ComplianceHook", [timelock, registry, token, ruleList], { id: `${key}_hook` });
  };

  return {
    intentHook: hookFor("intent", "intentImpl"),
    fundHook: hookFor("fund", "fundImpl"),
    asyncFundHook: hookFor("asyncFund", "asyncFundImpl"),
  };
});
