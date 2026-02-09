// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {InterestMath} from "../../src/libraries/InterestMath.sol";
import {MarginState, MarginStateLibrary} from "../../src/types/MarginState.sol";
import {Reserves, toReserves} from "../../src/types/Reserves.sol";

contract InterestMathTest is Test {
    using MarginStateLibrary for MarginState;

    MarginState internal marginState;

    function setUp() public {
        marginState = marginState.setRateBase(20000).setUseMiddleLevel(700000).setUseHighLevel(900000).setMLow(500)
            .setMMiddle(5000).setMHigh(50000);
    }

    function test_getBorrowRateByReserves() public view {
        uint256 borrowReserve = 1000e18;
        uint256 mirrorReserve = 100e18;
        uint256 rate = InterestMath.getBorrowRateByReserves(marginState, 0, borrowReserve, mirrorReserve);
        console.log("rate", rate);
        assertTrue(rate > marginState.rateBase());
    }

    function test_getBorrowRateCumulativeLast() public view {
        uint256 timeElapsed = 3600;
        uint256 rate0CumulativeBefore = 1e18;
        uint256 rate1CumulativeBefore = 1e18;
        Reserves realReserves = toReserves(uint128(1000e18), uint128(1000e18));
        Reserves mirrorReserve = toReserves(uint128(100e18), uint128(200e18));

        (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast) = InterestMath.getBorrowRateCumulativeLast(
            timeElapsed, 0, rate0CumulativeBefore, rate1CumulativeBefore, marginState, realReserves, mirrorReserve
        );

        assertTrue(rate0CumulativeLast > rate0CumulativeBefore);
        assertTrue(rate1CumulativeLast > rate1CumulativeBefore);
    }

    function test_updateInterestForOne() public pure {
        InterestMath.InterestUpdateParams memory params = InterestMath.InterestUpdateParams({
            mirrorReserve: 100e18,
            borrowCumulativeLast: 1.1e18,
            borrowCumulativeBefore: 1e18,
            interestReserve: 0,
            pairReserve: 500e18,
            lendReserve: 500e18,
            protocolInterestReserve: 0,
            depositCumulativeLast: 1e18,
            protocolFee: 0
        });

        InterestMath.InterestUpdateResult memory result = InterestMath.updateInterestForOne(params);

        assertTrue(result.changed);
        assertTrue(result.newMirrorReserve > params.mirrorReserve);
        assertTrue(result.newPairReserve > params.pairReserve);
        assertTrue(result.newLendReserve > params.lendReserve);
        assertTrue(result.newDepositCumulativeLast > params.depositCumulativeLast);
        assertEq(result.newInterestReserve, 0);
    }

    function test_getBorrowRateByReserves_zeroMirrorReserve() public view {
        uint256 borrowReserve = 1000e18;
        uint256 mirrorReserve = 0;
        uint256 rate = InterestMath.getBorrowRateByReserves(marginState, 0, borrowReserve, mirrorReserve);
        assertEq(rate, marginState.rateBase(), "Rate should equal rateBase when mirrorReserve is 0");
    }

    function test_getBorrowRateByReserves_highUtilization() public view {
        uint256 borrowReserve = 100e18;
        uint256 mirrorReserve = 90e18;
        uint256 rate = InterestMath.getBorrowRateByReserves(marginState, 0, borrowReserve, mirrorReserve);
        assertTrue(rate > marginState.rateBase(), "Rate should increase with high utilization");
        uint256 useLevel = (mirrorReserve * 1e6) / borrowReserve;
        if (useLevel >= marginState.useHighLevel()) {
            assertTrue(
                rate > marginState.rateBase() + (useLevel - marginState.useHighLevel()) * marginState.mHigh() / 100
            );
        }
    }

    function test_getBorrowRateCumulativeLast_zeroTimeElapsed() public view {
        uint256 timeElapsed = 0;
        uint256 rate0CumulativeBefore = 1e18;
        uint256 rate1CumulativeBefore = 1e18;
        Reserves realReserves = toReserves(uint128(1000e18), uint128(1000e18));
        Reserves mirrorReserve = toReserves(uint128(100e18), uint128(200e18));

        (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast) = InterestMath.getBorrowRateCumulativeLast(
            timeElapsed, 0, rate0CumulativeBefore, rate1CumulativeBefore, marginState, realReserves, mirrorReserve
        );

        assertEq(rate0CumulativeLast, rate0CumulativeBefore, "Rate should not change when timeElapsed is 0");
        assertEq(rate1CumulativeLast, rate1CumulativeBefore, "Rate should not change when timeElapsed is 0");
    }

    function test_updateInterestForOne_noChange() public pure {
        InterestMath.InterestUpdateParams memory params = InterestMath.InterestUpdateParams({
            mirrorReserve: 100e18,
            borrowCumulativeLast: 1e18,
            borrowCumulativeBefore: 1e18,
            interestReserve: 0,
            pairReserve: 500e18,
            lendReserve: 500e18,
            protocolInterestReserve: 0,
            depositCumulativeLast: 1e18,
            protocolFee: 0
        });

        InterestMath.InterestUpdateResult memory result = InterestMath.updateInterestForOne(params);

        assertFalse(result.changed, "Should not change when borrowCumulative is same");
        assertEq(result.newMirrorReserve, params.mirrorReserve);
        assertEq(result.newPairReserve, params.pairReserve);
        assertEq(result.newLendReserve, params.lendReserve);
    }

    function test_updateInterestForOne_withProtocolFee() public pure {
        InterestMath.InterestUpdateParams memory params = InterestMath.InterestUpdateParams({
            mirrorReserve: 100e18,
            borrowCumulativeLast: 1.1e18,
            borrowCumulativeBefore: 1e18,
            interestReserve: 0,
            pairReserve: 500e18,
            lendReserve: 500e18,
            protocolInterestReserve: 0,
            depositCumulativeLast: 1e18,
            protocolFee: 0x640000
        });

        InterestMath.InterestUpdateResult memory result = InterestMath.updateInterestForOne(params);

        assertTrue(result.changed);
        assertTrue(result.protocolInterest > 0, "Protocol interest should be collected");
    }

    function test_getBorrowRateByReserves_lowUtilization() public view {
        uint256 borrowReserve = 1000e18;
        uint256 mirrorReserve = 100e18;
        uint256 rate = InterestMath.getBorrowRateByReserves(marginState, 0, borrowReserve, mirrorReserve);
        uint256 useLevel = (mirrorReserve * 1e6) / borrowReserve;
        assertTrue(useLevel < marginState.useMiddleLevel(), "Should be low utilization");
        uint256 expectedRate = marginState.rateBase() + (useLevel * marginState.mLow() / 100);
        assertEq(rate, expectedRate, "Rate should follow low utilization formula");
    }

    function test_getBorrowRateCumulativeLast_largeTimeElapsed() public view {
        uint256 timeElapsed = 365 days;
        uint256 rate0CumulativeBefore = 1e18;
        uint256 rate1CumulativeBefore = 1e18;
        Reserves realReserves = toReserves(uint128(1000e18), uint128(1000e18));
        Reserves mirrorReserve = toReserves(uint128(100e18), uint128(200e18));

        (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast) = InterestMath.getBorrowRateCumulativeLast(
            timeElapsed, 0, rate0CumulativeBefore, rate1CumulativeBefore, marginState, realReserves, mirrorReserve
        );

        assertTrue(rate0CumulativeLast > rate0CumulativeBefore, "Rate should increase over time");
        assertTrue(rate1CumulativeLast > rate1CumulativeBefore, "Rate should increase over time");
    }

    function test_getBorrowRateByReserves_withLowRate() public view {
        uint256 borrowReserve = 1000e18;
        uint256 mirrorReserve = 100e18;
        // minRate component = 25 -> 25 * 10**4 = 250000. rateRange = 25 << 8 = 0x1900
        uint16 rateRange = 0x1900;
        uint256 minRate = 25 * 10 ** 4;
        uint256 rate = InterestMath.getBorrowRateByReserves(marginState, rateRange, borrowReserve, mirrorReserve);
        uint256 useLevel = (mirrorReserve * 1e6) / borrowReserve;
        uint256 expectedRate = minRate + (useLevel * marginState.mLow() / 100);
        assertEq(rate, expectedRate, "Rate should start from minRate");
        assertTrue(rate > marginState.rateBase(), "Rate should be higher than base rate");
        rate = InterestMath.getBorrowRateByReserves(marginState, 0, borrowReserve, mirrorReserve);
        expectedRate = marginState.rateBase() + (useLevel * marginState.mLow() / 100);
        assertEq(rate, expectedRate, "Rate should start from base rate when no rateRange is provided");
    }

    function test_getBorrowRateByReserves_withHighRate() public view {
        uint256 borrowReserve = 100e18;
        uint256 mirrorReserve = 95e18; // high utilization
        // maxRate component = 30 -> 30 * 10**4 = 300000. rateRange = 30 = 0x001e
        uint16 rateRange = 0x001e;
        uint256 maxRate = 30 * 10 ** 4;
        uint256 rate = InterestMath.getBorrowRateByReserves(marginState, rateRange, borrowReserve, mirrorReserve);
        assertEq(rate, maxRate, "Rate should be capped at maxRate");
    }

    function test_getBorrowRateByReserves_withLowAndHighRate() public view {
        uint256 borrowReserve = 100e18;
        uint256 mirrorReserve = 95e18; // high utilization
        // minRate = 25, maxRate = 30. rateRange = (25 << 8) | 30 = 0x191e
        uint16 rateRange = 0x191e;
        uint256 maxRate = 30 * 10 ** 4;
        uint256 rate = InterestMath.getBorrowRateByReserves(marginState, rateRange, borrowReserve, mirrorReserve);
        assertEq(rate, maxRate, "Rate should be capped at maxRate when starting from minRate");
        rate = InterestMath.getBorrowRateByReserves(marginState, 0, borrowReserve, mirrorReserve);
        assertGt(rate, maxRate, "Rate should be higher than maxRate when no rateRange is provided");
    }
}
