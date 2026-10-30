// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title IPortfolio
 * @notice Where one vault's money may go. It holds the idle money, sends it only to installed adapters within caps, and
 *         tells the vault what the on-chain part is worth. One portfolio serves one vault, so there is no ledger between
 *         vaults to get wrong
 * @dev Not a proxy and it keeps no role table: every gate asks the vault at call time, so a revoked role stops working at
 *      once. The vault's DEFAULT_ADMIN_ROLE (the timelock) decides what is allowed, ALLOCATOR_ROLE moves money within that,
 *      and GUARDIAN_ROLE can only reduce risk: pull money back and lower caps
 */
interface IPortfolio {
  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice One risk, shared by every adapter that names its id
   * @param allocation The assets allocated under this id
   * @param absoluteCap The most assets allowed under this id; zero allows none
   * @param relativeCapBps The most allowed as a share of the vault's `totalAssets()`, in basis points; 10,000 is no limit
   */
  struct Risk {
    uint120 allocation;
    uint120 absoluteCap;
    uint16 relativeCapBps;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when an adapter is installed
   * @param _adapter The adapter
   */
  event AdapterAdded(address indexed _adapter);

  /**
   * @notice Emitted when an empty adapter is taken off the list
   * @param _adapter The adapter
   */
  event AdapterRemoved(address indexed _adapter);

  /**
   * @notice Emitted when an adapter is written off: taken off the list with whatever it holds
   * @param _adapter The adapter
   * @param _allocationCleared The allocation that no longer counts against its caps
   */
  event AdapterWrittenOff(address indexed _adapter, uint256 _allocationCleared);

  /**
   * @notice Emitted when money goes to an adapter
   * @param _adapter The adapter
   * @param _assets The assets sent
   * @param _allocated What was added to its allocation: the change in value for a priced adapter
   */
  event Allocated(address indexed _adapter, uint256 _assets, uint256 _allocated);

  /**
   * @notice Emitted when money comes back from an adapter
   * @param _adapter The adapter
   * @param _assets The assets returned
   * @param _deallocated What was taken off its allocation
   */
  event Deallocated(address indexed _adapter, uint256 _assets, uint256 _deallocated);

  /**
   * @notice Emitted when a risk's caps change
   * @param _id The risk id
   * @param _absoluteCap The new absolute cap
   * @param _relativeCapBps The new relative cap
   */
  event CapsSet(bytes32 indexed _id, uint256 _absoluteCap, uint256 _relativeCapBps);

  /**
   * @notice Emitted when the adapter that serves `raise` changes
   * @param _adapter The new liquidity adapter, or zero for none
   */
  event LiquidityAdapterSet(address indexed _adapter);

  /**
   * @notice Emitted when the idle money moves to a successor
   * @param _successor The new portfolio
   * @param _assets The assets moved
   */
  event Migrated(address indexed _successor, uint256 _assets);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when the caller holds none of the roles the function allows
   * @param _caller The caller
   */
  error Portfolio_Unauthorized(address _caller);

  /// @notice Thrown when a constructor argument is the zero address
  error Portfolio_ZeroAddress();

  /// @notice Thrown when moving nothing
  error Portfolio_ZeroAmount();

  /**
   * @notice Thrown when installing or migrating to code the vault's registry has not attested
   * @param _target The contract
   */
  error Portfolio_NotAttested(address _target);

  /**
   * @notice Thrown when an adapter serves another portfolio
   * @param _adapter The adapter
   */
  error Portfolio_WrongPortfolio(address _adapter);

  /**
   * @notice Thrown when an adapter or a successor uses another asset
   * @param _target The contract
   */
  error Portfolio_WrongAsset(address _target);

  /**
   * @notice Thrown when a successor serves another vault
   * @param _successor The successor
   */
  error Portfolio_WrongVault(address _successor);

  /**
   * @notice Thrown when a portfolio that takes no reported adapters is offered one
   * @param _adapter The adapter
   */
  error Portfolio_ReportedNotAccepted(address _adapter);

  /**
   * @notice Thrown when an adapter names no risk, which would put it outside every cap
   * @param _adapter The adapter
   */
  error Portfolio_NoRiskIds(address _adapter);

