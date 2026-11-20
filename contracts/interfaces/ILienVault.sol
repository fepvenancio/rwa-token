// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title ILienVault
 * @notice Holds tokens a holder has pledged, each amount under a lien that names a beneficiary, who alone decides
 *         whether they go back to the holder or to itself
 * @dev An escrow. The contract is immutable, has no role table and holds no role on any token. On each token it is an
 *      ordinary holder: it needs whatever that token's policy asks of a holder, and every movement in and out is a
 *      plain transfer that the token's policy judges. Nothing here is forced. A default is a fact off-chain that the
 *      contract cannot judge, so a beneficiary may take what its lien holds at any time, and a pledgor trusts it with
 *      that amount and no more. The contract is the holder of record of every pledged token: whoever builds a
 *      distribution's list, or counts a fund's investors, reads the liens to find the owners. ERC-20 tokens only, and
 *      only tokens that deliver exactly the amount sent
 */
interface ILienVault {
  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice One lien
   * @param token The token pledged
   * @param pledgor Who pledged it, and who a release pays
   * @param beneficiary Who may release it, take it or hand the lien on
   * @param amount What the lien holds now
   */
  struct Lien {
    address token;
    address pledgor;
    address beneficiary;
    uint256 amount;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a holder opens a lien
   * @param _lienId The lien
   * @param _token The token
   * @param _pledgor The holder
   * @param _beneficiary The beneficiary
   * @param _amount The amount pledged
   */
  event LienOpened(
    uint256 indexed _lienId, address indexed _token, address indexed _pledgor, address _beneficiary, uint256 _amount
  );

  /**
   * @notice Emitted when a pledgor adds to its lien
   * @param _lienId The lien
   * @param _amount The amount added
   */
  event LienIncreased(uint256 indexed _lienId, uint256 _amount);

  /**
   * @notice Emitted when a beneficiary sends pledged tokens back to the pledgor
   * @param _lienId The lien
   * @param _amount The amount released
   */
  event LienReleased(uint256 indexed _lienId, uint256 _amount);

  /**
   * @notice Emitted when a beneficiary takes pledged tokens
   * @param _lienId The lien
   * @param _beneficiary The beneficiary, which received them
   * @param _amount The amount taken
   */
  event LienSeized(uint256 indexed _lienId, address indexed _beneficiary, uint256 _amount);

  /**
   * @notice Emitted when a beneficiary hands its lien to another account
   * @param _lienId The lien
   * @param _previousBeneficiary The beneficiary until now
   * @param _newBeneficiary The beneficiary from now on
   */
  event LienAssigned(uint256 indexed _lienId, address indexed _previousBeneficiary, address indexed _newBeneficiary);

  /**
   * @notice Emitted when a token's agent moves what a lien holds to a recovery account
   * @param _lienId The lien, closed by this
   * @param _to Where the tokens went
   * @param _amount The amount
   * @param _agent The agent
   */
  event LienRecovered(uint256 indexed _lienId, address indexed _to, uint256 _amount, address indexed _agent);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown for a zero address, a zero amount, or this contract named as a beneficiary or a receiver
  error LienVault_InvalidValue();

  /**
   * @notice Thrown when a lien does not exist, or holds nothing any more
   * @param _lienId The lien
   */
  error LienVault_NoLien(uint256 _lienId);

  /**
   * @notice Thrown when the caller is not the account the function is for
   * @param _caller The caller
   */
  error LienVault_Unauthorized(address _caller);

  /**
   * @notice Thrown when an amount is more than the lien holds
   * @param _lienId The lien
   * @param _amount The amount asked for
   * @param _held What the lien holds
   */
  error LienVault_ExceedsLien(uint256 _lienId, uint256 _amount, uint256 _held);

