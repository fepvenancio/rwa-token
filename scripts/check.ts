// SPDX-License-Identifier: UNLICENSED
// `npm run check -- --network <name>`, with its settings in the environment: see `checkCommand` in `scripts/lib/commands.ts`.
import { network } from "hardhat";

import { checkCommand } from "./lib/commands.js";

process.exitCode = await checkCommand(process.env, await network.create(), console.log);
