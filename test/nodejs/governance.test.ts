import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, getAddress, keccak256, toHex, zeroHash, type Abi, type Address, type Hex } from "viem";

import { ROLES } from "../../ignition/modules/roles.js";
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
    assert.equal((await s.hooks.vault4626.read.rules()).length, 3);
    await networkHelpers.time.increase(1n);
    await viem.assertions.emitWithArgs(swap.execute(), s.token, "PolicyHookChanged", [
      getAddress(s.hooks.token.address),
      getAddress(replacement.address),
    ]);
    await rules.execute();
    assert.deepEqual(await s.hooks.vault4626.read.rules(), [getAddress(identityRule.address)]);
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
});
