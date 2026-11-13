// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IFeeModel} from 'interfaces/IFeeModel.sol';
import {IGated4626Vault} from 'interfaces/IGated4626Vault.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {IPortfolio} from 'interfaces/IPortfolio.sol';
// Needed by the compiler to resolve `@inheritdoc ITemplated`; solhint does not see NatSpec usage.
// solhint-disable-next-line no-unused-vars
import {ITemplated} from 'interfaces/ITemplated.sol';

import {Gated4626Common} from 'contracts/vaults/Gated4626Common.sol';

/**
 * @title Gated4626Management
 * @notice The management functions of `Gated4626Vault`, as specified in `IGated4626Vault`: plugging a portfolio, the
 *         rate limit, the fee model and paying fees. The vault's named functions hand these calls here by delegatecall,
 *         so they run on the vault's storage, with its caller
 * @dev Created by the vault implementation's constructor, so the implementation's attested codehash pins its address. It
 *      inherits the base for its internals. The vault forwards only these four selectors, so the base's external
 *      functions in this contract cannot be reached from a proxy. Reached directly it has its own empty storage: nobody
 *      holds a role on it, nobody can be granted one, it has no initializer that could change that, it has no asset and
 *      no policy, and it holds no money
 * @custom:oz-upgrades-unsafe-allow missing-initializer
 */
