// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {IdentityRule} from 'contracts/hooks/rules/IdentityRule.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';

/**
 * @notice EIP-170 guard. The default build profile matches the production one, so these are the deployed sizes.
 *         The test network keeps the size limit; this assertion makes a regression fail CI instead of a deployment
 */
contract ContractSizesTest is Test {
  uint256 internal constant _EIP170_LIMIT = 24_576;

  function test_WhenDeployed_EveryContractFitsTheEip170Limit() external {
    address _registry = address(new PolicyRegistry(address(this), address(this)));
    _assertFits('IntentToken', address(new IntentToken()));
    _assertFits('PolicyRegistry', _registry);
    _assertFits(
      'ComplianceHook',
      address(new ComplianceHook(address(this), IPolicyRegistry(_registry), address(this), new IComplianceRule[](0)))
    );
    _assertFits('IdentityRule', address(new IdentityRule(address(this), IIdentityRegistry(address(this)))));
  }

  function _assertFits(
    string memory _name,
    address _deployed
  ) internal view {
    assertLe(_deployed.code.length, _EIP170_LIMIT, _name);
  }
}
