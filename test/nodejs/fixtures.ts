import assert from "node:assert/strict";

import hre from "hardhat";
import type { NetworkConnection } from "hardhat/types/network";
import {
  BaseError,
  ContractFunctionRevertedError,
  decodeErrorResult,
  encodeAbiParameters,
  encodeFunctionData,
  hashTypedData,
  isAddressEqual,
  keccak256,
  maxUint256,
  pad,
  toFunctionSelector,
  toHex,
  type Abi,
  type Account,
  type Address,
  type Hex,
  zeroAddress,
  parseAbi,
} from "viem";

import { coreModule } from "../../ignition/modules/Core.js";
import { hasLegos, legosModule } from "../../ignition/modules/Legos.js";
import { coreHandoverModule } from "../../ignition/modules/CoreHandover.js";
import { fundModule } from "../../ignition/modules/Fund.js";
import { fundOpenModule } from "../../ignition/modules/FundOpen.js";
import { productModule } from "../../ignition/modules/Product.js";
import { QUALS, ROLES } from "../../ignition/modules/roles.js";
import {
  classesOf,
  DEFAULT_POLICY,
  fundsOf,
  IMPLEMENTATION_KEY,
  PROFILES,
  type Product,
  type Profile,
  type Template,
} from "../../ignition/profiles.js";

/**
 * Runs the production deployment: the Ignition modules, which are where deployment order lives (Phase 6 Q2), with this
 * file playing the parties Ignition cannot sign for:
 *
 *   Core → council attests rules, the hook and implementations → CoreHandover → a Fund for each fund, whose rule the
 *   council attests → a Product for each product → a FundOpen for each fund → hand-over check. The operations account runs
 *   everything after CoreHandover.
 *
 * Each stage gets the previous stage's addresses as parameters, as a live deployment does between council steps
 * (Ignition is also ephemeral per `deploy` call on the in-process network, so stages cannot share a journal here).
 */

const REASON_NAMES = [
  "TRANSFER_OK",
  "PAUSED",
  "INSUFFICIENT_UNFROZEN",
  "SENDER_NOT_VERIFIED",
  "RECEIVER_NOT_VERIFIED",
  "OUTSIDE_SETTLEMENT_WINDOW",
  "MAX_HOLDERS",
  "LOCKED",
  "INTENT_EXPIRED",
  "NONCE_USED",
  "BAD_SIGNATURE",
  "NO_HOOK",
  "NO_RULES",
  "NOT_FUND_CLASS",
  "WRONG_EXECUTOR",
  "INTENT_NOT_YET_VALID",
  "CONSIDERATION_NEEDS_EXECUTOR",
  "LEGS_DO_NOT_MATCH",
  "BELOW_MIN_POSITION",
  "SENDER_FROZEN",
  "RECEIVER_FROZEN",
  "CREDENTIAL_EXPIRED",
  "RECEIVER_NOT_ELIGIBLE",
  "NOT_EXECUTOR",
  "ZERO_RECEIVER",
  "ABOVE_SUPPLY_CAP",
  "TRANSFER_NOT_EXECUTED",
] as const;

/** `Errors.sol` reason codes, keyed by name; `reasonName` maps a code back for readable assertions. */
export const REASONS = Object.fromEntries(REASON_NAMES.map((name) => [name, keccak256(toHex(name))])) as Record<
  (typeof REASON_NAMES)[number],
  Hex
>;
export const reasonName = (code: Hex) => REASON_NAMES.find((name) => REASONS[name] === code) ?? code;

/** Mon 2026-10-12 00:00 UTC plus 260 weeks: a Monday in 2031, safely after the local chain's wall clock. */
export const MONDAY = 1_791_763_200n + 260n * 7n * 86_400n;
const MONDAY_10AM = MONDAY + 10n * 3_600n;
export const WINDOW_OPEN = 9 * 3_600;
export const WINDOW_CLOSE = 17 * 3_600;
/** The fund-wide investor cap, one number for the three demo classes. */
export const FUND_HOLDER_CAP = 3n;

const LEGO_ABI = parseAbi([
  "function VAULT() view returns (address)",
  "function portfolio() view returns (address)",
  "function feeModel() view returns (address)",
  "function adapters() view returns (address[])",
  "function SETTLEMENT_LOGIC() view returns (address)",
  "function redemptionGate() view returns (uint256)",
]);
const SAFE_ABI = parseAbi(["function getThreshold() view returns (uint256)"]);
const ACCOUNT_ABI = parseAbi([
  "function RISK_ID() view returns (bytes32)",
  "function validatorOf(address, bytes4) view returns (address)",
  "function MAX_PER_CALL() view returns (uint256)",
  "function riskOf(bytes32) view returns ((uint120 allocation, uint120 absoluteCap, uint16 relativeCapBps))",
]);
/** The one function a custodian's account may call on the asset. */
const TRANSFER = toFunctionSelector("transfer(address,uint256)");
const ATTEST = { HOOK: 1, RULE: 2, IMPLEMENTATION: 3, PORTFOLIO: 4, ADAPTER: 5, VALIDATOR: 6, FEE_MODEL: 7 } as const;
/** The timelocks' delay: the least the hand-over check accepts. */
const DAY = 86_400n;

/** The qualification bits, from the deployment's own copy of `Quals.sol` (`InterfaceFreeze` pins the Solidity side). */
export { QUALS };
/** `ICredentialRegistry.Status`, as the registry returns it. `LAPSED` is only ever returned, never stored. */
export const STATUS = { NONE: 0, ACTIVE: 1, EXIT_ONLY: 2, BLOCKED: 3, LAPSED: 4 } as const;
/** How long the demo credentials last: far past anything a test does with the clock. Tests of expiry write their own. */
export const DEMO_VALIDITY = 3_650n * 86_400n;

export async function deployStack(connection: NetworkConnection) {
  const { launch, parameters } = await deployUntilProducts(connection);
  return launch(parameters);
}

/** Any profile, from the core to its last product, with no holder verified yet. */
export async function deployProfile(connection: NetworkConnection, profile: Profile, overrides: Parameters_ = {}) {
  const { launch, parameters } = await stages(connection, profile);
  return launch({ ...parameters, ...overrides });
}

/** A later product on a stack that is already handed over, run by the operations account. */
export const deployProduct = (s: ProfileStack, product: Product) => s.place(product);

/**
 * The demo stack up to the council step. Returns the parameters and a function that runs the rest and finishes the
 * deployment, so a test can run it on tampered parameters and inspect what was left behind.
 */
