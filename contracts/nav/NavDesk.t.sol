// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {Test} from 'forge-std/Test.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {INavDesk} from 'interfaces/INavDesk.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {Quals} from 'interfaces/Quals.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {CredentialRule} from 'contracts/hooks/rules/CredentialRule.sol';
import {CredentialRegistry} from 'contracts/identity/CredentialRegistry.sol';
import {NavDesk} from 'contracts/nav/NavDesk.sol';
import {Portfolio} from 'contracts/portfolio/Portfolio.sol';
import {MockAdapter} from 'contracts/test/MockAdapter.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';

/// @notice A real vault behind a real hook, with a desk holding SETTLER_ROLE. This test contract is the vault's admin and
///         the registries' attester
abstract contract NavDeskTest is Test {
  uint256 internal constant _NOW = 1_792_198_800;
  uint256 internal constant _LENGTH = 1 days;
  uint256 internal constant _COOLDOWN = 2 hours;
  uint256 internal constant _MAX_AGE = 3 days;
  uint256 internal constant _PAR = 1e6;
  bytes32 internal constant _REPORT = keccak256('the NAV pack');

  PolicyRegistry internal _registry;
  CredentialRegistry internal _creds;
  CredentialRule internal _rule;
  ComplianceHook internal _hook;
  MockAsset internal _asset;
  Gated7540Vault internal _vault;
  NavDesk internal _desk;

  address internal _guardian = makeAddr('guardian');
  address internal _agent = makeAddr('agent');
  address internal _reporter = makeAddr('reporter');
  address internal _checker = makeAddr('checker');
  address internal _custodian = makeAddr('custodian');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');
  address internal _stranger = makeAddr('stranger');

  function setUp() public virtual {
    vm.warp(_NOW);
    _registry = new PolicyRegistry(address(this), address(this));
    _creds = new CredentialRegistry(address(this), _guardian);
    _creds.addAttester(address(this), type(uint32).max);
    _rule = new CredentialRule(_creds);
    _registry.attest(address(_rule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _hook = new ComplianceHook(_registry);
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _asset = new MockAsset(6);

    Gated7540Vault _impl = new Gated7540Vault();
    _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    IComplianceRule[] memory _rules = new IComplianceRule[](1);
    _rules[0] = _rule;
    ProxyDeployer _deployer = new ProxyDeployer(address(this), _registry);
    _vault = Gated7540Vault(
      _deployer.deploy(
        'gFUND',
        address(_impl),
        abi.encodeCall(
          Gated7540Vault.initialize,
          (
            IERC20(address(_asset)),
            'Gated Fund',
            'gFUND',
            address(this),
            _guardian,
            address(_registry),
            address(_hook),
            _rules
          )
        ),
        address(_hook),
        _rules
      )
    );
    _rule.setPolicy(address(_vault), Quals.KYC, 0, 0, 1);
    _creds.set(_alice, uint64(block.timestamp + 3650 days), Quals.KYC, 756);
    _creds.set(_bob, uint64(block.timestamp + 3650 days), Quals.KYC, 756);

    _desk = new NavDesk(address(_vault), _custodian, _LENGTH, _COOLDOWN, _MAX_AGE);
    _vault.grantRole(_vault.SETTLER_ROLE(), address(_desk));
    _vault.grantRole(_vault.AGENT_ROLE(), _agent);
    _vault.grantRole(_desk.REPORTER_ROLE(), _reporter);
    _vault.grantRole(_desk.CHECKER_ROLE(), _checker);

    address[3] memory _accounts = [_alice, _bob, _custodian];
    for (uint256 _i; _i < 3; ++_i) {
      _asset.mint(_accounts[_i], 1e15);
      vm.prank(_accounts[_i]);
      _asset.approve(address(_vault), type(uint256).max);
    }
  }

  function _unauthorized(
    address _caller
  ) internal pure returns (bytes memory _data) {
    _data = abi.encodeWithSelector(INavDesk.NavDesk_Unauthorized.selector, _caller);
  }

  function _request(
    address _who,
    uint256 _assets
  ) internal {
    vm.prank(_who);
    _vault.requestDeposit(_assets, _who, _who);
  }

  function _close() internal {
    vm.warp(_desk.lastCutoff() + _LENGTH);
    _desk.closePeriod();
  }

  function _propose(
    uint256 _reported
  ) internal {
    vm.prank(_reporter);
    _desk.propose(_reported, _REPORT, block.timestamp, 0);
  }

  function _hash() internal view returns (bytes32 _proposalHash) {
    _proposalHash = _desk.hashOf(_desk.proposal());
  }

  function _accept() internal {
    bytes32 _proposalHash = _hash();
    vm.prank(_checker);
    _desk.accept(_proposalHash);
  }

  /// @dev A whole cycle at `_reported`
  function _deal(
    uint256 _reported
  ) internal {
    _close();
    _propose(_reported);
    _accept();
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();
  }
}

contract NavDesk_Construction is NavDeskTest {
  function test_ItStartsWithTheSettings() external view {
    assertEq(_desk.VAULT(), address(_vault));
    assertEq(_desk.portfolio(), address(0));
    assertEq(_desk.custodianAccount(), _custodian);
    assertEq(_desk.periodLength(), _LENGTH);
    assertEq(_desk.cooldown(), _COOLDOWN);
    assertEq(_desk.maxReportAge(), _MAX_AGE);
    assertEq(_desk.lastCutoff(), _NOW);
    assertTrue(_desk.isWired());
  }

  function test_WhenAValueIsZero_ItReverts() external {
    vm.expectRevert(INavDesk.NavDesk_ZeroValue.selector);
    new NavDesk(address(0), _custodian, _LENGTH, _COOLDOWN, _MAX_AGE);
    vm.expectRevert(INavDesk.NavDesk_ZeroValue.selector);
    new NavDesk(address(_vault), _custodian, 0, _COOLDOWN, _MAX_AGE);
    vm.expectRevert(INavDesk.NavDesk_ZeroValue.selector);
    new NavDesk(address(_vault), _custodian, _LENGTH, _COOLDOWN, 0);
  }

  /// @dev A report younger than the cooldown could never execute, so every price would go stale first
  function test_WhenTheMaximumAgeIsBelowTheCooldown_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(INavDesk.NavDesk_ReportAgeBelowCooldown.selector, 2 hours - 1, 2 hours));
    new NavDesk(address(_vault), _custodian, _LENGTH, 2 hours, 2 hours - 1);
    new NavDesk(address(_vault), _custodian, _LENGTH, 2 hours, 2 hours);
  }

  function test_WhenTheCooldownIsOutOfBounds_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(INavDesk.NavDesk_InvalidCooldown.selector, 1 hours - 1));
    new NavDesk(address(_vault), _custodian, _LENGTH, 1 hours - 1, _MAX_AGE);
    vm.expectRevert(abi.encodeWithSelector(INavDesk.NavDesk_InvalidCooldown.selector, 3 days + 1));
    new NavDesk(address(_vault), _custodian, _LENGTH, 3 days + 1, _MAX_AGE);
    new NavDesk(address(_vault), _custodian, _LENGTH, 1 hours, _MAX_AGE);
    new NavDesk(address(_vault), _custodian, _LENGTH, 3 days, _MAX_AGE);
  }

  function test_WhenItDoesNotHoldTheRole_ItIsNotWired() external {
    _vault.revokeRole(_vault.SETTLER_ROLE(), address(_desk));
    assertFalse(_desk.isWired());
  }
}

