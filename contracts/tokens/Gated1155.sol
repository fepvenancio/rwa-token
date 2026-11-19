// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC1155Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol';
import {
  ERC1155SupplyUpgradeable
} from '@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol';
import {
  ERC1155URIStorageUpgradeable
} from '@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155URIStorageUpgradeable.sol';
import {ERC1155Utils} from '@openzeppelin/contracts/token/ERC1155/utils/ERC1155Utils.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC7943MultiToken} from 'interfaces/IERC7943MultiToken.sol';
import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';
import {IGated1155} from 'interfaces/IGated1155.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';

import {PolicyGatedCoreUpgradeable} from 'contracts/base/PolicyGatedCoreUpgradeable.sol';

/**
 * @title Gated1155
 * @notice A policy-gated ERC-1155 with a supply and a metadata URI for each token id. Every movement of an amount of an
 *         id is decided by the same hook and rules as the other templates, with `tokenId` set to the id and `amount` to
 *         the amount. Deployed behind a UUPS proxy
 * @dev The core holds the roles, pause, the hook pointer and the upgrade checks; this contract adds the balances'
 *      frozen amounts and the single `_move` path. A batch is its items in order: each item is checked, moved, announced
 *      with its own `TransferSingle` and reported to the policy before the next one is checked (ERC-8473, token rule
 *      10). ERC-1155's receiver callback runs once after the last item, outside the guard, with the state final
 */
