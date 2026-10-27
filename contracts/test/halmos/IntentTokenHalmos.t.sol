// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

import {IntentToken} from 'contracts/tokens/IntentToken.sol';

/// @notice Registry stub that attests everything, so the symbolic run focuses on the token
contract HalmosAcceptAllRegistry {
  function isAttested(
    address,
    IPolicyRegistry.AttestKind
  ) external pure returns (bool _attested) {
    _attested = true;
  }
}

/// @notice Hook stub that approves every movement, so only the token's own checks are under test
contract HalmosAcceptAllHook {
  /// @dev The registry the token requires a hook to name as its own
  address public immutable REGISTRY;

  constructor(
    address _registry
  ) {
    REGISTRY = _registry;
  }

  function beforeTransfer(
    IPolicyHook.TransferContext calldata
  ) external pure returns (bytes32 _reason) {
    _reason = Reasons.TRANSFER_OK;
  }

  function wantsAfter() external pure returns (bool _wantsAfter) {
    _wantsAfter = false;
  }
}

/**
 * @notice Halmos symbolic properties on the nonce/signature, frozen-balance and executor-binding paths of the real,
 *         proxied IntentToken
 * @dev Run with `npm run test:halmos`. Hardhat compiles this file but does not run `check_` functions.
 *      Halmos discards reverting paths, so liveness properties turn a revert into `assert(false)` explicitly.
 *      `vm.assume` is used here as a symbolic path constraint; the Wonderland "bound, not assume" rule targets fuzzing.
 *      Mutation-checked on 2026-10-16: each property fails when its guarded line is removed (nonce consumption,
 *      nonce cancellation, the unfrozen-balance check, the frozen release on burn). Mutation-checked on 2026-10-23: the
 *      consideration property fails when the consideration check is removed, and the executor property fails when the
 *      executor comparison is removed
 */
