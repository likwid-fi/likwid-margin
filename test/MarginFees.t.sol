// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {MarginFees} from "../src/MarginFees.sol";
import {PairPoolManager} from "../src/PairPoolManager.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {PoolStatus} from "../src/types/PoolStatus.sol";
import {RateStatus} from "../src/types/RateStatus.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
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

contract MarginFeesTest is DeployHelper {
    using CurrencyPoolLibrary for *;

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
        assertEq(rate, uint256(rateBase));
        mirrorReserve = 0.4 ether;
        rate = marginFees.getBorrowRateByReserves(realReserve, mirrorReserve);
        assertEq(rate, rateBase + useMiddleLevel * mLow);
        realReserve = 0;
        rate = marginFees.getBorrowRateByReserves(realReserve, mirrorReserve);
        assertEq(
            rate,
            rateBase + uint256(useMiddleLevel) * mLow + uint256(useHighLevel - useMiddleLevel) * mMiddle
                + (ONE_MILLION - useHighLevel) * mHigh
        );
        uint256 test = UINT256_MAX;
        uint24 test24 = uint24(test);
        assertEq(test24, type(uint24).max);
    }

    function testDynamicFee() public {
        address user = address(this);
        PoolId poolId = nativeKey.toId();
        uint256 keyId = CurrencyLibrary.ADDRESS_ZERO.toTokenId(poolId);
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        uint24 _beforeFee = marginFees.dynamicFee(address(pairPoolManager), status);
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
        status = pairPoolManager.getStatus(poolId);
        uint24 _afterFee = marginFees.dynamicFee(address(pairPoolManager), status);
        assertEq(_afterFee, 20 * status.key.fee);
        vm.warp(10);
        _afterFee = marginFees.dynamicFee(address(pairPoolManager), status);
        assertLe(_afterFee, 20 * status.key.fee);
        console.log("_afterFee:", _afterFee);
        vm.warp(130);
        _afterFee = marginFees.dynamicFee(address(pairPoolManager), status);
        assertEq(_afterFee, status.key.fee);
    }
}
