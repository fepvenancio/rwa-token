// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import {MulticallUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol';
import {PausableUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC8473} from 'interfaces/IERC8473.sol';
import {IPolicyGatedCore} from 'interfaces/IPolicyGatedCore.sol';
import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';

/**
 * @title PolicyGatedCoreUpgradeable
 * @notice The part of every gated template that does not depend on what it counts: the roles, the guardian and the
 *         recovery path, pause, the hook pointer and its attestation, the registry, and the upgrade checks. A fungible
 *         template adds balances and frozen amounts (`PolicyGatedERC20Upgradeable`), an ERC-721 its tokens and their
 *         freezes (`Gated721`)
 * @dev DEFAULT_ADMIN_ROLE is the timelock and administers every role. GUARDIAN_ROLE can only stop things: it pauses,
 *      and cannot unpause, change the hook, grant roles or upgrade
 */
abstract contract PolicyGatedCoreUpgradeable is
  AccessControlUpgradeable,
  PausableUpgradeable,
  MulticallUpgradeable,
  UUPSUpgradeable,
  ReentrancyGuardUpgradeable,
  IPolicyGatedCore,
  ITemplated
{
  /**
   * @notice ERC-7201 namespaced storage of the core
   * @param registry The policy registry, fixed at initialization
   * @param hook The current policy hook
   * @custom:storage-location erc7201:gated.storage.PolicyGatedCore
   */
  struct PolicyGatedCoreStorage {
    IPolicyRegistry registry;
    IERC8473Policy hook;
  }

  /// @notice Role allowed to mint
  bytes32 public constant MINTER_ROLE = keccak256('MINTER_ROLE');
  /// @notice Role allowed to burn from any account
  bytes32 public constant BURNER_ROLE = keccak256('BURNER_ROLE');
  /// @notice Role allowed to force transfers and set frozen amounts
  bytes32 public constant AGENT_ROLE = keccak256('AGENT_ROLE');
  /// @notice Role allowed to pause, with no delay
  bytes32 public constant GUARDIAN_ROLE = keccak256('GUARDIAN_ROLE');
  /// @notice Role allowed to upgrade to an attested implementation
  bytes32 public constant UPGRADER_ROLE = keccak256('UPGRADER_ROLE');

  /// @notice Role of the recovery timelock: may only `unpause` and revoke GUARDIAN_ROLE, a path the guardian cannot
  ///         cancel. Granted and revoked by DEFAULT_ADMIN_ROLE like any role
  bytes32 public constant RECOVERY_ROLE = keccak256('RECOVERY_ROLE');

  /// @notice keccak256(abi.encode(uint256(keccak256('gated.storage.PolicyGatedCore')) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _POLICY_GATED_CORE_STORAGE_LOCATION =
    0x24cd91f20c425d0e230af450b7e1d478ce1f14845adc233e0b9fadc9198cf100;

  /// @inheritdoc IPolicyGatedCore
  function pause() external onlyRole(GUARDIAN_ROLE) {
    _pause();
  }

  /**
   * @inheritdoc IPolicyGatedCore
   * @dev DEFAULT_ADMIN_ROLE (the main timelock) or RECOVERY_ROLE (the recovery timelock, which the guardian cannot
   *      cancel). Anyone else gets the usual AccessControl error for DEFAULT_ADMIN_ROLE
   */
  function unpause() external {
    address _sender = _msgSender();
    if (!hasRole(DEFAULT_ADMIN_ROLE, _sender) && !hasRole(RECOVERY_ROLE, _sender)) {
      revert AccessControlUnauthorizedAccount(_sender, DEFAULT_ADMIN_ROLE);
    }
    _unpause();
  }

  /// @inheritdoc IPolicyGatedCore
  function installPolicy(
    address _newPolicy,
    bytes calldata _data
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _installPolicy(_newPolicy, _data);
  }

  /// @inheritdoc IERC8473
  function policy() external view returns (address _installed) {
    _installed = address(_policy());
  }

  /**
   * @inheritdoc AccessControlUpgradeable
   * @dev RECOVERY_ROLE may revoke GUARDIAN_ROLE and nothing else; every other revocation needs the role's admin
   */
  function revokeRole(
    bytes32 _role,
    address _account
  ) public override {
    if (_role == GUARDIAN_ROLE && hasRole(RECOVERY_ROLE, _msgSender())) {
      // _revokeRole returns false only if the role was not held; either way the account ends up without it.
      // aderyn-ignore-next-line(unchecked-return)
      _revokeRole(_role, _account);
      return;
    }
    super.revokeRole(_role, _account);
  }

  /// @inheritdoc IPolicyGatedCore
  function registry() public view returns (address _registry) {
    _registry = address(_getPolicyGatedCoreStorage().registry);
  }

  /// @inheritdoc AccessControlUpgradeable
  function supportsInterface(
    bytes4 _interfaceId
  ) public view virtual override(AccessControlUpgradeable, IERC165) returns (bool _supported) {
    _supported = _interfaceId == type(IPolicyGatedCore).interfaceId || _interfaceId == type(IERC8473).interfaceId
      || super.supportsInterface(_interfaceId);
  }

  /// @inheritdoc ITemplated
  function templateId() public pure virtual override returns (bytes32 _id);

  /**
   * @notice Initializes the core and its OpenZeppelin parents
   * @param _admin The first admin, granted DEFAULT_ADMIN_ROLE: the operations account in a launch, which hands it to the timelock
   * @param _guardian The guardian multisig, granted GUARDIAN_ROLE
   * @param _registry The policy registry
   * @param _hook The initial policy hook; must be attested as HOOK and name the same registry
   * @param _initialRules The rule set installed on the hook for this token in the same call; empty installs none
   */
  // solhint-disable-next-line style-guide-casing
  function __PolicyGatedCore_init(
    address _admin,
    address _guardian,
    address _registry,
    address _hook,
    IComplianceRule[] memory _initialRules
  ) internal onlyInitializing {
    __AccessControl_init();
    __Pausable_init();
    __Multicall_init();
    __ReentrancyGuard_init();
    __PolicyGatedCore_init_unchained(_admin, _guardian, _registry, _hook, _initialRules);
  }

  /**
   * @notice Initializes the core's own state
   * @param _admin The first admin, granted DEFAULT_ADMIN_ROLE: the operations account in a launch, which hands it to the timelock
   * @param _guardian The guardian multisig, granted GUARDIAN_ROLE
   * @param _registry The policy registry
   * @param _hook The initial policy hook; must be attested as HOOK and name the same registry
   * @param _initialRules The rule set installed on the hook for this token in the same call; empty installs none
   */
  // solhint-disable-next-line style-guide-casing
  function __PolicyGatedCore_init_unchained(
    address _admin,
    address _guardian,
    address _registry,
    address _hook,
    IComplianceRule[] memory _initialRules
  ) internal onlyInitializing {
    if (_admin == address(0) || _guardian == address(0) || _registry == address(0)) revert PolicyGated_ZeroAddress();
    _getPolicyGatedCoreStorage().registry = IPolicyRegistry(_registry);
    // _grantRole returns false only if the role is already held; either way the account ends up holding it.
    // aderyn-ignore-next-line(unchecked-return)
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    // As above.
    // aderyn-ignore-next-line(unchecked-return)
    _grantRole(GUARDIAN_ROLE, _guardian);
    // The rule list travels as the installation's data, which the hook's `onInstall` accepts from the token itself, so
    // the token is live with its policy as soon as it is initialised. Nothing to install means the hook's own state
    // stands: no rules, every movement rejected.
    _installPolicy(_hook, _initialRules.length != 0 ? abi.encode(_initialRules) : bytes(''));
  }

  /**
   * @notice Authorizes a UUPS upgrade
   * @dev Only UPGRADER_ROLE; the new implementation must be attested as IMPLEMENTATION and must belong to the same
   *      template: an implementation that reports another template id, or none, is refused
   * @param _newImplementation The new implementation
   */
  function _authorizeUpgrade(
    address _newImplementation
  ) internal view override onlyRole(UPGRADER_ROLE) {
    if (!_getPolicyGatedCoreStorage()
        .registry
        .isAttested(_newImplementation, IPolicyRegistry.AttestKind.IMPLEMENTATION)) {
      revert PolicyGated_NotAttested(_newImplementation, IPolicyRegistry.AttestKind.IMPLEMENTATION);
    }
    bytes32 _expected = templateId();
    bytes32 _actual = ITemplated(_newImplementation).templateId();
    if (_actual != _expected) revert Templated_WrongTemplate(_newImplementation, _expected, _actual);
  }

  /**
   * @notice The current policy hook
   * @return _hook The hook
   */
  function _policy() internal view returns (IERC8473Policy _hook) {
    _hook = _getPolicyGatedCoreStorage().hook;
  }

  /**
   * @notice Asks the policy for one decision, treating any failure as a rejection
   * @dev A bounded static call: one word of the answer is copied, to the scratch space. A policy that reverts, runs out
   *      of gas, answers fewer than 32 bytes or has no code is `CHECK_UNAVAILABLE`, so a pre-flight reads false and
   *      never reverts, and a movement reverts (ERC-8473, check rule 5 and token rule 4)
   * @param _policyAddress The policy, read once by the caller
   * @param _call The encoded check
   * @return _reason The policy's answer, or `CHECK_UNAVAILABLE`
   */
  function _ask(
    address _policyAddress,
    bytes memory _call
  ) internal view returns (bytes32 _reason) {
    _reason = Reasons.CHECK_UNAVAILABLE;
    assembly ('memory-safe') {
      if staticcall(gas(), _policyAddress, add(_call, 0x20), mload(_call), 0x00, 0x20) {
        if gt(returndatasize(), 0x1f) { _reason := mload(0x00) }
      }
    }
  }

  /**
   * @notice Whether an account may send, or receive, at all; the account-level question of ERC-7943
   * @dev True for the zero address, without asking the policy: the zero side of a mint or a burn is no account
   *      (ERC-8473, check rules 1 and 2). False while paused and when the token has no policy. Never reverts: a policy
   *      that cannot be asked reads false
   * @param _account The account
   * @param _sending True to ask about sending, false about receiving
   * @return _allowed True if the account may
   */
  function _accountAllowed(
    address _account,
    bool _sending
  ) internal view returns (bool _allowed) {
    IERC8473Policy _hook = _policy();
    if (_account == address(0)) return true;
    if (paused() || address(_hook) == address(0)) return false;
    bytes32 _reason = _ask(
      address(_hook),
      _sending
        ? abi.encodeCall(IERC8473Policy.checkSend, (address(this), _account))
        : abi.encodeCall(IERC8473Policy.checkReceive, (address(this), _account))
    );
    // Compares a reason code with a constant, not a balance.
    // slither-disable-next-line incorrect-equality
    _allowed = _reason == Reasons.TRANSFER_OK;
  }

  /**
   * @notice Infers MINT, BURN or TRANSFER from the addresses
   * @param _from The sender
   * @param _to The receiver
   * @return _kind The inferred kind
   */
  function _inferKind(
    address _from,
    address _to
  ) internal pure returns (IERC8473Policy.TransferKind _kind) {
    if (_from == address(0)) return IERC8473Policy.TransferKind.MINT;
    if (_to == address(0)) return IERC8473Policy.TransferKind.BURN;
    _kind = IERC8473Policy.TransferKind.TRANSFER;
  }

  /**
   * @notice Installs a policy: checks it, sets it, announces it, then lets it initialise
   * @dev ERC-8473, installing a policy. The policy must be attested as HOOK, name the token's registry and answer the
   *      policy interface id. `onInstall` is called once `policy()` returns the new policy, with the policy consulted
   *      until now; if it reverts, so does the installation. The guard is held throughout, so no movement and no other
   *      installation can begin while `onInstall` runs. The outgoing policy is never called
   * @param _newPolicy The new policy
   * @param _data Passed to `onInstall` unchanged
   */
  function _installPolicy(
    address _newPolicy,
    bytes memory _data
  ) private nonReentrant {
    if (_newPolicy == address(0)) revert PolicyGated_ZeroAddress();
    PolicyGatedCoreStorage storage $ = _getPolicyGatedCoreStorage();
    if (!$.registry.isAttested(_newPolicy, IPolicyRegistry.AttestKind.HOOK)) {
      revert PolicyGated_NotAttested(_newPolicy, IPolicyRegistry.AttestKind.HOOK);
    }
    // A hook shared by several tokens vets their rules against its own registry, so it must be the token's.
    address _hookRegistry = address(IComplianceHook(_newPolicy).REGISTRY());
    if (_hookRegistry != address($.registry)) {
      revert PolicyGated_HookRegistryMismatch(_hookRegistry, address($.registry));
    }
    if (!IERC165(_newPolicy).supportsInterface(type(IERC8473Policy).interfaceId)) {
      revert PolicyGated_NotAPolicy(_newPolicy);
    }
    address _previous = address($.hook);
    $.hook = IERC8473Policy(_newPolicy);
    emit PolicyChanged(_previous, _newPolicy);
    IERC8473Policy(_newPolicy).onInstall(address(this), _previous, _data);
  }

  /**
   * @notice The ERC-7201 storage of the core
   * @return $ The storage pointer
   */
  function _getPolicyGatedCoreStorage() private pure returns (PolicyGatedCoreStorage storage $) {
    assembly ('memory-safe') {
      $.slot := _POLICY_GATED_CORE_STORAGE_LOCATION
    }
  }
}
