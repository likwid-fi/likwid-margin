// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library UQ112x112 {
    uint224 constant Q112 = 2 ** 112;

    // encode a uint112 as a UQ112x112
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // never overflows
    }

    // decode UQ112x112 as a uint112
    function decode(uint224 x) internal pure returns (uint112 z) {
        z = uint112(x / Q112); // never overflows
    }

    function encode256(uint256 y) internal pure returns (uint256 z) {
        z = y * Q112;
    }

    function decode256(uint256 x) internal pure returns (uint256 z) {
        z = x / Q112;
    }

    function add(uint112 x, uint256 y) internal pure returns (uint112 z) {
        z = x + uint112(y);
    }

    // subtract
    function sub(uint112 x, uint256 y) internal pure returns (uint112 z) {
        z = x - uint112(y);
    }

    function mul(uint112 x, uint256 y) internal pure returns (uint224 z) {
        z = uint224(x) * uint224(y);
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function div(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }

    function scaleDown(uint112 x, uint256 scaler, uint256 denominator) internal pure returns (uint112 z) {
        z = uint112(Math.mulDiv(x, denominator - scaler, denominator));
    }

    function growRatioX112(uint256 ratio, uint256 numerator, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        result = Math.mulDiv(Math.mulDiv(Q112, numerator, denominator) + Q112, ratio, Q112);
    }

    function mulRatioX112(uint256 input, uint256 ratioX112) internal pure returns (uint256 result) {
        result = Math.mulDiv(input, ratioX112, Q112);
    }

    function divRatioX112(uint256 input, uint256 ratioX112) internal pure returns (uint256 result) {
        result = Math.mulDiv(input, Q112, ratioX112);
    }
}
