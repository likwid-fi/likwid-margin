// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PerLibrary} from "../../src/libraries/PerLibrary.sol";
import {Math} from "../../src/libraries/Math.sol";

contract PerLibraryTest is Test {
    using PerLibrary for uint256;

    function testConstants() public pure {
        assertEq(PerLibrary.ONE_MILLION, 1e6, "ONE_MILLION should be 1e6");
        assertEq(PerLibrary.ONE_TRILLION, 1e12, "ONE_TRILLION should be 1e12");
        assertEq(PerLibrary.YEAR_TRILLION_SECONDS, 1e12 * 365 days, "YEAR_TRILLION_SECONDS should be correct");
    }

    function testMulMillion() public pure {
        uint256 x = 100;
        uint256 result = x.mulMillion();
        assertEq(result, 100 * 1e6, "Should multiply by 1 million");
    }

    function testDivMillion() public pure {
        uint256 x = 100 * 1e6;
        uint256 result = x.divMillion();
        assertEq(result, 100, "Should divide by 1 million");
    }

    function testMulMillionDiv() public pure {
        uint256 x = 1000;
        uint256 y = 500;
        uint256 result = x.mulMillionDiv(y);

        // x * ONE_MILLION / y
        uint256 expected = Math.mulDiv(x, PerLibrary.ONE_MILLION, y);
        assertEq(result, expected, "Should multiply by million then divide");
    }

    function testMulDivMillion() public pure {
        uint256 x = 1000;
        uint256 y = 500;
        uint256 result = x.mulDivMillion(y);

        // x * y / ONE_MILLION
        uint256 expected = Math.mulDiv(x, y, PerLibrary.ONE_MILLION);
        assertEq(result, expected, "Should multiply then divide by million");
    }

    function testUpperMillion() public pure {
        uint256 x = 1000 ether;
        uint256 per = 10000; // 1%
        uint256 result = x.upperMillion(per);

        // x * (ONE_MILLION + per) / ONE_MILLION
        uint256 expected = x * (PerLibrary.ONE_MILLION + per) / PerLibrary.ONE_MILLION;
        assertEq(result, expected, "Should increase by percentage");
        assertGt(result, x, "Result should be greater than original");
    }

    function testLowerMillion() public pure {
        uint256 x = 1000 ether;
        uint256 per = 10000; // 1%
        uint256 result = x.lowerMillion(per);

        // x * (ONE_MILLION - per) / ONE_MILLION
        uint256 expected = x * (PerLibrary.ONE_MILLION - per) / PerLibrary.ONE_MILLION;
        assertEq(result, expected, "Should decrease by percentage");
        assertLt(result, x, "Result should be less than original");
    }

    function testLowerMillionPerTooHigh() public pure {
        uint256 x = 1000 ether;
        uint256 per = PerLibrary.ONE_MILLION + 1; // More than 100%

        uint256 result = x.lowerMillion(per);
        assertEq(result, 0, "Should return 0 when per >= ONE_MILLION");
    }

    function testLowerMillionPerEqualToOneMillion() public pure {
        uint256 x = 1000 ether;
        uint256 per = PerLibrary.ONE_MILLION; // Exactly 100%

        uint256 result = x.lowerMillion(per);
        assertEq(result, 0, "Should return 0 when per == ONE_MILLION");
    }

    function testIsWithinTolerance() public pure {
        uint256 a = 1000;
        uint256 b = 1005;
        uint256 tolerance = 10;

        assertTrue(PerLibrary.isWithinTolerance(a, b, tolerance), "Should be within tolerance");

        uint256 c = 1020;
        assertFalse(PerLibrary.isWithinTolerance(a, c, tolerance), "Should not be within tolerance");
    }

    function testIsWithinToleranceExact() public pure {
        uint256 a = 1000;
        uint256 b = 1010;
        uint256 tolerance = 10;

        assertTrue(PerLibrary.isWithinTolerance(a, b, tolerance), "Exact tolerance should be within");
    }

    function testIsWithinToleranceSameValue() public pure {
        uint256 a = 1000;
        uint256 tolerance = 0;

        assertTrue(PerLibrary.isWithinTolerance(a, a, tolerance), "Same value should always be within tolerance");
    }

    function testIsWithinToleranceZeroTolerance() public pure {
        uint256 a = 1000;
        uint256 b = 1001;
        uint256 tolerance = 0;

        assertFalse(PerLibrary.isWithinTolerance(a, b, tolerance), "Different values should not be within zero tolerance");
    }

    function testUpperMillionZeroPercent() public pure {
        uint256 x = 1000 ether;
        uint256 per = 0;
        uint256 result = x.upperMillion(per);

        assertEq(result, x, "0% should return same value");
    }

    function testLowerMillionZeroPercent() public pure {
        uint256 x = 1000 ether;
        uint256 per = 0;
        uint256 result = x.lowerMillion(per);

        assertEq(result, x, "0% should return same value");
    }

    function testMulMillionRoundTrip() public pure {
        uint256 x = 1234567;
        uint256 multiplied = x.mulMillion();
        uint256 result = multiplied.divMillion();

        assertEq(result, x, "Round trip should return original value");
    }

    function testMulMillionDivConsistency() public pure {
        uint256 x = 1000 ether;
        uint256 y = 200 ether;

        uint256 result1 = x.mulMillionDiv(y);
        uint256 result2 = Math.mulDiv(x, PerLibrary.ONE_MILLION, y);

        assertEq(result1, result2, "Should be consistent with Math.mulDiv");
    }

    function testMulDivMillionConsistency() public pure {
        uint256 x = 1000 ether;
        uint256 y = 500000; // 0.5

        uint256 result1 = x.mulDivMillion(y);
        uint256 result2 = Math.mulDiv(x, y, PerLibrary.ONE_MILLION);

        assertEq(result1, result2, "Should be consistent with Math.mulDiv");
    }

    function testUpperLowerMillionInverse() public pure {
        uint256 x = 1000 ether;
        uint256 per = 10000; // 1%

        uint256 upper = x.upperMillion(per);
        uint256 lower = x.lowerMillion(per);

        // upper should be greater than x, lower should be less than x
        assertGt(upper, x, "Upper should be greater than x");
        assertLt(lower, x, "Lower should be less than x");

        // The differences should be approximately equal
        uint256 upperDiff = upper - x;
        uint256 lowerDiff = x - lower;

        // Allow for small rounding differences
        assertApproxEqRel(upperDiff, lowerDiff, 0.0001e18, "Differences should be approximately equal");
    }

    function testIsWithinToleranceLargeNumbers() public pure {
        uint256 a = type(uint128).max;
        uint256 b = a + 1000;
        uint256 tolerance = 10000;

        assertTrue(PerLibrary.isWithinTolerance(a, b, tolerance), "Should handle large numbers");
    }

    function testYearTrillionSecondsCalculation() public pure {
        uint256 expected = 1e12 * 365 * 24 * 60 * 60;
        assertEq(PerLibrary.YEAR_TRILLION_SECONDS, expected, "YEAR_TRILLION_SECONDS calculation should be correct");
    }
}
