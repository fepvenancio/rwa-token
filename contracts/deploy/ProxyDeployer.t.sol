// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ERC1967Utils} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol';
import {Initializable} from '@openzeppelin/contracts/proxy/utils/Initializable.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';

import {IComplianceHook} from 'interfaces/IComplianceHook.sol';
import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {IProxyDeployer} from 'interfaces/IProxyDeployer.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {TokenProxy} from 'contracts/deploy/TokenProxy.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {Helpers} from 'contracts/test/Helpers.sol';
import {MockIdentityRegistry} from 'contracts/test/MockIdentityRegistry.sol';
import {MockIdentityRule} from 'contracts/test/MockIdentityRule.sol';
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
    _registry = _mockContract('registry');
    _deployer = new ProxyDeployer(_owner, IPolicyRegistry(_registry));
    _impl = new IntentToken();
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

  /// @dev Overrides the registry's answer for one (target, kind) pair; the blanket `true` of `setUp` still covers the
  ///      rest. The reads prove the exact mock wins, so a test that relies on it cannot pass for the wrong reason
  function _setAttested(
    address _target,
    IPolicyRegistry.AttestKind _kind,
    bool _attested
  ) internal {
    vm.mockCall(_registry, abi.encodeCall(IPolicyRegistry.isAttested, (_target, _kind)), abi.encode(_attested));
    assertEq(IPolicyRegistry(_registry).isAttested(_target, _kind), _attested, 'the exact mock is in force');
  }

  function _init(
    string memory _symbol,
    address _withHook
  ) internal view returns (bytes memory _data) {
    _data = abi.encodeCall(
      IntentToken.initialize, ('Intent Token', _symbol, 18, _admin, _guardian, _registry, _withHook, _rules)
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
    new ProxyDeployer(address(0), IPolicyRegistry(_registry));
  }

  function test_WhenTheRegistryIsZero_ItReverts() external {
    vm.expectRevert(IProxyDeployer.ProxyDeployer_ZeroAddress.selector);
    new ProxyDeployer(_owner, IPolicyRegistry(address(0)));
  }

  function test_ItRecordsTheOwner() external view {
    assertEq(_deployer.owner(), _owner);
  }

  function test_ItRecordsTheRegistry() external view {
    assertEq(address(_deployer.REGISTRY()), _registry);
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
    IntentToken(_proxy).initialize('Evil', 'INT', 18, makeAddr('attacker'), _guardian, _registry, _hook, _rules);
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
    _setAttested(_hook, IPolicyRegistry.AttestKind.HOOK, false);
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
    _setAttested(_hook, IPolicyRegistry.AttestKind.HOOK, false);
    vm.expectRevert(
      abi.encodeWithSelector(IPolicyGated.PolicyGated_NotAttested.selector, _hook, IPolicyRegistry.AttestKind.HOOK)
    );
    _deploy('INT', _init('INT', _hook), _hook);

    _setAttested(_hook, IPolicyRegistry.AttestKind.HOOK, true);
    assertEq(_deploy('INT', _init('INT', _hook), _hook), _predicted);
    assertEq(IPolicyGated(_predicted).policyHook(), _hook);
  }

  /// @dev After the hand-over the deployer EOA cannot place a token outside governance
  function test_WhenOwnershipMoved_TheFormerOwnerCannotDeploy() external {
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

  function test_WhenDeploying_ItAsksTheRegistryAboutTheImplementationAsAnImplementation() external {
    vm.expectCall(
      _registry, abi.encodeCall(IPolicyRegistry.isAttested, (address(_impl), IPolicyRegistry.AttestKind.IMPLEMENTATION))
    );
    _deploy('INT', _init('INT', _hook), _hook);
  }

  function test_WhenTheImplementationIsNotAttested_ItRevertsAndNothingIsDeployed() external {
    address _predicted = _deployer.predict('INT', address(_impl));
    _setAttested(address(_impl), IPolicyRegistry.AttestKind.IMPLEMENTATION, false);
    vm.expectRevert(
      abi.encodeWithSelector(IProxyDeployer.ProxyDeployer_ImplementationNotAttested.selector, address(_impl))
    );
    _deploy('INT', _init('INT', _hook), _hook);
    assertEq(_predicted.code.length, 0);
    assertFalse(_deployer.saltUsed(keccak256('INT')));
  }

  function test_WhenTheImplementationIsNotAttested_TheSameSymbolDeploysAfterTheAttestation() external {
    address _predicted = _deployer.predict('INT', address(_impl));
    _setAttested(address(_impl), IPolicyRegistry.AttestKind.IMPLEMENTATION, false);
    vm.expectRevert(
      abi.encodeWithSelector(IProxyDeployer.ProxyDeployer_ImplementationNotAttested.selector, address(_impl))
    );
    _deploy('INT', _init('INT', _hook), _hook);

    _setAttested(address(_impl), IPolicyRegistry.AttestKind.IMPLEMENTATION, true);
    assertEq(_deploy('INT', _init('INT', _hook), _hook), _predicted);
  }

  /// @dev The salt check keeps its place ahead of the registry question: a used symbol is reported as used
  function test_WhenTheSymbolWasUsedAndTheImplementationIsNotAttested_SaltUsedWins() external {
    _deploy('INT', _init('INT', _hook), _hook);
    IntentToken _otherImpl = new IntentToken();
    _setAttested(address(_otherImpl), IPolicyRegistry.AttestKind.IMPLEMENTATION, false);
    vm.expectRevert(abi.encodeWithSelector(IProxyDeployer.ProxyDeployer_SaltUsed.selector, keccak256('INT')));
    vm.prank(_owner);
    _deployer.deploy('INT', address(_otherImpl), _init('INT', _otherHook), _otherHook, _rules);
  }

  /// @dev A token initialised against another registry, which attests its own hook and rules, is refused
  function test_WhenTheTokenNamesAnotherRegistry_ItRevertsAndNothingIsDeployed() external {
    address _predicted = _deployer.predict('INT', address(_impl));
    address _otherRegistry = _mockContract('otherRegistry');
    vm.mockCall(_otherRegistry, abi.encodeWithSelector(IPolicyRegistry.isAttested.selector), abi.encode(true));
    _hookNamesRegistry(_otherHook, _otherRegistry);
    _hookHolds(_otherHook, _predicted, _rules);

    bytes memory _data = abi.encodeCall(
      IntentToken.initialize, ('Intent Token', 'INT', 18, _admin, _guardian, _otherRegistry, _otherHook, _rules)
    );
    vm.expectRevert(
      abi.encodeWithSelector(IProxyDeployer.ProxyDeployer_RegistryMismatch.selector, _registry, _otherRegistry)
    );
    _deploy('INT', _data, _otherHook);
    assertEq(_predicted.code.length, 0);
    assertFalse(_deployer.saltUsed(keccak256('INT')));
  }
}

/// @notice Integration: the real registry answers the implementation question, so what counts as attested is the
///         registry's own rule (kind and runtime codehash), not a mocked answer
contract ProxyDeployerIntegration_RealRegistry is Helpers {
  PolicyRegistry internal _registry;
  ProxyDeployer internal _deployer;
  ComplianceHook internal _hook;
  MockIdentityRule internal _rule;
  IntentToken internal _impl;
  address internal _admin = makeAddr('admin');
  address internal _guardian = makeAddr('guardian');
  IComplianceRule[] internal _rules;

  function setUp() public virtual {
    // This test is the registry admin, the attester and the deployer's owner, as the deploy module is while it runs.
    _registry = new PolicyRegistry(address(this), address(this));
    _deployer = new ProxyDeployer(address(this), _registry);
    _hook = new ComplianceHook(_registry);
    _rule = new MockIdentityRule(IIdentityRegistry(address(new MockIdentityRegistry())));
    _impl = new IntentToken();
    _registry.attest(address(_rule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _rules.push(_rule);
  }

  function _deployOver(
    address _implementation
  ) internal returns (address _proxy) {
    bytes memory _data = abi.encodeCall(
      IntentToken.initialize, ('Intent Token', 'INT', 18, _admin, _guardian, address(_registry), address(_hook), _rules)
    );
    _proxy = _deployer.deploy('INT', _implementation, _data, address(_hook), _rules);
  }

  function test_WhenTheImplementationIsAttested_ItDeploys() external {
    _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    address _predicted = _deployer.predict('INT', address(_impl));
    assertEq(_deployOver(address(_impl)), _predicted);
    assertEq(IPolicyGated(_predicted).registry(), address(_registry));
  }

  function test_WhenTheImplementationIsNotAttested_ItReverts() external {
    vm.expectRevert(
      abi.encodeWithSelector(IProxyDeployer.ProxyDeployer_ImplementationNotAttested.selector, address(_impl))
    );
    _deployOver(address(_impl));
  }

  /// @dev A kind other than `IMPLEMENTATION` on the same codehash does not open the gate. `NONE` cannot be attested:
  ///      it is the unattested case above
  function testFuzz_WhenTheImplementationIsAttestedAsAnotherKind_ItReverts(
    uint8 _seed
  ) external {
    IPolicyRegistry.AttestKind _kind = IPolicyRegistry.AttestKind(bound(_seed, 1, 2)); // HOOK or RULE
    _registry.attest(address(_impl).codehash, _kind, '');
    vm.expectRevert(
      abi.encodeWithSelector(IProxyDeployer.ProxyDeployer_ImplementationNotAttested.selector, address(_impl))
    );
    _deployOver(address(_impl));
  }

  /// @dev Another instance of the same template has its own codehash (UUPS keeps `address(this)` in the code), so the
  ///      council's attestation of one deployment does not cover a second one
  function test_WhenAnotherInstanceOfTheTemplateIsNotAttested_ItReverts() external {
    _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    IntentToken _second = new IntentToken();
    vm.expectRevert(
      abi.encodeWithSelector(IProxyDeployer.ProxyDeployer_ImplementationNotAttested.selector, address(_second))
    );
    _deployOver(address(_second));
  }

  /// @dev Without the check this reverts inside the proxy constructor, with the proxy's own error, not the deployer's
  function test_WhenTheImplementationHasNoCode_ItRevertsAsNotAttested(
    address _nothing
  ) external {
    if (_nothing.code.length != 0) _nothing = address(uint160(_nothing) ^ type(uint160).max); // remap, not vm.assume
    vm.expectRevert(abi.encodeWithSelector(IProxyDeployer.ProxyDeployer_ImplementationNotAttested.selector, _nothing));
    _deployOver(_nothing);
  }
}