contract Gated1155 is ERC1155SupplyUpgradeable, ERC1155URIStorageUpgradeable, PolicyGatedCoreUpgradeable, IGated1155 {
  /**
   * @notice ERC-7201 namespaced storage of the token
   * @param name The collection's name
   * @param symbol The collection's symbol
   * @param frozen The frozen amount of each token id for each account; it may exceed the balance
   * @custom:storage-location erc7201:gated.storage.Gated1155
   */
  struct Gated1155Storage {
    string name;
    string symbol;
    mapping(address _account => mapping(uint256 _tokenId => uint256 _amount)) frozen;
  }

  /// @notice keccak256(abi.encode(uint256(keccak256('gated.storage.Gated1155')) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant _GATED_1155_STORAGE_LOCATION =
    0x99a6bb33e7f2ba3c982ab9d869b98714e59c3a13fe4325b59d537b88a1ff8800;

  /**
   * @notice Locks the implementation; only proxies can be initialized
   * @custom:oz-upgrades-unsafe-allow constructor
   */
  constructor() {
    _disableInitializers();
  }

  /**
   * @notice Initializes a proxy
   * @param _name The collection name
   * @param _symbol The collection symbol
   * @param _admin Holds DEFAULT_ADMIN_ROLE and grants every other role; ends up with the timelock
   * @param _guardian The guardian multisig. Can pause and, through the timelock's CANCELLER_ROLE, veto; nothing else
   * @param _registry The policy registry, fixed after initialization
   * @param _hook The initial policy hook; must be attested as HOOK and name the same registry
   * @param _initialRules The rule set installed on the hook for this token in the same call; empty installs none
   */
  function initialize(
    string memory _name,
    string memory _symbol,
    address _admin,
    address _guardian,
    address _registry,
    address _hook,
    IComplianceRule[] memory _initialRules
  ) external initializer {
    __ERC1155_init('');
    __ERC1155Supply_init();
    __ERC1155URIStorage_init();
    Gated1155Storage storage $ = _getGated1155Storage();
    $.name = _name;
    $.symbol = _symbol;
    __PolicyGatedCore_init(_admin, _guardian, _registry, _hook, _initialRules);
  }

  /// @inheritdoc IGated1155
  function mint(
    address _to,
    uint256 _tokenId,
    uint256 _amount
  ) external onlyRole(MINTER_ROLE) {
    _mint(_to, _tokenId, _amount, '');
  }

  /// @inheritdoc IGated1155
  function burn(
    address _from,
    uint256 _tokenId,
    uint256 _amount
  ) external onlyRole(BURNER_ROLE) {
    if (_from == address(0)) revert ERC1155InvalidSender(address(0));
    _releaseFrozen(_from, _tokenId, _amount);
    // An enforcement burn takes tokens without the holder directing it, so the policy sees FORCED with a zero receiver
    // (ERC-8473, transfer kinds).
    _move(_from, address(0), _tokenId, _amount, IERC8473Policy.TransferKind.FORCED);
  }

  /// @inheritdoc IGated1155
  function setURI(
    uint256 _tokenId,
    string calldata _uri
  ) external onlyRole(AGENT_ROLE) {
    _setURI(_tokenId, _uri);
  }

  /// @inheritdoc IERC7943MultiToken
  function forcedTransfer(
    address _from,
    address _to,
    uint256 _tokenId,
    uint256 _amount
  ) external onlyRole(AGENT_ROLE) returns (bool _result) {
    if (_to == address(0)) revert ERC1155InvalidReceiver(address(0));
    if (_from == address(0)) revert ERC1155InvalidSender(address(0));
    _releaseFrozen(_from, _tokenId, _amount);
    _move(_from, _to, _tokenId, _amount, IERC8473Policy.TransferKind.FORCED);
    // Emitted after the hook's afterTransfer: re-entry is blocked by `_move`'s guard and the hook is attested.
    // slither-disable-start reentrancy-events
    emit ForcedTransfer(_from, _to, _tokenId, _amount);
    emit ForcedTransferBy(_from, _to, _tokenId, _amount, _msgSender());
    // slither-disable-end reentrancy-events
    // ERC-1155 has a non-standard transfer function follow the receiver rules too. Last, with the state final.
    ERC1155Utils.checkOnERC1155Received(_msgSender(), _from, _to, _tokenId, _amount, '');
    _result = true;
  }

  /// @inheritdoc IERC7943MultiToken
  function setFrozenTokens(
    address _account,
    uint256 _tokenId,
    uint256 _amount
  ) external onlyRole(AGENT_ROLE) returns (bool _result) {
    _getGated1155Storage().frozen[_account][_tokenId] = _amount;
    emit Frozen(_account, _tokenId, _amount);
    _result = true;
  }

  /// @inheritdoc IGated1155
  function name() external view returns (string memory _name) {
    _name = _getGated1155Storage().name;
  }

  /// @inheritdoc IGated1155
  function symbol() external view returns (string memory _symbol) {
    _symbol = _getGated1155Storage().symbol;
  }

  /// @inheritdoc IERC7943MultiToken
  function canSend(
    address _account
  ) external view returns (bool _allowed) {
    _allowed = _accountAllowed(_account, true);
  }

  /// @inheritdoc IERC7943MultiToken
  function canReceive(
    address _account
  ) external view returns (bool _allowed) {
    _allowed = _accountAllowed(_account, false);
  }

  /// @inheritdoc IERC7943MultiToken
  function getFrozenTokens(
    address _account,
    uint256 _tokenId
  ) external view returns (uint256 _amount) {
    _amount = _getGated1155Storage().frozen[_account][_tokenId];
  }

  /**
   * @inheritdoc IERC7943MultiToken
   * @dev ERC-7943 says this MUST NOT return false for a balance check and MUST return false when a frozen amount keeps
   *      the amount from the unfrozen balance, so a shortfall counts here only while a frozen amount of that id is in
   *      the way. With nothing frozen an amount above the balance reads true if the policy accepts it, and the write
   *      reverts with `ERC1155InsufficientBalance`. `canTransferWithReason` does not make that exception
   */
  function canTransfer(
    address _from,
    address _to,
    uint256 _tokenId,
    uint256 _amount
  ) external view returns (bool _allowed) {
    // Compares a reason code with a constant, not a balance.
    // slither-disable-next-line incorrect-equality
    _allowed = _canTransfer(_from, _to, _tokenId, _amount, false) == Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IGated1155
  function canTransferWithReason(
    address _from,
    address _to,
    uint256 _tokenId,
    uint256 _amount
  ) external view returns (bool _ok, bytes32 _reason) {
    _reason = _canTransfer(_from, _to, _tokenId, _amount, true);
    // Compares a reason code with a constant, not a balance.
    // slither-disable-next-line incorrect-equality
    _ok = _reason == Reasons.TRANSFER_OK;
  }

  /// @inheritdoc ERC1155Upgradeable
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override(ERC1155Upgradeable, PolicyGatedCoreUpgradeable, IERC165) returns (bool _supported) {
    _supported = _interfaceId == type(IGated1155).interfaceId || _interfaceId == type(IERC7943MultiToken).interfaceId
      || ERC1155Upgradeable.supportsInterface(_interfaceId)
      || PolicyGatedCoreUpgradeable.supportsInterface(_interfaceId);
  }

  /// @inheritdoc ERC1155URIStorageUpgradeable
  function uri(
    uint256 _tokenId
  ) public view override(ERC1155Upgradeable, ERC1155URIStorageUpgradeable) returns (string memory _uri) {
    _uri = ERC1155URIStorageUpgradeable.uri(_tokenId);
  }

  /// @inheritdoc ITemplated
  function templateId() public pure override returns (bytes32 _id) {
    _id = keccak256('Gated1155');
  }

  /**
   * @notice The route ERC-1155's transfers and `_mint` take into `_move`, one item at a time, with the kind the
   *         addresses imply
   * @dev ERC-1155 checks approval before it gets here. Each item is a whole movement before the next one starts, so a
   *      later item sees the balances the earlier ones left, and an id named twice is two movements. An empty batch
   *      makes none. The parent would apply the batch and emit one `TransferBatch`; here each item emits its own
   *      `TransferSingle`, which ERC-1155 allows
   * @param _from The sender, or address(0) on mint
   * @param _to The receiver, or address(0) on burn
   * @param _ids The token ids, in order
   * @param _values The amounts, in the same order
   */
  function _update(
    address _from,
    address _to,
    uint256[] memory _ids,
    uint256[] memory _values
  ) internal override(ERC1155Upgradeable, ERC1155SupplyUpgradeable) {
    if (_ids.length != _values.length) revert ERC1155InvalidArrayLength(_ids.length, _values.length);
    IERC8473Policy.TransferKind _kind = _inferKind(_from, _to);
    for (uint256 _i = 0; _i < _ids.length; ++_i) {
      _move(_from, _to, _ids[_i], _values[_i], _kind);
    }
  }

  /**
   * @notice The single path every movement of one token id takes: mechanical checks and hook, the move, then
   *         `afterTransfer`
   * @dev Guarded against reentrancy, so a hook or rule calling back into any transfer function reverts. The supply of
   *      the id changes inside the same move, so it is current when `afterTransfer` runs
   * @param _from The sender, or address(0) on mint
   * @param _to The receiver, or address(0) on burn
   * @param _tokenId The token id
   * @param _amount The amount
   * @param _kind The kind the hook sees
   */
  function _move(
    address _from,
    address _to,
    uint256 _tokenId,
    uint256 _amount,
    IERC8473Policy.TransferKind _kind
  ) private nonReentrant {
    IERC8473Policy.TransferContext memory _ctx = _context(_from, _to, _tokenId, _amount, _msgSender(), _kind);

    // Read once: the hook that approves the movement is the hook that sees `afterTransfer`.
    IERC8473Policy _hook = _policy();
    bytes32 _reason = _check(_ctx, _hook, true);
    if (_reason != Reasons.TRANSFER_OK) {
      // The token's own balance checks revert with the standard's error for an amount within the balance, which a frozen
      // amount keeps from moving, and with ERC-1155's for an amount above it; every policy decision keeps the typed
      // rejection that carries its reason, even one that borrows the code without a shortfall behind it.
      // Compares a reason code with a constant, not a balance.
      // slither-disable-next-line incorrect-equality
      if (_reason == Reasons.INSUFFICIENT_UNFROZEN && _from != address(0) && _availableToMove(_ctx) < _amount) {
        uint256 _balance = balanceOf(_from, _tokenId);
        if (_amount > _balance) revert ERC1155InsufficientBalance(_from, _balance, _amount, _tokenId);
        revert ERC7943InsufficientUnfrozenBalance(_from, _tokenId, _amount, _unfrozenBalance(_from, _tokenId));
      }
      revert ERC8473PolicyRejected(_reason);
    }

    uint256[] memory _ids = new uint256[](1);
    uint256[] memory _values = new uint256[](1);
    _ids[0] = _tokenId;
    _values[0] = _amount;
    super._update(_from, _to, _ids, _values);

    if (_hook.wantsAfterTransfer()) _hook.afterTransfer(_ctx);
  }

  /**
   * @notice Lowers an account's frozen amount of a token id by the part of an enforcement action that comes out of it
   * @dev The unfrozen balance is what an action can take without touching the frozen amount; only the rest of `_amount`
   *      is released, so a frozen amount above the balance (ERC-7943 allows it) loses exactly what leaves. Emits `Frozen`
   *      before the token's `TransferSingle`, as ERC-7943 requires
   * @param _account The account losing tokens
   * @param _tokenId The token id
   * @param _amount The amount it loses
   */
  function _releaseFrozen(
    address _account,
    uint256 _tokenId,
    uint256 _amount
  ) private {
    uint256 _balance = balanceOf(_account, _tokenId);
    if (_amount > _balance) revert ERC1155InsufficientBalance(_account, _balance, _amount, _tokenId);
    Gated1155Storage storage $ = _getGated1155Storage();
    uint256 _frozen = $.frozen[_account][_tokenId];
    uint256 _unfrozen = _balance > _frozen ? _balance - _frozen : 0;
    if (_amount > _unfrozen) {
      uint256 _newFrozen = _frozen - (_amount - _unfrozen);
      $.frozen[_account][_tokenId] = _newFrozen;
      emit Frozen(_account, _tokenId, _newFrozen);
    }
  }

  /**
   * @notice The pre-flight behind `canTransfer` and `canTransferWithReason`
   * @dev Simulates a holder-driven movement of one item: the operator is `_from`, which is zero for a mint, so the
   *      answer does not depend on who asks (ERC-8473, check rule 3). It models TRANSFER, MINT and BURN. `burn` here is
   *      the burner's enforcement action, a FORCED movement that no pre-flight predicts, so a burn asked about is
   *      answered as a holder's would be
   * @param _from The sender, or address(0) for a mint
   * @param _to The receiver, or address(0) for a burn
   * @param _tokenId The token id
   * @param _amount The amount
   * @param _balanceCounts False to leave a shortfall that is only the balance's to ERC-1155 (see `_check`)
   * @return _reason The reason code
   */
  function _canTransfer(
    address _from,
    address _to,
    uint256 _tokenId,
    uint256 _amount,
    bool _balanceCounts
  ) private view returns (bytes32 _reason) {
    // A mint to the zero address cannot happen, so the hook is not asked about one.
    if (_from == address(0) && _to == address(0)) return Reasons.ZERO_RECEIVER;
    _reason = _check(_context(_from, _to, _tokenId, _amount, _from, _inferKind(_from, _to)), _policy(), _balanceCounts);
  }

  /**
   * @notice Mechanical checks then the hook decision, shared by `_move` and the pre-flights
   * @dev The amount must fit in the unfrozen balance of the id, which is zero when the frozen amount is the larger
   *      (ERC-7943). A FORCED movement may take frozen tokens, since `_releaseFrozen` lowers the frozen amount by the
   *      part that comes out of it, but never more than the balance. With `_balanceCounts` false a shortfall counts
   *      only while a frozen amount is in the way: ERC-7943 leaves a plain balance shortfall to the base standard. The
   *      policy is asked through `_ask`: one that cannot be asked is `CHECK_UNAVAILABLE`
   * @param _ctx The movement context
   * @param _hook The hook to consult, read once by the caller
   * @param _balanceCounts Whether a balance shortfall with no frozen amount in the way counts as a failure
   * @return _reason The reason code
   */
  function _check(
    IERC8473Policy.TransferContext memory _ctx,
    IERC8473Policy _hook,
    bool _balanceCounts
  ) private view returns (bytes32 _reason) {
    if (paused() && _ctx.kind != IERC8473Policy.TransferKind.FORCED) return Reasons.PAUSED;

    if (_ctx.from != address(0) && _availableToMove(_ctx) < _ctx.amount) {
      if (_balanceCounts || _getGated1155Storage().frozen[_ctx.from][_ctx.tokenId] > 0) {
        return Reasons.INSUFFICIENT_UNFROZEN;
      }
    }

    if (address(_hook) == address(0)) return Reasons.NO_HOOK;
    _reason = _ask(address(_hook), abi.encodeCall(IERC8473Policy.checkTransfer, (_ctx)));
  }

  /**
   * @notice Builds a movement context for one token id
   * @param _from The sender
   * @param _to The receiver
   * @param _tokenId The token id
   * @param _amount The amount
   * @param _operator The account driving the movement
   * @param _kind The movement kind
   * @return _ctx The context
   */
  function _context(
    address _from,
    address _to,
    uint256 _tokenId,
    uint256 _amount,
    address _operator,
    IERC8473Policy.TransferKind _kind
  ) private view returns (IERC8473Policy.TransferContext memory _ctx) {
    // The balances of this id before the move, so rules never call back into the token. The zero address holds nothing.
    _ctx = IERC8473Policy.TransferContext({
      token: address(this),
      from: _from,
      to: _to,
      tokenId: _tokenId,
      amount: _amount,
      operator: _operator,
      kind: _kind,
      data: abi.encode(balanceOf(_from, _tokenId), balanceOf(_to, _tokenId))
    });
  }

  /**
   * @notice The amount of the id a movement's sender can move: the whole balance for FORCED, else the unfrozen part
   * @param _ctx The movement context
   * @return _available The amount the sender can move
   */
  function _availableToMove(
    IERC8473Policy.TransferContext memory _ctx
  ) private view returns (uint256 _available) {
    // FORCED, the token's enforcement authority, may take frozen tokens. Compares movement kinds, not balances.
    // slither-disable-next-line incorrect-equality
    _available = _ctx.kind == IERC8473Policy.TransferKind.FORCED
      ? balanceOf(_ctx.from, _ctx.tokenId)
      : _unfrozenBalance(_ctx.from, _ctx.tokenId);
  }

  /**
   * @notice The part of an account's balance of a token id that is not frozen; zero when the frozen amount is the larger
   * @param _account The account
   * @param _tokenId The token id
   * @return _unfrozen The unfrozen balance
   */
  function _unfrozenBalance(
    address _account,
    uint256 _tokenId
  ) private view returns (uint256 _unfrozen) {
    uint256 _balance = balanceOf(_account, _tokenId);
    uint256 _frozen = _getGated1155Storage().frozen[_account][_tokenId];
    _unfrozen = _balance > _frozen ? _balance - _frozen : 0;
  }

  /**
   * @notice The ERC-7201 storage of the token
   * @return $ The storage pointer
   */
  function _getGated1155Storage() private pure returns (Gated1155Storage storage $) {
    assembly ('memory-safe') {
      $.slot := _GATED_1155_STORAGE_LOCATION
    }
  }
}
