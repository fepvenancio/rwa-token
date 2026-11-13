// SPDX-License-Identifier: UNLICENSED
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress, maxUint256, parseUnits, zeroAddress } from "viem";

import { deployStack, deverify, PAR, settlePeriod } from "./fixtures.js";

const usd = (amount: string) => parseUnits(amount, 6);

describe("vault flows", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  async function funded() {
    const s = await deployStack(connection);
    for (const w of [s.holders.alice, s.holders.bob]) {
      await s.asset.write.mint([w.account.address, usd("1000000")]);
      for (const v of [s.vault4626.address, s.vault7540.address]) {
        await s.asset.write.approve([v, maxUint256], { account: w.account });
      }
    }
    return s;
  }

  describe("Gated4626Vault", function () {
    it("deposit mints gated shares and withdraw(maxWithdraw) returns the assets", async function () {
      const s = await networkHelpers.loadFixture(funded);
      const alice = s.holders.alice.account;
      const assets = usd("1000");
      const shares = await s.vault4626.read.previewDeposit([assets]);

      // Shares arrive as a MINT through the hook: Transfer from the zero address.
      await viem.assertions.emitWithArgs(
        s.vault4626.write.deposit([assets, alice.address], { account: alice }),
        s.vault4626,
        "Transfer",
        [zeroAddress, getAddress(alice.address), shares],
      );
      const maxWithdraw = await s.vault4626.read.maxWithdraw([alice.address]);
      assert.equal(maxWithdraw, assets);
      await s.vault4626.write.withdraw([maxWithdraw, alice.address, alice.address], { account: alice });
      assert.equal(await s.asset.read.balanceOf([alice.address]), usd("1000000"));
      assert.equal(await s.vault4626.read.balanceOf([alice.address]), 0n);
    });
  });

  describe("Gated7540Vault", function () {
    it("request → settle → claim, for deposits and redemptions", async function () {
      const s = await networkHelpers.loadFixture(funded);
      const { alice } = s.holders;
      const a = alice.account.address;
      const custody = s.wallets.custody.account.address;

      await viem.assertions.emitWithArgs(
        s.vault7540.write.requestDeposit([usd("1000"), a, a], { account: alice.account }),
        s.vault7540,
        "DepositRequest",
        [getAddress(a), getAddress(a), 0n, getAddress(a), usd("1000")],
      );
      assert.equal(await s.vault7540.read.pendingDepositRequest([0n, a]), usd("1000"));
      assert.equal(await s.vault7540.read.maxDeposit([a]), 0n, "nothing claimable before settlement");

      // The first period deals at par; the money goes to the cash account.
      const custodyBefore = await s.asset.read.balanceOf([custody]);
      await settlePeriod(s, s.vault7540);
      assert.equal((await s.asset.read.balanceOf([custody])) - custodyBefore, 10n ** 30n + usd("1000"));
      assert.equal(await s.vault7540.read.maxDeposit([a]), usd("1000"));

      await s.vault7540.write.deposit([usd("1000"), a, a], { account: alice.account });
      const shares = usd("1000") * PAR;
      assert.equal(await s.vault7540.read.balanceOf([a]), shares);
      assert.equal(await s.vault7540.read.claimableDepositRequest([0n, a]), 0n);

      // Redemption: the shares are escrowed in the vault, burned at settlement, and paid out at the claim.
      await s.vault7540.write.requestRedeem([shares, a, a], { account: alice.account });
      assert.equal(await s.vault7540.read.balanceOf([s.vault7540.address]), shares);
      await settlePeriod(s, s.vault7540, usd("1040")); // the value rose 4%
      assert.equal(await s.vault7540.read.totalSupply(), 0n);
      const owed = await s.vault7540.read.maxWithdraw([a]);
      await s.vault7540.write.redeem([shares, a, a], { account: alice.account });
      assert.equal(await s.asset.read.balanceOf([a]), usd("1000000") - usd("1000") + owed);
    });

    it("a rejected deposit request returns the assets; a rejected redeem request returns the shares", async function () {
      const s = await networkHelpers.loadFixture(funded);
      const bob = s.holders.bob.account;
      const agent = s.wallets.agent.account;

      await s.vault7540.write.requestDeposit([usd("500"), bob.address, bob.address], { account: bob });
      await viem.assertions.emitWithArgs(
        s.vault7540.write.rejectDepositRequest([bob.address], { account: agent }),
        s.vault7540,
        "DepositRequestRejected",
        [getAddress(bob.address), usd("500")],
      );
      assert.equal(await s.asset.read.balanceOf([bob.address]), usd("1000000"));

      await s.vault7540.write.requestDeposit([usd("500"), bob.address, bob.address], { account: bob });
      await settlePeriod(s, s.vault7540);
      await s.vault7540.write.deposit([usd("500"), bob.address, bob.address], { account: bob });
      await s.vault7540.write.requestRedeem([usd("200"), bob.address, bob.address], { account: bob });
      await viem.assertions.emitWithArgs(
        s.vault7540.write.rejectRedeemRequest([bob.address], { account: agent }),
        s.vault7540,
        "RedeemRequestRejected",
        [getAddress(bob.address), usd("200")],
      );
      assert.equal(await s.vault7540.read.balanceOf([bob.address]), usd("500") * PAR);
      assert.equal(await s.vault7540.read.pendingRedeemRequest([0n, bob.address]), 0n);
    });

    it("an agent recovers a de-verified controller's pending redemption to a verified account", async function () {
      const s = await networkHelpers.loadFixture(funded);
      const alice = s.holders.alice.account;
      const agent = s.wallets.agent.account;
      const recovery = s.wallets.recovery.account.address;
      const shares = usd("300") * PAR;

      await s.vault7540.write.requestDeposit([usd("300"), alice.address, alice.address], { account: alice });
      await settlePeriod(s, s.vault7540);
      await s.vault7540.write.deposit([usd("300"), alice.address, alice.address], { account: alice });
      await s.vault7540.write.requestRedeem([shares, alice.address, alice.address], { account: alice });

      // De-verified: a reject sends the shares back as a plain TRANSFER, which the credential rule refuses, so it
      // fails; recovery (FORCED, to a verified account) does not.
      await deverify(s, alice.address);
      await viem.assertions.revertWithCustomError(
        s.vault7540.write.rejectRedeemRequest([alice.address], { account: agent }),
        s.vault7540,
        "ERC8473PolicyRejected",
      );
      await viem.assertions.emitWithArgs(
        s.vault7540.write.recoverRedeemRequest([alice.address, recovery], { account: agent }),
        s.vault7540,
        "RedeemRequestRecovered",
        [getAddress(alice.address), getAddress(recovery), shares, getAddress(agent.address)],
      );
      assert.equal(await s.vault7540.read.balanceOf([recovery]), shares);
      assert.equal(await s.vault7540.read.pendingRedeemRequest([0n, alice.address]), 0n);
    });

    it("a controller that waited walks the gated periods at a small cost for each", async function () {
      /** The gas of a claim after `periods` settlements that each took one share unit, and one that took the rest. */
      const claimAfter = async (periods: number) => {
        const s = await networkHelpers.loadFixture(funded);
        const { alice } = s.holders;
        const a = alice.account.address;
        await s.vault7540.write.requestDeposit([usd("1000"), a, a], { account: alice.account });
        await settlePeriod(s, s.vault7540);
        await s.vault7540.write.mint([usd("1000") * PAR, a, a], { account: alice.account });
        await s.vault7540.write.requestRedeem([usd("1000") * PAR, a, a], { account: alice.account });
        for (let i = 0; i < periods; i++) await settlePeriod(s, s.vault7540, undefined, 1n);
        await settlePeriod(s, s.vault7540);
        assert.equal(await s.vault7540.read.maxRedeem([a]), usd("1000") * PAR);
        const hash = await s.vault7540.write.redeem([usd("1000") * PAR, a, a], { account: alice.account });
        return (await s.publicClient.getTransactionReceipt({ hash })).gasUsed;
      };
      const perPeriod = ((await claimAfter(21)) - (await claimAfter(1))) / 20n;
      // 5,979 when written, so about 5,000 gated periods in a row fit a block of 30 million.
      assert.ok(perPeriod < 7_000n, `each gated period walked costs ${perPeriod} gas`);
    });

    it("rebuilds the NAV history from decoded PeriodSettled events", async function () {
      const s = await networkHelpers.loadFixture(funded);
      const { alice, bob } = s.holders;
      const fromBlock = await s.publicClient.getBlockNumber();
      const VIRTUAL = 1_000_000n;

      // Three periods at different values, the last with a price that rounds.
      const deal = async (holder: typeof alice, assets: bigint, nav?: bigint) => {
        const a = holder.account.address;
        await s.vault7540.write.requestDeposit([assets, a, a], { account: holder.account });
        await settlePeriod(s, s.vault7540, nav);
      };
      await deal(alice, usd("1000"));
      await deal(bob, usd("1000"), usd("1250")); // the value rose
      await deal(alice, usd("1000"), usd("3333"));

      const events = await s.publicClient.getContractEvents({
        address: s.vault7540.address,
        abi: s.vault7540.abi,
        eventName: "PeriodSettled",
        fromBlock,
        strict: true,
      });
      assert.equal(events.length, 3);
      assert.deepEqual(events.map((e) => e.args._period), [1n, 2n, 3n]);
      let supply = 0n;
      for (const { args } of events) {
        assert.equal(args._supply, supply, "each period's supply is the last one's plus what it bought");
        assert.equal(args._deposits, usd("1000"));
        assert.equal(args._fee, 0n);
        // Each period's price is recomputable off-chain from the event alone.
        assert.equal(args._shares, (args._deposits * (args._supply + VIRTUAL)) / (args._nav + 1n));
        supply += args._shares;
      }
      const last = events.at(-1)!.args;
      const assets = usd("7");
      assert.equal(await s.vault7540.read.convertToShares([assets]), (assets * (last._supply + VIRTUAL)) / (last._nav + 1n));
    });
  });
});