contract IntentTokenHalmos is Test {
  IntentToken internal _token;
  address internal _admin = address(0xA0);
  address internal _executor = address(0xE0);
  address internal _agent = address(0xA9);
  address internal _burner = address(0xB0);
  address internal _minter = address(0xC0);
  address internal _holder = address(0x1111);
  address internal _other = address(0x2222);

  function setUp() public {
    IntentToken _impl = new IntentToken();
    address _registry = address(new HalmosAcceptAllRegistry());
    _token = IntentToken(
      address(
        new ERC1967Proxy(
          address(_impl),
          abi.encodeCall(
            IntentToken.initialize,
            (
              'Gated',
              'GTD',
              _admin,
              _admin,
              _registry,
              address(new HalmosAcceptAllHook(_registry)),
              new IComplianceRule[](0)
            )
          )
        )
      )
    );
    vm.startPrank(_admin);
    _token.grantRole(_token.EXECUTOR_ROLE(), _executor);
    _token.grantRole(_token.AGENT_ROLE(), _agent);
    _token.grantRole(_token.BURNER_ROLE(), _burner);
    _token.grantRole(_token.MINTER_ROLE(), _minter);
    vm.stopPrank();
  }

  /// @notice A successful execution consumes the nonce, and the same intent can never execute again
  function check_executedIntentCannotReplay(
    uint256 _amount,
    bytes32 _nonce,
    uint256 _deadline,
    bytes32 _ref,
    bytes memory _sig
  ) public {
    vm.prank(_minter);
    _token.mint(_holder, _amount);
    ITransferIntent.TransferIntent memory _i =
      ITransferIntent.TransferIntent(_holder, _other, _amount, _nonce, _deadline, _ref, address(0), 0, address(0), 0);

    vm.prank(_executor);
    try _token.executeTransfer(_i, _sig) {
      assert(_token.nonceUsed(_holder, _nonce));
      vm.prank(_executor);
      try _token.executeTransfer(_i, _sig) {
        assert(false);
      } catch {}
    } catch {}
  }

  /// @notice A cancelled nonce never executes, whatever the signature
  function check_cancelledNonceNeverExecutes(
    uint256 _amount,
    bytes32 _nonce,
    uint256 _deadline,
    bytes32 _ref,
    bytes memory _sig
  ) public {
    vm.prank(_minter);
    _token.mint(_holder, _amount);
    vm.prank(_holder);
    _token.cancelIntent(_nonce);
    ITransferIntent.TransferIntent memory _i =
      ITransferIntent.TransferIntent(_holder, _other, _amount, _nonce, _deadline, _ref, address(0), 0, address(0), 0);

    vm.prank(_executor);
    try _token.executeTransfer(_i, _sig) {
      assert(false);
    } catch {}
  }

  /// @notice An intent that names an executor never executes from any other caller, whatever else it says and
  ///         whatever the signature
  function check_intentNamingAnotherExecutorNeverExecutes(
    uint256 _amount,
    bytes32 _nonce,
    uint256 _deadline,
    bytes32 _ref,
    address _named,
    uint256 _validAfter,
    address _considerationToken,
    uint256 _considerationAmount,
    bytes memory _sig
  ) public {
    vm.assume(_named != address(0) && _named != _executor);
    vm.prank(_minter);
    _token.mint(_holder, _amount);
    ITransferIntent.TransferIntent memory _i = ITransferIntent.TransferIntent(
      _holder, _other, _amount, _nonce, _deadline, _ref, _named, _validAfter, _considerationToken, _considerationAmount
    );

    vm.prank(_executor);
    try _token.executeTransfer(_i, _sig) {
      assert(false);
    } catch {}
  }

  /// @notice An intent that states a consideration and names no executor never executes, whoever submits it
  function check_considerationWithoutExecutorNeverExecutes(
    uint256 _amount,
    bytes32 _nonce,
    uint256 _deadline,
    bytes32 _ref,
    uint256 _validAfter,
    address _considerationToken,
    uint256 _considerationAmount,
    bytes memory _sig
  ) public {
    vm.assume(_considerationToken != address(0) || _considerationAmount != 0);
    vm.prank(_minter);
    _token.mint(_holder, _amount);
    ITransferIntent.TransferIntent memory _i = ITransferIntent.TransferIntent(
      _holder,
      _other,
      _amount,
      _nonce,
      _deadline,
      _ref,
      address(0),
      _validAfter,
      _considerationToken,
      _considerationAmount
    );

    vm.prank(_executor);
    try _token.executeTransfer(_i, _sig) {
      assert(false);
    } catch {}
  }

  /// @notice Holder transfers never spend frozen tokens, and no action raises the frozen amount. The frozen amount may
  ///         exceed the balance (ERC-7943), in which case nothing is unfrozen
  function check_frozenBalanceInvariants(
    uint256 _minted,
    uint256 _frozen,
    uint256 _amount,
    uint8 _action
  ) public {
    vm.prank(_minter);
    _token.mint(_holder, _minted);
    vm.prank(_agent);
    _token.setFrozenTokens(_holder, _frozen);

    uint256 _before = _token.balanceOf(_holder);
    uint256 _unfrozen = _before > _frozen ? _before - _frozen : 0;
    if (_action % 3 == 0) {
      vm.prank(_holder);
      try _token.transfer(_other, _amount) {
        assert(_amount <= _unfrozen);
        assert(_token.getFrozenTokens(_holder) == _frozen);
      } catch {}
    } else if (_action % 3 == 1) {
      vm.prank(_agent);
      try _token.forcedTransfer(_holder, _other, _amount) {} catch {}
    } else {
      vm.prank(_burner);
      try _token.burn(_holder, _amount) {} catch {}
    }
    assert(_token.getFrozenTokens(_holder) <= _frozen);
  }

  /// @notice Enforcement always reaches frozen tokens, and releases exactly the part of the amount that was frozen:
  ///         burn and forcedTransfer of any amount up to the balance succeed, whatever the frozen amount
  function check_enforcementCanTakeFrozenTokens(
    uint256 _minted,
    uint256 _frozen,
    uint256 _amount,
    bool _isBurn
  ) public {
    vm.assume(_amount <= _minted);
    vm.prank(_minter);
    _token.mint(_holder, _minted);
    vm.prank(_agent);
    _token.setFrozenTokens(_holder, _frozen);

    uint256 _unfrozen = _minted > _frozen ? _minted - _frozen : 0;
    uint256 _needed = _amount > _unfrozen ? _amount - _unfrozen : 0;

    if (_isBurn) {
      vm.prank(_burner);
      try _token.burn(_holder, _amount) {}
      catch {
        assert(false);
      }
    } else {
      vm.prank(_agent);
      try _token.forcedTransfer(_holder, _other, _amount) {}
      catch {
        assert(false);
      }
    }
    assert(_token.balanceOf(_holder) == _minted - _amount);
    assert(_token.getFrozenTokens(_holder) == _frozen - _needed);
  }
}
