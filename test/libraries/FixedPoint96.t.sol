// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FixedPoint96} from "../../src/libraries/FixedPoint96.sol";

contract FixedPoint96Test is Test {
    function testResolution() public pure {
        assertEq(FixedPoint96.RESOLUTION, 96, "Resolution should be 96 bits");
    }

    function testQ96() public pure {
        uint256 expectedQ96 = 0x1000000000000000000000000;
        assertEq(FixedPoint96.Q96, expectedQ96, "Q96 should be 2^96");
    }

    function testQ96Value() public pure {
        // Verify Q96 is exactly 2^96
        uint256 expected = 2 ** 96;
        assertEq(FixedPoint96.Q96, expected, "Q96 should equal 2^96");
    }

    function testQ96InDecimal() public pure {
        // Q96 represents 1.0 in fixed point format
        // This means 2^96 = 1.0
        assertEq(FixedPoint96.Q96, 79228162514264337593543950336, "Q96 should have correct decimal value");
    }

    function testResolutionConsistency() public pure {
        // Q96 should be 2^RESOLUTION
        uint256 expected = 2 ** FixedPoint96.RESOLUTION;
        assertEq(FixedPoint96.Q96, expected, "Q96 should equal 2^RESOLUTION");
    }

    function testFixedPointScaling() public pure {
        // Test basic scaling operations
        uint256 value = 100;
        uint256 scaled = value * FixedPoint96.Q96;

        assertEq(scaled, value * (2 ** 96), "Scaling should work correctly");
    }

    function testFixedPointDivision() public pure {
        // Test basic division operations
        uint256 scaledValue = 100 * FixedPoint96.Q96;
        uint256 unscaled = scaledValue / FixedPoint96.Q96;

        assertEq(unscaled, 100, "Unscaling should work correctly");
    }

    function testQ96Precision() public pure {
        // Q96 provides 96 bits of precision after the decimal point
        // This means the smallest representable value is 1/Q96
        uint256 smallestValue = 1;
        uint256 fixedPoint = smallestValue * FixedPoint96.Q96;

        assertEq(fixedPoint, FixedPoint96.Q96, "Smallest value should be 1/Q96");
    }

    function testLargeNumberHandling() public pure {
        // Test with larger numbers
        uint256 largeNumber = 1e18; // 1 ether
        uint256 fixedPoint = largeNumber * FixedPoint96.Q96;

        assertEq(fixedPoint, largeNumber * (2 ** 96), "Large number scaling should work");
    }

    function testMaxSafeInteger() public pure {
        // Test the maximum safe integer that can be represented
        // In Q96 format, we need to be careful about overflow
        uint256 maxSafe = type(uint256).max / FixedPoint96.Q96;
        uint256 result = maxSafe * FixedPoint96.Q96;

        assertEq(result / FixedPoint96.Q96, maxSafe, "Max safe integer should work");
    }

    function testQ96AsOne() public pure {
        // In fixed point arithmetic, Q96 represents 1.0
        // So Q96 / Q96 should equal 1
        uint256 one = FixedPoint96.Q96 / FixedPoint96.Q96;
        assertEq(one, 1, "Q96/Q96 should equal 1");
    }

    function testHalfQ96() public pure {
        // Half of Q96 should represent 0.5
        uint256 half = FixedPoint96.Q96 / 2;
        assertEq(half, 2 ** 95, "Half Q96 should be 2^95");
    }

    function testQuarterQ96() public pure {
        // Quarter of Q96 should represent 0.25
        uint256 quarter = FixedPoint96.Q96 / 4;
        assertEq(quarter, 2 ** 94, "Quarter Q96 should be 2^94");
    }

    function testQ96BitSize() public pure {
        // Q96 should fit in 256 bits
        assertLe(FixedPoint96.Q96, type(uint256).max, "Q96 should fit in uint256");

        // Q96 is 2^96, which is less than uint128.max (2^128 - 1)
        // But it should be greater than uint96.max
        assertLt(FixedPoint96.Q96, type(uint128).max, "Q96 should be less than uint128 max");
        assertGt(FixedPoint96.Q96, type(uint96).max, "Q96 should be greater than uint96 max");
    }

    function testQ96InBinary() public pure {
        // Q96 in binary should be 1 followed by 96 zeros
        uint256 q96Binary = 1 << 96;
        assertEq(FixedPoint96.Q96, q96Binary, "Q96 should be 1 << 96");
    }
}
