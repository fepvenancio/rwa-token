// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';

/**
 * @title ISupplyCapRule
 * @notice Per-token cap on what can be minted, so a stolen minter key cannot mint without limit. A mint above the cap is
 *         rejected with `Reasons.ABOVE_SUPPLY_CAP`
 * @dev Judges MINT only. FORCED mints are exempt, as enforcement. For tokens, not vaults: a vault's `maxDeposit` probes a mint
 *      of a very large amount, which a cap would refuse. Installed with no cap set it fails closed. State is keyed by token
 *      and authorised live by the token's own DEFAULT_ADMIN_ROLE. It reads the supply from the token, a view call. It has no
 *      account-level opinion: a cap is quantitative
 */
interface ISupplyCapRule is IComplianceRule {
  /**
   * @notice Emitted when a token's cap changes
   * @param _token The token
   * @param _oldCap The previous cap
   * @param _newCap The new cap
   */
  event SupplyCapSet(address indexed _token, uint256 _oldCap, uint256 _newCap);

  /**
   * @notice Thrown when the caller is not the token's admin
   * @param _token The token
   * @param _caller The caller
   */
  error SupplyCapRule_OnlyTokenAdmin(address _token, address _caller);

  /**
   * @notice Sets a token's cap
   * @dev The token's DEFAULT_ADMIN_ROLE. A cap below the supply stops further mints and takes nothing back
   * @param _token The token
   * @param _cap The most its supply may reach by minting
   */
  function setSupplyCap(
    address _token,
    uint256 _cap
  ) external;

  /**
   * @notice A token's cap
   * @param _token The token
   * @return _cap The cap
   */
  function supplyCap(
    address _token
  ) external view returns (uint256 _cap);
}
