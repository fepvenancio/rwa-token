// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IFund} from 'interfaces/IFund.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {Fund} from 'contracts/fund/Fund.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {FundHoldersRule} from 'contracts/hooks/rules/FundHoldersRule.sol';
import {IdentityRule} from 'contracts/hooks/rules/IdentityRule.sol';
import {LockupRule} from 'contracts/hooks/rules/LockupRule.sol';
import {MaxHoldersRule} from 'contracts/hooks/rules/MaxHoldersRule.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {MockIdentityRegistry} from 'contracts/test/MockIdentityRegistry.sol';
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

  PolicyRegistry internal _registry;
  MockIdentityRegistry internal _identity;
  MockAsset internal _asset;
  ProxyDeployer internal _deployer;
  Fund internal _fund;
  FundHoldersRule internal _fundRule;
  IdentityRule internal _identityRule;
  LockupRule internal _lockupRule;
  MaxHoldersRule internal _maxHoldersRule;

  IntentToken internal _token;
  Gated4626Vault internal _vault4626;
  Gated7540Vault internal _vault7540;
  ComplianceHook[3] internal _hooks;

  address internal _guardian = makeAddr('guardian');
  address internal _minter = makeAddr('minter');
  address internal _burner = makeAddr('burner');
  address internal _agent = makeAddr('agent');
  address internal _fulfiller = makeAddr('fulfiller');
  address internal _custody = makeAddr('custody');
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
    _deployer = new ProxyDeployer(address(this));

    _identityRule = new IdentityRule(IIdentityRegistry(address(_identity)));
    _lockupRule = new LockupRule();
    _maxHoldersRule = new MaxHoldersRule();
    _fund = new Fund(address(this), IPolicyRegistry(address(_registry)));
    _fundRule = new FundHoldersRule(_fund);
    _registry.attest(address(_identityRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_lockupRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_maxHoldersRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_fundRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _fund.setRule(address(_fundRule));
    _fund.setHolderCap(3);

    _deployToken();
    _deploy4626();
    _deploy7540();
    _configure();
  }

  function _rules(
    FundHoldersRule _last
  ) internal view returns (IComplianceRule[] memory _list) {
    _list = new IComplianceRule[](4);
    _list[0] = _identityRule;
    _list[1] = _lockupRule;
    _list[2] = _maxHoldersRule;
    _list[3] = _last;
  }

  /// @dev Deployment order: implementation, hook bound to the predicted proxy, attestations, proxy
  function _hookAndAttest(
    string memory _symbol,
    address _impl,
    uint256 _slot
  ) internal returns (address _predicted) {
    _predicted = _deployer.predict(_symbol, _impl);
    _hooks[_slot] = new ComplianceHook(address(this), _registry, _predicted, _rules(_fundRule));
    _registry.attest(address(_hooks[_slot]).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _registry.attest(_impl.codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
  }

  function _deployToken() internal {
    address _impl = address(new IntentToken());
    _hookAndAttest('gINT', _impl, 0);
    _token = IntentToken(
      _deployer.deploy(
        'gINT',
        _impl,
        abi.encodeCall(
          IntentToken.initialize,
          ('Class Token', 'gINT', address(this), _guardian, address(_registry), address(_hooks[0]))
        ),
        address(_hooks[0])
      )
    );
  }

  function _deploy4626() internal {
    address _impl = address(new Gated4626Vault());
    _hookAndAttest('g4626', _impl, 1);
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
            address(_hooks[1])
          )
        ),
        address(_hooks[1])
      )
    );
  }

  function _deploy7540() internal {
    address _impl = address(new Gated7540Vault());
    _hookAndAttest('g7540', _impl, 2);
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
            address(_hooks[2]),
            _custody
          )
        ),
        address(_hooks[2])
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
    _vault7540.grantRole(_vault7540.FULFILLER_ROLE(), _fulfiller);

    // The class caps stay out of the way, so every rejection below comes from the fund.
    _maxHoldersRule.setCap(address(_token), 100);
    _maxHoldersRule.setCap(address(_vault4626), 100);
    _maxHoldersRule.setCap(address(_vault7540), 100);
    // The 7540 escrow is a verified, holder-exempt account at the class level.
    _identity.set(address(_vault7540), true);
    _maxHoldersRule.setExemptHolder(address(_vault7540), address(_vault7540), true);

    address[6] memory _accounts = [_alice, _bob, _carol, _dave, _treasury, _fulfiller];
    for (uint256 _i; _i < _accounts.length; ++_i) {
      if (_accounts[_i] != _fulfiller) _identity.set(_accounts[_i], true);
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

  function _invest7540(
    address _account,
    uint256 _assets
  ) internal {
    vm.prank(_account);
    _vault7540.requestDeposit(_assets, _account, _account);
    vm.prank(_fulfiller);
    _vault7540.fulfillDeposit(_account, _assets, _assets);
    vm.prank(_account);
    _vault7540.mint(_assets, _account, _account);
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
    _revertData = abi.encodeWithSelector(IPolicyGated.PolicyGated_TransferRejected.selector, _reason);
  }

  function _assertTransferParity(
    address _from,
    address _to,
    uint256 _amount,
    bytes32 _expected
  ) internal {
    (bool _ok, bytes32 _reason) = _token.canTransfer(_from, _to, _amount);
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
    assertEq(_balances[2], 7e6);

    _mintToken(_bob, 1 ether);
    assertEq(_fund.holderCount(), 2);
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

    _requestRedeem7540(_alice, 7e6);
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

    (bool _ok, bytes32 _reason) = _token.canTransfer(address(0), _carol, 1);
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
    address _predicted = _deployer.predict('gOTH', _impl);
    ComplianceHook _hook = new ComplianceHook(address(this), _registry, _predicted, _rules(_fundRule));
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _registry.attest(_impl.codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _other = IntentToken(
      _deployer.deploy(
        'gOTH',
        _impl,
        abi.encodeCall(
          IntentToken.initialize, ('Other', 'gOTH', address(this), _guardian, address(_registry), address(_hook))
        ),
        address(_hook)
      )
    );
    _other.grantRole(_other.MINTER_ROLE(), _minter);
    _maxHoldersRule.setCap(address(_other), 100);
  }

  function test_WhenAClassIsNotRegistered_EveryMovementIsRejectedUntilItIs() external {
    _deployUnregistered();

    (bool _ok, bytes32 _reason) = _other.canTransfer(address(0), _alice, 1);
    assertFalse(_ok);
    assertEq(_reason, Reasons.NOT_FUND_CLASS);
    assertFalse(_other.isUserAllowed(_alice));
    vm.expectRevert(_rejected(Reasons.NOT_FUND_CLASS));
    vm.prank(_minter);
    _other.mint(_alice, 1 ether);

    _fund.registerClass(address(_other));
    assertTrue(_other.isUserAllowed(_alice));
    vm.prank(_minter);
    _other.mint(_alice, 1 ether);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.heldClasses(_alice), 8);
  }

  function test_WhenAClassAlreadyHasSupply_ItCannotBeRegistered() external {
    _deployUnregistered();
    // Take the fund rule out of play to mint, which is exactly the cold start the supply check exists to refuse.
    IComplianceRule[] memory _without = new IComplianceRule[](2);
    _without[0] = _identityRule;
    _without[1] = _maxHoldersRule;
    ComplianceHook _hook = ComplianceHook(IPolicyGated(address(_other)).policyHook());
    _hook.setRules(_without);
    vm.prank(_minter);
    _other.mint(_alice, 1 ether);
    _hook.setRules(_rules(_fundRule));

    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_ClassHasSupply.selector, address(_other), 1 ether));
    _fund.registerClass(address(_other));
  }

  function test_WhenTheHookDoesNotListTheFundRule_ItCannotBeRegistered() external {
    _deployUnregistered();
    IComplianceRule[] memory _without = new IComplianceRule[](2);
    _without[0] = _identityRule;
    _without[1] = _maxHoldersRule;
    ComplianceHook(IPolicyGated(address(_other)).policyHook()).setRules(_without);

    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_RuleNotListed.selector, address(_other), address(_fundRule)));
    _fund.registerClass(address(_other));
  }
}

