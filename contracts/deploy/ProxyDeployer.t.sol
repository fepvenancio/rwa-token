// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ERC1967Utils} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol';
import {Initializable} from '@openzeppelin/contracts/proxy/utils/Initializable.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {IProxyDeployer} from 'interfaces/IProxyDeployer.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {TokenProxy} from 'contracts/deploy/TokenProxy.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';

contract ProxyDeployerUnitTest is Helpers {
  ProxyDeployer internal _deployer;
  IntentToken internal _impl;
  address internal _owner = makeAddr('deployer');
  address internal _admin = makeAddr('admin');
  address internal _guardian = makeAddr('guardian');
  address internal _registry;
  address internal _hook;
  address internal _otherHook;
  IComplianceRule[] internal _rules;

  function setUp() public virtual {
    _deployer = new ProxyDeployer(_owner);
    _impl = new IntentToken();
    _registry = _mockContract('registry');
    _hook = _mockContract('hook');
    _otherHook = _mockContract('otherHook');
    vm.mockCall(_registry, abi.encodeWithSelector(IPolicyRegistry.isAttested.selector), abi.encode(true));
    _rules.push(IComplianceRule(_mockContract('ruleA')));
    _rules.push(IComplianceRule(_mockContract('ruleB')));
    _hookNamesRegistry(_hook, _registry);
    _hookNamesRegistry(_otherHook, _registry);
    vm.mockCall(_otherHook, abi.encodeWithSelector(IComplianceHook.setRules.selector), '');
    _hookHolds(_hook, _deployer.predict('INT', address(_impl)), _rules);
  }

  /// @dev The hook names the registry it vets rules against; the token requires it to be its own
  function _hookNamesRegistry(
    address _target,
    address _named
  ) internal {
    vm.mockCall(_target, abi.encodeCall(IComplianceHook.REGISTRY, ()), abi.encode(_named));
  }

  /// @dev What the hook reports as the token's rules, and the hook accepting the token's own `setRules`
  function _hookHolds(
    address _target,
    address _token,
    IComplianceRule[] memory _held
  ) internal {
    vm.mockCall(_target, abi.encodeCall(IComplianceHook.rules, (_token)), abi.encode(_held));
    vm.mockCall(_target, abi.encodeWithSelector(IComplianceHook.setRules.selector), '');
  }

  function _init(
    string memory _symbol,
    address _withHook
  ) internal view returns (bytes memory _data) {
    _data = abi.encodeCall(
      IntentToken.initialize, ('Intent Token', _symbol, _admin, _guardian, _registry, _withHook, _rules)
    );
  }

  function _deploy(
    string memory _symbol,
    bytes memory _data,
    address _checkedHook
  ) internal returns (address _proxy) {
    vm.prank(_owner);
    _proxy = _deployer.deploy(_symbol, address(_impl), _data, _checkedHook, _rules);
  }
}

contract ProxyDeployerUnit_Constructor is ProxyDeployerUnitTest {
  function test_WhenTheOwnerIsZero_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
    new ProxyDeployer(address(0));
  }

  function test_ItRecordsTheOwner() external view {
    assertEq(_deployer.owner(), _owner);
  }
}

contract ProxyDeployerUnit_Predict is ProxyDeployerUnitTest {
  /// @dev The council's off-chain formula: CREATE2 over the proxy with empty init data, salt = keccak256(symbol)
  function testFuzz_ItIsTheCreate2AddressOfAnUninitialisedProxy(
    string memory _symbol,
    address _implementation
  ) external view {
    bytes32 _initCodeHash =
      keccak256(abi.encodePacked(type(TokenProxy).creationCode, abi.encode(_implementation, bytes(''))));
    assertEq(
      _deployer.predict(_symbol, _implementation),
      vm.computeCreate2Address(keccak256(bytes(_symbol)), _initCodeHash, address(_deployer))
    );
  }
}

