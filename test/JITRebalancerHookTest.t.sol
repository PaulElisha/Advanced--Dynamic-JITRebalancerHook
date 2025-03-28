// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console2, console, stdError} from "forge-std/Test.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import "@uniswap/v4-core/test/utils/Constants.sol";
import "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/src/types/BalanceDelta.sol";
import "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import "@uniswap/v4-core/src/libraries/Hooks.sol";
import {JITRebalancerHook} from "../src/JITRebalancerHook.sol";

contract JITRebalancerHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    JITRebalancerHook jitRebalancerHook;
    MockERC20 token0;
    MockERC20 token1;

    address pairPool;

    function setUp() public {
        deployFreshManagerAndRouters();

        token0 = new MockERC20();
        token0.mint(address(this), 1 ether);

        token1 = new MockERC20();
        token1.mint(address(this), 1 ether);

        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );

        address hookAddress = address(flags);

        deployCodeTo("JITRebalancerHook.sol", abi.encode(manager), hookAddress);
        jitRebalancerHook = JITRebalancerHook(hookAddress);

        token0.approve(address(swapRouter), type(uint256).max);
        // token1.approve(address(swapRouter), type(uint256).max);

        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        (key, ) = initPoolAndAddLiquidity(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            jitRebalancerHook,
            3000,
            SQRT_PRICE_1_1
        );
    }

    function testAfterAddLiquidity() public {
        uint128 poolLiquidityBefore = manager.getLiquidity(key.toId());
        console.log("Pool liquidity Before: %d", poolLiquidityBefore);

        uint256 minLiquidity = (uint256(poolLiquidityBefore) *
            jitRebalancerHook.THRESHOLD()) / 10000;

        console.log("Min liquidity: %d", minLiquidity);

        int256 liquidityDelta = int256(minLiquidity + 1 ether);

        console.log("Liquidity delta: %d", liquidityDelta);

        bytes memory hookData = abi.encode(address(this));

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager
            .ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            });

        BalanceDelta delta = modifyLiquidityRouter.modifyLiquidity(
            key,
            params,
            hookData
        );

        uint128 poolLiquidityAfter = manager.getLiquidity(key.toId());

        console.log("Pool liquidity After: %d", poolLiquidityAfter);

        console.log("Token0 delta: %d", delta.amount0());
        console.log("Token1 delta: %d", delta.amount1());

        assertLt(delta.amount0(), 0);
        assertLt(delta.amount1(), 0);

        JITRebalancerHook.Bid[] memory bids;

        bids = jitRebalancerHook.getBids(key.toId());

        console.log("Bids length: %d", bids.length);
        console.log("Bids[0].liquidity: %d", bids[0].liquidityDelta);
        assertEq(bids.length, 1);
        assertEq(bids[0].liquidityDelta, liquidityDelta);
    }

    function testBeforeSwap() public {
        testAfterAddLiquidity();

        uint128 poolLiquidity = manager.getLiquidity(key.toId());
        console.log("Pool liquidity Before Swap: %d", poolLiquidity);

        (, int24 tick, , ) = manager.getSlot0(key.toId());
        console2.log(" tick before swap: %d", tick);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -100000, // Large swap
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        BalanceDelta delta = swapRouter.swap(
            key,
            swapParams,
            testSettings,
            ZERO_BYTES
        );

        console.log("Token0 delta: %d", delta.amount0());
        console.log("Token1 delta: %d", delta.amount1());

        uint128 _poolLiquidity = manager.getLiquidity(key.toId());
        console.log("Pool liquidity After Swap: %d", _poolLiquidity);

        (, int24 _tick, , ) = manager.getSlot0(key.toId());
        console2.log(" tick after swap: %d", _tick);
    }
}
