// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol';
import {Multicall} from '@openzeppelin/contracts/utils/Multicall.sol';

import {IGated4626Vault} from 'interfaces/IGated4626Vault.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';

import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';
import {Gated4626VaultPortfolioTest} from 'contracts/vaults/Gated4626VaultPortfolio.t.sol';

abstract contract Gated4626ManagementTest is Gated4626VaultPortfolioTest {
  function _noRole(
    address _caller,
    bytes32 _role
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role);
  }
}

/// @notice The vault names one fixed second contract, and every implementation creates its own
contract Gated4626ManagementUnit_Wiring is Gated4626ManagementTest {
  function test_WhenQueried_TheVaultNamesContractCode() external view {
    address _logic = _vault.MANAGEMENT_LOGIC();
    assertGt(_logic.code.length, 0);
    assertNotEq(_logic, address(_vault));
  }

  function test_WhenTwoImplementationsAreDeployed_EachCreatesItsOwn() external {
    assertNotEq(new Gated4626Vault().MANAGEMENT_LOGIC(), new Gated4626Vault().MANAGEMENT_LOGIC());
  }
}

/// @notice Reached directly, the second contract has its own empty storage: nobody holds a role, and nothing can be done
contract Gated4626ManagementUnit_DirectCalls is Gated4626ManagementTest {
  Gated4626Vault internal _logic;

  function setUp() public override {
    super.setUp();
    _logic = Gated4626Vault(_vault.MANAGEMENT_LOGIC());
  }

  /// @dev This test contract is the vault's admin, and holds nothing on the second contract
  function test_WhenTheVaultsAdminPlugsAPortfolioOnIt_ItReverts() external {
    vm.expectRevert(_noRole(address(this), bytes32(0)));
    _logic.setPortfolio(address(_portfolio), _RATE);
  }

  function test_WhenTheVaultsAdminSetsAFeeModelOnIt_ItReverts() external {
    vm.expectRevert(_noRole(address(this), bytes32(0)));
    _logic.setFeeModel(makeAddr('feeModel'));
  }

  function test_WhenTheVaultsAdminOrGuardianSetsTheRateOnIt_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IGated4626Vault.Gated4626Vault_Unauthorized.selector, address(this)));
    _logic.setMaxRate(1);
    vm.expectRevert(abi.encodeWithSelector(IGated4626Vault.Gated4626Vault_Unauthorized.selector, _guardian));
    vm.prank(_guardian);
    _logic.setMaxRate(0);
  }

  function test_WhenAnyoneCollectsFeesOnIt_ThereIsNoFeeModel() external {
    vm.expectRevert(IGated4626Vault.Gated4626Vault_NoFeeModel.selector);
    _logic.collectFees();
  }

  function test_WhenTheVaultsAdminGrantsARoleOnIt_ItReverts() external {
    vm.expectRevert(_noRole(address(this), bytes32(0)));
    _logic.grantRole(_ALLOCATOR_ROLE, address(this));
  }

  function test_WhenUpgradedDirectly_ItReverts() external {
    vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
    _logic.upgradeToAndCall(address(_vault), '');
  }

  /// @dev It has no asset and no policy, so it can take no money and issue no share
  function test_WhenAnInvestorDepositsIntoIt_ItReverts() external {
    vm.expectRevert();
    vm.prank(_alice);
    _logic.deposit(_IN, _alice);
    assertEq(_logic.totalSupply(), 0);
  }
}