contract NavDesk_ClosePeriod is NavDeskTest {
  function test_BeforeThePeriodIsOver_NobodyCanClose() external {
    vm.warp(_NOW + _LENGTH - 1);
    vm.expectRevert(INavDesk.NavDesk_PeriodNotOver.selector);
    _desk.closePeriod();
  }

  function testFuzz_OnceThePeriodIsOver_AnyoneCanClose(
    address _caller
  ) external {
    vm.warp(_NOW + _LENGTH);
    vm.expectEmit(address(_desk));
    emit INavDesk.CutOff(_NOW + _LENGTH);
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.PeriodClosed(1);
    vm.prank(_caller);
    _desk.closePeriod();
    assertEq(_desk.lastCutoff(), _NOW + _LENGTH);
  }

  function test_WhenAnEarlierPeriodIsUnsettled_ItReverts() external {
    _close();
    vm.warp(block.timestamp + _LENGTH);
    vm.expectRevert(abi.encodeWithSelector(IGated7540Vault.Gated7540Vault_PeriodUnsettled.selector, 1));
    _desk.closePeriod();
  }
}

contract NavDesk_Propose is NavDeskTest {
  function setUp() public override {
    super.setUp();
    _request(_alice, 1000);
  }

  function testFuzz_OnlyTheReporterProposes(
    address _caller
  ) external {
    if (_caller == _reporter) _caller = _stranger;
    _close();
    uint256 _asOf = block.timestamp;
    vm.expectRevert(_unauthorized(_caller));
    vm.prank(_caller);
    _desk.propose(1, _REPORT, _asOf, 0);
  }

  function test_ARevokedReporterStopsAtOnce() external {
    _close();
    _vault.revokeRole(_desk.REPORTER_ROLE(), _reporter);
    uint256 _asOf = block.timestamp;
    vm.expectRevert(_unauthorized(_reporter));
    vm.prank(_reporter);
    _desk.propose(1, _REPORT, _asOf, 0);
  }

  function test_WithNoClosedPeriod_ItReverts() external {
    vm.expectRevert(INavDesk.NavDesk_NoClosedPeriod.selector);
    vm.prank(_reporter);
    _desk.propose(1, _REPORT, _NOW, 0);
  }

  function test_AReportAtExactlyTheCutOffIsAccepted() external {
    _close();
    uint256 _cutoff = _desk.lastCutoff();
    vm.warp(_cutoff + 1 hours);
    vm.prank(_reporter);
    _desk.propose(1, _REPORT, _cutoff, 0);
    assertEq(_desk.proposal().asOf, _cutoff);
  }

  function test_AReportBeforeTheCutOffIsRefused() external {
    _close();
    uint256 _before = _desk.lastCutoff() - 1;
    vm.expectRevert(INavDesk.NavDesk_ReportOutOfWindow.selector);
    vm.prank(_reporter);
    _desk.propose(1, _REPORT, _before, 0);
  }

  function test_AReportFromTheFutureIsRefused() external {
    _close();
    uint256 _future = block.timestamp + 1;
    vm.expectRevert(INavDesk.NavDesk_ReportOutOfWindow.selector);
    vm.prank(_reporter);
    _desk.propose(1, _REPORT, _future, 0);
  }

  function test_OneAtATime() external {
    _close();
    _propose(1);
    uint256 _asOf = block.timestamp;
    vm.expectRevert(INavDesk.NavDesk_ProposalPending.selector);
    vm.prank(_reporter);
    _desk.propose(2, _REPORT, _asOf, 0);
  }

  function test_WithNoCashAccount_ItReverts() external {
    NavDesk _noCash = new NavDesk(address(_vault), address(0), _LENGTH, _COOLDOWN, _MAX_AGE);
    _vault.grantRole(_vault.SETTLER_ROLE(), address(_noCash));
    vm.warp(block.timestamp + _LENGTH);
    _noCash.closePeriod();
    uint256 _asOf = block.timestamp;
    vm.expectRevert(INavDesk.NavDesk_NoCashAccount.selector);
    vm.prank(_reporter);
    _noCash.propose(1, _REPORT, _asOf, 0);
  }

  function test_WithNoPortfolio_TheMovesMustBeZero() external {
    _close();
    uint256 _asOf = block.timestamp;
    vm.expectRevert(abi.encodeWithSelector(INavDesk.NavDesk_MovesChanged.selector, 1, 0));
    vm.prank(_reporter);
    _desk.propose(1, _REPORT, _asOf, 1);
  }

  function test_AValueOfZeroIsFineWithNoShares() external {
    _close();
    _propose(0);
    assertEq(_desk.proposal().nav, 0);
  }

  function test_AValueOfZeroIsRefusedWhileSharesExist() external {
    _deal(0);
    vm.prank(_alice);
    _vault.mint(1000 * _PAR, _alice, _alice);
    _close();
    uint256 _asOf = block.timestamp;
    vm.expectRevert(INavDesk.NavDesk_ZeroNav.selector);
    vm.prank(_reporter);
    _desk.propose(0, _REPORT, _asOf, 0);
  }

  function test_AValueOfZeroIsRefusedWhileOnlyUnclaimedSharesExist() external {
    _deal(0); // alice has not claimed
    _close();
    uint256 _asOf = block.timestamp;
    vm.expectRevert(INavDesk.NavDesk_ZeroNav.selector);
    vm.prank(_reporter);
    _desk.propose(0, _REPORT, _asOf, 0);
  }

  function test_ItFreezesTheProposalAndEmits() external {
    _close();
    INavDesk.Proposal memory _expected = INavDesk.Proposal({
      period: 1,
      proposedAt: uint64(block.timestamp),
      asOf: uint64(block.timestamp),
      acceptedAt: 0,
      proposer: _reporter,
      nav: 500,
      fee: 0,
      mark: 0,
      reportHash: _REPORT,
      cash: _custodian,
      feeRecipient: address(0)
    });
    vm.expectEmit(address(_desk));
    emit INavDesk.ProposalMade(_desk.hashOf(_expected), 1, 500, 0, 500, 0, _REPORT, block.timestamp);
    _propose(500);
    assertEq(_hash(), _desk.hashOf(_expected));
    assertEq(_desk.proposal().proposer, _reporter);
    assertEq(_desk.proposal().cash, _custodian);
  }
}