  /**
   * @notice Thrown when the adapter list is full
   * @param _max The most adapters allowed
   */
  error Portfolio_TooManyAdapters(uint256 _max);

  /**
   * @notice Thrown when installing an adapter twice
   * @param _adapter The adapter
   */
  error Portfolio_AdapterExists(address _adapter);

  /**
   * @notice Thrown when naming an adapter that is not installed
   * @param _adapter The adapter
   */
  error Portfolio_UnknownAdapter(address _adapter);

  /**
   * @notice Thrown when removing an adapter that holds money, or whose position cannot be read
   * @param _adapter The adapter
   */
  error Portfolio_NotEmpty(address _adapter);

  /**
   * @notice Thrown when writing off a priced adapter that can still be priced
   * @param _adapter The adapter
   */
  error Portfolio_StillPriced(address _adapter);

  /**
   * @notice Thrown when migrating with adapters still installed
   * @param _count How many are installed
   */
  error Portfolio_AdaptersInstalled(uint256 _count);

  /**
   * @notice Thrown when an allocation would pass a cap
   * @param _id The risk id
   * @param _allocation What the allocation would be
   * @param _limit The limit it passes
   */
  error Portfolio_CapExceeded(bytes32 _id, uint256 _allocation, uint256 _limit);

  /**
   * @notice Thrown when a relative cap is above 10,000 basis points
   * @param _relativeCapBps The relative cap
   */
  error Portfolio_InvalidCap(uint256 _relativeCapBps);

  /**
   * @notice Thrown when allocating to a priced adapter whose value cannot be read
   * @param _adapter The adapter
   */
  error Portfolio_StalePrice(address _adapter);

  /**
   * @notice Thrown when an adapter returns less than it was asked for
   * @param _adapter The adapter
   * @param _expected The assets asked for
   * @param _received The assets that arrived
   */
  error Portfolio_ShortReturn(address _adapter, uint256 _expected, uint256 _received);

  /// @notice Thrown when `raise` needs an adapter and none is set
  error Portfolio_NoLiquidityAdapter();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Installs an adapter
   * @dev The vault's DEFAULT_ADMIN_ROLE. The adapter must be attested as ADAPTER in the vault's registry, serve this
   *      portfolio and this asset, name at least one risk, and be priced unless this portfolio accepts reported adapters
   * @param _adapter The adapter
   */
  function addAdapter(
    address _adapter
  ) external;

  /**
   * @notice Takes an empty adapter off the list
   * @dev The vault's DEFAULT_ADMIN_ROLE. A priced adapter is empty when it can be read and is worth nothing. A reported
   *      adapter's money can be off-chain, so it is empty when its on-chain balance and its allocation are both zero
   * @param _adapter The adapter
   */
  function removeAdapter(
    address _adapter
  ) external;

  /**
   * @notice Takes an adapter off the list with whatever it holds, and clears its allocation
   * @dev The vault's DEFAULT_ADMIN_ROLE. A priced adapter qualifies only while it cannot be priced, and the value it stops
   *      contributing is a loss to the vault. A reported adapter qualifies at any time, and its value was always the report
   * @param _adapter The adapter
   */
  function writeOffAdapter(
    address _adapter
  ) external;

  /**
   * @notice Sets a risk's caps
   * @dev The vault's DEFAULT_ADMIN_ROLE sets any value. GUARDIAN_ROLE may only lower them, and neither number may rise
   * @param _id The risk id
   * @param _absoluteCap The most assets allowed under this id
   * @param _relativeCapBps The most allowed as a share of the vault's `totalAssets()`, in basis points; 10,000 is no limit
   */
  function setCaps(
    bytes32 _id,
    uint256 _absoluteCap,
    uint256 _relativeCapBps
  ) external;

  /**
   * @notice Sends idle money to an installed adapter, within the caps of every risk it names
   * @dev The vault's ALLOCATOR_ROLE. Caps are checked here only, so an exit can leave a risk above its relative cap
   * @param _adapter The adapter
   * @param _assets The assets to send
   */
  function allocate(
    address _adapter,
    uint256 _assets
  ) external;