  /**
   * @notice Thrown when a pledge did not raise this contract's balance by exactly the amount pledged
   * @param _expected The amount pledged
   * @param _received What arrived
   */
  error LienVault_WrongAmountReceived(uint256 _expected, uint256 _received);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Pledges the caller's tokens to a beneficiary, under a new lien
   * @dev Pulls `_amount` under the caller's allowance, a plain transfer the token's policy judges, so a holder inside
   *      a lockup cannot pledge. Reverts unless this contract's balance rose by exactly `_amount`
   * @param _token The token
   * @param _amount The amount, not zero
   * @param _beneficiary Who decides over it, not zero and not this contract
   * @return _lienId The new lien; the first is 1
   */
  function pledge(
    address _token,
    uint256 _amount,
    address _beneficiary
  ) external returns (uint256 _lienId);

  /**
   * @notice Adds to a lien. Only its pledgor
   * @param _lienId The lien
   * @param _amount The amount to add, not zero
   */
  function increase(
    uint256 _lienId,
    uint256 _amount
  ) external;

  /**
   * @notice Sends pledged tokens back to the pledgor. Only the lien's beneficiary
   * @dev A plain transfer: it reverts while the token is paused or its policy refuses the pledgor as a receiver, and
   *      the tokens stay under the lien. A lien that holds nothing afterwards is closed
   * @param _lienId The lien
   * @param _amount The amount, not zero and not above what the lien holds
   */
  function release(
    uint256 _lienId,
    uint256 _amount
  ) external;

  /**
   * @notice Takes pledged tokens. Only the lien's beneficiary, at any time
   * @dev A plain transfer to the beneficiary: it reverts while the token is paused or its policy refuses the
   *      beneficiary as a receiver. Such a beneficiary can `assign` the lien to an account the policy admits. A lien
   *      that holds nothing afterwards is closed
   * @param _lienId The lien
   * @param _amount The amount, not zero and not above what the lien holds
   */
  function seize(
    uint256 _lienId,
    uint256 _amount
  ) external;

  /**
   * @notice Hands a lien to another beneficiary. Only the lien's beneficiary
   * @param _lienId The lien
   * @param _newBeneficiary The beneficiary from now on, not zero and not this contract
   */
  function assign(
    uint256 _lienId,
    address _newBeneficiary
  ) external;

  /**
   * @notice Moves everything a lien holds to a recovery account and closes it. Only an account that holds the
   *         token's `AGENT_ROLE`, asked of the token at call time
   * @dev The enforcement path for one pledgor's tokens, since the token's own forced transfer out of this contract
   *      cannot name a pledgor. This contract holds no role on the token, so the movement is a plain transfer, not a
   *      forced one: it needs the token unpaused and `_to` admitted by its policy. Neither the pledgor nor the
   *      beneficiary is a party to that transfer, so it works when either is frozen or blocked. On a token that has
   *      no such role the call reverts
   * @param _lienId The lien
   * @param _to Where the tokens go, not zero and not this contract
   */
  function recover(
    uint256 _lienId,
    address _to
  ) external;

  /*///////////////////////////////////////////////////////////////
                            VIEWS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The role on a token whose holders may `recover`
   * @return _role `keccak256('AGENT_ROLE')`
   */
  // getter of an UPPER_SNAKE constant
  // solhint-disable-next-line style-guide-casing
  function AGENT_ROLE() external view returns (bytes32 _role);

  /**
   * @notice How many liens were ever opened; their ids run from 1 to this
   * @return _count The count
   */
  function lienCount() external view returns (uint256 _count);

  /**
   * @notice A lien
   * @param _lienId The lien
   * @return _lien It; all zero for one that never existed or is closed
   */
  function lienOf(
    uint256 _lienId
  ) external view returns (Lien memory _lien);

  /**
   * @notice What one holder has pledged of a token, over all its liens
   * @param _token The token
   * @param _pledgor The holder
   * @return _amount The amount
   */
  function pledgedOf(
    address _token,
    address _pledgor
  ) external view returns (uint256 _amount);

  /**
   * @notice What all liens on a token hold together. This contract's balance of the token is at least this
   * @param _token The token
   * @return _amount The amount
   */
  function totalPledged(
    address _token
  ) external view returns (uint256 _amount);
}
