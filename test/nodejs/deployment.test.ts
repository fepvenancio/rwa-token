// SPDX-License-Identifier: UNLICENSED
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

import hre, { network } from "hardhat";
import {
  concatHex,
  encodeAbiParameters,
  getAddress,
  getContractAddress,
  isAddressEqual,
  keccak256,
  parseEther,
  toHex,
  zeroAddress,
} from "viem";

import { ROLES, TOKENS } from "../../ignition/modules/roles.js";
import { deployStack, deployUntilProducts, REASONS } from "./fixtures.js";

const IDVP_EXECUTOR_ID = "0xe68774e8";

describe("deployment (Ignition: Core → council → CoreHandover → products)", async function () {
  const connection = await network.create();
  const { networkHelpers } = connection;
  const stack = () => deployStack(connection);

  it("deploys every template live with its policy and hands over to the timelock", async function () {
    const s = await networkHelpers.loadFixture(stack);
    for (const t of [s.token, s.vault4626, s.vault7540]) {
      assert.ok(isAddressEqual(await t.read.registry(), s.registry.address));
    }
    // Live from deploy: the credential rule already gates the first mint.
    const [ok, reason] = await s.token.read.canTransferWithReason([zeroAddress, s.holders.eve.account.address, 1n]);
    assert.equal(ok, false);
    assert.equal(reason, REASONS.RECEIVER_NOT_VERIFIED);
  });

  /** RD5 and the assumptions of the review items: the order is the owner's, written out here, not read from the module. */
  it("lists each token's rules in the decided order, with the minimum off", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const r = s.rules;
    const classRules = [r.credentialRule, r.minPositionRule, r.holderRestrictionRule, r.fundHoldersRule];
    const cases = [
      [s.token, [r.credentialRule, r.minPositionRule, r.holderRestrictionRule, r.windowRule, r.fundHoldersRule]],
      [s.vault4626, classRules],
      [s.vault7540, classRules],
    ] as const;
    for (const [t, expected] of cases) {
      const listed = (await s.hook.read.rules([t.address])).map((rule) => getAddress(rule));
      assert.deepEqual(listed, expected.map((rule) => getAddress(rule.address)));
      assert.equal(await r.minPositionRule.read.minPosition([t.address]), 0n, "the minimum is off unless the deployment sets one");
    }
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

describe("a product given a twin hook", async function () {
  const connection = await network.create();
  const stages = () => deployUntilProducts(connection);

  it("a second hook on the same registry shares the attested codehash, so the product launches, and the hand-over check refuses it", async function () {
    const { launch, parameters, registry } = await connection.networkHelpers.loadFixture(stages);
    // Its only immutable is the registry, so the council's attestation of the hook covers any instance on that registry.
    const twin = await connection.viem.deployContract("ComplianceHook", [registry.address]);
    assert.equal(await registry.read.isAttested([twin.address, 1]), true, "the attestation covers the twin");
    // The tokens come up on the twin with the right rules, so ProxyDeployer is satisfied and the launch completes; the
    // hand-over check is what insists on the instance the council reviewed.
    await assert.rejects(launch({ ...parameters, hook: twin.address }), /runs another hook/);
  });

  it("a hook on another registry is not the attested one, and the token refuses it before anything is created", async function () {
    const { launch, parameters, registry, timelock, proxyDeployer, components } = await connection.networkHelpers.loadFixture(stages);
    const other = await connection.viem.deployContract("ComplianceHook", [timelock.address]);
    assert.equal(await registry.read.isAttested([other.address, 1]), false, "another registry, another codehash");
    // The token's initialiser reverts with `PolicyGated_NotAttested(address,uint8)`, which bubbles up through
    // `ProxyDeployer`, whose ABI does not name it: Ignition reports the selector.
    await assert.rejects(launch({ ...parameters, hook: other.address }), /signature 0x78193cdc/);
    const predicted = await proxyDeployer.read.predict([TOKENS.intent.symbol, components.intentImpl.address]);
    const client = await connection.viem.getPublicClient();
    assert.equal(await client.getCode({ address: predicted }), undefined, "no proxy was created");
  });
});

describe("a deployment that sets minimum positions", async function () {
  const connection = await network.create();
  const stages = () => deployUntilProducts(connection);

  it("sets each token's minimum before the hand-over, and the deployed intent token enforces it", async function () {
    const { launch, parameters } = await connection.networkHelpers.loadFixture(stages);
    const s = await launch({ ...parameters, intentMinPosition: parseEther("10"), fundMinPosition: 5n, asyncFundMinPosition: 7n });
    const min = s.rules.minPositionRule;
    assert.equal(await min.read.minPosition([s.token.address]), parseEther("10"));
    assert.equal(await min.read.minPosition([s.vault4626.address]), 5n);
    assert.equal(await min.read.minPosition([s.vault7540.address]), 7n);
    // The 7540 escrow is the token itself, exempt without being listed.
    assert.equal(await min.read.isExempt([s.vault7540.address, s.vault7540.address]), true);

    const [alice, bob] = [s.holders.alice.account.address, s.holders.bob.account.address];
    await s.token.write.mint([alice, parseEther("100")], { account: s.wallets.minter.account });
    assert.deepEqual(await s.token.read.canTransferWithReason([alice, bob, 1n]), [false, REASONS.BELOW_MIN_POSITION]);
    await connection.viem.assertions.revertWithCustomErrorWithArgs(
      s.token.write.transfer([bob, 1n], { account: s.holders.alice.account }),
      s.token,
      "PolicyGated_TransferRejected",
      [REASONS.BELOW_MIN_POSITION],
    );
    // The account-level answers do not read a minimum as a block.
    assert.equal(await s.token.read.canReceive([bob]), true);
    await s.token.write.transfer([bob, parseEther("10")], { account: s.holders.alice.account });
    assert.equal(await s.token.read.balanceOf([bob]), parseEther("10"));
  });
});

describe("a tampered deployment", async function () {
  // A fresh chain: the fixture pins the clock, which only moves forward on a shared connection.
  const connection = await network.create();
  const stages = () => deployUntilProducts(connection);

  it("a CoreHandover that points the DvP executor at another contract leaves the real one with the deployer, and the hand-over check refuses it", async function () {
    const { launch, parameters } = await connection.networkHelpers.loadFixture(stages);
    // The intent executor takes the DvP executor's roles and hand-over; the real DvP executor is never touched.
    await assert.rejects(launch({ ...parameters, dvpExecutor: parameters.executor }), /deployer holds roles on/);
  });

  /** What a refused product leaves behind: no proxy, the symbol free, and the next product never started. */
  async function assertNothingPlaced(proxyDeployer: Awaited<ReturnType<typeof stages>>["proxyDeployer"], implementation: `0x${string}`, later: `0x${string}`) {
    const client = await connection.viem.getPublicClient();
    const predicted = await proxyDeployer.read.predict([TOKENS.intent.symbol, implementation]);
    assert.equal(await client.getCode({ address: predicted }), undefined, "no proxy was created");
    assert.equal(await proxyDeployer.read.saltUsed([keccak256(toHex(TOKENS.intent.symbol))]), false);
    const next = await proxyDeployer.read.predict([TOKENS.fund.symbol, later]);
    assert.equal(await client.getCode({ address: next }), undefined, "the next product was not started");
  }

  it("a rule the council did not attest stops the product before anything is placed", async function () {
    const { launch, parameters, proxyDeployer, components, wallets } = await connection.networkHelpers.loadFixture(stages);
    // The holder-restriction rule's place in every token's rule list names a contract nobody attested as a rule.
    const tampered = { ...parameters, holderRestrictionRule: parameters.asset };
    // `ComplianceHook_NotAttested(address)` from the hook, through the token's initialiser and `ProxyDeployer`: Ignition
    // reports the selector.
    await assert.rejects(launch(tampered), /signature 0xebefa01e/);
    await assertNothingPlaced(proxyDeployer, components.intentImpl.address, components.fundImpl.address);
    assert.ok(isAddressEqual(await proxyDeployer.read.owner(), wallets.operations.account.address), "the core was handed over first");
  });

  it("an implementation the council did not attest stops the product before anything is placed", async function () {
    const { launch, parameters, proxyDeployer, components } = await connection.networkHelpers.loadFixture(stages);
    // A second IntentToken: the same source with its own codehash (UUPS keeps the contract's address in its code), so
    // the council's attestation of the first one does not cover it.
    const unreviewed = await connection.viem.deployContract("IntentToken");
    // `ProxyDeployer_ImplementationNotAttested(address)` from `ProxyDeployer.deploy` itself, before any proxy exists.
    await assert.rejects(launch({ ...parameters, intentImpl: unreviewed.address }), /ProxyDeployer_ImplementationNotAttested/);
    await assertNothingPlaced(proxyDeployer, unreviewed.address, components.fundImpl.address);
  });
});
