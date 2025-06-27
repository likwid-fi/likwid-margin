// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StageMath} from "../../src/libraries/StageMath.sol";

contract StageMathTest is Test {
    using StageMath for uint256;

    function test_add() public pure {
        uint256 stage = 0;
        uint128 amount = 100;
        uint256 newStage = stage.add(amount);
        (uint128 total, uint128 liquidity) = StageMath.decode(newStage);
        assertEq(total, amount);
        assertEq(liquidity, amount);
    }

    function test_sub() public pure {
        uint256 stage = 0;
        uint128 amount = 100;
        uint256 newStage = stage.add(amount).sub(amount);
        (uint128 total, uint128 liquidity) = StageMath.decode(newStage);
        assertEq(total, amount, "Total should be equal to amount");
        assertEq(liquidity, 0, "Liquidity should be zero after subtraction");
    }

    function test_isFree() public pure {
        uint256 stage = 0;
        assertTrue(StageMath.isFree(stage));
        stage = stage.add(100);
        assertFalse(StageMath.isFree(stage));
        stage = stage.sub(50);
        assertTrue(StageMath.isFree(stage), "Stage should be free after reducing liquidity");
    }
}
