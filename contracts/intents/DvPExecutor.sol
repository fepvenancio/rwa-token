// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IDvPExecutor} from 'interfaces/IDvPExecutor.sol';
import {IERC3009} from 'interfaces/IERC3009.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

/**
 * @title DvPExecutor
 * @notice Settles a trade of a gated security against cash atomically. Tokens authorise it by granting it their
 *         EXECUTOR_ROLE; operators (bank / relayer keys) hold OPERATOR_ROLE here
 * @dev Immutable, not a proxy: replacing it means deploying a new executor and moving the tokens' EXECUTOR_ROLE. It keeps
 *      no state beyond its roles and its pause flag, and it never keeps settlement funds: a gated cash leg moves
 *      directly between the parties, and an ERC-3009 cash leg passes through it inside one call, which succeeds only if
 *      the executor ends with the balance it started with. Anything sent to it by mistake stays there, because it has
 *      no sweep. Each token stays the single source of truth for signature, nonce, window, executor binding and policy
 *      checks. What this contract adds is the check that the two legs describe one trade, and atomicity
 */
contract DvPExecutor is AccessControl, Pausable, ReentrancyGuardTransient, IDvPExecutor {
  using SafeERC20 for IERC20;

  /// @notice Role allowed to submit trades
  bytes32 public constant OPERATOR_ROLE = keccak256('OPERATOR_ROLE');

  /// @notice Role allowed to pause the executor, with no delay
  bytes32 public constant GUARDIAN_ROLE = keccak256('GUARDIAN_ROLE');

  /// @notice Role of the recovery timelock: may only `unpause` and revoke GUARDIAN_ROLE, a path the guardian cannot
  ///         cancel (owner decision M-1). Granted and revoked by DEFAULT_ADMIN_ROLE like any role
  bytes32 public constant RECOVERY_ROLE = keccak256('RECOVERY_ROLE');

  /**
   * @notice Deploys the executor
   * @param _admin The timelock, granted DEFAULT_ADMIN_ROLE; it grants OPERATOR_ROLE and unpauses
   * @param _guardian The guardian multisig, granted GUARDIAN_ROLE; it can only pause
   */
  constructor(
    address _admin,
    address _guardian
  ) {
    if (_admin == address(0) || _guardian == address(0)) revert DvPExecutor_ZeroAddress();
    // _grantRole returns false only if the role is already held; either way the account ends up holding it.
    // aderyn-ignore-next-line(unchecked-return)
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    // As above.
    // aderyn-ignore-next-line(unchecked-return)
    _grantRole(GUARDIAN_ROLE, _guardian);
  }

  /// @inheritdoc IDvPExecutor
  function executeDvPGated(
    address _securityToken,
    address _cashToken,
    ITransferIntent.TransferIntent calldata _securitiesIntent,
    bytes calldata _securitiesSig,
    ITransferIntent.TransferIntent calldata _cashIntent,
    bytes calldata _cashSig
  ) external nonReentrant onlyRole(OPERATOR_ROLE) whenNotPaused returns (bytes32 _securitiesIntentHash) {
    if (!_legsMirror(_securityToken, _cashToken, _securitiesIntent, _cashIntent)) revert DvPExecutor_LegsDoNotMatch();

    // The cash leg's digest is not needed: the securities leg's digest identifies the trade.
    // aderyn-ignore-next-line(unchecked-return)
    _executeLeg(Leg.CASH, _cashToken, _cashIntent, _cashSig);
    _securitiesIntentHash = _executeLeg(Leg.SECURITIES, _securityToken, _securitiesIntent, _securitiesSig);

    emit DvPSettled(
      _securitiesIntentHash,
      _securitiesIntent.from,
      _securitiesIntent.to,
      _securityToken,
      _cashToken,
      _securitiesIntent.amount,
      _cashIntent.amount,
      _msgSender()
    );
  }

  /// @inheritdoc IDvPExecutor
  function executeDvP3009(
    address _securityToken,
    address _cashToken,
    ITransferIntent.TransferIntent calldata _securitiesIntent,
    bytes calldata _securitiesSig,
    Authorization calldata _authorization
  ) external nonReentrant onlyRole(OPERATOR_ROLE) whenNotPaused returns (bytes32 _securitiesIntentHash) {
    _securitiesIntentHash = ITransferIntent(_securityToken).intentHash(_securitiesIntent);
    if (!_authorizationMatches(_securityToken, _cashToken, _securitiesIntent, _authorization, _securitiesIntentHash)) {
      revert DvPExecutor_LegsDoNotMatch();
    }

    address _seller = _securitiesIntent.from;
    uint256 _executorBefore = IERC20(_cashToken).balanceOf(address(this));

    try IERC3009(_cashToken)
      .receiveWithAuthorization(
        _authorization.from,
        address(this),
        _authorization.value,
        _authorization.validAfter,
        _authorization.validBefore,
        _authorization.nonce,
        _authorization.signature
      ) {}
    catch (bytes memory _reason) {
      revert DvPExecutor_LegFailed(Leg.CASH, _reason);
    }
    // The digest was read before the call and is the one the authorization's nonce was checked against.
    // aderyn-ignore-next-line(unchecked-return)
    _executeLeg(Leg.SECURITIES, _securityToken, _securitiesIntent, _securitiesSig);
    // Read after the pull, so the payout alone is measured: a seller who is also the payer would otherwise look short.
    uint256 _sellerBefore = IERC20(_cashToken).balanceOf(_seller);
    IERC20(_cashToken).safeTransfer(_seller, _authorization.value);

    _requireBalance(_cashToken, address(this), _executorBefore);
    _requireBalance(_cashToken, _seller, _sellerBefore + _authorization.value);

    emit DvPSettled(
      _securitiesIntentHash,
      _seller,
      _securitiesIntent.to,
      _securityToken,
      _cashToken,
      _securitiesIntent.amount,
      _authorization.value,
      _msgSender()
    );
  }

  /// @inheritdoc IDvPExecutor
  function pause() external onlyRole(GUARDIAN_ROLE) {
    _pause();
  }

  /**
   * @inheritdoc IDvPExecutor
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

  /// @inheritdoc IDvPExecutor
  function canExecuteDvPGated(
    address _securityToken,
    address _cashToken,
    ITransferIntent.TransferIntent calldata _securitiesIntent,
    bytes calldata _securitiesSig,
    ITransferIntent.TransferIntent calldata _cashIntent,
    bytes calldata _cashSig
  ) external view returns (bool _ok, bytes32 _reason) {
    if (paused()) {
      _reason = Reasons.PAUSED;
    } else if (!_legsMirror(_securityToken, _cashToken, _securitiesIntent, _cashIntent)) {
      _reason = Reasons.LEGS_DO_NOT_MATCH;
    } else {
      // The token's `ok` is `reason == TRANSFER_OK`, so the reason carries it.
      // slither-disable-next-line unused-return
      (, _reason) = ITransferIntent(_cashToken).canExecute(_cashIntent, _cashSig);
      if (_reason == Reasons.TRANSFER_OK) {
        // As above.
        // slither-disable-next-line unused-return
        (, _reason) = ITransferIntent(_securityToken).canExecute(_securitiesIntent, _securitiesSig);
      }
    }
    _ok = _reason == Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IDvPExecutor
  function canExecuteDvP3009(
    address _securityToken,
    address _cashToken,
    ITransferIntent.TransferIntent calldata _securitiesIntent,
    bytes calldata _securitiesSig,
    Authorization calldata _authorization
  ) external view returns (bool _ok, bytes32 _reason) {
    if (paused()) {
      _reason = Reasons.PAUSED;
    } else if (!_authorizationMatches(
        _securityToken,
        _cashToken,
        _securitiesIntent,
        _authorization,
        ITransferIntent(_securityToken).intentHash(_securitiesIntent)
      )) {
      _reason = Reasons.LEGS_DO_NOT_MATCH;
    } else {
      _reason = _authorizationReason(_cashToken, _authorization);
      if (_reason == Reasons.TRANSFER_OK) {
        // The token's `ok` is `reason == TRANSFER_OK`, so the reason carries it.
        // slither-disable-next-line unused-return
        (, _reason) = ITransferIntent(_securityToken).canExecute(_securitiesIntent, _securitiesSig);
      }
    }
    _ok = _reason == Reasons.TRANSFER_OK;
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

  /// @inheritdoc AccessControl
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(IDvPExecutor).interfaceId || super.supportsInterface(_interfaceId);
  }

  /**
   * @notice Executes one gated leg, naming the leg if the token refuses it
   * @param _leg The leg, for the error
   * @param _token The token that holds the leg
   * @param _intent The signed intent
   * @param _sig The signature
   * @return _intentHash The EIP-712 digest of the intent
   */
  function _executeLeg(
    Leg _leg,
    address _token,
    ITransferIntent.TransferIntent calldata _intent,
    bytes calldata _sig
  ) private returns (bytes32 _intentHash) {
    try ITransferIntent(_token).executeTransfer(_intent, _sig) returns (bytes32 _executed) {
      _intentHash = _executed;
    } catch (bytes memory _reason) {
      revert DvPExecutor_LegFailed(_leg, _reason);
    }
  }

  /**
   * @notice Reverts unless an account holds exactly the expected cash balance
   * @param _cashToken The cash token
   * @param _account The account
   * @param _expected The balance it must hold
   */
  function _requireBalance(
    address _cashToken,
    address _account,
    uint256 _expected
  ) private view {
    uint256 _actual = IERC20(_cashToken).balanceOf(_account);
    if (_actual != _expected) revert DvPExecutor_CashNotConserved(_account, _expected, _actual);
  }

  /**
   * @notice What the cash token would say about an authorization, in the order Circle's FiatToken checks it: not yet
   *         valid, expired, used, then the payer's balance. Both ends of the window are exclusive
   * @param _cashToken The ERC-3009 cash token
   * @param _authorization The buyer's authorization
   * @return _reason The reason code; `Reasons.TRANSFER_OK` when nothing in the authorization blocks the payment
   */
  function _authorizationReason(
    address _cashToken,
    Authorization calldata _authorization
  ) private view returns (bytes32 _reason) {
    if (block.timestamp <= _authorization.validAfter) return Reasons.INTENT_NOT_YET_VALID;
    if (block.timestamp >= _authorization.validBefore) return Reasons.INTENT_EXPIRED;
    if (IERC3009(_cashToken).authorizationState(_authorization.from, _authorization.nonce)) return Reasons.NONCE_USED;
    if (IERC20(_cashToken).balanceOf(_authorization.from) < _authorization.value) {
      return Reasons.INSUFFICIENT_UNFROZEN;
    }
    _reason = Reasons.TRANSFER_OK;
  }

  /**
   * @notice Whether two gated legs describe one trade: the parties are swapped, each amount is the other leg's stated
   *         consideration, each stated consideration token is the other leg's token, and the tokens differ
   * @param _securityToken The security token
   * @param _cashToken The cash token
   * @param _securitiesIntent The seller's intent
   * @param _cashIntent The buyer's intent
   * @return _mirrors True if they mirror
   */
  function _legsMirror(
    address _securityToken,
    address _cashToken,
    ITransferIntent.TransferIntent calldata _securitiesIntent,
    ITransferIntent.TransferIntent calldata _cashIntent
  ) private pure returns (bool _mirrors) {
    _mirrors = _securityToken != _cashToken && _securitiesIntent.from == _cashIntent.to
      && _securitiesIntent.to == _cashIntent.from && _securitiesIntent.amount == _cashIntent.considerationAmount
      && _cashIntent.amount == _securitiesIntent.considerationAmount
      && _securitiesIntent.considerationToken == _cashToken && _cashIntent.considerationToken == _securityToken;
  }

  /**
   * @notice Whether an authorization belongs to a securities intent: from the seller's receiver, for the seller's stated
   *         consideration in the stated cash token, and tied by its nonce to this intent on this security token. The
   *         nonce includes the token's address because the executor cannot tell an honest token's hash from a
   *         counterfeit's: with the bare hash, a substituted token could report it and deliver nothing
   * @param _securityToken The security token
   * @param _cashToken The cash token
   * @param _securitiesIntent The seller's intent
   * @param _authorization The buyer's authorization
   * @param _securitiesIntentHash The security token's digest of the intent
   * @return _matches True if the authorization belongs to the intent
   */
  function _authorizationMatches(
    address _securityToken,
    address _cashToken,
    ITransferIntent.TransferIntent calldata _securitiesIntent,
    Authorization calldata _authorization,
    bytes32 _securitiesIntentHash
  ) private pure returns (bool _matches) {
    _matches = _securityToken != _cashToken && _authorization.from == _securitiesIntent.to
      && _authorization.value == _securitiesIntent.considerationAmount
      && _securitiesIntent.considerationToken == _cashToken
      && _authorization.nonce == keccak256(abi.encode(_securityToken, _securitiesIntentHash));
  }
}
