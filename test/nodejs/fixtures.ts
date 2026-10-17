import assert from "node:assert/strict";

import type { NetworkConnection } from "hardhat/types/network";
import {
  BaseError,
  ContractFunctionRevertedError,
  decodeErrorResult,
  encodeFunctionData,
  getContractAddress,
  isAddressEqual,
  keccak256,
  parseAbi,
  toHex,
  type Abi,
  type Address,
  type Hex,
} from "viem";

/**
 * The single source of deployment order (Phase 6 Q2). Phase 7's Ignition module mirrors this file; it does not
 * re-derive the order:
 *
 *   registry → identity → rules → attest rules → per template: implementation → hook bound to the predicted proxy,
 *   initial rules in its constructor → attest hook and implementation → proxy → configure → hand over.
 *
 * Configure-then-hand-over: the deployer is each contract's admin only while it sets rule parameters and grants
 * operational roles, then grants DEFAULT_ADMIN_ROLE to the admin and renounces. The fixture ends by proving the
 * deployer holds no role anywhere. Phase 6 uses a plain admin account; Phase 7 substitutes the timelock (Q3).
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
] as const;

/** `Errors.sol` reason codes, keyed by name; `reasonName` maps a code back for readable assertions. */
export const REASONS = Object.fromEntries(REASON_NAMES.map((name) => [name, keccak256(toHex(name))])) as Record<
  (typeof REASON_NAMES)[number],
  Hex
>;
export const reasonName = (code: Hex) => REASON_NAMES.find((name) => REASONS[name] === code) ?? code;

/** Mon 2026-10-12 00:00 UTC plus 260 weeks: a Monday in 2031, safely after the local chain's wall clock. */
export const MONDAY = 1_791_763_200n + 260n * 7n * 86_400n;
export const MONDAY_10AM = MONDAY + 10n * 3_600n;
export const WINDOW_OPEN = 9 * 3_600;
export const WINDOW_CLOSE = 17 * 3_600;
export const HOLDER_CAP = 3n;

const ATTEST = { HOOK: 1, RULE: 2, IMPLEMENTATION: 3 } as const;
const DEFAULT_ADMIN_ROLE = `0x${"00".repeat(32)}` as Hex;
// The loops below span contracts whose typed instances do not unify, so they share the OZ AccessControl surface.
const ACCESS_CONTROL = parseAbi([
  "function grantRole(bytes32 role, address account)",
  "function renounceRole(bytes32 role, address callerConfirmation)",
]);

