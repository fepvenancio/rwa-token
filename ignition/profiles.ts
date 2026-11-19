// SPDX-License-Identifier: UNLICENSED
import { QUALS, RULE_ORDER, TOKENS } from "./modules/roles.js";

/** The rules a product can list, by the key each module and parameter uses. */
export type RuleKey =
  | "credentialRule"
  | "minPositionRule"
  | "holderRestrictionRule"
  | "windowRule"
  | "fundHoldersRule"
  | "supplyCapRule"
  | "executedOnlyRule";
export type Template = "GatedToken" | "IntentToken" | "Gated721" | "Gated1155" | "Gated4626Vault" | "Gated7540Vault";
/** `ICredentialRule.Policy`: the qualification bits a receiver needs, and the attesters this token trusts. */
export type Policy = { requireAll: number; requireAny: number; forbidAny: number; attesters: bigint };

/** Each risk's caps, as `Portfolio.setCaps` takes them. */
export type Caps = { absoluteCap: bigint; relativeCapBps: bigint };
/** A `GuardedAccount` with one permission: the asset's `transfer` to one custodian. Reported, so behind a 7540 only. */
export type Custodian = Caps & { key: string; maxPerCall: bigint };
/** An `ERC4626Adapter` over an outside vault. */
export type Target = Caps & { key: string };
/** A `FeeModel`'s terms. */
export type Fees = { managementBps: bigint; performanceBps: bigint; hurdleBps: bigint; softHurdle: boolean };
/** A `NavDesk`'s schedule, in seconds, and the redemption gate's level, in basis points, which each product takes from its own documents. */
export type Nav = { periodLength: bigint; cooldown: bigint; maxReportAge: bigint; redemptionGateBps?: bigint };

/** One product of the issuer: a proxy over its template's implementation, with its own rule list and policy. */
export type Product = {
  key: string;
  template: Template;
  name: string;
  symbol: string;
  rules: readonly RuleKey[];
  /** Who may receive it. KYC from attester 0 unless stated. */
  policy?: Policy;
  /** The decimals of a `GatedToken` or an `IntentToken`: for a cash token, its ledger's precision. 18 unless stated. */
  decimals?: number;
  /** The key of the fund it is a class of. Needed exactly when it lists `fundHoldersRule`. */
  fund?: string;
  /** For a vault: the key of an earlier product that is its asset. Otherwise the `asset` parameter. */
  assetProduct?: string;
  /** The executors that hold EXECUTOR_ROLE on an `IntentToken`. */
  executors?: readonly ("intent" | "dvp")[];
  /**
   * A 7540's price desk: it holds SETTLER_ROLE, and a maker and a checker approve every price. With none the role goes to
   * the `settler` account, which sets any price alone: for a test stack, never a real product.
   */
  nav?: Nav;
  /** Where the vault's money may go. With none a 4626 keeps its own, and a 7540's desk names a custodian account. */
  portfolio?: { custodians?: readonly Custodian[]; targets?: readonly Target[]; maxRateBps?: bigint };
  /** A fee model, on a 7540's desk or a 4626 with a portfolio. */
  fees?: Fees;
  /** Refuses on-chain yield: only custodians may hold its money, for a fund that sells no such exposure. */
  custodyOnly?: boolean;
  /**
   * A `Distributor` for this product's holders: `Legos` deploys it and `Product` grants its maker and its checker. The checker
   * is the `checker` account, which on a 7540 with a desk also approves prices.
   */
  distributor?: boolean;
};

/** The roles the hand-over check wants held by a Safe of at least two signers. A desk holds the settler's, where there is one. */
export type SensitiveRole = "minter" | "burner" | "agent" | "settler";

/**
 * A combination the issuer deploys: what `Core` must contain follows from it. `singleSigners` names roles the hand-over check
 * lets a single key hold, for example an MPC custody wallet whose policy engine does the same job. A real deployment states
 * each one on purpose. `signedEntry` adds the one `SignedEntry` the issuer's vaults can be entered through, and `signedExit`
 * the one `SignedExit` they can be left through and a 7540's settled claims delivered by.
 *
 * `credentials` chooses the KYC registry: `"own"` (the default) deploys the core's own `CredentialRegistry` and
 * `CredentialRule`; `"external"` deploys neither, and the deployment's parameters name an existing `credentialRule` and the
 * governance the issuer accepts over the registry it reads (`credentialAdmin`, `credentialGuardian`), which the hand-over
 * check pins. That governance then decides who may receive the issuer's tokens.
 */
