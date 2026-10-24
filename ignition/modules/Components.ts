import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Stage 1 of 2. Everything that does not depend on a token address:
 *
 * - The recovery timelock (plain OZ TimelockController, governance as proposer and executor) and the main timelock
 *   (`GovernanceTimelock`: proposer and executor are the governance multisig only; the recovery timelock may revoke
 *   CANCELLER_ROLE there and nothing else). The deployer is the admin of both only until `Activate` finishes.
 * - The registry, administered by the timelock from the start, and the one shared `ComplianceHook` that every token
 *   uses. Its only immutable is the registry, so the council attests one codehash for the whole deployment, and each
 *   token's rules are installed by the token itself when `Activate` initialises it.
 * - The shared rules, one implementation per template, the `ProxyDeployer`, the intent executor and the DvP executor
 *   (both administered by the deployer until `Activate` hands them over). Neither executor is attested: neither is a
 *   hook, a rule or an implementation, and each token authorises it by granting it EXECUTOR_ROLE.
 * - The `Fund` (owned by the deployer until `Activate` hands it over) and the `FundHoldersRule` that points at it. The
 *   rule's codehash covers the fund's address and not the fund's code, so the council reads the fund's code and its
 *   owner before attesting the rule.
 *
 * Next: the council attests the rules, the hook and the implementations (the council step), then `Activate`.
 */
export default buildModule("Components", (m) => {
  const deployer = m.getAccount(0);
  const governance = m.getParameter<string>("governance");
  const council = m.getParameter<string>("council");
  const guardian = m.getParameter<string>("guardian");
  const identityRegistry = m.getParameter<string>("identityRegistry");
  const minDelay = m.getParameter<bigint>("minDelay", 7n * 24n * 3_600n);

  // M-1: the recovery timelock (same delay, governance proposes and executes, no cancellers, guardian holds nothing)
  // can only unpause and remove the guardian everywhere; deployed first so the main timelock can name it.
  const recoveryTimelock = m.contract("TimelockController", [minDelay, [governance], [governance], deployer], {
    id: "recoveryTimelock",
  });
  const timelock = m.contract("GovernanceTimelock", [minDelay, [governance], [governance], deployer, recoveryTimelock]);
  const registry = m.contract("PolicyRegistry", [timelock, council]);
  const hook = m.contract("ComplianceHook", [registry]);

  const identityRule = m.contract("IdentityRule", [identityRegistry]);
  const lockupRule = m.contract("LockupRule");
  const windowRule = m.contract("SettlementWindowRule");
  const maxHoldersRule = m.contract("MaxHoldersRule");
  // The fund and its rule need each other's address, so the rule takes the fund at construction and `Activate` installs
  // the rule in the fund with `setRule`. Not `fund`: that key already means the 4626 vault in these modules.
  const fundContract = m.contract("Fund", [deployer, registry]);
  const fundHoldersRule = m.contract("FundHoldersRule", [fundContract]);

  const intentImpl = m.contract("IntentToken");
  const fundImpl = m.contract("Gated4626Vault");
  const asyncFundImpl = m.contract("Gated7540Vault");

  const proxyDeployer = m.contract("ProxyDeployer", [deployer]);
  const executor = m.contract("IntentExecutor", [deployer, guardian]);
  const dvpExecutor = m.contract("DvPExecutor", [deployer, guardian]);

  return {
    timelock,
    recoveryTimelock,
    registry,
    hook,
    identityRule,
    lockupRule,
    windowRule,
    maxHoldersRule,
    fundContract,
    fundHoldersRule,
    intentImpl,
    fundImpl,
    asyncFundImpl,
    proxyDeployer,
    executor,
    dvpExecutor,
  };
});
