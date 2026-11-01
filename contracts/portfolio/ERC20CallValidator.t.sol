// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {IERC20CallValidator} from 'interfaces/IERC20CallValidator.sol';

import {ERC20CallValidator} from 'contracts/portfolio/ERC20CallValidator.sol';

contract ERC20CallValidatorUnit is Test {
  uint256 internal constant _MAX = 1000;

  ERC20CallValidator internal _validator;
  address internal _custodian = makeAddr('custodian');
  address internal _other = makeAddr('other');
  address internal _account = makeAddr('account');
  address internal _asset = makeAddr('asset');

  function setUp() public {
    _validator = new ERC20CallValidator(_custodian, _MAX);
  }

  function _allows(
    bytes memory _data
  ) internal view returns (bool _allowed) {
    _allowed = _validator.validate(_account, _asset, _data);
  }

  function test_ItKeepsItsSettings() external view {
    assertEq(_validator.WHO(), _custodian);
    assertEq(_validator.MAX_PER_CALL(), _MAX);
  }

  function test_WhenItNamesNobody_ItReverts() external {
    vm.expectRevert(IERC20CallValidator.ERC20CallValidator_ZeroAddress.selector);
    new ERC20CallValidator(address(0), _MAX);
  }

  function testFuzz_ATransferToTheOneAddressUpToTheAmountPasses(
    uint256 _amount
  ) external view {
    _amount = bound(_amount, 0, _MAX);
    assertTrue(_allows(abi.encodeCall(IERC20.transfer, (_custodian, _amount))));
  }

  function testFuzz_AnApprovalOfTheOneSpenderUpToTheAmountPasses(
    uint256 _amount
  ) external view {
    _amount = bound(_amount, 0, _MAX);
    assertTrue(_allows(abi.encodeCall(IERC20.approve, (_custodian, _amount))));
  }

  function test_OneAboveTheAmountIsRefused() external view {
    assertFalse(_allows(abi.encodeCall(IERC20.transfer, (_custodian, _MAX + 1))));
    assertFalse(_allows(abi.encodeCall(IERC20.approve, (_custodian, _MAX + 1))));
  }

  function testFuzz_AnyOtherAddressIsRefused(
    address _to
  ) external view {
    if (_to == _custodian) _to = _other;
    assertFalse(_allows(abi.encodeCall(IERC20.transfer, (_to, 1))));
    assertFalse(_allows(abi.encodeCall(IERC20.approve, (_to, 1))));
  }

  function test_TransferFromIsRefused() external view {
    assertFalse(_allows(abi.encodeCall(IERC20.transferFrom, (_account, _custodian, 1))));
  }

  /// @dev `increaseAllowance` has the same arguments as `approve`, so only the selector stops it
  function test_AnyOtherFunctionWithTheSameShapeIsRefused() external view {
    assertFalse(_allows(abi.encodeWithSignature('increaseAllowance(address,uint256)', _custodian, 1)));
    assertFalse(_allows(abi.encodeWithSignature('mint(address,uint256)', _custodian, 1)));
  }

  function testFuzz_AnyOtherLengthIsRefused(
    bytes memory _data
  ) external view {
    if (_data.length == 68) return;
    assertFalse(_allows(_data));
  }

  function test_ExtraDataIsRefused() external view {
    assertFalse(_allows(abi.encodePacked(abi.encodeCall(IERC20.transfer, (_custodian, 1)), bytes1(0))));
  }

  function test_TooShortIsRefusedRatherThanReverting() external view {
    assertFalse(_allows(''));
    assertFalse(_allows(hex'a9059c'));
  }
}
