// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IProxyDeployer
 * @notice Deployment-only helper that places each token proxy at an address fixed before its hook exists. The hook
 *         binds to that address in an immutable, so the council can compute the token address and attest the hook
 *         for exactly that token
 * @dev CREATE2 with salt `keccak256(bytes(symbol))` over `TokenProxy(implementation, "")`: the address depends on
 *      this contract, the symbol and the implementation, never on the init data, which carries the hook. The proxy is
 *      initialised in the same transaction, so no one can initialise it first. Holds no roles and no funds. Ownership
 *      (OZ `Ownable`) gates `deploy`; after deployment it belongs to the timelock
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
   * @param _hook The policy hook the token was initialised with, bound to `_proxy`
   */
  event ProxyDeployed(bytes32 indexed _salt, address indexed _proxy, address indexed _implementation, address _hook);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when the hook is bound to another token than the proxy about to be deployed
   * @param _hook The hook
   * @param _hookToken The token the hook is bound to
   * @param _proxy The address the proxy will occupy
   */
  error ProxyDeployer_HookTokenMismatch(address _hook, address _hookToken, address _proxy);

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
   * @dev Only the owner, once per symbol; a reverted deploy leaves the symbol unused. Reverts before creating anything unless `_hook` is bound to the predicted
   *      address, and after initialising unless the token installed `_hook` and reports `_symbol`
   * @param _symbol The token symbol; its hash is the salt
   * @param _implementation The attested implementation
   * @param _initData The `initialize` call, which must pass `_hook` and `_symbol`
   * @param _hook The attested hook, bound to the predicted address
   * @return _proxy The token proxy
   */
  function deploy(
    string calldata _symbol,
    address _implementation,
    bytes calldata _initData,
    address _hook
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
