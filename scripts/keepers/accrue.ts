// SPDX-License-Identifier: UNLICENSED
import { isAddressEqual, zeroAddress, type Abi } from "viem";

import type { Product } from "../../ignition/profiles.js";
import type { Context, Plan } from "../lib/keeper.js";

/**
 * `Gated4626Vault.accrue()`, for each instant vault with a portfolio whose price is fresh and whose value now is not the
 * value it last counted. Open to anyone on-chain. A vault that another product of the stack invests in comes first, and
 * each call is tried after the one before it has landed, so a feeder class counts against its master's new value.
 *
 * With a management fee the two figures differ in almost every block, so a second run right after the first may send
 * again: how often this keeper runs is how often the fund is counted.
 */
export async function accrue({ connection, placed }: Context): Promise<Plan> {
  const { viem } = connection;
  const plan: Plan = { calls: [], skipped: [] };
  /** How many vaults of the stack a product invests through: none for a master, one for its class. */
  const depth = (product: Product, seen: readonly string[] = []): number =>
    Math.max(
      0,
      ...(product.portfolio?.targets ?? []).map((target) => {
        const master = placed.find((other) => other.product.key === target.product)?.product;
        return master === undefined || seen.includes(master.key) ? 0 : 1 + depth(master, [...seen, product.key]);
      }),
    );
  const ordered = [...placed].sort((a, b) => depth(a.product) - depth(b.product));
  for (const { product, address } of ordered) {
    if (product.template !== "Gated4626Vault") continue;
    const vault = await viem.getContractAt("Gated4626Vault", address);
    const portfolio = await vault.read.portfolio();
    if (isAddressEqual(portfolio, zeroAddress)) continue;
    if (!(await (await viem.getContractAt("Portfolio", portfolio)).read.priceFresh())) {
      plan.skipped.push(`count ${product.key}: its portfolio gives no fresh price`);
      continue;
    }
    if ((await vault.read.totalAssets()) === (await vault.read.lastCounted())) continue;
    plan.calls.push({ address: vault.address, abi: vault.abi as Abi, functionName: "accrue", args: [], note: `count ${product.key}` });
  }
  return plan;
}
