// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DoubleEndedQueue} from "../../src/libraries/external/DoubleEndedQueue.sol";

contract DoubleEndedQueueTest is Test {
    using DoubleEndedQueue for DoubleEndedQueue.Uint256Deque;

    DoubleEndedQueue.Uint256Deque deque;

    function setUp() public {
        // deque is automatically initialized to empty
    }

    function testEmpty() public view {
        assertTrue(deque.empty(), "New deque should be empty");
        assertEq(deque.length(), 0, "Empty deque should have length 0");
    }

    function testPushBack() public {
        deque.pushBack(100);
        assertFalse(deque.empty(), "Deque should not be empty after push");
        assertEq(deque.length(), 1, "Length should be 1");
        assertEq(deque.back(), 100, "Back should be the pushed value");
        assertEq(deque.front(), 100, "Front should also be the pushed value");
    }

    function testPushFront() public {
        deque.pushFront(100);
        assertFalse(deque.empty(), "Deque should not be empty after push");
        assertEq(deque.length(), 1, "Length should be 1");
        assertEq(deque.front(), 100, "Front should be the pushed value");
        assertEq(deque.back(), 100, "Back should also be the pushed value");
    }

    function testPushBackMultiple() public {
        deque.pushBack(100);
        deque.pushBack(200);
        deque.pushBack(300);

        assertEq(deque.length(), 3, "Length should be 3");
        assertEq(deque.front(), 100, "Front should be first pushed");
        assertEq(deque.back(), 300, "Back should be last pushed");
    }

    function testPushFrontMultiple() public {
        deque.pushFront(100);
        deque.pushFront(200);
        deque.pushFront(300);

        assertEq(deque.length(), 3, "Length should be 3");
        assertEq(deque.front(), 300, "Front should be last pushed");
        assertEq(deque.back(), 100, "Back should be first pushed");
    }

    function testPopBack() public {
        deque.pushBack(100);
        deque.pushBack(200);

        uint256 value = deque.popBack();
        assertEq(value, 200, "Should pop the back value");
        assertEq(deque.length(), 1, "Length should be 1");
        assertEq(deque.back(), 100, "Back should now be the first value");
    }

    function testPopFront() public {
        deque.pushBack(100);
        deque.pushBack(200);

        uint256 value = deque.popFront();
        assertEq(value, 100, "Should pop the front value");
        assertEq(deque.length(), 1, "Length should be 1");
        assertEq(deque.front(), 200, "Front should now be the second value");
    }

    function testPopBackEmpty() public {
        // Note: Cannot use vm.expectRevert for library functions called directly
        // The revert happens at the same depth as the test
        try this.callPopBack() {
            assertTrue(false, "Should have reverted");
        } catch {
            // Expected
        }
    }

    function callPopBack() external {
        deque.popBack();
    }

    function testPopFrontEmpty() public {
        try this.callPopFront() {
            assertTrue(false, "Should have reverted");
        } catch {
            // Expected
        }
    }

    function callPopFront() external {
        deque.popFront();
    }

    function testFrontEmpty() public view {
        try this.callFront() {
            assertTrue(false, "Should have reverted");
        } catch {
            // Expected
        }
    }

    function callFront() external view {
        deque.front();
    }

    function testBackEmpty() public view {
        try this.callBack() {
            assertTrue(false, "Should have reverted");
        } catch {
            // Expected
        }
    }

    function callBack() external view {
        deque.back();
    }

    function testAt() public {
        deque.pushBack(100);
        deque.pushBack(200);
        deque.pushBack(300);

        assertEq(deque.at(0), 100, "Index 0 should be 100");
        assertEq(deque.at(1), 200, "Index 1 should be 200");
        assertEq(deque.at(2), 300, "Index 2 should be 300");
    }

    function testAtOutOfBounds() public {
        deque.pushBack(100);

        try this.callAt(1) {
            assertTrue(false, "Should have reverted");
        } catch {
            // Expected
        }
    }

    function callAt(uint256 index) external view {
        deque.at(index);
    }

    function testSet() public {
        deque.pushBack(100);
        deque.pushBack(200);
        deque.pushBack(300);

        deque.set(1, 250);

        assertEq(deque.at(1), 250, "Index 1 should be updated to 250");
        assertEq(deque.at(0), 100, "Index 0 should remain unchanged");
        assertEq(deque.at(2), 300, "Index 2 should remain unchanged");
    }

    function testSetOutOfBounds() public {
        deque.pushBack(100);

        try this.callSet(1, 200) {
            assertTrue(false, "Should have reverted");
        } catch {
            // Expected
        }
    }

    function callSet(uint256 index, uint256 value) external {
        deque.set(index, value);
    }

    function testClear() public {
        deque.pushBack(100);
        deque.pushBack(200);
        deque.pushBack(300);

        deque.clear();

        assertTrue(deque.empty(), "Deque should be empty after clear");
        assertEq(deque.length(), 0, "Length should be 0 after clear");
    }

    function testMixedOperations() public {
        // Push back and front
        deque.pushBack(200);
        deque.pushFront(100);
        deque.pushBack(300);

        assertEq(deque.length(), 3, "Length should be 3");
        assertEq(deque.front(), 100, "Front should be 100");
        assertEq(deque.back(), 300, "Back should be 300");

        // Pop front and back
        uint256 front = deque.popFront();
        uint256 back = deque.popBack();

        assertEq(front, 100, "Popped front should be 100");
        assertEq(back, 300, "Popped back should be 300");
        assertEq(deque.length(), 1, "Length should be 1");
        assertEq(deque.front(), 200, "Remaining should be 200");
        assertEq(deque.back(), 200, "Remaining should be 200");
    }

    function testLargeValues() public {
        uint256 maxValue = type(uint256).max;
        deque.pushBack(maxValue);

        assertEq(deque.front(), maxValue, "Should handle max uint256");
        assertEq(deque.back(), maxValue, "Should handle max uint256");
    }

    function testZeroValue() public {
        deque.pushBack(0);

        assertEq(deque.front(), 0, "Should handle zero value");
        assertFalse(deque.empty(), "Deque with zero should not be empty");
    }

    function testPushBackMany() public {
        for (uint256 i = 0; i < 100; i++) {
            deque.pushBack(i);
        }

        assertEq(deque.length(), 100, "Length should be 100");
        assertEq(deque.front(), 0, "Front should be 0");
        assertEq(deque.back(), 99, "Back should be 99");

        for (uint256 i = 0; i < 100; i++) {
            assertEq(deque.at(i), i, "Value at index should match");
        }
    }

    function testPushFrontMany() public {
        for (uint256 i = 0; i < 100; i++) {
            deque.pushFront(i);
        }

        assertEq(deque.length(), 100, "Length should be 100");
        assertEq(deque.front(), 99, "Front should be 99");
        assertEq(deque.back(), 0, "Back should be 0");

        for (uint256 i = 0; i < 100; i++) {
            assertEq(deque.at(i), 99 - i, "Value at index should match");
        }
    }

    function testFIFO() public {
        // Test FIFO behavior with pushBack and popFront
        for (uint256 i = 0; i < 10; i++) {
            deque.pushBack(i);
        }

        for (uint256 i = 0; i < 10; i++) {
            uint256 value = deque.popFront();
            assertEq(value, i, "FIFO order should be maintained");
        }

        assertTrue(deque.empty(), "Deque should be empty after popping all");
    }

    function testLIFO() public {
        // Test LIFO behavior with pushBack and popBack
        for (uint256 i = 0; i < 10; i++) {
            deque.pushBack(i);
        }

        for (uint256 i = 0; i < 10; i++) {
            uint256 value = deque.popBack();
            assertEq(value, 9 - i, "LIFO order should be maintained");
        }

        assertTrue(deque.empty(), "Deque should be empty after popping all");
    }
}
