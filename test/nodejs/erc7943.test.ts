import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, getAddress, parseEther, zeroAddress } from "viem";

import { deployStack, REASONS, revertOf } from "./fixtures.js";

/** The ERC-7943 Final fungible id, the XOR of the standard's six selectors. */
const IERC7943_FUNGIBLE_ID = "0x3edbb4c4";

/** What the deployed tokens answer to the standard's questions, and the batching every call of them supports. */
describe("ERC-7943 face and multicall on the deployed stack", async function () {
  const connection = await network.create();
  const { networkHelpers } = connection;
  const stack = () => deployStack(connection);

  it("every template advertises the standard's id", async function () {
    const s = await networkHelpers.loadFixture(stack);
    for (const t of [s.token, s.vault4626, s.vault7540]) {
      assert.equal(await t.read.supportsInterface([IERC7943_FUNGIBLE_ID]), true, t.address);
    }
  });

  it("canSend and canReceive follow the identity registry, and canTransfer is never more generous", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const alice = s.holders.alice.account.address;
    const eve = s.holders.eve.account.address; // never verified
    assert.equal(await s.token.read.canSend([alice]), true);
    assert.equal(await s.token.read.canReceive([alice]), true);
    assert.equal(await s.token.read.canSend([eve]), false);
    assert.equal(await s.token.read.canReceive([eve]), false);
    // Nothing is minted yet, so no transfer is possible whatever the accounts' standing.
    assert.equal(await s.token.read.canTransfer([alice, s.holders.bob.account.address, 1n]), false);
    // The plain answer is the first value of the reasoned one.
    const [ok] = await s.token.read.canTransferWithReason([zeroAddress, alice, 1n]);
    assert.equal(await s.token.read.canTransfer([zeroAddress, alice, 1n]), ok);
  });

  it("freezing more than the balance is allowed, and the unfrozen balance is zero", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const alice = s.holders.alice.account.address;
    const bob = s.holders.bob.account.address;
    const agent = s.wallets.agent.account;
    await s.token.write.mint([alice, parseEther("10")], { account: s.wallets.minter.account });
    await s.token.write.setFrozenTokens([alice, parseEther("25")], { account: agent });
    assert.equal(await s.token.read.getFrozenTokens([alice]), parseEther("25"));
    assert.equal(await s.token.read.canTransfer([alice, bob, 1n]), false);
    const failure = await revertOf(s.token.simulate.transfer([bob, 1n], { account: alice }), s.token.abi);
    assert.deepEqual(failure, { errorName: "ERC7943InsufficientUnfrozenBalance", args: [getAddress(alice), 1n, 0n] });
  });

  it("an address freeze blocks an account both ways, and the standard's answers say so", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const alice = s.holders.alice.account.address;
    const bob = s.holders.bob.account.address;
    const agent = s.wallets.agent.account;
    await s.token.write.mint([alice, parseEther("10")], { account: s.wallets.minter.account });
    await s.rules.holderRestrictionRule.write.setFrozen([s.token.address, bob, true], { account: agent });

    assert.equal(await s.token.read.canSend([bob]), false);
    assert.equal(await s.token.read.canReceive([bob]), false);
    assert.deepEqual(await s.token.read.canTransferWithReason([alice, bob, 1n]), [false, REASONS.RECEIVER_FROZEN]);
    const failure = await revertOf(s.token.simulate.transfer([bob, 1n], { account: alice }), s.token.abi);
    assert.deepEqual(failure, { errorName: "PolicyGated_TransferRejected", args: [REASONS.RECEIVER_FROZEN] });

    await s.rules.holderRestrictionRule.write.setFrozen([s.token.address, bob, false], { account: agent });
    assert.equal(await s.token.read.canReceive([bob]), true);
    await s.token.write.transfer([bob, 1n], { account: s.holders.alice.account });
    assert.equal(await s.token.read.balanceOf([bob]), 1n);
  });

  it("a minter batches two mints in one transaction, and a stranger cannot", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const alice = s.holders.alice.account.address;
    const bob = s.holders.bob.account.address;
    const mint = (to: `0x${string}`, amount: bigint) =>
      encodeFunctionData({ abi: s.token.abi, functionName: "mint", args: [to, amount] });
    await s.token.write.multicall([[mint(alice, 3n), mint(bob, 4n)]], { account: s.wallets.minter.account });
    assert.equal(await s.token.read.balanceOf([alice]), 3n);
    assert.equal(await s.token.read.balanceOf([bob]), 4n);

    const stranger = s.holders.eve.account;
    const failure = await revertOf(s.token.simulate.multicall([[mint(alice, 1n)]], { account: stranger.address }), s.token.abi);
    assert.equal(failure?.errorName, "AccessControlUnauthorizedAccount");
    assert.equal(await s.token.read.balanceOf([alice]), 3n);
  });

  it("a token is on its own template: the id each one reports", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const ids = await Promise.all([s.token, s.vault4626, s.vault7540].map((t) => t.read.templateId()));
    assert.equal(new Set(ids).size, 3);
  });
});
