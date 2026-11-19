// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/**
 * @title IERC8473
 * @notice ERC-8473 (uRWA Policy, draft): an ERC-7943 token governed by an external policy
 * @dev ERC-165 id `0x0505c8c9`, the selector of `policy()`
 */
interface IERC8473 is IERC165 {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted on every installation, including the first
   * @param _previousPolicy The policy before the change; address(0) on the first installation
   * @param _newPolicy The policy after the change
   */
  event PolicyChanged(address indexed _previousPolicy, address indexed _newPolicy);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when the policy rejects a movement, or could not be asked. The token's own checks keep their own
   *         errors: on a fungible template a frozen amount in the way reverts with `ERC7943InsufficientUnfrozenBalance`
   *         and an amount above the balance with `ERC20InsufficientBalance`; on an ERC-721 a frozen token reverts with
   *         the standard's `ERC7943InsufficientUnfrozenBalance` and ownership and approval with ERC-721's errors
   * @param _reason A reason code from `Reasons`
   */
  error ERC8473PolicyRejected(bytes32 _reason);

  /*///////////////////////////////////////////////////////////////
                            VIEW
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The policy the token consults for every movement and for its ERC-7943 checks
   * @return _policy The policy
   */
  function policy() external view returns (address _policy);
}
