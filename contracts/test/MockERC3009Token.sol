// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';
import {SignatureChecker} from '@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol';

import {IERC3009} from 'interfaces/IERC3009.sol';

/**
 * @title MockERC3009Token
 * @notice A USDC-shaped cash token for tests: ERC-20 with 6 decimals and `receiveWithAuthorization`, with the same
 *         checks as Circle's FiatToken (payee must be the caller, strict time window, single-use nonce, signature
 *         through `SignatureChecker`). An optional fee on every transfer lets tests exercise fee-on-transfer tokens
 */
contract MockERC3009Token is ERC20, EIP712, IERC3009 {
  /// @notice EIP-712 typehash of the authorization the payee submits
  bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
    'ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)'
  );

  /// @notice The fee taken from every transfer between two accounts, in basis points, and burned
  uint256 public feeBps;

  /// @inheritdoc IERC3009
  mapping(address _authorizer => mapping(bytes32 _nonce => bool _used)) public authorizationState;

  constructor() ERC20('Mock USD', 'mUSD') EIP712('Mock USD', '2') {}

  /**
   * @notice Mints to an account
   * @param _to The receiver
   * @param _amount The amount
   */
  function mint(
    address _to,
    uint256 _amount
  ) external {
    _mint(_to, _amount);
  }

  /**
   * @notice Sets the transfer fee
   * @param _feeBps The fee in basis points
   */
  function setFeeBps(
    uint256 _feeBps
  ) external {
    feeBps = _feeBps;
  }

  /// @inheritdoc IERC3009
  function receiveWithAuthorization(
    address _from,
    address _to,
    uint256 _value,
    uint256 _validAfter,
    uint256 _validBefore,
    bytes32 _nonce,
    bytes calldata _signature
  ) external {
    require(_to == msg.sender, 'MockERC3009: caller must be the payee');
    require(block.timestamp > _validAfter, 'MockERC3009: authorization is not yet valid');
    require(block.timestamp < _validBefore, 'MockERC3009: authorization is expired');
    require(!authorizationState[_from][_nonce], 'MockERC3009: authorization is used');
    bytes32 _digest = _hashTypedDataV4(
      keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, _from, _to, _value, _validAfter, _validBefore, _nonce))
    );
    require(SignatureChecker.isValidSignatureNow(_from, _digest, _signature), 'MockERC3009: invalid signature');
    authorizationState[_from][_nonce] = true;
    _transfer(_from, _to, _value);
  }

  /// @inheritdoc ERC20
  function decimals() public pure override returns (uint8 _decimals) {
    _decimals = 6;
  }

  /// @inheritdoc ERC20
  function _update(
    address _from,
    address _to,
    uint256 _value
  ) internal virtual override {
    if (feeBps != 0 && _from != address(0) && _to != address(0)) {
      uint256 _fee = (_value * feeBps) / 10_000;
      super._update(_from, address(0), _fee);
      super._update(_from, _to, _value - _fee);
    } else {
      super._update(_from, _to, _value);
    }
  }
}
