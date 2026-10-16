// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @dev Phase 0 toolchain smoke test. Delete at the start of Phase 1.
contract SmokeToken is ERC20Upgradeable, ReentrancyGuardTransient {
    function guarded() external nonReentrant returns (bool) {
        return true;
    }
}

contract SmokeTest is Test {
    function test_ToolchainCompilesOzAndTransientStorage() public {
        assertTrue(new SmokeToken().guarded());
    }
}
