// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {IPortfolio} from 'interfaces/IPortfolio.sol';

import {Portfolio} from 'contracts/portfolio/Portfolio.sol';
import {MockAdapter} from 'contracts/test/MockAdapter.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {MockPortfolioVault} from 'contracts/test/MockPortfolioVault.sol';

/// @notice Registry stub that attests everything, so the symbolic run focuses on the caps
contract HalmosOpenRegistry {
  function isAttested(
    address,
    IPolicyRegistry.AttestKind
  ) external pure returns (bool _attested) {
    _attested = true;
  }
}

/**
 * @notice Halmos symbolic properties of `Portfolio.allocate`: whatever the amount and the caps, an allocation that goes
 *         through leaves every risk it names within both of its caps, and one that fails moves nothing
 * @dev Run with `npm run test:halmos`. Hardhat compiles this file but does not run `check_` functions. The vault's total
 *      assets are a constant, which keeps the relative cap linear for the solver; the fuzz tests in `Portfolio.t.sol`
 *      vary it. `vm.assume` here is a symbolic path constraint; the Wonderland "bound, not assume" rule targets fuzzing
 */
contract PortfolioHalmos is Test {
  bytes32 internal constant _DEFAULT_ADMIN_ROLE = 0x00;
  bytes32 internal constant _ALLOCATOR_ROLE = keccak256('ALLOCATOR_ROLE');
  bytes32 internal constant _OWN_ID = keccak256('own');
  bytes32 internal constant _SHARED_ID = keccak256('shared');
  uint256 internal constant _BPS = 10_000;
  uint256 internal constant _TOTAL = 1_000_000e6;
  uint256 internal constant _IDLE = 500_000e6;

  address internal _admin = address(0x1111);
  address internal _allocator = address(0x2222);
  Portfolio internal _portfolio;
  MockAsset internal _asset;
  MockAdapter internal _adapter;

  function setUp() public {
    _asset = new MockAsset(6);
    MockPortfolioVault _vault = new MockPortfolioVault(address(new HalmosOpenRegistry()));
    _vault.setRole(_DEFAULT_ADMIN_ROLE, _admin, true);
    _vault.setRole(_ALLOCATOR_ROLE, _allocator, true);
    _vault.setTotalAssets(_TOTAL);
    _portfolio = new Portfolio(address(_vault), IERC20(address(_asset)), true);
    bytes32[] memory _ids = new bytes32[](2);
    _ids[0] = _OWN_ID;
    _ids[1] = _SHARED_ID;
    _adapter = new MockAdapter(address(_portfolio), address(_asset), true, _ids);
    _asset.mint(address(_portfolio), _IDLE);
    vm.prank(_admin);
    _portfolio.addAdapter(address(_adapter));
  }

  /// @notice A successful allocation leaves both risks within both caps, and a refused one changes nothing
  function check_anAllocationNeverPassesACap(
    uint256 _assets,
    uint120 _ownAbsolute,
    uint120 _sharedAbsolute,
    uint16 _ownRelative,
    uint16 _sharedRelative
  ) public {
    vm.assume(_ownRelative <= _BPS && _sharedRelative <= _BPS);
    vm.startPrank(_admin);
    _portfolio.setCaps(_OWN_ID, _ownAbsolute, _ownRelative);
    _portfolio.setCaps(_SHARED_ID, _sharedAbsolute, _sharedRelative);
    vm.stopPrank();

    vm.prank(_allocator);
    (bool _ok,) = address(_portfolio).call(abi.encodeCall(IPortfolio.allocate, (address(_adapter), _assets, 0)));

    IPortfolio.Risk memory _own = _portfolio.riskOf(_OWN_ID);
    IPortfolio.Risk memory _shared = _portfolio.riskOf(_SHARED_ID);
    if (!_ok) {
      assert(_own.allocation == 0 && _shared.allocation == 0);
      assert(_asset.balanceOf(address(_portfolio)) == _IDLE);
      return;
    }
    assert(_own.allocation <= _ownAbsolute && _shared.allocation <= _sharedAbsolute);
    if (_ownRelative < _BPS) assert(uint256(_own.allocation) * _BPS <= uint256(_ownRelative) * _TOTAL);
    if (_sharedRelative < _BPS) assert(uint256(_shared.allocation) * _BPS <= uint256(_sharedRelative) * _TOTAL);
  }
}
