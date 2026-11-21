// SPDX-License-Identifier: UNLICENSED
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { maxUint256 } from "viem";

import { missingParts, partsOf, PROFILES, type Profile } from "../../ignition/profiles.js";
import { reconcile } from "../../scripts/lib/reconcile.js";
import type { StackFile } from "../../scripts/lib/stack.js";
import { assertHandedOver, deployProfile, REASONS, verify, type ProfileStack } from "./fixtures.js";

/** The demo stack with the escrow for pledged tokens: three classes of one fund, each with a minimum position. */
const WITH_LIENS: Profile = { ...PROFILES.full, id: "fullLien", lienVault: true };
const MINIMUM = 10n;

/** The stack file an operator would keep for it. */
function stackFileOf(s: ProfileStack): StackFile {
  return {
    profile: s.profile.id,
    accounts: Object.fromEntries(Object.entries(s.wallets).map(([key, w]) => [key, w.account.address])),
    parameters: Object.fromEntries(Object.entries(s.parameters).map(([key, value]) => [key, typeof value === "bigint" ? value.toString() : value])),
    core: Object.fromEntries(Object.entries(s.components).map(([key, c]) => [key, c.address])),
    funds: Object.fromEntries(Object.entries(s.funds).map(([key, f]) => [key, { fund: f.fund.address, rule: f.rule.address, cap: f.cap.toString() }])),
    products: Object.fromEntries(s.deployed.map(({ product, contract }) => [product.key, contract.address])),
    legos: s.legos,
  };
}

