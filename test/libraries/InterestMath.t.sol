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
        uint256 rate = InterestMath.getBorrowRateByReserves(marginState, borrowReserve, mirrorReserve);
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
            timeElapsed, rate0CumulativeBefore, rate1CumulativeBefore, marginState, realReserves, mirrorReserve
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
        uint256 rate = InterestMath.getBorrowRateByReserves(marginState, borrowReserve, mirrorReserve);
        assertEq(rate, marginState.rateBase(), "Rate should equal rateBase when mirrorReserve is 0");
    }

    function test_getBorrowRateByReserves_highUtilization() public view {
        uint256 borrowReserve = 100e18;
        uint256 mirrorReserve = 90e18;
        uint256 rate = InterestMath.getBorrowRateByReserves(marginState, borrowReserve, mirrorReserve);
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
            timeElapsed, rate0CumulativeBefore, rate1CumulativeBefore, marginState, realReserves, mirrorReserve
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
        uint256 rate = InterestMath.getBorrowRateByReserves(marginState, borrowReserve, mirrorReserve);
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
            timeElapsed, rate0CumulativeBefore, rate1CumulativeBefore, marginState, realReserves, mirrorReserve
        );

        assertTrue(rate0CumulativeLast > rate0CumulativeBefore, "Rate should increase over time");
        assertTrue(rate1CumulativeLast > rate1CumulativeBefore, "Rate should increase over time");
    }

    /// Regression for the on-chain deposit cumulative anomaly (HONEY pool: deposit1Cum = 54.8x).
    /// With the lend side rounding up, a lendReserve of 1 wei of rounding dust received at least 1 wei
    /// on every interest update, multiplying the deposit cumulative by (lend + 1) / lend each time:
    /// 54 updates took it from 1x to 55x. The lend side now rounds down, so dust earns nothing.
    function test_dustLendReserve_doesNotInflateDepositCumulative() public pure {
        uint256 Q96 = 2 ** 96;
        uint256 pairReserve = 224_000_000e18;
        uint256 lendReserve = 1; // 1 wei of dust
        uint256 mirrorReserve = 1_000_000e18;
        uint256 depositCumulative = Q96;
        uint256 borrowCumulative = Q96;
        uint256 interestReserve;
        uint256 pairBefore = pairReserve;
        uint256 mirrorBefore = mirrorReserve;

        for (uint256 i = 0; i < 54; i++) {
            uint256 borrowBefore = borrowCumulative;
            borrowCumulative = borrowCumulative * 1_000_001 / 1_000_000;
            InterestMath.InterestUpdateResult memory r = InterestMath.updateInterestForOne(
                InterestMath.InterestUpdateParams({
                    mirrorReserve: mirrorReserve,
                    borrowCumulativeLast: borrowCumulative,
                    borrowCumulativeBefore: borrowBefore,
                    interestReserve: interestReserve,
                    pairReserve: pairReserve,
                    lendReserve: lendReserve,
                    protocolInterestReserve: 0,
                    depositCumulativeLast: depositCumulative,
                    protocolFee: 0
                })
            );
            mirrorReserve = r.newMirrorReserve;
            pairReserve = r.newPairReserve;
            lendReserve = r.newLendReserve;
            depositCumulative = r.newDepositCumulativeLast;
            interestReserve = r.newInterestReserve;
        }

        assertEq(lendReserve, 1, "dust must not grow");
        assertEq(depositCumulative, Q96, "deposit cumulative must not move");
        assertGt(mirrorReserve, mirrorBefore, "interest did accrue");
        assertEq(pairReserve - pairBefore, mirrorReserve - mirrorBefore, "all of it went to the pair");
    }

    /// A real lend reserve still earns its pro-rata share (rounded down) and nothing is lost.
    function test_lendReserve_earnsProRataRoundedDown() public pure {
        uint256 Q96 = 2 ** 96;
        InterestMath.InterestUpdateResult memory r = InterestMath.updateInterestForOne(
            InterestMath.InterestUpdateParams({
                mirrorReserve: 1_000e18,
                borrowCumulativeLast: Q96 * 101 / 100,
                borrowCumulativeBefore: Q96,
                interestReserve: 0,
                pairReserve: 3_000e18,
                lendReserve: 1_000e18,
                protocolInterestReserve: 0,
                depositCumulativeLast: Q96,
                protocolFee: 0
            })
        );
        uint256 gross = r.newMirrorReserve - 1_000e18;
        uint256 lendInterest = r.newLendReserve - 1_000e18;
        assertEq(lendInterest + r.pairInterest, gross, "interest conserved");
        assertEq(lendInterest, gross / 4, "lend earns 1000 / (3000 + 1000), rounded down");
        assertEq(r.newDepositCumulativeLast, Q96 * (1_000e18 + lendInterest) / 1_000e18);
    }
}
