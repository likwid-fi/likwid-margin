// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";

contract LiquidityMathTest is Test {
    function testAddInvestmentPositive() public pure {
        uint256 prev = 0;
        int128 amount0 = 100;
        int128 amount1 = 200;
        uint256 current = LiquidityMath.addInvestment(prev, amount0, amount1);

        int128 currentAmount0 = int128(uint128(current >> 128));
        int128 currentAmount1 = int128(uint128(current));

        assertEq(currentAmount0, 100);
        assertEq(currentAmount1, 200);
    }

    function testAddInvestmentNegative() public pure {
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

    function testAddInvestmentMixed() public pure {
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
}