export type Profile = {
  id: string;
  products: readonly Product[];
  singleSigners?: readonly SensitiveRole[];
  signedEntry?: boolean;
  signedExit?: boolean;
  credentials?: "own" | "external";
};

export const DEFAULT_POLICY: Policy = { requireAll: QUALS.KYC, requireAny: 0, forbidAny: 0, attesters: 1n };

/** The implementation's key in `Core` and in the parameters, per template. One implementation serves every product. */
export const IMPLEMENTATION_KEY: Record<Template, string> = {
  GatedToken: "gatedImpl",
  IntentToken: "intentImpl",
  Gated721: "nftImpl",
  Gated1155: "multiImpl",
  Gated4626Vault: "fundImpl",
  Gated7540Vault: "asyncFundImpl",
};

/** `SettlementWindowRule` judges EXECUTED movements only, and only an `IntentToken` has them. */
const RULES_NEEDING_INTENTS: readonly RuleKey[] = ["windowRule", "executedOnlyRule"];

/**
 * Rules an ERC-721 cannot use: a minimum position counts units, which mean nothing for unique tokens, and the fund cap and
 * the supply cap read an ERC-20 `totalSupply` the NFT does not have.
 */
const RULES_NOT_FOR_NFTS: readonly RuleKey[] = ["minPositionRule", "fundHoldersRule", "supplyCapRule"];

/**
 * Rules an ERC-1155 cannot use: the supply cap reads `totalSupply()`, which there is the sum over every token id, and a
 * fund counts one balance for each class, which a contract of many ids does not have.
 */
const RULES_NOT_FOR_MULTI_TOKENS: readonly RuleKey[] = ["fundHoldersRule", "supplyCapRule"];

/** A supply cap would refuse the large mint a vault's `maxDeposit` probes with, so it would read zero for everybody. */
const RULES_FOR_TOKENS_ONLY: readonly RuleKey[] = ["supplyCapRule"];

/** Throws for a rule list the template cannot use, so a mistake stops when the module is built, not on chain. */
export function assertUsable(product: Product) {
  for (const rule of product.rules) {
    if (RULES_NEEDING_INTENTS.includes(rule) && product.template !== "IntentToken") {
      throw new Error(`${product.key}: ${product.template} cannot use ${rule}`);
    }
    if (RULES_NOT_FOR_NFTS.includes(rule) && product.template === "Gated721") {
      throw new Error(`${product.key}: ${product.template} cannot use ${rule}`);
    }
    if (RULES_NOT_FOR_MULTI_TOKENS.includes(rule) && product.template === "Gated1155") {
      throw new Error(`${product.key}: ${product.template} cannot use ${rule}`);
    }
  }
  const isVault = product.template === "Gated4626Vault" || product.template === "Gated7540Vault";
  for (const rule of product.rules) {
    if (RULES_FOR_TOKENS_ONLY.includes(rule) && isVault) throw new Error(`${product.key}: a vault cannot use ${rule}`);
  }
  if (product.nav !== undefined && product.template !== "Gated7540Vault") throw new Error(`${product.key}: only a 7540 has a desk`);
  if (product.portfolio !== undefined && !isVault) throw new Error(`${product.key}: only a vault has a portfolio`);
  if (product.template === "Gated7540Vault" && product.portfolio !== undefined && product.nav === undefined) {
    throw new Error(`${product.key}: a portfolio behind a 7540 needs a desk to price it`);
  }
  if (product.template === "Gated4626Vault" && product.portfolio !== undefined) {
    if ((product.portfolio.custodians ?? []).length !== 0) {
      throw new Error(`${product.key}: a custodian's value is reported, and a stale price on an instant vault is free money`);
    }
    if (product.portfolio.maxRateBps === undefined) throw new Error(`${product.key}: plugging a portfolio must set a rate limit`);
  }
  if (product.fees !== undefined) {
    const priced = product.template === "Gated7540Vault" ? product.nav !== undefined : product.portfolio !== undefined;
    if (!isVault || !priced) throw new Error(`${product.key}: fees need a desk or a portfolio`);
  }
  if (product.custodyOnly && (product.portfolio?.targets ?? []).length !== 0) {
    throw new Error(`${product.key}: custody only, and an ERC4626Adapter is on-chain yield`);
  }
  // Only an IntentToken runs signed intents, so an executor's role on anything else would do nothing.
  if ((product.executors ?? []).length !== 0 && product.template !== "IntentToken") {
    throw new Error(`${product.key}: only an IntentToken has executors`);
  }
  // `Product` passes decimals to the two token templates only: a vault's follow its asset, and an NFT has none.
  if (product.decimals !== undefined && product.template !== "GatedToken" && product.template !== "IntentToken") {
    throw new Error(`${product.key}: ${product.template} cannot set its decimals`);
  }
  const listsFundRule = product.rules.includes("fundHoldersRule");
  if (listsFundRule && product.fund === undefined) throw new Error(`${product.key}: fundHoldersRule needs a fund`);
  if (!listsFundRule && product.fund !== undefined) throw new Error(`${product.key}: names a fund without fundHoldersRule`);
}

