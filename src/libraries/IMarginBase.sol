// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Reserves, toReserves} from "../types/Reserves.sol";
import {MarginState} from "../types/MarginState.sol";
import {Math} from "./Math.sol";
import {FeeLibrary} from "./FeeLibrary.sol";
import {PerLibrary} from "./PerLibrary.sol";
import {CustomRevert} from "./CustomRevert.sol";

library IMarginBase {
    using CustomRevert for bytes4;
    using FeeLibrary for uint24;
    using PerLibrary for uint256;

    function getBorrowRateByReserves(MarginState rateState, uint256 borrowReserve, uint256 mirrorReserve)
        internal
        pure
        returns (uint256 rate)
    {
        rate = rateState.rateBase();
        if (mirrorReserve == 0) {
            return rate;
        }
        uint256 useLevel = Math.mulDiv(mirrorReserve, PerLibrary.ONE_MILLION, borrowReserve);
        if (useLevel >= rateState.useHighLevel()) {
            rate += uint256(useLevel - rateState.useHighLevel()) * rateState.mHigh() / 100;
            useLevel = rateState.useHighLevel();
        }
        if (useLevel >= rateState.useMiddleLevel()) {
            rate += uint256(useLevel - rateState.useMiddleLevel()) * rateState.mMiddle() / 100;
            useLevel = rateState.useMiddleLevel();
        }
        return rate + useLevel * rateState.mLow() / 100;
    }

    function getBorrowRateCumulativeLast(
        uint256 timeElapsed,
        uint256 rate0CumulativeBefore,
        uint256 rate1CumulativeBefore,
        MarginState rateState,
        Reserves realReserves,
        Reserves mirrorReserve
    ) internal pure returns (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast) {
        if (timeElapsed == 0) {
            return (rate0CumulativeBefore, rate1CumulativeBefore);
        }
        (uint256 realReserve0, uint256 realReserve1) = realReserves.reserves();
        (uint256 mirrorReserve0, uint256 mirrorReserve1) = mirrorReserve.reserves();
        uint256 rate0 = getBorrowRateByReserves(rateState, realReserve0 + mirrorReserve0, mirrorReserve0);
        uint256 rate0LastYear = PerLibrary.TRILLION_YEAR_SECONDS + rate0 * timeElapsed;
        rate0CumulativeLast = Math.mulDiv(rate0CumulativeBefore, rate0LastYear, PerLibrary.TRILLION_YEAR_SECONDS);
        uint256 rate1 = getBorrowRateByReserves(rateState, realReserve1 + mirrorReserve1, mirrorReserve1);
        uint256 rate1LastYear = PerLibrary.TRILLION_YEAR_SECONDS + rate1 * timeElapsed;
        rate1CumulativeLast = Math.mulDiv(rate1CumulativeBefore, rate1LastYear, PerLibrary.TRILLION_YEAR_SECONDS);
    }
}
