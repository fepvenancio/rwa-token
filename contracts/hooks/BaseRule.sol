// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC165} from '@openzeppelin/contracts/utils/introspection/ERC165.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';

/**
 * @title BaseRule
 * @notice Parent of every compliance rule. Rules are immutable contracts, attested by codehash
 * @dev Rules that keep state MUST key it by `ctx.token`. `HOOK` is immutable, so it is part of the codehash: one rule
 *      instance serves one hook
 */
abstract contract BaseRule is ERC165, IComplianceRule {
  /// @notice The hook allowed to call `after_`
  address public immutable HOOK;

  /**
   * @notice Restricts a function to `HOOK`
   */
  modifier onlyHook() {
    if (msg.sender != HOOK) revert ComplianceRule_OnlyHook(msg.sender);
    _;
  }

  /**
   * @notice Binds the rule to its hook
   * @param _hook The hook allowed to call `after_`
   */
  constructor(
    address _hook
  ) {
    HOOK = _hook;
  }

  /// @inheritdoc IComplianceRule
  function after_(
    IPolicyHook.TransferContext calldata
  ) external virtual onlyHook {}

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
