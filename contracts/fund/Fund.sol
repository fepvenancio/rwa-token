// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC165} from '@openzeppelin/contracts/utils/introspection/ERC165.sol';
import {ERC165Checker} from '@openzeppelin/contracts/utils/introspection/ERC165Checker.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IFund} from 'interfaces/IFund.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

/**
 * @title Fund
 * @notice The set of share classes of one fund, with the investor count and each investor's class mask, as specified in
 *         `IFund`. Not a proxy, and it holds no policy: the installed rule decides, the fund only records
 * @dev `Ownable` like `ProxyDeployer`: the deployer owns it while it is configured and `Activate` hands ownership to the
 *      timelock. An immutable admin would force a timelock operation, and its delay, onto every first deployment.
 *      An account's state is one slot: bit `n - 1` for class `n`, and the top bit for "exempt". The installed rule, the
 *      investor count and the cap share one slot. The first count write is then never a write to an empty slot, and the
 *      rule, which the rule checks on every movement, is read together with the count and the cap at no extra cost
 */
contract Fund is Ownable, ERC165, IFund {
  /**
   * @notice The installed rule, the investor count and the cap, packed into one slot
   * @param rule The rule allowed to call `join` and `leave`; the zero address until set
   * @param count The number of distinct non-exempt accounts that hold at least one class
   * @param cap The most investors the rule admits
   */
  struct Investors {
    address rule;
    uint48 count;
    uint48 cap;
  }

  /// @inheritdoc IFund
  uint256 public constant MAX_CLASSES = 32;

  /// @notice The exemption flag in an account's state
  uint256 private constant _EXEMPT = 1 << 255;

  /// @notice The class bits in an account's state
  uint256 private constant _CLASS_BITS = (1 << MAX_CLASSES) - 1;

  /// @inheritdoc IFund
  IPolicyRegistry public immutable REGISTRY;

  /// @notice The installed rule, the investor count and the cap
  Investors internal _investors;

  /// @notice The registered classes, in registration order
  address[] internal _classes;

  /// @notice The class number of each token; 0 when it is not a class
  mapping(address _token => uint256 _index) internal _classIndex;

  /// @notice Each account's class bits and exemption flag
  mapping(address _account => uint256 _state) internal _holder;

  /**
   * @notice Restricts a function to the installed rule
   */
  // Kept as a modifier so the rule gate is visible in the `join` and `leave` signatures.
  // aderyn-ignore-next-line(modifier-used-only-once)
  modifier onlyRule() {
    if (msg.sender != _investors.rule) revert Fund_OnlyRule(msg.sender);
    _;
  }

  /**
   * @notice Deploys the fund
   * @param _initialOwner The account that configures the fund until ownership moves to the timelock
   * @param _registry The registry that must attest the rule
   */
  constructor(
    address _initialOwner,
    IPolicyRegistry _registry
  ) Ownable(_initialOwner) {
    if (address(_registry) == address(0)) revert Fund_ZeroAddress();
    REGISTRY = _registry;
  }

  /// @inheritdoc IFund
  function registerClass(
    address _token
  ) external onlyOwner {
    if (_token == address(0)) revert Fund_ZeroAddress();
    if (_classIndex[_token] != 0) revert Fund_AlreadyRegistered(_token);
    uint256 _count = _classes.length;
    if (_count >= MAX_CLASSES) revert Fund_TooManyClasses(MAX_CLASSES);
    address _installed = _investors.rule;
    if (_installed == address(0)) revert Fund_RuleNotSet();
    if (!ERC165Checker.supportsInterface(_token, type(IPolicyGated).interfaceId)) revert Fund_NotPolicyGated(_token);
    if (!_hookListsRule(_token, _installed)) revert Fund_RuleNotListed(_token, _installed);
    // The reads above and this one go through view interfaces or ERC165Checker: compiled to STATICCALL, so the token
    // cannot change state or re-enter with effect before the writes below.
    // aderyn-ignore-next-line(reentrancy-state-change)
    uint256 _supply = IERC20(_token).totalSupply();
    if (_supply != 0) revert Fund_ClassHasSupply(_token, _supply);

    _classes.push(_token);
    uint256 _index = _count + 1;
    _classIndex[_token] = _index;
    emit ClassRegistered(_token, _index);
  }

  /// @inheritdoc IFund
  function setRule(
    address _rule
  ) external onlyOwner {
    if (_rule == address(0)) revert Fund_ZeroAddress();
    // View interface: compiled to STATICCALL, so the registry cannot change state or re-enter before the write below.
    // aderyn-ignore-next-line(reentrancy-state-change)
    if (!REGISTRY.isAttested(_rule, IPolicyRegistry.AttestKind.RULE)) revert Fund_NotAttested(_rule);
    address _oldRule = _investors.rule;
    _investors.rule = _rule;
    emit RuleSet(_oldRule, _rule);
  }

  /// @inheritdoc IFund
  function setHolderCap(
    uint256 _cap
  ) external onlyOwner {
    uint48 _newCap = SafeCast.toUint48(_cap);
    uint256 _oldCap = _investors.cap;
    _investors.cap = _newCap;
    emit HolderCapSet(_oldCap, _cap);
  }

  /// @inheritdoc IFund
  function setExempt(
    address _account,
    bool _exempt
  ) external onlyOwner {
    if (_account == address(0)) revert Fund_ZeroAddress();
    uint256 _state = _holder[_account];
    if ((_state & _EXEMPT != 0) == _exempt) return;
    _holder[_account] = _exempt ? _state | _EXEMPT : _state & ~_EXEMPT;
    emit ExemptSet(_account, _exempt);
    // An account that holds a class enters or leaves the count with its exemption.
    if (_state & _CLASS_BITS != 0) _moveCount(!_exempt);
  }

  /// @inheritdoc IFund
  function join(
    address _token,
    address _account
  ) external onlyRule {
    uint256 _index = _classIndex[_token];
    if (_index == 0) revert Fund_NotAClass(_token);
    // A class never counts itself: a 7540 vault escrows shares at its own address.
    if (_account == _token) return;
    uint256 _state = _holder[_account];
    uint256 _bit = 1 << (_index - 1);
    if (_state & _bit != 0) return;

    uint256 _newState = _state | _bit;
    _holder[_account] = _newState;
    emit HolderClassesUpdated(_account, _newState & _CLASS_BITS);
    // No class bit and not exempt: the account is a new investor.
    if (_state == 0) _moveCount(true);
  }

  /// @inheritdoc IFund
  function leave(
    address _token,
    address _account
  ) external onlyRule {
    uint256 _index = _classIndex[_token];
    if (_index == 0) revert Fund_NotAClass(_token);
    uint256 _state = _holder[_account];
    uint256 _bit = 1 << (_index - 1);
    // The class itself is never recorded by `join`, so its own bit is never set and this covers it.
    if (_state & _bit == 0) return;

    uint256 _newState = _state & ~_bit;
    _holder[_account] = _newState;
    emit HolderClassesUpdated(_account, _newState & _CLASS_BITS);
    // No class bit left and not exempt: the account stops being an investor.
    if (_newState == 0) _moveCount(false);
  }

  /// @inheritdoc IFund
  function classCount() external view returns (uint256 _count) {
    _count = _classes.length;
  }

  /// @inheritdoc IFund
  function classAt(
    uint256 _index
  ) external view returns (address _token) {
    if (_index == 0 || _index > _classes.length) revert Fund_ClassOutOfRange(_index);
    _token = _classes[_index - 1];
  }

  /// @inheritdoc IFund
  function classIndexOf(
    address _token
  ) external view returns (uint256 _index) {
    _index = _classIndex[_token];
  }

  /// @inheritdoc IFund
  function holderCount() external view returns (uint256 _count) {
    _count = _investors.count;
  }

  /// @inheritdoc IFund
  function holderCap() external view returns (uint256 _cap) {
    _cap = _investors.cap;
  }

  /// @inheritdoc IFund
  function rule() external view returns (address _rule) {
    _rule = _investors.rule;
  }

  /// @inheritdoc IFund
  function heldClasses(
    address _account
  ) external view returns (uint256 _held) {
    _held = _holder[_account] & _CLASS_BITS;
  }

  /// @inheritdoc IFund
  function isExempt(
    address _account
  ) external view returns (bool _exempt) {
    _exempt = _holder[_account] & _EXEMPT != 0;
  }

  /// @inheritdoc IFund
  function admission(
    address _token,
    address _account
  ) external view returns (uint256 _index, uint256 _held, bool _exempt, uint256 _count, uint256 _cap, address _rule) {
    _index = _classIndex[_token];
    uint256 _state = _holder[_account];
    _held = _state & _CLASS_BITS;
    _exempt = _state & _EXEMPT != 0;
    Investors memory _snapshot = _investors;
    _count = _snapshot.count;
    _cap = _snapshot.cap;
    _rule = _snapshot.rule;
  }

  /// @inheritdoc IFund
  function positionsOf(
    address _account
  ) external view returns (address[] memory _tokens, uint256[] memory _balances) {
    uint256 _held = _holder[_account] & _CLASS_BITS;
    // Both counters start at zero by design: the first counts the classes held, the second the entries written.
    // slither-disable-start uninitialized-local
    uint256 _size;
    uint256 _filled;
    // slither-disable-end uninitialized-local
    // The loop clears the lowest set bit each pass.
    for (uint256 _bits = _held; _bits != 0; _bits &= _bits - 1) {
      ++_size;
    }
    _tokens = new address[](_size);
    _balances = new uint256[](_size);

    uint256 _total = _classes.length;
    for (uint256 _i; _i < _total && _filled < _size; ++_i) {
      if (_held & (1 << _i) == 0) continue;
      address _token = _classes[_i];
      _tokens[_filled] = _token;
      _balances[_filled] = IERC20(_token).balanceOf(_account);
      ++_filled;
    }
  }

  /// @inheritdoc ERC165
  function supportsInterface(
    bytes4 _interfaceId
  ) public view override returns (bool _supported) {
    _supported = _interfaceId == type(IFund).interfaceId || super.supportsInterface(_interfaceId);
  }

  /**
   * @notice Raises or lowers the investor count by one
   * @dev Checked arithmetic. The count cannot underflow: it rises with every account that gets its first class bit or
   *      loses its exemption while holding a class, and falls only for the reverse
   * @param _up True to raise the count
   */
  function _moveCount(
    bool _up
  ) internal {
    uint48 _count = _investors.count;
    _count = _up ? _count + 1 : _count - 1;
    _investors.count = _count;
    emit HolderCountUpdated(_count);
  }

  /**
   * @notice Whether the token's current hook lists a rule
   * @dev Reverts if the token has no hook or the hook has no `rules()`
   * @param _token The class token
   * @param _candidate The rule to look for
   * @return _listed True if listed
   */
  function _hookListsRule(
    address _token,
    address _candidate
  ) internal view returns (bool _listed) {
    IComplianceRule[] memory _list = IComplianceHook(IPolicyGated(_token).policyHook()).rules();
    uint256 _length = _list.length;
    for (uint256 _i; _i < _length; ++_i) {
      if (address(_list[_i]) == _candidate) return true;
    }
  }
}