contract NavDesk_Accept is NavDeskTest {
  bytes32 internal _proposalHash;

  function setUp() public override {
    super.setUp();
    _request(_alice, 1000);
    _close();
    _propose(0);
    _proposalHash = _hash();
  }

  function testFuzz_OnlyTheCheckerAccepts(
    address _caller
  ) external {
    if (_caller == _checker) _caller = _stranger;
    vm.expectRevert(_unauthorized(_caller));
    vm.prank(_caller);
    _desk.accept(_proposalHash);
  }

  function test_TheProposerCannotAcceptItsOwn() external {
    _vault.grantRole(_desk.CHECKER_ROLE(), _reporter);
    vm.expectRevert(INavDesk.NavDesk_SelfAccept.selector);
    vm.prank(_reporter);
    _desk.accept(_proposalHash);
  }

  function test_AnotherHashIsRefused() external {
    vm.expectRevert(INavDesk.NavDesk_ProposalMismatch.selector);
    vm.prank(_checker);
    _desk.accept(bytes32(uint256(_proposalHash) + 1));
  }

  function test_WithNothingOnTheTable_ItReverts() external {
    vm.prank(_guardian);
    _desk.cancel();
    vm.expectRevert(INavDesk.NavDesk_NoProposal.selector);
    vm.prank(_checker);
    _desk.accept(_proposalHash);
  }

  function test_AcceptingTwiceReverts() external {
    vm.prank(_checker);
    _desk.accept(_proposalHash);
    vm.expectRevert(INavDesk.NavDesk_AcceptanceWrong.selector);
    vm.prank(_checker);
    _desk.accept(_proposalHash);
  }

  function test_ItRecordsWhenAndEmits() external {
    vm.expectEmit(address(_desk));
    emit INavDesk.ProposalAccepted(_proposalHash, _checker);
    vm.prank(_checker);
    _desk.accept(_proposalHash);
    assertEq(_desk.proposal().acceptedAt, block.timestamp);
  }

  /// @dev A replaced proposal cannot pick up an approval meant for another
  function test_AnApprovalDoesNotCarryOverToAReplacement() external {
    vm.prank(_checker);
    _desk.accept(_proposalHash);
    vm.prank(_checker);
    _desk.cancel();

    _propose(999);
    assertEq(_desk.proposal().acceptedAt, 0);
    vm.expectRevert(INavDesk.NavDesk_ProposalMismatch.selector);
    vm.prank(_checker);
    _desk.accept(_proposalHash);
    vm.expectRevert(INavDesk.NavDesk_AcceptanceWrong.selector);
    _desk.execute();
  }

  function test_TheHashCoversEveryFrozenField() external view {
    INavDesk.Proposal memory _p = _desk.proposal();
    bytes32 _base = _desk.hashOf(_p);
    INavDesk.Proposal memory _q = _desk.proposal();
    _q.period += 1;
    assertTrue(_desk.hashOf(_q) != _base, 'period');
    _q = _desk.proposal();
    _q.nav += 1;
    assertTrue(_desk.hashOf(_q) != _base, 'nav');
    _q = _desk.proposal();
    _q.fee += 1;
    assertTrue(_desk.hashOf(_q) != _base, 'fee');
    _q = _desk.proposal();
    _q.mark += 1;
    assertTrue(_desk.hashOf(_q) != _base, 'mark');
    _q = _desk.proposal();
    _q.reportHash = bytes32(uint256(_q.reportHash) + 1);
    assertTrue(_desk.hashOf(_q) != _base, 'report');
    _q = _desk.proposal();
    _q.cash = address(1);
    assertTrue(_desk.hashOf(_q) != _base, 'cash');
    _q = _desk.proposal();
    _q.feeRecipient = address(1);
    assertTrue(_desk.hashOf(_q) != _base, 'fee recipient');
  }
}

