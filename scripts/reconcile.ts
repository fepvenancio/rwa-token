// SPDX-License-Identifier: UNLICENSED
// `npm run reconcile -- --network <name>`, with its settings in the environment: see `reconcileCommand` in `scripts/lib/commands.ts`.
import { network } from "hardhat";

import { reconcileCommand } from "./lib/commands.js";

process.exitCode = await reconcileCommand(process.env, await network.create(), console.log);
