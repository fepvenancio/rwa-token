// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {ILienVault} from 'interfaces/ILienVault.sol';

import {LienVault} from 'contracts/escrow/LienVault.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';

/**
 * @notice Halmos symbolic property of `LienVault`: after any one call by either of its parties, with any arguments, on a
 *         vault with two open liens, the vault holds exactly what its liens book, and the sum it keeps for the token is the sum of its liens
 * @dev Run with `npm run test:halmos`. Hardhat compiles this file but does not run `check_` functions. The token is a
 *      plain ERC-20, so `recover` always reverts here: it has no role to ask. The fuzzed invariant in `LienVault.t.sol`
 *      covers `recover` on a real token and sequences of calls. Two symbolic calls pass too and take eleven minutes, so the
 *      property keeps to one
 */
contract LienVaultHalmos is Test {
  address internal _alice = address(0x1111);
  address internal _bob = address(0x2222);
  LienVault internal _vault;
  MockAsset internal _asset;

  function setUp() public {
    _asset = new MockAsset(6);
    _vault = new LienVault();
    address[2] memory _parties = [_alice, _bob];
    for (uint256 _i; _i < 2; ++_i) {
      _asset.mint(_parties[_i], 1000);
      vm.prank(_parties[_i]);
      _asset.approve(address(_vault), type(uint256).max);
    }
    // Two liens are open before the symbolic call, one each way, so every function has something to act on.
    vm.prank(_alice);
    _vault.pledge(address(_asset), 100, _bob);
    vm.prank(_bob);
    _vault.pledge(address(_asset), 70, _alice);
  }

  /// @notice One call by either party: any of the five functions, with any arguments
  function check_theBalanceIsTheSumOfTheLiens(
    bool _byAlice,
    uint8 _kind,
    uint256 _lienId,
    uint256 _amount
  ) public {
    _call(_byAlice, _kind, _lienId, _amount);

    // At most three liens can exist: the two from `setUp` and one the call may open.
    uint256 _sum = _vault.lienOf(1).amount + _vault.lienOf(2).amount + _vault.lienOf(3).amount;
    assertEq(_vault.totalPledged(address(_asset)), _sum);
    assertEq(_asset.balanceOf(address(_vault)), _sum);
    assertEq(_vault.pledgedOf(address(_asset), _alice) + _vault.pledgedOf(address(_asset), _bob), _sum);
    assertEq(_asset.balanceOf(_alice) + _asset.balanceOf(_bob) + _sum, 2000);
  }

  /// @dev One call, which may revert: the property is about what a sequence leaves, whatever succeeded
  function _call(
    bool _byAlice,
    uint8 _kind,
    uint256 _lienId,
    uint256 _amount
  ) internal {
    address _other = _byAlice ? _bob : _alice;
    bytes memory _data;
    if (_kind == 0) _data = abi.encodeCall(ILienVault.pledge, (address(_asset), _amount, _other));
    else if (_kind == 1) _data = abi.encodeCall(ILienVault.increase, (_lienId, _amount));
    else if (_kind == 2) _data = abi.encodeCall(ILienVault.release, (_lienId, _amount));
    else if (_kind == 3) _data = abi.encodeCall(ILienVault.seize, (_lienId, _amount));
    else _data = abi.encodeCall(ILienVault.assign, (_lienId, _other));
    vm.prank(_byAlice ? _alice : _bob);
    (bool _ok,) = address(_vault).call(_data);
    _ok;
  }
}
