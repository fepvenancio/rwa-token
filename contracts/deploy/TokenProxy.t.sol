// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC1967Utils} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol';
import {Test} from 'forge-std/Test.sol';

import {TokenProxy} from 'contracts/deploy/TokenProxy.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';

contract TokenProxyUnitTest is Test {
  MockAsset internal _impl = new MockAsset(6);

  function test_WhenTheInitDataIsEmpty_ItDeploysUninitialised() external {
    address _proxy = address(new TokenProxy(address(_impl), ''));
    assertEq(address(uint160(uint256(vm.load(_proxy, ERC1967Utils.IMPLEMENTATION_SLOT)))), address(_impl));
    assertEq(MockAsset(_proxy).totalSupply(), 0);
  }

  function test_WhenTheInitDataIsSet_ItDelegatesItAtConstruction() external {
    address _proxy = address(new TokenProxy(address(_impl), abi.encodeCall(MockAsset.mint, (address(this), 7))));
    assertEq(MockAsset(_proxy).balanceOf(address(this)), 7);
  }
}