export async function deployUntilProducts(connection: NetworkConnection) {
  const { viem } = connection;
  const stage = await stages(connection, PROFILES.full);

  const launch = async (parameters: Parameters_) => {
    const s = await stage.launch(parameters);
    const { alice, bob, carol, dave } = s.holders;
    const validUntil = (await s.publicClient.getBlock()).timestamp + DEMO_VALIDITY;
    // The KYC attester vouches for the holders used by the tests and the recovery account.
    for (const w of [alice, bob, carol, dave, s.wallets.recovery]) {
      await s.credentials!.write.set([w.account.address, validUntil, QUALS.KYC], { account: s.wallets.kyc.account });
    }
    return {
      ...s,
      credentials: s.credentials!,
      fund: s.fund!,
      executor: s.executor!,
      dvpExecutor: s.dvpExecutor!,
      rules: s.rules as { [K in keyof typeof s.rules]: NonNullable<(typeof s.rules)[K]> },
      token: await viem.getContractAt("IntentToken", s.products.intent.address),
      vault4626: await viem.getContractAt("Gated4626Vault", s.products.fund.address),
      vault7540: await viem.getContractAt("Gated7540Vault", s.products.asyncFund.address),
      implementations: {
        token: stage.components.intentImpl,
        vault4626: stage.components.fundImpl,
        vault7540: stage.components.asyncFundImpl,
      },
    };
  };
  return { ...stage, launch };
}

export type Stack = Awaited<ReturnType<typeof deployStack>>;
export type ProfileStack = Awaited<ReturnType<typeof deployProfile>>;
type HandedOverKeys = "legos" | "parameters" | "profile" | "publicClient" | "wallets" | "timelock" | "recoveryTimelock" | "registry" | "hook" | "proxyDeployer" | "credentials" | "funds" | "executor" | "dvpExecutor" | "rules" | "deployed";
type Parameters_ = Record<string, Address | bigint | number>;

