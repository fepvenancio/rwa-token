import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Stage 1 of 3. Everything that does not depend on a token address:
 *
 * - The timelock: proposer and executor are the governance multisig only. The deployer is its admin only until
 *   `Activate` grants the guardian CANCELLER_ROLE, then it renounces.
 * - The registry, administered by the timelock from the start.
 * - The shared rules, one implementation per template, the `ProxyDeployer`, and the intent executor (administered by
 *   the deployer until `Activate` hands it over).
 *
 * Next: the council attests the rules and implementations (council step 1), then `Tokens`.
 */
export default buildModule("Components", (m) => {
  const deployer = m.getAccount(0);
  const governance = m.getParameter<string>("governance");
  const council = m.getParameter<string>("council");
  const guardian = m.getParameter<string>("guardian");
  const identityRegistry = m.getParameter<string>("identityRegistry");
  const minDelay = m.getParameter<bigint>("minDelay", 7n * 24n * 3_600n);

  const timelock = m.contract("TimelockController", [minDelay, [governance], [governance], deployer]);
  const registry = m.contract("PolicyRegistry", [timelock, council]);

  const identityRule = m.contract("IdentityRule", [identityRegistry]);
  const lockupRule = m.contract("LockupRule");
  const windowRule = m.contract("SettlementWindowRule");
  const maxHoldersRule = m.contract("MaxHoldersRule");

  const intentImpl = m.contract("IntentToken");
  const fundImpl = m.contract("Gated4626Vault");
  const asyncFundImpl = m.contract("Gated7540Vault");

  const proxyDeployer = m.contract("ProxyDeployer", [deployer]);
  const executor = m.contract("IntentExecutor", [deployer, guardian]);

  return {
    timelock,
    registry,
    identityRule,
    lockupRule,
    windowRule,
    maxHoldersRule,
    intentImpl,
    fundImpl,
    asyncFundImpl,
    proxyDeployer,
    executor,
  };
});
