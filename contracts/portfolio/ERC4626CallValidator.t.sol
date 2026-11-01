// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {ERC4626CallValidator} from 'contracts/portfolio/ERC4626CallValidator.sol';

contract ERC4626CallValidatorUnit is Test {
  ERC4626CallValidator internal _validator;
  address internal _account = makeAddr('account');
  address internal _other = makeAddr('other');
  address internal _target = makeAddr('target');

  function setUp() public {
    _validator = new ERC4626CallValidator();
  }

  function _allows(
    bytes memory _data
  ) internal view returns (bool _allowed) {
    _allowed = _validator.validate(_account, _target, _data);
  }

  function test_EntryToTheAccountPasses() external view {
    assertTrue(_allows(abi.encodeWithSelector(IERC4626.deposit.selector, 1, _account)));
    assertTrue(_allows(abi.encodeWithSelector(IERC4626.mint.selector, 1, _account)));
  }

  function test_ExitToTheAccountFromTheAccountPasses() external view {
    assertTrue(_allows(abi.encodeWithSelector(IERC4626.withdraw.selector, 1, _account, _account)));
    assertTrue(_allows(abi.encodeWithSelector(IERC4626.redeem.selector, 1, _account, _account)));
  }

  function testFuzz_EntryToAnyoneElseIsRefused(
    address _receiver
  ) external view {
    if (_receiver == _account) _receiver = _other;
    assertFalse(_allows(abi.encodeWithSelector(IERC4626.deposit.selector, 1, _receiver)));
    assertFalse(_allows(abi.encodeWithSelector(IERC4626.mint.selector, 1, _receiver)));
  }

  function testFuzz_ExitToAnyoneElseIsRefused(
    address _receiver
  ) external view {
    if (_receiver == _account) _receiver = _other;
    assertFalse(_allows(abi.encodeWithSelector(IERC4626.withdraw.selector, 1, _receiver, _account)));
    assertFalse(_allows(abi.encodeWithSelector(IERC4626.redeem.selector, 1, _receiver, _account)));
  }

  function testFuzz_ExitFromAnyoneElseIsRefused(
    address _owner
  ) external view {
    if (_owner == _account) _owner = _other;
    assertFalse(_allows(abi.encodeWithSelector(IERC4626.withdraw.selector, 1, _account, _owner)));
    assertFalse(_allows(abi.encodeWithSelector(IERC4626.redeem.selector, 1, _account, _owner)));
  }

  function test_AnyOtherFunctionIsRefused() external view {
    assertFalse(_allows(abi.encodeCall(IERC20.transfer, (_account, 1))));
    assertFalse(_allows(abi.encodeCall(IERC20.approve, (_account, 1))));
  }

  function test_AWrongLengthIsRefused() external view {
    assertFalse(_allows(''));
    assertFalse(_allows(hex'6e553f'));
    assertFalse(_allows(abi.encodePacked(abi.encodeWithSelector(IERC4626.deposit.selector, 1, _account), bytes1(0))));
    assertFalse(
      _allows(abi.encodePacked(abi.encodeWithSelector(IERC4626.redeem.selector, 1, _account, _account), bytes1(0)))
    );
  }
}
