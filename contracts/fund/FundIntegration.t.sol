// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';
import {Vm} from 'forge-std/Vm.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC8473} from 'interfaces/IERC8473.sol';
import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';
import {IFund} from 'interfaces/IFund.sol';
import {IFundHoldersRule} from 'interfaces/IFundHoldersRule.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IPolicyGatedCore} from 'interfaces/IPolicyGatedCore.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {Fund} from 'contracts/fund/Fund.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {FundHoldersRule} from 'contracts/hooks/rules/FundHoldersRule.sol';
import {HolderRestrictionRule} from 'contracts/hooks/rules/HolderRestrictionRule.sol';
import {MinPositionRule} from 'contracts/hooks/rules/MinPositionRule.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {MockIdentityRegistry} from 'contracts/test/MockIdentityRegistry.sol';
import {MockIdentityRule} from 'contracts/test/MockIdentityRule.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';
import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';

/**
 * @notice One fund, three classes of three templates (`IntentToken`, `Gated4626Vault`, `Gated7540Vault`), each with its
 *         own real hook and the real rules in the deployed order, plus `FundHoldersRule` last. This test contract is
 *         the admin of everything while it configures, as in the other integration suites
 */
contract FundIntegrationTest is Test {
  uint256 internal constant _CLASS_TOKEN = 1;
  uint256 internal constant _CLASS_4626 = 2;
  uint256 internal constant _CLASS_7540 = 3;
  uint256 internal constant _PAR = 1e6;

  PolicyRegistry internal _registry;
  MockIdentityRegistry internal _identity;
  MockAsset internal _asset;
  ProxyDeployer internal _deployer;
  Fund internal _fund;
  FundHoldersRule internal _fundRule;
  MockIdentityRule internal _identityRule;
  HolderRestrictionRule internal _restrictionRule;

  IntentToken internal _token;
  Gated4626Vault internal _vault4626;
  Gated7540Vault internal _vault7540;
  ComplianceHook internal _hook;

  address internal _guardian = makeAddr('guardian');
  address internal _minter = makeAddr('minter');
  address internal _burner = makeAddr('burner');
  address internal _agent = makeAddr('agent');
  address internal _settler = makeAddr('settler');
  address internal _cash = makeAddr('cash');
  address internal _treasury = makeAddr('treasury');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');
  address internal _carol = makeAddr('carol');
  address internal _dave = makeAddr('dave');
  address internal _eve = makeAddr('eve'); // never verified

  function setUp() public virtual {
    _registry = new PolicyRegistry(address(this), address(this));
    _identity = new MockIdentityRegistry();
    _asset = new MockAsset(6);
    _deployer = new ProxyDeployer(address(this), _registry);

    _identityRule = new MockIdentityRule(IIdentityRegistry(address(_identity)));
    _restrictionRule = new HolderRestrictionRule();
    _fund = new Fund(address(this), IPolicyRegistry(address(_registry)));
    _fundRule = new FundHoldersRule(_fund);
    _registry.attest(address(_identityRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_restrictionRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_fundRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _fund.setRule(address(_fundRule));
    _fund.setHolderCap(3);
    _hook = new ComplianceHook(_registry);
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');

    _deployToken();
    _deploy4626();
    _deploy7540();
    _configure();
  }

  function _rules(
    FundHoldersRule _last
  ) internal view returns (IComplianceRule[] memory _list) {
    _list = new IComplianceRule[](3);
    _list[0] = _identityRule;
    _list[1] = _restrictionRule;
    _list[2] = _last;
  }

  /// @dev Deployment order: the shared hook is attested once in `setUp`; each class attests its implementation, then
  ///      the proxy comes up with the hook and its rules
  function _attestImplementation(
    address _impl
  ) internal {
    _registry.attest(_impl.codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
  }

  function _deployToken() internal {
    address _impl = address(new IntentToken());
    _attestImplementation(_impl);
    _token = IntentToken(
      _deployer.deploy(
        'gINT',
        _impl,
        abi.encodeCall(
          IntentToken.initialize,
          ('Class Token', 'gINT', 18, address(this), _guardian, address(_registry), address(_hook), _rules(_fundRule))
        ),
        address(_hook),
        _rules(_fundRule)
      )
    );
  }

  function _deploy4626() internal {
    address _impl = address(new Gated4626Vault());
    _attestImplementation(_impl);
    _vault4626 = Gated4626Vault(
      _deployer.deploy(
        'g4626',
        _impl,
        abi.encodeCall(
          Gated4626Vault.initialize,
          (
            IERC20(address(_asset)),
            'Class 4626',
            'g4626',
            address(this),
            _guardian,
            address(_registry),
            address(_hook),
            _rules(_fundRule)
          )
        ),
        address(_hook),
        _rules(_fundRule)
      )
    );
  }

  function _deploy7540() internal {
    address _impl = address(new Gated7540Vault());
    _attestImplementation(_impl);
    _vault7540 = Gated7540Vault(
      _deployer.deploy(
        'g7540',
        _impl,
        abi.encodeCall(
          Gated7540Vault.initialize,
          (
            IERC20(address(_asset)),
            'Class 7540',
            'g7540',
            address(this),
            _guardian,
            address(_registry),
            address(_hook),
            _rules(_fundRule)
          )
        ),
        address(_hook),
        _rules(_fundRule)
      )
    );
  }

  function _configure() internal {
    _fund.registerClass(address(_token));
    _fund.registerClass(address(_vault4626));
    _fund.registerClass(address(_vault7540));

    _token.grantRole(_token.MINTER_ROLE(), _minter);
    _token.grantRole(_token.BURNER_ROLE(), _burner);
    _token.grantRole(_token.AGENT_ROLE(), _agent);
    _vault4626.grantRole(_vault4626.AGENT_ROLE(), _agent);
    _vault7540.grantRole(_vault7540.AGENT_ROLE(), _agent);
    _vault7540.grantRole(_vault7540.SETTLER_ROLE(), _settler);

    // The 7540 escrow is a verified account.
    _identity.set(address(_vault7540), true);

    address[6] memory _accounts = [_alice, _bob, _carol, _dave, _treasury, _cash];
    for (uint256 _i; _i < _accounts.length; ++_i) {
      if (_accounts[_i] != _cash) _identity.set(_accounts[_i], true);
      _asset.mint(_accounts[_i], 1e12);
      vm.startPrank(_accounts[_i]);
      _asset.approve(address(_vault4626), type(uint256).max);
      _asset.approve(address(_vault7540), type(uint256).max);
      vm.stopPrank();
    }
  }

  // ---- actions -----------------------------------------------------------------------------------------------------

  function _mintToken(
    address _to,
    uint256 _amount
  ) internal {
    vm.prank(_minter);
    _token.mint(_to, _amount);
  }

  function _deposit4626(
    address _account,
    uint256 _assets
  ) internal {
    vm.prank(_account);
    _vault4626.deposit(_assets, _account);
  }

  /// @dev Closes the open period and settles it at par: one asset unit buys `_PAR` shares
  function _settle7540() internal {
    (,, uint256 _unclaimed) = _vault7540.dealingState();
    uint256 _nav = (_vault7540.totalSupply() + _unclaimed) / _PAR;
    vm.startPrank(_settler);
    _vault7540.closePeriod();
    _vault7540.settlePeriod(_nav, 0, _cash, address(0), type(uint256).max);
    vm.stopPrank();
  }

  /// @dev Leaves `_account` with `_assets * _PAR` shares of the class
  function _invest7540(
    address _account,
    uint256 _assets
  ) internal {
    vm.prank(_account);
    _vault7540.requestDeposit(_assets, _account, _account);
    _settle7540();
    vm.prank(_account);
    _vault7540.mint(_assets * _PAR, _account, _account);
  }

  function _requestRedeem7540(
    address _account,
    uint256 _shares
  ) internal {
    vm.prank(_account);
    _vault7540.requestRedeem(_shares, _account, _account);
  }

  function _rejected(
    bytes32 _reason
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, _reason);
  }

  function _assertTransferParity(
    address _from,
    address _to,
    uint256 _amount,
    bytes32 _expected
  ) internal {
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(_from, _to, _amount);
    assertEq(_reason, _expected, 'canTransfer reason');
    assertEq(_ok, _expected == Reasons.TRANSFER_OK);
    if (_expected != Reasons.TRANSFER_OK) vm.expectRevert(_rejected(_expected));
    vm.prank(_from);
    _token.transfer(_to, _amount);
  }
}

contract FundIntegration_Counting is FundIntegrationTest {
  function test_WhenAnInvestorHoldsAllThreeClasses_TheyCountOnceAndPositionsListEachClass() external {
    _mintToken(_alice, 10 ether);
    assertEq(_fund.holderCount(), 1);
    _deposit4626(_alice, 5e6);
    assertEq(_fund.holderCount(), 1);
    _invest7540(_alice, 7e6);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.heldClasses(_alice), 7);

    (address[] memory _tokens, uint256[] memory _balances) = _fund.positionsOf(_alice);
    assertEq(_tokens.length, 3);
    assertEq(_tokens[0], address(_token));
    assertEq(_tokens[1], address(_vault4626));
    assertEq(_tokens[2], address(_vault7540));
    assertEq(_balances[0], 10 ether);
    assertEq(_balances[1], _vault4626.balanceOf(_alice));
    assertEq(_balances[2], 7e6 * _PAR);

    _mintToken(_bob, 1 ether);
    assertEq(_fund.holderCount(), 2);
  }

  /// @dev What P27 accepts, and a redemption gate makes last longer: a queued investor is out of the count while its shares
  ///      wait in the escrow, and is counted again if they are handed back
  function test_AQueuedInvestorIsOutOfTheCountUntilHandedBack() external {
    _invest7540(_alice, 7e6);
    assertEq(_fund.holderCount(), 1);
    _requestRedeem7540(_alice, 7e6 * _PAR);
    assertEq(_fund.holderCount(), 0);

    (,, uint256 _unclaimed) = _vault7540.dealingState();
    uint256 _nav = (_vault7540.totalSupply() + _unclaimed) / _PAR;
    vm.startPrank(_settler);
    _vault7540.closePeriod();
    _vault7540.settlePeriod(_nav, 0, _cash, address(0), 1e6 * _PAR);
    vm.stopPrank();
    assertEq(_vault7540.pendingRedeemRequest(0, _alice), 6e6 * _PAR);
    assertEq(_fund.holderCount(), 0);

    vm.prank(_agent);
    _vault7540.rejectRedeemRequest(_alice);
    assertEq(_vault7540.balanceOf(_alice), 6e6 * _PAR);
    assertEq(_fund.holderCount(), 1);
  }

  function test_WhenAnInvestorLeavesEveryClass_TheCountReturnsToZeroOnlyAfterTheLastOne() external {
    _mintToken(_alice, 10 ether);
    _deposit4626(_alice, 5e6);
    _invest7540(_alice, 7e6);

    vm.prank(_burner);
    _token.burn(_alice, 10 ether);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.heldClasses(_alice), 6);

    uint256 _shares = _vault4626.balanceOf(_alice);
    vm.prank(_alice);
    _vault4626.redeem(_shares, _alice, _alice);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.heldClasses(_alice), 4);

    _requestRedeem7540(_alice, 7e6 * _PAR);
    assertEq(_fund.holderCount(), 0);
    assertEq(_fund.heldClasses(_alice), 0);
  }

  function test_WhenAMovementIsRecorded_TheFundEmitsTheRegisterEvents() external {
    vm.expectEmit(true, false, false, true, address(_fund));
    emit IFund.HolderClassesUpdated(_alice, 1);
    vm.expectEmit(false, false, false, true, address(_fund));
    emit IFund.HolderCountUpdated(1);
    _mintToken(_alice, 10 ether);
  }

  function test_WhenAnExemptTreasuryReceivesAtAFullCap_ItDoesNotCount() external {
    _mintToken(_alice, 1 ether);
    _mintToken(_bob, 1 ether);
    _mintToken(_carol, 1 ether);
    assertEq(_fund.holderCount(), 3);
    _fund.setExempt(_treasury, true);

    _mintToken(_treasury, 5 ether);
    assertEq(_fund.holderCount(), 3);
    assertEq(_fund.heldClasses(_treasury), 1);
  }

  function test_WhenAnExistingHolderIsExempted_TheCountFalls() external {
    _mintToken(_alice, 1 ether);
    _mintToken(_bob, 1 ether);
    _fund.setExempt(_bob, true);
    assertEq(_fund.holderCount(), 1);
    _fund.setExempt(_bob, false);
    assertEq(_fund.holderCount(), 2);
  }
}

