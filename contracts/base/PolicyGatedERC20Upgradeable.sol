// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {
  ERC20PermitUpgradeable
} from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol';
import {PausableUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {TransientSlot} from '@openzeppelin/contracts/utils/TransientSlot.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

/**
 * @title PolicyGatedERC20Upgradeable
 * @notice Base for every gated template. Owns accounting, roles, the enforcement primitives (mint, burn, forced
 *         transfer, freeze, pause), the guardian and the hook pointer. Every policy decision is delegated to the hook
 *         through the single `_update` path; the base holds no business logic about who, where or when
 * @dev DEFAULT_ADMIN_ROLE is the timelock and administers every role. GUARDIAN_ROLE can only stop things: it pauses,
 *      and cannot unpause, change the hook, grant roles or upgrade
 */
abstract contract PolicyGatedERC20Upgradeable is
  ERC20PermitUpgradeable,
  AccessControlUpgradeable,
  PausableUpgradeable,
  UUPSUpgradeable,
  ReentrancyGuardTransient,
  IPolicyGated
{
  using TransientSlot for *;

  /**
   * @notice ERC-7201 namespaced storage of the base
   * @param registry The policy registry, fixed at initialization
   * @param hook The current policy hook
   * @param frozen The absolute frozen amount of each account; never above its balance
   * @custom:storage-location erc7201:gated.storage.PolicyGatedERC20
   */
  struct PolicyGatedStorage {
    IPolicyRegistry registry;
    IPolicyHook hook;
    mapping(address _user => uint256 _amount) frozen;
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
  ///         cancel (owner decision M-1). Granted and revoked by DEFAULT_ADMIN_ROLE like any role
  bytes32 public constant RECOVERY_ROLE = keccak256('RECOVERY_ROLE');

  /// @notice keccak256(abi.encode(uint256(keccak256('gated.storage.PolicyGatedERC20')) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _POLICY_GATED_STORAGE_LOCATION =
    0xe8c11567602593a5bc8df6eb5a119138618a3fad68d46d33c073939016673d00;

  /// @notice Transient slot holding `uint8(kind) + 1` announced by `_moveAs`; 0 means "infer from addresses"
  bytes32 private constant _KIND_SLOT = keccak256('gated.transient.kind');
  /// @notice Transient slot holding the announced `ref`
  bytes32 private constant _REF_SLOT = keccak256('gated.transient.ref');
  /// @notice Transient slot holding the announced `deadline`
  bytes32 private constant _DEADLINE_SLOT = keccak256('gated.transient.deadline');

  /// @inheritdoc IPolicyGated
  function mint(
    address _to,
    uint256 _amount
  ) external virtual onlyRole(MINTER_ROLE) {
    _mint(_to, _amount);
  }

  /// @inheritdoc IPolicyGated
  function burn(
    address _from,
    uint256 _amount
  ) external virtual onlyRole(BURNER_ROLE) {
    _releaseFrozen(_from, _amount);
    _burn(_from, _amount);
  }

  /// @inheritdoc IPolicyGated
  function forcedTransfer(
    address _from,
    address _to,
    uint256 _amount
  ) external onlyRole(AGENT_ROLE) {
    _releaseFrozen(_from, _amount);
    _moveAs(_from, _to, _amount, IPolicyHook.TransferKind.FORCED, bytes32(0), 0);
    // Emitted after the hook's afterTransfer: re-entry is blocked by `_update`'s guard and the hook is attested.
    // slither-disable-next-line reentrancy-events
    emit ForcedTransfer(_from, _to, _amount, _msgSender());
  }

  /// @inheritdoc IPolicyGated
  function setFrozen(
    address _user,
    uint256 _amount
  ) external onlyRole(AGENT_ROLE) {
    uint256 _balance = balanceOf(_user);
    if (_amount > _balance) revert PolicyGated_FrozenExceedsBalance(_user, _amount, _balance);
    _getPolicyGatedStorage().frozen[_user] = _amount;
    emit Frozen(_user, _amount);
  }

  /// @inheritdoc IPolicyGated
  function pause() external onlyRole(GUARDIAN_ROLE) {
    _pause();
  }

  /**
   * @inheritdoc IPolicyGated
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

  /// @inheritdoc IPolicyGated
  function setPolicyHook(
    address _newHook
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setHook(_newHook);
  }

  /// @inheritdoc IPolicyGated
  function canTransfer(
    address _from,
    address _to,
    uint256 _amount
  ) external view returns (bool _ok, bytes32 _reason) {
    _reason = _canTransfer(_from, _to, _amount);
    // Compares a reason code with a constant, not a balance.
    // slither-disable-next-line incorrect-equality
    _ok = _reason == Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IPolicyGated
  function isUserAllowed(
    address _user
  ) external view returns (bool _allowed) {
    IPolicyHook _hook = _policyHook();
    if (address(_hook) == address(0)) return false;
    // Compares a reason code with a constant, not a balance.
    // slither-disable-next-line incorrect-equality
    _allowed = _hook.beforeTransfer(
      _context(address(0), _user, 0, _msgSender(), IPolicyHook.TransferKind.MINT, bytes32(0), 0)
    ) == Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IPolicyGated
  function policyHook() external view returns (address _hook) {
    _hook = address(_policyHook());
  }

  /// @inheritdoc IPolicyGated
  function registry() external view returns (address _registry) {
    _registry = address(_getPolicyGatedStorage().registry);
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

  /// @inheritdoc IPolicyGated
  function getFrozen(
    address _user
  ) public view returns (uint256 _amount) {
    _amount = _getPolicyGatedStorage().frozen[_user];
  }

  /// @inheritdoc AccessControlUpgradeable
  function supportsInterface(
    bytes4 _interfaceId
  ) public view virtual override returns (bool _supported) {
    _supported = _interfaceId == type(IPolicyGated).interfaceId || _interfaceId == type(IERC20).interfaceId
      || _interfaceId == type(IERC20Permit).interfaceId || super.supportsInterface(_interfaceId);
  }

  /**
   * @notice Initializes the base and its OpenZeppelin parents
   * @param _name The token name, also the EIP-712 domain name
   * @param _symbol The token symbol
   * @param _admin The timelock, granted DEFAULT_ADMIN_ROLE
   * @param _guardian The guardian multisig, granted GUARDIAN_ROLE
   * @param _registry The policy registry
   * @param _hook The initial policy hook; must be attested as HOOK and name the same registry
   * @param _initialRules The rule set installed on the hook for this token in the same call; empty installs none
   */
  // solhint-disable-next-line style-guide-casing
  function __PolicyGatedERC20_init(
    string memory _name,
    string memory _symbol,
    address _admin,
    address _guardian,
    address _registry,
    address _hook,
    IComplianceRule[] memory _initialRules
  ) internal onlyInitializing {
    __ERC20_init(_name, _symbol);
    __ERC20Permit_init(_name);
    __AccessControl_init();
    __Pausable_init();
    __PolicyGatedERC20_init_unchained(_admin, _guardian, _registry, _hook, _initialRules);
  }

  /**
   * @notice Initializes the base's own state
   * @param _admin The timelock, granted DEFAULT_ADMIN_ROLE
   * @param _guardian The guardian multisig, granted GUARDIAN_ROLE
   * @param _registry The policy registry
   * @param _hook The initial policy hook; must be attested as HOOK and name the same registry
   * @param _initialRules The rule set installed on the hook for this token in the same call; empty installs none
   */
  // solhint-disable-next-line style-guide-casing
  function __PolicyGatedERC20_init_unchained(
    address _admin,
    address _guardian,
    address _registry,
    address _hook,
    IComplianceRule[] memory _initialRules
  ) internal onlyInitializing {
    if (_admin == address(0) || _guardian == address(0) || _registry == address(0)) revert PolicyGated_ZeroAddress();
    _getPolicyGatedStorage().registry = IPolicyRegistry(_registry);
    // _grantRole returns false only if the role is already held; either way the account ends up holding it.
    // aderyn-ignore-next-line(unchecked-return)
    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    // As above.
    // aderyn-ignore-next-line(unchecked-return)
    _grantRole(GUARDIAN_ROLE, _guardian);
    _setHook(_hook);
    // A shared hook accepts the rules of a token from the token itself, so the token is live with its policy as soon as
    // it is initialised. Nothing to install means the hook's own state stands: no rules, every movement rejected.
    if (_initialRules.length != 0) IComplianceHook(_hook).setRules(address(this), _initialRules);
  }

  /**
   * @notice The single path every balance movement takes: mechanical checks and hook, balances, then `afterTransfer`
   * @dev Guarded against reentrancy, so a hook or rule calling back into any transfer function reverts
   * @param _from The sender, or address(0) on mint
   * @param _to The receiver, or address(0) on burn
   * @param _value The amount
   */
  function _update(
    address _from,
    address _to,
    uint256 _value
  ) internal virtual override nonReentrant {
    (IPolicyHook.TransferKind _kind, bytes32 _ref, uint256 _deadline) = _consumePending(_from, _to);
    IPolicyHook.TransferContext memory _ctx = _context(_from, _to, _value, _msgSender(), _kind, _ref, _deadline);

    // Read once: the hook that approves the movement is the hook that sees `afterTransfer`.
    IPolicyHook _hook = _policyHook();
    bytes32 _reason = _check(_ctx, _hook);
    if (_reason != Reasons.TRANSFER_OK) revert PolicyGated_TransferRejected(_reason);

    super._update(_from, _to, _value);

    if (_hook.wantsAfter()) _hook.afterTransfer(_ctx);
  }

  /**
   * @notice Moves tokens announcing a kind that cannot be inferred from the addresses (FORCED, EXECUTED)
   * @dev `_transfer` either reaches `_update`, which consumes and clears the slots, or reverts, which rolls them back
   * @param _from The sender
   * @param _to The receiver
   * @param _amount The amount
   * @param _kind The announced kind
   * @param _ref The announced reference
   * @param _deadline The announced deadline
   */
  function _moveAs(
    address _from,
    address _to,
    uint256 _amount,
    IPolicyHook.TransferKind _kind,
    bytes32 _ref,
    uint256 _deadline
  ) internal {
    _KIND_SLOT.asUint256().tstore(uint256(_kind) + 1);
    _REF_SLOT.asBytes32().tstore(_ref);
    _DEADLINE_SLOT.asUint256().tstore(_deadline);
    _transfer(_from, _to, _amount);
  }

  /**
   * @notice Mints announcing a kind that cannot be inferred from the addresses: FORCED with `from == address(0)` is an
   *         enforcement mint (brief §5), exempt from pause and the holder cap but still identity-checked on `to`
   * @dev Kept apart from `_moveAs`, which never sees `from == address(0)`. `_mint` either reaches `_update`, which
   *      consumes and clears the slots, or reverts, which rolls them back
   * @param _to The receiver
   * @param _amount The amount
   * @param _kind The announced kind
   */
  function _mintAs(
    address _to,
    uint256 _amount,
    IPolicyHook.TransferKind _kind
  ) internal {
    _KIND_SLOT.asUint256().tstore(uint256(_kind) + 1);
    _REF_SLOT.asBytes32().tstore(bytes32(0));
    _DEADLINE_SLOT.asUint256().tstore(0);
    _mint(_to, _amount);
  }

  /**
   * @notice Lowers an account's frozen amount so an enforcement action can take `_amount` from it
   * @dev Keeps `frozen <= balance` after the action. Emits `Frozen` before the token `Transfer`, as ERC-7943 requires.
   *      Internal so templates' own enforcement moves (e.g. the 7540 escrow returns) keep the same invariant
   * @param _account The account losing tokens
   * @param _amount The amount it loses
   */
  function _releaseFrozen(
    address _account,
    uint256 _amount
  ) internal {
    uint256 _balance = balanceOf(_account);
    if (_amount > _balance) revert ERC20InsufficientBalance(_account, _balance, _amount);
    PolicyGatedStorage storage $ = _getPolicyGatedStorage();
    uint256 _remaining = _balance - _amount;
    if ($.frozen[_account] > _remaining) {
      $.frozen[_account] = _remaining;
      emit Frozen(_account, _remaining);
    }
  }

  /**
   * @notice Authorizes a UUPS upgrade
   * @dev Only UPGRADER_ROLE, and the new implementation must be attested as IMPLEMENTATION
   * @param _newImplementation The new implementation
   */
  function _authorizeUpgrade(
    address _newImplementation
  ) internal view override onlyRole(UPGRADER_ROLE) {
    if (!_getPolicyGatedStorage().registry.isAttested(_newImplementation, IPolicyRegistry.AttestKind.IMPLEMENTATION)) {
      revert PolicyGated_NotAttested(_newImplementation, IPolicyRegistry.AttestKind.IMPLEMENTATION);
    }
  }

  /**
   * @notice The pre-flight behind `canTransfer`, shared with templates (e.g. vault `max*`)
   * @dev Simulates a holder-driven movement: the operator is `_from`, or the caller for a mint
   * @param _from The sender, or address(0) for a mint
   * @param _to The receiver, or address(0) for a burn
   * @param _amount The amount
   * @return _reason The reason code
   */
  function _canTransfer(
    address _from,
    address _to,
    uint256 _amount
  ) internal view returns (bytes32 _reason) {
    address _operator = _from == address(0) ? _msgSender() : _from;
    _reason = _check(_context(_from, _to, _amount, _operator, _inferKind(_from, _to), bytes32(0), 0), _policyHook());
  }

  /**
   * @notice Mechanical checks then the hook decision, shared by `_update` and the pre-flights
   * @param _ctx The movement context
   * @param _hook The hook to consult, read once by the caller
   * @return _reason The reason code
   */
  function _check(
    IPolicyHook.TransferContext memory _ctx,
    IPolicyHook _hook
  ) internal view returns (bytes32 _reason) {
    if (paused() && _ctx.kind != IPolicyHook.TransferKind.FORCED) return Reasons.PAUSED;

    if (_ctx.from != address(0) && _ctx.kind != IPolicyHook.TransferKind.FORCED) {
      uint256 _balance = balanceOf(_ctx.from);
      uint256 _frozen = _getPolicyGatedStorage().frozen[_ctx.from];
      if (_balance < _frozen || _balance - _frozen < _ctx.amount) return Reasons.INSUFFICIENT_UNFROZEN;
    }

    if (address(_hook) == address(0)) return Reasons.NO_HOOK;
    _reason = _hook.beforeTransfer(_ctx);
  }

  /**
   * @notice The current policy hook
   * @return _hook The hook
   */
  function _policyHook() internal view returns (IPolicyHook _hook) {
    _hook = _getPolicyGatedStorage().hook;
  }

  /**
   * @notice Builds a movement context for this token
   * @param _from The sender
   * @param _to The receiver
   * @param _amount The amount
   * @param _operator The account driving the movement
   * @param _kind The movement kind
   * @param _ref The reference
   * @param _deadline The deadline
   * @return _ctx The context
   */
  function _context(
    address _from,
    address _to,
    uint256 _amount,
    address _operator,
    IPolicyHook.TransferKind _kind,
    bytes32 _ref,
    uint256 _deadline
  ) internal view returns (IPolicyHook.TransferContext memory _ctx) {
    // The balances before the move, so rules never call back into the token. Zero for the zero address, which holds
    // nothing. EXECUTED continues with the intent's reference and deadline.
    uint256 _fromBalance = _from == address(0) ? 0 : balanceOf(_from);
    uint256 _toBalance = _to == address(0) ? 0 : balanceOf(_to);
    _ctx = IPolicyHook.TransferContext({
      token: address(this),
      from: _from,
      to: _to,
      id: 0,
      amount: _amount,
      operator: _operator,
      kind: _kind,
      extra: _kind == IPolicyHook.TransferKind.EXECUTED
        ? abi.encode(_fromBalance, _toBalance, _ref, _deadline)
        : abi.encode(_fromBalance, _toBalance)
    });
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
  ) internal pure returns (IPolicyHook.TransferKind _kind) {
    if (_from == address(0)) return IPolicyHook.TransferKind.MINT;
    if (_to == address(0)) return IPolicyHook.TransferKind.BURN;
    _kind = IPolicyHook.TransferKind.TRANSFER;
  }

  /**
   * @notice Installs a hook after checking its attestation
   * @param _newHook The new hook
   */
  function _setHook(
    address _newHook
  ) private {
    if (_newHook == address(0)) revert PolicyGated_ZeroAddress();
    PolicyGatedStorage storage $ = _getPolicyGatedStorage();
    if (!$.registry.isAttested(_newHook, IPolicyRegistry.AttestKind.HOOK)) {
      revert PolicyGated_NotAttested(_newHook, IPolicyRegistry.AttestKind.HOOK);
    }
    // A hook shared by several tokens vets their rules against its own registry, so it must be the token's.
    address _hookRegistry = address(IComplianceHook(_newHook).REGISTRY());
    if (_hookRegistry != address($.registry)) {
      revert PolicyGated_HookRegistryMismatch(_hookRegistry, address($.registry));
    }
    address _oldHook = address($.hook);
    $.hook = IPolicyHook(_newHook);
    emit PolicyHookChanged(_oldHook, _newHook);
  }

  /**
   * @notice Reads and clears the kind announced by `_moveAs`, or infers it
   * @param _from The sender
   * @param _to The receiver
   * @return _kind The kind
   * @return _ref The reference
   * @return _deadline The deadline
   */
  function _consumePending(
    address _from,
    address _to
  ) private returns (IPolicyHook.TransferKind _kind, bytes32 _ref, uint256 _deadline) {
    uint256 _raw = _KIND_SLOT.asUint256().tload();
    if (_raw == 0) return (_inferKind(_from, _to), bytes32(0), 0);
    _kind = IPolicyHook.TransferKind(_raw - 1);
    _ref = _REF_SLOT.asBytes32().tload();
    _deadline = _DEADLINE_SLOT.asUint256().tload();
    _KIND_SLOT.asUint256().tstore(0);
    _REF_SLOT.asBytes32().tstore(bytes32(0));
    _DEADLINE_SLOT.asUint256().tstore(0);
  }

  /**
   * @notice The ERC-7201 storage of the base
   * @return $ The storage pointer
   */
  function _getPolicyGatedStorage() private pure returns (PolicyGatedStorage storage $) {
    assembly ('memory-safe') {
      $.slot := _POLICY_GATED_STORAGE_LOCATION
    }
  }
}