/** `Core`, then the council step. Returns what the later stages need, and a function that runs them. */
async function stages(connection: NetworkConnection, profile: Profile) {
  const { viem, networkHelpers, ignition } = connection;
  const publicClient = await viem.getPublicClient();
  const [
    deployer,
    governance,
    attester,
    guardian,
    minter,
    burner,
    agent,
    operator,
    settler,
    custody,
    recovery,
    alice,
    bob,
    carol,
    dave,
    eve,
    kyc,
    operations,
    reporter,
    checker,
    allocator,
    feeRecipient,
  ] = await viem.getWalletClients();
  const address = (w: typeof deployer) => w.account.address;

  // Deterministic calendar: everything below happens inside the settlement window (Mon 10:00 UTC onwards). A second
  // fixture on the same connection is already past it.
  if (BigInt(await networkHelpers.time.latest()) < MONDAY_10AM) await networkHelpers.time.increaseTo(MONDAY_10AM);

  // External to the stack: the vaults' asset.
  const asset = await viem.deployContract("MockAsset", [6]);

  const core = coreModule(profile);
  const deployed = await ignition.deploy(core, {
    parameters: { [core.id]: { governance: address(governance), council: address(attester), guardian: address(guardian) } },
  });
  const components = Object.fromEntries(Object.entries(deployed).map(([key, c]) => [key, { address: c.address as Address }]));
  const has = (key: string) => components[key] !== undefined;

  const timelock = await viem.getContractAt("GovernanceTimelock", components.timelock.address);
  const recoveryTimelock = await viem.getContractAt("GovernanceTimelock", components.recoveryTimelock.address);
  const registry = await viem.getContractAt("PolicyRegistry", components.registry.address);
  const hook = await viem.getContractAt("ComplianceHook", components.hook.address);
  const proxyDeployer = await viem.getContractAt("ProxyDeployer", components.proxyDeployer.address);
  const credentials = has("credentialRegistry") ? await viem.getContractAt("CredentialRegistry", components.credentialRegistry.address) : undefined;
  const executor = has("executor") ? await viem.getContractAt("IntentExecutor", components.executor.address) : undefined;
  const dvpExecutor = has("dvpExecutor") ? await viem.getContractAt("DvPExecutor", components.dvpExecutor.address) : undefined;
  const rules = {
    credentialRule: has("credentialRule") ? await viem.getContractAt("CredentialRule", components.credentialRule.address) : undefined,
    minPositionRule: has("minPositionRule") ? await viem.getContractAt("MinPositionRule", components.minPositionRule.address) : undefined,
    holderRestrictionRule: has("holderRestrictionRule") ? await viem.getContractAt("HolderRestrictionRule", components.holderRestrictionRule.address) : undefined,
    windowRule: has("windowRule") ? await viem.getContractAt("SettlementWindowRule", components.windowRule.address) : undefined,
    supplyCapRule: has("supplyCapRule") ? await viem.getContractAt("SupplyCapRule", components.supplyCapRule.address) : undefined,
    executedOnlyRule: has("executedOnlyRule") ? await viem.getContractAt("ExecutedOnlyRule", components.executedOnlyRule.address) : undefined,
  };

  const attest = async (target: Address, kind: number, uri: string) => {
    const code = await publicClient.getCode({ address: target });
    await registry.write.attest([keccak256(code!), kind, uri], { account: attester.account });
  };

  // Council step: the rules, the one shared hook and the implementations. The credential rule's codehash covers the
  // registry's address and not its code, so the council reads the registry first (its admin, its attesters, its code).
  for (const rule of Object.values(rules)) {
    if (rule !== undefined) await attest(rule.address, ATTEST.RULE, `ipfs://rule-review/${rule.address}`);
  }
  await attest(hook.address, ATTEST.HOOK, `ipfs://hook-review/${hook.address}`);
  for (const key of Object.values(IMPLEMENTATION_KEY)) {
    if (has(key)) await attest(components[key].address, ATTEST.IMPLEMENTATION, `ipfs://impl-review/${components[key].address}`);
  }

  const parameters: Parameters_ = {
    ...Object.fromEntries(Object.entries(components).map(([key, c]) => [key, c.address])),
    kycAttester: address(kyc),
    guardian: address(guardian),
    governance: address(governance),
    operations: address(operations),
    asset: asset.address,
    minter: address(minter),
    burner: address(burner),
    agent: address(agent),
    operator: address(operator),
    settler: address(settler),
    reporter: address(reporter),
    checker: address(checker),
    allocator: address(allocator),
    windowOpen: WINDOW_OPEN,
    windowClose: WINDOW_CLOSE,
    windowDays: rules.windowRule === undefined ? 0 : await rules.windowRule.read.MON_TO_FRI(),
  };

  const wallets = { deployer, governance, attester, guardian, minter, burner, agent, operator, settler, custody, recovery, kyc, operations, reporter, checker, allocator, feeRecipient };

  /** A fund as the stack knows it: its contract, its rule, its intended cap and the classes it opened with. */
  type FundStack = {
    fund: Awaited<ReturnType<typeof attachFund>>;
    rule: Awaited<ReturnType<typeof attachFundRule>>;
    cap: bigint;
    classes: string[];
  };
  const attachFund = (target: Address) => viem.getContractAt("Fund", target);
  const attachFundRule = (target: Address) => viem.getContractAt("FundHoldersRule", target);

  /** Attaches a placed product with its own template's ABI, so a role scan sees that template's roles. */
  const attach = async (template: Template, target: Address) => {
    switch (template) {
      case "GatedToken":
        return viem.getContractAt("GatedToken", target);
      case "IntentToken":
        return viem.getContractAt("IntentToken", target);
      case "Gated721":
        return viem.getContractAt("Gated721", target);
      case "Gated4626Vault":
        return viem.getContractAt("Gated4626Vault", target);
      case "Gated7540Vault":
        return viem.getContractAt("Gated7540Vault", target);
    }
  };

  const launch = async (p: Parameters_) => {
    const handover = coreHandoverModule(profile);
    await ignition.deploy(handover, { parameters: { [handover.id]: p } });

    // Each fund, with the council attesting its rule: a class cannot list the rule before that.
    const funds: Record<string, FundStack> = {};
    for (const key of fundsOf(profile)) {
      const module = fundModule(key);
      const pair = await ignition.deploy(module, {
        parameters: { [module.id]: { operations: address(operations), registry: registry.address } },
        defaultSender: address(operations),
      });
      await attest(pair.rule.address, ATTEST.RULE, `ipfs://rule-review/${pair.rule.address}`);
      funds[key] = {
        fund: await attachFund(pair.fund.address),
        rule: await attachFundRule(pair.rule.address),
        cap: (p[`${key}HolderCap`] as bigint | undefined) ?? FUND_HOLDER_CAP,
        classes: classesOf(profile, key),
      };
    }
    const [firstFund] = Object.values(funds);

    const placed: Record<string, Awaited<ReturnType<typeof attach>>> = {};
    const legos: Record<string, Record<string, Address>> = {};

    /** Runs `Legos` for a product that has them, with the council attesting each. Returns what `Product` plugs in. */
    const buildLegos = async (product: Product, assetAddress: Address) => {
      if (!hasLegos(product)) return {};
      const implementation = p[IMPLEMENTATION_KEY[product.template]] as Address;
      const vault = await proxyDeployer.read.predict([product.symbol, implementation]);
      const module = legosModule(product);
      // An outside vault the test can pay yield into, unless the test named one.
      const targets = await Promise.all(
        (product.portfolio?.targets ?? []).map(async (t) => [
          `target_${t.key}`,
          p[`target_${t.key}`] ?? (await viem.deployContract("MockERC4626Target", [assetAddress])).address,
        ]),
      );
      const built = await ignition.deploy(module, {
        parameters: {
          [module.id]: {
            ...p,
            vault,
            asset: assetAddress,
            custodianAccount: address(custody),
            feeRecipient: address(feeRecipient),
            ...Object.fromEntries((product.portfolio?.custodians ?? []).map((c) => [`custodian_${c.key}`, address(custody)])),
            ...Object.fromEntries(targets),
          },
        },
        defaultSender: address(operations),
      });
      const addresses = Object.fromEntries(Object.entries(built).map(([key, c]) => [key, (c as { address: Address }).address]));
      const kindOf = (key: string) =>
        key === "portfolio" ? ATTEST.PORTFOLIO
        : key.startsWith("validator_") ? ATTEST.VALIDATOR
        : key === "feeModel" ? ATTEST.FEE_MODEL
        : key === "navDesk" ? undefined
        : ATTEST.ADAPTER;
      for (const [key, target] of Object.entries(addresses)) {
        const kind = kindOf(key);
        // Two custodians' validators can be the same code: the council attests it once.
        if (kind !== undefined && !(await registry.read.isAttested([target, kind]))) await attest(target, kind, `ipfs://lego-review/${target}`);
      }
      legos[product.key] = addresses;
      return addresses;
    };

    /** Runs `Product` as the operations account, with the parameters that are specific to this product. */
    const place = async (product: Product) => {
      const module = productModule(product);
      const assetAddress = (product.assetProduct === undefined ? p.asset : placed[product.assetProduct].address) as Address;
      const built = await buildLegos(product, assetAddress);
      const { token } = await ignition.deploy(module, {
        parameters: {
          [module.id]: {
            ...p,
            ...built,
            implementation: p[IMPLEMENTATION_KEY[product.template]],
            minPosition: p[`${product.key}MinPosition`] ?? 0n,
            supplyCap: p[`${product.key}SupplyCap`] ?? 0n,
            asset: assetAddress,
            ...(product.fund === undefined ? {} : { fundHoldersRule: funds[product.fund].rule.address }),
          },
        },
        defaultSender: address(operations),
      });
      const contract = await attach(product.template, token.address);
      // A 7540 vault is an ordinary holder of a gated asset while it holds pending deposits, so that asset's attester
      // credentials it. Its own shares need no credential: `CredentialRule` does not judge a token's own address.
      if (product.template === "Gated7540Vault" && product.assetProduct !== undefined && credentials !== undefined) {
        const validUntil = (await publicClient.getBlock()).timestamp + DEMO_VALIDITY;
        await credentials.write.set([contract.address, validUntil, QUALS.KYC | QUALS.INFRA], { account: kyc.account });
      }
      placed[product.key] = contract;
      return contract;
    };

    const products: { product: Product; contract: Awaited<ReturnType<typeof attach>> }[] = [];
    for (const product of profile.products) products.push({ product, contract: await place(product) });

    for (const [key, { fund, rule, cap, classes }] of Object.entries(funds)) {
      const module = fundOpenModule(key, classes);
      await ignition.deploy(module, {
        parameters: {
          [module.id]: {
            fundContract: fund.address,
            fundHoldersRule: rule.address,
            holderCap: cap,
            timelock: timelock.address,
            ...Object.fromEntries(classes.map((name) => [`class_${name}`, placed[name].address])),
          },
        },
        defaultSender: address(operations),
      });
    }

    const stack = {
      publicClient,
      wallets,
      holders: { alice, bob, carol, dave, eve },
      components,
      timelock,
      recoveryTimelock,
      registry,
      hook,
      proxyDeployer,
      credentials,
      funds,
      fund: firstFund?.fund,
      executor,
      dvpExecutor,
      rules: { ...rules, fundHoldersRule: firstFund?.rule },
      asset,
      deployed: products,
      products: placed,
      legos,
      parameters: p,
      place,
      profile,
    };
    await assertHandedOver(stack);
    return stack;
  };

  return { launch, parameters, components, wallets, timelock, registry, proxyDeployer, executor };
}

