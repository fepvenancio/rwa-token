// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {IERC1155} from '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';
import {SignatureChecker} from '@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol';
import {ERC165Checker} from '@openzeppelin/contracts/utils/introspection/ERC165Checker.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IERC7943Fungible} from 'interfaces/IERC7943Fungible.sol';
import {IERC7943MultiToken} from 'interfaces/IERC7943MultiToken.sol';
import {IGated1155} from 'interfaces/IGated1155.sol';
import {IOrderSettlement} from 'interfaces/IOrderSettlement.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';

/**
 * @title OrderSettlement
 * @notice Settles signed orders against each other, in whole or in parts, many in one transaction, as specified in
 *         `IOrderSettlement`
 * @dev Immutable, not a proxy, and not attested: it holds no role on any token. It moves a maker's tokens only under an
 *      allowance that maker gave it, and only as that maker's signed order allows. It never holds a token: each leg
 *      goes straight from one maker to the other. Its state is its roles, its pause flag, what each order has filled
 *      and the nonces makers cancelled
 */
contract OrderSettlement is AccessControl, Pausable, ReentrancyGuard, EIP712, IOrderSettlement {
  /// @inheritdoc IOrderSettlement
  bytes32 public constant OPERATOR_ROLE = keccak256('OPERATOR_ROLE');

  /// @inheritdoc IOrderSettlement
  bytes32 public constant GUARDIAN_ROLE = keccak256('GUARDIAN_ROLE');

  /// @inheritdoc IOrderSettlement
  bytes32 public constant RECOVERY_ROLE = keccak256('RECOVERY_ROLE');

  /// @notice The EIP-712 type of what a maker signs
  bytes32 private constant _ORDER_TYPEHASH = keccak256(
    'Order(address maker,address giveToken,uint256 giveId,uint256 giveAmount,address takeToken,uint256 takeId,uint256 takeAmount,bool giveIs1155,bool takeIs1155,address taker,bool allOrNothing,bytes32 nonce,uint256 validAfter,uint256 deadline)'
  );

  /// @inheritdoc IOrderSettlement
  mapping(bytes32 _orderHash => uint256 _given) public filled;

  /// @notice The nonces each maker cancelled, one bit each: bit `nonce & 0xff` of word `nonce >> 8`
  mapping(address _maker => mapping(uint256 _word => uint256 _bits)) internal _cancelled;

  /**
   * @notice Deploys the executor
   * @param _admin The timelock, granted DEFAULT_ADMIN_ROLE; it grants OPERATOR_ROLE and unpauses
   * @param _guardian The guardian multisig, granted GUARDIAN_ROLE; it can only pause
   */
  constructor(
    address _admin,
    address _guardian
  ) EIP712('OrderSettlement', '1') {
    if (_admin == address(0) || _guardian == address(0)) revert OrderSettlement_ZeroAddress();
    // _grantRole returns false only if the role is already held; either way the account ends up holding it.
    // aderyn-ignore-next-line(unchecked-return)
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    // As above.
    // aderyn-ignore-next-line(unchecked-return)
    _grantRole(GUARDIAN_ROLE, _guardian);
  }

  /// @inheritdoc IOrderSettlement
  function cancelOrder(
    bytes32 _nonce
  ) external {
    address _maker = _msgSender();
    if (_isCancelled(_maker, _nonce)) revert OrderSettlement_NonceCancelled();
    _cancelled[_maker][uint256(_nonce) >> 8] |= 1 << (uint256(_nonce) & 0xff);
    emit OrderCancelled(_maker, _nonce);
  }

  /// @inheritdoc IOrderSettlement
  function pause() external onlyRole(GUARDIAN_ROLE) {
    _pause();
  }

  /// @inheritdoc IOrderSettlement
  function settle(
    Fill[] calldata _fills
  ) external nonReentrant onlyRole(OPERATOR_ROLE) whenNotPaused {
    uint256 _count = _fills.length;
    for (uint256 _i; _i < _count; ++_i) {
      _settle(_i, _fills[_i]);
    }
  }

  /**
   * @inheritdoc IOrderSettlement
   * @dev DEFAULT_ADMIN_ROLE (the main timelock) or RECOVERY_ROLE (the recovery timelock, which the guardian cannot
   *      cancel). Anyone else gets the usual AccessControl error for DEFAULT_ADMIN_ROLE
   */
  function unpause() external {
    address _sender = _msgSender();
    if (!hasRole(DEFAULT_ADMIN_ROLE, _sender) && !hasRole(RECOVERY_ROLE, _sender)) {
      revert AccessControlUnauthorizedAccount(_sender, DEFAULT_ADMIN_ROLE);
    }
    _unpause();
  }

  /// @inheritdoc IOrderSettlement
  function canFill(
    Fill calldata _fill
  ) external view returns (Refusal _refusal, bool _secondOrder, bytes32 _tokenReason) {
    (_refusal, _secondOrder) = _refuses(_fill, orderHash(_fill.first), orderHash(_fill.second));
    if (_refusal != Refusal.NONE) return (_refusal, _secondOrder, bytes32(0));

    bool _refused;
    (_refused, _tokenReason) = _tokenRefuses(_fill.first, _fill.second.maker, _fill.firstGives);
    if (_refused) return (Refusal.TOKEN_REFUSES, false, _tokenReason);
    (_refused, _tokenReason) = _tokenRefuses(_fill.second, _fill.first.maker, _fill.secondGives);
    if (_refused) return (Refusal.TOKEN_REFUSES, true, _tokenReason);
  }

  /// @inheritdoc IOrderSettlement
  function nonceCancelled(
    address _maker,
    bytes32 _nonce
  ) external view returns (bool _isNonceCancelled) {
    _isNonceCancelled = _isCancelled(_maker, _nonce);
  }

  /**
   * @inheritdoc AccessControl
   * @dev RECOVERY_ROLE may revoke GUARDIAN_ROLE and nothing else; every other revocation needs the role's admin
   */
  function revokeRole(
    bytes32 _role,
    address _account
  ) public override {
    if (_role == GUARDIAN_ROLE && hasRole(RECOVERY_ROLE, _msgSender())) {
      // _revokeRole returns false only if the role was not held; either way the account ends up without it.
      // aderyn-ignore-next-line(unchecked-return)
      _revokeRole(_role, _account);
      return;
    }
    super.revokeRole(_role, _account);
  }

  /// @inheritdoc IOrderSettlement
  function orderHash(
    Order calldata _order
  ) public view returns (bytes32 _hash) {
    _hash = _hashTypedDataV4(keccak256(abi.encode(_ORDER_TYPEHASH, _order)));
  }

  /// @inheritdoc AccessControl
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(IOrderSettlement).interfaceId || super.supportsInterface(_interfaceId);
  }

  /**
   * @notice Settles one fill: the checks, what both orders have filled, the two legs, the two events
   * @param _index The fill's place in the batch, for the errors
   * @param _fill The fill
   */
  function _settle(
    uint256 _index,
    Fill calldata _fill
  ) internal {
    bytes32 _firstHash = orderHash(_fill.first);
    bytes32 _secondHash = orderHash(_fill.second);
    (Refusal _refusal, bool _secondOrder) = _refuses(_fill, _firstHash, _secondHash);
    if (_refusal != Refusal.NONE) revert OrderSettlement_FillRefused(_index, _refusal, _secondOrder);

    // Recorded before either token is called, and the entry point is guarded: a token that calls back cannot fill an
    // order twice.
    filled[_firstHash] += _fill.firstGives;
    filled[_secondHash] += _fill.secondGives;

    _move(_index, false, _fill.first, _fill.second.maker, _fill.firstGives);
    _move(_index, true, _fill.second, _fill.first.maker, _fill.secondGives);

    // Emitted after the legs: the guard blocks re-entry, and what was filled is already recorded.
    // slither-disable-start reentrancy-events
    emit OrderFilled(_firstHash, _fill.first.maker, _fill.second.maker, _fill.firstGives, _fill.secondGives);
    emit OrderFilled(_secondHash, _fill.second.maker, _fill.first.maker, _fill.secondGives, _fill.firstGives);
    // slither-disable-end reentrancy-events
  }

  /**
   * @notice Moves what an order's maker gives to the other maker, straight from one to the other
   * @dev An ERC-20 must raise the receiver's balance by exactly the amount, so a token that keeps a fee cannot settle.
   *      A token's own revert comes back in `OrderSettlement_TransferFailed`
   * @param _index The fill's place in the batch, for the errors
   * @param _secondLeg True for the second maker's leg, for the errors
   * @param _order The order whose maker gives
   * @param _to The other maker
   * @param _amount The amount
   */
  function _move(
    uint256 _index,
    bool _secondLeg,
    Order calldata _order,
    address _to,
    uint256 _amount
  ) internal {
    address _token = _order.giveToken;
    if (_order.giveIs1155) {
      try IERC1155(_token).safeTransferFrom(_order.maker, _to, _order.giveId, _amount, '') {}
      catch (bytes memory _reason) {
        revert OrderSettlement_TransferFailed(_index, _secondLeg, _reason);
      }
      return;
    }

    // The balance is read before and after the call on purpose: the difference is what the receiver got. The entry
    // point is guarded, so nothing else of this contract runs in between.
    // slither-disable-start reentrancy-balance
    uint256 _before = IERC20(_token).balanceOf(_to);
    // A low-level call, so that the token's own error can be reported with the fill's index, and so that a token
    // that returns nothing is accepted as OpenZeppelin's SafeERC20 accepts it. The maker signed the order naming this
    // token and this amount, checked above.
    // slither-disable-next-line low-level-calls,arbitrary-send-erc20
    (bool _ok, bytes memory _returned) = _token.call(abi.encodeCall(IERC20.transferFrom, (_order.maker, _to, _amount)));
    if (!_ok || !_saysTrue(_token, _returned)) revert OrderSettlement_TransferFailed(_index, _secondLeg, _returned);
    uint256 _received = IERC20(_token).balanceOf(_to) - _before;
    if (_received != _amount) revert OrderSettlement_WrongAmountReceived(_index, _secondLeg, _amount, _received);
    // slither-disable-end reentrancy-balance
  }

  /**
   * @notice The first of the contract's own checks a fill fails
   * @param _fill The fill
   * @param _firstHash The first order's hash
   * @param _secondHash The second order's hash
   * @return _refusal The refusal, or `NONE`
   * @return _secondOrder True when it is about the second order
   */
  function _refuses(
    Fill calldata _fill,
    bytes32 _firstHash,
    bytes32 _secondHash
  ) internal view returns (Refusal _refusal, bool _secondOrder) {
    if (_fill.firstGives == 0 || _fill.secondGives == 0) return (Refusal.ZERO_AMOUNT, false);
    _refusal = _shape(_fill.first);
    if (_refusal != Refusal.NONE) return (_refusal, false);
    _refusal = _shape(_fill.second);
    if (_refusal != Refusal.NONE) return (_refusal, true);
    if (_fill.first.maker == _fill.second.maker) return (Refusal.SELF_FILL, false);
    if (!_cross(_fill.first, _fill.second)) return (Refusal.DO_NOT_CROSS, false);

    _refusal = _state(_fill.first, _firstHash, _fill.firstSig, _fill.second.maker, _fill.firstGives, _fill.secondGives);
    if (_refusal != Refusal.NONE) return (_refusal, false);
    _refusal =
      _state(_fill.second, _secondHash, _fill.secondSig, _fill.first.maker, _fill.secondGives, _fill.firstGives);
    _secondOrder = _refusal != Refusal.NONE;
  }

  /**
   * @notice What an order's own state and terms say about a fill of it
   * @param _order The order
   * @param _hash Its hash
   * @param _sig Its maker's signature
   * @param _counterparty The other maker
   * @param _gives What its maker gives in this fill
   * @param _receives What its maker receives in this fill
   * @return _refusal The refusal, or `NONE`
   */
  function _state(
    Order calldata _order,
    bytes32 _hash,
    bytes calldata _sig,
    address _counterparty,
    uint256 _gives,
    uint256 _receives
  ) internal view returns (Refusal _refusal) {
    if (block.timestamp > _order.deadline) return Refusal.EXPIRED;
    if (block.timestamp < _order.validAfter) return Refusal.NOT_YET_VALID;
    if (_isCancelled(_order.maker, _order.nonce)) return Refusal.CANCELLED;
    if (_order.taker != address(0) && _order.taker != _counterparty) return Refusal.WRONG_TAKER;
    if (!SignatureChecker.isValidSignatureNow(_order.maker, _hash, _sig)) return Refusal.BAD_SIGNATURE;
    // `_gives` is compared before it is added, so the sum cannot overflow.
    if (_gives > _order.giveAmount - Math.min(filled[_hash], _order.giveAmount)) return Refusal.OVERFILLED;
    if (_order.allOrNothing && _gives != _order.giveAmount) return Refusal.NOT_WHOLE;
    // The maker's limit, rounded against the counterparty. A 512-bit product, so no two amounts overflow it.
    if (_receives < Math.mulDiv(_gives, _order.takeAmount, _order.giveAmount, Math.Rounding.Ceil)) {
      return Refusal.BELOW_LIMIT;
    }
  }

  /**
   * @notice Whether the token of an order's leg refuses it in its own pre-flight
   * @dev One of the stack's tokens is asked for its reasoned pre-flight, which counts the balance. A token that answers
   *      only ERC-7943 is asked `canTransfer`. Any other token is not asked
   * @param _order The order whose maker gives
   * @param _to The other maker
   * @param _amount The amount
   * @return _refused True if the token refuses
   * @return _reason The token's reason, when it gives one
   */
  function _tokenRefuses(
    Order calldata _order,
    address _to,
    uint256 _amount
  ) internal view returns (bool _refused, bytes32 _reason) {
    address _token = _order.giveToken;
    bool _ok = true;
    if (_order.giveIs1155) {
      if (ERC165Checker.supportsInterface(_token, type(IGated1155).interfaceId)) {
        (_ok, _reason) = IGated1155(_token).canTransferWithReason(_order.maker, _to, _order.giveId, _amount);
      } else if (ERC165Checker.supportsInterface(_token, type(IERC7943MultiToken).interfaceId)) {
        _ok = IERC7943MultiToken(_token).canTransfer(_order.maker, _to, _order.giveId, _amount);
      }
    } else if (ERC165Checker.supportsInterface(_token, type(IPolicyGated).interfaceId)) {
      (_ok, _reason) = IPolicyGated(_token).canTransferWithReason(_order.maker, _to, _amount);
    } else if (ERC165Checker.supportsInterface(_token, type(IERC7943Fungible).interfaceId)) {
      _ok = IERC7943Fungible(_token).canTransfer(_order.maker, _to, _amount);
    }
    _refused = !_ok;
  }

  /**
   * @notice Whether a maker cancelled a nonce
   * @param _maker The maker
   * @param _nonce The nonce
   * @return _isNonceCancelled True if cancelled
   */
  function _isCancelled(
    address _maker,
    bytes32 _nonce
  ) internal view returns (bool _isNonceCancelled) {
    _isNonceCancelled = _cancelled[_maker][uint256(_nonce) >> 8] & (1 << (uint256(_nonce) & 0xff)) != 0;
  }

  /**
   * @notice Whether an ERC-20's answer to a transfer is a yes: nothing from a contract, or exactly `true`
   * @param _token The token
   * @param _returned What it returned
   * @return _yes True if the transfer is to be taken as done
   */
  function _saysTrue(
    address _token,
    bytes memory _returned
  ) internal view returns (bool _yes) {
    if (_returned.length == 0) return _token.code.length != 0;
    _yes = _returned.length == 32 && abi.decode(_returned, (bool));
  }

  /**
   * @notice Whether two orders name each other's assets: each gives what the other takes, token, id and kind
   * @param _first One order
   * @param _second The other
   * @return _crosses True if they cross
   */
  function _cross(
    Order calldata _first,
    Order calldata _second
  ) internal pure returns (bool _crosses) {
    _crosses = _first.giveToken == _second.takeToken && _first.giveId == _second.takeId
      && _first.giveIs1155 == _second.takeIs1155 && _first.takeToken == _second.giveToken
      && _first.takeId == _second.giveId && _first.takeIs1155 == _second.giveIs1155;
  }

  /**
   * @notice What an order's own shape says, whatever it is filled against
   * @param _order The order
   * @return _refusal The refusal, or `NONE`
   */
  function _shape(
    Order calldata _order
  ) internal pure returns (Refusal _refusal) {
    if (_order.giveAmount == 0 || _order.takeAmount == 0) return Refusal.EMPTY_ORDER;
    if ((!_order.giveIs1155 && _order.giveId != 0) || (!_order.takeIs1155 && _order.takeId != 0)) {
      return Refusal.ID_ON_ERC20;
    }
    if (_order.giveToken == _order.takeToken && _order.giveId == _order.takeId) return Refusal.SAME_ASSET;
  }
}
