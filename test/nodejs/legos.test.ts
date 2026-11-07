// SPDX-License-Identifier: UNLICENSED
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, erc20Abi, isAddressEqual, keccak256, maxUint256, toFunctionSelector, toHex } from "viem";

import { productModule } from "../../ignition/modules/Product.js";
import { ROLES } from "../../ignition/modules/roles.js";
import { DEMO_SIGNERS, PROFILES, type Product, type Profile } from "../../ignition/profiles.js";
import { assertHandedOver, deployProfile, PAR, REASONS, settleThroughDesk, verify } from "./fixtures.js";

const usd = (amount: bigint) => amount * 10n ** 6n;
const DAY = 86_400n;
const YEAR = 365n * DAY;

describe("a fund whose money sits with one custodian", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  async function funded() {
    const s = await deployProfile(connection, PROFILES.vault7540);
    const vault = await viem.getContractAt("Gated7540Vault", s.products.asyncFund.address);
    const desk = await viem.getContractAt("NavDesk", s.legos.asyncFund.navDesk);
    const alice = s.holders.alice;
    await verify(s, alice);
    await s.asset.write.mint([alice.account.address, usd(100n)]);
    await s.asset.write.approve([vault.address, maxUint256], { account: alice.account });
    return { s, vault, desk, alice, a: alice.account.address };
  }

  it("has its desk and nothing else, and the desk is the only thing that can price", async function () {
    const { s, vault, desk } = await networkHelpers.loadFixture(funded);
    assert.deepEqual(Object.keys(s.legos.asyncFund), ["navDesk"]);
    assert.equal(await desk.read.isWired(), true);
    assert.ok(isAddressEqual(await desk.read.custodianAccount(), s.wallets.custody.account.address));
    await viem.assertions.revertWithCustomError(vault.write.closePeriod({ account: s.wallets.settler.account }), vault, "AccessControlUnauthorizedAccount");
  });

  it("runs a whole cycle: money to the custodian at one price, back from it at another, each price approved by two", async function () {
    const { s, vault, desk, alice, a } = await networkHelpers.loadFixture(funded);
    const custody = s.wallets.custody.account;
    await vault.write.requestDeposit([usd(100n), a, a], { account: alice.account });

    await settleThroughDesk(connection, s, "asyncFund", 0n);
    assert.equal(await s.asset.read.balanceOf([custody.address]), usd(100n));
    await vault.write.mint([usd(100n) * PAR, a, a], { account: alice.account });
    assert.equal(await vault.read.balanceOf([a]), usd(100n) * PAR);

    // The custodian's money has grown by a tenth, and it pays the redemption out of it.
    await s.asset.write.mint([custody.address, usd(10n)]);
    await s.asset.write.approve([vault.address, maxUint256], { account: custody });
    await vault.write.requestRedeem([usd(50n) * PAR, a, a], { account: alice.account });
    await settleThroughDesk(connection, s, "asyncFund", usd(110n));
    await vault.write.redeem([usd(50n) * PAR, a, a], { account: alice.account });
    const paid = await s.asset.read.balanceOf([a]);
    assert.ok(paid > usd(54n) && paid <= usd(55n), `paid ${paid}`);

    // The reporter cannot accept its own price, and a stranger cannot propose one.
    await networkHelpers.time.increase(await desk.read.periodLength());
    await desk.write.closePeriod();
    await viem.assertions.revertWithCustomError(desk.write.propose([0n, keccak256(toHex("r")), 0n, 0n], { account: alice.account }), desk, "NavDesk_Unauthorized");
    const asOf = BigInt(await networkHelpers.time.latest());
    await desk.write.propose([usd(60n), keccak256(toHex("r")), asOf, 0n], { account: s.wallets.reporter.account });
    const hash = await desk.read.hashOf([await desk.read.proposal()]);
    await viem.assertions.revertWithCustomError(desk.write.accept([hash], { account: s.wallets.reporter.account }), desk, "NavDesk_Unauthorized");
  });
});

