// SPDX-License-Identifier: UNLICENSED
// The post-deploy check. `npm run check` runs it against a deployed stack (`scripts/check.ts`), and the node tests run
// it on every stack they deploy, through `assertHandedOver` in `test/nodejs/fixtures.ts`.
import assert from "node:assert/strict";

import hre from "hardhat";
import { hashTypedData, isAddressEqual, pad, parseAbi, toFunctionSelector, zeroAddress, zeroHash, type Abi, type Address, type Hex } from "viem";

import { ROLES } from "../../ignition/modules/roles.js";
import { DEFAULT_POLICY } from "../../ignition/profiles.js";
import type { ProfileStack } from "../../test/nodejs/fixtures.js";

type HandedOverKeys = "legos" | "parameters" | "profile" | "publicClient" | "timelock" | "recoveryTimelock" | "registry" | "hook" | "proxyDeployer" | "credentials" | "funds" | "executor" | "dvpExecutor" | "orderSettlement" | "signedEntry" | "signedExit" | "rules" | "deployed";
/**
 * What the check reads: the stack's contracts, its profile, the parameters it was deployed with, and the accounts the
 * deployment names, by name. Addresses only: the check signs nothing.
 */
export type Stack = Pick<ProfileStack, HandedOverKeys> & { accounts: Record<string, Address> };

