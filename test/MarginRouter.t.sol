// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {MarginHookManager} from "../src/MarginHookManager.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {MarginOracle} from "../src/MarginOracle.sol";
import {HookParams} from "../src/types/HookParams.sol";
import {HookStatus} from "../src/types/HookStatus.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition} from "../src/types/MarginPosition.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "../src/types/LiquidityParams.sol";
// Solmate
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
// Forge
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
// V4
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

import {HookMiner} from "./utils/HookMiner.sol";
import {DeployHelper} from "./utils/DeployHelper.sol";

contract MarginRouterTest is DeployHelper {
    function setUp() public {
        deployHookAndRouter();
        initPoolLiquidity();
    }

    function test_hook_swap_native() public {
        uint256 amountIn = 0.0123 ether;
        address user = address(this);
        // swap
        uint256 balance0 = manager.balanceOf(address(hookManager), 0);
        uint256 balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        console.log("before swap user.balance:%s,tokenB:%s", address(this).balance, tokenB.balanceOf(address(this)));
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            poolId: nativeKey.toId(),
            zeroForOne: true,
            to: address(this),
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        swapRouter.exactInput{value: amountIn}(swapParams);
        console.log("swapRouter.balance:%s", manager.balanceOf(address(swapRouter), 0));
        console.log("after swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        balance0 = manager.balanceOf(address(hookManager), 0);
        balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        // token => native
        console.log("before swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        swapParams = MarginRouter.SwapParams({
            poolId: nativeKey.toId(),
            zeroForOne: false,
            to: user,
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        tokenB.approve(address(swapRouter), amountIn);
        swapRouter.exactInput(swapParams);
        console.log("swapRouter.balance:%s", manager.balanceOf(address(swapRouter), 0));
        console.log("after swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        balance0 = manager.balanceOf(address(hookManager), 0);
        balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
    }

    function test_hook_swap_native_out() public {
        address user = address(this);
        uint256 amountOut = 0.0123 ether;
        bool zeroForOne = true;
        // swap
        uint256 amountIn = hookManager.getAmountIn(nativeKey.toId(), zeroForOne, amountOut);
        uint256 balance0 = manager.balanceOf(address(hookManager), 0);
        uint256 balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("before swap hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            poolId: nativeKey.toId(),
            zeroForOne: zeroForOne,
            to: user,
            amountIn: 0,
            amountOut: amountOut,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        swapRouter.exactOutput{value: amountIn}(swapParams);
        balance0 = manager.balanceOf(address(hookManager), 0);
        balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("after swap hook.balance0:%s,hook.balance1:%s", balance0, balance1);

        // token => native
        zeroForOne = false;
        amountIn = hookManager.getAmountIn(nativeKey.toId(), zeroForOne, amountOut);
        tokenB.approve(address(swapRouter), amountIn);
        // swap
        balance0 = manager.balanceOf(address(hookManager), 0);
        balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("before swap hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        swapParams = MarginRouter.SwapParams({
            poolId: nativeKey.toId(),
            zeroForOne: zeroForOne,
            to: user,
            amountIn: 0,
            amountOut: amountOut,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        swapRouter.exactOutput(swapParams);
        balance0 = manager.balanceOf(address(hookManager), 0);
        balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("after swap hook.balance0:%s,hook.balance1:%s", balance0, balance1);
    }

    function test_hook_swap_tokens() public {
        address user = address(this);
        uint256 amountIn = 0.0123 ether;
        // swap
        uint256 balance0 = manager.balanceOf(address(hookManager), uint160(address(tokenA)));
        uint256 balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        console.log("before swap tokenA:%s,tokenB:%s", tokenA.balanceOf(user), tokenB.balanceOf(user));
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            poolId: key.toId(),
            zeroForOne: true,
            to: user,
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        tokenA.approve(address(swapRouter), amountIn);
        tokenB.approve(address(swapRouter), amountIn);
        swapRouter.exactInput(swapParams);
        console.log("swapRouter.balance:%s", manager.balanceOf(address(swapRouter), 0));
        console.log("after swap tokenA:%s,tokenB:%s", tokenA.balanceOf(user), tokenB.balanceOf(user));
        balance0 = manager.balanceOf(address(hookManager), uint160(address(tokenA)));
        balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
    }

    function test_hook_swap_usdts() public {
        address user = address(this);
        uint256 amountIn = 0.0123 ether;
        // swap
        uint256 balance0 = manager.balanceOf(address(hookManager), uint160(address(tokenA)));
        uint256 balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        console.log("before swap tokenA:%s,tokenB:%s", tokenA.balanceOf(user), tokenB.balanceOf(user));
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            poolId: key.toId(),
            zeroForOne: true,
            to: user,
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        tokenA.approve(address(swapRouter), amountIn);
        tokenB.approve(address(swapRouter), amountIn);
        swapRouter.exactInput(swapParams);
        console.log("swapRouter.balance:%s", manager.balanceOf(address(swapRouter), 0));
        console.log("after swap tokenA:%s,tokenB:%s", tokenA.balanceOf(user), tokenB.balanceOf(user));
        balance0 = manager.balanceOf(address(hookManager), uint160(address(tokenA)));
        balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
    }
}
