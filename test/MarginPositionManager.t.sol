// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {PoolStatusManager} from "../src/PoolStatusManager.sol";
import {PairPoolManager} from "../src/PairPoolManager.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {PoolStatus} from "../src/types/PoolStatus.sol";
import {PoolStatusLibrary} from "../src/types/PoolStatusLibrary.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition, MarginPositionVo} from "../src/types/MarginPosition.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "../src/types/LiquidityParams.sol";
import {TimeLibrary} from "../src/libraries/TimeLibrary.sol";
import {PerLibrary} from "../src/libraries/PerLibrary.sol";
import {LiquidityLevel} from "../src/libraries/LiquidityLevel.sol";
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
    using LiquidityLevel for uint8;
    using CurrencyPoolLibrary for Currency;
    using PoolStatusLibrary for PoolStatus;
    using PerLibrary for uint256;

    function setUp() public {
        deployHookAndRouter();
        initPoolLiquidity();
    }

    function test_hook_margin_tokens() public {
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), tokensKey.toId(), false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;
        tokenA.approve(address(marginPositionManager), payValue);
        tokenB.approve(address(marginPositionManager), payValue);
        MarginParams memory params = MarginParams({
            poolId: tokensKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
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
            poolId: tokensKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
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
        (uint256 _reserves0, uint256 _reserves1) = pairPoolManager.getReserves(tokensKey.toId());
        console.log("_reserves0:%s,_reserves1:%s", _reserves0, _reserves1);
        PoolStatus memory _status = pairPoolManager.getStatus(tokensKey.toId());
        console.log("reserve0:%s,reserve1:%s", uint256(_status.realReserve0), uint256(_status.realReserve1));
        console.log(
            "mirrorReserve0:%s,mirrorReserve1:%s", uint256(_status.mirrorReserve0), uint256(_status.mirrorReserve1)
        );
    }

    function test_hook_repay_tokens() public {
        test_hook_margin_tokens();
        address user = address(this);
        uint256 positionId = marginPositionManager.getPositionId(tokensKey.toId(), false, user, true);
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
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), tokensKey.toId(), false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        PoolId poolId = tokensKey.toId();
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
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin(params);
        Currency marginCurrency = tokensKey.currency0;
        uint256 lendingId = marginCurrency.toTokenId(poolId);
        positionId = marginPositionManager.getPositionId(tokensKey.toId(), false, user, true);
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
        // skip(3600);
        uint256 releaseAmount = 0.01 ether;
        tokenA.approve(address(pairPoolManager), releaseAmount);
        int256 pnlAmount = marginChecker.estimatePNL(marginPositionManager, positionId, 300000);
        marginPositionManager.close(positionId, 300000, pnlAmount, UINT256_MAX);
        marginBalance = lendingPoolManager.balanceOf(address(marginPositionManager), lendingId);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        console.log(
            "after close positionId:%s,position.borrowAmount:%s,marginBalance:%s",
            positionId,
            newPosition.borrowAmount,
            marginBalance
        );
        skip(3600 * 2);
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
        console.log("pnlAmount:%s", pnlAmount);
    }

    function moreMarginRate(PoolStatus memory status, uint256 borrowAmountBefore, uint256 rateCumulativeLastBefore)
        public
    {
        PoolId poolId = nativeKey.toId();
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), poolId, false);
        skip(3600 * 20);

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
        skip(100);
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
        payValue = 0.0002 ether;
        params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 1,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            deadline: block.timestamp + 1001
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
            deadline: 0
        });
        vm.expectRevert(bytes("EXPIRED"));
        payValue = 0.001 ether;
        skip(3600 * 20);
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        vm.stopPrank();
    }

    function test_hook_repay_native() public {
        test_hook_margin_native();
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        uint256 positionId = marginPositionManager.getPositionId(poolId, false, user, true);
        assertGt(positionId, 0);
        skip(3600 * 20);
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log("status.mirrorReserve1:%s", status.mirrorReserve1);
        assertLe(status.mirrorReserve1, position.borrowAmount, "status.mirrorReserve1<=position.borrowAmount");
        uint256 userBalance = user.balance;
        uint256 repay = 0.01 ether;
        tokenB.approve(address(pairPoolManager), repay);
        marginPositionManager.repay(positionId, repay, UINT256_MAX);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        assertEq((position.borrowAmount - newPosition.borrowAmount) / 10, repay / 10, "repay assertEq");
        assertEq(
            position.marginTotal + position.marginAmount - newPosition.marginTotal - newPosition.marginAmount,
            user.balance - userBalance,
            "userBalance"
        );
        status = pairPoolManager.getStatus(poolId);
        assertLe(status.mirrorReserve1, newPosition.borrowAmount, "status.mirrorReserve1<=newPosition.borrowAmount");

        uint256 pFeeAmount = poolStatusManager.protocolFeesAccrued(nativeKey.currency0);
        console.log("pFeeAmount:%s", pFeeAmount);
        uint256 collectFeeAmount =
            marginFees.collectProtocolFees(address(pairPoolManager), user, nativeKey.currency0, pFeeAmount);
        console.log("collectFeeAmount:%s", collectFeeAmount);
        assertEq(collectFeeAmount, pFeeAmount, "collectFeeAmount");
    }

    function test_hook_close_native() public {
        test_hook_margin_native();
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        uint256 positionId = marginPositionManager.getPositionId(poolId, false, user, true);
        assertGt(positionId, 0);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        assertEq(status.mirrorReserve1, position.borrowAmount);
        marginPositionManager.close(positionId, 3000, 0, UINT256_MAX);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        assertEq(position.borrowAmount - newPosition.borrowAmount, position.borrowAmount * 3000 / ONE_MILLION);
        status = pairPoolManager.getStatus(poolId);
        assertEq(status.mirrorReserve1, newPosition.borrowAmount);
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
        uint256 amountIn = 0.01 ether;
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
            skip(30 * swapIndex);
        }
        console.log(
            "before swapIndex:%s, liquidate nativeHook.balance:%s,marginPositionManager.balance:%s",
            swapIndex,
            address(pairPoolManager).balance,
            address(marginPositionManager).balance
        );

        marginPositionManager.liquidateBurn(positionId);
        position = marginPositionManager.getPosition(positionId);
        console.log(
            "after liquidate nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(pairPoolManager).balance,
            address(marginPositionManager).balance
        );
    }

    function test_hook_margin_max() public {
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
        (payValue, borrowAmount) = getMarginMax(nativeKey.toId(), false, 3);
        console.log("maxPayValue:%s", payValue);
        params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            deadline: block.timestamp + 1000
        });
        skip(1000);
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
        (uint24 _fee, uint24 _marginFee) =
            pairPoolManager.marginFees().getPoolFees(address(pairPoolManager), poolId, true, 0, 0);
        console.log("before margin _fee:%s", _fee);
        test_hook_margin_usdts();
        (_fee, _marginFee) = pairPoolManager.marginFees().getPoolFees(address(pairPoolManager), poolId, true, 0, 0);
        console.log("after margin _fee:%s", _fee);
        skip(30);
        (_fee, _marginFee) = pairPoolManager.marginFees().getPoolFees(address(pairPoolManager), poolId, true, 0, 0);
        console.log("after margin _fee:%s", _fee);
        skip(126);
        (_fee, _marginFee) = pairPoolManager.marginFees().getPoolFees(address(pairPoolManager), poolId, true, 0, 0);
        console.log("after margin _fee:%s", _fee);
    }

    function test_hook_liquidateCall01() public {
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

        uint256 amountIn = 0.05 ether;
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
            swapIndex++;
            skip(300);
            (liquidated, borrowAmount) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
            position = marginPositionManager.getPosition(positionId);
            status = pairPoolManager.getStatus(poolId);
            console.log(
                "position.borrowAmount:%s,rateCumulativeLast:%s,borrowAmount:%s",
                position.borrowAmount,
                position.rateCumulativeLast,
                borrowAmount
            );
            uint256 _repayAmount = marginChecker.getLiquidateRepayAmount(address(marginPositionManager), positionId);
            console.log("repayAmount:%s,borrowAmount:%s", _repayAmount, borrowAmount);
            assertGe(position.borrowAmount, status.mirrorReserve1);
        }
        uint256 repayAmount = marginChecker.getLiquidateRepayAmount(address(marginPositionManager), positionId);
        position = marginPositionManager.getPosition(positionId);
        tokenB.approve(address(pairPoolManager), repayAmount);
        uint256 balanceBefore = tokenB.balanceOf(user);
        uint256 nativeBefore = user.balance;
        marginPositionManager.liquidateCall(positionId);
        uint256 balanceAfter = tokenB.balanceOf(user);
        uint256 nativeAfter = user.balance;
        assertEq(balanceBefore - balanceAfter, repayAmount, "borrow eq");
        assertEq(nativeAfter - nativeBefore, position.marginAmount + position.marginTotal, "margin eq");
        position = marginPositionManager.getPosition(positionId);
        assertEq(position.borrowAmount, 0);
    }

    function test_hook_liquidateCall02() public {
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
            swapIndex++;
            skip(300);
            (liquidated, borrowAmount) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
            position = marginPositionManager.getPosition(positionId);
            status = pairPoolManager.getStatus(poolId);
            console.log(
                "position.borrowAmount:%s,rateCumulativeLast:%s,borrowAmount:%s",
                position.borrowAmount,
                position.rateCumulativeLast,
                borrowAmount
            );
            uint256 _repayAmount = marginChecker.getLiquidateRepayAmount(address(marginPositionManager), positionId);
            console.log("repayAmount:%s,borrowAmount:%s", _repayAmount, borrowAmount);
            assertGe(position.borrowAmount, status.mirrorReserve1);
        }
        uint256 repayAmount = marginChecker.getLiquidateRepayAmount(address(marginPositionManager), positionId);
        position = marginPositionManager.getPosition(positionId);
        tokenB.approve(address(pairPoolManager), repayAmount);
        uint256 balanceBefore = tokenB.balanceOf(user);
        uint256 nativeBefore = user.balance;
        marginPositionManager.liquidateCall(positionId);
        uint256 balanceAfter = tokenB.balanceOf(user);
        uint256 nativeAfter = user.balance;
        assertEq(balanceBefore - balanceAfter, repayAmount, "borrow eq");
        assertEq(nativeAfter - nativeBefore, position.marginAmount + position.marginTotal, "margin eq");
        position = marginPositionManager.getPosition(positionId);
        assertEq(position.borrowAmount, 0);
    }

    function test_getPositions() public {
        PoolId poolId1 = tokensKey.toId();
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
        PoolId poolId1 = nativeKey.toId();
        uint256 positionId;
        uint256 borrowAmount;
        (uint256 payValue, uint256 borrowAmountEstimate) = getMarginMax(poolId1, marginForOne, leverage);
        MarginParams memory params = MarginParams({
            poolId: poolId1,
            marginForOne: marginForOne,
            leverage: leverage,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        assertGt(positionId, 0);
        assertLt(borrowAmountEstimate - borrowAmount, 1000);
    }

    function test_OneLeverage() public {
        leverageMax(true, 1);
        skip(1000);
        leverageMax(false, 1);
    }

    function test_TwoLeverage() public {
        leverageMax(true, 2);
        skip(1000);
        leverageMax(false, 2);
    }

    function test_ThreeLeverage() public {
        leverageMax(true, 3);
        skip(1000);
        leverageMax(false, 3);
    }

    function test_FourLeverage() public {
        leverageMax(true, 4);
        skip(1000);
        leverageMax(false, 4);
    }

    function test_FiveLeverage() public {
        leverageMax(true, 5);
        skip(1000);
        leverageMax(false, 5);
    }

    function testGetPositionsZero() public view {
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = 1;
        positionIds[1] = 2;
        marginChecker.getPositions(marginPositionManager, positionIds);
    }

    function testBorrowOne() public {
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.0001 ether;
        address user = vm.addr(1);
        (bool success,) = user.call{value: 1 ether}("");
        require(success, "TRANSFER_FAILED");
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 0,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            deadline: block.timestamp + 1000
        });
        uint256 beforeBalance = tokenB.balanceOf(user);
        assertEq(beforeBalance, 0, "beforeBalance==0");
        vm.startPrank(user);
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        uint256 afterBalance = tokenB.balanceOf(user);
        assertEq(positionId, 1);
        uint256 borrowPositionId = marginPositionManager.getPositionId(nativeKey.toId(), false, user, false);
        assertEq(positionId, borrowPositionId);
        assertEq(afterBalance, borrowAmount);
        uint256 beforeETH = user.balance;
        tokenB.approve(address(pairPoolManager), borrowAmount / 2);
        marginPositionManager.repay(positionId, borrowAmount / 2, block.timestamp + 1000);
        uint256 afterETH = user.balance;
        assertGt(afterETH, beforeETH);
        uint256 newAfterBalance = tokenB.balanceOf(user);
        assertEq(newAfterBalance, afterBalance - borrowAmount / 2);
        vm.expectRevert(bytes("BORROW_DISABLE_CLOSE"));
        marginPositionManager.close(positionId, 500000, 0, block.timestamp + 1000);
        vm.stopPrank();
    }

    uint24 minBorrowLevel = 1400000;
    uint24[] leverageThousandths = [150, 120, 90, 50, 10];

    function getBorrowMax(PoolId poolId, bool marginForOne, uint256 marginAmount)
        internal
        view
        returns (uint256 marginAmountIn, uint256 borrowMax)
    {
        (uint256 reserveBorrow, uint256 reserveMargin) =
            marginChecker.getReserves(address(pairPoolManager), poolId, marginForOne);
        marginAmountIn = marginAmount.mulMillionDiv(minBorrowLevel);
        borrowMax = Math.mulDiv(marginAmountIn, reserveBorrow, reserveMargin);
    }

    function getMarginMax(PoolId poolId, bool marginForOne, uint24 leverage)
        internal
        view
        returns (uint256 marginMax, uint256 borrowAmount)
    {
        PoolStatus memory status = pairPoolManager.getStatus(poolId);

        if (leverage > 0) {
            (uint256 marginReserve0, uint256 marginReserve1, uint256 incrementMaxMirror0, uint256 incrementMaxMirror1) =
                marginLiquidity.getMarginReserves(address(pairPoolManager), poolId, status);
            uint256 borrowMaxAmount = marginForOne ? incrementMaxMirror0 : incrementMaxMirror1;
            uint256 marginMaxTotal = (marginForOne ? marginReserve1 : marginReserve0);
            if (marginMaxTotal > 1000 && borrowMaxAmount > 1000) {
                borrowMaxAmount -= 1000;
                uint256 marginBorrowMax = status.getAmountOut(marginForOne, borrowMaxAmount);
                if (marginMaxTotal > marginBorrowMax) {
                    marginMaxTotal = marginBorrowMax;
                }
                {
                    uint256 marginMaxReserve = (marginForOne ? status.reserve1() : status.reserve0());
                    uint256 part = leverageThousandths[leverage - 1];
                    marginMaxReserve = Math.mulDiv(marginMaxReserve, part, 1000);
                    marginMaxTotal = Math.min(marginMaxTotal, marginMaxReserve);
                }
                borrowAmount = pairPoolManager.getAmountIn(poolId, marginForOne, marginMaxTotal);
            }
            marginMax = marginMaxTotal / leverage;
        } else {
            (uint256 interestReserve0, uint256 interestReserve1) =
                marginLiquidity.getFlowReserves(address(pairPoolManager), poolId, status);
            uint256 borrowMaxAmount = (marginForOne ? interestReserve0 : interestReserve1);
            uint256 flowMaxAmount = (marginForOne ? status.realReserve0 : status.realReserve1) * 20 / 100;
            borrowMaxAmount = Math.min(borrowMaxAmount, flowMaxAmount);
            if (borrowMaxAmount > 1000) {
                borrowAmount = borrowMaxAmount - 1000;
            } else {
                borrowAmount = 0;
            }
            if (borrowAmount > 0) {
                (uint256 reserve0, uint256 reserve1) = (status.reserve0(), status.reserve1());
                (uint256 reserveBorrow, uint256 reserveMargin) =
                    marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
                marginMax = Math.mulDiv(reserveMargin, borrowAmount, reserveBorrow);
            }
        }
    }

    function testBorrowMax() public {
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.0001 ether;
        address user = vm.addr(1);
        (bool success,) = user.call{value: 1 ether}("");
        assertTrue(success);
        (, uint256 borrowMax) = getBorrowMax(nativeKey.toId(), false, payValue);
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 0,
            marginAmount: payValue,
            borrowAmount: borrowMax,
            borrowMaxAmount: 0,
            deadline: block.timestamp + 1000
        });
        vm.startPrank(user);
        uint256 beforeBalance = tokenB.balanceOf(user);
        assertEq(beforeBalance, 0);
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        uint256 afterBalance = tokenB.balanceOf(user);
        assertEq(positionId, 1);
        uint256 borrowPositionId = marginPositionManager.getPositionId(nativeKey.toId(), false, user, false);
        assertEq(positionId, borrowPositionId);
        assertEq(afterBalance, borrowAmount);
        skip(3600);
        uint256 beforeETH = user.balance;
        tokenB.approve(address(pairPoolManager), borrowAmount / 2);
        marginPositionManager.repay(positionId, borrowAmount / 2, block.timestamp + 1001);
        uint256 afterETH = user.balance;
        assertGt(afterETH, beforeETH);
        uint256 newAfterBalance = tokenB.balanceOf(user);
        assertEq(newAfterBalance, afterBalance - borrowAmount / 2);
        vm.expectRevert(bytes("BORROW_DISABLE_CLOSE"));
        marginPositionManager.close(positionId, 500000, 0, block.timestamp + 1002);
        vm.stopPrank();
    }

    function testModifyPosition() public {
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.0001 ether;
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: true,
            leverage: 0,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin(params);
        MarginPosition memory _position = marginPositionManager.getPosition(positionId);
        console.log(
            "_position.marginAmount:%s,_position.borrowAmount:%s", _position.marginAmount, _position.borrowAmount
        );
        tokenB.approve(address(lendingPoolManager), payValue);
        skip(3600);
        marginPositionManager.modify(positionId, int256(payValue));
        _position = marginPositionManager.getPosition(positionId);
        console.log(
            "_position.marginAmount:%s,_position.borrowAmount:%s", _position.marginAmount, _position.borrowAmount
        );
    }

    function testGetMarginMax() public view {
        (uint256 marginMax, uint256 borrowAmount) = getMarginMax(nativeKey.toId(), true, 0);
        console.log("marginMax:%s,borrowAmount:%s", marginMax, borrowAmount);
        assertGt(marginMax, borrowAmount);
        (marginMax, borrowAmount) = getMarginMax(nativeKey.toId(), false, 0);
        console.log("marginMax:%s,borrowAmount:%s", marginMax, borrowAmount);
        assertLt(marginMax, borrowAmount);
        (marginMax, borrowAmount) = getMarginMax(nativeKey.toId(), false, 1);
        console.log("marginMax:%s,borrowAmount:%s", marginMax, borrowAmount);
    }

    function testMarginAndLending() public {
        uint256 liquidity;
        PoolId poolId = nativeKey.toId();
        {
            liquidity = marginLiquidity.getPoolLiquidity(poolId, address(this), LiquidityLevel.BORROW_BOTH);
            assertGt(liquidity, 0);
            RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
                poolId: poolId,
                level: LiquidityLevel.BORROW_BOTH,
                liquidity: liquidity,
                deadline: type(uint256).max
            });
            skip(3600 * 2);
            pairPoolManager.removeLiquidity(removeParams);
            uint256 amount0 = 0.1 ether;
            uint256 amount1 = 1 ether;
            AddLiquidityParams memory params = AddLiquidityParams({
                poolId: poolId,
                amount0: amount0,
                amount1: amount1,
                to: address(this),
                level: LiquidityLevel.RETAIN_BOTH,
                deadline: type(uint256).max
            });
            pairPoolManager.addLiquidity{value: amount0}(params);
            params = AddLiquidityParams({
                poolId: poolId,
                amount0: amount0,
                amount1: amount1,
                to: address(this),
                level: LiquidityLevel.BORROW_BOTH,
                deadline: type(uint256).max
            });
            pairPoolManager.addLiquidity{value: amount0}(params);
            PoolStatus memory status = pairPoolManager.getStatus(nativeKey.toId());
            printPoolStatus(status);
            liquidity = marginLiquidity.getPoolLiquidity(poolId, address(this), LiquidityLevel.BORROW_BOTH);
        }
        address user = vm.addr(1);
        uint256 payValue = 0.001 ether;
        {
            (bool success,) = user.call{value: 1 ether}("");
            assertTrue(success);
            tokenB.approve(address(lendingPoolManager), 10 ether);
            lendingPoolManager.deposit{value: 10 ether}(address(this), poolId, nativeKey.currency0, 10 ether);
            lendingPoolManager.deposit(address(this), poolId, nativeKey.currency1, 10 ether);
        }
        skip(1000);
        {
            uint256 nowLiquidity = marginLiquidity.getPoolLiquidity(poolId, address(this), LiquidityLevel.BORROW_BOTH);
            assertEq(nowLiquidity, liquidity);
            console.log("before margin:nowLiquidity, liquidity", nowLiquidity, liquidity);
            tokenB.transfer(user, 1 ether);
        }
        vm.startPrank(user);
        MarginParams memory borrowParams = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 2,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            deadline: block.timestamp + 1000
        });

        (uint256 positionId, uint256 borrowAmount) = marginPositionManager.margin{value: payValue}(borrowParams);
        assertEq(positionId, 1);
        skip(1000);

        {
            payValue = borrowAmount / 10;
            borrowParams = MarginParams({
                poolId: poolId,
                marginForOne: true,
                leverage: 2,
                marginAmount: payValue,
                borrowAmount: 0,
                borrowMaxAmount: 0,
                deadline: block.timestamp + 1000
            });
            tokenB.approve(address(pairPoolManager), payValue);
            (positionId, borrowAmount) = marginPositionManager.margin(borrowParams);
            console.log("borrowAmount:%s", borrowAmount);
        }
        {
            uint256 nowLiquidity = marginLiquidity.getPoolLiquidity(poolId, address(this), LiquidityLevel.BORROW_BOTH);
            assertGt(nowLiquidity, liquidity);
            console.log("after margin:nowLiquidity%s, liquidity%s", nowLiquidity, liquidity);
        }
        vm.stopPrank();
        {
            PoolStatus memory status = pairPoolManager.getStatus(nativeKey.toId());
            printPoolStatus(status);
        }
    }

    function testMarginLendingTwo() public {
        testMarginAndLending();
        PoolId poolId = nativeKey.toId();
        uint256[4] memory beforeLiquidities = marginLiquidity.getPoolLiquidities(poolId, address(this));
        uint256 positionId = 2;
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log(
            "position.marginAmount:%s,position.marginTotal:%s,position.borrowAmount:%s",
            position.marginAmount,
            position.marginTotal,
            position.borrowAmount
        );
        (bool liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
        uint256 amountIn = 1 ether;
        uint256 swapIndex = 0;
        while (!liquidated) {
            tokenB.approve(address(swapRouter), amountIn);
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

            (liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
            swapIndex++;
            skip(30);
            console.log("swapIndex:%s", swapIndex);
        }
        PoolStatus memory status = pairPoolManager.getStatus(nativeKey.toId());
        console.log("before liquidateBurn");
        printPoolStatus(status);
        uint256 beforeLendingAmount0 =
            lendingPoolManager.balanceOf(address(this), nativeKey.currency0.toTokenId(poolId));
        uint256 beforeLendingAmount1 =
            lendingPoolManager.balanceOf(address(this), nativeKey.currency1.toTokenId(poolId));
        marginPositionManager.liquidateBurn(positionId);
        uint256 afterLendingAmount0 = lendingPoolManager.balanceOf(address(this), nativeKey.currency0.toTokenId(poolId));
        uint256 afterLendingAmount1 = lendingPoolManager.balanceOf(address(this), nativeKey.currency1.toTokenId(poolId));
        assertLt(afterLendingAmount0, beforeLendingAmount0);
        assertLt(beforeLendingAmount1, afterLendingAmount1);
        position = marginPositionManager.getPosition(positionId);
        assertEq(position.borrowAmount, 0);
        uint256[4] memory afterLiquidities = marginLiquidity.getPoolLiquidities(poolId, address(this));
        assertEq(afterLiquidities[0], beforeLiquidities[0]);
        assertEq(afterLiquidities[1], beforeLiquidities[1]);
        assertEq(afterLiquidities[2], beforeLiquidities[2]);
        assertLt(afterLiquidities[3], beforeLiquidities[3]);
        console.log("after liquidateBurn,before withdraw");
        status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
        lendingPoolManager.withdraw(address(this), poolId, nativeKey.currency0, afterLendingAmount0);
        console.log("after withdraw");
        status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
        address user1 = vm.addr(1);
        tokenB.transfer(user1, 1 ether);
        vm.startPrank(user1);
        positionId = 1;
        position = marginPositionManager.getPosition(positionId);
        tokenB.approve(address(pairPoolManager), position.borrowAmount);
        console.log("position.marginAmount:%s", position.marginAmount);
        marginPositionManager.repay(positionId, position.borrowAmount, block.timestamp + 1000);
        vm.stopPrank();
        console.log("after repay");
        status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
        uint256 balance0 = manager.balanceOf(address(lendingPoolManager), nativeKey.currency0.toId());
        console.log("balance0:%s", balance0);
    }

    function testEarnedMarginLendingTwo() public {
        testMarginAndLending();
        PoolId poolId = nativeKey.toId();
        uint256[4] memory beforeLiquidities = marginLiquidity.getPoolLiquidities(poolId, address(this));
        uint256 positionId = 2;
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log(
            "position.marginAmount:%s,position.marginTotal:%s,position.borrowAmount:%s",
            position.marginAmount,
            position.marginTotal,
            position.borrowAmount
        );
        (bool liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
        uint256 amountIn = 0.01 ether;
        uint256 swapIndex = 0;
        while (!liquidated) {
            tokenB.approve(address(swapRouter), amountIn);
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
            (liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
            swapIndex++;
            skip(30);
            console.log("swapIndex:%s", swapIndex);
        }
        uint256 beforeLendingAmount0 =
            lendingPoolManager.balanceOf(address(this), nativeKey.currency0.toTokenId(poolId));
        uint256 beforeLendingAmount1 =
            lendingPoolManager.balanceOf(address(this), nativeKey.currency1.toTokenId(poolId));
        marginPositionManager.liquidateBurn(positionId);
        uint256 afterLendingAmount0 = lendingPoolManager.balanceOf(address(this), nativeKey.currency0.toTokenId(poolId));
        uint256 afterLendingAmount1 = lendingPoolManager.balanceOf(address(this), nativeKey.currency1.toTokenId(poolId));
        assertGt(afterLendingAmount0, beforeLendingAmount0);
        assertLe(beforeLendingAmount1, afterLendingAmount1);
        position = marginPositionManager.getPosition(positionId);
        assertEq(position.borrowAmount, 0);
        uint256[4] memory afterLiquidities = marginLiquidity.getPoolLiquidities(poolId, address(this));
        assertEq(afterLiquidities[0], beforeLiquidities[0]);
        assertEq(afterLiquidities[1], beforeLiquidities[1]);
        assertEq(afterLiquidities[2], beforeLiquidities[2]);
        assertGt(afterLiquidities[3], beforeLiquidities[3]);
        console.log("after liquidateBurn,before withdraw");
        PoolStatus memory status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
        lendingPoolManager.withdraw(address(this), poolId, nativeKey.currency0, afterLendingAmount0);
        console.log("after withdraw");
        status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
        address user1 = vm.addr(1);
        tokenB.transfer(user1, 1 ether);
        vm.startPrank(user1);
        positionId = 1;
        position = marginPositionManager.getPosition(positionId);
        tokenB.approve(address(pairPoolManager), position.borrowAmount);
        console.log("position.marginAmount:%s", position.marginAmount);
        marginPositionManager.repay(positionId, position.borrowAmount, block.timestamp + 1000);
        vm.stopPrank();
        console.log("after repay");
        status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
        uint256 balance0 = manager.balanceOf(address(lendingPoolManager), nativeKey.currency0.toId());
        console.log("balance0:%s", balance0);
    }

    function testInterestSwitch() public {
        address user = address(this);
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), tokensKey.toId(), false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        PoolId poolId = tokensKey.toId();
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
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin(params);
        positionId = marginPositionManager.getPositionId(poolId, false, user, true);
        assertGt(positionId, 0);
        PoolStatus memory beforeStatus = pairPoolManager.getStatus(poolId);
        PoolStatus memory afterStatus = pairPoolManager.getStatus(poolId);
        assertGt(beforeStatus.totalMirrorReserve1(), 0, "MirrorReserve1 > 0");
        assertEq(beforeStatus.totalMirrorReserve1(), afterStatus.totalMirrorReserve1(), "MirrorReserve1 Eq 1");
        skip(1000);
        afterStatus = pairPoolManager.getStatus(poolId);
        assertLt(beforeStatus.totalMirrorReserve1(), afterStatus.totalMirrorReserve1(), "MirrorReserve1 Lt");
        poolStatusManager.setInterestClosed(poolId, true);
        beforeStatus = pairPoolManager.getStatus(poolId);
        skip(1000);
        afterStatus = pairPoolManager.getStatus(poolId);
        assertEq(beforeStatus.totalMirrorReserve1(), afterStatus.totalMirrorReserve1(), "MirrorReserve1 Eq 2");

        {
            uint256 amountIn = 0.0123 ether;
            MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
                poolId: poolId,
                zeroForOne: true,
                to: user,
                amountIn: amountIn,
                amountOut: 0,
                amountOutMin: 0,
                deadline: type(uint256).max
            });
            uint256 amountOut = swapRouter.exactInput(swapParams);
            console.log("amountIn:%s,amountOut:%s", amountIn, amountOut);
            afterStatus = pairPoolManager.getStatus(poolId);
            uint256 amount0 = 0.0123 ether;
            uint256 amount1 = amount0 * afterStatus.reserve1() / afterStatus.reserve0();
            AddLiquidityParams memory addParams = AddLiquidityParams({
                poolId: poolId,
                amount0: amount0,
                amount1: amount1,
                to: user,
                level: LiquidityLevel.RETAIN_BOTH,
                deadline: type(uint256).max
            });
            uint256 liquidity = pairPoolManager.addLiquidity(addParams);
            skip(1000);
            RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
                poolId: poolId,
                level: LiquidityLevel.RETAIN_BOTH,
                liquidity: liquidity,
                deadline: type(uint256).max
            });
            pairPoolManager.removeLiquidity(removeParams);
        }
        poolStatusManager.setInterestClosed(poolId, false);
        {
            uint256 amountIn = 0.0123 ether;
            MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
                poolId: poolId,
                zeroForOne: true,
                to: user,
                amountIn: amountIn,
                amountOut: 0,
                amountOutMin: 0,
                deadline: type(uint256).max
            });
            uint256 amountOut = swapRouter.exactInput(swapParams);
            console.log("amountIn:%s,amountOut:%s", amountIn, amountOut);
            afterStatus = pairPoolManager.getStatus(poolId);
            uint256 amount0 = 0.0123 ether;
            uint256 amount1 = amount0 * afterStatus.reserve1() / afterStatus.reserve0();
            AddLiquidityParams memory addParams = AddLiquidityParams({
                poolId: poolId,
                amount0: amount0,
                amount1: amount1,
                to: user,
                level: LiquidityLevel.RETAIN_BOTH,
                deadline: type(uint256).max
            });
            uint256 liquidity = pairPoolManager.addLiquidity(addParams);
            skip(1000);
            RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
                poolId: poolId,
                level: LiquidityLevel.RETAIN_BOTH,
                liquidity: liquidity,
                deadline: type(uint256).max
            });
            pairPoolManager.removeLiquidity(removeParams);
        }
    }
}
