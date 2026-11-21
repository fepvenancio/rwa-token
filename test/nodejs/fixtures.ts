// SPDX-License-Identifier: UNLICENSED
import assert from "node:assert/strict";

import type { NetworkConnection } from "hardhat/types/network";
import {
  BaseError,
  ContractFunctionRevertedError,
  decodeErrorResult,
  encodeAbiParameters,
  encodeFunctionData,
  hashTypedData,
  keccak256,
  maxUint256,
  toHex,
  type Abi,
  type Account,
  type Address,
  type Hex,
  zeroAddress,
} from "viem";

import { ENTRY_TYPES, EXIT_TYPES, handoverFailures, ORDER_TYPES, type Stack as CheckedStack } from "../../scripts/lib/check.js";
import { coreModule } from "../../ignition/modules/Core.js";
import { hasLegos, legosModule } from "../../ignition/modules/Legos.js";
import { coreHandoverModule } from "../../ignition/modules/CoreHandover.js";
import { fundModule } from "../../ignition/modules/Fund.js";
import { fundOpenModule } from "../../ignition/modules/FundOpen.js";
import { corePartsModule, partsHandoverModule } from "../../ignition/parts.js";
import { productModule } from "../../ignition/modules/Product.js";
import { QUALS, ROLES } from "../../ignition/modules/roles.js";
import {
  classesOf,
  fundsOf,
  IMPLEMENTATION_KEY,
  missingParts,
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
  "SENDER_NOT_ELIGIBLE",
  "RECEIVER_NOT_VERIFIED",
  "WINDOW_CLOSED",
  "MAX_HOLDERS",
  "LOCKED_UP",
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
  "KIND_NOT_ALLOWED",
  "NOT_TOKEN_OWNER",
  "CHECK_UNAVAILABLE",
] as const;

/** `Errors.sol` reason codes, keyed by name; `reasonName` maps a code back for readable assertions. */
export const REASONS = Object.fromEntries(REASON_NAMES.map((name) => [name, keccak256(toHex(name))])) as Record<
  (typeof REASON_NAMES)[number],
  Hex
>;
export const reasonName = (code: Hex) => REASON_NAMES.find((name) => REASONS[name] === code) ?? code;

/** Mon 2026-10-12 00:00 UTC plus 260 weeks: a Monday in 2031, safely after the local chain's wall clock. */
export const MONDAY = 1_791_763_200n + 260n * 7n * 86_400n;
const ATTEST = { HOOK: 1, RULE: 2, IMPLEMENTATION: 3, PORTFOLIO: 4, ADAPTER: 5, VALIDATOR: 6, FEE_MODEL: 7 } as const;
const MONDAY_10AM = MONDAY + 10n * 3_600n;
export const WINDOW_OPEN = 9 * 3_600;
export const WINDOW_CLOSE = 17 * 3_600;
/** The fund-wide investor cap, one number for the three demo classes. */
export const FUND_HOLDER_CAP = 3n;

/** The qualification bits, from the deployment's own copy of `Quals.sol` (`InterfaceFreeze` pins the Solidity side). */
export { ENTRY_TYPES, EXIT_TYPES, ORDER_TYPES, QUALS };
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
      await s.credentials!.write.set([w.account.address, validUntil, QUALS.KYC, 0], { account: s.wallets.kyc.account });
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
/**
 * Fails unless the post-deploy check finds nothing wrong: the same check `npm run check` runs against a deployed stack,
 * given the test wallets' addresses as the accounts the deployment names.
 */