contract FundIntegration_Cap is FundIntegrationTest {
  function setUp() public override {
    super.setUp();
    _fund.setHolderCap(2);
  }

  function test_WhenTheFundIsFull_ANewInvestorIsRejectedInEveryClassWithParity() external {
    _mintToken(_alice, 10 ether);
    _deposit4626(_bob, 5e6);
    assertEq(_fund.holderCount(), 2);

    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(address(0), _carol, 1);
    assertFalse(_ok);
    assertEq(_reason, Reasons.MAX_HOLDERS);
    vm.expectRevert(_rejected(Reasons.MAX_HOLDERS));
    _mintToken(_carol, 1 ether);

    assertEq(_vault4626.maxDeposit(_carol), 0);
    vm.expectRevert();
    _deposit4626(_carol, 1e6);

    vm.expectRevert(
      abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ControllerNotEligible.selector, Reasons.MAX_HOLDERS)
    );
    vm.prank(_carol);
    _vault7540.requestDeposit(1e6, _carol, _carol);

    assertEq(_fund.holderCount(), 2);
  }

  /// @dev The cap is still known to `maxDeposit` with a minimum set: the probe amount is above any minimum, so the
  ///      minimum does not hide a full fund
  function test_WhenTheFundIsFullAndAMinimumIsSet_MaxDepositIsStillZeroForANewInvestor() external {
    MinPositionRule _minRule = new MinPositionRule();
    _registry.attest(address(_minRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    IComplianceRule[] memory _list = new IComplianceRule[](4);
    _list[0] = _identityRule;
    _list[1] = _minRule;
    _list[2] = _restrictionRule;
    _list[3] = _fundRule;
    _hook.setRules(address(_vault4626), _list);
    _minRule.setMinPosition(address(_vault4626), 1e12);

    _mintToken(_alice, 10 ether);
    _deposit4626(_bob, 1e6); // 1e12 shares at the first deposit: exactly the minimum
    assertEq(_fund.holderCount(), 2);
    assertEq(_vault4626.maxDeposit(_carol), 0);
    assertEq(_vault4626.maxDeposit(_alice), type(uint256).max);
  }

  function test_WhenTheFundIsFull_AnExistingInvestorStillTakesAPositionInAnotherClass() external {
    _mintToken(_alice, 10 ether);
    _deposit4626(_bob, 5e6);
    assertEq(_fund.holderCount(), 2);

    assertEq(_vault4626.maxDeposit(_alice), type(uint256).max);
    _deposit4626(_alice, 1e6);
    _invest7540(_bob, 2e6);
    assertEq(_fund.holderCount(), 2);
    assertEq(_fund.heldClasses(_alice), 3);
    assertEq(_fund.heldClasses(_bob), 6);
  }

  function test_WhenTheSenderLeavesTheFundAtAFullCap_AWholeBalanceMoveToANewHolderIsAdmitted() external {
    _mintToken(_alice, 10 ether);
    _deposit4626(_bob, 5e6);
    assertEq(_fund.holderCount(), 2);

    _assertTransferParity(_alice, _dave, 10 ether, Reasons.TRANSFER_OK);
    assertEq(_fund.holderCount(), 2);
    assertEq(_fund.heldClasses(_alice), 0);
    assertEq(_fund.heldClasses(_dave), 1);
  }

  function test_WhenTheSenderLeavesTheFundAtAFullCap_NoEventShowsTheCountAboveTheCap() external {
    _mintToken(_alice, 10 ether);
    _deposit4626(_bob, 5e6);
    uint256 _cap = _fund.holderCap();
    assertEq(_fund.holderCount(), _cap);

    vm.recordLogs();
    vm.prank(_alice);
    _token.transfer(_dave, 10 ether);

    Vm.Log[] memory _logs = vm.getRecordedLogs();
    uint256 _counts;
    for (uint256 _i; _i < _logs.length; ++_i) {
      if (_logs[_i].topics[0] != IFund.HolderCountUpdated.selector) continue;
      assertLe(abi.decode(_logs[_i].data, (uint256)), _cap);
      ++_counts;
    }
    assertEq(_counts, 2);
    assertEq(_fund.holderCount(), _cap);
  }

  function test_WhenTheSenderKeepsAnotherClass_ThatSameMoveIsRejectedWithParity() external {
    _mintToken(_alice, 10 ether);
    _deposit4626(_alice, 5e6);
    _mintToken(_bob, 1 ether);
    assertEq(_fund.holderCount(), 2);

    _assertTransferParity(_alice, _dave, 10 ether, Reasons.MAX_HOLDERS);
    assertEq(_fund.holderCount(), 2);
  }

  function test_WhenTheSenderKeepsABalance_APartialMoveToANewHolderIsRejected() external {
    _mintToken(_alice, 10 ether);
    _mintToken(_bob, 1 ether);
    _assertTransferParity(_alice, _dave, 4 ether, Reasons.MAX_HOLDERS);
  }

  function test_WhenTheMovementIsForced_ItIsExemptFromTheCapAndStillCounted() external {
    _mintToken(_alice, 10 ether);
    _mintToken(_bob, 1 ether);
    vm.prank(_agent);
    _token.forcedTransfer(_alice, _dave, 1 ether);
    assertEq(_fund.holderCount(), 3);
    assertEq(_fund.heldClasses(_dave), 1);

    // Above the cap now: nobody new is admitted, even by a whole-balance move.
    _assertTransferParity(_dave, _carol, 1 ether, Reasons.MAX_HOLDERS);
  }

  function test_WhenAnInvestorWhoIsNotVerifiedReceives_IdentityRejectsBeforeTheFundDoes() external {
    _mintToken(_alice, 10 ether);
    _mintToken(_bob, 1 ether);
    _assertTransferParity(_alice, _eve, 1 ether, Reasons.RECEIVER_NOT_VERIFIED);
  }
}

contract FundIntegration_Registration is FundIntegrationTest {
  IntentToken internal _other;

  /// @dev A fourth class whose hook lists the fund rule, deployed but not registered
  function _deployUnregistered() internal {
    address _impl = address(new IntentToken());
    _attestImplementation(_impl);
    _other = IntentToken(
      _deployer.deploy(
        'gOTH',
        _impl,
        abi.encodeCall(
          IntentToken.initialize,
          ('Other', 'gOTH', 18, address(this), _guardian, address(_registry), address(_hook), _rules(_fundRule))
        ),
        address(_hook),
        _rules(_fundRule)
      )
    );
    _other.grantRole(_other.MINTER_ROLE(), _minter);
  }

  function test_WhenAClassIsNotRegistered_EveryMovementIsRejectedUntilItIs() external {
    _deployUnregistered();

    (bool _ok, bytes32 _reason) = _other.canTransferWithReason(address(0), _alice, 1);
    assertFalse(_ok);
    assertEq(_reason, Reasons.NOT_FUND_CLASS);
    assertFalse(_other.canReceive(_alice));
    vm.expectRevert(_rejected(Reasons.NOT_FUND_CLASS));
    vm.prank(_minter);
    _other.mint(_alice, 1 ether);

    _fund.registerClass(address(_other));
    assertTrue(_other.canReceive(_alice));
    vm.prank(_minter);
    _other.mint(_alice, 1 ether);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.heldClasses(_alice), 8);
  }

  /// @dev The cold start: a class that got a supply without the fund rule. The rule refuses to be listed again, so the
  ///      class never reaches the fund's own supply check, which `Fund.t.sol` covers on its own
  function test_WhenAClassAlreadyHasSupply_TheRuleCannotBeListedAndItCannotBeRegistered() external {
    _deployUnregistered();
    IComplianceRule[] memory _without = new IComplianceRule[](1);
    _without[0] = _identityRule;
    _hook.setRules(address(_other), _without);
    vm.prank(_minter);
    _other.mint(_alice, 1 ether);

    vm.expectRevert(abi.encodeWithSelector(IFundHoldersRule.FundHoldersRule_CountNotCurrent.selector, address(_other)));
    _hook.setRules(address(_other), _rules(_fundRule));
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_RuleNotListed.selector, address(_other), address(_fundRule)));
    _fund.registerClass(address(_other));
  }

  function test_WhenTheHookDoesNotListTheFundRule_ItCannotBeRegistered() external {
    _deployUnregistered();
    IComplianceRule[] memory _without = new IComplianceRule[](1);
    _without[0] = _identityRule;
    _hook.setRules(address(_other), _without);

    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_RuleNotListed.selector, address(_other), address(_fundRule)));
    _fund.registerClass(address(_other));
  }
}

