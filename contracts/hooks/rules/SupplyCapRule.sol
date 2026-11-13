// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';
import {ISupplyCapRule} from 'interfaces/ISupplyCapRule.sol';

import {BaseRule} from 'contracts/hooks/BaseRule.sol';

/**
 * @title SupplyCapRule
 * @notice Refuses a mint above a per-token cap, as specified in `ISupplyCapRule`
 */
contract SupplyCapRule is BaseRule, ISupplyCapRule {
  /// @notice The token role that sets its cap
  bytes32 private constant _DEFAULT_ADMIN_ROLE = 0x00;

  /// @inheritdoc ISupplyCapRule
  mapping(address _token => uint256 _cap) public supplyCap;

  /// @inheritdoc ISupplyCapRule
  function setSupplyCap(
    address _token,
    uint256 _cap
  ) external {
    // View interface: compiled to STATICCALL, so the token cannot change any state or re-enter before the write below.
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (!IAccessControl(_token).hasRole(_DEFAULT_ADMIN_ROLE, msg.sender)) {
      revert SupplyCapRule_OnlyTokenAdmin(_token, msg.sender);
    }
    emit SupplyCapSet(_token, supplyCap[_token], _cap);
    supplyCap[_token] = _cap;
  }

  /// @inheritdoc IComplianceRule
  function check(
    IERC8473Policy.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    _reason = Reasons.TRANSFER_OK;
    if (_ctx.kind != IERC8473Policy.TransferKind.MINT) return _reason;
    uint256 _cap = supplyCap[_ctx.token];
    uint256 _supply = IERC20(_ctx.token).totalSupply();
    // Compared before subtracting, so no amount can make this revert.
    if (_supply > _cap || _ctx.amount > _cap - _supply) _reason = Reasons.ABOVE_SUPPLY_CAP;
  }

  /// @inheritdoc IComplianceRule
  function ruleId() external pure returns (bytes32 _id) {
    _id = keccak256('SupplyCapRule.v1');
  }

  /// @inheritdoc BaseRule
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(ISupplyCapRule).interfaceId || super.supportsInterface(_interfaceId);
  }
}
