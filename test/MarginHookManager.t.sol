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

contract MarginHookManagerTest is DeployHelper {
    function setUp() public {
        deployHookAndRouter();
    }

    function test_hook_liquidity_native() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 1 ether;
        PoolId poolId = nativeKey.toId();
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: poolId,
            amount0: amount0,
            amount1: amount1,
            tickLower: 50000,
            tickUpper: 50000,
            to: address(this),
            level: 4,
            deadline: type(uint256).max
        });
        hookManager.addLiquidity{value: amount0}(params);
        uint256 uPoolId = marginLiquidity.getPoolId(poolId);
        uint256 liquidity = marginLiquidity.balanceOf(address(this), marginLiquidity.getLevelPool(uPoolId, 4));
        assertGt(liquidity, 0);
        (uint256 _reserves0, uint256 _reserves1) = hookManager.getReserves(poolId);
        assertEq(_reserves0, amount0);
        assertEq(_reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams =
            RemoveLiquidityParams({poolId: poolId, level: 4, liquidity: liquidity / 2, deadline: type(uint256).max});
        hookManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = marginLiquidity.balanceOf(address(this), marginLiquidity.getLevelPool(uPoolId, 4));
        assertEq(liquidityHalf, liquidity - liquidity / 2);
    }

    function test_hook_liquidity_tokens() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 1 ether;
        PoolId poolId = key.toId();
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: key.toId(),
            amount0: amount0,
            amount1: amount1,
            tickLower: 50000,
            tickUpper: 50000,
            to: address(this),
            level: 4,
            deadline: type(uint256).max
        });
        hookManager.addLiquidity(params);
        uint256 uPoolId = marginLiquidity.getPoolId(poolId);
        uint256 liquidity = marginLiquidity.balanceOf(address(this), marginLiquidity.getLevelPool(uPoolId, 4));
        assertGt(liquidity, 0);
        (uint256 _reserves0, uint256 _reserves1) = hookManager.getReserves(poolId);
        assertEq(_reserves0, amount0);
        assertEq(_reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams =
            RemoveLiquidityParams({poolId: poolId, level: 4, liquidity: liquidity / 2, deadline: type(uint256).max});
        hookManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = marginLiquidity.balanceOf(address(this), marginLiquidity.getLevelPool(uPoolId, 4));
        assertEq(liquidityHalf, liquidity - liquidity / 2);
    }

    function test_hook_liquidity_usdt_tokens() public {
        PoolId poolId = usdtKey.toId();
        uint256 amount0 = 1 ether;
        uint256 amount1 = 1 ether;
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: poolId,
            amount0: amount0,
            amount1: amount1,
            tickLower: 50000,
            tickUpper: 50000,
            to: address(this),
            level: 4,
            deadline: type(uint256).max
        });
        hookManager.addLiquidity{value: amount0}(params);
        uint256 uPoolId = marginLiquidity.getPoolId(poolId);
        console.logBytes32(PoolId.unwrap(poolId));
        console.logBytes32(bytes32(marginLiquidity.getLevelPool(uPoolId, 0)));
        console.logBytes32(bytes32(marginLiquidity.getLevelPool(uPoolId, 1)));
        console.logBytes32(bytes32(marginLiquidity.getLevelPool(uPoolId, 2)));
        console.logBytes32(bytes32(marginLiquidity.getLevelPool(uPoolId, 3)));
        console.logBytes32(bytes32(marginLiquidity.getLevelPool(uPoolId, 4)));
        uint256 liquidity = marginLiquidity.balanceOf(address(this), marginLiquidity.getLevelPool(uPoolId, 4));
        assertGt(liquidity, 0);
        (uint256 _reserves0, uint256 _reserves1) = hookManager.getReserves(poolId);
        assertEq(_reserves0, amount0);
        assertEq(_reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams =
            RemoveLiquidityParams({poolId: poolId, level: 4, liquidity: liquidity / 2, deadline: type(uint256).max});
        hookManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = marginLiquidity.balanceOf(address(this), marginLiquidity.getLevelPool(uPoolId, 4));
        assertEq(liquidityHalf, liquidity - liquidity / 2);
    }

    function test_hook_liquidity_fee() public {
        address user = vm.addr(1);
        tokenUSDT.transfer(user, 10 ether);
        (bool success,) = user.call{value: 10 ether}("");
        assertTrue(success);
        PoolId poolId = usdtKey.toId();
        {
            vm.startPrank(user);
            uint256 amount0 = 1 ether;
            uint256 amount1 = 1 ether;
            tokenUSDT.approve(address(hookManager), amount1);
            AddLiquidityParams memory params = AddLiquidityParams({
                poolId: poolId,
                amount0: amount0,
                amount1: amount1,
                tickLower: 50000,
                tickUpper: 50000,
                to: user,
                level: 4,
                deadline: type(uint256).max
            });
            hookManager.addLiquidity{value: amount0}(params);
            vm.stopPrank();
        }
        uint256 uPoolId = marginLiquidity.getPoolId(poolId);
        uint256 feeLiquidity = marginLiquidity.balanceOf(address(this), marginLiquidity.getLevelPool(uPoolId, 4));
        console.log("feeLiquidity:%s,kLast:%s", feeLiquidity, hookManager.kLast());
        {
            vm.startPrank(user);
            uint256 amount0 = 1 ether;
            uint256 amount1 = 1 ether;
            tokenUSDT.approve(address(hookManager), amount1);
            AddLiquidityParams memory params = AddLiquidityParams({
                poolId: poolId,
                amount0: amount0,
                amount1: amount1,
                tickLower: 50000,
                tickUpper: 50000,
                to: user,
                level: 4,
                deadline: type(uint256).max
            });
            hookManager.addLiquidity{value: amount0}(params);
            vm.stopPrank();
        }
        feeLiquidity = marginLiquidity.balanceOf(address(this), marginLiquidity.getLevelPool(uPoolId, 4));
        console.log("feeLiquidity:%s,kLast:%s", feeLiquidity, hookManager.kLast());
        {
            vm.startPrank(user);
            uint256 amount0 = 1 ether;
            uint256 amount1 = 1 ether;
            tokenUSDT.approve(address(hookManager), amount1);
            AddLiquidityParams memory params = AddLiquidityParams({
                poolId: poolId,
                amount0: amount0,
                amount1: amount1,
                tickLower: 50000,
                tickUpper: 50000,
                to: user,
                level: 4,
                deadline: type(uint256).max
            });
            hookManager.addLiquidity{value: amount0}(params);
            vm.stopPrank();
        }
        feeLiquidity = marginLiquidity.balanceOf(address(this), marginLiquidity.getLevelPool(uPoolId, 4));
        console.log("feeLiquidity:%s,kLast:%s", feeLiquidity, hookManager.kLast());
        {
            uint256 amountIn = 0.0123 ether;
            // swap
            uint256 balance0 = manager.balanceOf(address(hookManager), 0);
            uint256 balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenUSDT)));
            console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
            MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
                poolId: poolId,
                zeroForOne: true,
                to: address(this),
                amountIn: amountIn,
                amountOut: 0,
                amountOutMin: 0,
                deadline: type(uint256).max
            });
            swapRouter.exactInput{value: amountIn}(swapParams);
            balance0 = manager.balanceOf(address(hookManager), 0);
            balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenUSDT)));
            console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        }
        {
            uint256 amountIn = 0.0123 ether;
            // swap
            uint256 balance0 = manager.balanceOf(address(hookManager), 0);
            uint256 balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenUSDT)));
            console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
            MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
                poolId: poolId,
                zeroForOne: false,
                to: address(this),
                amountIn: amountIn,
                amountOut: 0,
                amountOutMin: 0,
                deadline: type(uint256).max
            });
            swapRouter.exactInput{value: amountIn}(swapParams);
            balance0 = manager.balanceOf(address(hookManager), 0);
            balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenUSDT)));
            console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        }
        {
            vm.startPrank(user);
            uint256 liquidity = marginLiquidity.balanceOf(user, marginLiquidity.getLevelPool(uPoolId, 4));
            assertGt(liquidity, 0);
            RemoveLiquidityParams memory removeParams =
                RemoveLiquidityParams({poolId: poolId, level: 4, liquidity: liquidity / 2, deadline: type(uint256).max});
            hookManager.removeLiquidity(removeParams);
            vm.stopPrank();
        }
        feeLiquidity = marginLiquidity.balanceOf(address(this), marginLiquidity.getLevelPool(uPoolId, 4));
        console.log("feeLiquidity:%s,kLast:%s", feeLiquidity, hookManager.kLast());
    }

    function addLiquidity(
        address user,
        PoolId poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 tickLower,
        uint256 tickUpper,
        uint8 level
    ) internal returns (uint256) {
        vm.startPrank(user);
        tokenUSDT.approve(address(hookManager), amount1);
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: poolId,
            amount0: amount0,
            amount1: amount1,
            tickLower: tickLower,
            tickUpper: tickUpper,
            to: user,
            level: level,
            deadline: type(uint256).max
        });
        uint256 liquidity = hookManager.addLiquidity{value: amount0}(params);
        vm.stopPrank();
        return liquidity;
    }

    function test_hook_liquidity_level() public {
        address user = vm.addr(1);
        tokenUSDT.transfer(user, 10 ether);
        (bool success,) = user.call{value: 10 ether}("");
        assertTrue(success);
        PoolId poolId = usdtKey.toId();
        uint256 level1 = addLiquidity(user, poolId, 0.1 ether, 0.1 ether, 50000, 50000, 1);
        uint256 level2 = addLiquidity(user, poolId, 0.2 ether, 0.2 ether, 50000, 50000, 2);
        uint256 level3 = addLiquidity(user, poolId, 0.3 ether, 0.3 ether, 50000, 50000, 3);
        uint256 level4 = addLiquidity(user, poolId, 0.4 ether, 0.4 ether, 50000, 50000, 4);
        uint256[4] memory liquidities = marginLiquidity.getPoolLiquidities(poolId, user);
        (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1) =
            marginLiquidity.getPoolSupplies(address(hookManager), poolId);
        assertEq(level1, liquidities[0]);
        assertEq(level2, liquidities[1]);
        assertEq(level3, liquidities[2]);
        assertEq(level4, liquidities[3]);
        assertEq(level1 + level2 + level3 + level4 + 1000, totalSupply);
        assertEq(level1 + level2, retainSupply0);
        assertEq(level1 + level3, retainSupply1);
        {
            vm.startPrank(user);
            uint256 liquidity = 0.2 ether;
            RemoveLiquidityParams memory params =
                RemoveLiquidityParams({poolId: poolId, liquidity: liquidity, level: 4, deadline: type(uint256).max});
            hookManager.removeLiquidity(params);
            vm.stopPrank();
        }
        liquidities = marginLiquidity.getPoolLiquidities(poolId, user);
        assertEq(level4 - 0.2 ether, liquidities[3]);
    }

    function test_OutOfRange() public {
        address user = vm.addr(1);
        tokenUSDT.transfer(user, 10 ether);
        (bool success,) = user.call{value: 10 ether}("");
        assertTrue(success);
        PoolId poolId = usdtKey.toId();
        addLiquidity(user, poolId, 0.1 ether, 0.1 ether, 50000, 50000, 1);
        vm.startPrank(user);
        uint256 amount0 = 0.1 ether;
        uint256 amount1 = 0.09 ether;
        tokenUSDT.approve(address(hookManager), amount1);
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: poolId,
            amount0: amount0,
            amount1: amount1,
            tickLower: 50000,
            tickUpper: 50000,
            to: user,
            level: 1,
            deadline: type(uint256).max
        });
        vm.expectRevert(bytes("OUT_OF_RANGE"));
        hookManager.addLiquidity{value: amount0}(params);
        vm.stopPrank();
    }
}
