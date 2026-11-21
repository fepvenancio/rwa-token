// SPDX-License-Identifier: UNLICENSED
// A deployed stack as a file, and how the commands read it.
import type { NetworkConnection } from "hardhat/types/network";
import { isAddress, type Address } from "viem";

import { classesOf, fundsOf, PROFILES, type Product, type Profile, type Template } from "../../ignition/profiles.js";
import type { Stack } from "./check.js";

/**
 * A deployed stack, as the operator records it: the addresses the deployment produced, under the names the Ignition
 * modules return and the later modules take as parameters, and the accounts the deployment names. Addresses only.
 */
export type StackFile = {
  /** The profile's name in `ignition/profiles.ts`. */
  profile: string;
  /** The accounts the deployment names: `deployer`, `governance`, `guardian`, `operations`, `operator`, `kyc` and the rest. */
  accounts: Record<string, Address>;
  /** What the product modules were given and the check reads: `asset`, `reporter`, `checker`, `allocator` and so on. */
  parameters?: Record<string, string | number>;
  /** What `Core` and `CoreParts` returned: `timelock`, `recoveryTimelock`, `registry`, `hook`, `proxyDeployer`, then the parts. */
  core: Record<string, Address>;
  /** Each fund the profile names: the fund, its rule and its intended cap. */
  funds?: Record<string, { fund: Address; rule: Address; cap: string | number }>;
  /** Each product placed so far, by its key in the profile. */
  products: Record<string, Address>;
  /** What `Legos` returned for each product that has any. */
  legos?: Record<string, Record<string, Address>>;
};

/** Input that cannot be used: a command exits with 2 on it, not 1. */
export class StackFileError extends Error {}

const REQUIRED_CORE = ["timelock", "recoveryTimelock", "registry", "hook", "proxyDeployer"] as const;
const REQUIRED_ACCOUNTS = ["deployer", "governance", "guardian", "operations", "operator"] as const;

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);

/** Reads a whole number that a JSON file gives as a number or as a decimal string. */
export function wholeNumber(value: unknown, path: string): bigint {
  if ((typeof value === "number" && Number.isSafeInteger(value) && value >= 0) || (typeof value === "string" && /^\d+$/.test(value))) return BigInt(value);
  throw new StackFileError(`${path} is not a whole number`);
}

/** Parses a stack file and checks its shape: every section an object, every address an address, the required names there. */
export function parseStackFile(text: string): StackFile {
  let file: unknown;
  try {
    file = JSON.parse(text);
  } catch {
    throw new StackFileError("the stack file is not JSON");
  }
  if (!isRecord(file)) throw new StackFileError("the stack file is not an object");
  if (typeof file.profile !== "string") throw new StackFileError("profile is not a name");
  const addresses = (section: unknown, path: string) => {
    if (!isRecord(section)) throw new StackFileError(`${path} is not an object`);
    for (const [key, value] of Object.entries(section)) {
      if (typeof value !== "string" || !isAddress(value)) throw new StackFileError(`${path}.${key} is not an address`);
    }
  };
  addresses(file.accounts, "accounts");
  addresses(file.core, "core");
  addresses(file.products, "products");
  for (const key of REQUIRED_CORE) if (!(key in (file.core as object))) throw new StackFileError(`core.${key} is missing`);
  for (const key of REQUIRED_ACCOUNTS) if (!(key in (file.accounts as object))) throw new StackFileError(`accounts.${key} is missing`);
  if (file.parameters !== undefined) {
    if (!isRecord(file.parameters)) throw new StackFileError("parameters is not an object");
    for (const [key, value] of Object.entries(file.parameters)) {
      if (typeof value !== "string" && typeof value !== "number") throw new StackFileError(`parameters.${key} is not a string or a number`);
    }
  }
  if (file.funds !== undefined) {
    if (!isRecord(file.funds)) throw new StackFileError("funds is not an object");
    for (const [key, fund] of Object.entries(file.funds)) {
      if (!isRecord(fund)) throw new StackFileError(`funds.${key} is not an object`);
      addresses({ fund: fund.fund, rule: fund.rule }, `funds.${key}`);
      wholeNumber(fund.cap, `funds.${key}.cap`);
    }
  }
  if (file.legos !== undefined) {
    if (!isRecord(file.legos)) throw new StackFileError("legos is not an object");
    for (const [key, legos] of Object.entries(file.legos)) addresses(legos, `legos.${key}`);
  }
  return file as StackFile;
}

