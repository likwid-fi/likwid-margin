// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {MarginHookManager} from "../src/MarginHookManager.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {HookParams} from "../src/types/HookParams.sol";
import {HookStatus} from "../src/types/HookStatus.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition, MarginPositionVo} from "../src/types/MarginPosition.sol";
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

contract MarginPositionManagerTest is DeployHelper {
    function setUp() public {
        deployHookAndRouter();
        initPoolLiquidity();
    }

    function test_hook_margin_tokens() public {
        address user = address(this);
        uint256 rate = marginFees.getBorrowRate(address(hookManager), key.toId(), false);
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
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin(params);
        console.log(
            "hookManager.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
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
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin(params);
        console.log(
            "hookManager.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
        position = marginPositionManager.getPosition(positionId);
        console.log(
            "positionId:%s,position.borrowAmount:%s,rateCumulativeLast:%s",
            positionId,
            position.borrowAmount,
            position.rateCumulativeLast
        );
        (uint256 _reserves0, uint256 _reserves1) = hookManager.getReserves(key.toId());
        console.log("_reserves0:%s,_reserves1:%s", _reserves0, _reserves1);
        HookStatus memory _status = hookManager.getStatus(key.toId());
        console.log("reserve0:%s,reserve1:%s", uint256(_status.realReserve0), uint256(_status.realReserve1));
        console.log(
            "mirrorReserve0:%s,mirrorReserve1:%s", uint256(_status.mirrorReserve0), uint256(_status.mirrorReserve1)
        );
    }

    function test_hook_repay_tokens() public {
        test_hook_margin_tokens();
        address user = address(this);
        uint256 positionId = marginPositionManager.getPositionId(key.toId(), false, user);
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

    function test_hook_close_tokens() public {
        test_hook_margin_tokens();
        address user = address(this);
        uint256 positionId = marginPositionManager.getPositionId(key.toId(), false, user);
        assertGt(positionId, 0);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log("before repay positionId:%s,position.borrowAmount:%s", positionId, position.borrowAmount);
        uint256 releaseAmount = 0.01 ether;
        tokenA.approve(address(hookManager), releaseAmount);
        marginPositionManager.close(positionId, 30000, 0, UINT256_MAX);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        console.log("after repay positionId:%s,position.borrowAmount:%s", positionId, newPosition.borrowAmount);
        vm.warp(3600 * 10);
        marginPositionManager.close(positionId, 1000000, 0, UINT256_MAX);
        newPosition = marginPositionManager.getPosition(positionId);
        console.log("after repay positionId:%s,position.borrowAmount:%s", positionId, newPosition.borrowAmount);
    }

    function test_hook_margin_rate() public {
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        uint256 rate = marginFees.getBorrowRate(address(hookManager), poolId, false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;
        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 1,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log(
            "hookManager.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
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
        rate = marginFees.getBorrowRate(address(hookManager), poolId, false);
        uint256 rateLast = marginFees.getBorrowRateCumulativeLast(address(hookManager), poolId, false);
        console.log("rate:%s,rateLast:%s", rate, rateLast);
        vm.warp(3600 * 10);
        uint256 timeElapsed = (3600 * 10 - 1) * 10 ** 3;
        uint256 rateLastX = (ONE_BILLION + rate * timeElapsed / YEAR_SECONDS) * rateLast / ONE_BILLION;
        uint256 newRateLast = marginFees.getBorrowRateCumulativeLast(address(hookManager), poolId, false);
        console.log("timeElapsed:%s,rateLastX:%s,newRateLast:%s", timeElapsed, rateLastX, newRateLast);
        uint256 borrowAmountLast = borrowAmount;
        payValue = 0.02e18;
        params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 1,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log(
            "nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
        console.log("positionId:%s,borrowAmount:%s", positionId, borrowAmount);
        position = marginPositionManager.getPosition(positionId);
        uint256 borrowAmountAll = borrowAmount + borrowAmountLast * rateLastX / rateLast;
        assertEq(position.borrowAmount / 100, borrowAmountAll / 100);
        console.log("positionId:%s,position.borrowAmount:%s,all:%s", positionId, position.borrowAmount, borrowAmountAll);

        vm.warp(3600 * 20);
        rate = marginFees.getBorrowRate(address(hookManager), poolId, false);
        timeElapsed = (3600 * 10) * 10 ** 3;
        rateLast = rateLastX;
        rateLastX = (ONE_BILLION + rate * timeElapsed / YEAR_SECONDS) * rateLast / ONE_BILLION;
        console.log("timeElapsed:%s,rateLast:%s,rateLastX:%s", timeElapsed, rateLast, rateLastX);

        payValue = 0.02e18;
        params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log(
            "nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
        console.log("positionId:%s,borrowAmount:%s", positionId, borrowAmount);
        position = marginPositionManager.getPosition(positionId);
        borrowAmountAll = borrowAmount + borrowAmountAll * rateLastX / rateLast;
        assertEq(position.borrowAmount / 100, borrowAmountAll / 100);
        console.log("positionId:%s,position.borrowAmount:%s,all:%s", positionId, position.borrowAmount, borrowAmountAll);
    }

    function test_hook_margin_native() public {
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        uint256 rate = marginFees.getBorrowRate(address(hookManager), poolId, false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;
        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        assertEq(address(marginPositionManager).balance, position.marginAmount + position.marginTotal);
        uint256 _positionId = marginPositionManager.getPositionId(poolId, false, user);
        assertEq(positionId, _positionId);
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
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        payValue = 0.001 ether;
        vm.expectPartialRevert(MarginPositionManager.InsufficientAmount.selector);
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
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
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
        HookStatus memory status = hookManager.getStatus(poolId);
        uint256 positionId = marginPositionManager.getPositionId(poolId, false, user);
        assertGt(positionId, 0);
        vm.warp(3600 * 20);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        assertEq(status.mirrorReserve1, position.rawBorrowAmount);
        uint256 userBalance = user.balance;
        uint256 repay = 0.01 ether;
        tokenB.approve(address(hookManager), repay);
        marginPositionManager.repay(positionId, repay, UINT256_MAX);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        assertEq((position.borrowAmount - newPosition.borrowAmount), repay);
        assertEq(
            position.marginTotal + position.marginAmount - newPosition.marginTotal - newPosition.marginAmount,
            user.balance - userBalance
        );
        status = hookManager.getStatus(poolId);
        assertEq(status.mirrorReserve1, newPosition.rawBorrowAmount);

        (uint112 interest0, uint112 interest1) = marginFees.getInterests(address(hookManager), poolId);
        console.log("interest0:%s,interest1:%s", interest0, interest1);
        assertEq(
            (
                (position.borrowAmount - newPosition.borrowAmount)
                    - (position.rawBorrowAmount - newPosition.rawBorrowAmount)
            ) / 10,
            interest1 / 10
        );
    }

    function test_hook_close_native() public {
        test_hook_margin_native();
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        HookStatus memory status = hookManager.getStatus(poolId);
        uint256 positionId = marginPositionManager.getPositionId(poolId, false, user);
        assertGt(positionId, 0);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        assertEq(status.mirrorReserve1, position.rawBorrowAmount);
        marginPositionManager.close(positionId, 3000, 0, UINT256_MAX);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        assertEq(position.borrowAmount - newPosition.borrowAmount, position.borrowAmount * 3000 / ONE_MILLION);
        status = hookManager.getStatus(poolId);
        assertEq(status.mirrorReserve1, newPosition.rawBorrowAmount);
    }

    function test_hook_liquidate_burn() public {
        address user = address(this);
        tokenB.approve(address(hookManager), 1e18);
        uint256 rate = marginFees.getBorrowRate(address(hookManager), nativeKey.toId(), false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.001 ether;
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log(
            "hookManager.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
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

        positionId = marginPositionManager.getPositionId(nativeKey.toId(), false, user);
        assertGt(positionId, 0);
        position = marginPositionManager.getPosition(positionId);
        (bool liquidated, uint256 amountNeed) = marginPositionManager.checkLiquidate(positionId);
        console.log("liquidated:%s,amountNeed:%s", liquidated, amountNeed);
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
            (liquidated, amountNeed) = marginPositionManager.checkLiquidate(positionId);
            swapIndex++;
            console.log("amountNeed:%s,swapIndex:%s", amountNeed, swapIndex);
            vm.warp(30 * swapIndex);
        }
        console.log(
            "before liquidate nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
        marginPositionManager.liquidateBurn(positionId, "");
        position = marginPositionManager.getPosition(positionId);
        console.log(
            "after liquidate nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
    }

    function test_hook_liquidate_burn_without_oracle() public {
        address user = address(this);
        marginPositionManager.setMarginOracle(address(0));
        tokenB.approve(address(hookManager), 1e18);
        uint256 rate = marginFees.getBorrowRate(address(hookManager), nativeKey.toId(), false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.001 ether;
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log(
            "hookManager.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
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

        positionId = marginPositionManager.getPositionId(nativeKey.toId(), false, user);
        assertGt(positionId, 0);
        position = marginPositionManager.getPosition(positionId);
        (bool liquidated, uint256 amountNeed) = marginPositionManager.checkLiquidate(positionId);
        console.log("liquidated:%s,amountNeed:%s", liquidated, amountNeed);
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
            (liquidated, amountNeed) = marginPositionManager.checkLiquidate(positionId);
            swapIndex++;
            console.log("amountNeed:%s,swapIndex:%s", amountNeed, swapIndex);
            vm.warp(30 * swapIndex);
        }
        console.log(
            "before liquidate nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
        marginPositionManager.liquidateBurn(positionId, "");
        position = marginPositionManager.getPosition(positionId);
        console.log(
            "after liquidate nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
    }

    function test_hook_margin_max() public {
        address user = address(this);
        tokenB.approve(address(hookManager), 1e18);
        uint256 rate = marginFees.getBorrowRate(address(hookManager), nativeKey.toId(), false);
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
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log(
            "hookManager.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
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
        (payValue, borrowAmount) = marginPositionManager.getMarginMax(nativeKey.toId(), false, 3);
        params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log(
            "hookManager.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
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
        uint256 rate = marginFees.getBorrowRate(address(hookManager), poolId, false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;
        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
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
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
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
        HookStatus memory _status = hookManager.getStatus(poolId);
        console.log("reserve0:%s,reserve1:%s", uint256(_status.realReserve0), uint256(_status.realReserve1));
        console.log(
            "mirrorReserve0:%s,mirrorReserve1:%s", uint256(_status.mirrorReserve0), uint256(_status.mirrorReserve1)
        );
    }

    function test_hook_margin_usdts_buy() public {
        address user = address(this);
        PoolId poolId = usdtKey.toId();
        uint256 rate = marginFees.getBorrowRate(address(hookManager), poolId, false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;
        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: true,
            leverage: 3,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
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
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
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
        HookStatus memory _status = hookManager.getStatus(poolId);
        console.log("reserve0:%s,reserve1:%s", uint256(_status.realReserve0), uint256(_status.realReserve1));
        console.log(
            "mirrorReserve0:%s,mirrorReserve1:%s", uint256(_status.mirrorReserve0), uint256(_status.mirrorReserve1)
        );
    }

    function test_hook_repay_usdts() public {
        test_hook_margin_usdts();
        address user = address(this);
        PoolId poolId = usdtKey.toId();
        uint256 positionId = marginPositionManager.getPositionId(poolId, false, user);
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
        uint256 positionId = marginPositionManager.getPositionId(usdtKey.toId(), false, user);
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
        uint256 positionId = marginPositionManager.getPositionId(usdtKey.toId(), false, user);
        assertGt(positionId, 0);
        uint256 maxAmount = marginPositionManager.getMaxDecrease(positionId);
        console.log("test_hook_modify_usdts maxAmount:%s", maxAmount);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        marginPositionManager.modify(positionId, -int256(maxAmount));
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        assertEq(position.marginAmount - maxAmount, newPosition.marginAmount);
    }

    function test_hook_dynamic_fee_usdts() public {
        PoolId poolId = usdtKey.toId();
        (uint24 _fee, uint24 _marginFee) = hookManager.marginFees().getPoolFees(address(hookManager), poolId);
        console.log("before margin _fee:%s", _fee);
        test_hook_margin_usdts();
        (_fee, _marginFee) = hookManager.marginFees().getPoolFees(address(hookManager), poolId);
        console.log("after margin _fee:%s", _fee);
        vm.warp(30);
        (_fee, _marginFee) = hookManager.marginFees().getPoolFees(address(hookManager), poolId);
        console.log("after margin _fee:%s", _fee);
        vm.warp(126);
        (_fee, _marginFee) = hookManager.marginFees().getPoolFees(address(hookManager), poolId);
        console.log("after margin _fee:%s", _fee);
    }

    function test_hook_liquidateCall() public {
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        uint256 rate = marginFees.getBorrowRate(address(hookManager), poolId, false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.1 ether;
        MarginParams memory params = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
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
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log(
            "hookManager.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
        console.log("positionId:%s,borrowAmount:%s", positionId, borrowAmount);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        assertEq(borrowAmount, position.borrowAmount);
        console.log(
            "marginAmount:%s,marginTotal:%s,rateCumulativeLast:%s",
            position.marginAmount,
            position.marginTotal,
            position.rateCumulativeLast
        );

        positionId = marginPositionManager.getPositionId(poolId, false, user);
        assertGt(positionId, 0);
        position = marginPositionManager.getPosition(positionId);
        (bool liquidated, uint256 releaseAmount) = marginPositionManager.checkLiquidate(positionId);
        console.log("liquidated:%s,releaseAmount:%s", liquidated, releaseAmount);
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
                (liquidated, releaseAmount) = marginPositionManager.checkLiquidate(positionId);
                swapIndex++;
                console.log("releaseAmount:%s,swapIndex:%s", releaseAmount, swapIndex);
                vm.warp(30 * swapIndex);
            }
        }

        {
            position = marginPositionManager.getPosition(positionId);
            tokenB.approve(address(hookManager), position.borrowAmount);
            uint256 balanceBefore = tokenB.balanceOf(user);
            uint256 nativeBefore = user.balance;
            marginPositionManager.liquidateCall(positionId, "");
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
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
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
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        assertEq(positionId, 2);
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = 1;
        positionIds[1] = 2;
        MarginPositionVo[] memory positions = marginPositionManager.getPositions(positionIds);
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
            marginPositionManager.getMarginMax(poolId1, marginForOne, leverage);
        MarginParams memory params = MarginParams({
            poolId: poolId1,
            marginForOne: marginForOne,
            leverage: leverage,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        assertGt(positionId, 0);
        assertEq(borrowAmountEstimate / 1000, borrowAmount / 1000);
    }

    function test_OneLeverage() public {
        leverageMax(true, 1);
        leverageMax(false, 1);
    }

    function test_TwoLeverage() public {
        leverageMax(true, 2);
        leverageMax(false, 2);
    }

    function test_ThreeLeverage() public {
        leverageMax(true, 3);
        leverageMax(false, 3);
    }

    function test_FourLeverage() public {
        leverageMax(true, 4);
        leverageMax(false, 4);
    }

    function test_FiveLeverage() public {
        leverageMax(true, 5);
        leverageMax(false, 5);
    }

    function test_getPositionsZero() public view {
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = 1;
        positionIds[1] = 2;
        marginPositionManager.getPositions(positionIds);
    }
}
