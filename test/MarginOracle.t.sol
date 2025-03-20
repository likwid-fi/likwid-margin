// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {PairPoolManager} from "../src/PairPoolManager.sol";
import {CurrencyPoolLibrary} from "../src/libraries/CurrencyPoolLibrary.sol";
import {TruncatedOracle} from "../src/libraries/TruncatedOracle.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {PoolStatus} from "../src/types/PoolStatus.sol";
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
import {SafeCast} from "v4-core/libraries/SafeCast.sol";

import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

import {HookMiner} from "./utils/HookMiner.sol";
import {DeployHelper} from "./utils/DeployHelper.sol";

contract MarginOracleTest is DeployHelper {
    using CurrencyPoolLibrary for *;
    using SafeCast for uint256;

    function setUp() public {
        deployHookAndRouter();
        // initPoolLiquidity();
    }

    function testObserve() public {
        int256 i = 0;
        uint256 j = uint256(-i);
        assertEq(j, 0);
        int256 k = -(j.toInt256());
        assertEq(k, 0);
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 1000;
        skip(10000);
        // vm.expectPartialRevert(TruncatedOracle.TargetPredatesOldestObservation.selector);
        marginOracle.observe(pairPoolManager, nativeKey.toId(), secondsAgos);
    }

    function testGetReserves() public {
        console.log(block.number);
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: nativeKey.toId(),
            level: 4,
            amount0: 10000 * 10 ** 6,
            amount1: 0.1 * 10 ** 8,
            to: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: 10000 * 10 ** 6}(params);
        (uint256 reserveBorrow, uint256 reserveMargin) =
            marginChecker.getReserves(address(pairPoolManager), nativeKey.toId(), true);
        console.log(reserveBorrow, reserveMargin);
        uint256 amountIn = 10000 * 10 ** 6;
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
        (reserveBorrow, reserveMargin) = marginChecker.getReserves(address(pairPoolManager), nativeKey.toId(), true);
        console.log("%s/%s", reserveBorrow, reserveMargin);
        skip(10);
        (reserveBorrow, reserveMargin) = marginChecker.getReserves(address(pairPoolManager), nativeKey.toId(), true);
        console.log("%s/%s", reserveBorrow, reserveMargin);
        skip(1);
        (reserveBorrow, reserveMargin) = marginChecker.getReserves(address(pairPoolManager), nativeKey.toId(), true);
        console.log("%s/%s", reserveBorrow, reserveMargin);
        skip(10);
        (reserveBorrow, reserveMargin) = marginChecker.getReserves(address(pairPoolManager), nativeKey.toId(), true);
        console.log("%s/%s", reserveBorrow, reserveMargin);
    }

    function testZeroGetReserves() public {
        console.log(block.number);
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: nativeKey.toId(),
            level: 4,
            amount0: 10000 * 10 ** 6,
            amount1: 0.1 * 10 ** 8,
            to: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: 10000 * 10 ** 6}(params);
        (uint256 reserveBorrow, uint256 reserveMargin) =
            marginChecker.getReserves(address(pairPoolManager), nativeKey.toId(), true);
        console.log(reserveBorrow, reserveMargin);
        uint256 amountIn = 0.2 * 10 ** 8;
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            poolId: nativeKey.toId(),
            zeroForOne: false,
            to: address(this),
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        swapRouter.exactInput(swapParams);
        (reserveBorrow, reserveMargin) = marginChecker.getReserves(address(pairPoolManager), nativeKey.toId(), true);
        console.log("%s/%s", reserveBorrow, reserveMargin);
        skip(10);
        (reserveBorrow, reserveMargin) = marginChecker.getReserves(address(pairPoolManager), nativeKey.toId(), true);
        console.log("%s/%s", reserveBorrow, reserveMargin);
        skip(1);
        (reserveBorrow, reserveMargin) = marginChecker.getReserves(address(pairPoolManager), nativeKey.toId(), true);
        console.log("%s/%s", reserveBorrow, reserveMargin);
        skip(10);
        (reserveBorrow, reserveMargin) = marginChecker.getReserves(address(pairPoolManager), nativeKey.toId(), true);
        console.log("%s/%s", reserveBorrow, reserveMargin);
    }
}
