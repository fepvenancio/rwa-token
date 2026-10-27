// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {Fund} from 'contracts/fund/Fund.sol';
import {FundIntegrationTest} from 'contracts/fund/FundIntegration.t.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';
import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';

/**
 * @notice Random holder and enforcement actions across the three templates. Policy rejections are expected (the fund cap
 *         is small) and are counted, not treated as failures: the invariants must hold after every outcome
 */
contract FundHandler is Test {
  Fund internal _fund;
  IntentToken internal _token;
  Gated4626Vault internal _vault4626;
  Gated7540Vault internal _vault7540;
  address internal _owner;
  address internal _minter;
  address internal _burner;
  address internal _agent;
  address internal _fulfiller;
  address[4] internal _actors;

  /// @notice Actions that went through
  uint256 public executed;
  /// @notice Actions the policy or the vault state turned away
  uint256 public rejected;

  constructor(
    Fund _fundContract,
    IntentToken _classToken,
    Gated4626Vault _classVault4626,
    Gated7540Vault _classVault7540,
    address[4] memory _holders,
    address[5] memory _roleHolders
  ) {
    _fund = _fundContract;
    _token = _classToken;
    _vault4626 = _classVault4626;
    _vault7540 = _classVault7540;
    _actors = _holders;
    (_owner, _minter, _burner, _agent, _fulfiller) =
    (_roleHolders[0], _roleHolders[1], _roleHolders[2], _roleHolders[3], _roleHolders[4]);
  }

  function actors() external view returns (address[4] memory _all) {
    _all = _actors;
  }

  function mintToken(
    uint256 _who,
    uint256 _amount
  ) external {
    _amount = bound(_amount, 1, 1000 ether);
    address _to = _actor(_who);
    vm.prank(_minter);
    try _token.mint(_to, _amount) {
      ++executed;
    } catch {
      ++rejected;
    }
  }

  function burnToken(
    uint256 _who
  ) external {
    address _from = _actor(_who);
    uint256 _balance = _token.balanceOf(_from);
    if (_balance == 0) return;
    vm.prank(_burner);
    try _token.burn(_from, _balance) {
      ++executed;
    } catch {
      ++rejected;
    }
  }

  function transferToken(
    uint256 _from,
    uint256 _to,
    uint256 _amount
  ) external {
    address _sender = _actor(_from);
    uint256 _balance = _token.balanceOf(_sender);
    if (_balance == 0) return;
    // Half the time move the whole balance, which is the net-zero case at a full cap.
    _amount = _amount % 2 == 0 ? _balance : bound(_amount, 1, _balance);
    address _receiver = _actor(_to);
    vm.prank(_sender);
    try _token.transfer(_receiver, _amount) {
      ++executed;
    } catch {
      ++rejected;
    }
  }

  function forcedToken(
    uint256 _from,
    uint256 _to
  ) external {
    address _sender = _actor(_from);
    uint256 _balance = _token.balanceOf(_sender);
    if (_balance == 0) return;
    address _receiver = _actor(_to);
    vm.prank(_agent);
    try _token.forcedTransfer(_sender, _receiver, _balance) {
      ++executed;
    } catch {
      ++rejected;
    }
  }

  function deposit4626(
    uint256 _who,
    uint256 _assets
  ) external {
    _assets = bound(_assets, 1e6, 1e9);
    address _account = _actor(_who);
    vm.prank(_account);
    try _vault4626.deposit(_assets, _account) {
      ++executed;
    } catch {
      ++rejected;
    }
  }

  function redeem4626(
    uint256 _who
  ) external {
    address _account = _actor(_who);
    uint256 _shares = _vault4626.balanceOf(_account);
    if (_shares == 0) return;
    vm.prank(_account);
    try _vault4626.redeem(_shares, _account, _account) {
      ++executed;
    } catch {
      ++rejected;
    }
  }

  function transfer4626(
    uint256 _from,
    uint256 _to
  ) external {
    address _sender = _actor(_from);
    uint256 _balance = _vault4626.balanceOf(_sender);
    if (_balance == 0) return;
    address _receiver = _actor(_to);
    vm.prank(_sender);
    try _vault4626.transfer(_receiver, _balance) {
      ++executed;
    } catch {
      ++rejected;
    }
  }

  function invest7540(
    uint256 _who,
    uint256 _assets
  ) external {
    _assets = bound(_assets, 1e6, 1e9);
    address _account = _actor(_who);
    vm.prank(_account);
    try _vault7540.requestDeposit(_assets, _account, _account) {
      vm.prank(_fulfiller);
      _vault7540.fulfillDeposit(_account, _assets, _assets);
      vm.prank(_account);
      try _vault7540.mint(_assets, _account, _account) {
        ++executed;
      } catch {
        ++rejected;
      }
    } catch {
      ++rejected;
    }
  }

  function requestRedeem7540(
    uint256 _who
  ) external {
    address _account = _actor(_who);
    uint256 _shares = _vault7540.balanceOf(_account);
    if (_shares == 0) return;
    vm.prank(_account);
    try _vault7540.requestRedeem(_shares, _account, _account) {
      ++executed;
    } catch {
      ++rejected;
    }
  }

  function fulfillRedeem7540(
    uint256 _who
  ) external {
    address _account = _actor(_who);
    uint256 _pending = _vault7540.pendingRedeemRequest(0, _account);
    if (_pending == 0) return;
    vm.prank(_fulfiller);
    try _vault7540.fulfillRedeem(_account, _pending, _pending) {
      ++executed;
    } catch {
      ++rejected;
    }
  }

  function rejectRedeem7540(
    uint256 _who
  ) external {
    address _account = _actor(_who);
    if (_vault7540.pendingRedeemRequest(0, _account) == 0) return;
    vm.prank(_fulfiller);
    try _vault7540.rejectRedeemRequest(_account) {
      ++executed;
    } catch {
      ++rejected;
    }
  }

  function recoverRedeem7540(
    uint256 _who
  ) external {
    address _account = _actor(_who);
    if (_vault7540.pendingRedeemRequest(0, _account) == 0) return;
    vm.prank(_agent);
    try _vault7540.recoverRedeemRequest(_account, _account) {
      ++executed;
    } catch {
      ++rejected;
    }
  }

  function transfer7540(
    uint256 _from,
    uint256 _to
  ) external {
    address _sender = _actor(_from);
    uint256 _balance = _vault7540.balanceOf(_sender);
    if (_balance == 0) return;
    address _receiver = _actor(_to);
    vm.prank(_sender);
    try _vault7540.transfer(_receiver, _balance) {
      ++executed;
    } catch {
      ++rejected;
    }
  }

  /// @dev Only the last actor is ever exempted, so the other three can always reach the cap and the run keeps hitting it
  function setExempt(
    bool _flag
  ) external {
    vm.prank(_owner);
    _fund.setExempt(_actors[3], _flag);
    ++executed;
  }

  function _actor(
    uint256 _seed
  ) internal view returns (address _account) {
    _account = _actors[_seed % 4];
  }
}

