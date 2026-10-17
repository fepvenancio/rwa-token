import hardhatKeystore from "@nomicfoundation/hardhat-keystore";
import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { defineConfig } from "hardhat/config";

// One compiler setting for both profiles: tests run on exactly the bytecode that gets deployed.
const compiler = {
  version: "0.8.30",
  settings: {
    evmVersion: "cancun",
    optimizer: {
      enabled: true,
      runs: 200,
    },
  },
};

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin, hardhatKeystore],
  solidity: {
    // Hardhat emits artifacts only for project sources; TS tests (and Phase 7) deploy OZ's own proxy by name.
    npmFilesToBuild: ["@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol"],
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
