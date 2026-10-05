// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {UniswapV2Pair} from "../src/UniswapV2Pair.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {FactoryStub} from "./mocks/FactoryStub.sol";
import {Handler} from "./Handler.sol";

/// @title Stateful invariant tests for UniswapV2Pair
/// @notice Fuzzes long call sequences (mint/burn/swap/skim/sync/donate/fee-toggle,
/// each from one of a handful of actors) through a Handler contract, and checks a set
/// of properties that must hold no matter what sequence was played:
///
///   1. reserves never overstate the pair's actual token balances
///   2. reserves always fit in uint112 (the type _update stores them as)
///   3. LP totalSupply always equals what's tracked across actors/pair/burn-address
///   4. MINIMUM_LIQUIDITY, once locked, is never spent
///   5. a swap never decreases reserve0 * reserve1 (the core constant-product property)
///   6. the live k never falls below the kLast snapshot taken at the last mint/burn
contract UniswapV2PairInvariantTest is Test {
    UniswapV2Pair internal pair;
    ERC20Mock internal token0;
    ERC20Mock internal token1;
    FactoryStub internal factoryStub;
    Handler internal handler;

    uint256 internal constant MINIMUM_LIQUIDITY = 1000;

    function setUp() public {
        // Deploy two mock tokens and sort them the way the real factory would.
        ERC20Mock tokenA = new ERC20Mock("Token A", "TKA");
        ERC20Mock tokenB = new ERC20Mock("Token B", "TKB");
        (token0, token1) =
            address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        // FactoryStub deploys the pair (so `pair.factory()` points at a contract that
        // actually implements feeTo(), which _mintFee() calls on every mint/burn) and
        // initializes it with the two tokens.
        factoryStub = new FactoryStub();
        pair = factoryStub.deployPair(address(token0), address(token1));

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");
        actors[3] = makeAddr("dave");

        handler = new Handler(pair, token0, token1, factoryStub, actors);

        // Restrict the fuzzer to the handler's own action selectors only, so every call
        // into the pair goes through the handler's bookkeeping (ghost variables, bounded
        // inputs, actor pranking) instead of forge calling pair/token functions directly
        // with arbitrary senders and unbounded args.
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = Handler.addLiquidity.selector;
        selectors[1] = Handler.removeLiquidity.selector;
        selectors[2] = Handler.swap0For1.selector;
        selectors[3] = Handler.swap1For0.selector;
        selectors[4] = Handler.skim.selector;
        selectors[5] = Handler.sync.selector;
        selectors[6] = Handler.toggleFee.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // --- invariants -----------------------------------------------------------

    /// @dev Reserves can lag behind actual balances (a donation, or a surplus pending
    /// skim/sync) but must never overstate them - `_update` only ever sets reserves
    /// from a balance it just read, never higher.
    function invariant_reservesNeverExceedBalances() public view {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        assertGe(token0.balanceOf(address(pair)), reserve0, "reserve0 exceeds actual token0 balance");
        assertGe(token1.balanceOf(address(pair)), reserve1, "reserve1 exceeds actual token1 balance");
    }

    /// @dev `_update` already `require`s this on every write; asserting it here too
    /// means a regression surfaces as a named invariant failure with a full repro
    /// trace instead of a generic revert somewhere mid-sequence.
    function invariant_reservesFitInUint112() public view {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        assertLe(uint256(reserve0), uint256(type(uint112).max), "reserve0 overflowed uint112");
        assertLe(uint256(reserve1), uint256(type(uint112).max), "reserve1 overflowed uint112");
    }

    /// @dev LP-token conservation: every unit ever minted is either held by an actor,
    /// held by the protocol-fee recipient (toggleFee mints to Handler.FEE_COLLECTOR),
    /// sitting on the pair itself pending a burn() call, or permanently locked at
    /// address(0).
    function invariant_totalSupplyAccounting() public view {
        uint256 tracked = handler.sumActorLPBalances() + pair.balanceOf(handler.FEE_COLLECTOR())
            + pair.balanceOf(address(pair)) + pair.balanceOf(address(0));
        assertEq(pair.totalSupply(), tracked, "LP totalSupply doesn't match tracked balances");
    }

    /// @dev Once the pool has been minted into, MINIMUM_LIQUIDITY is permanently
    /// locked at address(0) (nothing can call burn() on its behalf) and totalSupply
    /// can never drop below it.
    function invariant_minimumLiquidityPermanentlyLocked() public view {
        if (pair.totalSupply() > 0) {
            assertGe(pair.totalSupply(), MINIMUM_LIQUIDITY, "totalSupply dropped below MINIMUM_LIQUIDITY");
            assertGe(pair.balanceOf(address(0)), MINIMUM_LIQUIDITY, "locked MINIMUM_LIQUIDITY was spent");
        }
    }

    /// @dev The core constant-product property: net of its 0.3% fee, a swap must never
    /// leave reserve0 * reserve1 lower than it was immediately beforehand. The actual
    /// before/after comparison happens inside Handler._swap around each swap call
    /// (that's the only place a "before this one call" snapshot is available); this
    /// just surfaces any violation as a named, always-checked invariant.
    function invariant_swapNeverDecreasesK() public view {
        assertFalse(handler.ghost_kViolation(), "a swap decreased reserve0 * reserve1");
    }

    /// @dev kLast is a snapshot of reserve0 * reserve1 taken immediately after the most
    /// recent mint/burn (only maintained while the protocol fee is on). Since swaps
    /// only ever grow k, the live product should never fall below that snapshot.
    function invariant_kLastNeverExceedsCurrentK() public view {
        uint256 kLast = pair.kLast();
        if (kLast == 0) return;
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        assertGe(uint256(reserve0) * uint256(reserve1), kLast, "current k fell below kLast");
    }

    /// @dev Not an invariant - forge calls this once at the end of every run. Useful to
    /// confirm the handler is actually generating successful mint/burn/swap calls
    /// rather than mostly reverting, which would make the invariants above vacuous.
    function afterInvariant() public view {
        console2.log("---- call summary ----");
        console2.log("mint     calls/success:", handler.ghost_mintCalls(), handler.ghost_mintSuccesses());
        console2.log("burn     calls/success:", handler.ghost_burnCalls(), handler.ghost_burnSuccesses());
        console2.log("swap     calls/success:", handler.ghost_swapCalls(), handler.ghost_swapSuccesses());
        console2.log("sync     calls:", handler.ghost_syncCalls());
        console2.log("skim     calls:", handler.ghost_skimCalls());
        console2.log("feeToggle calls:", handler.ghost_feeToggleCalls());
    }
}