export async function assertHandedOver(s: Omit<CheckedStack, "accounts"> & Pick<ProfileStack, "wallets">) {
  const accounts = Object.fromEntries(Object.entries(s.wallets).map(([name, w]) => [name, w.account.address]));
  const failures = await handoverFailures({ ...s, accounts });
  assert.deepEqual(failures, [], failures.join("\n"));
}
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
    distributionMaker,
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
  const components: Record<string, { address: Address }> = Object.fromEntries(
    Object.entries(deployed).map(([key, c]) => [key, { address: c.address as Address }]),
  );
  const has = (key: string) => components[key] !== undefined;

  const timelock = await viem.getContractAt("GovernanceTimelock", components.timelock.address);
  const recoveryTimelock = await viem.getContractAt("GovernanceTimelock", components.recoveryTimelock.address);
  const registry = await viem.getContractAt("PolicyRegistry", components.registry.address);
  const hook = await viem.getContractAt("ComplianceHook", components.hook.address);
  const proxyDeployer = await viem.getContractAt("ProxyDeployer", components.proxyDeployer.address);
  /** The credential rule the parameters name, for a profile that reads an external registry. Set when the stack launches. */
  let externalRule: Address | undefined;
  /** The parts the core has, attached: read again after parts are added to it. */
  const attachParts = async () => ({
    credentials: has("credentialRegistry")
      ? await viem.getContractAt("CredentialRegistry", components.credentialRegistry.address)
      : externalRule !== undefined
        ? await viem.getContractAt("CredentialRegistry", await (await viem.getContractAt("CredentialRule", externalRule)).read.REGISTRY())
        : undefined,
    executor: has("executor") ? await viem.getContractAt("IntentExecutor", components.executor.address) : undefined,
    dvpExecutor: has("dvpExecutor") ? await viem.getContractAt("DvPExecutor", components.dvpExecutor.address) : undefined,
    orderSettlement: has("orderSettlement") ? await viem.getContractAt("OrderSettlement", components.orderSettlement.address) : undefined,
    signedEntry: has("signedEntry") ? await viem.getContractAt("SignedEntry", components.signedEntry.address) : undefined,
    signedExit: has("signedExit") ? await viem.getContractAt("SignedExit", components.signedExit.address) : undefined,
    lienVault: has("lienVault") ? await viem.getContractAt("LienVault", components.lienVault.address) : undefined,
    rules: await attachRules(),
  });
  const attachRules = async () => ({
    credentialRule: has("credentialRule")
      ? await viem.getContractAt("CredentialRule", components.credentialRule.address)
      : externalRule !== undefined
        ? await viem.getContractAt("CredentialRule", externalRule)
        : undefined,
    minPositionRule: has("minPositionRule") ? await viem.getContractAt("MinPositionRule", components.minPositionRule.address) : undefined,
    holderRestrictionRule: has("holderRestrictionRule") ? await viem.getContractAt("HolderRestrictionRule", components.holderRestrictionRule.address) : undefined,
    windowRule: has("windowRule") ? await viem.getContractAt("SettlementWindowRule", components.windowRule.address) : undefined,
    supplyCapRule: has("supplyCapRule") ? await viem.getContractAt("SupplyCapRule", components.supplyCapRule.address) : undefined,
    executedOnlyRule: has("executedOnlyRule") ? await viem.getContractAt("ExecutedOnlyRule", components.executedOnlyRule.address) : undefined,
  });
  let { credentials, executor, dvpExecutor, orderSettlement, signedEntry, signedExit, lienVault, rules } = await attachParts();

  const attest = async (target: Address, kind: number, uri: string) => {
    const code = await publicClient.getCode({ address: target });
    await registry.write.attest([keccak256(code!), kind, uri], { account: attester.account });
  };

  // Council step: the rules, the one shared hook and the implementations. The credential rule's codehash covers the
  // registry's address and not its code, so the council reads the registry first (its admin, its attesters, its code).
  /** The council's attestations for these parts of the core: its rules and its implementations. */
  const attestParts = async (keys: readonly string[]) => {
    for (const key of keys) {
      if (key in rules) await attest(components[key].address, ATTEST.RULE, `ipfs://rule-review/${components[key].address}`);
      if (Object.values(IMPLEMENTATION_KEY).includes(key)) await attest(components[key].address, ATTEST.IMPLEMENTATION, `ipfs://impl-review/${components[key].address}`);
    }
  };
  await attestParts(Object.keys(components));
  await attest(hook.address, ATTEST.HOOK, `ipfs://hook-review/${hook.address}`);

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
    distributionMaker: address(distributionMaker),
    windowOpen: WINDOW_OPEN,
    windowClose: WINDOW_CLOSE,
    windowDays: rules.windowRule === undefined ? 0 : await rules.windowRule.read.MON_TO_FRI(),
  };

  const wallets = { deployer, governance, attester, guardian, minter, burner, agent, operator, settler, custody, recovery, kyc, operations, reporter, checker, allocator, feeRecipient, distributionMaker };

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
      case "Gated1155":
        return viem.getContractAt("Gated1155", target);
      case "Gated4626Vault":
        return viem.getContractAt("Gated4626Vault", target);
      case "Gated7540Vault":
        return viem.getContractAt("Gated7540Vault", target);
    }
  };

  const launch = async (given: Parameters_) => {
    // A copy: parts added to the core later add their addresses to it.
    const p: Parameters_ = { ...given };
    const handover = coreHandoverModule(profile);
    await ignition.deploy(handover, { parameters: { [handover.id]: p } });

    // A core on an existing credential registry: the council reads that registry's code and governance, then attests the
    // credential rule the parameters name in its own registry, as it would any rule.
    if (profile.credentials === "external") {
      if (p.credentialRule === undefined) throw new Error("an external credential registry needs the credentialRule parameter");
      externalRule = p.credentialRule as Address;
      await attest(externalRule, ATTEST.RULE, `ipfs://rule-review/${externalRule}`);
      ({ credentials, executor, dvpExecutor, orderSettlement, signedEntry, signedExit, lienVault, rules } = await attachParts());
    }

    // Each fund, with the council attesting its rule: a class cannot list the rule before that.
    const funds: Record<string, FundStack> = {};
    for (const key of fundsOf(profile)) {
      const module = fundModule(key);
      const pair = await ignition.deploy(module, {
        // A fund counts investors by the entity the credential registry gives each address, when the core has one.
        parameters: {
          [module.id]: { operations: address(operations), registry: registry.address, credentials: credentials?.address ?? zeroAddress },
        },
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
          p[`target_${t.key}`] ?? (t.product !== undefined ? placed[t.product].address : (await viem.deployContract("MockERC4626Target", [assetAddress])).address),
        ]),
      );
      const built = await ignition.deploy(module, {
        parameters: {
          [module.id]: {
            ...p,
            vault,
            product: vault,
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
        : key === "navDesk" || key === "distributor" ? undefined
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
      const module = productModule(product, profile.lienVault === true);
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
        await credentials.write.set([contract.address, validUntil, QUALS.KYC | QUALS.INFRA, 0], { account: kyc.account });
      }
      // A feeder class: its adapter holds the master's shares and its portfolio receives the cash of a redemption, so the
      // master's attester credentials both.
      if ((product.portfolio?.targets ?? []).some((t) => t.product !== undefined) && credentials !== undefined) {
        const validUntil = (await publicClient.getBlock()).timestamp + DEMO_VALIDITY;
        for (const [key, target] of Object.entries(built)) {
          const feeds = (product.portfolio?.targets ?? []).some((t) => t.product !== undefined && key === `adapter_${t.key}`);
          if (key === "portfolio" || feeds) await credentials.write.set([target, validUntil, QUALS.KYC | QUALS.FUND, 0], { account: kyc.account });
        }
      }
      placed[product.key] = contract;
      return contract;
    };

    /**
     * Adds to the running core what these products, or a signed entry, need and it lacks, as an issuer would: `CoreParts`,
     * the council's attestations, then `PartsHandover`. The stack then reads the new parts. Returns the parts added.
     */
    const addParts = async (wanted: Pick<Profile, "products" | "signedEntry" | "signedExit" | "lienVault" | "orderSettlement">) => {
      const present = Object.keys(components);
      const parts = missingParts({ ...wanted, credentials: profile.credentials }, present);
      const module = corePartsModule(parts, present);
      const added = await ignition.deploy(module, { parameters: { [module.id]: { guardian: address(guardian) } } });
      for (const [key, c] of Object.entries(added)) {
        components[key] = { address: (c as { address: Address }).address };
        p[key] = components[key].address;
      }
      await attestParts(Object.keys(added));
      const partsHandover = partsHandoverModule(parts);
      await ignition.deploy(partsHandover, { parameters: { [partsHandover.id]: p } });
      ({ credentials, executor, dvpExecutor, orderSettlement, signedEntry, signedExit, lienVault, rules } = await attachParts());
      if (rules.windowRule !== undefined) p.windowDays = await rules.windowRule.read.MON_TO_FRI();
      Object.assign(stack, {
        credentials,
        executor,
        dvpExecutor,
        orderSettlement,
        signedEntry,
        signedExit,
        lienVault,
        rules: { ...rules, fundHoldersRule: stack.rules.fundHoldersRule },
        profile: {
          ...stack.profile,
          orderSettlement: stack.profile.orderSettlement === true || wanted.orderSettlement === true,
          signedEntry: stack.profile.signedEntry === true || wanted.signedEntry === true,
          signedExit: stack.profile.signedExit === true || wanted.signedExit === true,
          lienVault: stack.profile.lienVault === true || wanted.lienVault === true,
        },
      });
      return parts;
    };

    const products: { product: Product; contract: Awaited<ReturnType<typeof attach>> }[] = [];
    for (const product of profile.products) products.push({ product, contract: await place(product) });

    for (const [key, { fund, rule, cap, classes }] of Object.entries(funds)) {
      const module = fundOpenModule(key, classes, profile.lienVault === true);
      await ignition.deploy(module, {
        parameters: {
          [module.id]: {
            fundContract: fund.address,
            fundHoldersRule: rule.address,
            holderCap: cap,
            timelock: timelock.address,
            ...(lienVault === undefined ? {} : { lienVault: lienVault.address }),
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
      orderSettlement,
      signedEntry,
      signedExit,
      lienVault,
      rules: { ...rules, fundHoldersRule: firstFund?.rule },
      asset,
      deployed: products,
      products: placed,
      legos,
      parameters: p,
      place,
      addParts,
      profile: profile as Profile,
    };
    await assertHandedOver(stack);
    return stack;
  };

  return { launch, parameters, components, wallets, timelock, registry, proxyDeployer, executor };
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
 * default) with `quals`, naming `entity` in the attester's numbering (none by default). Writes over an earlier credential
 * of the same attester.
 */
export async function verify(
  s: Pick<ProfileStack, "publicClient" | "credentials" | "wallets">,
  who: Who,
  opts: { quals?: number; validFor?: bigint; entity?: number } = {},
) {
  const now = (await s.publicClient.getBlock()).timestamp;
  await s.credentials!.write.set([addressOf(who), now + (opts.validFor ?? DEMO_VALIDITY), opts.quals ?? QUALS.KYC, opts.entity ?? 0], {
    account: s.wallets.kyc.account,
  });
}

/** The KYC attester blocks `who`: it can no longer send or receive. (The old "de-verified".) */
export async function deverify(s: Pick<ProfileStack, "credentials" | "wallets">, who: Who) {
  await s.credentials!.write.setStatus([addressOf(who), STATUS.BLOCKED], { account: s.wallets.kyc.account });
}