contract FundIntegration_VaultEscrow is FundIntegrationTest {
  function test_WhenARedemptionIsRequested_TheEscrowIsNeverCountedAndTheInvestorLeavesAtTheTransfer() external {
    _invest7540(_alice, 7e6);
    assertEq(_fund.holderCount(), 1);

    _requestRedeem7540(_alice, 7e6 * _PAR);
    assertEq(_fund.holderCount(), 0);
    assertEq(_fund.heldClasses(_alice), 0);
    assertEq(_fund.heldClasses(address(_vault7540)), 0);
  }

  function test_WhenARedemptionIsSettled_TheBurnFromTheEscrowChangesNothing() external {
    _invest7540(_alice, 7e6);
    _requestRedeem7540(_alice, 7e6 * _PAR);
    _settle7540();
    assertEq(_fund.holderCount(), 0);

    vm.prank(_alice);
    _vault7540.redeem(7e6 * _PAR, _alice, _alice);
    assertEq(_fund.holderCount(), 0);
  }

  function test_WhenARejectedRedemptionReturnsSharesToAnInvestorWhoWasReplaced_TheFundCapAppliesAndRecoveryIsCounted()
    external
  {
    _fund.setHolderCap(2);
    _invest7540(_alice, 7e6);
    _mintToken(_bob, 1 ether);
    assertEq(_fund.holderCount(), 2);

    _requestRedeem7540(_alice, 7e6 * _PAR);
    assertEq(_fund.holderCount(), 1);
    _mintToken(_carol, 1 ether);
    assertEq(_fund.holderCount(), 2);

    // The return is a plain transfer, so alice is a new investor at a full cap and the reject reverts.
    vm.expectRevert(_rejected(Reasons.MAX_HOLDERS));
    vm.prank(_agent);
    _vault7540.rejectRedeemRequest(_alice);

    // The agent recovers the escrow with an enforcement move: exempt from the cap, still counted.
    vm.prank(_agent);
    _vault7540.recoverRedeemRequest(_alice, _alice);
    assertEq(_fund.holderCount(), 3);
    assertEq(_fund.heldClasses(_alice), 4);
  }

  function test_WhenARejectedRedemptionReturnsSharesWithRoomInTheFund_TheInvestorRejoins() external {
    _invest7540(_alice, 7e6);
    _requestRedeem7540(_alice, 7e6 * _PAR);
    assertEq(_fund.holderCount(), 0);

    vm.prank(_agent);
    _vault7540.rejectRedeemRequest(_alice);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.heldClasses(_alice), 4);
  }
}

