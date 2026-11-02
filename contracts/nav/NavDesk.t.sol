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
import {FeeModel} from 'contracts/nav/FeeModel.sol';
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
    _creds.set(_alice, uint64(block.timestamp + 3650 days), Quals.KYC);
    _creds.set(_bob, uint64(block.timestamp + 3650 days), Quals.KYC);

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
      nav: 0, // no shares yet, so what is reported is nobody's, the mark starts at par and the clocks restart
      fee: 0,
      mark: 1e12,
      markMovedAt: block.timestamp,
      reportHash: _REPORT,
      cash: _custodian,
      feeRecipient: address(0),
      redeemLimit: type(uint256).max
    });
    vm.expectEmit(address(_desk));
    emit INavDesk.ProposalMade(_desk.hashOf(_expected), 1, 500, 0, 0, 0, _REPORT, block.timestamp, type(uint256).max);
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

    vm.prank(_reporter);
    _desk.propose(999, keccak256('another NAV pack'), block.timestamp, 0);
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
    _q.markMovedAt += 1;
    assertTrue(_desk.hashOf(_q) != _base, 'the clock');
    _q = _desk.proposal();
    _q.reportHash = bytes32(uint256(_q.reportHash) + 1);
    assertTrue(_desk.hashOf(_q) != _base, 'report');
    _q = _desk.proposal();
    _q.cash = address(1);
    assertTrue(_desk.hashOf(_q) != _base, 'cash');
    _q = _desk.proposal();
    _q.feeRecipient = address(1);
    assertTrue(_desk.hashOf(_q) != _base, 'fee recipient');
    _q = _desk.proposal();
    _q.asOf += 1;
    assertTrue(_desk.hashOf(_q) != _base, 'the report date');
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
    assertEq(_desk.proposal().period, 1);
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
    emit IGated7540Vault.PeriodSettled(1, 0, 0, 1000, 1000 * _PAR, 0, 0, 0, 0);
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

  /// @dev A second settler dealt the period this priced and closed the next. Executing would deal that one at this price
  function test_WhenAnotherPeriodIsClosedNow_ItReverts() external {
    _accept();
    address _settler = makeAddr('settler');
    _vault.grantRole(_vault.SETTLER_ROLE(), _settler);
    vm.startPrank(_settler);
    _vault.settlePeriod(0, 0, _custodian, address(0), type(uint256).max);
    _vault.closePeriod();
    vm.stopPrank();
    vm.warp(block.timestamp + _COOLDOWN);
    vm.expectRevert(abi.encodeWithSelector(INavDesk.NavDesk_WrongPeriod.selector, 1, 2));
    _desk.execute();
    assertEq(_desk.proposal().period, 1, 'cancelling is the way out');
  }

  function test_WhenNoPeriodIsClosedNow_ItReverts() external {
    _accept();
    address _settler = makeAddr('settler');
    _vault.grantRole(_vault.SETTLER_ROLE(), _settler);
    vm.prank(_settler);
    _vault.settlePeriod(0, 0, _custodian, address(0), type(uint256).max);
    vm.warp(block.timestamp + _COOLDOWN);
    vm.expectRevert(INavDesk.NavDesk_NoClosedPeriod.selector);
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
    _creds.set(_carol, uint64(block.timestamp + 3650 days), Quals.KYC);
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

contract NavDesk_Fees is NavDeskTest {
  uint256 internal constant _YEAR = 365 days;
  address internal _recipient = makeAddr('recipient');
  FeeModel internal _model;

  function setUp() public override {
    super.setUp();
    _model = new FeeModel(_recipient, 200, 2000, 0, false);
    _registry.attest(address(_model).codehash, IPolicyRegistry.AttestKind.FEE_MODEL, '');
    // 1,000 in, at par, and claimed.
    _request(_alice, 1000e6);
    _deal(0);
    vm.prank(_alice);
    _vault.mint(1000e6 * _PAR, _alice, _alice);
  }

  function _plug() internal {
    _desk.setFeeModel(address(_model));
  }

  function testFuzz_OnlyTheAdminPlugsAModel(
    address _caller
  ) external {
    if (_caller == address(this)) _caller = _stranger;
    vm.expectRevert(_unauthorized(_caller));
    vm.prank(_caller);
    _desk.setFeeModel(address(_model));
  }

  function test_AnUnattestedModelIsRefused() external {
    FeeModel _rogue = new FeeModel(_stranger, 500, 5000, 0, false);
    vm.expectRevert(abi.encodeWithSelector(INavDesk.NavDesk_FeeModelRefused.selector, address(_rogue)));
    _desk.setFeeModel(address(_rogue));
  }

  function _settleAt(
    uint256 _reported
  ) internal {
    _close();
    _propose(_reported);
    _accept();
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();
  }

  function test_TheFirstPlugStartsTheMarkAtTheCurrentPrice() external {
    _settleAt(2000e6);
    vm.expectEmit(address(_desk));
    emit INavDesk.FeeModelSet(address(_model));
    _plug();
    assertEq(_desk.feeModel(), address(_model));
    assertEq(_desk.mark(), _vault.convertToAssets(1e18));
    assertGt(_desk.mark(), 1e12);
    assertEq(_desk.lastFeeAt(), block.timestamp);
    assertEq(_desk.markMovedAt(), block.timestamp);
  }

  /// @dev Getting back to par is a recovery of principal, not a gain
  function test_AFirstPlugBelowParStartsTheMarkAtPar() external {
    _settleAt(500e6);
    assertLt(_vault.convertToAssets(1e18), 1e12);
    _plug();
    assertEq(_desk.mark(), 1e12);
    _close();
    _propose(1000e6);
    assertEq(_desk.proposal().mark, 1e12, 'no performance fee on the way back');
  }

  function test_ASwapKeepsTheMarkAndTheClocks() external {
    _plug();
    uint256 _mark = _desk.mark();
    uint256 _at = block.timestamp;
    vm.warp(block.timestamp + 1 days);
    FeeModel _next = new FeeModel(_recipient, 100, 1000, 0, false);
    _registry.attest(address(_next).codehash, IPolicyRegistry.AttestKind.FEE_MODEL, '');
    _desk.setFeeModel(address(_next));
    assertEq(_desk.mark(), _mark);
    assertEq(_desk.lastFeeAt(), _at);
  }

  function test_UnpluggingStopsTheFee() external {
    _plug();
    _desk.setFeeModel(address(0));
    vm.warp(block.timestamp + _YEAR);
    _close();
    _propose(1000e6);
    assertEq(_desk.proposal().fee, 0);
    assertEq(_desk.proposal().nav, 1000e6);
  }

  function test_TheFeeIsQuotedFrozenAndPaid() external {
    _plug();
    vm.warp(block.timestamp + _YEAR);
    _close();
    uint256 _at = block.timestamp;
    uint256 _gross = 1000e6;
    (uint256 _quoted,,) =
      _model.quote(_gross, _vault.totalSupply(), _desk.mark(), _at - _desk.markMovedAt(), _at - _desk.lastFeeAt());
    _propose(_gross);
    INavDesk.Proposal memory _p = _desk.proposal();
    assertEq(_p.fee, _quoted);
    assertGt(_p.fee, 0);
    assertEq(_p.nav, _gross - _quoted);
    assertEq(_p.feeRecipient, _recipient);
    _accept();
    vm.warp(block.timestamp + _COOLDOWN);
    uint256 _cashBefore = _asset.balanceOf(_custodian);
    _desk.execute();
    assertEq(_asset.balanceOf(_recipient), _quoted);
    assertEq(_asset.balanceOf(_custodian), _cashBefore - _quoted);
  }

  /// @dev The frozen fee is the fee paid, even if the model is swapped in the cooldown
  function test_TheFrozenFeeIsTheFeePaid() external {
    _plug();
    vm.warp(block.timestamp + _YEAR);
    _close();
    _propose(1000e6);
    uint256 _frozen = _desk.proposal().fee;
    _accept();
    _desk.setFeeModel(address(0));
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();
    assertEq(_asset.balanceOf(_recipient), _frozen);
  }

  function test_ExecutingMovesTheMarkAndTheClocks() external {
    _plug();
    vm.warp(block.timestamp + _YEAR);
    _close();
    uint256 _at = block.timestamp;
    _propose(2000e6); // the value doubled
    uint256 _newMark = _desk.proposal().mark;
    assertGt(_newMark, _desk.mark());
    _accept();
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();
    assertEq(_desk.mark(), _newMark);
    assertEq(_desk.markMovedAt(), _at);
    assertEq(_desk.lastFeeAt(), _at);
  }

  function test_BelowTheMarkItStaysAndItsClockRunsOn() external {
    _plug();
    uint256 _mark = _desk.mark();
    uint256 _movedAt = _desk.markMovedAt();
    vm.warp(block.timestamp + _YEAR);
    _close();
    uint256 _at = block.timestamp;
    _propose(500e6);
    _accept();
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();
    assertEq(_desk.mark(), _mark);
    assertEq(_desk.markMovedAt(), _movedAt);
    assertEq(_desk.lastFeeAt(), _at);
  }

  /// @dev A cancel leaves the fee clocks where they were, so nothing is lost or charged twice
  function test_ACancelledProposalChargesNothing() external {
    _plug();
    uint256 _feeAt = _desk.lastFeeAt();
    vm.warp(block.timestamp + _YEAR);
    _close();
    _propose(1000e6);
    vm.prank(_checker);
    _desk.cancel();
    assertEq(_desk.lastFeeAt(), _feeAt);
    assertEq(_asset.balanceOf(_recipient), 0);
  }

  /// @dev With no shares the first investors pay nothing for time before they arrived
  function test_WithNoSharesThereIsNoFeeAndTheClocksRestart() external {
    _plug();
    vm.prank(_alice);
    _vault.requestRedeem(1000e6 * _PAR, _alice, _alice);
    _deal(1000e6);
    assertEq(_vault.totalSupply(), 0);

    vm.warp(block.timestamp + _YEAR);
    _close();
    uint256 _at = block.timestamp;
    _propose(0);
    assertEq(_desk.proposal().fee, 0);
    _accept();
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();
    assertEq(_desk.markMovedAt(), _at);
    assertEq(_desk.lastFeeAt(), _at);
  }

  function test_ADeskThatAdoptsChargesNothingTwice() external {
    _plug();
    vm.warp(block.timestamp + _YEAR);
    _close();
    _propose(2000e6);
    _accept();
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();
    uint256 _mark = _desk.mark();
    uint256 _movedAt = _desk.markMovedAt();
    uint256 _feeAt = _desk.lastFeeAt();

    vm.warp(block.timestamp + 30 days); // a long timelock delay
    NavDesk _next = new NavDesk(address(_vault), _custodian, _LENGTH, _COOLDOWN, _MAX_AGE);
    _next.adopt(address(_desk));
    assertEq(_next.mark(), _mark);
    assertEq(_next.markMovedAt(), _movedAt);
    assertEq(_next.lastFeeAt(), _feeAt);
    assertEq(_next.feeModel(), address(0), 'the batch plugs the model itself');
  }

  /// @dev The proposal froze no mark, as there was no model. Writing that over the plug's would charge principal
  function test_AFirstPlugDuringACooldownKeepsItsMarkAndChargesNoPrincipal() external {
    _close();
    _propose(1000e6);
    _accept();
    _plug();
    uint256 _mark = _desk.mark();
    uint256 _at = block.timestamp;
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();
    assertEq(_desk.mark(), _mark);
    assertEq(_desk.markMovedAt(), _at);
    assertEq(_desk.lastFeeAt(), _at);
    assertEq(_asset.balanceOf(_recipient), 0);

    // An unchanged value pays a day's management fee, and no performance fee.
    _close();
    _propose(1000e6);
    assertLt(_desk.proposal().fee, 100e3);
    assertEq(_desk.proposal().mark, _mark);
  }

  /// @dev The same numbers on a later report are another price: the staleness check runs from the report's date
  function test_AnApprovalDoesNotCarryOverToALaterReportWithTheSameNumbers() external {
    _close();
    _propose(1000e6);
    bytes32 _earlier = _hash();
    vm.prank(_checker);
    _desk.cancel();
    vm.warp(block.timestamp + 1);
    _propose(1000e6);
    vm.expectRevert(INavDesk.NavDesk_ProposalMismatch.selector);
    vm.prank(_checker);
    _desk.accept(_earlier);
  }

  function test_WithNoModelExecutingLeavesTheFeeStateAlone() external {
    _close();
    _propose(1000e6);
    _accept();
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();
    assertEq(_desk.mark(), 0);
    assertEq(_desk.markMovedAt(), 0);
    assertEq(_desk.lastFeeAt(), 0);
  }

  /// @dev Plugging then adopting from a desk that never charged: its mark of 0 says nothing, and must not replace the plug's
  function test_AdoptingFromADeskThatNeverChargedKeepsThePlug() external {
    NavDesk _next = new NavDesk(address(_vault), _custodian, _LENGTH, _COOLDOWN, _MAX_AGE);
    _next.setFeeModel(address(_model));
    uint256 _mark = _next.mark();
    uint256 _at = block.timestamp;
    assertGt(_mark, 0);
    vm.warp(block.timestamp + 1 days);
    _next.adopt(address(_desk));
    assertEq(_next.mark(), _mark);
    assertEq(_next.markMovedAt(), _at);
    assertEq(_next.lastFeeAt(), _at);
    assertEq(_next.lastCutoff(), _desk.lastCutoff());
  }

  /// @dev Plugging then adopting from a desk that charges: the time since its last fee is still charged
  function test_PluggingThenAdoptingTakesTheOldDesksClocks() external {
    _plug();
    uint256 _mark = _desk.mark();
    uint256 _at = block.timestamp;
    vm.warp(block.timestamp + 30 days);
    NavDesk _next = new NavDesk(address(_vault), _custodian, _LENGTH, _COOLDOWN, _MAX_AGE);
    _next.setFeeModel(address(_model));
    _next.adopt(address(_desk));
    assertEq(_next.mark(), _mark);
    assertEq(_next.markMovedAt(), _at);
    assertEq(_next.lastFeeAt(), _at);
  }

  /// @dev A desk with its model taken off keeps a mark, so no gain pays twice, and no time without a model is charged
  function test_AdoptingFromADeskWithItsModelOffTakesTheMarkAndNotTheFeeClock() external {
    _plug();
    uint256 _mark = _desk.mark();
    uint256 _movedAt = _desk.markMovedAt();
    vm.warp(block.timestamp + 30 days);
    _desk.setFeeModel(address(0));
    vm.warp(block.timestamp + 30 days);
    NavDesk _next = new NavDesk(address(_vault), _custodian, _LENGTH, _COOLDOWN, _MAX_AGE);
    _next.setFeeModel(address(_model));
    uint256 _at = block.timestamp;
    _next.adopt(address(_desk));
    assertEq(_next.mark(), _mark);
    assertEq(_next.markMovedAt(), _movedAt);
    assertEq(_next.lastFeeAt(), _at);
  }
}

/// @notice With no shares nothing is anyone's: a period strikes at par, and the mark starts there
contract NavDesk_NoShares is NavDeskTest {
  uint256 internal constant _PAR_MARK = 1e12;
  uint256 internal constant _IN = 1000e6;
  address internal _recipient = makeAddr('recipient');

  function setUp() public override {
    super.setUp();
    FeeModel _model = new FeeModel(_recipient, 0, 2000, 0, false);
    _registry.attest(address(_model).codehash, IPolicyRegistry.AttestKind.FEE_MODEL, '');
    _desk.setFeeModel(address(_model));
  }

  function _settle() internal {
    _accept();
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();
  }

  function _claim(
    address _who
  ) internal returns (uint256 _shares) {
    _shares = _vault.maxMint(_who);
    vm.prank(_who);
    _vault.mint(_shares, _who, _who);
  }

  function test_AValueReportedWithNoSharesStrikesAtPar() external {
    _request(_alice, _IN);
    _close();
    _propose(1e6);
    assertEq(_desk.proposal().nav, 0);
    assertEq(_desk.proposal().mark, _PAR_MARK);
    _settle();
    assertEq(_claim(_alice), _IN * _PAR);
    assertEq(_desk.mark(), _PAR_MARK);
  }

  /// @dev One unit reported would double the price against a mark at par, and charge 100 of an unchanged 1,000
  function test_TheNextPeriodChargesNoFeeOnPrincipal() external {
    _request(_alice, _IN);
    _close();
    _propose(1);
    _settle();
    _claim(_alice);
    _close();
    _propose(_IN);
    assertEq(_desk.proposal().fee, 0);
    assertEq(_desk.proposal().nav, _IN);
  }

  /// @dev Shares not claimed yet are shares: valuing them at nothing would hand their value to the next investors
  function test_UnclaimedSharesStillHaveAValue() external {
    _request(_alice, _IN);
    _close();
    _propose(0);
    _settle();
    assertEq(_vault.totalSupply(), 0);
    _close();
    _propose(_IN);
    assertEq(_desk.proposal().nav, _IN);
  }

  /// @dev A stranger cannot move the first price, or stop it, with a unit sent to the portfolio
  function test_ADonationToThePortfolioWithNoSharesStrikesAtPar() external {
    Portfolio _portfolio = new Portfolio(address(_vault), IERC20(address(_asset)), true);
    _registry.attest(address(_portfolio).codehash, IPolicyRegistry.AttestKind.PORTFOLIO, '');
    _desk.setSettings(address(_portfolio), address(0), _LENGTH, _COOLDOWN, _MAX_AGE);
    _request(_alice, _IN);
    _asset.mint(address(_portfolio), 1);
    _close();
    _propose(0);
    assertEq(_desk.proposal().nav, 0);
    _settle();
    assertEq(_claim(_alice), _IN * _PAR);
    _close();
    _propose(0);
    assertEq(_desk.proposal().fee, 0, 'a gain of one unit rounds to no fee');
    assertEq(_desk.proposal().nav, _IN + 1);
  }

  /// @dev Every holder gone, with the mark far above par and money left: the next investor still starts from par
  function test_TheMarkRestartsAtParWhenEveryoneHasLeft() external {
    _request(_alice, _IN);
    _close();
    _propose(0);
    _settle();
    uint256 _shares = _claim(_alice);

    // The value doubles, a fee is charged and the mark moves.
    _close();
    _propose(2 * _IN);
    _settle();
    assertGt(_desk.mark(), _PAR_MARK);

    vm.prank(_alice);
    _vault.requestRedeem(_shares, _alice, _alice);
    _close();
    _propose(2 * _IN);
    _settle();
    assertEq(_vault.totalSupply(), 0);

    _request(_bob, _IN);
    _close();
    _propose(5);
    assertEq(_desk.proposal().nav, 0);
    assertEq(_desk.proposal().fee, 0);
    _settle();
    assertEq(_claim(_bob), _IN * _PAR);
    assertEq(_desk.mark(), _PAR_MARK);

    _close();
    _propose(_IN);
    assertEq(_desk.proposal().fee, 0);
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

  function test_APortfolioForAnotherAssetIsRefused() external {
    MockAsset _other = new MockAsset(6);
    Portfolio _wrong = new Portfolio(address(_vault), IERC20(address(_other)), true);
    _registry.attest(address(_wrong).codehash, IPolicyRegistry.AttestKind.PORTFOLIO, '');
    vm.expectRevert(INavDesk.NavDesk_PortfolioRefused.selector);
    _desk.setSettings(address(_wrong), address(0), _LENGTH, _COOLDOWN, _MAX_AGE);
  }

  /// @dev A portfolio that has sent its money on prices nothing, and no price can be struck against it
  function test_AfterAMigrationNoPriceIsProposed() external {
    _portfolio.removeAdapter(address(_adapter));
    Portfolio _next = new Portfolio(address(_vault), IERC20(address(_asset)), true);
    _portfolio.migrateTo(address(_next));
    _request(_alice, 1000);
    _close();
    uint256 _asOf = block.timestamp;
    vm.expectRevert(INavDesk.NavDesk_PriceNotFresh.selector);
    vm.prank(_reporter);
    _desk.propose(0, _REPORT, _asOf, 0);
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

/// @notice The desk holds the level, works out the limit when a price is proposed, and freezes it there. A holds 900 and B
///         100, at par, and the value reported keeps the price there
contract NavDesk_RedemptionGate is NavDeskTest {
  uint256 internal constant _TENTH = 1000;

  function setUp() public override {
    super.setUp();
    _request(_alice, 900);
    _request(_bob, 100);
    _deal(0);
    vm.prank(_alice);
    _vault.mint(900 * _PAR, _alice, _alice);
    vm.prank(_bob);
    _vault.mint(100 * _PAR, _bob, _bob);
  }

  function _askToRedeem(
    address _who,
    uint256 _shares
  ) internal {
    vm.prank(_who);
    _vault.requestRedeem(_shares, _who, _who);
  }

  function _supply() internal view returns (uint256 _all) {
    (,, uint256 _unclaimed) = _vault.dealingState();
    _all = _vault.totalSupply() + _unclaimed;
  }

  function _executeAfterCooldown() internal {
    vm.warp(block.timestamp + _COOLDOWN);
    _desk.execute();
  }

  function test_ItStartsOffAndTakesEverything() external {
    assertEq(_desk.redemptionGate(), 0);
    _askToRedeem(_alice, 900 * _PAR);
    _close();
    _propose(1000);
    assertEq(_desk.proposal().redeemLimit, type(uint256).max);
    _accept();
    _executeAfterCooldown();
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);
    assertEq(_vault.maxRedeem(_alice), 900 * _PAR);
  }

  function test_WhenTheAdminSetsTheLevel_ItIsAnnounced() external {
    vm.expectEmit(address(_desk));
    emit INavDesk.RedemptionGateSet(_TENTH);
    _desk.setRedemptionGate(_TENTH);
    assertEq(_desk.redemptionGate(), _TENTH);
  }

  function test_WhenAStrangerSetsTheLevel_ItReverts() external {
    vm.expectRevert(_unauthorized(_stranger));
    vm.prank(_stranger);
    _desk.setRedemptionGate(_TENTH);
  }

  function test_TheGuardianCannotSetTheLevel() external {
    vm.expectRevert(_unauthorized(_guardian));
    vm.prank(_guardian);
    _desk.setRedemptionGate(_TENTH);
  }

  function test_TheLevelStopsAtTheWholeFund() external {
    vm.expectRevert(abi.encodeWithSelector(INavDesk.NavDesk_InvalidGate.selector, 10_001));
    _desk.setRedemptionGate(10_001);
    _desk.setRedemptionGate(10_000);
    assertEq(_desk.redemptionGate(), 10_000);
    _desk.setRedemptionGate(0);
    assertEq(_desk.redemptionGate(), 0);
  }

  /// @dev The worked example in `PLAN.md`: a queue of 300 clears in four periods at a tenth of the fund
  function test_AQueueClearsInFourPeriodsAtATenthOfTheFund() external {
    _desk.setRedemptionGate(_TENTH);
    _askToRedeem(_alice, 200 * _PAR);
    _askToRedeem(_bob, 100 * _PAR);
    _request(_bob, 20);

    uint256 _before = _asset.balanceOf(_custodian);
    _close();
    _propose(1000);
    assertEq(_desk.proposal().redeemLimit, 100 * _PAR + 20 * _PAR, 'a tenth, plus the shares the deposits buy');
    _accept();
    _executeAfterCooldown();
    assertEq(_before - _asset.balanceOf(_custodian), 100, 'a tenth of the fund leaves on net');
    assertEq(_vault.maxRedeem(_alice), 80 * _PAR);
    assertEq(_vault.maxRedeem(_bob), 40 * _PAR);
    assertEq(_vault.pendingRedeemRequest(0, _alice), 120 * _PAR);
    assertEq(_vault.pendingRedeemRequest(0, _bob), 60 * _PAR);
    assertEq(_supply(), 900 * _PAR);

    _close();
    _propose(900);
    assertEq(_desk.proposal().redeemLimit, 90 * _PAR);
    _accept();
    _executeAfterCooldown();
    assertEq(_vault.pendingRedeemRequest(0, _alice), 60 * _PAR);
    assertEq(_vault.pendingRedeemRequest(0, _bob), 30 * _PAR);
    assertEq(_supply(), 810 * _PAR);

    _close();
    _propose(810);
    assertEq(_desk.proposal().redeemLimit, 81 * _PAR);
    _accept();
    _executeAfterCooldown();
    assertEq(_vault.pendingRedeemRequest(0, _alice), 6 * _PAR);
    assertEq(_vault.pendingRedeemRequest(0, _bob), 3 * _PAR);
    assertEq(_supply(), 729 * _PAR);

    _close();
    _propose(729);
    assertEq(_desk.proposal().redeemLimit, 72_900_000);
    _accept();
    _executeAfterCooldown();
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);
    assertEq(_vault.pendingRedeemRequest(0, _bob), 0);
    assertEq(_vault.maxRedeem(_alice), 200 * _PAR);
    assertEq(_vault.maxRedeem(_bob), 100 * _PAR);
  }

  /// @dev Measured in shares at one price, what leaves less what the deposits buy never passes the level
  function testFuzz_NoMoreThanTheLevelLeavesOnNet(
    uint256 _level,
    uint256 _deposits,
    uint256 _redemptions
  ) external {
    _level = bound(_level, 1, 10_000);
    _deposits = bound(_deposits, 0, 2000);
    _desk.setRedemptionGate(_level);
    _askToRedeem(_alice, bound(_redemptions, 1, 900 * _PAR));
    if (_deposits != 0) _request(_bob, _deposits);

    uint256 _before = _supply();
    _close();
    _propose(1000);
    _accept();
    _executeAfterCooldown();
    uint256 _after = _supply();
    if (_after < _before) assertLe(_before - _after, _before * _level / 10_000);
  }

  function test_WhenTheRedemptionsAreBelowTheLimit_TheyAreFilled() external {
    _desk.setRedemptionGate(_TENTH);
    _askToRedeem(_alice, 100 * _PAR);
    _close();
    _propose(1000);
    _accept();
    _executeAfterCooldown();
    assertEq(_vault.pendingRedeemRequest(0, _alice), 0);
    assertEq(_vault.maxRedeem(_alice), 100 * _PAR);
  }

  function test_ALevelChangedInsideTheCooldownMovesNothingOnTheTable() external {
    _desk.setRedemptionGate(_TENTH);
    _askToRedeem(_alice, 300 * _PAR);
    _close();
    _propose(1000);
    _accept();
    _desk.setRedemptionGate(0);
    _executeAfterCooldown();
    assertEq(_vault.maxRedeem(_alice), 100 * _PAR, 'the frozen limit');

    _close();
    _propose(900);
    assertEq(_desk.proposal().redeemLimit, type(uint256).max, 'the next price reads the new level');
  }

  function test_TheHashCoversTheLimit() external {
    _desk.setRedemptionGate(_TENTH);
    _close();
    _propose(1000);
    INavDesk.Proposal memory _p = _desk.proposal();
    bytes32 _hashed = _desk.hashOf(_p);
    _p.redeemLimit = _p.redeemLimit + 1;
    assertNotEq(_desk.hashOf(_p), _hashed);
  }

  function test_AnApprovalOfAnotherLimitIsRefused() external {
    _desk.setRedemptionGate(_TENTH);
    _close();
    _propose(1000);
    bytes32 _stale = _hash();
    vm.prank(_checker);
    _desk.cancel();
    _desk.setRedemptionGate(2 * _TENTH);
    _propose(1000);
    vm.expectRevert(INavDesk.NavDesk_ProposalMismatch.selector);
    vm.prank(_checker);
    _desk.accept(_stale);
  }

  function test_AReplacementDeskKeepsTheLevel() external {
    _desk.setRedemptionGate(_TENTH);
    NavDesk _next = new NavDesk(address(_vault), _custodian, _LENGTH, _COOLDOWN, _MAX_AGE);
    vm.expectEmit(address(_next));
    emit INavDesk.RedemptionGateSet(_TENTH);
    _next.adopt(address(_desk));
    assertEq(_next.redemptionGate(), _TENTH);
    _next.setRedemptionGate(0);
    assertEq(_next.redemptionGate(), 0);
  }
}
