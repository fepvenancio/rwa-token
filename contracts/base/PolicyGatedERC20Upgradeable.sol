// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
  ERC20PermitUpgradeable
} from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IERC7943Fungible} from 'interfaces/IERC7943Fungible.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';

import {PolicyGatedCoreUpgradeable} from 'contracts/base/PolicyGatedCoreUpgradeable.sol';

/**
 * @title PolicyGatedERC20Upgradeable
 * @notice Base for every fungible gated template. Owns accounting and the enforcement primitives that move amounts
 *         (mint, burn, forced transfer, freeze) over the shared core, which holds the roles, pause, the guardian and the
 *         hook pointer. Every policy decision is delegated to the hook through the single `_move` path; the base holds
 *         no business logic about who, where or when
 * @dev DEFAULT_ADMIN_ROLE is the timelock and administers every role. GUARDIAN_ROLE can only stop things: it pauses,
 *      and cannot unpause, change the hook, grant roles or upgrade
 */
abstract contract PolicyGatedERC20Upgradeable is ERC20PermitUpgradeable, PolicyGatedCoreUpgradeable, IPolicyGated {
  /**
   * @notice ERC-7201 namespaced storage of the base
   * @param frozen The absolute frozen amount of each account; it may exceed the balance (ERC-7943)
   * @custom:storage-location erc7201:gated.storage.PolicyGatedERC20
   */
  struct PolicyGatedStorage {
    mapping(address _user => uint256 _amount) frozen;
  }

  /// @notice keccak256(abi.encode(uint256(keccak256('gated.storage.PolicyGatedERC20')) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _POLICY_GATED_STORAGE_LOCATION =
    0xe8c11567602593a5bc8df6eb5a119138618a3fad68d46d33c073939016673d00;

  /// @notice The amount of the mint a template's `max*` and eligibility checks probe: above any minimum position up to
  ///         this value
  uint256 internal constant _MINT_PROBE = type(uint128).max;

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
    if (_from == address(0)) revert ERC20InvalidSender(address(0));
    _releaseFrozen(_from, _amount);
    // An enforcement burn takes tokens without the holder directing it, so the policy sees FORCED with a zero receiver
    // (ERC-8473, transfer kinds). BURN is the holder's own, such as a vault redemption.
    _move(_from, address(0), _amount, IERC8473Policy.TransferKind.FORCED, bytes32(0), 0);
  }

  /// @inheritdoc IPolicyGated
  function canTransferWithReason(
    address _from,
    address _to,
    uint256 _amount
  ) external view returns (bool _ok, bytes32 _reason) {
    _reason = _canTransfer(_from, _to, _amount);
    // Compares a reason code with a constant, not a balance.
    // slither-disable-next-line incorrect-equality
    _ok = _reason == Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IERC7943Fungible
  function canReceive(
    address _account
  ) external view returns (bool _allowed) {
    _allowed = _accountAllowed(_account, false);
  }

  /// @inheritdoc IERC7943Fungible
  function canSend(
    address _account
  ) external view returns (bool _allowed) {
    _allowed = _accountAllowed(_account, true);
  }

  /**
   * @inheritdoc IERC7943Fungible
   * @dev ERC-7943 says this MUST NOT return false for a balance check and MUST return false when a frozen amount keeps
   *      the amount from the unfrozen balance, so a shortfall counts here only while a frozen amount is in the way.
   *      With nothing frozen on `_from` an amount above the balance reads true if the policy accepts it, and the write
   *      reverts with `ERC20InsufficientBalance`. `canTransferWithReason` does not make that exception, so it says the
   *      write would revert. Neither depends on who asks: the operator simulated is `_from` (ERC-8473, check rule 3)
   */
  function canTransfer(
    address _from,
    address _to,
    uint256 _amount
  ) external view returns (bool _allowed) {
    // Compares a reason code with a constant, not a balance.
    // slither-disable-next-line incorrect-equality
    _allowed = _canTransfer(_from, _to, _amount, false) == Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IERC7943Fungible
  function forcedTransfer(
    address _from,
    address _to,
    uint256 _amount
  ) public virtual onlyRole(AGENT_ROLE) returns (bool _result) {
    _releaseFrozen(_from, _amount);
    _moveAs(_from, _to, _amount, IERC8473Policy.TransferKind.FORCED, bytes32(0), 0);
    // Emitted after the hook's afterTransfer: re-entry is blocked by `_move`'s guard and the hook is attested.
    // slither-disable-start reentrancy-events
    emit ForcedTransfer(_from, _to, _amount);
    emit ForcedTransferBy(_from, _to, _amount, _msgSender());
    // slither-disable-end reentrancy-events
    _result = true;
  }

  /// @inheritdoc IERC7943Fungible
  function setFrozenTokens(
    address _account,
    uint256 _amount
  ) public virtual onlyRole(AGENT_ROLE) returns (bool _result) {
    _getPolicyGatedStorage().frozen[_account] = _amount;
    emit Frozen(_account, _amount);
    _result = true;
  }

  /// @inheritdoc IERC7943Fungible
  function getFrozenTokens(
    address _account
  ) public view returns (uint256 _amount) {
    _amount = _getPolicyGatedStorage().frozen[_account];
  }

  /// @inheritdoc PolicyGatedCoreUpgradeable
  function supportsInterface(
    bytes4 _interfaceId
  ) public view virtual override(PolicyGatedCoreUpgradeable, IERC165) returns (bool _supported) {
    _supported = _interfaceId == type(IPolicyGated).interfaceId || _interfaceId == type(IERC7943Fungible).interfaceId
      || _interfaceId == type(IERC20).interfaceId || _interfaceId == type(IERC20Permit).interfaceId
      || super.supportsInterface(_interfaceId);
  }

  /**
   * @notice The route OpenZeppelin's `_transfer`, `_mint` and `_burn` take into `_move`, with the kind the addresses imply
   * @param _from The sender, or address(0) on mint
   * @param _to The receiver, or address(0) on burn
   * @param _value The amount
   */
  function _update(
    address _from,
    address _to,
    uint256 _value
  ) internal virtual override {
    _move(_from, _to, _value, _inferKind(_from, _to), bytes32(0), 0);
  }

  /**
   * @notice The single path every balance movement takes: mechanical checks and hook, balances, then `afterTransfer`
   * @dev Guarded against reentrancy, so a hook or rule calling back into any transfer function reverts. A template that
   *      must act on every movement extends this function: `_update` does not see FORCED or EXECUTED movements
   * @param _from The sender, or address(0) on mint
   * @param _to The receiver, or address(0) on burn
   * @param _value The amount
   * @param _kind The kind the hook sees
   * @param _ref The reference of an executed intent, otherwise zero
   * @param _deadline The deadline of an executed intent, otherwise zero
   */
  function _move(
    address _from,
    address _to,
    uint256 _value,
    IERC8473Policy.TransferKind _kind,
    bytes32 _ref,
    uint256 _deadline
  ) internal virtual nonReentrant {
    IERC8473Policy.TransferContext memory _ctx = _context(_from, _to, _value, _msgSender(), _kind, _ref, _deadline);

    // Read once: the hook that approves the movement is the hook that sees `afterTransfer`.
    IERC8473Policy _hook = _policy();
    bytes32 _reason = _check(_ctx, _hook);
    if (_reason != Reasons.TRANSFER_OK) {
      // The token's own balance checks revert with the standard's error for an amount within the balance, which a frozen
      // amount keeps from moving, and with the base's for an amount above it; every policy decision keeps the typed
      // rejection that carries its reason, even one that borrows the code without a shortfall behind it.
      // Compares a reason code with a constant, not a balance.
      // slither-disable-next-line incorrect-equality
      if (_reason == Reasons.INSUFFICIENT_UNFROZEN && _from != address(0) && _availableToMove(_ctx) < _value) {
        uint256 _balance = balanceOf(_from);
        if (_value > _balance) revert ERC20InsufficientBalance(_from, _balance, _value);
        revert ERC7943InsufficientUnfrozenBalance(_from, _value, _unfrozenBalance(_from));
      }
      revert ERC8473PolicyRejected(_reason);
    }

    super._update(_from, _to, _value);

    if (_hook.wantsAfterTransfer()) _hook.afterTransfer(_ctx);
  }

  /**
   * @notice Moves tokens announcing a kind that cannot be inferred from the addresses (FORCED, EXECUTED)
   * @dev Keeps both zero-address checks of OpenZeppelin's `_transfer`, which it does not call: a move to zero would burn
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
    IERC8473Policy.TransferKind _kind,
    bytes32 _ref,
    uint256 _deadline
  ) internal {
    if (_from == address(0)) revert ERC20InvalidSender(address(0));
    if (_to == address(0)) revert ERC20InvalidReceiver(address(0));
    _move(_from, _to, _amount, _kind, _ref, _deadline);
  }

  /**
   * @notice Mints announcing a kind that cannot be inferred from the addresses: FORCED with `from == address(0)` is an
   *         enforcement mint (brief §5), exempt from pause and the holder cap but still identity-checked on `to`
   * @dev Kept apart from `_moveAs`, which never sees `from == address(0)`. Keeps the zero-address check of OpenZeppelin's
   *      `_mint`, which it does not call
   * @param _to The receiver
   * @param _amount The amount
   * @param _kind The announced kind
   */
  function _mintAs(
    address _to,
    uint256 _amount,
    IERC8473Policy.TransferKind _kind
  ) internal {
    if (_to == address(0)) revert ERC20InvalidReceiver(address(0));
    _move(address(0), _to, _amount, _kind, bytes32(0), 0);
  }

  /**
   * @notice Lowers an account's frozen amount by the part of an enforcement action that comes out of it
   * @dev The unfrozen balance is what an action can take without touching the frozen amount; only the rest of `_amount`
   *      is released, so a frozen amount above the balance (ERC-7943 allows it) loses exactly what leaves. Emits `Frozen`
   *      before the token `Transfer`, as ERC-7943 requires
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
    uint256 _frozen = $.frozen[_account];
    uint256 _unfrozen = _balance > _frozen ? _balance - _frozen : 0;
    if (_amount > _unfrozen) {
      uint256 _newFrozen = _frozen - (_amount - _unfrozen);
      $.frozen[_account] = _newFrozen;
      emit Frozen(_account, _newFrozen);
    }
  }

  /**
   * @notice The part of an account's balance that is not frozen; zero when the frozen amount is the larger
   * @param _account The account
   * @return _unfrozen The unfrozen balance
   */
  function _unfrozenBalance(
    address _account
  ) internal view returns (uint256 _unfrozen) {
    uint256 _balance = balanceOf(_account);
    uint256 _frozen = _getPolicyGatedStorage().frozen[_account];
    _unfrozen = _balance > _frozen ? _balance - _frozen : 0;
  }

  /**
   * @notice The pre-flight behind `canTransferWithReason`, shared with templates (e.g. vault `max*`)
   * @dev Simulates a holder-driven movement: the operator is `_from`, which is zero for a mint, so the answer does not
   *      depend on who asks (ERC-8473, check rule 3). Every shortfall counts
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
    _reason = _canTransfer(_from, _to, _amount, true);
  }

  /**
   * @notice The pre-flight behind `canTransfer` and `canTransferWithReason`
   * @dev Simulates a holder-driven movement: the operator is `_from`, which is zero for a mint, so the answer does not
   *      depend on who asks (ERC-8473, check rule 3)
   * @param _from The sender, or address(0) for a mint
   * @param _to The receiver, or address(0) for a burn
   * @param _amount The amount
   * @param _balanceCounts False to leave a shortfall that is only the balance's to the base standard (see `_check`)
   * @return _reason The reason code
   */
  function _canTransfer(
    address _from,
    address _to,
    uint256 _amount,
    bool _balanceCounts
  ) internal view returns (bytes32 _reason) {
    // A mint to the zero address cannot happen, so the hook is not asked about one.
    if (_from == address(0) && _to == address(0)) return Reasons.ZERO_RECEIVER;
    _reason =
      _check(_context(_from, _to, _amount, _from, _inferKind(_from, _to), bytes32(0), 0), _policy(), _balanceCounts);
  }

  /**
   * @notice The pre-flight of a mint to `_receiver`, for templates' `max*` and eligibility checks
   * @dev The amount is `_MINT_PROBE`: it is not zero, so a rule that caps holders sees a new holder, and it is above
   *      any minimum position up to `type(uint128).max`, so such a minimum does not read as a block (one wei would; a
   *      minimum set above that would refuse the probe). A rule that bounds the size of a position, such as a supply
   *      cap or a maximum balance, would refuse it and zero the `max*` that use it. The operator is the caller, as in
   *      `_canTransfer`
   * @param _receiver The account that would receive the shares
   * @return _reason TRANSFER_OK, or the reason a mint to `_receiver` would be rejected
   */
  function _mintProbe(
    address _receiver
  ) internal view returns (bytes32 _reason) {
    _reason = _canTransfer(address(0), _receiver, _MINT_PROBE);
  }

  /**
   * @notice Mechanical checks then the hook decision, shared by `_update` and the pre-flights
   * @param _ctx The movement context
   * @param _hook The hook to consult, read once by the caller
   * @return _reason The reason code
   */
  function _check(
    IERC8473Policy.TransferContext memory _ctx,
    IERC8473Policy _hook
  ) internal view returns (bytes32 _reason) {
    _reason = _check(_ctx, _hook, true);
  }

  /**
   * @notice Mechanical checks then the hook decision, with the choice of whether a balance shortfall counts
   * @dev The amount must fit in the unfrozen balance, which is zero when the frozen amount is the larger (ERC-7943). A
   *      FORCED movement (a forced transfer or the burner's enforcement burn) may take frozen tokens, since
   *      `_releaseFrozen` lowers the frozen amount by the part that comes out of it, but never more than the balance:
   *      that bound holds for the write and for the pre-flights that count every shortfall. With `_balanceCounts` false
   *      a shortfall counts only while a frozen amount is in the way: ERC-7943 leaves a plain balance shortfall to the
   *      base standard, whose error the write reverts with. No pre-flight simulates FORCED, so none depends on who
   *      asks. The policy is asked through `_ask`: one that cannot be asked is `CHECK_UNAVAILABLE`
   * @param _ctx The movement context
   * @param _hook The hook to consult, read once by the caller
   * @param _balanceCounts Whether a balance shortfall with no frozen amount in the way counts as a failure
   * @return _reason The reason code
   */
  function _check(
    IERC8473Policy.TransferContext memory _ctx,
    IERC8473Policy _hook,
    bool _balanceCounts
  ) internal view returns (bytes32 _reason) {
    if (paused() && _ctx.kind != IERC8473Policy.TransferKind.FORCED) return Reasons.PAUSED;

    if (_ctx.from != address(0) && _availableToMove(_ctx) < _ctx.amount) {
      if (_balanceCounts || _getPolicyGatedStorage().frozen[_ctx.from] > 0) {
        return Reasons.INSUFFICIENT_UNFROZEN;
      }
    }

    if (address(_hook) == address(0)) return Reasons.NO_HOOK;
    _reason = _ask(address(_hook), abi.encodeCall(IERC8473Policy.checkTransfer, (_ctx)));
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
    IERC8473Policy.TransferKind _kind,
    bytes32 _ref,
    uint256 _deadline
  ) internal view returns (IERC8473Policy.TransferContext memory _ctx) {
    // The balances before the move, so rules never call back into the token. Zero for the zero address, which holds
    // nothing. EXECUTED continues with the intent's reference and deadline.
    uint256 _fromBalance = _from == address(0) ? 0 : balanceOf(_from);
    uint256 _toBalance = _to == address(0) ? 0 : balanceOf(_to);
    _ctx = IERC8473Policy.TransferContext({
      token: address(this),
      from: _from,
      to: _to,
      tokenId: 0,
      amount: _amount,
      operator: _operator,
      kind: _kind,
      data: _kind == IERC8473Policy.TransferKind.EXECUTED
        ? abi.encode(_fromBalance, _toBalance, _ref, _deadline)
        : abi.encode(_fromBalance, _toBalance)
    });
  }

  /**
   * @notice How much of the sender's balance a movement may take: all of it for an enforcement action, the unfrozen part
   *         for everything else
   * @param _ctx The movement context
   * @return _available The amount the sender can move
   */
  function _availableToMove(
    IERC8473Policy.TransferContext memory _ctx
  ) private view returns (uint256 _available) {
    // FORCED, the token's enforcement authority, may take frozen tokens. Compares movement kinds, not balances.
    // slither-disable-next-line incorrect-equality
    _available = _ctx.kind == IERC8473Policy.TransferKind.FORCED ? balanceOf(_ctx.from) : _unfrozenBalance(_ctx.from);
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
