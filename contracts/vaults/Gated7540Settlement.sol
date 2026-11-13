// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IGated7540Vault} from 'interfaces/IGated7540Vault.sol';
import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';
// Needed by the compiler to resolve `@inheritdoc ITemplated`; solhint does not see NatSpec usage.
// solhint-disable-next-line no-unused-vars
import {ITemplated} from 'interfaces/ITemplated.sol';

import {Gated7540Common} from 'contracts/vaults/Gated7540Common.sol';

/**
 * @title Gated7540Settlement
 * @notice The settlement and recovery functions of `Gated7540Vault`, as specified in `IGated7540Vault`. The vault's named
 *         functions hand these calls here by delegatecall, so they run on the vault's storage, with its caller
 * @dev Created by the vault implementation's constructor, so the implementation's attested codehash pins its address. It
 *      inherits the base for its internals. The vault forwards only these six selectors, so the base's external functions
 *      in this contract cannot be reached from a proxy. Reached directly it has its own empty storage: nobody holds a role
 *      on it, nobody can be granted one, it has no initializer that could change that, and it holds no money
 * @custom:oz-upgrades-unsafe-allow missing-initializer
 */
// No receive or payable function, so no ETH can enter.
// aderyn-ignore-next-line(contract-locks-ether)
contract Gated7540Settlement is Gated7540Common {
  using SafeERC20 for IERC20;
  using SafeCast for uint256;

  /**
   * @notice What one settlement struck
   * @param deposits The assets of the period's deposit requests
   * @param redemptions The shares of its redemption requests, carried ones included
   * @param redeemed The shares taken from them
   * @param supply All shares at the period's value
   * @param shares The shares its deposits bought
   * @param assets The assets the shares taken pay
   */
  struct Settlement {
    uint256 deposits;
    uint256 redemptions;
    uint256 redeemed;
    uint256 supply;
    uint256 shares;
    uint256 assets;
  }

  /// @notice Closes the open period and opens the next, as `IGated7540Vault.closePeriod` specifies
  function closePeriod() external onlyRole(_SETTLER_ROLE) {
    Gated7540Storage storage $ = _getGated7540Storage();
    uint64 _open = $.openPeriod;
    uint64 _next = $.settledPeriod + 1;
    if (_open != _next) revert IGated7540Vault.Gated7540Vault_PeriodUnsettled(_next);
    $.openPeriod = _open + 1;
    emit IGated7540Vault.PeriodClosed(_open);
  }

  /**
   * @notice Settles the closed period at one price, as `IGated7540Vault.settlePeriod` specifies
   * @param _nav The net asset value the period deals at
   * @param _fee The fee to pay, in assets
   * @param _cash The account that receives net inflow and funds net outflow
   * @param _feeRecipient The account that receives the fee
   * @param _redeemLimit The most shares to take from the period's redemptions; the rest carry to the next period
   */
  function settlePeriod(
    uint256 _nav,
    uint256 _fee,
    address _cash,
    address _feeRecipient,
    uint256 _redeemLimit
  ) external onlyRole(_SETTLER_ROLE) whenNotPaused {
    Settlement memory _s = _strike(_nav, _fee, _redeemLimit);
    if (_s.redeemed != 0) _burn(address(this), _s.redeemed);
    // The book was written before the burn, `_net` writes no state, and what Slither reads as a write here is the storage
    // pointer.
    // slither-disable-next-line reentrancy-no-eth
    _net(_s.deposits, _s.assets, _fee, _cash, _feeRecipient);
  }

  /**
   * @notice Rejects a controller's whole pending deposit, as `IGated7540Vault.rejectDepositRequest` specifies
   * @param _controller The controller
   */
  function rejectDepositRequest(
    address _controller
  ) external {
    uint256 _assets = _takePending(_controller, true);
    Gated7540Storage storage $ = _getGated7540Storage();
    $.pendingDeposits -= _assets;
    emit IGated7540Vault.DepositRequestRejected(_controller, _assets);
    $.asset.safeTransfer(_controller, _assets);
  }

  /**
   * @notice Rejects a controller's whole pending redemption, as `IGated7540Vault.rejectRedeemRequest` specifies
   * @param _controller The controller
   */
  function rejectRedeemRequest(
    address _controller
  ) external {
    uint256 _shares = _takePending(_controller, false);
    _getGated7540Storage().pendingRedeemShares -= _shares;
    emit IGated7540Vault.RedeemRequestRejected(_controller, _shares);
    // A plain TRANSFER back to the controller: cap, pause, lockup and freeze all
    // apply, so a holder cannot route shares past the cap by naming a new controller. If the transfer is blocked,
    // this reverts and recoverRedeemRequest (FORCED, to a verified account) is the enforcement path.
    _transfer(address(this), _controller, _shares);
  }

  /**
   * @notice Recovers a controller's claimable balances, as `IGated7540Vault.recoverClaimable` specifies
   * @param _controller The controller
   * @param _to The verified recovery account
   */
  function recoverClaimable(
    address _controller,
    address _to
  ) external onlyRole(AGENT_ROLE) {
    if (_to == address(0)) revert IGated7540Vault.Gated7540Vault_ZeroAddress();
    // The recipient must pass the policy as the receiver of an enforcement move, even for the asset leg, which is not
    // hooked.
    bytes32 _reason = _enforcementProbe(_to);
    if (_reason != Reasons.TRANSFER_OK) revert IGated7540Vault.Gated7540Vault_RecipientNotEligible(_reason);

    Gated7540Storage storage $ = _getGated7540Storage();
    Request memory _deposit = _request(_controller, true);
    Request memory _redeem = _request(_controller, false);
    uint256 _shares = _deposit.owed;
    uint256 _assets = _redeem.owed;
    if (_shares == 0 && _assets == 0 && _deposit.paid == 0 && _redeem.paid == 0) {
      revert IGated7540Vault.Gated7540Vault_NothingClaimable();
    }
    // Clear every claimable figure: a redemption's shares were burned at settlement, and a deposit's assets already
    // went to the cash account then, so only `_assets` (held here) and `_shares` (not yet minted) remain.
    _deposit.paid = _deposit.owed = _redeem.paid = _redeem.owed = 0;
    _store(_controller, true, _deposit);
    _store(_controller, false, _redeem);
    // The mint raises `totalSupply()`, so these shares would otherwise count twice in the next price.
    $.unclaimedShares -= _shares;
    $.claimableCash -= _assets;
    emit IGated7540Vault.ClaimableRecovered(_controller, _to, _assets, _shares, _msgSender());
    if (_shares != 0) _mintAs(_to, _shares, IERC8473Policy.TransferKind.FORCED);
    if (_assets != 0) $.asset.safeTransfer(_to, _assets);
  }

  /**
   * @notice Recovers a controller's whole pending redemption, as `IGated7540Vault.recoverRedeemRequest` specifies
   * @param _controller The controller
   * @param _to The verified recovery account
   */
  function recoverRedeemRequest(
    address _controller,
    address _to
  ) external {
    if (_to == address(0)) revert IGated7540Vault.Gated7540Vault_ZeroAddress();
    uint256 _shares = _takePending(_controller, false);
    _getGated7540Storage().pendingRedeemShares -= _shares;
    emit IGated7540Vault.RedeemRequestRecovered(_controller, _to, _shares, _msgSender());
    // Internal FORCED move: an enforcement action; identity still applies to the recovery account.
    _moveAs(address(this), _to, _shares, IERC8473Policy.TransferKind.FORCED, bytes32(0), 0);
  }

  /**
   * @inheritdoc ITemplated
   * @dev Not the vault's, so a proxy cannot be moved onto this contract even if it were attested by mistake
   */
  function templateId() public pure override returns (bytes32 _id) {
    _id = keccak256('Gated7540Settlement');
  }

  /**
   * @notice Strikes the closed period's price and books it
   * @param _nav The net asset value the period deals at
   * @param _fee The fee, for the event
   * @param _redeemLimit The most shares to take from the period's redemptions
   * @return _s What was struck
   */
  function _strike(
    uint256 _nav,
    uint256 _fee,
    uint256 _redeemLimit
  ) private returns (Settlement memory _s) {
    Gated7540Storage storage $ = _getGated7540Storage();
    uint64 _period = $.settledPeriod + 1;
    if (_period == $.openPeriod) revert IGated7540Vault.Gated7540Vault_NoClosedPeriod();

    // A mapping's key, which Slither reads as a misused constant.
    // slither-disable-start boolean-cst
    _s.deposits = $.books[_period][true].paid;
    _s.redemptions = $.books[_period][false].paid;
    _s.redeemed = Math.min(_s.redemptions, _redeemLimit);
    _s.supply = totalSupply() + $.unclaimedShares;
    _s.shares = Math.mulDiv(_s.deposits, _s.supply + _VIRTUAL_SHARES, _nav + 1);
    _s.assets = Math.mulDiv(_s.redeemed, _nav + 1, _s.supply + _VIRTUAL_SHARES);

    // The casts refuse a period whose claims could not be booked later, so no controller's claim can ever overflow alone.
    $.books[_period][true].owed = _s.shares.toUint128();
    $.books[_period][false].owed = _s.assets.toUint128();
    if (_s.redeemed != _s.redemptions) {
      uint128 _carried = (_s.redemptions - _s.redeemed).toUint128();
      $.books[_period][false].carried = _carried;
      // At most one period is closed, so the next one is the open one. The shares stay in the escrow and in the supply.
      $.books[_period + 1][false].paid += _carried;
    }
    // slither-disable-end boolean-cst
    $.settledPeriod = _period;
    $.lastNav = _nav.toUint128();
    $.lastSupply = _s.supply.toUint128();
    $.unclaimedShares += _s.shares;
    $.pendingDeposits -= _s.deposits;
    $.pendingRedeemShares -= _s.redeemed;
    $.claimableCash += _s.assets;
    emit IGated7540Vault.PeriodSettled(
      _period, _nav, _s.supply, _s.deposits, _s.shares, _s.redemptions, _s.redeemed, _s.assets, _fee
    );
  }

  /**
   * @notice Moves only the difference between deposits and what must be paid, pays the fee, and audits the balance
   * @param _deposits The assets of the period's deposit requests
   * @param _assets The assets its redemptions pay
   * @param _fee The fee
   * @param _cash The account that receives net inflow and funds net outflow
   * @param _feeRecipient The account that receives the fee
   */
  function _net(
    uint256 _deposits,
    uint256 _assets,
    uint256 _fee,
    address _cash,
    address _feeRecipient
  ) private {
    Gated7540Storage storage $ = _getGated7540Storage();
    IERC20 _token = $.asset;
    uint256 _out = _assets + _fee;
    if (_deposits > _out) {
      _token.safeTransfer(_cash, _deposits - _out);
    } else if (_out > _deposits) {
      // The settler names the account, and only one that approved the vault can be pulled from.
      // slither-disable-next-line arbitrary-send-erc20
      _token.safeTransferFrom(_cash, address(this), _out - _deposits); // aderyn-ignore(arbitrary-transfer-from)
    }
    if (_fee != 0) _token.safeTransfer(_feeRecipient, _fee);

    uint256 _owed = $.pendingDeposits + $.claimableCash;
    uint256 _held = _token.balanceOf(address(this));
    if (_held < _owed) revert IGated7540Vault.Gated7540Vault_BalanceAudit(_held, _owed);
  }

  /**
   * @notice Takes a controller's whole pending request off its period. The agent may while the period is open, and only
   *         the settler once it has closed, so a request cannot leave a period that is being priced
   * @param _controller The controller
   * @param _isDeposit True on the deposit side
   * @return _pending What was pending
   */
  function _takePending(
    address _controller,
    bool _isDeposit
  ) private returns (uint256 _pending) {
    Gated7540Storage storage $ = _getGated7540Storage();
    Request memory _r = _request(_controller, _isDeposit);
    _pending = _r.pending;
    if (_pending == 0) revert IGated7540Vault.Gated7540Vault_NothingPending();
    _checkRole(_r.period == $.openPeriod ? AGENT_ROLE : _SETTLER_ROLE);
    $.books[_r.period][_isDeposit].paid -= _r.pending;
    _r.pending = 0;
    _r.period = 0;
    _store(_controller, _isDeposit, _r);
  }
}
