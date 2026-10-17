// Reproducibility gate and release manifest. Run with `npm run verify:reproducible`.
//
// The same source must compile to the same bytecode however it is built. Compared, from clean:
//   1. two Hardhat production builds (each file compiled in isolation);
//   2. production vs Hardhat's default build (files grouped into shared jobs with the tests);
//   3. production vs forge (different remappings and source paths);
//   4. the TokenProxy artifact vs the TokenProxy creation code embedded in ProxyDeployer, which fixes every token's
//      CREATE2 address. With solc's metadata hash on, (2)-(4) differ; this gate is what keeps it off.
//
// Then writes `release-build/`: `manifest.json` (per contract: runtime and creation code hashes, immutable slots) and
// the production build-info of the in-scope sources only (no tests, mocks or OZ-rooted jobs; the OZ sources a contract
// imports stay inside its job's solc input, since they are needed to reproduce it). This is the reference the council
// compares a clean build at the release tag against.
import { execSync } from "node:child_process";
import { cpSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { keccak256, type Hex } from "viem";

/** Contracts whose codehash is attested, then everything else the deployment puts on-chain. */
const ATTESTED = {
  IdentityRule: "hooks/rules",
  LockupRule: "hooks/rules",
  SettlementWindowRule: "hooks/rules",
  MaxHoldersRule: "hooks/rules",
  ComplianceHook: "hooks",
  IntentToken: "tokens",
  Gated4626Vault: "vaults",
  Gated7540Vault: "vaults",
} as const;
const DEPLOYED = {
  PolicyRegistry: "governance",
  IntentExecutor: "intents",
  ProxyDeployer: "deploy",
  TokenProxy: "deploy",
} as const;
const CONTRACTS: Record<string, string> = { ...ATTESTED, ...DEPLOYED };

type Entry = { runtime: string; creation: string; immutables: string };
type Manifest = Record<string, Entry>;

const sh = (command: string) => execSync(command, { stdio: ["ignore", "ignore", "inherit"] });

/** Immutable slots as sorted `start:length` pairs: AST ids differ between jobs, positions must not. */
function immutableSlots(references: Record<string, { start: number; length: number }[]> | undefined) {
  return Object.values(references ?? {})
    .flat()
    .map(({ start, length }) => `${start}:${length}`)
    .sort()
    .join(",");
}

function hardhatBuild(profile: "production" | "default"): Manifest {
  rmSync("artifacts", { recursive: true, force: true });
  rmSync("cache", { recursive: true, force: true });
  sh(`npx hardhat build --quiet --build-profile ${profile}`);
  const manifest: Manifest = {};
  for (const [name, dir] of Object.entries(CONTRACTS)) {
    const a = JSON.parse(readFileSync(`artifacts/contracts/${dir}/${name}.sol/${name}.json`, "utf8"));
    manifest[name] = {
      runtime: a.deployedBytecode,
      creation: a.bytecode,
      immutables: immutableSlots(a.immutableReferences),
    };
  }
  return manifest;
}

function forgeBuild(): Manifest {
  const out = "forge-repro";
  rmSync(out, { recursive: true, force: true });
  rmSync(`${out}-cache`, { recursive: true, force: true });
  sh(`forge build --force --out ${out} --cache-path ${out}-cache --skip './contracts/**/*.t.sol'`);
  const manifest: Manifest = {};
  for (const name of Object.keys(CONTRACTS)) {
    const a = JSON.parse(readFileSync(join(out, `${name}.sol`, `${name}.json`), "utf8"));
    manifest[name] = {
      runtime: a.deployedBytecode.object,
      creation: a.bytecode.object,
      immutables: immutableSlots(a.deployedBytecode.immutableReferences),
    };
  }
  rmSync(out, { recursive: true, force: true });
  rmSync(`${out}-cache`, { recursive: true, force: true });
  return manifest;
}

function compare(label: string, reference: Manifest, other: Manifest): string[] {
  const failures: string[] = [];
  for (const name of Object.keys(reference)) {
    for (const field of ["runtime", "creation", "immutables"] as const) {
      if (reference[name][field] !== other[name][field]) failures.push(`${label}: ${name}.${field} differs`);
    }
  }
  return failures;
}

const failures: string[] = [];
const production = hardhatBuild("production");
failures.push(...compare("production rebuild", production, hardhatBuild("production")));
failures.push(...compare("default profile", production, hardhatBuild("default")));
failures.push(...compare("forge", production, forgeBuild()));
const proxyCreation = production.TokenProxy.creation.replace(/^0x/, "");
if (!production.ProxyDeployer.runtime.includes(proxyCreation)) {
  failures.push("ProxyDeployer does not embed the TokenProxy artifact's creation code");
}

// Leave the production build in place and package it as the release reference.
hardhatBuild("production");
rmSync("release-build", { recursive: true, force: true });
mkdirSync("release-build");
const manifest = Object.fromEntries(
  Object.entries(production).map(([name, e]) => [
    name,
    {
      attested: name in ATTESTED,
      // keccak256 of the runtime code with its immutable slots zeroed. A deployed instance's extcodehash is the
      // keccak256 of this code with the slots filled from that instance's code (its constructor arguments).
      runtimeTemplateKeccak: keccak256(e.runtime as Hex),
      creationKeccak: keccak256(e.creation as Hex),
      runtime: e.runtime,
      immutableSlots: e.immutables,
    },
  ]),
);
writeFileSync("release-build/manifest.json", `${JSON.stringify(manifest, null, 2)}\n`);
// Production builds compile each file in its own job, so a build-info's single user source is its root file.
const inScope = (source: string) =>
  source.startsWith("contracts/") && !source.startsWith("contracts/test/") && !source.endsWith(".t.sol");
mkdirSync("release-build/build-info");
let published = 0;
for (const file of readdirSync("artifacts/build-info").filter((f) => !f.endsWith(".output.json"))) {
  const roots = Object.keys(JSON.parse(readFileSync(join("artifacts/build-info", file), "utf8")).userSourceNameMap);
  if (roots.length !== 1) failures.push(`build-info ${file} has ${roots.length} root files; expected an isolated build`);
  if (!roots.every(inScope)) continue;
  for (const part of [file, file.replace(/\.json$/, ".output.json")]) {
    cpSync(join("artifacts/build-info", part), join("release-build/build-info", part));
  }
  published += 1;
}
if (published === 0) failures.push("no in-scope build-info to publish");

if (failures.length > 0) {
  console.error(`NOT REPRODUCIBLE\n  ${failures.join("\n  ")}`);
  process.exit(1);
}
console.log(
  `REPRODUCIBLE: ${Object.keys(CONTRACTS).length} contracts identical across 2 production builds, the default profile ` +
    `and forge; TokenProxy matches ProxyDeployer. Release reference written to release-build/ ` +
    `(${published} in-scope build-info files).`,
);
