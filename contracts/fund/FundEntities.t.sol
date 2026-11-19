// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IERC8473} from 'interfaces/IERC8473.sol';
import {IFund} from 'interfaces/IFund.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {Quals} from 'interfaces/Quals.sol';

import {ProxyDeployer} from 'contracts/deploy/ProxyDeployer.sol';
import {Fund} from 'contracts/fund/Fund.sol';
import {PolicyRegistry} from 'contracts/governance/PolicyRegistry.sol';
import {ComplianceHook} from 'contracts/hooks/ComplianceHook.sol';
import {CredentialRule} from 'contracts/hooks/rules/CredentialRule.sol';
import {FundHoldersRule} from 'contracts/hooks/rules/FundHoldersRule.sol';
import {CredentialRegistry} from 'contracts/identity/CredentialRegistry.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';

/// @notice One fund with two classes over the real credential registry, credential rule, fund rule and hook. The
///         test contract is the admin of everything. The fund's cap is 3
contract FundEntitiesTest is Test {
  uint256 internal constant _NOW = 1_792_198_800;

  PolicyRegistry internal _registry;
  CredentialRegistry internal _creds;
  CredentialRule internal _credentialRule;
  ProxyDeployer internal _deployer;
  ComplianceHook internal _hook;
  Fund internal _fund;
  FundHoldersRule internal _fundRule;
  IntentToken internal _classA;
  IntentToken internal _classB;

  address internal _guardian = makeAddr('guardian');
  address internal _kyc = makeAddr('kycAttester');
  address internal _otherKyc = makeAddr('otherAttester');
  address internal _minter = makeAddr('minter');
  address internal _agent = makeAddr('agent');
  address internal _stranger = makeAddr('stranger');
  // Wallets. `_a1`, `_a2` and `_a3` are one institution's; the others stand alone unless a test links them.
  address internal _a1 = makeAddr('a1');
  address internal _a2 = makeAddr('a2');
  address internal _a3 = makeAddr('a3');
  address internal _bob = makeAddr('bob');
  address internal _carol = makeAddr('carol');
  address internal _dave = makeAddr('dave');

  function setUp() public virtual {
    vm.warp(_NOW);
    _registry = new PolicyRegistry(address(this), address(this));
    _creds = new CredentialRegistry(address(this), _guardian);
    _creds.addAttester(_kyc, type(uint32).max);
    _creds.addAttester(_otherKyc, type(uint32).max);
    _credentialRule = new CredentialRule(_creds);
    _deployer = new ProxyDeployer(address(this), _registry);
    _fund = _newFund();
    _fundRule = new FundHoldersRule(_fund);
    _hook = new ComplianceHook(_registry);
    _registry.attest(address(_credentialRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_fundRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_hook).codehash, IPolicyRegistry.AttestKind.HOOK, '');
    _fund.setRule(address(_fundRule));
    _fund.setHolderCap(3);

    address _impl = address(new IntentToken());
    _registry.attest(_impl.codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    _classA = _deployClass(_impl, 'gA');
    _classB = _deployClass(_impl, 'gB');
  }

  /// @dev The fund under test reads the credential registry
  function _newFund() internal virtual returns (Fund _newFundContract) {
    _newFundContract = new Fund(address(this), IPolicyRegistry(address(_registry)), address(_creds));
  }

  /// @dev A credential from the first attester, naming an entity in its numbering (zero for none)
  function _cred(
    address _who,
    uint48 _entity
  ) internal {
    vm.prank(_kyc);
    _creds.set(_who, uint64(block.timestamp + 365 days), Quals.KYC, _entity);
  }

  function _key(
    uint8 _attester,
    uint48 _entity
  ) internal pure returns (uint56 _expected) {
    _expected = (uint56(_attester) << 48) | _entity;
  }

  /// @dev Three investors, a full fund: the institution through `_a1` alone, bob and carol
  function _fillTheFund() internal {
    _cred(_a1, 1);
    _cred(_a2, 1);
    _cred(_a3, 1);
    _cred(_bob, 0);
    _cred(_carol, 0);
    _cred(_dave, 0);
    _mint(_classA, _a1, 10 ether);
    _mint(_classA, _bob, 10 ether);
    _mint(_classA, _carol, 10 ether);
    assertEq(_fund.holderCount(), 3);
  }

  function _rules() internal view returns (IComplianceRule[] memory _list) {
    _list = new IComplianceRule[](2);
    _list[0] = _credentialRule;
    _list[1] = _fundRule;
  }

  function _deployClass(
    address _impl,
    string memory _symbol
  ) internal returns (IntentToken _class) {
    _class = IntentToken(
      _deployer.deploy(
        _symbol,
        _impl,
        abi.encodeCall(
          IntentToken.initialize,
          (_symbol, _symbol, 18, address(this), _guardian, address(_registry), address(_hook), _rules())
        ),
        address(_hook),
        _rules()
      )
    );
    _credentialRule.setPolicy(address(_class), Quals.KYC, 0, 0, 3);
    _fund.registerClass(address(_class));
    _class.grantRole(_class.MINTER_ROLE(), _minter);
    _class.grantRole(_class.AGENT_ROLE(), _agent);
  }

  function _mint(
    IntentToken _class,
    address _to,
    uint256 _amount
  ) internal {
    vm.prank(_minter);
    _class.mint(_to, _amount);
  }

  function _rejected(
    bytes32 _reason
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, _reason);
  }

  /// @dev A transfer whose pre-flight must agree with the write
  function _transferWithParity(
    IntentToken _class,
    address _from,
    address _to,
    uint256 _amount,
    bytes32 _expected
  ) internal {
    (bool _ok, bytes32 _reason) = _class.canTransferWithReason(_from, _to, _amount);
    assertEq(_reason, _expected, 'pre-flight reason');
    assertEq(_ok, _expected == Reasons.TRANSFER_OK);
    if (!_ok) vm.expectRevert(_rejected(_expected));
    vm.prank(_from);
    _class.transfer(_to, _amount);
  }
}

