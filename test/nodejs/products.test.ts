import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, getAddress, isAddressEqual, keccak256, maxUint256, toHex, zeroAddress, zeroHash } from "viem";

import { fundOpenModule } from "../../ignition/modules/FundOpen.js";
import { productModule } from "../../ignition/modules/Product.js";
import { QUALS } from "../../ignition/modules/roles.js";
import { DEMO_SIGNERS, PROFILES, type Product, type Profile } from "../../ignition/profiles.js";
import { assertHandedOver, deployProduct, deployProfile, deployStack, deverify, PAR, REASONS, RECEIVE_AUTHORIZATION_TYPES, settlePeriod, settleThroughDesk, verify } from "./fixtures.js";

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
    await settleThroughDesk(connection, s, "asyncFund", 0n);
    await vault.write.mint([usd(100n) * PAR, a, a], { account: alice.account });
    assert.equal(await vault.read.balanceOf([a]), usd(100n) * PAR);
  });
});

describe("one core, many products", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;
  const bond: Product = { key: "bond", template: "GatedToken", name: "Corporate Bond", symbol: "BOND", rules: PLAIN };

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

describe("a vault whose asset is a gated cash token", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  const cashAndFund: Profile = {
    id: "cashAndFund",
    singleSigners: DEMO_SIGNERS,
    products: [
      {
        key: "cash",
        template: "GatedToken",
        name: "Cash Token",
        symbol: "cUSD",
        rules: ["credentialRule"],
        policy: { requireAll: 0, requireAny: QUALS.CUSTOMER | QUALS.INFRA, forbidAny: 0, attesters: 1n },
      },
      { key: "fund", template: "Gated4626Vault", name: "Cash Fund", symbol: "cFUND", rules: PLAIN, assetProduct: "cash" },
    ],
  };

  async function funded() {
    const s = await deployProfile(connection, cashAndFund);
    const cash = await viem.getContractAt("GatedToken", s.products.cash.address);
    const vault = await viem.getContractAt("Gated4626Vault", s.products.fund.address);
    return { s, cash, vault };
  }

  it("a customer pays in cash tokens, receives shares and gets them back", async function () {
    const { s, cash, vault } = await networkHelpers.loadFixture(funded);
    const alice = s.holders.alice;
    const a = alice.account.address;
    assert.ok(isAddressEqual(await vault.read.asset(), cash.address));

    await verify(s, alice, { quals: QUALS.KYC | QUALS.CUSTOMER });
    await verify(s, vault.address, { quals: QUALS.KYC | QUALS.INFRA });
    // The account is debited off-chain and treasury mints.
    await cash.write.mint([a, 1_000n], { account: s.wallets.minter.account });
    await cash.write.approve([vault.address, maxUint256], { account: alice.account });
    await vault.write.deposit([1_000n, a], { account: alice.account });
    assert.equal(await cash.read.balanceOf([a]), 0n);
    assert.equal(await cash.read.balanceOf([vault.address]), 1_000n);

    await vault.write.redeem([await vault.read.maxRedeem([a]), a, a], { account: alice.account });
    assert.equal(await cash.read.balanceOf([a]), 1_000n);
  });

  it("the cash token stays with customers and the vault, and a vault without the infrastructure bit cannot take it", async function () {
    const { s, cash, vault } = await networkHelpers.loadFixture(funded);
    const [alice, bob] = [s.holders.alice, s.holders.bob];
    await verify(s, alice, { quals: QUALS.KYC | QUALS.CUSTOMER });
    await verify(s, bob); // verified, but not a customer
    await cash.write.mint([alice.account.address, 1_000n], { account: s.wallets.minter.account });
    assert.deepEqual(await cash.read.canTransferWithReason([alice.account.address, bob.account.address, 1n]), [false, REASONS.RECEIVER_NOT_ELIGIBLE]);

    await cash.write.approve([vault.address, maxUint256], { account: alice.account });
    await viem.assertions.revertWithCustomError(
      vault.write.deposit([1_000n, alice.account.address], { account: alice.account }),
      cash,
      "PolicyGated_TransferRejected",
    );
  });
});

