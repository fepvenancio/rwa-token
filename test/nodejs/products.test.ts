import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress, isAddressEqual, maxUint256, zeroAddress } from "viem";

import { productModule } from "../../ignition/modules/Product.js";
import { QUALS } from "../../ignition/modules/roles.js";
import { PROFILES, type Product, type Profile } from "../../ignition/profiles.js";
import { assertHandedOver, deployProduct, deployProfile, deverify, REASONS, verify } from "./fixtures.js";

const PLAIN = ["credentialRule", "holderRestrictionRule"] as const;
const CORE = ["credentialRegistry", "credentialRule", "holderRestrictionRule", "hook", "proxyDeployer", "recoveryTimelock", "registry", "timelock"];
const usd = (amount: bigint) => amount * 10n ** 6n;

describe("one product alone: the core and that product, and nothing else", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  it("a token", async function () {
    const s = await networkHelpers.loadFixture(async function token() {
      return deployProfile(connection, PROFILES.token);
    });
    assert.deepEqual(Object.keys(s.components).sort(), [...CORE, "gatedImpl"].sort());
    assert.equal(s.fund, undefined);
    assert.equal(s.executor, undefined);
    assert.equal(s.dvpExecutor, undefined);

    const token = await viem.getContractAt("GatedToken", s.products.token.address);
    const [alice, bob, eve] = [s.holders.alice, s.holders.bob, s.holders.eve];
    await verify(s, alice);
    await verify(s, bob);
    await token.write.mint([alice.account.address, 100n], { account: s.wallets.minter.account });
    await token.write.transfer([bob.account.address, 40n], { account: alice.account });
    assert.equal(await token.read.balanceOf([bob.account.address]), 40n);
    assert.deepEqual(await token.read.canTransferWithReason([alice.account.address, eve.account.address, 1n]), [false, REASONS.RECEIVER_NOT_VERIFIED]);
    await viem.assertions.revertWithCustomErrorWithArgs(
      token.write.transfer([eve.account.address, 1n], { account: alice.account }),
      token,
      "PolicyGated_TransferRejected",
      [REASONS.RECEIVER_NOT_VERIFIED],
    );
  });

  it("an instant vault", async function () {
    const s = await networkHelpers.loadFixture(async function vault4626() {
      return deployProfile(connection, PROFILES.vault4626);
    });
    assert.deepEqual(Object.keys(s.components).sort(), [...CORE, "fundImpl"].sort());

    const vault = await viem.getContractAt("Gated4626Vault", s.products.fund.address);
    const [alice, eve] = [s.holders.alice, s.holders.eve];
    await verify(s, alice);
    await s.asset.write.mint([alice.account.address, usd(100n)]);
    await s.asset.write.approve([vault.address, maxUint256], { account: alice.account });
    await vault.write.deposit([usd(100n), alice.account.address], { account: alice.account });
    assert.equal(await vault.read.maxDeposit([eve.account.address]), 0n);
    await vault.write.redeem([await vault.read.maxRedeem([alice.account.address]), alice.account.address, alice.account.address], { account: alice.account });
    assert.equal(await s.asset.read.balanceOf([alice.account.address]), usd(100n));
  });

  it("a request-and-claim vault", async function () {
    const s = await networkHelpers.loadFixture(async function vault7540() {
      return deployProfile(connection, PROFILES.vault7540);
    });
    assert.deepEqual(Object.keys(s.components).sort(), [...CORE, "asyncFundImpl"].sort());

    const vault = await viem.getContractAt("Gated7540Vault", s.products.asyncFund.address);
    const alice = s.holders.alice;
    const a = alice.account.address;
    await verify(s, alice);
    await s.asset.write.mint([a, usd(100n)]);
    await s.asset.write.approve([vault.address, maxUint256], { account: alice.account });
    await vault.write.requestDeposit([usd(100n), a, a], { account: alice.account });
    await vault.write.fulfillDeposit([a, usd(100n), usd(100n)], { account: s.wallets.fulfiller.account });
    await vault.write.mint([usd(100n), a, a], { account: alice.account });
    assert.equal(await vault.read.balanceOf([a]), usd(100n));
  });
});

