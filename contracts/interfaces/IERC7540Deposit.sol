// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IERC7540Deposit
 * @notice ERC-7540 asynchronous deposit (ERC-165 id 0xce3bbe50, which includes the controller overloads of
 *         `deposit` and `mint`)
 */
interface IERC7540Deposit {
  /**
   * @notice Emitted when assets are requested for deposit
   * @param _controller The controller of the request
   * @param _owner The owner of the assets
   * @param _requestId The request id (always 0: requests aggregate per controller)
   * @param _sender The caller
   * @param _assets The assets requested
   */
  event DepositRequest(
    address indexed _controller, address indexed _owner, uint256 indexed _requestId, address _sender, uint256 _assets
  );

  /**
   * @notice Requests an asynchronous deposit, taking custody of the assets
   * @param _assets The assets
   * @param _controller The controller of the request
   * @param _owner The owner of the assets; the caller or an operator of it
   * @return _requestId The request id (0)
   */
  function requestDeposit(
    uint256 _assets,
    address _controller,
    address _owner
  ) external returns (uint256 _requestId);

  /**
   * @notice Claims a fulfilled deposit by assets
   * @param _assets The assets to claim
   * @param _receiver The receiver of the shares
   * @param _controller The controller of the request
   * @return _shares The shares minted
   */
  function deposit(
    uint256 _assets,
    address _receiver,
    address _controller
  ) external returns (uint256 _shares);

  /**
   * @notice Claims a fulfilled deposit by shares
   * @param _shares The shares to claim
   * @param _receiver The receiver of the shares
   * @param _controller The controller of the request
   * @return _assets The assets consumed
   */
  function mint(
    uint256 _shares,
    address _receiver,
    address _controller
  ) external returns (uint256 _assets);

  /**
   * @notice Assets requested and not yet fulfilled
   * @param _requestId The request id (ignored: requests aggregate per controller)
   * @param _controller The controller
   * @return _pendingAssets The pending assets
   */
  function pendingDepositRequest(
    uint256 _requestId,
    address _controller
  ) external view returns (uint256 _pendingAssets);

  /**
   * @notice Assets fulfilled and not yet claimed
   * @param _requestId The request id (ignored: requests aggregate per controller)
   * @param _controller The controller
   * @return _claimableAssets The claimable assets
   */
  function claimableDepositRequest(
    uint256 _requestId,
    address _controller
  ) external view returns (uint256 _claimableAssets);
}
