// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ITransferIntent} from 'interfaces/ITransferIntent.sol';

/**
 * @title IIntentExecutor
 * @notice Role-gated caller that submits signed transfer intents to tokens. Replaceable; grows into multi-leg DvP
 */
interface IIntentExecutor {
  /**
   * @notice Submits a signed intent to a token
   * @param _token The token, which must have granted this executor EXECUTOR_ROLE
   * @param _intent The intent
   * @param _sig The holder's signature
   * @return _intentHash The EIP-712 digest of the executed intent
   */
  function execute(
    address _token,
    ITransferIntent.TransferIntent calldata _intent,
    bytes calldata _sig
  ) external returns (bytes32 _intentHash);
}
