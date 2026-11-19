// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {Reasons} from 'interfaces/Errors.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IDistributor} from 'interfaces/IDistributor.sol';
import {IERC8473} from 'interfaces/IERC8473.sol';
import {IGatedVaultBase} from 'interfaces/IGatedVaultBase.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ISignedEntry} from 'interfaces/ISignedEntry.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';
import {Quals} from 'interfaces/Quals.sol';

import {Distributor} from 'contracts/distribution/Distributor.sol';
import {SupplyCapRule} from 'contracts/hooks/rules/SupplyCapRule.sol';
import {DvPExecutor} from 'contracts/intents/DvPExecutor.sol';
import {SignedEntryTest} from 'contracts/intents/SignedEntry.t.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';
import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';

/**
 * @notice The `cash` profile's token on real contracts: an `IntentToken` with the credential rule and a supply cap,
 *         used as the money of each part of the stack that moves money. Every contract that holds it, a vault, the
 *         signed entry, a distributor, a fund's cash account, is a holder like any other and needs a credential
 */
contract IntentTokenAsCashTest is SignedEntryTest {
  uint256 internal constant _CAP = 1_000_000e6;

  IntentToken internal _cash;
  SupplyCapRule internal _capRule;
  address internal _minter = makeAddr('minter');
  address internal _settler = makeAddr('settler');
  address internal _custody = makeAddr('custody');
  address internal _seller;
  uint256 internal _sellerKey;

  function setUp() public virtual override {
    super.setUp();
    (_seller, _sellerKey) = makeAddrAndKey('seller');
    _capRule = new SupplyCapRule();
    _registry.attest(address(_capRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _cash = _intentToken('cCASH', 6, true);
    _capRule.setSupplyCap(address(_cash), _CAP);
    _cash.grantRole(_cash.MINTER_ROLE(), _minter);
    _credential(_seller);
    _credential(_custody);
    vm.prank(_minter);
    _cash.mint(_investor, 10 * _ASSETS);
  }

  function _intentToken(
    string memory _symbol,
    uint8 _decimals,
    bool _capped
  ) internal returns (IntentToken _token) {
    IntentToken _impl = new IntentToken();
    if (_registry.kindOf(address(_impl).codehash) == IPolicyRegistry.AttestKind.NONE) {
      _registry.attest(address(_impl).codehash, IPolicyRegistry.AttestKind.IMPLEMENTATION, '');
    }
    IComplianceRule[] memory _list = new IComplianceRule[](_capped ? 2 : 1);
    _list[0] = _rule;
    if (_capped) _list[1] = _capRule;
    _token = IntentToken(
      _deployer.deploy(
        _symbol,
        address(_impl),
        abi.encodeCall(
          IntentToken.initialize,
          (_symbol, _symbol, _decimals, address(this), _guardian, address(_registry), address(_hook), _list)
        ),
        address(_hook),
        _list
      )
    );
    _rule.setPolicy(address(_token), Quals.KYC, 0, 0, 1);
  }

  function _rejected(
    bytes32 _reason
  ) internal pure returns (bytes memory _revertData) {
    _revertData = abi.encodeWithSelector(IERC8473.ERC8473PolicyRejected.selector, _reason);
  }

  function _signIntent(
    uint256 _key,
    IntentToken _token,
    ITransferIntent.TransferIntent memory _intent
  ) internal view returns (bytes memory _sig) {
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_key, _token.intentHash(_intent));
    _sig = abi.encodePacked(_r, _s, _v);
  }
}

contract IntentTokenAsCash_Issuance is IntentTokenAsCashTest {
  /// @dev The cap bounds what a minter key can create, whoever holds it
  function test_TheMinterIssuesUpToTheCapAndNoFurther() external {
    uint256 _room = _CAP - _cash.totalSupply();
    vm.prank(_minter);
    _cash.mint(_investor, _room);
    assertEq(_cash.totalSupply(), _CAP);
    vm.expectRevert(_rejected(Reasons.ABOVE_SUPPLY_CAP));
    vm.prank(_minter);
    _cash.mint(_investor, 1);
  }

  function test_AnAddressWithNoCredentialCannotReceiveIt() external {
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    vm.prank(_investor);
    _cash.transfer(_stranger, 1);
  }
}

contract IntentTokenAsCash_Vaults is IntentTokenAsCashTest {
  /// @dev A vault whose asset is gated is a holder of that asset: without a credential it cannot be paid
  function test_A4626TakesItOnlyOnceTheVaultHoldsACredential() external {
    Gated4626Vault _vault = _vault4626(address(_cash));
    vm.startPrank(_investor);
    _cash.approve(address(_vault), _ASSETS);
    vm.expectRevert(_rejected(Reasons.RECEIVER_NOT_VERIFIED));
    _vault.deposit(_ASSETS, _investor);
    vm.stopPrank();

    _credential(address(_vault));
    vm.startPrank(_investor);
    uint256 _shares = _vault.deposit(_ASSETS, _investor);
    assertEq(_cash.balanceOf(address(_vault)), _ASSETS);
    assertEq(_vault.redeem(_shares, _investor, _investor), _ASSETS);
    vm.stopPrank();
    assertEq(_cash.balanceOf(_investor), 10 * _ASSETS);
  }

  /// @dev The gated token has `permit`, so an investor enters by signature and a relayer pays the gas
  function test_AnInvestorEntersA4626ThroughTheSignedEntryByPermit() external {
    Gated4626Vault _vault = _vault4626(address(_cash));
    _credential(address(_vault));
    ISignedEntry.Entry memory _e = _entry(address(_vault), false);
    bytes32 _structHash = keccak256(
      abi.encode(_PERMIT_TYPEHASH, _investor, address(_router), _e.assets, _cash.nonces(_investor), _e.deadline)
    );
    (uint8 _v, bytes32 _r, bytes32 _s) =
      vm.sign(_investorKey, keccak256(abi.encodePacked('\x19\x01', _cash.DOMAIN_SEPARATOR(), _structHash)));
    bytes memory _sig = _sign(_e);
    vm.prank(_relayer);
    uint256 _shares = _router.enterWithPermit(_e, _sig, _v, _r, _s);
    assertEq(_vault.balanceOf(_investor), _shares);
    assertGt(_shares, 0);
    assertEq(_cash.balanceOf(address(_router)), 0);
  }

  /// @dev A 7540's money goes to its cash account at settlement and comes back from it for redemptions; both the vault
  ///      and that account hold a credential
  function test_A7540DealsInItThroughACredentialedCashAccount() external {
    Gated7540Vault _vault = _vault7540(address(_cash));
    _credential(address(_vault));
    _vault.grantRole(_vault.SETTLER_ROLE(), _settler);
    vm.prank(_custody);
    _cash.approve(address(_vault), type(uint256).max);

    vm.startPrank(_investor);
    _cash.approve(address(_vault), _ASSETS);
    _vault.requestDeposit(_ASSETS, _investor, _investor);
    vm.stopPrank();
    vm.startPrank(_settler);
    _vault.closePeriod();
    _vault.settlePeriod(0, 0, _custody, address(0), type(uint256).max);
    vm.stopPrank();
    assertEq(_cash.balanceOf(_custody), _ASSETS);

    uint256 _shares = _ASSETS * _PAR;
    vm.startPrank(_investor);
    _vault.mint(_shares, _investor, _investor);
    _vault.requestRedeem(_shares, _investor, _investor);
    vm.stopPrank();
    vm.startPrank(_settler);
    _vault.closePeriod();
    _vault.settlePeriod(_ASSETS, 0, _custody, address(0), type(uint256).max);
    vm.stopPrank();
    uint256 _owed = _vault.maxWithdraw(_investor);
    vm.prank(_investor);
    _vault.withdraw(_owed, _investor, _investor);
    assertEq(_cash.balanceOf(_investor), 9 * _ASSETS + _owed);
    assertGt(_owed, 0);
  }
}

contract IntentTokenAsCash_Distribution is IntentTokenAsCashTest {
  /// @dev A distributor pays a token's holders in it. The distributor holds the money between the approval and the
  ///      claims, so it needs a credential, and a holder that may not receive now is passed over by the batch
  function test_ADistributionIsFundedAndPaidInIt() external {
    IntentToken _security = _intentToken('SEC', 18, false);
    Distributor _distributor = new Distributor(address(_security));
    _credential(address(_distributor));
    address _maker = makeAddr('maker');
    address _checker = makeAddr('checker');
    _security.grantRole(_distributor.DISTRIBUTION_MAKER_ROLE(), _maker);
    _security.grantRole(_distributor.CHECKER_ROLE(), _checker);

    vm.prank(_minter);
    _cash.mint(_custody, 1000e6);
    vm.prank(_custody);
    _cash.approve(address(_distributor), 1000e6);

    // Two holders of the security: the investor, and the seller, whom the cash token will refuse.
    bytes32 _investorLeaf = keccak256(bytes.concat(keccak256(abi.encode(_investor, uint256(300e6)))));
    bytes32 _sellerLeaf = keccak256(bytes.concat(keccak256(abi.encode(_seller, uint256(700e6)))));
    bytes32 _root = _investorLeaf < _sellerLeaf
      ? keccak256(abi.encode(_investorLeaf, _sellerLeaf))
      : keccak256(abi.encode(_sellerLeaf, _investorLeaf));
    vm.prank(_maker);
    uint256 _id =
      _distributor.propose(_root, IERC20(address(_cash)), 1000e6, uint64(block.timestamp + 30 days), _custody);
    vm.prank(_checker);
    _distributor.approve(_id);
    assertEq(_cash.balanceOf(address(_distributor)), 1000e6);

    // The guardian blocks the seller in the registry both tokens read: it may not receive, so its row is passed over.
    vm.prank(_guardian);
    _creds.blockSubject(_seller);
    address[] memory _holders = new address[](2);
    uint256[] memory _amounts = new uint256[](2);
    bytes32[][] memory _proofs = new bytes32[][](2);
    (_holders[0], _amounts[0], _proofs[0]) = (_investor, 300e6, new bytes32[](1));
    (_holders[1], _amounts[1], _proofs[1]) = (_seller, 700e6, new bytes32[](1));
    _proofs[0][0] = _sellerLeaf;
    _proofs[1][0] = _investorLeaf;

    uint256 _before = _cash.balanceOf(_investor);
    vm.expectEmit(address(_distributor));
    emit IDistributor.DistributionClaimSkipped(_id, _seller, IDistributor.ClaimSkip.MAY_NOT_RECEIVE);
    assertEq(_distributor.claimBatch(_id, _holders, _amounts, _proofs), 1);
    assertEq(_cash.balanceOf(_investor), _before + 300e6);
    assertFalse(_distributor.hasClaimed(_id, _seller));

    _creds.clearGuardianBlock(_seller);
    assertEq(_distributor.claimBatch(_id, _holders, _amounts, _proofs), 1);
    assertEq(_cash.balanceOf(_seller), 700e6);
  }
}

contract IntentTokenAsCash_Settlement is IntentTokenAsCashTest {
  /// @dev A security against cash, both legs signed, in one transaction through the real executor
  function test_ATradeSettlesAgainstItThroughTheDvPExecutor() external {
    IntentToken _security = _intentToken('SEC', 18, false);
    DvPExecutor _dvp = new DvPExecutor(address(this), _guardian);
    _dvp.grantRole(_dvp.OPERATOR_ROLE(), _relayer);
    _security.grantRole(_security.EXECUTOR_ROLE(), address(_dvp));
    _cash.grantRole(_cash.EXECUTOR_ROLE(), address(_dvp));
    _security.grantRole(_security.MINTER_ROLE(), _minter);
    vm.prank(_minter);
    _security.mint(_seller, 10 ether);

    ITransferIntent.TransferIntent memory _securities = ITransferIntent.TransferIntent({
      from: _seller,
      to: _investor,
      amount: 10 ether,
      nonce: bytes32(uint256(1)),
      deadline: block.timestamp + 1 days,
      ref: bytes32('trade-1'),
      executor: address(_dvp),
      validAfter: 0,
      considerationToken: address(_cash),
      considerationAmount: 500e6
    });
    ITransferIntent.TransferIntent memory _payment = ITransferIntent.TransferIntent({
      from: _investor,
      to: _seller,
      amount: 500e6,
      nonce: bytes32(uint256(1)),
      deadline: block.timestamp + 1 days,
      ref: bytes32('trade-1'),
      executor: address(_dvp),
      validAfter: 0,
      considerationToken: address(_security),
      considerationAmount: 10 ether
    });
    bytes memory _securitiesSig = _signIntent(_sellerKey, _security, _securities);
    bytes memory _paymentSig = _signIntent(_investorKey, _cash, _payment);

    vm.prank(_relayer);
    _dvp.executeDvPGated(address(_security), address(_cash), _securities, _securitiesSig, _payment, _paymentSig);
    assertEq(_security.balanceOf(_investor), 10 ether);
    assertEq(_cash.balanceOf(_seller), 500e6);
    assertEq(_cash.balanceOf(address(_dvp)), 0);
  }
}