describe("a fund with a redemption gate", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;
  const [product] = PROFILES.vault7540.products;
  const gated: Profile = {
    ...PROFILES.vault7540,
    id: "gatedFund",
    products: [{ ...product, nav: { ...product.nav!, redemptionGateBps: 1_000n } }],
  };

  async function funded() {
    const s = await deployProfile(connection, gated);
    const vault = await viem.getContractAt("Gated7540Vault", s.products.asyncFund.address);
    const desk = await viem.getContractAt("NavDesk", s.legos.asyncFund.navDesk);
    const { alice, bob } = s.holders;
    const custody = s.wallets.custody.account;
    await verify(s, alice);
    await verify(s, bob);
    for (const holder of [alice, bob]) {
      await s.asset.write.mint([holder.account.address, usd(1000n)]);
      await s.asset.write.approve([vault.address, maxUint256], { account: holder.account });
    }
    await s.asset.write.mint([custody.address, usd(1000n)]);
    await s.asset.write.approve([vault.address, maxUint256], { account: custody });
    await vault.write.requestDeposit([usd(900n), alice.account.address, alice.account.address], { account: alice.account });
    await vault.write.requestDeposit([usd(100n), bob.account.address, bob.account.address], { account: bob.account });
    await settleThroughDesk(connection, s, "asyncFund", 0n);
    await vault.write.mint([usd(900n) * PAR, alice.account.address, alice.account.address], { account: alice.account });
    await vault.write.mint([usd(100n) * PAR, bob.account.address, bob.account.address], { account: bob.account });
    return { s, vault, desk, alice, bob, a: alice.account.address, b: bob.account.address };
  }

  it("is set at launch and pinned by the hand-over check", async function () {
    const { s, desk } = await networkHelpers.loadFixture(funded);
    assert.equal(await desk.read.redemptionGate(), 1_000n);
    await assertHandedOver(s);
  });

  it("a tenth of the fund leaves in a period, each request filled at one fraction, and the rest deals at the next price", async function () {
    const { s, vault, alice, bob, a, b } = await networkHelpers.loadFixture(funded);
    const fromBlock = await s.publicClient.getBlockNumber();
    await vault.write.requestRedeem([usd(200n) * PAR, a, a], { account: alice.account });
    await vault.write.requestRedeem([usd(100n) * PAR, b, b], { account: bob.account });

    await settleThroughDesk(connection, s, "asyncFund", usd(1000n));
    assert.equal(await vault.read.maxRedeem([a]), usd(200n) * PAR / 3n + 1n);
    assert.equal(await vault.read.pendingRedeemRequest([0n, a]), usd(200n) * PAR - (usd(200n) * PAR / 3n + 1n));
    assert.equal(await vault.read.maxRedeem([b]), usd(100n) * PAR / 3n + 1n);

    // What was asked and what was taken are both in the history.
    const [settled] = await s.publicClient.getContractEvents({
      address: vault.address,
      abi: vault.abi,
      eventName: "PeriodSettled",
      fromBlock,
      strict: true,
    });
    assert.equal(settled.args._redemptions, usd(300n) * PAR);
    assert.equal(settled.args._redeemed, usd(100n) * PAR);

    // The next period takes a tenth of what remains, from the queue, and the gate off clears it.
    await settleThroughDesk(connection, s, "asyncFund", usd(900n));
    assert.equal(await vault.read.pendingRedeemRequest([0n, a]) + await vault.read.pendingRedeemRequest([0n, b]) <= usd(110n) * PAR, true);
    const desk = await viem.getContractAt("NavDesk", s.legos.asyncFund.navDesk);
    await networkHelpers.impersonateAccount(s.timelock.address);
    await networkHelpers.setBalance(s.timelock.address, 10n ** 18n);
    await desk.write.setRedemptionGate([0n], { account: s.timelock.address });
    await networkHelpers.stopImpersonatingAccount(s.timelock.address);
    await settleThroughDesk(connection, s, "asyncFund", usd(810n));
    assert.equal(await vault.read.pendingRedeemRequest([0n, a]), 0n);
    assert.equal(await vault.read.maxRedeem([a]), usd(200n) * PAR);
    assert.equal(await vault.read.maxRedeem([b]), usd(100n) * PAR);
    await vault.write.redeem([usd(200n) * PAR, a, a], { account: alice.account });
    const paid = (await s.asset.read.balanceOf([a])) - usd(100n);
    assert.ok(paid <= usd(200n) && usd(200n) - paid <= 3n, `paid ${paid}`);
  });
});