/** The profile a stack file names, with each product it places. A test may give a profile that is not a shipped one. */
export function profileOf(file: StackFile, given?: Profile): { profile: Profile; placed: { product: Product; address: Address }[] } {
  const profile = given ?? (PROFILES as Record<string, Profile>)[file.profile];
  if (profile === undefined) throw new StackFileError(`ignition/profiles.ts has no profile named ${file.profile}`);
  const placed = Object.entries(file.products).map(([key, address]) => {
    const product = profile.products.find((candidate) => candidate.key === key);
    if (product === undefined) throw new StackFileError(`the profile ${file.profile} has no product named ${key}`);
    return { product, address };
  });
  return { profile, placed };
}

/** The products of the profile that a stack file does not place, so that no command reads them. */
export const unplacedOf = (file: StackFile, given?: Profile): string[] =>
  profileOf(file, given).profile.products.map((product) => product.key).filter((key) => file.products[key] === undefined);

/**
 * Attaches a stack file's contracts on a connection, as the post-deploy check reads them. Refuses a file that names a
 * profile or a product the repository does not have, or an address with no contract at it. Refuses also a file that
 * leaves out what a product it places needs: a rule the product lists, an executor it names, its fund, the credential
 * registry its credential rule reads, or a class of a fund it lists. A part left out would be a part the check does not
 * read. A product the file does not place is not an error: `unplacedOf` names those.
 */