contract FundEntities_Constructor is FundEntitiesTest {
  function test_WhenBuiltOverARegistry_ItNamesIt() external view {
    assertEq(_fund.CREDENTIALS(), address(_creds));
  }

  function test_WhenBuiltWithNoRegistry_ItNamesNone() external {
    Fund _plain = new Fund(address(this), IPolicyRegistry(address(_registry)), address(0));
    assertEq(_plain.CREDENTIALS(), address(0));
  }

  /// @dev A registry that cannot be asked for an entity: here a contract that answers another interface
  function test_WhenTheRegistryDoesNotAnswerTheInterface_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_NotACredentialRegistry.selector, address(_registry)));
    new Fund(address(this), IPolicyRegistry(address(_registry)), address(_registry));
  }

  function test_WhenTheRegistryHasNoCode_ItReverts() external {
    vm.expectRevert(abi.encodeWithSelector(IFund.Fund_NotACredentialRegistry.selector, _stranger));
    new Fund(address(this), IPolicyRegistry(address(_registry)), _stranger);
  }
}

contract FundEntities_Counting is FundEntitiesTest {
  function test_WhenTwoAddressesOfOneEntityHold_TheyCountOnce() external {
    _cred(_a1, 1);
    _cred(_a2, 1);
    vm.expectEmit(address(_fund));
    emit IFund.HolderKeyUpdated(_a1, _key(0, 1));
    _mint(_classA, _a1, 1 ether);
    assertEq(_fund.holderCount(), 1);
    _mint(_classA, _a2, 1 ether);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.countedKeyOf(_a1), _key(0, 1));
    assertEq(_fund.countedKeyOf(_a2), _key(0, 1));
    assertEq(_fund.countedWith(_a1), 2);
  }

  function test_WhenOneEntityHoldsTwoClassesThroughTwoAddresses_ItCountsOnce() external {
    _cred(_a1, 1);
    _cred(_a2, 1);
    _mint(_classA, _a1, 1 ether);
    _mint(_classB, _a2, 1 ether);
    assertEq(_fund.holderCount(), 1);
  }

  /// @dev Key zero is an address on its own, never a shared investor
  function test_WhenAddressesNameNoEntity_EachCountsOnItsOwn() external {
    _cred(_bob, 0);
    _cred(_carol, 0);
    _mint(_classA, _bob, 1 ether);
    _mint(_classA, _carol, 1 ether);
    assertEq(_fund.holderCount(), 2);
    assertEq(_fund.countedKeyOf(_bob), 0);
    assertEq(_fund.countedWith(_bob), 1);
  }

  function test_WhenTwoAttestersUseTheSameEntityNumber_TheyAreTwoInvestors() external {
    _cred(_a1, 1);
    vm.prank(_otherKyc);
    _creds.set(_bob, uint64(block.timestamp + 365 days), Quals.KYC, 1);
    _mint(_classA, _a1, 1 ether);
    _mint(_classA, _bob, 1 ether);
    assertEq(_fund.holderCount(), 2);
  }

  function test_WhenOneAddressOfAnEntityLeaves_TheInvestorStaysUntilTheLastOneLeaves() external {
    _cred(_a1, 1);
    _cred(_a2, 1);
    _cred(_bob, 0);
    _mint(_classA, _a1, 1 ether);
    _mint(_classA, _a2, 1 ether);
    _mint(_classA, _bob, 1 ether);
    assertEq(_fund.holderCount(), 2);

    _transferWithParity(_classA, _a1, _bob, 1 ether, Reasons.TRANSFER_OK);
    assertEq(_fund.holderCount(), 2, 'the entity still holds through a2');
    assertEq(_fund.countedKeyOf(_a1), 0, 'the key is cleared with the last class');
    assertEq(_fund.countedWith(_a2), 1);

    _transferWithParity(_classA, _a2, _bob, 1 ether, Reasons.TRANSFER_OK);
    assertEq(_fund.holderCount(), 1);
  }

  /// @dev The count does not move because a credential expires: a lapsed holder keeps its key and can still leave
  function test_WhenACredentialLapses_TheCountStaysAndTheHolderCanLeave() external {
    _cred(_a1, 1);
    _cred(_a2, 1);
    _mint(_classA, _a1, 1 ether);
    _mint(_classA, _a2, 1 ether);
    vm.warp(block.timestamp + 366 days);
    _cred(_bob, 0);
    assertEq(_fund.holderCount(), 1);
    _transferWithParity(_classA, _a1, _bob, 1 ether, Reasons.TRANSFER_OK);
    assertEq(_fund.holderCount(), 2);
    assertEq(_fund.countedWith(_a2), 1);
  }
}

