// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC165} from '@openzeppelin/contracts/utils/introspection/ERC165.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyHook} from 'interfaces/IPolicyHook.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

/**
 * @title ComplianceHook
 * @notice Dispatcher bound to one token: an ordered list of attested rules, first rejection wins. Not a proxy
 * @dev Fails closed: with no rules installed, every movement is rejected with `Reasons.NO_RULES`. `ADMIN`, `REGISTRY`
 *      and `TOKEN` are immutable, so they are part of the attested codehash and a clone cannot change who governs it
 */
contract ComplianceHook is ERC165, IComplianceHook {
  /// @inheritdoc IComplianceHook
  uint256 public constant MAX_RULES = 16;

  /// @inheritdoc IComplianceHook
  address public immutable ADMIN;

  /// @inheritdoc IComplianceHook
  IPolicyRegistry public immutable REGISTRY;

  /// @inheritdoc IComplianceHook
  address public immutable TOKEN;

  /// @notice The installed rules, in evaluation order
  IComplianceRule[] internal _rules;

  /// @notice Bit `i` is set iff rule `i` wanted `after_` when the rule set was installed
  uint256 internal _afterMask;

  /**
   * @notice Restricts a function to `ADMIN`
   */
  // Kept as a modifier so the ADMIN gate is visible in the setRules signature.
  // aderyn-ignore-next-line(modifier-used-only-once)
  modifier onlyAdmin() {
    if (msg.sender != ADMIN) revert ComplianceHook_OnlyAdmin(msg.sender);
    _;
  }

  /**
   * @notice Deploys the hook
   * @param _admin The timelock, allowed to change the rule set
   * @param _registry The registry used to vet rules
   * @param _token The token served; may be predicted when the hook is deployed before the token proxy
   * @param _initialRules The rule set installed at deployment, under the same checks as `setRules`, so the token is
   *        live with its policy from the start and the timelock only governs changes. The rules live in storage, so
   *        they do not change the codehash
   */
  constructor(
    address _admin,
    IPolicyRegistry _registry,
    address _token,
    IComplianceRule[] memory _initialRules
  ) {
    if (_admin == address(0) || address(_registry) == address(0) || _token == address(0)) {
      revert ComplianceHook_ZeroAddress();
    }
    ADMIN = _admin;
    REGISTRY = _registry;
    TOKEN = _token;
    _setRules(_initialRules);
  }

  /// @inheritdoc IPolicyHook
  function afterTransfer(
    IPolicyHook.TransferContext calldata _ctx
  ) external {
    if (msg.sender != TOKEN) revert ComplianceHook_OnlyToken(msg.sender);
    uint256 _mask = _afterMask;
    if (_mask == 0) return;
    IComplianceRule[] memory _list = _rules;
    uint256 _length = _list.length;
    for (uint256 _i; _i < _length; ++_i) {
      if (_mask & (1 << _i) != 0) _list[_i].after_(_ctx);
    }
  }

  /// @inheritdoc IComplianceHook
  function setRules(
    IComplianceRule[] calldata _newRules
  ) external onlyAdmin {
    _setRules(_newRules);
  }

  /// @inheritdoc IPolicyHook
  function beforeTransfer(
    IPolicyHook.TransferContext calldata _ctx
  ) external view returns (bytes32 _reason) {
    IComplianceRule[] memory _list = _rules;
    uint256 _length = _list.length;
    if (_length == 0) return Reasons.NO_RULES;
    for (uint256 _i; _i < _length; ++_i) {
      bytes32 _ruleReason = _list[_i].check(_ctx);
      if (_ruleReason != Reasons.TRANSFER_OK) return _ruleReason;
    }
    _reason = Reasons.TRANSFER_OK;
  }

  /// @inheritdoc IComplianceHook
  function ruleCount() external view returns (uint256 _count) {
    _count = _rules.length;
  }

  /// @inheritdoc IComplianceHook
  function rules() external view returns (IComplianceRule[] memory _ruleList) {
    _ruleList = _rules;
  }

  /// @inheritdoc IPolicyHook
  function wantsAfter() external view returns (bool _wantsAfter) {
    _wantsAfter = _afterMask != 0;
  }

  /// @inheritdoc ERC165
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(IPolicyHook).interfaceId || _interfaceId == type(IComplianceHook).interfaceId
      || super.supportsInterface(_interfaceId);
  }

  /**
   * @notice Validates and installs an ordered rule set, replacing the current one
   * @param _newRules The new rules, in evaluation order
   */
  function _setRules(
    IComplianceRule[] memory _newRules
  ) internal {
    uint256 _length = _newRules.length;
    if (_length > MAX_RULES) revert ComplianceHook_TooManyRules(_length);

    delete _rules;
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
      // `ruleId` is the rule type: one instance of each type per hook. The same contract twice shares an id too.
      bytes32 _ruleId = _rule.ruleId();
      // Duplicate check over at most 16 rules; a duplicate must revert the whole set.
      // aderyn-ignore-next-line(require-revert-in-loop)
      for (uint256 _j; _j < _i; ++_j) {
        if (_ruleIds[_j] == _ruleId) revert ComplianceHook_DuplicateRule(address(_rule));
      }
      _rules.push(_rule);
      _ruleIds[_i] = _ruleId;
      if (_rule.wantsAfter()) _mask |= 1 << _i;
    }
    _afterMask = _mask;
    emit RuleSetChanged(_ruleIds);
  }
}
