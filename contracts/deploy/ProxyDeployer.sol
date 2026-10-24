// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Address} from '@openzeppelin/contracts/utils/Address.sol';
import {Create2} from '@openzeppelin/contracts/utils/Create2.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IProxyDeployer} from 'interfaces/IProxyDeployer.sol';

import {TokenProxy} from 'contracts/deploy/TokenProxy.sol';

/**
 * @title ProxyDeployer
 * @notice Places each token proxy at an address the council can compute from the symbol and the implementation alone,
 *         and refuses to finish unless the token came up with the shared hook and exactly the reviewed rule set
 * @dev Immutable code, owner-gated. The owner gate matters: the address does not cover the init data, so anyone else
 *      could otherwise occupy it with the same symbol and implementation but their own admin. The deployer owns it only
 *      during deployment; `Activate` transfers ownership to the timelock, so any later token goes through governance
 */
contract ProxyDeployer is Ownable, IProxyDeployer {
  /// @inheritdoc IProxyDeployer
  mapping(bytes32 _salt => bool _used) public saltUsed;

  /**
   * @notice Deploys the helper
   * @param _initialOwner The deployer account, the only one allowed to deploy proxies until ownership moves to the
   *        timelock
   */
  constructor(
    address _initialOwner
  ) Ownable(_initialOwner) {}

  /// @inheritdoc IProxyDeployer
  function deploy(
    string calldata _symbol,
    address _implementation,
    bytes calldata _initData,
    address _hook,
    IComplianceRule[] calldata _expectedRules
  ) external onlyOwner returns (address _proxy) {
    // Every revert below undoes the whole call, `saltUsed` included: a failed deploy never strands the symbol.
    bytes32 _salt = keccak256(bytes(_symbol));
    if (saltUsed[_salt]) revert ProxyDeployer_SaltUsed(_salt);
    saltUsed[_salt] = true;

    // Empty init data keeps the address independent of the hook; initialising here leaves no window to front-run.
    _proxy = address(new TokenProxy{salt: _salt}(_implementation, ''));
    // `initialize` returns nothing; its success is all that matters, and it is checked below.
    // Aderyn's form of the Slither finding below; initialize returns nothing.
    // slither-disable-next-line unused-return
    Address.functionCall(_proxy, _initData); // aderyn-ignore(unchecked-return)

    address _installed = IPolicyGated(_proxy).policyHook();
    if (_installed != _hook) revert ProxyDeployer_HookNotInstalled(_hook, _installed);
    if (!_rulesMatch(_hook, _proxy, _expectedRules)) revert ProxyDeployer_RulesMismatch(_hook, _proxy);
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
   * @notice Whether the hook holds exactly the expected rules for a token, in the same order
   * @param _hook The shared hook
   * @param _token The token
   * @param _expected The expected rules
   * @return _same True if the lists are equal
   */
  function _rulesMatch(
    address _hook,
    address _token,
    IComplianceRule[] calldata _expected
  ) private view returns (bool _same) {
    IComplianceRule[] memory _actual = IComplianceHook(_hook).rules(_token);
    uint256 _length = _expected.length;
    if (_actual.length != _length) return false;
    for (uint256 _i; _i < _length; ++_i) {
      if (_actual[_i] != _expected[_i]) return false;
    }
    _same = true;
  }

  /**
   * @notice The hash of the proxy's creation code with empty init data
   * @param _implementation The implementation the proxy starts with
   * @return _hash The init code hash
   */
  function _initCodeHash(
    address _implementation
  ) private pure returns (bytes32 _hash) {
    // Only the second operand varies; the first is fixed creation code, so the packed encoding is unambiguous.
    // aderyn-ignore-next-line(abi-encode-packed-hash-collision)
    _hash = keccak256(abi.encodePacked(type(TokenProxy).creationCode, abi.encode(_implementation, bytes(''))));
  }
}