contract FundIntegration_Claimable is FundIntegrationTest {
  function setUp() public override {
    super.setUp();
    _fund.setHolderCap(2);
  }

  function test_WhenAnotherClassFillsTheFundBeforeAClaim_TheClaimIsBlockedAndRecoverClaimableDeliversCounted()
    external
  {
    // alice's deposit settles while the fund has room, and she has not claimed yet.
    vm.prank(_alice);
    _vault7540.requestDeposit(7e6, _alice, _alice);
    _settle7540();
    assertEq(_fund.holderCount(), 0);

    // Two other investors fill the fund through the other two classes.
    _mintToken(_bob, 1 ether);
    _deposit4626(_carol, 1e6);
    assertEq(_fund.holderCount(), 2);

    // The claim re-runs the policy, so it is refused, and the shares stay claimable.
    vm.expectRevert(
      abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_ControllerNotEligible.selector, Reasons.MAX_HOLDERS)
    );
    vm.prank(_alice);
    _vault7540.mint(7e6 * _PAR, _alice, _alice);
    assertEq(_vault7540.claimableDepositRequest(0, _alice), 7e6);

    // The agent delivers them as an enforcement mint: exempt from the cap and still counted.
    vm.prank(_agent);
    _vault7540.recoverClaimable(_alice, _alice);
    assertEq(_vault7540.balanceOf(_alice), 7e6 * _PAR);
    assertEq(_fund.holderCount(), 3);
    assertEq(_fund.heldClasses(_alice), 4);
    assertEq(_vault7540.claimableDepositRequest(0, _alice), 0);
  }
}

