// SPDX-License-Identifier: UNLICENSED
// `npm run keeper -- --network <name>`, with its settings in the environment: see `keeperCommand` in `scripts/lib/commands.ts`.
import { network } from "hardhat";

import { keeperCommand } from "./lib/commands.js";

process.exitCode = await keeperCommand(process.env, await network.create(), console.log);