contract NavDesk_Cancel is NavDeskTest {
  function setUp() public override {
    super.setUp();
    _request(_alice, 1000);
    _close();
    _propose(0);
  }

  function test_TheGuardianCancels() external {
    bytes32 _proposalHash = _hash();
    vm.expectEmit(address(_desk));
    emit INavDesk.ProposalCancelled(_proposalHash, _guardian);
    vm.prank(_guardian);
    _desk.cancel();
    assertEq(_desk.proposal().period, 0);
  }

  function test_TheCheckerCancels() external {
    vm.prank(_checker);
    _desk.cancel();
    assertEq(_desk.proposal().period, 0);
  }

  function testFuzz_NobodyElseCancels(
    address _caller
  ) external {
    if (_caller == _guardian || _caller == _checker) _caller = _stranger;
    vm.expectRevert(_unauthorized(_caller));
    vm.prank(_caller);
    _desk.cancel();
  }

  function test_WithNothingOnTheTable_ItReverts() external {
    vm.prank(_guardian);
    _desk.cancel();
    vm.expectRevert(INavDesk.NavDesk_NoProposal.selector);
    vm.prank(_guardian);
    _desk.cancel();
  }

  function test_CancellingAfterAcceptanceStopsExecution() external {
    _accept();
    vm.prank(_guardian);
    _desk.cancel();
    vm.warp(block.timestamp + _COOLDOWN);
    vm.expectRevert(INavDesk.NavDesk_NoProposal.selector);
    _desk.execute();
  }

  function test_AfterACancelTheReporterCanProposeAgain() external {
    vm.prank(_checker);
    _desk.cancel();
    _propose(7);
    assertEq(_desk.proposal().nav, 7);
  }
}