contract FundIntegration_VaultEscrow is FundIntegrationTest {
  function test_WhenARedemptionIsRequested_TheEscrowIsNeverCountedAndTheInvestorLeavesAtTheTransfer() external {
    _invest7540(_alice, 7e6);
    assertEq(_fund.holderCount(), 1);

    _requestRedeem7540(_alice, 7e6);
    assertEq(_fund.holderCount(), 0);
    assertEq(_fund.heldClasses(_alice), 0);
    assertEq(_fund.heldClasses(address(_vault7540)), 0);
  }

  function test_WhenARedemptionIsFulfilled_TheBurnFromTheEscrowChangesNothing() external {
    _invest7540(_alice, 7e6);
    _requestRedeem7540(_alice, 7e6);
    vm.prank(_fulfiller);
    _vault7540.fulfillRedeem(_alice, 7e6, 7e6);
    assertEq(_fund.holderCount(), 0);

    vm.prank(_alice);
    _vault7540.redeem(7e6, _alice, _alice);
    assertEq(_fund.holderCount(), 0);
  }

  function test_WhenARejectedRedemptionReturnsSharesToAnInvestorWhoWasReplaced_TheFundCapAppliesAndRecoveryIsCounted()
    external
  {
    _fund.setHolderCap(2);
    _invest7540(_alice, 7e6);
    _mintToken(_bob, 1 ether);
    assertEq(_fund.holderCount(), 2);

    _requestRedeem7540(_alice, 7e6);
    assertEq(_fund.holderCount(), 1);
    _mintToken(_carol, 1 ether);
    assertEq(_fund.holderCount(), 2);

    // The return is a plain transfer, so alice is a new investor at a full cap and the reject reverts (owner decision M-2).
    vm.expectRevert(_rejected(Reasons.MAX_HOLDERS));
    vm.prank(_fulfiller);
    _vault7540.rejectRedeemRequest(_alice);

    // The agent recovers the escrow with an enforcement move: exempt from the cap, still counted.
    vm.prank(_agent);
    _vault7540.recoverRedeemRequest(_alice, _alice);
    assertEq(_fund.holderCount(), 3);
    assertEq(_fund.heldClasses(_alice), 4);
  }

  function test_WhenARejectedRedemptionReturnsSharesWithRoomInTheFund_TheInvestorRejoins() external {
    _invest7540(_alice, 7e6);
    _requestRedeem7540(_alice, 7e6);
    assertEq(_fund.holderCount(), 0);

    vm.prank(_fulfiller);
    _vault7540.rejectRedeemRequest(_alice);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.heldClasses(_alice), 4);
  }
}

