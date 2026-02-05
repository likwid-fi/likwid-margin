// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";

contract LiquidityMathTest is Test {
    function testAddInvestmentPositive01() public pure {
        uint256 prev = 0;
        int128 amount0 = 100;
        int128 amount1 = 200;
        uint256 current = LiquidityMath.addInvestment(prev, amount0, amount1);

        int128 currentAmount0 = int128(uint128(current >> 128));
        int128 currentAmount1 = int128(uint128(current));

        assertEq(currentAmount0, 100);
        assertEq(currentAmount1, 200);
    }

    function testAddInvestmentPositive02() public pure {
        uint256 prev = 0;
        int128 amount0 = 10000000000000000000;
        int128 amount1 = 20000000000000000000;
        uint256 current = LiquidityMath.addInvestment(prev, amount0, amount1);

        int128 currentAmount0 = int128(uint128(current >> 128));
        int128 currentAmount1 = int128(uint128(current));

        assertEq(currentAmount0, amount0);
        assertEq(currentAmount1, amount1);
    }

    function testAddInvestmentNegative01() public pure {
        // Initial values: amount0 = 500, amount1 = 1000
        uint256 prev = (uint256(uint128(int128(500))) << 128) | uint256(uint128(int128(1000)));
        int128 amount0 = -100;
        int128 amount1 = -200;
        uint256 current = LiquidityMath.addInvestment(prev, amount0, amount1);

        int128 currentAmount0 = int128(uint128(current >> 128));
        int128 currentAmount1 = int128(uint128(current));

        assertEq(currentAmount0, 400);
        assertEq(currentAmount1, 800);
    }

    function testAddInvestmentNegative02() public pure {
        uint256 prev = 0;
        int128 amount0 = -10000000000000000000;
        int128 amount1 = -20000000000000000000;
        uint256 current = LiquidityMath.addInvestment(prev, amount0, amount1);

        int128 currentAmount0 = int128(uint128(current >> 128));
        int128 currentAmount1 = int128(uint128(current));

        assertEq(currentAmount0, amount0);
        assertEq(currentAmount1, amount1);
    }

    function testAddInvestmentMixed01() public pure {
        uint256 prev = 0;
        int128 amount0 = -10000000000000000000;
        int128 amount1 = 30000000000000000000;
        uint256 current = LiquidityMath.addInvestment(prev, amount0, amount1);

        int128 currentAmount0 = int128(uint128(current >> 128));
        int128 currentAmount1 = int128(uint128(current));

        assertEq(currentAmount0, amount0);
        assertEq(currentAmount1, amount1);
    }

    function testAddInvestmentMixed02() public pure {
        // Initial values: amount0 = 500, amount1 = 1000
        uint256 prev = (uint256(uint128(int128(500))) << 128) | uint256(uint128(int128(1000)));
        int128 amount0 = -100;
        int128 amount1 = 200;
        uint256 current = LiquidityMath.addInvestment(prev, amount0, amount1);

        int128 currentAmount0 = int128(uint128(current >> 128));
        int128 currentAmount1 = int128(uint128(current));

        assertEq(currentAmount0, 400);
        assertEq(currentAmount1, 1200);
    }

    function testAddDelta_positive() public pure {
        uint128 x = 1000;
        int128 y = 500;
        uint128 z = LiquidityMath.addDelta(x, y);
        assertEq(z, 1500, "Should add positive delta");
    }

    function testAddDelta_negative() public pure {
        uint128 x = 1000;
        int128 y = -500;
        uint128 z = LiquidityMath.addDelta(x, y);
        assertEq(z, 500, "Should subtract negative delta");
    }

    function testAddDelta_zero() public pure {
        uint128 x = 1000;
        int128 y = 0;
        uint128 z = LiquidityMath.addDelta(x, y);
        assertEq(z, 1000, "Should remain unchanged with zero delta");
    }

    function testAddDelta_largePositive() public pure {
        uint128 x = type(uint128).max - 1000;
        int128 y = 500;
        uint128 z = LiquidityMath.addDelta(x, y);
        assertEq(z, type(uint128).max - 500, "Should handle large values");
    }

    function testAddDelta_largeNegative() public pure {
        uint128 x = 1000;
        int128 y = -1000;
        uint128 z = LiquidityMath.addDelta(x, y);
        assertEq(z, 0, "Should handle large negative delta");
    }

    function testAddInvestment_multipleOperations() public pure {
        uint256 prev = 0;
        prev = LiquidityMath.addInvestment(prev, 100, 200);
        prev = LiquidityMath.addInvestment(prev, 50, -100);
        prev = LiquidityMath.addInvestment(prev, -30, 50);

        int128 currentAmount0 = int128(uint128(prev >> 128));
        int128 currentAmount1 = int128(uint128(prev));

        assertEq(currentAmount0, 120, "Amount0 should be 120");
        assertEq(currentAmount1, 150, "Amount1 should be 150");
    }

    function testAddInvestment_maxValues() public pure {
        int128 maxInt128 = type(int128).max;
        uint256 current = LiquidityMath.addInvestment(0, maxInt128, maxInt128);

        int128 currentAmount0 = int128(uint128(current >> 128));
        int128 currentAmount1 = int128(uint128(current));

        assertEq(currentAmount0, maxInt128, "Should handle max int128 for amount0");
        assertEq(currentAmount1, maxInt128, "Should handle max int128 for amount1");
    }

    function testAddInvestment_minValues() public pure {
        int128 minInt128 = type(int128).min;
        uint256 current = LiquidityMath.addInvestment(0, minInt128, minInt128);

        int128 currentAmount0 = int128(uint128(current >> 128));
        int128 currentAmount1 = int128(uint128(current));

        assertEq(currentAmount0, minInt128, "Should handle min int128 for amount0");
        assertEq(currentAmount1, minInt128, "Should handle min int128 for amount1");
    }
}