  /**
   * @notice Brings money back from an installed adapter
   * @dev The vault's ALLOCATOR_ROLE or GUARDIAN_ROLE
   * @param _adapter The adapter
   * @param _assets The assets to return; the adapter must return at least this
   */
  function deallocate(
    address _adapter,
    uint256 _assets
  ) external;

  /**
   * @notice Chooses the adapter that `raise` draws on
   * @dev The vault's ALLOCATOR_ROLE
   * @param _adapter An installed adapter, or zero for none
   */
  function setLiquidityAdapter(
    address _adapter
  ) external;

  /**
   * @notice Makes sure the idle money covers an amount, drawing the shortfall from the liquidity adapter
   * @dev Only the vault, which then pulls the money through the allowance given at construction
   * @param _assets The assets the vault needs
   */
  function raise(
    uint256 _assets
  ) external;

  /**
   * @notice Moves the idle money to a successor for the same vault
   * @dev The vault's DEFAULT_ADMIN_ROLE. No adapter may be installed. The successor must be attested as PORTFOLIO in the
   *      vault's registry. A timelock batch runs this together with the vault's own plug change
   * @param _successor The new portfolio
   */
  function migrateTo(
    address _successor
  ) external;

  /*///////////////////////////////////////////////////////////////
                            VIEWS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The role that moves money, held on the vault
   * @return _role The role id
   */
  // solhint-disable-next-line style-guide-casing
  function ALLOCATOR_ROLE() external view returns (bytes32 _role);

  /**
   * @notice The most adapters that can be installed
   * @return _max The limit
   */
  // solhint-disable-next-line style-guide-casing
  function MAX_ADAPTERS() external view returns (uint256 _max);

  /**
   * @notice The vault this portfolio serves
   * @return _vault The vault, fixed at construction
   */
  // solhint-disable-next-line style-guide-casing
  function VAULT() external view returns (address _vault);

  /**
   * @notice The asset this portfolio holds
   * @return _asset The asset, fixed at construction
   */
  // solhint-disable-next-line style-guide-casing
  function ASSET() external view returns (IERC20 _asset);

  /**
   * @notice Whether this portfolio takes adapters whose value comes from a report
   * @return _accepted True when it does; a vault with a live price refuses a portfolio that does
   */
  // solhint-disable-next-line style-guide-casing
  function ACCEPTS_REPORTED() external view returns (bool _accepted);

  /**
   * @notice The installed adapters
   * @return _list The adapters
   */
  function adapters() external view returns (address[] memory _list);

  /**
   * @notice What an adapter has outstanding against its caps
   * @param _adapter The adapter
   * @return _allocation The allocation
   */
  function allocationOf(
    address _adapter
  ) external view returns (uint256 _allocation);

  /**
   * @notice A risk's allocation and caps
   * @param _id The risk id
   * @return _risk The risk
   */
  function riskOf(
    bytes32 _id
  ) external view returns (Risk memory _risk);

  /**
   * @notice The adapter `raise` draws on
   * @return _adapter The adapter, or zero for none
   */
  function liquidityAdapter() external view returns (address _adapter);

  /**
   * @notice How many times money has crossed between this portfolio and an adapter
   * @return _count The count; a valuation taken before a move is out of date once this changes
   */
  function moves() external view returns (uint256 _count);

  /**
   * @notice The on-chain value: the idle money plus every priced adapter
   * @dev Reported adapters are not in it: their value is in the report. Read `priceFresh()` too: an adapter that cannot be
   *      read counts as zero here, and that is not a loss. It reverts in the middle of a move, when the money is in
   *      neither place or in both, so nothing can price against a half-finished transfer
   * @return _value The value in assets
   */
  function pricedValue() external view returns (uint256 _value);

  /**
   * @notice Whether every priced adapter can be read right now
   * @return _fresh False stops dealing, and the last counted value stands
   */
  function priceFresh() external view returns (bool _fresh);

  /**
   * @notice What the vault could have now: the idle money plus what the liquidity adapter can return
   * @return _assets The assets
   */
  function liquidAssets() external view returns (uint256 _assets);
}