/** The rules `CoreParts` deploys, in this order. The fund rule comes with its fund, from the `Fund` module. */
const CORE_RULES: readonly RuleKey[] = ["credentialRule", "minPositionRule", "holderRestrictionRule", "windowRule", "supplyCapRule", "executedOnlyRule"];

/** Every key a part of a core can have: the rules, the implementations, the executors, the signed entry and the signed exit. */
export const PART_KEYS: readonly string[] = [...CORE_RULES, ...Object.values(IMPLEMENTATION_KEY), "executor", "dvpExecutor", "signedEntry", "signedExit"];

/**
 * What a core needs for these products, by the key each part has in the core and in the parameters: the rules, one
 * implementation per template, the executors and the signed entry. `credentialRule` brings its `credentialRegistry`, unless
 * the profile reads an external one.
 */
export function partsOf(profile: Pick<Profile, "products" | "signedEntry" | "signedExit" | "credentials">): string[] {
  const rules = new Set(profile.products.flatMap((product) => product.rules));
  if (profile.credentials === "external") rules.delete("credentialRule");
  const templates = new Set(profile.products.map((product) => product.template));
  const executors = new Set(profile.products.flatMap((product) => product.executors ?? []));
  return [
    ...CORE_RULES.filter((rule) => rules.has(rule)),
    ...(Object.keys(IMPLEMENTATION_KEY) as Template[]).filter((template) => templates.has(template)).map((template) => IMPLEMENTATION_KEY[template]),
    ...(executors.has("intent") ? ["executor"] : []),
    ...(executors.has("dvp") ? ["dvpExecutor"] : []),
    ...(profile.signedEntry ? ["signedEntry"] : []),
    ...(profile.signedExit ? ["signedExit"] : []),
  ];
}

/** The parts these products need that a running core, whose parts are `present`, does not have. */
export const missingParts = (
  profile: Pick<Profile, "products" | "signedEntry" | "signedExit" | "credentials">,
  present: readonly string[],
) =>
  partsOf(profile).filter((part) => !present.includes(part));

/** The funds a profile's products name, each once, in the order they first appear. */
export const fundsOf = (profile: Profile) => [
  ...new Set(profile.products.flatMap((product) => (product.fund === undefined ? [] : [product.fund]))),
];

/** The products that open as a fund's first classes, in order. */
export const classesOf = (profile: Profile, fund: string) =>
  profile.products.filter((product) => product.fund === fund).map((product) => product.key);

/** The core and a few plain rules: who may hold it, and each holder's lockup and freeze. */
const PLAIN_RULES: readonly RuleKey[] = ["credentialRule", "holderRestrictionRule"];

/** The demo stacks run on single test keys, stated here so that a real deployment has to state its own. */
export const DEMO_SIGNERS: readonly SensitiveRole[] = ["minter", "burner", "agent", "settler"];

const DAY = 86_400n;
/** Deals daily, with a day for the guardian and the checker to look at a price, and a report good for three. */
const DAILY: Nav = { periodLength: DAY, cooldown: DAY, maxReportAge: 3n * DAY };

