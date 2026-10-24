// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';

/**
 * @title IProxyDeployer
 * @notice Deployment-only helper that places each token proxy at an address the council can compute from the symbol and
 *         the implementation alone, and checks that the token came up with the shared hook and exactly the reviewed
 *         rule set
 * @dev CREATE2 with salt `keccak256(bytes(symbol))` over `TokenProxy(implementation, "")`: the address depends on
 *      this contract, the symbol and the implementation, never on the init data, which carries the hook and the initial
 *      rules. The proxy is initialised in the same transaction, so no one can initialise it first. Holds no roles and no
 *      funds. Ownership (OZ `Ownable`) gates `deploy`; after deployment it belongs to the timelock
 */
interface IProxyDeployer {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a token proxy is deployed and initialised
   * @param _salt The CREATE2 salt, `keccak256(bytes(symbol))`
   * @param _proxy The token proxy
   * @param _implementation The implementation behind the proxy
   * @param _hook The shared policy hook the token was initialised with
   */
  event ProxyDeployed(bytes32 indexed _salt, address indexed _proxy, address indexed _implementation, address _hook);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when the hook does not hold exactly the expected rules for the new token after initialisation
   * @param _hook The hook
   * @param _proxy The token proxy
   */
  error ProxyDeployer_RulesMismatch(address _hook, address _proxy);

  /**
   * @notice Thrown when the init data installed another hook than the one checked
   * @param _expected The checked hook
   * @param _installed The hook the token reports after initialisation
   */
  error ProxyDeployer_HookNotInstalled(address _expected, address _installed);

  /**
   * @notice Thrown when the symbol's salt was already used, with any implementation
   * @param _salt The salt
   */
  error ProxyDeployer_SaltUsed(bytes32 _salt);

  /**
   * @notice Thrown when the initialised token reports another symbol than the one its salt was derived from
   * @param _expected The symbol the salt was derived from
   * @param _actual The token's symbol
   */
  error ProxyDeployer_SymbolMismatch(string _expected, string _actual);

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Deploys and initialises a token proxy at `predict(_symbol, _implementation)`
   * @dev Only the owner, once per symbol; a reverted deploy leaves the symbol unused. Reverts after initialising unless
   *      the token installed `_hook`, reports `_symbol`, and the hook holds exactly `_expectedRules` for it, in order
   * @param _symbol The token symbol; its hash is the salt
   * @param _implementation The attested implementation
   * @param _initData The `initialize` call, which must pass `_hook`, `_symbol` and the initial rules
   * @param _hook The attested shared hook
   * @param _expectedRules The rules the token must have on the hook after initialisation
   * @return _proxy The token proxy
   */
  function deploy(
    string calldata _symbol,
    address _implementation,
    bytes calldata _initData,
    address _hook,
    IComplianceRule[] calldata _expectedRules
  ) external returns (address _proxy);

  /**
   * @notice The address a token proxy for `_symbol` over `_implementation` will occupy
   * @param _symbol The token symbol
   * @param _implementation The implementation
   * @return _proxy The predicted address
   */
  function predict(
    string calldata _symbol,
    address _implementation
  ) external view returns (address _proxy);

  /**
   * @notice Whether a salt was used
   * @param _salt The salt, `keccak256(bytes(symbol))`
   * @return _used True once a proxy was deployed with it
   */
  function saltUsed(
    bytes32 _salt
  ) external view returns (bool _used);
}
