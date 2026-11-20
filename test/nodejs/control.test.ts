// SPDX-License-Identifier: UNLICENSED
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";

import { network } from "hardhat";
import type { NetworkConnection } from "hardhat/types/network";
import { encodeAbiParameters, getAddress, isAddressEqual, keccak256, maxUint256, toFunctionSelector, toHex, type Address, type Hex } from "viem";

import { classesOf, DEMO_SIGNERS, PROFILES, type Profile } from "../../ignition/profiles.js";
import { handoverFailures } from "../../scripts/lib/check.js";
import { checkCommand, keeperCommand, reconcileCommand, type Env } from "../../scripts/lib/commands.js";
import { runKeeper, type PayoutList } from "../../scripts/lib/keeper.js";
import { reconcile } from "../../scripts/lib/reconcile.js";
import { loadStack, StackFileError, type StackFile } from "../../scripts/lib/stack.js";
import { deployProfile, deployStack, verify, type ProfileStack } from "./fixtures.js";

const usd = (amount: bigint) => amount * 10n ** 6n;
const YEAR = 365n * 86_400n;
const SELECTOR = {
  rekey: toFunctionSelector("rekey(address)"),
  closePeriod: toFunctionSelector("closePeriod()"),
  execute: toFunctionSelector("execute()"),
  collectFees: toFunctionSelector("collectFees()"),
  claimBatch: toFunctionSelector("claimBatch(uint256,address[],uint256[],bytes32[][])"),
  claimFor: toFunctionSelector("claimFor(address,address[])"),
};

/** The stack file an operator would keep for a stack a test deployed. */
function stackFileOf(s: ProfileStack): StackFile {
  const name = Object.entries(PROFILES).find(([, profile]) => profile.id === s.profile.id)?.[0] ?? s.profile.id;
  return {
    profile: name,
    accounts: Object.fromEntries(Object.entries(s.wallets).map(([key, w]) => [key, w.account.address])),
    parameters: Object.fromEntries(Object.entries(s.parameters).map(([key, value]) => [key, typeof value === "bigint" ? value.toString() : value])),
    core: Object.fromEntries(Object.entries(s.components).map(([key, c]) => [key, c.address])),
    funds: Object.fromEntries(Object.entries(s.funds).map(([key, f]) => [key, { fund: f.fund.address, rule: f.rule.address, cap: f.cap.toString() }])),
    products: Object.fromEntries(s.deployed.map(({ product, contract }) => [product.key, contract.address])),
    legos: s.legos,
  };
}

const directory = mkdtempSync(join(tmpdir(), "control-"));
let files = 0;
/** Writes a value as a JSON file and returns its path. */
function saved(value: unknown) {
  const path = join(directory, `${files++}.json`);
  writeFileSync(path, typeof value === "string" ? value : JSON.stringify(value));
  return path;
}

type Connection = NetworkConnection;

/** Runs a command and returns its exit code and what it printed. */
async function ran(command: typeof checkCommand, env: Env, connection: Connection) {
  const lines: string[] = [];
  const code = await command(env, connection, (line) => lines.push(line));
  return { code, lines, text: lines.join("\n") };
}

/** Every transaction an account sent after block `since`: its target and its selector. */
async function sentBy(s: Pick<ProfileStack, "publicClient">, account: Address, since: bigint) {
  const sent: { to: Address; selector: Hex }[] = [];
  const latest = await s.publicClient.getBlockNumber();
  for (let number = since + 1n; number <= latest; number++) {
    const block = await s.publicClient.getBlock({ blockNumber: number, includeTransactions: true });
    for (const tx of block.transactions) {
      if (isAddressEqual(tx.from, account)) sent.push({ to: tx.to!, selector: tx.input.slice(0, 10) as Hex });
    }
  }
  return sent;
}

