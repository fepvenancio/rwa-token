// SPDX-License-Identifier: UNLICENSED
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { type Address, encodeAbiParameters, encodeFunctionData, getAddress, isAddressEqual, keccak256, maxUint256, toHex, zeroAddress, zeroHash } from "viem";

import { fundOpenModule } from "../../ignition/modules/FundOpen.js";
import { productModule } from "../../ignition/modules/Product.js";
import { QUALS } from "../../ignition/modules/roles.js";
import { coreHas, corePartsModule, partsHandoverModule } from "../../ignition/parts.js";
import { DEFAULT_POLICY, DEMO_SIGNERS, missingParts, partsOf, PROFILES, type Product, type Profile } from "../../ignition/profiles.js";
import { assertHandedOver, deployProduct, deployProfile, deployStack, deverify, INTENT_TYPES, PAR, REASONS, RECEIVE_AUTHORIZATION_TYPES, settlePeriod, settleThroughDesk, verify } from "./fixtures.js";

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
      "ERC8473PolicyRejected",
      [REASONS.RECEIVER_NOT_VERIFIED],
    );
  });

  it("an NFT", async function () {
    const s = await networkHelpers.loadFixture(async function nft() {
      return deployProfile(connection, PROFILES.nft);
    });
    assert.deepEqual(Object.keys(s.components).sort(), [...CORE, "nftImpl"].sort());
    assert.equal(s.fund, undefined);

    const nft = await viem.getContractAt("Gated721", s.products.nft.address);
    const [alice, bob, eve] = [s.holders.alice, s.holders.bob, s.holders.eve];
    assert.equal(await nft.read.supportsInterface(["0xbf1ef5fe"]), true);
    await verify(s, alice);
    await verify(s, bob);
    await nft.write.mint([alice.account.address, 1n, "ipfs://note-1"], { account: s.wallets.minter.account });
    await nft.write.transferFrom([alice.account.address, bob.account.address, 1n], { account: alice.account });
    assert.ok(isAddressEqual(await nft.read.ownerOf([1n]), bob.account.address));
    assert.equal(await nft.read.tokenURI([1n]), "ipfs://note-1");
    assert.deepEqual(await nft.read.canTransferWithReason([bob.account.address, eve.account.address, 1n]), [false, REASONS.RECEIVER_NOT_VERIFIED]);
    await viem.assertions.revertWithCustomErrorWithArgs(
      nft.write.transferFrom([bob.account.address, eve.account.address, 1n], { account: bob.account }),
      nft,
      "ERC8473PolicyRejected",
      [REASONS.RECEIVER_NOT_VERIFIED],
    );
  });

  it("a multi-token", async function () {
    const s = await networkHelpers.loadFixture(async function multi() {
      return deployProfile(connection, PROFILES.multi);
    });
    assert.deepEqual(Object.keys(s.components).sort(), [...CORE, "multiImpl"].sort());
    assert.equal(s.fund, undefined);

    const series = await viem.getContractAt("Gated1155", s.products.multi.address);
    const [alice, bob, eve] = [s.holders.alice, s.holders.bob, s.holders.eve];
    assert.equal(await series.read.supportsInterface(["0x41c4fbad"]), true);
    assert.equal(await series.read.symbol(), "gSER");
    await verify(s, alice);
    await verify(s, bob);
    await series.write.mint([alice.account.address, 1n, 100n], { account: s.wallets.minter.account });
    await series.write.mint([alice.account.address, 2n, 50n], { account: s.wallets.minter.account });
    await series.write.safeBatchTransferFrom([alice.account.address, bob.account.address, [1n, 2n], [30n, 20n], "0x"], { account: alice.account });
    assert.equal(await series.read.balanceOf([bob.account.address, 1n]), 30n);
    assert.equal(await series.read.balanceOf([bob.account.address, 2n]), 20n);
    assert.equal(await series.read.totalSupply([1n]), 100n);
    assert.deepEqual(await series.read.canTransferWithReason([bob.account.address, eve.account.address, 1n, 30n]), [false, REASONS.RECEIVER_NOT_VERIFIED]);
    await viem.assertions.revertWithCustomErrorWithArgs(
      series.write.safeTransferFrom([bob.account.address, eve.account.address, 1n, 30n, "0x"], { account: bob.account }),
      series,
      "ERC8473PolicyRejected",
      [REASONS.RECEIVER_NOT_VERIFIED],
    );
  });

  it("an intent token, with both executors", async function () {
    const s = await networkHelpers.loadFixture(async function intent() {
      return deployProfile(connection, PROFILES.intent);
    });
    assert.deepEqual(Object.keys(s.components).sort(), [...CORE, "intentImpl", "executor", "dvpExecutor"].sort());
    assert.equal(s.fund, undefined);

    const token = await viem.getContractAt("IntentToken", s.products.intent.address);
    const [alice, bob] = [s.holders.alice, s.holders.bob];
    await verify(s, alice);
    await verify(s, bob);
    await token.write.mint([alice.account.address, 100n], { account: s.wallets.minter.account });
    const [, name, version, chainId, verifyingContract] = await token.read.eip712Domain();
    const now = (await s.publicClient.getBlock()).timestamp;
    const intent = {
      from: alice.account.address,
      to: bob.account.address,
      amount: 40n,
      nonce: keccak256(toHex("one intent")),
      deadline: now + 3_600n,
      ref: keccak256(toHex("ref")),
      executor: zeroAddress,
      validAfter: 0n,
      considerationToken: zeroAddress,
      considerationAmount: 0n,
    };
    const sig = await alice.signTypedData({ domain: { name, version, chainId, verifyingContract }, types: INTENT_TYPES, primaryType: "TransferIntent", message: intent });
    await s.executor!.write.execute([token.address, intent, sig], { account: s.wallets.operator.account });
    assert.equal(await token.read.balanceOf([bob.account.address]), 40n);
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
    for (const rule of ["minPositionRule", "fundHoldersRule", "supplyCapRule", "windowRule", "executedOnlyRule"] as const) {
      const note: Product = { key: "n", template: "Gated721", name: "N", symbol: "N", rules: ["credentialRule", rule], fund: "main" };
      assert.throws(() => productModule(note), new RegExp(`n: Gated721 cannot use ${rule}`));
    }
    for (const rule of ["fundHoldersRule", "supplyCapRule", "windowRule", "executedOnlyRule"] as const) {
      const series: Product = { key: "m", template: "Gated1155", name: "M", symbol: "M", rules: ["credentialRule", rule], fund: "main" };
      assert.throws(() => productModule(series), new RegExp(`m: Gated1155 cannot use ${rule}`));
    }
    const withMinimum: Product = { key: "m", template: "Gated1155", name: "M", symbol: "M", rules: ["credentialRule", "minPositionRule"] };
    assert.doesNotThrow(() => productModule(withMinimum));
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
      "ERC8473PolicyRejected",
    );
  });
});