/// @notice Through the vault, a moved function acts on the vault: its storage, its events, its caller, its errors
contract Gated4626ManagementUnit_HandOff is Gated4626ManagementTest {
  function test_WhenAMovedFunctionRuns_TheEventsComeFromTheVault() external {
    vm.expectEmit(address(_vault));
    emit IGated4626Vault.PortfolioSet(address(_portfolio));
    vm.expectEmit(address(_vault));
    emit IGated4626Vault.MaxRateSet(_RATE);
    _plug();
  }

  function test_WhenAMovedFunctionRuns_ItWritesTheVaultsStorage() external {
    _plug();
    assertEq(_vault.portfolio(), address(_portfolio));
    assertEq(_vault.maxRate(), _RATE);
  }

  function test_WhenCalledWithoutTheRole_TheErrorNamesTheCaller() external {
    vm.expectRevert(_noRole(_stranger, bytes32(0)));
    vm.prank(_stranger);
    _vault.setPortfolio(address(_portfolio), _RATE);
    vm.expectRevert(abi.encodeWithSelector(IGated4626Vault.Gated4626Vault_Unauthorized.selector, _stranger));
    vm.prank(_stranger);
    _vault.setMaxRate(1);
  }

  function test_WhenAMovedFunctionReverts_TheTypedErrorComesBack() external {
    vm.expectRevert(IGated4626Vault.Gated4626Vault_ZeroRate.selector);
    _vault.setPortfolio(address(_portfolio), 0);
    vm.expectRevert(IGated4626Vault.Gated4626Vault_NoFeeModel.selector);
    _vault.collectFees();
  }

  function test_WhenTheGuardianLowersTheRate_ItIsTheVaultsGuardianThatIsAsked() external {
    _plug();
    vm.prank(_guardian);
    _vault.setMaxRate(_RATE - 1);
    assertEq(_vault.maxRate(), _RATE - 1);
  }

  function test_WhenBatched_MovedFunctionsKeepTheCaller() external {
    bytes[] memory _calls = new bytes[](2);
    _calls[0] = abi.encodeCall(IGated4626Vault.setPortfolio, (address(_portfolio), _RATE));
    _calls[1] = abi.encodeCall(IGated4626Vault.setMaxRate, (_RATE * 2));
    Multicall(address(_vault)).multicall(_calls);
    assertEq(_vault.portfolio(), address(_portfolio));
    assertEq(_vault.maxRate(), _RATE * 2);
  }

  /// @dev The money a first plug forwards moves from the vault, not from the second contract
  function test_WhenAPlugForwardsTheVaultsBalance_ItLeavesTheVault() external {
    _deposit(_alice, _IN);
    _plug();
    assertEq(_asset.balanceOf(address(_vault)), 0);
    assertEq(_asset.balanceOf(address(_portfolio)), _IN);
    assertEq(_vault.lastCounted(), _IN);
  }
}

/// @notice An upgrade brings the new implementation's second contract and keeps the proxy's state
contract Gated4626ManagementUnit_Upgrade is Gated4626ManagementTest {
  function test_WhenUpgradedOntoTheSecondContract_ItIsRefused() external {
    address _logic = _vault.MANAGEMENT_LOGIC();
    _registry.attest(_logic.codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _vault.grantRole(_vault.UPGRADER_ROLE(), address(this));
    vm.expectRevert(
      abi.encodeWithSelector(
        ITemplated.Templated_WrongTemplate.selector,
        _logic,
        keccak256('Gated4626Vault'),
        keccak256('Gated4626Management')
      )
    );
    _vault.upgradeToAndCall(_logic, '');
  }

  function test_WhenUpgraded_TheNewLogicActsOnTheOldState() external {
    _plug();
    _deposit(_alice, _IN);
    address _before = _vault.MANAGEMENT_LOGIC();
    Gated4626Vault _impl = new Gated4626Vault();
    // Each implementation names its own second contract, so each has its own codehash to attest.
    _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _vault.grantRole(_vault.UPGRADER_ROLE(), address(this));
    _vault.upgradeToAndCall(address(_impl), '');

    assertEq(_vault.MANAGEMENT_LOGIC(), _impl.MANAGEMENT_LOGIC());
    assertNotEq(_vault.MANAGEMENT_LOGIC(), _before);
    assertEq(_vault.portfolio(), address(_portfolio));
    assertEq(_vault.lastCounted(), _IN);
    _vault.setMaxRate(_RATE * 2);
    assertEq(_vault.maxRate(), _RATE * 2);
  }
}