describe("the post-deploy check, as a command", async function () {
  const connection = await network.create();
  const { networkHelpers } = connection;

  async function deployed() {
    const s = await deployStack(connection);
    return { s, file: stackFileOf(s) };
  }

  it("passes on a deployed stack read from its stack file, in prose and as JSON", async function () {
    const { file } = await networkHelpers.loadFixture(deployed);
    assert.deepEqual(await handoverFailures(await loadStack(connection, file)), []);

    const prose = await ran(checkCommand, { STACK: saved(file) }, connection);
    assert.equal(prose.code, 0, prose.text);
    const json = await ran(checkCommand, { STACK: saved(file), JSON: "1" }, connection);
    assert.equal(json.code, 0);
    assert.deepEqual(JSON.parse(json.text), { ok: true, failures: [], products: Object.keys(file.products), unplaced: [] });
  });

  it("names every part that fails, not only the first, and exits 1", async function () {
    const { s, file } = await networkHelpers.loadFixture(deployed);
    const eve = s.holders.eve.account.address;
    // Two faults in two parts: an operations account that does not own the deployer, a guardian that guards nothing.
    const wrong = { ...file, accounts: { ...file.accounts, operations: eve, guardian: eve } };
    const failures = await handoverFailures(await loadStack(connection, wrong));
    assert.ok(failures.some((line) => /^ProxyDeployer: .*not owned by the operations account/.test(line)), failures.join("\n"));
    assert.ok(failures.some((line) => /^the executors: .*executor guardian/.test(line)), failures.join("\n"));
    assert.ok(failures.some((line) => /^the timelocks: /.test(line)), failures.join("\n"));

    const prose = await ran(checkCommand, { STACK: saved(wrong) }, connection);
    assert.equal(prose.code, 1);
    for (const failure of failures) assert.ok(prose.text.includes(failure.split("\n")[0]), `the command left out: ${failure}`);
    const json = await ran(checkCommand, { STACK: saved(wrong), JSON: "1" }, connection);
    assert.equal(json.code, 1);
    assert.deepEqual(JSON.parse(json.text), { ok: false, failures, products: Object.keys(file.products), unplaced: [] });
  });

  it("exits 2 on input it cannot use, and says why", async function () {
    const { s, file } = await networkHelpers.loadFixture(deployed);
    const eve = s.holders.eve.account.address;
    const { timelock: _timelock, ...coreWithoutTimelock } = file.core;
    const { governance: _governance, ...accountsWithoutGovernance } = file.accounts;
    const without = (key: string) => Object.fromEntries(Object.entries(file.core).filter(([name]) => name !== key));
    const [fundKey] = Object.keys(file.funds!);
    const [firstClass] = classesOf(s.profile, fundKey);
    const { [firstClass]: _class, ...productsWithoutAClass } = file.products;
    const unusable: [Env, RegExp][] = [
      // A file that leaves out what a placed product needs would have the check skip it, or fail on a missing value.
      [{ STACK: saved({ ...file, core: without("credentialRule") }) }, /core\.credentialRule is missing/],
      [{ STACK: saved({ ...file, core: without("credentialRegistry") }) }, /core\.credentialRegistry is missing/],
      [{ STACK: saved({ ...file, core: without("executor") }) }, /core\.executor is missing/],
      [{ STACK: saved({ ...file, funds: {} }) }, new RegExp(`funds\\.${fundKey} is missing`)],
      [{ STACK: saved({ ...file, products: productsWithoutAClass }) }, new RegExp(`products\\.${firstClass} is missing: it is a class of`)],
      [{}, /STACK/],
      [{ STACK: join(directory, "missing.json") }, /cannot read/],
      [{ STACK: saved("{ not json") }, /not JSON/],
      [{ STACK: saved({ ...file, profile: "no-such-profile" }) }, /no profile named no-such-profile/],
      [{ STACK: saved({ ...file, core: coreWithoutTimelock }) }, /core\.timelock/],
      [{ STACK: saved({ ...file, accounts: accountsWithoutGovernance }) }, /accounts\.governance/],
      [{ STACK: saved({ ...file, core: { ...file.core, registry: "0x1234" } }) }, /core\.registry is not an address/],
      [{ STACK: saved({ ...file, products: { ...file.products, stranger: eve } }) }, /no product named stranger/],
      [{ STACK: saved({ ...file, products: { ...file.products, intent: eve } }) }, /no contract at .* \(products\.intent\)/],
    ];
    for (const [env, why] of unusable) {
      const { code, text } = await ran(checkCommand, env, connection);
      assert.equal(code, 2, `${why}: ${text}`);
      assert.match(text, why);
    }
  });
});