describe("a fund with custodians, a mandate and fees", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  async function funded() {
    const s = await deployProfile(connection, PROFILES["managed-fund"]);
    const vault = await viem.getContractAt("Gated7540Vault", s.products.managedFund.address);
    const legos = s.legos.managedFund;
    const portfolio = await viem.getContractAt("Portfolio", legos.portfolio);
    const account = await viem.getContractAt("GuardedAccount", legos.account_firstCustodian);
    const alice = s.holders.alice;
    await verify(s, alice);
    await s.asset.write.mint([alice.account.address, usd(1000n)]);
    await s.asset.write.approve([vault.address, maxUint256], { account: alice.account });
    return { s, vault, portfolio, account, alice, a: alice.account.address };
  }

  it("has exactly its legos, each attested and installed", async function () {
    const { s, portfolio } = await networkHelpers.loadFixture(funded);
    assert.deepEqual(Object.keys(s.legos.managedFund).sort(), [
      "account_firstCustodian",
      "account_secondCustodian",
      "feeModel",
      "navDesk",
      "portfolio",
      "validator_firstCustodian",
      "validator_secondCustodian",
    ]);
    assert.equal((await portfolio.read.adapters()).length, 2);
    assert.equal(await portfolio.read.ACCEPTS_REPORTED(), true);
    for (const key of ["account_firstCustodian", "account_secondCustodian"]) {
      const account = await viem.getContractAt("GuardedAccount", s.legos.managedFund[key]);
      assert.ok((await portfolio.read.riskOf([await account.read.RISK_ID()])).absoluteCap > 0n, `${key} has no cap`);
    }
  });

  it("sends money to a custodian and only there, takes its fee, and brings the money back", async function () {
    const { s, vault, portfolio, account, alice, a } = await networkHelpers.loadFixture(funded);
    const allocator = s.wallets.allocator.account;
    const custody = s.wallets.custody.account;
    const recipient = s.wallets.feeRecipient.account.address;
    const pay = (to: `0x${string}`, amount: bigint) => [
      { target: s.asset.address, data: encodeFunctionData({ abi: erc20Abi, functionName: "transfer", args: [to, amount] }) },
    ];

    await vault.write.requestDeposit([usd(1000n), a, a], { account: alice.account });
    await settleThroughDesk(connection, s, "managedFund", 0n);
    assert.equal(await s.asset.read.balanceOf([portfolio.address]), usd(1000n));
    await vault.write.mint([usd(1000n) * PAR, a, a], { account: alice.account });

    // Out, within the mandate. Anywhere else is refused.
    await portfolio.write.allocate([account.address, usd(600n), usd(600n)], { account: allocator });
    await viem.assertions.revertWithCustomError(
      account.write.execute([pay(s.holders.eve.account.address, usd(1n))], { account: allocator }),
      account,
      "GuardedAccount_CallRefused",
    );
    await account.write.execute([pay(custody.address, usd(600n))], { account: allocator });
    assert.equal(await s.asset.read.balanceOf([custody.address]), usd(600n));

    // A year on the custodian reports a gain: a fee on it, out of the idle money, to the fee model's recipient.
    await networkHelpers.time.increase(YEAR);
    await settleThroughDesk(connection, s, "managedFund", usd(660n));
    const fee = await s.asset.read.balanceOf([recipient]);
    assert.ok(fee > 0n, "no fee was paid");
    assert.equal(await s.asset.read.balanceOf([portfolio.address]), usd(400n) - fee);

    // Back, and out to the investor at the struck price.
    await s.asset.write.mint([custody.address, usd(60n)]);
    await s.asset.write.transfer([account.address, usd(660n)], { account: custody });
    await portfolio.write.deallocate([account.address, usd(660n)], { account: allocator });
    await vault.write.requestRedeem([usd(1000n) * PAR, a, a], { account: alice.account });
    await settleThroughDesk(connection, s, "managedFund", 0n);
    await vault.write.redeem([usd(1000n) * PAR, a, a], { account: alice.account });
    const out = await s.asset.read.balanceOf([a]);
    assert.ok(out > usd(1000n) && out <= usd(1060n) - fee, `paid ${out} after a fee of ${fee}`);
  });
});