/**
 * Hand-over check, the same one the runbook prescribes after a live deployment:
 * - the deployer and the operations account hold no role (every `*_ROLE()` getter, so later roles are covered) on the
 *   timelock, registry, products or executors, while the timelock holds DEFAULT_ADMIN_ROLE on each, so the check is not
 *   vacuous;
 * - each executor's operator is the stack's operator and its guardian the stack's guardian, and EXECUTOR_ROLE on an intent
 *   token is held by the executors the product names and by no account the stack knows about;
 * - UPGRADER_ROLE is held by the timelock and nobody else that the stack knows about;
 * - every product runs the one shared hook the council reviewed, which names the stack's registry and holds the intended
 *   ordered rule list for that product; rules have no access control of their own;
 * - the guardian can cancel timelock operations but cannot propose or execute them, and both timelocks wait at least 24
 *   hours; on each, no known account but governance proposes or executes, and the zero address, which would open the role
 *   to anyone, holds no proposer, executor or canceller role;
 * - `ProxyDeployer` is owned by the operations account, so products launch without waiting;
 * - each fund is owned by the timelock, runs the attested rule that points back at it, has the intended cap, and holds the
 *   classes it opened with, in order, each intact (its hook lists the fund's rule: `firstBrokenClass()` is the zero
 *   address);
 * - a 7540's second contract is the code the release says, as an implementation's attestation pins only its address;
 * - a product's legos are wired as its profile says and name this product: its desk has the profile's redemption gate and
 *   holds SETTLER_ROLE and no account
 *   does, the reporter, the checker and the allocator are different accounts, the council attested what needs it, each
 *   custodian's account lets its attested validator judge the asset's `transfer`, up to the profile's amount, and every
 *   risk has the profile's caps;
 * - MINTER_ROLE, BURNER_ROLE, AGENT_ROLE and a desk-less vault's SETTLER_ROLE sit with a Safe of at least two signers,
 *   unless the profile names the role as an exception;
 * - the recovery timelock holds exactly RECOVERY_ROLE on each product, the executors, the credential registry and the
 *   main timelock (nothing else, nowhere else), has no cancellers, and the guardian holds nothing on it.
 */