describe("the post-deploy check, on a stack with products still to place", async function () {
  const connection = await network.create();

  it("passes on the core alone, and says which products it did not check", async function () {
    const s = await deployStack(connection);
    const file: StackFile = { ...stackFileOf(s), products: {}, funds: {}, legos: {} };
    const keys = s.profile.products.map((product) => product.key);
    const json = await ran(checkCommand, { STACK: saved(file), JSON: "1" }, connection);
    assert.deepEqual([json.code, JSON.parse(json.text)], [0, { ok: true, failures: [], products: [], unplaced: keys }]);
    const prose = await ran(checkCommand, { STACK: saved(file) }, connection);
    assert.equal(prose.code, 0);
    assert.match(prose.text, new RegExp(`not placed, so not checked: ${keys.join(", ")}`));
    assert.doesNotMatch(prose.text, /the stack is as its profile says/);
  });
});

describe("the rekey keeper", async function () {
  const connection = await network.create();
  const { networkHelpers } = connection;

  async function linked() {
    const s = await deployStack(connection);
    const { alice, bob, carol } = s.holders;
    for (const holder of [alice, carol]) await s.token.write.mint([holder.account.address, 10n ** 18n], { account: s.wallets.minter.account });
    // The attester links carol, who holds a class, and bob, who holds none, to one investor after the fact.
    await verify(s, carol, { entity: 7 });
    await verify(s, bob, { entity: 7 });
    return { s, file: stackFileOf(s) };
  }

  it("rekeys the one account whose key moved, sends nothing else, and nothing on a second run", async function () {
    const { s, file } = await networkHelpers.loadFixture(linked);
    const keeper = s.holders.eve.account;
    const carol = getAddress(s.holders.carol.account.address);
    const since = await s.publicClient.getBlockNumber();
    assert.equal(await s.fund.read.countedKeyOf([carol]), 0n);

    // Logs from after the last credential: nothing to look at. Then from the start, in small ranges.
    assert.deepEqual((await runKeeper(connection, "rekey", file, { account: keeper, fromBlock: since + 1n })).sent, []);
    const run = await runKeeper(connection, "rekey", file, { account: keeper, logChunk: 7n });
    assert.deepEqual(run.sent.map((call) => [call.address.toLowerCase(), call.functionName, call.args]), [[s.fund.address.toLowerCase(), "rekey", [carol]]]);
    assert.equal(await s.fund.read.countedKeyOf([carol]), 7n);
    const sent = await sentBy(s, keeper.address, since);
    assert.equal(sent.length, 1);
    assert.ok(isAddressEqual(sent[0].to, s.fund.address) && sent[0].selector === SELECTOR.rekey);

    assert.deepEqual((await runKeeper(connection, "rekey", file, { account: keeper })).sent, []);
    assert.equal((await sentBy(s, keeper.address, since)).length, 1);
  });

  it("runs as a command with the connection's own account, and refuses a keeper it does not know", async function () {
    const { s, file } = await networkHelpers.loadFixture(linked);
    const first = await ran(keeperCommand, { STACK: saved(file), KEEPER: "rekey", JSON: "1" }, connection);
    assert.equal(first.code, 0, first.text);
    assert.equal(JSON.parse(first.text).sent.length, 1);
    assert.equal(await s.fund.read.countedKeyOf([s.holders.carol.account.address]), 7n);
    const second = await ran(keeperCommand, { STACK: saved(file), KEEPER: "rekey" }, connection);
    assert.equal(second.code, 0);
    assert.match(second.text, /nothing to send/);

    const unknown = await ran(keeperCommand, { STACK: saved(file), KEEPER: "mint" }, connection);
    assert.equal(unknown.code, 2);
    assert.match(unknown.text, /KEEPER/);
    assert.equal((await ran(keeperCommand, { STACK: saved(file), KEEPER: "payout" }, connection)).code, 2, "a payout with no list");
    assert.equal((await ran(keeperCommand, { STACK: saved(file), KEEPER: "rekey", FROM_BLOCK: "soon" }, connection)).code, 2);
  });
});

