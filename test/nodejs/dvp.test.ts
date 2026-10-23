import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { decodeErrorResult, isAddressEqual, parseEther, parseEventLogs, parseUnits, type Abi, type Hex } from "viem";

import {
  deployGatedCashToken,
  deployStack,
  dvpNonce,
  MONDAY,
  REASONS,
  revertOf,
  sign3009Trade,
  signGatedTrade,
  signIntent,
  type Stack,
} from "./fixtures.js";

const usd = (amount: string) => parseUnits(amount, 6);
const DAY = 86_400n;

/**
 * Delivery versus payment through the production deployment: the real security token under the real policy, the real
 * `DvPExecutor` that `Activate` wired, a gated cash token and an ERC-3009 token deployed here as external instruments.
 */
describe("DvP: a share trade against cash, settled in one transaction", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;
  const { time } = networkHelpers;

  /** The stack, alice with 1,000 shares, bob with 1,000 of each cash token, and bob's two trades' cash tokens. */
  async function funded() {
    const s = await deployStack(connection);
    const cash = await deployGatedCashToken(connection, s);
    const usdc = await viem.deployContract("MockERC3009Token");
    const { alice, bob } = s.holders;
    await s.token.write.mint([alice.account.address, parseEther("1000")], { account: s.wallets.minter.account });
    await cash.write.mint([bob.account.address, usd("1000")], { account: s.wallets.minter.account });
    await usdc.write.mint([bob.account.address, usd("1000")]);
    return { s, cash, usdc };
  }

  type Funded = Awaited<ReturnType<typeof funded>>;
  const abis = (s: Stack) => [...s.dvpExecutor.abi, ...s.token.abi] as Abi;

  const gatedArgs = (s: Stack, cash: Funded["cash"], t: Awaited<ReturnType<typeof signGatedTrade>>) =>
    [s.token.address, cash.address, t.securities.intent, t.securities.sig, t.payment.intent, t.payment.sig] as const;
  const arguments3009 = (s: Stack, usdc: Funded["usdc"], t: Awaited<ReturnType<typeof sign3009Trade>>) =>
    [s.token.address, usdc.address, t.securities.intent, t.securities.sig, t.authorization] as const;

  /** The refused leg and the token's reason, decoded from the executor's error and the revert data it carries. */
  async function legFailure(s: Stack, call: Promise<unknown>) {
    const failure = await revertOf(call, abis(s));
    assert.ok(failure, "the trade should revert");
    assert.equal(failure.errorName, "DvPExecutor_LegFailed");
    const [leg, inner] = failure.args as [number, Hex];
    const { errorName, args } = decodeErrorResult({ abi: s.token.abi, data: inner });
    assert.equal(errorName, "PolicyGated_TransferRejected");
    return { leg, reason: (args as readonly Hex[])[0] };
  }
  const CASH = 0;
  const SECURITIES = 1;

  it("a gated trade settles through the deployed executor and the events name the trade", async function () {
    const { s, cash } = await networkHelpers.loadFixture(funded);
    const { alice, bob } = s.holders;
    const trade = await signGatedTrade(s, { seller: alice, buyer: bob, securityToken: s.token, cashToken: cash, shares: parseEther("10"), cash: usd("500") });
    const args = gatedArgs(s, cash, trade);

    assert.deepEqual(await s.dvpExecutor.read.canExecuteDvPGated(args), [true, REASONS.TRANSFER_OK]);
    const hash = await s.dvpExecutor.write.executeDvPGated(args, { account: s.wallets.operator.account });
    const receipt = await s.publicClient.waitForTransactionReceipt({ hash });

    const [settled] = parseEventLogs({ abi: s.dvpExecutor.abi, logs: receipt.logs, eventName: "DvPSettled" });
    assert.equal(settled.args._securitiesIntentHash, await s.token.read.intentHash([trade.securities.intent]));
    assert.ok(isAddressEqual(settled.args._seller, alice.account.address));
    assert.ok(isAddressEqual(settled.args._buyer, bob.account.address));
    assert.ok(isAddressEqual(settled.args._securityToken, s.token.address));
    assert.ok(isAddressEqual(settled.args._cashToken, cash.address));
    assert.equal(settled.args._securityAmount, parseEther("10"));
    assert.equal(settled.args._cashAmount, usd("500"));
    assert.ok(isAddressEqual(settled.args._operator, s.wallets.operator.account.address));
    // Each token reports the executor that moved it: the DvP executor, not an operator key.
    for (const token of [s.token, cash]) {
      const [executed] = parseEventLogs({ abi: token.abi, logs: receipt.logs, eventName: "IntentExecuted" });
      assert.ok(isAddressEqual(executed.args._executor, s.dvpExecutor.address));
    }

    assert.equal(await s.token.read.balanceOf([bob.account.address]), parseEther("10"));
    assert.equal(await cash.read.balanceOf([alice.account.address]), usd("500"));
    assert.equal(await cash.read.balanceOf([bob.account.address]), usd("500"));
    assert.equal(await s.token.read.balanceOf([s.dvpExecutor.address]), 0n);
    assert.equal(await cash.read.balanceOf([s.dvpExecutor.address]), 0n);
  });

  it("an ERC-3009 trade settles when the buyer's authorization carries the nonce the helper computes", async function () {
    const { s, usdc } = await networkHelpers.loadFixture(funded);
    const { alice, bob } = s.holders;
    const trade = await sign3009Trade(s, { seller: alice, buyer: bob, securityToken: s.token, cashToken: usdc, shares: parseEther("10"), cash: usd("500") });
    const args = arguments3009(s, usdc, trade);

    // The nonce is computed off-chain from the typed data and equals what the chain derives from the token.
    assert.equal(trade.authorization.nonce, dvpNonce(s.token.address, await s.token.read.intentHash([trade.securities.intent])));
    assert.deepEqual(await s.dvpExecutor.read.canExecuteDvP3009(args), [true, REASONS.TRANSFER_OK]);
    await s.dvpExecutor.write.executeDvP3009(args, { account: s.wallets.operator.account });

    assert.equal(await s.token.read.balanceOf([bob.account.address]), parseEther("10"));
    assert.equal(await usdc.read.balanceOf([alice.account.address]), usd("500"));
    assert.equal(await usdc.read.balanceOf([bob.account.address]), usd("500"));
    assert.equal(await usdc.read.balanceOf([s.dvpExecutor.address]), 0n);
    assert.equal(await usdc.read.authorizationState([bob.account.address, trade.authorization.nonce]), true);
  });

  it("an authorization whose nonce is the bare intent hash is refused, because it would not name the security token", async function () {
    const { s, usdc } = await networkHelpers.loadFixture(funded);
    const { alice, bob } = s.holders;
    const naive = await sign3009Trade(s, {
      seller: alice,
      buyer: bob,
      securityToken: s.token,
      cashToken: usdc,
      shares: parseEther("10"),
      cash: usd("500"),
      nonce: (intentHash) => intentHash,
    });
    const args = arguments3009(s, usdc, naive);
    assert.deepEqual(await s.dvpExecutor.read.canExecuteDvP3009(args), [false, REASONS.LEGS_DO_NOT_MATCH]);
    await viem.assertions.revertWithCustomError(
      s.dvpExecutor.write.executeDvP3009(args, { account: s.wallets.operator.account }),
      s.dvpExecutor,
      "DvPExecutor_LegsDoNotMatch",
    );
    assert.equal(await usdc.read.balanceOf([bob.account.address]), usd("1000"));
  });

  it("the settlement window applies to the securities leg: a Saturday trade is refused and settles on Monday", async function () {
    const { s, cash } = await networkHelpers.loadFixture(funded);
    const { alice, bob } = s.holders;
    const saturday = MONDAY + 5n * DAY + 10n * 3_600n;
    const nextMonday = MONDAY + 7n * DAY + 10n * 3_600n;
    const trade = await signGatedTrade(s, {
      seller: alice,
      buyer: bob,
      securityToken: s.token,
      cashToken: cash,
      shares: parseEther("10"),
      cash: usd("500"),
      deadline: nextMonday + DAY,
    });
    const args = gatedArgs(s, cash, trade);

    await time.increaseTo(saturday);
    assert.deepEqual(await s.dvpExecutor.read.canExecuteDvPGated(args), [false, REASONS.OUTSIDE_SETTLEMENT_WINDOW]);
    const refused = await legFailure(s, s.dvpExecutor.write.executeDvPGated(args, { account: s.wallets.operator.account }));
    assert.deepEqual(refused, { leg: SECURITIES, reason: REASONS.OUTSIDE_SETTLEMENT_WINDOW });
    assert.equal(await cash.read.balanceOf([bob.account.address]), usd("1000"), "the cash leg ran first and was undone");

    await time.increaseTo(nextMonday);
    await s.dvpExecutor.write.executeDvPGated(args, { account: s.wallets.operator.account });
    assert.equal(await s.token.read.balanceOf([bob.account.address]), parseEther("10"));
  });

  it("at a full holder cap a partial sale to a new investor is refused and a whole-balance sale is admitted", async function () {
    const { s, cash } = await networkHelpers.loadFixture(funded);
    const { alice, bob, carol, dave } = s.holders;
    for (const w of [carol, dave]) {
      await s.token.write.mint([w.account.address, parseEther("1")], { account: s.wallets.minter.account });
    }
    assert.equal(await s.fund.read.holderCount(), 3n, "alice, carol and dave fill the fund");

    const partial = await signGatedTrade(s, { seller: alice, buyer: bob, securityToken: s.token, cashToken: cash, shares: parseEther("4"), cash: usd("200") });
    assert.deepEqual(await s.dvpExecutor.read.canExecuteDvPGated(gatedArgs(s, cash, partial)), [false, REASONS.MAX_HOLDERS]);
    const refused = await legFailure(s, s.dvpExecutor.write.executeDvPGated(gatedArgs(s, cash, partial), { account: s.wallets.operator.account }));
    assert.deepEqual(refused, { leg: SECURITIES, reason: REASONS.MAX_HOLDERS });
    assert.equal(await cash.read.balanceOf([bob.account.address]), usd("1000"));

    // Alice sells everything she holds: she leaves the fund and bob joins it, so the count does not grow.
    const whole = await signGatedTrade(s, { seller: alice, buyer: bob, securityToken: s.token, cashToken: cash, shares: parseEther("1000"), cash: usd("200") });
    await s.dvpExecutor.write.executeDvPGated(gatedArgs(s, cash, whole), { account: s.wallets.operator.account });
    assert.equal(await s.token.read.balanceOf([alice.account.address]), 0n);
    assert.equal(await s.token.read.balanceOf([bob.account.address]), parseEther("1000"));
    assert.equal(await s.fund.read.holderCount(), 3n);
  });

  it("an intent that names the DvP executor cannot be settled by the intent executor", async function () {
    const { s, cash } = await networkHelpers.loadFixture(funded);
    const { alice, bob } = s.holders;
    const operator = s.wallets.operator.account;
    const bound = await signIntent(s, alice, {
      to: bob.account.address,
      amount: 1n,
      executor: s.dvpExecutor.address,
      considerationToken: cash.address,
      considerationAmount: 1n,
    });
    const refused = await revertOf(s.executor.write.execute([s.token.address, bound.intent, bound.sig], { account: operator }), s.token.abi as Abi);
    assert.deepEqual(refused, { errorName: "PolicyGated_TransferRejected", args: [REASONS.WRONG_EXECUTOR] });

    // Naming no executor while stating a payment is refused by every executor.
    const unbound = await signIntent(s, alice, { to: bob.account.address, amount: 1n, considerationToken: cash.address, considerationAmount: 1n });
    const noExecutor = await revertOf(s.executor.write.execute([s.token.address, unbound.intent, unbound.sig], { account: operator }), s.token.abi as Abi);
    assert.deepEqual(noExecutor, { errorName: "PolicyGated_TransferRejected", args: [REASONS.CONSIDERATION_NEEDS_EXECUTOR] });
    assert.equal(await s.token.read.balanceOf([bob.account.address]), 0n);
  });

  it("only the operator submits a trade, the guardian pauses at once, and a paused executor refuses and says so", async function () {
    const { s, cash } = await networkHelpers.loadFixture(funded);
    const { alice, bob, eve } = s.holders;
    const trade = await signGatedTrade(s, { seller: alice, buyer: bob, securityToken: s.token, cashToken: cash, shares: parseEther("10"), cash: usd("500") });
    const args = gatedArgs(s, cash, trade);

    await viem.assertions.revertWithCustomError(
      s.dvpExecutor.write.executeDvPGated(args, { account: eve.account }),
      s.dvpExecutor,
      "AccessControlUnauthorizedAccount",
    );

    await s.dvpExecutor.write.pause({ account: s.wallets.guardian.account });
    assert.deepEqual(await s.dvpExecutor.read.canExecuteDvPGated(args), [false, REASONS.PAUSED]);
    await viem.assertions.revertWithCustomError(
      s.dvpExecutor.write.executeDvPGated(args, { account: s.wallets.operator.account }),
      s.dvpExecutor,
      "EnforcedPause",
    );
    assert.equal(await s.token.read.balanceOf([bob.account.address]), 0n);
  });
});