export async function deployStack(connection: NetworkConnection) {
  const { viem, networkHelpers } = connection;
  const publicClient = await viem.getPublicClient();
  const [
    deployer,
    admin,
    attester,
    guardian,
    minter,
    burner,
    agent,
    operator,
    fulfiller,
    custody,
    recovery,
    alice,
    bob,
    carol,
    dave,
    eve,
  ] = await viem.getWalletClients();
  const D = deployer.account.address;

  // Deterministic calendar: everything below happens inside the settlement window (Mon 10:00 UTC onwards).
  await networkHelpers.time.increaseTo(MONDAY_10AM);

  // 1. Registry, identity, rules. Rules are hook-agnostic and shared by every token.
  const registry = await viem.deployContract("PolicyRegistry", [admin.account.address, attester.account.address]);
  const identity = await viem.deployContract("MockIdentityRegistry");
  const identityRule = await viem.deployContract("IdentityRule", [identity.address]);
  const lockupRule = await viem.deployContract("LockupRule");
  const windowRule = await viem.deployContract("SettlementWindowRule");
  const maxHoldersRule = await viem.deployContract("MaxHoldersRule");

  const attest = async (target: Address, kind: number, uri: string) => {
    const code = await publicClient.getCode({ address: target });
    await registry.write.attest([keccak256(code!), kind, uri], { account: attester.account });
  };
  for (const rule of [identityRule, lockupRule, windowRule, maxHoldersRule]) {
    await attest(rule.address, ATTEST.RULE, `ipfs://rule-review/${rule.address}`);
  }

  // 2. Per template: implementation, hook bound to the predicted proxy, attestations, proxy.
  const deployProxied = async (
    name: "IntentToken" | "Gated4626Vault" | "Gated7540Vault",
    rules: Address[],
    initArgs: (hook: Address) => readonly unknown[],
  ) => {
    const impl = await viem.deployContract(name);
    // The hook takes the next nonce and the proxy the one after it; attestations come from the attester.
    const nonce = await publicClient.getTransactionCount({ address: D });
    const predicted = getContractAddress({ from: D, nonce: BigInt(nonce + 1) });
    const hook = await viem.deployContract("ComplianceHook", [admin.account.address, registry.address, predicted, rules]);
    await attest(hook.address, ATTEST.HOOK, `ipfs://hook-review/${name}`);
    await attest(impl.address, ATTEST.IMPLEMENTATION, `ipfs://impl-review/${name}`);
    const data = encodeFunctionData({ abi: impl.abi as Abi, functionName: "initialize", args: initArgs(hook.address) });
    const proxy = await viem.deployContract("ERC1967Proxy", [impl.address, data]);
    assert.ok(isAddressEqual(proxy.address, predicted), `${name}: proxy address prediction`);
    return { impl, hook, address: proxy.address };
  };
  const base = (name: string, symbol: string, hook: Address) =>
    [name, symbol, D, guardian.account.address, registry.address, hook] as const;

  const asset = await viem.deployContract("MockAsset", [6]);
  const tokenDeployment = await deployProxied(
    "IntentToken",
    [identityRule.address, lockupRule.address, windowRule.address, maxHoldersRule.address],
    (hook) => base("Intent Token", "INT", hook),
  );
  const vaultRules = [identityRule.address, lockupRule.address, maxHoldersRule.address];
  const vault4626Deployment = await deployProxied("Gated4626Vault", vaultRules, (hook) => [
    asset.address,
    ...base("Gated Fund", "gFUND", hook),
  ]);
  const vault7540Deployment = await deployProxied("Gated7540Vault", vaultRules, (hook) => [
    asset.address,
    ...base("Gated Async Fund", "gASYNC", hook),
    custody.account.address,
  ]);
  const token = await viem.getContractAt("IntentToken", tokenDeployment.address);
  const vault4626 = await viem.getContractAt("Gated4626Vault", vault4626Deployment.address);
  const vault7540 = await viem.getContractAt("Gated7540Vault", vault7540Deployment.address);

  // 3. Executor: the deployer administers it only while granting OPERATOR_ROLE.
  const executor = await viem.deployContract("IntentExecutor", [D, guardian.account.address]);

  // 4. Configure, while the deployer is still every token's admin.
  await windowRule.write.setWindow([token.address, WINDOW_OPEN, WINDOW_CLOSE, await windowRule.read.MON_TO_FRI()]);
  for (const t of [token, vault4626, vault7540]) await maxHoldersRule.write.setCap([t.address, HOLDER_CAP]);
  // The 7540 vault escrows pending redemptions: a verified holder that never counts against the cap.
  await maxHoldersRule.write.setExemptHolder([vault7540.address, vault7540.address, true]);
  for (const w of [alice, bob, carol, dave, recovery]) await identity.write.set([w.account.address, true]);
  await identity.write.set([vault7540.address, true]);

  await token.write.grantRole([await token.read.MINTER_ROLE(), minter.account.address]);
  await token.write.grantRole([await token.read.BURNER_ROLE(), burner.account.address]);
  await token.write.grantRole([await token.read.EXECUTOR_ROLE(), executor.address]);
  await vault7540.write.grantRole([await vault7540.read.FULFILLER_ROLE(), fulfiller.account.address]);
  const grant = (address: Address, role: Hex, account: Address) =>
    deployer.writeContract({ address, abi: ACCESS_CONTROL, functionName: "grantRole", args: [role, account] });
  for (const t of [token, vault4626, vault7540]) {
    await grant(t.address, await token.read.AGENT_ROLE(), agent.account.address);
    await grant(t.address, await token.read.UPGRADER_ROLE(), admin.account.address);
  }
  await executor.write.grantRole([await executor.read.OPERATOR_ROLE(), operator.account.address]);

  // 5. Hand over: admin in, deployer out.
  for (const c of [token, vault4626, vault7540, executor]) {
    await grant(c.address, DEFAULT_ADMIN_ROLE, admin.account.address);
    await deployer.writeContract({ address: c.address, abi: ACCESS_CONTROL, functionName: "renounceRole", args: [DEFAULT_ADMIN_ROLE, D] });
  }

  const stack = {
    publicClient,
    wallets: { deployer, admin, attester, guardian, minter, burner, agent, operator, fulfiller, custody, recovery },
    holders: { alice, bob, carol, dave, eve },
    registry,
    identity,
    rules: { identityRule, lockupRule, windowRule, maxHoldersRule },
    asset,
    token,
    vault4626,
    vault7540,
    executor,
    hooks: { token: tokenDeployment.hook, vault4626: vault4626Deployment.hook, vault7540: vault7540Deployment.hook },
    implementations: {
      token: tokenDeployment.impl,
      vault4626: vault4626Deployment.impl,
      vault7540: vault7540Deployment.impl,
    },
  };
  await assertHandedOver(stack);
  return stack;
}

