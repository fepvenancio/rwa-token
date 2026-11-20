// SPDX-License-Identifier: UNLICENSED
import { erc20Abi, isAddressEqual, zeroAddress, type Abi } from "viem";

import type { Context, Plan } from "../lib/keeper.js";

/**
 * `Gated4626Vault.collectFees()`, for each instant vault with a fee model that has fees counted as owed and idle money in
 * its portfolio to pay some of them. Open to anyone on-chain; the money goes to the recipient the attested fee model
 * names. It does not count the value itself: fees are counted by the next deposit, withdrawal or `accrue()`,
 * which the `accrue` keeper sends.
 */
export async function fees({ connection, placed }: Context): Promise<Plan> {
  const { viem } = connection;
  const publicClient = await viem.getPublicClient();
  const plan: Plan = { calls: [], skipped: [] };
  for (const { product, address } of placed) {
    if (product.template !== "Gated4626Vault") continue;
    const vault = await viem.getContractAt("Gated4626Vault", address);
    const portfolio = await vault.read.portfolio();
    if (isAddressEqual(await vault.read.feeModel(), zeroAddress) || isAddressEqual(portfolio, zeroAddress)) continue;
    if ((await vault.read.feesOwed()) === 0n) continue;
    const idle = await publicClient.readContract({ address: await vault.read.asset(), abi: erc20Abi, functionName: "balanceOf", args: [portfolio] });
    if (idle === 0n) {
      plan.skipped.push(`collect the fees of ${product.key}: the portfolio holds no idle money`);
      continue;
    }
    plan.calls.push({ address: vault.address, abi: vault.abi as Abi, functionName: "collectFees", args: [], note: `collect the fees of ${product.key}` });
  }
  return plan;
}
