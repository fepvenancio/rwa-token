// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Reasons} from 'interfaces/Errors.sol';

import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';
import {IGatedVaultBase} from 'interfaces/IGatedVaultBase.sol';
// Needed by the compiler to resolve `@inheritdoc IPolicyGated`; solhint does not see NatSpec usage.
// solhint-disable-next-line no-unused-vars
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';

import {PolicyGatedERC20Upgradeable} from 'contracts/base/PolicyGatedERC20Upgradeable.sol';

/**
 * @title GatedVaultBase
 * @notice Holds what both vault templates share, as specified in `IGatedVaultBase`
 */
abstract contract GatedVaultBase is PolicyGatedERC20Upgradeable, IGatedVaultBase {
  /**
   * @inheritdoc IPolicyGated
   * @dev Always reverts: vault shares are minted only by deposits and deposit claims
   */
  function mint(
    address,
    uint256
  ) external pure override {
    revert GatedVault_Unsupported();
  }

  /**
   * @inheritdoc IPolicyGated
   * @dev Always reverts: vault shares are burned only by redemptions and settlements
   */
  function burn(
    address,
    uint256
  ) external pure override {
    revert GatedVault_Unsupported();
  }

  /**
   * @notice The token's policy on an account receiving under an enforcement move
   * @param _account The account
   * @return _reason TRANSFER_OK or the policy's reason code
   */
  function _enforcementProbe(
    address _account
  ) internal view returns (bytes32 _reason) {
    _reason = _check(
      _context(address(0), _account, 0, _msgSender(), IERC8473Policy.TransferKind.FORCED, bytes32(0), 0), _policy()
    );
  }

  /**
   * @notice Reverts unless `_account` is the party itself or passes the token's policy
   * @param _account The payer, the receiver of redemption cash, or the named controller
   * @param _party The receiver, owner or controller it acts for
   */
  function _requireThirdPartyEligible(
    address _account,
    address _party
  ) internal view {
    if (_account == _party) return;
    bytes32 _reason = _enforcementProbe(_account);
    if (_reason != Reasons.TRANSFER_OK) revert GatedVault_ThirdPartyNotEligible(_account, _reason);
  }
}