export async function assertHandedOver(s: Pick<ProfileStack, HandedOverKeys>) {
  const deployer = s.wallets.deployer.account.address;
  const operations = s.wallets.operations.account.address;
  const guardian = s.wallets.guardian.account.address;
  const timelock = s.timelock.address;
  // The same code as the main timelock, so its delay has the same floor. First, because the role reads below would only
  // revert on another contract.
  assert.equal(
    await s.publicClient.getCode({ address: s.recoveryTimelock.address }),
    await s.publicClient.getCode({ address: timelock }),
    "the recovery timelock is not a GovernanceTimelock",
  );
  const known = Object.values(s.wallets).map((w) => w.account.address);
  const tokens = s.deployed.map(({ contract }) => contract);
  const executors = [s.executor, s.dvpExecutor].filter((c) => c !== undefined);
  type Gated = { address: Address; abi: unknown };
  /** Every role id the contract exposes through a `*_ROLE()` getter, so a role added later is covered. */
  const rolesOf = async (c: Gated) => {
    const abi = c.abi as Abi;
    const roles: Hex[] = [];
    for (const item of abi) {
      if (item.type !== "function" || !item.name.endsWith("_ROLE") || item.inputs.length !== 0) continue;
      roles.push((await s.publicClient.readContract({ address: c.address, abi, functionName: item.name })) as Hex);
    }
    return roles;
  };
  const heldBy = async (c: Gated, account: Address) => {
    const held: Hex[] = [];
    for (const role of await rolesOf(c)) {
      const has = await s.publicClient.readContract({
        address: c.address,
        abi: c.abi as Abi,
        functionName: "hasRole",
        args: [role, account],
      });
      if (has) held.push(role);
    }
    return held.sort();
  };
  const administered: Gated[] = [s.timelock, s.registry, ...tokens, ...executors, ...(s.credentials === undefined ? [] : [s.credentials])];
  for (const c of [s.recoveryTimelock, ...administered]) {
    assert.deepEqual(await heldBy(c, deployer), [], `deployer holds roles on ${c.address}`);
    assert.deepEqual(await heldBy(c, operations), [], `the operations account holds roles on ${c.address}`);
  }
  for (const c of administered) {
    assert.ok((await heldBy(c, timelock)).includes(ROLES.DEFAULT_ADMIN), `timelock lacks DEFAULT_ADMIN_ROLE on ${c.address}`);
  }
  // M-1: the recovery timelock's complete role set, pinned so a change that widens it fails the deploy.
  const recovery = s.recoveryTimelock.address;
  const expectedRecoveryRoles: [Gated, Hex[]][] = [
    [s.timelock, [ROLES.RECOVERY]],
    [s.registry, []],
    ...[...tokens, ...executors].map((c): [Gated, Hex[]] => [c, [ROLES.RECOVERY]]),
    // It may clear a guardian block, revive an attester and remove the guardian.
    ...(s.credentials === undefined ? [] : [[s.credentials, [ROLES.RECOVERY]] as [Gated, Hex[]]]),
    [s.recoveryTimelock, [ROLES.DEFAULT_ADMIN]], // OZ makes every timelock its own admin
  ];
  for (const [c, roles] of expectedRecoveryRoles) {
    assert.deepEqual(await heldBy(c, recovery), [...roles].sort(), `recovery timelock role set on ${c.address}`);
  }
  assert.deepEqual(await heldBy(s.recoveryTimelock, guardian), [], "guardian holds roles on the recovery timelock");
  for (const account of known) {
    assert.equal(await s.recoveryTimelock.read.hasRole([ROLES.CANCELLER, account]), false, `${account} can cancel recovery`);
  }
  const governance = s.wallets.governance.account.address;
  assert.equal(await s.recoveryTimelock.read.hasRole([await s.recoveryTimelock.read.PROPOSER_ROLE(), governance]), true);
  assert.equal(await s.recoveryTimelock.read.hasRole([await s.recoveryTimelock.read.EXECUTOR_ROLE(), governance]), true);
  assert.ok((await s.recoveryTimelock.read.getMinDelay()) >= DAY, "recovery timelock delay below 24 hours");
  // No recovery power over itself.
  for (const account of [...known, recovery, timelock]) {
    assert.equal(await s.recoveryTimelock.read.hasRole([ROLES.RECOVERY, account]), false, `${account} holds RECOVERY_ROLE on the recovery timelock`);
  }
  // Each executor: the stack's operator submits through it and the guardian can pause it.
  for (const executor of executors) {
    assert.deepEqual(await heldBy(executor, s.wallets.operator.account.address), [ROLES.OPERATOR], `executor operator on ${executor.address}`);
    assert.deepEqual(await heldBy(executor, guardian), [ROLES.GUARDIAN], `executor guardian on ${executor.address}`);
  }
  // EXECUTOR_ROLE on an intent token: the executors it names and no account the stack knows about, so nothing can run a
  // signed intent without going through one of them.
  for (const { product, contract } of s.deployed) {
    if (product.template !== "IntentToken") continue;
    const named = (product.executors ?? []).map((kind) => (kind === "intent" ? s.executor : s.dvpExecutor));
    for (const executor of named) {
      assert.equal(await contract.read.hasRole([ROLES.EXECUTOR, executor!.address]), true, `${executor!.address} lacks EXECUTOR_ROLE on the intent token`);
    }
    for (const account of known) {
      assert.equal(await contract.read.hasRole([ROLES.EXECUTOR, account]), false, `${account} holds EXECUTOR_ROLE on the intent token`);
    }
  }
  for (const t of tokens) {
    assert.equal(await t.read.hasRole([ROLES.UPGRADER, timelock]), true, `timelock lacks UPGRADER_ROLE on ${t.address}`);
    for (const account of known) assert.equal(await t.read.hasRole([ROLES.UPGRADER, account]), false, `${account} can upgrade`);
  }
  // `s.hook` is the hook the council reviewed. A second instance on the same registry shares its attested codehash, so
  // check each product runs that exact instance and that its rule list on it is the intended one.
  assert.ok(isAddressEqual(await s.hook.read.REGISTRY(), s.registry.address), `hook ${s.hook.address} names another registry`);
  for (const { product, contract } of s.deployed) {
    assert.ok(isAddressEqual(await contract.read.policyHook(), s.hook.address), `token ${contract.address} runs another hook`);
    const expected = product.rules.map((name) => (name === "fundHoldersRule" ? s.funds[product.fund!].rule.address : s.rules[name]!.address));
    const actual = await s.hook.read.rules([contract.address]);
    assert.equal(actual.length, expected.length, `token ${contract.address} rule count`);
    actual.forEach((rule, i) => assert.ok(isAddressEqual(rule, expected[i]), `token ${contract.address} rule ${i}`));
  }
  for (const rule of Object.values(s.rules)) {
    if (rule === undefined) continue;
    const names = (rule.abi as Abi).flatMap((item) => (item.type === "function" ? [item.name] : []));
    assert.ok(!names.includes("hasRole") && !names.includes("owner"), `rule ${rule.address} has its own access control`);
  }
  assert.ok(isAddressEqual(await s.proxyDeployer.read.owner(), operations), "ProxyDeployer is not owned by the operations account");
  for (const { fund, rule, cap, classes } of Object.values(s.funds)) {
    assert.ok(isAddressEqual(await fund.read.owner(), timelock), "the fund is not owned by the timelock");
    assert.ok(isAddressEqual(await fund.read.rule(), rule.address), "the fund runs another rule");
    assert.ok(isAddressEqual(await rule.read.FUND(), fund.address), "the fund rule points at another fund");
    assert.equal(await s.registry.read.isAttested([rule.address, ATTEST.RULE]), true, "the fund rule is not attested");
    assert.equal(await fund.read.holderCap(), cap, "fund cap");
    assert.equal(await fund.read.classCount(), BigInt(classes.length), "class count");
    for (const [i, name] of classes.entries()) {
      const t = s.deployed.find(({ product }) => product.key === name)!.contract;
      assert.ok(isAddressEqual(await fund.read.classAt([BigInt(i + 1)]), t.address), `class ${i + 1} is not ${t.address}`);
      assert.equal(await fund.read.isClassIntact([t.address]), true, `class ${i + 1} no longer lists the fund's rule`);
    }
    assert.ok(isAddressEqual(await fund.read.firstBrokenClass(), zeroAddress), "the fund has a broken class");
  }
  // The credential layer: the guardian can stop (block, kill) and nothing else; one attester, the KYC function, and each
  // product trusts it and asks for what it lists; the rule reads this registry and the council attested it.
  if (s.credentials !== undefined) {
    const credentialRule = s.rules.credentialRule!;
    assert.deepEqual(await heldBy(s.credentials, guardian), [ROLES.GUARDIAN], "credential registry guardian");
    assert.equal(await s.credentials.read.attesterCount(), 1n, "attester count");
    const kycAttester = await s.credentials.read.attesterAt([0]);
    assert.ok(isAddressEqual(kycAttester.account, s.wallets.kyc.account.address), "attester 0 is not the KYC provider");
    assert.equal(kycAttester.killed, false, "the KYC attester is killed");
    assert.ok(isAddressEqual(await credentialRule.read.REGISTRY(), s.credentials.address), "the credential rule reads another registry");
    assert.equal(await s.registry.read.isAttested([credentialRule.address, ATTEST.RULE]), true, "the credential rule is not attested");
    for (const { product, contract } of s.deployed) {
      if (!product.rules.includes("credentialRule")) continue;
      const expected = product.policy ?? DEFAULT_POLICY;
      const policy = await credentialRule.read.policyOf([contract.address]);
      assert.deepEqual(
        [policy.requireAll, policy.requireAny, policy.forbidAny, policy.attesters],
        [expected.requireAll, expected.requireAny, expected.forbidAny, expected.attesters],
        `policy of ${contract.address}`,
      );
    }
  }
  assert.equal(await s.timelock.read.hasRole([await s.timelock.read.CANCELLER_ROLE(), guardian]), true);
  assert.equal(await s.timelock.read.hasRole([await s.timelock.read.PROPOSER_ROLE(), guardian]), false);
  assert.equal(await s.timelock.read.hasRole([await s.timelock.read.EXECUTOR_ROLE(), guardian]), false);
  assert.ok((await s.timelock.read.getMinDelay()) >= DAY, "timelock delay below 24 hours");
  // Governance alone proposes and executes on each timelock. The zero address holding a role opens it to anyone.
  for (const [label, tl] of [["timelock", s.timelock], ["recovery timelock", s.recoveryTimelock]] as const) {
    const roles = [
      ["PROPOSER_ROLE", await tl.read.PROPOSER_ROLE()],
      ["EXECUTOR_ROLE", await tl.read.EXECUTOR_ROLE()],
      ["CANCELLER_ROLE", await tl.read.CANCELLER_ROLE()],
    ] as const;
    for (const [name, role] of roles) {
      assert.equal(await tl.read.hasRole([role, zeroAddress]), false, `the zero address holds ${name} on the ${label}`);
    }
    for (const account of known) {
      if (isAddressEqual(account, governance)) continue;
      for (const [name, role] of roles.slice(0, 2)) {
        assert.equal(await tl.read.hasRole([role, account]), false, `${account} holds ${name} on the ${label}`);
      }
    }
  }

  // A product's legos. Their roles live outside the vault's role scan, so they are asked by name.
  const named = s.parameters as Record<string, Address>;
  const read = <T>(address: Address, functionName: "VAULT" | "portfolio" | "feeModel" | "adapters" | "SETTLEMENT_LOGIC" | "redemptionGate") =>
    s.publicClient.readContract({ address, abi: LEGO_ABI, functionName }) as Promise<T>;
  const isSame = async (address: Address, functionName: "VAULT" | "portfolio" | "feeModel", expected: Address) =>
    isAddressEqual(await read<Address>(address, functionName), expected);
  for (const { product, contract } of s.deployed) {
    const legos = s.legos[product.key] ?? {};
    /** The role sits with `holder` and with no other account the stack knows about. */
    const heldOnlyBy = async (role: Hex, holder: Address, label: string) => {
      assert.equal(await contract.read.hasRole([role, holder]), true, `no ${label} on ${contract.address}`);
      for (const account of known) {
        if (!isAddressEqual(account, holder)) assert.equal(await contract.read.hasRole([role, account]), false, `${account} is also ${label} on ${contract.address}`);
      }
    };
    const functions = [
      ...(product.nav === undefined ? [] : [named.reporter, named.checker]),
      ...(product.portfolio === undefined ? [] : [named.allocator]),
    ].map((account) => account.toLowerCase());
    assert.equal(new Set(functions).size, functions.length, `the reporter, the checker and the allocator of ${contract.address} are not different accounts`);
    if (product.template === "Gated7540Vault") {
      const logic = await read<Address>(contract.address, "SETTLEMENT_LOGIC");
      const artifact = await hre.artifacts.readArtifact("Gated7540Settlement");
      // Its one immutable is `__self`, its own address.
      let expected = artifact.deployedBytecode.slice(2);
      for (const { start, length } of Object.values(artifact.immutableReferences ?? {}).flat()) {
        expected = expected.slice(0, start * 2) + pad(logic, { size: length }).slice(2) + expected.slice((start + length) * 2);
      }
      const code = await s.publicClient.getCode({ address: logic });
      assert.equal(code?.toLowerCase(), `0x${expected}`.toLowerCase(), `the second contract of ${contract.address} is not the release's`);
    }
    if (product.nav !== undefined) {
      assert.ok(await isSame(legos.navDesk, "VAULT", contract.address), `the desk of ${contract.address} names another vault`);
      assert.equal(await read<bigint>(legos.navDesk, "redemptionGate"), product.nav.redemptionGateBps ?? 0n, `the redemption gate of ${contract.address}`);
      await heldOnlyBy(ROLES.SETTLER, legos.navDesk, "settler");
      await heldOnlyBy(ROLES.REPORTER, named.reporter, "reporter");
      await heldOnlyBy(ROLES.CHECKER, named.checker, "checker");
    }
    if (product.portfolio !== undefined) {
      const { portfolio } = legos;
      assert.ok(await isSame(portfolio, "VAULT", contract.address), `the portfolio of ${contract.address} names another vault`);
      assert.ok(await isSame(legos.navDesk ?? contract.address, "portfolio", portfolio), `the portfolio of ${contract.address} is not plugged in`);
      assert.equal(await s.registry.read.isAttested([portfolio, ATTEST.PORTFOLIO]), true, "the portfolio is not attested");
      await heldOnlyBy(ROLES.ALLOCATOR, named.allocator, "allocator");
      const adapters = Object.entries(legos).flatMap(([key, target]) => (key.startsWith("account_") || key.startsWith("adapter_") ? [target] : []));
      const lowered = (list: readonly Address[]) => list.map((account) => account.toLowerCase()).sort();
      assert.deepEqual(lowered(await read<Address[]>(portfolio, "adapters")), lowered(adapters), `the adapters of ${contract.address}`);
      for (const adapter of adapters) assert.equal(await s.registry.read.isAttested([adapter, ATTEST.ADAPTER]), true, `adapter ${adapter} is not attested`);
      const readAs = <T>(address: Address, functionName: "RISK_ID" | "validatorOf" | "MAX_PER_CALL" | "riskOf", args?: readonly unknown[]) =>
        s.publicClient.readContract({ address, abi: ACCOUNT_ABI, functionName, args } as never) as Promise<T>;
      const capsAre = async (adapter: Address, caps: { absoluteCap: bigint; relativeCapBps: bigint }, label: string) => {
        const risk = await readAs<{ absoluteCap: bigint; relativeCapBps: number }>(portfolio, "riskOf", [await readAs<Hex>(adapter, "RISK_ID")]);
        assert.deepEqual([risk.absoluteCap, BigInt(risk.relativeCapBps)], [caps.absoluteCap, caps.relativeCapBps], `the caps of ${label} are not the profile's`);
      };
      for (const custodian of product.portfolio.custodians ?? []) {
        const account = legos[`account_${custodian.key}`];
        const validator = legos[`validator_${custodian.key}`];
        assert.equal(await s.registry.read.isAttested([validator, ATTEST.VALIDATOR]), true, `validator_${custodian.key} is not attested`);
        const judge = await readAs<Address>(account, "validatorOf", [named.asset, TRANSFER]);
        assert.ok(isAddressEqual(judge, validator), `the permission of account_${custodian.key} is not the profile's`);
        assert.equal(await readAs<bigint>(validator, "MAX_PER_CALL"), custodian.maxPerCall, `validator_${custodian.key} allows another amount per call`);
        await capsAre(account, custodian, `account_${custodian.key}`);
      }
      for (const target of product.portfolio.targets ?? []) await capsAre(legos[`adapter_${target.key}`], target, `adapter_${target.key}`);
    }
    if (product.fees !== undefined) {
      assert.ok(await isSame(legos.navDesk ?? contract.address, "feeModel", legos.feeModel), `the fee model of ${contract.address} is not plugged in`);
      assert.equal(await s.registry.read.isAttested([legos.feeModel, ATTEST.FEE_MODEL]), true, "the fee model is not attested");
    }
    // The sensitive roles sit with a Safe of at least two signers, unless the profile says otherwise on purpose.
    const sensitive = [
      ["minter", ROLES.MINTER],
      ["burner", ROLES.BURNER],
      ["agent", ROLES.AGENT],
      ["settler", ROLES.SETTLER],
    ] as const;
    for (const [name, role] of sensitive) {
      if (s.profile.singleSigners?.includes(name) || !(await contract.read.hasRole([role, named[name]]))) continue;
      assert.ok(await isMultiSigner(s.publicClient, named[name]), `${name} on ${contract.address} is a single signer and the profile names no exception`);
    }
  }
}

