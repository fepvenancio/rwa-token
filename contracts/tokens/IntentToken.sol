// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IntentSettledUpgradeable} from 'contracts/mixins/IntentSettledUpgradeable.sol';

/**
 * @title IntentToken
 * @notice Gated ERC-20 with executor-settled transfers. Deployed behind a UUPS proxy
 */
// No receive or payable function, and upgradeToAndCall rejects value: no ETH can enter (tests: *_Ether).
// aderyn-ignore-next-line(contract-locks-ether)
contract IntentToken is IntentSettledUpgradeable {
  /**
   * @notice Locks the implementation; only proxies can be initialized
   * @custom:oz-upgrades-unsafe-allow constructor
   */
  constructor() {
    _disableInitializers();
  }

  /**
   * @notice Initializes a proxy
   * @param _name The token name, also the EIP-712 domain name
   * @param _symbol The token symbol
   * @param _admin The timelock. Holds DEFAULT_ADMIN_ROLE and grants every other role
   * @param _guardian The guardian multisig. Can pause and, through the timelock's CANCELLER_ROLE, veto; nothing else
   * @param _registry The policy registry, fixed after initialization
   * @param _hook The initial policy hook; must be attested as HOOK
   */
  function initialize(
    string calldata _name,
    string calldata _symbol,
    address _admin,
    address _guardian,
    address _registry,
    address _hook
  ) external initializer {
    __PolicyGatedERC20_init(_name, _symbol, _admin, _guardian, _registry, _hook);
    __IntentSettled_init();
  }
}
