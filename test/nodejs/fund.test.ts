import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import {
  encodeFunctionData,
  getAddress,
  isAddressEqual,
  keccak256,
  maxUint256,
  parseEventLogs,
  parseUnits,
  toHex,
  zeroAddress,
  zeroHash,
  type Abi,
  type Address,
  type Hex,
} from "viem";

import { RULE_ORDER } from "../../ignition/modules/roles.js";
import { deployStack, FUND_HOLDER_CAP, REASONS, revertOf, signIntent, type Stack } from "./fixtures.js";

const ATTEST = { HOOK: 1, RULE: 2 } as const;
const usd = (amount: string) => parseUnits(amount, 6);

/**
 * The fund layer through the production deployment: one fund, the three demo tokens as its classes, the fund rule in
 * every hook. Parameters changing hands go through the real timelock, as in governance.test.ts.
 */
describe("fund: investors counted across classes", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  /** The stack with asset balances and approvals, so the vault flows run. */
  async function funded() {
    const s = await deployStack(connection);
    for (const w of [s.holders.alice, s.holders.bob, s.holders.carol, s.holders.dave, s.wallets.fulfiller]) {
      await s.asset.write.mint([w.account.address, usd("1000000")]);
      for (const v of [s.vault4626.address, s.vault7540.address]) {
        await s.asset.write.approve([v, maxUint256], { account: w.account });
      }
    }
    return s;
  }

  type Holder = Stack["holders"]["alice"];

  const mintToken = (s: Stack, to: Holder, amount = 10n ** 18n) =>
    s.token.write.mint([to.account.address, amount], { account: s.wallets.minter.account });
  const deposit4626 = (s: Stack, who: Holder, assets = usd("100")) =>
    s.vault4626.write.deposit([assets, who.account.address], { account: who.account });

  /** Request, fulfil at par, claim: the holder ends up with `assets` shares of the 7540 class. */
  async function invest7540(s: Stack, who: Holder, assets = usd("100")) {
    const a = who.account.address;
    await s.vault7540.write.requestDeposit([assets, a, a], { account: who.account });
    await s.vault7540.write.fulfillDeposit([a, assets, assets], { account: s.wallets.fulfiller.account });
    await s.vault7540.write.mint([assets, a, a], { account: who.account });
  }

  let saltCounter = 0;
  async function schedule(s: Stack, target: Address, data: Hex) {
    const governance = s.wallets.governance.account;
    const delay = await s.timelock.read.getMinDelay();
    const args = [target, 0n, data, zeroHash, keccak256(toHex(`fund-op-${saltCounter++}`))] as const;
    await s.timelock.write.schedule([...args, delay], { account: governance });
    return { execute: () => s.timelock.write.execute(args, { account: governance }), delay };
  }
  async function scheduleBatch(s: Stack, calls: { target: Address; data: Hex }[]) {
    const governance = s.wallets.governance.account;
    const delay = await s.timelock.read.getMinDelay();
    const targets = calls.map((c) => c.target);
    const values = calls.map(() => 0n);
    const payloads = calls.map((c) => c.data);
    const salt = keccak256(toHex(`fund-batch-${saltCounter++}`));
    await s.timelock.write.scheduleBatch([targets, values, payloads, zeroHash, salt, delay], { account: governance });
    return { execute: () => s.timelock.write.executeBatch([targets, values, payloads, zeroHash, salt], { account: governance }), delay };
  }

  it("the deployment makes the three tokens classes of one fund, in order, and hands the fund to the timelock", async function () {
    const s = await networkHelpers.loadFixture(funded);
    assert.equal(await s.fund.read.classCount(), 3n);
    assert.equal(getAddress(await s.fund.read.classAt([1n])), getAddress(s.token.address));
    assert.equal(getAddress(await s.fund.read.classAt([2n])), getAddress(s.vault4626.address));
    assert.equal(getAddress(await s.fund.read.classAt([3n])), getAddress(s.vault7540.address));
    assert.equal(await s.fund.read.classIndexOf([s.vault7540.address]), 3n);
    assert.ok(isAddressEqual(await s.fund.read.owner(), s.timelock.address));
    assert.equal(await s.fund.read.holderCap(), FUND_HOLDER_CAP);
    // Nobody holds anything yet.
    assert.equal(await s.fund.read.holderCount(), 0n);
  });

  it("an investor in all three classes counts once, and the register events decode", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob } = s.holders;
    const a = getAddress(alice.account.address);

    const first = await s.publicClient.waitForTransactionReceipt({ hash: await mintToken(s, alice, 10n ** 18n) });
    const firstEvents = parseEventLogs({ abi: s.fund.abi, logs: first.logs });
    assert.deepEqual(
      firstEvents.map((e) => [e.eventName, e.args]),
      [
        ["HolderClassesUpdated", { _account: a, _classes: 1n }],
        ["HolderCountUpdated", { _count: 1n }],
      ],
    );

    // A second class changes the mask and not the count.
    const second = await s.publicClient.waitForTransactionReceipt({ hash: await deposit4626(s, alice) });
    const secondEvents = parseEventLogs({ abi: s.fund.abi, logs: second.logs });
    assert.deepEqual(
      secondEvents.map((e) => [e.eventName, e.args]),
      [["HolderClassesUpdated", { _account: a, _classes: 3n }]],
    );

    await invest7540(s, alice);
    assert.equal(await s.fund.read.holderCount(), 1n);
    assert.equal(await s.fund.read.heldClasses([a]), 7n);
    const [tokens, balances] = await s.fund.read.positionsOf([a]);
    assert.deepEqual(tokens.map(getAddress), [s.token.address, s.vault4626.address, s.vault7540.address].map(getAddress));
    assert.equal(balances[0], 10n ** 18n);
    assert.equal(balances[1], await s.vault4626.read.balanceOf([a]));
    assert.equal(balances[2], usd("100"));

    await mintToken(s, bob);
    assert.equal(await s.fund.read.holderCount(), 2n);
  });

  it("the fund cap holds across classes, and pre-flight agrees with the write in each", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob, carol, dave } = s.holders;
    const d = dave.account.address;
    await mintToken(s, alice);
    await deposit4626(s, bob);
    await invest7540(s, carol);
    assert.equal(await s.fund.read.holderCount(), FUND_HOLDER_CAP);

    // Token: pre-flight says MAX_HOLDERS and the mint reverts with that reason.
    assert.deepEqual(await s.token.read.canTransferWithReason([zeroAddress, d, 1n]), [false, REASONS.MAX_HOLDERS]);
    await viem.assertions.revertWithCustomErrorWithArgs(mintToken(s, dave), s.token, "PolicyGated_TransferRejected", [REASONS.MAX_HOLDERS]);
    // 4626: the gating-aware max is zero, and a deposit above it reverts.
    assert.equal(await s.vault4626.read.maxDeposit([d]), 0n);
    await viem.assertions.revertWithCustomError(deposit4626(s, dave), s.vault4626, "ERC4626ExceededMaxDeposit");
    // 7540: the request is refused up front, because there is no cancellation.
    await viem.assertions.revertWithCustomErrorWithArgs(
      s.vault7540.write.requestDeposit([usd("100"), d, d], { account: dave.account }),
      s.vault7540,
      "Gated7540Vault_ControllerNotEligible",
      [REASONS.MAX_HOLDERS],
    );

    // An existing investor still takes a position in another class at a full cap.
    assert.equal(await s.vault4626.read.maxDeposit([alice.account.address]), maxUint256);
    await deposit4626(s, alice);
    assert.equal(await s.fund.read.holderCount(), FUND_HOLDER_CAP);
    assert.equal(await s.fund.read.heldClasses([alice.account.address]), 3n);
  });

  it("an executor-settled intent to a new investor at a full fund cap is refused, with canExecute in agreement", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob, carol, dave } = s.holders;
    await mintToken(s, alice);
    await deposit4626(s, bob);
    await invest7540(s, carol);
    assert.equal(await s.fund.read.holderCount(), FUND_HOLDER_CAP);

    // Intent settlement is the EXECUTED kind: the fund cap applies to it like any other movement.
    const { intent, sig } = await signIntent(s, alice, { to: dave.account.address, amount: 1n });
    assert.deepEqual(await s.token.read.canExecute([intent, sig], { account: s.executor.address }), [false, REASONS.MAX_HOLDERS]);
    const failure = await revertOf(
      s.executor.write.execute([s.token.address, intent, sig], { account: s.wallets.operator.account }),
      [...s.executor.abi, ...s.token.abi] as Abi,
    );
    assert.equal(failure?.errorName, "PolicyGated_TransferRejected");
    assert.deepEqual(failure?.args, [REASONS.MAX_HOLDERS]);

    // A whole-balance intent is net zero, so it passes: alice leaves the fund as dave joins it.
    const whole = await signIntent(s, alice, { to: dave.account.address, amount: 10n ** 18n });
    assert.deepEqual(await s.token.read.canExecute([whole.intent, whole.sig], { account: s.executor.address }), [true, REASONS.TRANSFER_OK]);
    await s.executor.write.execute([s.token.address, whole.intent, whole.sig], { account: s.wallets.operator.account });
    assert.equal(await s.fund.read.holderCount(), FUND_HOLDER_CAP);
    assert.equal(await s.fund.read.heldClasses([alice.account.address]), 0n);
    assert.equal(await s.fund.read.heldClasses([dave.account.address]), 1n);
  });

  it("a class created after hand-over is rejected until the timelock registers it, then works", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const implementation = s.implementations.token.address;
    const predicted = await s.proxyDeployer.read.predict(["NEWF", implementation]);
    // The shared hook is already attested; the new class only names its rules.
    const rules = [s.rules.identityRule.address, s.rules.fundHoldersRule.address];
    const initData = encodeFunctionData({
      abi: s.token.abi,
      functionName: "initialize",
      args: ["New Class", "NEWF", s.timelock.address, s.wallets.guardian.account.address, s.registry.address, s.hook.address, rules],
    });
    const deploy = await schedule(
      s,
      s.proxyDeployer.address,
      encodeFunctionData({
        abi: s.proxyDeployer.abi,
        functionName: "deploy",
        args: ["NEWF", implementation, initData, s.hook.address, rules],
      }),
    );
    await networkHelpers.time.increase(deploy.delay);
    await deploy.execute();
    const created = await viem.getContractAt("IntentToken", predicted);

    // Live with its hook, and unusable: the fund does not know it yet.
    const alice = s.holders.alice.account.address;
    assert.deepEqual(await created.read.canTransferWithReason([zeroAddress, alice, 1n]), [false, REASONS.NOT_FUND_CLASS]);
    assert.equal(await created.read.canReceive([alice]), false);

    // Only the timelock registers, and only after the delay.
    await viem.assertions.revertWithCustomErrorWithArgs(
      s.fund.write.registerClass([created.address], { account: s.wallets.deployer.account }),
      s.fund,
      "OwnableUnauthorizedAccount",
      [getAddress(s.wallets.deployer.account.address)],
    );
    const registration = await schedule(
      s,
      s.fund.address,
      encodeFunctionData({ abi: s.fund.abi, functionName: "registerClass", args: [created.address] }),
    );
    await viem.assertions.revertWithCustomError(registration.execute(), s.timelock, "TimelockUnexpectedOperationState");
    await networkHelpers.time.increase(registration.delay);
    await viem.assertions.emitWithArgs(registration.execute(), s.fund, "ClassRegistered", [getAddress(created.address), 4n]);

    assert.deepEqual(await created.read.canTransferWithReason([zeroAddress, alice, 1n]), [true, REASONS.TRANSFER_OK]);
    assert.equal(await s.fund.read.classCount(), 4n);
  });

  describe("replacing the rule", function () {
    /** The ordered rule list each demo hook should have once `next` replaces the fund rule. */
    const ruleListWith = (s: Stack, key: keyof typeof RULE_ORDER, next: Address) =>
      RULE_ORDER[key].map((name) => (name === "fundHoldersRule" ? next : s.rules[name].address));
    const classes = (s: Stack) =>
      [
        { token: s.token, key: "intent" },
        { token: s.vault4626, key: "fund" },
        { token: s.vault7540, key: "asyncFund" },
      ] as const;

    it("one timelock batch swaps the rule in the fund and in every class's hook, and the count survives", async function () {
      const s = await networkHelpers.loadFixture(funded);
      await mintToken(s, s.holders.alice);
      await deposit4626(s, s.holders.bob);
      assert.equal(await s.fund.read.holderCount(), 2n);

      // Same code and same fund: the same codehash, so the council's attestation already covers it.
      const next = await viem.deployContract("FundHoldersRule", [s.fund.address]);
      assert.equal(await s.registry.read.isAttested([next.address, ATTEST.RULE]), true);

      const calls = [
        { target: s.fund.address, data: encodeFunctionData({ abi: s.fund.abi, functionName: "setRule", args: [next.address] }) },
        ...classes(s).map(({ token, key }) => ({
          target: s.hook.address,
          data: encodeFunctionData({
            abi: s.hook.abi,
            functionName: "setRules",
            args: [token.address, ruleListWith(s, key, next.address)],
          }),
        })),
      ];
      const batch = await scheduleBatch(s, calls);
      await networkHelpers.time.increase(batch.delay - 1n);
      assert.ok(isAddressEqual(await s.fund.read.rule(), s.rules.fundHoldersRule.address), "nothing moves before the delay");
      await networkHelpers.time.increase(1n);
      await batch.execute();

      assert.ok(isAddressEqual(await s.fund.read.rule(), next.address));
      assert.equal(await s.fund.read.holderCount(), 2n);
      // The new rule records, and the old one no longer can.
      await mintToken(s, s.holders.carol);
      assert.equal(await s.fund.read.holderCount(), 3n);
      assert.equal(await s.fund.read.heldClasses([s.holders.carol.account.address]), 1n);
    });

    it("setting the rule alone fails every movement closed, with pre-flight and write in agreement", async function () {
      const s = await networkHelpers.loadFixture(funded);
      await mintToken(s, s.holders.alice);
      await mintToken(s, s.holders.bob);
      const next = await viem.deployContract("FundHoldersRule", [s.fund.address]);
      const alone = await schedule(
        s,
        s.fund.address,
        encodeFunctionData({ abi: s.fund.abi, functionName: "setRule", args: [next.address] }),
      );
      await networkHelpers.time.increase(alone.delay);
      await alone.execute();

      // The hooks still list the old rule, which is no longer the fund's: it rejects a new holder and a transfer
      // between existing holders alike, and `canTransferWithReason` says so before any write.
      const carol = s.holders.carol.account.address;
      const [alice, bob] = [s.holders.alice.account.address, s.holders.bob.account.address];
      assert.deepEqual(await s.token.read.canTransferWithReason([zeroAddress, carol, 1n]), [false, REASONS.NOT_FUND_CLASS]);
      assert.deepEqual(await s.token.read.canTransferWithReason([alice, bob, 1n]), [false, REASONS.NOT_FUND_CLASS]);
      await viem.assertions.revertWithCustomErrorWithArgs(mintToken(s, s.holders.carol), s.token, "PolicyGated_TransferRejected", [REASONS.NOT_FUND_CLASS]);
      await viem.assertions.revertWithCustomErrorWithArgs(
        s.token.write.transfer([bob, 1n], { account: s.holders.alice.account }),
        s.token,
        "PolicyGated_TransferRejected",
        [REASONS.NOT_FUND_CLASS],
      );
      assert.equal(await s.fund.read.holderCount(), 2n);
      assert.equal(await s.fund.read.heldClasses([carol]), 0n);
    });
  });
});
