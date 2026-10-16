import hardhatKeystore from "@nomicfoundation/hardhat-keystore";
import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { defineConfig } from "hardhat/config";

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin, hardhatKeystore],
  solidity: {
    profiles: {
      default: {
        version: "0.8.30",
        settings: {
          evmVersion: "cancun",
        },
      },
      production: {
        version: "0.8.30",
        settings: {
          evmVersion: "cancun",
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
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
