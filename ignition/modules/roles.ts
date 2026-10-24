import { keccak256, toHex, type Hex } from "viem";

/** Role ids as the contracts define them: `keccak256('<NAME>')`; DEFAULT_ADMIN_ROLE is zero. */
export const ROLES = {
  DEFAULT_ADMIN: `0x${"00".repeat(32)}` as Hex,
  MINTER: keccak256(toHex("MINTER_ROLE")),
  BURNER: keccak256(toHex("BURNER_ROLE")),
  AGENT: keccak256(toHex("AGENT_ROLE")),
  GUARDIAN: keccak256(toHex("GUARDIAN_ROLE")),
  PROPOSER: keccak256(toHex("PROPOSER_ROLE")),
  UPGRADER: keccak256(toHex("UPGRADER_ROLE")),
  EXECUTOR: keccak256(toHex("EXECUTOR_ROLE")),
  FULFILLER: keccak256(toHex("FULFILLER_ROLE")),
  OPERATOR: keccak256(toHex("OPERATOR_ROLE")),
  CANCELLER: keccak256(toHex("CANCELLER_ROLE")),
  RECOVERY: keccak256(toHex("RECOVERY_ROLE")),
} as const;

/** Default token identities. A token's symbol is its CREATE2 salt, so `Tokens` and `Activate` must agree on it. */
export const TOKENS = {
  intent: { name: "Intent Token", symbol: "INT" },
  fund: { name: "Gated Fund", symbol: "gFUND" },
  asyncFund: { name: "Gated Async Fund", symbol: "gASYNC" },
} as const;

/**
 * Each token's ordered rule list: Identity, then MinPosition (so the rules after it only ever see real positions), then
 * HolderRestriction, then the SettlementWindow for the intent token (vaults have no EXECUTED transfers to window), then
 * the fund-wide `FundHoldersRule` last. There is no per-class `MaxHoldersRule`: the investor count that matters for a
 * fund is fund-wide (review items, RD5). `Activate` passes each list through the token's init data and `ProxyDeployer`
 * checks it; the post-deploy check compares `hook.rules()` against it, since a hook's attested codehash covers its
 * immutables, not this list.
 */
export const RULE_ORDER = {
  intent: ["identityRule", "minPositionRule", "holderRestrictionRule", "windowRule", "fundHoldersRule"],
  fund: ["identityRule", "minPositionRule", "holderRestrictionRule", "fundHoldersRule"],
  asyncFund: ["identityRule", "minPositionRule", "holderRestrictionRule", "fundHoldersRule"],
} as const satisfies Record<keyof typeof TOKENS, readonly string[]>;
