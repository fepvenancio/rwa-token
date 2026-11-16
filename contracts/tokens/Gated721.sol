// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
  ERC721URIStorageUpgradeable
} from '@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC7943NonFungible} from 'interfaces/IERC7943NonFungible.sol';
import {IERC8473Policy} from 'interfaces/IERC8473Policy.sol';
import {IGated721} from 'interfaces/IGated721.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';

import {PolicyGatedCoreUpgradeable} from 'contracts/base/PolicyGatedCoreUpgradeable.sol';

/**
 * @title Gated721
 * @notice A policy-gated ERC-721 with a metadata URI per token. Every movement of a token is decided by the same hook
 *         and rules as the fungible templates, with `tokenId` set to the token and `amount` to one. Deployed behind a UUPS
 *         proxy
 * @dev The core holds the roles, pause, the hook pointer and the upgrade checks; this contract adds the tokens, their
 *      freezes and the single `_move` path. ERC-721's own checks (existence, ownership, approval) come first, then
 *      pause, the freeze, the hook, the move and `afterTransfer`
 */
// No receive or payable function, and upgradeToAndCall rejects value: no ETH can enter.
// aderyn-ignore-next-line(contract-locks-ether)
contract Gated721 is ERC721URIStorageUpgradeable, PolicyGatedCoreUpgradeable, IGated721 {
  /**
   * @notice ERC-7201 namespaced storage of the token
   * @param frozen The frozen status of each token for each account; it may name a token the account does not hold
   * @custom:storage-location erc7201:gated.storage.Gated721
   */
  struct Gated721Storage {
    mapping(address _account => mapping(uint256 _tokenId => bool _frozen)) frozen;
  }

  /// @notice keccak256(abi.encode(uint256(keccak256('gated.storage.Gated721')) - 1)) & ~bytes32(uint256(0xff))
  // Read in assembly by the ERC-7201 accessor.
  // aderyn-ignore-next-line(unused-state-variable)
  bytes32 private constant _GATED_721_STORAGE_LOCATION =
    0xe2e6a0763355f0c539395516a687d1cc0bc64d7e84611f8f6d2274edd1a6f900;

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
    __ERC721_init(_name, _symbol);
    __ERC721URIStorage_init();
    __PolicyGatedCore_init(_admin, _guardian, _registry, _hook, _initialRules);
  }

  /// @inheritdoc IGated721
  function mint(
    address _to,
    uint256 _tokenId,
    string calldata _uri
  ) external onlyRole(MINTER_ROLE) {
    // ERC-721's `_mint` reports an existing token only after the update, which would ask the hook about a transfer.
    if (_ownerOf(_tokenId) != address(0)) revert ERC721InvalidSender(address(0));
    // A plain mint on purpose: issuance makes no receiver callback, so nothing runs between the move and the URI.
    // aderyn-ignore-next-line(unsafe-oz-erc721-mint)
    _mint(_to, _tokenId);
    _setTokenURI(_tokenId, _uri);
  }

  /// @inheritdoc IGated721
  function burn(
    uint256 _tokenId
  ) external onlyRole(BURNER_ROLE) {
    address _owner = _requireOwned(_tokenId);
    _releaseFrozen(_owner, _tokenId);
    // An enforcement burn takes the token without its owner directing it, so the policy sees FORCED with a zero
    // receiver (ERC-8473, transfer kinds). `_move` burns through ERC-721's `_update`, as `_burn` would.
    _move(_owner, address(0), _tokenId, IERC8473Policy.TransferKind.FORCED);
  }

  /// @inheritdoc IGated721
  function setTokenURI(
    uint256 _tokenId,
    string calldata _uri
  ) external onlyRole(AGENT_ROLE) {
    // Called for its revert on a token that does not exist; the owner it returns is not needed.
    // aderyn-ignore-next-line(unchecked-return)
    _requireOwned(_tokenId);
    _setTokenURI(_tokenId, _uri);
  }

  /// @inheritdoc IERC7943NonFungible
  function forcedTransfer(
    address _from,
    address _to,
    uint256 _tokenId
  ) external onlyRole(AGENT_ROLE) returns (bool _result) {
    if (_to == address(0)) revert ERC721InvalidReceiver(address(0));
    address _owner = _requireOwned(_tokenId);
    if (_owner != _from) revert ERC721IncorrectOwner(_from, _tokenId, _owner);
    _releaseFrozen(_from, _tokenId);
    _move(_from, _to, _tokenId, IERC8473Policy.TransferKind.FORCED);
    // Emitted after the hook's afterTransfer: re-entry is blocked by `_move`'s guard and the hook is attested.
    // slither-disable-start reentrancy-events
    emit ForcedTransfer(_from, _to, _tokenId);
    emit ForcedTransferBy(_from, _to, _tokenId, _msgSender());
    // slither-disable-end reentrancy-events
    _result = true;
  }

  /// @inheritdoc IERC7943NonFungible
  function setFrozenTokens(
    address _account,
    uint256 _tokenId,
    bool _frozenStatus
  ) external onlyRole(AGENT_ROLE) returns (bool _result) {
    _getGated721Storage().frozen[_account][_tokenId] = _frozenStatus;
    emit Frozen(_account, _tokenId, _frozenStatus);
    _result = true;
  }

  /// @inheritdoc IERC7943NonFungible
  function canSend(
    address _account
  ) external view returns (bool _allowed) {
    _allowed = _accountAllowed(_account, true);
  }

  /// @inheritdoc IERC7943NonFungible
  function canReceive(
    address _account
  ) external view returns (bool _allowed) {
    _allowed = _accountAllowed(_account, false);
  }

  /// @inheritdoc IERC7943NonFungible
  function getFrozenTokens(
    address _account,
    uint256 _tokenId
  ) external view returns (bool _frozenStatus) {
    _frozenStatus = _getGated721Storage().frozen[_account][_tokenId];
  }

  /**
   * @inheritdoc IERC7943NonFungible
   * @dev ERC-7943 says this MUST NOT return false for non-permissioned checks such as a balance or an allowance, so
   *      ownership and approval are left to ERC-721, whose errors the write reverts with. `canTransferWithReason`
   *      counts ownership
   */
  function canTransfer(
    address _from,
    address _to,
    uint256 _tokenId
  ) external view returns (bool _allowed) {
    // Compares a reason code with a constant, not a balance.
    // slither-disable-next-line incorrect-equality
    _allowed = _canTransfer(_from, _to, _tokenId, false) == Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IGated721
  function canTransferWithReason(
    address _from,
    address _to,
    uint256 _tokenId
  ) external view returns (bool _ok, bytes32 _reason) {
    _reason = _canTransfer(_from, _to, _tokenId, true);
    // Compares a reason code with a constant, not a balance.
    // slither-disable-next-line incorrect-equality
    _ok = _reason == Reasons.TRANSFER_OK;
  }

  /// @inheritdoc ERC721URIStorageUpgradeable
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override(ERC721URIStorageUpgradeable, PolicyGatedCoreUpgradeable, IERC165) returns (bool _supported) {
    _supported = _interfaceId == type(IGated721).interfaceId || _interfaceId == type(IERC7943NonFungible).interfaceId
      || ERC721URIStorageUpgradeable.supportsInterface(_interfaceId)
      || PolicyGatedCoreUpgradeable.supportsInterface(_interfaceId);
  }

  /// @inheritdoc ITemplated
  function templateId() public pure override returns (bytes32 _id) {
    _id = keccak256('Gated721');
  }

  /**
   * @notice The route ERC-721's transfers, `_mint` and `_burn` take into `_move`, with the kind the addresses imply
   * @dev Checks approval first, as ERC-721 does, so an unapproved caller gets ERC-721's error and not the policy's
   * @param _to The receiver, or address(0) on burn
   * @param _tokenId The token
   * @param _auth The caller to check approval for, or address(0) to skip the check
   * @return _from The owner before the move, or address(0) on mint
   */
  function _update(
    address _to,
    uint256 _tokenId,
    address _auth
  ) internal override returns (address _from) {
    _from = _ownerOf(_tokenId);
    if (_auth != address(0)) _checkAuthorized(_from, _auth, _tokenId);
    _move(_from, _to, _tokenId, _inferKind(_from, _to));
  }

  /**
   * @notice The single path every movement of a token takes: mechanical checks and hook, the move, then `afterTransfer`
   * @dev Guarded against reentrancy, so a hook or rule calling back into any transfer function reverts. ERC-721's
   *      receiver callback runs after this returns, outside the guard, with the state final
   * @param _from The owner, or address(0) on mint
   * @param _to The receiver, or address(0) on burn
   * @param _tokenId The token
   * @param _kind The kind the hook sees
   */
  function _move(
    address _from,
    address _to,
    uint256 _tokenId,
    IERC8473Policy.TransferKind _kind
  ) private nonReentrant {
    IERC8473Policy.TransferContext memory _ctx = _context(_from, _to, _tokenId, _msgSender(), _kind);

    // Read once: the hook that approves the movement is the hook that sees `afterTransfer`.
    IERC8473Policy _hook = _policy();
    bytes32 _reason = _check(_ctx, _hook);
    if (_reason != Reasons.TRANSFER_OK) {
      // A frozen token reverts with the standard's error; every policy decision keeps the typed rejection that carries
      // its reason, even one that borrows the code without a freeze behind it.
      // Compares a reason code with a constant, not a balance.
      // slither-disable-next-line incorrect-equality
      if (_reason == Reasons.INSUFFICIENT_UNFROZEN && _frozenInTheWay(_ctx)) {
        revert ERC7943InsufficientUnfrozenBalance(_from, _tokenId);
      }
      revert ERC8473PolicyRejected(_reason);
    }

    // The previous owner it returns is `_from`, read by the caller before the checks.
    // aderyn-ignore-next-line(unchecked-return)
    super._update(_to, _tokenId, address(0));

    if (_hook.wantsAfterTransfer()) _hook.afterTransfer(_ctx);
  }

  /**
   * @notice Clears the freeze of a token an enforcement action takes, emitting `Frozen` before the token's `Transfer`
   * @param _account The owner losing the token
   * @param _tokenId The token
   */
  function _releaseFrozen(
    address _account,
    uint256 _tokenId
  ) private {
    Gated721Storage storage $ = _getGated721Storage();
    if ($.frozen[_account][_tokenId]) {
      $.frozen[_account][_tokenId] = false;
      emit Frozen(_account, _tokenId, false);
    }
  }

  /**
   * @notice The pre-flight behind `canTransfer` and `canTransferWithReason`
   * @dev The operator is `_from`, which is zero for a mint, so the answer does not depend on who asks (ERC-8473, check
   *      rule 3). It models TRANSFER, MINT and BURN. `burn` here is the burner's enforcement action, a FORCED movement
   *      that no pre-flight predicts, so a burn asked about is answered as a holder's would be
   * @param _from The sender, or address(0) for a mint
   * @param _to The receiver, or address(0) for a burn
   * @param _tokenId The token
   * @param _ownershipCounts False to leave ownership to ERC-721, as ERC-7943's `canTransfer` must
   * @return _reason The reason code
   */
  function _canTransfer(
    address _from,
    address _to,
    uint256 _tokenId,
    bool _ownershipCounts
  ) private view returns (bytes32 _reason) {
    // A mint to the zero address cannot happen, so the hook is not asked about one.
    if (_from == address(0) && _to == address(0)) return Reasons.ZERO_RECEIVER;
    if (_ownershipCounts && _ownerOf(_tokenId) != _from) return Reasons.NOT_TOKEN_OWNER;
    _reason = _check(_context(_from, _to, _tokenId, _from, _inferKind(_from, _to)), _policy());
  }

  /**
   * @notice Mechanical checks then the hook decision, shared by `_move` and the pre-flights
   * @param _ctx The movement context
   * @param _hook The hook to consult, read once by the caller
   * @return _reason The reason code
   */
  function _check(
    IERC8473Policy.TransferContext memory _ctx,
    IERC8473Policy _hook
  ) private view returns (bytes32 _reason) {
    if (paused() && _ctx.kind != IERC8473Policy.TransferKind.FORCED) return Reasons.PAUSED;
    if (_frozenInTheWay(_ctx)) return Reasons.INSUFFICIENT_UNFROZEN;
    if (address(_hook) == address(0)) return Reasons.NO_HOOK;
    _reason = _ask(address(_hook), abi.encodeCall(IERC8473Policy.checkTransfer, (_ctx)));
  }

  /**
   * @notice Builds a movement context for this token
   * @param _from The sender
   * @param _to The receiver
   * @param _tokenId The token
   * @param _operator The account driving the movement
   * @param _kind The movement kind
   * @return _ctx The context
   */
  function _context(
    address _from,
    address _to,
    uint256 _tokenId,
    address _operator,
    IERC8473Policy.TransferKind _kind
  ) private view returns (IERC8473Policy.TransferContext memory _ctx) {
    // The holdings before the move, so rules never call back into the token. Zero for the zero address, for which
    // ERC-721's `balanceOf` reverts.
    uint256 _fromBalance = _from == address(0) ? 0 : balanceOf(_from);
    uint256 _toBalance = _to == address(0) ? 0 : balanceOf(_to);
    _ctx = IERC8473Policy.TransferContext({
      token: address(this),
      from: _from,
      to: _to,
      tokenId: _tokenId,
      amount: 1,
      operator: _operator,
      kind: _kind,
      data: abi.encode(_fromBalance, _toBalance)
    });
  }

  /**
   * @notice Whether the token is frozen for its sender and the movement may not take a frozen token
   * @dev A FORCED movement may (a forced transfer or the burner's burn): the enforcement paths clear the freeze first
   * @param _ctx The movement context
   * @return _inTheWay True if the freeze stops the movement
   */
  function _frozenInTheWay(
    IERC8473Policy.TransferContext memory _ctx
  ) private view returns (bool _inTheWay) {
    if (_ctx.from == address(0) || !_getGated721Storage().frozen[_ctx.from][_ctx.tokenId]) return false;
    // FORCED, the token's enforcement authority, may take a frozen token.
    _inTheWay = _ctx.kind != IERC8473Policy.TransferKind.FORCED;
  }

  /**
   * @notice The ERC-7201 storage of the token
   * @return $ The storage pointer
   */
  function _getGated721Storage() private pure returns (Gated721Storage storage $) {
    assembly ('memory-safe') {
      $.slot := _GATED_721_STORAGE_LOCATION
    }
  }
}
