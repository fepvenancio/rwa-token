// SPDX-License-Identifier: UNLICENSED
import { isAddress, type Abi, type Address, type Hex } from "viem";

import { chunksOf, reasonOf, type Context, type Plan } from "../lib/keeper.js";
import { StackFileError, wholeNumber } from "../lib/stack.js";

/** How many rows one `claimBatch` carries unless told otherwise: about 4.9 million gas in the benchmark. */
const ROWS = 100;

/**
 * `Distributor.claimBatch`, in chunks, for the rows of a distribution's list that are not paid yet and can be paid now.
 * Each unpaid row is first tried alone without sending it: a row the share token or the cash token refuses, or whose
 * proof does not match, is left out and named, so it cannot hold back the others and a second run does not send it
 * again. Open to anyone on-chain; each payment goes to its holder.
 */
export async function payout({ connection, options, account, now }: Context): Promise<Plan> {
  const { viem } = connection;
  const publicClient = await viem.getPublicClient();
  const { list } = options;
  if (list === undefined) throw new StackFileError("a payout needs the distribution's list");
  if (typeof list !== "object" || list === null || !isAddress(String(list.distributor)) || !Array.isArray(list.rows)) {
    throw new StackFileError("the list needs a distributor, an id and rows");
  }
  const id = wholeNumber(list.id, "the list's id");
  const distributor = await viem.getContractAt("Distributor", list.distributor);
  const plan: Plan = { calls: [], skipped: [] };

  const distribution = await distributor.read.distributionOf([id]);
  if (!distribution.approved) return { calls: [], skipped: [`distribution ${id} is not approved`] };
  if (now > distribution.expiry) return { calls: [], skipped: [`distribution ${id} has expired`] };

  const payable: { holder: Address; amount: bigint; proof: Hex[] }[] = [];
  for (const [index, row] of list.rows.entries()) {
    if (typeof row !== "object" || row === null || !isAddress(String(row.holder)) || !Array.isArray(row.proof)) throw new StackFileError(`row ${index} of the list needs a holder, an amount and a proof`);
    const amount = wholeNumber(row.amount, `the amount of row ${index}`);
    if (await distributor.read.hasClaimed([id, row.holder])) continue;
    try {
      await publicClient.simulateContract({ address: distributor.address, abi: distributor.abi, functionName: "claim", args: [id, row.holder, amount, row.proof], account });
    } catch (error) {
      plan.skipped.push(`pay ${row.holder} from distribution ${id}: ${reasonOf(error)}`);
      continue;
    }
    payable.push({ holder: row.holder, amount, proof: row.proof });
  }
  for (const rows of chunksOf(payable, options.chunk ?? ROWS)) {
    plan.calls.push({
      address: distributor.address,
      abi: distributor.abi as Abi,
      functionName: "claimBatch",
      args: [id, rows.map((row) => row.holder), rows.map((row) => row.amount), rows.map((row) => row.proof)],
      note: `pay ${rows.length} holders from distribution ${id}`,
    });
  }
  return plan;
}
