import assert from "node:assert/strict";

import type { NetworkConnection } from "hardhat/types/network";
import {
  BaseError,
  ContractFunctionRevertedError,
  decodeErrorResult,
  isAddressEqual,
  keccak256,
  toHex,
  type Abi,
  type Address,
  type Hex,
} from "viem";

import Activate from "../../ignition/modules/Activate.js";
import Components from "../../ignition/modules/Components.js";
import { ROLES, RULE_ORDER } from "../../ignition/modules/roles.js";
import Tokens from "../../ignition/modules/Tokens.js";

/**
 * Runs the production deployment: the three Ignition modules, which are where deployment order lives (Phase 6 Q2),
 * with this file playing the parties Ignition cannot sign for:
 *
 *   Components → council attests rules + implementations → Tokens → council attests hooks → Activate
 *   → identity provider verifies holders and the 7540 escrow vault → hand-over check.
 *
 * Each stage gets the previous stages' addresses as parameters, as a live deployment does between council steps
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
/** The fund-wide investor cap, one number for the three demo classes. */
export const FUND_HOLDER_CAP = 3n;

const ATTEST = { HOOK: 1, RULE: 2, IMPLEMENTATION: 3 } as const;

export async function deployStack(connection: NetworkConnection) {
  const { activate, parameters } = await deployUntilActivate(connection);
  return activate(parameters);
}

/**
 * Stages 1–2 and both council steps. Returns `Activate`'s parameters and a function that runs stage 3 with them and
 * finishes the deployment, so a test can run stage 3 on tampered parameters and inspect what was left behind.
 */
export async function deployUntilActivate(connection: NetworkConnection) {
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
    fulfiller,
    custody,
    recovery,
    alice,
    bob,
    carol,
    dave,
    eve,
  ] = await viem.getWalletClients();
  const address = (w: typeof deployer) => w.account.address;

  // Deterministic calendar: everything below happens inside the settlement window (Mon 10:00 UTC onwards).
  await networkHelpers.time.increaseTo(MONDAY_10AM);

  // External to the stack: the identity provider's registry and the vaults' asset.
  const identity = await viem.deployContract("MockIdentityRegistry");
  const asset = await viem.deployContract("MockAsset", [6]);

  const components = await ignition.deploy(Components, {
    parameters: {
      Components: {
        governance: address(governance),
        council: address(attester),
        guardian: address(guardian),
        identityRegistry: identity.address,
      },
    },
  });
  const {
    timelock,
    recoveryTimelock,
    registry,
    identityRule,
    lockupRule,
    windowRule,
    maxHoldersRule,
    fundContract,
    fundHoldersRule,
    proxyDeployer,
    executor,
  } =
    components;
  const attest = async (target: Address, kind: number, uri: string) => {
    const code = await publicClient.getCode({ address: target });
    await registry.write.attest([keccak256(code!), kind, uri], { account: attester.account });
  };

  // Council step 1.
  for (const rule of [identityRule, lockupRule, windowRule, maxHoldersRule, fundHoldersRule]) {
    await attest(rule.address, ATTEST.RULE, `ipfs://rule-review/${rule.address}`);
  }
  for (const impl of [components.intentImpl, components.fundImpl, components.asyncFundImpl]) {
    await attest(impl.address, ATTEST.IMPLEMENTATION, `ipfs://impl-review/${impl.address}`);
  }

  const addresses = {
    timelock: timelock.address,
    registry: registry.address,
    proxyDeployer: proxyDeployer.address,
    identityRule: identityRule.address,
    lockupRule: lockupRule.address,
    windowRule: windowRule.address,
    maxHoldersRule: maxHoldersRule.address,
    fundHoldersRule: fundHoldersRule.address,
    intentImpl: components.intentImpl.address,
    fundImpl: components.fundImpl.address,
    asyncFundImpl: components.asyncFundImpl.address,
  };
  const hooks = await ignition.deploy(Tokens, { parameters: { Tokens: addresses } });

  // Council step 2.
  for (const hook of Object.values(hooks)) {
    await attest(hook.address, ATTEST.HOOK, `ipfs://hook-review/${hook.address}`);
  }

  const parameters = {
    ...addresses,
    executor: executor.address,
    guardian: address(guardian),
    governance: address(governance),
    recoveryTimelock: recoveryTimelock.address,
    asset: asset.address,
    custody: address(custody),
    intentHook: hooks.intentHook.address,
    fundHook: hooks.fundHook.address,
    asyncFundHook: hooks.asyncFundHook.address,
    minter: address(minter),
    burner: address(burner),
    agent: address(agent),
    operator: address(operator),
    fulfiller: address(fulfiller),
    holderCap: HOLDER_CAP,
    fundContract: fundContract.address,
    fundHolderCap: FUND_HOLDER_CAP,
    windowOpen: WINDOW_OPEN,
    windowClose: WINDOW_CLOSE,
    windowDays: await windowRule.read.MON_TO_FRI(),
  };

  const activate = async (activateParameters: typeof parameters) => {
    const tokens = await ignition.deploy(Activate, { parameters: { Activate: activateParameters } });
    const token = tokens.intent;
    const vault4626 = tokens.fund;
    const vault7540 = tokens.asyncFund;

    // Identity provider: the holders used by the tests, the recovery account and the 7540 escrow vault.
    for (const w of [alice, bob, carol, dave, recovery]) await identity.write.set([address(w), true]);
    await identity.write.set([vault7540.address, true]);

    const stack = {
      publicClient,
      wallets: { deployer, governance, attester, guardian, minter, burner, agent, operator, fulfiller, custody, recovery },
      holders: { alice, bob, carol, dave, eve },
      timelock,
      recoveryTimelock,
      registry,
      identity,
      rules: { identityRule, lockupRule, windowRule, maxHoldersRule, fundHoldersRule },
      fund: fundContract,
      proxyDeployer,
      asset,
      token,
      vault4626,
      vault7540,
      executor,
      hooks: { token: hooks.intentHook, vault4626: hooks.fundHook, vault7540: hooks.asyncFundHook },
      implementations: {
        token: components.intentImpl,
        vault4626: components.fundImpl,
        vault7540: components.asyncFundImpl,
      },
    };
    await assertHandedOver(stack);
    return stack;
  };
  return { activate, parameters, components, hooks, wallets: { deployer, agent, operator, governance, guardian } };
}