contract NavDesk_Execute is NavDeskTest {
  function setUp() public override {
    super.setUp();
    _request(_alice, 1000);
    _close();
    _propose(0);
  }

  function test_WithNothingOnTheTable_ItReverts() external {
    vm.prank(_guardian);
    _desk.cancel();
    vm.expectRevert(INavDesk.NavDesk_NoProposal.selector);
    _desk.execute();
  }

  function test_WithoutAcceptance_ItReverts() external {
    vm.warp(block.timestamp + _COOLDOWN);
    vm.expectRevert(INavDesk.NavDesk_AcceptanceWrong.selector);
    _desk.execute();
  }

  function test_BeforeTheCooldown_ItReverts() external {
    _accept();
    vm.warp(block.timestamp + _COOLDOWN - 1);
    vm.expectRevert(INavDesk.NavDesk_TooEarly.selector);
    _desk.execute();
  }

  function testFuzz_AfterTheCooldown_AnyoneExecutes(
    address _caller
  ) external {
    _accept();
    vm.warp(block.timestamp + _COOLDOWN);
    vm.prank(_caller);
    _desk.execute();
    assertEq(_vault.maxMint(_alice), 1000 * _PAR);
    assertEq(_desk.proposal().period, 0);
    assertEq(_asset.balanceOf(_custodian), 1e15 + 1000);
  }

  function test_AReportAtExactlyTheMaximumAgePasses() external {
    _accept();
    vm.warp(block.timestamp + _MAX_AGE);
    _desk.execute();
  }

  function test_AReportOlderThanTheMaximumAgeIsRefused() external {
    _accept();
    vm.warp(block.timestamp + _MAX_AGE + 1);
    vm.expectRevert(INavDesk.NavDesk_StaleReport.selector);
    _desk.execute();
  }

  function test_ItSettlesWithTheFrozenNumbersAndEmits() external {
    _accept();
    bytes32 _proposalHash = _hash();
    vm.warp(block.timestamp + _COOLDOWN);
    vm.expectEmit(address(_desk));
    emit INavDesk.ProposalExecuted(_proposalHash, 1);
    vm.expectEmit(address(_vault));
    emit IGated7540Vault.PeriodSettled(1, 0, 0, 1000, 1000 * _PAR, 0, 0, 0);
    _desk.execute();
  }

  /// @dev A timelock change can land inside the cooldown, so the frozen cash account is the one used
  function test_ASettingChangedInTheCooldownDoesNotChangeTheProposal() external {
    _accept();
    address _other = makeAddr('other');
    _desk.setSettings(address(0), _other, _LENGTH, _COOLDOWN, _MAX_AGE);
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();
    assertEq(_asset.balanceOf(_custodian), 1e15 + 1000);
    assertEq(_asset.balanceOf(_other), 0);
  }

  function test_WhenTheDeskLosesTheRole_ExecutionReverts() external {
    _accept();
    _vault.revokeRole(_vault.SETTLER_ROLE(), address(_desk));
    vm.warp(block.timestamp + _COOLDOWN);
    vm.expectRevert();
    _desk.execute();
    assertEq(_desk.proposal().period, 1, 'the revert leaves it on the table');
  }

  function test_WhenPaused_ExecutionReverts() external {
    _accept();
    vm.prank(_guardian);
    _vault.pause();
    vm.warp(block.timestamp + _COOLDOWN);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    _desk.execute();
  }
}

