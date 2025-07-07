// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library UQ112x112 {
    using SafeCast for uint256;

    error Overflow();

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
        z = x + y.toUint112();
    }

    // subtract
    function sub(uint112 x, uint256 y) internal pure returns (uint112 z) {
        z = x - y.toUint112();
    }

    function mul(uint112 x, uint256 y) internal pure returns (uint224 z) {
        z = uint224(x) * y.toUint224();
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function div(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / y;
    }

    function scaleDown(uint112 x, uint256 scaler, uint256 denominator) internal pure returns (uint112 z) {
        z = (Math.mulDiv(x, denominator - scaler, denominator)).toUint112();
    }

    function growRatioX112(uint256 ratio, uint256 numerator, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        result = ratio;
        if (numerator > 0 && denominator > 0) result += Math.mulDiv(Q112, numerator, denominator);
    }

    function reduceRatioX112(uint256 ratio, uint256 numerator, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        result = ratio;
        if (numerator > 0 && denominator > 0) {
            uint256 cut = Math.mulDiv(Q112, numerator, denominator, Math.Rounding.Ceil);
            if (result > cut) {
                result -= cut;
            } else {
                result = 0;
            }
        }
    }

    function mulRatioX112(uint256 input, uint256 ratioX112) internal pure returns (uint256 result) {
        result = Math.mulDiv(input, ratioX112, Q112);
    }

    function divRatioX112(uint256 input, uint256 ratioX112) internal pure returns (uint256 result) {
        result = Math.mulDiv(input, Q112, ratioX112);
    }

    function increaseInterestCeil(uint128 current, uint256 rateCumulativeOld, uint256 rateCumulativeLast)
        internal
        pure
        returns (uint128 result)
    {
        result = (Math.mulDiv(current, rateCumulativeLast, rateCumulativeOld, Math.Rounding.Ceil)).toUint128();
    }
}
