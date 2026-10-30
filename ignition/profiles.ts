import { QUALS, RULE_ORDER, TOKENS } from "./modules/roles.js";

/** The rules a product can list, by the key each module and parameter uses. */
export type RuleKey = "credentialRule" | "minPositionRule" | "holderRestrictionRule" | "windowRule" | "fundHoldersRule";
export type Template = "GatedToken" | "IntentToken" | "Gated4626Vault" | "Gated7540Vault";
/** `ICredentialRule.Policy`: the qualification bits a receiver needs, and the attesters this token trusts. */
export type Policy = { requireAll: number; requireAny: number; forbidAny: number; attesters: bigint };

/** One product of the issuer: a proxy over its template's implementation, with its own rule list and policy. */
export type Product = {
  key: string;
  template: Template;
  name: string;
  symbol: string;
  rules: readonly RuleKey[];
  /** Who may receive it. KYC from attester 0 unless stated. */
  policy?: Policy;
  /** The decimals of a `GatedToken`: for a cash token, its ledger's precision. 18 unless stated. */
  decimals?: number;
  /** The key of the fund it is a class of. Needed exactly when it lists `fundHoldersRule`. */
  fund?: string;
  /** For a vault: the key of an earlier product that is its asset. Otherwise the `asset` parameter. */
  assetProduct?: string;
  /** The executors that hold EXECUTOR_ROLE on an `IntentToken`. */
  executors?: readonly ("intent" | "dvp")[];
};

/** A combination the issuer deploys: what `Core` must contain follows from it. */
export type Profile = { id: string; products: readonly Product[] };

export const DEFAULT_POLICY: Policy = { requireAll: QUALS.KYC, requireAny: 0, forbidAny: 0, attesters: 1n };

/** The implementation's key in `Core` and in the parameters, per template. One implementation serves every product. */
export const IMPLEMENTATION_KEY: Record<Template, string> = {
  GatedToken: "gatedImpl",
  IntentToken: "intentImpl",
  Gated4626Vault: "fundImpl",
  Gated7540Vault: "asyncFundImpl",
};

/** `SettlementWindowRule` judges EXECUTED movements only, and only an `IntentToken` has them. */
const RULES_NEEDING_INTENTS: readonly RuleKey[] = ["windowRule"];

/** Throws for a rule list the template cannot use, so a mistake stops when the module is built, not on chain. */
export function assertUsable(product: Product) {
  for (const rule of product.rules) {
    if (RULES_NEEDING_INTENTS.includes(rule) && product.template !== "IntentToken") {
      throw new Error(`${product.key}: ${product.template} cannot use ${rule}`);
    }
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

export const PROFILES = {
  /** One plain token, alone. */
  token: {
    id: "token",
    products: [{ key: "token", template: "GatedToken", name: "Gated Token", symbol: "GTK", rules: PLAIN_RULES }],
  },
  /** One instant vault, alone. */
  vault4626: {
    id: "vault4626",
    products: [{ key: "fund", template: "Gated4626Vault", ...TOKENS.fund, rules: PLAIN_RULES }],
  },
  /** One request-and-claim vault, alone. */
  vault7540: {
    id: "vault7540",
    products: [{ key: "asyncFund", template: "Gated7540Vault", ...TOKENS.asyncFund, rules: PLAIN_RULES }],
  },
  /** The demo: an intent token and both vaults, as three classes of one fund, with both executors. */
  full: {
    id: "full",
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