describe("a client verified once holds a token and an NFT of the same issuer", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  const tokenAndNote: Profile = {
    id: "tokenAndNote",
    singleSigners: DEMO_SIGNERS,
    products: [
      { key: "token", template: "GatedToken", name: "Gated Token", symbol: "GTK", rules: PLAIN },
      { key: "nft", template: "Gated721", name: "Gated Note", symbol: "gNOTE", rules: PLAIN },
    ],
  };

  it("one credential admits the client to both, and one block stops both", async function () {
    const s = await networkHelpers.loadFixture(async function both() {
      return deployProfile(connection, tokenAndNote);
    });
    const token = await viem.getContractAt("GatedToken", s.products.token.address);
    const nft = await viem.getContractAt("Gated721", s.products.nft.address);
    const alice = s.holders.alice;
    const a = alice.account.address;

    await verify(s, alice);
    await token.write.mint([a, 100n], { account: s.wallets.minter.account });
    await nft.write.mint([a, 1n, "ipfs://note-1"], { account: s.wallets.minter.account });
    assert.equal(await token.read.balanceOf([a]), 100n);
    assert.ok(isAddressEqual(await nft.read.ownerOf([1n]), a));

    await deverify(s, alice);
    assert.equal(await token.read.canReceive([a]), false);
    assert.equal(await nft.read.canReceive([a]), false);
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

describe("adding to a running core", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;
  const later: Product[] = [
    { key: "laterFund", template: "Gated4626Vault", name: "Later Fund", symbol: "lFUND", rules: PLAIN },
    { key: "laterNote", template: "Gated721", name: "Later Note", symbol: "lNOTE", rules: PLAIN },
    { key: "laterIntent", template: "IntentToken", name: "Later Intent", symbol: "lINT", rules: PLAIN, executors: ["intent", "dvp"] },
  ];

  async function tokenCore() {
    return deployProfile(connection, PROFILES.token);
  }

  it("a token's core later takes a vault, an NFT and an intent token with its executors, and keeps its timelocks and hook", async function () {
    // Its own deployment: adding parts extends the stack object, which a shared fixture would hand to the next test.
    const s = await tokenCore();
    const [timelock, hook, registry] = [s.timelock.address, s.hook.address, s.registry.address];
    const added = await s.addParts({ products: later });
    assert.deepEqual([...added].sort(), ["dvpExecutor", "executor", "fundImpl", "intentImpl", "nftImpl"]);
    for (const product of later) await deployProduct(s, product);

    assert.ok(isAddressEqual(s.timelock.address, timelock) && isAddressEqual(s.hook.address, hook) && isAddressEqual(s.registry.address, registry));
    for (const product of later) {
      const placed = await viem.getContractAt("GatedToken", s.products[product.key].address);
      assert.ok(isAddressEqual(await placed.read.policy(), hook), `${product.key} runs another hook`);
    }
    await assertHandedOver({ ...s, deployed: [...s.deployed, ...later.map((product) => ({ product, contract: s.products[product.key] }))] });

    const intent = await viem.getContractAt("IntentToken", s.products.laterIntent.address);
    assert.equal(await intent.read.hasRole([await intent.read.EXECUTOR_ROLE(), s.executor!.address]), true);
  });

  it("asks only for what the core lacks, and refuses to deploy a part twice", async function () {
    const s = await networkHelpers.loadFixture(tokenCore);
    const present = Object.keys(s.components);
    assert.deepEqual(missingParts({ products: [PROFILES.token.products[0]] }, present), []);
    assert.deepEqual(missingParts({ products: [later[0]] }, present), ["fundImpl"]);
    assert.throws(() => corePartsModule(["gatedImpl"], present), /gatedImpl is already in the core/);
    assert.throws(() => corePartsModule([], present), /nothing to add/);
    assert.throws(() => partsHandoverModule([]), /nothing to hand over/);

    // On the command line an unset CORE_HAS is refused: an empty list would deploy every part again.
    const saved = process.env.CORE_HAS;
    try {
      delete process.env.CORE_HAS;
      assert.throws(() => coreHas(), /CORE_HAS must list/);
      process.env.CORE_HAS = "timelock,gatedImpl";
      assert.deepEqual(coreHas(), ["timelock", "gatedImpl"]);
      // A list that names nothing would read every part as missing, as an unset one would.
      for (const empty of ["", " ", " , ", ","]) {
        process.env.CORE_HAS = empty;
        assert.throws(() => coreHas(), /CORE_HAS must list/, `CORE_HAS=${JSON.stringify(empty)}`);
      }
      // A mistyped key would be ignored and its part deployed again.
      process.env.CORE_HAS = "timelock,GatedToken";
      assert.throws(() => coreHas(), /GatedToken is not a part of a core/);
      process.env.CORE_HAS = " timelock , gatedImpl ,";
      assert.deepEqual(coreHas(), ["timelock", "gatedImpl"]);
      // Every key a whole deployment produces is accepted.
      process.env.CORE_HAS = present.join(",");
      assert.deepEqual(coreHas(), present);
    } finally {
      if (saved === undefined) delete process.env.CORE_HAS;
      else process.env.CORE_HAS = saved;
    }
  });

  it("a signed entry joins a running core alone, and an investor enters a vault through it", async function () {
    const usdc = await viem.deployContract("MockERC3009Token");
    const s = await deployProfile(connection, PROFILES.vault4626, { asset: usdc.address });
    assert.equal(s.signedEntry, undefined);
    assert.deepEqual(await s.addParts({ products: [], signedEntry: true }), ["signedEntry"]);
    await assertHandedOver({ ...s, profile: { ...s.profile, signedEntry: true } });

    const router = s.signedEntry!;
    const vault = await viem.getContractAt("Gated4626Vault", s.products.fund.address);
    const alice = s.holders.alice;
    const a = alice.account.address;
    await verify(s, alice);
    await verify(s, router.address);
    await usdc.write.mint([a, usd(10n)]);
    const now = (await s.publicClient.getBlock()).timestamp;
    const entry = {
      investor: a,
      vault: vault.address,
      assets: usd(10n),
      minShares: 1n,
      asynchronous: false,
      nonce: keccak256(toHex("entry")),
      validAfter: 0n,
      deadline: now + 3_600n,
    };
    const chainId = await s.publicClient.getChainId();
    const entrySig = await alice.signTypedData({
      domain: { name: "SignedEntry", version: "1", chainId, verifyingContract: router.address },
      types: {
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
      },
      primaryType: "Entry",
      message: entry,
    });
    const cashSig = await alice.signTypedData({
      domain: { name: "Mock USD", version: "2", chainId, verifyingContract: usdc.address },
      types: RECEIVE_AUTHORIZATION_TYPES,
      primaryType: "ReceiveWithAuthorization",
      message: { from: a, to: router.address, value: entry.assets, validAfter: 0n, validBefore: entry.deadline, nonce: await router.read.cashNonce([entry]) },
    });
    await router.write.enterWith3009([entry, entrySig, cashSig], { account: s.holders.bob.account });
    assert.ok((await vault.read.balanceOf([a])) > 0n);
  });

  it("a whole deployment that asks for a signed entry has one, and the check refuses a stack that lost it", async function () {
    const s = await deployProfile(connection, { ...PROFILES.token, id: "tokenWithEntry", signedEntry: true });
    assert.ok(s.signedEntry !== undefined);
    await assert.rejects(assertHandedOver({ ...s, signedEntry: undefined }), /no signed entry/);
  });
});

describe("a distribution on a deployed token", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;
  const bond: Profile = {
    id: "bond",
    singleSigners: DEMO_SIGNERS,
    products: [{ key: "bond", template: "GatedToken", name: "Corporate Bond", symbol: "BOND", rules: PLAIN, distributor: true }],
  };
  const leafOf = (holder: `0x${string}`, amount: bigint) =>
    keccak256(keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [holder, amount])));

  async function bondStack() {
    return deployProfile(connection, bond);
  }

  it("a maker proposes, a different checker approves and funds it, and a holder claims", async function () {
    const s = await networkHelpers.loadFixture(bondStack);
    const distributor = await viem.getContractAt("Distributor", s.legos.bond.distributor);
    assert.ok(isAddressEqual(await distributor.read.TOKEN(), s.products.bond.address));

    const cash = await viem.deployContract("MockAsset", [6]);
    const funder = s.wallets.custody;
    await cash.write.mint([funder.account.address, usd(50n)]);
    await cash.write.approve([distributor.address, usd(50n)], { account: funder.account });
    const alice = s.holders.alice;
    await verify(s, alice);

    const now = (await s.publicClient.getBlock()).timestamp;
    const root = leafOf(alice.account.address, usd(50n));
    await distributor.write.propose([root, cash.address, usd(50n), now + 86_400n, funder.account.address], { account: s.wallets.distributionMaker.account });
    await distributor.write.approve([1n], { account: s.wallets.checker.account });
    await distributor.write.claim([1n, alice.account.address, usd(50n), []]);
    assert.equal(await cash.read.balanceOf([alice.account.address]), usd(50n));
  });

  it("the check refuses a distributor naming another token, a maker who is also the checker, and a stray maker", async function () {
    const s = await networkHelpers.loadFixture(bondStack);
    const other = await viem.deployContract("Distributor", [s.timelock.address]);
    await assert.rejects(assertHandedOver({ ...s, legos: { bond: { ...s.legos.bond, distributor: other.address } } }), /names another token|not the release's/);
    await assert.rejects(
      assertHandedOver({ ...s, parameters: { ...s.parameters, distributionMaker: s.wallets.checker.account.address } }),
      /the distribution maker and checker of .* are the same account/,
    );

    const token = await viem.getContractAt("GatedToken", s.products.bond.address);
    const maker = await viem.getContractAt("Distributor", s.legos.bond.distributor).then((d) => d.read.DISTRIBUTION_MAKER_ROLE());
    await networkHelpers.impersonateAccount(s.timelock.address);
    await networkHelpers.setBalance(s.timelock.address, 10n ** 18n);
    await token.write.grantRole([maker, s.wallets.agent.account.address], { account: s.timelock.address });
    await assert.rejects(assertHandedOver(s), /is also distribution maker/);
  });
});

