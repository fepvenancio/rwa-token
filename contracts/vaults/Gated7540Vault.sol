// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import {ERC4626Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IERC7540Deposit} from 'interfaces/IERC7540Deposit.sol';
import {IERC7540Operator} from 'interfaces/IERC7540Operator.sol';
import {IERC7540Redeem} from 'interfaces/IERC7540Redeem.sol';
import {IERC7575} from 'interfaces/IERC7575.sol';
import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
// Needed by the compiler to resolve `@inheritdoc IPolicyGated`; solhint does not see NatSpec usage.
// solhint-disable-next-line no-unused-vars
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {PolicyGatedERC20Upgradeable} from 'contracts/base/PolicyGatedERC20Upgradeable.sol';

/**
 * @title Gated7540Vault
 * @notice ERC-7540 asynchronous vault whose shares are a policy-gated token, as specified in `IGated7540Vault`
 * @dev Deployed behind a UUPS proxy. Share decimals equal the asset's (no offset: prices are set explicitly by the
 *      fulfiller, so there is no on-chain exchange rate to inflate)
 */
// IERC7575 re-declares every ERC-4626 function already inherited via OZ IERC4626; inheriting both would need dual
// override specifiers on each. Conformance is pinned by the 0x2f0a18c5 ERC-165 test and full function coverage.
// slither-disable-next-line missing-inheritance
contract Gated7540Vault is
  ERC4626Upgradeable,
  PolicyGatedERC20Upgradeable,
  IERC7540Operator,
  IERC7540Deposit,
  IERC7540Redeem,
  IGated7540Vault
{
  using SafeERC20 for IERC20;

  /**
   * @notice A controller's deposit request
   * @param pendingAssets Requested, not yet fulfilled
   * @param claimableAssets Fulfilled assets not yet claimed
   * @param claimableShares Shares those assets buy, not yet minted
   */
  struct DepositState {
    uint256 pendingAssets;
    uint256 claimableAssets;
    uint256 claimableShares;
  }

  /**
   * @notice A controller's redemption request
   * @param pendingShares Escrowed in the vault, not yet fulfilled
   * @param claimableShares Fulfilled (burned) shares not yet claimed
   * @param claimableAssets Assets those shares pay, held for the claim
   */
  struct RedeemState {
    uint256 pendingShares;
    uint256 claimableShares;
    uint256 claimableAssets;
  }

  /**
   * @notice ERC-7201 namespaced storage of the vault
   * @param custody Receives fulfilled deposit assets
   * @param lastPrice Assets per `10**decimals()` shares at the last fulfilment
   * @param deposits Deposit requests per controller
   * @param redeems Redemption requests per controller
   * @param operators Operator approvals per controller
   * @custom:storage-location erc7201:gated.storage.Gated7540Vault
   */
  struct Gated7540Storage {
    address custody;
    uint256 lastPrice;
    mapping(address _controller => DepositState _state) deposits;
    mapping(address _controller => RedeemState _state) redeems;
    mapping(address _controller => mapping(address _operator => bool _approved)) operators;
  }

  /// @inheritdoc IGated7540Vault
  bytes32 public constant FULFILLER_ROLE = keccak256('FULFILLER_ROLE');

  /// @notice keccak256(abi.encode(uint256(keccak256('gated.storage.Gated7540Vault')) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _GATED_7540_STORAGE_LOCATION =
    0x2cc225a2bfbd5a47b58fbfec984f4f856b2fa5e8b68081e6d3300ec76f5f3900;

  /**
   * @notice Locks the implementation; only proxies can be initialized
   * @custom:oz-upgrades-unsafe-allow constructor
   */
  constructor() {
    _disableInitializers();
  }

  /// @inheritdoc IGated7540Vault
  function initialize(
    IERC20 _asset,
    string calldata _name,
    string calldata _symbol,
    address _admin,
    address _guardian,
    address _registry,
    address _hook,
    address _custody
  ) external initializer {
    if (_custody == address(0)) revert Gated7540Vault_ZeroAddress();
    __ERC4626_init(_asset);
    __PolicyGatedERC20_init(_name, _symbol, _admin, _guardian, _registry, _hook);
    Gated7540Storage storage $ = _getGated7540Storage();
    $.custody = _custody;
    $.lastPrice = 10 ** decimals();
    emit CustodyChanged(address(0), _custody);
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
    bytes32 _reason = _canTransfer(address(0), _controller, 1);
    if (_reason != Reasons.TRANSFER_OK) revert Gated7540Vault_ControllerNotEligible(_reason);

    $.deposits[_controller].pendingAssets += _assets;
    emit DepositRequest(_controller, _owner, 0, _sender, _assets);
    // `_owner` is authorised above: the caller itself, or an operator the owner approved (ERC-7540 operators are trusted).
    // slither-disable-next-line arbitrary-send-erc20
    IERC20(asset()).safeTransferFrom(_owner, address(this), _assets);
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

    $.redeems[_controller].pendingShares += _shares;
    emit RedeemRequest(_controller, _owner, 0, _sender, _shares);
    // Escrow as a TRANSFER through the hook: lockup, frozen, identity and pause all apply.
    _transfer(_owner, address(this), _shares);
    _requestId = 0;
  }

  /// @inheritdoc IGated7540Vault
  function fulfillDeposit(
    address _controller,
    uint256 _assets,
    uint256 _shares
  ) external onlyRole(FULFILLER_ROLE) {
    if (_assets == 0 || _shares == 0) revert Gated7540Vault_ZeroAmount();
    Gated7540Storage storage $ = _getGated7540Storage();
    DepositState storage _state = $.deposits[_controller];
    if (_state.pendingAssets == 0) revert Gated7540Vault_NothingPending();
    if (_assets > _state.pendingAssets) revert Gated7540Vault_ExceedsPending(_assets, _state.pendingAssets);

    _state.pendingAssets -= _assets;
    _state.claimableAssets += _assets;
    _state.claimableShares += _shares;
    uint256 _price = _recordPrice(_assets, _shares);
    emit Fulfilled(_controller, true, _price, _assets, _shares, _msgSender());
    IERC20(asset()).safeTransfer($.custody, _assets);
  }

  /// @inheritdoc IGated7540Vault
  function fulfillRedeem(
    address _controller,
    uint256 _shares,
    uint256 _assets
  ) external onlyRole(FULFILLER_ROLE) {
    if (_assets == 0 || _shares == 0) revert Gated7540Vault_ZeroAmount();
    RedeemState storage _state = _getGated7540Storage().redeems[_controller];
    if (_state.pendingShares == 0) revert Gated7540Vault_NothingPending();
    if (_shares > _state.pendingShares) revert Gated7540Vault_ExceedsPending(_shares, _state.pendingShares);

    _state.pendingShares -= _shares;
    _state.claimableShares += _shares;
    _state.claimableAssets += _assets;
    uint256 _price = _recordPrice(_assets, _shares);
    emit Fulfilled(_controller, false, _price, _assets, _shares, _msgSender());
    // BURN the escrow through the hook, then pull the assets that pay for it.
    _burn(address(this), _shares);
    IERC20(asset()).safeTransferFrom(_msgSender(), address(this), _assets);
  }

  /// @inheritdoc IGated7540Vault
  function rejectDepositRequest(
    address _controller
  ) external onlyRole(FULFILLER_ROLE) {
    DepositState storage _state = _getGated7540Storage().deposits[_controller];
    uint256 _assets = _state.pendingAssets;
    if (_assets == 0) revert Gated7540Vault_NothingPending();
    _state.pendingAssets = 0;
    emit DepositRequestRejected(_controller, _assets);
    IERC20(asset()).safeTransfer(_controller, _assets);
  }

  /// @inheritdoc IGated7540Vault
  function rejectRedeemRequest(
    address _controller
  ) external onlyRole(FULFILLER_ROLE) {
    RedeemState storage _state = _getGated7540Storage().redeems[_controller];
    uint256 _shares = _state.pendingShares;
    if (_shares == 0) revert Gated7540Vault_NothingPending();
    _state.pendingShares = 0;
    emit RedeemRequestRejected(_controller, _shares);
    // Internal FORCED move: not an agent action, and the vault needs no AGENT_ROLE on itself.
    _moveAs(address(this), _controller, _shares, IPolicyHook.TransferKind.FORCED, bytes32(0), 0);
  }

  /// @inheritdoc IGated7540Vault
  function recoverRedeemRequest(
    address _controller,
    address _to
  ) external onlyRole(AGENT_ROLE) {
    if (_to == address(0)) revert Gated7540Vault_ZeroAddress();
    RedeemState storage _state = _getGated7540Storage().redeems[_controller];
    uint256 _shares = _state.pendingShares;
    if (_shares == 0) revert Gated7540Vault_NothingPending();
    _state.pendingShares = 0;
    emit RedeemRequestRecovered(_controller, _to, _shares, _msgSender());
    // Internal FORCED move: an enforcement action; identity still applies to the recovery account.
    _moveAs(address(this), _to, _shares, IPolicyHook.TransferKind.FORCED, bytes32(0), 0);
  }

  /// @inheritdoc IGated7540Vault
  function setCustody(
    address _newCustody
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_newCustody == address(0)) revert Gated7540Vault_ZeroAddress();
    Gated7540Storage storage $ = _getGated7540Storage();
    emit CustodyChanged($.custody, _newCustody);
    $.custody = _newCustody;
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
    _shares = _claimDeposit(_assets, _receiver, _controller);
  }

  /// @inheritdoc IERC7540Deposit
  function mint(
    uint256 _shares,
    address _receiver,
    address _controller
  ) external returns (uint256 _assets) {
    _assets = _claimMint(_shares, _receiver, _controller);
  }

  /// @inheritdoc IERC7540Deposit
  function claimableDepositRequest(
    uint256,
    address _controller
  ) external view returns (uint256 _claimableAssets) {
    _claimableAssets = _getGated7540Storage().deposits[_controller].claimableAssets;
  }

  /// @inheritdoc IERC7540Redeem
  function claimableRedeemRequest(
    uint256,
    address _controller
  ) external view returns (uint256 _claimableShares) {
    _claimableShares = _getGated7540Storage().redeems[_controller].claimableShares;
  }

  /// @inheritdoc IGated7540Vault
  function custody() external view returns (address _custody) {
    _custody = _getGated7540Storage().custody;
  }

  /// @inheritdoc IERC7540Operator
  function isOperator(
    address _controller,
    address _operator
  ) external view returns (bool _status) {
    _status = _getGated7540Storage().operators[_controller][_operator];
  }

  /// @inheritdoc IGated7540Vault
  function lastPrice() external view returns (uint256 _price) {
    _price = _getGated7540Storage().lastPrice;
  }

  /// @inheritdoc IERC7540Deposit
  function pendingDepositRequest(
    uint256,
    address _controller
  ) external view returns (uint256 _pendingAssets) {
    _pendingAssets = _getGated7540Storage().deposits[_controller].pendingAssets;
  }

  /// @inheritdoc IERC7540Redeem
  function pendingRedeemRequest(
    uint256,
    address _controller
  ) external view returns (uint256 _pendingShares) {
    _pendingShares = _getGated7540Storage().redeems[_controller].pendingShares;
  }

  /**
   * @notice The share token (ERC-7575)
   * @return _shareTokenAddress This vault
   */
  function share() external view returns (address _shareTokenAddress) {
    _shareTokenAddress = address(this);
  }

  /**
   * @inheritdoc IPolicyGated
   * @dev Always reverts: shares are minted only by deposit claims
   */
  function mint(
    address,
    uint256
  ) external pure override {
    revert Gated7540Vault_Unsupported();
  }

  /**
   * @inheritdoc IPolicyGated
   * @dev Always reverts: shares are burned only by redemption fulfilments
   */
  function burn(
    address,
    uint256
  ) external pure override {
    revert Gated7540Vault_Unsupported();
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev Claims a fulfilled deposit with the caller as controller
   */
  function deposit(
    uint256 _assets,
    address _receiver
  ) public override returns (uint256 _shares) {
    _shares = _claimDeposit(_assets, _receiver, _msgSender());
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev Claims a fulfilled deposit with the caller as controller
   */
  function mint(
    uint256 _shares,
    address _receiver
  ) public override returns (uint256 _assets) {
    _assets = _claimMint(_shares, _receiver, _msgSender());
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev Claims fulfilled redemption assets; the third argument is the controller (ERC-7540)
   */
  function redeem(
    uint256 _shares,
    address _receiver,
    address _controller
  ) public override whenNotPaused returns (uint256 _assets) {
    _onlyControllerOrOperator(_controller);
    if (_shares == 0) revert Gated7540Vault_ZeroAmount();
    RedeemState storage _state = _getGated7540Storage().redeems[_controller];
    if (_shares > _state.claimableShares) revert Gated7540Vault_ExceedsClaimable(_shares, _state.claimableShares);
    _assets = _shares == _state.claimableShares
      ? _state.claimableAssets
      : Math.mulDiv(_shares, _state.claimableAssets, _state.claimableShares, Math.Rounding.Floor);
    if (_assets == 0) revert Gated7540Vault_ZeroAmount();
    _payRedemption(_state, _receiver, _controller, _assets, _shares);
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev Claims fulfilled redemption assets; the third argument is the controller (ERC-7540)
   */
  function withdraw(
    uint256 _assets,
    address _receiver,
    address _controller
  ) public override whenNotPaused returns (uint256 _shares) {
    _onlyControllerOrOperator(_controller);
    if (_assets == 0) revert Gated7540Vault_ZeroAmount();
    RedeemState storage _state = _getGated7540Storage().redeems[_controller];
    if (_assets > _state.claimableAssets) revert Gated7540Vault_ExceedsClaimable(_assets, _state.claimableAssets);
    // Ceil on the shares deducted: assets can never be drained for zero shares.
    _shares = _assets == _state.claimableAssets
      ? _state.claimableShares
      : Math.mulDiv(_assets, _state.claimableShares, _state.claimableAssets, Math.Rounding.Ceil);
    _payRedemption(_state, _receiver, _controller, _assets, _shares);
  }

  /// @inheritdoc ERC4626Upgradeable
  function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8 _decimals) {
    _decimals = super.decimals();
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev The controller's claimable deposit assets; 0 when paused or when the controller could not receive shares
   */
  function maxDeposit(
    address _controller
  ) public view override returns (uint256 _maxAssets) {
    if (_canTransfer(address(0), _controller, 1) != Reasons.TRANSFER_OK) return 0;
    _maxAssets = _getGated7540Storage().deposits[_controller].claimableAssets;
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev The controller's claimable deposit shares; 0 when paused or when the controller could not receive shares
   */
  function maxMint(
    address _controller
  ) public view override returns (uint256 _maxShares) {
    if (_canTransfer(address(0), _controller, 1) != Reasons.TRANSFER_OK) return 0;
    _maxShares = _getGated7540Storage().deposits[_controller].claimableShares;
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev The controller's claimable redemption shares; 0 when paused
   */
  function maxRedeem(
    address _controller
  ) public view override returns (uint256 _maxShares) {
    if (paused()) return 0;
    _maxShares = _getGated7540Storage().redeems[_controller].claimableShares;
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev The controller's claimable redemption assets; 0 when paused
   */
  function maxWithdraw(
    address _controller
  ) public view override returns (uint256 _maxAssets) {
    if (paused()) return 0;
    _maxAssets = _getGated7540Storage().redeems[_controller].claimableAssets;
  }

  /// @inheritdoc PolicyGatedERC20Upgradeable
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(IERC7540Operator).interfaceId || _interfaceId == type(IERC7540Deposit).interfaceId
      || _interfaceId == type(IERC7540Redeem).interfaceId || _interfaceId == type(IERC7575).interfaceId
      || super.supportsInterface(_interfaceId);
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev Indicative only: derived from the last fulfilment price, not from assets held (they sit in custody)
   */
  function totalAssets() public view override returns (uint256 _totalManagedAssets) {
    _totalManagedAssets = _convertToAssets(totalSupply(), Math.Rounding.Floor);
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev Always reverts, as ERC-7540 requires for asynchronous flows
   */
  function previewDeposit(
    uint256
  ) public pure override returns (uint256) {
    revert Gated7540Vault_AsyncOnly();
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev Always reverts, as ERC-7540 requires for asynchronous flows
   */
  function previewMint(
    uint256
  ) public pure override returns (uint256) {
    revert Gated7540Vault_AsyncOnly();
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev Always reverts, as ERC-7540 requires for asynchronous flows
   */
  function previewRedeem(
    uint256
  ) public pure override returns (uint256) {
    revert Gated7540Vault_AsyncOnly();
  }

  /**
   * @inheritdoc ERC4626Upgradeable
   * @dev Always reverts, as ERC-7540 requires for asynchronous flows
   */
  function previewWithdraw(
    uint256
  ) public pure override returns (uint256) {
    revert Gated7540Vault_AsyncOnly();
  }

  /**
   * @notice Claims fulfilled deposit assets for shares; Floor on the shares, exact on a full claim
   * @param _assets The claimable assets to consume
   * @param _receiver The receiver of the shares
   * @param _controller The controller of the request
   * @return _shares The shares minted
   */
  function _claimDeposit(
    uint256 _assets,
    address _receiver,
    address _controller
  ) internal returns (uint256 _shares) {
    _onlyControllerOrOperator(_controller);
    if (_assets == 0) revert Gated7540Vault_ZeroAmount();
    DepositState storage _state = _getGated7540Storage().deposits[_controller];
    if (_assets > _state.claimableAssets) revert Gated7540Vault_ExceedsClaimable(_assets, _state.claimableAssets);
    _shares = _assets == _state.claimableAssets
      ? _state.claimableShares
      : Math.mulDiv(_assets, _state.claimableShares, _state.claimableAssets, Math.Rounding.Floor);
    if (_shares == 0) revert Gated7540Vault_ZeroAmount();
    _mintClaim(_state, _receiver, _controller, _assets, _shares);
  }

  /**
   * @notice Claims fulfilled deposit shares; Ceil on the assets consumed, exact on a full claim
   * @param _shares The claimable shares to mint
   * @param _receiver The receiver of the shares
   * @param _controller The controller of the request
   * @return _assets The claimable assets consumed
   */
  function _claimMint(
    uint256 _shares,
    address _receiver,
    address _controller
  ) internal returns (uint256 _assets) {
    _onlyControllerOrOperator(_controller);
    if (_shares == 0) revert Gated7540Vault_ZeroAmount();
    DepositState storage _state = _getGated7540Storage().deposits[_controller];
    if (_shares > _state.claimableShares) revert Gated7540Vault_ExceedsClaimable(_shares, _state.claimableShares);
    // Ceil on the assets consumed: shares can never be minted for zero assets.
    _assets = _shares == _state.claimableShares
      ? _state.claimableAssets
      : Math.mulDiv(_shares, _state.claimableAssets, _state.claimableShares, Math.Rounding.Ceil);
    _mintClaim(_state, _receiver, _controller, _assets, _shares);
  }

  /**
   * @notice Routes every share movement through the policy hook
   * @param _from The sender, or address(0) on a claim mint
   * @param _to The receiver, or address(0) on a fulfilment burn
   * @param _value The share amount
   */
  function _update(
    address _from,
    address _to,
    uint256 _value
  ) internal override(ERC20Upgradeable, PolicyGatedERC20Upgradeable) {
    super._update(_from, _to, _value);
  }

  /**
   * @notice Shares for assets at the last fulfilment price
   * @param _assets The assets
   * @param _rounding The rounding
   * @return _shares The shares
   */
  function _convertToShares(
    uint256 _assets,
    Math.Rounding _rounding
  ) internal view override returns (uint256 _shares) {
    _shares = Math.mulDiv(_assets, 10 ** decimals(), _getGated7540Storage().lastPrice, _rounding);
  }

  /**
   * @notice Assets for shares at the last fulfilment price
   * @param _shares The shares
   * @param _rounding The rounding
   * @return _assets The assets
   */
  function _convertToAssets(
    uint256 _shares,
    Math.Rounding _rounding
  ) internal view override returns (uint256 _assets) {
    _assets = Math.mulDiv(_shares, _getGated7540Storage().lastPrice, 10 ** decimals(), _rounding);
  }

  /**
   * @notice Books and mints a deposit claim (MINT through the hook)
   * @param _state The controller's deposit state
   * @param _receiver The receiver of the shares
   * @param _controller The controller
   * @param _assets The claimable assets consumed
   * @param _shares The shares minted
   */
  function _mintClaim(
    DepositState storage _state,
    address _receiver,
    address _controller,
    uint256 _assets,
    uint256 _shares
  ) private {
    _state.claimableAssets -= _assets;
    _state.claimableShares -= _shares;
    emit Deposit(_controller, _receiver, _assets, _shares);
    _mint(_receiver, _shares);
  }

  /**
   * @notice Books and pays a redemption claim
   * @param _state The controller's redemption state
   * @param _receiver The receiver of the assets
   * @param _controller The controller
   * @param _assets The assets paid
   * @param _shares The claimable shares consumed
   */
  function _payRedemption(
    RedeemState storage _state,
    address _receiver,
    address _controller,
    uint256 _assets,
    uint256 _shares
  ) private {
    _state.claimableShares -= _shares;
    _state.claimableAssets -= _assets;
    emit Withdraw(_msgSender(), _receiver, _controller, _assets, _shares);
    IERC20(asset()).safeTransfer(_receiver, _assets);
  }

  /**
   * @notice Records a fulfilment price
   * @param _assets The fulfilled assets
   * @param _shares The fulfilled shares
   * @return _price Assets per `10**decimals()` shares, rounded down
   */
  function _recordPrice(
    uint256 _assets,
    uint256 _shares
  ) private returns (uint256 _price) {
    _price = Math.mulDiv(_assets, 10 ** decimals(), _shares);
    _getGated7540Storage().lastPrice = _price;
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

  /**
   * @notice The ERC-7201 storage of the vault
   * @return $ The storage pointer
   */
  function _getGated7540Storage() private pure returns (Gated7540Storage storage $) {
    assembly ('memory-safe') {
      $.slot := _GATED_7540_STORAGE_LOCATION
    }
  }
}
