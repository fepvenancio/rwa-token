// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Address} from '@openzeppelin/contracts/utils/Address.sol';
import {Create2} from '@openzeppelin/contracts/utils/Create2.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IProxyDeployer} from 'interfaces/IProxyDeployer.sol';

import {TokenProxy} from 'contracts/deploy/TokenProxy.sol';

/**
 * @title ProxyDeployer
 * @notice Places each token proxy at an address the council can compute before the token's hook is deployed, and
 *         refuses to deploy unless the hook is bound to exactly that address
 * @dev Immutable, deployment-only, owner-gated. The owner gate matters: the address does not cover the init data, so
 *      anyone else could otherwise occupy it with the same symbol and implementation but their own admin
 */
contract ProxyDeployer is IProxyDeployer {
  /// @inheritdoc IProxyDeployer
  address public immutable OWNER;

  /// @inheritdoc IProxyDeployer
  mapping(bytes32 _salt => bool _used) public saltUsed;

  /**
   * @notice Deploys the helper
   * @param _owner The deployer account, the only one allowed to deploy proxies
   */
  constructor(
    address _owner
  ) {
    if (_owner == address(0)) revert ProxyDeployer_ZeroAddress();
    OWNER = _owner;
  }

  /// @inheritdoc IProxyDeployer
  function deploy(
    string calldata _symbol,
    address _implementation,
    bytes calldata _initData,
    address _hook
  ) external returns (address _proxy) {
    if (msg.sender != OWNER) revert ProxyDeployer_OnlyOwner(msg.sender);
    bytes32 _salt = keccak256(bytes(_symbol));
    if (saltUsed[_salt]) revert ProxyDeployer_SaltUsed(_salt);
    saltUsed[_salt] = true;

    // The loud failure: a hook bound to any other address is refused before the proxy exists.
    address _predicted = Create2.computeAddress(_salt, _initCodeHash(_implementation));
    address _hookToken = IComplianceHook(_hook).TOKEN();
    if (_hookToken != _predicted) revert ProxyDeployer_HookTokenMismatch(_hook, _hookToken, _predicted);

    // Empty init data keeps the address independent of the hook; initialising here leaves no window to front-run.
    _proxy = address(new TokenProxy{salt: _salt}(_implementation, ''));
    // `initialize` returns nothing; its success is all that matters, and it is checked below.
    // slither-disable-next-line unused-return
    Address.functionCall(_proxy, _initData);

    address _installed = IPolicyGated(_proxy).policyHook();
    if (_installed != _hook) revert ProxyDeployer_HookNotInstalled(_hook, _installed);
    string memory _actual = IERC20Metadata(_proxy).symbol();
    if (keccak256(bytes(_actual)) != _salt) revert ProxyDeployer_SymbolMismatch(_symbol, _actual);

    emit ProxyDeployed(_salt, _proxy, _implementation, _hook);
  }

  /// @inheritdoc IProxyDeployer
  function predict(
    string calldata _symbol,
    address _implementation
  ) external view returns (address _proxy) {
    _proxy = Create2.computeAddress(keccak256(bytes(_symbol)), _initCodeHash(_implementation));
  }

  /**
   * @notice The hash of the proxy's creation code with empty init data
   * @param _implementation The implementation the proxy starts with
   * @return _hash The init code hash
   */
  function _initCodeHash(
    address _implementation
  ) private pure returns (bytes32 _hash) {
    _hash = keccak256(abi.encodePacked(type(TokenProxy).creationCode, abi.encode(_implementation, bytes(''))));
  }
}
