// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {IAdapter} from 'interfaces/IAdapter.sol';
import {IERC4626Adapter} from 'interfaces/IERC4626Adapter.sol';

/**
 * @title ERC4626Adapter
 * @notice Holds a `Portfolio`'s position in one ERC-4626 vault as an ordinary depositor, as specified in `IERC4626Adapter`
 * @dev Immutable, attested as ADAPTER. Every setting is an immutable, so the attested codehash covers the portfolio, the
 *      target and the risk ids. It covers the target's address and not its behaviour, so the council reads the target
 *      before it attests. A target that cannot be read gives a value of zero with `fresh()` false, never a revert
 */
contract ERC4626Adapter is IERC4626Adapter {
  using SafeERC20 for IERC20;

  /// @inheritdoc IAdapter
  address public immutable PORTFOLIO;

  /// @inheritdoc IERC4626Adapter
  IERC4626 public immutable TARGET;

  /// @inheritdoc IERC4626Adapter
  bytes32 public immutable RISK_ID;

  /// @inheritdoc IERC4626Adapter
  bytes32 public immutable SHARED_RISK_ID;

  /// @notice The target's asset
  IERC20 internal immutable _ASSET;

  /**
   * @notice Deploys the adapter
   * @param _portfolio The portfolio it serves
   * @param _target The vault it deposits into
   * @param _sharedRiskId A risk id shared with other adapters, or zero for none
   */
  constructor(
    address _portfolio,
    IERC4626 _target,
    bytes32 _sharedRiskId
  ) {
    if (_portfolio == address(0) || address(_target) == address(0)) revert ERC4626Adapter_ZeroAddress();
    PORTFOLIO = _portfolio;
    TARGET = _target;
    SHARED_RISK_ID = _sharedRiskId;
    RISK_ID = keccak256(abi.encode('ERC4626Adapter', address(_target)));
    _ASSET = IERC20(_target.asset());
  }

  /// @inheritdoc IAdapter
  function allocate(
    uint256 _assets
  ) external {
    if (msg.sender != PORTFOLIO) revert ERC4626Adapter_OnlyPortfolio(msg.sender);
    _ASSET.forceApprove(address(TARGET), _assets);
    // The shares are this adapter's position, which `value` reads; what the deposit returned is not needed.
    // slither-disable-next-line unused-return
    TARGET.deposit(_assets, address(this)); // aderyn-ignore(unchecked-return)
  }

  /// @inheritdoc IAdapter
  function deallocate(
    uint256 _assets
  ) external {
    if (msg.sender != PORTFOLIO) revert ERC4626Adapter_OnlyPortfolio(msg.sender);
    // The portfolio measures what arrived; the shares burned are not needed.
    // slither-disable-next-line unused-return
    TARGET.withdraw(_assets, PORTFOLIO, address(this)); // aderyn-ignore(unchecked-return)
  }

  /// @inheritdoc IAdapter
  function value() external view returns (uint256 _value) {
    (, _value) = _read();
  }

  /// @inheritdoc IAdapter
  function fresh() public view virtual returns (bool _fresh) {
    (_fresh,) = _read();
  }

  /// @inheritdoc IAdapter
  function liquid() external view returns (uint256 _liquid) {
    (, _liquid) = _ask(address(TARGET), abi.encodeCall(IERC4626.maxWithdraw, (address(this))));
  }

  /// @inheritdoc IAdapter
  function riskIds() external view returns (bytes32[] memory _ids) {
    bool _shared = SHARED_RISK_ID != bytes32(0);
    _ids = new bytes32[](_shared ? 2 : 1);
    _ids[0] = RISK_ID;
    if (_shared) _ids[1] = SHARED_RISK_ID;
  }

  /// @inheritdoc IAdapter
  function asset() external view returns (address _asset) {
    _asset = address(_ASSET);
  }

  /// @inheritdoc IAdapter
  function reported() external pure returns (bool _reported) {
    _reported = false;
  }

  /**
   * @notice Reads the position, treating a failed read as no answer rather than as a loss
   * @return _ok True if both reads succeeded
   * @return _value The position's value in assets, zero when `_ok` is false
   */
  function _read() private view returns (bool _ok, uint256 _value) {
    uint256 _shares;
    (_ok, _shares) = _ask(address(TARGET), abi.encodeCall(IERC20.balanceOf, (address(this))));
    if (_ok) (_ok, _value) = _ask(address(TARGET), abi.encodeCall(IERC4626.previewRedeem, (_shares)));
  }

  /**
   * @notice Asks a contract for one number, treating any failure as no answer
   * @dev Low level, because a `try` does not catch a contract with no code or one that returns too little: the decoding
   *      reverts here. It reads the first word and copies nothing else
   * @param _to The contract asked: the target, or one the target names
   * @param _call The call
   * @return _ok True if it answered with at least one word
   * @return _answer The answer, zero when `_ok` is false
   */
  function _ask(
    address _to,
    bytes memory _call
  ) internal view returns (bool _ok, uint256 _answer) {
    // Only the first word of the answer is copied, into the scratch space, so a target cannot make the read costly
    // with a long answer.
    assembly ('memory-safe') {
      let _success := staticcall(gas(), _to, add(_call, 0x20), mload(_call), 0x00, 0x20)
      _ok := and(_success, gt(returndatasize(), 0x1f))
      if _ok { _answer := mload(0x00) }
    }
  }
}
