// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Hashes} from '@openzeppelin/contracts/utils/cryptography/Hashes.sol';
import {Test} from 'forge-std/Test.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {console} from 'forge-std/console.sol';

import {IComplianceRule} from 'interfaces/IComplianceRule.sol';
import {IDvPExecutor} from 'interfaces/IDvPExecutor.sol';
import {IPolicyRegistry} from 'interfaces/IPolicyRegistry.sol';
import {ISignedEntry} from 'interfaces/ISignedEntry.sol';
import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

import {Distributor} from 'contracts/distribution/Distributor.sol';
import {FundEntitiesTest} from 'contracts/fund/FundEntities.t.sol';
import {HolderRestrictionRule} from 'contracts/hooks/rules/HolderRestrictionRule.sol';
import {MinPositionRule} from 'contracts/hooks/rules/MinPositionRule.sol';
import {RuleSetIntegrationTest} from 'contracts/hooks/rules/RuleSetIntegration.t.sol';
import {DvPExecutor} from 'contracts/intents/DvPExecutor.sol';
import {DvPExecutorIntegrationTest} from 'contracts/intents/DvPExecutor.t.sol';
import {IntentExecutor} from 'contracts/intents/IntentExecutor.sol';
import {SignedEntryTest} from 'contracts/intents/SignedEntry.t.sol';
import {MockAsset} from 'contracts/test/MockAsset.sol';
import {MockPermitAsset} from 'contracts/test/MockPermitAsset.sol';
import {IntentToken} from 'contracts/tokens/IntentToken.sol';
import {Gated4626Vault} from 'contracts/vaults/Gated4626Vault.sol';
import {Gated4626VaultIntegrationTest} from 'contracts/vaults/Gated4626Vault.t.sol';
import {Gated7540Vault} from 'contracts/vaults/Gated7540Vault.sol';
import {Gated7540VaultIntegrationTest} from 'contracts/vaults/Gated7540Vault.t.sol';

/**
 * @title Bench
 * @notice A benchmark, not a gate: nothing here asserts a number. For each fixed flow it prints one line,
 *         `BENCH|<flow>|<calls>|<writes>|<gas>`, which `npm run bench` collects into a table. The numbers are for
 *         comparing two versions of the stack. They differ between the two build lines (the opcodes and the
 *         OpenZeppelin release differ) and under the isolated test profile, so compare like with like
 * @dev    Calls are the CALL, STATICCALL and DELEGATECALL frames of the flow, the call into the contract included.
 *         Writes are storage write accesses, not distinct slots. Gas is `gasleft()` around the one call, so it includes
 *         encoding the arguments and leaves out the 21,000 of a transaction and the calldata. Each flow is prepared in
 *         its own test, so what the preparation touched is warm when the flow runs
 */
abstract contract BenchReport is Test {
  /**
   * @notice Stops the recording the flow started, counts its calls and storage writes, and prints the flow's line
   * @param _flow The flow's name, as `scripts/bench.ts` lists it
   * @param _gas The gas the flow's one call used
   */
  function _report(
    string memory _flow,
    uint256 _gas
  ) internal {
    VmSafe.AccountAccess[] memory _accesses = vm.stopAndReturnStateDiff();
    uint256 _calls;
    uint256 _writes;
    for (uint256 _i; _i < _accesses.length; ++_i) {
      VmSafe.AccountAccessKind _kind = _accesses[_i].kind;
      if (
        _kind == VmSafe.AccountAccessKind.Call || _kind == VmSafe.AccountAccessKind.StaticCall
          || _kind == VmSafe.AccountAccessKind.DelegateCall
      ) ++_calls;
      VmSafe.StorageAccess[] memory _slots = _accesses[_i].storageAccesses;
      for (uint256 _j; _j < _slots.length; ++_j) {
        if (_slots[_j].isWrite) ++_writes;
      }
    }
    console.log(
      string.concat('BENCH|', _flow, '|', vm.toString(_calls), '|', vm.toString(_writes), '|', vm.toString(_gas))
    );
  }
}

