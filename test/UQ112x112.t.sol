// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Test, console} from "forge-std/Test.sol";

import {PoolStatus} from "../src/types/PoolStatus.sol";
import {MarginPosition} from "../src/types/MarginPosition.sol";
import {UQ112x112} from "../src/libraries/UQ112x112.sol";

contract UQ112x112Test is Test {
    using UQ112x112 for *;

    function setUp() public {}

    function testScaleDown() public pure {
        uint112 test = 1000;
        uint112 test0 = test.scaleDown(10, 100);
        assertEq(test0, 900);
    }

    function testGrowRatioX112() public pure {
        uint256 ratio = UQ112x112.Q112;
        uint256 growth01 =
            ratio * (uint256(UQ112x112.Q112) + uint256(10) * uint256(UQ112x112.Q112) / 100) / UQ112x112.Q112;
        uint256 growth02 = ratio.growRatioX112(10, 100);
        assertEq(growth01, growth02);
        growth01 = growth01 * (uint256(UQ112x112.Q112) + uint256(11) * uint256(UQ112x112.Q112) / 100) / UQ112x112.Q112;
        growth02 = growth02.growRatioX112(11, 100);
        assertEq(growth01, growth02);
        growth01 =
            growth01 * (uint256(UQ112x112.Q112) + uint256(11) * uint256(UQ112x112.Q112) / 99999999999) / UQ112x112.Q112;
        growth02 = growth02.growRatioX112(11, 99999999999);
        assertEq(growth01, growth02);
    }
}
