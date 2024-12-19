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
        uint256 uPoolId = marginFees.getPoolId(poolId);
        uint256 liquidity = marginLiquidity.balanceOf(address(this), marginFees.getLevelPool(uPoolId, 4));
        assertGt(liquidity, 0);
        (uint256 _reserves0, uint256 _reserves1) = hookManager.getReserves(poolId);
        assertEq(_reserves0, amount0);
        assertEq(_reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams =
            RemoveLiquidityParams({poolId: poolId, level: 4, liquidity: liquidity / 2, deadline: type(uint256).max});
        hookManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = marginLiquidity.balanceOf(address(this), marginFees.getLevelPool(uPoolId, 4));
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
        uint256 uPoolId = marginFees.getPoolId(poolId);
        uint256 liquidity = marginLiquidity.balanceOf(address(this), marginFees.getLevelPool(uPoolId, 4));
        assertGt(liquidity, 0);
        (uint256 _reserves0, uint256 _reserves1) = hookManager.getReserves(poolId);
        assertEq(_reserves0, amount0);
        assertEq(_reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams =
            RemoveLiquidityParams({poolId: poolId, level: 4, liquidity: liquidity / 2, deadline: type(uint256).max});
        hookManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = marginLiquidity.balanceOf(address(this), marginFees.getLevelPool(uPoolId, 4));
        assertEq(liquidityHalf, liquidity - liquidity / 2);
    }

    function test_hook_liquidity_usdt_tokens() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 1 ether;
        PoolId poolId = usdtKey.toId();
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
        uint256 uPoolId = marginFees.getPoolId(poolId);
        console.logBytes32(PoolId.unwrap(poolId));
        console.logBytes32(bytes32(marginFees.getLevelPool(uPoolId, 0)));
        console.logBytes32(bytes32(marginFees.getLevelPool(uPoolId, 1)));
        console.logBytes32(bytes32(marginFees.getLevelPool(uPoolId, 2)));
        console.logBytes32(bytes32(marginFees.getLevelPool(uPoolId, 3)));
        console.logBytes32(bytes32(marginFees.getLevelPool(uPoolId, 4)));
        uint256 liquidity = marginLiquidity.balanceOf(address(this), marginFees.getLevelPool(uPoolId, 4));
        assertGt(liquidity, 0);
        (uint256 _reserves0, uint256 _reserves1) = hookManager.getReserves(poolId);
        assertEq(_reserves0, amount0);
        assertEq(_reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams =
            RemoveLiquidityParams({poolId: poolId, level: 4, liquidity: liquidity / 2, deadline: type(uint256).max});
        hookManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = marginLiquidity.balanceOf(address(this), marginFees.getLevelPool(uPoolId, 4));
        assertEq(liquidityHalf, liquidity - liquidity / 2);
    }
}
