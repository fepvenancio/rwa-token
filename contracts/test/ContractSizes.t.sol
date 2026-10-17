// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {GovernanceTimelock} from 'contracts/governance/GovernanceTimelock.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {IdentityRule} from 'contracts/hooks/rules/IdentityRule.sol';
import {LockupRule} from 'contracts/hooks/rules/LockupRule.sol';
import {MaxHoldersRule} from 'contracts/hooks/rules/MaxHoldersRule.sol';
import {SettlementWindowRule} from 'contracts/hooks/rules/SettlementWindowRule.sol';
import {IntentExecutor} from 'contracts/intents/IntentExecutor.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';
import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';

/**
 * @notice EIP-170 guard. The default build profile matches the production one, so these are the deployed sizes.
 *         The test network keeps the size limit; this assertion makes a regression fail CI instead of a deployment
 */
contract ContractSizesTest is Test {
  uint256 internal constant _EIP170_LIMIT = 24_576;

  /// @dev Hardhat's coverage instrumentation calls this address from every instrumented contract (EDR's
  ///      `__NomicFoundationCoverage` library), so its 20 bytes appear in instrumented bytecode and never in a real build
  address internal constant _COVERAGE_ADDRESS = 0xc0bEc0BEc0BeC0bEC0beC0bEC0bEC0beC0beC0BE;

  function test_WhenDeployed_EveryContractFitsTheEip170Limit() external {
    // Under `--coverage` the bytecode is instrumented and larger than what deploys; the limit applies to real builds.
    vm.skip(_isInstrumented(address(new IntentToken()).code));
    address _registry = address(new PolicyRegistry(address(this), address(this)));
    _assertFits('IntentToken', address(new IntentToken()));
    _assertFits('Gated4626Vault', address(new Gated4626Vault()));
    _assertFits('Gated7540Vault', address(new Gated7540Vault()));
    _assertFits('PolicyRegistry', _registry);
    _assertFits(
      'ComplianceHook',
      address(new ComplianceHook(address(this), IPolicyRegistry(_registry), address(this), new IComplianceRule[](0)))
    );
    _assertFits('IntentExecutor', address(new IntentExecutor(address(this), address(this))));
    _assertFits('LockupRule', address(new LockupRule()));
    _assertFits('SettlementWindowRule', address(new SettlementWindowRule()));
    _assertFits('MaxHoldersRule', address(new MaxHoldersRule()));
    _assertFits('IdentityRule', address(new IdentityRule(IIdentityRegistry(address(this)))));
    _assertFits('ProxyDeployer', address(new ProxyDeployer(address(this))));
    _assertFits(
      'GovernanceTimelock',
      address(new GovernanceTimelock(7 days, new address[](0), new address[](0), address(this), address(this)))
    );
  }

  function _isInstrumented(
    bytes memory _code
  ) internal pure returns (bool _instrumented) {
    bytes20 _needle = bytes20(_COVERAGE_ADDRESS);
    if (_code.length < 20) return false;
    for (uint256 _i; _i <= _code.length - 20; ++_i) {
      bytes20 _window;
      assembly ('memory-safe') {
        _window := mload(add(add(_code, 0x20), _i))
      }
      if (_window == _needle) return true;
    }
  }

  function _assertFits(
    string memory _name,
    address _deployed
  ) internal view {
    assertLe(_deployed.code.length, _EIP170_LIMIT, _name);
  }
}
