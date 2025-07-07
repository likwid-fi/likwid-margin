// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {PairPoolManager} from "../src/PairPoolManager.sol";
import {MarginLiquidity} from "../src/MarginLiquidity.sol";
import {ERC6909Liquidity} from "../src/base/ERC6909Liquidity.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {PoolStatus} from "../src/types/PoolStatus.sol";
import {PoolStatusLibrary} from "../src/types/PoolStatusLibrary.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition} from "../src/types/MarginPosition.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "../src/types/LiquidityParams.sol";
// Solmate
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
// Forge
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
// Likwid V2
import {LikwidVault} from "likwid-v2-core/LikwidVault.sol";
import {Hooks} from "likwid-v2-core/libraries/Hooks.sol";
import {IHooks} from "likwid-v2-core/interfaces/IHooks.sol";
import {IPoolManager} from "likwid-v2-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "likwid-v2-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "likwid-v2-core/types/Currency.sol";
import {PoolKey} from "likwid-v2-core/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "likwid-v2-core/types/BalanceDelta.sol";

import {HookMiner} from "./utils/HookMiner.sol";
import {DeployHelper} from "./utils/DeployHelper.sol";

contract PairPoolManagerTest is DeployHelper {
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
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: amount0}(params);
        uint256 uPoolId = marginLiquidity.getPoolId(poolId);
        uint256 liquidity = marginLiquidity.balanceOf(address(this), uPoolId);
        assertGt(liquidity, 0);
        (uint256 _reserves0, uint256 _reserves1) = pairPoolManager.getReserves(poolId);
        assertEq(_reserves0, amount0);
        assertEq(_reserves0, _reserves1);
        vm.warp(3600);
        RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
            poolId: poolId,
            liquidity: liquidity / 2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        vm.roll(100);
        pairPoolManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = marginLiquidity.balanceOf(address(this), uPoolId);
        assertEq(liquidityHalf, liquidity - liquidity / 2);
        removeParams = RemoveLiquidityParams({
            poolId: poolId,
            liquidity: liquidityHalf,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        vm.roll(100);
        vm.warp(3600 * 2);
        pairPoolManager.removeLiquidity(removeParams);
        liquidityHalf = marginLiquidity.balanceOf(address(this), uPoolId);
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
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: amount0}(params);
        uint256 uPoolId = marginLiquidity.getPoolId(poolId);
        uint256 liquidity = marginLiquidity.balanceOf(address(this), uPoolId);
        assertGt(liquidity, 0);
        (uint256 _reserves0, uint256 _reserves1) = pairPoolManager.getReserves(poolId);
        assertEq(_reserves0, amount0);
        assertEq(_reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
            poolId: poolId,
            liquidity: liquidity / 2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        vm.roll(100);
        vm.warp(3600);
        pairPoolManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = marginLiquidity.balanceOf(address(this), uPoolId);
        assertEq(liquidityHalf, liquidity - liquidity / 2);
        removeParams = RemoveLiquidityParams({
            poolId: poolId,
            liquidity: liquidityHalf,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        vm.roll(100);
        vm.warp(3600 * 2);
        pairPoolManager.removeLiquidity(removeParams);
        liquidityHalf = marginLiquidity.balanceOf(address(this), uPoolId);
        console.log("remove all liquidity:%s", liquidityHalf);
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        console.log("status.reserve0:%s,status.reserve1:%s", status.reserve0(), status.reserve1());
        params = AddLiquidityParams({
            poolId: poolId,
            amount0: amount0,
            amount1: amount1 * 2,
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
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
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity(params);
        uint256 uPoolId = marginLiquidity.getPoolId(poolId);
        uint256 liquidity = marginLiquidity.balanceOf(address(this), uPoolId);
        assertGt(liquidity, 0);
        (uint256 _reserves0, uint256 _reserves1) = pairPoolManager.getReserves(poolId);
        assertEq(_reserves0, amount0);
        assertEq(_reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
            poolId: poolId,
            liquidity: liquidity / 2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        vm.roll(100);
        skip(100);
        pairPoolManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = marginLiquidity.balanceOf(address(this), uPoolId);
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
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: amount0}(params);
        uint256 uPoolId = marginLiquidity.getPoolId(poolId);
        uint256 liquidity = marginLiquidity.balanceOf(address(this), uPoolId);
        assertGt(liquidity, 0);
        (uint256 _reserves0, uint256 _reserves1) = pairPoolManager.getReserves(poolId);
        assertEq(_reserves0, amount0);
        assertEq(_reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
            poolId: poolId,
            liquidity: liquidity / 2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        vm.roll(100);
        skip(100);
        pairPoolManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = marginLiquidity.balanceOf(address(this), uPoolId);
        assertEq(liquidityHalf, liquidity - liquidity / 2);
    }

    function addLiquidity(address user, PoolId poolId, uint256 amount0, uint256 amount1) internal returns (uint256) {
        vm.startPrank(user);
        tokenUSDT.approve(address(pairPoolManager), amount1);
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: poolId,
            amount0: amount0,
            amount1: amount1,
            amount0Min: 0,
            amount1Min: 0,
            source: user,
            deadline: type(uint256).max
        });
        uint256 liquidity = pairPoolManager.addLiquidity{value: amount0}(params);
        vm.stopPrank();
        return liquidity;
    }

    function test_OutOfRange() public {
        address user = vm.addr(1);
        tokenUSDT.transfer(user, 10 ether);
        (bool success,) = user.call{value: 10 ether}("");
        assertTrue(success);
        PoolId poolId = usdtKey.toId();
        addLiquidity(user, poolId, 0.1 ether, 0.1 ether);
        vm.startPrank(user);
        uint256 amount0 = 0.1 ether;
        uint256 amount1 = 0.09 ether;
        tokenUSDT.approve(address(pairPoolManager), amount1);
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: poolId,
            amount0: amount0,
            amount1: amount1,
            amount0Min: amount0,
            amount1Min: amount1,
            source: user,
            deadline: type(uint256).max
        });
        vm.expectRevert(bytes("INSUFFICIENT_AMOUNT0"));
        pairPoolManager.addLiquidity{value: amount0}(params);
        amount0 = 0.09 ether;
        amount1 = 0.1 ether;
        tokenUSDT.approve(address(pairPoolManager), amount1);
        params = AddLiquidityParams({
            poolId: poolId,
            amount0: amount0,
            amount1: amount1,
            amount0Min: amount0,
            amount1Min: amount1,
            source: user,
            deadline: type(uint256).max
        });
        vm.expectRevert(bytes("INSUFFICIENT_AMOUNT1"));
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
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        uint256 liquidity = pairPoolManager.addLiquidity{value: amount0}(params);
        uint256 balance = marginLiquidity.balanceOf(address(this), uPoolId);
        assertEq(liquidity, balance, "liquidity==balance");
        skip(1000);
        RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
            poolId: poolId,
            liquidity: liquidity * 2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        pairPoolManager.removeLiquidity(removeParams);
        balance = marginLiquidity.balanceOf(address(this), uPoolId);
        assertEq(0, balance, "balance==0");
    }
}