contract FundEntities_Cap is FundEntitiesTest {
  function test_WhenTheFundIsFull_AnotherAddressOfAnInvestorIsAdmittedAndAStrangerIsNot() external {
    _fillTheFund();
    (bool _ok, bytes32 _reason) = _classA.canTransferWithReason(address(0), _a2, 1 ether);
    assertTrue(_ok);
    assertEq(_reason, Reasons.TRANSFER_OK);
    _mint(_classA, _a2, 1 ether);
    assertEq(_fund.holderCount(), 3);

    (_ok, _reason) = _classA.canTransferWithReason(address(0), _dave, 1 ether);
    assertFalse(_ok);
    assertEq(_reason, Reasons.MAX_HOLDERS);
    vm.expectRevert(_rejected(Reasons.MAX_HOLDERS));
    _mint(_classA, _dave, 1 ether);
  }

  function test_WhenTheFundIsFull_ATransferBetweenTwoAddressesOfOneEntityPasses() external {
    _fillTheFund();
    _transferWithParity(_classA, _a1, _a3, 4 ether, Reasons.TRANSFER_OK);
    _transferWithParity(_classB, _bob, _bob, 0, Reasons.TRANSFER_OK);
    assertEq(_fund.holderCount(), 3);
  }

  /// @dev Net zero: the entity's only holding address hands its whole balance to a new investor
  function test_WhenAnEntitysLastAddressLeavesAtAFullCap_ANewInvestorTakesItsPlace() external {
    _fillTheFund();
    _transferWithParity(_classA, _a1, _dave, 10 ether, Reasons.TRANSFER_OK);
    assertEq(_fund.holderCount(), 3);
    assertEq(_fund.countedWith(_a2), 0);
  }

  /// @dev Not net zero: the address leaves, the entity does not
  function test_WhenAnEntityKeepsAnotherAddressAtAFullCap_ItsWholeBalanceMoveToANewInvestorIsRefused() external {
    _fillTheFund();
    _mint(_classA, _a2, 1 ether);
    _transferWithParity(_classA, _a1, _dave, 10 ether, Reasons.MAX_HOLDERS);
    assertEq(_fund.holderCount(), 3);
  }

  function test_WhenAnAddressOnItsOwnLeavesAtAFullCap_ANewInvestorTakesItsPlace() external {
    _fillTheFund();
    _transferWithParity(_classA, _bob, _dave, 10 ether, Reasons.TRANSFER_OK);
    assertEq(_fund.holderCount(), 3);
  }

  /// @dev The sender's side of the decision reads the key it was counted under, so the pre-flight and the write agree
  ///      while a registry change has not been followed by `rekey`
  function test_WhenTheRegistryUnlinksASenderAndNobodyRekeys_TheDecisionStillFollowsTheCount() external {
    _fillTheFund();
    _mint(_classA, _a2, 1 ether);
    _cred(_a1, 0); // the registry now says a1 stands alone; the fund still counts it with a2
    _transferWithParity(_classA, _a1, _dave, 10 ether, Reasons.MAX_HOLDERS);
    assertEq(_fund.holderCount(), 3);

    _fund.rekey(_a1);
    assertEq(_fund.holderCount(), 4, 'above the cap, by the rekey');
    _transferWithParity(_classA, _a1, _dave, 10 ether, Reasons.MAX_HOLDERS);
  }

  function test_WhenTheRegistryLinksASenderAndNobodyRekeys_ItStillLeavesAsItWasCounted() external {
    _cred(_a1, 0);
    _cred(_a2, 0);
    _cred(_bob, 0);
    _cred(_dave, 0);
    _mint(_classA, _a1, 10 ether);
    _mint(_classA, _a2, 10 ether);
    _mint(_classA, _bob, 10 ether);
    assertEq(_fund.holderCount(), 3);
    _cred(_a1, 1);
    _cred(_a2, 1); // linked in the registry, still counted apart
    _transferWithParity(_classA, _a1, _dave, 10 ether, Reasons.TRANSFER_OK);
    assertEq(_fund.holderCount(), 3);
  }
}

