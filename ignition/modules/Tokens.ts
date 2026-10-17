import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

import { TOKENS } from "./roles.js";

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
  const identityRule = m.getParameter<string>("identityRule");
  const lockupRule = m.getParameter<string>("lockupRule");
  const windowRule = m.getParameter<string>("windowRule");
  const maxHoldersRule = m.getParameter<string>("maxHoldersRule");

  // Identity → Lockup → SettlementWindow → MaxHolders (brief §6); vaults have no EXECUTED transfers to window.
  const tokenRules = [identityRule, lockupRule, windowRule, maxHoldersRule];
  const vaultRules = [identityRule, lockupRule, maxHoldersRule];

  const hookFor = (key: keyof typeof TOKENS, implementation: string, rules: typeof tokenRules) => {
    const symbol = m.getParameter<string>(`${key}Symbol`, TOKENS[key].symbol);
    const token = m.staticCall(proxyDeployer, "predict", [symbol, m.getParameter<string>(implementation)], 0, {
      id: `${key}_predict`,
    });
    return m.contract("ComplianceHook", [timelock, registry, token, rules], { id: `${key}_hook` });
  };

  return {
    intentHook: hookFor("intent", "intentImpl", tokenRules),
    fundHook: hookFor("fund", "fundImpl", vaultRules),
    asyncFundHook: hookFor("asyncFund", "asyncFundImpl", vaultRules),
  };
});