contract FundIntegration_Replacement is FundIntegrationTest {
  function test_WhenTheHookIsReplacedKeepingTheRule_TheStateAndTheRecordingContinue() external {
    _mintToken(_alice, 1 ether);
    _mintToken(_bob, 1 ether);
    assertEq(_fund.holderCount(), 2);

    // A twin hook: same admin, registry and token, so the attested codehash matches. Different rule order.
    IComplianceRule[] memory _reordered = new IComplianceRule[](4);
    _reordered[0] = _fundRule;
    _reordered[1] = _identityRule;
    _reordered[2] = _lockupRule;
    _reordered[3] = _maxHoldersRule;
    ComplianceHook _twin = new ComplianceHook(address(this), _registry, address(_token), _reordered);
    assertEq(address(_twin).codehash, address(_hooks[0]).codehash);
    _token.setPolicyHook(address(_twin));
    assertEq(_fund.holderCount(), 2);

    _mintToken(_carol, 1 ether);
    assertEq(_fund.holderCount(), 3);
    assertEq(_fund.heldClasses(_carol), 1);
  }

  function test_WhenTheRuleIsReplaced_TheCountSurvivesAndTheWindowBetweenTheTwoStepsFailsClosed() external {
    _mintToken(_alice, 1 ether);
    _mintToken(_bob, 1 ether);
    assertEq(_fund.holderCount(), 2);

    // A second instance with the same fund has the same codehash, so the registry already attests it.
    FundHoldersRule _next = new FundHoldersRule(_fund);
    assertEq(address(_next).codehash, address(_fundRule).codehash);
    _fund.setRule(address(_next));
    assertEq(_fund.holderCount(), 2);

    // The hooks still list the old rule. Its pre-flight says yes, and its `after_` is refused by the fund, so the
    // movement reverts: the state cannot drift. In production both steps go in one timelock batch.
    assertEq(_fundRule.check(_ctxFor(address(_token), _carol)), Reasons.TRANSFER_OK);
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_OnlyRule.selector, address(_fundRule)));
    _mintToken(_carol, 1 ether);

    for (uint256 _i; _i < 3; ++_i) {
      _hooks[_i].setRules(_rules(_next));
    }
    _mintToken(_carol, 1 ether);
    assertEq(_fund.holderCount(), 3);
  }

  function _ctxFor(
    address _tokenAddress,
    address _receiver
  ) internal view returns (IPolicyHook.TransferContext memory _context) {
    _context = IPolicyHook.TransferContext({
      token: _tokenAddress,
      from: address(0),
      to: _receiver,
      id: 0,
      amount: 1 ether,
      operator: _minter,
      kind: IPolicyHook.TransferKind.MINT,
      ref: bytes32(0),
      deadline: 0,
      extra: ''
    });
  }
}