contract NavDesk_Stuck is NavDeskTest {
  uint256 internal constant _SHARES = 500 * _PAR;

  function setUp() public override {
    super.setUp();
    // Alice holds 500 at par, then asks to leave, while bob asks to come in.
    _request(_alice, 500);
    _deal(0);
    vm.prank(_alice);
    _vault.mint(_SHARES, _alice, _alice);
    vm.prank(_alice);
    _vault.requestRedeem(_SHARES, _alice, _alice);
    _request(_bob, 300);
    _close();
  }

  function _pastMaxAge() internal {
    vm.warp(_desk.lastCutoff() + _MAX_AGE + 1);
  }

  function test_BeforeTheMaximumAge_ItIsNotStuck() external {
    vm.warp(_desk.lastCutoff() + _MAX_AGE);
    vm.expectRevert(INavDesk.NavDesk_NotStuck.selector);
    vm.prank(_agent);
    _desk.refundRequest(_bob, true);
  }

  function testFuzz_OnlyTheAgentReleases(
    address _caller
  ) external {
    if (_caller == _agent) _caller = _stranger;
    _pastMaxAge();
    vm.expectRevert(_unauthorized(_caller));
    vm.prank(_caller);
    _desk.refundRequest(_bob, true);
    vm.expectRevert(_unauthorized(_caller));
    vm.prank(_caller);
    _desk.recoverRequest(_alice, _bob);
  }

  function test_WhileAProposalIsPending_NothingIsReleased() external {
    _propose(500);
    _pastMaxAge();
    vm.startPrank(_agent);
    vm.expectRevert(INavDesk.NavDesk_ProposalPending.selector);
    _desk.refundRequest(_bob, true);
    vm.expectRevert(INavDesk.NavDesk_ProposalPending.selector);
    _desk.recoverRequest(_alice, _bob);
    vm.stopPrank();
  }

  function test_WithNoClosedPeriod_ItIsNotStuck() external {
    _propose(500);
    _accept();
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();
    _pastMaxAge();
    vm.expectRevert(INavDesk.NavDesk_NotStuck.selector);
    vm.prank(_agent);
    _desk.refundRequest(_bob, true);
  }

  function test_ADepositIsRefunded() external {
    _pastMaxAge();
    uint256 _before = _asset.balanceOf(_bob);
    vm.expectEmit(address(_desk));
    emit INavDesk.RequestReleased(_bob, true, _bob);
    vm.prank(_agent);
    _desk.refundRequest(_bob, true);
    assertEq(_asset.balanceOf(_bob), _before + 300);
    assertEq(_vault.pendingDepositRequest(0, _bob), 0);
  }

  function test_ARedemptionIsRefunded() external {
    _pastMaxAge();
    vm.prank(_agent);
    _desk.refundRequest(_alice, false);
    assertEq(_vault.balanceOf(_alice), _SHARES);
  }

  function test_ARedemptionIsRecovered() external {
    _pastMaxAge();
    vm.expectEmit(address(_desk));
    emit INavDesk.RequestReleased(_alice, false, _bob);
    vm.prank(_agent);
    _desk.recoverRequest(_alice, _bob);
    assertEq(_vault.balanceOf(_bob), _SHARES);
  }

  /// @dev A total loss leaves no price anyone can propose, and every request can still go back
  function test_AfterATotalLoss_EveryRequestIsRefundable() external {
    uint256 _asOf = block.timestamp;
    vm.expectRevert(INavDesk.NavDesk_ZeroNav.selector);
    vm.prank(_reporter);
    _desk.propose(0, _REPORT, _asOf, 0);

    _pastMaxAge();
    vm.startPrank(_agent);
    _desk.refundRequest(_bob, true);
    _desk.refundRequest(_alice, false);
    vm.stopPrank();
    assertEq(_vault.pendingDepositRequest(0, _bob) + _vault.pendingRedeemRequest(0, _alice), 0);
  }

  /// @dev A pause stops the plain transfer back, so the redemption takes the recovery path; the deposit's cash still goes back
  function test_WhilePaused_ADepositIsRefundedAndARedemptionRecovered() external {
    vm.prank(_guardian);
    _vault.pause();
    _pastMaxAge();
    vm.startPrank(_agent);
    _desk.refundRequest(_bob, true);
    _desk.recoverRequest(_alice, _bob);
    vm.stopPrank();
    assertEq(_vault.balanceOf(_bob), _SHARES);
  }

  /// @dev Short cash stops the settlement, and leaves the period closed and the requests refundable
  function test_WhenTheCashAccountIsShort_ThePeriodStaysClosedAndTheRequestsGoBack() external {
    uint256 _all = _asset.balanceOf(_custodian);
    vm.prank(_custodian);
    _asset.transfer(_stranger, _all);
    _propose(500);
    _accept();
    vm.warp(block.timestamp + _COOLDOWN);
    vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, _custodian, 0, 200));
    _desk.execute();
    vm.prank(_checker);
    _desk.cancel();

    _pastMaxAge();
    vm.startPrank(_agent);
    _desk.refundRequest(_bob, true);
    _desk.refundRequest(_alice, false);
    vm.stopPrank();
    assertEq(_vault.balanceOf(_alice), _SHARES);
  }

  /// @dev A request in the open period is the agent's own to reject on the vault, and the desk cannot reach it
  function test_ARequestInTheOpenPeriodIsNotTheDesks() external {
    address _carol = makeAddr('carol');
    _creds.set(_carol, uint64(block.timestamp + 3650 days), Quals.KYC, 756);
    _asset.mint(_carol, 10);
    vm.prank(_carol);
    _asset.approve(address(_vault), 10);
    _request(_carol, 10);
    _pastMaxAge();
    vm.expectRevert();
    vm.prank(_agent);
    _desk.refundRequest(_carol, true);
    vm.prank(_agent);
    _vault.rejectDepositRequest(_carol);
  }
}

