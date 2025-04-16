// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {MarginFees} from "../src/MarginFees.sol";
import {PairPoolManager} from "../src/PairPoolManager.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {PoolStatus} from "../src/types/PoolStatus.sol";
import {PoolStatusLibrary} from "../src/types/PoolStatusLibrary.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition} from "../src/types/MarginPosition.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "../src/types/LiquidityParams.sol";
import {CurrencyPoolLibrary} from "../src/libraries/CurrencyPoolLibrary.sol";
import {UQ112x112} from "../src/libraries/UQ112x112.sol";
import {PerLibrary} from "../src/libraries/PerLibrary.sol";
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

contract MarginFeesTest is DeployHelper {
    using UQ112x112 for *;
    using CurrencyPoolLibrary for *;
    using PoolStatusLibrary for PoolStatus;
    using PerLibrary for uint256;

    function setUp() public {
        deployHookAndRouter();
        initPoolLiquidity();
    }

    function test_get_borrow_rate() public view {
        uint256 realReserve = 0.6 ether;
        uint256 mirrorReserve = 0;
        uint256 rate = marginFees.getBorrowRateByReserves(realReserve, mirrorReserve);
        (uint24 rateBase, uint24 useMiddleLevel, uint24 useHighLevel, uint24 mLow, uint24 mMiddle, uint24 mHigh) =
            marginFees.rateStatus();
        console.log("rate:%s", rate);
        assertEq(rate, uint256(rateBase));
        mirrorReserve = 0.4 ether;
        rate = marginFees.getBorrowRateByReserves(realReserve + mirrorReserve, mirrorReserve);
        console.log("rate:%s", rate);
        assertEq(rate, rateBase + useMiddleLevel * mLow / 100);
        realReserve = 0;
        rate = marginFees.getBorrowRateByReserves(realReserve + mirrorReserve, mirrorReserve);
        assertEq(
            rate,
            rateBase + uint256(useMiddleLevel) * mLow / 100 + uint256(useHighLevel - useMiddleLevel) * mMiddle / 100
                + (ONE_MILLION - useHighLevel) * mHigh / 100
        );
        console.log("rate:%s", rate);
        uint256 test = UINT256_MAX;
        uint24 test24 = uint24(test);
        assertEq(test24, type(uint24).max);
    }

    function testMarginDynamicFee() public {
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        uint256 keyId = CurrencyLibrary.ADDRESS_ZERO.toTokenId(poolId);
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        uint24 _beforeFee = marginFees.dynamicFee(status, true, 0, 0);
        assertEq(_beforeFee, status.key.fee);
        uint256 rate = marginFees.getBorrowRate(address(pairPoolManager), poolId, false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.1 ether;
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
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        assertEq(
            lendingPoolManager.balanceOf(address(marginPositionManager), keyId),
            position.marginAmount + position.marginTotal
        );
        uint256 _positionId = marginPositionManager.getPositionId(poolId, false, user, true);
        assertEq(positionId, _positionId);
        status = pairPoolManager.getStatus(poolId);
        printPoolStatus(status);
        (uint24 _afterFee,) = marginFees.getPoolFees(address(pairPoolManager), poolId, true, 0, 0);
        assertEq(_afterFee, 41076);
        skip(10);
        (_afterFee,) = marginFees.getPoolFees(address(pairPoolManager), poolId, true, 0, 0);
        assertLe(_afterFee, 41076);
        status = pairPoolManager.getStatus(poolId);
        printPoolStatus(status);
        console.log("_afterFee:", _afterFee);
        skip(130);
        status = pairPoolManager.getStatus(poolId);
        printPoolStatus(status);
        (_afterFee,) = marginFees.getPoolFees(address(pairPoolManager), poolId, true, 0, 0);
        assertEq(_afterFee, status.key.fee);
    }

    function differencePrice(uint256 price, uint256 lastPrice) internal pure returns (uint256 priceDiff) {
        priceDiff = price > lastPrice ? price - lastPrice : lastPrice - price;
    }

    function testDynamicFee() public view {
        PoolId poolId = nativeKey.toId();
        bool zeroForOne = true;
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        uint24 _beforeFee = marginFees.dynamicFee(status, zeroForOne, 0, 0);
        assertEq(_beforeFee, status.key.fee);
        uint256 amountIn = 0.1 ether;
        uint24 _afterFee1 = marginFees.dynamicFee(status, zeroForOne, amountIn, 0);
        assertGt(_afterFee1, status.key.fee);
        uint256 amountOut = status.getAmountOut(zeroForOne, amountIn);
        uint24 _afterFee2 = marginFees.dynamicFee(status, zeroForOne, 0, amountOut);
        assertEq(_afterFee1, _afterFee2);

        (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
        if (amountIn > 0) {
            amountOut = status.getAmountOut(zeroForOne, amountIn);
        } else if (amountOut > 0) {
            amountIn = status.getAmountIn(zeroForOne, amountOut);
        }
        if (zeroForOne) {
            _reserve1 -= amountOut;
            _reserve0 += amountIn;
        } else {
            _reserve0 -= amountOut;
            _reserve1 += amountIn;
        }
        uint256 lastPrice0X112 = status.getPrice0X112();
        uint256 lastPrice1X112 = status.getPrice1X112();
        uint224 price0X112 = UQ112x112.encode(_reserve1.toUint112()).div(_reserve0.toUint112());
        uint224 price1X112 = UQ112x112.encode(_reserve0.toUint112()).div(_reserve1.toUint112());
        uint256 degree0 = differencePrice(price0X112, lastPrice0X112).mulMillionDiv(lastPrice0X112);
        uint256 degree1 = differencePrice(price1X112, lastPrice1X112).mulMillionDiv(lastPrice1X112);
        uint256 degree = Math.max(degree0, degree1);
        console.log("degree:%s", degree);
        uint256 dFee = Math.mulDiv((degree * 10) ** 3, status.key.fee, PerLibrary.ONE_MILLION ** 3);
        assertEq(dFee, _afterFee2);
    }

    function testUtilizationReserves() public {
        PoolId poolId = nativeKey.toId();
        (uint256 suppliedReserve0, uint256 suppliedReserve1, uint256 borrowedReserve0, uint256 borrowedReserve1) =
            marginFees.getUtilizationReserves(address(pairPoolManager), poolId);
        console.log("suppliedReserve0:%s,suppliedReserve1:%s", suppliedReserve0, suppliedReserve1);
        console.log("borrowedReserve0:%s,borrowedReserve1:%s", borrowedReserve0, borrowedReserve1);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.1 ether;
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
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        assertGt(position.borrowAmount, 0);
        (suppliedReserve0, suppliedReserve1, borrowedReserve0, borrowedReserve1) =
            marginFees.getUtilizationReserves(address(pairPoolManager), poolId);
        console.log("suppliedReserve0:%s,suppliedReserve1:%s", suppliedReserve0, suppliedReserve1);
        console.log("borrowedReserve0:%s,borrowedReserve1:%s", borrowedReserve0, borrowedReserve1);
    }
}
