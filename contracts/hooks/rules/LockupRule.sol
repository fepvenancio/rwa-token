// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {ILockupRule} from 'interfaces/ILockupRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

import {BaseRule} from 'contracts/hooks/BaseRule.sol';

/**
 * @title LockupRule
 * @notice Per-(token, holder) lockup on holder-driven movements, as specified in `ILockupRule`
 */
contract LockupRule is BaseRule, ILockupRule {
  /// @inheritdoc ILockupRule
  bytes32 public constant AGENT_ROLE = keccak256('AGENT_ROLE');

  /// @notice Unlock time per token and holder; 0 when not locked
  mapping(address _token => mapping(address _holder => uint256 _unlockTime)) internal _unlockTimes;

  /// @inheritdoc ILockupRule
  function setLockup(
    address _token,
    address _holder,
    uint256 _unlockTime
  ) external {
    if (!IAccessControl(_token).hasRole(AGENT_ROLE, msg.sender)) revert LockupRule_OnlyTokenAgent(_token, msg.sender);
    if (_holder == address(0)) revert LockupRule_ZeroAddress();
    uint256 _stored = _unlockTime > block.timestamp ? _unlockTime : 0;
    _unlockTimes[_token][_holder] = _stored;
    emit LockupSet(_token, _holder, _stored);
  }

  /// @inheritdoc IComplianceRule
  function check(
    IPolicyHook.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    bool _holderDriven =
      _ctx.kind == IPolicyHook.TransferKind.TRANSFER || _ctx.kind == IPolicyHook.TransferKind.EXECUTED;
    if (_holderDriven && block.timestamp < _unlockTimes[_ctx.token][_ctx.from]) return Reasons.LOCKED;
    _reason = Reasons.TRANSFER_OK;
  }

  /// @inheritdoc ILockupRule
  function unlockTime(
    address _token,
    address _holder
  ) external view returns (uint256 _unlockTime) {
    _unlockTime = _unlockTimes[_token][_holder];
  }

  /// @inheritdoc IComplianceRule
  function ruleId() external pure returns (bytes32 _ruleId) {
    _ruleId = keccak256('LockupRule.v1');
  }

  /// @inheritdoc BaseRule
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(ILockupRule).interfaceId || super.supportsInterface(_interfaceId);
  }
}
