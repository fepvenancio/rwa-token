import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

import hre, { network } from "hardhat";
import { concatHex, encodeAbiParameters, getContractAddress, isAddressEqual, keccak256, toHex, zeroAddress } from "viem";

import { ROLES, TOKENS } from "../../ignition/modules/roles.js";
import { deployStack, deployUntilActivate, HOLDER_CAP, REASONS } from "./fixtures.js";

const IDVP_EXECUTOR_ID = "0xe68774e8";

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

  it("wires the DvP executor: roles, ERC-165, EXECUTOR_ROLE on the intent token, and nothing paused", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const dvp = s.dvpExecutor;
    const timelock = s.timelock.address;
    assert.equal(await dvp.read.supportsInterface([IDVP_EXECUTOR_ID]), true);
    assert.equal(await dvp.read.paused(), false);
    assert.equal(await dvp.read.hasRole([ROLES.OPERATOR, s.wallets.operator.account.address]), true);
    assert.equal(await dvp.read.hasRole([ROLES.GUARDIAN, s.wallets.guardian.account.address]), true);
    assert.equal(await dvp.read.hasRole([ROLES.RECOVERY, s.recoveryTimelock.address]), true);
    assert.equal(await dvp.read.hasRole([ROLES.DEFAULT_ADMIN, timelock]), true);
    assert.equal(await dvp.read.hasRole([ROLES.DEFAULT_ADMIN, s.wallets.deployer.account.address]), false);
    // The intent token has exactly two executors, the intent executor and the DvP executor.
    assert.equal(await s.token.read.hasRole([ROLES.EXECUTOR, s.executor.address]), true);
    assert.equal(await s.token.read.hasRole([ROLES.EXECUTOR, dvp.address]), true);
    assert.equal(await s.token.read.hasRole([ROLES.EXECUTOR, s.wallets.operator.account.address]), false);
  });

  it("puts each token where the council computes it off-chain: CREATE2(ProxyDeployer, keccak256(symbol), TokenProxy(impl, ''))", async function () {
    const s = await networkHelpers.loadFixture(stack);
    // The creation code ProxyDeployer embeds, taken from ProxyDeployer's own build. A TokenProxy compiled in another
    // job can differ in its trailing metadata hash (solc metadata includes the job's remappings).
    const buildInfoId = await hre.artifacts.getBuildInfoId("ProxyDeployer");
    const outputPath = await hre.artifacts.getBuildInfoOutputPath(buildInfoId!);
    const { output } = JSON.parse(await readFile(outputPath!, "utf8"));
    const bytecode = `0x${output.contracts["project/contracts/deploy/TokenProxy.sol"].TokenProxy.evm.bytecode.object}` as const;
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

describe("deployment with a twin hook passed to Activate", async function () {
  const connection = await network.create();
  const stages = () => deployUntilActivate(connection);

  it("a twin of the reviewed hook (same immutables, weaker rules) installs, and the post-deploy check rejects it", async function () {
    const { activate, parameters, components } = await connection.networkHelpers.loadFixture(stages);
    const token = await components.proxyDeployer.read.predict([TOKENS.intent.symbol, components.intentImpl.address]);
    // Same admin, registry and token as the reviewed hook, so the same codehash, already attested: only max-holders
    // and the fund rule, which the fund needs in order to register the class.
    const twin = await connection.viem.deployContract("ComplianceHook", [
      components.timelock.address,
      components.registry.address,
      token,
      [components.maxHoldersRule.address, components.fundHoldersRule.address],
    ]);
    assert.equal(await components.registry.read.isAttested([twin.address, 1]), true, "the attestation covers the twin");
    // ProxyDeployer checks the binding only, so Activate completes; the hand-over check is what refuses it.
    await assert.rejects(activate({ ...parameters, intentHook: twin.address }), /runs another hook/);
  });

  it("a twin without the fund rule never gets registered, so Activate stops before ownership or roles move", async function () {
    const { activate, parameters, components, wallets } = await connection.networkHelpers.loadFixture(stages);
    const token = await components.proxyDeployer.read.predict([TOKENS.intent.symbol, components.intentImpl.address]);
    const twin = await connection.viem.deployContract("ComplianceHook", [
      components.timelock.address,
      components.registry.address,
      token,
      [components.maxHoldersRule.address],
    ]);
    await assert.rejects(activate({ ...parameters, intentHook: twin.address }), /Fund_RuleNotListed/);

    // The fund stays with the deployer, empty, and no operational role was granted on the unregistered class.
    assert.ok(isAddressEqual(await components.fundContract.read.owner(), wallets.deployer.account.address));
    assert.equal(await components.fundContract.read.classCount(), 0n);
    const intent = await connection.viem.getContractAt("IntentToken", token);
    assert.equal(await intent.read.hasRole([ROLES.AGENT, wallets.agent.account.address]), false);
    assert.equal(await intent.read.hasRole([ROLES.DEFAULT_ADMIN, components.timelock.address]), false);
  });
});

describe("deployment with a tampered Activate", async function () {
  // A fresh chain: the fixture pins the clock, which only moves forward on a shared connection.
  const connection = await network.create();
  const stages = () => deployUntilActivate(connection);

  it("an Activate that points the DvP executor at another contract leaves the real one with the deployer, and the hand-over check refuses it", async function () {
    const { activate, parameters } = await connection.networkHelpers.loadFixture(stages);
    // The intent executor takes the DvP executor's roles and hand-over; the real DvP executor is never touched.
    await assert.rejects(activate({ ...parameters, dvpExecutor: parameters.executor }), /deployer holds roles on/);
  });

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
    assert.ok(isAddressEqual(await pd.read.owner(), wallets.deployer.account.address), "ownership not yet handed over");
  });
});