describe("the dealing keeper and the claims keeper", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  async function requested() {
    const s = await deployProfile(connection, PROFILES.vault7540);
    await s.addParts({ products: [], signedExit: true });
    const vault = await viem.getContractAt("Gated7540Vault", s.products.asyncFund.address);
    const desk = await viem.getContractAt("NavDesk", s.legos.asyncFund.navDesk);
    const { alice, bob } = s.holders;
    for (const holder of [alice, bob]) {
      await verify(s, holder);
      await s.asset.write.mint([holder.account.address, usd(100n)]);
      await s.asset.write.approve([vault.address, maxUint256], { account: holder.account });
      await vault.write.requestDeposit([usd(100n), holder.account.address, holder.account.address], { account: holder.account });
    }
    return { s, vault, desk, file: stackFileOf(s) };
  }

  it("closes a period once it is over, executes a price once it is accepted and cooled, and each only once", async function () {
    const { s, desk, file } = await networkHelpers.loadFixture(requested);
    const keeper = s.holders.eve.account;
    const since = await s.publicClient.getBlockNumber();
    /** What a run sent. A run never tries a call that is not due, so it leaves nothing out either. */
    const names = async () => {
      const run = await runKeeper(connection, "dealing", file, { account: keeper });
      assert.deepEqual(run.skipped, []);
      return run.sent.map((call) => call.functionName);
    };

    assert.deepEqual(await names(), [], "the period is not over");
    await networkHelpers.time.increase(await desk.read.periodLength());
    assert.deepEqual(await names(), ["closePeriod"]);
    assert.deepEqual(await names(), [], "a second close");

    const asOf = BigInt(await networkHelpers.time.latest());
    await desk.write.propose([0n, keccak256(toHex("report")), asOf, 0n], { account: s.wallets.reporter.account });
    assert.deepEqual(await names(), [], "a proposal nobody accepted");
    await desk.write.accept([await desk.read.hashOf([await desk.read.proposal()])], { account: s.wallets.checker.account });
    assert.deepEqual(await names(), [], "inside the cooldown");
    await networkHelpers.time.increase(await desk.read.cooldown());
    assert.deepEqual(await names(), ["execute"]);
    // The cooldown is as long as a period here, so by now the next period is over as well: the next run closes it.
    assert.deepEqual(await names(), ["closePeriod"], "a second execution");
    assert.deepEqual(await names(), []);

    const sent = await sentBy(s, keeper.address, since);
    assert.deepEqual(sent.map((tx) => tx.selector), [SELECTOR.closePeriod, SELECTOR.execute, SELECTOR.closePeriod]);
    for (const tx of sent) assert.ok(isAddressEqual(tx.to, desk.address));
  });

  it("delivers the claim of a controller that allowed it, to that controller, and leaves the other's alone", async function () {
    const { s, vault, desk, file } = await networkHelpers.loadFixture(requested);
    const keeper = s.holders.eve.account;
    const exits = s.signedExit!;
    const [a, b] = [getAddress(s.holders.alice.account.address), getAddress(s.holders.bob.account.address)];
    const claims = async () => runKeeper(connection, "claims", file, { account: keeper, logChunk: 11n });

    assert.deepEqual((await claims()).sent, [], "nothing is settled");
    await networkHelpers.time.increase(await desk.read.periodLength());
    await desk.write.closePeriod();
    const asOf = BigInt(await networkHelpers.time.latest());
    await desk.write.propose([0n, keccak256(toHex("report")), asOf, 0n], { account: s.wallets.reporter.account });
    await desk.write.accept([await desk.read.hashOf([await desk.read.proposal()])], { account: s.wallets.checker.account });
    await networkHelpers.time.increase(await desk.read.cooldown());
    await desk.write.execute();
    assert.deepEqual(await claims(), { sent: [], skipped: [] }, "no controller allowed it");

    await vault.write.setOperator([exits.address, true], { account: s.holders.alice.account });
    const since = await s.publicClient.getBlockNumber();
    const run = await claims();
    assert.deepEqual(run.sent.map((call) => [call.functionName, call.args]), [["claimFor", [getAddress(vault.address), [a]]]]);
    assert.ok((await vault.read.balanceOf([a])) > 0n);
    assert.equal(await vault.read.balanceOf([b]), 0n);
    assert.equal(await vault.read.balanceOf([keeper.address]), 0n);
    assert.equal(await vault.read.claimableDepositRequest([0n, b]), usd(100n));
    const sent = await sentBy(s, keeper.address, since);
    assert.equal(sent.length, 1);
    assert.ok(isAddressEqual(sent[0].to, exits.address) && sent[0].selector === SELECTOR.claimFor);

    // Bob's claim is still there, and he did not allow it: a run does not try it.
    assert.deepEqual(await claims(), { sent: [], skipped: [] });
    assert.equal((await sentBy(s, keeper.address, since)).length, 1);
  });
});

