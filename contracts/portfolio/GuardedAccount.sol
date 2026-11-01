// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Address} from '@openzeppelin/contracts/utils/Address.sol';

import {IAdapter} from 'interfaces/IAdapter.sol';
import {ICallValidator} from 'interfaces/ICallValidator.sol';
import {IGuardedAccount} from 'interfaces/IGuardedAccount.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {IPortfolio} from 'interfaces/IPortfolio.sol';

/**
 * @title GuardedAccount
 * @notice Runs only the calls its validators allow, as specified in `IGuardedAccount`
 * @dev Immutable, attested as ADAPTER
 */
contract GuardedAccount is IGuardedAccount {
  using SafeERC20 for IERC20;

  /// @notice The vault's role that makes calls
  bytes32 private constant _ALLOCATOR_ROLE = keccak256('ALLOCATOR_ROLE');

  /// @notice The vault's role that may also revoke
  bytes32 private constant _GUARDIAN_ROLE = keccak256('GUARDIAN_ROLE');

  /// @notice The vault's admin role
  bytes32 private constant _DEFAULT_ADMIN_ROLE = 0x00;

  /// @inheritdoc IAdapter
  address public immutable PORTFOLIO;

  /// @inheritdoc IGuardedAccount
  address public immutable VAULT;

  /// @inheritdoc IGuardedAccount
  bytes32 public immutable RISK_ID;

  /// @inheritdoc IGuardedAccount
  bytes32 public immutable SHARED_RISK_ID;

  /// @notice The portfolio's asset
  IERC20 internal immutable _ASSET;

  /// @inheritdoc IGuardedAccount
  mapping(address _target => mapping(bytes4 _selector => address _validator)) public validatorOf;

  /**
   * @notice Deploys the account
   * @param _portfolio The portfolio it serves; it must accept reported adapters
   * @param _riskId The risk that is this account's alone
   * @param _sharedRiskId A risk shared with other adapters, or zero for none
   */
  constructor(
    address _portfolio,
    bytes32 _riskId,
    bytes32 _sharedRiskId
  ) {
    if (_portfolio == address(0)) revert GuardedAccount_ZeroAddress();
    if (_riskId == bytes32(0)) revert GuardedAccount_NoRiskId();
    IPortfolio _plug = IPortfolio(_portfolio);
    // Immutables read from view interfaces, at construction: nothing can re-enter.
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (!_plug.ACCEPTS_REPORTED()) revert GuardedAccount_ReportedNotAccepted();
    PORTFOLIO = _portfolio;
    // aderyn-ignore-next-line(reentrancy-state-change)
    VAULT = _plug.VAULT();
    // aderyn-ignore-next-line(reentrancy-state-change)
    _ASSET = _plug.ASSET();
    RISK_ID = _riskId;
    SHARED_RISK_ID = _sharedRiskId;
  }

  /// @inheritdoc IGuardedAccount
  function execute(
    Call[] calldata _calls
  ) external {
    if (!_hasRole(_ALLOCATOR_ROLE)) revert GuardedAccount_Unauthorized(msg.sender);
    uint256 _count = _calls.length;
    // All or nothing, by design: a batch that moves money must not half-run.
    // aderyn-ignore-next-line(require-revert-in-loop)
    for (uint256 _i; _i < _count; ++_i) {
      address _target = _calls[_i].target;
      bytes calldata _data = _calls[_i].data;
      bytes4 _selector = _data.length < 4 ? bytes4(0) : bytes4(_data);
      address _validator = validatorOf[_target][_selector];
      if (_validator == address(0) || !ICallValidator(_validator).validate(address(this), _target, _data)) {
        revert GuardedAccount_CallRefused(_target, _selector);
      }
      emit CallMade(_target, _selector, _data);
      // A permission is a timelock decision, and the validator has judged these parameters. What it returns is not needed.
      // slither-disable-next-line unused-return
      Address.functionCall(_target, _data); // aderyn-ignore(unchecked-return)
    }
  }

  /// @inheritdoc IGuardedAccount
  function setPermission(
    address _target,
    bytes4 _selector,
    address _validator
  ) external {
    if (!_hasRole(_DEFAULT_ADMIN_ROLE)) revert GuardedAccount_Unauthorized(msg.sender);
    if (_target == PORTFOLIO || _target == VAULT || _target == address(this)) {
      revert GuardedAccount_ForbiddenTarget(_target);
    }
    // View interfaces, compiled to STATICCALL: nothing re-enters before the write below.
    // aderyn-ignore-next-line(reentrancy-state-change)
    IPolicyRegistry _registry = IPolicyRegistry(IPolicyGated(VAULT).registry());
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (!_registry.isAttested(_validator, IPolicyRegistry.AttestKind.VALIDATOR)) {
      revert GuardedAccount_NotAttested(_validator);
    }
    validatorOf[_target][_selector] = _validator;
    emit PermissionSet(_target, _selector, _validator);
  }

  /// @inheritdoc IGuardedAccount
  function revokePermission(
    address _target,
    bytes4 _selector
  ) external {
    if (!_hasRole(_DEFAULT_ADMIN_ROLE) && !_hasRole(_GUARDIAN_ROLE)) revert GuardedAccount_Unauthorized(msg.sender);
    delete validatorOf[_target][_selector];
    emit PermissionRevoked(_target, _selector);
  }

  /// @inheritdoc IAdapter
  function deallocate(
    uint256 _assets
  ) external {
    if (msg.sender != PORTFOLIO) revert GuardedAccount_Unauthorized(msg.sender);
    _ASSET.safeTransfer(PORTFOLIO, _assets);
  }

  /**
   * @inheritdoc IAdapter
   * @dev The money stays here until the allocator sends it on with `execute`
   */
  function allocate(
    uint256
  ) external view {
    if (msg.sender != PORTFOLIO) revert GuardedAccount_Unauthorized(msg.sender);
  }

  /// @inheritdoc IAdapter
  function liquid() external view returns (uint256 _liquid) {
    _liquid = _ASSET.balanceOf(address(this));
  }

  /// @inheritdoc IAdapter
  function riskIds() external view returns (bytes32[] memory _ids) {
    bool _shared = SHARED_RISK_ID != bytes32(0);
    _ids = new bytes32[](_shared ? 2 : 1);
    _ids[0] = RISK_ID;
    if (_shared) _ids[1] = SHARED_RISK_ID;
  }

  /// @inheritdoc IAdapter
  function asset() external view returns (address _asset) {
    _asset = address(_ASSET);
  }

  /// @inheritdoc IAdapter
  function value() external pure returns (uint256 _value) {
    _value = 0;
  }

  /// @inheritdoc IAdapter
  function fresh() external pure returns (bool _fresh) {
    _fresh = true;
  }

  /// @inheritdoc IAdapter
  function reported() external pure returns (bool _reported) {
    _reported = true;
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
