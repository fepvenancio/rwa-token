// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';

import {IntentSettledUpgradeable} from 'contracts/mixins/IntentSettledUpgradeable.sol';

/**
 * @title IntentToken
 * @notice Gated ERC-20 with executor-settled transfers, at the decimals its ledger uses. Deployed behind a UUPS proxy
 */
// No receive or payable function, and upgradeToAndCall rejects value: no ETH can enter (tests: *_Ether).
// aderyn-ignore-next-line(contract-locks-ether)
contract IntentToken is IntentSettledUpgradeable {
  /**
   * @notice ERC-7201 namespaced storage of the token
   * @param decimals The token's decimals, fixed at initialization
   * @custom:storage-location erc7201:gated.storage.IntentToken
   */
  struct IntentTokenStorage {
    uint8 decimals;
  }

  /// @notice keccak256(abi.encode(uint256(keccak256('gated.storage.IntentToken')) - 1)) & ~bytes32(uint256(0xff))
  // Read in assembly by the ERC-7201 accessor (test: test_TheErc7201LocationHoldsTheDecimals).
  // aderyn-ignore-next-line(unused-state-variable)
  bytes32 private constant _INTENT_TOKEN_STORAGE_LOCATION =
    0x403ba412e6fa3831ce946cdd170c250cfb7cdf1cb5d1422d2bd90099bcd06700;

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
   * @param _decimals The token's decimals, fixed from here on: for a cash token, its ledger's precision
   * @param _admin The first admin, which holds DEFAULT_ADMIN_ROLE and grants every other role: the operations account in a
   *        launch, which hands it to the timelock
   * @param _guardian The guardian multisig. Can pause and, through the timelock's CANCELLER_ROLE, veto; nothing else
   * @param _registry The policy registry, fixed after initialization
   * @param _hook The initial policy hook; must be attested as HOOK and name the same registry
   * @param _initialRules The rule set installed on the hook for this token in the same call; empty installs none
   */
  function initialize(
    string memory _name,
    string memory _symbol,
    uint8 _decimals,
    address _admin,
    address _guardian,
    address _registry,
    address _hook,
    IComplianceRule[] memory _initialRules
  ) external initializer {
    _getIntentTokenStorage().decimals = _decimals;
    __ERC20_init(_name, _symbol);
    __ERC20Permit_init(_name);
    __PolicyGatedCore_init(_admin, _guardian, _registry, _hook, _initialRules);
    __IntentSettled_init();
  }

  /**
   * @notice The token's decimals
   * @return _decimals The value fixed at initialization
   */
  function decimals() public view override returns (uint8 _decimals) {
    _decimals = _getIntentTokenStorage().decimals;
  }

  /// @inheritdoc ITemplated
  function templateId() public pure override returns (bytes32 _id) {
    _id = keccak256('IntentToken');
  }

  /**
   * @notice The ERC-7201 storage of the token
   * @return $ The storage pointer
   */
  function _getIntentTokenStorage() private pure returns (IntentTokenStorage storage $) {
    assembly ('memory-safe') {
      $.slot := _INTENT_TOKEN_STORAGE_LOCATION
    }
  }
}