contract FundIntegration_Replacement is FundIntegrationTest {
  function test_WhenTheHookIsReplacedKeepingTheRule_TheStateAndTheRecordingContinue() external {
    _mintToken(_alice, 1 ether);
    _mintToken(_bob, 1 ether);
    assertEq(_fund.holderCount(), 2);

    // A twin hook: same registry, so the attested codehash matches. Different rule order.
    IComplianceRule[] memory _reordered = new IComplianceRule[](3);
    _reordered[0] = _fundRule;
    _reordered[1] = _identityRule;
    _reordered[2] = _restrictionRule;
    ComplianceHook _twin = new ComplianceHook(_registry);
    assertEq(address(_twin).codehash, address(_hook).codehash);
    _twin.setRules(address(_token), _reordered);
    _token.installPolicy(address(_twin), '');
    assertEq(_fund.holderCount(), 2);

    _mintToken(_carol, 1 ether);
    assertEq(_fund.holderCount(), 3);
    assertEq(_fund.heldClasses(_carol), 1);
  }

  function test_WhenTheRuleIsReplaced_TheCountSurvivesAndTheWindowBetweenTheTwoStepsFailsClosedWithParity() external {
    _mintToken(_alice, 1 ether);
    _mintToken(_bob, 1 ether);
    assertEq(_fund.holderCount(), 2);

    // A second instance with the same fund has the same codehash, so the registry already attests it.
    FundHoldersRule _next = new FundHoldersRule(_fund);
    assertEq(address(_next).codehash, address(_fundRule).codehash);
    _fund.setRule(address(_next));
    assertEq(_fund.holderCount(), 2);

    // The hooks still list the old rule, which is no longer the fund's. It rejects every movement, the ones that would
    // not touch the fund's state too, and the pre-flight says the same as the write: nothing drifts, nothing lies.
    assertEq(_fundRule.check(_ctxFor(address(_token), _carol)), Reasons.NOT_FUND_CLASS);
    (bool _ok, bytes32 _reason) = _token.canTransferWithReason(address(0), _carol, 1);
    assertFalse(_ok);
    assertEq(_reason, Reasons.NOT_FUND_CLASS);
    vm.expectRevert(_rejected(Reasons.NOT_FUND_CLASS));
    _mintToken(_carol, 1 ether);
    // A transfer between two existing holders needs no write to the fund, and is refused all the same.
    _assertTransferParity(_alice, _bob, 0.5 ether, Reasons.NOT_FUND_CLASS);
    assertFalse(_token.canReceive(_alice));
    assertEq(_fund.holderCount(), 2);

    // The monitor sees the window too: every class is broken until its hook lists the new rule, one at a time.
    assertFalse(_fund.isClassIntact(address(_token)));
    assertEq(_fund.firstBrokenClass(), address(_token));
    _hook.setRules(address(_token), _rules(_next));
    assertTrue(_fund.isClassIntact(address(_token)));
    assertEq(_fund.firstBrokenClass(), address(_vault4626));
    _hook.setRules(address(_vault4626), _rules(_next));
    assertEq(_fund.firstBrokenClass(), address(_vault7540));
    _hook.setRules(address(_vault7540), _rules(_next));
    assertEq(_fund.firstBrokenClass(), address(0));
    _mintToken(_carol, 1 ether);
    assertEq(_fund.holderCount(), 3);
    _assertTransferParity(_alice, _bob, 0.5 ether, Reasons.TRANSFER_OK);
  }

  function _ctxFor(
    address _tokenAddress,
    address _receiver
  ) internal view returns (IERC8473Policy.TransferContext memory _context) {
    _context = IERC8473Policy.TransferContext({
      token: _tokenAddress,
      from: address(0),
      to: _receiver,
      tokenId: 0,
      amount: 1 ether,
      operator: _minter,
      kind: IERC8473Policy.TransferKind.MINT,
      data: abi.encode(uint256(0), IERC20(_tokenAddress).balanceOf(_receiver))
    });
  }
}