contract ProxyDeployerUnit_Deploy is ProxyDeployerUnitTest {
  function test_WhenTheTokenComesUpWithTheHookAndTheRules_ItDeploysAndInitialisesThere() external {
    address _predicted = _deployer.predict('INT', address(_impl));
    vm.expectEmit(address(_deployer));
    emit IProxyDeployer.ProxyDeployed(keccak256('INT'), _predicted, address(_impl), _hook);
    address _proxy = _deploy('INT', _init('INT', _hook), _hook);

    assertEq(_proxy, _predicted);
    assertEq(address(uint160(uint256(vm.load(_proxy, ERC1967Utils.IMPLEMENTATION_SLOT)))), address(_impl));
    assertEq(IPolicyGated(_proxy).policyHook(), _hook);
    assertTrue(IAccessControl(_proxy).hasRole(0x00, _admin));
    assertFalse(IAccessControl(_proxy).hasRole(0x00, address(_deployer)), 'the helper holds no role');
    assertTrue(_deployer.saltUsed(keccak256('INT')));
  }

  function test_WhenInitialisedInTheSameTransaction_NoOneCanInitialiseItAgain() external {
    address _proxy = _deploy('INT', _init('INT', _hook), _hook);
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    IntentToken(_proxy).initialize('Evil', 'INT', makeAddr('attacker'), _guardian, _registry, _hook, _rules);
  }

  function test_WhenTheCallerIsNotTheOwner_ItReverts(
    address _caller
  ) external {
    if (_caller == _owner) _caller = address(uint160(_owner) ^ 1); // remap rather than vm.assume
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _deployer.deploy('INT', address(_impl), _init('INT', _hook), _hook, _rules);
  }

  /// @dev The token installs its initial rules on the hook itself, in the init call, as its own address
  function test_WhenInitialising_TheTokenInstallsItsRulesOnTheHookAsItself() external {
    address _predicted = _deployer.predict('INT', address(_impl));
    vm.expectCall(_hook, abi.encodeCall(IComplianceHook.setRules, (_predicted, _rules)));
    _deploy('INT', _init('INT', _hook), _hook);
  }

  /// @dev The hook must end up holding exactly the reviewed rules for the new token, or the deploy reverts
  function test_WhenTheHookHoldsOtherRules_ItRevertsAndNothingIsDeployed() external {
    address _predicted = _deployer.predict('INT', address(_impl));
    IComplianceRule[] memory _other = new IComplianceRule[](2);
    _other[0] = _rules[1];
    _other[1] = _rules[0];
    _hookHolds(_hook, _predicted, _other);
    vm.expectRevert(abi.encodeWithSelector(IProxyDeployer.ProxyDeployer_RulesMismatch.selector, _hook, _predicted));
    _deploy('INT', _init('INT', _hook), _hook);
    assertEq(_predicted.code.length, 0);
    assertFalse(_deployer.saltUsed(keccak256('INT')));
  }

  function test_WhenTheHookHoldsFewerRules_ItReverts() external {
    address _predicted = _deployer.predict('INT', address(_impl));
    _hookHolds(_hook, _predicted, new IComplianceRule[](0));
    vm.expectRevert(abi.encodeWithSelector(IProxyDeployer.ProxyDeployer_RulesMismatch.selector, _hook, _predicted));
    _deploy('INT', _init('INT', _hook), _hook);
  }

  function test_WhenTheHookHoldsMoreRules_ItReverts() external {
    address _predicted = _deployer.predict('INT', address(_impl));
    IComplianceRule[] memory _more = new IComplianceRule[](3);
    _more[0] = _rules[0];
    _more[1] = _rules[1];
    _more[2] = IComplianceRule(_mockContract('ruleC'));
    _hookHolds(_hook, _predicted, _more);
    vm.expectRevert(abi.encodeWithSelector(IProxyDeployer.ProxyDeployer_RulesMismatch.selector, _hook, _predicted));
    _deploy('INT', _init('INT', _hook), _hook);
  }

  /// @dev A hook that vets against another registry is refused by the token's initialiser; the salt stays free
  function test_WhenTheHookNamesAnotherRegistry_TheSaltStaysFreeForTheCorrectHook() external {
    address _predicted = _deployer.predict('INT', address(_impl));
    address _otherRegistry = makeAddr('otherRegistry');
    _hookNamesRegistry(_otherHook, _otherRegistry);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_HookRegistryMismatch.selector, _otherRegistry, _registry)
    );
    _deploy('INT', _init('INT', _otherHook), _otherHook);
    assertFalse(_deployer.saltUsed(keccak256('INT')));

    assertEq(_deploy('INT', _init('INT', _hook), _hook), _predicted);
    assertTrue(_deployer.saltUsed(keccak256('INT')));
  }

  function test_WhenTheSymbolWasUsed_ItRevertsEvenWithAnotherImplementation() external {
    _deploy('INT', _init('INT', _hook), _hook);
    IntentToken _otherImpl = new IntentToken();
    _hookHolds(_otherHook, _deployer.predict('INT', address(_otherImpl)), _rules);
    vm.expectRevert(abi.encodeWithSelector(IProxyDeployer.ProxyDeployer_SaltUsed.selector, keccak256('INT')));
    vm.prank(_owner);
    _deployer.deploy('INT', address(_otherImpl), _init('INT', _otherHook), _otherHook, _rules);
  }

  function test_WhenTheInitDataInstallsAnotherHook_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IProxyDeployer.ProxyDeployer_HookNotInstalled.selector, _hook, _otherHook));
    _deploy('INT', _init('INT', _otherHook), _hook);
  }

  function test_WhenTheTokenReportsAnotherSymbol_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IProxyDeployer.ProxyDeployer_SymbolMismatch.selector, 'INT', 'XXX'));
    _deploy('INT', _init('XXX', _hook), _hook);
  }

  function test_WhenInitialisationReverts_NothingIsDeployed() external {
    address _predicted = _deployer.predict('INT', address(_impl));
    vm.mockCall(_registry, abi.encodeWithSelector(IPolicyRegistry.isAttested.selector), abi.encode(false));
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_NotAttested.selector, _hook, IPolicyRegistry.AttestKind.HOOK)
    );
    _deploy('INT', _init('INT', _hook), _hook);
    assertEq(_predicted.code.length, 0);
    assertFalse(_deployer.saltUsed(keccak256('INT')));
  }

  /// @dev Same-transaction initialisation is the safety argument for `TokenProxy`: a failed init leaves nothing at the
  ///      address and does not burn the salt, so a bad configuration does not strand the symbol
  function test_WhenInitialisationReverts_TheSameSymbolDeploysAfterTheFix() external {
    address _predicted = _deployer.predict('INT', address(_impl));
    vm.mockCall(_registry, abi.encodeWithSelector(IPolicyRegistry.isAttested.selector), abi.encode(false));
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_NotAttested.selector, _hook, IPolicyRegistry.AttestKind.HOOK)
    );
    _deploy('INT', _init('INT', _hook), _hook);

    vm.mockCall(_registry, abi.encodeWithSelector(IPolicyRegistry.isAttested.selector), abi.encode(true));
    assertEq(_deploy('INT', _init('INT', _hook), _hook), _predicted);
    assertEq(IPolicyGated(_predicted).policyHook(), _hook);
  }

  /// @dev After the hand-over the deployer EOA cannot place a token outside governance
  function test_WhenOwnershipMovedToTheTimelock_TheFormerOwnerCannotDeploy() external {
    address _timelock = makeAddr('timelock');
    vm.prank(_owner);
    _deployer.transferOwnership(_timelock);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _owner));
    _deploy('INT', _init('INT', _hook), _hook);

    address _predicted = _deployer.predict('INT', address(_impl)); // read first, never inside the pranked call
    vm.prank(_timelock);
    assertEq(_deployer.deploy('INT', address(_impl), _init('INT', _hook), _hook, _rules), _predicted);
  }

  function test_ItReportsTheSymbolItWasKeyedOn() external {
    address _proxy = _deploy('INT', _init('INT', _hook), _hook);
    assertEq(IERC20Metadata(_proxy).symbol(), 'INT');
  }
}