describe("the reconciler, on a 7540 vault", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  it("names a vault that holds less than the deposits waiting for a price", async function () {
    const s = await deployProfile(connection, PROFILES.vault7540);
    const file = stackFileOf(s);
    const vault = await viem.getContractAt("Gated7540Vault", s.products.asyncFund.address);
    const { alice, eve } = s.holders;
    await verify(s, alice);
    await s.asset.write.mint([alice.account.address, usd(100n)]);
    await s.asset.write.approve([vault.address, maxUint256], { account: alice.account });
    await vault.write.requestDeposit([usd(100n), alice.account.address, alice.account.address], { account: alice.account });
    assert.deepEqual(await reconcile(connection, file), []);

    await networkHelpers.impersonateAccount(vault.address);
    await networkHelpers.setBalance(vault.address, 10n ** 18n);
    await s.asset.write.transfer([eve.account.address, 1n], { account: vault.address });
    const lines = await reconcile(connection, file);
    assert.equal(lines.length, 1, lines.join("\n"));
    assert.match(lines[0], new RegExp(`asyncFund holds ${usd(100n) - 1n} of its asset and ${usd(100n)} of deposits wait`));
  });
});

describe("the fees keeper", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;

  it("collects what is owed when there is something, sends nothing when there is not, and the vault reconciles clean", async function () {
    const s = await deployProfile(connection, PROFILES["vault4626-invest"]);
    const file = stackFileOf(s);
    const vault = await viem.getContractAt("Gated4626Vault", s.products.investFund.address);
    const keeper = s.holders.eve.account;
    const alice = s.holders.alice;
    const recipient = s.wallets.feeRecipient.account.address;
    const fees = async () => (await runKeeper(connection, "fees", file, { account: keeper })).sent;
    await verify(s, alice);
    await s.asset.write.mint([alice.account.address, usd(1000n)]);
    await s.asset.write.approve([vault.address, maxUint256], { account: alice.account });
    await vault.write.deposit([usd(1000n), alice.account.address], { account: alice.account });

    assert.deepEqual(await fees(), [], "nothing is owed yet");
    await networkHelpers.time.increase(YEAR);
    await vault.write.accrue();
    const owed = await vault.read.feesOwed();
    assert.ok(owed > 0n);

    const since = await s.publicClient.getBlockNumber();
    assert.deepEqual((await fees()).map((call) => [call.address.toLowerCase(), call.functionName]), [[vault.address.toLowerCase(), "collectFees"]]);
    assert.ok((await s.asset.read.balanceOf([recipient])) >= owed);
    assert.deepEqual(await fees(), []);
    const sent = await sentBy(s, keeper.address, since);
    assert.equal(sent.length, 1);
    assert.ok(isAddressEqual(sent[0].to, vault.address) && sent[0].selector === SELECTOR.collectFees);

    assert.deepEqual(await reconcile(connection, file), []);

    // The outside vault cannot be read: no fresh price, so the vault has stopped dealing. Then it can again.
    const portfolio = await viem.getContractAt("Portfolio", await vault.read.portfolio());
    const [adapter] = await portfolio.read.adapters();
    const target = await viem.getContractAt("MockERC4626Target", await (await viem.getContractAt("ERC4626Adapter", adapter)).read.TARGET());
    await target.write.setBroken([true]);
    const stale = await reconcile(connection, file);
    assert.equal(stale.length, 1, stale.join("\n"));
    assert.match(stale[0], /investFund: its portfolio gives no fresh price/);
    await target.write.setBroken([false]);
    assert.deepEqual(await reconcile(connection, file), []);

    // More than half of what the portfolio holds is gone: the vault is exit-only.
    await networkHelpers.impersonateAccount(portfolio.address);
    await networkHelpers.setBalance(portfolio.address, 10n ** 18n);
    const idle = await s.asset.read.balanceOf([portfolio.address]);
    await s.asset.write.transfer([keeper.address, (idle * 6n) / 10n], { account: portfolio.address });
    const closed = await reconcile(connection, file);
    assert.equal(closed.length, 1, closed.join("\n"));
    assert.match(closed[0], /investFund is exit-only/);
  });
});

