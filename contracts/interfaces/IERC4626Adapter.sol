// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';

import {IAdapter} from 'interfaces/IAdapter.sol';

/**
 * @title IERC4626Adapter
 * @notice An adapter that holds a position in one ERC-4626 vault as an ordinary depositor, priced on-chain
 */
interface IERC4626Adapter is IAdapter {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when anyone but the portfolio moves money
   * @param _caller The caller
   */
  error ERC4626Adapter_OnlyPortfolio(address _caller);

  /// @notice Thrown when a constructor argument is the zero address
  error ERC4626Adapter_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            VIEWS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The vault this adapter deposits into
   * @return _target The target, fixed at construction
   */
  // solhint-disable-next-line style-guide-casing
  function TARGET() external view returns (IERC4626 _target);

  /**
   * @notice The risk id of this target: `keccak256(abi.encode('ERC4626Adapter', target))`
   * @return _id The risk id
   */
  // solhint-disable-next-line style-guide-casing
  function RISK_ID() external view returns (bytes32 _id);

  /**
   * @notice A risk id shared with other adapters
   * @return _id The shared risk id, or zero for none
   */
  // solhint-disable-next-line style-guide-casing
  function SHARED_RISK_ID() external view returns (bytes32 _id);
}