contract FundEntities_Rekey is FundEntitiesTest {
  function test_WhenTwoHoldingAddressesAreLinked_RekeyCountsThemOnce() external {
    _cred(_a1, 0);
    _cred(_a2, 0);
    _mint(_classA, _a1, 1 ether);
    _mint(_classA, _a2, 1 ether);
    assertEq(_fund.holderCount(), 2);

    _cred(_a1, 1);
    _cred(_a2, 1);
    assertEq(_fund.holderCount(), 2, 'strict until rekeyed');

    vm.expectEmit(address(_fund));
    emit IFund.HolderKeyUpdated(_a1, _key(0, 1));
    vm.prank(_stranger);
    _fund.rekey(_a1);
    assertEq(_fund.holderCount(), 2, 'one address moved to an empty key');
    vm.prank(_stranger);
    _fund.rekey(_a2);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.countedWith(_a1), 2);
  }

  function test_WhenAHoldingAddressIsUnlinked_RekeyCountsItApartEvenAboveTheCap() external {
    _cred(_a1, 1);
    _cred(_a2, 1);
    _mint(_classA, _a1, 1 ether);
    _mint(_classA, _a2, 1 ether);
    _fund.setHolderCap(1);
    assertEq(_fund.holderCount(), 1);

    _cred(_a2, 0);
    _fund.rekey(_a2);
    assertEq(_fund.holderCount(), 2);
    assertEq(_fund.countedKeyOf(_a2), 0);
    assertEq(_fund.countedWith(_a1), 1);
  }

  function test_WhenAnAddressMovesBetweenTwoEntitiesThatBothHold_TheCountStays() external {
    _cred(_a1, 1);
    _cred(_a2, 1);
    _cred(_bob, 2);
    _mint(_classA, _a1, 1 ether);
    _mint(_classA, _a2, 1 ether);
    _mint(_classA, _bob, 1 ether);
    assertEq(_fund.holderCount(), 2);
    _cred(_a2, 2);
    _fund.rekey(_a2);
    assertEq(_fund.holderCount(), 2);
    assertEq(_fund.countedWith(_a1), 1);
    assertEq(_fund.countedWith(_bob), 2);
  }

  function test_WhenNothingChanged_RekeyDoesNothing() external {
    _cred(_a1, 1);
    _mint(_classA, _a1, 1 ether);
    vm.recordLogs();
    _fund.rekey(_a1);
    _fund.rekey(_bob); // holds nothing
    assertEq(vm.getRecordedLogs().length, 0);
    assertEq(_fund.holderCount(), 1);
  }

  function test_WhenTheAddressIsExempt_RekeyDoesNothing() external {
    _cred(_a1, 0);
    _mint(_classA, _a1, 1 ether);
    _fund.setExempt(_a1, true);
    _cred(_a1, 1);
    vm.recordLogs();
    _fund.rekey(_a1);
    assertEq(vm.getRecordedLogs().length, 0);
    assertEq(_fund.holderCount(), 0);
    assertEq(_fund.countedKeyOf(_a1), 0);
  }
}

