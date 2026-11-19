// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';
import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';
import {SignatureChecker} from '@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol';

import {IERC7540Deposit} from 'interfaces/IERC7540Deposit.sol';
import {IERC7540Redeem} from 'interfaces/IERC7540Redeem.sol';
import {ISignedExit} from 'interfaces/ISignedExit.sol';

/**
 * @title SignedExit
 * @notice Lets a holder leave a vault with signatures alone while a relayer submits them, and delivers what a 7540
 *         vault owes a controller that allowed it, as specified in `ISignedExit`
 * @dev Immutable, with no roles. Anyone can deploy and run one. It never holds shares or cash: a redemption pays the
 *      signed receiver from the vault, and a claim names the controller as its receiver
 */
contract SignedExit is EIP712, ISignedExit {
  /// @notice The EIP-712 type of what the holder signs
  bytes32 private constant _EXIT_TYPEHASH = keccak256(
    'Exit(address holder,address vault,uint256 shares,address receiver,uint256 minAssets,bool asynchronous,bytes32 nonce,uint256 validAfter,uint256 deadline)'
  );

  /// @notice Used and cancelled nonces of each holder, one bit each: bit `nonce & 0xff` of word `nonce >> 8`, so 256
  ///         nonces numbered one after the other take one storage slot
  mapping(address _holder => mapping(uint256 _word => uint256 _bits)) internal _nonces;

  /// @notice Deploys it, with its EIP-712 domain
  constructor() EIP712('SignedExit', '1') {}

  /// @inheritdoc ISignedExit
  function cancelExit(
    bytes32 _nonce
  ) external {
    if (_nonceUsed(msg.sender, _nonce)) revert SignedExit_NonceUsed();
    _useNonce(msg.sender, _nonce);
    emit ExitCancelled(msg.sender, _nonce);
  }

  // What a claim or an exit delivered is known only after the vault's call, so its event follows it. An exit's nonce
  // is spent before any external call, and a claim keeps no state here, so a re-entry can repeat nothing.
  // slither-disable-start reentrancy-events

  /// @inheritdoc ISignedExit
  function claimFor(
    address _vault,
    address[] calldata _controllers
  ) external returns (uint256 _delivered) {
    uint256 _count = _controllers.length;
    // One controller cannot stop the others: a claim the vault refuses is passed over and stays with the vault. The
    // vault is the caller's choice; nothing here is this contract's own, so a hostile one gains nothing.
    // slither-disable-start calls-loop
    for (uint256 _i; _i < _count; ++_i) {
      address _controller = _controllers[_i];
      uint256 _assets = IERC7540Deposit(_vault).claimableDepositRequest(0, _controller);
      if (_assets != 0) {
        // The controller is the receiver: the shares can go nowhere else.
        try IERC7540Deposit(_vault).deposit(_assets, _controller, _controller) returns (uint256 _shares) {
          emit ClaimDelivered(_vault, _controller, true, _shares);
          ++_delivered;
        } catch (bytes memory _reason) {
          emit ClaimSkipped(_vault, _controller, true, _reason);
        }
      }
      uint256 _claimableShares = IERC7540Redeem(_vault).claimableRedeemRequest(0, _controller);
      if (_claimableShares != 0) {
        // On a 7540 the third argument of `redeem` is the controller. Again the controller is the receiver.
        try IERC4626(_vault).redeem(_claimableShares, _controller, _controller) returns (uint256 _paid) {
          emit ClaimDelivered(_vault, _controller, false, _paid);
          ++_delivered;
        } catch (bytes memory _reason) {
          emit ClaimSkipped(_vault, _controller, false, _reason);
        }
      }
    }
    // slither-disable-end calls-loop
  }

  /// @inheritdoc ISignedExit
  function exitWithPermit(
    Exit calldata _exit,
    bytes calldata _exitSig,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external returns (uint256 _assets) {
    bytes32 _hash = _accept(_exit, _exitSig);

    // Anyone can submit a signed permit first, and that must not stop the exit: only the allowance matters.
    try IERC20Permit(_exit.vault).permit(_exit.holder, address(this), _exit.shares, _exit.deadline, _v, _r, _s) {}
      catch {}
    if (_exit.asynchronous) {
      // Returns the aggregated request id, 0, which says nothing. The holder is the controller and the owner.
      // slither-disable-next-line unused-return
      IERC7540Redeem(_exit.vault).requestRedeem(_exit.shares, _exit.holder, _exit.holder); // aderyn-ignore(unchecked-return)
    } else {
      // The vault pays the signed receiver itself; nothing passes through this contract.
      _assets = IERC4626(_exit.vault).redeem(_exit.shares, _exit.receiver, _exit.holder);
      if (_assets < _exit.minAssets) revert SignedExit_TooFewAssets(_exit.minAssets, _assets);
    }
    emit ExitExecuted(_hash, _exit.holder, _exit.vault, _exit.shares, _assets);
  }

  // slither-disable-end reentrancy-events

  /// @inheritdoc ISignedExit
  function nonceUsed(
    address _holder,
    bytes32 _nonce
  ) external view returns (bool _used) {
    _used = _nonceUsed(_holder, _nonce);
  }

  /// @inheritdoc ISignedExit
  function exitHash(
    Exit calldata _exit
  ) public view returns (bytes32 _hash) {
    _hash = _hashTypedDataV4(keccak256(abi.encode(_EXIT_TYPEHASH, _exit)));
  }

  /**
   * @notice Checks an exit and spends its nonce
   * @param _exit The exit
   * @param _sig The holder's signature
   * @return _hash The hash it signed
   */
  function _accept(
    Exit calldata _exit,
    bytes calldata _sig
  ) private returns (bytes32 _hash) {
    if (block.timestamp > _exit.deadline) revert SignedExit_Expired();
    if (block.timestamp < _exit.validAfter) revert SignedExit_NotYetValid();
    if (_nonceUsed(_exit.holder, _exit.nonce)) revert SignedExit_NonceUsed();
    if (_exit.asynchronous) {
      if (_exit.minAssets != 0) revert SignedExit_MinimumOnARequest();
      if (_exit.receiver != _exit.holder) revert SignedExit_ReceiverOnARequest();
    }
    _hash = exitHash(_exit);
    if (!SignatureChecker.isValidSignatureNow(_exit.holder, _hash, _sig)) revert SignedExit_BadSignature();
    _useNonce(_exit.holder, _exit.nonce);
  }

  /**
   * @notice Marks a holder's nonce as used
   * @param _holder The holder
   * @param _nonce The nonce
   */
  function _useNonce(
    address _holder,
    bytes32 _nonce
  ) private {
    _nonces[_holder][uint256(_nonce) >> 8] |= 1 << (uint256(_nonce) & 0xff);
  }

  /**
   * @notice Whether a holder's nonce was used or cancelled
   * @param _holder The holder
   * @param _nonce The nonce
   * @return _used True if used
   */
  function _nonceUsed(
    address _holder,
    bytes32 _nonce
  ) private view returns (bool _used) {
    _used = _nonces[_holder][uint256(_nonce) >> 8] & (1 << (uint256(_nonce) & 0xff)) != 0;
  }
}
