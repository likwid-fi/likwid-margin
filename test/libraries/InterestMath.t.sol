// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {InterestMath} from "../../src/libraries/InterestMath.sol";
import {MarginState, MarginStateLibrary} from "../../src/types/MarginState.sol";
import {Reserves, toReserves} from "../../src/types/Reserves.sol";
import {PerLibrary} from "../../src/libraries/PerLibrary.sol";

contract InterestMathTest is Test {
    using MarginStateLibrary for MarginState;

    function testGetUpdatedCumulativeValues() public {
        // 1. Setup initial state
        uint256 timeElapsed = 3600; // 1 hour
        uint256 borrow0CumulativeBefore = 1e18;
        uint256 borrow1CumulativeBefore = 1e18;
        uint256 deposit0CumulativeBefore = 1e18;
        uint256 deposit1CumulativeBefore = 1e18;

        MarginState marginState;
        marginState = marginState.setRateBase(100);
        marginState = marginState.setUseHighLevel(800000);
        marginState = marginState.setUseMiddleLevel(600000);
        marginState = marginState.setMHigh(200);
        marginState = marginState.setMMiddle(100);
        marginState = marginState.setMLow(50);

        Reserves realReserves = toReserves(1000e18, 1000e18);
        Reserves mirrorReserves = toReserves(100e18, 200e18);
        Reserves pairReserves = toReserves(500e18, 500e18);
        Reserves lendReserves = toReserves(500e18, 500e18);
        Reserves interestReserves = toReserves(0, 0);
        uint24 protocolFee = 1000; // 0.1%

        // 2. Call the function
        (
            uint256 borrow0CumulativeLast,
            uint256 borrow1CumulativeLast,
            uint256 deposit0CumulativeLast,
            uint256 deposit1CumulativeLast
        ) = InterestMath.getUpdatedCumulativeValues(
            timeElapsed,
            borrow0CumulativeBefore,
            borrow1CumulativeBefore,
            deposit0CumulativeBefore,
            deposit1CumulativeBefore,
            marginState,
            realReserves,
            mirrorReserves,
            pairReserves,
            lendReserves,
            interestReserves,
            protocolFee
        );

        // 3. Assert the results
        assertTrue(borrow0CumulativeLast > borrow0CumulativeBefore, "borrow0CumulativeLast should be greater");
        assertTrue(borrow1CumulativeLast > borrow1CumulativeBefore, "borrow1CumulativeLast should be greater");
        assertTrue(deposit0CumulativeLast > deposit0CumulativeBefore, "deposit0CumulativeLast should be greater");
        assertTrue(deposit1CumulativeLast > deposit1CumulativeBefore, "deposit1CumulativeLast should be greater");
    }
}
