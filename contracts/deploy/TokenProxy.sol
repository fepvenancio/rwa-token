// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

/**
 * @title TokenProxy
 * @notice OZ's ERC-1967 proxy, constructed without init data so `ProxyDeployer` can CREATE2 it at an address that
 *         does not depend on the hook carried by the init data
 * @dev It adds nothing to OZ's proxy, which accepts empty init data in the pinned release. That is safe here because
 *      `ProxyDeployer` initialises the proxy in the same transaction that creates it; a `TokenProxy` deployed any other
 *      way is not one of this system's tokens
 */
// Delegates to implementations with no payable entry point, so no ETH can be sent in (tests: *_Ether).
// aderyn-ignore-next-line(contract-locks-ether)
contract TokenProxy is ERC1967Proxy {
  /**
   * @notice Deploys the proxy
   * @param _implementation The initial implementation
   * @param _data An optional initialisation call, delegated to `_implementation`
   */
  constructor(
    address _implementation,
    bytes memory _data
  ) ERC1967Proxy(_implementation, _data) {}
}
