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
export type Template = "GatedToken" | "IntentToken" | "Gated4626Vault" | "Gated7540Vault";
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
};

/** The roles the hand-over check wants held by a Safe of at least two signers. A desk holds the settler's, where there is one. */
export type SensitiveRole = "minter" | "burner" | "agent" | "settler";

/**
 * A combination the issuer deploys: what `Core` must contain follows from it. `singleSigners` names roles the hand-over check
 * lets a single key hold, for example an MPC custody wallet whose policy engine does the same job. A real deployment states
 * each one on purpose.
 */
export type Profile = { id: string; products: readonly Product[]; singleSigners?: readonly SensitiveRole[] };

export const DEFAULT_POLICY: Policy = { requireAll: QUALS.KYC, requireAny: 0, forbidAny: 0, attesters: 1n };

/** The implementation's key in `Core` and in the parameters, per template. One implementation serves every product. */
export const IMPLEMENTATION_KEY: Record<Template, string> = {
  GatedToken: "gatedImpl",
  IntentToken: "intentImpl",
  Gated4626Vault: "fundImpl",
  Gated7540Vault: "asyncFundImpl",
};

/** `SettlementWindowRule` judges EXECUTED movements only, and only an `IntentToken` has them. */
const RULES_NEEDING_INTENTS: readonly RuleKey[] = ["windowRule", "executedOnlyRule"];

/** A supply cap would refuse the large mint a vault's `maxDeposit` probes with, so it would read zero for everybody. */
const RULES_FOR_TOKENS_ONLY: readonly RuleKey[] = ["supplyCapRule"];

/** Throws for a rule list the template cannot use, so a mistake stops when the module is built, not on chain. */
export function assertUsable(product: Product) {
  for (const rule of product.rules) {
    if (RULES_NEEDING_INTENTS.includes(rule) && product.template !== "IntentToken") {
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
  const listsFundRule = product.rules.includes("fundHoldersRule");
  if (listsFundRule && product.fund === undefined) throw new Error(`${product.key}: fundHoldersRule needs a fund`);
  if (!listsFundRule && product.fund !== undefined) throw new Error(`${product.key}: names a fund without fundHoldersRule`);
}

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
