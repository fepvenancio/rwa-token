import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress, maxUint256, parseEther, parseUnits, zeroAddress, type Abi, type Address, type Hex } from "viem";

import { deployStack, deverify, MONDAY, reasonName, REASONS, revertOf, signIntent, STATUS, verify, type Stack } from "./fixtures.js";

/**
 * Pre-flight never lies, checked from the integrator's side. For every condition × operation, the pre-flight answer
 * (`canTransferWithReason`, `canExecute`, or the gating-aware `max*`), `simulateContract`, and the real write must
 * agree. Token operations revert with the reason itself; vault operations revert at their `max*` bound, so their reason
 * is read from `canTransferWithReason` with the zero address standing in for the vault side, as integrators do. The
 * boolean `canTransfer` is left out: it does not fail on a balance shortfall, and every amount here is within the balance.
 */

type Expect = keyof typeof REASONS;
type Condition = {
  name: string;
  setup: (s: Stack) => Promise<void>;
  /** Seconds the clock moves after `setup`, for the standings that depend on time. */
  advance?: bigint;
  transfer: Expect;
  intent: Expect;
  deposit: Expect;
  redeem: Expect;
};

const FULL_LOCK = 30n * 86_400n;
/** 90 minutes: past an hour-long credential and, from Monday 10:00, still inside the settlement window. */
const LAPSE_BY = 5_400n;

const CONDITIONS: Condition[] = [
  { name: "no condition", setup: async () => {}, transfer: "TRANSFER_OK", intent: "TRANSFER_OK", deposit: "TRANSFER_OK", redeem: "TRANSFER_OK" },
  {
    name: "receiver de-verified",
    setup: async (s) => deverify(s, s.holders.bob),
    transfer: "RECEIVER_NOT_VERIFIED",
    intent: "RECEIVER_NOT_VERIFIED",
    deposit: "RECEIVER_NOT_VERIFIED",
    redeem: "TRANSFER_OK",
  },
  {
    name: "sender de-verified",
    setup: async (s) => deverify(s, s.holders.alice),
    transfer: "SENDER_NOT_VERIFIED",
    intent: "SENDER_NOT_VERIFIED",
    deposit: "TRANSFER_OK", // the asset leg is not hooked and bob receives the shares
    redeem: "SENDER_NOT_VERIFIED",
  },
  {
    // The new standings of the credential layer. An exit-only or lapsed holder can leave but not receive.
    name: "sender exit-only",
    setup: async (s) => void (await s.credentials.write.setStatus([s.holders.alice.account.address, STATUS.EXIT_ONLY], { account: s.wallets.kyc.account })),
    transfer: "TRANSFER_OK",
    intent: "TRANSFER_OK",
    deposit: "TRANSFER_OK",
    redeem: "TRANSFER_OK",
  },
  {
    name: "receiver exit-only",
    setup: async (s) => void (await s.credentials.write.setStatus([s.holders.bob.account.address, STATUS.EXIT_ONLY], { account: s.wallets.kyc.account })),
    transfer: "RECEIVER_NOT_VERIFIED",
    intent: "RECEIVER_NOT_VERIFIED",
    deposit: "RECEIVER_NOT_VERIFIED",
    redeem: "TRANSFER_OK",
  },
  {
    // An hour-long credential and a clock moved 90 minutes on, which is still inside the Monday settlement window.
    name: "sender credential lapsed",
    setup: async (s) => void (await verify(s, s.holders.alice, { validFor: 3_600n })),
    advance: LAPSE_BY,
    transfer: "TRANSFER_OK",
    intent: "TRANSFER_OK",
    deposit: "TRANSFER_OK",
    redeem: "TRANSFER_OK",
  },
  {
    name: "receiver credential lapsed",
    setup: async (s) => void (await verify(s, s.holders.bob, { validFor: 3_600n })),
    advance: LAPSE_BY,
    transfer: "CREDENTIAL_EXPIRED",
    intent: "CREDENTIAL_EXPIRED",
    deposit: "CREDENTIAL_EXPIRED",
    redeem: "TRANSFER_OK",
  },
  {
    name: "sender blocked by the guardian",
    setup: async (s) => void (await s.credentials.write.blockSubject([s.holders.alice.account.address], { account: s.wallets.guardian.account })),
    transfer: "SENDER_NOT_VERIFIED",
    intent: "SENDER_NOT_VERIFIED",
    deposit: "TRANSFER_OK",
    redeem: "SENDER_NOT_VERIFIED",
  },
  {
    name: "sender locked up",
    setup: async (s) => {
      const until = (await s.publicClient.getBlock()).timestamp + FULL_LOCK;
      for (const t of [s.token, s.vault4626]) {
        await s.rules.holderRestrictionRule.write.setLockup([t.address, s.holders.alice.account.address, until], {
          account: s.wallets.agent.account,
        });
      }
    },
    transfer: "LOCKED",
    intent: "LOCKED",
    deposit: "TRANSFER_OK",
    redeem: "LOCKED",
  },
  {
    name: "outside the settlement window (Saturday)",
    setup: async () => {}, // `prepared` moves the clock to Saturday 10:00 UTC
    transfer: "TRANSFER_OK",
    intent: "OUTSIDE_SETTLEMENT_WINDOW",
    deposit: "TRANSFER_OK",
    redeem: "TRANSFER_OK",
  },
  {
    name: "holder cap reached",
    setup: async (s) => {
      const { alice, carol, dave } = s.holders;
      for (const to of [carol, dave]) {
        await s.token.write.transfer([to.account.address, 1n], { account: alice.account });
        await s.vault4626.write.transfer([to.account.address, 1n], { account: alice.account });
      }
    },
    transfer: "MAX_HOLDERS",
    intent: "MAX_HOLDERS",
    deposit: "MAX_HOLDERS",
    redeem: "TRANSFER_OK", // a redemption never adds a holder
  },
  {
    name: "sender fully frozen",
    setup: async (s) => {
      const alice = s.holders.alice.account.address;
      const agent = s.wallets.agent.account;
      await s.token.write.setFrozenTokens([alice, await s.token.read.balanceOf([alice])], { account: agent });
      await s.vault4626.write.setFrozenTokens([alice, await s.vault4626.read.balanceOf([alice])], { account: agent });
    },
    transfer: "INSUFFICIENT_UNFROZEN",
    intent: "INSUFFICIENT_UNFROZEN",
    deposit: "TRANSFER_OK",
    redeem: "INSUFFICIENT_UNFROZEN",
  },
  {
    name: "paused by the guardian",
    setup: async (s) => {
      await s.token.write.pause({ account: s.wallets.guardian.account });
      await s.vault4626.write.pause({ account: s.wallets.guardian.account });
    },
    transfer: "PAUSED",
    intent: "PAUSED",
    deposit: "PAUSED",
    redeem: "PAUSED",
  },
];