contract FundEntities_Exempt is FundEntitiesTest {
  function test_WhenOneAddressOfAnEntityIsExempted_TheInvestorStaysWhileAnotherHolds() external {
    _cred(_a1, 1);
    _cred(_a2, 1);
    _mint(_classA, _a1, 1 ether);
    _mint(_classA, _a2, 1 ether);
    _fund.setExempt(_a1, true);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.countedWith(_a2), 1);
    assertEq(_fund.countedKeyOf(_a1), 0);
    _fund.setExempt(_a2, true);
    assertEq(_fund.holderCount(), 0);

    _fund.setExempt(_a1, false);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.countedKeyOf(_a1), _key(0, 1));
  }

  /// @dev An exempt address holds no place in its entity's counter, so the entity's next address is counted
  function test_WhenAnExemptAddressOfAnEntityHolds_TheNextAddressOfThatEntityIsCounted() external {
    _cred(_a1, 1);
    _cred(_a2, 1);
    _fund.setExempt(_a1, true);
    _mint(_classA, _a1, 1 ether);
    assertEq(_fund.holderCount(), 0);
    _mint(_classA, _a2, 1 ether);
    assertEq(_fund.holderCount(), 1);
    _transferWithParity(_classA, _a2, _a1, 1 ether, Reasons.TRANSFER_OK);
    assertEq(_fund.holderCount(), 0);
  }

  /// @dev Exempting takes the address out of the key it was counted under, whatever the registry says now
  function test_WhenTheRegistryChangedBeforeAnExemption_TheCountedKeyIsTheOneLowered() external {
    _cred(_a1, 1);
    _cred(_a2, 1);
    _mint(_classA, _a1, 1 ether);
    _mint(_classA, _a2, 1 ether);
    _cred(_a1, 2);
    _fund.setExempt(_a1, true);
    assertEq(_fund.holderCount(), 1);
    assertEq(_fund.countedWith(_a2), 1);
    _fund.setExempt(_a1, false);
    assertEq(_fund.holderCount(), 2, 'counted again under the key the registry gives now');
    assertEq(_fund.countedKeyOf(_a1), _key(0, 2));
  }
}

/// @notice A fund built with no credential registry counts every address on its own, whatever the registry says
contract FundEntities_NoRegistry is FundEntitiesTest {
  function _newFund() internal override returns (Fund _newFundContract) {
    _newFundContract = new Fund(address(this), IPolicyRegistry(address(_registry)), address(0));
  }

  function test_WhenTheFundReadsNoRegistry_TwoAddressesOfOneEntityAreTwoInvestors() external {
    _cred(_a1, 1);
    _cred(_a2, 1);
    _mint(_classA, _a1, 1 ether);
    _mint(_classA, _a2, 1 ether);
    assertEq(_fund.holderCount(), 2);
    assertEq(_fund.countedKeyOf(_a1), 0);
    _fund.rekey(_a1);
    assertEq(_fund.holderCount(), 2);
  }
}

