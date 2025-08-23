// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Forge
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
// Likwid Contracts
import {RateState} from "../../src/types/RateState.sol";

contract RateStateTest is Test {
    RateState private rateState;

    function setUp() public {
        rateState = RateState.wrap(0);
    }

    function testSetAndGetRateBase() public {
        uint24 rateBase = 1000;
        rateState = rateState.setRateBase(rateBase);
        assertEq(rateState.rateBase(), rateBase);
    }

    function testSetAndGetUseMiddleLevel() public {
        uint24 useMiddleLevel = 2000;
        rateState = rateState.setUseMiddleLevel(useMiddleLevel);
        assertEq(rateState.useMiddleLevel(), useMiddleLevel);
    }

    function testSetAndGetUseHighLevel() public {
        uint24 useHighLevel = 3000;
        rateState = rateState.setUseHighLevel(useHighLevel);
        assertEq(rateState.useHighLevel(), useHighLevel);
    }

    function testSetAndGetMLow() public {
        uint24 mLow = 4000;
        rateState = rateState.setMLow(mLow);
        assertEq(rateState.mLow(), mLow);
    }

    function testSetAndGetMMiddle() public {
        uint24 mMiddle = 5000;
        rateState = rateState.setMMiddle(mMiddle);
        assertEq(rateState.mMiddle(), mMiddle);
    }

    function testSetAndGetMHigh() public {
        uint24 mHigh = 6000;
        rateState = rateState.setMHigh(mHigh);
        assertEq(rateState.mHigh(), mHigh);
    }

    function testMultipleSetAndGet() public {
        uint24 rateBase = 1000;
        uint24 useMiddleLevel = 2000;
        uint24 useHighLevel = 3000;
        uint24 mLow = 4000;
        uint24 mMiddle = 5000;
        uint24 mHigh = 6000;

        rateState = rateState.setRateBase(rateBase);
        rateState = rateState.setUseMiddleLevel(useMiddleLevel);
        rateState = rateState.setUseHighLevel(useHighLevel);
        rateState = rateState.setMLow(mLow);
        rateState = rateState.setMMiddle(mMiddle);
        rateState = rateState.setMHigh(mHigh);

        assertEq(rateState.rateBase(), rateBase);
        assertEq(rateState.useMiddleLevel(), useMiddleLevel);
        assertEq(rateState.useHighLevel(), useHighLevel);
        assertEq(rateState.mLow(), mLow);
        assertEq(rateState.mMiddle(), mMiddle);
        assertEq(rateState.mHigh(), mHigh);
    }
}