describe("an instant vault that invests through a portfolio", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  async function funded() {
    const s = await deployProfile(connection, PROFILES["vault4626-invest"]);
    const vault = await viem.getContractAt("Gated4626Vault", s.products.investFund.address);
    const legos = s.legos.investFund;
    const portfolio = await viem.getContractAt("Portfolio", legos.portfolio);
    const adapter = await viem.getContractAt("ERC4626Adapter", legos.adapter_onChainVault);
    const alice = s.holders.alice;
    await verify(s, alice);
    await s.asset.write.mint([alice.account.address, usd(1000n)]);
    await s.asset.write.approve([vault.address, maxUint256], { account: alice.account });
    return { s, vault, portfolio, adapter, alice, a: alice.account.address };
  }

  it("has exactly its legos, each attested and plugged in", async function () {
    const { s, vault, portfolio, adapter } = await networkHelpers.loadFixture(funded);
    assert.deepEqual(Object.keys(s.legos.investFund).sort(), ["adapter_onChainVault", "feeModel", "portfolio"]);
    assert.ok(isAddressEqual(await vault.read.portfolio(), portfolio.address));
    assert.ok(isAddressEqual(await vault.read.feeModel(), s.legos.investFund.feeModel));
    assert.equal(await portfolio.read.ACCEPTS_REPORTED(), false);
    assert.ok((await portfolio.read.riskOf([await adapter.read.RISK_ID()])).absoluteCap > 0n, "the adapter has no cap");
  });

  it("invests, counts the gain within the rate limit, and pays out from the outside vault", async function () {
    const { s, vault, portfolio, adapter, alice, a } = await networkHelpers.loadFixture(funded);
    const allocator = s.wallets.allocator.account;
    await vault.write.deposit([usd(1000n), a], { account: alice.account });
    assert.equal(await s.asset.read.balanceOf([portfolio.address]), usd(1000n));

    await portfolio.write.allocate([adapter.address, usd(800n), 0n], { account: allocator });
    await portfolio.write.setLiquidityAdapter([adapter.address], { account: allocator });
    const target = await adapter.read.TARGET();
    await s.asset.write.mint([target, usd(80n)]);

    // Ten percent in one go, and the vault counts it no faster than its limit allows.
    await vault.write.accrue();
    const before = await vault.read.totalAssets();
    assert.ok(before < usd(1001n), `counted ${before} at once`);
    await networkHelpers.time.increase(YEAR);
    await vault.write.accrue();
    const after = await vault.read.totalAssets();
    assert.ok(after > usd(1050n) && after <= usd(1080n), `counted ${after} after a year`);
    assert.ok((await vault.read.feesOwed()) > 0n, "no fee accrued");

    const shares = await vault.read.maxRedeem([a]);
    await vault.write.redeem([shares, a, a], { account: alice.account });
    assert.ok((await s.asset.read.balanceOf([a])) > usd(1000n));
  });
});

