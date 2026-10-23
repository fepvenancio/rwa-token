import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { decodeErrorResult, hashTypedData, parseEther, parseEventLogs, verifyTypedData, type Abi } from "viem";

import { deployStack, INTENT_TYPES, REASONS, revertOf, signIntent, type Intent, type Stack } from "./fixtures.js";

describe("intents: EIP-712 signing and executor settlement", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  async function funded() {
    const s = await deployStack(connection);
    await s.token.write.mint([s.holders.alice.account.address, parseEther("1000")], {
      account: s.wallets.minter.account,
    });
    return s;
  }
  const execute = (s: Stack, intent: Intent, sig: `0x${string}`) =>
    s.executor.write.execute([s.token.address, intent, sig], { account: s.wallets.operator.account });

  it("a real wallet's signTypedData matches the on-chain intentHash and settles through the executor", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob } = s.holders;
    const { intent, sig, domain } = await signIntent(s, alice, { to: bob.account.address, amount: parseEther("50") });

    const offChain = hashTypedData({ domain, types: INTENT_TYPES, primaryType: "TransferIntent", message: intent });
    assert.equal(await s.token.read.intentHash([intent]), offChain);
    assert.ok(await verifyTypedData({ address: alice.account.address, domain, types: INTENT_TYPES, primaryType: "TransferIntent", message: intent, signature: sig }));
    assert.deepEqual(await s.token.read.canExecute([intent, sig], { account: s.executor.address }), [true, REASONS.TRANSFER_OK]);

    await viem.assertions.emitWithArgs(execute(s, intent, sig), s.token, "IntentExecuted", [
      offChain,
      alice.account.address,
      bob.account.address,
      intent.amount,
      s.executor.address,
      intent.ref,
    ]);
    assert.equal(await s.token.read.balanceOf([bob.account.address]), intent.amount);
    assert.equal(await s.token.read.nonceUsed([alice.account.address, intent.nonce]), true);
  });

  it("decodes IntentExecuted from the receipt, as the ops tooling does", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { intent, sig } = await signIntent(s, s.holders.alice, { to: s.holders.bob.account.address, amount: 7n });
    const receipt = await s.publicClient.waitForTransactionReceipt({ hash: await execute(s, intent, sig) });
    const [event] = parseEventLogs({ abi: s.token.abi, logs: receipt.logs, eventName: "IntentExecuted" });
    assert.equal(event.args._intentHash, await s.token.read.intentHash([intent]));
    assert.equal(event.args._ref, intent.ref);
    assert.equal(event.args._amount, 7n);
  });

  it("a signature over another chain's domain reverts BAD_SIGNATURE, and canExecute says so first", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { intent, sig, domain } = await signIntent(s, s.holders.alice, { to: s.holders.bob.account.address, amount: 1n }, { chainId: 1n });
    assert.deepEqual(await s.token.read.canExecute([intent, sig], { account: s.executor.address }), [false, REASONS.BAD_SIGNATURE]);
    const onChainDomain = { ...domain, chainId: await s.publicClient.getChainId() };
    assert.equal(
      await verifyTypedData({ address: s.holders.alice.account.address, domain: onChainDomain, types: INTENT_TYPES, primaryType: "TransferIntent", message: intent, signature: sig }),
      false,
    );
    await viem.assertions.revertWithCustomErrorWithArgs(execute(s, intent, sig), s.token, "PolicyGated_TransferRejected", [REASONS.BAD_SIGNATURE]);
  });

  it("an intent with all ten fields set hashes alike in the wallet and on chain, and the intent executor refuses the payment it states", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob, carol } = s.holders;
    // `carol` stands in for the cash token's address: the token never reads it.
    const { intent, sig, domain } = await signIntent(s, alice, {
      to: bob.account.address,
      amount: 5n,
      executor: s.executor.address,
      considerationToken: carol.account.address,
      considerationAmount: 500n,
    });
    const offChain = hashTypedData({ domain, types: INTENT_TYPES, primaryType: "TransferIntent", message: intent });
    assert.equal(await s.token.read.intentHash([intent]), offChain, "the wallet and the chain hash all ten fields alike");
    // The token's pre-flight knows nothing of the intent executor's own refusal, which comes first.
    assert.deepEqual(await s.token.read.canExecute([intent, sig], { account: s.executor.address }), [true, REASONS.TRANSFER_OK]);

    const refused = await revertOf(execute(s, intent, sig), s.executor.abi as Abi);
    assert.deepEqual(refused, { errorName: "IntentExecutor_ConsiderationNotSupported", args: [0n] });
    assert.equal(await s.token.read.balanceOf([bob.account.address]), 0n, "the shares did not move without the payment");
    assert.equal(await s.token.read.nonceUsed([alice.account.address, intent.nonce]), false);
  });

  it("an intent that names the intent executor and states no payment settles, and the event names the executor", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob } = s.holders;
    const { intent, sig, domain } = await signIntent(s, alice, { to: bob.account.address, amount: 5n, executor: s.executor.address });
    const offChain = hashTypedData({ domain, types: INTENT_TYPES, primaryType: "TransferIntent", message: intent });
    assert.deepEqual(await s.token.read.canExecute([intent, sig], { account: s.executor.address }), [true, REASONS.TRANSFER_OK]);

    await viem.assertions.emitWithArgs(execute(s, intent, sig), s.token, "IntentExecuted", [
      offChain,
      alice.account.address,
      bob.account.address,
      5n,
      s.executor.address,
      intent.ref,
    ]);
    assert.equal(await s.token.read.balanceOf([bob.account.address]), 5n);
  });

  it("a batch with one intent that states a payment names its position and settles nothing", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob, carol } = s.holders;
    const plain = await signIntent(s, alice, { to: bob.account.address, amount: 3n });
    const paying = await signIntent(s, alice, { to: bob.account.address, amount: 4n, considerationToken: carol.account.address, considerationAmount: 1n });
    const refused = await revertOf(
      s.executor.simulate.executeBatch(
        [s.token.address, [plain.intent, paying.intent], [plain.sig, paying.sig]],
        { account: s.wallets.operator.account.address },
      ),
      s.executor.abi as Abi,
    );
    assert.deepEqual(refused, { errorName: "IntentExecutor_ConsiderationNotSupported", args: [1n] });
    assert.equal(await s.token.read.balanceOf([bob.account.address]), 0n);
    assert.equal(await s.token.read.nonceUsed([alice.account.address, plain.intent.nonce]), false);
  });

  it("an intent that names another executor is refused by the real executor, and pre-flight says so from each address", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob, carol } = s.holders;
    const named = carol.account.address; // an account other than the executor contract
    const { intent, sig } = await signIntent(s, alice, { to: bob.account.address, amount: 5n, executor: named });

    assert.deepEqual(await s.token.read.canExecute([intent, sig], { account: s.executor.address }), [false, REASONS.WRONG_EXECUTOR]);
    // Pre-flight does not check the role, only the binding: from the named address the intent is executable.
    assert.deepEqual(await s.token.read.canExecute([intent, sig], { account: named }), [true, REASONS.TRANSFER_OK]);
    await viem.assertions.revertWithCustomErrorWithArgs(execute(s, intent, sig), s.token, "PolicyGated_TransferRejected", [REASONS.WRONG_EXECUTOR]);
    assert.equal(await s.token.read.nonceUsed([alice.account.address, intent.nonce]), false);
    assert.equal(await s.token.read.balanceOf([bob.account.address]), 0n);
  });

  it("a stated consideration with no executor is refused: by the token's pre-flight, and by the intent executor before it reaches the token", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob, carol } = s.holders;
    const { intent, sig } = await signIntent(s, alice, {
      to: bob.account.address,
      amount: 5n,
      considerationToken: carol.account.address,
      considerationAmount: 500n,
    });

    assert.deepEqual(await s.token.read.canExecute([intent, sig], { account: s.executor.address }), [false, REASONS.CONSIDERATION_NEEDS_EXECUTOR]);
    const refused = await revertOf(execute(s, intent, sig), s.executor.abi as Abi);
    assert.deepEqual(refused, { errorName: "IntentExecutor_ConsiderationNotSupported", args: [0n] });
    assert.equal(await s.token.read.balanceOf([bob.account.address]), 0n);
  });

  it("replay and cancellation both surface as NONCE_USED, in pre-flight and on-chain", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob } = s.holders;
    const first = await signIntent(s, alice, { to: bob.account.address, amount: 1n });
    await execute(s, first.intent, first.sig);
    assert.deepEqual(await s.token.read.canExecute([first.intent, first.sig]), [false, REASONS.NONCE_USED]);
    await viem.assertions.revertWithCustomErrorWithArgs(execute(s, first.intent, first.sig), s.token, "PolicyGated_TransferRejected", [REASONS.NONCE_USED]);

    const cancelled = await signIntent(s, alice, { to: bob.account.address, amount: 1n });
    await viem.assertions.emitWithArgs(
      s.token.write.cancelIntent([cancelled.intent.nonce], { account: alice.account }),
      s.token,
      "IntentCancelled",
      [alice.account.address, cancelled.intent.nonce],
    );
    assert.deepEqual(await s.token.read.canExecute([cancelled.intent, cancelled.sig]), [false, REASONS.NONCE_USED]);
    await viem.assertions.revertWithCustomErrorWithArgs(execute(s, cancelled.intent, cancelled.sig), s.token, "PolicyGated_TransferRejected", [REASONS.NONCE_USED]);
  });

  it("a failed batch names the failing index and its nested reason; dropping it lets the rest settle", async function () {
    const s = await networkHelpers.loadFixture(funded);
    const { alice, bob, carol, eve } = s.holders;
    const items = [
      await signIntent(s, alice, { to: bob.account.address, amount: 10n }),
      await signIntent(s, alice, { to: eve.account.address, amount: 10n }), // eve is not verified
      await signIntent(s, alice, { to: carol.account.address, amount: 10n }),
    ];
    const batch = (list: typeof items) =>
      s.executor.write.executeBatch(
        [s.token.address, list.map((i) => i.intent), list.map((i) => i.sig)],
        { account: s.wallets.operator.account },
      );

    // Decode the outer error, then the token's revert data it carries.
    const failure = await revertOf(
      s.executor.simulate.executeBatch(
        [s.token.address, items.map((i) => i.intent), items.map((i) => i.sig)],
        { account: s.wallets.operator.account.address },
      ),
      s.executor.abi,
    );
    assert.ok(failure, "batch should revert");
    assert.equal(failure.errorName, "IntentExecutor_BatchItemFailed");
    const [index, nested] = failure.args as [bigint, `0x${string}`];
    assert.equal(index, 1n);
    const inner = decodeErrorResult({ abi: s.token.abi, data: nested });
    assert.equal(inner.errorName, "PolicyGated_TransferRejected");
    assert.deepEqual(inner.args, [REASONS.RECEIVER_NOT_VERIFIED]);
    await viem.assertions.revertWithCustomError(batch(items), s.executor, "IntentExecutor_BatchItemFailed");
    // Atomic: nothing moved, no nonce consumed.
    assert.equal(await s.token.read.nonceUsed([alice.account.address, items[0].intent.nonce]), false);

    const kept = items.filter((_, i) => BigInt(i) !== index);
    await batch(kept);
    assert.equal(await s.token.read.balanceOf([bob.account.address]), 10n);
    assert.equal(await s.token.read.balanceOf([carol.account.address]), 10n);
  });
});
