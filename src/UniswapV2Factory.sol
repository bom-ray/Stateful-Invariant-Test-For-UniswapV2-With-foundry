pragma solidity ^0.8.13;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    constructor(address _feeToSetter) {
        require(_feeToSetter != address(0), 'UniswapV2: ZERO_ADDRESS');
        feeToSetter = _feeToSetter;
        emit FeeToSetterChanged(address(0), _feeToSetter);
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        // `pair` is this contract's own freshly-deployed UniswapV2Pair (via CREATE2 above,
        // known bytecode), not attacker-supplied code, so there's no real reentrancy path here
        // forge-lint: disable-next-line(reentrancy-no-eth)
        IUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        // forge-lint: disable-next-line(reentrancy-events)
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    // forge-lint: disable-next-line(missing-zero-check)
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        // no zero-address check: address(0) is the valid sentinel that turns the
        // protocol fee off (see UniswapV2Pair._mintFee's `feeTo != address(0)` check)
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        require(_feeToSetter != address(0), 'UniswapV2: ZERO_ADDRESS');
        address previousFeeToSetter = feeToSetter;
        feeToSetter = _feeToSetter;
        emit FeeToSetterChanged(previousFeeToSetter, _feeToSetter);
    }
}
