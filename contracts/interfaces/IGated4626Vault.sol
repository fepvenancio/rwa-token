// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title IGated4626Vault
 * @notice ERC-4626 vault whose shares are a policy-gated token. Deposits and mints arrive at the hook as MINT to the
 *         receiver; withdrawals and redemptions as BURN from the owner, with the caller as operator. The asset leg is
 *         an ordinary ERC-20 transfer and is not hooked
 * @dev `max*` express the gating: `maxDeposit` / `maxMint` are 0 when paused or when `canTransfer(0, receiver, 1)` is
 *      not OK; `maxRedeem` is `balanceOf - getFrozen`, or 0 when paused or `canTransfer(owner, 0, 1)` is not OK;
 *      `maxWithdraw` is `convertToAssets(maxRedeem, Floor)`. `preview*` stay pure conversions. Share supply moves only
 *      through deposits and redemptions: the issuer `mint` / `burn` primitives revert
 */
interface IGated4626Vault {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown by the issuer `mint` / `burn` primitives, which vault shares do not support
  error Gated4626Vault_Unsupported();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Initializes a vault proxy
   * @param _asset The underlying asset
   * @param _name The share token name, also the EIP-712 domain name
   * @param _symbol The share token symbol
   * @param _admin The timelock, granted DEFAULT_ADMIN_ROLE
   * @param _guardian The guardian multisig, granted GUARDIAN_ROLE
   * @param _registry The policy registry
   * @param _hook The initial policy hook; must be attested as HOOK
   */
  function initialize(
    IERC20 _asset,
    string calldata _name,
    string calldata _symbol,
    address _admin,
    address _guardian,
    address _registry,
    address _hook
  ) external;
}
