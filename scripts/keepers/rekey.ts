// SPDX-License-Identifier: UNLICENSED
import { isAddressEqual, zeroAddress, type Abi, type Address } from "viem";

import { inRanges, LOG_CHUNK, type Context, type Plan } from "../lib/keeper.js";

/**
 * `Fund.rekey(account)`, for each account that holds a class of a fund and is counted under a key that is no longer the
 * one its credential gives. The candidates are the subjects of `CredentialSet` since `fromBlock`. Open to anyone on-chain.
 */
export async function rekey({ connection, file, options }: Context): Promise<Plan> {
  const { viem } = connection;
  const publicClient = await viem.getPublicClient();
  const latest = await publicClient.getBlockNumber();
  const plan: Plan = { calls: [], skipped: [] };
  const subjectsOf = new Map<string, Address[]>();

  for (const [key, { fund: fundAddress }] of Object.entries(file.funds ?? {})) {
    const fund = await viem.getContractAt("Fund", fundAddress);
    const credentials = await fund.read.CREDENTIALS();
    // A fund with no credential registry counts every address on its own: there is no key to follow.
    if (isAddressEqual(credentials, zeroAddress)) continue;
    const registry = await viem.getContractAt("CredentialRegistry", credentials);
    let subjects = subjectsOf.get(credentials.toLowerCase());
    if (subjects === undefined) {
      const logs = await inRanges(options.fromBlock ?? 0n, latest, options.logChunk ?? LOG_CHUNK, (fromBlock, toBlock) =>
        publicClient.getContractEvents({ address: registry.address, abi: registry.abi, eventName: "CredentialSet", fromBlock, toBlock }),
      );
      subjects = [...new Map(logs.map((log) => [log.args._subject!.toLowerCase(), log.args._subject!])).values()];
      subjectsOf.set(credentials.toLowerCase(), subjects);
    }
    for (const subject of subjects) {
      if ((await fund.read.heldClasses([subject])) === 0n || (await fund.read.isExempt([subject]))) continue;
      if ((await fund.read.countedKeyOf([subject])) === (await registry.read.entityKeyOf([subject]))) continue;
      plan.calls.push({ address: fund.address, abi: fund.abi as Abi, functionName: "rekey", args: [subject], note: `rekey ${subject} in fund ${key}` });
    }
  }
  return plan;
}
