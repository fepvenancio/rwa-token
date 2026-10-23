import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, getAddress, isAddressEqual, keccak256, toHex, zeroHash, type Abi, type Address, type Hex } from "viem";

import { ROLES, RULE_ORDER } from "../../ignition/modules/roles.js";
import { deployStack, revertOf, type Stack } from "./fixtures.js";

const IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const ATTEST = { HOOK: 1, IMPLEMENTATION: 3 } as const;

/** Everything here goes through the real TimelockController: governance proposes and executes, the guardian cancels. */
describe("governance through the timelock", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;
  const stack = () => deployStack(connection);

  let saltCounter = 0;
  async function schedule(s: Stack, target: Address, data: Hex) {
    const governance = s.wallets.governance.account;
    const delay = await s.timelock.read.getMinDelay();
    const args = [target, 0n, data, zeroHash, keccak256(toHex(`op-${saltCounter++}`))] as const;
    await s.timelock.write.schedule([...args, delay], { account: governance });
    return {
      id: await s.timelock.read.hashOperation(args),
      execute: () => s.timelock.write.execute(args, { account: governance }),
      delay,
    };
  }
  const attest = async (s: Stack, target: Address, kind: number) => {
    const code = await s.publicClient.getCode({ address: target });
    await s.registry.write.attest([keccak256(code!), kind, "ipfs://review"], { account: s.wallets.attester.account });
  };
  const implementationOf = async (s: Stack, proxy: Address) =>
    getAddress(`0x${(await s.publicClient.getStorageAt({ address: proxy, slot: IMPLEMENTATION_SLOT }))!.slice(26)}`);
  const upgradeCall = (s: Stack, implementation: Address) =>
    encodeFunctionData({ abi: s.token.abi, functionName: "upgradeToAndCall", args: [implementation, "0x"] });

  it("an upgrade to an attested implementation waits out the delay, then lands", async function () {
    const s = await networkHelpers.loadFixture(stack);
    // UUPS `__self` makes every implementation deployment its own codehash, so this one needs its own attestation.
    const next = await viem.deployContract("IntentToken");
    await attest(s, next.address, ATTEST.IMPLEMENTATION);
    const op = await schedule(s, s.token.address, upgradeCall(s, next.address));

    await viem.assertions.revertWithCustomError(op.execute(), s.timelock, "TimelockUnexpectedOperationState");
    await networkHelpers.time.increase(op.delay - 2n);
    await viem.assertions.revertWithCustomError(op.execute(), s.timelock, "TimelockUnexpectedOperationState");
    await networkHelpers.time.increase(2n);
    await op.execute();
    assert.equal(await implementationOf(s, s.token.address), getAddress(next.address));
  });

  it("an upgrade to an unattested build of the same source is refused at execution", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const before = await implementationOf(s, s.token.address);
    const rogue = await viem.deployContract("IntentToken"); // identical source, never reviewed
    const op = await schedule(s, s.token.address, upgradeCall(s, rogue.address));
    await networkHelpers.time.increase(op.delay);
    const failure = await revertOf(op.execute(), [...s.timelock.abi, ...s.token.abi] as Abi);
    assert.deepEqual(failure, { errorName: "PolicyGated_NotAttested", args: [getAddress(rogue.address), ATTEST.IMPLEMENTATION] });
    assert.equal(await implementationOf(s, s.token.address), before);
  });

  it("nobody but the timelock can upgrade, swap the hook or change the rules directly", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const governance = s.wallets.governance.account;
    await viem.assertions.revertWithCustomError(
      s.token.write.upgradeToAndCall([s.implementations.token.address, "0x"], { account: governance }),
      s.token,
      "AccessControlUnauthorizedAccount",
    );
    await viem.assertions.revertWithCustomError(
      s.token.write.setPolicyHook([s.hooks.token.address], { account: governance }),
      s.token,
      "AccessControlUnauthorizedAccount",
    );
    await viem.assertions.revertWithCustomError(
      s.hooks.token.write.setRules([[s.rules.identityRule.address]], { account: governance }),
      s.hooks.token,
      "ComplianceHook_OnlyAdmin",
    );
  });

  it("the guardian cancels a pending operation but can neither propose nor execute", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const guardian = s.wallets.guardian.account;
    const next = await viem.deployContract("IntentToken");
    await attest(s, next.address, ATTEST.IMPLEMENTATION);
    const op = await schedule(s, s.token.address, upgradeCall(s, next.address));

    await viem.assertions.emitWithArgs(s.timelock.write.cancel([op.id], { account: guardian }), s.timelock, "Cancelled", [op.id]);
    await networkHelpers.time.increase(op.delay);
    await viem.assertions.revertWithCustomError(op.execute(), s.timelock, "TimelockUnexpectedOperationState");

    const args = [s.token.address, 0n, upgradeCall(s, next.address), zeroHash, zeroHash] as const;
    await viem.assertions.revertWithCustomError(
      s.timelock.write.schedule([...args, op.delay], { account: guardian }),
      s.timelock,
      "AccessControlUnauthorizedAccount",
    );
    await viem.assertions.revertWithCustomError(
      s.timelock.write.execute(args, { account: guardian }),
      s.timelock,
      "AccessControlUnauthorizedAccount",
    );
  });

  it("the guardian pauses at once; only the timelock unpauses, after the delay", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const guardian = s.wallets.guardian.account;
    await s.token.write.pause({ account: guardian });
    await s.executor.write.pause({ account: guardian });
    await viem.assertions.revertWithCustomError(
      s.token.write.unpause({ account: guardian }),
      s.token,
      "AccessControlUnauthorizedAccount",
    );

    const unpause = (abi: Abi) => encodeFunctionData({ abi, functionName: "unpause" });
    const token = await schedule(s, s.token.address, unpause(s.token.abi as Abi));
    const executor = await schedule(s, s.executor.address, unpause(s.executor.abi as Abi));
    await networkHelpers.time.increase(token.delay);
    await token.execute();
    await executor.execute();
    assert.equal(await s.token.read.paused(), false);
    assert.equal(await s.executor.read.paused(), false);
  });

  it("a hook swap and a rule-set change take effect only when the timelock executes them", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const { identityRule, lockupRule } = s.rules;
    const replacement = await viem.deployContract("ComplianceHook", [
      s.timelock.address,
      s.registry.address,
      s.token.address,
      [identityRule.address, lockupRule.address],
    ]);
    // Same immutables as the installed hook, so the same codehash: the council's per-token hook attestation already
    // covers it, whatever its rule list. Only the timelock can install it, and only after the delay.
    assert.equal(await s.registry.read.isAttested([replacement.address, ATTEST.HOOK]), true);
    const swap = await schedule(
      s,
      s.token.address,
      encodeFunctionData({ abi: s.token.abi, functionName: "setPolicyHook", args: [replacement.address] }),
    );
    const rules = await schedule(
      s,
      s.hooks.vault4626.address,
      encodeFunctionData({ abi: s.hooks.vault4626.abi, functionName: "setRules", args: [[identityRule.address]] }),
    );

    await networkHelpers.time.increase(swap.delay - 1n);
    assert.equal(getAddress(await s.token.read.policyHook()), getAddress(s.hooks.token.address));
    assert.equal((await s.hooks.vault4626.read.rules()).length, RULE_ORDER.fund.length);
    await networkHelpers.time.increase(1n);
    await viem.assertions.emitWithArgs(swap.execute(), s.token, "PolicyHookChanged", [
      getAddress(s.hooks.token.address),
      getAddress(replacement.address),
    ]);
    await rules.execute();
    assert.deepEqual(await s.hooks.vault4626.read.rules(), [getAddress(identityRule.address)]);
  });

  it("after hand-over a new token can be placed only through the timelock, still bound to its attested hook", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const implementation = s.implementations.token.address;
    const predicted = await s.proxyDeployer.read.predict(["NEW", implementation]);
    const hook = await viem.deployContract("ComplianceHook", [
      s.timelock.address,
      s.registry.address,
      predicted,
      [s.rules.identityRule.address],
    ]);
    await attest(s, hook.address, ATTEST.HOOK);
    const initData = encodeFunctionData({
      abi: s.token.abi,
      functionName: "initialize",
      args: ["New Token", "NEW", s.timelock.address, s.wallets.guardian.account.address, s.registry.address, hook.address],
    });
    const deploy = encodeFunctionData({
      abi: s.proxyDeployer.abi,
      functionName: "deploy",
      args: ["NEW", implementation, initData, hook.address],
    });

    await viem.assertions.revertWithCustomErrorWithArgs(
      s.proxyDeployer.write.deploy(["NEW", implementation, initData, hook.address], { account: s.wallets.deployer.account }),
      s.proxyDeployer,
      "OwnableUnauthorizedAccount",
      [getAddress(s.wallets.deployer.account.address)],
    );
    const op = await schedule(s, s.proxyDeployer.address, deploy);
    await networkHelpers.time.increase(op.delay);
    await op.execute();
    const token = await viem.getContractAt("IntentToken", predicted);
    assert.ok(isAddressEqual(await token.read.policyHook(), hook.address));
    assert.equal(await token.read.hasRole([ROLES.DEFAULT_ADMIN, s.timelock.address]), true);
  });

  it("the timelock is self-administered: governance changes the guardian only through it", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const timelock = s.timelock.address;
    assert.equal(await s.timelock.read.hasRole([ROLES.DEFAULT_ADMIN, timelock]), true);
    const governance = s.wallets.governance.account;
    const newGuardian = s.wallets.recovery.account.address;
    await viem.assertions.revertWithCustomError(
      s.token.write.grantRole([await s.token.read.GUARDIAN_ROLE(), newGuardian], { account: governance }),
      s.token,
      "AccessControlUnauthorizedAccount",
    );
    const op = await schedule(
      s,
      s.token.address,
      encodeFunctionData({
        abi: s.token.abi,
        functionName: "grantRole",
        args: [await s.token.read.GUARDIAN_ROLE(), newGuardian],
      }),
    );
    await networkHelpers.time.increase(op.delay);
    await op.execute();
    assert.equal(await s.token.read.hasRole([await s.token.read.GUARDIAN_ROLE(), newGuardian]), true);
  });

  /** Schedules a batch on the recovery timelock (governance proposes; no one can cancel). */
  async function scheduleRecovery(s: Stack, calls: { target: Address; data: Hex }[]) {
    const governance = s.wallets.governance.account;
    const delay = await s.recoveryTimelock.read.getMinDelay();
    const targets = calls.map((c) => c.target);
    const values = calls.map(() => 0n);
    const payloads = calls.map((c) => c.data);
    const salt = keccak256(toHex(`recovery-${saltCounter++}`));
    await s.recoveryTimelock.write.scheduleBatch([targets, values, payloads, zeroHash, salt, delay], { account: governance });
    return {
      id: await s.recoveryTimelock.read.hashOperationBatch([targets, values, payloads, zeroHash, salt]),
      execute: () => s.recoveryTimelock.write.executeBatch([targets, values, payloads, zeroHash, salt], { account: governance }),
      delay,
    };
  }
  const call = (target: { address: Address; abi: unknown }, functionName: string, args: readonly unknown[] = []) => ({
    target: target.address,
    data: encodeFunctionData({ abi: target.abi as Abi, functionName, args } as never),
  });

  it("M-1: the guardian vetoes the main-timelock unpause; the recovery timelock still unpauses after the delay", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const guardian = s.wallets.guardian.account;
    await s.token.write.pause({ account: guardian });

    const viaMain = await schedule(s, s.token.address, encodeFunctionData({ abi: s.token.abi, functionName: "unpause" }));
    await s.timelock.write.cancel([viaMain.id], { account: guardian }); // the veto

    const viaRecovery = await scheduleRecovery(s, [call(s.token, "unpause")]);
    await viem.assertions.revertWithCustomError(
      s.recoveryTimelock.write.cancel([viaRecovery.id], { account: guardian }),
      s.recoveryTimelock,
      "AccessControlUnauthorizedAccount",
    );
    await viem.assertions.revertWithCustomError(viaRecovery.execute(), s.recoveryTimelock, "TimelockUnexpectedOperationState");
    await networkHelpers.time.increase(viaRecovery.delay);
    await viaRecovery.execute();
    assert.equal(await s.token.read.paused(), false);
  });

  it("M-1: one recovery batch strips the guardian everywhere, including its cancel right on the main timelock", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const guardian = s.wallets.guardian.account;
    await s.token.write.pause({ account: guardian });
    await s.executor.write.pause({ account: guardian });

    const removal = await scheduleRecovery(s, [
      call(s.token, "unpause"),
      call(s.executor, "unpause"),
      call(s.token, "revokeRole", [ROLES.GUARDIAN, guardian.address]),
      call(s.vault4626, "revokeRole", [ROLES.GUARDIAN, guardian.address]),
      call(s.vault7540, "revokeRole", [ROLES.GUARDIAN, guardian.address]),
      call(s.executor, "revokeRole", [ROLES.GUARDIAN, guardian.address]),
      call(s.timelock, "revokeRole", [ROLES.CANCELLER, guardian.address]),
    ]);
    await networkHelpers.time.increase(removal.delay);
    await removal.execute();

    for (const c of [s.token, s.vault4626, s.vault7540, s.executor]) {
      assert.equal(await c.read.hasRole([ROLES.GUARDIAN, guardian.address]), false, `guardian kept on ${c.address}`);
    }
    assert.equal(await s.timelock.read.hasRole([ROLES.CANCELLER, guardian.address]), false);
    assert.equal(await s.token.read.paused(), false);
    assert.equal(await s.executor.read.paused(), false);
    const next = await schedule(s, s.token.address, encodeFunctionData({ abi: s.token.abi, functionName: "unpause" }));
    await viem.assertions.revertWithCustomError(
      s.timelock.write.cancel([next.id], { account: guardian }),
      s.timelock,
      "AccessControlUnauthorizedAccount",
    );
  });

  it("M-1: the recovery timelock cannot grant roles, change hooks, upgrade, or propose on the main timelock", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const recovery = s.recoveryTimelock.address;
    const forbidden = [
      call(s.token, "grantRole", [ROLES.MINTER, recovery]),
      call(s.token, "revokeRole", [ROLES.AGENT, s.wallets.agent.account.address]),
      call(s.token, "setPolicyHook", [s.hooks.token.address]),
      call(s.token, "upgradeToAndCall", [s.implementations.token.address, "0x"]),
      call(s.executor, "grantRole", [ROLES.OPERATOR, recovery]),
      call(s.timelock, "grantRole", [ROLES.CANCELLER, recovery]),
      call(s.timelock, "revokeRole", [ROLES.PROPOSER, s.wallets.governance.account.address]),
      call(s.timelock, "schedule", [s.token.address, 0n, "0x", zeroHash, zeroHash, 7n * 86_400n]),
    ];
    for (const f of forbidden) {
      const op = await scheduleRecovery(s, [f]);
      await networkHelpers.time.increase(op.delay);
      const failure = await revertOf(op.execute(), [...s.recoveryTimelock.abi, ...s.token.abi, ...s.timelock.abi] as Abi);
      assert.equal(failure?.errorName, "AccessControlUnauthorizedAccount", `allowed: ${f.data.slice(0, 10)}`);
    }
  });
});