export type Stack = Awaited<ReturnType<typeof deployStack>>;

/**
 * Hand-over check, the same one the runbook prescribes after a live deployment:
 * - the deployer holds no role (every `*_ROLE()` getter, so later roles are covered) on the timelock, registry,
 *   tokens or executor, while the timelock holds DEFAULT_ADMIN_ROLE on each, so the check is not vacuous;
 * - UPGRADER_ROLE is held by the timelock and nobody else that the stack knows about;
 * - every token runs the hook the council reviewed, bound to it, administered by the timelock, with the intended
 *   ordered rule list (`RULE_ORDER`); rules have no access control of their own;
 * - the guardian can cancel timelock operations but cannot propose or execute them;
 * - `ProxyDeployer` is owned by the timelock, so no token can be placed outside governance;
 * - the fund is owned by the timelock, runs the attested rule that points back at it, has the intended cap, and holds
 *   the three tokens as its classes, in that order;
 * - the recovery timelock holds exactly RECOVERY_ROLE on each token, the executor and the main timelock (nothing else,
 *   nowhere else), has no cancellers, and the guardian holds nothing on it.
 */
async function assertHandedOver(s: Omit<Stack, "holders" | "identity" | "asset" | "implementations">) {
  const deployer = s.wallets.deployer.account.address;
  const timelock = s.timelock.address;
  const known = Object.values(s.wallets).map((w) => w.account.address);
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
  for (const c of [s.timelock, s.recoveryTimelock, s.registry, s.token, s.vault4626, s.vault7540, s.executor]) {
    assert.deepEqual(await heldBy(c, deployer), [], `deployer holds roles on ${c.address}`);
  }
  for (const c of [s.timelock, s.registry, s.token, s.vault4626, s.vault7540, s.executor]) {
    assert.ok((await heldBy(c, timelock)).includes(ROLES.DEFAULT_ADMIN), `timelock lacks DEFAULT_ADMIN_ROLE on ${c.address}`);
  }
  // M-1: the recovery timelock's complete role set, pinned so a change that widens it fails the deploy.
  const recovery = s.recoveryTimelock.address;
  const expectedRecoveryRoles: [Gated, Hex[]][] = [
    [s.timelock, [ROLES.RECOVERY]],
    [s.token, [ROLES.RECOVERY]],
    [s.vault4626, [ROLES.RECOVERY]],
    [s.vault7540, [ROLES.RECOVERY]],
    [s.executor, [ROLES.RECOVERY]],
    [s.registry, []],
    [s.recoveryTimelock, [ROLES.DEFAULT_ADMIN]], // OZ makes every timelock its own admin
  ];
  for (const [c, roles] of expectedRecoveryRoles) {
    assert.deepEqual(await heldBy(c, recovery), [...roles].sort(), `recovery timelock role set on ${c.address}`);
  }
  assert.deepEqual(await heldBy(s.recoveryTimelock, s.wallets.guardian.account.address), [], "guardian holds roles on the recovery timelock");
  for (const account of known) {
    assert.equal(await s.recoveryTimelock.read.hasRole([ROLES.CANCELLER, account]), false, `${account} can cancel recovery`);
  }
  const governance = s.wallets.governance.account.address;
  assert.equal(await s.recoveryTimelock.read.hasRole([await s.recoveryTimelock.read.PROPOSER_ROLE(), governance]), true);
  assert.equal(await s.recoveryTimelock.read.hasRole([await s.recoveryTimelock.read.EXECUTOR_ROLE(), governance]), true);
  assert.ok((await s.recoveryTimelock.read.getMinDelay()) >= 7n * 86_400n, "recovery timelock delay below 7 days");
  for (const t of [s.token, s.vault4626, s.vault7540]) {
    assert.equal(await t.read.hasRole([ROLES.UPGRADER, timelock]), true, `timelock lacks UPGRADER_ROLE on ${t.address}`);
    for (const account of known) assert.equal(await t.read.hasRole([ROLES.UPGRADER, account]), false, `${account} can upgrade`);
  }
  // `s.hooks` are the hooks the council reviewed (stage 2). A twin with the same immutables shares their attested
  // codehash whatever its rules, so check the token runs that exact hook and that its rule list is the intended one.
  const bound = [
    [s.hooks.token, s.token, RULE_ORDER.intent],
    [s.hooks.vault4626, s.vault4626, RULE_ORDER.fund],
    [s.hooks.vault7540, s.vault7540, RULE_ORDER.asyncFund],
  ] as const;
  for (const [hook, t, order] of bound) {
    assert.ok(isAddressEqual(await hook.read.TOKEN(), t.address), `hook ${hook.address} bound elsewhere`);
    assert.ok(isAddressEqual(await t.read.policyHook(), hook.address), `token ${t.address} runs another hook`);
    assert.ok(isAddressEqual(await hook.read.ADMIN(), timelock), `hook ${hook.address} admin`);
    const expected = order.map((name) => s.rules[name].address);
    const actual = await hook.read.rules();
    assert.equal(actual.length, expected.length, `hook ${hook.address} rule count`);
    actual.forEach((rule, i) => assert.ok(isAddressEqual(rule, expected[i]), `hook ${hook.address} rule ${i}`));
  }
  for (const rule of Object.values(s.rules)) {
    const names = (rule.abi as Abi).flatMap((item) => (item.type === "function" ? [item.name] : []));
    assert.ok(!names.includes("hasRole") && !names.includes("owner"), `rule ${rule.address} has its own access control`);
  }
  assert.ok(isAddressEqual(await s.proxyDeployer.read.owner(), timelock), "ProxyDeployer is not owned by the timelock");
  assert.ok(isAddressEqual(await s.fund.read.owner(), timelock), "the fund is not owned by the timelock");
  assert.ok(isAddressEqual(await s.fund.read.rule(), s.rules.fundHoldersRule.address), "the fund runs another rule");
  assert.ok(isAddressEqual(await s.rules.fundHoldersRule.read.FUND(), s.fund.address), "the fund rule points at another fund");
  assert.equal(await s.registry.read.isAttested([s.rules.fundHoldersRule.address, ATTEST.RULE]), true, "the fund rule is not attested");
  assert.equal(await s.fund.read.holderCap(), FUND_HOLDER_CAP, "fund cap");
  const classes = [s.token, s.vault4626, s.vault7540];
  assert.equal(await s.fund.read.classCount(), BigInt(classes.length), "class count");
  for (const [i, t] of classes.entries()) {
    assert.ok(isAddressEqual(await s.fund.read.classAt([BigInt(i + 1)]), t.address), `class ${i + 1} is not ${t.address}`);
  }
  const guardian = s.wallets.guardian.account.address;
  assert.equal(await s.timelock.read.hasRole([await s.timelock.read.CANCELLER_ROLE(), guardian]), true);
  assert.equal(await s.timelock.read.hasRole([await s.timelock.read.PROPOSER_ROLE(), guardian]), false);
  assert.equal(await s.timelock.read.hasRole([await s.timelock.read.EXECUTOR_ROLE(), guardian]), false);
  assert.ok((await s.timelock.read.getMinDelay()) >= 7n * 86_400n, "timelock delay below 7 days");
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
