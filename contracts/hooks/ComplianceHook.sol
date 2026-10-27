// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {ERC165} from '@openzeppelin/contracts/utils/introspection/ERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

/**
 * @title ComplianceHook
 * @notice Dispatcher shared by every token of a deployment: each token has its own ordered list of attested rules, first
 *         rejection wins. Not a proxy
 * @dev Fails closed: a token with no rules installed has every movement rejected with `Reasons.NO_RULES`. `REGISTRY` is
 *      the only immutable, so one attestation of the codehash serves every token. A token's rules are set by whoever holds
 *      that token's DEFAULT_ADMIN_ROLE (asked live, as the rules do for their own configuration) or by the token itself,
 *      so that its initialiser can install the hook and the initial rules in one call. All state is keyed by token, so a
 *      token can set its own rules and nobody else's. A rule list and its after mask share one storage word
 */
contract ComplianceHook is ERC165, IComplianceHook {
  /**
   * @notice One token's rule set
   * @param afterMask Bit `i` is set iff rule `i` wanted `after_` when the rule set was installed (at most 16 bits)
   * @param count The number of installed rules (at most `MAX_RULES`)
   * @param rule The installed rules by position, in evaluation order
   */
  struct RuleSet {
    uint16 afterMask;
    uint8 count;
    mapping(uint256 _index => IComplianceRule _rule) rule;
  }

  /// @inheritdoc IComplianceHook
  uint256 public constant MAX_RULES = 16;

  /// @notice The role that administers a token, in OpenZeppelin's `AccessControl`
  bytes32 private constant _DEFAULT_ADMIN_ROLE = 0x00;

  /// @inheritdoc IComplianceHook
  IPolicyRegistry public immutable REGISTRY;

  /// @notice The rule set of each token
  mapping(address _token => RuleSet _ruleSet) internal _ruleSets;

  /**
   * @notice Deploys the hook
   * @param _registry The registry used to vet rules, and the one every token using this hook must name as its own
   */
  constructor(
    IPolicyRegistry _registry
  ) {
    if (address(_registry) == address(0)) revert ComplianceHook_ZeroAddress();
    REGISTRY = _registry;
  }

  /// @inheritdoc IPolicyHook
  function afterTransfer(
    IPolicyHook.TransferContext calldata _ctx
  ) external {
    if (msg.sender != _ctx.token) revert ComplianceHook_OnlyToken(msg.sender);
    RuleSet storage _set = _ruleSets[msg.sender];
    uint256 _mask = _set.afterMask;
    if (_mask == 0) return;
    uint256 _length = _set.count;
    for (uint256 _i; _i < _length; ++_i) {
      if (_mask & (1 << _i) != 0) _set.rule[_i].after_(_ctx);
    }
  }

  /// @inheritdoc IComplianceHook
  function setRules(
    address _token,
    IComplianceRule[] calldata _newRules
  ) external {
    // A token sets its own rules (its initialiser has no role the hook could ask about yet); anyone else needs the
    // token's DEFAULT_ADMIN_ROLE, asked live. `hasRole` is a view call, so it cannot change state before the write.
    if (
      msg.sender != _token
        && (_token.code.length == 0 || !IAccessControl(_token).hasRole(_DEFAULT_ADMIN_ROLE, msg.sender))
    ) {
      revert ComplianceHook_NotTokenAdmin(_token, msg.sender);
    }
    _setRules(_token, _newRules);
  }

  /// @inheritdoc IPolicyHook
  function beforeTransfer(
    IPolicyHook.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    RuleSet storage _set = _ruleSets[_ctx.token];
    uint256 _length = _set.count;
    if (_length == 0) return Reasons.NO_RULES;
    for (uint256 _i; _i < _length; ++_i) {
      bytes32 _ruleReason = _set.rule[_i].check(_ctx);
      if (_ruleReason != Reasons.TRANSFER_OK) return _ruleReason;
    }
    _reason = Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IPolicyHook
  function checkReceive(
    address _token,
    address _account
  ) external view returns (bytes32 _reason) {
    RuleSet storage _set = _ruleSets[_token];
    uint256 _length = _set.count;
    if (_length == 0) return Reasons.NO_RULES;
    for (uint256 _i; _i < _length; ++_i) {
      bytes32 _ruleReason = _set.rule[_i].checkReceive(_token, _account);
      if (_ruleReason != Reasons.TRANSFER_OK) return _ruleReason;
    }
    _reason = Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IPolicyHook
  function checkSend(
    address _token,
    address _account
  ) external view returns (bytes32 _reason) {
    RuleSet storage _set = _ruleSets[_token];
    uint256 _length = _set.count;
    if (_length == 0) return Reasons.NO_RULES;
    for (uint256 _i; _i < _length; ++_i) {
      bytes32 _ruleReason = _set.rule[_i].checkSend(_token, _account);
      if (_ruleReason != Reasons.TRANSFER_OK) return _ruleReason;
    }
    _reason = Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IComplianceHook
  function ruleCount(
    address _token
  ) external view returns (uint256 _count) {
    _count = _ruleSets[_token].count;
  }

  /// @inheritdoc IComplianceHook
  function rules(
    address _token
  ) external view returns (IComplianceRule[] memory _ruleList) {
    RuleSet storage _set = _ruleSets[_token];
    uint256 _length = _set.count;
    _ruleList = new IComplianceRule[](_length);
    for (uint256 _i; _i < _length; ++_i) {
      _ruleList[_i] = _set.rule[_i];
    }
  }

  /// @inheritdoc IPolicyHook
  function wantsAfter() external view returns (bool _wantsAfter) {
    _wantsAfter = _ruleSets[msg.sender].afterMask != 0;
  }

  /// @inheritdoc ERC165
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(IPolicyHook).interfaceId || _interfaceId == type(IComplianceHook).interfaceId
      || super.supportsInterface(_interfaceId);
  }

  /**
   * @notice Validates and installs a token's ordered rule set, replacing its current one
   * @param _token The token
   * @param _newRules The new rules, in evaluation order
   */
  function _setRules(
    address _token,
    IComplianceRule[] calldata _newRules
  ) internal {
    uint256 _length = _newRules.length;
    if (_length > MAX_RULES) revert ComplianceHook_TooManyRules(_length);

    RuleSet storage _set = _ruleSets[_token];
    uint256 _oldCount = _set.count;
    // At most MAX_RULES (16) iterations.
    // aderyn-ignore-next-line(costly-loop)
    for (uint256 _old; _old < _oldCount; ++_old) {
      delete _set.rule[_old];
    }

    // Starts at zero by design; bits are set below.
    // slither-disable-next-line uninitialized-local
    uint256 _mask;
    bytes32[] memory _ruleIds = new bytes32[](_length);

    // At most MAX_RULES (16) iterations; an invalid rule must revert the whole set (fail closed).
    // aderyn-ignore-next-line(costly-loop, require-revert-in-loop)
    for (uint256 _i; _i < _length; ++_i) {
      IComplianceRule _rule = _newRules[_i];
      if (!REGISTRY.isAttested(address(_rule), IPolicyRegistry.AttestKind.RULE)) {
        revert ComplianceHook_NotAttested(address(_rule));
      }
      // `ruleId` is the rule type: one instance of each type per token. The same contract twice shares an id too.
      bytes32 _ruleId = _rule.ruleId();
      // Duplicate check over at most 16 rules; a duplicate must revert the whole set.
      // aderyn-ignore-next-line(require-revert-in-loop)
      for (uint256 _j; _j < _i; ++_j) {
        if (_ruleIds[_j] == _ruleId) revert ComplianceHook_DuplicateRule(address(_rule));
      }
      _set.rule[_i] = _rule;
      _ruleIds[_i] = _ruleId;
      if (_rule.wantsAfter()) _mask |= 1 << _i;
    }
    // `_length` is at most 16 and the mask has at most 16 bits, so both narrowings are exact.
    // aderyn-ignore-next-line(unsafe-casting)
    _set.count = uint8(_length);
    // aderyn-ignore-next-line(unsafe-casting)
    _set.afterMask = uint16(_mask);
    emit RuleSetChanged(_token, _ruleIds);
  }
}
