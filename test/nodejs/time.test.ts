import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { parseEther } from "viem";

import { deployStack, MONDAY, REASONS, signIntent, WINDOW_CLOSE, WINDOW_OPEN, type Intent, type Stack } from "./fixtures.js";

/**
 * Boundaries in time. Pre-flight reads the latest block, but a write is mined in the next one, so every boundary write
 * pins its own timestamp with `setNextBlockTimestamp`: the second each rule is specified at is the one exercised.
 */
describe("time-based flows", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;
  const { time } = networkHelpers;
  const DAY = 86_400n;

  async function funded() {
    const s = await deployStack(connection);
    await s.token.write.mint([s.holders.alice.account.address, parseEther("1000")], { account: s.wallets.minter.account });
    return s;
  }
  const execute = (s: Stack, intent: Intent, sig: `0x${string}`) =>
    s.executor.write.execute([s.token.address, intent, sig], { account: s.wallets.operator.account });
  const rejected = (s: Stack, call: Promise<unknown>, reason: `0x${string}`) =>
    viem.assertions.revertWithCustomErrorWithArgs(call, s.token, "PolicyGated_TransferRejected", [reason]);

  it("a lockup holds until its unlock second, then releases", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob } = s.holders;
    const unlock = (await time.latest()) + 30 * 86_400;
    await s.rules.lockupRule.write.setLockup([s.token.address, alice.account.address, BigInt(unlock)], {
      account: s.wallets.agent.account,
    });

    await time.increaseTo(unlock - 2);
    assert.deepEqual(await s.token.read.canTransfer([alice.account.address, bob.account.address, 1n]), [false, REASONS.LOCKED]);
    await time.setNextBlockTimestamp(unlock - 1);
    await rejected(s, s.token.write.transfer([bob.account.address, 1n], { account: alice.account }), REASONS.LOCKED);

    await time.setNextBlockTimestamp(unlock);
    await s.token.write.transfer([bob.account.address, 1n], { account: alice.account });
    assert.deepEqual(await s.token.read.canTransfer([alice.account.address, bob.account.address, 1n]), [true, REASONS.TRANSFER_OK]);
  });

  it("the settlement window is [open, close) on weekdays only", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob } = s.holders;
    const friday = MONDAY + 4n * DAY;
    const nextMonday = MONDAY + 7n * DAY;
    // Long deadlines: this test is about the window, not expiry.
    const sign = () => signIntent(s, alice, { to: bob.account.address, amount: 1n, deadline: nextMonday + DAY });

    const lastSecond = await sign();
    await time.setNextBlockTimestamp(friday + BigInt(WINDOW_CLOSE) - 1n);
    await execute(s, lastSecond.intent, lastSecond.sig);

    const atClose = await sign();
    await time.setNextBlockTimestamp(friday + BigInt(WINDOW_CLOSE));
    await rejected(s, execute(s, atClose.intent, atClose.sig), REASONS.OUTSIDE_SETTLEMENT_WINDOW);
    assert.equal(await s.rules.windowRule.read.isOpen([s.token.address, friday + DAY + 12n * 3_600n]), false, "Saturday noon");

    // The same intent waits out the weekend and settles at Monday's open.
    await time.increaseTo(nextMonday + BigInt(WINDOW_OPEN) - 2n);
    assert.deepEqual(await s.token.read.canExecute([atClose.intent, atClose.sig], { account: s.executor.address }), [false, REASONS.OUTSIDE_SETTLEMENT_WINDOW]);
    await time.setNextBlockTimestamp(nextMonday + BigInt(WINDOW_OPEN));
    await execute(s, atClose.intent, atClose.sig);
    assert.equal(await s.token.read.balanceOf([bob.account.address]), 2n);
  });

  it("an intent's deadline is inclusive", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob } = s.holders;
    const deadline = BigInt(await time.latest()) + 600n;
    const onTime = await signIntent(s, alice, { to: bob.account.address, amount: 1n, deadline });
    const late = await signIntent(s, alice, { to: bob.account.address, amount: 1n, deadline });

    await time.setNextBlockTimestamp(deadline);
    await execute(s, onTime.intent, onTime.sig);
    // The latest block now sits on the deadline, so pre-flight still says yes; a write would land a second later.
    assert.deepEqual(await s.token.read.canExecute([late.intent, late.sig], { account: s.executor.address }), [true, REASONS.TRANSFER_OK]);

    await time.increaseTo(deadline + 1n);
    assert.deepEqual(await s.token.read.canExecute([late.intent, late.sig], { account: s.executor.address }), [false, REASONS.INTENT_EXPIRED]);
    await rejected(s, execute(s, late.intent, late.sig), REASONS.INTENT_EXPIRED);
  });

  it("an intent's validAfter is inclusive: refused the second before, settled at it", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob } = s.holders;
    const validAfter = BigInt(await time.latest()) + 600n;
    const { intent, sig } = await signIntent(s, alice, { to: bob.account.address, amount: 1n, validAfter, deadline: validAfter + DAY });

    assert.deepEqual(await s.token.read.canExecute([intent, sig], { account: s.executor.address }), [false, REASONS.INTENT_NOT_YET_VALID]);
    await time.setNextBlockTimestamp(validAfter - 1n);
    await rejected(s, execute(s, intent, sig), REASONS.INTENT_NOT_YET_VALID);

    await time.setNextBlockTimestamp(validAfter);
    await execute(s, intent, sig);
    assert.equal(await s.token.read.balanceOf([bob.account.address]), 1n);
  });
});
