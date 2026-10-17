import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress, maxUint256, parseUnits, zeroAddress } from "viem";

import { deployStack } from "./fixtures.js";

const usd = (amount: string) => parseUnits(amount, 6);

describe("vault flows", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  async function funded() {
    const s = await deployStack(connection);
    for (const w of [s.holders.alice, s.holders.bob, s.wallets.fulfiller]) {
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
    it("request → fulfil → claim, for deposits and redemptions", async function () {
      const s = await networkHelpers.loadFixture(funded);
      const { alice } = s.holders;
      const a = alice.account.address;
      const fulfiller = s.wallets.fulfiller.account;
      const custody = s.wallets.custody.account.address;

      await viem.assertions.emitWithArgs(
        s.vault7540.write.requestDeposit([usd("1000"), a, a], { account: alice.account }),
        s.vault7540,
        "DepositRequest",
        [getAddress(a), getAddress(a), 0n, getAddress(a), usd("1000")],
      );
      assert.equal(await s.vault7540.read.pendingDepositRequest([0n, a]), usd("1000"));
      assert.equal(await s.vault7540.read.maxDeposit([a]), 0n, "nothing claimable before fulfilment");

      // The bank prices the request at 1.25 assets per share; the assets go to custody.
      await s.vault7540.write.fulfillDeposit([a, usd("1000"), usd("800")], { account: fulfiller });
      assert.equal(await s.asset.read.balanceOf([custody]), usd("1000"));
      assert.equal(await s.vault7540.read.maxDeposit([a]), usd("1000"));

      await s.vault7540.write.deposit([usd("1000"), a, a], { account: alice.account });
      assert.equal(await s.vault7540.read.balanceOf([a]), usd("800"));
      assert.equal(await s.vault7540.read.claimableDepositRequest([0n, a]), 0n);

      // Redemption: the shares are escrowed in the vault, burned at fulfilment, and paid out at claim.
      await s.vault7540.write.requestRedeem([usd("800"), a, a], { account: alice.account });
      assert.equal(await s.vault7540.read.balanceOf([s.vault7540.address]), usd("800"));
      await s.vault7540.write.fulfillRedeem([a, usd("800"), usd("1040")], { account: fulfiller });
      assert.equal(await s.vault7540.read.totalSupply(), 0n);
      await s.vault7540.write.redeem([usd("800"), a, a], { account: alice.account });
      assert.equal(await s.asset.read.balanceOf([a]), usd("1000000") - usd("1000") + usd("1040"));
    });

    it("a rejected deposit request returns the assets; a rejected redeem request returns the shares", async function () {
      const s = await networkHelpers.loadFixture(funded);
      const bob = s.holders.bob.account;
      const fulfiller = s.wallets.fulfiller.account;

      await s.vault7540.write.requestDeposit([usd("500"), bob.address, bob.address], { account: bob });
      await viem.assertions.emitWithArgs(
        s.vault7540.write.rejectDepositRequest([bob.address], { account: fulfiller }),
        s.vault7540,
        "DepositRequestRejected",
        [getAddress(bob.address), usd("500")],
      );
      assert.equal(await s.asset.read.balanceOf([bob.address]), usd("1000000"));

      await s.vault7540.write.requestDeposit([usd("500"), bob.address, bob.address], { account: bob });
      await s.vault7540.write.fulfillDeposit([bob.address, usd("500"), usd("500")], { account: fulfiller });
      await s.vault7540.write.deposit([usd("500"), bob.address, bob.address], { account: bob });
      await s.vault7540.write.requestRedeem([usd("200"), bob.address, bob.address], { account: bob });
      await viem.assertions.emitWithArgs(
        s.vault7540.write.rejectRedeemRequest([bob.address], { account: fulfiller }),
        s.vault7540,
        "RedeemRequestRejected",
        [getAddress(bob.address), usd("200")],
      );
      assert.equal(await s.vault7540.read.balanceOf([bob.address]), usd("500"));
      assert.equal(await s.vault7540.read.pendingRedeemRequest([0n, bob.address]), 0n);
    });

    it("an agent recovers a de-verified controller's pending redemption to a verified account", async function () {
      const s = await networkHelpers.loadFixture(funded);
      const alice = s.holders.alice.account;
      const fulfiller = s.wallets.fulfiller.account;
      const recovery = s.wallets.recovery.account.address;

      await s.vault7540.write.requestDeposit([usd("300"), alice.address, alice.address], { account: alice });
      await s.vault7540.write.fulfillDeposit([alice.address, usd("300"), usd("300")], { account: fulfiller });
      await s.vault7540.write.deposit([usd("300"), alice.address, alice.address], { account: alice });
      await s.vault7540.write.requestRedeem([usd("300"), alice.address, alice.address], { account: alice });

      // De-verified: a reject would FORCE the shares back to an unverified holder, so it fails; recovery does not.
      await s.identity.write.set([alice.address, false]);
      await viem.assertions.revertWithCustomError(
        s.vault7540.write.rejectRedeemRequest([alice.address], { account: fulfiller }),
        s.vault7540,
        "PolicyGated_TransferRejected",
      );
      await viem.assertions.emitWithArgs(
        s.vault7540.write.recoverRedeemRequest([alice.address, recovery], { account: s.wallets.agent.account }),
        s.vault7540,
        "RedeemRequestRecovered",
        [getAddress(alice.address), getAddress(recovery), usd("300"), getAddress(s.wallets.agent.account.address)],
      );
      assert.equal(await s.vault7540.read.balanceOf([recovery]), usd("300"));
      assert.equal(await s.vault7540.read.pendingRedeemRequest([0n, alice.address]), 0n);
    });

    it("rebuilds the NAV history from decoded Fulfilled events and ends at lastPrice", async function () {
      const s = await networkHelpers.loadFixture(funded);
      const { alice, bob } = s.holders;
      const fulfiller = s.wallets.fulfiller.account;
      const fromBlock = await s.publicClient.getBlockNumber();

      // Three fulfilments at different prices, including one that rounds (1000 / 3 shares).
      const fills: [typeof alice, bigint, bigint][] = [
        [alice, usd("1000"), usd("1000")],
        [bob, usd("1000"), usd("800")],
        [alice, usd("1000"), 3n],
      ];
      for (const [holder, assets, shares] of fills) {
        await s.vault7540.write.requestDeposit([assets, holder.account.address, holder.account.address], { account: holder.account });
        await s.vault7540.write.fulfillDeposit([holder.account.address, assets, shares], { account: fulfiller });
      }

      const events = await s.publicClient.getContractEvents({
        address: s.vault7540.address,
        abi: s.vault7540.abi,
        eventName: "Fulfilled",
        fromBlock,
        strict: true,
      });
      const unit = 10n ** BigInt(await s.vault7540.read.decimals());
      const history = events.map((e) => ({ block: e.blockNumber, ...e.args }));
      assert.equal(history.length, fills.length);
      history.forEach((h, i) => {
        const [holder, assets, shares] = fills[i];
        assert.equal(h._controller, getAddress(holder.account.address));
        assert.equal(h._isDeposit, true);
        assert.equal(h._fulfiller, getAddress(fulfiller.address));
        // The emitted price is assets per 10**decimals() shares, rounded down: recomputable off-chain.
        assert.equal(h._price, (assets * unit) / shares);
        assert.equal(h._assets, assets);
        assert.equal(h._shares, shares);
      });
      assert.deepEqual(
        history.map((h) => h._price),
        [unit, (usd("1000") * unit) / usd("800"), (usd("1000") * unit) / 3n],
      );
      assert.equal(await s.vault7540.read.lastPrice(), history.at(-1)!._price);
      assert.equal(await s.vault7540.read.convertToShares([history.at(-1)!._price]), unit);
    });
  });
});