describe("each fund is its own lego", async function () {
  const connection = await network.create();
  const { viem, networkHelpers, ignition } = connection;
  const FUND_RULES = ["credentialRule", "fundHoldersRule"] as const;

  const twoFunds: Profile = {
    id: "twoFunds",
    singleSigners: DEMO_SIGNERS,
    products: [
      { key: "usdShare", template: "GatedToken", name: "USD Fund", symbol: "USDF", rules: FUND_RULES, fund: "usd" },
      { key: "eurShare", template: "GatedToken", name: "EUR Fund", symbol: "EURF", rules: FUND_RULES, fund: "eur" },
    ],
  };

  it("an issuer runs two funds, each with its own contract, rule and cap", async function () {
    const s = await networkHelpers.loadFixture(async function two() {
      return deployProfile(connection, twoFunds, { usdHolderCap: 1n, eurHolderCap: 2n });
    });
    const { usd, eur } = s.funds;
    assert.ok(!isAddressEqual(usd.fund.address, eur.fund.address));
    assert.ok(!isAddressEqual(usd.rule.address, eur.rule.address));
    assert.equal(await usd.fund.read.holderCap(), 1n);
    assert.equal(await eur.fund.read.holderCap(), 2n);
    assert.ok(isAddressEqual(await usd.fund.read.owner(), s.timelock.address));
    assert.ok(isAddressEqual(await eur.fund.read.owner(), s.timelock.address));
    assert.equal(await s.registry.read.isAttested([usd.rule.address, 2]), true);

    const usdShare = await viem.getContractAt("GatedToken", s.products.usdShare.address);
    const eurShare = await viem.getContractAt("GatedToken", s.products.eurShare.address);
    const [alice, bob] = [s.holders.alice, s.holders.bob];
    await verify(s, alice);
    await verify(s, bob);
    const minter = s.wallets.minter.account;

    // The USD fund is full with one investor, and the EUR fund does not care.
    await usdShare.write.mint([alice.account.address, 1n], { account: minter });
    assert.deepEqual(await usdShare.read.canTransferWithReason([zeroAddress, bob.account.address, 1n]), [false, REASONS.MAX_HOLDERS]);
    await eurShare.write.mint([alice.account.address, 1n], { account: minter });
    await eurShare.write.mint([bob.account.address, 1n], { account: minter });
    assert.equal(await usd.fund.read.holderCount(), 1n);
    assert.equal(await eur.fund.read.holderCount(), 2n);
  });

  async function fullStack() {
    return deployStack(connection);
  }

  it("a later class launches at once with nothing half-done, and is inert until the timelock registers it", async function () {
    const s = await networkHelpers.loadFixture(fullStack);
    const late: Product = { key: "late", template: "IntentToken", name: "Late", symbol: "LATE", rules: FUND_RULES, fund: "main" };
    const before = await s.fund.read.classCount();
    const launched = await deployProduct(s, late);
    const token = await viem.getContractAt("IntentToken", launched.address);

    // Fully launched: the operations account holds nothing, and the timelock administers it.
    assert.equal(await token.read.hasRole([await token.read.DEFAULT_ADMIN_ROLE(), s.timelock.address]), true);
    assert.equal(await token.read.hasRole([await token.read.DEFAULT_ADMIN_ROLE(), s.wallets.operations.account.address]), false);
    assert.equal(await s.fund.read.classCount(), before);

    // Inert: every movement is refused until it is a class of the fund.
    const alice = s.holders.alice.account.address;
    assert.deepEqual(await token.read.canTransferWithReason([zeroAddress, alice, 1n]), [false, REASONS.NOT_FUND_CLASS]);

    const governance = s.wallets.governance.account;
    const data = encodeFunctionData({ abi: s.fund.abi, functionName: "registerClass", args: [token.address] });
    const args = [s.fund.address, 0n, data, zeroHash, keccak256(toHex("late-class"))] as const;
    const delay = await s.timelock.read.getMinDelay();
    await s.timelock.write.schedule([...args, delay], { account: governance });
    await networkHelpers.time.increase(delay);
    await s.timelock.write.execute(args, { account: governance });

    assert.equal(await s.fund.read.classCount(), before + 1n);
    assert.deepEqual(await token.read.canTransferWithReason([zeroAddress, alice, 1n]), [true, REASONS.TRANSFER_OK]);
  });

  it("opening a fund that the timelock already owns reverts and changes nothing", async function () {
    const s = await networkHelpers.loadFixture(fullStack);
    const module = fundOpenModule("main", ["intent"]);
    await assert.rejects(
      ignition.deploy(module, {
        parameters: {
          [module.id]: {
            fundContract: s.fund.address,
            fundHoldersRule: s.rules.fundHoldersRule.address,
            holderCap: 9n,
            timelock: s.timelock.address,
            class_intent: s.token.address,
          },
        },
        defaultSender: s.wallets.operations.account.address,
      }),
      /OwnableUnauthorizedAccount|0x118cdaa7/,
    );
    assert.notEqual(await s.fund.read.holderCap(), 9n);
  });

  it("a product must name its fund if it lists the fund rule, and list the rule if it names a fund", function () {
    const noFund: Product = { key: "a", template: "GatedToken", name: "A", symbol: "A", rules: FUND_RULES };
    assert.throws(() => productModule(noFund), /a: fundHoldersRule needs a fund/);
    const noRule: Product = { key: "b", template: "GatedToken", name: "B", symbol: "B", rules: ["credentialRule"], fund: "usd" };
    assert.throws(() => productModule(noRule), /b: names a fund without fundHoldersRule/);
  });
});