describe("the rules a profile can list", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  const capped: Profile = {
    id: "capped",
    singleSigners: DEMO_SIGNERS,
    products: [
      { key: "note", template: "GatedToken", name: "Capped Note", symbol: "NOTE", rules: ["credentialRule", "supplyCapRule"] },
      { key: "signed", template: "IntentToken", name: "Signed Note", symbol: "SIGN", rules: ["credentialRule", "executedOnlyRule"], executors: ["intent"] },
    ],
  };

  it("a supply cap set at launch, and a token that moves only by signed intent", async function () {
    const s = await networkHelpers.loadFixture(async function cappedStack() {
      return deployProfile(connection, capped, { noteSupplyCap: 100n });
    });
    const note = await viem.getContractAt("GatedToken", s.products.note.address);
    const signed = await viem.getContractAt("IntentToken", s.products.signed.address);
    const [alice, bob] = [s.holders.alice, s.holders.bob];
    await verify(s, alice);
    await verify(s, bob);
    const a = alice.account.address;

    await note.write.mint([a, 100n], { account: s.wallets.minter.account });
    await viem.assertions.revertWithCustomErrorWithArgs(
      note.write.mint([a, 1n], { account: s.wallets.minter.account }),
      note,
      "PolicyGated_TransferRejected",
      [REASONS.ABOVE_SUPPLY_CAP],
    );

    await signed.write.mint([a, 10n], { account: s.wallets.minter.account });
    await viem.assertions.revertWithCustomErrorWithArgs(
      signed.write.transfer([bob.account.address, 1n], { account: alice.account }),
      signed,
      "PolicyGated_TransferRejected",
      [REASONS.TRANSFER_NOT_EXECUTED],
    );
  });
});

