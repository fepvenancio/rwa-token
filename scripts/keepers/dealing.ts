// SPDX-License-Identifier: UNLICENSED
import type { Abi } from "viem";

import type { Context, Plan } from "../lib/keeper.js";

/**
 * For each product with a desk: `NavDesk.closePeriod()` once the period's length has passed and no earlier period waits
 * for its price, and `NavDesk.execute()` once a proposal is accepted, its cooldown is over, its report is not too old
 * and the period it priced is still the closed one. Both are open to anyone on-chain. It proposes and accepts nothing.
 */
export async function dealing({ connection, file, placed, now }: Context): Promise<Plan> {
  const { viem } = connection;
  const plan: Plan = { calls: [], skipped: [] };
  for (const { product, address } of placed) {
    const deskAddress = file.legos?.[product.key]?.navDesk;
    if (product.nav === undefined || deskAddress === undefined) continue;
    const desk = await viem.getContractAt("NavDesk", deskAddress);
    const vault = await viem.getContractAt("Gated7540Vault", address);
    const [open, settled] = await vault.read.dealingState();
    const closed = settled + 1n < open;

    if (!closed && now >= (await desk.read.lastCutoff()) + (await desk.read.periodLength())) {
      plan.calls.push({ address: desk.address, abi: desk.abi as Abi, functionName: "closePeriod", args: [], note: `close the period of ${product.key}` });
    }
    const p = await desk.read.proposal();
    const accepted = p.period !== 0n && p.acceptedAt !== 0n;
    const cooled = now >= p.proposedAt + (await desk.read.cooldown());
    const fresh = now <= p.asOf + (await desk.read.maxReportAge());
    if (closed && accepted && cooled && fresh && p.period === settled + 1n) {
      plan.calls.push({ address: desk.address, abi: desk.abi as Abi, functionName: "execute", args: [], note: `execute the price of ${product.key}` });
    }
  }
  return plan;
}
