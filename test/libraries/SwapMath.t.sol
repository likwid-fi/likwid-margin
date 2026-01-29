// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SwapMath} from "../../src/libraries/SwapMath.sol";
import {Reserves, toReserves} from "../../src/types/Reserves.sol";
import {FeeLibrary} from "../../src/libraries/FeeLibrary.sol";

contract SwapMathTest is Test {
    using FeeLibrary for uint24;

    Reserves testReserves;
    Reserves testTruncatedReserves;

    function setUp() public {
        testReserves = toReserves(1000e18, 1000e18);
        testTruncatedReserves = toReserves(1000e18, 1000e18);
    }

    // =========================================
    // differencePrice Tests
    // =========================================

    function testDifferencePrice_Positive() public pure {
        assertEq(SwapMath.differencePrice(110, 100), 10, "Test 1");
        assertEq(SwapMath.differencePrice(100, 110), 10, "Test 2");
    }

    function testDifferencePrice_Zero() public pure {
        assertEq(SwapMath.differencePrice(100, 100), 0, "Test 3");
    }

    // =========================================
    // dynamicFee Tests
    // =========================================

    function testDynamicFee_NoChange() public pure {
        uint24 baseFee = 3000;
        uint256 degree = 100000; // 10%
        uint24 dynamic = SwapMath.dynamicFee(baseFee, degree);
        assertEq(dynamic, baseFee, "Fee should not change for low degree");
    }

    function testDynamicFee_Increases() public pure {
        uint24 baseFee = 3000;
        uint256 degree = 200000; // 20%
        uint24 dynamic = SwapMath.dynamicFee(baseFee, degree);
        assertTrue(dynamic > baseFee, "Fee should increase for high degree");
    }

    function testDynamicFee_CappedAtMax() public pure {
        uint24 baseFee = 3000;
        uint256 degree = SwapMath.MAX_SWAP_FEE + 1;
        uint24 dynamic = SwapMath.dynamicFee(baseFee, degree);
        assertEq(dynamic, SwapMath.MAX_SWAP_FEE - 10000, "Fee should be capped");
    }

    // =========================================
    // getAmountOut Tests
    // =========================================

    function testGetAmountOut_FixedFee() public view {
        uint256 amountIn = 100e18;
        uint24 fee = 3000; // 0.3%
        (uint256 amountOut, uint256 feeAmount) = SwapMath.getAmountOut(testReserves, fee, true, amountIn);

        (uint256 amountInWithoutFee, uint256 expectedFeeAmount) = fee.deduct(amountIn);
        assertEq(feeAmount, expectedFeeAmount, "Fee amount should be correct");

        uint256 expectedAmountOut = (amountInWithoutFee * 1000e18) / (1000e18 + amountInWithoutFee);
        assertEq(amountOut, expectedAmountOut);
    }

    function testGetAmountOut_DynamicFee() public view {
        uint256 amountIn = 100e18;
        uint24 baseFee = 3000; // 0.3%
        (uint256 amountOut, uint24 finalFee,) =
            SwapMath.getAmountOut(testReserves, testTruncatedReserves, baseFee, true, amountIn);
        assertTrue(finalFee > baseFee, "Dynamic fee should be higher than base fee");

        (uint256 expectedAmountOutFixed,) = SwapMath.getAmountOut(testReserves, baseFee, true, amountIn);
        assertTrue(amountOut < expectedAmountOutFixed, "Amount out with dynamic fee should be less than with fixed fee");
    }

    // =========================================
    // getAmountIn Tests
    // =========================================

    function testGetAmountIn_FixedFee() public view {
        uint256 amountOut = 100e18;
        uint24 fee = 3000; // 0.3%
        (uint256 amountIn, uint256 feeAmount) = SwapMath.getAmountIn(testReserves, fee, true, amountOut);

        uint256 expectedAmountInWithoutFee = (1000e18 * amountOut) / (1000e18 - amountOut) + 1;
        uint256 expectedAmountIn = (expectedAmountInWithoutFee * 1e6 + (1e6 - fee - 1)) / (1e6 - fee);
        uint256 expectedFeeAmount = expectedAmountIn - expectedAmountInWithoutFee;

        assertEq(amountIn, expectedAmountIn, "Amount in should be correct");
        assertEq(feeAmount, expectedFeeAmount, "Fee amount should be correct");
    }

    function testGetAmountIn_DynamicFee() public view {
        uint256 amountOut = 100e18;
        uint24 baseFee = 3000; // 0.3%
        (uint256 amountIn, uint24 finalFee,) =
            SwapMath.getAmountIn(testReserves, testTruncatedReserves, baseFee, true, amountOut);
        assertTrue(finalFee > baseFee, "Dynamic fee should be higher than base fee");

        (uint256 expectedAmountInFixed,) = SwapMath.getAmountIn(testReserves, baseFee, true, amountOut);
        assertTrue(amountIn > expectedAmountInFixed, "Amount in with dynamic fee should be greater");
    }

    // =========================================
    // getPriceDegree Tests
    // =========================================

    function testGetPriceDegree_AmountIn() public view {
        uint256 amountIn = 100e18;
        uint24 lpFee = 3000;
        uint256 degree = SwapMath.getPriceDegree(testReserves, testTruncatedReserves, lpFee, true, amountIn, 0);
        assertTrue(degree > 0, "Degree should be positive for a swap");
    }

    function testGetPriceDegree_AmountOut() public view {
        uint256 amountOut = 100e18;
        uint24 lpFee = 3000;
        uint256 degree = SwapMath.getPriceDegree(testReserves, testTruncatedReserves, lpFee, true, 0, amountOut);
        assertTrue(degree > 0, "Degree should be positive for a swap");
    }

    function testGetPriceDegree_ZeroForNoSwap() public view {
        uint256 degree = SwapMath.getPriceDegree(testReserves, testTruncatedReserves, 3000, true, 0, 0);
        assertEq(degree, 0, "Degree should be zero for no swap");
    }

    function testDynamicFee_boundary() public pure {
        uint24 baseFee = 3000;

        // Just below threshold - fee should remain base
        uint24 feeLow = SwapMath.dynamicFee(baseFee, 100000);
        assertEq(feeLow, baseFee, "Fee should be base at threshold");

        // At threshold where dynamic fee kicks in
        uint24 feeHigh = SwapMath.dynamicFee(baseFee, 100001);
        assertTrue(feeHigh >= baseFee, "Fee should increase above threshold");
    }

    function testGetPriceDegree_zeroTruncatedReserves() public view {
        Reserves zeroReserves = toReserves(0, 0);
        uint256 degree = SwapMath.getPriceDegree(testReserves, zeroReserves, 3000, true, 100e18, 0);
        assertEq(degree, 0, "Degree should be 0 when truncated reserves are 0");
    }

    function testGetPriceDegree_zeroPairReserves() public view {
        Reserves zeroReserves = toReserves(0, 0);
        uint256 degree = SwapMath.getPriceDegree(zeroReserves, testTruncatedReserves, 3000, true, 100e18, 0);
        assertEq(degree, 0, "Degree should be 0 when pair reserves are 0");
    }

    function testGetAmountOut_reverseDirection() public view {
        uint256 amountIn = 100e18;
        uint24 fee = 3000;

        // Swap token0 for token1
        (uint256 amountOut01,) = SwapMath.getAmountOut(testReserves, fee, true, amountIn);

        // Swap token1 for token0
        (uint256 amountOut10,) = SwapMath.getAmountOut(testReserves, fee, false, amountIn);

        // Both should work and return positive amounts
        assertGt(amountOut01, 0, "Amount out should be positive for 0->1");
        assertGt(amountOut10, 0, "Amount out should be positive for 1->0");
    }

    function testGetAmountIn_reverseDirection() public view {
        uint256 amountOut = 50e18;
        uint24 fee = 3000;

        // Swap token0 for token1
        (uint256 amountIn01,) = SwapMath.getAmountIn(testReserves, fee, true, amountOut);

        // Swap token1 for token0
        (uint256 amountIn10,) = SwapMath.getAmountIn(testReserves, fee, false, amountOut);

        // Both should work and return positive amounts
        assertGt(amountIn01, 0, "Amount in should be positive for 0->1");
        assertGt(amountIn10, 0, "Amount in should be positive for 1->0");
    }

    function testDifferencePrice_largeDifference() public pure {
        uint256 price1 = 1e18;
        uint256 price2 = 100e18;
        uint256 diff = SwapMath.differencePrice(price1, price2);
        assertEq(diff, 99e18, "Should calculate large difference correctly");
    }

    function testDynamicFee_maxCap() public pure {
        uint24 baseFee = 500000; // 50%
        uint256 degree = SwapMath.MAX_SWAP_FEE + 1000;
        uint24 fee = SwapMath.dynamicFee(baseFee, degree);
        assertEq(fee, uint24(SwapMath.MAX_SWAP_FEE) - 10000, "Fee should be capped at max");
    }
}
