// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {PairPoolManager} from "../src/PairPoolManager.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginLiquidity, ERC6909Liquidity} from "../src/MarginLiquidity.sol";
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
import {EIP20NonStandardThrowHarness} from "./mocks/EIP20NonStandardThrowHarness.sol";

import {DeployHelper} from "./utils/DeployHelper.sol";

contract NativeKeyPoolManagerTest is DeployHelper {
    using CurrencyPoolLibrary for Currency;
    using PoolStatusLibrary for *;
    using LiquidityLevel for uint8;

    function setUp() public {
        deployHookAndRouter();
        initNativeKey();
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
        skip(3600 * 10);
        borrowAmount = marginPositionManager.getPosition(positionId).borrowAmount;
        console.log("borrowAmount:%s", borrowAmount);
        marginPositionManager.close(positionId, PerLibrary.ONE_MILLION, 0, block.timestamp + 1001);
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
            deadline: block.timestamp + 1000
        });
        marginPositionManager.margin{value: payValue}(params);
        skip(3600 * 10);
        uint256 borrowRate = marginFees.getBorrowRate(address(pairPoolManager), nativeKey.toId(), false);
        apr = lendingPoolManager.getLendingAPR(nativeKey.toId(), nativeKey.currency1, 0);
        PoolStatus memory status = pairPoolManager.getStatus(nativeKey.toId());
        assertGt(borrowRate, apr, "borrowRate>apr");
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
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: true,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        skip(3600);
        marginPositionManager.close(positionId, 1000000, 0, block.timestamp + 1001);
        vm.startPrank(user);
        lb = lendingPoolManager.balanceOf(user, id);
        assertGt(lb, depositAmount, "lb>depositAmount");
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
        {
            PoolStatus memory status = pairPoolManager.getStatus(nativeKey.toId());
            uint256 balance0 = manager.balanceOf(address(lendingPoolManager), nativeKey.currency0.toId());
            uint256 balance1 = manager.balanceOf(address(lendingPoolManager), nativeKey.currency1.toId());
            assertEq(balance0, status.lendingRealReserve0, "balance0==lendingRealReserve0");
            assertEq(balance1, status.lendingRealReserve1, "balance1==lendingRealReserve1");
        }
    }

    function testBorrowLevelOne() public {
        PoolId poolId = nativeKey.toId();
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        printPoolStatus(status);
        uint256 liquidity = marginLiquidity.getPoolLiquidity(poolId, address(this), LiquidityLevel.BORROW_BOTH);
        assertGt(liquidity, 0);
        RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
            poolId: poolId,
            level: LiquidityLevel.BORROW_BOTH,
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
            level: LiquidityLevel.RETAIN_BOTH,
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
            deadline: block.timestamp + 1000
        });
        uint256 beforeBalance = tokenB.balanceOf(user);
        assertEq(beforeBalance, 0);
        vm.expectRevert(bytes("MIRROR_TOO_MUCH"));
        marginPositionManager.margin{value: payValue}(borrowParams);
        vm.stopPrank();
    }

    function testNativeLiquidity() public {
        nativeKeyBalance("before testNativeLiquidity");
        uint256 liquidity;
        PoolId poolId = nativeKey.toId();
        {
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
            assertGt(liquidity, 0);
            RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
                poolId: poolId,
                level: LiquidityLevel.BORROW_BOTH,
                liquidity: liquidity,
                deadline: type(uint256).max
            });
            vm.expectRevert(ERC6909Liquidity.NotAllowed.selector);
            pairPoolManager.removeLiquidity(removeParams);
            skip(20);
            vm.expectRevert(ERC6909Liquidity.NotAllowed.selector);
            pairPoolManager.removeLiquidity(removeParams);
            skip(60);
            pairPoolManager.removeLiquidity(removeParams);
            liquidity = marginLiquidity.getPoolLiquidity(poolId, address(this), LiquidityLevel.BORROW_BOTH);
            assertEq(liquidity, 0);
            params = AddLiquidityParams({
                poolId: poolId,
                amount0: amount0,
                amount1: amount1,
                to: address(this),
                level: LiquidityLevel.BORROW_BOTH,
                deadline: type(uint256).max
            });
            pairPoolManager.addLiquidity{value: amount0}(params);
        }
        nativeKeyBalance("after testNativeLiquidity");
    }

    function testBorrowAndLending() public returns (uint256 positionId1, uint256 positionId2) {
        PoolId poolId = nativeKey.toId();
        uint256 liquidity = marginLiquidity.getPoolLiquidity(poolId, address(this), LiquidityLevel.BORROW_BOTH);
        uint256 nowLiquidity = marginLiquidity.getPoolLiquidity(poolId, address(this), LiquidityLevel.BORROW_BOTH);
        assertEq(nowLiquidity, liquidity, "nowLiquidity==liquidity");
        console.log("before margin:nowLiquidity, liquidity", nowLiquidity, liquidity);
        address user = vm.addr(1);
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        printPoolStatus(status);
        while (status.realReserve0 > status.realReserve1) {
            uint256 amountIn = status.realReserve1;
            tokenB.approve(address(swapRouter), amountIn);
            MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
                poolId: poolId,
                zeroForOne: false,
                to: address(this),
                amountIn: amountIn,
                amountOut: 0,
                amountOutMin: 0,
                deadline: type(uint256).max
            });
            swapRouter.exactInput(swapParams);
            // console.log("swapIndex:%s", swapIndex);
            nativeKeyBalance("after swap");
            status = pairPoolManager.getStatus(poolId);
        }
        printPoolStatus(status);
        uint256 payValue = status.realReserve0 / 1000;
        (bool success,) = user.call{value: payValue}("");
        assertTrue(success);
        tokenB.approve(address(lendingPoolManager), 1000000 ether);
        lendingPoolManager.deposit{value: 10000 ether}(address(this), poolId, nativeKey.currency0, 10000 ether);
        lendingPoolManager.deposit(address(this), poolId, nativeKey.currency1, 1000000 ether);
        skip(1000);
        uint256 borrowAmount;
        vm.startPrank(user);
        MarginParams memory borrowParams = MarginParams({
            poolId: poolId,
            marginForOne: false,
            leverage: 0,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            deadline: block.timestamp + 1000
        });
        uint256 beforeBalance = tokenB.balanceOf(user);
        (positionId1, borrowAmount) = marginPositionManager.margin{value: payValue}(borrowParams);
        console.log("positionId1:%s,borrowAmount:%s", positionId1, borrowAmount);
        nativeKeyBalance("after margin 01");
        uint256 afterBalance = tokenB.balanceOf(user);
        assertGt(positionId1, 0);
        assertEq(borrowAmount + beforeBalance, afterBalance);
        skip(1000);

        payValue = Math.min(0.01 ether, borrowAmount / 10);
        borrowParams = MarginParams({
            poolId: poolId,
            marginForOne: true,
            leverage: 0,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            deadline: block.timestamp + 1000
        });
        beforeBalance = tokenB.balanceOf(user);
        assertEq(beforeBalance, afterBalance);
        tokenB.approve(address(pairPoolManager), payValue);
        (positionId2, borrowAmount) = marginPositionManager.margin(borrowParams);
        console.log("positionId2:%s,borrowAmount:%s", positionId2, borrowAmount);
        assertGt(positionId2, 0);
        nativeKeyBalance("after margin 02");
        afterBalance = tokenB.balanceOf(user);
        console.log("borrowAmount:%s", borrowAmount);
        assertEq(afterBalance, beforeBalance - payValue, "afterBalance=beforeBalance - payValue");
        nowLiquidity = marginLiquidity.getPoolLiquidity(poolId, address(this), LiquidityLevel.BORROW_BOTH);
        assertGe(nowLiquidity, liquidity, "nowLiquidity>liquidity");
        console.log("after margin:nowLiquidity%s, liquidity%s", nowLiquidity, liquidity);
        vm.stopPrank();
        status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
    }

    function testBalanceMirror() public {
        testBorrowAndLending();
        PoolId poolId = nativeKey.toId();
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        tokenB.approve(address(lendingPoolManager), 0.001 ether);
        lendingPoolManager.balanceMirror(poolId, nativeKey.currency1, 0.001 ether);
        status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
    }

    function testBurnOneBorrow() public {
        (uint256 positionId1,) = testBorrowAndLending();
        PoolId poolId = nativeKey.toId();
        uint256[4] memory beforeLiquidities = marginLiquidity.getPoolLiquidities(poolId, address(this));
        uint256 positionId = positionId1;
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
        (uint256 positionId1,) = testBorrowAndLending();
        PoolId poolId = nativeKey.toId();
        uint256[4] memory beforeLiquidities = marginLiquidity.getPoolLiquidities(poolId, address(this));
        uint256 positionId = positionId1;
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

    function _nativeBurnBorrow(uint256 positionIdRepay, uint256 positionIdBurn) internal {
        console.log("positionIdRepay:%s,positionIdBurn:%s", positionIdRepay, positionIdBurn);
        PoolId poolId = nativeKey.toId();

        MarginPosition memory position = marginPositionManager.getPosition(positionIdRepay);
        console.log(
            "positionIdRepay.position.marginAmount:%s,position.marginTotal:%s,position.borrowAmount:%s",
            position.marginAmount,
            position.marginTotal,
            position.borrowAmount
        );
        position = marginPositionManager.getPosition(positionIdBurn);
        console.log(
            "positionIdBurn.position.marginAmount:%s,position.marginTotal:%s,position.borrowAmount:%s",
            position.marginAmount,
            position.marginTotal,
            position.borrowAmount
        );
        bool zeroForOne = positionIdBurn < positionIdRepay;
        (bool liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionIdBurn);
        uint256 swapIndex = 0;
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        console.log("before swap");
        printPoolStatus(status);
        while (!liquidated) {
            uint256 amountIn = status.realReserve1;
            uint256 sendValue;
            if (zeroForOne) {
                amountIn = status.realReserve0;
                sendValue = amountIn;
            } else {
                tokenB.approve(address(swapRouter), amountIn);
            }
            MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
                poolId: poolId,
                zeroForOne: zeroForOne,
                to: address(this),
                amountIn: amountIn,
                amountOut: 0,
                amountOutMin: 0,
                deadline: type(uint256).max
            });
            swapRouter.exactInput{value: sendValue}(swapParams);
            swapIndex++;
            // console.log("swapIndex:%s", swapIndex);
            nativeKeyBalance("after swap");
            status = pairPoolManager.getStatus(poolId);
            skip(100);
            (liquidated,) = marginChecker.checkLiquidate(address(marginPositionManager), positionIdBurn);
        }
        console.log("swapIndex:%s", swapIndex);
        status = pairPoolManager.getStatus(poolId);
        console.log("before liquidateBurn");
        printPoolStatus(status);
        uint256 beforeLendingAmount0 =
            lendingPoolManager.balanceOf(address(this), nativeKey.currency0.toTokenId(poolId));
        uint256 beforeLendingAmount1 =
            lendingPoolManager.balanceOf(address(this), nativeKey.currency1.toTokenId(poolId));

        uint256 positionLendingAmount1 =
            lendingPoolManager.balanceOf(address(marginPositionManager), nativeKey.currency1.toTokenId(poolId));
        console.log("beforeLendingAmount1:%s,positionLendingAmount1:%s", beforeLendingAmount1, positionLendingAmount1);
        position = marginPositionManager.getPosition(positionIdBurn);
        console.log(
            "after swap positionIdBurn.position.marginAmount:%s,position.marginTotal:%s,position.borrowAmount:%s",
            position.marginAmount,
            position.marginTotal,
            position.borrowAmount
        );
        nativeKeyBalance("before testNativeBurnTwoBorrow liquidateBurn");
        uint256[4] memory beforeLiquidities = marginLiquidity.getPoolLiquidities(poolId, address(this));
        (, uint256 repayAmount) = marginPositionManager.liquidateBurn(positionIdBurn);
        uint256 afterLendingAmount0 = lendingPoolManager.balanceOf(address(this), nativeKey.currency0.toTokenId(poolId));
        uint256 afterLendingAmount1 = lendingPoolManager.balanceOf(address(this), nativeKey.currency1.toTokenId(poolId));
        if (!zeroForOne) {
            if (repayAmount < position.borrowAmount) {
                assertLt(afterLendingAmount0, beforeLendingAmount0, "afterLendingAmount0<beforeLendingAmount0");
                assertLt(beforeLendingAmount1, afterLendingAmount1, "beforeLendingAmount1<afterLendingAmount1");
            } else {
                assertLe(beforeLendingAmount0, afterLendingAmount0, "beforeLendingAmount0<=afterLendingAmount0");
                assertLe(beforeLendingAmount1, afterLendingAmount1, "beforeLendingAmount1<=afterLendingAmount1");
            }

            uint256[4] memory afterLiquidities = marginLiquidity.getPoolLiquidities(poolId, address(this));
            assertEq(afterLiquidities[0], beforeLiquidities[0]);
            assertEq(afterLiquidities[1], beforeLiquidities[1]);
            assertEq(afterLiquidities[2], beforeLiquidities[2]);
            if (repayAmount < position.borrowAmount) {
                assertLt(afterLiquidities[3], beforeLiquidities[3]);
            } else {
                assertGe(afterLiquidities[3], beforeLiquidities[3]);
            }
        }
        position = marginPositionManager.getPosition(positionIdBurn);
        assertEq(position.borrowAmount, 0);
        console.log("after liquidateBurn,before withdraw");
        status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
        afterLendingAmount1 = lendingPoolManager.balanceOf(address(this), nativeKey.currency1.toTokenId(poolId));
        positionLendingAmount1 =
            lendingPoolManager.balanceOf(address(marginPositionManager), nativeKey.currency1.toTokenId(poolId));
        console.log("afterLendingAmount1:%s,positionLendingAmount1:%s", afterLendingAmount1, positionLendingAmount1);
        for (uint256 i = 0; i < 10; i++) {
            lendingPoolManager.withdraw(address(this), poolId, nativeKey.currency0, afterLendingAmount0 / 10);
            lendingPoolManager.withdraw(address(this), poolId, nativeKey.currency1, afterLendingAmount1 / 10);
        }
        console.log("after withdraw");
        status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
        {
            uint256 balanceAfter0 = manager.balanceOf(address(lendingPoolManager), nativeKey.currency0.toId());
            uint256 balanceAfter1 = manager.balanceOf(address(lendingPoolManager), nativeKey.currency1.toId());
            console.log("balanceAfter0:%s,balanceAfter1:%s", balanceAfter0, balanceAfter1);
            address user1 = vm.addr(1);
            if (zeroForOne) {
                (bool success,) = user1.call{value: 1 ether}("");
                require(success, "TRANSFER_FAILED");
            } else {
                tokenB.transfer(user1, 1 ether);
            }
            skip(100);
            console.log("before repay");
            status = pairPoolManager.getStatus(nativeKey.toId());
            printPoolStatus(status);
            vm.startPrank(user1);
            position = marginPositionManager.getPosition(positionIdRepay);
            uint256 sendValue;
            if (zeroForOne) {
                sendValue = position.borrowAmount;
            } else {
                tokenB.approve(address(pairPoolManager), position.borrowAmount);
            }
            console.log(
                "before repay position.marginAmount:%s,position.borrowAmount:%s",
                position.marginAmount,
                position.borrowAmount
            );
            afterLendingAmount0 =
                lendingPoolManager.balanceOf(address(marginPositionManager), nativeKey.currency0.toTokenId(poolId));
            afterLendingAmount1 =
                lendingPoolManager.balanceOf(address(marginPositionManager), nativeKey.currency1.toTokenId(poolId));
            console.log(
                "marginPositionManager.afterLendingAmount0:%s,afterLendingAmount1:%s",
                afterLendingAmount0,
                afterLendingAmount1
            );
            marginPositionManager.repay{value: sendValue}(
                positionIdRepay, position.borrowAmount, block.timestamp + 1000
            );
            vm.stopPrank();
            console.log("after repay");
            status = pairPoolManager.getStatus(nativeKey.toId());
            printPoolStatus(status);
            balanceAfter0 = manager.balanceOf(address(lendingPoolManager), nativeKey.currency0.toId());
            balanceAfter1 = manager.balanceOf(address(lendingPoolManager), nativeKey.currency1.toId());
            console.log("balanceAfter0:%s,balanceAfter1:%s", balanceAfter0, balanceAfter1);
        }
        {
            int256 deviationAmount0 = lendingPoolManager.deviationOf(nativeKey.currency0.toTokenId(poolId));
            int256 deviationAmount1 = lendingPoolManager.deviationOf(nativeKey.currency1.toTokenId(poolId));
            console.log("deviationAmount0:%s", deviationAmount0);
            console.log("deviationAmount1:%s", deviationAmount1);
            afterLendingAmount0 = lendingPoolManager.balanceOf(address(this), nativeKey.currency0.toTokenId(poolId));
            afterLendingAmount1 = lendingPoolManager.balanceOf(address(this), nativeKey.currency1.toTokenId(poolId));
            console.log("user0.afterLendingAmount0:%s,afterLendingAmount1:%s", afterLendingAmount0, afterLendingAmount1);
            afterLendingAmount0 =
                lendingPoolManager.balanceOf(address(marginPositionManager), nativeKey.currency0.toTokenId(poolId));
            afterLendingAmount1 =
                lendingPoolManager.balanceOf(address(marginPositionManager), nativeKey.currency1.toTokenId(poolId));
            console.log(
                "marginPositionManager.afterLendingAmount0:%s,afterLendingAmount1:%s",
                afterLendingAmount0,
                afterLendingAmount1
            );
            address user = vm.addr(1);
            afterLendingAmount0 = lendingPoolManager.balanceOf(user, nativeKey.currency0.toTokenId(poolId));
            afterLendingAmount1 = lendingPoolManager.balanceOf(user, nativeKey.currency1.toTokenId(poolId));
            console.log("user1.afterLendingAmount0:%s,afterLendingAmount1:%s", afterLendingAmount0, afterLendingAmount1);
            afterLendingAmount0 =
                lendingPoolManager.balanceOf(address(lendingPoolManager), nativeKey.currency0.toTokenId(poolId));
            afterLendingAmount1 =
                lendingPoolManager.balanceOf(address(lendingPoolManager), nativeKey.currency1.toTokenId(poolId));
            console.log(
                "lendingPoolManager.afterLendingAmount0:%s,afterLendingAmount1:%s",
                afterLendingAmount0,
                afterLendingAmount1
            );
        }
        nativeKeyBalance("after _nativeBurnBorrow");
    }

    function testNativeBurnTwoBorrow() public {
        (uint256 positionIdRepay, uint256 positionIdBurn) = testBorrowAndLending();
        _nativeBurnBorrow(positionIdRepay, positionIdBurn);
    }

    function testNativeBurnOneBorrow() public {
        (uint256 positionIdBurn, uint256 positionIdRepay) = testBorrowAndLending();
        _nativeBurnBorrow(positionIdRepay, positionIdBurn);
    }

    function testBatchNativeBurnBorrow() public {
        // Avoid excessive cycles, since compounding interest will have a greater adverse effect on LPs
        // than liquidations in the long run.
        for (uint256 i = 0; i < 20; i++) {
            console.log("start test:%s", i);
            testNativeBurnOneBorrow();
            skip(1000);
            testNativeBurnTwoBorrow();
            console.log("end test:%s", i);
        }
    }

    function testNativeProtocolInterests() public {
        address owner = vm.addr(8);
        PoolId poolId = nativeKey.toId();
        lendingPoolManager.transferOwnership(owner);
        for (uint256 i = 0; i < 5; i++) {
            testNativeBurnTwoBorrow();
        }
        PoolStatus memory status = pairPoolManager.getStatus(nativeKey.toId());
        printPoolStatus(status);
        uint256 protocolInterests0 = lendingPoolManager.balanceOf(owner, nativeKey.currency0.toTokenId(poolId));
        uint256 protocolInterests1 = lendingPoolManager.balanceOf(owner, nativeKey.currency1.toTokenId(poolId));
        assertGt(protocolInterests0, 0);
        assertGt(protocolInterests1, 0);
        console.log("protocolInterests0:%s,protocolInterests1:%s", protocolInterests0, protocolInterests1);
    }

    function testEarnedBurnTwoBorrow() public {
        nativeKeyBalance("before testEarnedBurnTwoBorrow");
        testBorrowAndLending();
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
        nativeKeyBalance("after testEarnedBurnTwoBorrow");
    }

    function testModifyBorrow() public {
        testBorrowAndLending();
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
        skip(3600 * 10);
        borrowAmount = marginPositionManager.getPosition(positionId).borrowAmount;
        console.log("borrowAmount:%s", borrowAmount);
    }

    function testGetMaxDecreaseByDiffLeverage() public {
        // Without considering the price curve: When marginLevel ≤ marginAmount/(marginAmount*(leverage+1)),
        // a minimum marginLevel of 117% implies a maximum leverage value of 5.
        // For equal marginAmount, higher leverage results in a smaller getMaxDecrease.
        uint256 payValue = 0.000001 ether;
        for (uint8 i = 1; i <= 5; i++) {
            MarginParams memory params = MarginParams({
                poolId: nativeKey.toId(),
                marginForOne: true,
                leverage: i,
                marginAmount: payValue,
                borrowAmount: 0,
                borrowMaxAmount: 0,
                deadline: block.timestamp + 1000
            });
            (uint256 positionId,) = marginPositionManager.margin{value: payValue}(params);
            uint256 maxAmount = marginChecker.getMaxDecrease(address(marginPositionManager), positionId);
            console.log("leverage:%s,maxAmount:%s", i, maxAmount);
            marginPositionManager.close(positionId, 1000000, 0, UINT256_MAX);
        }
        MarginParams memory outParams = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: true,
            leverage: 6,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            deadline: block.timestamp + 1000
        });
        vm.expectPartialRevert(MarginPositionManager.InsufficientAmount.selector);
        marginPositionManager.margin{value: payValue}(outParams);
    }
}
