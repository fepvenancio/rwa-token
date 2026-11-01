// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {IAdapter} from 'interfaces/IAdapter.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {IPortfolio} from 'interfaces/IPortfolio.sol';

/**
 * @title Portfolio
 * @notice Where one vault's money may go, as specified in `IPortfolio`: to an installed adapter within caps, to the vault,
 *         or by a timelock operation to an attested successor for the same vault. Nowhere else
 * @dev Immutable, attested as PORTFOLIO. A lego that names its vault can be built before the vault exists, so the registry
 *      is read from the vault at call time rather than fixed here. A risk's allocation is the sum of its adapters';
 *      an adapter that named an id twice would only reach that cap sooner
 */
contract Portfolio is ReentrancyGuardTransient, IPortfolio {
  using EnumerableSet for EnumerableSet.AddressSet;
  using SafeERC20 for IERC20;

  /// @inheritdoc IPortfolio
  bytes32 public constant ALLOCATOR_ROLE = keccak256('ALLOCATOR_ROLE');

  /// @inheritdoc IPortfolio
  uint256 public constant MAX_ADAPTERS = 8;

  /// @notice The vault's admin role, as OpenZeppelin defines it
  bytes32 private constant _DEFAULT_ADMIN_ROLE = 0x00;

  /// @notice The vault's guardian role, as the base defines it
  bytes32 private constant _GUARDIAN_ROLE = keccak256('GUARDIAN_ROLE');

  /// @notice A relative cap of all the vault's assets, which is no limit at all
  uint256 private constant _BPS = 1e4;

  /// @inheritdoc IPortfolio
  address public immutable VAULT;

  /// @inheritdoc IPortfolio
  IERC20 public immutable ASSET;

  /// @inheritdoc IPortfolio
  bool public immutable ACCEPTS_REPORTED;

  /// @inheritdoc IPortfolio
  address public liquidityAdapter;

  /// @inheritdoc IPortfolio
  uint256 public moves;

  /// @inheritdoc IPortfolio
  bool public writtenOff;

  /// @inheritdoc IPortfolio
  mapping(address _adapter => uint256 _allocation) public allocationOf;

  /// @notice Each risk's allocation and caps
  mapping(bytes32 _id => Risk _risk) internal _risks;

  /// @notice The installed adapters
  EnumerableSet.AddressSet internal _adapters;

  /// @notice Whether the money has gone to a successor, after which this portfolio gives no price
  bool internal _migrated;

  /**
   * @notice Deploys the portfolio and lets its vault pull the idle money
   * @param _vault The vault it serves
   * @param _asset The asset it holds
   * @param _acceptsReported Whether it takes adapters whose value comes from a report
   */
  constructor(
    address _vault,
    IERC20 _asset,
    bool _acceptsReported
  ) {
    if (_vault == address(0) || address(_asset) == address(0)) revert Portfolio_ZeroAddress();
    VAULT = _vault;
    ASSET = _asset;
    ACCEPTS_REPORTED = _acceptsReported;
    _asset.forceApprove(_vault, type(uint256).max);
  }

  /// @inheritdoc IPortfolio
  function addAdapter(
    address _adapter
  ) external {
    _requireAdmin();
    if (!_registry().isAttested(_adapter, IPolicyRegistry.AttestKind.ADAPTER)) revert Portfolio_NotAttested(_adapter);
    IAdapter _plug = IAdapter(_adapter);
    if (_plug.PORTFOLIO() != address(this)) revert Portfolio_WrongPortfolio(_adapter);
    if (_plug.asset() != address(ASSET)) revert Portfolio_WrongAsset(_adapter);
    bool _priced = !_plug.reported();
    if (!_priced && !ACCEPTS_REPORTED) revert Portfolio_ReportedNotAccepted(_adapter);
    if (_plug.riskIds().length == 0) revert Portfolio_NoRiskIds(_adapter);
    if (_adapters.length() >= MAX_ADAPTERS) revert Portfolio_TooManyAdapters(MAX_ADAPTERS);
    if (!_adapters.add(_adapter)) revert Portfolio_AdapterExists(_adapter);
    if (_priced && !_plug.fresh()) revert Portfolio_StalePrice(_adapter);
    // A position already there counts at once, so it cannot come back from a write-off outside the caps.
    uint256 _allocation = _priced ? _plug.value() : 0;
    _addAllocation(_adapter, _allocation, IERC4626(VAULT).totalAssets());
    emit AdapterAdded(_adapter, _allocation);
  }

  /// @inheritdoc IPortfolio
  function removeAdapter(
    address _adapter
  ) external {
    _requireAdmin();
    _requireInstalled(_adapter);
    IAdapter _plug = IAdapter(_adapter);
    // Empty means exactly zero, and a donation only delays a removal until the allocator brings it back.
    // slither-disable-next-line incorrect-equality
    bool _empty = _plug.reported()
      ? ASSET.balanceOf(_adapter) == 0 && allocationOf[_adapter] == 0
      : _plug.fresh() && _plug.value() == 0;
    if (!_empty) revert Portfolio_NotEmpty(_adapter);
    _takeOff(_adapter);
    emit AdapterRemoved(_adapter);
  }

  /// @inheritdoc IPortfolio
  function writeOffAdapter(
    address _adapter
  ) external {
    _requireAdmin();
    _requireInstalled(_adapter);
    IAdapter _plug = IAdapter(_adapter);
    // View interface: compiled to STATICCALL, so the adapter cannot change state or re-enter before the writes below.
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (!_plug.reported() && _plug.fresh()) revert Portfolio_StillPriced(_adapter);
    uint256 _cleared = allocationOf[_adapter];
    writtenOff = true;
    _takeOff(_adapter);
    emit AdapterWrittenOff(_adapter, _cleared);
  }

  /// @inheritdoc IPortfolio
  function setCaps(
    bytes32 _id,
    uint256 _absoluteCap,
    uint256 _relativeCapBps
  ) external {
    if (_relativeCapBps > _BPS) revert Portfolio_InvalidCap(_relativeCapBps);
    Risk storage _risk = _risks[_id];
    if (!_hasRole(_DEFAULT_ADMIN_ROLE)) {
      bool _lowers = _absoluteCap <= _risk.absoluteCap && _relativeCapBps <= _risk.relativeCapBps;
      if (!_lowers || !_hasRole(_GUARDIAN_ROLE)) revert Portfolio_Unauthorized(msg.sender);
    }
    _risk.absoluteCap = SafeCast.toUint120(_absoluteCap);
    _risk.relativeCapBps = SafeCast.toUint16(_relativeCapBps);
    emit CapsSet(_id, _absoluteCap, _relativeCapBps);
  }

  /// @inheritdoc IPortfolio
  function allocate(
    address _adapter,
    uint256 _assets,
    uint256 _minAdded
  ) external {
    if (!_hasRole(ALLOCATOR_ROLE)) revert Portfolio_Unauthorized(msg.sender);
    if (Pausable(VAULT).paused()) revert Portfolio_VaultPaused();
    _requireInstalled(_adapter);
    // A caller's argument, not a balance.
    // slither-disable-next-line incorrect-equality
    if (_assets == 0) revert Portfolio_ZeroAmount();
    // Read before the guard: a vault's total can ask this portfolio, which gives no price in the middle of a move.
    _allocate(_adapter, _assets, _minAdded, IERC4626(VAULT).totalAssets());
  }

  /// @inheritdoc IPortfolio
  function deallocate(
    address _adapter,
    uint256 _assets
  ) external nonReentrant {
    if (!_hasRole(ALLOCATOR_ROLE) && !_hasRole(_GUARDIAN_ROLE)) revert Portfolio_Unauthorized(msg.sender);
    _requireInstalled(_adapter);
    _deallocate(_adapter, _assets);
  }

  /// @inheritdoc IPortfolio
  function setLiquidityAdapter(
    address _adapter
  ) external {
    if (!_hasRole(ALLOCATOR_ROLE)) revert Portfolio_Unauthorized(msg.sender);
    if (_adapter != address(0)) _requireInstalled(_adapter);
    liquidityAdapter = _adapter;
    emit LiquidityAdapterSet(_adapter);
  }

  /// @inheritdoc IPortfolio
  function raise(
    uint256 _assets
  ) external nonReentrant {
    if (msg.sender != VAULT) revert Portfolio_Unauthorized(msg.sender);
    uint256 _idle = ASSET.balanceOf(address(this));
    if (_idle >= _assets) return;
    address _adapter = liquidityAdapter;
    if (_adapter == address(0)) revert Portfolio_NoLiquidityAdapter();
    _deallocate(_adapter, _assets - _idle);
  }

  /// @inheritdoc IPortfolio
  function migrateTo(
    address _successor
  ) external nonReentrant {
    _requireAdmin();
    uint256 _count = _adapters.length();
    if (_count != 0) revert Portfolio_AdaptersInstalled(_count);
    _migrated = true;
    if (!_registry().isAttested(_successor, IPolicyRegistry.AttestKind.PORTFOLIO)) {
      revert Portfolio_NotAttested(_successor);
    }
    if (IPortfolio(_successor).VAULT() != VAULT) revert Portfolio_WrongVault(_successor);
    if (IPortfolio(_successor).ASSET() != ASSET) revert Portfolio_WrongAsset(_successor);
    uint256 _assets = ASSET.balanceOf(address(this));
    ASSET.safeTransfer(_successor, _assets);
    emit Migrated(_successor, _assets);
  }

  /// @inheritdoc IPortfolio
  function adapters() external view returns (address[] memory _list) {
    _list = _adapters.values();
  }

  /// @inheritdoc IPortfolio
  function riskOf(
    bytes32 _id
  ) external view returns (Risk memory _risk) {
    _risk = _risks[_id];
  }

  /// @inheritdoc IPortfolio
  function pricedValue() external view returns (uint256 _value) {
    if (_reentrancyGuardEntered()) revert ReentrancyGuardReentrantCall();
    _value = ASSET.balanceOf(address(this));
    uint256 _count = _adapters.length();
    for (uint256 _i; _i < _count; ++_i) {
      IAdapter _plug = IAdapter(_adapters.at(_i));
      // A portfolio that refuses reported adapters has none to ask about, and this is a hot path behind a 4626.
      if (!ACCEPTS_REPORTED || !_plug.reported()) _value += _plug.value();
    }
  }

  /// @inheritdoc IPortfolio
  function priceFresh() external view returns (bool _fresh) {
    if (_migrated) return false;
    uint256 _count = _adapters.length();
    for (uint256 _i; _i < _count; ++_i) {
      IAdapter _plug = IAdapter(_adapters.at(_i));
      if ((!ACCEPTS_REPORTED || !_plug.reported()) && !_plug.fresh()) return false;
    }
    _fresh = true;
  }

  /// @inheritdoc IPortfolio
  function liquidAssets() external view returns (uint256 _assets) {
    _assets = ASSET.balanceOf(address(this));
    address _adapter = liquidityAdapter;
    if (_adapter != address(0)) _assets += IAdapter(_adapter).liquid();
  }

  /**
   * @notice Sends the money and adds what the position gained to the allocation
   * @dev A priced adapter's allocation grows by the change in its value, so a fee taken on the way in does not count
   * @param _adapter The adapter
   * @param _assets The assets to send
   * @param _totalAssets The vault's total assets, for the relative caps
   */
  function _allocate(
    address _adapter,
    uint256 _assets,
    uint256 _minAdded,
    uint256 _totalAssets
  ) private nonReentrant {
    IAdapter _plug = IAdapter(_adapter);
    bool _priced = !_plug.reported();
    if (_priced && !_plug.fresh()) revert Portfolio_StalePrice(_adapter);
    uint256 _before = _priced ? _plug.value() : 0;
    ASSET.safeTransfer(_adapter, _assets);
    // The guard is held, the adapter is attested, and the change can only be measured after the call.
    // slither-disable-start reentrancy-benign,reentrancy-events
    _plug.allocate(_assets);

    uint256 _added = _assets;
    if (_priced) {
      if (!_plug.fresh()) revert Portfolio_StalePrice(_adapter);
      uint256 _after = _plug.value();
      _added = _after > _before ? _after - _before : 0;
    }
    if (_added < _minAdded) revert Portfolio_ShortAllocation(_adapter, _minAdded, _added);
    ++moves;
    _addAllocation(_adapter, _added, _totalAssets);
    emit Allocated(_adapter, _assets, _added);
    // slither-disable-end reentrancy-benign,reentrancy-events
  }

  /**
   * @notice Brings money back and takes what left the position off the allocation
   * @dev A priced adapter's allocation falls by the change in its value, unless it cannot be read: then by what it was asked for.
   *      It never falls below zero, so a gain taken out leaves nothing against the cap
   * @param _adapter The adapter
   * @param _assets The assets it must return
   */
  function _deallocate(
    address _adapter,
    uint256 _assets
  ) private {
    // A caller's argument, not a balance.
    // slither-disable-next-line incorrect-equality
    if (_assets == 0) revert Portfolio_ZeroAmount();
    IAdapter _plug = IAdapter(_adapter);
    bool _priced = !_plug.reported() && _plug.fresh();
    uint256 _before = _priced ? _plug.value() : 0;
    uint256 _idle = ASSET.balanceOf(address(this));
    // The guard is held, the adapter is attested, and what arrived can only be measured after the call.
    // slither-disable-start reentrancy-benign,reentrancy-events,reentrancy-balance
    _plug.deallocate(_assets);
    uint256 _received = ASSET.balanceOf(address(this)) - _idle;
    if (_received < _assets) revert Portfolio_ShortReturn(_adapter, _assets, _received);

    uint256 _taken = _assets;
    if (_priced && _plug.fresh()) {
      uint256 _after = _plug.value();
      _taken = _before > _after ? _before - _after : 0;
    }
    uint256 _allocation = allocationOf[_adapter];
    if (_taken > _allocation) _taken = _allocation;
    ++moves;
    _subtractAllocation(_adapter, _taken);
    emit Deallocated(_adapter, _assets, _taken);
    // slither-disable-end reentrancy-benign,reentrancy-events,reentrancy-balance
  }

  /**
   * @notice Adds to an adapter's allocation and to every risk it names, within each risk's caps
   * @param _adapter The adapter
   * @param _amount The amount to add
   * @param _totalAssets The vault's total assets, for the relative caps
   */
  function _addAllocation(
    address _adapter,
    uint256 _amount,
    uint256 _totalAssets
  ) private {
    allocationOf[_adapter] += _amount;
    bytes32[] memory _ids = IAdapter(_adapter).riskIds();
    // A move past any cap must fail whole, and an adapter names only a few risks.
    // aderyn-ignore-next-line(require-revert-in-loop,costly-loop)
    for (uint256 _i; _i < _ids.length; ++_i) {
      bytes32 _id = _ids[_i];
      Risk storage _risk = _risks[_id];
      uint256 _next = _risk.allocation + _amount;
      if (_next > _risk.absoluteCap) revert Portfolio_CapExceeded(_id, _next, _risk.absoluteCap);
      uint256 _relativeCap = _risk.relativeCapBps;
      if (_relativeCap < _BPS && _next * _BPS > _relativeCap * _totalAssets) {
        revert Portfolio_CapExceeded(_id, _next, _relativeCap * _totalAssets / _BPS);
      }
      // Cannot truncate: `_next` is at most the absolute cap, which fits in 120 bits.
      // aderyn-ignore-next-line(unsafe-casting)
      _risk.allocation = uint120(_next);
    }
  }

  /**
   * @notice Takes from an adapter's allocation and from every risk it names
   * @param _adapter The adapter
   * @param _amount The amount to take, at most the adapter's allocation
   */
  function _subtractAllocation(
    address _adapter,
    uint256 _amount
  ) private {
    allocationOf[_adapter] -= _amount;
    bytes32[] memory _ids = IAdapter(_adapter).riskIds();
    // An adapter names only a few risks.
    // aderyn-ignore-next-line(costly-loop)
    for (uint256 _i; _i < _ids.length; ++_i) {
      // Cannot truncate: a risk's allocation is the sum of its adapters', so `_amount` fits in it.
      // aderyn-ignore-next-line(unsafe-casting)
      _risks[_ids[_i]].allocation -= uint120(_amount);
    }
  }

  /**
   * @notice Takes an adapter off the list and clears what it had against the caps
   * @param _adapter The adapter
   */
  function _takeOff(
    address _adapter
  ) private {
    _subtractAllocation(_adapter, allocationOf[_adapter]);
    // The return is false only if it was not there, and every caller has checked that it was.
    // slither-disable-next-line unused-return
    _adapters.remove(_adapter); // aderyn-ignore(unchecked-return)
    if (liquidityAdapter == _adapter) liquidityAdapter = address(0);
  }

  /**
   * @notice Reverts unless the caller holds the vault's admin role
   */
  function _requireAdmin() private view {
    if (!_hasRole(_DEFAULT_ADMIN_ROLE)) revert Portfolio_Unauthorized(msg.sender);
  }

  /**
   * @notice Reverts unless an adapter is installed
   * @param _adapter The adapter
   */
  function _requireInstalled(
    address _adapter
  ) private view {
    if (!_adapters.contains(_adapter)) revert Portfolio_UnknownAdapter(_adapter);
  }

  /**
   * @notice Whether the caller holds a role on the vault right now
   * @param _role The role
   * @return _held True if it does
   */
  function _hasRole(
    bytes32 _role
  ) private view returns (bool _held) {
    _held = IAccessControl(VAULT).hasRole(_role, msg.sender);
  }

  /**
   * @notice The registry the vault names
   * @return _policyRegistry The registry
   */
  function _registry() private view returns (IPolicyRegistry _policyRegistry) {
    _policyRegistry = IPolicyRegistry(IPolicyGated(VAULT).registry());
  }
}
