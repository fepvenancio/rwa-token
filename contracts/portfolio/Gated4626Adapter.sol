// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';

import {IGated4626Vault} from 'interfaces/IGated4626Vault.sol';
import {IPortfolio} from 'interfaces/IPortfolio.sol';

import {ERC4626Adapter} from 'contracts/portfolio/ERC4626Adapter.sol';

/**
 * @title Gated4626Adapter
 * @notice An `ERC4626Adapter` whose target is a `Gated4626Vault`: a feeder class's position in its master fund. Its
 *         price is fresh only while the target itself deals, so a class stops dealing when its master does
 * @dev Immutable, attested as ADAPTER, as specified in `IERC4626Adapter`. A `Gated4626Vault` that stops dealing still
 *      answers `previewRedeem` with the price it holds, which the plain adapter reads as fresh. A class would then take
 *      deposits and pay its idle money at a price its master will not deal at. Here `fresh()` is also false while the
 *      target is paused, while its portfolio gives no fresh price, and while it reads nothing although its holders have a
 *      value counted. It is not false because the target is exit-only: that would stop the class's redemptions too, so
 *      whoever writes off an adapter on a master closes deposits on its classes. The third condition copies the vault's
 *      own rule, so an upgrade that changes when a `Gated4626Vault` stops dealing needs a new adapter
 */
contract Gated4626Adapter is ERC4626Adapter {
  /// @notice Fewer share units than this count as no shares, as in the vault: what one unit of the asset buys at par
  uint256 private constant _VIRTUAL_SHARES = 1e6;

  /**
   * @notice Deploys the adapter
   * @param _portfolio The portfolio it serves
   * @param _target The `Gated4626Vault` it deposits into
   * @param _sharedRiskId A risk id shared with other adapters, or zero for none
   */
  constructor(
    address _portfolio,
    IERC4626 _target,
    bytes32 _sharedRiskId
  ) ERC4626Adapter(_portfolio, _target, _sharedRiskId) {}

  /**
   * @inheritdoc ERC4626Adapter
   * @dev Also false while the target does not deal, or cannot say
   */
  function fresh() public view override returns (bool _fresh) {
    _fresh = super.fresh() && _targetDeals();
  }

  /**
   * @notice Whether the target would deal now, as far as its price goes
   * @dev The target's portfolio is asked for on every call and never stored: a target that replaces its portfolio leaves
   *      the old one giving no price for good. A read that fails is no answer, and no answer is "does not deal"
   * @return _deals False while the target is paused, its portfolio gives no fresh price, it reads nothing, or any of
   *         these cannot be read
   */
  function _targetDeals() private view returns (bool _deals) {
    address _target = address(TARGET);
    (bool _ok, uint256 _answer) = _ask(_target, abi.encodeCall(Pausable.paused, ()));
    if (!_ok || _answer != 0) return false;
    (_ok, _answer) = _ask(_target, abi.encodeCall(IGated4626Vault.portfolio, ()));
    if (!_ok) return false;
    // With no portfolio the vault prices from its own balance and never stops for a price.
    if (_answer == 0) return true;
    address _portfolio = address(uint160(_answer));
    (_ok, _answer) = _ask(_portfolio, abi.encodeCall(IPortfolio.priceFresh, ()));
    if (!_ok || _answer == 0) return false;

    (bool _okLast, uint256 _last) = _ask(_target, abi.encodeCall(IGated4626Vault.lastCounted, ()));
    (bool _okSupply, uint256 _supply) = _ask(_target, abi.encodeCall(IERC20.totalSupply, ()));
    (bool _okOwed, uint256 _owed) = _ask(_target, abi.encodeCall(IGated4626Vault.feesOwed, ()));
    (bool _okPriced, uint256 _priced) = _ask(_portfolio, abi.encodeCall(IPortfolio.pricedValue, ()));
    if (!_okLast || !_okSupply || !_okOwed || !_okPriced) return false;
    // The vault's own rule for a read of nothing, which it does not write down and does not deal through.
    _deals = !(_last != 0 && _supply >= _VIRTUAL_SHARES && _priced <= _owed);
  }
}
