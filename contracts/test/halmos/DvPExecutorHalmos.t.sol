// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {IDvPExecutor} from 'interfaces/IDvPExecutor.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

import {DvPExecutor} from 'contracts/intents/DvPExecutor.sol';

/// @dev A security token that only counts executions and reports a hash that depends on the whole intent
contract HalmosStubSecurity {
  uint256 public executions;

  function intentHash(
    ITransferIntent.TransferIntent calldata _intent
  ) external pure returns (bytes32 _hash) {
    _hash = keccak256(abi.encode(_intent));
  }

  function executeTransfer(
    ITransferIntent.TransferIntent calldata _intent,
    bytes calldata
  ) external returns (bytes32 _hash) {
    ++executions;
    _hash = keccak256(abi.encode(_intent));
  }
}

/// @dev A cash token that is both a gated token (it counts executions) and an ERC-3009 token with real balances and a
///      configurable fee on the pull
contract HalmosStubCash {
  uint256 public executions;
  uint256 public pulls;
  uint256 public fee;
  mapping(address _account => uint256 _balance) public balanceOf;

  function setFee(
    uint256 _fee
  ) external {
    fee = _fee;
  }

  function mint(
    address _to,
    uint256 _amount
  ) external {
    balanceOf[_to] += _amount;
  }

  function executeTransfer(
    ITransferIntent.TransferIntent calldata,
    bytes calldata
  ) external returns (bytes32 _hash) {
    ++executions;
    _hash = bytes32(0);
  }

  function receiveWithAuthorization(
    address _from,
    address _to,
    uint256 _value,
    uint256,
    uint256,
    bytes32,
    bytes calldata
  ) external {
    require(_to == msg.sender);
    balanceOf[_from] -= _value;
    balanceOf[_to] += _value - fee;
    ++pulls;
  }

  function transfer(
    address _to,
    uint256 _value
  ) external returns (bool _ok) {
    balanceOf[msg.sender] -= _value;
    balanceOf[_to] += _value;
    _ok = true;
  }
}

/**
 * @notice Halmos symbolic properties of `DvPExecutor` on stub tokens. A returning call has run both legs once and the
 *         legs described one trade; a returning 3009 call left the executor with the cash it started with and paid the
 *         seller exactly the value
 * @dev Run with `npm run test:halmos`. Hardhat compiles this file but does not run `check_` functions.
 *      `vm.assume` is used here as a symbolic path constraint; the Wonderland "bound, not assume" rule targets fuzzing
 */
contract DvPExecutorHalmos is Test {
  DvPExecutor internal _dvp;
  HalmosStubSecurity internal _security;
  HalmosStubCash internal _cash;
  address internal _admin = address(0xA0);
  address internal _guardian = address(0xA1);
  address internal _operator = address(0xB0);

  function setUp() public {
    _security = new HalmosStubSecurity();
    _cash = new HalmosStubCash();
    _dvp = new DvPExecutor(_admin, _guardian);
    bytes32 _role = _dvp.OPERATOR_ROLE();
    vm.prank(_admin);
    _dvp.grantRole(_role, _operator);
  }

  /// @notice If a gated settlement returns, both legs ran exactly once and the two intents mirror each other
  function check_gatedReturnsOnlyIfBothLegsRanAndTheLegsMirror(
    ITransferIntent.TransferIntent memory _s,
    ITransferIntent.TransferIntent memory _c,
    bool _sameToken
  ) public {
    address _cashAddress = _sameToken ? address(_security) : address(_cash);
    vm.prank(_operator);
    try _dvp.executeDvPGated(address(_security), _cashAddress, _s, '', _c, '') {
      assert(_cashAddress != address(_security));
      assert(_cash.executions() == 1 && _security.executions() == 1);
      assert(_s.from == _c.to && _s.to == _c.from);
      assert(_s.amount == _c.considerationAmount && _c.amount == _s.considerationAmount);
      assert(_s.considerationToken == address(_cash) && _c.considerationToken == address(_security));
    } catch {}
  }

  /// @notice If an ERC-3009 settlement returns, the securities leg ran once, the cash was pulled once, the executor
  ///         ends with the cash it started with, the payout raised the seller's balance by exactly the value (a seller who is also the payer nets zero), and the nonce was the one
  ///         that ties the authorization to this intent on this token
  function check_authorizedReturnsOnlyIfCashIsConservedAndTheNonceTiesTheIntent(
    ITransferIntent.TransferIntent memory _s,
    IDvPExecutor.Authorization memory _a,
    uint256 _buyerBalance,
    uint256 _strayBalance,
    uint256 _fee
  ) public {
    vm.assume(_s.from != address(_dvp) && _a.from != address(_dvp));
    _cash.mint(_a.from, _buyerBalance);
    _cash.mint(address(_dvp), _strayBalance);
    _cash.setFee(_fee);
    uint256 _sellerBefore = _cash.balanceOf(_s.from);

    vm.prank(_operator);
    try _dvp.executeDvP3009(address(_security), address(_cash), _s, '', _a) {
      assert(_security.executions() == 1 && _cash.pulls() == 1);
      assert(_cash.balanceOf(address(_dvp)) == _strayBalance);
      // A seller who is also the payer is paid back what the pull took, so the net change is zero.
      assert(_cash.balanceOf(_s.from) == (_s.from == _a.from ? _sellerBefore : _sellerBefore + _a.value));
      assert(_a.nonce == keccak256(abi.encode(address(_security), _security.intentHash(_s))));
      assert(_a.from == _s.to && _a.value == _s.considerationAmount && _s.considerationToken == address(_cash));
    } catch {}
  }
}