/** Whether an account answers a Safe's `getThreshold()` with two or more. */
async function isMultiSigner(publicClient: ProfileStack["publicClient"], account: Address) {
  try {
    return (await publicClient.readContract({ address: account, abi: SAFE_ABI, functionName: "getThreshold" })) >= 2n;
  } catch {
    return false;
  }
}

export const INTENT_TYPES = {
  TransferIntent: [
    { name: "from", type: "address" },
    { name: "to", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "nonce", type: "bytes32" },
    { name: "deadline", type: "uint256" },
    { name: "ref", type: "bytes32" },
    { name: "executor", type: "address" },
    { name: "validAfter", type: "uint256" },
    { name: "considerationToken", type: "address" },
    { name: "considerationAmount", type: "uint256" },
  ],
} as const;

export type Intent = {
  from: Address;
  to: Address;
  amount: bigint;
  nonce: Hex;
  deadline: bigint;
  ref: Hex;
  executor: Address;
  validAfter: bigint;
  considerationToken: Address;
  considerationAmount: bigint;
};

/** Anything that reports its EIP-712 domain through ERC-5267, as every token and the ERC-3009 mock here does. */
type DomainSource = {
  read: { eip712Domain: () => Promise<readonly [Hex, string, string, bigint, Address, Hex, readonly bigint[]]> };
};

