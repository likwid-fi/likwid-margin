// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {PairPoolManager} from "../src/PairPoolManager.sol";
import {MarginLiquidity} from "../src/MarginLiquidity.sol";
import {BaseFees} from "../src/base/BaseFees.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
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

contract MarginLiquidityTest is DeployHelper {
    using CurrencyPoolLibrary for Currency;

    function setUp() public {
        deployHookAndRouter();
        marginLiquidity.setStageDuration(1 hours);
        marginLiquidity.setStageSize(10);
        assertEq(marginLiquidity.stageDuration(), 3600, "Stage duration should be set to 1 hour");
        skip(356 days); // Skip to just before the next stage starts
    }

    function test_single_AddLiquidity() public {
        PoolId poolId = tokensKey.toId();
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: poolId,
            amount0: 1e18,
            amount1: 1e18,
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        uint256 liquidity = pairPoolManager.addLiquidity(params);
        uint256 releaseLiquidity = marginLiquidity.getReleasedLiquidity(poolId);
        assertEq(liquidity, 1e18, "Liquidity should be 1e18");
        assertEq(releaseLiquidity, 1e18 / 10, "Release 1 liquidity should be 1e17");
        skip(1 hours + 1);
        releaseLiquidity = marginLiquidity.getReleasedLiquidity(poolId);
        assertEq(releaseLiquidity, 1e18 / 10, "Release 2 liquidity should be 1e17");
        skip(1 hours + 1);
        releaseLiquidity = marginLiquidity.getReleasedLiquidity(poolId);
        assertEq(releaseLiquidity, 1e18 / 10, "Release 3 liquidity should be 1e17");
        skip(10 days);
        releaseLiquidity = marginLiquidity.getReleasedLiquidity(poolId);
        assertEq(releaseLiquidity, 1e18 / 10, "Release 4 liquidity should be 1e17");
    }

    function test_double_AddLiquidity() public {
        PoolId poolId = tokensKey.toId();
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: poolId,
            amount0: 1e18,
            amount1: 1e18,
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        uint256 liquidity = pairPoolManager.addLiquidity(params);
        uint256 releaseLiquidity = marginLiquidity.getReleasedLiquidity(poolId);
        assertEq(liquidity, 1e18, "Liquidity should be 1e18");
        assertEq(releaseLiquidity, 1e18 / 10, "Release 1 liquidity should be 1e17");
        params = AddLiquidityParams({
            poolId: poolId,
            amount0: 1e18,
            amount1: 1e18,
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        uint256 liquidity2 = pairPoolManager.addLiquidity(params);
        assertEq(liquidity2, 1e18, "Liquidity2 should be 1e18");
        releaseLiquidity = marginLiquidity.getReleasedLiquidity(poolId);
        assertEq(releaseLiquidity, liquidity / 10 + liquidity2 / 10, "Release 2 liquidity should be 1e17 + 1e17");
    }

    function test_single_removeLiquidity() public {
        PoolId poolId = tokensKey.toId();
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: poolId,
            amount0: 1e18,
            amount1: 1e18,
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        uint256 liquidity = pairPoolManager.addLiquidity(params);
        uint256 releaseLiquidity = marginLiquidity.getReleasedLiquidity(poolId);
        assertEq(liquidity, 1e18, "Liquidity should be 1e18");
        assertEq(releaseLiquidity, 1e18 / 10, "Release 1 liquidity should be 1e17");
        skip(1 hours + 1);
        RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
            poolId: poolId,
            liquidity: releaseLiquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        pairPoolManager.removeLiquidity(removeParams);
        uint256 releaseLiquidity01 = marginLiquidity.getReleasedLiquidity(poolId);
        releaseLiquidity += 100;
        assertLt(releaseLiquidity01, releaseLiquidity, "Release liquidity should be less than 1e17 + 100");
        removeParams = RemoveLiquidityParams({
            poolId: poolId,
            liquidity: releaseLiquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        vm.expectRevert(MarginLiquidity.LiquidityLocked.selector);
        pairPoolManager.removeLiquidity(removeParams);
        skip(1 hours + 1);
        removeParams = RemoveLiquidityParams({
            poolId: poolId,
            liquidity: releaseLiquidity / 2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        pairPoolManager.removeLiquidity(removeParams);
        skip(1 hours + 1);
        removeParams = RemoveLiquidityParams({
            poolId: poolId,
            liquidity: releaseLiquidity / 2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        pairPoolManager.removeLiquidity(removeParams);
        uint256 lp = marginLiquidity.getPoolLiquidity(poolId, address(this));
        assertGt(lp, 0, "Liquidity should be greater than 0");
        while (lp > 0) {
            skip(1 hours + 1);
            removeParams = RemoveLiquidityParams({
                poolId: poolId,
                liquidity: releaseLiquidity / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            });
            pairPoolManager.removeLiquidity(removeParams);
            lp = marginLiquidity.getPoolLiquidity(poolId, address(this));
        }
    }
}
