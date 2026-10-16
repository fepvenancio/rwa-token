// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

/**
 * @title Helpers
 * @notice Shared test utilities: Wonderland's "mock and expect" pattern for isolating a unit
 */
abstract contract Helpers is Test {
  /**
   * @notice Mocks a call and expects it to happen during the test
   * @param _target The mocked contract
   * @param _callData The exact calldata, or a prefix such as a bare selector
   * @param _returnData The ABI-encoded return data
   */
  function _mockAndExpect(
    address _target,
    bytes memory _callData,
    bytes memory _returnData
  ) internal {
    vm.mockCall(_target, _callData, _returnData);
    vm.expectCall(_target, _callData);
  }

  /**
   * @notice Creates a labelled address carrying a one-byte stub, so high-level calls pass the extcodesize check.
   *         Any call that is not mocked hits the stub and reverts
   * @param _name The label
   * @return _contract The address
   */
  function _mockContract(
    string memory _name
  ) internal returns (address _contract) {
    _contract = makeAddr(_name);
    vm.etch(_contract, hex'01');
  }
}