describe("an issuer on another issuer's credential registry", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;
  const IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
  const IMPLEMENTATION = 3;

  /** A solo issuer's one token, on a core that names an existing credential rule instead of deploying its own. */
  const solo: Profile = {
    id: "solo",
    singleSigners: DEMO_SIGNERS,
    credentials: "external",
    products: [{ key: "solo", template: "GatedToken", name: "Solo Token", symbol: "SOLO", rules: PLAIN }],
  };
  /** The parameters that name the registry and the governance the solo issuer accepts: the whole deployment's. */
  const namedBy = (whole: Awaited<ReturnType<typeof deployProfile>>) => ({
    credentialRule: whole.rules.credentialRule!.address,
    credentialAdmin: whole.timelock.address,
    credentialGuardian: whole.wallets.guardian.account.address,
  });

  async function twoIssuers() {
    const whole = await deployProfile(connection, PROFILES.full);
    const issuer = await deployProfile(connection, solo, namedBy(whole));
    return { whole, issuer };
  }

  it("the solo core deploys no registry or rule, and an investor credentialed once holds both issuers' tokens", async function () {
    const { whole, issuer } = await networkHelpers.loadFixture(twoIssuers);
    assert.deepEqual(partsOf(solo), ["holderRestrictionRule", "gatedImpl"]);
    assert.deepEqual(missingParts({ ...solo, products: [...solo.products, PROFILES.intent.products[0]] }, ["holderRestrictionRule", "gatedImpl"]), ["intentImpl", "executor", "dvpExecutor"]);
    assert.equal(issuer.components.credentialRegistry, undefined);
    assert.equal(issuer.components.credentialRule, undefined);
    assert.ok(isAddressEqual(issuer.credentials!.address, whole.credentials!.address));

    const wholeToken = await viem.getContractAt("IntentToken", whole.products.intent.address);
    const soloToken = await viem.getContractAt("GatedToken", issuer.products.solo.address);
    const [alice, eve] = [whole.holders.alice, whole.holders.eve];
    await verify(whole, alice);
    await wholeToken.write.mint([alice.account.address, 10n], { account: whole.wallets.minter.account });
    await soloToken.write.mint([alice.account.address, 10n], { account: issuer.wallets.minter.account });
    assert.equal(await wholeToken.read.balanceOf([alice.account.address]), 10n);
    assert.equal(await soloToken.read.balanceOf([alice.account.address]), 10n);
    assert.deepEqual(await soloToken.read.canTransferWithReason([alice.account.address, eve.account.address, 1n]), [false, REASONS.RECEIVER_NOT_VERIFIED]);
  });

  it("a later product on the solo core adds its implementation and still no registry", async function () {
    const { whole } = await networkHelpers.loadFixture(twoIssuers);
    // Its own deployment: adding parts extends the stack object, which a shared fixture would hand to the next test.
    const issuer = await deployProfile(connection, solo, namedBy(whole));
    const note: Product = { key: "soloNote", template: "Gated721", name: "Solo Note", symbol: "sNOTE", rules: PLAIN };
    assert.deepEqual(await issuer.addParts({ products: [note] }), ["nftImpl"]);
    await deployProduct(issuer, note);
    assert.equal(issuer.components.credentialRegistry, undefined);
    await assertHandedOver({ ...issuer, deployed: [...issuer.deployed, { product: note, contract: issuer.products.soloNote }] });
  });

  it("the registry's guardian blocks an investor, and both issuers' tokens refuse to deliver to it", async function () {
    const { whole, issuer } = await networkHelpers.loadFixture(twoIssuers);
    const alice = whole.holders.alice.account.address;
    await verify(whole, alice);
    const tokens = [await viem.getContractAt("IntentToken", whole.products.intent.address), await viem.getContractAt("GatedToken", issuer.products.solo.address)];
    for (const token of tokens) assert.equal(await token.read.canReceive([alice]), true);
    await whole.credentials!.write.blockSubject([alice], { account: whole.wallets.guardian.account });
    for (const token of tokens) {
      assert.equal(await token.read.canReceive([alice]), false);
      assert.deepEqual(await token.read.canTransferWithReason([zeroAddress, alice, 1n]), [false, REASONS.RECEIVER_NOT_VERIFIED]);
    }
  });

  it("upgrades stay with each issuer: the solo timelock upgrades its token and the other issuer's tokens keep theirs", async function () {
    const { whole, issuer } = await networkHelpers.loadFixture(twoIssuers);
    const implementationOf = async (proxy: Address) => getAddress(`0x${(await issuer.publicClient.getStorageAt({ address: proxy, slot: IMPLEMENTATION_SLOT }))!.slice(26)}`);
    const soloToken = await viem.getContractAt("GatedToken", issuer.products.solo.address);
    const wholeTokens = whole.deployed.map(({ contract }) => contract);
    const before = await Promise.all(wholeTokens.map((t) => implementationOf(t.address)));

    // The solo issuer's council attests the new implementation in its own registry, and its governance upgrades.
    const next = await viem.deployContract("GatedToken");
    const code = await issuer.publicClient.getCode({ address: next.address });
    await issuer.registry.write.attest([keccak256(code!), IMPLEMENTATION, "ipfs://review"], { account: issuer.wallets.attester.account });
    const data = encodeFunctionData({ abi: soloToken.abi, functionName: "upgradeToAndCall", args: [next.address, "0x"] });
    const args = [soloToken.address, 0n, data, zeroHash, keccak256(toHex("solo-upgrade"))] as const;
    const delay = await issuer.timelock.read.getMinDelay();
    await issuer.timelock.write.schedule([...args, delay], { account: issuer.wallets.governance.account });
    await networkHelpers.time.increase(delay);
    await issuer.timelock.write.execute(args, { account: issuer.wallets.governance.account });

    assert.ok(isAddressEqual(await implementationOf(soloToken.address), next.address));
    assert.deepEqual(await Promise.all(wholeTokens.map((t) => implementationOf(t.address))), before);
    const upgrader = await soloToken.read.UPGRADER_ROLE();
    assert.equal(await soloToken.read.hasRole([upgrader, whole.timelock.address]), false);
    for (const t of wholeTokens) assert.equal(await t.read.hasRole([upgrader, issuer.timelock.address]), false);
  });

  it("the check refuses a registry under governance other than the named one, or a role this core holds on it", async function () {
    const { whole, issuer } = await networkHelpers.loadFixture(twoIssuers);
    const named = issuer.parameters;
    await assertHandedOver(issuer);
    await assert.rejects(assertHandedOver({ ...issuer, parameters: { ...named, credentialAdmin: issuer.timelock.address } }), /credentialAdmin .* does not hold DEFAULT_ADMIN_ROLE/);
    await assert.rejects(assertHandedOver({ ...issuer, parameters: { ...named, credentialGuardian: issuer.wallets.operator.account.address } }), /credentialGuardian .* does not hold GUARDIAN_ROLE/);
    const other = await viem.deployContract("CredentialRegistry", [whole.timelock.address, whole.wallets.guardian.account.address]);
    await assert.rejects(assertHandedOver({ ...issuer, credentials: other }), /the credential rule reads another registry/);
    await assert.rejects(assertHandedOver({ ...issuer, parameters: { ...named, credentialRule: other.address } }), /not the one the deployment names/);

    // A grant to this core's timelock on the registry it reads gives it powers over the other issuer's investors.
    const recovery = await whole.credentials!.read.RECOVERY_ROLE();
    await networkHelpers.impersonateAccount(whole.timelock.address);
    await networkHelpers.setBalance(whole.timelock.address, 10n ** 18n);
    await whole.credentials!.write.grantRole([recovery, issuer.timelock.address], { account: whole.timelock.address });
    await assert.rejects(assertHandedOver(issuer), /holds roles on the external credential registry/);
    await whole.credentials!.write.revokeRole([recovery, issuer.timelock.address], { account: whole.timelock.address });
    await assertHandedOver(issuer);
    await whole.credentials!.write.grantRole([recovery, issuer.recoveryTimelock.address], { account: whole.timelock.address });
    await assert.rejects(assertHandedOver(issuer), /holds roles on the external credential registry/);
    await assert.rejects(assertHandedOver({ ...issuer, credentials: undefined }), /the stack has none/);
  });

  it("the check refuses a policy that trusts no attester, a missing one or a killed one", async function () {
    const { whole } = await networkHelpers.loadFixture(twoIssuers);
    const withPolicy = (attesters: bigint): Profile => ({ ...solo, products: [{ ...solo.products[0], policy: { ...DEFAULT_POLICY, attesters } }] });
    await assert.rejects(deployProfile(connection, withPolicy(0n), namedBy(whole)), /trusts no attester/);
    await assert.rejects(deployProfile(connection, withPolicy(3n), namedBy(whole)), /trusts attester 1, which does not exist/);

    const issuer = await deployProfile(connection, solo, namedBy(whole));
    await whole.credentials!.write.killAttester([0], { account: whole.wallets.guardian.account });
    await assert.rejects(assertHandedOver(issuer), /trusts attester 0, which is killed/);
  });

  it("the check refuses a rule over a registry that is not the release's", async function () {
    const { whole } = await networkHelpers.loadFixture(twoIssuers);
    const counterfeit = await viem.deployContract("CredentialRule", [whole.asset.address]);
    await assert.rejects(deployProfile(connection, solo, { ...namedBy(whole), credentialRule: counterfeit.address }), /is not the release's CredentialRegistry/);
  });
});