describe("the lien vault as a part of a core", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  async function pledged() {
    const s = await deployProfile(connection, WITH_LIENS, { intentMinPosition: MINIMUM });
    const liens = s.lienVault!;
    const token = await viem.getContractAt("IntentToken", s.products.intent.address);
    const { alice, bob, carol, dave, eve } = s.holders;
    // The vault is an ordinary holder of the token, so the attester credentials it.
    for (const who of [alice, bob, carol, dave, eve, liens.address]) await verify(s, who);
    for (const who of [alice, bob, carol]) {
      await token.write.mint([who.account.address, 100n], { account: s.wallets.minter.account });
      await token.write.approve([liens.address, maxUint256], { account: who.account });
    }
    return { s, liens, token, alice, bob, carol, dave, eve, file: stackFileOf(s) };
  }
  const asTimelock = async (s: ProfileStack, act: () => Promise<unknown>) => {
    await networkHelpers.impersonateAccount(s.timelock.address);
    await networkHelpers.setBalance(s.timelock.address, 10n ** 18n);
    await act();
    await networkHelpers.stopImpersonatingAccount(s.timelock.address);
  };

  it("is a part a profile asks for, and one a running core can be given", function () {
    assert.ok(partsOf(WITH_LIENS).includes("lienVault"));
    assert.ok(!partsOf(PROFILES.full).includes("lienVault"));
    assert.deepEqual(missingParts({ products: [], lienVault: true }, []), ["lienVault"]);
    assert.deepEqual(missingParts({ products: [], lienVault: true }, ["lienVault"]), []);
  });

  it("deploys with the core, exempt from the fund's count and from each product's minimum, and the check passes", async function () {
    const { s, liens } = await networkHelpers.loadFixture(pledged);
    assert.equal(await liens.read.lienCount(), 0n);
    assert.equal(await s.fund!.read.isExempt([liens.address]), true);
    for (const { contract } of s.deployed) assert.equal(await s.rules.minPositionRule!.read.isExempt([contract.address, liens.address]), true);
    await assertHandedOver(s);
  });

  it("the check refuses a stack with no lien vault, one the fund counts, and one a product's minimum judges", async function () {
    const { s, liens, token } = await networkHelpers.loadFixture(pledged);
    await assert.rejects(assertHandedOver({ ...s, lienVault: undefined }), /the profile asks for a lien vault and the stack has none/);
    const other = await viem.deployContract("SignedExit");
    await assert.rejects(assertHandedOver({ ...s, lienVault: await viem.getContractAt("LienVault", other.address) }), /is not the release's/);

    await asTimelock(s, () => s.rules.minPositionRule!.write.setExempt([token.address, liens.address, false], { account: s.timelock.address }));
    await assert.rejects(assertHandedOver(s), /the minimum position of intent judges the lien vault/);
    await asTimelock(s, () => s.rules.minPositionRule!.write.setExempt([token.address, liens.address, true], { account: s.timelock.address }));
    await asTimelock(s, () => s.fund!.write.setExempt([liens.address, false], { account: s.timelock.address }));
    await assert.rejects(assertHandedOver(s), /the fund main counts the lien vault/);
  });

  it("a holder that pledges its whole position leaves the fund's count, and cannot be released to once the fund is full", async function () {
    const { s, liens, token, alice, bob, dave, file } = await networkHelpers.loadFixture(pledged);
    assert.equal(await s.fund!.read.holderCount(), 3n);
    assert.deepEqual(await reconcile(connection, file, {}, WITH_LIENS), []);

    await liens.write.pledge([token.address, 100n, bob.account.address], { account: alice.account });
    assert.equal(await s.fund!.read.holderCount(), 2n, "the count is of holders of record");
    const lines = await reconcile(connection, file, {}, WITH_LIENS);
    assert.equal(lines.length, 1, lines.join("\n"));
    assert.match(lines[0], /fund main: 1 account holds its classes only through the lien vault, so 3 owners are counted as 2/);

    // The slot the pledge freed is taken, and the fund is full again.
    await token.write.mint([dave.account.address, 100n], { account: s.wallets.minter.account });
    assert.equal(await s.fund!.read.holderCount(), 3n);
    await viem.assertions.revertWithCustomErrorWithArgs(
      liens.write.release([1n, 100n], { account: bob.account }),
      token,
      "ERC8473PolicyRejected",
      [REASONS.MAX_HOLDERS],
    );
    // The lender, a holder already, can still take it.
    await liens.write.seize([1n, 100n], { account: bob.account });
    assert.equal(await token.read.balanceOf([bob.account.address]), 200n);
    assert.deepEqual(await reconcile(connection, file, {}, WITH_LIENS), []);
  });

  it("the reconciler counts owners behind the vault by investor: two addresses of one are one, and none when it is still counted", async function () {
    const { s, liens, token, alice, bob, carol, file } = await networkHelpers.loadFixture(pledged);
    // The attester links alice and carol as one investor, and the fund is brought into line.
    for (const who of [alice, carol]) {
      await verify(s, who, { entity: 7 });
      await s.fund!.write.rekey([who.account.address], { account: bob.account });
    }
    assert.equal(await s.fund!.read.holderCount(), 2n);

    // Alice pledges everything. Her investor still holds through carol, so the count misses nobody.
    await liens.write.pledge([token.address, 100n, bob.account.address], { account: alice.account });
    assert.equal(await s.fund!.read.holderCount(), 2n);
    assert.deepEqual(await reconcile(connection, file, {}, WITH_LIENS), []);

    // Carol pledges everything too: two accounts behind the vault, and one investor missing from the count.
    await liens.write.pledge([token.address, 100n, bob.account.address], { account: carol.account });
    assert.equal(await s.fund!.read.holderCount(), 1n);
    const lines = await reconcile(connection, file, {}, WITH_LIENS);
    assert.equal(lines.length, 1, lines.join("\n"));
    assert.match(lines[0], /fund main: 2 accounts hold its classes only through the lien vault, so 2 owners are counted as 1/);
  });

  it("a pledge may not leave the holder with dust, and a lien below the minimum cannot be taken by a lender that holds nothing", async function () {
    const { liens, token, alice, eve } = await networkHelpers.loadFixture(pledged);
    await viem.assertions.revertWithCustomErrorWithArgs(
      liens.write.pledge([token.address, 95n, eve.account.address], { account: alice.account }),
      token,
      "ERC8473PolicyRejected",
      [REASONS.BELOW_MIN_POSITION],
    );
    await liens.write.pledge([token.address, 5n, eve.account.address], { account: alice.account });
    assert.equal(await token.read.balanceOf([liens.address]), 5n);
    await viem.assertions.revertWithCustomErrorWithArgs(
      liens.write.seize([1n, 5n], { account: eve.account }),
      token,
      "ERC8473PolicyRejected",
      [REASONS.BELOW_MIN_POSITION],
    );
    // Back to the holder it goes: the holder has more than the minimum with it.
    await liens.write.release([1n, 5n], { account: eve.account });
    assert.equal(await token.read.balanceOf([alice.account.address]), 100n);
  });

  it("the reconciler names a token of which the vault holds less than its liens book", async function () {
    const { s, liens, token, alice, bob, carol, file } = await networkHelpers.loadFixture(pledged);
    await liens.write.pledge([token.address, 50n, bob.account.address], { account: alice.account });
    assert.deepEqual(await reconcile(connection, file, {}, WITH_LIENS), []);

    // The token's agent takes tokens straight out of the vault, which names no lien: the wrong way to enforce.
    await token.write.forcedTransfer([liens.address, carol.account.address, 20n], { account: s.wallets.agent.account });
    const lines = await reconcile(connection, file, {}, WITH_LIENS);
    assert.equal(lines.length, 1, lines.join("\n"));
    assert.match(lines[0], /the lien vault holds 30 of intent and its liens book 50/);
  });
});
