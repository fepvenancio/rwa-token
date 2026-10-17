import hardhatKeystore from "@nomicfoundation/hardhat-keystore";
import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { defineConfig } from "hardhat/config";

// One compiler setting for both profiles: tests run on exactly the bytecode that gets deployed.
// No metadata hash: solc metadata includes each compile job's remappings, so with it the same source compiles to
// different bytecode depending on job grouping. Without it, every codehash and CREATE2 address is reproducible from the
// source at a tag. Mirrored in foundry.toml; `npm run verify:reproducible` checks Hardhat and forge agree.
const compiler = {
  version: "0.8.30",
  settings: {
    evmVersion: "cancun",
    optimizer: {
      enabled: true,
      runs: 200,
    },
    metadata: {
      bytecodeHash: "none" as const,
    },
  },
};

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin, hardhatKeystore],
  solidity: {
    // Hardhat emits artifacts only for project sources; Ignition deploys OZ's own timelock by name.
    npmFilesToBuild: ["@openzeppelin/contracts/governance/TimelockController.sol"],
    profiles: {
      default: compiler,
      production: compiler,
    },
  },
  test: {
    solidity: {
      fuzz: {
        runs: 256,
      },
    },
  },
});