/// @notice A fund class behind four real rules: credential, minimum position, holder restriction, the fund's cap
contract Bench_FundClass is FundEntitiesTest, BenchReport {
  /// @dev Both rows in one test, the second after the first, as the base in `PLAN.md` was measured
  function test_Transfers() external {
    _fourRulesAndTwoHolders();
    IntentToken _class = _classA;
    (address _from, address _holder, address _newHolder) = (_a1, _bob, _carol);

    vm.startStateDiffRecording();
    vm.prank(_from);
    uint256 _gas = gasleft();
    _class.transfer(_holder, 1 ether);
    _gas -= gasleft();
    _report('transfer: between holders, 4 rules, fund class', _gas);

    vm.startStateDiffRecording();
    vm.prank(_from);
    _gas = gasleft();
    _class.transfer(_newHolder, 1 ether);
    _gas -= gasleft();
    _report('transfer: to a new holder, 4 rules, fund class', _gas);
  }

  /// @dev The share token is the real class; the money is a plain ERC-20. Two holders, so a proof of one node
  function test_DistributionClaim() external {
    _fourRulesAndTwoHolders();
    Distributor _distributor = new Distributor(address(_classA));
    MockAsset _money = new MockAsset(6);
    _classA.grantRole(_distributor.DISTRIBUTION_MAKER_ROLE(), _agent);
    _classA.grantRole(_distributor.CHECKER_ROLE(), _stranger);
    _money.mint(_minter, 1000);
    vm.prank(_minter);
    _money.approve(address(_distributor), 1000);

    address _holder = _a1;
    bytes32[] memory _proof = new bytes32[](1);
    _proof[0] = _leaf(_bob, 700);
    vm.prank(_agent);
    uint256 _id = _distributor.propose(
      Hashes.commutativeKeccak256(_leaf(_holder, 300), _proof[0]),
      IERC20(address(_money)),
      1000,
      uint64(block.timestamp + 30 days),
      _minter
    );
    vm.prank(_stranger);
    _distributor.approve(_id);

    vm.startStateDiffRecording();
    uint256 _gas = gasleft();
    _distributor.claim(_id, _holder, 300, _proof);
    _gas -= gasleft();
    _report('distribution: claim', _gas);
  }

  function _fourRulesAndTwoHolders() internal {
    MinPositionRule _minPositionRule = new MinPositionRule();
    HolderRestrictionRule _restrictionRule = new HolderRestrictionRule();
    _registry.attest(address(_minPositionRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    _registry.attest(address(_restrictionRule).codehash, IPolicyRegistry.AttestKind.RULE, '');
    IComplianceRule[] memory _list = new IComplianceRule[](4);
    _list[0] = _credentialRule;
    _list[1] = _minPositionRule;
    _list[2] = _restrictionRule;
    _list[3] = _fundRule;
    _hook.setRules(address(_classA), _list);
    _cred(_a1, 0);
    _cred(_bob, 0);
    _cred(_carol, 0);
    _mint(_classA, _a1, 100 ether);
    _mint(_classA, _bob, 1 ether);
  }

  function _leaf(
    address _holder,
    uint256 _amount
  ) internal pure returns (bytes32 _hash) {
    _hash = keccak256(bytes.concat(keccak256(abi.encode(_holder, _amount))));
  }
}

/// @notice An `IntentToken` behind the identity (mocked registry), minimum, restriction and window rules
contract Bench_Intent is RuleSetIntegrationTest, BenchReport {
  /// @dev Alice's signed intent to bob, who holds nothing, any executor, no consideration
  function test_ExecuteTransfer() external {
    IntentExecutor _intentExecutor = new IntentExecutor(_admin, _guardian);
    address _operator = makeAddr('operator');
    vm.startPrank(_admin);
    _intentExecutor.grantRole(_intentExecutor.OPERATOR_ROLE(), _operator);
    _token.grantRole(_token.EXECUTOR_ROLE(), address(_intentExecutor));
    vm.stopPrank();
    (ITransferIntent.TransferIntent memory _intent, bytes memory _sig) = _signedIntent(_bob, 50 ether, keccak256('n'));
    address _security = address(_token);

    vm.startStateDiffRecording();
    vm.prank(_operator);
    uint256 _gas = gasleft();
    _intentExecutor.execute(_security, _intent, _sig);
    _gas -= gasleft();
    _report('intent: executeTransfer through IntentExecutor', _gas);
  }
}

/// @notice The security of `Bench_Intent` against a gated cash token (identity only) and an ERC-3009 mock
contract Bench_DvP is DvPExecutorIntegrationTest, BenchReport {
  function test_GatedCash() external {
    Trade memory _t = _gatedTrade(_SHARES, _CASH);
    (DvPExecutor _executor, address _security, address _cashAddress, address _caller) = _parties(address(_cashToken));

    vm.startStateDiffRecording();
    vm.prank(_caller);
    uint256 _gas = gasleft();
    _executor.executeDvPGated(_security, _cashAddress, _t.s, _t.sSig, _t.c, _t.cSig);
    _gas -= gasleft();
    _report('dvp: gated cash', _gas);
  }

  function test_Erc3009Cash() external {
    (ITransferIntent.TransferIntent memory _s, bytes memory _sSig) =
      _securitiesIntent(_SHARES, _CASH, address(_usdc), keccak256('sNonce'));
    IDvPExecutor.Authorization memory _a = _authorization(_s, _CASH);
    (DvPExecutor _executor, address _security, address _cashAddress, address _caller) = _parties(address(_usdc));

    vm.startStateDiffRecording();
    vm.prank(_caller);
    uint256 _gas = gasleft();
    _executor.executeDvP3009(_security, _cashAddress, _s, _sSig, _a);
    _gas -= gasleft();
    _report('dvp: erc-3009 cash', _gas);
  }

  /// @dev The flow's addresses, read from storage before the measurement starts
  function _parties(
    address _cashAddress
  ) internal view returns (DvPExecutor _executor, address _security, address _cashOut, address _caller) {
    (_executor, _security, _cashOut, _caller) = (_dvp, address(_token), _cashAddress, _operator);
  }
}

/// @notice A 4626 vault behind the identity (mocked registry) and restriction rules, no portfolio and no fee model
contract Bench_4626 is Gated4626VaultIntegrationTest, BenchReport {
  /// @dev Alice's first deposit into a vault bob is already in
  function test_Deposit() external {
    _deposit(_bob, 1000e6);
    (Gated4626Vault _target, address _investor) = (_vault, _alice);

    vm.startStateDiffRecording();
    vm.prank(_investor);
    uint256 _gas = gasleft();
    _target.deposit(1000e6, _investor);
    _gas -= gasleft();
    _report('4626: deposit', _gas);
  }

  /// @dev Alice redeems half of her shares to herself; bob stays in
  function test_Redeem() external {
    _deposit(_bob, 1000e6);
    uint256 _half = _deposit(_alice, 1000e6) / 2;
    (Gated4626Vault _target, address _investor) = (_vault, _alice);

    vm.startStateDiffRecording();
    vm.prank(_investor);
    uint256 _gas = gasleft();
    _target.redeem(_half, _investor, _investor);
    _gas -= gasleft();
    _report('4626: redeem', _gas);
  }
}

/// @notice A 7540 vault, a fund's class, behind the identity (mocked registry), restriction and fund rules, settled by
///         a plain settler account at par, with no desk
contract Bench_7540 is Gated7540VaultIntegrationTest, BenchReport {
  /// @dev The first request of the first period
  function test_RequestDeposit() external {
    (Gated7540Vault _target, address _investor) = (_vault, _alice);

    vm.startStateDiffRecording();
    vm.prank(_investor);
    uint256 _gas = gasleft();
    _target.requestDeposit(1000, _investor, _investor);
    _gas -= gasleft();
    _report('7540: requestDeposit', _gas);
  }

  function test_SettlePeriodOneInvestor() external {
    _settleWith(1, '7540: settlePeriod, 1 investor');
  }

  function test_SettlePeriodHundredInvestors() external {
    _settleWith(100, '7540: settlePeriod, 100 investors');
  }

  /// @dev Alice claims all the shares her settled request bought, to herself
  function test_ClaimDeposit() external {
    vm.prank(_alice);
    _vault.requestDeposit(1000, _alice, _alice);
    _settleAtPar();
    (Gated7540Vault _target, address _investor) = (_vault, _alice);

    vm.startStateDiffRecording();
    vm.prank(_investor);
    uint256 _gas = gasleft();
    _target.deposit(1000, _investor, _investor);
    _gas -= gasleft();
    _report('7540: claim deposit', _gas);
  }

  /// @dev The first period, closed with `_investors` controllers each holding a pending deposit request and no
  ///      redemptions, then settled at par
  function _settleWith(
    uint256 _investors,
    string memory _flow
  ) internal {
    for (uint256 _i; _i < _investors; ++_i) {
      address _investor = address(uint160(uint256(keccak256(abi.encode('investor', _i)))));
      _identity.set(_investor, true);
      _asset.mint(_investor, 1000);
      vm.startPrank(_investor);
      _asset.approve(address(_vault), 1000);
      _vault.requestDeposit(1000, _investor, _investor);
      vm.stopPrank();
    }
    uint256 _nav = _supply() / _PAR;
    (Gated7540Vault _target, address _caller, address _cashAccount) = (_vault, _settler, _cash);
    vm.prank(_caller);
    _target.closePeriod();

    vm.startStateDiffRecording();
    vm.prank(_caller);
    uint256 _gas = gasleft();
    _target.settlePeriod(_nav, 0, _cashAccount, address(0), type(uint256).max);
    _gas -= gasleft();
    _report(_flow, _gas);
  }
}

/// @notice The real lego, credential registry and rule and a 4626 vault; the cash is a mock with ERC-2612
contract Bench_SignedEntry is SignedEntryTest, BenchReport {
  /// @dev A relayer submits the investor's entry and permit; the first deposit into the vault
  function test_EnterWithPermit() external {
    MockPermitAsset _asset = new MockPermitAsset();
    ISignedEntry.Entry memory _e = _entry(address(_vault4626(address(_asset))), false);
    _asset.mint(_investor, _ASSETS);
    bytes memory _sig = _sign(_e);
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(
      _investorKey,
      keccak256(
        abi.encodePacked(
          '\x19\x01',
          _asset.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              _PERMIT_TYPEHASH,
              _investor,
              address(_router),
              _ASSETS,
              _asset.nonces(_investor),
              block.timestamp + 1 hours
            )
          )
        )
      )
    );
    (ISignedEntry _target, address _caller) = (_router, _relayer);

    vm.startStateDiffRecording();
    vm.prank(_caller);
    uint256 _gas = gasleft();
    _target.enterWithPermit(_e, _sig, _v, _r, _s);
    _gas -= gasleft();
    _report('signed entry: 4626 with permit', _gas);
  }
}
