import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";

// Phase 0 toolchain smoke test. Delete at the start of Phase 1.
describe("smoke", async function () {
  const { viem } = await network.create();

  it("connects to the simulated network through viem", async function () {
    const publicClient = await viem.getPublicClient();
    assert.equal(await publicClient.getChainId(), 31337);
  });
});
