// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

library UQ112x112 {
    uint224 constant Q112 = 2 ** 112;
    uint24 constant ONE_MILLION = 10 ** 6;

    // encode a uint112 as a UQ112x112
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // never overflows
    }

    // decode UQ112x112 as a uint112
    function decode(uint224 x) internal pure returns (uint112 z) {
        z = uint112(x / uint224(Q112)); // never overflows
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function div(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }

    function truncated(uint112 reverse0, uint112 reverse1, uint224 price0X112, uint24 range)
        internal
        pure
        returns (uint112 inReverse1)
    {
        uint112 reverse1Min = decode(reverse0 * price0X112 * (ONE_MILLION - range) / ONE_MILLION);
        uint112 reverse1Max = decode(reverse0 * price0X112 * (ONE_MILLION + range) / ONE_MILLION);
        if (reverse1 < reverse1Min) {
            inReverse1 = reverse1Min;
        } else if (reverse1 > reverse1Max) {
            inReverse1 = reverse1Max;
        } else {
            inReverse1 = reverse1;
        }
    }
}