describe("one core, many products", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;
  const bond: Product = { key: "bond", template: "GatedToken", name: "Bank Bond", symbol: "BOND", rules: PLAIN };

  async function coreAndToken() {
    return deployProfile(connection, PROFILES.token);
  }

  it("the timelocks wait 24 hours, and the operations account owns ProxyDeployer", async function () {
    const s = await networkHelpers.loadFixture(coreAndToken);
    assert.equal(await s.timelock.read.getMinDelay(), 86_400n);
    assert.equal(await s.recoveryTimelock.read.getMinDelay(), 86_400n);
    assert.ok(isAddressEqual(await s.proxyDeployer.read.owner(), s.wallets.operations.account.address));
  });

  it("a later product launches at once, is handed to the timelock, and leaves the first alone", async function () {
    const s = await networkHelpers.loadFixture(coreAndToken);
    const before = await s.hook.read.rules([s.products.token.address]);
    const launched = await deployProduct(s, bond);

    const token = await viem.getContractAt("GatedToken", launched.address);
    const operations = s.wallets.operations.account.address;
    assert.equal(await token.read.hasRole([await token.read.DEFAULT_ADMIN_ROLE(), s.timelock.address]), true);
    assert.equal(await token.read.hasRole([await token.read.DEFAULT_ADMIN_ROLE(), operations]), false);
    assert.deepEqual(await s.hook.read.rules([s.products.token.address]), before);

    // The whole stack, with both products, still passes the hand-over check.
    await assertHandedOver({ ...s, deployed: [...s.deployed, { product: bond, contract: token }] });
  });

  it("a client verified once can hold both, and a block applies to both", async function () {
    const s = await networkHelpers.loadFixture(coreAndToken);
    const launched = await deployProduct(s, bond);
    const first = await viem.getContractAt("GatedToken", s.products.token.address);
    const second = await viem.getContractAt("GatedToken", launched.address);
    const alice = s.holders.alice;
    const a = alice.account.address;
    const minter = s.wallets.minter.account;

    await verify(s, alice);
    await first.write.mint([a, 10n], { account: minter });
    await second.write.mint([a, 10n], { account: minter });
    assert.equal(await first.read.balanceOf([a]), 10n);
    assert.equal(await second.read.balanceOf([a]), 10n);

    await deverify(s, alice);
    for (const token of [first, second]) {
      assert.deepEqual(await token.read.canTransferWithReason([zeroAddress, a, 1n]), [false, REASONS.RECEIVER_NOT_VERIFIED]);
    }
  });

  it("nobody but the operations account can place a product", async function () {
    const s = await networkHelpers.loadFixture(coreAndToken);
    for (const stranger of [s.wallets.deployer, s.wallets.governance, s.wallets.guardian]) {
      await viem.assertions.revertWithCustomErrorWithArgs(
        s.proxyDeployer.write.deploy(["NOPE", s.components.gatedImpl.address, "0x", s.hook.address, []], { account: stranger.account }),
        s.proxyDeployer,
        "OwnableUnauthorizedAccount",
        [getAddress(stranger.account.address)],
      );
    }
  });

  it("a rule list a template cannot use throws when the module is built", function () {
    const unusable: Product = { key: "x", template: "Gated4626Vault", name: "X", symbol: "X", rules: ["credentialRule", "windowRule"] };
    assert.throws(() => productModule(unusable), /x: Gated4626Vault cannot use windowRule/);
  });
});

describe("a vault whose asset is the bank's tokenised deposit", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  const depositAndFund: Profile = {
    id: "depositAndFund",
    products: [
      {
        key: "deposit",
        template: "GatedToken",
        name: "Bank Deposit",
        symbol: "bUSD",
        rules: ["credentialRule"],
        policy: { requireAll: 0, requireAny: QUALS.CUSTOMER | QUALS.INFRA, forbidAny: 0, attesters: 1n },
      },
      { key: "fund", template: "Gated4626Vault", name: "Bank Fund", symbol: "bFUND", rules: PLAIN, assetProduct: "deposit" },
    ],
  };

  async function deposited() {
    const s = await deployProfile(connection, depositAndFund);
    const deposit = await viem.getContractAt("GatedToken", s.products.deposit.address);
    const vault = await viem.getContractAt("Gated4626Vault", s.products.fund.address);
    return { s, deposit, vault };
  }

  it("a customer pays in deposits, receives shares and gets the deposits back", async function () {
    const { s, deposit, vault } = await networkHelpers.loadFixture(deposited);
    const alice = s.holders.alice;
    const a = alice.account.address;
    assert.ok(isAddressEqual(await vault.read.asset(), deposit.address));

    await verify(s, alice, { quals: QUALS.KYC | QUALS.CUSTOMER });
    await verify(s, vault.address, { quals: QUALS.KYC | QUALS.INFRA });
    // The account is debited off-chain and treasury mints.
    await deposit.write.mint([a, 1_000n], { account: s.wallets.minter.account });
    await deposit.write.approve([vault.address, maxUint256], { account: alice.account });
    await vault.write.deposit([1_000n, a], { account: alice.account });
    assert.equal(await deposit.read.balanceOf([a]), 0n);
    assert.equal(await deposit.read.balanceOf([vault.address]), 1_000n);

    await vault.write.redeem([await vault.read.maxRedeem([a]), a, a], { account: alice.account });
    assert.equal(await deposit.read.balanceOf([a]), 1_000n);
  });

  it("the deposit stays with customers and the vault, and a vault without the infrastructure bit cannot take it", async function () {
    const { s, deposit, vault } = await networkHelpers.loadFixture(deposited);
    const [alice, bob] = [s.holders.alice, s.holders.bob];
    await verify(s, alice, { quals: QUALS.KYC | QUALS.CUSTOMER });
    await verify(s, bob); // verified, but not a customer
    await deposit.write.mint([alice.account.address, 1_000n], { account: s.wallets.minter.account });
    assert.deepEqual(await deposit.read.canTransferWithReason([alice.account.address, bob.account.address, 1n]), [false, REASONS.RECEIVER_NOT_ELIGIBLE]);

    await deposit.write.approve([vault.address, maxUint256], { account: alice.account });
    await viem.assertions.revertWithCustomError(
      vault.write.deposit([1_000n, alice.account.address], { account: alice.account }),
      deposit,
      "PolicyGated_TransferRejected",
    );
  });
});
