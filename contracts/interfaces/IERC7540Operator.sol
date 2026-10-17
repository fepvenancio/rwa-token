// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IERC7540Operator
 * @notice ERC-7540 operator methods (ERC-165 id 0xe3bc4e65). An operator may request and claim on behalf of a
 *         controller
 */
interface IERC7540Operator {
  /**
   * @notice Emitted when a controller approves or revokes an operator
   * @param _controller The controller
   * @param _operator The operator
   * @param _approved Whether the operator is approved
   */
  event OperatorSet(address indexed _controller, address indexed _operator, bool _approved);

  /**
   * @notice Approves or revokes an operator for the caller
   * @param _operator The operator
   * @param _approved Whether to approve
   * @return _success Always true
   */
  function setOperator(
    address _operator,
    bool _approved
  ) external returns (bool _success);

  /**
   * @notice Whether an operator is approved for a controller
   * @param _controller The controller
   * @param _operator The operator
   * @return _status True if approved
   */
  function isOperator(
    address _controller,
    address _operator
  ) external view returns (bool _status);
}