export const PROFILES = {
  /** One plain token, alone. */
  token: {
    id: "token",
    singleSigners: DEMO_SIGNERS,
    products: [{ key: "token", template: "GatedToken", name: "Gated Token", symbol: "GTK", rules: PLAIN_RULES }],
  },
  /** One NFT, alone: a certificate or a note per token, with who may hold it and each holder's lockup and freeze. */
  nft: {
    id: "nft",
    singleSigners: DEMO_SIGNERS,
    products: [{ key: "nft", template: "Gated721", name: "Gated Note", symbol: "gNOTE", rules: PLAIN_RULES }],
  },
  /**
   * One multi-token, alone: several series of one instrument in one contract, each a token id with its own supply, under
   * one set of eligibility terms. Series that differ in who may hold them are separate contracts.
   */
  multi: {
    id: "multi",
    singleSigners: DEMO_SIGNERS,
    products: [{ key: "multi", template: "Gated1155", name: "Gated Series", symbol: "gSER", rules: PLAIN_RULES }],
  },
  /** One intent token, alone: holder-signed movements through either executor. */
  intent: {
    id: "intent",
    singleSigners: DEMO_SIGNERS,
    products: [{ key: "intent", template: "IntentToken", ...TOKENS.intent, rules: PLAIN_RULES, executors: ["intent", "dvp"] }],
  },
  /** One instant vault, alone. */
  vault4626: {
    id: "vault4626",
    singleSigners: DEMO_SIGNERS,
    products: [{ key: "fund", template: "Gated4626Vault", ...TOKENS.fund, rules: PLAIN_RULES }],
  },
  /** A fund whose money sits with one custodian: one request-and-claim vault and its desk. */
  vault7540: {
    id: "vault7540",
    singleSigners: DEMO_SIGNERS,
    products: [{ key: "asyncFund", template: "Gated7540Vault", ...TOKENS.asyncFund, rules: PLAIN_RULES, nav: DAILY }],
  },
  /** A fund with several custodians, a mandate and fees, and no on-chain yield. */
  "managed-fund": {
    id: "managedFund",
    singleSigners: DEMO_SIGNERS,
    products: [
      {
        key: "managedFund",
        template: "Gated7540Vault",
        name: "Managed Fund",
        symbol: "mFUND",
        rules: PLAIN_RULES,
        nav: DAILY,
        custodyOnly: true,
        portfolio: {
          custodians: [
            { key: "firstCustodian", maxPerCall: 1_000_000_000_000n, absoluteCap: 1_000_000_000_000n, relativeCapBps: 10_000n },
            { key: "secondCustodian", maxPerCall: 1_000_000_000_000n, absoluteCap: 1_000_000_000_000n, relativeCapBps: 10_000n },
          ],
        },
        fees: { managementBps: 100n, performanceBps: 1_000n, hurdleBps: 300n, softHurdle: false },
      },
    ],
  },
  /** Liquid yield in on-chain vaults: an instant vault that invests through a portfolio, within a rate limit. */
  "vault4626-invest": {
    id: "vault4626Invest",
    singleSigners: DEMO_SIGNERS,
    products: [
      {
        key: "investFund",
        template: "Gated4626Vault",
        name: "Invest Fund",
        symbol: "iFUND",
        rules: PLAIN_RULES,
        portfolio: {
          targets: [{ key: "onChainVault", absoluteCap: 1_000_000_000_000n, relativeCapBps: 10_000n }],
          maxRateBps: 1_000n,
        },
        fees: { managementBps: 50n, performanceBps: 1_000n, hurdleBps: 0n, softHurdle: false },
      },
    ],
  },
  /** The demo: an intent token and both vaults, as three classes of one fund, with both executors. */
  full: {
    id: "full",
    singleSigners: DEMO_SIGNERS,
    products: [
      { key: "intent", template: "IntentToken", ...TOKENS.intent, rules: RULE_ORDER.intent, fund: "main", executors: ["intent", "dvp"] },
      { key: "fund", template: "Gated4626Vault", ...TOKENS.fund, rules: RULE_ORDER.fund, fund: "main" },
      { key: "asyncFund", template: "Gated7540Vault", ...TOKENS.asyncFund, rules: RULE_ORDER.asyncFund, fund: "main" },
    ],
  },
} as const satisfies Record<string, Profile>;

/** The profile the `ignition deploy` command runs: `PROFILE`, or the demo. */
export function activeProfile(): Profile {
  const id = (process.env.PROFILE ?? "full") as keyof typeof PROFILES;
  const profile = PROFILES[id];
  if (profile === undefined) throw new Error(`Unknown profile ${id}`);
  return profile;
}

/** The fund the `ignition deploy` command deploys or opens: `FUND`, or the profile's first. */
export function activeFund(): string {
  return process.env.FUND ?? fundsOf(activeProfile())[0] ?? "main";
}

/** The product the `ignition deploy` command places: `PRODUCT` within the profile, or its first. */
export function activeProduct(): Product {
  const { products } = activeProfile();
  const product = process.env.PRODUCT === undefined ? products[0] : products.find((candidate) => candidate.key === process.env.PRODUCT);
  if (product === undefined) throw new Error(`Unknown product ${process.env.PRODUCT}`);
  return product;
}
