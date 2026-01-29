// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StageMath} from "../../src/libraries/StageMath.sol";

contract StageMathTest is Test {
    using StageMath for uint256;

    function testAdd() public pure {
        uint256 stage = 0;
        uint128 amount = 100;
        uint256 newStage = stage.add(amount);
        (uint128 total, uint128 liquidity) = StageMath.decode(newStage);
        assertEq(total, amount);
        assertEq(liquidity, amount);
    }

    function testSub() public pure {
        uint256 stage = 0;
        uint128 amount = 100;
        uint256 newStage = stage.add(amount).sub(amount);
        (uint128 total, uint128 liquidity) = StageMath.decode(newStage);
        assertEq(total, amount, "Total should be equal to amount");
        assertEq(liquidity, 0, "Liquidity should be zero after subtraction");
    }

    function testIsFree() public pure {
        uint256 stage = 0;
        uint32 leavePart = 5; // Default level part
        assertTrue(StageMath.isFree(stage, leavePart));
        stage = stage.add(100);
        assertFalse(StageMath.isFree(stage, leavePart));
        stage = stage.sub(50);
        assertFalse(StageMath.isFree(stage, leavePart), "Stage should not be free after reducing liquidity");
        stage = stage.sub(30);
        assertTrue(StageMath.isFree(stage, leavePart), "Stage should be free after reducing liquidity");
    }

    function testAdd_multiple() public pure {
        uint256 stage = 0;
        stage = stage.add(100);
        stage = stage.add(200);
        stage = stage.add(50);

        (uint128 total, uint128 liquidity) = StageMath.decode(stage);
        assertEq(total, 350, "Total should be sum of all adds");
        assertEq(liquidity, 350, "Liquidity should be sum of all adds");
    }

    function testSubTotal_partial() public pure {
        uint256 stage = 0;
        stage = stage.add(100);
        stage = stage.subTotal(30);

        (uint128 total, uint128 liquidity) = StageMath.decode(stage);
        assertEq(total, 70, "Total should be reduced");
        assertEq(liquidity, 70, "Liquidity should also be reduced");
    }

    function testIsFree_zeroLeavePart() public pure {
        uint256 stage = 0;
        stage = stage.add(100);

        // When leavePart is 0, it defaults to 2
        // total = 100, liquidity = 100, leavePart = 2
        // total / 2 = 50, liquidity = 100, 50 >= 100 is false
        assertFalse(StageMath.isFree(stage, 0), "Should not be free when liquidity > total/2");

        stage = stage.sub(51); // liquidity = 49
        // total / 2 = 50, liquidity = 49, 50 >= 49 is true
        assertTrue(StageMath.isFree(stage, 0), "Should be free when liquidity <= total/2");
    }

    function testIsFree_exactThreshold() public pure {
        uint256 stage = 0;
        stage = stage.add(100);
        stage = stage.sub(80); // liquidity = 20, total = 100

        // total / 5 = 20, liquidity = 20, so total/5 >= liquidity is true
        assertTrue(StageMath.isFree(stage, 5), "Should be free at exact threshold");

        stage = stage.sub(1); // liquidity = 19
        assertTrue(StageMath.isFree(stage, 5), "Should be free below threshold");
    }

    function testDecode_zero() public pure {
        (uint128 total, uint128 liquidity) = StageMath.decode(0);
        assertEq(total, 0, "Total should be 0");
        assertEq(liquidity, 0, "Liquidity should be 0");
    }

    function testDecode_largeValues() public pure {
        uint128 largeTotal = type(uint128).max;
        uint128 largeLiquidity = type(uint128).max;
        uint256 stage = (uint256(largeTotal) << 128) | uint256(largeLiquidity);

        (uint128 total, uint128 liquidity) = StageMath.decode(stage);
        assertEq(total, largeTotal, "Should decode large total correctly");
        assertEq(liquidity, largeLiquidity, "Should decode large liquidity correctly");
    }

    function testSub_partialThenFull() public pure {
        uint256 stage = 0;
        stage = stage.add(100);
        stage = stage.sub(50);
        stage = stage.sub(50);

        (uint128 total, uint128 liquidity) = StageMath.decode(stage);
        assertEq(total, 100, "Total should remain 100");
        assertEq(liquidity, 0, "Liquidity should be 0");
        assertTrue(StageMath.isFree(stage, 5), "Should be free when liquidity is 0");
    }
}
