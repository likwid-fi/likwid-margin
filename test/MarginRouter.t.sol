// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {PairPoolManager} from "../src/PairPoolManager.sol";
import {BaseFees} from "../src/base/BaseFees.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {MarginOracle} from "../src/MarginOracle.sol";
import {PoolStatus} from "../src/types/PoolStatus.sol";
import {MarginParams, MarginParamsVo} from "../src/types/MarginParams.sol";
import {MarginPosition} from "../src/types/MarginPosition.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "../src/types/LiquidityParams.sol";
import {CurrencyPoolLibrary} from "../src/libraries/CurrencyPoolLibrary.sol";
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
    using CurrencyPoolLibrary for Currency;

    function setUp() public {
        deployHookAndRouter();
        initPoolLiquidity();
    }

    function exactInputNative(uint256 amountIn, address user) internal {
        // swap
        uint256 balance0 = manager.balanceOf(address(pairPoolManager), 0);
        uint256 balance1 = manager.balanceOf(address(pairPoolManager), uint160(address(tokenB)));
        uint256 balanceB = tokenB.balanceOf(user);
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            poolId: nativeKey.toId(),
            zeroForOne: true,
            to: user,
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        uint256 amountOut = swapRouter.exactInput(swapParams);
        uint256 _balance0 = manager.balanceOf(address(pairPoolManager), 0);
        uint256 _balance1 = manager.balanceOf(address(pairPoolManager), uint160(address(tokenB)));
        uint256 _balanceB = tokenB.balanceOf(user);
        assertEq(amountIn, _balance0 - balance0);
        assertEq(amountOut, _balanceB - balanceB);
        assertEq(amountOut, balance1 - _balance1);
    }

    function test_hook_swap_native() public {
        address user = address(this);
        uint256 amountIn = 0.0123 ether;
        exactInputTokens(amountIn, user);
        amountIn = 0.0000123 ether;
        exactInputTokens(amountIn, user);
        amountIn = 1.23 ether;
        exactInputTokens(amountIn, user);
    }

    function test_hook_swap_native_out() public {
        address user = address(this);
        uint256 amountOut = 0.0123 ether;
        bool zeroForOne = true;
        // swap
        uint256 amountIn = pairPoolManager.getAmountIn(nativeKey.toId(), zeroForOne, amountOut);
        uint256 balance0 = manager.balanceOf(address(pairPoolManager), 0);
        uint256 balance1 = manager.balanceOf(address(pairPoolManager), uint160(address(tokenB)));
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
        balance0 = manager.balanceOf(address(pairPoolManager), 0);
        balance1 = manager.balanceOf(address(pairPoolManager), uint160(address(tokenB)));
        console.log("after swap hook.balance0:%s,hook.balance1:%s", balance0, balance1);

        // token => native
        zeroForOne = false;
        amountIn = pairPoolManager.getAmountIn(nativeKey.toId(), zeroForOne, amountOut);
        // swap
        balance0 = manager.balanceOf(address(pairPoolManager), 0);
        balance1 = manager.balanceOf(address(pairPoolManager), uint160(address(tokenB)));
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
        balance0 = manager.balanceOf(address(pairPoolManager), 0);
        balance1 = manager.balanceOf(address(pairPoolManager), uint160(address(tokenB)));
        console.log("after swap hook.balance0:%s,hook.balance1:%s", balance0, balance1);
    }

    function exactInputTokens(uint256 amountIn, address user) internal {
        // swap
        uint256 balance0 = manager.balanceOf(address(pairPoolManager), uint160(address(tokenA)));
        uint256 balance1 = manager.balanceOf(address(pairPoolManager), uint160(address(tokenB)));
        uint256 balanceA = tokenA.balanceOf(user);
        uint256 balanceB = tokenB.balanceOf(user);
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            poolId: key.toId(),
            zeroForOne: true,
            to: user,
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        uint256 amountOut = swapRouter.exactInput(swapParams);
        uint256 _balance0 = manager.balanceOf(address(pairPoolManager), uint160(address(tokenA)));
        uint256 _balance1 = manager.balanceOf(address(pairPoolManager), uint160(address(tokenB)));
        uint256 _balanceA = tokenA.balanceOf(user);
        uint256 _balanceB = tokenB.balanceOf(user);
        if (address(tokenA) < address(tokenB)) {
            assertEq(amountIn, _balance0 - balance0);
            assertEq(amountOut, _balanceB - balanceB);
            assertEq(amountOut, balance1 - _balance1);
        } else {
            assertEq(amountIn, _balance1 - balance1);
            assertEq(amountOut, _balanceA - balanceA);
            assertEq(amountOut, balance0 - _balance0);
        }
    }

    function test_hook_swap_tokens() public {
        address user = address(this);
        uint256 amountIn = 0.0123 ether;
        exactInputTokens(amountIn, user);
        amountIn = 0.0000123 ether;
        exactInputTokens(amountIn, user);
        amountIn = 1.23 ether;
        exactInputTokens(amountIn, user);
    }

    function test_hook_swap_usdts() public {
        address user = address(this);
        uint256 amountIn = 0.0123 ether;
        // swap
        uint256 balance0 = manager.balanceOf(address(pairPoolManager), 0);
        uint256 balance1 = manager.balanceOf(address(pairPoolManager), uint160(address(tokenUSDT)));
        uint256 balanceUSDT = tokenUSDT.balanceOf(user);
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            poolId: usdtKey.toId(),
            zeroForOne: true,
            to: user,
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        uint256 amountOut = swapRouter.exactInput{value: amountIn}(swapParams);
        uint256 _balance0 = manager.balanceOf(address(pairPoolManager), 0);
        uint256 _balance1 = manager.balanceOf(address(pairPoolManager), uint160(address(tokenUSDT)));
        uint256 _balanceUSDT = tokenUSDT.balanceOf(user);
        assertEq(amountIn, _balance0 - balance0);
        assertEq(amountOut, _balanceUSDT - balanceUSDT);
        assertEq(amountOut, balance1 - _balance1);
    }

    function testSwapMirror() public {
        console.log("pairPoolManager:%s", address(pairPoolManager));
        console.log("poolStatusManager:%s", address(poolStatusManager));
        console.log("SWAP.feeType:%s", uint256(BaseFees.FeeType.SWAP));
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), poolId, false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;

        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 1,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log(
            "pairPoolManager.balance:%s,marginPositionManager.balance:%s",
            address(pairPoolManager).balance,
            address(marginPositionManager).balance
        );
        console.log("positionId:%s,borrowAmount:%s", positionId, borrowAmount);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log(
            "positionId:%s,position.borrowAmount:%s,rateCumulativeLast:%s",
            positionId,
            position.borrowAmount,
            position.rateCumulativeLast
        );
        uint256 tokenBId = nativeKey.currency1.toTokenId(poolId);
        uint256 lb = lendingPoolManager.balanceOf(user, tokenBId);
        assertEq(lb, 0);
        uint256 amountIn = 0.001 ether;
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            poolId: poolId,
            zeroForOne: true,
            to: user,
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        uint256 amountOut = swapRouter.swapMirror{value: amountIn}(swapParams);
        lb = lendingPoolManager.balanceOf(user, tokenBId);
        console.log(amountOut, lb);
        assertEq(lb, amountOut);
    }
}
