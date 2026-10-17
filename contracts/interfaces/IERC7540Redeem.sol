// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IERC7540Redeem
 * @notice ERC-7540 asynchronous redemption (ERC-165 id 0x620ee8e4). Claims use the ERC-4626 `withdraw` / `redeem`
 *         signatures, with the `owner` argument acting as the controller
 */
interface IERC7540Redeem {
  /**
   * @notice Emitted when shares are requested for redemption
   * @param _controller The controller of the request
   * @param _owner The owner of the shares
   * @param _requestId The request id (always 0: requests aggregate per controller)
   * @param _sender The caller
   * @param _shares The shares requested
   */
  event RedeemRequest(
    address indexed _controller, address indexed _owner, uint256 indexed _requestId, address _sender, uint256 _shares
  );

  /**
   * @notice Requests an asynchronous redemption, taking the shares out of the owner's custody
   * @param _shares The shares
   * @param _controller The controller of the request
   * @param _owner The owner of the shares; the caller, an operator of it, or a spender with allowance
   * @return _requestId The request id (0)
   */
  function requestRedeem(
    uint256 _shares,
    address _controller,
    address _owner
  ) external returns (uint256 _requestId);

  /**
   * @notice Shares requested and not yet fulfilled
   * @param _requestId The request id (ignored: requests aggregate per controller)
   * @param _controller The controller
   * @return _pendingShares The pending shares
   */
  function pendingRedeemRequest(
    uint256 _requestId,
    address _controller
  ) external view returns (uint256 _pendingShares);

  /**
   * @notice Shares fulfilled and not yet claimed
   * @param _requestId The request id (ignored: requests aggregate per controller)
   * @param _controller The controller
   * @return _claimableShares The claimable shares
   */
  function claimableRedeemRequest(
    uint256 _requestId,
    address _controller
  ) external view returns (uint256 _claimableShares);
}