/**
 * What a trade costs, measured on the local chain with the real policy (identity, lockup, settlement window, holder cap
 * and fund rule on the security token; identity on the gated cash token). The cash token of the 3009 trade is a mock, so
 * its figure is lower than USDC's would be: Circle's token runs behind a proxy and checks a blocklist. The ceilings are
 * loose and only catch a change that makes a trade several times dearer.
 */
describe("DvP: gas", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  async function funded() {
    const s = await deployStack(connection);
    const cash = await deployGatedCashToken(connection, s);
    const usdc = await viem.deployContract("MockERC3009Token");
    const { alice, bob } = s.holders;
    await s.token.write.mint([alice.account.address, parseEther("1000")], { account: s.wallets.minter.account });
    await cash.write.mint([bob.account.address, usd("1000")], { account: s.wallets.minter.account });
    await usdc.write.mint([bob.account.address, usd("1000")]);
    return { s, cash, usdc };
  }
  const gasOf = async (s: Stack, hash: Hex) => (await s.publicClient.waitForTransactionReceipt({ hash })).gasUsed;

  it("a gated trade, an ERC-3009 trade, and the same movements as two separate intents", async function () {
    const { s, cash, usdc } = await networkHelpers.loadFixture(funded);
    const { alice, bob } = s.holders;
    const operator = s.wallets.operator.account;
    const shares = parseEther("10");

    const gated = await signGatedTrade(s, { seller: alice, buyer: bob, securityToken: s.token, cashToken: cash, shares, cash: usd("500") });
    const gatedGas = await gasOf(
      s,
      await s.dvpExecutor.write.executeDvPGated(
        [s.token.address, cash.address, gated.securities.intent, gated.securities.sig, gated.payment.intent, gated.payment.sig],
        { account: operator },
      ),
    );

    const authorized = await sign3009Trade(s, { seller: alice, buyer: bob, securityToken: s.token, cashToken: usdc, shares, cash: usd("500") });
    const authorizedGas = await gasOf(
      s,
      await s.dvpExecutor.write.executeDvP3009(
        [s.token.address, usdc.address, authorized.securities.intent, authorized.securities.sig, authorized.authorization],
        { account: operator },
      ),
    );

    // The same two movements as two plain intents through the intent executor, which is not atomic and not a trade.
    const plain = async (token: typeof s.token | typeof cash, from: typeof alice, to: typeof bob, amount: bigint) => {
      const { intent, sig } = await signIntent(s, from, { to: to.account.address, amount }, {}, token);
      return gasOf(s, await s.executor.write.execute([token.address, intent, sig], { account: operator }));
    };
    // The intent executor holds EXECUTOR_ROLE on the stack's token only, so the cash movement is a plain transfer.
    const securitiesIntentGas = await plain(s.token, alice, bob, shares);
    const cashTransferGas = await gasOf(s, await cash.write.transfer([alice.account.address, usd("500")], { account: bob.account }));

    console.log(`DvP gas: gated ${gatedGas}, ERC-3009 (mock cash) ${authorizedGas}, one securities intent through IntentExecutor ${securitiesIntentGas}, one cash transfer ${cashTransferGas}`);
    assert.ok(gatedGas < 1_000_000n && authorizedGas < 1_000_000n, "a trade should cost well under a million gas");
    assert.ok(gatedGas > securitiesIntentGas, "a trade moves two tokens, so it costs more than one intent");
  });
});
