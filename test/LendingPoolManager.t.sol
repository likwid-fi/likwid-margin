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
import {PerLibrary} from "../src/libraries/PerLibrary.sol";
import {CurrencyPoolLibrary} from "../src/libraries/CurrencyPoolLibrary.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "../src/types/LiquidityParams.sol";
import {LiquidityLevel} from "../src/libraries/LiquidityLevel.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition, MarginPositionVo} from "../src/types/MarginPosition.sol";
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
import {EIP20NonStandardThrowHarness} from "./mocks/EIP20NonStandardThrowHarness.sol";

import {DeployHelper} from "./utils/DeployHelper.sol";

contract LendingPoolManagerTest is DeployHelper {
    using CurrencyPoolLibrary for Currency;
    using PoolStatusLibrary for *;
    using LiquidityLevel for uint8;

    function setUp() public {
        deployHookAndRouter();
        initPoolLiquidity();
    }

    function testDepositAndWithdraw() public {
        address user = vm.addr(1);
        (bool success,) = user.call{value: 1 ether}("");
        require(success, "TRANSFER_FAILED");
        console.log("balance:%s", user.balance);
        Currency eth = CurrencyLibrary.ADDRESS_ZERO;
        PoolId nativeId = nativeKey.toId();
        uint256 id = eth.toTokenId(nativeId);
        vm.startPrank(user);
        uint256 lb = lendingPoolManager.balanceOf(user, id);
        assertEq(lb, 0);
        lendingPoolManager.deposit{value: 0.1 ether}(user, nativeId, eth, 0.1 ether);
        uint256 ethAmount = manager.balanceOf(address(lendingPoolManager), eth.toId());
        lb = lendingPoolManager.balanceOf(user, id);
        console.log("lending.balance:%s,ethAmount:%s", lb, ethAmount);
        lendingPoolManager.withdraw(user, nativeId, eth, 0.01 ether);
        ethAmount = manager.balanceOf(address(lendingPoolManager), eth.toId());
        lb = lendingPoolManager.balanceOf(user, id);
        console.log("lending.balance:%s,ethAmount:%s", lb, ethAmount);
        vm.stopPrank();
    }

    function testUpdateInterests() public {
        address user = vm.addr(1);
        (bool success,) = user.call{value: 1 ether}("");
        require(success, "TRANSFER_FAILED");
        console.log("balance:%s", user.balance);
        Currency eth = CurrencyLibrary.ADDRESS_ZERO;
        PoolId nativeId = nativeKey.toId();
        uint256 id = eth.toTokenId(nativeId);
        vm.startPrank(user);
        uint256 lb = lendingPoolManager.balanceOf(user, id);
        assertEq(lb, 0);
        lendingPoolManager.deposit{value: 0.1 ether}(user, nativeId, eth, 0.1 ether);
        uint256 ethAmount = manager.balanceOf(address(lendingPoolManager), eth.toId());
        lb = lendingPoolManager.balanceOf(user, id);
        console.log("lending.balance:%s,ethAmount:%s", lb, ethAmount);
        vm.stopPrank();
        tokenB.approve(address(lendingPoolManager), 0.1 ether);
        lendingPoolManager.deposit(user, nativeId, nativeKey.currency1, 0.099 ether);
        uint256 tokenBId = nativeKey.currency1.toTokenId(nativeId);
        lb = lendingPoolManager.balanceOf(user, tokenBId);
        assertGt(lb, 0);
        uint256 tokenBAmount = manager.balanceOf(address(lendingPoolManager), nativeKey.currency1.toId());
        console.log("lending.balance:%s,tokenBAmount:%s", lb, tokenBAmount);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.001 ether;
        address user0 = address(this);
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user0,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        skip(3600 * 10);
        borrowAmount = marginPositionManager.getPosition(positionId).borrowAmount;
        console.log("borrowAmount:%s", borrowAmount);
        marginPositionManager.close(positionId, PerLibrary.ONE_MILLION, 0, block.timestamp + 1000);
        lb = lendingPoolManager.balanceOf(user, tokenBId);
        uint256 mirrorBalance = mirrorTokenManager.balanceOf(address(lendingPoolManager), tokenBId);
        tokenBAmount = manager.balanceOf(address(lendingPoolManager), nativeKey.currency1.toId());
        console.log("lending.balance:%s,tokenBAmount:%s,mirrorBalance:%s", lb, tokenBAmount, mirrorBalance);
    }

    function testLendingAPR() public {
        uint256 apr = lendingPoolManager.getLendingAPR(nativeKey.toId(), nativeKey.currency1, 0);
        assertEq(apr, 0);
        uint256 payValue = 0.01 ether;
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: address(this),
            deadline: block.timestamp + 1000
        });
        marginPositionManager.margin{value: payValue}(params);
        skip(3600 * 10);
        uint256 borrowRate = marginFees.getBorrowRate(address(pairPoolManager), nativeKey.toId(), false);
        apr = lendingPoolManager.getLendingAPR(nativeKey.toId(), nativeKey.currency1, 0);
        PoolStatus memory status = pairPoolManager.getStatus(nativeKey.toId());
        assertGt(borrowRate, apr);
        assertEq(
            borrowRate * status.totalMirrorReserve1() / (status.totalMirrorReserve1() + status.totalRealReserve1()), apr
        );
    }

    function testWithdrawInterests() public {
        PoolStatus memory status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
        address user = vm.addr(1);
        uint256 depositAmount = 0.1 ether;
        (bool success,) = user.call{value: 1 ether}("");
        require(success, "TRANSFER_FAILED");
        console.log("balance:%s", user.balance);
        Currency eth = CurrencyLibrary.ADDRESS_ZERO;
        PoolId nativeId = nativeKey.toId();
        uint256 id = eth.toTokenId(nativeId);
        vm.startPrank(user);
        uint256 lb = lendingPoolManager.balanceOf(user, id);
        assertLt(lb, 1000);
        lendingPoolManager.deposit{value: depositAmount}(user, nativeId, eth, depositAmount);
        uint256 ethAmount = manager.balanceOf(address(lendingPoolManager), eth.toId());
        lb = lendingPoolManager.balanceOf(user, id);
        console.log("lending.balance:%s,ethAmount:%s", lb, ethAmount);
        vm.stopPrank();
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.001 ether;
        address user0 = address(this);
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: true,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user0,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        skip(3600);
        marginPositionManager.close(positionId, 1000000, 0, block.timestamp + 1000);
        vm.startPrank(user);
        lb = lendingPoolManager.balanceOf(user, id);
        assertGt(lb, depositAmount);
        console.log("withdraw:%d", lb);
        lendingPoolManager.withdraw(user, nativeId, eth, lb);
        status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
        vm.stopPrank();
    }

    function testWithdrawInterest100() public {
        for (uint256 i = 0; i < 100; i++) {
            testWithdrawInterests();
        }
        uint256 balance0 = manager.balanceOf(address(lendingPoolManager), nativeKey.currency0.toId());
        uint256 balance1 = manager.balanceOf(address(lendingPoolManager), nativeKey.currency1.toId());
        console.log(balance0, balance1);
    }

    function testBorrowLevelOne() public {
        PoolId poolId = nativeKey.toId();
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        printPoolStatus(status);
        uint256 liquidity = marginLiquidity.getPoolLiquidity(poolId, address(this), LiquidityLevel.BOTH_MARGIN);
        assertGt(liquidity, 0);
        RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
            poolId: poolId,
            level: LiquidityLevel.BOTH_MARGIN,
            liquidity: liquidity,
            deadline: type(uint256).max
        });
        vm.roll(100);
        skip(3600 * 2);
        pairPoolManager.removeLiquidity(removeParams);
        status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
        uint256 amount0 = 0.1 ether;
        uint256 amount1 = 1 ether;
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: poolId,
            amount0: amount0,
            amount1: amount1,
            to: address(this),
            level: LiquidityLevel.NO_MARGIN,
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: amount0}(params);
        status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
        address user = vm.addr(1);
        uint256 payValue = 0.1 ether;
        (bool success,) = user.call{value: amount0}("");
        assertTrue(success);
        vm.startPrank(user);
        MarginParams memory borrowParams = MarginParams({
            poolId: poolId,
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
        vm.expectRevert(bytes("MIRROR_TOO_MUCH"));
        marginPositionManager.margin{value: payValue}(borrowParams);
    }

    function testBorrowLevelOneAndLending() public {
        uint256 liquidity;
        PoolId poolId = nativeKey.toId();
        {
            liquidity = marginLiquidity.getPoolLiquidity(poolId, address(this), LiquidityLevel.BOTH_MARGIN);
            assertGt(liquidity, 0);
            RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
                poolId: poolId,
                level: LiquidityLevel.BOTH_MARGIN,
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
                level: LiquidityLevel.NO_MARGIN,
                deadline: type(uint256).max
            });
            pairPoolManager.addLiquidity{value: amount0}(params);
            params = AddLiquidityParams({
                poolId: poolId,
                amount0: amount0,
                amount1: amount1,
                to: address(this),
                level: LiquidityLevel.BOTH_MARGIN,
                deadline: type(uint256).max
            });
            pairPoolManager.addLiquidity{value: amount0}(params);
            PoolStatus memory status = pairPoolManager.getStatus(nativeKey.toId());
            printPoolStatus(status);
            liquidity = marginLiquidity.getPoolLiquidity(poolId, address(this), LiquidityLevel.BOTH_MARGIN);
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
            uint256 nowLiquidity = marginLiquidity.getPoolLiquidity(poolId, address(this), LiquidityLevel.BOTH_MARGIN);
            assertEq(nowLiquidity, liquidity);
            console.log("before margin:nowLiquidity, liquidity", nowLiquidity, liquidity);
        }
        vm.startPrank(user);
        MarginParams memory borrowParams = MarginParams({
            poolId: poolId,
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
        (uint256 positionId, uint256 borrowAmount) = marginPositionManager.margin{value: payValue}(borrowParams);
        uint256 afterBalance = tokenB.balanceOf(user);
        assertEq(positionId, 1);
        assertEq(borrowAmount, afterBalance);
        skip(1000);

        {
            payValue = borrowAmount / 10;
            borrowParams = MarginParams({
                poolId: poolId,
                marginForOne: true,
                leverage: 0,
                marginAmount: payValue,
                borrowAmount: 0,
                borrowMaxAmount: 0,
                recipient: user,
                deadline: block.timestamp + 1000
            });
            beforeBalance = tokenB.balanceOf(user);
            assertEq(beforeBalance, borrowAmount);
            tokenB.approve(address(pairPoolManager), payValue);
            (positionId, borrowAmount) = marginPositionManager.margin(borrowParams);
            afterBalance = tokenB.balanceOf(user);
            console.log("borrowAmount:%s", borrowAmount);
            assertEq(afterBalance, beforeBalance - payValue);
        }
        {
            uint256 nowLiquidity = marginLiquidity.getPoolLiquidity(poolId, address(this), LiquidityLevel.BOTH_MARGIN);
            assertGt(nowLiquidity, liquidity);
            console.log("after margin:nowLiquidity%s, liquidity%s", nowLiquidity, liquidity);
        }
        vm.stopPrank();
        {
            PoolStatus memory status = pairPoolManager.getStatus(nativeKey.toId());
            printPoolStatus(status);
        }
    }

    function testBalanceMirror() public {
        testBorrowLevelOneAndLending();
        PoolId poolId = nativeKey.toId();
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        tokenB.approve(address(lendingPoolManager), 0.001 ether);
        lendingPoolManager.balanceMirror(poolId, nativeKey.currency1, 0.001 ether);
        status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
    }

    function testBurnOneBorrow() public {
        testBorrowLevelOneAndLending();
        PoolId poolId = nativeKey.toId();
        uint256[4] memory beforeLiquidities = marginLiquidity.getPoolLiquidities(poolId, address(this));
        uint256 positionId = 1;
        (bool liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
        uint256 amountIn = 0.1 ether;
        uint256 swapIndex = 0;
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log(
            "position.marginAmount:%s,position.marginTotal:%s,position.borrowAmount:%s",
            position.marginAmount,
            position.marginTotal,
            position.borrowAmount
        );
        while (!liquidated) {
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
        assertGt(beforeLendingAmount1, afterLendingAmount1);
        position = marginPositionManager.getPosition(positionId);
        assertEq(position.borrowAmount, 0);
        uint256[4] memory afterLiquidities = marginLiquidity.getPoolLiquidities(poolId, address(this));
        assertEq(afterLiquidities[0], beforeLiquidities[0]);
        assertEq(afterLiquidities[1], beforeLiquidities[1]);
        assertEq(afterLiquidities[2], beforeLiquidities[2]);
        assertLt(afterLiquidities[3], beforeLiquidities[3]);
    }

    function testEarnedBurnOneBorrow() public {
        testBorrowLevelOneAndLending();
        PoolId poolId = nativeKey.toId();
        uint256[4] memory beforeLiquidities = marginLiquidity.getPoolLiquidities(poolId, address(this));
        uint256 positionId = 1;
        (bool liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionId);
        uint256 amountIn = 0.001 ether;
        uint256 swapIndex = 0;
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log(
            "position.marginAmount:%s,position.marginTotal:%s,position.borrowAmount:%s",
            position.marginAmount,
            position.marginTotal,
            position.borrowAmount
        );
        while (!liquidated) {
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
        assertLt(beforeLendingAmount1, afterLendingAmount1);
        position = marginPositionManager.getPosition(positionId);
        assertEq(position.borrowAmount, 0);
        uint256[4] memory afterLiquidities = marginLiquidity.getPoolLiquidities(poolId, address(this));
        assertEq(afterLiquidities[0], beforeLiquidities[0]);
        assertEq(afterLiquidities[1], beforeLiquidities[1]);
        assertEq(afterLiquidities[2], beforeLiquidities[2]);
        assertGt(afterLiquidities[3], beforeLiquidities[3]);
    }

    function testBurnTwoBorrow() public {
        testBorrowLevelOneAndLending();
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

    function testEarnedBurnTwoBorrow() public {
        testBorrowLevelOneAndLending();
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
            PoolStatus memory status = pairPoolManager.getStatus(nativeKey.toId());
            printPoolStatus(status);
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
        assertLt(beforeLendingAmount1, afterLendingAmount1);
        position = marginPositionManager.getPosition(positionId);
        assertEq(position.borrowAmount, 0);
        uint256[4] memory afterLiquidities = marginLiquidity.getPoolLiquidities(poolId, address(this));
        assertEq(afterLiquidities[0], beforeLiquidities[0]);
        assertEq(afterLiquidities[1], beforeLiquidities[1]);
        assertEq(afterLiquidities[2], beforeLiquidities[2]);
        assertGt(afterLiquidities[3], beforeLiquidities[3]);
    }

    function testModifyBorrow() public {
        testBorrowLevelOneAndLending();
        uint256 positionId = 1;
        uint256 maxAmount = marginChecker.getMaxDecrease(address(marginPositionManager), positionId);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        assertEq(position.marginTotal, 0);
        console.log("maxAmount:%s", maxAmount);
    }

    function testOnlyBorrow() public {
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.001 ether;
        address user0 = address(this);
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user0,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        skip(3600 * 10);
        borrowAmount = marginPositionManager.getPosition(positionId).borrowAmount;
        console.log("borrowAmount:%s", borrowAmount);
    }
}
