// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {UniswapV2Pair} from "../../src/UniswapV2Pair.sol";

/// @notice Stands in for UniswapV2Factory. UniswapV2Pair._mintFee() calls back into
/// `factory.feeTo()`, so the pair needs *some* contract at that address implementing
/// the selector - deploying the pair directly from a test/EOA with no matching
/// function there would make every mint()/burn() call revert. This stub also lets the
/// invariant suite flip the protocol fee on and off mid-run to exercise both branches
/// of _mintFee.
contract FactoryStub {
    address public feeTo;

    /// @dev Deploys the pair so `factory` (set in UniswapV2Pair's constructor from
    /// msg.sender) is this stub's own address, then initializes it.
    function deployPair(address token0, address token1) external returns (UniswapV2Pair pair) {
        pair = new UniswapV2Pair();
        pair.initialize(token0, token1);
    }

    function setFeeTo(address _feeTo) external {
        feeTo = _feeTo;
    }
}
