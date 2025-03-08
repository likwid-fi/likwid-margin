// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library UQ112x112 {
    error Overflow();

    uint224 constant Q112 = 2 ** 112;

    /// @notice Cast a uint256 to a uint112, revert on overflow or underflow
    /// @param x The uint256 to be casted
    /// @return y The casted integer, now type uint112
    function toUint112(uint256 x) internal pure returns (uint112 y) {
        y = uint112(x);
        if (x != y) revert Overflow();
    }

    /// @notice Cast a uint256 to a uint224, revert on overflow or underflow
    /// @param x The uint256 to be casted
    /// @return y The casted integer, now type uint224
    function toUint224(uint256 x) internal pure returns (uint224 y) {
        y = uint224(x);
        if (x != y) revert Overflow();
    }

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
        z = x + toUint112(y);
    }

    // subtract
    function sub(uint112 x, uint256 y) internal pure returns (uint112 z) {
        z = x - toUint112(y);
    }

    function mul(uint112 x, uint256 y) internal pure returns (uint224 z) {
        z = toUint224(x) * toUint224(y);
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function div(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / toUint224(y);
    }

    function scaleDown(uint112 x, uint256 scaler, uint256 denominator) internal pure returns (uint112 z) {
        z = toUint112(Math.mulDiv(x, denominator - scaler, denominator));
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

    function increaseInterest(
        uint256 current,
        uint256 rateCumulativeOld,
        uint256 rateCumulativeLast,
        Math.Rounding rounding
    ) internal pure returns (uint112 result) {
        result = toUint112(Math.mulDiv(current, rateCumulativeOld, rateCumulativeLast, rounding));
    }

    function increaseInterest(uint128 current, uint256 rateCumulativeOld, uint256 rateCumulativeLast)
        internal
        pure
        returns (uint128 result)
    {
        result = toUint112(Math.mulDiv(current, rateCumulativeOld, rateCumulativeLast, Math.Rounding.Ceil));
    }
}