describe("the hand-over check", async function () {
  const connection = await network.create();
  const { viem } = connection;

  const { networkHelpers } = connection;
  async function asTimelock(s: { timelock: { address: `0x${string}` } }, act: () => Promise<unknown>) {
    await networkHelpers.impersonateAccount(s.timelock.address);
    await networkHelpers.setBalance(s.timelock.address, 10n ** 18n);
    await act();
    await networkHelpers.stopImpersonatingAccount(s.timelock.address);
  }

  /** A fund and its desk, with no exception named: every sensitive role must sit with a Safe. */
  const strict: Profile = { ...PROFILES.vault7540, id: "strict", singleSigners: undefined };

  it("refuses a sensitive role held by a single key, unless the profile names it", async function () {
    await assert.rejects(deployProfile(connection, strict), /agent on 0x[0-9a-fA-F]+ is a single signer/);
    await deployProfile(connection, { ...strict, id: "strictNamed", singleSigners: ["agent"] });
  });

  it("refuses a Safe of one signer and accepts one of two", async function () {
    const one = await viem.deployContract("MockSafe", [1n]);
    await assert.rejects(deployProfile(connection, strict, { agent: one.address }), /agent on 0x[0-9a-fA-F]+ is a single signer/);
    const two = await viem.deployContract("MockSafe", [2n]);
    const s = await deployProfile(connection, strict, { agent: two.address });
    await assertHandedOver(s);
  });

  it("refuses a price checked by whoever proposed it", async function () {
    const [, , , , , , , , , , , , , , , , , , , reporter] = await viem.getWalletClients();
    await assert.rejects(
      deployProfile(connection, PROFILES.vault7540, { checker: reporter.account.address, reporter: reporter.account.address }),
      /are not different accounts/,
    );
  });

  it("refuses a desk-less fund's settler as a single key, unless the profile names it", async function () {
    const deskless: Product = { ...PROFILES.vault7540.products[0], nav: undefined };
    const settled: Profile = { id: "deskless", singleSigners: ["agent"], products: [deskless] };
    await assert.rejects(deployProfile(connection, settled), /settler on 0x[0-9a-fA-F]+ is a single signer/);
  });

  it("refuses a desk that names another vault, or that does not hold the settler's role", async function () {
    const s = await deployProfile(connection, PROFILES.vault7540);
    const elsewhere = await viem.deployContract("NavDesk", [s.timelock.address, s.wallets.custody.account.address, DAY, DAY, DAY]);
    await assert.rejects(assertHandedOver({ ...s, legos: { asyncFund: { navDesk: elsewhere.address } } }), /names another vault/);
    const idle = await viem.deployContract("NavDesk", [s.products.asyncFund.address, s.wallets.custody.account.address, DAY, DAY, DAY]);
    await assert.rejects(assertHandedOver({ ...s, legos: { asyncFund: { navDesk: idle.address } } }), /no settler/);
  });

  it("refuses a person who can price beside the desk", async function () {
    const s = await deployProfile(connection, PROFILES.vault7540);
    const vault = await viem.getContractAt("Gated7540Vault", s.products.asyncFund.address);
    await asTimelock(s, () =>
      vault.write.grantRole([ROLES.SETTLER, s.wallets.settler.account.address], { account: s.timelock.address }),
    );
    await assert.rejects(assertHandedOver(s), /is also settler/);
  });

  it("refuses a portfolio or a fee model the council no longer vouches for, or one not plugged in", async function () {
    const s = await deployProfile(connection, PROFILES["vault4626-invest"]);
    const legos = s.legos.investFund;
    await assert.rejects(assertHandedOver({ ...s, legos: { investFund: { ...legos, adapter_onChainVault: legos.feeModel } } }), /the adapters of/);
    const other = await viem.deployContract("FeeModel", [s.wallets.feeRecipient.account.address, 1n, 0n, 0n, false]);
    await assert.rejects(assertHandedOver({ ...s, legos: { investFund: { ...legos, feeModel: other.address } } }), /is not plugged in/);
    await s.registry.write.revoke([keccak256((await s.publicClient.getCode({ address: legos.feeModel }))!)], { account: s.wallets.attester.account });
    await assert.rejects(assertHandedOver(s), /the fee model is not attested/);
    await s.registry.write.revoke([keccak256((await s.publicClient.getCode({ address: legos.portfolio }))!)], { account: s.wallets.attester.account });
    await assert.rejects(assertHandedOver(s), /the portfolio is not attested/);
  });

  it("refuses a custodian's validator the council no longer vouches for, or a permission or caps not the profile's", async function () {
    const s = await deployProfile(connection, PROFILES["managed-fund"]);
    const legos = s.legos.managedFund;
    const portfolio = await viem.getContractAt("Portfolio", legos.portfolio);
    const account = await viem.getContractAt("GuardedAccount", legos.account_firstCustodian);
    const asset = s.parameters.asset as `0x${string}`;
    const transfer = toFunctionSelector("transfer(address,uint256)");

    const validatorCode = keccak256((await s.publicClient.getCode({ address: legos.validator_firstCustodian }))!);
    await s.registry.write.revoke([validatorCode], { account: s.wallets.attester.account });
    await assert.rejects(assertHandedOver(s), /validator_firstCustodian is not attested/);
    await s.registry.write.attest([validatorCode, 6, "ipfs://review"], { account: s.wallets.attester.account });
    await assertHandedOver(s);

    const riskId = await account.read.RISK_ID();
    const caps = await portfolio.read.riskOf([riskId]);
    await asTimelock(s, () => portfolio.write.setCaps([riskId, caps.absoluteCap - 1n, BigInt(caps.relativeCapBps)], { account: s.timelock.address }));
    await assert.rejects(assertHandedOver(s), /the caps of account_firstCustodian/);
    await asTimelock(s, () => portfolio.write.setCaps([riskId, caps.absoluteCap, BigInt(caps.relativeCapBps)], { account: s.timelock.address }));
    await assertHandedOver(s);

    await account.write.revokePermission([asset, transfer], { account: s.wallets.guardian.account });
    await assert.rejects(assertHandedOver(s), /the permission of account_firstCustodian/);
  });

  it("refuses an on-chain target whose caps are not the profile's", async function () {
    const s = await deployProfile(connection, PROFILES["vault4626-invest"]);
    const legos = s.legos.investFund;
    const portfolio = await viem.getContractAt("Portfolio", legos.portfolio);
    const adapter = await viem.getContractAt("ERC4626Adapter", legos.adapter_onChainVault);
    const riskId = await adapter.read.RISK_ID();
    await asTimelock(s, () => portfolio.write.setCaps([riskId, 1n, 10_000n], { account: s.timelock.address }));
    await assert.rejects(assertHandedOver(s), /the caps of adapter_onChainVault/);
  });

  it("every profile passes it as written: deploying one runs the check", async function () {
    for (const profile of Object.values(PROFILES)) await deployProfile(connection, profile);
  });
});

