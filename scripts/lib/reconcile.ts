// SPDX-License-Identifier: UNLICENSED
// The reconciler: reads a deployed stack and names what does not add up. It sends nothing.
import type { NetworkConnection } from "hardhat/types/network";
import { erc20Abi, isAddress, isAddressEqual, zeroAddress, zeroHash } from "viem";

import type { Profile } from "../../ignition/profiles.js";
import { profileOf, StackFileError, wholeNumber, type StackFile } from "./stack.js";

/** The ledger's figure for each cash token's supply, by the token's address. */
export type Ledger = Record<string, string | number>;

/**
 * What does not add up on a deployed stack, one line each; an empty list when everything does:
 *
 * - a token whose supply is not the figure the ledger has for it;
 * - a fund counted above its cap, or with a class that no longer lists its rule;
 * - a 7540 vault that holds less of its asset than the deposits still waiting for a price. What it owes on settled
 *   redemptions is not readable from outside and is not counted here; `settlePeriod` checks both on every settlement;
 * - an instant vault with a portfolio that is exit-only, or whose portfolio gives no fresh price, so it has stopped dealing;
 * - a token of which the lien vault holds less than its liens book, which a forced transfer straight out of the vault
 *   causes: enforcement on pledged tokens goes through the vault's `recover`;
 * - a fund with accounts that hold its classes only through the lien vault. The fund exempts the vault, so those owners
 *   are not in its count, and the line gives the number with them;
 * - a distribution past its expiry with money still in it, which `sweep` returns to its funder. A distributor numbers
 *   its distributions from 1 and none has an empty root, so they are read one by one until the first that has, and no
 *   log is read: a first block set too late cannot hide one.
 */
export async function reconcile(
  connection: NetworkConnection,
  file: StackFile,
  ledger: Ledger = {},
  given?: Profile,
): Promise<string[]> {
  const { viem } = connection;
  const publicClient = await viem.getPublicClient();
  const { placed } = profileOf(file, given);
  const latest = await publicClient.getBlock();
  const lines: string[] = [];

  for (const [token, figure] of Object.entries(ledger)) {
    if (!isAddress(token)) throw new StackFileError(`the ledger names ${token}, which is not an address`);
    const expected = wholeNumber(figure, `the ledger's figure for ${token}`);
    const supply = await publicClient.readContract({ address: token, abi: erc20Abi, functionName: "totalSupply" });
    if (supply !== expected) lines.push(`token ${token}: its supply is ${supply} and the ledger has ${expected}`);
  }

  for (const [key, { fund: fundAddress }] of Object.entries(file.funds ?? {})) {
    const fund = await viem.getContractAt("Fund", fundAddress);
    const [count, cap, broken] = [await fund.read.holderCount(), await fund.read.holderCap(), await fund.read.firstBrokenClass()];
    if (count > cap) lines.push(`fund ${key} counts ${count} investors, above its cap of ${cap}`);
    if (!isAddressEqual(broken, zeroAddress)) lines.push(`fund ${key}: the class ${broken} no longer lists the fund's rule`);
  }

  for (const { product, address } of placed) {
    if (product.template === "Gated7540Vault") {
      const vault = await viem.getContractAt("Gated7540Vault", address);
      const [open, settled] = await vault.read.dealingState();
      let waiting = 0n;
      for (let period = settled + 1n; period <= open; period++) waiting += (await vault.read.periodBook([period, true]))[0];
      const held = await publicClient.readContract({ address: await vault.read.asset(), abi: erc20Abi, functionName: "balanceOf", args: [address] });
      if (held < waiting) lines.push(`vault ${product.key} holds ${held} of its asset and ${waiting} of deposits wait for a price`);
    }
    if (product.template === "Gated4626Vault") {
      const vault = await viem.getContractAt("Gated4626Vault", address);
      const portfolio = await vault.read.portfolio();
      if (!isAddressEqual(portfolio, zeroAddress)) {
        if (await vault.read.exitOnly()) lines.push(`vault ${product.key} is exit-only: it takes no deposit`);
        if (!(await (await viem.getContractAt("Portfolio", portfolio)).read.priceFresh())) lines.push(`vault ${product.key}: its portfolio gives no fresh price, so it has stopped dealing`);
      }
    }
    const distributorAddress = file.legos?.[product.key]?.distributor;
    if (distributorAddress !== undefined) {
      const distributor = await viem.getContractAt("Distributor", distributorAddress);
      for (let id = 1n; ; id++) {
        const d = await distributor.read.distributionOf([id]);
        if (d.root === zeroHash) break;
        if (d.approved && latest.timestamp > d.expiry && d.total > d.claimed) {
          lines.push(`distribution ${id} of ${product.key} is past its expiry with ${d.total - d.claimed} unclaimed: sweep returns it to its funder`);
        }
      }
    }
  }
  if (file.core.lienVault !== undefined) {
    const liens = await viem.getContractAt("LienVault", file.core.lienVault);
    const keyOf = (token: string) => placed.find(({ address }) => isAddressEqual(address, token as `0x${string}`))?.product.key ?? token;
    // Every open lien, read by id: the vault numbers them from 1 and never reuses one.
    const pledgors = new Map<string, Set<string>>();
    const count = await liens.read.lienCount();
    for (let id = 1n; id <= count; id++) {
      const lien = await liens.read.lienOf([id]);
      if (lien.amount === 0n) continue;
      const token = lien.token.toLowerCase();
      if (!pledgors.has(token)) pledgors.set(token, new Set());
      pledgors.get(token)!.add(lien.pledgor.toLowerCase());
    }
    for (const token of pledgors.keys()) {
      const address = token as `0x${string}`;
      const [held, booked] = [await publicClient.readContract({ address, abi: erc20Abi, functionName: "balanceOf", args: [liens.address] }), await liens.read.totalPledged([address])];
      if (held < booked) lines.push(`the lien vault holds ${held} of ${keyOf(token)} and its liens book ${booked}`);
    }
    for (const [key, { fund: fundAddress }] of Object.entries(file.funds ?? {})) {
      const fund = await viem.getContractAt("Fund", fundAddress);
      const hidden = new Set<string>();
      for (const [token, accounts] of pledgors) {
        if ((await fund.read.classIndexOf([token as `0x${string}`])) === 0n) continue;
        for (const account of accounts) {
          const who = account as `0x${string}`;
          if ((await fund.read.heldClasses([who])) === 0n && !(await fund.read.isExempt([who]))) hidden.add(account);
        }
      }
      if (hidden.size === 0) continue;
      const counted = await fund.read.holderCount();
      lines.push(`fund ${key}: ${hidden.size} account${hidden.size === 1 ? " holds" : "s hold"} its classes only through the lien vault, so ${counted + BigInt(hidden.size)} owners are counted as ${counted}`);
    }
  }
  return lines;
}
