// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Address} from '@openzeppelin/contracts/utils/Address.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

import {ERC20Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC7540Deposit} from 'interfaces/IERC7540Deposit.sol';
import {IERC7540Operator} from 'interfaces/IERC7540Operator.sol';
import {IERC7540Redeem} from 'interfaces/IERC7540Redeem.sol';
import {IERC7575} from 'interfaces/IERC7575.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';

import {PolicyGatedERC20Upgradeable} from 'contracts/base/PolicyGatedERC20Upgradeable.sol';
import {Gated7540Common} from 'contracts/vaults/Gated7540Common.sol';
import {Gated7540Settlement} from 'contracts/vaults/Gated7540Settlement.sol';

/**
 * @title Gated7540Vault
 * @notice ERC-7540 asynchronous vault whose shares are a policy-gated token, dealt in periods, as specified in
 *         `IGated7540Vault`
 * @dev Deployed behind a UUPS proxy. It does not inherit OpenZeppelin's ERC-4626: it would have to override almost all of
 *      it and claim to be a synchronous vault while its previews revert (owner decision P13). Everything an investor or an
 *      operator calls runs here; closing, settling, rejecting and recovering are named here and run in `SETTLEMENT_LOGIC`
 */
// IERC7575 re-declares every ERC-4626 function; inheriting both would need dual override specifiers on each. Conformance
// is pinned by the 0x2f0a18c5 ERC-165 test and full function coverage.
// No receive or payable function, and upgradeToAndCall rejects value: no ETH can enter (tests: *_Ether).
// Slither missing-inheritance spans the whole contract, so its suppression block closes after the last line.
// slither-disable-start missing-inheritance
// aderyn-ignore-next-line(contract-locks-ether)
contract Gated7540Vault is
  Gated7540Common,
  IERC4626,
  IERC7540Operator,
  IERC7540Deposit,
  IERC7540Redeem,
  IGated7540Vault
{
  using SafeERC20 for IERC20;
  using SafeCast for uint256;

  /// @inheritdoc IGated7540Vault
  bytes32 public constant SETTLER_ROLE = _SETTLER_ROLE;

  /**
   * @inheritdoc IGated7540Vault
   * @custom:oz-upgrades-unsafe-allow state-variable-immutable
   */
  address public immutable SETTLEMENT_LOGIC;

  /**
   * @notice Creates the second contract and locks the implementation; only proxies can be initialized
   * @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable state-variable-assignment
   */
  constructor() {
    SETTLEMENT_LOGIC = address(new Gated7540Settlement());
    _disableInitializers();
  }

  /// @inheritdoc IGated7540Vault
  function initialize(
    IERC20 _asset,
    string memory _name,
    string memory _symbol,
    address _admin,
    address _guardian,
    address _registry,
    address _hook,
    IComplianceRule[] memory _initialRules
  ) external initializer {
    if (address(_asset) == address(0)) revert Gated7540Vault_ZeroAddress();
    Gated7540Storage storage $ = _getGated7540Storage();
    $.asset = _asset;
    // 6 is the digits of `_VIRTUAL_SHARES`. A view interface: compiled to STATICCALL, so the asset cannot change state or
    // re-enter before the write below.
    // aderyn-ignore-next-line(reentrancy-state-change)
    $.decimals = IERC20Metadata(address(_asset)).decimals() + 6;
    $.openPeriod = 1;
    __ERC20_init(_name, _symbol);
    __ERC20Permit_init(_name);
    __PolicyGatedCore_init(_admin, _guardian, _registry, _hook, _initialRules);
  }

  /// @inheritdoc IERC7540Deposit
  function requestDeposit(
    uint256 _assets,
    address _controller,
    address _owner
  ) external returns (uint256 _requestId) {
    if (_assets == 0) revert Gated7540Vault_ZeroAmount();
    if (_controller == address(0)) revert Gated7540Vault_ZeroAddress();
    Gated7540Storage storage $ = _getGated7540Storage();
    address _sender = _msgSender();
    if (_owner != _sender && !$.operators[_owner][_sender]) revert Gated7540Vault_Unauthorized(_sender);
    // No cancellation exists, so refuse assets from a controller that could not hold the shares.
    bytes32 _reason = _mintProbe(_controller);
    if (_reason != Reasons.TRANSFER_OK) revert Gated7540Vault_ControllerNotEligible(_reason);
    _requireThirdPartyEligible(_owner, _controller);

    _join(_controller, _assets, true);
    $.pendingDeposits += _assets;
    emit DepositRequest(_controller, _owner, 0, _sender, _assets);
    // `_owner` is authorised above: the caller itself, or an operator the owner approved (ERC-7540 operators are trusted).
    // Aderyn's form of the Slither finding below; same guard, same tests.
    // slither-disable-next-line arbitrary-send-erc20
    $.asset.safeTransferFrom(_owner, address(this), _assets); // aderyn-ignore(arbitrary-transfer-from)
    _requestId = 0;
  }

  /// @inheritdoc IERC7540Redeem
  function requestRedeem(
    uint256 _shares,
    address _controller,
    address _owner
  ) external returns (uint256 _requestId) {
    if (_shares == 0) revert Gated7540Vault_ZeroAmount();
    if (_controller == address(0)) revert Gated7540Vault_ZeroAddress();
    Gated7540Storage storage $ = _getGated7540Storage();
    address _sender = _msgSender();
    if (_owner != _sender && !$.operators[_owner][_sender]) _spendAllowance(_owner, _sender, _shares);
    // Otherwise a holder could name a lapsed address as controller, which, paying itself, would collect the cash.
    _requireThirdPartyEligible(_controller, _owner);

    _join(_controller, _shares, false);
    $.pendingRedeemShares += _shares;
    emit RedeemRequest(_controller, _owner, 0, _sender, _shares);
    // Escrow as a TRANSFER through the hook: lockup, frozen, identity and pause all apply.
    _transfer(_owner, address(this), _shares);
    _requestId = 0;
  }

  /// @inheritdoc IGated7540Vault
  function closePeriod() external {
    _toSettlement();
  }

  /// @inheritdoc IGated7540Vault
  function settlePeriod(
    uint256,
    uint256,
    address,
    address,
    uint256
  ) external {
    _toSettlement();
  }

  /// @inheritdoc IGated7540Vault
  function rejectDepositRequest(
    address
  ) external {
    _toSettlement();
  }

  /// @inheritdoc IGated7540Vault
  function rejectRedeemRequest(
    address
  ) external {
    _toSettlement();
  }

  /// @inheritdoc IGated7540Vault
  function recoverClaimable(
    address,
    address
  ) external {
    _toSettlement();
  }

  /// @inheritdoc IGated7540Vault
  function recoverRedeemRequest(
    address,
    address
  ) external {
    _toSettlement();
  }

  /// @inheritdoc IERC7540Operator
  function setOperator(
    address _operator,
    bool _approved
  ) external returns (bool _success) {
    address _controller = _msgSender();
    _getGated7540Storage().operators[_controller][_operator] = _approved;
    emit OperatorSet(_controller, _operator, _approved);
    _success = true;
  }

  /// @inheritdoc IERC7540Deposit
  function deposit(
    uint256 _assets,
    address _receiver,
    address _controller
  ) external returns (uint256 _shares) {
    (, _shares) = _claimShares(_assets, _receiver, _controller, true);
  }

  /// @inheritdoc IERC7540Deposit
  function mint(
    uint256 _shares,
    address _receiver,
    address _controller
  ) external returns (uint256 _assets) {
    (_assets,) = _claimShares(_shares, _receiver, _controller, false);
  }

  /// @inheritdoc IERC4626
  function deposit(
    uint256 _assets,
    address _receiver
  ) external returns (uint256 _shares) {
    (, _shares) = _claimShares(_assets, _receiver, _msgSender(), true);
  }

  /// @inheritdoc IERC4626
  function mint(
    uint256 _shares,
    address _receiver
  ) external returns (uint256 _assets) {
    (_assets,) = _claimShares(_shares, _receiver, _msgSender(), false);
  }

  /**
   * @inheritdoc IERC4626
   * @dev Claims settled redemption assets; the third argument is the controller (ERC-7540)
   */
  function redeem(
    uint256 _shares,
    address _receiver,
    address _controller
  ) external returns (uint256 _assets) {
    (, _assets) = _claimCash(_shares, _receiver, _controller, true);
  }

  /**
   * @inheritdoc IERC4626
   * @dev Claims settled redemption assets; the third argument is the controller (ERC-7540)
   */
  function withdraw(
    uint256 _assets,
    address _receiver,
    address _controller
  ) external returns (uint256 _shares) {
    (_shares,) = _claimCash(_assets, _receiver, _controller, false);
  }

  /// @inheritdoc IERC4626
  function asset() external view returns (address _assetTokenAddress) {
    _assetTokenAddress = address(_getGated7540Storage().asset);
  }

  /// @inheritdoc IERC7540Deposit
  function claimableDepositRequest(
    uint256,
    address _controller
  ) external view returns (uint256 _claimableAssets) {
    _claimableAssets = _request(_controller, true).paid;
  }

  /// @inheritdoc IERC7540Redeem
  function claimableRedeemRequest(
    uint256,
    address _controller
  ) external view returns (uint256 _claimableShares) {
    _claimableShares = _request(_controller, false).paid;
  }

  /// @inheritdoc IGated7540Vault
  function dealingState() external view returns (uint64 _open, uint64 _settled, uint256 _unclaimedShares) {
    Gated7540Storage storage $ = _getGated7540Storage();
    (_open, _settled, _unclaimedShares) = ($.openPeriod, $.settledPeriod, $.unclaimedShares);
  }

  /// @inheritdoc IGated7540Vault
  function periodBook(
    uint256 _period,
    bool _isDeposit
  ) external view returns (uint256 _paid, uint256 _owed, uint256 _carried) {
    Book storage _book = _getGated7540Storage().books[_period][_isDeposit];
    (_paid, _owed, _carried) = (_book.paid, _book.owed, _book.carried);
  }

  /// @inheritdoc IERC7540Operator
  function isOperator(
    address _controller,
    address _operator
  ) external view returns (bool _status) {
    _status = _getGated7540Storage().operators[_controller][_operator];
  }

  /// @inheritdoc IERC7540Deposit
  function pendingDepositRequest(
    uint256,
    address _controller
  ) external view returns (uint256 _pendingAssets) {
    _pendingAssets = _request(_controller, true).pending;
  }

  /// @inheritdoc IERC7540Redeem
  function pendingRedeemRequest(
    uint256,
    address _controller
  ) external view returns (uint256 _pendingShares) {
    _pendingShares = _request(_controller, false).pending;
  }

  /**
   * @notice The share token (ERC-7575)
   * @return _shareTokenAddress This vault
   */
  function share() external view returns (address _shareTokenAddress) {
    _shareTokenAddress = address(this);
  }

  /**
   * @inheritdoc IERC4626
   * @dev At the last settlement's value, indicative only
   */
  function convertToShares(
    uint256 _assets
  ) external view returns (uint256 _shares) {
    Gated7540Storage storage $ = _getGated7540Storage();
    _shares = Math.mulDiv(_assets, uint256($.lastSupply) + _VIRTUAL_SHARES, uint256($.lastNav) + 1);
  }

  /**
   * @inheritdoc IERC4626
   * @dev The controller's claimable deposit assets; 0 when paused, when the controller could not receive shares, or when
   *      they bought no shares
   */
  function maxDeposit(
    address _controller
  ) external view returns (uint256 _maxAssets) {
    if (_mintProbe(_controller) != Reasons.TRANSFER_OK) return 0;
    Request memory _r = _request(_controller, true);
    // A request that bought no shares cannot be claimed by its assets.
    _maxAssets = _r.owed == 0 ? 0 : _r.paid;
  }

  /**
   * @inheritdoc IERC4626
   * @dev The controller's claimable deposit shares; 0 when paused or when the controller could not receive shares
   */
  function maxMint(
    address _controller
  ) external view returns (uint256 _maxShares) {
    if (_mintProbe(_controller) != Reasons.TRANSFER_OK) return 0;
    _maxShares = _request(_controller, true).owed;
  }

  /**
   * @inheritdoc IERC4626
   * @dev The controller's claimable redemption shares; 0 when paused, when a burn from the controller would be rejected,
   *      or when they pay nothing
   */
  function maxRedeem(
    address _controller
  ) external view returns (uint256 _maxShares) {
    if (_payoutReason(_controller) != Reasons.TRANSFER_OK) return 0;
    Request memory _r = _request(_controller, false);
    // A redemption that pays nothing cannot be claimed by its shares.
    _maxShares = _r.owed == 0 ? 0 : _r.paid;
  }

  /**
   * @inheritdoc IERC4626
   * @dev The controller's claimable redemption assets; 0 when paused or when a burn from the controller would be rejected
   */
  function maxWithdraw(
    address _controller
  ) external view returns (uint256 _maxAssets) {
    if (_payoutReason(_controller) != Reasons.TRANSFER_OK) return 0;
    _maxAssets = _request(_controller, false).owed;
  }

  /**
   * @inheritdoc IERC4626
   * @dev Indicative only: all shares, unclaimed included, at the last settlement's value
   */
  function totalAssets() external view returns (uint256 _totalManagedAssets) {
    _totalManagedAssets = convertToAssets(totalSupply() + _getGated7540Storage().unclaimedShares);
  }

  /**
   * @inheritdoc IERC4626
   * @dev Always reverts, as ERC-7540 requires for asynchronous flows
   */
  function previewDeposit(
    uint256
  ) external pure returns (uint256) {
    revert Gated7540Vault_AsyncOnly();
  }

  /**
   * @inheritdoc IERC4626
   * @dev Always reverts, as ERC-7540 requires for asynchronous flows
   */
  function previewMint(
    uint256
  ) external pure returns (uint256) {
    revert Gated7540Vault_AsyncOnly();
  }

  /**
   * @inheritdoc IERC4626
   * @dev Always reverts, as ERC-7540 requires for asynchronous flows
   */
  function previewRedeem(
    uint256
  ) external pure returns (uint256) {
    revert Gated7540Vault_AsyncOnly();
  }

  /**
   * @inheritdoc IERC4626
   * @dev Always reverts, as ERC-7540 requires for asynchronous flows
   */
  function previewWithdraw(
    uint256
  ) external pure returns (uint256) {
    revert Gated7540Vault_AsyncOnly();
  }

  /**
   * @inheritdoc PolicyGatedERC20Upgradeable
   * @dev Out of the vault's own address, only the shares above those booked to pending redemptions can be forced
   *      (`Gated7540Vault_ExceedsSurplus`): shares that reached the vault outside a request. A pending redemption
   *      leaves the escrow only through settlement, reject or `recoverRedeemRequest`, per controller. The role is
   *      checked first, so a caller without AGENT_ROLE gets the access error whatever it asks
   */
  function forcedTransfer(
    address _from,
    address _to,
    uint256 _amount
  ) public override onlyRole(AGENT_ROLE) returns (bool _result) {
    if (_from == address(this)) {
      uint256 _balance = balanceOf(address(this));
      uint256 _booked = _getGated7540Storage().pendingRedeemShares;
      uint256 _surplus = _balance > _booked ? _balance - _booked : 0;
      if (_amount > _surplus) revert Gated7540Vault_ExceedsSurplus(_amount, _surplus);
    }
    _result = super.forcedTransfer(_from, _to, _amount);
  }

  /**
   * @inheritdoc PolicyGatedERC20Upgradeable
   * @dev Reverts for the vault's own address: the escrow is shared by every controller, so a frozen amount there
   *      could not name whose redemption it holds. One controller's redemption is held by rejecting or recovering it
   */
  function setFrozenTokens(
    address _account,
    uint256 _amount
  ) public override onlyRole(AGENT_ROLE) returns (bool _result) {
    if (_account == address(this)) revert GatedVault_Unsupported();
    _result = super.setFrozenTokens(_account, _amount);
  }

  /**
   * @inheritdoc IERC4626
   * @dev At the last settlement's value, indicative only
   */
  function convertToAssets(
    uint256 _shares
  ) public view returns (uint256 _assets) {
    Gated7540Storage storage $ = _getGated7540Storage();
    _assets = Math.mulDiv(_shares, uint256($.lastNav) + 1, uint256($.lastSupply) + _VIRTUAL_SHARES);
  }

  /**
   * @notice The share decimals
   * @return _decimals The asset's plus 6
   */
  function decimals() public view override(ERC20Upgradeable, IERC20Metadata) returns (uint8 _decimals) {
    _decimals = _getGated7540Storage().decimals;
  }

  /// @inheritdoc PolicyGatedERC20Upgradeable
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(IERC7540Operator).interfaceId || _interfaceId == type(IERC7540Deposit).interfaceId
      || _interfaceId == type(IERC7540Redeem).interfaceId || _interfaceId == type(IERC7575).interfaceId
      || super.supportsInterface(_interfaceId);
  }

  /// @inheritdoc ITemplated
  function templateId() public pure override returns (bytes32 _id) {
    _id = keccak256('Gated7540Vault');
  }

  /**
   * @notice Adds to a controller's request in the open period, rolling a settled one into its claimable amounts first
   * @param _controller The controller
   * @param _amount What it gives
   * @param _isDeposit True on the deposit side
   */
  function _join(
    address _controller,
    uint256 _amount,
    bool _isDeposit
  ) private {
    Gated7540Storage storage $ = _getGated7540Storage();
    Request memory _r = _request(_controller, _isDeposit);
    uint64 _open = $.openPeriod;
    if (_r.period != 0 && _r.period != _open) revert Gated7540Vault_EarlierRequestUnsettled(_r.period);
    uint128 _added = _amount.toUint128();
    _r.period = _open;
    _r.pending += _added;
    _store(_controller, _isDeposit, _r);
    $.books[_open][_isDeposit].paid += _added;
  }

  /**
   * @notice Takes part of a controller's claimable amounts. Given what was paid, the other side rounds down; given what
   *         is owed, the paid side rounds up; a full claim clears exactly, because the rounding has nothing to round
   * @param _controller The controller
   * @param _amount The amount claimed
   * @param _isDeposit True on the deposit side
   * @param _givenPaid True when `_amount` is of what was paid
   * @return _paid What the claim consumed of what was paid
   * @return _owed What it delivers
   */
  function _claim(
    address _controller,
    uint256 _amount,
    bool _isDeposit,
    bool _givenPaid
  ) private returns (uint256 _paid, uint256 _owed) {
    if (_amount == 0) revert Gated7540Vault_ZeroAmount();
    Request memory _r = _request(_controller, _isDeposit);
    uint256 _claimable = _givenPaid ? _r.paid : _r.owed;
    if (_amount > _claimable) revert Gated7540Vault_ExceedsClaimable(_amount, _claimable);
    if (_givenPaid) {
      (_paid, _owed) = (_amount, Math.mulDiv(_amount, _r.owed, _r.paid));
    } else {
      (_paid, _owed) = (Math.mulDiv(_amount, _r.paid, _r.owed, Math.Rounding.Ceil), _amount);
    }
    if (_givenPaid && _owed == 0) revert Gated7540Vault_ZeroAmount();
    // Neither exceeds what the request holds, each being a share of it at most, so both fit.
    // aderyn-ignore-next-line(unsafe-casting)
    _r.paid -= uint128(_paid);
    // aderyn-ignore-next-line(unsafe-casting)
    _r.owed -= uint128(_owed);
    _store(_controller, _isDeposit, _r);
  }

  /**
   * @notice Claims settled deposit shares (MINT through the hook)
   * @param _amount The amount claimed
   * @param _receiver The receiver of the shares
   * @param _controller The controller
   * @param _givenAssets True when `_amount` is in assets
   * @return _assets The claimable assets consumed
   * @return _shares The shares minted
   */
  function _claimShares(
    uint256 _amount,
    address _receiver,
    address _controller,
    bool _givenAssets
  ) private returns (uint256 _assets, uint256 _shares) {
    _onlyControllerOrOperator(_controller);
    bytes32 _reason = _mintProbe(_controller);
    if (_reason != Reasons.TRANSFER_OK) revert Gated7540Vault_ControllerNotEligible(_reason);
    (_assets, _shares) = _claim(_controller, _amount, true, _givenAssets);
    _getGated7540Storage().unclaimedShares -= _shares;
    emit Deposit(_controller, _receiver, _assets, _shares);
    _mint(_receiver, _shares);
  }

  /**
   * @notice Claims settled redemption cash
   * @param _amount The amount claimed
   * @param _receiver The receiver of the assets
   * @param _controller The controller
   * @param _givenShares True when `_amount` is in shares
   * @return _shares The claimable shares consumed
   * @return _assets The assets paid
   */
  function _claimCash(
    uint256 _amount,
    address _receiver,
    address _controller,
    bool _givenShares
  ) private whenNotPaused returns (uint256 _shares, uint256 _assets) {
    _onlyControllerOrOperator(_controller);
    bytes32 _reason = _payoutReason(_controller);
    if (_reason != Reasons.TRANSFER_OK) revert Gated7540Vault_ControllerNotEligible(_reason);
    _requireThirdPartyEligible(_receiver, _controller);
    (_shares, _assets) = _claim(_controller, _amount, false, _givenShares);
    Gated7540Storage storage $ = _getGated7540Storage();
    $.claimableCash -= _assets;
    emit Withdraw(_msgSender(), _receiver, _controller, _assets, _shares);
    $.asset.safeTransfer(_receiver, _assets);
  }

  /**
   * @notice Hands this call to the second contract, unchanged, and passes back a revert as it came
   * @custom:oz-upgrades-unsafe-allow-reachable delegatecall
   */
  function _toSettlement() private {
    // The moved functions return nothing, and the target is this implementation's own immutable.
    // slither-disable-next-line unused-return
    Address.functionDelegateCall(SETTLEMENT_LOGIC, msg.data); // aderyn-ignore(unchecked-return)
  }

  /**
   * @notice The policy verdict on a controller collecting a redemption payout: a zero-amount burn by the controller.
   *         Checks who the controller is (identity, lockup, pause) without the frozen-balance check, since its shares
   *         were escrowed and burned at settlement and it typically holds none
   * @param _controller The controller
   * @return _reason TRANSFER_OK or the policy's reason code
   */
  function _payoutReason(
    address _controller
  ) private view returns (bytes32 _reason) {
    _reason = _canTransfer(_controller, address(0), 0);
  }

  /**
   * @notice Reverts unless the caller is the controller or one of its operators
   * @param _controller The controller
   */
  function _onlyControllerOrOperator(
    address _controller
  ) private view {
    address _sender = _msgSender();
    if (_sender != _controller && !_getGated7540Storage().operators[_controller][_sender]) {
      revert Gated7540Vault_Unauthorized(_sender);
    }
  }
}
// slither-disable-end missing-inheritance
