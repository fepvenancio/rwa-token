// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {ICredentialRegistry} from 'interfaces/ICredentialRegistry.sol';
import {IFund} from 'interfaces/IFund.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {Fund} from 'contracts/fund/Fund.sol';
import {GovernanceTimelock} from 'contracts/governance/GovernanceTimelock.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {CredentialRule} from 'contracts/hooks/rules/CredentialRule.sol';
import {FundHoldersRule} from 'contracts/hooks/rules/FundHoldersRule.sol';
import {HolderRestrictionRule} from 'contracts/hooks/rules/HolderRestrictionRule.sol';
import {MinPositionRule} from 'contracts/hooks/rules/MinPositionRule.sol';
import {SettlementWindowRule} from 'contracts/hooks/rules/SettlementWindowRule.sol';
import {CredentialRegistry} from 'contracts/identity/CredentialRegistry.sol';
import {DvPExecutor} from 'contracts/intents/DvPExecutor.sol';
import {IntentExecutor} from 'contracts/intents/IntentExecutor.sol';
import {ERC4626Adapter} from 'contracts/portfolio/ERC4626Adapter.sol';
import {Portfolio} from 'contracts/portfolio/Portfolio.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {MockERC4626Target} from 'contracts/test/MockERC4626Target.sol';
import {GatedToken} from 'contracts/tokens/GatedToken.sol';
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
    _assertFits('GatedToken', address(new GatedToken()));
    _assertFits('IntentToken', address(new IntentToken()));
    _assertFits('Gated4626Vault', address(new Gated4626Vault()));
    _assertFits('Gated7540Vault', address(new Gated7540Vault()));
    _assertFits('PolicyRegistry', _registry);
    _assertFits('ComplianceHook', address(new ComplianceHook(IPolicyRegistry(_registry))));
    _assertFits('IntentExecutor', address(new IntentExecutor(address(this), address(this))));
    _assertFits('DvPExecutor', address(new DvPExecutor(address(this), address(this))));
    _assertFits('HolderRestrictionRule', address(new HolderRestrictionRule()));
    _assertFits('MinPositionRule', address(new MinPositionRule()));
    _assertFits('SettlementWindowRule', address(new SettlementWindowRule()));
    _assertFits('CredentialRegistry', address(new CredentialRegistry(address(this), address(this))));
    _assertFits('CredentialRule', address(new CredentialRule(ICredentialRegistry(address(this)))));
    _assertFits('ProxyDeployer', address(new ProxyDeployer(address(this), IPolicyRegistry(_registry))));
    Fund _fund = new Fund(address(this), IPolicyRegistry(_registry));
    _assertFits('Fund', address(_fund));
    _assertFits('FundHoldersRule', address(new FundHoldersRule(IFund(address(_fund)))));
    MockAsset _asset = new MockAsset(6);
    _assertFits('Portfolio', address(new Portfolio(address(this), IERC20(address(_asset)), true)));
    MockERC4626Target _target = new MockERC4626Target(IERC20(address(_asset)));
    _assertFits('ERC4626Adapter', address(new ERC4626Adapter(address(this), _target, bytes32(0))));
    _assertFits(
      'GovernanceTimelock',
      address(new GovernanceTimelock(1 days, new address[](0), new address[](0), address(this), address(this)))
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