// No receive or payable function, so no ETH can enter.
// aderyn-ignore-next-line(contract-locks-ether)
contract Gated4626Management is Gated4626Common {
  using SafeERC20 for IERC20;

  /// @notice The ceiling on the limit, so the arithmetic cannot overflow. It leaves the timelock room to raise the limit
  uint256 private constant _MAX_RATE_BPS = 1e9;

  /**
   * @notice Plugs a portfolio, or replaces one, as `IGated4626Vault.setPortfolio` specifies
   * @param _portfolio The portfolio
   * @param _maxRateBps The most the counted value may rise in a year, in basis points
   */
  function setPortfolio(
    address _portfolio,
    uint256 _maxRateBps
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_maxRateBps == 0) revert IGated4626Vault.Gated4626Vault_ZeroRate();
    if (_maxRateBps > _MAX_RATE_BPS) revert IGated4626Vault.Gated4626Vault_RateTooHigh(_maxRateBps);
    // View interfaces, compiled to STATICCALL: nothing re-enters before the writes below.
    // aderyn-ignore-next-line(reentrancy-state-change)
    _requireAttested(_portfolio, IPolicyRegistry.AttestKind.PORTFOLIO);
    IPortfolio _next = IPortfolio(_portfolio);
    // aderyn-ignore-next-line(reentrancy-state-change)
    IERC20 _asset = IERC20(asset());
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (_next.VAULT() != address(this) || _next.ASSET() != _asset || _next.ACCEPTS_REPORTED()) {
      revert IGated4626Vault.Gated4626Vault_PortfolioRefused(_portfolio);
    }

    Gated4626Storage storage $ = _getGated4626Storage();
    address _old = $.portfolio;
    if (_old == address(0)) {
      $.lastAt = uint64(block.timestamp);
    } else {
      // An adapter on the list can hold a position that cannot be read now, which `pricedValue()` counts as nothing.
      // A replacement keeps the limit's clock, so the next count allows what it would have allowed anyway.
      // View interfaces, compiled to STATICCALL, and the portfolio is attested: nothing re-enters before these writes.
      // aderyn-ignore-next-line(reentrancy-state-change)
      if (_hasAdapters(_old) || _pricedValue(IPortfolio(_old)) != 0) {
        revert IGated4626Vault.Gated4626Vault_PortfolioNotEmpty();
      }
      // aderyn-ignore-next-line(reentrancy-state-change)
      if (_writtenOff(IPortfolio(_old))) $.exitOnly = true;
    }
    // OpenZeppelin's own count is the asset balance the vault itself holds, which is what is forwarded.
    // aderyn-ignore-next-line(reentrancy-state-change)
    uint256 _held = super.totalAssets();
    $.portfolio = _portfolio;
    $.maxRateBps = _maxRateBps;
    $.last += _held;
    emit IGated4626Vault.PortfolioSet(_portfolio);
    emit IGated4626Vault.MaxRateSet(_maxRateBps);
    if (_held != 0) _asset.safeTransfer(_portfolio, _held);
  }

  /**
   * @notice Sets the limit on how fast the counted value may rise, as `IGated4626Vault.setMaxRate` specifies
   * @param _maxRateBps The new limit, in basis points a year
   */
  function setMaxRate(
    uint256 _maxRateBps
  ) external {
    Gated4626Storage storage $ = _getGated4626Storage();
    if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
      if (!hasRole(GUARDIAN_ROLE, _msgSender()) || _maxRateBps > $.maxRateBps) {
        revert IGated4626Vault.Gated4626Vault_Unauthorized(_msgSender());
      }
    }
    if (_maxRateBps > _MAX_RATE_BPS) revert IGated4626Vault.Gated4626Vault_RateTooHigh(_maxRateBps);
    // The old rate decides what has counted so far.
    _accrue();
    $.maxRateBps = _maxRateBps;
    emit IGated4626Vault.MaxRateSet(_maxRateBps);
  }

  /**
   * @notice Plugs a fee model, or replaces one, as `IGated4626Vault.setFeeModel` specifies
   * @param _feeModel The fee model, which must be attested: the vault has no way to go back to none
   */
  function setFeeModel(
    address _feeModel
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    Gated4626Storage storage $ = _getGated4626Storage();
    if ($.portfolio == address(0)) revert IGated4626Vault.Gated4626Vault_NoPortfolio();
    // A view interface, compiled to STATICCALL: nothing re-enters before the writes below.
    // aderyn-ignore-next-line(reentrancy-state-change)
    _requireAttested(_feeModel, IPolicyRegistry.AttestKind.FEE_MODEL);
    _accrue();
    if ($.feeModel == address(0)) {
      if ($.mark == 0) {
        // From what was counted, not from `totalAssets()`, which during a read of nothing would start the mark at nothing.
        $.mark = Math.max(Math.mulDiv(_PRICE_SCALE, $.last + 1, totalSupply() + _VIRTUAL_SHARES), _PAR_MARK);
        $.markMovedAt = uint64(block.timestamp);
      }
      $.lastFeeAt = uint64(block.timestamp);
    }
    $.feeModel = _feeModel;
    emit IGated4626Vault.FeeModelSet(_feeModel);
  }

  /// @notice Pays the fees owed to the fee model's recipient, as `IGated4626Vault.collectFees` specifies
  function collectFees() external whenNotPaused {
    Gated4626Storage storage $ = _getGated4626Storage();
    address _feeModel = $.feeModel;
    if (_feeModel == address(0)) revert IGated4626Vault.Gated4626Vault_NoFeeModel();
    _accrue();
    address _portfolio = $.portfolio;
    IERC20 _asset = IERC20(asset());
    // View interfaces, compiled to STATICCALL: nothing re-enters before the write below.
    // aderyn-ignore-next-line(reentrancy-state-change)
    uint256 _assets = Math.min($.feesOwed, _asset.balanceOf(_portfolio));
    // aderyn-ignore-next-line(reentrancy-state-change)
    address _recipient = IFeeModel(_feeModel).RECIPIENT();
    $.feesOwed -= _assets;
    emit IGated4626Vault.FeesCollected(_recipient, _assets);
    // The portfolio gave this vault an allowance at construction; the recipient is the one the attested model names.
    // slither-disable-next-line arbitrary-send-erc20
    _asset.safeTransferFrom(_portfolio, _recipient, _assets); // aderyn-ignore(arbitrary-transfer-from)
  }

  /**
   * @inheritdoc ITemplated
   * @dev Not the vault's, so a proxy cannot be moved onto this contract even if it were attested by mistake
   */
  function templateId() public pure override returns (bytes32 _id) {
    _id = keccak256('Gated4626Management');
  }

  /**
   * @notice Whether a portfolio still lists an adapter
   * @dev `adapters()` answers with an array, encoded as its offset and then its length. Only those two words are
   *      copied and the list itself is never decoded, which a call through the interface would do. A failed call or an
   *      answer too short to hold a length reverts. The second word is taken as the length, which is the standard
   *      encoding of a lone array and what any Solidity portfolio answers; the portfolio asked is one this vault had
   *      plugged, so its code was attested
   * @param _portfolio The portfolio
   * @return _has True when its list is not empty
   */
  function _hasAdapters(
    address _portfolio
  ) private view returns (bool _has) {
    bytes4 _selector = IPortfolio.adapters.selector;
    assembly ('memory-safe') {
      mstore(0x00, _selector)
      let _success := staticcall(gas(), _portfolio, 0x00, 0x04, 0x00, 0x40)
      if or(iszero(_success), lt(returndatasize(), 0x40)) { revert(0x00, 0x00) }
      _has := iszero(iszero(mload(0x20)))
    }
  }

  /**
   * @notice Reverts unless a lego's code is attested as the given kind in the vault's registry
   * @param _target The lego
   * @param _kind The kind it must be attested as
   */
  function _requireAttested(
    address _target,
    IPolicyRegistry.AttestKind _kind
  ) private view {
    if (!IPolicyRegistry(registry()).isAttested(_target, _kind)) {
      revert IGated4626Vault.Gated4626Vault_NotAttested(_target);
    }
  }
}
