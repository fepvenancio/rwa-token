import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { isAddressEqual, zeroAddress } from "viem";

import { deployStack, HOLDER_CAP, REASONS } from "./fixtures.js";

describe("deployment fixture", async function () {
  const connection = await network.create();
  const stack = () => deployStack(connection);

  it("deploys every template live with its policy and hands over to the admin", async function () {
    const s = await connection.networkHelpers.loadFixture(stack);
    for (const t of [s.token, s.vault4626, s.vault7540]) {
      assert.ok(isAddressEqual(await t.read.registry(), s.registry.address));
      assert.equal(await s.rules.maxHoldersRule.read.capOf([t.address]), HOLDER_CAP);
    }
    assert.ok(isAddressEqual(await s.token.read.policyHook(), s.hooks.token.address));
    // Live from deploy: the identity rule already gates the first mint.
    const [ok, reason] = await s.token.read.canTransfer([zeroAddress, s.holders.eve.account.address, 1n]);
    assert.equal(ok, false);
    assert.equal(reason, REASONS.RECEIVER_NOT_VERIFIED);
  });
});
