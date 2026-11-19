// SPDX-License-Identifier: UNLICENSED
// The benchmark of `PLAN.md` ("How "better than today" is decided"). Run with `npm run bench`.
//
// Runs `contracts/test/Bench.t.sol`, collects the `BENCH|<flow>|<calls>|<writes>|<gas>` line each flow prints, and
// prints them as a Markdown table in the order below. Not a gate on the numbers: it fails only if the run fails or a
// flow is missing. The numbers differ between the two build lines and under the isolated test profile.
import { spawnSync } from "node:child_process";

const FLOWS = [
  "transfer: between holders, 4 rules, fund class",
  "transfer: to a new holder, 4 rules, fund class",
  "intent: executeTransfer through IntentExecutor",
  "intent: executeTransfer, the nonce next to a used one",
  "dvp: gated cash",
  "dvp: erc-3009 cash",
  "4626: deposit",
  "4626: redeem",
  "7540: requestDeposit",
  "7540: settlePeriod, 1 investor",
  "7540: settlePeriod, 100 investors",
  "7540: claim deposit",
  "7540: claimFor, 10 controllers",
  "signed entry: 4626 with permit",
  "signed exit: 4626 with permit",
  "distribution: claim",
  "distribution: 100 claims, one by one",
  "distribution: claimBatch, 100 holders",
];

const run = spawnSync("npx", ["hardhat", "test", "solidity", "contracts/test/Bench.t.sol"], {
  encoding: "utf8",
  maxBuffer: 64 * 1024 * 1024,
});
const output = `${run.stdout ?? ""}${run.stderr ?? ""}`;
if (run.status !== 0) {
  console.error(output);
  console.error("bench: the test run failed");
  process.exit(1);
}

const rows = new Map<string, string[]>();
for (const line of output.split("\n")) {
  const at = line.indexOf("BENCH|");
  if (at === -1) continue;
  const [, flow, calls, writes, gas] = line.slice(at).trim().split("|");
  rows.set(flow, [calls, writes, Number(gas).toLocaleString("en-US")]);
}

const missing = FLOWS.filter((flow) => !rows.has(flow));
const unknown = [...rows.keys()].filter((flow) => !FLOWS.includes(flow));
if (missing.length > 0 || unknown.length > 0) {
  console.error(output);
  for (const flow of missing) console.error(`bench: no line for "${flow}"`);
  for (const flow of unknown) console.error(`bench: a line for "${flow}", which this script does not list`);
  process.exit(1);
}

console.log("| Flow | Calls | Slots written | Gas |");
console.log("|---|---|---|---|");
for (const flow of FLOWS) console.log(`| ${flow} | ${rows.get(flow)!.join(" | ")} |`);
