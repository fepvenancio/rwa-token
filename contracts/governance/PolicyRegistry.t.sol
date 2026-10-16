// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';

import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {Helpers} from 'contracts/test/Helpers.sol';

contract PolicyRegistryUnitTest is Helpers {
  PolicyRegistry internal _registry;
  address internal _admin = makeAddr('admin');
  address internal _attester = makeAddr('attester');
  address internal _stranger = makeAddr('stranger');
  /// @dev Any contract with code, used as an attestation target
  address internal _target;

  function setUp() public virtual {
    _registry = new PolicyRegistry(_admin, _attester);
    _target = address(new PolicyRegistry(_admin, _attester));
  }

  function _attest(
    address _contract,
    IPolicyRegistry.AttestKind _kind
  ) internal {
    vm.prank(_attester);
    _registry.attest(_contract.codehash, _kind, 'ipfs://review');
  }

  /// @dev Maps a fuzzed seed onto HOOK, RULE or IMPLEMENTATION
  function _kindFrom(
    uint8 _seed
  ) internal pure returns (IPolicyRegistry.AttestKind _attestKind) {
    _attestKind = IPolicyRegistry.AttestKind(bound(_seed, 1, 3));
  }
}

contract PolicyRegistryUnit_Constructor is PolicyRegistryUnitTest {
  function test_WhenAdminIsZero_ItReverts() external {
    vm.expectRevert(IPolicyRegistry.PolicyRegistry_ZeroAddress.selector);
    new PolicyRegistry(address(0), _attester);
  }

  function test_WhenAttesterIsZero_ItReverts() external {
    vm.expectRevert(IPolicyRegistry.PolicyRegistry_ZeroAddress.selector);
    new PolicyRegistry(_admin, address(0));
  }

  function test_WhenArgumentsAreValid_ItGrantsTheRoles() external view {
    assertTrue(_registry.hasRole(_registry.DEFAULT_ADMIN_ROLE(), _admin));
    assertTrue(_registry.hasRole(_registry.ATTESTER_ROLE(), _attester));
  }
}

contract PolicyRegistryUnit_Attest is PolicyRegistryUnitTest {
  function test_WhenCallerIsNotAttester_ItReverts() external {
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, _stranger, _registry.ATTESTER_ROLE()
      )
    );
    vm.prank(_stranger);
    _registry.attest(_target.codehash, IPolicyRegistry.AttestKind.HOOK, '');
  }

  function test_WhenKindIsNone_ItReverts() external {
    vm.expectRevert(IPolicyRegistry.PolicyRegistry_InvalidKind.selector);
    vm.prank(_attester);
    _registry.attest(_target.codehash, IPolicyRegistry.AttestKind.NONE, '');
  }

  /// @dev Regression: attesting the codehash of an empty account was accepted although it can never match
  function test_WhenCodehashIsZero_ItReverts() external {
    vm.expectRevert(IPolicyRegistry.PolicyRegistry_InvalidCodehash.selector);
    vm.prank(_attester);
    _registry.attest(bytes32(0), IPolicyRegistry.AttestKind.HOOK, '');
  }

  /// @dev Regression: attesting the codehash of an empty account was accepted although it can never match
  function test_WhenCodehashIsEmptyCode_ItReverts() external {
    vm.expectRevert(IPolicyRegistry.PolicyRegistry_InvalidCodehash.selector);
    vm.prank(_attester);
    _registry.attest(keccak256(''), IPolicyRegistry.AttestKind.HOOK, '');
  }

  function test_WhenAlreadyAttested_ItReverts(
    uint8 _seed
  ) external {
    _attest(_target, IPolicyRegistry.AttestKind.RULE);
    vm.expectRevert(abi.encodeWithSelector(IPolicyRegistry.PolicyRegistry_AlreadyAttested.selector, _target.codehash));
    vm.prank(_attester);
    _registry.attest(_target.codehash, _kindFrom(_seed), '');
  }

  function test_WhenValid_ItStoresTheKindAndEmits(
    bytes32 _codehash,
    uint8 _seed,
    string calldata _uri
  ) external {
    _codehash = bytes32(bound(uint256(_codehash), 1, type(uint256).max));
    // The empty-code hash is the one other invalid value (covered above); remap it instead of discarding the run.
    if (_codehash == keccak256('')) _codehash = keccak256('code');
    IPolicyRegistry.AttestKind _attestKind = _kindFrom(_seed);

    vm.expectEmit(address(_registry));
    emit IPolicyRegistry.Attested(_codehash, _attestKind, _attester, _uri);
    vm.prank(_attester);
    _registry.attest(_codehash, _attestKind, _uri);

    assertEq(uint8(_registry.kindOf(_codehash)), uint8(_attestKind));
  }
}