/** The token's EIP-712 domain as the chain reports it (ERC-5267), so signing never re-derives it off-chain. */
async function intentDomain(token: DomainSource) {
  const [, name, version, chainId, verifyingContract] = await token.read.eip712Domain();
  return { name, version, chainId, verifyingContract };
}

/**
 * A fresh intent from `signer`: random nonce (as the signer's HSM would choose), one-hour deadline, random ref, and by
 * default no executor binding, no `validAfter` and no consideration.
 */
export async function signIntent(
  s: Stack,
  signer: Stack["holders"]["alice"],
  fields: {
    to: Address;
    amount: bigint;
    deadline?: bigint;
    executor?: Address;
    validAfter?: bigint;
    considerationToken?: Address;
    considerationAmount?: bigint;
  },
  domainOverride: Partial<Awaited<ReturnType<typeof intentDomain>>> = {},
  /** The token the intent is for: its domain is the one signed. Defaults to the stack's intent token. */
  token: DomainSource = s.token,
) {
  const now = (await s.publicClient.getBlock()).timestamp;
  const intent: Intent = {
    from: signer.account.address,
    to: fields.to,
    amount: fields.amount,
    nonce: toHex(crypto.getRandomValues(new Uint8Array(32))),
    deadline: fields.deadline ?? now + 3_600n,
    ref: toHex(crypto.getRandomValues(new Uint8Array(32))),
    executor: fields.executor ?? zeroAddress,
    validAfter: fields.validAfter ?? 0n,
    considerationToken: fields.considerationToken ?? zeroAddress,
    considerationAmount: fields.considerationAmount ?? 0n,
  };
  const domain = { ...(await intentDomain(token)), ...domainOverride };
  const sig = await signer.signTypedData({ domain, types: INTENT_TYPES, primaryType: "TransferIntent", message: intent });
  return { intent, sig, domain };
}

/**
 * Runs a call expected to revert and decodes its revert data against `abi`, which may combine several contracts'
 * ABIs (an executor bubbles the token's errors). Resolves to `undefined` when the call succeeds.
 */
export async function revertOf(call: Promise<unknown>, abi: Abi) {
  try {
    await call;
    return undefined;
  } catch (error) {
    const reverted = error instanceof BaseError ? error.walk((e) => e instanceof ContractFunctionRevertedError) : null;
    if (!(reverted instanceof ContractFunctionRevertedError) || reverted.raw === undefined) throw error;
    const { errorName, args } = decodeErrorResult({ abi, data: reverted.raw });
    return { errorName, args: (args ?? []) as readonly unknown[] };
  }
}

// ---- DvP ---------------------------------------------------------------------------------------------------------------

/** The typed data of an ERC-3009 `receiveWithAuthorization`, as Circle's FiatToken and the test mock define it. */
export const RECEIVE_AUTHORIZATION_TYPES = {
  ReceiveWithAuthorization: [
    { name: "from", type: "address" },
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "validAfter", type: "uint256" },
    { name: "validBefore", type: "uint256" },
    { name: "nonce", type: "bytes32" },
  ],
} as const;

/** The buyer's authorization as `DvPExecutor.executeDvP3009` takes it; its payee is always the executor. */
type Authorization = { from: Address; value: bigint; validAfter: bigint; validBefore: bigint; nonce: Hex; signature: Hex };

/**
 * The nonce that ties a buyer's ERC-3009 authorization to one securities intent on one security token:
 * `keccak256(abi.encode(securityToken, intentHash))`. The token's address is in it, so an operator cannot pair the
 * authorization with another token that merely reports the same hash.
 */
export function dvpNonce(securityToken: Address, securitiesIntentHash: Hex): Hex {
  return keccak256(encodeAbiParameters([{ type: "address" }, { type: "bytes32" }], [securityToken, securitiesIntentHash]));
}

type Trader = Stack["holders"]["alice"];
type TokenHandle = DomainSource & { address: Address };

/**
 * A gated trade: the seller signs the securities intent (executor = the DvP executor, stating the cash it is to
 * receive), the buyer signs the cash intent on the cash token (stating the shares it is to receive).
 */
export async function signGatedTrade(
  s: Stack,
  trade: { seller: Trader; buyer: Trader; securityToken: TokenHandle; cashToken: TokenHandle; shares: bigint; cash: bigint; deadline?: bigint },
) {
  const { seller, buyer, securityToken, cashToken, shares, cash, deadline } = trade;
  const dvp = s.dvpExecutor.address;
  const securities = await signIntent(
    s,
    seller,
    { to: buyer.account.address, amount: shares, deadline, executor: dvp, considerationToken: cashToken.address, considerationAmount: cash },
    {},
    securityToken,
  );
  const payment = await signIntent(
    s,
    buyer,
    { to: seller.account.address, amount: cash, deadline, executor: dvp, considerationToken: securityToken.address, considerationAmount: shares },
    {},
    cashToken,
  );
  return { securities, payment };
}

/**
 * An ERC-3009 trade: the seller signs the securities intent; the buyer signs an authorization to the executor whose
 * nonce is `dvpNonce(securityToken, intentHash)`, computed here from the typed data and not read from the chain.
 */
