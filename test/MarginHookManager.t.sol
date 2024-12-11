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
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: key.toId(),
            amount0: 1e18,
            amount1: 1e18,
            tickLower: 50000,
            tickUpper: 50000,
            to: address(this),
            deadline: type(uint256).max
        });
        hookManager.addLiquidity(params);
        uint256 uPoolId = uint256(PoolId.unwrap(key.toId()));
        uint256 liquidity = hookManager.balanceOf(address(this), uPoolId);
        (uint256 _reserves0, uint256 _reserves1) = hookManager.getReserves(key.toId());
        assertEq(_reserves0, _reserves1);
        console.log("_reserves0:%s,_reserves1:%s", _reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams =
            RemoveLiquidityParams({poolId: key.toId(), liquidity: liquidity / 2, deadline: type(uint256).max});
        hookManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = hookManager.balanceOf(address(this), uPoolId);
        assertEq(liquidityHalf, liquidity - liquidity / 2);

        params = AddLiquidityParams({
            poolId: nativeKey.toId(),
            amount0: 1e18,
            amount1: 1e18,
            tickLower: 50000,
            tickUpper: 50000,
            to: address(this),
            deadline: type(uint256).max
        });
        hookManager.addLiquidity{value: 1 ether}(params);
        uPoolId = uint256(PoolId.unwrap(nativeKey.toId()));
        liquidity = hookManager.balanceOf(address(this), uPoolId);
        (_reserves0, _reserves1) = hookManager.getReserves(nativeKey.toId());
        assertEq(_reserves0, _reserves1);
        console.log("_reserves0:%s,_reserves1:%s", _reserves0, _reserves1);
        removeParams =
            RemoveLiquidityParams({poolId: nativeKey.toId(), liquidity: liquidity / 2, deadline: type(uint256).max});
        hookManager.removeLiquidity(removeParams);
        liquidityHalf = hookManager.balanceOf(address(this), uPoolId);
        assertEq(liquidityHalf, liquidity - liquidity / 2);
    }

    function test_hook_liquidity_tokens() public {
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: key.toId(),
            amount0: 1e18,
            amount1: 1e18,
            tickLower: 50000,
            tickUpper: 50000,
            to: address(this),
            deadline: type(uint256).max
        });
        hookManager.addLiquidity(params);
        uint256 uPoolId = uint256(PoolId.unwrap(key.toId()));
        uint256 liquidity = hookManager.balanceOf(address(this), uPoolId);
        (uint256 _reserves0, uint256 _reserves1) = hookManager.getReserves(key.toId());
        assertEq(_reserves0, _reserves1);
        console.log("_reserves0:%s,_reserves1:%s", _reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams =
            RemoveLiquidityParams({poolId: key.toId(), liquidity: liquidity / 2, deadline: type(uint256).max});
        hookManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = hookManager.balanceOf(address(this), uPoolId);
        assertEq(liquidityHalf, liquidity - liquidity / 2);
    }

    function test_hook_liquidity_usdt_tokens() public {
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: usdtKey.toId(),
            amount0: 1e18,
            amount1: 1e18,
            tickLower: 50000,
            tickUpper: 50000,
            to: address(this),
            deadline: type(uint256).max
        });
        hookManager.addLiquidity(params);
        uint256 uPoolId = uint256(PoolId.unwrap(key.toId()));
        uint256 liquidity = hookManager.balanceOf(address(this), uPoolId);
        (uint256 _reserves0, uint256 _reserves1) = hookManager.getReserves(key.toId());
        assertEq(_reserves0, _reserves1);
        console.log("_reserves0:%s,_reserves1:%s", _reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams =
            RemoveLiquidityParams({poolId: usdtKey.toId(), liquidity: liquidity / 2, deadline: type(uint256).max});
        hookManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = hookManager.balanceOf(address(this), uPoolId);
        assertEq(liquidityHalf, liquidity - liquidity / 2);
    }
}
