// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {PairPoolManager} from "../src/PairPoolManager.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {PoolStatus} from "../src/types/PoolStatus.sol";
import {PoolStatusLibrary} from "../src/types/PoolStatusLibrary.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition} from "../src/types/MarginPosition.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "../src/types/LiquidityParams.sol";
import {LiquidityLevel} from "../src/libraries/LiquidityLevel.sol";
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

contract PairPoolManagerTest is DeployHelper {
    using LiquidityLevel for uint8;
    using PoolStatusLibrary for PoolStatus;

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
            to: address(this),
            level: LiquidityLevel.BORROW_BOTH,
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: amount0}(params);
        uint256 uPoolId = marginLiquidity.getPoolId(poolId);
        uint256 liquidity = marginLiquidity.balanceOf(address(this), LiquidityLevel.BORROW_BOTH.getLevelId(uPoolId));
        assertGt(liquidity, 0);
        (uint256 _reserves0, uint256 _reserves1) = pairPoolManager.getReserves(poolId);
        assertEq(_reserves0, amount0);
        assertEq(_reserves0, _reserves1);
        vm.warp(3600);
        RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
            poolId: poolId,
            level: LiquidityLevel.BORROW_BOTH,
            liquidity: liquidity / 2,
            deadline: type(uint256).max
        });
        vm.roll(100);
        pairPoolManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = marginLiquidity.balanceOf(address(this), LiquidityLevel.BORROW_BOTH.getLevelId(uPoolId));
        assertEq(liquidityHalf, liquidity - liquidity / 2);
        removeParams = RemoveLiquidityParams({
            poolId: poolId,
            level: LiquidityLevel.BORROW_BOTH,
            liquidity: liquidityHalf,
            deadline: type(uint256).max
        });
        vm.roll(100);
        vm.warp(3600 * 2);
        pairPoolManager.removeLiquidity(removeParams);
        liquidityHalf = marginLiquidity.balanceOf(address(this), LiquidityLevel.BORROW_BOTH.getLevelId(uPoolId));
        console.log("remove all liquidity:%s", liquidityHalf);
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        console.log("status.reserve0:%s,status.reserve1:%s", status.reserve0(), status.reserve1());
        assertEq(status.marginFee, 0);
        (uint24 _fee, uint24 _marginFee) = marginFees.getPoolFees(address(pairPoolManager), poolId, true, 0, 0);
        assertEq(_fee, 3000);
        assertEq(_marginFee, 3000);
    }

    function testLiquidityNativeOne() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 1 ether;
        PoolId poolId = nativeKey.toId();
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: poolId,
            amount0: amount0,
            amount1: amount1,
            to: address(this),
            level: LiquidityLevel.RETAIN_BOTH,
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: amount0}(params);
        uint256 uPoolId = marginLiquidity.getPoolId(poolId);
        uint256 liquidity = marginLiquidity.balanceOf(address(this), LiquidityLevel.RETAIN_BOTH.getLevelId(uPoolId));
        assertGt(liquidity, 0);
        (uint256 _reserves0, uint256 _reserves1) = pairPoolManager.getReserves(poolId);
        assertEq(_reserves0, amount0);
        assertEq(_reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
            poolId: poolId,
            level: LiquidityLevel.RETAIN_BOTH,
            liquidity: liquidity / 2,
            deadline: type(uint256).max
        });
        vm.roll(100);
        vm.warp(3600);
        pairPoolManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = marginLiquidity.balanceOf(address(this), LiquidityLevel.RETAIN_BOTH.getLevelId(uPoolId));
        assertEq(liquidityHalf, liquidity - liquidity / 2);
        removeParams = RemoveLiquidityParams({
            poolId: poolId,
            level: LiquidityLevel.RETAIN_BOTH,
            liquidity: liquidityHalf,
            deadline: type(uint256).max
        });
        vm.roll(100);
        vm.warp(3600 * 2);
        pairPoolManager.removeLiquidity(removeParams);
        liquidityHalf = marginLiquidity.balanceOf(address(this), LiquidityLevel.RETAIN_BOTH.getLevelId(uPoolId));
        console.log("remove all liquidity:%s", liquidityHalf);
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        console.log("status.reserve0:%s,status.reserve1:%s", status.reserve0(), status.reserve1());
        params = AddLiquidityParams({
            poolId: poolId,
            amount0: amount0,
            amount1: amount1 * 2,
            to: address(this),
            level: LiquidityLevel.RETAIN_BOTH,
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: amount0}(params);
    }

    function test_hook_liquidity_tokens() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 1 ether;
        PoolId poolId = tokensKey.toId();
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: tokensKey.toId(),
            amount0: amount0,
            amount1: amount1,
            to: address(this),
            level: 4,
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity(params);
        uint256 uPoolId = marginLiquidity.getPoolId(poolId);
        uint256 liquidity = marginLiquidity.balanceOf(address(this), LiquidityLevel.BORROW_BOTH.getLevelId(uPoolId));
        assertGt(liquidity, 0);
        (uint256 _reserves0, uint256 _reserves1) = pairPoolManager.getReserves(poolId);
        assertEq(_reserves0, amount0);
        assertEq(_reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams =
            RemoveLiquidityParams({poolId: poolId, level: 4, liquidity: liquidity / 2, deadline: type(uint256).max});
        vm.roll(100);
        skip(100);
        pairPoolManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = marginLiquidity.balanceOf(address(this), LiquidityLevel.BORROW_BOTH.getLevelId(uPoolId));
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
            to: address(this),
            level: 4,
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: amount0}(params);
        uint256 uPoolId = marginLiquidity.getPoolId(poolId);
        uint256 liquidity = marginLiquidity.balanceOf(address(this), LiquidityLevel.BORROW_BOTH.getLevelId(uPoolId));
        assertGt(liquidity, 0);
        (uint256 _reserves0, uint256 _reserves1) = pairPoolManager.getReserves(poolId);
        assertEq(_reserves0, amount0);
        assertEq(_reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams =
            RemoveLiquidityParams({poolId: poolId, level: 4, liquidity: liquidity / 2, deadline: type(uint256).max});
        vm.roll(100);
        skip(100);
        pairPoolManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = marginLiquidity.balanceOf(address(this), LiquidityLevel.BORROW_BOTH.getLevelId(uPoolId));
        assertEq(liquidityHalf, liquidity - liquidity / 2);
    }

    function addLiquidity(address user, PoolId poolId, uint256 amount0, uint256 amount1, uint8 level)
        internal
        returns (uint256)
    {
        vm.startPrank(user);
        tokenUSDT.approve(address(pairPoolManager), amount1);
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: poolId,
            amount0: amount0,
            amount1: amount1,
            to: user,
            level: level,
            deadline: type(uint256).max
        });
        uint256 liquidity = pairPoolManager.addLiquidity{value: amount0}(params);
        vm.stopPrank();
        return liquidity;
    }

    function test_hook_liquidity_level() public {
        address user = vm.addr(1);
        tokenUSDT.transfer(user, 10 ether);
        (bool success,) = user.call{value: 10 ether}("");
        assertTrue(success);
        PoolId poolId = usdtKey.toId();
        uint256 level1 = addLiquidity(user, poolId, 0.1 ether, 0.1 ether, LiquidityLevel.RETAIN_BOTH);
        uint256 level2 = addLiquidity(user, poolId, 0.2 ether, 0.2 ether, LiquidityLevel.BORROW_TOKEN0);
        uint256 level3 = addLiquidity(user, poolId, 0.3 ether, 0.3 ether, LiquidityLevel.BORROW_TOKEN1);
        uint256 level4 = addLiquidity(user, poolId, 0.4 ether, 0.4 ether, LiquidityLevel.BORROW_BOTH);
        uint256[4] memory liquidities = marginLiquidity.getPoolLiquidities(poolId, user);
        (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1) =
            marginLiquidity.getPoolSupplies(address(pairPoolManager), poolId);
        assertEq(level1, liquidities[0]);
        assertEq(level2, liquidities[1]);
        assertEq(level3, liquidities[2]);
        assertEq(level4, liquidities[3]);
        assertEq(level1 + level2 + level3 + level4, totalSupply);
        assertEq(level1 + level3, retainSupply0);
        assertEq(level1 + level2, retainSupply1);
        {
            vm.startPrank(user);
            uint256 liquidity = 0.2 ether;
            RemoveLiquidityParams memory params =
                RemoveLiquidityParams({poolId: poolId, liquidity: liquidity, level: 4, deadline: type(uint256).max});
            vm.roll(100);
            skip(100);
            pairPoolManager.removeLiquidity(params);
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
        addLiquidity(user, poolId, 0.1 ether, 0.1 ether, LiquidityLevel.BORROW_TOKEN0);
        vm.startPrank(user);
        uint256 amount0 = 0.1 ether;
        uint256 amount1 = 0.09 ether;
        tokenUSDT.approve(address(pairPoolManager), amount1);
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: poolId,
            amount0: amount0,
            amount1: amount1,
            to: user,
            level: 1,
            deadline: type(uint256).max
        });
        vm.expectRevert(bytes("OUT_OF_RANGE"));
        pairPoolManager.addLiquidity{value: amount0}(params);
        vm.stopPrank();
    }

    function testRemoveAll() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 1 ether;
        PoolId poolId = nativeKey.toId();
        uint256 uPoolId = marginLiquidity.getPoolId(poolId);
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: poolId,
            amount0: amount0,
            amount1: amount1,
            to: address(this),
            level: LiquidityLevel.BORROW_BOTH,
            deadline: type(uint256).max
        });
        uint256 liquidity = pairPoolManager.addLiquidity{value: amount0}(params);
        uint256 balance = marginLiquidity.balanceOf(address(this), LiquidityLevel.BORROW_BOTH.getLevelId(uPoolId));
        assertEq(liquidity, balance, "liquidity==balance");
        skip(1000);
        RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
            poolId: poolId,
            level: LiquidityLevel.BORROW_BOTH,
            liquidity: liquidity * 2,
            deadline: type(uint256).max
        });
        pairPoolManager.removeLiquidity(removeParams);
        balance = marginLiquidity.balanceOf(address(this), LiquidityLevel.BORROW_BOTH.getLevelId(uPoolId));
        assertEq(0, balance, "balance==0");
    }
}
