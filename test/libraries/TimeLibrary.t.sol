// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimeLibrary} from "../../src/libraries/TimeLibrary.sol";

contract TimeLibraryTest is Test {
    function setUp() public {
        // Set a reasonable block timestamp to avoid underflow
        vm.warp(1000000);
    }

    function testGetTimeElapsedNormal() public view {
        uint32 blockTimestampLast = uint32(block.timestamp - 3600); // 1 hour ago
        uint256 timeElapsed = TimeLibrary.getTimeElapsed(blockTimestampLast);

        assertEq(timeElapsed, 3600, "Should return correct time elapsed");
    }

    function testGetTimeElapsedZero() public view {
        uint32 blockTimestampLast = uint32(block.timestamp);
        uint256 timeElapsed = TimeLibrary.getTimeElapsed(blockTimestampLast);

        assertEq(timeElapsed, 0, "Should return 0 when timestamps are equal");
    }

    function testGetTimeElapsedSmallDifference() public view {
        uint32 blockTimestampLast = uint32(block.timestamp - 1);
        uint256 timeElapsed = TimeLibrary.getTimeElapsed(blockTimestampLast);

        assertEq(timeElapsed, 1, "Should return 1 second difference");
    }

    function testGetTimeElapsedLargeDifference() public view {
        uint32 blockTimestampLast = uint32(block.timestamp - 86400); // 1 day ago
        uint256 timeElapsed = TimeLibrary.getTimeElapsed(blockTimestampLast);

        assertEq(timeElapsed, 86400, "Should return correct large time elapsed");
    }

    function testGetTimeElapsedWraparound() public view {
        // Test the wraparound case where blockTimestampLast > current timestamp
        // This simulates the case where the timestamp has wrapped around uint32
        uint32 blockTimestampLast = uint32(block.timestamp + 1000);
        uint256 timeElapsed = TimeLibrary.getTimeElapsed(blockTimestampLast);

        // Expected: 2^32 - blockTimestampLast + current_timestamp
        uint256 expected = uint256(2 ** 32) - blockTimestampLast + uint32(block.timestamp);
        assertEq(timeElapsed, expected, "Should handle wraparound correctly");
    }

    function testGetTimeElapsedMaxUint32() public view {
        uint32 blockTimestampLast = type(uint32).max;
        uint256 timeElapsed = TimeLibrary.getTimeElapsed(blockTimestampLast);

        // Should handle max uint32 correctly
        assertGe(timeElapsed, 0, "Should not underflow");
    }

    function testGetTimeElapsedMinUint32() public view {
        uint32 blockTimestampLast = 0;
        uint256 timeElapsed = TimeLibrary.getTimeElapsed(blockTimestampLast);

        // Should handle min uint32 correctly
        assertGe(timeElapsed, uint32(block.timestamp), "Should handle minimum timestamp");
    }

    function testGetTimeElapsedFutureTimestamp() public view {
        // Test with a timestamp that's "in the future" due to wraparound
        uint32 currentTimestamp = uint32(block.timestamp);
        uint32 futureTimestamp = currentTimestamp + 1000;

        uint256 timeElapsed = TimeLibrary.getTimeElapsed(futureTimestamp);

        // This should be treated as a wraparound case
        uint256 expected = uint256(2 ** 32) - futureTimestamp + currentTimestamp;
        assertEq(timeElapsed, expected, "Should handle future timestamp as wraparound");
    }

    function testGetTimeElapsedNearWraparound() public view {
        // Test near the wraparound boundary
        uint32 currentTimestamp = uint32(block.timestamp);
        uint32 nearWrapTimestamp = currentTimestamp - 10;

        uint256 timeElapsed = TimeLibrary.getTimeElapsed(nearWrapTimestamp);

        assertEq(timeElapsed, 10, "Should handle near wraparound correctly");
    }

    function testGetTimeElapsedConsistency() public view {
        // Test that the function is consistent
        uint32 timestamp1 = uint32(block.timestamp - 100);
        uint32 timestamp2 = uint32(block.timestamp - 200);

        uint256 elapsed1 = TimeLibrary.getTimeElapsed(timestamp1);
        uint256 elapsed2 = TimeLibrary.getTimeElapsed(timestamp2);

        assertGt(elapsed2, elapsed1, "Earlier timestamp should have larger elapsed time");
    }

    function testGetTimeElapsedZeroDifference() public view {
        uint32 currentTimestamp = uint32(block.timestamp);
        uint256 timeElapsed = TimeLibrary.getTimeElapsed(currentTimestamp);

        assertEq(timeElapsed, 0, "Same timestamp should return 0");
    }

    function testGetTimeElapsedOneSecond() public view {
        uint32 blockTimestampLast = uint32(block.timestamp - 1);
        uint256 timeElapsed = TimeLibrary.getTimeElapsed(blockTimestampLast);

        assertEq(timeElapsed, 1, "1 second difference should return 1");
    }

    function testGetTimeElapsedMaxDifference() public {
        // Test with maximum possible difference
        uint32 blockTimestampLast = 0;
        uint32 currentTimestamp = type(uint32).max;

        // Mock the current timestamp
        vm.warp(currentTimestamp);

        uint256 timeElapsed = TimeLibrary.getTimeElapsed(blockTimestampLast);

        assertEq(timeElapsed, type(uint32).max, "Maximum difference should return max uint32");
    }

    function testGetTimeElapsedWraparoundCalculation() public {
        // Test the exact wraparound calculation
        uint32 currentTimestamp = 1000;
        uint32 lastTimestamp = 4294966296; // 2^32 - 1000

        vm.warp(currentTimestamp);

        uint256 timeElapsed = TimeLibrary.getTimeElapsed(lastTimestamp);

        assertEq(timeElapsed, 2000, "Should correctly calculate wraparound time");
    }
}
