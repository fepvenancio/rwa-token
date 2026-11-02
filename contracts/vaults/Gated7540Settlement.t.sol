// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol';
import {Multicall} from '@openzeppelin/contracts/utils/Multicall.sol';

import {IERC7540Deposit} from 'interfaces/IERC7540Deposit.sol';
import {IERC7540Redeem} from 'interfaces/IERC7540Redeem.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';
import {Gated7540VaultUnitTest} from 'contracts/vaults/Gated7540Vault.t.sol';

/// @notice The vault names one fixed second contract, and every implementation creates its own
contract Gated7540SettlementUnit_Wiring is Gated7540VaultUnitTest {
  function test_WhenQueried_TheVaultNamesContractCode() external view {
    address _logic = _vault.SETTLEMENT_LOGIC();
    assertGt(_logic.code.length, 0);
    assertNotEq(_logic, address(_vault));
  }

  function test_WhenTwoImplementationsAreDeployed_EachCreatesItsOwn() external {
    assertNotEq(new Gated7540Vault().SETTLEMENT_LOGIC(), new Gated7540Vault().SETTLEMENT_LOGIC());
  }
}

/// @notice Reached directly, the second contract has its own empty storage: nobody holds a role, and nothing can be done
contract Gated7540SettlementUnit_DirectCalls is Gated7540VaultUnitTest {
  Gated7540Vault internal _logic;

  function setUp() public override {
    super.setUp();
    _logic = Gated7540Vault(_vault.SETTLEMENT_LOGIC());
  }

  function test_WhenTheSettlerClosesAPeriodOnIt_ItReverts() external {
    vm.expectRevert(_noRole(_settler, _vault.SETTLER_ROLE()));
    vm.prank(_settler);
    _logic.closePeriod();
  }

  function test_WhenTheSettlerSettlesOnIt_ItReverts() external {
    vm.expectRevert(_noRole(_settler, _vault.SETTLER_ROLE()));
    vm.prank(_settler);
    _logic.settlePeriod(0, 0, _cash, address(0));
  }

  function test_WhenTheAgentRecoversClaimableOnIt_ItReverts() external {
    vm.expectRevert(_noRole(_agent, _vault.AGENT_ROLE()));
    vm.prank(_agent);
    _logic.recoverClaimable(_alice, _bob);
  }

  function test_WhenTheAgentRejectsOnIt_NothingIsPending() external {
    vm.startPrank(_agent);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _logic.rejectDepositRequest(_alice);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _logic.rejectRedeemRequest(_alice);
    vm.expectRevert(IGated7540Vault.Gated7540Vault_NothingPending.selector);
    _logic.recoverRedeemRequest(_alice, _bob);
    vm.stopPrank();
  }

  function test_WhenTheVaultsAdminGrantsARoleOnIt_ItReverts() external {
    bytes32 _settlerRole = _vault.SETTLER_ROLE();
    vm.expectRevert(_noRole(_admin, bytes32(0)));
    vm.prank(_admin);
    _logic.grantRole(_settlerRole, _admin);
  }

  function test_WhenUpgradedDirectly_ItReverts() external {
    vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
    vm.prank(_admin);
    _logic.upgradeToAndCall(address(_vault), '');
  }

  function test_WhenAnInvestorCallsIt_TheFunctionIsNotThere() external {
    (bool _deposited,) = address(_logic).call(abi.encodeCall(IERC7540Deposit.requestDeposit, (1, _alice, _alice)));
    (bool _redeemed,) = address(_logic).call(abi.encodeCall(IERC7540Redeem.requestRedeem, (1, _alice, _alice)));
    assertFalse(_deposited);
    assertFalse(_redeemed);
  }
}

/// @notice Through the vault, a moved function acts on the vault: its storage, its events, its caller, its errors
contract Gated7540SettlementUnit_HandOff is Gated7540VaultUnitTest {
  function test_WhenAMovedFunctionRuns_TheEventComesFromTheVault() external {
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.PeriodClosed(1);
    vm.prank(_settler);
    _vault.closePeriod();
  }

  function test_WhenAMovedFunctionRuns_ItWritesTheVaultsStorage() external {
    vm.prank(_settler);
    _vault.closePeriod();
    (uint64 _open,,) = _vault.dealingState();
    assertEq(_open, 2);
  }

  function test_WhenCalledWithoutTheRole_TheErrorNamesTheCaller() external {
    vm.expectRevert(_noRole(_stranger, _vault.SETTLER_ROLE()));
    vm.prank(_stranger);
    _vault.closePeriod();
  }

  function test_WhenAMovedFunctionReverts_TheTypedErrorComesBack() external {
    vm.startPrank(_settler);
    _vault.closePeriod();
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_PeriodUnsettled.selector, 1));
    _vault.closePeriod();
    vm.stopPrank();
  }

  function test_WhenBatched_MovedFunctionsKeepTheCaller() external {
    _requestDeposit(_alice, 100);
    bytes[] memory _calls = new bytes[](2);
    _calls[0] = abi.encodeCall(IGated7540Vault.closePeriod, ());
    _calls[1] = abi.encodeCall(IGated7540Vault.settlePeriod, (0, 0, _cash, address(0)));
    vm.prank(_settler);
    Multicall(address(_vault)).multicall(_calls);
    (, uint64 _settled,) = _vault.dealingState();
    assertEq(_settled, 1);
    assertEq(_vault.maxMint(_alice), 100 * _PAR);
  }

  function test_WhenASelectorIsUnknown_ItReverts() external {
    (bool _ok,) = address(_vault).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
    assertFalse(_ok);
  }
}

/// @notice An upgrade brings the new implementation's second contract and keeps the proxy's state
contract Gated7540SettlementUnit_Upgrade is Gated7540VaultUnitTest {
  function test_WhenUpgraded_TheNewLogicActsOnTheOldState() external {
    _requestDeposit(_alice, 100);
    _settleAtPar();
    address _before = _vault.SETTLEMENT_LOGIC();

    Gated7540Vault _impl = new Gated7540Vault();
    vm.mockCall(
      _registry,
      abi.encodeCall(IPolicyRegistry.isAttested, (address(_impl), IPolicyRegistry.AttestKind.IMPLEMENTATION)),
      abi.encode(true)
    );
    vm.startPrank(_admin);
    _vault.grantRole(_vault.UPGRADER_ROLE(), _admin);
    _vault.upgradeToAndCall(address(_impl), '');
    vm.stopPrank();

    assertEq(_vault.SETTLEMENT_LOGIC(), _impl.SETTLEMENT_LOGIC());
    assertNotEq(_vault.SETTLEMENT_LOGIC(), _before);
    assertEq(_vault.maxMint(_alice), 100 * _PAR);

    _requestDeposit(_bob, 50);
    _settleAtPar();
    (, uint64 _settled,) = _vault.dealingState();
    assertEq(_settled, 2);
    assertEq(_vault.maxMint(_bob), 50 * _PAR);
    assertTrue(IAccessControl(address(_vault)).hasRole(_vault.SETTLER_ROLE(), _settler));
  }
}
