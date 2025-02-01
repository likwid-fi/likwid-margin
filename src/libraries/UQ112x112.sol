// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library UQ112x112 {
    uint224 constant Q112 = 2 ** 112;

    // encode a uint112 as a UQ112x112
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // never overflows
    }

    // decode UQ112x112 as a uint112
    function decode(uint224 x) internal pure returns (uint112 z) {
        z = uint112(x / uint224(Q112)); // never overflows
    }

    function mul(uint112 x, uint256 y) internal pure returns (uint224 z) {
        z = uint224(x) * uint224(y);
    }

    function scaleDown(uint112 x, uint256 scaler, uint256 denominator) internal pure returns (uint112 z) {
        z = decode(div(mul(x, denominator - scaler), uint112(denominator)));
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function div(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}