const LEGO_ABI = parseAbi([
  "function VAULT() view returns (address)",
  "function portfolio() view returns (address)",
  "function feeModel() view returns (address)",
  "function adapters() view returns (address[])",
  "function SETTLEMENT_LOGIC() view returns (address)",
  "function MANAGEMENT_LOGIC() view returns (address)",
  "function redemptionGate() view returns (uint256)",
]);
const SAFE_ABI = parseAbi(["function getThreshold() view returns (uint256)"]);
const DISTRIBUTOR_ABI = parseAbi(["function TOKEN() view returns (address)"]);
/** `OrderSettlement`'s EIP-712 type, as a maker signs it. */
export const ORDER_TYPES = {
  Order: [
    { name: "maker", type: "address" },
    { name: "giveToken", type: "address" },
    { name: "giveId", type: "uint256" },
    { name: "giveAmount", type: "uint256" },
    { name: "takeToken", type: "address" },
    { name: "takeId", type: "uint256" },
    { name: "takeAmount", type: "uint256" },
    { name: "giveIs1155", type: "bool" },
    { name: "takeIs1155", type: "bool" },
    { name: "taker", type: "address" },
    { name: "allOrNothing", type: "bool" },
    { name: "nonce", type: "bytes32" },
    { name: "validAfter", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;
/** `SignedExit`'s EIP-712 type, as a holder signs it. */
export const EXIT_TYPES = {
  Exit: [
    { name: "holder", type: "address" },
    { name: "vault", type: "address" },
    { name: "shares", type: "uint256" },
    { name: "receiver", type: "address" },
    { name: "minAssets", type: "uint256" },
    { name: "asynchronous", type: "bool" },
    { name: "nonce", type: "bytes32" },
    { name: "validAfter", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;
/** `SignedEntry`'s EIP-712 type, as an investor signs it. */
export const ENTRY_TYPES = {
  Entry: [
    { name: "investor", type: "address" },
    { name: "vault", type: "address" },
    { name: "assets", type: "uint256" },
    { name: "minShares", type: "uint256" },
    { name: "asynchronous", type: "bool" },
    { name: "nonce", type: "bytes32" },
    { name: "validAfter", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;
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


/**
 * Hand-over check, the same one the runbook prescribes after a live deployment. It returns what it found wrong, one line
 * for each part that failed, and an empty list for a stack that is as it should be. A part stops at its first failure,
 * so a part with two faults names the first; the parts are independent, so one fault does not hide another part's.
 *
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
 * - each fund is owned by the timelock, runs the attested rule that points back at it, has the intended cap, counts its
 *   investors over the core's credential registry (or over none, when the core has none), and holds the
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
 * - the recovery timelock holds exactly RECOVERY_ROLE on each product, the executors, the core's own credential registry and
 *   the main timelock (nothing else, nowhere else), has no cancellers, and the guardian holds nothing on it;
 * - the credential rule reads the stack's registry and the council attested it, and each product's policy is its profile's
 *   and trusts at least one attester, each of which exists and is not killed. With the core's own registry, the guardian
 *   holds only GUARDIAN_ROLE there and the one attester is the KYC function. With an external one, the rule is the one the
 *   parameters name, the registry is the release's code, `credentialAdmin` holds DEFAULT_ADMIN_ROLE and
 *   `credentialGuardian` GUARDIAN_ROLE there, and no other role there is held by an account the stack knows or by either
 *   timelock;
 * - a profile that asks for a signed entry has one, whose code is the release's and whose EIP-712 domain is its own;
 * - a product's distributor is the release's code, names this product, and its maker and its checker are different
 *   accounts, each the only account the stack knows to hold its role on the token.
 */
export async function handoverFailures(s: Stack): Promise<string[]> {
  const failures: string[] = [];
  /** Runs one part of the check. Its first failed assertion, or a read that reverts, is recorded and the next part runs. */
  const part = async (name: string, body: () => Promise<void>) => {
    try {
      await body();
    } catch (error) {
      failures.push(`${name}: ${error instanceof Error ? error.message : String(error)}`);
    }
  };
  const deployer = s.accounts.deployer;
  const operations = s.accounts.operations;
  const guardian = s.accounts.guardian;
  const timelock = s.timelock.address;
  // The same code as the main timelock, so its delay has the same floor. First, because the role reads below would only
  // revert on another contract.
  await part("the recovery timelock", async () => {
    assert.equal(
      await s.publicClient.getCode({ address: s.recoveryTimelock.address }),
      await s.publicClient.getCode({ address: timelock }),
      "the recovery timelock is not a GovernanceTimelock",
    );
  });
  // Nothing below can be read on another contract.
  if (failures.length > 0) return failures;
  const known = Object.values(s.accounts);
  const named = s.parameters as Record<string, Address>;
  const external = s.profile.credentials === "external";
  const tokens = s.deployed.map(({ contract }) => contract);
  const executors = [s.executor, s.dvpExecutor, s.orderSettlement].filter((c) => c !== undefined);
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
  // An external credential registry is governed elsewhere: its roles are checked with the credential layer below.
  const administered: Gated[] = [s.timelock, s.registry, ...tokens, ...executors, ...(s.credentials === undefined || external ? [] : [s.credentials])];
  await part("roles of the deployer, the operations account and the timelock", async () => {
    for (const c of [s.recoveryTimelock, ...administered]) {
      assert.deepEqual(await heldBy(c, deployer), [], `deployer holds roles on ${c.address}`);
      assert.deepEqual(await heldBy(c, operations), [], `the operations account holds roles on ${c.address}`);
    }
    for (const c of administered) {
      assert.ok((await heldBy(c, timelock)).includes(ROLES.DEFAULT_ADMIN), `timelock lacks DEFAULT_ADMIN_ROLE on ${c.address}`);
    }
  });
  // M-1: the recovery timelock's complete role set, pinned so a change that widens it fails the deploy.
  const recovery = s.recoveryTimelock.address;
  await part("the recovery timelock's roles", async () => {
    const expectedRecoveryRoles: [Gated, Hex[]][] = [
      [s.timelock, [ROLES.RECOVERY]],
      [s.registry, []],
      ...[...tokens, ...executors].map((c): [Gated, Hex[]] => [c, [ROLES.RECOVERY]]),
      // It may clear a guardian block, revive an attester and remove the guardian.
      ...(s.credentials === undefined || external ? [] : [[s.credentials, [ROLES.RECOVERY]] as [Gated, Hex[]]]),
      [s.recoveryTimelock, [ROLES.DEFAULT_ADMIN]], // OZ makes every timelock its own admin
    ];
    for (const [c, roles] of expectedRecoveryRoles) {
      assert.deepEqual(await heldBy(c, recovery), [...roles].sort(), `recovery timelock role set on ${c.address}`);
    }
    assert.deepEqual(await heldBy(s.recoveryTimelock, guardian), [], "guardian holds roles on the recovery timelock");
    for (const account of known) {
      assert.equal(await s.recoveryTimelock.read.hasRole([ROLES.CANCELLER, account]), false, `${account} can cancel recovery`);
    }
  });
  const governance = s.accounts.governance;
  await part("the recovery timelock's governance", async () => {
    assert.equal(await s.recoveryTimelock.read.hasRole([await s.recoveryTimelock.read.PROPOSER_ROLE(), governance]), true);
    assert.equal(await s.recoveryTimelock.read.hasRole([await s.recoveryTimelock.read.EXECUTOR_ROLE(), governance]), true);
    assert.ok((await s.recoveryTimelock.read.getMinDelay()) >= DAY, "recovery timelock delay below 24 hours");
    // No recovery power over itself.
    for (const account of [...known, recovery, timelock]) {
      assert.equal(await s.recoveryTimelock.read.hasRole([ROLES.RECOVERY, account]), false, `${account} holds RECOVERY_ROLE on the recovery timelock`);
    }
  });
  // Each executor: the stack's operator submits through it and the guardian can pause it.
  await part("the executors", async () => {
    for (const executor of executors) {
      assert.deepEqual(await heldBy(executor, s.accounts.operator), [ROLES.OPERATOR], `executor operator on ${executor.address}`);
      assert.deepEqual(await heldBy(executor, guardian), [ROLES.GUARDIAN], `executor guardian on ${executor.address}`);
    }
  });
  /** Whether the code at `address` is the release's, leaving out its immutables, which the caller checks by reading them. */
  const isRelease = async (address: Address, name: string) => {
    const artifact = await hre.artifacts.readArtifact(name);
    let expected = artifact.deployedBytecode.slice(2).toLowerCase();
    let actual = ((await s.publicClient.getCode({ address })) ?? "0x").slice(2).toLowerCase();
    for (const { start, length } of Object.values(artifact.immutableReferences ?? {}).flat()) {
      const blank = "00".repeat(length);
      expected = expected.slice(0, start * 2) + blank + expected.slice((start + length) * 2);
      actual = actual.slice(0, start * 2) + blank + actual.slice((start + length) * 2);
    }
    return actual.length > 0 && actual === expected;
  };
  // The signed entry. Its immutables are its EIP-712 domain, so a sample entry's hash must be the one an investor signs
  // for this chain and this address: that reads every one of them.
  await part("the signed entry", async () => {
    if (s.profile.signedEntry === true || s.signedEntry !== undefined) {
      assert.ok(s.signedEntry !== undefined, "the profile asks for a signed entry and the stack has no signed entry");
      assert.ok(await isRelease(s.signedEntry.address, "SignedEntry"), `the signed entry ${s.signedEntry.address} is not the release's`);
      const sample = {
        investor: s.signedEntry.address,
        vault: s.signedEntry.address,
        assets: 1n,
        minShares: 1n,
        asynchronous: false,
        nonce: zeroHash,
        validAfter: 0n,
        deadline: 1n,
      };
      const domain = { name: "SignedEntry", version: "1", chainId: await s.publicClient.getChainId(), verifyingContract: s.signedEntry.address };
      assert.equal(
        await s.signedEntry.read.entryHash([sample]),
        hashTypedData({ domain, types: ENTRY_TYPES, primaryType: "Entry", message: sample }),
        "the signed entry hashes entries for another domain",
      );
    }
  });
  // The order settlement: the release's code, and a sample order's hash is the one a maker signs for this chain and address.
  await part("the order settlement", async () => {
    if (s.profile.orderSettlement === true || s.orderSettlement !== undefined) {
      assert.ok(s.orderSettlement !== undefined, "the profile asks for an order settlement and the stack has no order settlement");
      assert.ok(await isRelease(s.orderSettlement.address, "OrderSettlement"), `the order settlement ${s.orderSettlement.address} is not the release's`);
      const sample = {
        maker: s.orderSettlement.address,
        giveToken: s.orderSettlement.address,
        giveId: 0n,
        giveAmount: 1n,
        takeToken: s.orderSettlement.address,
        takeId: 0n,
        takeAmount: 1n,
        giveIs1155: false,
        takeIs1155: false,
        taker: zeroAddress,
        allOrNothing: false,
        nonce: zeroHash,
        validAfter: 0n,
        deadline: 1n,
      };
      const domain = { name: "OrderSettlement", version: "1", chainId: await s.publicClient.getChainId(), verifyingContract: s.orderSettlement.address };
      assert.equal(
        await s.orderSettlement.read.orderHash([sample]),
        hashTypedData({ domain, types: ORDER_TYPES, primaryType: "Order", message: sample }),
        "the order settlement hashes orders for another domain",
      );
    }
  });
  // The signed exit, the same way: a sample exit's hash must be the one a holder signs for this chain and this address.
  await part("the signed exit", async () => {
    if (s.profile.signedExit === true || s.signedExit !== undefined) {
      assert.ok(s.signedExit !== undefined, "the profile asks for a signed exit and the stack has no signed exit");
      assert.ok(await isRelease(s.signedExit.address, "SignedExit"), `the signed exit ${s.signedExit.address} is not the release's`);
      const sample = {
        holder: s.signedExit.address,
        vault: s.signedExit.address,
        shares: 1n,
        receiver: s.signedExit.address,
        minAssets: 1n,
        asynchronous: false,
        nonce: zeroHash,
        validAfter: 0n,
        deadline: 1n,
      };
      const domain = { name: "SignedExit", version: "1", chainId: await s.publicClient.getChainId(), verifyingContract: s.signedExit.address };
      assert.equal(
        await s.signedExit.read.exitHash([sample]),
        hashTypedData({ domain, types: EXIT_TYPES, primaryType: "Exit", message: sample }),
        "the signed exit hashes exits for another domain",
      );
    }
  });
  // EXECUTOR_ROLE on an intent token: the executors it names and no account the stack knows about, so nothing can run a
  // signed intent without going through one of them.
  await part("EXECUTOR_ROLE on the intent tokens", async () => {
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
  });
  await part("UPGRADER_ROLE", async () => {
    for (const t of tokens) {
      assert.equal(await t.read.hasRole([ROLES.UPGRADER, timelock]), true, `timelock lacks UPGRADER_ROLE on ${t.address}`);
      for (const account of known) assert.equal(await t.read.hasRole([ROLES.UPGRADER, account]), false, `${account} can upgrade`);
    }
  });
  // `s.hook` is the hook the council reviewed. A second instance on the same registry shares its attested codehash, so
  // check each product runs that exact instance and that its rule list on it is the intended one.
  await part("the hook and the rule lists", async () => {
    assert.ok(isAddressEqual(await s.hook.read.REGISTRY(), s.registry.address), `hook ${s.hook.address} names another registry`);
    for (const { product, contract } of s.deployed) {
      assert.ok(isAddressEqual(await contract.read.policy(), s.hook.address), `token ${contract.address} runs another hook`);
      const expected = product.rules.map((name) => (name === "fundHoldersRule" ? s.funds[product.fund!].rule.address : s.rules[name]!.address));
      const actual = await s.hook.read.rules([contract.address]);
      assert.equal(actual.length, expected.length, `token ${contract.address} rule count`);
      actual.forEach((rule, i) => assert.ok(isAddressEqual(rule, expected[i]), `token ${contract.address} rule ${i}`));
    }
  });
  await part("the rules' access control", async () => {
    for (const rule of Object.values(s.rules)) {
      if (rule === undefined) continue;
      const names = (rule.abi as Abi).flatMap((item) => (item.type === "function" ? [item.name] : []));
      assert.ok(!names.includes("hasRole") && !names.includes("owner"), `rule ${rule.address} has its own access control`);
    }
  });
  await part("ProxyDeployer", async () => {
    assert.ok(isAddressEqual(await s.proxyDeployer.read.owner(), operations), "ProxyDeployer is not owned by the operations account");
  });
  await part("the funds", async () => {
    for (const { fund, rule, cap, classes } of Object.values(s.funds)) {
      assert.ok(isAddressEqual(await fund.read.owner(), timelock), "the fund is not owned by the timelock");
      assert.ok(isAddressEqual(await fund.read.rule(), rule.address), "the fund runs another rule");
      assert.ok(isAddressEqual(await rule.read.FUND(), fund.address), "the fund rule points at another fund");
      assert.equal(await s.registry.read.isAttested([rule.address, ATTEST.RULE]), true, "the fund rule is not attested");
      assert.equal(await fund.read.holderCap(), cap, "fund cap");
      assert.ok(
        isAddressEqual(await fund.read.CREDENTIALS(), s.credentials?.address ?? zeroAddress),
        "the fund counts investors over another credential registry",
      );
      assert.equal(await fund.read.classCount(), BigInt(classes.length), "class count");
      for (const [i, name] of classes.entries()) {
        const t = s.deployed.find(({ product }) => product.key === name)!.contract;
        assert.ok(isAddressEqual(await fund.read.classAt([BigInt(i + 1)]), t.address), `class ${i + 1} is not ${t.address}`);
        assert.equal(await fund.read.isClassIntact([t.address]), true, `class ${i + 1} no longer lists the fund's rule`);
      }
      assert.ok(isAddressEqual(await fund.read.firstBrokenClass(), zeroAddress), "the fund has a broken class");
    }
  });
  // The credential layer: the rule reads this registry and the council attested it. With the core's own registry the
  // guardian can stop (block, kill) and nothing else, and the one attester is the KYC function. With an external one, whose
  // governance decides who may receive every token that reads it, that governance is the one the deployment names.
  await part("the credential layer", async () => {
    if (external) assert.ok(s.credentials !== undefined && s.rules.credentialRule !== undefined, "the profile reads an external credential registry and the stack has none");
    if (s.credentials !== undefined) {
      const credentialRule = s.rules.credentialRule!;
      assert.ok(isAddressEqual(await credentialRule.read.REGISTRY(), s.credentials.address), "the credential rule reads another registry");
      assert.equal(await s.registry.read.isAttested([credentialRule.address, ATTEST.RULE]), true, "the credential rule is not attested");
      if (external) {
        assert.ok(isAddressEqual(credentialRule.address, named.credentialRule), "the credential rule is not the one the deployment names");
        assert.ok(await isRelease(s.credentials.address, "CredentialRegistry"), `${s.credentials.address} is not the release's CredentialRegistry`);
        assert.equal(
          await s.credentials.read.hasRole([ROLES.DEFAULT_ADMIN, named.credentialAdmin]),
          true,
          `credentialAdmin ${named.credentialAdmin} does not hold DEFAULT_ADMIN_ROLE on the credential registry`,
        );
        assert.equal(
          await s.credentials.read.hasRole([ROLES.GUARDIAN, named.credentialGuardian]),
          true,
          `credentialGuardian ${named.credentialGuardian} does not hold GUARDIAN_ROLE on the credential registry`,
        );
        for (const account of [...known, timelock, s.recoveryTimelock.address]) {
          const allowed = [
            ...(isAddressEqual(account, named.credentialAdmin) ? [ROLES.DEFAULT_ADMIN] : []),
            ...(isAddressEqual(account, named.credentialGuardian) ? [ROLES.GUARDIAN] : []),
          ].sort();
          assert.deepEqual(await heldBy(s.credentials, account), allowed, `${account} holds roles on the external credential registry`);
        }
      } else {
        assert.deepEqual(await heldBy(s.credentials, guardian), [ROLES.GUARDIAN], "credential registry guardian");
        assert.equal(await s.credentials.read.attesterCount(), 1n, "attester count");
        const kycAttester = await s.credentials.read.attesterAt([0]);
        assert.ok(isAddressEqual(kycAttester.account, s.accounts.kyc), "attester 0 is not the KYC provider");
        assert.equal(kycAttester.killed, false, "the KYC attester is killed");
      }
      const attesterCount = await s.credentials.read.attesterCount();
      for (const { product, contract } of s.deployed) {
        if (!product.rules.includes("credentialRule")) continue;
        const expected = product.policy ?? DEFAULT_POLICY;
        const policy = await credentialRule.read.policyOf([contract.address]);
        assert.deepEqual(
          [policy.requireAll, policy.requireAny, policy.forbidAny, policy.attesters],
          [expected.requireAll, expected.requireAny, expected.forbidAny, expected.attesters],
          `policy of ${contract.address}`,
        );
        // A policy whose attesters are all missing or killed admits nobody, and one that names a missing id would trust
        // whoever the registry's admin adds under it later.
        assert.notEqual(policy.attesters, 0n, `the policy of ${contract.address} trusts no attester`);
        for (let id = 0n; id < 64n; id++) {
          if (((policy.attesters >> id) & 1n) === 0n) continue;
          assert.ok(id < attesterCount, `the policy of ${contract.address} trusts attester ${id}, which does not exist`);
          const attester: { killed: boolean } = await s.credentials.read.attesterAt([Number(id)]);
          assert.equal(attester.killed, false, `the policy of ${contract.address} trusts attester ${id}, which is killed`);
        }
      }
    }
  });
  await part("the timelocks", async () => {
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
  });

  // A product's legos. Their roles live outside the vault's role scan, so they are asked by name.
  const read = <T>(address: Address, functionName: "VAULT" | "portfolio" | "feeModel" | "adapters" | "SETTLEMENT_LOGIC" | "MANAGEMENT_LOGIC" | "redemptionGate") =>
    s.publicClient.readContract({ address, abi: LEGO_ABI, functionName }) as Promise<T>;
  const isSame = async (address: Address, functionName: "VAULT" | "portfolio" | "feeModel", expected: Address) =>
    isAddressEqual(await read<Address>(address, functionName), expected);
  for (const { product, contract } of s.deployed) {
    await part(`product ${product.key}`, async () => {
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
      // Each vault names a second contract its implementation created: it must be the release's code.
      const second = { Gated7540Vault: ["SETTLEMENT_LOGIC", "Gated7540Settlement"], Gated4626Vault: ["MANAGEMENT_LOGIC", "Gated4626Management"] } as const;
      if (product.template === "Gated7540Vault" || product.template === "Gated4626Vault") {
        const [getter, name] = second[product.template];
        const logic = await read<Address>(contract.address, getter);
        const artifact = await hre.artifacts.readArtifact(name);
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
      if (product.distributor === true) {
        const { distributor } = legos;
        assert.ok(distributor !== undefined, `${contract.address} has no distributor`);
        assert.ok(await isRelease(distributor, "Distributor"), `the distributor of ${contract.address} is not the release's`);
        const token = await s.publicClient.readContract({ address: distributor, abi: DISTRIBUTOR_ABI, functionName: "TOKEN" });
        assert.ok(isAddressEqual(token, contract.address), `the distributor of ${contract.address} names another token`);
        assert.ok(!isAddressEqual(named.distributionMaker, named.checker), `the distribution maker and checker of ${contract.address} are the same account`);
        await heldOnlyBy(ROLES.DISTRIBUTION_MAKER, named.distributionMaker, "distribution maker");
        await heldOnlyBy(ROLES.CHECKER, named.checker, "checker");
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
    });
  }
  return failures;
}

/** Whether an account answers a Safe's `getThreshold()` with two or more. */
async function isMultiSigner(publicClient: Stack["publicClient"], account: Address) {
  try {
    return (await publicClient.readContract({ address: account, abi: SAFE_ABI, functionName: "getThreshold" })) >= 2n;
  } catch {
    return false;
  }
}
