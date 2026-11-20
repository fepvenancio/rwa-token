// SPDX-License-Identifier: UNLICENSED
// The three commands of the control plane, each a function of the environment and a network connection that returns
// its exit code: 0 when all is well, 1 when the stack is not as it should be, 2 when the input cannot be used. They take
// their settings from the environment, as the Ignition modules do (`PROFILE`, `PRODUCT`, `FUND`), because `hardhat run`
// passes a script no arguments of its own.
import { readFileSync } from "node:fs";

import type { NetworkConnection } from "hardhat/types/network";

import { handoverFailures } from "./check.js";
import { KEEPERS, runKeeper, type KeeperName, type PayoutList } from "./keeper.js";
import { reconcile, type Ledger } from "./reconcile.js";
import { loadStack, parseStackFile, StackFileError, unplacedOf, wholeNumber, type StackFile } from "./stack.js";

/** What a command reads from the environment. */
export type Env = Record<string, string | undefined>;
type Print = (line: string) => void;

const asJson = (value: unknown) => JSON.stringify(value, (_key, item) => (typeof item === "bigint" ? item.toString() : item), 2);
const wantsJson = (env: Env) => env.JSON !== undefined && env.JSON !== "" && env.JSON !== "0";

function readFile(path: string | undefined, name: string): string {
  if (path === undefined || path === "") throw new StackFileError(`${name} is not set: it names the file to read`);
  try {
    return readFileSync(path, "utf8");
  } catch {
    throw new StackFileError(`cannot read ${path} (${name})`);
  }
}

function readJson(path: string | undefined, name: string): unknown {
  const text = readFile(path, name);
  try {
    return JSON.parse(text);
  } catch {
    throw new StackFileError(`${path} (${name}) is not JSON`);
  }
}

const stackOf = (env: Env): StackFile => parseStackFile(readFile(env.STACK, "STACK"));
const optional = (env: Env, name: string) => (env[name] === undefined || env[name] === "" ? undefined : wholeNumber(env[name], name));

/** Runs a command's body and turns unusable input into exit code 2. */
async function guarded(print: Print, body: () => Promise<number>): Promise<number> {
  try {
    return await body();
  } catch (error) {
    if (!(error instanceof StackFileError)) throw error;
    print(`error: ${error.message}`);
    return 2;
  }
}

/**
 * `npm run check`: the post-deploy check against the stack `STACK` names. Prints each part that failed, or with `JSON=1`
 * one object `{ ok, failures, products, unplaced }`. It checks the products the file places and names the profile's
 * products it does not, so a file that places few of them does not read as the whole stack passing.
 */
export function checkCommand(env: Env, connection: NetworkConnection, print: Print): Promise<number> {
  return guarded(print, async () => {
    const file = stackOf(env);
    const failures = await handoverFailures(await loadStack(connection, file));
    const products = Object.keys(file.products);
    const unplaced = unplacedOf(file);
    if (wantsJson(env)) print(asJson({ ok: failures.length === 0, failures, products, unplaced }));
    else {
      for (const failure of failures) print(`check: ${failure}`);
      if (unplaced.length !== 0) print(`check: not placed, so not checked: ${unplaced.join(", ")}`);
      if (failures.length === 0) print(unplaced.length === 0 ? "check: the stack is as its profile says" : `check: what is placed is as its profile says (${products.length} of ${products.length + unplaced.length} products)`);
    }
    return failures.length === 0 ? 0 : 1;
  });
}

/**
 * `npm run reconcile`: what does not add up on the stack `STACK` names, against the supplies in the file `LEDGER` names
 * when it is set. It reads no logs. With `JSON=1`, one object `{ ok, mismatches }`.
 */
export function reconcileCommand(env: Env, connection: NetworkConnection, print: Print): Promise<number> {
  return guarded(print, async () => {
    const file = stackOf(env);
    const ledger = env.LEDGER === undefined || env.LEDGER === "" ? {} : readJson(env.LEDGER, "LEDGER");
    if (typeof ledger !== "object" || ledger === null || Array.isArray(ledger)) throw new StackFileError("the ledger file is not an object");
    const mismatches = await reconcile(connection, file, ledger as Ledger);
    if (wantsJson(env)) print(asJson({ ok: mismatches.length === 0, mismatches }));
    else if (mismatches.length === 0) print("reconcile: nothing to report");
    else for (const mismatch of mismatches) print(`reconcile: ${mismatch}`);
    return mismatches.length === 0 ? 0 : 1;
  });
}

/**
 * `npm run keeper`: one keeper, once, on the stack `STACK` names. `KEEPER` is `rekey`, `dealing`, `fees`, `payout` or
 * `claims`; `FROM_BLOCK` and `LOG_CHUNK` bound the log queries of `rekey` and `claims` (see `KeeperOptions.fromBlock` for
 * what `FROM_BLOCK` may be), `CHUNK` sets how many rows or controllers a transaction carries, and `LIST` names a
 * payout's list. It sends from the network's first account. With `JSON=1`, one object `{ sent, skipped }`. It exits with
 * 0 when it ran, also when it left calls out: whoever watches a keeper reads `skipped`.
 */
export function keeperCommand(env: Env, connection: NetworkConnection, print: Print): Promise<number> {
  return guarded(print, async () => {
    const name = env.KEEPER;
    if (name === undefined || !Object.hasOwn(KEEPERS, name)) throw new StackFileError(`KEEPER must be one of ${Object.keys(KEEPERS).join(", ")}`);
    const chunk = optional(env, "CHUNK");
    const run = await runKeeper(connection, name as KeeperName, stackOf(env), {
      fromBlock: optional(env, "FROM_BLOCK"),
      logChunk: optional(env, "LOG_CHUNK"),
      chunk: chunk === undefined ? undefined : Number(chunk),
      list: name === "payout" ? (readJson(env.LIST, "LIST") as PayoutList) : undefined,
    });
    if (wantsJson(env)) {
      print(asJson({ sent: run.sent.map(({ address, functionName, args, note }) => ({ to: address, function: functionName, args, note })), skipped: run.skipped }));
    } else {
      for (const call of run.sent) print(`${name}: sent ${call.functionName} to ${call.address} (${call.note})`);
      for (const skipped of run.skipped) print(`${name}: left out: ${skipped}`);
      if (run.sent.length === 0) print(`${name}: nothing to send`);
    }
    return 0;
  });
}
