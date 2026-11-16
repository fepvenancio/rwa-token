// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {Initializable} from '@openzeppelin/contracts/proxy/utils/Initializable.sol';
import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC7943Fungible} from 'interfaces/IERC7943Fungible.sol';
import {IERC8473} from 'interfaces/IERC8473.sol';
import {IIdentityRegistry} from 'interfaces/IIdentityRegistry.sol';
import {IPolicyGated} from 'interfaces/IPolicyGated.sol';
import {IPolicyGatedCore} from 'interfaces/IPolicyGatedCore.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ITemplated} from 'interfaces/ITemplated.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {MockIdentityRegistry} from 'contracts/test/MockIdentityRegistry.sol';
import {MockIdentityRule} from 'contracts/test/MockIdentityRule.sol';
import {GatedToken} from 'contracts/tokens/GatedToken.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';

/// @notice Integration: a real registry, hook and rule, the token placed through `ProxyDeployer`
contract GatedTokenIntegrationTest is Test {
  PolicyRegistry internal _registry;
  MockIdentityRegistry internal _identity;
  ComplianceHook internal _hook;
  MockIdentityRule internal _rule;
  GatedToken internal _impl;
  GatedToken internal _token;

  address internal _admin = makeAddr('timelock');
  address internal _guardian = makeAddr('guardian');
  address internal _attester = makeAddr('attester');
  address internal _minter = makeAddr('minter');
  address internal _burner = makeAddr('burner');
  address internal _agent = makeAddr('agent');
  address internal _upgrader = makeAddr('upgrader');
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');
  address internal _eve = makeAddr('eve');

  function setUp() public {
    _registry = new PolicyRegistry(_admin, _attester);
    _identity = new MockIdentityRegistry();
    _rule = new MockIdentityRule(IIdentityRegistry(address(_identity)));
    _hook = new ComplianceHook(_registry);
    _impl = new GatedToken();
    _attest(address(_rule), IPolicyRegistry.AttestKind.RULE);
    _attest(address(_hook), IPolicyRegistry.AttestKind.HOOK);
    _attest(address(_impl), IPolicyRegistry.AttestKind.IMPLEMENTATION);

    IComplianceRule[] memory _rules = _ruleList();
    ProxyDeployer _proxyDeployer = new ProxyDeployer(address(this), _registry);
    _token = GatedToken(
      _proxyDeployer.deploy(
        'gUSD',
        address(_impl),
        abi.encodeCall(
          GatedToken.initialize, ('Gated USD', 'gUSD', 2, _admin, _guardian, address(_registry), address(_hook), _rules)
        ),
        address(_hook),
        _rules
      )
    );

    vm.startPrank(_admin);
    _token.grantRole(_token.MINTER_ROLE(), _minter);
    _token.grantRole(_token.BURNER_ROLE(), _burner);
    _token.grantRole(_token.AGENT_ROLE(), _agent);
    _token.grantRole(_token.UPGRADER_ROLE(), _upgrader);
    vm.stopPrank();

    _identity.set(_alice, true);
    _identity.set(_bob, true);
  }

  function test_TheTemplateIdIsItsOwn() external view {
    assertEq(_token.templateId(), keccak256('GatedToken'));
    assertTrue(_token.templateId() != keccak256('IntentToken'));
  }

  function test_WhenPlaced_ItIsLiveWithItsPolicy() external view {
    assertEq(_token.name(), 'Gated USD');
    assertEq(_token.symbol(), 'gUSD');
    assertEq(_token.decimals(), 2);
    assertTrue(_token.hasRole(_token.DEFAULT_ADMIN_ROLE(), _admin));
    assertTrue(_token.hasRole(_token.GUARDIAN_ROLE(), _guardian));
    assertEq(_token.registry(), address(_registry));
    assertEq(_token.policy(), address(_hook));
    assertEq(address(_hook.rules(address(_token))[0]), address(_rule));
  }

  function testFuzz_ItReportsTheDecimalsItWasGiven(
    uint8 _decimals
  ) external {
    IComplianceRule[] memory _rules = _ruleList();
    ProxyDeployer _proxyDeployer = new ProxyDeployer(address(this), _registry);
    GatedToken _other = GatedToken(
      _proxyDeployer.deploy(
        'OTHER',
        address(_impl),
        abi.encodeCall(
          GatedToken.initialize,
          ('Other', 'OTHER', _decimals, _admin, _guardian, address(_registry), address(_hook), _rules)
        ),
        address(_hook),
        _rules
      )
    );
    assertEq(_other.decimals(), _decimals);
  }

  function test_TheErc7201LocationHoldsTheDecimals() external view {
    bytes32 _location =
      keccak256(abi.encode(uint256(keccak256('gated.storage.GatedToken')) - 1)) & ~bytes32(uint256(0xff));
    assertEq(_location, 0x8ecbb7c7992ff85ff8c7609447e9e2c8c5afb116431053f717237fde2f251600);
    assertEq(uint256(vm.load(address(_token), _location)), 2);
  }

  function test_WhenInitialisedAgain_ItReverts() external {
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    _token.initialize('x', 'x', 6, _admin, _guardian, address(_registry), address(_hook), _ruleList());
  }

  function test_TheImplementationCannotBeInitialised() external {
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    _impl.initialize('x', 'x', 6, _admin, _guardian, address(_registry), address(_hook), _ruleList());
  }

  function test_ItOffersTheStandardsAndNoSignedIntents() external {
    assertTrue(_token.supportsInterface(type(IPolicyGated).interfaceId));
    assertTrue(_token.supportsInterface(type(IERC7943Fungible).interfaceId));
    assertFalse(_token.supportsInterface(type(ITransferIntent).interfaceId));
    (bool _ok,) = address(_token).call(abi.encodeWithSelector(ITransferIntent.cancelIntent.selector, bytes32(0)));
    assertFalse(_ok, 'there is no intent entry point');
  }

  function test_WhenBothPartiesAreVerified_ItMovesAndThePreflightAgrees() external {
    vm.prank(_minter);
    _token.mint(_alice, 100);
    (bool _allowed, bytes32 _reason) = _token.canTransferWithReason(_alice, _bob, 40);
    assertTrue(_allowed);
    assertEq(_reason, Reasons.TRANSFER_OK);

    vm.prank(_alice);
    assertTrue(_token.transfer(_bob, 40));
    assertEq(_token.balanceOf(_alice), 60);
    assertEq(_token.balanceOf(_bob), 40);
  }

  function test_WhenTheReceiverIsNotVerified_ItRevertsAndThePreflightAgrees() external {
    vm.prank(_minter);
    _token.mint(_alice, 100);
    (bool _allowed, bytes32 _reason) = _token.canTransferWithReason(_alice, _eve, 40);
    assertFalse(_allowed);

    vm.expectRevert(abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, _reason));
    vm.prank(_alice);
    _token.transfer(_eve, 40); // solhint-disable-line unchecked-transfer
  }

  function test_WhenTheAgentEnforces_FreezeForceAndBurnAllWork() external {
    vm.prank(_minter);
    _token.mint(_alice, 100);

    vm.prank(_agent);
    _token.setFrozenTokens(_alice, 100);
    vm.expectRevert(
      abi.encodeWithSelector(IERC7943Fungible.ERC7943InsufficientUnfrozenBalance.selector, _alice, uint256(1), 0)
    );
    vm.prank(_alice);
    _token.transfer(_bob, 1); // solhint-disable-line unchecked-transfer

    vm.prank(_agent);
    _token.forcedTransfer(_alice, _bob, 60);
    assertEq(_token.balanceOf(_bob), 60);
    assertEq(_token.getFrozenTokens(_alice), 40);

    vm.prank(_burner);
    _token.burn(_alice, 40);
    assertEq(_token.balanceOf(_alice), 0);
    assertEq(_token.totalSupply(), 60);
  }

  function testFuzz_AHolderCanMoveExactlyTheUnfrozenBalance(
    uint256 _balance,
    uint256 _frozen
  ) external {
    _balance = bound(_balance, 1, 1e30);
    _frozen = bound(_frozen, 0, _balance);
    vm.prank(_minter);
    _token.mint(_alice, _balance);
    vm.prank(_agent);
    _token.setFrozenTokens(_alice, _frozen);

    uint256 _unfrozen = _balance - _frozen;
    vm.prank(_alice);
    assertTrue(_token.transfer(_bob, _unfrozen));
    assertEq(_token.balanceOf(_alice), _frozen);
  }

  function test_WhenUpgradedToAnAttestedImplementationOfTheSameTemplate_ItWorks() external {
    GatedToken _next = new GatedToken();
    _attest(address(_next), IPolicyRegistry.AttestKind.IMPLEMENTATION);
    vm.prank(_upgrader);
    UUPSUpgradeable(address(_token)).upgradeToAndCall(address(_next), '');
    assertEq(_token.templateId(), keccak256('GatedToken'));
  }

  function test_WhenUpgradedToAnotherTemplate_ItReverts() external {
    IntentToken _other = new IntentToken();
    _attest(address(_other), IPolicyRegistry.AttestKind.IMPLEMENTATION);
    vm.expectRevert(
      abi.encodeWithSelector(
        ITemplated.Templated_WrongTemplate.selector, address(_other), keccak256('GatedToken'), keccak256('IntentToken')
      )
    );
    vm.prank(_upgrader);
    UUPSUpgradeable(address(_token)).upgradeToAndCall(address(_other), '');
  }

  function test_WhenUpgradedToAnUnattestedImplementation_ItReverts() external {
    GatedToken _next = new GatedToken();
    vm.expectRevert(
      abi.encodeWithSelector(
        IPolicyGatedCore.PolicyGated_NotAttested.selector, address(_next), IPolicyRegistry.AttestKind.IMPLEMENTATION
      )
    );
    vm.prank(_upgrader);
    UUPSUpgradeable(address(_token)).upgradeToAndCall(address(_next), '');
  }

  function test_WhenEtherIsSent_ItReverts() external {
    vm.deal(address(this), 1 ether);
    (bool _ok,) = address(_token).call{value: 1 ether}('');
    assertFalse(_ok);
    assertEq(address(_token).balance, 0);
  }

  function test_WhenSomeoneWithoutTheRoleMints_ItReverts() external {
    vm.expectRevert();
    vm.prank(_eve);
    _token.mint(_alice, 1);
  }

  /**
   * @notice The attester attests a contract's codehash
   * @param _target The contract
   * @param _kind The kind
   */
  function _attest(
    address _target,
    IPolicyRegistry.AttestKind _kind
  ) internal {
    vm.prank(_attester);
    _registry.attest(_target.codehash, _kind, 'ipfs://review');
  }

  /**
   * @notice The one rule the token lists
   * @return _rules The list
   */
  function _ruleList() internal view returns (IComplianceRule[] memory _rules) {
    _rules = new IComplianceRule[](1);
    _rules[0] = _rule;
  }
}
