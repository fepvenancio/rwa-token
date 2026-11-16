// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {ICredentialRegistry} from 'interfaces/ICredentialRegistry.sol';
import {IFund} from 'interfaces/IFund.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {Distributor} from 'contracts/distribution/Distributor.sol';
import {Fund} from 'contracts/fund/Fund.sol';
import {GovernanceTimelock} from 'contracts/governance/GovernanceTimelock.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {CredentialRule} from 'contracts/hooks/rules/CredentialRule.sol';
import {ExecutedOnlyRule} from 'contracts/hooks/rules/ExecutedOnlyRule.sol';
import {FundHoldersRule} from 'contracts/hooks/rules/FundHoldersRule.sol';
import {HolderRestrictionRule} from 'contracts/hooks/rules/HolderRestrictionRule.sol';
import {MinPositionRule} from 'contracts/hooks/rules/MinPositionRule.sol';
import {SettlementWindowRule} from 'contracts/hooks/rules/SettlementWindowRule.sol';
import {SupplyCapRule} from 'contracts/hooks/rules/SupplyCapRule.sol';
import {CredentialRegistry} from 'contracts/identity/CredentialRegistry.sol';
import {DvPExecutor} from 'contracts/intents/DvPExecutor.sol';
import {IntentExecutor} from 'contracts/intents/IntentExecutor.sol';
import {SignedEntry} from 'contracts/intents/SignedEntry.sol';
import {FeeModel} from 'contracts/nav/FeeModel.sol';
import {NavDesk} from 'contracts/nav/NavDesk.sol';
import {ERC20CallValidator} from 'contracts/portfolio/ERC20CallValidator.sol';
import {ERC4626Adapter} from 'contracts/portfolio/ERC4626Adapter.sol';
import {ERC4626CallValidator} from 'contracts/portfolio/ERC4626CallValidator.sol';
import {GuardedAccount} from 'contracts/portfolio/GuardedAccount.sol';
import {Portfolio} from 'contracts/portfolio/Portfolio.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {MockERC4626Target} from 'contracts/test/MockERC4626Target.sol';
import {Gated721} from 'contracts/tokens/Gated721.sol';
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
  uint256 internal constant _EIP3860_LIMIT = 49_152;

  /// @dev Hardhat's coverage instrumentation calls this address from every instrumented contract (EDR's
  ///      `__NomicFoundationCoverage` library), so its 20 bytes appear in instrumented bytecode and never in a real build
  address internal constant _COVERAGE_ADDRESS = 0xc0bEc0BEc0BeC0bEC0beC0bEC0bEC0beC0beC0BE;

  function test_WhenDeployed_EveryContractFitsTheEip170Limit() external {
    // Under `--coverage` the bytecode is instrumented and larger than what deploys; the limit applies to real builds.
    vm.skip(_isInstrumented(address(new IntentToken()).code));
    address _registry = address(new PolicyRegistry(address(this), address(this)));
    _assertFits('GatedToken', address(new GatedToken()));
    _assertFits('IntentToken', address(new IntentToken()));
    _assertFits('Gated721', address(new Gated721()));
    Gated4626Vault _syncVault = new Gated4626Vault();
    _assertFits('Gated4626Vault', address(_syncVault));
    assertGt(_syncVault.MANAGEMENT_LOGIC().code.length, 0, 'Gated4626Management has no code');
    _assertFits('Gated4626Management', _syncVault.MANAGEMENT_LOGIC());
    Gated7540Vault _asyncVault = new Gated7540Vault();
    _assertFits('Gated7540Vault', address(_asyncVault));
    assertGt(_asyncVault.SETTLEMENT_LOGIC().code.length, 0, 'Gated7540Settlement has no code');
    _assertFits('Gated7540Settlement', _asyncVault.SETTLEMENT_LOGIC());
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
    _assertFits('NavDesk', address(new NavDesk(address(this), address(this), 1 days, 1 hours, 1 days)));
    _assertFits('SignedEntry', address(new SignedEntry()));
    _assertFits('SupplyCapRule', address(new SupplyCapRule()));
    _assertFits('ExecutedOnlyRule', address(new ExecutedOnlyRule()));
    _assertFits('Distributor', address(new Distributor(address(this))));
    _assertFits('FeeModel', address(new FeeModel(address(this), 0, 0, 0, false)));
    _assertFits('ERC20CallValidator', address(new ERC20CallValidator(address(this), 0)));
    _assertFits('ERC4626CallValidator', address(new ERC4626CallValidator()));
    Portfolio _reportedPortfolio = new Portfolio(address(this), IERC20(address(_asset)), true);
    _assertFits(
      'GuardedAccount', address(new GuardedAccount(address(_reportedPortfolio), bytes32(uint256(1)), bytes32(0)))
    );
    MockERC4626Target _target = new MockERC4626Target(IERC20(address(_asset)));
    _assertFits('ERC4626Adapter', address(new ERC4626Adapter(address(this), _target, bytes32(0))));
    _assertFits(
      'GovernanceTimelock',
      address(new GovernanceTimelock(1 days, new address[](0), new address[](0), address(this), address(this)))
    );
  }

  /// @dev Each vault's creation code carries its second contract's, so they are the ones close to this limit
  function test_WhenDeployed_TheVaultsWithASecondContractFitTheEip3860Limit() external {
    vm.skip(_isInstrumented(address(new IntentToken()).code));
    assertLe(type(Gated7540Vault).creationCode.length, _EIP3860_LIMIT);
    assertLe(type(Gated4626Vault).creationCode.length, _EIP3860_LIMIT);
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
