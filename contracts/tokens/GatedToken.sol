// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';

import {PolicyGatedERC20Upgradeable} from 'contracts/base/PolicyGatedERC20Upgradeable.sol';

/**
 * @title GatedToken
 * @notice The base and nothing else: a policy-gated ERC-20 with no signed intents. Deployed behind a UUPS proxy
 */
// No receive or payable function, and upgradeToAndCall rejects value: no ETH can enter.
// aderyn-ignore-next-line(contract-locks-ether)
contract GatedToken is PolicyGatedERC20Upgradeable {
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
   * @param _admin Holds DEFAULT_ADMIN_ROLE and grants every other role; ends up with the timelock
   * @param _guardian The guardian multisig. Can pause and, through the timelock's CANCELLER_ROLE, veto; nothing else
   * @param _registry The policy registry, fixed after initialization
   * @param _hook The initial policy hook; must be attested as HOOK and name the same registry
   * @param _initialRules The rule set installed on the hook for this token in the same call; empty installs none
   */
  function initialize(
    string calldata _name,
    string calldata _symbol,
    address _admin,
    address _guardian,
    address _registry,
    address _hook,
    IComplianceRule[] calldata _initialRules
  ) external initializer {
    __PolicyGatedERC20_init(_name, _symbol, _admin, _guardian, _registry, _hook, _initialRules);
  }

  /// @inheritdoc ITemplated
  function templateId() public pure override returns (bytes32 _id) {
    _id = keccak256('GatedToken');
  }
}