contract FundInvariantTest is FundIntegrationTest {
  FundHandler internal _handler;

  function setUp() public override {
    super.setUp();
    // A small cap, so the handler runs into it and the net-zero rule often.
    _fund.setHolderCap(2);
    _handler = new FundHandler(
      _fund,
      _token,
      _vault4626,
      _vault7540,
      [_alice, _bob, _carol, _dave],
      [address(this), _minter, _burner, _agent, _fulfiller]
    );
    targetContract(address(_handler));
  }

  /// @dev A class bit is set exactly when the account's balance in that class is positive
  function invariant_ClassBitsMatchBalances() external view {
    address[4] memory _all = _handler.actors();
    for (uint256 _i; _i < 4; ++_i) {
      uint256 _expected;
      if (_token.balanceOf(_all[_i]) > 0) _expected |= 1;
      if (_vault4626.balanceOf(_all[_i]) > 0) _expected |= 2;
      if (_vault7540.balanceOf(_all[_i]) > 0) _expected |= 4;
      assertEq(_fund.heldClasses(_all[_i]), _expected, 'mask');
    }
  }

  /// @dev The count is the number of non-exempt accounts holding at least one class
  function invariant_CountIsTheNumberOfNonExemptInvestors() external view {
    address[4] memory _all = _handler.actors();
    uint256 _expected;
    for (uint256 _i; _i < 4; ++_i) {
      if (_fund.heldClasses(_all[_i]) != 0 && !_fund.isExempt(_all[_i])) ++_expected;
    }
    assertEq(_fund.holderCount(), _expected, 'count');
  }

  /// @dev Neither a class nor an account outside the handler's set is ever recorded
  function invariant_NoOneElseIsRecorded() external view {
    assertEq(_fund.heldClasses(address(_token)), 0);
    assertEq(_fund.heldClasses(address(_vault4626)), 0);
    assertEq(_fund.heldClasses(address(_vault7540)), 0);
    assertEq(_fund.heldClasses(_fulfiller), 0);
    assertEq(_fund.heldClasses(_custody), 0);
  }

  /// @dev Non-vacuity: every run must execute actions and must run into a rejection, or the cap was never exercised
  function afterInvariant() external view {
    assertGt(_handler.executed(), 0, 'no action executed');
    assertGt(_handler.rejected(), 0, 'no action was rejected');
  }
}