describe("a signed entry", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  const ENTRY_TYPES = {
    Entry: [
      { name: "investor", type: "address" },
      { name: "vault", type: "address" },
      { name: "assets", type: "uint256" },
      { name: "minShares", type: "uint256" },
      { name: "asynchronous", type: "bool" },
      { name: "nonce", type: "bytes32" },
      { name: "validAfter", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  } as const;

  it("an investor signs twice, a relayer pays the gas, and the shares arrive", async function () {
    const usdc = await viem.deployContract("MockERC3009Token");
    const s = await deployProfile(connection, PROFILES.vault4626, { asset: usdc.address });
    const vault = await viem.getContractAt("Gated4626Vault", s.products.fund.address);
    const router = await viem.deployContract("SignedEntry");
    const alice = s.holders.alice;
    const a = alice.account.address;
    await verify(s, alice);
    await verify(s, router.address); // a vault's policy decides whether to accept it as a payer
    await usdc.write.mint([a, usd(100n)]);

    const now = (await s.publicClient.getBlock()).timestamp;
    const entry = {
      investor: a,
      vault: vault.address,
      assets: usd(100n),
      minShares: 1n,
      asynchronous: false,
      nonce: keccak256(toHex("one entry")),
      validAfter: 0n,
      deadline: now + 3_600n,
    };
    const chainId = await s.publicClient.getChainId();
    const entrySig = await alice.signTypedData({
      domain: { name: "SignedEntry", version: "1", chainId, verifyingContract: router.address },
      types: ENTRY_TYPES,
      primaryType: "Entry",
      message: entry,
    });
    const cashSig = await alice.signTypedData({
      domain: { name: "Mock USD", version: "2", chainId, verifyingContract: usdc.address },
      types: RECEIVE_AUTHORIZATION_TYPES,
      primaryType: "ReceiveWithAuthorization",
      message: {
        from: a,
        to: router.address,
        value: entry.assets,
        validAfter: entry.validAfter,
        validBefore: entry.deadline,
        nonce: await router.read.cashNonce([entry]),
      },
    });

    // The relayer is not the investor, and holds no asset.
    await router.write.enterWith3009([entry, entrySig, cashSig], { account: s.holders.bob.account });
    assert.ok((await vault.read.balanceOf([a])) > 0n);
    assert.equal(await usdc.read.balanceOf([a]), 0n);
    assert.equal(await usdc.read.balanceOf([router.address]), 0n);
    assert.equal(await router.read.nonceUsed([a, entry.nonce]), true);
  });
});

describe("a token's decimals", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  const twoDecimals: Profile = {
    id: "twoDecimals",
    singleSigners: DEMO_SIGNERS,
    products: [
      {
        key: "cash",
        template: "GatedToken",
        name: "Cash Token",
        symbol: "cUSD",
        decimals: 2,
        rules: ["credentialRule"],
        policy: { requireAll: 0, requireAny: QUALS.CUSTOMER | QUALS.INFRA, forbidAny: 0, attesters: 1n },
      },
      { key: "fund", template: "Gated4626Vault", name: "Cash Fund", symbol: "cFUND", rules: PLAIN, assetProduct: "cash" },
    ],
  };

  it("a cash token matches its ledger's precision, and a vault over it follows", async function () {
    const s = await networkHelpers.loadFixture(async function decimals() {
      return deployProfile(connection, twoDecimals);
    });
    const cash = await viem.getContractAt("GatedToken", s.products.cash.address);
    const vault = await viem.getContractAt("Gated4626Vault", s.products.fund.address);
    assert.equal(await cash.read.decimals(), 2);
    assert.equal(await vault.read.decimals(), 8);
  });

  it("a token that signs intents states its own too", async function () {
    const signed: Profile = {
      id: "signedCash",
      singleSigners: DEMO_SIGNERS,
      products: [
        {
          key: "cash",
          template: "IntentToken",
          name: "Signed Cash",
          symbol: "sUSD",
          decimals: 6,
          rules: ["credentialRule"],
          policy: { requireAll: 0, requireAny: QUALS.CUSTOMER | QUALS.INFRA, forbidAny: 0, attesters: 1n },
        },
      ],
    };
    const s = await networkHelpers.loadFixture(async function signedDecimals() {
      return deployProfile(connection, signed);
    });
    const cash = await viem.getContractAt("IntentToken", s.products.cash.address);
    assert.equal(await cash.read.decimals(), 6);
    assert.equal(await cash.read.templateId(), keccak256(toHex("IntentToken")));
  });

  it("a plain token states its own or takes 18", async function () {
    const s = await networkHelpers.loadFixture(async function token() {
      return deployProfile(connection, PROFILES.token);
    });
    const token = await viem.getContractAt("GatedToken", s.products.token.address);
    assert.equal(await token.read.decimals(), 18);
  });
});