contract NavDesk_Settings is NavDeskTest {
  function testFuzz_OnlyTheAdminChangesThem(
    address _caller
  ) external {
    if (_caller == address(this)) _caller = _stranger;
    vm.expectRevert(_unauthorized(_caller));
    vm.prank(_caller);
    _desk.setSettings(address(0), _custodian, _LENGTH, _COOLDOWN, _MAX_AGE);
  }

  function test_ItChangesThemAndEmits() external {
    address _other = makeAddr('other');
    vm.expectEmit(address(_desk));
    emit INavDesk.SettingsChanged(address(0), _other, 2 days, 3 hours, 4 days);
    _desk.setSettings(address(0), _other, 2 days, 3 hours, 4 days);
    assertEq(_desk.custodianAccount(), _other);
    assertEq(_desk.periodLength(), 2 days);
    assertEq(_desk.cooldown(), 3 hours);
    assertEq(_desk.maxReportAge(), 4 days);
  }

  function test_TheBoundsHold() external {
    vm.expectRevert(INavDesk.NavDesk_ZeroValue.selector);
    _desk.setSettings(address(0), _custodian, 0, _COOLDOWN, _MAX_AGE);
    vm.expectRevert(abi.encodeWithSelector(INavDesk.NavDesk_InvalidCooldown.selector, 0));
    _desk.setSettings(address(0), _custodian, _LENGTH, 0, _MAX_AGE);
    vm.expectRevert(INavDesk.NavDesk_ZeroValue.selector);
    _desk.setSettings(address(0), _custodian, _LENGTH, _COOLDOWN, 0);
  }

  function test_TheMaximumAgeCannotFallBelowTheCooldown() external {
    vm.expectRevert(abi.encodeWithSelector(INavDesk.NavDesk_ReportAgeBelowCooldown.selector, _COOLDOWN - 1, _COOLDOWN));
    _desk.setSettings(address(0), _custodian, _LENGTH, _COOLDOWN, _COOLDOWN - 1);
    _desk.setSettings(address(0), _custodian, _LENGTH, _COOLDOWN, _COOLDOWN);
    assertEq(_desk.maxReportAge(), _COOLDOWN);
  }

  function test_AnUnattestedPortfolioIsRefused() external {
    Portfolio _portfolio = new Portfolio(address(_vault), IERC20(address(_asset)), true);
    vm.expectRevert(INavDesk.NavDesk_PortfolioRefused.selector);
    _desk.setSettings(address(_portfolio), address(0), _LENGTH, _COOLDOWN, _MAX_AGE);
  }

  function test_AnotherVaultsPortfolioIsRefused() external {
    Portfolio _portfolio = new Portfolio(makeAddr('otherVault'), IERC20(address(_asset)), true);
    _registry.attest(address(_portfolio).codehash, IPolicyRegistry.AttestKind.PORTFOLIO, '');
    vm.expectRevert(INavDesk.NavDesk_PortfolioRefused.selector);
    _desk.setSettings(address(_portfolio), address(0), _LENGTH, _COOLDOWN, _MAX_AGE);
  }
}

contract NavDesk_Adopt is NavDeskTest {
  NavDesk internal _next;

  function setUp() public override {
    super.setUp();
    _next = new NavDesk(address(_vault), _custodian, _LENGTH, _COOLDOWN, _MAX_AGE);
  }

  function testFuzz_OnlyTheAdminAdopts(
    address _caller
  ) external {
    if (_caller == address(this)) _caller = _stranger;
    vm.expectRevert(_unauthorized(_caller));
    vm.prank(_caller);
    _next.adopt(address(_desk));
  }

  function test_ItReadsTheLastCutOffAtThatMoment() external {
    _request(_alice, 10);
    _deal(0);
    uint256 _cutoff = _desk.lastCutoff();
    vm.warp(block.timestamp + 20 days); // however long the timelock took
    vm.expectEmit(address(_next));
    emit INavDesk.DeskAdopted(address(_desk));
    _next.adopt(address(_desk));
    assertEq(_next.lastCutoff(), _cutoff);
  }

  function test_ItRunsOnce() external {
    _next.adopt(address(_desk));
    vm.expectRevert(INavDesk.NavDesk_CannotAdopt.selector);
    _next.adopt(address(_desk));
  }

  function test_ADeskForAnotherVaultIsRefused() external {
    NavDesk _other = new NavDesk(address(_vault), _custodian, _LENGTH, _COOLDOWN, _MAX_AGE);
    vm.mockCall(address(_other), abi.encodeCall(INavDesk.VAULT, ()), abi.encode(makeAddr('otherVault')));
    vm.expectRevert(INavDesk.NavDesk_CannotAdopt.selector);
    _next.adopt(address(_other));
  }

  function test_ADeskWithAProposalPendingIsRefused() external {
    _request(_alice, 10);
    _close();
    _propose(0);
    vm.expectRevert(INavDesk.NavDesk_CannotAdopt.selector);
    _next.adopt(address(_desk));
  }

  function test_TheSuccessorDealsOnFromThere() external {
    _request(_alice, 10);
    _deal(0);
    _next.adopt(address(_desk));
    _vault.revokeRole(_vault.SETTLER_ROLE(), address(_desk));
    _vault.grantRole(_vault.SETTLER_ROLE(), address(_next));
    assertTrue(_next.isWired());
    assertFalse(_desk.isWired());

    _request(_bob, 20);
    vm.warp(_next.lastCutoff() + _LENGTH);
    _next.closePeriod();
    uint256 _asOf = block.timestamp;
    vm.prank(_reporter);
    _next.propose(10, _REPORT, _asOf, 0);
    bytes32 _proposalHash = _next.hashOf(_next.proposal());
    vm.prank(_checker);
    _next.accept(_proposalHash);
    vm.warp(block.timestamp + _COOLDOWN);
    _next.execute();
    assertEq(_vault.maxMint(_bob), 20 * _PAR);
  }
}