describe("the payout keeper, and a distribution in the reconciler", async function () {
  const connection = await network.create();
  const { viem, networkHelpers } = connection;
  const bond: Profile = {
    id: "bond",
    singleSigners: DEMO_SIGNERS,
    products: [{ key: "bond", template: "GatedToken", name: "Corporate Bond", symbol: "BOND", rules: ["credentialRule"], distributor: true }],
  };
  const leafOf = (holder: Address, amount: bigint) => keccak256(keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [holder, amount])));
  /** OpenZeppelin's commutative pair hash. */
  const pair = (x: Hex, y: Hex) => keccak256(x.toLowerCase() < y.toLowerCase() ? `0x${x.slice(2)}${y.slice(2)}` : `0x${y.slice(2)}${x.slice(2)}`);

  it("pays the rows that can be paid, in chunks, names the one that cannot, and pays it once it can", async function () {
    const s = await deployProfile(connection, bond);
    const file = stackFileOf(s);
    const distributor = await viem.getContractAt("Distributor", s.legos.bond.distributor);
    const cash = await viem.deployContract("MockAsset", [6]);
    const funder = s.wallets.custody;
    const keeper = s.holders.eve.account;
    const { alice, bob, carol } = s.holders;
    const [a, b, c] = [alice, bob, carol].map((w) => w.account.address);
    await verify(s, alice);
    await verify(s, bob);
    await cash.write.mint([funder.account.address, usd(65n)]);
    await cash.write.approve([distributor.address, usd(65n)], { account: funder.account });

    const [la, lb, lc] = [leafOf(a, usd(10n)), leafOf(b, usd(20n)), leafOf(c, usd(30n))];
    const ab = pair(la, lb);
    const now = (await s.publicClient.getBlock()).timestamp;
    await distributor.write.propose([pair(ab, lc), cash.address, usd(60n), now + 86_400n, funder.account.address], { account: s.wallets.distributionMaker.account });
    const list: PayoutList = {
      distributor: distributor.address,
      id: 1,
      rows: [
        { holder: a, amount: usd(10n).toString(), proof: [lb, lc] },
        { holder: b, amount: usd(20n).toString(), proof: [la, lc] },
        { holder: c, amount: usd(30n).toString(), proof: [ab] },
      ],
    };
    const payout = (chunk: number) => runKeeper(connection, "payout", file, { account: keeper, list, chunk }, bond);
    assert.deepEqual((await payout(100)).sent, [], "not approved yet");
    await distributor.write.approve([1n], { account: s.wallets.checker.account });
    // A proof that is not a list of 32-byte words is input that cannot be used, not a row to skip.
    for (const proof of [["0x12"], [7], "0x"]) {
      const bad = { ...list, rows: [{ ...list.rows[0], proof }] } as unknown as PayoutList;
      await assert.rejects(runKeeper(connection, "payout", file, { account: keeper, list: bad }, bond), (error) => error instanceof StackFileError && /proof/.test(error.message));
    }

    const since = await s.publicClient.getBlockNumber();
    const first = await payout(1);
    assert.deepEqual(first.sent.map((call) => [call.functionName, (call.args[1] as Address[]).length]), [["claimBatch", 1], ["claimBatch", 1]]);
    assert.equal(first.skipped.length, 1);
    assert.match(first.skipped[0], new RegExp(c, "i"));
    assert.deepEqual([await cash.read.balanceOf([a]), await cash.read.balanceOf([b]), await cash.read.balanceOf([c])], [usd(10n), usd(20n), 0n]);
    assert.equal(await cash.read.balanceOf([keeper.address]), 0n);
    const sent = await sentBy(s, keeper.address, since);
    assert.equal(sent.length, 2);
    for (const tx of sent) assert.ok(isAddressEqual(tx.to, distributor.address) && tx.selector === SELECTOR.claimBatch);

    const second = await payout(100);
    assert.deepEqual(second.sent, []);
    assert.equal(second.skipped.length, 1);
    assert.equal((await sentBy(s, keeper.address, since)).length, 2);

    await verify(s, carol);
    assert.equal((await payout(100)).sent.length, 1);
    assert.equal(await cash.read.balanceOf([c]), usd(30n));
    assert.deepEqual(await payout(100), { sent: [], skipped: [] });

    // A second distribution nobody claims: clean while it runs, reported once it has expired with money in it, clean
    // again when it is swept.
    await distributor.write.propose([leafOf(a, usd(5n)), cash.address, usd(5n), now + 2n * 86_400n, funder.account.address], { account: s.wallets.distributionMaker.account });
    await distributor.write.approve([2n], { account: s.wallets.checker.account });
    assert.deepEqual(await reconcile(connection, file, {}, bond), []);
    await networkHelpers.time.increaseTo(now + 2n * 86_400n + 1n);
    const lines = await reconcile(connection, file, {}, bond);
    assert.equal(lines.length, 1);
    assert.match(lines[0], /distribution 2 .* past its expiry .* 5000000/);
    await distributor.write.sweep([2n]);
    assert.deepEqual(await reconcile(connection, file, {}, bond), []);
  });
});

