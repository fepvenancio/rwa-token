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
 * Each token's ordered rule list (brief §6: Identity → Lockup → SettlementWindow → MaxHolders; vaults have no EXECUTED
 * transfers to window). `Tokens` builds the hooks from it and the post-deploy check compares `hook.rules()` against it:
 * a hook's attested codehash covers its immutables, not this list.
 */
export const RULE_ORDER = {
  intent: ["identityRule", "lockupRule", "windowRule", "maxHoldersRule"],
  fund: ["identityRule", "lockupRule", "maxHoldersRule"],
  asyncFund: ["identityRule", "lockupRule", "maxHoldersRule"],
} as const satisfies Record<keyof typeof TOKENS, readonly string[]>;
