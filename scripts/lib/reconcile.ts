// SPDX-License-Identifier: UNLICENSED
// The reconciler: reads a deployed stack and names what does not add up. It sends nothing.
import type { NetworkConnection } from "hardhat/types/network";
import { erc20Abi, isAddress, isAddressEqual, zeroAddress } from "viem";

import type { Profile } from "../../ignition/profiles.js";
import { inRanges, LOG_CHUNK } from "./keeper.js";
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
 * - a distribution past its expiry with money still in it, which `sweep` returns to its funder.
 */
export async function reconcile(
  connection: NetworkConnection,
  file: StackFile,
  ledger: Ledger = {},
  options: { fromBlock?: bigint; logChunk?: bigint } = {},
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
      const proposed = await inRanges(options.fromBlock ?? 0n, latest.number, options.logChunk ?? LOG_CHUNK, (fromBlock, toBlock) =>
        publicClient.getContractEvents({ address: distributor.address, abi: distributor.abi, eventName: "DistributionProposed", fromBlock, toBlock }),
      );
      for (const id of new Set(proposed.map((log) => log.args._id!))) {
        const d = await distributor.read.distributionOf([id]);
        if (d.approved && latest.timestamp > d.expiry && d.total > d.claimed) {
          lines.push(`distribution ${id} of ${product.key} is past its expiry with ${d.total - d.claimed} unclaimed: sweep returns it to its funder`);
        }
      }
    }
  }
  return lines;
}
