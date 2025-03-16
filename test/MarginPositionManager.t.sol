// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {PoolStatusManager} from "../src/PoolStatusManager.sol";
import {PairPoolManager} from "../src/PairPoolManager.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {PoolStatus} from "../src/types/PoolStatus.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition, MarginPositionVo} from "../src/types/MarginPosition.sol";
import {BurnParams} from "../src/types/BurnParams.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "../src/types/LiquidityParams.sol";
import {TimeLibrary} from "../src/libraries/TimeLibrary.sol";
import {CurrencyPoolLibrary} from "../src/libraries/CurrencyPoolLibrary.sol";
// Solmate
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
// Forge
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
// V4
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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

contract MarginPositionManagerTest is DeployHelper {
    using TimeLibrary for *;
    using CurrencyPoolLibrary for Currency;

    function setUp() public {
        deployHookAndRouter();
        initPoolLiquidity();
    }

    function test_hook_margin_tokens() public {
        address user = address(this);
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), key.toId(), false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;
        tokenA.approve(address(marginPositionManager), payValue);
        tokenB.approve(address(marginPositionManager), payValue);
        MarginParams memory params = MarginParams({
            poolId: key.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin(params);
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

        tokenA.approve(address(marginPositionManager), payValue);
        tokenB.approve(address(marginPositionManager), payValue);
        params = MarginParams({
            poolId: key.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin(params);
        console.log(
            "pairPoolManager.balance:%s,marginPositionManager.balance:%s",
            address(pairPoolManager).balance,
            address(marginPositionManager).balance
        );
        position = marginPositionManager.getPosition(positionId);
        console.log(
            "positionId:%s,position.borrowAmount:%s,rateCumulativeLast:%s",
            positionId,
            position.borrowAmount,
            position.rateCumulativeLast
        );
        (uint256 _reserves0, uint256 _reserves1) = pairPoolManager.getReserves(key.toId());
        console.log("_reserves0:%s,_reserves1:%s", _reserves0, _reserves1);
        PoolStatus memory _status = pairPoolManager.getStatus(key.toId());
        console.log("reserve0:%s,reserve1:%s", uint256(_status.realReserve0), uint256(_status.realReserve1));
        console.log(
            "mirrorReserve0:%s,mirrorReserve1:%s", uint256(_status.mirrorReserve0), uint256(_status.mirrorReserve1)
        );
    }

    function test_hook_repay_tokens() public {
        test_hook_margin_tokens();
        address user = address(this);
        uint256 positionId = marginPositionManager.getPositionId(key.toId(), false, user, true);
        assertGt(positionId, 0);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        uint256 repay = 0.01 ether;
        marginPositionManager.repay(positionId, repay, UINT256_MAX);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        assertEq(position.borrowAmount - newPosition.borrowAmount, repay);
        repay = position.borrowAmount + 0.01 ether;
        marginPositionManager.repay(positionId, repay, UINT256_MAX);
        newPosition = marginPositionManager.getPosition(positionId);
        assertEq(newPosition.borrowAmount, 0);
    }

    function testCloseTokens() public {
        address user = address(this);
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), key.toId(), false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        PoolId poolId = key.toId();
        uint256 payValue = 0.01 ether;
        tokenA.approve(address(marginPositionManager), payValue);
        tokenB.approve(address(marginPositionManager), payValue);
        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin(params);
        Currency marginCurrency = key.currency0;
        uint256 lendingId = marginCurrency.toTokenId(poolId);
        positionId = marginPositionManager.getPositionId(key.toId(), false, user, true);
        assertGt(positionId, 0);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        uint256 marginBalance = lendingPoolManager.balanceOf(address(marginPositionManager), lendingId);
        assertEq(marginBalance, position.marginAmount + position.marginTotal);
        console.log(
            "before close positionId:%s,position.borrowAmount:%s,marginBalance:%s",
            positionId,
            position.borrowAmount,
            marginBalance
        );
        uint256 releaseAmount = 0.01 ether;
        tokenA.approve(address(pairPoolManager), releaseAmount);
        int256 pnlAmount = marginChecker.estimatePNL(marginPositionManager, positionId, 30000);
        marginPositionManager.close(positionId, 30000, pnlAmount, UINT256_MAX);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        console.log("after close positionId:%s,position.borrowAmount:%s", positionId, newPosition.borrowAmount);
        vm.warp(3600 * 10);
        position = marginPositionManager.getPosition(positionId);
        marginBalance = lendingPoolManager.balanceOf(address(marginPositionManager), lendingId);
        console.log(
            "before close positionId:%s,position.borrowAmount:%s,marginBalance:%s",
            positionId,
            position.borrowAmount,
            marginBalance
        );
        pnlAmount = marginChecker.estimatePNL(marginPositionManager, positionId, 1000000);
        marginPositionManager.close(positionId, 1000000, pnlAmount, UINT256_MAX);
        newPosition = marginPositionManager.getPosition(positionId);
        console.log("after close positionId:%s,position.borrowAmount:%s", positionId, newPosition.borrowAmount);
    }

    function moreMarginRate(PoolStatus memory status, uint256 borrowAmountBefore, uint256 rateCumulativeLastBefore)
        public
    {
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), poolId, false);
        vm.warp(3600 * 20);

        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.02e18;
        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log("positionId:%s,borrowAmount:%s", positionId, borrowAmount);
        uint256 rateCumulativeLast = rateCumulativeLastBefore;
        uint256 timeElapsed = status.blockTimestampLast.getTimeElapsedMicrosecond();
        uint256 rateCumulativeLastAfter =
            Math.mulDiv(TRILLION_YEAR_SECONDS + rate * timeElapsed, rateCumulativeLast, TRILLION_YEAR_SECONDS);
        uint256 newRateCumulativeLast = marginFees.getBorrowRateCumulativeLast(address(pairPoolManager), poolId, false);
        console.log(
            "timeElapsed:%s,rateLastX:%s,newRateCumulativeLast:%s",
            timeElapsed,
            rateCumulativeLastAfter,
            newRateCumulativeLast
        );

        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log("borrowAmountBefore:%s", borrowAmountBefore);
        uint256 borrowAmountAll =
            borrowAmount + Math.mulDiv(borrowAmountBefore, rateCumulativeLastAfter, rateCumulativeLast);
        assertEq(position.borrowAmount / 100, borrowAmountAll / 100);
        console.log("positionId:%s,position.borrowAmount:%s,all:%s", positionId, position.borrowAmount, borrowAmountAll);
    }

    function testMarginRate() public {
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
        rate = marginFees.getBorrowRate(address(pairPoolManager), poolId, false);
        uint256 rateCumulativeLast = marginFees.getBorrowRateCumulativeLast(address(pairPoolManager), poolId, false);
        console.log("rate:%s,rateCumulativeLast:%s", rate, rateCumulativeLast);
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        vm.warp(3600 * 10);
        position = marginPositionManager.getPosition(positionId);
        console.log(
            "positionId:%s,position.borrowAmount:%s,rateCumulativeLast:%s",
            positionId,
            position.borrowAmount,
            position.rateCumulativeLast
        );
        uint256 timeElapsed = status.blockTimestampLast.getTimeElapsedMicrosecond();
        uint256 rateCumulativeLastAfter =
            Math.mulDiv(TRILLION_YEAR_SECONDS + rate * timeElapsed, rateCumulativeLast, TRILLION_YEAR_SECONDS);
        uint256 newRateCumulativeLast = marginFees.getBorrowRateCumulativeLast(address(pairPoolManager), poolId, false);
        assertEq(rateCumulativeLastAfter, newRateCumulativeLast);
        uint256 borrowAmountLast = borrowAmount;
        payValue = 0.02e18;
        params = MarginParams({
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
            "nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(pairPoolManager).balance,
            address(marginPositionManager).balance
        );
        console.log("positionId:%s,borrowAmount:%s", positionId, borrowAmount);
        position = marginPositionManager.getPosition(positionId);
        uint256 borrowAmountAll =
            borrowAmount + Math.mulDiv(borrowAmountLast, rateCumulativeLastAfter, rateCumulativeLast);
        console.log(
            "position.rawBorrowAmount:%s,position.borrowAmount:%s,borrowAmountAll:%s",
            position.rawBorrowAmount,
            position.borrowAmount,
            borrowAmountAll
        );
        assertEq(position.borrowAmount / 100, borrowAmountAll / 100);
        console.log("positionId:%s,position.borrowAmount:%s,all:%s", positionId, position.borrowAmount, borrowAmountAll);

        status = pairPoolManager.getStatus(poolId);
        moreMarginRate(status, borrowAmountAll, rateCumulativeLastAfter);
    }

    function test_hook_margin_native() public {
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        uint256 keyId = CurrencyLibrary.ADDRESS_ZERO.toTokenId(poolId);
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), poolId, false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;
        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        assertEq(
            lendingPoolManager.balanceOf(address(marginPositionManager), keyId),
            position.marginAmount + position.marginTotal
        );
        uint256 _positionId = marginPositionManager.getPositionId(poolId, false, user, true);
        assertEq(positionId, _positionId);
    }

    function testMarginNative() public {
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        uint256 currencyPoolId = CurrencyLibrary.ADDRESS_ZERO.toTokenId(poolId);
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), poolId, false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;
        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        assertEq(
            lendingPoolManager.balanceOf(address(marginPositionManager), currencyPoolId),
            position.marginAmount + position.marginTotal
        );
        uint256 _positionId = marginPositionManager.getPositionId(poolId, false, user, true);
        assertEq(positionId, _positionId);
        vm.expectPartialRevert(CurrencyPoolLibrary.InsufficientValue.selector);
        (positionId, borrowAmount) = marginPositionManager.margin(params);
    }

    function test_checkAmount() public {
        address user = vm.addr(10);
        (bool success,) = user.call{value: 1 ether}("");
        assertTrue(success);
        vm.startPrank(user);
        PoolId poolId = nativeKey.toId();
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;
        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        payValue = 0.001 ether;
        vm.expectPartialRevert(CurrencyPoolLibrary.InsufficientValue.selector);
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        vm.stopPrank();
    }

    function test_deadline() public {
        address user = vm.addr(10);
        (bool success,) = user.call{value: 1 ether}("");
        assertTrue(success);
        vm.startPrank(user);
        PoolId poolId = nativeKey.toId();
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;
        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: 0
        });
        vm.expectRevert(bytes("EXPIRED"));
        payValue = 0.001 ether;
        vm.warp(3600 * 20);
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        vm.stopPrank();
    }

    function test_hook_repay_native() public {
        test_hook_margin_native();
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        uint256 positionId = marginPositionManager.getPositionId(poolId, false, user, true);
        assertGt(positionId, 0);
        vm.warp(3600 * 20);
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log("status.mirrorReserve1:%s", status.mirrorReserve1);
        assertEq(status.mirrorReserve1 / 10, position.borrowAmount / 10);
        uint256 userBalance = user.balance;
        uint256 repay = 0.01 ether;
        tokenB.approve(address(pairPoolManager), repay);
        marginPositionManager.repay(positionId, repay, UINT256_MAX);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        assertEq((position.borrowAmount - newPosition.borrowAmount) / 10, repay / 10);
        assertEq(
            position.marginTotal + position.marginAmount - newPosition.marginTotal - newPosition.marginAmount,
            user.balance - userBalance
        );
        status = pairPoolManager.getStatus(poolId);
        assertEq(status.mirrorReserve1 / 10, newPosition.borrowAmount / 10);

        uint256 pFeeAmount = poolStatusManager.protocolFeesAccrued(nativeKey.currency1);
        console.log("pFeeAmount:%s", pFeeAmount);
        uint256 collectFeeAmount =
            marginFees.collectProtocolFees(address(pairPoolManager), user, nativeKey.currency1, pFeeAmount);
        console.log("collectFeeAmount:%s", collectFeeAmount);
        assertEq(collectFeeAmount, pFeeAmount);
    }

    function test_hook_close_native() public {
        test_hook_margin_native();
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        uint256 positionId = marginPositionManager.getPositionId(poolId, false, user, true);
        assertGt(positionId, 0);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        assertEq(status.mirrorReserve1, position.rawBorrowAmount);
        marginPositionManager.close(positionId, 3000, 0, UINT256_MAX);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        assertEq(position.borrowAmount - newPosition.borrowAmount, position.borrowAmount * 3000 / ONE_MILLION);
        status = pairPoolManager.getStatus(poolId);
        assertEq(status.mirrorReserve1, newPosition.rawBorrowAmount);
    }

    function test_hook_liquidate_burn() public {
        address user = address(this);
        tokenB.approve(address(pairPoolManager), 1e18);
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), nativeKey.toId(), false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.001 ether;
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
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

        positionId = marginPositionManager.getPositionId(nativeKey.toId(), false, user, true);
        assertGt(positionId, 0);
        position = marginPositionManager.getPosition(positionId);
        (bool liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
        uint256 amountIn = 0.1 ether;
        uint256 swapIndex = 0;
        while (!liquidated) {
            MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
                poolId: nativeKey.toId(),
                zeroForOne: true,
                to: user,
                amountIn: amountIn,
                amountOut: 0,
                amountOutMin: 0,
                deadline: type(uint256).max
            });
            swapRouter.exactInput{value: amountIn}(swapParams);
            (liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
            swapIndex++;
            vm.warp(30 * swapIndex);
        }
        console.log(
            "before swapIndex:%s, liquidate nativeHook.balance:%s,marginPositionManager.balance:%s",
            swapIndex,
            address(pairPoolManager).balance,
            address(marginPositionManager).balance
        );
        BurnParams memory liquidateParams =
            BurnParams({poolId: nativeKey.toId(), marginForOne: false, positionIds: new uint256[](1)});
        liquidateParams.positionIds[0] = positionId;
        marginPositionManager.liquidateBurn(liquidateParams);
        position = marginPositionManager.getPosition(positionId);
        console.log(
            "after liquidate nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(pairPoolManager).balance,
            address(marginPositionManager).balance
        );
    }

    function test_hook_liquidate_burn_without_oracle() public {
        address user = address(this);
        poolStatusManager.setMarginOracle(address(0));
        tokenB.approve(address(pairPoolManager), 1e18);
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), nativeKey.toId(), false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.001 ether;
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
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

        positionId = marginPositionManager.getPositionId(nativeKey.toId(), false, user, true);
        assertGt(positionId, 0);
        position = marginPositionManager.getPosition(positionId);
        (bool liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
        uint256 amountIn = 0.1 ether;
        uint256 swapIndex = 0;
        while (!liquidated) {
            MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
                poolId: nativeKey.toId(),
                zeroForOne: true,
                to: user,
                amountIn: amountIn,
                amountOut: 0,
                amountOutMin: 0,
                deadline: type(uint256).max
            });
            swapRouter.exactInput{value: amountIn}(swapParams);
            (liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
            swapIndex++;
            vm.warp(30 * swapIndex);
        }
        console.log(
            "before swapIndex:%s, liquidate nativeHook.balance:%s,marginPositionManager.balance:%s",
            swapIndex,
            address(pairPoolManager).balance,
            address(marginPositionManager).balance
        );
        BurnParams memory liquidateParams =
            BurnParams({poolId: nativeKey.toId(), marginForOne: false, positionIds: new uint256[](1)});
        liquidateParams.positionIds[0] = positionId;
        marginPositionManager.liquidateBurn(liquidateParams);
        position = marginPositionManager.getPosition(positionId);
        console.log(
            "after liquidate nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(pairPoolManager).balance,
            address(marginPositionManager).balance
        );
    }

    function test_hook_margin_max() public {
        address user = address(this);
        tokenB.approve(address(pairPoolManager), 1e18);
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), nativeKey.toId(), false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue;
        payValue = 0.01 ether;
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
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
        (payValue, borrowAmount) = marginChecker.getMarginMax(address(pairPoolManager), nativeKey.toId(), false, 3);
        params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        vm.warp(1000);
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log(
            "pairPoolManager.balance:%s,marginPositionManager.balance:%s",
            address(pairPoolManager).balance,
            address(marginPositionManager).balance
        );
        console.log("positionId:%s,borrowAmount:%s", positionId, borrowAmount);
        position = marginPositionManager.getPosition(positionId);
        console.log(
            "positionId:%s,position.borrowAmount:%s,rateCumulativeLast:%s",
            positionId,
            position.borrowAmount,
            position.rateCumulativeLast
        );
    }

    function test_hook_margin_usdts() public {
        address user = address(this);
        PoolId poolId = usdtKey.toId();
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), poolId, false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;
        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log(
            "positionId:%s,position.borrowAmount:%s,rateCumulativeLast:%s",
            positionId,
            position.borrowAmount,
            position.rateCumulativeLast
        );

        params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);

        position = marginPositionManager.getPosition(positionId);
        console.log(
            "positionId:%s,position.borrowAmount:%s,rateCumulativeLast:%s",
            positionId,
            position.borrowAmount,
            position.rateCumulativeLast
        );
        PoolStatus memory _status = pairPoolManager.getStatus(poolId);
        console.log("reserve0:%s,reserve1:%s", uint256(_status.realReserve0), uint256(_status.realReserve1));
        console.log(
            "mirrorReserve0:%s,mirrorReserve1:%s", uint256(_status.mirrorReserve0), uint256(_status.mirrorReserve1)
        );
    }

    function test_hook_margin_usdts_buy() public {
        address user = address(this);
        PoolId poolId = usdtKey.toId();
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), poolId, false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;
        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: true,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log(
            "positionId:%s,position.borrowAmount:%s,rateCumulativeLast:%s",
            positionId,
            position.borrowAmount,
            position.rateCumulativeLast
        );

        params = MarginParams({
            poolId: poolId,
            marginForOne: true,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);

        position = marginPositionManager.getPosition(positionId);
        console.log(
            "positionId:%s,position.borrowAmount:%s,rateCumulativeLast:%s",
            positionId,
            position.borrowAmount,
            position.rateCumulativeLast
        );
        PoolStatus memory _status = pairPoolManager.getStatus(poolId);
        console.log("reserve0:%s,reserve1:%s", uint256(_status.realReserve0), uint256(_status.realReserve1));
        console.log(
            "mirrorReserve0:%s,mirrorReserve1:%s", uint256(_status.mirrorReserve0), uint256(_status.mirrorReserve1)
        );
    }

    function test_hook_repay_usdts() public {
        test_hook_margin_usdts();
        address user = address(this);
        PoolId poolId = usdtKey.toId();
        uint256 positionId = marginPositionManager.getPositionId(poolId, false, user, true);
        assertGt(positionId, 0);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log("before repay positionId:%s,position.borrowAmount:%s", positionId, position.borrowAmount);
        uint256 repay = 0.01 ether;
        marginPositionManager.repay(positionId, repay, UINT256_MAX);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        console.log("after repay positionId:%s,position.borrowAmount:%s", positionId, newPosition.borrowAmount);
        assertEq(position.borrowAmount - newPosition.borrowAmount, repay);
        repay = position.borrowAmount + 0.01 ether;
        marginPositionManager.repay(positionId, repay, UINT256_MAX);
        newPosition = marginPositionManager.getPosition(positionId);
        console.log("after all.repay positionId:%s,position.borrowAmount:%s", positionId, newPosition.borrowAmount);
    }

    function test_hook_close_usdts() public {
        test_hook_margin_usdts();
        address user = address(this);
        uint256 positionId = marginPositionManager.getPositionId(usdtKey.toId(), false, user, true);
        assertGt(positionId, 0);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log("before repay positionId:%s,position.borrowAmount:%s", positionId, position.borrowAmount);

        marginPositionManager.close(positionId, 1000000, 0, UINT256_MAX);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);

        console.log("after repay positionId:%s,position.borrowAmount:%s", positionId, newPosition.borrowAmount);
    }

    function test_hook_modify_usdts() public {
        test_hook_margin_usdts();
        address user = address(this);
        uint256 positionId = marginPositionManager.getPositionId(usdtKey.toId(), false, user, true);
        assertGt(positionId, 0);
        uint256 maxAmount = marginChecker.getMaxDecrease(address(marginPositionManager), positionId);
        console.log("test_hook_modify_usdts maxAmount:%s", maxAmount);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        marginPositionManager.modify{value: maxAmount}(positionId, -int256(maxAmount));
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        assertEq(position.marginAmount - maxAmount, newPosition.marginAmount);
        assertEq(address(marginPositionManager).balance, 0);
        marginPositionManager.modify{value: maxAmount}(positionId, int256(maxAmount));
        assertEq(address(marginPositionManager).balance, 0);
        newPosition = marginPositionManager.getPosition(positionId);
        assertEq(position.marginAmount, newPosition.marginAmount);
        console.log("newPosition.marginTotal:%s", newPosition.marginTotal);
    }

    function test_hook_dynamic_fee_usdts() public {
        PoolId poolId = usdtKey.toId();
        (uint24 _fee, uint24 _marginFee) = pairPoolManager.marginFees().getPoolFees(address(pairPoolManager), poolId);
        console.log("before margin _fee:%s", _fee);
        test_hook_margin_usdts();
        (_fee, _marginFee) = pairPoolManager.marginFees().getPoolFees(address(pairPoolManager), poolId);
        console.log("after margin _fee:%s", _fee);
        vm.warp(30);
        (_fee, _marginFee) = pairPoolManager.marginFees().getPoolFees(address(pairPoolManager), poolId);
        console.log("after margin _fee:%s", _fee);
        vm.warp(126);
        (_fee, _marginFee) = pairPoolManager.marginFees().getPoolFees(address(pairPoolManager), poolId);
        console.log("after margin _fee:%s", _fee);
    }

    function test_hook_liquidateCall() public {
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), poolId, false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.1 ether;
        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        vm.expectPartialRevert(MarginPositionManager.InsufficientAmount.selector);
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        payValue = 0.001 ether;
        params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log("positionId:%s,borrowAmount:%s", positionId, borrowAmount);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        assertEq(borrowAmount, position.borrowAmount);
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        assertEq(borrowAmount, status.mirrorReserve1);
        console.log(
            "marginAmount:%s,marginTotal:%s,rateCumulativeLast:%s",
            position.marginAmount,
            position.marginTotal,
            position.rateCumulativeLast
        );

        positionId = marginPositionManager.getPositionId(poolId, false, user, true);
        assertGt(positionId, 0);
        position = marginPositionManager.getPosition(positionId);
        (bool liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
        console.log("liquidated:%s", liquidated);
        {
            uint256 amountIn = 0.1 ether;
            uint256 swapIndex = 0;
            while (!liquidated) {
                MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
                    poolId: poolId,
                    zeroForOne: true,
                    to: user,
                    amountIn: amountIn,
                    amountOut: 0,
                    amountOutMin: 0,
                    deadline: type(uint256).max
                });
                swapRouter.exactInput{value: amountIn}(swapParams);
                (liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
                swapIndex++;
                vm.warp(30 * swapIndex);
                position = marginPositionManager.getPosition(positionId);
                status = pairPoolManager.getStatus(poolId);
                console.log(
                    "position.borrowAmount:%s,rateCumulativeLast:%s,status.mirrorReserve1:%s",
                    position.borrowAmount,
                    position.rateCumulativeLast,
                    status.mirrorReserve1
                );
                assertGe(position.borrowAmount, status.mirrorReserve1);
            }
        }

        {
            position = marginPositionManager.getPosition(positionId);
            tokenB.approve(address(pairPoolManager), position.borrowAmount);
            uint256 balanceBefore = tokenB.balanceOf(user);
            uint256 nativeBefore = user.balance;
            marginPositionManager.liquidateCall(positionId);
            uint256 balanceAfter = tokenB.balanceOf(user);
            uint256 nativeAfter = user.balance;
            assertEq(balanceBefore - balanceAfter, position.borrowAmount);
            assertEq(nativeAfter - nativeBefore, position.marginAmount + position.marginTotal);
            position = marginPositionManager.getPosition(positionId);
            assertEq(position.borrowAmount, 0);
        }
    }

    function test_getPositions() public {
        address user = address(this);
        PoolId poolId1 = key.toId();
        PoolId poolId2 = nativeKey.toId();
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.001 ether;
        MarginParams memory params = MarginParams({
            poolId: poolId1,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        assertEq(positionId, 1);
        params = MarginParams({
            poolId: poolId2,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        assertEq(positionId, 2);
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = 1;
        positionIds[1] = 2;
        MarginPositionVo[] memory positions = marginChecker.getPositions(marginPositionManager, positionIds);
        assertGt(positions.length, 0);
        assertGt(positions[0].position.borrowAmount, 0);
        assertGt(positions[1].position.borrowAmount, 0);
    }

    function leverageMax(bool marginForOne, uint24 leverage) public {
        address user = address(this);
        PoolId poolId1 = nativeKey.toId();
        uint256 positionId;
        uint256 borrowAmount;
        (uint256 payValue, uint256 borrowAmountEstimate) =
            marginChecker.getMarginMax(address(pairPoolManager), poolId1, marginForOne, leverage);
        MarginParams memory params = MarginParams({
            poolId: poolId1,
            marginForOne: marginForOne,
            leverage: leverage,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        assertGt(positionId, 0);
        assertLt(borrowAmountEstimate - borrowAmount, 1000);
    }

    function test_OneLeverage() public {
        leverageMax(true, 1);
        vm.warp(1000);
        leverageMax(false, 1);
    }

    function test_TwoLeverage() public {
        leverageMax(true, 2);
        vm.warp(1000);
        leverageMax(false, 2);
    }

    function test_ThreeLeverage() public {
        leverageMax(true, 3);
        vm.warp(1000);
        leverageMax(false, 3);
    }

    function test_FourLeverage() public {
        leverageMax(true, 4);
        vm.warp(1000);
        leverageMax(false, 4);
    }

    function test_FiveLeverage() public {
        leverageMax(true, 5);
        vm.warp(1000);
        leverageMax(false, 5);
    }

    function testGetPositionsZero() public {
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = 1;
        positionIds[1] = 2;
        vm.expectRevert(PoolStatusManager.PairNotExists.selector);
        marginChecker.getPositions(marginPositionManager, positionIds);
    }

    function test_liquidateBurn() public {
        uint256 length = 100;
        uint256[] memory positionIds = new uint256[](length);
        uint256 debtAmount = 0;
        uint256 borrowAmountAll = 0;
        uint256 keyId = nativeKey.currency1.toTokenId(nativeKey);
        uint256 keyId0 = nativeKey.currency0.toTokenId(nativeKey);
        for (uint256 i = 0; i < length; i++) {
            address user = vm.addr(i + 1);
            uint256 positionId;
            uint256 borrowAmount;
            uint256 payValue = 0.0001 ether;
            MarginParams memory params = MarginParams({
                poolId: nativeKey.toId(),
                marginForOne: false,
                leverage: 3,
                marginAmount: payValue,
                borrowAmount: 0,
                borrowMaxAmount: 0,
                recipient: user,
                deadline: block.timestamp + 1000
            });

            (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
            MarginPosition memory position = marginPositionManager.getPosition(positionId);
            positionId = marginPositionManager.getPositionId(nativeKey.toId(), false, user, true);
            assertGt(positionId, 0);
            position = marginPositionManager.getPosition(positionId);
            positionIds[i] = positionId;
            debtAmount += position.marginAmount + position.marginTotal;
            borrowAmountAll += borrowAmount;
            // uint256 releaseAmount =
            //     pairPoolManager.getAmountIn(position.poolId, !position.marginForOne, position.borrowAmount);
        }
        assertEq(debtAmount, lendingPoolManager.balanceOf(address(marginPositionManager), keyId0));
        uint256 mirrorBalance = mirrorTokenManager.balanceOf(address(pairPoolManager), keyId);
        console.log("mirrorBalance:%s,borrowAmountAll:%s", mirrorBalance, borrowAmountAll);
        uint256 swapIndex = 0;
        for (uint256 i = 0; i < length; i++) {
            uint256 positionId = positionIds[i];
            (bool liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
            uint256 amountIn = 0.1 ether;
            address user = address(this);
            while (!liquidated) {
                MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
                    poolId: nativeKey.toId(),
                    zeroForOne: true,
                    to: user,
                    amountIn: amountIn,
                    amountOut: 0,
                    amountOutMin: 0,
                    deadline: type(uint256).max
                });
                swapRouter.exactInput{value: amountIn}(swapParams);
                (liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
                swapIndex++;
                console.log("swapIndex:%s", swapIndex);
                vm.warp(300 * swapIndex);
            }
        }
        MarginPosition memory _position = marginPositionManager.getPosition(1);
        console.log("position.borrowAmount:%s", _position.borrowAmount);
        assertGt(_position.borrowAmount, 0);
        BurnParams memory burnParams =
            BurnParams({poolId: nativeKey.toId(), marginForOne: false, positionIds: positionIds});
        uint256 profit = marginPositionManager.liquidateBurn(burnParams);
        console.log("profit:%s", profit);
        _position = marginPositionManager.getPosition(1);
        assertEq(_position.borrowAmount, 0);
        assertEq(0, address(marginPositionManager).balance);
        PoolStatus memory status = pairPoolManager.getStatus(nativeKey.toId());
        mirrorBalance = mirrorTokenManager.balanceOf(address(pairPoolManager), keyId);
        console.log("mirrorBalance:%s,status.mirrorReserve1:%s", mirrorBalance, status.mirrorReserve1);
    }

    function testLiquidateBurnSame() public {
        uint256 length = 2;
        uint256[] memory positionIds = new uint256[](length);
        address user = vm.addr(1);
        uint256 keyId = CurrencyLibrary.ADDRESS_ZERO.toTokenId(nativeKey);
        uint256 debtAmount = 0;
        {
            uint256 positionId;
            uint256 borrowAmount;
            uint256 payValue = 0.0001 ether;
            MarginParams memory params = MarginParams({
                poolId: nativeKey.toId(),
                marginForOne: false,
                leverage: 3,
                marginAmount: payValue,
                borrowAmount: 0,
                borrowMaxAmount: 0,
                recipient: user,
                deadline: block.timestamp + 1000
            });

            (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
            MarginPosition memory position = marginPositionManager.getPosition(positionId);
            positionId = marginPositionManager.getPositionId(nativeKey.toId(), false, user, true);
            assertGt(positionId, 0);
            position = marginPositionManager.getPosition(positionId);
            for (uint256 i = 0; i < length; i++) {
                positionIds[i] = positionId;
            }
            debtAmount += position.marginAmount + position.marginTotal;
            assertEq(debtAmount, lendingPoolManager.balanceOf(address(marginPositionManager), keyId));
        }

        uint256 swapIndex = 0;
        for (uint256 i = 0; i < length; i++) {
            uint256 positionId = positionIds[i];
            (bool liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
            uint256 amountIn = 0.1 ether;
            while (!liquidated) {
                MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
                    poolId: nativeKey.toId(),
                    zeroForOne: true,
                    to: user,
                    amountIn: amountIn,
                    amountOut: 0,
                    amountOutMin: 0,
                    deadline: type(uint256).max
                });
                swapRouter.exactInput{value: amountIn}(swapParams);
                (liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
                swapIndex++;
                console.log("swapIndex:%s", swapIndex);
                vm.warp(300 * swapIndex);
            }
        }
        MarginPosition memory _position = marginPositionManager.getPosition(1);
        console.log("position.borrowAmount:%s", _position.borrowAmount);
        assertGt(_position.borrowAmount, 0);
        BurnParams memory burnParams =
            BurnParams({poolId: nativeKey.toId(), marginForOne: false, positionIds: positionIds});
        vm.expectRevert(bytes("ALREADY_BURNT"));
        marginPositionManager.liquidateBurn(burnParams);
    }

    function testBorrow() public {
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.0001 ether;
        address user = vm.addr(1);
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 0,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        uint256 beforeBalance = tokenB.balanceOf(user);
        assertEq(beforeBalance, 0);
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        uint256 afterBalance = tokenB.balanceOf(user);
        assertEq(positionId, 1);
        uint256 borrowPositionId = marginPositionManager.getPositionId(nativeKey.toId(), false, user, false);
        assertEq(positionId, borrowPositionId);
        assertEq(afterBalance, borrowAmount);
        vm.startPrank(user);
        uint256 beforeETH = user.balance;
        assertEq(beforeETH, 0);
        tokenB.approve(address(pairPoolManager), borrowAmount / 2);
        marginPositionManager.repay(positionId, borrowAmount / 2, block.timestamp + 1000);
        uint256 afterETH = user.balance;
        assertGt(afterETH, 0);
        uint256 newAfterBalance = tokenB.balanceOf(user);
        assertEq(newAfterBalance, afterBalance - borrowAmount / 2);
        vm.expectRevert(bytes("DISABLE_CLOSE"));
        marginPositionManager.close(positionId, 500000, 0, block.timestamp + 1000);
        vm.stopPrank();
    }

    function testBorrowMax() public {
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.0001 ether;
        address user = vm.addr(1);
        (, uint256 borrowMax) = marginChecker.getBorrowMax(address(pairPoolManager), nativeKey.toId(), false, payValue);
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 0,
            marginAmount: payValue,
            borrowAmount: borrowMax,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        uint256 beforeBalance = tokenB.balanceOf(user);
        assertEq(beforeBalance, 0);
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        uint256 afterBalance = tokenB.balanceOf(user);
        assertEq(positionId, 1);
        uint256 borrowPositionId = marginPositionManager.getPositionId(nativeKey.toId(), false, user, false);
        assertEq(positionId, borrowPositionId);
        assertEq(afterBalance, borrowAmount);
        vm.warp(3600);
        vm.startPrank(user);
        uint256 beforeETH = user.balance;
        assertEq(beforeETH, 0);
        tokenB.approve(address(pairPoolManager), borrowAmount / 2);
        marginPositionManager.repay(positionId, borrowAmount / 2, block.timestamp + 1000);
        uint256 afterETH = user.balance;
        assertGt(afterETH, 0);
        uint256 newAfterBalance = tokenB.balanceOf(user);
        assertEq(newAfterBalance, afterBalance - borrowAmount / 2);
        vm.expectRevert(bytes("DISABLE_CLOSE"));
        marginPositionManager.close(positionId, 500000, 0, block.timestamp + 1000);
        vm.stopPrank();
    }

    function testModifyPosition() public {
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.0001 ether;
        address user = address(this);
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: true,
            leverage: 0,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin(params);
        MarginPosition memory _position = marginPositionManager.getPosition(positionId);
        console.log(
            "_position.marginAmount:%s,_position.borrowAmount:%s", _position.marginAmount, _position.borrowAmount
        );
        tokenB.approve(address(lendingPoolManager), payValue);
        vm.warp(3600);
        marginPositionManager.modify(positionId, int256(payValue));
        _position = marginPositionManager.getPosition(positionId);
        console.log(
            "_position.marginAmount:%s,_position.borrowAmount:%s", _position.marginAmount, _position.borrowAmount
        );
    }

    function testGetMarginMax() public view {
        (uint256 marginMax, uint256 borrowAmount) =
            marginChecker.getMarginMax(address(pairPoolManager), nativeKey.toId(), true, 0);
        console.log("marginMax:%s,borrowAmount:%s", marginMax, borrowAmount);
        assertGt(marginMax, borrowAmount);
        (marginMax, borrowAmount) = marginChecker.getMarginMax(address(pairPoolManager), nativeKey.toId(), false, 0);
        console.log("marginMax:%s,borrowAmount:%s", marginMax, borrowAmount);
        assertLt(marginMax, borrowAmount);
        (marginMax, borrowAmount) = marginChecker.getMarginMax(address(pairPoolManager), nativeKey.toId(), false, 1);
        console.log("marginMax:%s,borrowAmount:%s", marginMax, borrowAmount);
    }
}