/// @notice The monitor against a real hook and real classes (`Fund.isClassIntact` and `firstBrokenClass`)
contract FundIntegration_Integrity is FundIntegrationTest {
  function test_WhenTheStackIsDeployed_EveryClassIsIntact() external view {
    assertTrue(_fund.isClassIntact(address(_token)));
    assertTrue(_fund.isClassIntact(address(_vault4626)));
    assertTrue(_fund.isClassIntact(address(_vault7540)));
    assertEq(_fund.firstBrokenClass(), address(0));
  }

  /// @dev The hazard the runbook forbids: a rule list without the fund rule is accepted by the hook, and the class is
  ///      un-capped. Nothing in the hook can know; the fund can say so
  function test_WhenAClassDropsTheFundRule_ItIsUncappedAndTheMonitorNamesIt() external {
    IComplianceRule[] memory _without = new IComplianceRule[](2);
    _without[0] = _identityRule;
    _without[1] = _restrictionRule;
    _hook.setRules(address(_vault4626), _without);

    assertFalse(_fund.isClassIntact(address(_vault4626)));
    assertTrue(_fund.isClassIntact(address(_token)));
    assertEq(_fund.firstBrokenClass(), address(_vault4626));

    _hook.setRules(address(_vault4626), _rules(_fundRule));
    assertTrue(_fund.isClassIntact(address(_vault4626)));
    assertEq(_fund.firstBrokenClass(), address(0));
  }

  /// @dev With holders, the same two calls no longer bring the rule back: the movements in between were not counted
  function test_WhenAClassWithHoldersDropsTheFundRule_ItCannotTakeItBack() external {
    _mintToken(_alice, 1 ether);
    IComplianceRule[] memory _without = new IComplianceRule[](2);
    _without[0] = _identityRule;
    _without[1] = _restrictionRule;
    _hook.setRules(address(_token), _without);
    _mintToken(_bob, 1 ether);
    assertEq(_fund.holderCount(), 1, 'the uncounted movement');

    vm.expectRevert(abi.encodeWithSelector(IFundHoldersRule.FundHoldersRule_CountNotCurrent.selector, address(_token)));
    _hook.setRules(address(_token), _rules(_fundRule));
    assertFalse(_fund.isClassIntact(address(_token)));
  }

  /// @dev A hook swap that keeps the rules keeps the class intact, and a swap to a hook without them breaks it
  function test_WhenTheHookIsReplacedWithoutTheRule_TheClassIsBroken() external {
    ComplianceHook _twin = new ComplianceHook(_registry);
    IComplianceRule[] memory _without = new IComplianceRule[](1);
    _without[0] = _identityRule;
    _twin.setRules(address(_token), _without);
    _token.installPolicy(address(_twin), '');
    assertFalse(_fund.isClassIntact(address(_token)));
    assertEq(_fund.firstBrokenClass(), address(_token));
  }
}
