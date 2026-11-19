// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC165} from '@openzeppelin/contracts/utils/introspection/ERC165.sol';
import {ERC165Checker} from '@openzeppelin/contracts/utils/introspection/ERC165Checker.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {ICredentialRegistry} from 'interfaces/ICredentialRegistry.sol';
import {IFund} from 'interfaces/IFund.sol';
import {IFundHoldersRule} from 'interfaces/IFundHoldersRule.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

/**
 * @title Fund
 * @notice The set of share classes of one fund, with the investor count and each investor's class mask, as specified in
 *         `IFund`. Not a proxy, and it holds no policy: the installed rule decides, the fund only records
 * @dev `Ownable` like `ProxyDeployer`: the operations account owns it from deployment while its first classes are
 *      registered, and `FundOpen` hands ownership to the timelock. An immutable admin would force a timelock operation, and
 *      its delay, onto every first deployment.
 *      An account's state is one slot: bit `n - 1` for class `n`, the 56 bits above the classes for the key it is
 *      counted under, and the top bit for "exempt". The installed rule, the
 *      investor count and the cap share one slot. The first count write is then never a write to an empty slot, and the
 *      rule, which the rule checks on every movement, is read together with the count and the cap at no extra cost
 */
contract Fund is Ownable, ERC165, IFund {
  /**
   * @notice The installed rule, the investor count and the cap, packed into one slot
   * @param rule The rule allowed to call `join` and `leave`; the zero address until set
   * @param count The number of investors: counted accounts on their own plus the keys that have a counted account
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

  /// @notice Where the key an account is counted under sits in its state: above the 32 class bits
  uint256 private constant _KEY_SHIFT = 32;

  /// @notice The 56 bits of that key, in place
  uint256 private constant _KEY_BITS = uint256(type(uint56).max) << _KEY_SHIFT;

  /// @notice The class bits in an account's state
  uint256 private constant _CLASS_BITS = (1 << MAX_CLASSES) - 1;

  /// @inheritdoc IFund
  IPolicyRegistry public immutable REGISTRY;

  /// @inheritdoc IFund
  address public immutable CREDENTIALS;

  /// @notice The installed rule, the investor count and the cap
  Investors internal _investors;

  /// @notice The registered classes, in registration order
  address[] internal _classes;

  /// @notice The class number of each token; 0 when it is not a class
  mapping(address _token => uint256 _index) internal _classIndex;

  /// @notice Each account's class bits, the key it is counted under and its exemption flag. An account is counted
  ///         when it holds a class and is not exempt, and only then has a key
  mapping(address _account => uint256 _state) internal _holder;

  /// @notice How many counted accounts each key has. Never used for key zero, which is an account on its own
  mapping(uint256 _key => uint256 _accounts) internal _keyAccounts;

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
   * @param _credentials The credential registry asked for each address's entity, or the zero address to count every
   *        address on its own
   */
  constructor(
    address _initialOwner,
    IPolicyRegistry _registry,
    address _credentials
  ) Ownable(_initialOwner) {
    if (address(_registry) == address(0)) revert Fund_ZeroAddress();
    // A registry that does not answer this version's id could not be asked for an address's entity.
    if (
      _credentials != address(0)
        && !ERC165Checker.supportsInterface(_credentials, type(ICredentialRegistry).interfaceId)
    ) revert Fund_NotACredentialRegistry(_credentials);
    REGISTRY = _registry;
    CREDENTIALS = _credentials;
  }

  /// @inheritdoc IFund
  function rekey(
    address _account
  ) external {
    uint256 _state = _holder[_account];
    if (!_isCounted(_state)) return;
    uint256 _oldKey = (_state & _KEY_BITS) >> _KEY_SHIFT;
    uint256 _newKey = _keyNow(_account);
    if (_newKey == _oldKey) return;

    // The account leaves the old key before it joins the new one. The count moves only by the difference, so an
    // account that empties one investor and starts another leaves it where it was.
    bool _emptied = _leaveKey(_oldKey);
    bool _started = _joinKey(_newKey);
    _holder[_account] = (_state & ~_KEY_BITS) | (_newKey << _KEY_SHIFT);
    // `_newKey` came from a uint56.
    // aderyn-ignore-next-line(unsafe-casting)
    emit HolderKeyUpdated(_account, uint56(_newKey));
    if (_emptied != _started) _moveCount(_started);
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
    // Every FundHoldersRule shares one ruleId, so a hook takes any of them that is attested: only the fund can tell that
    // a rule counts into another fund's state. A view interface too, so no state changes before the write.
    // aderyn-ignore-next-line(reentrancy-state-change)
    address _named = address(IFundHoldersRule(_rule).FUND());
    if (_named != address(this)) revert Fund_RuleForAnotherFund(_rule, _named);
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
    emit ExemptSet(_account, _exempt);
    // An account that holds a class enters or leaves the count with its exemption.
    if (_state & _CLASS_BITS == 0) {
      _holder[_account] = _exempt ? _state | _EXEMPT : _state & ~_EXEMPT;
    } else if (_exempt) {
      // It leaves the key it was counted under.
      _holder[_account] = _stopCounting(_account, _state) | _EXEMPT;
    } else {
      // It is counted under the key the registry gives it now.
      _holder[_account] = _startCounting(_account, _state & ~_EXEMPT);
    }
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
    emit HolderClassesUpdated(_account, _newState & _CLASS_BITS);
    // No class bit and not exempt: the account is counted from here.
    if (_state & _CLASS_BITS == 0 && _state & _EXEMPT == 0) _newState = _startCounting(_account, _newState);
    _holder[_account] = _newState;
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
    emit HolderClassesUpdated(_account, _newState & _CLASS_BITS);
    // No class bit left and not exempt: the account stops being counted, and its key is cleared.
    if (_newState & _CLASS_BITS == 0 && _newState & _EXEMPT == 0) _newState = _stopCounting(_account, _newState);
    _holder[_account] = _newState;
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
  function isClassIntact(
    address _token
  ) external view returns (bool _intact) {
    _intact = _classIndex[_token] != 0 && _listsInstalledRule(_token);
  }

  /// @inheritdoc IFund
  function firstBrokenClass() external view returns (address _token) {
    uint256 _length = _classes.length;
    for (uint256 _i; _i < _length; ++_i) {
      address _class = _classes[_i];
      if (!_listsInstalledRule(_class)) return _class;
    }
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
  function countedWith(
    address _account
  ) external view returns (uint256 _addresses) {
    uint256 _state = _holder[_account];
    if (_isCounted(_state)) {
      uint256 _key = (_state & _KEY_BITS) >> _KEY_SHIFT;
      return _key == 0 ? 1 : _keyAccounts[_key];
    }
    uint256 _now = _keyNow(_account);
    if (_now != 0) _addresses = _keyAccounts[_now];
  }

  /// @inheritdoc IFund
  function countedKeyOf(
    address _account
  ) external view returns (uint56 _key) {
    // The mask leaves 56 bits.
    // aderyn-ignore-next-line(unsafe-casting)
    _key = uint56((_holder[_account] & _KEY_BITS) >> _KEY_SHIFT);
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
   * @notice Starts counting an account, under the key the credential registry gives it now
   * @param _account The account
   * @param _state Its state, with no key
   * @return _newState The state with the key it is counted under
   */
  function _startCounting(
    address _account,
    uint256 _state
  ) internal returns (uint256 _newState) {
    uint256 _key = _keyNow(_account);
    _newState = _state | (_key << _KEY_SHIFT);
    if (_key != 0) {
      // `_key` came from a uint56.
      // aderyn-ignore-next-line(unsafe-casting)
      emit HolderKeyUpdated(_account, uint56(_key));
    }
    if (_joinKey(_key)) _moveCount(true);
  }

  /**
   * @notice Stops counting an account: it leaves the key it was counted under, whatever the registry says now
   * @param _account The account
   * @param _state Its state, with the key it was counted under
   * @return _newState The state with no key
   */
  function _stopCounting(
    address _account,
    uint256 _state
  ) internal returns (uint256 _newState) {
    uint256 _key = (_state & _KEY_BITS) >> _KEY_SHIFT;
    _newState = _state & ~_KEY_BITS;
    if (_key != 0) emit HolderKeyUpdated(_account, 0);
    if (_leaveKey(_key)) _moveCount(false);
  }

  /**
   * @notice Adds one counted account to a key
   * @param _key The key; zero is an account on its own
   * @return _started True when this starts an investor: key zero, or the key's first account
   */
  function _joinKey(
    uint256 _key
  ) internal returns (bool _started) {
    if (_key == 0) return true;
    uint256 _accounts = _keyAccounts[_key];
    _keyAccounts[_key] = _accounts + 1;
    // Compares a count of accounts with zero, not a balance.
    // slither-disable-next-line incorrect-equality
    _started = _accounts == 0;
  }

  /**
   * @notice Takes one counted account from a key
   * @param _key The key; zero is an account on its own
   * @return _emptied True when this ends an investor: key zero, or the key's last account
   */
  function _leaveKey(
    uint256 _key
  ) internal returns (bool _emptied) {
    if (_key == 0) return true;
    uint256 _accounts = _keyAccounts[_key] - 1;
    _keyAccounts[_key] = _accounts;
    // Compares a count of accounts with zero, not a balance.
    // slither-disable-next-line incorrect-equality
    _emptied = _accounts == 0;
  }

  /**
   * @notice Raises or lowers the investor count by one
   * @dev Checked arithmetic. The count cannot underflow: it rises when an investor starts, an account on its own or the
   *      first counted account of a key, and falls only when that investor ends
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
    IComplianceRule[] memory _list = IComplianceHook(IPolicyGated(_token).policy()).rules(_token);
    uint256 _length = _list.length;
    for (uint256 _i; _i < _length; ++_i) {
      if (address(_list[_i]) == _candidate) return true;
    }
  }

  /**
   * @notice Whether the token's current hook lists the installed rule, answering false where `_hookListsRule` reverts
   * @dev For the monitor's views, which must not revert on the thing they watch: a token that cannot name its hook, or a
   *      hook that cannot list its rules, lists nothing. Hooks are attested, so a hook that answers with malformed data is
   *      not a case this covers
   * @param _token The class token
   * @return _listed True if the hook lists the installed rule
   */
  function _listsInstalledRule(
    address _token
  ) internal view returns (bool _listed) {
    address _installed = _investors.rule;
    // A failing token or hook is a broken class, not an error: the empty catch blocks answer false. A call to an address
    // with no code would fail in decoding its answer, which no catch block reaches, so that is asked first.
    if (_token.code.length == 0) return false;
    // aderyn-ignore-next-line(empty-block)
    try IPolicyGated(_token).policy() returns (address _hook) {
      if (_hook.code.length == 0) return false;
      // aderyn-ignore-next-line(empty-block)
      try IComplianceHook(_hook).rules(_token) returns (IComplianceRule[] memory _list) {
        uint256 _length = _list.length;
        for (uint256 _i; _i < _length; ++_i) {
          if (address(_list[_i]) == _installed) return true;
        }
      } catch {}
    } catch {}
  }

  /**
   * @notice The key the credential registry gives an account now; zero when the fund reads no registry
   * @param _account The account
   * @return _key The key
   */
  function _keyNow(
    address _account
  ) internal view returns (uint256 _key) {
    if (CREDENTIALS != address(0)) _key = ICredentialRegistry(CREDENTIALS).entityKeyOf(_account);
  }

  /**
   * @notice Whether a state is a counted account's: it holds a class and is not exempt
   * @param _state The state
   * @return _counted True if counted
   */
  function _isCounted(
    uint256 _state
  ) internal pure returns (bool _counted) {
    _counted = _state & _CLASS_BITS != 0 && _state & _EXEMPT == 0;
  }
}
