// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {UniswapV2Pair} from "../src/UniswapV2Pair.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {FactoryStub} from "./mocks/FactoryStub.sol";

/// @notice Drives UniswapV2Pair through the action sequences an invariant campaign
/// fuzzes over. Each external function here is one "handler action": inputs are
/// bounded to values that mostly succeed, so depth is spent exploring interesting
/// states rather than on guaranteed reverts. Every action updates the ghost state the
/// test contract's `invariant_*` functions check.
contract Handler is Test {
    UniswapV2Pair public immutable pair;
    ERC20Mock public immutable token0;
    ERC20Mock public immutable token1;
    FactoryStub public immutable factoryStub;
    address public constant FEE_COLLECTOR = address(0xFEE);

    address[] public actors;
    address public currentActor;

    /// @dev Latched true the moment a swap is observed to reduce reserve0 * reserve1.
    /// Should never happen - checked by invariant_swapNeverDecreasesK.
    bool public ghost_kViolation;

    uint256 public ghost_mintCalls;
    uint256 public ghost_mintSuccesses;
    uint256 public ghost_burnCalls;
    uint256 public ghost_burnSuccesses;
    uint256 public ghost_swapCalls;
    uint256 public ghost_swapSuccesses;
    uint256 public ghost_syncCalls;
    uint256 public ghost_skimCalls;
    uint256 public ghost_feeToggleCalls;

    constructor(
        UniswapV2Pair _pair,
        ERC20Mock _token0,
        ERC20Mock _token1,
        FactoryStub _factoryStub,
        address[] memory _actors
    ) {
        pair = _pair;
        token0 = _token0;
        token1 = _token1;
        factoryStub = _factoryStub;
        actors = _actors;
    }

    modifier useActor(uint256 actorSeed) {
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    // --- read helpers for the test contract's invariants ----------------------

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function sumActorLPBalances() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += pair.balanceOf(actors[i]);
        }
    }

    // --- handler actions --------------------------------------------------

    function addLiquidity(uint256 actorSeed, uint256 amount0Seed, uint256 amount1Seed) external useActor(actorSeed) {
        ghost_mintCalls++;
        uint256 amount0 = bound(amount0Seed, 1e6, 1e24);
        uint256 amount1 = bound(amount1Seed, 1e6, 1e24);

        token0.mint(currentActor, amount0);
        token1.mint(currentActor, amount1);
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);

        try pair.mint(currentActor) returns (uint256) {
            ghost_mintSuccesses++;
        } catch {}
    }

    function removeLiquidity(uint256 actorSeed, uint256 liquiditySeed) external useActor(actorSeed) {
        ghost_burnCalls++;
        uint256 lpBalance = pair.balanceOf(currentActor);
        if (lpBalance == 0) return;
        uint256 liquidity = bound(liquiditySeed, 1, lpBalance);

        pair.transfer(address(pair), liquidity);
        try pair.burn(currentActor) returns (uint256, uint256) {
            ghost_burnSuccesses++;
        } catch {}
    }

    function swap0For1(uint256 actorSeed, uint256 amountInSeed) external useActor(actorSeed) {
        _swap(true, amountInSeed);
    }

    function swap1For0(uint256 actorSeed, uint256 amountInSeed) external useActor(actorSeed) {
        _swap(false, amountInSeed);
    }

    function _swap(bool zeroForOne, uint256 amountInSeed) internal {
        ghost_swapCalls++;
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) return; // pool not seeded yet

        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
        ERC20Mock tokenIn = zeroForOne ? token0 : token1;

        // Fixed, reserve-independent range: keeps `bound`'s min <= max regardless of how
        // small reserves have shrunk to, and stays well under the uint112 balance cap
        // enforced in _update so most calls actually reach the K check instead of
        // reverting on OVERFLOW.
        uint256 amountIn = bound(amountInSeed, 1, 1e26);

        // Replicates the router's getAmountOut formula so the call is very likely to
        // satisfy the pair's own K check instead of reverting.
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        uint256 amountOut = numerator / denominator;
        if (amountOut == 0) return; // would revert with INSUFFICIENT_OUTPUT_AMOUNT

        tokenIn.mint(currentActor, amountIn);
        tokenIn.transfer(address(pair), amountIn);

        uint256 kBefore = uint256(reserve0) * uint256(reserve1);
        (uint256 out0, uint256 out1) = zeroForOne ? (uint256(0), amountOut) : (amountOut, uint256(0));

        try pair.swap(out0, out1, currentActor, "") {
            ghost_swapSuccesses++;
            (uint112 r0After, uint112 r1After,) = pair.getReserves();
            uint256 kAfter = uint256(r0After) * uint256(r1After);
            if (kAfter < kBefore) {
                ghost_kViolation = true;
            }
        } catch {}
    }

    function skim(uint256 actorSeed, uint256 toSeed) external useActor(actorSeed) {
        ghost_skimCalls++;
        address to = actors[bound(toSeed, 0, actors.length - 1)];
        try pair.skim(to) {} catch {}
    }

    function sync(uint256 actorSeed) external useActor(actorSeed) {
        ghost_syncCalls++;
        try pair.sync() {} catch {}
    }


    /// @dev Flips the protocol fee on/off so the invariant run exercises both branches
    /// of _mintFee, not just the fee-off default.
    function toggleFee(uint256 seed) external {
        ghost_feeToggleCalls++;
        bool turnOn = seed % 2 == 0;
        factoryStub.setFeeTo(turnOn ? FEE_COLLECTOR : address(0));
    }
}