/// @notice With a `Portfolio` plugged it is both the cash account and the source of on-chain value
contract NavDesk_WithAPortfolio is NavDeskTest {
  bytes32 internal constant _RISK = keccak256('the priced risk');

  Portfolio internal _portfolio;
  MockAdapter internal _adapter;
  address internal _allocator = makeAddr('allocator');

  function setUp() public override {
    super.setUp();
    _portfolio = new Portfolio(address(_vault), IERC20(address(_asset)), true);
    _registry.attest(address(_portfolio).codehash, IPolicyRegistry.AttestKind.PORTFOLIO, '');
    _desk.setSettings(address(_portfolio), address(0), _LENGTH, _COOLDOWN, _MAX_AGE);

    bytes32[] memory _ids = new bytes32[](1);
    _ids[0] = _RISK;
    _adapter = new MockAdapter(address(_portfolio), address(_asset), false, _ids);
    _registry.attest(address(_adapter).codehash, IPolicyRegistry.AttestKind.ADAPTER, '');
    _portfolio.addAdapter(address(_adapter));
    _portfolio.setCaps(_RISK, type(uint120).max, 10_000);
    _vault.grantRole(_portfolio.ALLOCATOR_ROLE(), _allocator);
  }

  function _proposeAgainst(
    uint256 _reported,
    uint256 _moves
  ) internal {
    uint256 _asOf = block.timestamp;
    vm.prank(_reporter);
    _desk.propose(_reported, _REPORT, _asOf, _moves);
  }

  function test_NetInflowGoesToThePortfolio() external {
    _request(_alice, 1000);
    _deal(0);
    assertEq(_asset.balanceOf(address(_portfolio)), 1000);
    assertEq(_asset.balanceOf(address(_vault)), 0);
  }

  function test_NetOutflowIsPulledFromThePortfolio() external {
    _request(_alice, 1000);
    _deal(0);
    vm.prank(_alice);
    _vault.mint(1000 * _PAR, _alice, _alice);
    vm.prank(_alice);
    _vault.requestRedeem(400 * _PAR, _alice, _alice);
    _close();
    _proposeAgainst(0, 0);
    _accept();
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();
    assertEq(_asset.balanceOf(address(_portfolio)), 600);
    assertEq(_vault.maxWithdraw(_alice), 400);
  }

  function test_TheValueCountsTheReportAndThePortfoliosPrice() external {
    _request(_alice, 1000);
    _deal(0);
    vm.prank(_allocator);
    _portfolio.allocate(address(_adapter), 400, 0);
    _adapter.setValue(450); // the position grew
    _close();
    _proposeAgainst(70, 1);
    // 600 idle, 450 priced, 70 reported
    assertEq(_desk.proposal().nav, 1120);
  }

  function test_AMoveAfterTheValuationCannotCountTwice() external {
    _request(_alice, 1000);
    _deal(0);
    vm.prank(_allocator);
    _portfolio.allocate(address(_adapter), 400, 0);
    _close();
    uint256 _asOf = block.timestamp;
    vm.expectRevert(abi.encodeWithSelector(INavDesk.NavDesk_MovesChanged.selector, 0, 1));
    vm.prank(_reporter);
    _desk.propose(100, _REPORT, _asOf, 0);
  }

  function test_WhenThePriceIsNotFresh_NoPriceIsProposed() external {
    _request(_alice, 1000);
    _deal(0);
    _adapter.setFresh(false);
    _close();
    uint256 _asOf = block.timestamp;
    vm.expectRevert(INavDesk.NavDesk_PriceNotFresh.selector);
    vm.prank(_reporter);
    _desk.propose(0, _REPORT, _asOf, 0);
  }

  /// @dev A 1-unit first investor donates to the portfolio before a victim's period, and the victim keeps its value
  function test_ADonationToThePortfolioDoesNotHurtTheNextInvestor() external {
    uint256 _thousand = 1000e6;
    _request(_alice, 1);
    _deal(0);
    vm.prank(_alice);
    _vault.mint(_PAR, _alice, _alice);

    _asset.mint(address(_portfolio), _thousand); // the donation
    _request(_bob, _thousand);
    _close();
    _proposeAgainst(0, 0);
    _accept();
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();

    uint256 _bought = _vault.maxMint(_bob);
    vm.prank(_bob);
    _vault.mint(_bought, _bob, _bob);
    uint256 _total = _portfolio.pricedValue();
    uint256 _victim = _bought * _total / _vault.totalSupply();
    assertGe(_victim, _thousand * 9998 / 10_000);
  }
}