export type Stack = Awaited<ReturnType<typeof deployStack>>;

/**
 * Hand-over check: the deployer holds no role on the registry, token, vaults or executor; it is not any hook's admin;
 * and rules have no access control of their own (they defer to the token's roles). The admin holds DEFAULT_ADMIN_ROLE
 * everywhere, so the negative check cannot pass on a contract that has no admin at all.
 */
async function assertHandedOver(s: {
  publicClient: Stack["publicClient"];
  wallets: Stack["wallets"];
  registry: Stack["registry"];
  token: Stack["token"];
  vault4626: Stack["vault4626"];
  vault7540: Stack["vault7540"];
  executor: Stack["executor"];
  hooks: Stack["hooks"];
  rules: Stack["rules"];
}) {
  const deployer = s.wallets.deployer.account.address;
  const admin = s.wallets.admin.account.address;
  for (const c of [s.registry, s.token, s.vault4626, s.vault7540, s.executor]) {
    // Every `*_ROLE()` getter in the ABI, so a role added later is covered without editing this list.
    const getters = (c.abi as Abi).filter(
      (item) => item.type === "function" && item.name.endsWith("_ROLE") && item.inputs.length === 0,
    );
    const roles: Hex[] = [DEFAULT_ADMIN_ROLE];
    for (const getter of getters) {
      if (getter.type !== "function") continue;
      roles.push((await s.publicClient.readContract({ address: c.address, abi: c.abi as Abi, functionName: getter.name })) as Hex);
    }
    for (const role of roles) {
      const held = await s.publicClient.readContract({
        address: c.address,
        abi: c.abi as Abi,
        functionName: "hasRole",
        args: [role, deployer],
      });
      assert.equal(held, false, `deployer still holds ${role} on ${c.address}`);
    }
    assert.equal(await c.read.hasRole([DEFAULT_ADMIN_ROLE, admin]), true, `admin lacks DEFAULT_ADMIN_ROLE on ${c.address}`);
  }
  for (const hook of Object.values(s.hooks)) {
    assert.ok(isAddressEqual(await hook.read.ADMIN(), admin), `hook ${hook.address} admin`);
  }
  for (const rule of Object.values(s.rules)) {
    const names = (rule.abi as Abi).flatMap((item) => (item.type === "function" ? [item.name] : []));
    assert.ok(!names.includes("hasRole") && !names.includes("owner"), `rule ${rule.address} has its own access control`);
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
  ],
} as const;

export type Intent = { from: Address; to: Address; amount: bigint; nonce: Hex; deadline: bigint; ref: Hex };

/** The token's EIP-712 domain as the chain reports it (ERC-5267), so signing never re-derives it off-chain. */
export async function intentDomain(token: Stack["token"]) {
  const [, name, version, chainId, verifyingContract] = await token.read.eip712Domain();
  return { name, version, chainId, verifyingContract };
}

/** A fresh intent from `signer`: random nonce (as the signer's HSM would choose), one-hour deadline, random ref. */
export async function signIntent(
  s: Stack,
  signer: Stack["holders"]["alice"],
  fields: { to: Address; amount: bigint; deadline?: bigint },
  domainOverride: Partial<Awaited<ReturnType<typeof intentDomain>>> = {},
) {
  const now = (await s.publicClient.getBlock()).timestamp;
  const intent: Intent = {
    from: signer.account.address,
    to: fields.to,
    amount: fields.amount,
    nonce: toHex(crypto.getRandomValues(new Uint8Array(32))),
    deadline: fields.deadline ?? now + 3_600n,
    ref: toHex(crypto.getRandomValues(new Uint8Array(32))),
  };
  const domain = { ...(await intentDomain(s.token)), ...domainOverride };
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
