// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC165} from '@openzeppelin/contracts/utils/introspection/ERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

/**
 * @title BaseRule
 * @notice Parent of every compliance rule. Rules are immutable contracts, attested by codehash
 * @dev Rules are hook-agnostic: `onlyHook` accepts whichever hook `ctx.token` currently has installed. One attested
 *      instance therefore serves every token, survives hook replacement, and its codehash does not depend on any hook.
 *      This is sound only because rule state MUST be keyed by `ctx.token`: a fake token naming itself in `ctx.token`
 *      can authorise writes to its own key and nothing else. `check` stays view and unauthenticated
 */
abstract contract BaseRule is ERC165, IComplianceRule {
  /**
   * @notice Restricts a function to the hook currently installed on `_ctx.token`
   * @dev One staticcall to the token, paid only by rules that want `after_`
   * @param _ctx The movement context naming the token
   */
  modifier onlyHook(
    IPolicyHook.TransferContext calldata _ctx
  ) {
    if (IPolicyGated(_ctx.token).policyHook() != msg.sender) revert ComplianceRule_OnlyHook(msg.sender);
    _;
  }

  /// @inheritdoc IComplianceRule
  // Default for rules without wantsAfter(); the hook only calls after_ on rules that opt in.
  // aderyn-ignore-next-line(empty-block)
  function after_(
    IPolicyHook.TransferContext calldata _ctx
  ) external virtual onlyHook(_ctx) {}

  /// @inheritdoc IComplianceRule
  function checkReceive(
    address,
    address
  ) external view virtual returns (bytes32 _reason) {
    _reason = Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IComplianceRule
  function checkSend(
    address,
    address
  ) external view virtual returns (bytes32 _reason) {
    _reason = Reasons.TRANSFER_OK;
  }

  /// @inheritdoc ERC165
  function supportsInterface(
    bytes4 _interfaceId
  ) public view virtual override returns (bool _supported) {
    _supported = _interfaceId == type(IComplianceRule).interfaceId || super.supportsInterface(_interfaceId);
  }

  /// @inheritdoc IComplianceRule
  function wantsAfter() public pure virtual returns (bool _wantsAfter) {
    _wantsAfter = false;
  }
}
