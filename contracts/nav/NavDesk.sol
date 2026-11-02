// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IFeeModel} from 'interfaces/IFeeModel.sol';
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

  /// @notice A share of the fund's scale: 10,000 basis points are the whole fund
  uint256 private constant _BPS = 1e4;

  /// @notice The vault's virtual shares, in the price it deals at
  uint256 private constant _VIRTUAL_SHARES = 1e6;

  /// @notice A price's scale: assets per this many share units
  uint256 private constant _PRICE_SCALE = 1e18;

  /// @notice The mark at par, the lowest it can be, and where a period with no shares strikes: the vault deals 1e6 share
  ///         units per unit of its asset. Getting back to par recovers principal, and is no gain
  uint256 private constant _PAR_MARK = _PRICE_SCALE / 1e6;

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

  /// @inheritdoc INavDesk
  address public feeModel;

  /// @inheritdoc INavDesk
  uint256 public mark;

  /// @inheritdoc INavDesk
  uint256 public markMovedAt;

  /// @inheritdoc INavDesk
  uint256 public lastFeeAt;

  /// @inheritdoc INavDesk
  uint256 public redemptionGate;

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
          || IPortfolio(_portfolio).ASSET() != IERC20(IERC4626(VAULT).asset())
      ) revert NavDesk_PortfolioRefused();
    }
    _setSettings(_portfolio, _custodianAccount, _periodLength, _cooldown, _maxReportAge);
  }

  /// @inheritdoc INavDesk
  function setRedemptionGate(
    uint256 _gateBps
  ) external {
    _onlyRole(_DEFAULT_ADMIN_ROLE);
    _setRedemptionGate(_gateBps);
  }

  /// @inheritdoc INavDesk
  function setFeeModel(
    address _feeModel
  ) external {
    _onlyRole(_DEFAULT_ADMIN_ROLE);
    if (_feeModel != address(0)) {
      // View interfaces, compiled to STATICCALL: nothing re-enters before the writes below.
      // aderyn-ignore-next-line(reentrancy-state-change)
      IPolicyRegistry _registry = IPolicyRegistry(IPolicyGated(VAULT).registry());
      // aderyn-ignore-next-line(reentrancy-state-change)
      if (!_registry.isAttested(_feeModel, IPolicyRegistry.AttestKind.FEE_MODEL)) {
        revert NavDesk_FeeModelRefused(_feeModel);
      }
      if (feeModel == address(0)) {
        // Zero means no mark yet, not a balance.
        // slither-disable-next-line incorrect-equality
        if (mark == 0) {
          // aderyn-ignore-next-line(reentrancy-state-change)
          mark = Math.max(IERC4626(VAULT).convertToAssets(_PRICE_SCALE), _PAR_MARK);
          markMovedAt = block.timestamp;
        }
        lastFeeAt = block.timestamp;
      }
    }
    feeModel = _feeModel;
    emit FeeModelSet(_feeModel);
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
    if (_asOf < lastCutoff || _asOf > block.timestamp) revert NavDesk_ReportOutOfWindow();
    // Filled in below, a field at a time.
    // slither-disable-next-line uninitialized-local
    Proposal memory _p;
    uint256 _supply;
    (_p.period, _supply) = _closedPeriod();
    uint256 _priced;
    (_p.cash, _priced) = _cashAndValue(_moves);
    // With no shares nothing is anyone's. A price struck on what is reported or left in the portfolio would be charged as
    // a gain on the next investors' principal, and refusing would let a stranger's donation stop the period.
    uint256 _gross = _supply == 0 ? 0 : _reported + _priced;
    _quote(_p, _gross, _supply);
    _p.nav = _gross - _p.fee;
    if (_p.nav == 0 && _supply != 0) revert NavDesk_ZeroNav();
    _p.proposedAt = uint64(block.timestamp);
    _p.asOf = uint64(_asOf);
    _p.proposer = msg.sender;
    _p.reportHash = _reportHash;
    _p.redeemLimit = _redeemLimit(_p.period, _p.nav, _supply);
    _proposal = _p;
    _announce(_p, _reported, _priced);
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
    // The supply says nothing about which period is closed.
    // slither-disable-next-line unused-return
    (uint64 _closed,) = _closedPeriod();
    if (_p.period != _closed) revert NavDesk_WrongPeriod(_p.period, _closed);
    bytes32 _hash = hashOf(_p);
    delete _proposal;
    // With no model it froze no fee state, and a first plug since then must keep its own. A model always names a recipient.
    if (_p.feeRecipient != address(0)) {
      mark = _p.mark;
      markMovedAt = _p.markMovedAt;
      lastFeeAt = _p.proposedAt;
    }
    emit ProposalExecuted(_hash, _p.period);
    IGated7540Vault(VAULT).settlePeriod(_p.nav, _p.fee, _p.cash, _p.feeRecipient, _p.redeemLimit);
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
    // aderyn-ignore-next-line(reentrancy-state-change)
    lastCutoff = _old.lastCutoff();
    // A desk that never charged has no mark to pass on, and a plug made here must keep its own.
    // aderyn-ignore-next-line(reentrancy-state-change)
    uint256 _oldMark = _old.mark();
    if (_oldMark != 0) {
      mark = _oldMark;
      // aderyn-ignore-next-line(reentrancy-state-change)
      markMovedAt = _old.markMovedAt();
    }
    // With its model off the old desk's fee clock stopped, and no fee is due for the time since.
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (_old.feeModel() != address(0)) lastFeeAt = _old.lastFeeAt();
    // A replacement that forgot the level would lift the gate without anyone deciding to.
    // aderyn-ignore-next-line(reentrancy-state-change)
    _setRedemptionGate(_old.redemptionGate());
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
    _hash = keccak256(
      abi.encode(
        _p.period,
        _p.nav,
        _p.fee,
        _p.mark,
        _p.markMovedAt,
        _p.reportHash,
        _p.cash,
        _p.feeRecipient,
        _p.asOf,
        _p.redeemLimit
      )
    );
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
   * @notice Stores the redemption gate's level
   * @param _gateBps The level in basis points; zero is off
   */
  function _setRedemptionGate(
    uint256 _gateBps
  ) private {
    if (_gateBps > _BPS) revert NavDesk_InvalidGate(_gateBps);
    redemptionGate = _gateBps;
    emit RedemptionGateSet(_gateBps);
  }

  /**
   * @notice Announces a proposal
   * @param _p The proposal
   * @param _reported What the reporter said of everything not priced on-chain
   * @param _priced What the portfolio priced on-chain
   */
  function _announce(
    Proposal memory _p,
    uint256 _reported,
    uint256 _priced
  ) private {
    emit ProposalMade(hashOf(_p), _p.period, _reported, _priced, _p.nav, _p.fee, _p.reportHash, _p.asOf, _p.redeemLimit);
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
   * @notice The most shares a period may take from its redemptions: the level's share of all shares, plus the shares the
   *         period's deposits buy at this price, so that the level measures what leaves net of what comes in. Nothing moves
   *         these figures while a proposal is on the table: the closed book changes only through `_onlyStuck` paths, and a
   *         claim or a recovery leaves the shares the same
   * @param _period The period
   * @param _nav The net asset value it deals at
   * @param _supply All shares
   * @return _limit The limit; `type(uint256).max` with the gate off
   */
  function _redeemLimit(
    uint64 _period,
    uint256 _nav,
    uint256 _supply
  ) private view returns (uint256 _limit) {
    uint256 _gate = redemptionGate;
    if (_gate == 0) return type(uint256).max;
    // Of the book, only what the deposits paid is wanted.
    // slither-disable-next-line unused-return
    (uint256 _deposits,,) = IGated7540Vault(VAULT).periodBook(_period, true);
    _limit = Math.mulDiv(_supply, _gate, _BPS) + Math.mulDiv(_deposits, _supply + _VIRTUAL_SHARES, _nav + 1);
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

  /**
   * @notice Fills in the fee, the mark and its clock
   * @param _p The proposal being drawn up
   * @param _gross The gross value
   * @param _supply All shares
   */
  function _quote(
    Proposal memory _p,
    uint256 _gross,
    uint256 _supply
  ) private view {
    // With no shares the mark starts at the price they strike, and both clocks restart, so the first investors do not pay
    // for time before they arrived.
    _p.mark = _supply == 0 ? _PAR_MARK : mark;
    _p.markMovedAt = _supply == 0 ? block.timestamp : markMovedAt;
    address _feeModel = feeModel;
    if (_feeModel == address(0)) return;
    bool _moved;
    (_p.fee, _p.mark, _moved) =
      IFeeModel(_feeModel).quote(_gross, _supply, _p.mark, block.timestamp - markMovedAt, block.timestamp - lastFeeAt);
    if (_moved) _p.markMovedAt = block.timestamp;
    _p.feeRecipient = IFeeModel(_feeModel).RECIPIENT();
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