contract PolicyRegistryUnit_Revoke is PolicyRegistryUnitTest {
  function test_WhenCallerIsNotAttester_ItReverts() external {
    _attest(_target, IPolicyRegistry.AttestKind.HOOK);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, _stranger, _registry.ATTESTER_ROLE()
      )
    );
    vm.prank(_stranger);
    _registry.revoke(_target.codehash);
  }

  function test_WhenNotAttested_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IPolicyRegistry.PolicyRegistry_NotAttested.selector, _target.codehash));
    vm.prank(_attester);
    _registry.revoke(_target.codehash);
  }

  function test_WhenAttested_ItClearsTheKindAndEmits(
    uint8 _seed
  ) external {
    _attest(_target, _kindFrom(_seed));

    vm.expectEmit(address(_registry));
    emit IPolicyRegistry.AttestationRevoked(_target.codehash, _attester);
    vm.prank(_attester);
    _registry.revoke(_target.codehash);

    assertEq(uint8(_registry.kindOf(_target.codehash)), uint8(IPolicyRegistry.AttestKind.NONE));
    assertFalse(_registry.isAttested(_target, _kindFrom(_seed)));
  }
}

contract PolicyRegistryUnit_IsAttested is PolicyRegistryUnitTest {
  function test_WhenKindIsNone_ItReturnsFalse() external view {
    assertFalse(_registry.isAttested(_target, IPolicyRegistry.AttestKind.NONE));
  }

  function test_WhenTargetHasNoCode_ItReturnsFalse(
    uint8 _seed
  ) external view {
    assertFalse(_registry.isAttested(_stranger, _kindFrom(_seed)));
  }

  function test_WhenAttestedAsAnotherKind_ItReturnsFalse() external {
    _attest(_target, IPolicyRegistry.AttestKind.RULE);
    assertFalse(_registry.isAttested(_target, IPolicyRegistry.AttestKind.HOOK));
    assertFalse(_registry.isAttested(_target, IPolicyRegistry.AttestKind.IMPLEMENTATION));
  }

  function test_WhenAttestedAsTheKind_ItReturnsTrue(
    uint8 _seed
  ) external {
    _attest(_target, _kindFrom(_seed));
    assertTrue(_registry.isAttested(_target, _kindFrom(_seed)));
  }

  function test_WhenAnotherContractHasTheSameCode_ItReturnsTrue() external {
    _attest(_target, IPolicyRegistry.AttestKind.HOOK);
    address _twin = address(new PolicyRegistry(_admin, _attester));
    assertTrue(_registry.isAttested(_twin, IPolicyRegistry.AttestKind.HOOK));
  }
}

contract PolicyRegistryUnit_SupportsInterface is PolicyRegistryUnitTest {
  function test_WhenQueried_ItSupportsItsInterfaces() external view {
    assertTrue(_registry.supportsInterface(type(IPolicyRegistry).interfaceId));
    assertTrue(_registry.supportsInterface(type(IAccessControl).interfaceId));
    assertTrue(_registry.supportsInterface(type(IERC165).interfaceId));
    assertFalse(_registry.supportsInterface(0xdeadbeef));
  }
}
