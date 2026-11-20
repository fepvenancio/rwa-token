// SPDX-License-Identifier: UNLICENSED
// What the keepers share. A keeper reads the chain and names the calls it wants; `runKeeper` tries each call without
// sending it, sends the ones that would succeed, and reports the rest. Every function a keeper calls is open to anyone,
// so the account that sends holds no role on anything.
import type { NetworkConnection } from "hardhat/types/network";
import { BaseError, type Abi, type Account, type Address } from "viem";

import type { Product, Profile } from "../../ignition/profiles.js";
import { claims } from "../keepers/claims.js";
import { dealing } from "../keepers/dealing.js";
import { fees } from "../keepers/fees.js";
import { payout } from "../keepers/payout.js";
import { rekey } from "../keepers/rekey.js";
import { profileOf, StackFileError, type StackFile } from "./stack.js";

/** One call a keeper wants to send. */
export type Call = { address: Address; abi: Abi; functionName: string; args: readonly unknown[]; note: string };
/** What a keeper found: the calls to send, and the candidates it left out with the reason. */
export type Plan = { calls: Call[]; skipped: string[] };
/** What a run did: the calls it sent, and what it left out with the reason. */
export type Run = { sent: Call[]; skipped: string[] };
/** One distribution's list, as its root was built. */
export type PayoutList = { distributor: Address; id: string | number; rows: { holder: Address; amount: string | number; proof: `0x${string}`[] }[] };
export type KeeperOptions = {
  /** Who sends. The connection's first account when left out. */
  account?: Account;
  /**
   * The first block `rekey` and `claims` read logs from; the queries are made in ranges of `logChunk`, so a wide span is
   * not a reason to raise it. For `claims` it is fixed: the block the oldest 7540 vault was deployed in, because a
   * request filed before it is never seen again, however much later it settles. For `rekey` it may move forward to the
   * block a run started at, and only when that run left nothing out: a rekey left out is found again only from its
   * credential's block.
   */
  fromBlock?: bigint;
  /** How many blocks one log query covers. */
  logChunk?: bigint;
  /** How many rows or controllers one transaction carries. */
  chunk?: number;
  /** The list a payout pays from. */
  list?: PayoutList;
};
/** What a keeper is given. */
export type Context = {
  connection: NetworkConnection;
  file: StackFile;
  profile: Profile;
  placed: { product: Product; address: Address }[];
  account: Account;
  options: KeeperOptions;
  /** The latest block's timestamp. */
  now: bigint;
};

export const KEEPERS = { rekey, dealing, fees, payout, claims } as const;
export type KeeperName = keyof typeof KEEPERS;

/** The default span of one log query: small enough for a node that limits `eth_getLogs`. */
export const LOG_CHUNK = 5_000n;

/** Runs `query` over `[from, latest]` in ranges of at most `chunk` blocks, and returns everything it found, in order. */
export async function inRanges<T>(from: bigint, latest: bigint, chunk: bigint, query: (fromBlock: bigint, toBlock: bigint) => Promise<T[]>): Promise<T[]> {
  if (chunk <= 0n) throw new StackFileError("a log query must cover at least one block");
  const found: T[] = [];
  for (let start = from; start <= latest; start += chunk) {
    const end = start + chunk - 1n < latest ? start + chunk - 1n : latest;
    found.push(...(await query(start, end)));
  }
  return found;
}

/** Why a call would fail, in one line. */
export const reasonOf = (error: unknown) => (error instanceof BaseError ? error.shortMessage : error instanceof Error ? error.message : String(error)).split("\n")[0];

/** Splits a list into pieces of at most `size`. */
export function chunksOf<T>(list: readonly T[], size: number): T[][] {
  if (!Number.isSafeInteger(size) || size < 1) throw new StackFileError("a chunk must hold at least one row");
  const pieces: T[][] = [];
  for (let at = 0; at < list.length; at += size) pieces.push(list.slice(at, at + size));
  return pieces;
}

/**
 * Runs one keeper once: asks it what to send, tries each call without sending it, and sends those that would succeed, one
 * after the other, waiting for each. A call that would revert is left out and named. A second run right after the first
 * finds nothing to send.
 */
export async function runKeeper(connection: NetworkConnection, name: KeeperName, file: StackFile, options: KeeperOptions = {}, given?: Profile): Promise<Run> {
  const { viem } = connection;
  const publicClient = await viem.getPublicClient();
  const account = options.account ?? (await viem.getWalletClients())[0]?.account;
  if (account === undefined) throw new StackFileError("the network has no account to send from");
  const wallet = await viem.getWalletClient(account.address);
  const { profile, placed } = profileOf(file, given);
  const now = (await publicClient.getBlock()).timestamp;

  const plan = await KEEPERS[name]({ connection, file, profile, placed, account, options, now });
  const run: Run = { sent: [], skipped: [...plan.skipped] };
  for (const call of plan.calls) {
    const request = { address: call.address, abi: call.abi, functionName: call.functionName, args: call.args, account };
    try {
      await publicClient.simulateContract(request);
    } catch (error) {
      run.skipped.push(`${call.note}: ${reasonOf(error)}`);
      continue;
    }
    const hash = await wallet.writeContract({ ...request, chain: wallet.chain });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`${call.note}: the transaction ${hash} reverted`);
    run.sent.push(call);
  }
  return run;
}
