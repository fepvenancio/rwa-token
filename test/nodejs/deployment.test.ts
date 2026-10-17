import assert from "node:assert/strict";
import { describe, it } from "node:test";

import hre, { network } from "hardhat";
import { concatHex, encodeAbiParameters, getContractAddress, isAddressEqual, keccak256, toHex, zeroAddress } from "viem";

import { ROLES, TOKENS } from "../../ignition/modules/roles.js";
import { deployStack, deployUntilActivate, HOLDER_CAP, REASONS } from "./fixtures.js";

describe("deployment (Ignition: Components → council → Tokens → council → Activate)", async function () {
  const connection = await network.create();
  const { networkHelpers } = connection;
  const stack = () => deployStack(connection);

  it("deploys every template live with its policy and hands over to the timelock", async function () {
    const s = await networkHelpers.loadFixture(stack);
    for (const t of [s.token, s.vault4626, s.vault7540]) {
      assert.ok(isAddressEqual(await t.read.registry(), s.registry.address));
      assert.equal(await s.rules.maxHoldersRule.read.capOf([t.address]), HOLDER_CAP);
    }
    // Live from deploy: the identity rule already gates the first mint.
    const [ok, reason] = await s.token.read.canTransfer([zeroAddress, s.holders.eve.account.address, 1n]);
    assert.equal(ok, false);
    assert.equal(reason, REASONS.RECEIVER_NOT_VERIFIED);
  });

  it("puts each token where the council computes it off-chain: CREATE2(ProxyDeployer, keccak256(symbol), TokenProxy(impl, ''))", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const { bytecode } = await hre.artifacts.readArtifact("TokenProxy");
    const expected = (symbol: string, implementation: `0x${string}`) =>
      getContractAddress({
        opcode: "CREATE2",
        from: s.proxyDeployer.address,
        salt: keccak256(toHex(symbol)),
        bytecode: concatHex([bytecode, encodeAbiParameters([{ type: "address" }, { type: "bytes" }], [implementation, "0x"])]),
      });
    const cases = [
      [TOKENS.intent.symbol, s.implementations.token, s.token],
      [TOKENS.fund.symbol, s.implementations.vault4626, s.vault4626],
      [TOKENS.asyncFund.symbol, s.implementations.vault7540, s.vault7540],
    ] as const;
    for (const [symbol, implementation, token] of cases) {
      assert.ok(isAddressEqual(expected(symbol, implementation.address), token.address), symbol);
      assert.equal(await s.proxyDeployer.read.saltUsed([keccak256(toHex(symbol))]), true);
    }
  });

});

describe("deployment with a tampered Activate", async function () {
  // A fresh chain: the fixture pins the clock, which only moves forward on a shared connection.
  const connection = await network.create();
  const stages = () => deployUntilActivate(connection);

  it("a hook bound to another token stops Activate before any role is granted", async function () {
    const { activate, parameters, components, wallets } = await connection.networkHelpers.loadFixture(stages);
    const client = await connection.viem.getPublicClient();
    // Swap two hooks: each is attested, but bound to the other token's address.
    const tampered = { ...parameters, intentHook: parameters.fundHook, fundHook: parameters.intentHook };
    await assert.rejects(activate(tampered), /ProxyDeployer_HookTokenMismatch/);

    const pd = components.proxyDeployer;
    for (const [key, impl] of [
      ["intent", components.intentImpl],
      ["fund", components.fundImpl],
    ] as const) {
      const predicted = await pd.read.predict([TOKENS[key].symbol, impl.address]);
      assert.equal(await client.getCode({ address: predicted }), undefined, `${key}: no proxy was created`);
      assert.equal(await pd.read.saltUsed([keccak256(toHex(TOKENS[key].symbol))]), false);
    }
    // The untampered token may be deployed in the same batch, but nothing after the deploy batch runs.
    const asyncFund = await pd.read.predict([TOKENS.asyncFund.symbol, components.asyncFundImpl.address]);
    if ((await client.getCode({ address: asyncFund })) !== undefined) {
      const vault = await connection.viem.getContractAt("Gated7540Vault", asyncFund);
      assert.equal(await vault.read.hasRole([ROLES.AGENT, wallets.agent.account.address]), false);
      assert.equal(await vault.read.hasRole([ROLES.UPGRADER, components.timelock.address]), false);
      assert.equal(await vault.read.hasRole([ROLES.DEFAULT_ADMIN, components.timelock.address]), false);
    }
    assert.equal(await components.executor.read.hasRole([ROLES.OPERATOR, wallets.operator.account.address]), false);
    assert.equal(await components.timelock.read.hasRole([ROLES.CANCELLER, wallets.guardian.account.address]), false);
  });
});