describe("the reconciler", async function () {
  const connection = await network.create();
  const { networkHelpers } = connection;

  async function held() {
    const s = await deployStack(connection);
    for (const holder of [s.holders.alice, s.holders.bob]) await s.token.write.mint([holder.account.address, 10n ** 18n], { account: s.wallets.minter.account });
    return { s, file: stackFileOf(s) };
  }

  it("reads a clean stack clean, with and without a ledger, in prose and as JSON", async function () {
    const { s, file } = await networkHelpers.loadFixture(held);
    assert.deepEqual(await reconcile(connection, file), []);
    const ledger = { [s.token.address]: (await s.token.read.totalSupply()).toString() };
    assert.deepEqual(await reconcile(connection, file, ledger), []);
    const prose = await ran(reconcileCommand, { STACK: saved(file), LEDGER: saved(ledger) }, connection);
    assert.equal(prose.code, 0, prose.text);
    const json = await ran(reconcileCommand, { STACK: saved(file), LEDGER: saved(ledger), JSON: "1" }, connection);
    assert.deepEqual([json.code, JSON.parse(json.text)], [0, { ok: true, mismatches: [] }]);
  });

  it("names a supply the ledger does not have, and exits 1", async function () {
    const { s, file } = await networkHelpers.loadFixture(held);
    const supply = await s.token.read.totalSupply();
    const ledger = { [s.token.address]: (supply + 1n).toString() };
    const lines = await reconcile(connection, file, ledger);
    assert.equal(lines.length, 1);
    assert.match(lines[0], new RegExp(`supply .*${supply} .*ledger .*${supply + 1n}`));
    const json = await ran(reconcileCommand, { STACK: saved(file), LEDGER: saved(ledger), JSON: "1" }, connection);
    assert.deepEqual([json.code, JSON.parse(json.text)], [1, { ok: false, mismatches: lines }]);
    assert.equal((await ran(reconcileCommand, { STACK: saved(file), LEDGER: saved({ "0x1234": "1" }) }, connection)).code, 2);
    assert.equal((await ran(reconcileCommand, { STACK: saved(file), LEDGER: saved({ [s.token.address]: "many" }) }, connection)).code, 2);
  });

  it("names a fund counted above its cap", async function () {
    const { s, file } = await networkHelpers.loadFixture(held);
    assert.equal(await s.fund.read.holderCount(), 2n);
    await networkHelpers.impersonateAccount(s.timelock.address);
    await networkHelpers.setBalance(s.timelock.address, 10n ** 18n);
    await s.fund.write.setHolderCap([1n], { account: s.timelock.address });
    const lines = await reconcile(connection, file);
    assert.equal(lines.length, 1);
    assert.match(lines[0], /counts 2 investors, above its cap of 1/);
  });

  it("names a class that no longer lists its fund's rule", async function () {
    const { s, file } = await networkHelpers.loadFixture(held);
    const [fundKey] = Object.keys(file.funds!);
    const fundRule = file.funds![fundKey].rule;
    const rules = await s.hook.read.rules([s.token.address]);
    assert.ok(rules.some((rule) => isAddressEqual(rule, fundRule)));
    await networkHelpers.impersonateAccount(s.timelock.address);
    await networkHelpers.setBalance(s.timelock.address, 10n ** 18n);
    await s.hook.write.setRules([s.token.address, rules.filter((rule) => !isAddressEqual(rule, fundRule))], { account: s.timelock.address });
    const lines = await reconcile(connection, file);
    assert.equal(lines.length, 1, lines.join("\n"));
    assert.match(lines[0], new RegExp(`fund ${fundKey}: the class ${s.token.address} no longer lists the fund's rule`, "i"));
  });
});