describe("a product that does not make sense does not build", function () {
  const base = { key: "x", name: "X", symbol: "X" };
  const refused: [string, Product, RegExp][] = [
    ["a desk on an instant vault", { ...base, template: "Gated4626Vault", rules: ["credentialRule"], nav: { periodLength: 1n, cooldown: 1n, maxReportAge: 1n } }, /only a 7540 has a desk/],
    ["a portfolio on a token", { ...base, template: "GatedToken", rules: ["credentialRule"], portfolio: {} }, /only a vault has a portfolio/],
    ["a portfolio behind a 7540 with no desk", { ...base, template: "Gated7540Vault", rules: ["credentialRule"], portfolio: {} }, /needs a desk/],
    [
      "a custodian behind an instant vault",
      { ...base, template: "Gated4626Vault", rules: ["credentialRule"], portfolio: { maxRateBps: 1n, custodians: [{ key: "c", maxPerCall: 1n, absoluteCap: 1n, relativeCapBps: 1n }] } },
      /a custodian's value is reported/,
    ],
    ["a portfolio on an instant vault with no rate limit", { ...base, template: "Gated4626Vault", rules: ["credentialRule"], portfolio: {} }, /must set a rate limit/],
    ["fees with nothing to price them", { ...base, template: "Gated4626Vault", rules: ["credentialRule"], fees: { managementBps: 1n, performanceBps: 0n, hurdleBps: 0n, softHurdle: false } }, /fees need/],
    [
      "on-chain yield on a custody-only fund",
      {
        ...base,
        template: "Gated7540Vault",
        rules: ["credentialRule"],
        custodyOnly: true,
        nav: { periodLength: 1n, cooldown: 1n, maxReportAge: 1n },
        portfolio: { targets: [{ key: "t", absoluteCap: 1n, relativeCapBps: 1n }] },
      },
      /custody only/,
    ],
    ["a supply cap on a vault", { ...base, template: "Gated4626Vault", rules: ["supplyCapRule"] }, /a vault cannot use supplyCapRule/],
    ["signed-only movement on a plain token", { ...base, template: "GatedToken", rules: ["executedOnlyRule"] }, /executedOnlyRule/],
    ["an executor on a plain token", { ...base, template: "GatedToken", rules: ["credentialRule"], executors: ["intent"] }, /only an IntentToken has executors/],
    ["an executor on a vault", { ...base, template: "Gated4626Vault", rules: ["credentialRule"], executors: ["dvp"] }, /only an IntentToken has executors/],
    ["an executor on an NFT", { ...base, template: "Gated721", rules: ["credentialRule"], executors: ["intent"] }, /only an IntentToken has executors/],
    ["decimals on a vault", { ...base, template: "Gated7540Vault", rules: ["credentialRule"], decimals: 6 }, /cannot set its decimals/],
    ["decimals on an NFT", { ...base, template: "Gated721", rules: ["credentialRule"], decimals: 0 }, /cannot set its decimals/],
  ];
  for (const [name, product, message] of refused) {
    it(name, function () {
      assert.throws(() => productModule(product), message);
    });
  }
});
