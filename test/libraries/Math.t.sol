// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "../../src/libraries/Math.sol";

contract MathTest is Test {
    function testTernaryTrue() public pure {
        uint256 result = Math.ternary(true, 100, 50);
        assertEq(result, 100, "Ternary should return first value when true");
    }

    function testTernaryFalse() public pure {
        uint256 result = Math.ternary(false, 100, 50);
        assertEq(result, 50, "Ternary should return second value when false");
    }

    function testMax() public pure {
        assertEq(Math.max(100, 50), 100, "Max should return larger value");
        assertEq(Math.max(50, 100), 100, "Max should return larger value regardless of order");
        assertEq(Math.max(100, 100), 100, "Max should return same value when equal");
    }

    function testMin() public pure {
        assertEq(Math.min(100, 50), 50, "Min should return smaller value");
        assertEq(Math.min(50, 100), 50, "Min should return smaller value regardless of order");
        assertEq(Math.min(100, 100), 100, "Min should return same value when equal");
    }

    function testAverage() public pure {
        assertEq(Math.average(100, 200), 150, "Average of 100 and 200 should be 150");
        assertEq(Math.average(0, 100), 50, "Average of 0 and 100 should be 50");
        assertEq(Math.average(100, 100), 100, "Average of same values should be that value");
    }

    function testMulDiv() public pure {
        // Test basic multiplication and division
        uint256 result = Math.mulDiv(100, 200, 100);
        assertEq(result, 200, "100 * 200 / 100 should be 200");

        // Test with larger numbers
        result = Math.mulDiv(1e18, 2e18, 1e18);
        assertEq(result, 2e18, "1e18 * 2e18 / 1e18 should be 2e18");
    }

    function testMulDivRoundingUp() public pure {
        // Test exact division (no rounding needed)
        uint256 result = Math.mulDivRoundingUp(100, 200, 100);
        assertEq(result, 200, "100 * 200 / 100 should be 200");

        // Test division with remainder (should round up)
        result = Math.mulDivRoundingUp(100, 1, 3);
        assertEq(result, 34, "100 * 1 / 3 should round up to 34");

        // Test exact division (no rounding needed)
        result = Math.mulDivRoundingUp(99, 1, 3);
        assertEq(result, 33, "99 * 1 / 3 should be exactly 33");
    }

    function testSqrt() public pure {
        // Test perfect squares
        assertEq(Math.sqrt(0), 0, "sqrt(0) should be 0");
        assertEq(Math.sqrt(1), 1, "sqrt(1) should be 1");
        assertEq(Math.sqrt(4), 2, "sqrt(4) should be 2");
        assertEq(Math.sqrt(9), 3, "sqrt(9) should be 3");
        assertEq(Math.sqrt(16), 4, "sqrt(16) should be 4");
        assertEq(Math.sqrt(100), 10, "sqrt(100) should be 10");
        assertEq(Math.sqrt(10000), 100, "sqrt(10000) should be 100");
    }

    function testSqrtLargeNumbers() public pure {
        // Test large perfect squares
        assertEq(Math.sqrt(1e18), 1e9, "sqrt(1e18) should be 1e9");
        assertEq(Math.sqrt(4e18), 2e9, "sqrt(4e18) should be 2e9");

        // Test non-perfect squares (should round down)
        uint256 result = Math.sqrt(10);
        assertEq(result, 3, "sqrt(10) should be 3 (rounded down)");

        result = Math.sqrt(15);
        assertEq(result, 3, "sqrt(15) should be 3 (rounded down)");
    }

    function testCeilDiv() public pure {
        // Test exact division
        assertEq(Math.ceilDiv(100, 10), 10, "ceil(100/10) should be 10");

        // Test division with remainder
        assertEq(Math.ceilDiv(100, 3), 34, "ceil(100/3) should be 34");
        assertEq(Math.ceilDiv(100, 30), 4, "ceil(100/30) should be 4");

        // Test with zero numerator
        assertEq(Math.ceilDiv(0, 10), 0, "ceil(0/10) should be 0");
    }

    function testCeilDivRevertOnZero() public view {
        try this.callCeilDiv(100, 0) {
            assertTrue(false, "Should have reverted");
        } catch {
            // Expected
        }
    }

    function callCeilDiv(uint256 a, uint256 b) external pure returns (uint256) {
        return Math.ceilDiv(a, b);
    }

    function testMulDivEdgeCases() public pure {
        // Test with zero
        assertEq(Math.mulDiv(0, 100, 100), 0, "0 * 100 / 100 should be 0");
        assertEq(Math.mulDiv(100, 0, 100), 0, "100 * 0 / 100 should be 0");

        // Test with 1
        assertEq(Math.mulDiv(100, 1, 1), 100, "100 * 1 / 1 should be 100");
    }

    function testMulDivLargeNumbers() public pure {
        // Test with large numbers that don't overflow
        uint256 a = type(uint128).max;
        uint256 b = type(uint128).max;
        uint256 denominator = type(uint128).max;

        uint256 result = Math.mulDiv(a, b, denominator);
        assertEq(result, type(uint128).max, "Large number mulDiv should work");
    }

    function testSqrtMaxUint256() public pure {
        // Test with maximum uint256
        uint256 result = Math.sqrt(type(uint256).max);
        // sqrt(2^256 - 1) ≈ 2^128 - 1
        assertGt(result, 0, "sqrt(max) should be positive");
        assertLe(result * result, type(uint256).max, "result^2 should not overflow");
    }

    function testTernaryWithMaxValues() public pure {
        uint256 max = type(uint256).max;
        uint256 min = 0;

        assertEq(Math.ternary(true, max, min), max, "Ternary should handle max value");
        assertEq(Math.ternary(false, max, min), min, "Ternary should handle min value");
    }

    function testAverageWithMaxValues() public pure {
        uint256 a = type(uint256).max;
        uint256 b = type(uint256).max;

        uint256 result = Math.average(a, b);
        assertEq(result, type(uint256).max, "Average of two max values should be max");
    }

    function testAverageOverflowProtection() public pure {
        // This would overflow with (a + b) / 2 but not with our implementation
        uint256 a = type(uint256).max;
        uint256 b = type(uint256).max;

        uint256 result = Math.average(a, b);
        assertEq(result, type(uint256).max, "Average should handle overflow case");
    }

    function testMulDivRoundingUpEdgeCases() public pure {
        // When result is exact, no rounding needed
        assertEq(Math.mulDivRoundingUp(6, 4, 3), 8, "6 * 4 / 3 = 8 exactly");

        // When there's remainder, round up
        assertEq(Math.mulDivRoundingUp(7, 4, 3), 10, "7 * 4 / 3 = 9.33..., rounds up to 10");

        // Edge case: rounding up causes overflow check
        uint256 max = type(uint256).max;
        uint256 result = Math.mulDivRoundingUp(max, 1, max);
        assertEq(result, 1, "max * 1 / max should be 1");
    }

    function testSqrtBoundaryValues() public pure {
        // Test boundary values
        assertEq(Math.sqrt(0), 0, "sqrt(0) = 0");
        assertEq(Math.sqrt(1), 1, "sqrt(1) = 1");
        assertEq(Math.sqrt(2), 1, "sqrt(2) = 1 (rounded down)");
        assertEq(Math.sqrt(3), 1, "sqrt(3) = 1 (rounded down)");
        assertEq(Math.sqrt(4), 2, "sqrt(4) = 2");
    }

    function testMaxMinConsistency() public pure {
        uint256 a = 100;
        uint256 b = 200;

        assertEq(Math.max(a, b) + Math.min(a, b), a + b, "max + min should equal sum");
        assertTrue(Math.max(a, b) >= Math.min(a, b), "max should be >= min");
    }
}