describe("pre-flight parity matrix", async function () {
  const connection = await network.create();
  const { networkHelpers } = connection;

  async function funded() {
    const s = await deployStack(connection);
    const { alice } = s.holders;
    await s.token.write.mint([alice.account.address, parseEther("1000")], { account: s.wallets.minter.account });
    await s.asset.write.mint([alice.account.address, parseUnits("1000000", 6)]);
    await s.asset.write.approve([s.vault4626.address, maxUint256], { account: alice.account });
    await s.vault4626.write.deposit([parseUnits("1000", 6), alice.account.address], { account: alice.account });
    return s;
  }

  /** Simulation and write must both succeed, or both revert with `expected` decoded from the same data. */
  async function assertCallParity(
    label: string,
    simulate: () => Promise<unknown>,
    write: () => Promise<unknown>,
    abi: Abi,
    expected: { errorName: string; args?: readonly unknown[] } | undefined,
  ) {
    for (const [path, call] of [["simulateContract", simulate], ["write", write]] as const) {
      const failure = await revertOf(call(), abi);
      if (expected === undefined) {
        assert.equal(failure, undefined, `${label}: ${path} reverted with ${failure?.errorName}`);
      } else {
        assert.equal(failure?.errorName, expected.errorName, `${label}: ${path} error`);
        if (expected.args) assert.deepEqual(failure?.args, expected.args, `${label}: ${path} args`);
      }
    }
  }

  /**
   * What the write reverts with for a refused movement. A policy rejection carries its reason; the token's own
   * frozen-balance check reverts with ERC-7943's error, which names the sender, the amount and the unfrozen balance.
   */
  const rejected = (reason: Hex, sender: Address, amount: bigint, unfrozen: bigint) =>
    reason === REASONS.INSUFFICIENT_UNFROZEN
      ? { errorName: "ERC7943InsufficientUnfrozenBalance", args: [getAddress(sender), amount, unfrozen] }
      : { errorName: "PolicyGated_TransferRejected", args: [reason] };

  for (const c of CONDITIONS) {
    describe(c.name, function () {
      async function prepared() {
        const s = await networkHelpers.loadFixture(funded);
        await c.setup(s);
        if (c.advance) await networkHelpers.time.increase(c.advance);
        if (c.intent === "OUTSIDE_SETTLEMENT_WINDOW") await networkHelpers.time.increaseTo(MONDAY + 5n * 86_400n + 10n * 3_600n);
        return s;
      }

      it(`transfer → ${c.transfer}`, async function () {
        const s = await prepared();
        const { alice, bob } = s.holders;
        const [ok, reason] = await s.token.read.canTransferWithReason([alice.account.address, bob.account.address, 1n]);
        assert.equal(reasonName(reason), c.transfer);
        assert.equal(ok, c.transfer === "TRANSFER_OK");
        await assertCallParity(
          "transfer",
          () => s.token.simulate.transfer([bob.account.address, 1n], { account: alice.account.address }),
          () => s.token.write.transfer([bob.account.address, 1n], { account: alice.account }),
          s.token.abi,
          ok ? undefined : rejected(reason, alice.account.address, 1n, 0n),
        );
      });

      it(`intent → ${c.intent}`, async function () {
        const s = await prepared();
        const { alice, bob } = s.holders;
        const { intent, sig } = await signIntent(s, alice, { to: bob.account.address, amount: 1n });
        // The token sees the executor contract as operator, so pre-flight is asked from its address.
        const [ok, reason] = await s.token.read.canExecute([intent, sig, s.executor.address]);
        assert.equal(reasonName(reason), c.intent);
        assert.equal(ok, c.intent === "TRANSFER_OK");
        const operator = s.wallets.operator.account;
        await assertCallParity(
          "intent",
          () => s.executor.simulate.execute([s.token.address, intent, sig], { account: operator.address }),
          () => s.executor.write.execute([s.token.address, intent, sig], { account: operator }),
          [...s.executor.abi, ...s.token.abi],
          ok ? undefined : rejected(reason, alice.account.address, 1n, 0n),
        );
      });

      it(`deposit → ${c.deposit}`, async function () {
        const s = await prepared();
        const { alice, bob } = s.holders;
        const [ok, reason] = await s.vault4626.read.canTransferWithReason([zeroAddress, bob.account.address, 1n]);
        assert.equal(reasonName(reason), c.deposit);
        const max = await s.vault4626.read.maxDeposit([bob.account.address]);
        assert.equal(max, ok ? maxUint256 : 0n, "maxDeposit agrees with the mint probe");
        await assertCallParity(
          "deposit",
          () => s.vault4626.simulate.deposit([1n, bob.account.address], { account: alice.account.address }),
          () => s.vault4626.write.deposit([1n, bob.account.address], { account: alice.account }),
          s.vault4626.abi,
          ok ? undefined : { errorName: "ERC4626ExceededMaxDeposit", args: [getAddress(bob.account.address), 1n, 0n] },
        );
      });

      it(`redeem → ${c.redeem}`, async function () {
        const s = await prepared();
        const owner = s.holders.alice.account;
        const [ok, reason] = await s.vault4626.read.canTransferWithReason([owner.address, zeroAddress, 1n]);
        assert.equal(reasonName(reason), c.redeem);
        const max = await s.vault4626.read.maxRedeem([owner.address]);
        assert.equal(max > 0n, ok, "maxRedeem agrees with canTransfer");
        // Exact form: from the same state redeem(maxRedeem + 1) reverts and redeem(maxRedeem) settles; a blocked owner
        // has maxRedeem 0, so its smallest redeem is the + 1 case.
        if (ok) {
          const over = await revertOf(
            s.vault4626.simulate.redeem([max + 1n, owner.address, owner.address], { account: owner.address }),
            s.vault4626.abi,
          );
          assert.deepEqual(over, { errorName: "ERC4626ExceededMaxRedeem", args: [getAddress(owner.address), max + 1n, max] });
        }
        const shares = ok ? max : 1n;
        await assertCallParity(
          "redeem",
          () => s.vault4626.simulate.redeem([shares, owner.address, owner.address], { account: owner.address }),
          () => s.vault4626.write.redeem([shares, owner.address, owner.address], { account: owner }),
          s.vault4626.abi,
          ok ? undefined : { errorName: "ERC4626ExceededMaxRedeem", args: [getAddress(owner.address), 1n, 0n] },
        );
      });
    });
  }
});
