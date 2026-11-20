// SPDX-License-Identifier: UNLICENSED
import type { Abi, Address } from "viem";

import { chunksOf, inRanges, LOG_CHUNK, reasonOf, type Context, type Plan } from "../lib/keeper.js";

/** How many controllers one `claimFor` carries unless told otherwise: ten cost 0.66 million gas in the benchmark. */
const CONTROLLERS = 50;

/**
 * `SignedExit.claimFor(vault, controllers)`, in chunks, for each 7540 vault: the controllers that filed a request since
 * `fromBlock`, have something settled to claim, and made the signed exit their operator. Each is first tried alone
 * without sending it, and one whose claim the vault would refuse is left out and named. Open to anyone on-chain; a claim
 * goes to its controller and nowhere else.
 */
export async function claims({ connection, file, placed, options, account }: Context): Promise<Plan> {
  const { viem } = connection;
  const publicClient = await viem.getPublicClient();
  const plan: Plan = { calls: [], skipped: [] };
  if (file.core.signedExit === undefined) return plan;
  const exits = await viem.getContractAt("SignedExit", file.core.signedExit);
  const latest = await publicClient.getBlockNumber();

  for (const { product, address } of placed) {
    if (product.template !== "Gated7540Vault") continue;
    const vault = await viem.getContractAt("Gated7540Vault", address);
    const requests = await inRanges(options.fromBlock ?? 0n, latest, options.logChunk ?? LOG_CHUNK, async (fromBlock, toBlock) => [
      ...(await publicClient.getContractEvents({ address: vault.address, abi: vault.abi, eventName: "DepositRequest", fromBlock, toBlock })),
      ...(await publicClient.getContractEvents({ address: vault.address, abi: vault.abi, eventName: "RedeemRequest", fromBlock, toBlock })),
    ]);
    const controllers = [...new Map(requests.map((log) => [log.args._controller!.toLowerCase(), log.args._controller!])).values()];

    const ready: Address[] = [];
    for (const controller of controllers) {
      const claimable = (await vault.read.claimableDepositRequest([0n, controller])) + (await vault.read.claimableRedeemRequest([0n, controller]));
      if (claimable === 0n || !(await vault.read.isOperator([controller, exits.address]))) continue;
      try {
        const { result } = await publicClient.simulateContract({ address: exits.address, abi: exits.abi, functionName: "claimFor", args: [vault.address, [controller]], account });
        if (result === 0n) {
          plan.skipped.push(`claim for ${controller} in ${product.key}: the vault refuses it`);
          continue;
        }
      } catch (error) {
        plan.skipped.push(`claim for ${controller} in ${product.key}: ${reasonOf(error)}`);
        continue;
      }
      ready.push(controller);
    }
    for (const group of chunksOf(ready, options.chunk ?? CONTROLLERS)) {
      plan.calls.push({ address: exits.address, abi: exits.abi as Abi, functionName: "claimFor", args: [vault.address, group], note: `claim for ${group.length} controllers in ${product.key}` });
    }
  }
  return plan;
}
