// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

/**
 * @title IProxyDeployer
 * @notice Deployment-only helper that places each token proxy at an address the council can compute from the symbol and
 *         the implementation alone, refuses an implementation the council did not attest, and checks that the token
 *         came up with the shared hook and exactly the reviewed rule set
 * @dev CREATE2 with salt `keccak256(bytes(symbol))` over `TokenProxy(implementation, "")`: the address depends on
 *      this contract, the symbol and the implementation, never on the init data, which carries the hook and the initial
 *      rules. The proxy is initialised in the same transaction, so no one can initialise it first. Holds no roles and no
 *      funds. Ownership (OZ `Ownable`) gates `deploy`; after the core is handed over it belongs to the operations account
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

  /**
   * @notice Thrown when the implementation's runtime codehash is not attested as an implementation in the registry
   * @param _implementation The implementation
   */
  error ProxyDeployer_ImplementationNotAttested(address _implementation);

  /**
   * @notice Thrown when the initialised token names another registry than the deployer's
   * @param _expected The deployer's registry
   * @param _actual The registry the token reports
   */
  error ProxyDeployer_RegistryMismatch(address _expected, address _actual);

  /// @notice Thrown when the registry given to the constructor is the zero address
  error ProxyDeployer_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Deploys and initialises a token proxy at `predict(_symbol, _implementation)`
   * @dev Only the owner, once per symbol; a reverted deploy leaves the symbol unused. Reverts before creating the proxy
   *      unless `REGISTRY` attests `_implementation` as an implementation. Reverts after initialising unless the token
   *      names `REGISTRY` as its own, installed `_hook`, reports `_symbol`, and the hook holds exactly `_expectedRules`
   *      for it, in order
   * @param _symbol The token symbol; its hash is the salt
   * @param _implementation The implementation, attested in `REGISTRY`
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

  /**
   * @notice The registry that attests the implementations this deployer places, and the one every token it deploys
   *         must name as its own
   * @return _registry The registry
   */
  // getter of an UPPER_SNAKE constant/immutable
  // solhint-disable-next-line style-guide-casing
  function REGISTRY() external view returns (IPolicyRegistry _registry);
}