/// @notice Random movements, links, unlinks, rekeys and exemptions over four addresses, two attesters and two classes
contract FundEntitiesHandler is Test {
  Fund internal immutable _FUND;
  CredentialRegistry internal immutable _CREDS;
  IntentToken[2] internal _classes;
  address[4] internal _wallets;
  address[2] internal _attesters;
  address internal immutable _MINTER;
  address internal immutable _OWNER;

  constructor(
    Fund _fund,
    CredentialRegistry _creds,
    IntentToken[2] memory _classList,
    address[4] memory _walletList,
    address[2] memory _attesterList,
    address _minter
  ) {
    _FUND = _fund;
    _CREDS = _creds;
    _classes = _classList;
    _wallets = _walletList;
    _attesters = _attesterList;
    _MINTER = _minter;
    _OWNER = msg.sender;
  }

  /// @dev Each address keeps one attester, as the registry allows one live attester for an address
  function link(
    uint256 _who,
    uint256 _entity
  ) external {
    _who = bound(_who, 0, 3);
    vm.prank(_attesters[_who % 2]);
    _CREDS.set(_wallets[_who], uint64(block.timestamp + 365 days), Quals.KYC, uint48(bound(_entity, 0, 2)));
  }

  function mint(
    uint256 _class,
    uint256 _who,
    uint256 _amount
  ) external {
    vm.prank(_MINTER);
    try _classes[bound(_class, 0, 1)].mint(_wallets[bound(_who, 0, 3)], bound(_amount, 0, 5)) {} catch {}
  }

  function transfer(
    uint256 _class,
    uint256 _from,
    uint256 _to,
    uint256 _amount
  ) external {
    IntentToken _token = _classes[bound(_class, 0, 1)];
    address _sender = _wallets[bound(_from, 0, 3)];
    _amount = bound(_amount, 0, _token.balanceOf(_sender));
    vm.prank(_sender);
    try _token.transfer(_wallets[bound(_to, 0, 3)], _amount) {} catch {}
  }

  function rekey(
    uint256 _who
  ) external {
    _FUND.rekey(_wallets[bound(_who, 0, 3)]);
  }

  function setExempt(
    uint256 _who,
    bool _exempt
  ) external {
    vm.prank(_OWNER);
    _FUND.setExempt(_wallets[bound(_who, 0, 3)], _exempt);
  }
}

contract FundEntitiesInvariantTest is FundEntitiesTest {
  FundEntitiesHandler internal _handler;
  address[4] internal _wallets;

  function setUp() public override {
    super.setUp();
    _wallets = [_a1, _a2, _bob, _carol];
    _handler = new FundEntitiesHandler(_fund, _creds, [_classA, _classB], _wallets, [_kyc, _otherKyc], _minter);
    _fund.transferOwnership(address(_handler));
    // Every address starts with a credential, so it can receive.
    for (uint256 _i; _i < 4; ++_i) {
      _handler.link(_i, 0);
    }
    targetContract(address(_handler));
  }

  function _isCounted(
    address _wallet
  ) internal view returns (bool _counted) {
    _counted = _fund.heldClasses(_wallet) != 0 && !_fund.isExempt(_wallet);
  }

  /// @dev The count is the counted addresses on their own plus the distinct keys among the counted ones, and each
  ///      key's counter is the number of counted addresses under it, whatever links and rekeys came before
  function invariant_TheCountIsTheInvestorsAmongTheCountedAddresses() external view {
    uint256 _investors;
    for (uint256 _i; _i < 4; ++_i) {
      address _wallet = _wallets[_i];
      uint56 _key = _fund.countedKeyOf(_wallet);
      if (!_isCounted(_wallet)) {
        assertEq(_key, 0, 'an address that is not counted has no key');
        continue;
      }
      uint256 _sameKey;
      bool _first = true;
      for (uint256 _j; _j < 4; ++_j) {
        if (_isCounted(_wallets[_j]) && _fund.countedKeyOf(_wallets[_j]) == _key && _key != 0) {
          ++_sameKey;
          if (_j < _i) _first = false;
        }
      }
      if (_key == 0) {
        ++_investors;
        assertEq(_fund.countedWith(_wallet), 1);
      } else {
        if (_first) ++_investors;
        assertEq(_fund.countedWith(_wallet), _sameKey, 'the counter of the key');
      }
    }
    assertEq(_fund.holderCount(), _investors);
  }

  /// @dev An address holds a class exactly when its balance of that class is above zero
  function invariant_TheClassBitsFollowTheBalances() external view {
    for (uint256 _i; _i < 4; ++_i) {
      uint256 _held = _fund.heldClasses(_wallets[_i]);
      assertEq(_held & 1 != 0, _classA.balanceOf(_wallets[_i]) != 0);
      assertEq(_held & 2 != 0, _classB.balanceOf(_wallets[_i]) != 0);
    }
  }
}
