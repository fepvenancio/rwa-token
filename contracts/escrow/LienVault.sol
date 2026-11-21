// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';

import {ILienVault} from 'interfaces/ILienVault.sol';

/**
 * @title LienVault
 * @notice Holds pledged tokens under liens, as specified in `ILienVault`
 * @dev Immutable, one per issuer, with no storage but the liens. It has no pause of its own: a token's pause already
 *      stops every movement in and out
 */
contract LienVault is ILienVault, ReentrancyGuardTransient {
  using SafeERC20 for IERC20;

  /// @inheritdoc ILienVault
  bytes32 public constant AGENT_ROLE = keccak256('AGENT_ROLE');

  /// @inheritdoc ILienVault
  uint256 public lienCount;

  /// @inheritdoc ILienVault
  mapping(address _token => mapping(address _pledgor => uint256 _amount)) public pledgedOf;

  /// @inheritdoc ILienVault
  mapping(address _token => uint256 _amount) public totalPledged;

  /// @notice The liens; a closed one is deleted
  mapping(uint256 _lienId => Lien _lien) internal _liens;

  /// @inheritdoc ILienVault
  function pledge(
    address _token,
    uint256 _amount,
    address _beneficiary
  ) external nonReentrant returns (uint256 _lienId) {
    if (_token == address(0) || _amount == 0) revert LienVault_InvalidValue();
    _checkAccount(_beneficiary);
    _lienId = ++lienCount;
    _liens[_lienId] = Lien({token: _token, pledgor: msg.sender, beneficiary: _beneficiary, amount: _amount});
    emit LienOpened(_lienId, _token, msg.sender, _beneficiary, _amount);
    _take(_token, _amount);
  }

  /// @inheritdoc ILienVault
  function increase(
    uint256 _lienId,
    uint256 _amount
  ) external nonReentrant {
    Lien storage _lien = _open(_lienId);
    if (msg.sender != _lien.pledgor) revert LienVault_Unauthorized(msg.sender);
    if (_amount == 0) revert LienVault_InvalidValue();
    _lien.amount += _amount;
    emit LienIncreased(_lienId, _amount);
    _take(_lien.token, _amount);
  }

  /// @inheritdoc ILienVault
  function release(
    uint256 _lienId,
    uint256 _amount
  ) external nonReentrant {
    Lien storage _lien = _open(_lienId);
    if (msg.sender != _lien.beneficiary) revert LienVault_Unauthorized(msg.sender);
    (address _token, address _pledgor) = (_lien.token, _lien.pledgor);
    _lower(_lienId, _lien, _amount);
    emit LienReleased(_lienId, _amount);
    IERC20(_token).safeTransfer(_pledgor, _amount);
  }

  /// @inheritdoc ILienVault
  function seize(
    uint256 _lienId,
    uint256 _amount
  ) external nonReentrant {
    Lien storage _lien = _open(_lienId);
    if (msg.sender != _lien.beneficiary) revert LienVault_Unauthorized(msg.sender);
    address _token = _lien.token;
    _lower(_lienId, _lien, _amount);
    emit LienSeized(_lienId, msg.sender, _amount);
    IERC20(_token).safeTransfer(msg.sender, _amount);
  }

  /// @inheritdoc ILienVault
  function assign(
    uint256 _lienId,
    address _newBeneficiary
  ) external nonReentrant {
    Lien storage _lien = _open(_lienId);
    if (msg.sender != _lien.beneficiary) revert LienVault_Unauthorized(msg.sender);
    _checkAccount(_newBeneficiary);
    _lien.beneficiary = _newBeneficiary;
    emit LienAssigned(_lienId, msg.sender, _newBeneficiary);
  }

  /// @inheritdoc ILienVault
  function recover(
    uint256 _lienId,
    address _to
  ) external nonReentrant {
    Lien storage _lien = _open(_lienId);
    (address _token, uint256 _amount) = (_lien.token, _lien.amount);
    // The token is asked who its agent is, as the other legos ask their vault. A token with no such role reverts here.
    if (!IAccessControl(_token).hasRole(AGENT_ROLE, msg.sender)) revert LienVault_Unauthorized(msg.sender);
    _checkAccount(_to);
    _lower(_lienId, _lien, _amount);
    emit LienRecovered(_lienId, _to, _amount, msg.sender);
    IERC20(_token).safeTransfer(_to, _amount);
  }

  /// @inheritdoc ILienVault
  function lienOf(
    uint256 _lienId
  ) external view returns (Lien memory _lien) {
    _lien = _liens[_lienId];
  }

  /**
   * @notice Pulls tokens from the caller and books them, or reverts if another amount arrived
   * @param _token The token
   * @param _amount The amount
   */
  function _take(
    address _token,
    uint256 _amount
  ) internal {
    pledgedOf[_token][msg.sender] += _amount;
    totalPledged[_token] += _amount;
    uint256 _before = IERC20(_token).balanceOf(address(this));
    IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
    uint256 _received = IERC20(_token).balanceOf(address(this)) - _before;
    if (_received != _amount) revert LienVault_WrongAmountReceived(_amount, _received);
  }

  /**
   * @notice Takes an amount off a lien and off the sums, and closes a lien that holds nothing
   * @param _lienId The lien
   * @param _lien The lien, in storage
   * @param _amount The amount, not zero and not above what the lien holds
   */
  function _lower(
    uint256 _lienId,
    Lien storage _lien,
    uint256 _amount
  ) internal {
    if (_amount == 0) revert LienVault_InvalidValue();
    uint256 _held = _lien.amount;
    if (_amount > _held) revert LienVault_ExceedsLien(_lienId, _amount, _held);
    pledgedOf[_lien.token][_lien.pledgor] -= _amount;
    totalPledged[_lien.token] -= _amount;
    if (_amount == _held) delete _liens[_lienId];
    else _lien.amount = _held - _amount;
  }

  /**
   * @notice A lien that exists and holds something, or a revert
   * @param _lienId The lien
   * @return _lien It, in storage
   */
  function _open(
    uint256 _lienId
  ) internal view returns (Lien storage _lien) {
    _lien = _liens[_lienId];
    if (_lien.pledgor == address(0)) revert LienVault_NoLien(_lienId);
  }

  /**
   * @notice Reverts for the zero address and for this contract, neither of which could ever act on a lien
   * @param _account The account
   */
  function _checkAccount(
    address _account
  ) internal view {
    if (_account == address(0) || _account == address(this)) revert LienVault_InvalidValue();
  }
}