export async function sign3009Trade(
  s: Stack,
  trade: {
    seller: Trader;
    buyer: Trader;
    securityToken: TokenHandle;
    cashToken: TokenHandle;
    shares: bigint;
    cash: bigint;
    deadline?: bigint;
    validBefore?: bigint;
    /** Replaces the nonce the helper would compute, to build the authorizations that must be refused. */
    nonce?: (intentHash: Hex) => Hex;
  },
) {
  const { seller, buyer, securityToken, cashToken, shares, cash, deadline } = trade;
  const securities = await signIntent(
    s,
    seller,
    { to: buyer.account.address, amount: shares, deadline, executor: s.dvpExecutor.address, considerationToken: cashToken.address, considerationAmount: cash },
    {},
    securityToken,
  );
  const intentHash = hashTypedData({ domain: securities.domain, types: INTENT_TYPES, primaryType: "TransferIntent", message: securities.intent });
  const now = (await s.publicClient.getBlock()).timestamp;
  const message = {
    from: buyer.account.address,
    to: s.dvpExecutor.address,
    value: cash,
    validAfter: 0n,
    validBefore: trade.validBefore ?? now + 3_600n,
    nonce: trade.nonce ? trade.nonce(intentHash) : dvpNonce(securityToken.address, intentHash),
  };
  const signature = await buyer.signTypedData({
    domain: await intentDomain(cashToken),
    types: RECEIVE_AUTHORIZATION_TYPES,
    primaryType: "ReceiveWithAuthorization",
    message,
  });
  const authorization: Authorization = {
    from: message.from,
    value: message.value,
    validAfter: message.validAfter,
    validBefore: message.validBefore,
    nonce: message.nonce,
    signature,
  };
  return { securities, authorization, intentHash };
}

/**
 * A gated cash token for tests: an `IntentToken` behind a fresh `ProxyDeployer`, on the stack's shared hook with the
 * stack's credential rule as its only rule, administered by the deployer (a live deployment would use the timelock), with
 * the DvP executor holding EXECUTOR_ROLE. The council attests its implementation as it would for any token; the hook
 * is the one already attested.
 */
export async function deployGatedCashToken(connection: NetworkConnection, s: Stack) {
  const { viem } = connection;
  const deployer = s.wallets.deployer.account.address;
  const attest = async (target: Address, kind: number) => {
    const code = await s.publicClient.getCode({ address: target });
    await s.registry.write.attest([keccak256(code!), kind, "ipfs://review"], { account: s.wallets.attester.account });
  };
  const implementation = await viem.deployContract("IntentToken");
  await attest(implementation.address, ATTEST.IMPLEMENTATION);
  const proxyDeployer = await viem.deployContract("ProxyDeployer", [deployer, s.registry.address]);
  const symbol = "gUSD";
  const predicted = await proxyDeployer.read.predict([symbol, implementation.address]);
  const rules = [s.rules.credentialRule.address];
  const data = encodeFunctionData({
    abi: implementation.abi,
    functionName: "initialize",
    args: ["Gated USD", symbol, 18, deployer, s.wallets.guardian.account.address, s.registry.address, s.hook.address, rules],
  });
  await proxyDeployer.write.deploy([symbol, implementation.address, data, s.hook.address, rules]);
  const token = await viem.getContractAt("IntentToken", predicted);
  // The deployer administers this token, so it sets the policy the deployment sets on the others: KYC from attester 0.
  await s.rules.credentialRule.write.setPolicy([token.address, QUALS.KYC, 0, 0, 1n]);
  await token.write.grantRole([ROLES.EXECUTOR, s.dvpExecutor.address]);
  await token.write.grantRole([ROLES.MINTER, s.wallets.minter.account.address]);
  return token;
}

// ---- Dealing ----

/** Shares per asset unit at par: the shares of a 7540 have 6 more decimals than its asset. */
export const PAR = 1_000_000n;

type DealingVault = {
  address: Address;
  read: { dealingState: () => Promise<readonly [bigint, bigint, bigint]>; totalSupply: () => Promise<bigint> };
  write: {
    closePeriod: (options: { account: Account }) => Promise<Hex>;
    settlePeriod: (args: readonly [bigint, bigint, Address, Address, bigint], options: { account: Account }) => Promise<Hex>;
  };
};
type DealingStack = {
  wallets: { settler: { account: Account }; custody: { account: Account } };
  asset: {
    write: {
      mint: (args: readonly [Address, bigint]) => Promise<Hex>;
      approve: (args: readonly [Address, bigint], options: { account: Account }) => Promise<Hex>;
    };
  };
};

/** Closes the vault's open period and settles it at `nav`, or at par, with the custody wallet as a funded cash account. */
export async function settlePeriod(s: DealingStack, vault: DealingVault, nav?: bigint, redeemLimit: bigint = maxUint256) {
  const custody = s.wallets.custody.account;
  await s.asset.write.mint([custody.address, 10n ** 30n]);
  await s.asset.write.approve([vault.address, 2n ** 256n - 1n], { account: custody });
  const [, , unclaimed] = await vault.read.dealingState();
  const value = nav ?? ((await vault.read.totalSupply()) + unclaimed) / PAR;
  const settler = s.wallets.settler.account;
  await vault.write.closePeriod({ account: settler });
  await vault.write.settlePeriod([value, 0n, custody.address, zeroAddress, redeemLimit], { account: settler });
}

/**
 * One period through a product's desk, as it runs live: anyone closes it once the period is over, the reporter proposes the
 * value it was given, the checker accepts that proposal by its hash, and anyone executes after the cooldown.
 */
export async function settleThroughDesk(connection: NetworkConnection, s: ProfileStack, key: string, reported: bigint) {
  const { viem, networkHelpers } = connection;
  const desk = await viem.getContractAt("NavDesk", s.legos[key].navDesk);
  const portfolio = s.legos[key].portfolio;
  await networkHelpers.time.increase(await desk.read.periodLength());
  await desk.write.closePeriod();
  const moves = portfolio === undefined ? 0n : await (await viem.getContractAt("Portfolio", portfolio)).read.moves();
  const asOf = BigInt(await networkHelpers.time.latest());
  await desk.write.propose([reported, keccak256(toHex(`report:${asOf}`)), asOf, moves], { account: s.wallets.reporter.account });
  const hash = await desk.read.hashOf([await desk.read.proposal()]);
  await desk.write.accept([hash], { account: s.wallets.checker.account });
  await networkHelpers.time.increase(await desk.read.cooldown());
  await desk.write.execute();
}

// ---- Credentials -------------------------------------------------------------------------------------------------------

type Who = Address | { account: { address: Address } };
const addressOf = (who: Who) => (typeof who === "string" ? who : who.account.address);

/**
 * The demo KYC attester vouches for `who`: a credential from now, valid for `validFor` seconds (far past any test by
 * default) with `quals`. Writes over an earlier credential of the same attester.
 */
export async function verify(s: Pick<ProfileStack, "publicClient" | "credentials" | "wallets">, who: Who, opts: { quals?: number; validFor?: bigint } = {}) {
  const now = (await s.publicClient.getBlock()).timestamp;
  await s.credentials!.write.set([addressOf(who), now + (opts.validFor ?? DEMO_VALIDITY), opts.quals ?? QUALS.KYC], {
    account: s.wallets.kyc.account,
  });
}

/** The KYC attester blocks `who`: it can no longer send or receive. (The old "de-verified".) */
export async function deverify(s: Pick<ProfileStack, "credentials" | "wallets">, who: Who) {
  await s.credentials!.write.setStatus([addressOf(who), STATUS.BLOCKED], { account: s.wallets.kyc.account });
}