export async function loadStack(connection: NetworkConnection, file: StackFile, given?: Profile): Promise<Stack> {
  const { viem } = connection;
  const publicClient = await viem.getPublicClient();
  const { profile, placed } = profileOf(file, given);
  const external = profile.credentials === "external";
  const { core } = file;
  const parameters = file.parameters ?? {};

  const need = (key: string, why: string) => {
    if (core[key] === undefined) throw new StackFileError(`core.${key} is missing: ${why}`);
  };
  for (const { product } of placed) {
    for (const rule of product.rules) {
      if (rule !== "fundHoldersRule" && !(rule === "credentialRule" && external)) need(rule, `products.${product.key} lists it`);
    }
    for (const kind of product.executors ?? []) need(kind === "intent" ? "executor" : "dvpExecutor", `products.${product.key} names it`);
    if (product.fund !== undefined && file.funds?.[product.fund] === undefined) throw new StackFileError(`funds.${product.fund} is missing: products.${product.key} is a class of it`);
  }
  if (!external && core.credentialRule !== undefined) need("credentialRegistry", "core.credentialRule reads it");
  for (const key of Object.keys(file.funds ?? {})) {
    for (const name of classesOf(profile, key)) {
      if (file.products[name] === undefined) throw new StackFileError(`products.${name} is missing: it is a class of funds.${key}`);
    }
  }

  const named: [string, Address][] = [
    ...Object.entries(core).map(([key, address]): [string, Address] => [`core.${key}`, address]),
    ...Object.entries(file.products).map(([key, address]): [string, Address] => [`products.${key}`, address]),
    ...Object.entries(file.funds ?? {}).flatMap(([key, f]): [string, Address][] => [[`funds.${key}.fund`, f.fund], [`funds.${key}.rule`, f.rule]]),
    ...Object.entries(file.legos ?? {}).flatMap(([key, legos]) => Object.entries(legos).map(([name, address]): [string, Address] => [`legos.${key}.${name}`, address])),
  ];
  for (const [path, address] of named) {
    const code = await publicClient.getCode({ address });
    if (code === undefined || code === "0x") throw new StackFileError(`no contract at ${address} (${path})`);
  }

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

  // A core on an existing credential registry names its rule in the parameters, and the registry is the one that rule reads.
  let externalRule: Address | undefined;
  if (external) {
    const rule = parameters.credentialRule;
    if (typeof rule !== "string" || !isAddress(rule)) throw new StackFileError("parameters.credentialRule is missing: the profile reads an external credential registry");
    externalRule = rule;
  }
  const credentialRule =
    core.credentialRule !== undefined ? await viem.getContractAt("CredentialRule", core.credentialRule)
    : externalRule !== undefined ? await viem.getContractAt("CredentialRule", externalRule)
    : undefined;
  const credentials =
    core.credentialRegistry !== undefined ? await viem.getContractAt("CredentialRegistry", core.credentialRegistry)
    : externalRule !== undefined ? await viem.getContractAt("CredentialRegistry", await credentialRule!.read.REGISTRY())
    : undefined;
  if (credentials !== undefined && !external && file.accounts.kyc === undefined) throw new StackFileError("accounts.kyc is missing: the core has its own credential registry");

  const funds: Stack["funds"] = {};
  for (const key of fundsOf(profile)) {
    const fund = file.funds?.[key];
    if (fund === undefined) continue;
    funds[key] = {
      fund: await viem.getContractAt("Fund", fund.fund),
      rule: await viem.getContractAt("FundHoldersRule", fund.rule),
      cap: wholeNumber(fund.cap, `funds.${key}.cap`),
      classes: classesOf(profile, key),
    };
  }
  for (const key of Object.keys(file.funds ?? {})) {
    if (funds[key] === undefined) throw new StackFileError(`the profile ${file.profile} has no fund named ${key}`);
  }
  const [firstFund] = Object.values(funds);

  const deployed: Stack["deployed"] = [];
  for (const { product, address } of placed) deployed.push({ product, contract: await attach(product.template, address) });

  return {
    publicClient,
    accounts: file.accounts,
    parameters: parameters as Stack["parameters"],
    profile,
    legos: file.legos ?? {},
    timelock: await viem.getContractAt("GovernanceTimelock", core.timelock),
    recoveryTimelock: await viem.getContractAt("GovernanceTimelock", core.recoveryTimelock),
    registry: await viem.getContractAt("PolicyRegistry", core.registry),
    hook: await viem.getContractAt("ComplianceHook", core.hook),
    proxyDeployer: await viem.getContractAt("ProxyDeployer", core.proxyDeployer),
    credentials,
    funds,
    executor: core.executor === undefined ? undefined : await viem.getContractAt("IntentExecutor", core.executor),
    dvpExecutor: core.dvpExecutor === undefined ? undefined : await viem.getContractAt("DvPExecutor", core.dvpExecutor),
    orderSettlement: core.orderSettlement === undefined ? undefined : await viem.getContractAt("OrderSettlement", core.orderSettlement),
    signedEntry: core.signedEntry === undefined ? undefined : await viem.getContractAt("SignedEntry", core.signedEntry),
    signedExit: core.signedExit === undefined ? undefined : await viem.getContractAt("SignedExit", core.signedExit),
    lienVault: core.lienVault === undefined ? undefined : await viem.getContractAt("LienVault", core.lienVault),
    rules: {
      credentialRule,
      minPositionRule: core.minPositionRule === undefined ? undefined : await viem.getContractAt("MinPositionRule", core.minPositionRule),
      holderRestrictionRule: core.holderRestrictionRule === undefined ? undefined : await viem.getContractAt("HolderRestrictionRule", core.holderRestrictionRule),
      windowRule: core.windowRule === undefined ? undefined : await viem.getContractAt("SettlementWindowRule", core.windowRule),
      supplyCapRule: core.supplyCapRule === undefined ? undefined : await viem.getContractAt("SupplyCapRule", core.supplyCapRule),
      executedOnlyRule: core.executedOnlyRule === undefined ? undefined : await viem.getContractAt("ExecutedOnlyRule", core.executedOnlyRule),
      fundHoldersRule: firstFund?.rule,
    },
    deployed,
  };
}
