// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title ISignedExit
 * @notice Lets a holder leave a vault with signatures alone, while a relayer submits them, and lets anyone deliver
 *         what a 7540 vault owes a controller that allowed it
 * @dev The mirror of `ISignedEntry`. The holder signs an `Exit` on this contract's EIP-712 domain, naming where the
 *      cash goes and the least it accepts, and signs the share token's own `permit` for the shares. On a 4626 the exit
 *      redeems to the signed receiver. On a 7540 it files a redemption request with the holder as controller. Whoever
 *      submits can change nothing the holder signed. The contract is immutable, has no roles and holds neither shares
 *      nor cash between calls. `claimFor` is the one thing it does without a signature: for a controller that made
 *      this contract its operator on a 7540 vault, it claims what the vault owes that controller, to that controller
 *      and to nobody else
 */
interface ISignedExit {
  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice What a holder signs
   * @param holder Who owns the shares, and who controls the request on a 7540
   * @param vault The vault
   * @param shares The shares to redeem
   * @param receiver Where the cash goes on a 4626; the holder itself on a 7540, where the cash comes at the claim
   * @param minAssets The least it accepts on a 4626; zero on a 7540, where a request has no price yet
   * @param asynchronous True for a 7540, where this files a request; false for a 4626, where this redeems. False on a
   *        7540 reaches that vault's three-argument `redeem`, which is a claim: it pays settled redemption cash to the
   *        receiver, for a holder that made this contract its operator
   * @param nonce A nonce the holder chooses, single use
   * @param validAfter The first moment it is valid, inclusive; zero for no lower bound
   * @param deadline The last moment it is valid, inclusive
   */
  struct Exit {
    address holder;
    address vault;
    uint256 shares;
    address receiver;
    uint256 minAssets;
    bool asynchronous;
    bytes32 nonce;
    uint256 validAfter;
    uint256 deadline;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a holder cancels an exit
   * @param _holder The holder
   * @param _nonce The nonce
   */
  event ExitCancelled(address indexed _holder, bytes32 indexed _nonce);

  /**
   * @notice Emitted when an exit executes
   * @param _exitHash The hash the holder signed
   * @param _holder The holder
   * @param _vault The vault
   * @param _shares The shares redeemed, or put into a request
   * @param _assets The assets paid to the receiver; zero for a request
   */
  event ExitExecuted(
    bytes32 indexed _exitHash, address indexed _holder, address indexed _vault, uint256 _shares, uint256 _assets
  );

  /**
   * @notice Emitted when `claimFor` delivers a controller's claim
   * @param _vault The vault
   * @param _controller The controller, who received it
   * @param _isDeposit True for the shares of a settled deposit, false for the cash of a settled redemption
   * @param _amount The shares or the assets delivered
   */
  event ClaimDelivered(address indexed _vault, address indexed _controller, bool _isDeposit, uint256 _amount);

  /**
   * @notice Emitted when `claimFor` passes over a controller's claim because the vault refused it. The claim stays
   *         with the vault
   * @param _vault The vault
   * @param _controller The controller
   * @param _isDeposit True for the shares of a settled deposit, false for the cash of a settled redemption
   * @param _reason What the vault reverted with
   */
  event ClaimSkipped(address indexed _vault, address indexed _controller, bool _isDeposit, bytes _reason);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when the holder's signature does not verify
  error SignedExit_BadSignature();

  /// @notice Thrown after the deadline
  error SignedExit_Expired();

  /// @notice Thrown when a request names a minimum: a 7540 request has no price yet
  error SignedExit_MinimumOnARequest();

  /// @notice Thrown when the nonce was used or cancelled
  error SignedExit_NonceUsed();

  /// @notice Thrown before `validAfter`
  error SignedExit_NotYetValid();

  /// @notice Thrown when a request names a receiver other than the holder: a request pays nobody
  error SignedExit_ReceiverOnARequest();

  /**
   * @notice Thrown when a redemption pays less than the holder accepts
   * @param _minAssets The least it accepts
   * @param _assets What the vault would pay
   */
  error SignedExit_TooFewAssets(uint256 _minAssets, uint256 _assets);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Cancels an exit the caller signed
   * @param _nonce The nonce
   */
  function cancelExit(
    bytes32 _nonce
  ) external;

  /**
   * @notice Delivers what a 7540 vault owes each controller, to that controller
   * @dev Anyone. For each controller, the shares of a settled deposit and the cash of a settled redemption are
   *      claimed in full, with the controller as receiver. The vault lets this contract do that only for a
   *      controller that made it an operator. A claim the vault refuses, for a controller that gave no such leave or
   *      one the policy does not let receive now, is passed over with `ClaimSkipped` and stays with the vault; the
   *      other controllers are still served. This function can file no request and name no other receiver
   * @param _vault The 7540 vault
   * @param _controllers The controllers
   * @return _delivered How many claims were delivered
   */
  function claimFor(
    address _vault,
    address[] calldata _controllers
  ) external returns (uint256 _delivered);

  /**
   * @notice Executes an exit, with the holder's `permit` on the share token for the shares
   * @dev Anyone. A permit that fails is ignored, because anyone can submit a signed permit first: only the allowance
   *      matters. On a 4626 it redeems the shares to the signed receiver and reverts below `minAssets`. On a 7540 it
   *      files a redemption request with the holder as controller
   * @param _exit The exit
   * @param _exitSig The holder's signature over `exitHash(_exit)`
   * @param _v The permit's v
   * @param _r The permit's r
   * @param _s The permit's s
   * @return _assets The assets paid; zero for a request
   */
  function exitWithPermit(
    Exit calldata _exit,
    bytes calldata _exitSig,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external returns (uint256 _assets);

  /**
   * @notice The EIP-712 hash a holder signs
   * @param _exit The exit
   * @return _hash The hash
   */
  function exitHash(
    Exit calldata _exit
  ) external view returns (bytes32 _hash);

  /**
   * @notice Whether a holder's nonce was used or cancelled
   * @param _holder The holder
   * @param _nonce The nonce
   * @return _used True if used
   */
  function nonceUsed(
    address _holder,
    bytes32 _nonce
  ) external view returns (bool _used);
}
