// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {INavDesk} from 'interfaces/INavDesk.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {IPortfolio} from 'interfaces/IPortfolio.sol';

/**
 * @title NavDesk
 * @notice Turns a reported value into an approved price for one 7540 vault, as specified in `INavDesk`
 * @dev Immutable, one per vault
 */
contract NavDesk is INavDesk {
  /// @inheritdoc INavDesk
  uint256 public constant MIN_COOLDOWN = 1 hours;

  /// @inheritdoc INavDesk
  uint256 public constant MAX_COOLDOWN = 3 days;

  /// @inheritdoc INavDesk
  bytes32 public constant REPORTER_ROLE = keccak256('REPORTER_ROLE');

  /// @inheritdoc INavDesk
  bytes32 public constant CHECKER_ROLE = keccak256('CHECKER_ROLE');

  /// @notice The vault's role behind the guardian's powers here
  bytes32 private constant _GUARDIAN_ROLE = keccak256('GUARDIAN_ROLE');

  /// @notice The vault's role behind `refundRequest` and `recoverRequest`
  bytes32 private constant _AGENT_ROLE = keccak256('AGENT_ROLE');

  /// @notice The vault's role this desk needs
  bytes32 private constant _SETTLER_ROLE = keccak256('SETTLER_ROLE');

  /// @notice The vault's admin role
  bytes32 private constant _DEFAULT_ADMIN_ROLE = 0x00;

  /// @inheritdoc INavDesk
  address public immutable VAULT;

  /// @inheritdoc INavDesk
  address public portfolio;

  /// @inheritdoc INavDesk
  address public custodianAccount;

  /// @inheritdoc INavDesk
  uint256 public periodLength;

  /// @inheritdoc INavDesk
  uint256 public cooldown;

  /// @inheritdoc INavDesk
  uint256 public maxReportAge;

  /// @inheritdoc INavDesk
  uint256 public lastCutoff;

  /// @notice Whether `adopt` has run
  bool internal _adopted;

  /// @notice The proposal on the table
  Proposal internal _proposal;

  /**
   * @notice Deploys the desk
   * @param _vault The vault it serves
   * @param _custodianAccount The cash account when there is no portfolio; zero when one will be plugged
   * @param _periodLength The time between cut-offs
   * @param _cooldown The time between a proposal and its execution
   * @param _maxReportAge The oldest report that may execute
   */
  constructor(
    address _vault,
    address _custodianAccount,
    uint256 _periodLength,
    uint256 _cooldown,
    uint256 _maxReportAge
  ) {
    if (_vault == address(0)) revert NavDesk_ZeroValue();
    VAULT = _vault;
    _setSettings(address(0), _custodianAccount, _periodLength, _cooldown, _maxReportAge);
    lastCutoff = block.timestamp;
  }

  /// @inheritdoc INavDesk
  function setSettings(
    address _portfolio,
    address _custodianAccount,
    uint256 _periodLength,
    uint256 _cooldown,
    uint256 _maxReportAge
  ) external {
    _onlyRole(_DEFAULT_ADMIN_ROLE);
    if (_portfolio != address(0)) {
      IPolicyRegistry _registry = IPolicyRegistry(IPolicyGated(VAULT).registry());
      if (
        !_registry.isAttested(_portfolio, IPolicyRegistry.AttestKind.PORTFOLIO)
          || IPortfolio(_portfolio).VAULT() != VAULT
      ) revert NavDesk_PortfolioRefused();
    }
    _setSettings(_portfolio, _custodianAccount, _periodLength, _cooldown, _maxReportAge);
  }

  /// @inheritdoc INavDesk
  function closePeriod() external {
    if (block.timestamp < lastCutoff + periodLength) revert NavDesk_PeriodNotOver();
    lastCutoff = block.timestamp;
    emit CutOff(block.timestamp);
    IGated7540Vault(VAULT).closePeriod();
  }

  /// @inheritdoc INavDesk
  function propose(
    uint256 _reported,
    bytes32 _reportHash,
    uint256 _asOf,
    uint256 _moves
  ) external {
    _onlyRole(REPORTER_ROLE);
    if (_proposal.period != 0) revert NavDesk_ProposalPending();
    (uint64 _period, uint256 _supply) = _closedPeriod();
    if (_asOf < lastCutoff || _asOf > block.timestamp) revert NavDesk_ReportOutOfWindow();
    (address _cash, uint256 _priced) = _cashAndValue(_moves);
    uint256 _nav = _reported + _priced;
    if (_nav == 0 && _supply != 0) revert NavDesk_ZeroNav();

    Proposal memory _p = Proposal({
      period: _period,
      proposedAt: uint64(block.timestamp),
      asOf: uint64(_asOf),
      acceptedAt: 0,
      proposer: msg.sender,
      nav: _nav,
      fee: 0,
      mark: 0,
      reportHash: _reportHash,
      cash: _cash,
      feeRecipient: address(0)
    });
    _proposal = _p;
    emit ProposalMade(hashOf(_p), _period, _reported, _priced, _nav, 0, _reportHash, _asOf);
  }

  /// @inheritdoc INavDesk
  function accept(
    bytes32 _proposalHash
  ) external {
    _onlyRole(CHECKER_ROLE);
    Proposal memory _p = _proposal;
    if (_p.period == 0) revert NavDesk_NoProposal();
    if (_proposalHash != hashOf(_p)) revert NavDesk_ProposalMismatch();
    if (msg.sender == _p.proposer) revert NavDesk_SelfAccept();
    if (_p.acceptedAt != 0) revert NavDesk_AcceptanceWrong();
    _proposal.acceptedAt = uint64(block.timestamp);
    emit ProposalAccepted(_proposalHash, msg.sender);
  }

  /// @inheritdoc INavDesk
  function cancel() external {
    if (!_hasRole(_GUARDIAN_ROLE) && !_hasRole(CHECKER_ROLE)) revert NavDesk_Unauthorized(msg.sender);
    Proposal memory _p = _proposal;
    if (_p.period == 0) revert NavDesk_NoProposal();
    delete _proposal;
    emit ProposalCancelled(hashOf(_p), msg.sender);
  }

  /// @inheritdoc INavDesk
  function execute() external {
    Proposal memory _p = _proposal;
    // Zero here means nothing on the table and nothing accepted, not a balance.
    // slither-disable-next-line incorrect-equality
    if (_p.period == 0) revert NavDesk_NoProposal();
    // slither-disable-next-line incorrect-equality
    if (_p.acceptedAt == 0) revert NavDesk_AcceptanceWrong();
    if (block.timestamp < _p.proposedAt + cooldown) revert NavDesk_TooEarly();
    if (block.timestamp > _p.asOf + maxReportAge) revert NavDesk_StaleReport();
    bytes32 _hash = hashOf(_p);
    delete _proposal;
    emit ProposalExecuted(_hash, _p.period);
    IGated7540Vault(VAULT).settlePeriod(_p.nav, _p.fee, _p.cash, _p.feeRecipient);
  }

  /// @inheritdoc INavDesk
  function refundRequest(
    address _controller,
    bool _isDeposit
  ) external {
    _onlyStuck();
    emit RequestReleased(_controller, _isDeposit, _controller);
    if (_isDeposit) IGated7540Vault(VAULT).rejectDepositRequest(_controller);
    else IGated7540Vault(VAULT).rejectRedeemRequest(_controller);
  }

  /// @inheritdoc INavDesk
  function recoverRequest(
    address _controller,
    address _to
  ) external {
    _onlyStuck();
    emit RequestReleased(_controller, false, _to);
    IGated7540Vault(VAULT).recoverRedeemRequest(_controller, _to);
  }

  /// @inheritdoc INavDesk
  function adopt(
    address _oldDesk
  ) external {
    _onlyRole(_DEFAULT_ADMIN_ROLE);
    INavDesk _old = INavDesk(_oldDesk);
    // View interface: compiled to STATICCALL, so the old desk cannot change state or re-enter before these writes.
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (_adopted || _old.VAULT() != VAULT || _old.proposal().period != 0) revert NavDesk_CannotAdopt();
    _adopted = true;
    lastCutoff = _old.lastCutoff();
    emit DeskAdopted(_oldDesk);
  }

  /// @inheritdoc INavDesk
  function proposal() external view returns (Proposal memory _current) {
    _current = _proposal;
  }

  /// @inheritdoc INavDesk
  function isWired() external view returns (bool _wired) {
    _wired = IAccessControl(VAULT).hasRole(_SETTLER_ROLE, address(this));
  }

  /// @inheritdoc INavDesk
  function hashOf(
    Proposal memory _p
  ) public pure returns (bytes32 _hash) {
    _hash = keccak256(abi.encode(_p.period, _p.nav, _p.fee, _p.mark, _p.reportHash, _p.cash, _p.feeRecipient));
  }

  /**
   * @notice Stores the settings
   * @param _portfolio The portfolio, or zero for none
   * @param _custodianAccount The cash account when there is no portfolio
   * @param _periodLength The time between cut-offs
   * @param _cooldown The time between a proposal and its execution
   * @param _maxReportAge The oldest report that may execute
   */
  function _setSettings(
    address _portfolio,
    address _custodianAccount,
    uint256 _periodLength,
    uint256 _cooldown,
    uint256 _maxReportAge
  ) private {
    if (_periodLength == 0 || _maxReportAge == 0) revert NavDesk_ZeroValue();
    if (_cooldown < MIN_COOLDOWN || _cooldown > MAX_COOLDOWN) revert NavDesk_InvalidCooldown(_cooldown);
    if (_maxReportAge < _cooldown) revert NavDesk_ReportAgeBelowCooldown(_maxReportAge, _cooldown);
    // Zero is a choice for both: no portfolio, or a portfolio to be plugged.
    // aderyn-ignore-next-line(state-no-address-check)
    portfolio = _portfolio;
    // aderyn-ignore-next-line(state-no-address-check)
    custodianAccount = _custodianAccount;
    periodLength = _periodLength;
    cooldown = _cooldown;
    maxReportAge = _maxReportAge;
    emit SettingsChanged(_portfolio, _custodianAccount, _periodLength, _cooldown, _maxReportAge);
  }

  /**
   * @notice The period a proposal would price
   * @return _period The closed period
   * @return _supply All shares, unclaimed included
   */
  function _closedPeriod() private view returns (uint64 _period, uint256 _supply) {
    (uint64 _open, uint64 _settled, uint256 _unclaimed) = IGated7540Vault(VAULT).dealingState();
    _period = _settled + 1;
    if (_period == _open) revert NavDesk_NoClosedPeriod();
    _supply = IERC20(VAULT).totalSupply() + _unclaimed;
  }

  /**
   * @notice The cash account and the on-chain value, checked against the report's move count
   * @param _moves The portfolio's `moves()` the report was struck against
   * @return _cash The cash account
   * @return _priced What the portfolio prices on-chain; 0 with none
   */
  function _cashAndValue(
    uint256 _moves
  ) private view returns (address _cash, uint256 _priced) {
    address _portfolio = portfolio;
    _cash = _portfolio == address(0) ? custodianAccount : _portfolio;
    if (_cash == address(0)) revert NavDesk_NoCashAccount();
    uint256 _currentMoves = _portfolio == address(0) ? 0 : IPortfolio(_portfolio).moves();
    if (_moves != _currentMoves) revert NavDesk_MovesChanged(_moves, _currentMoves);
    if (_portfolio != address(0)) {
      if (!IPortfolio(_portfolio).priceFresh()) revert NavDesk_PriceNotFresh();
      _priced = IPortfolio(_portfolio).pricedValue();
    }
  }

  /// @notice Reverts unless the caller is the agent, nothing is on the table and the period has been closed long enough
  function _onlyStuck() private view {
    _onlyRole(_AGENT_ROLE);
    if (_proposal.period != 0) revert NavDesk_ProposalPending();
    // The unclaimed shares say nothing about whether a period is stuck.
    // slither-disable-next-line unused-return
    (uint64 _open, uint64 _settled,) = IGated7540Vault(VAULT).dealingState();
    if (_settled + 1 == _open || block.timestamp <= lastCutoff + maxReportAge) revert NavDesk_NotStuck();
  }

  /**
   * @notice Reverts unless the caller holds a vault role
   * @param _role The role
   */
  function _onlyRole(
    bytes32 _role
  ) private view {
    if (!_hasRole(_role)) revert NavDesk_Unauthorized(msg.sender);
  }

  /**
   * @notice Whether the caller holds a vault role, asked live
   * @param _role The role
   * @return _holds True when it does
   */
  function _hasRole(
    bytes32 _role
  ) private view returns (bool _holds) {
    _holds = IAccessControl(VAULT).hasRole(_role, msg.sender);
  }
}
