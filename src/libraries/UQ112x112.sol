// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

library UQ112x112 {
    uint224 constant Q112 = 2 ** 112;
    uint32 constant ONE_MILLION = 10 ** 6;

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

    function getReverses(uint112 reserve0, uint112 reserve1) internal pure returns (uint224 reserves) {
        reserves = (uint224(reserve0) << 112) + uint224(reserve1);
    }

    function getReverse0(uint224 reserves) internal pure returns (uint112 reserve0) {
        reserve0 = uint112(reserves >> 112);
    }

    function getReverse1(uint224 reserves) internal pure returns (uint112 reserve1) {
        reserve1 = uint112(reserves);
    }

    function getPrice1X112(uint224 reserves) internal pure returns (uint224 price1X112) {
        price1X112 = div(encode(getReverse0(reserves)), getReverse1(reserves));
    }

    function truncated(uint112 reverse0, uint112 reverse1, uint224 price1X112, uint32 moved)
        internal
        pure
        returns (uint112 reverse0Result)
    {
        uint112 reverse0Min = decode(reverse1 * price1X112 * (ONE_MILLION - moved) / ONE_MILLION);
        uint112 reverse0Max = decode(reverse1 * price1X112 * (ONE_MILLION + moved) / ONE_MILLION);
        if (reverse0 < reverse0Min) {
            reverse0Result = reverse0Min;
        } else if (reverse1 > reverse0Max) {
            reverse0Result = reverse0Max;
        } else {
            reverse0Result = reverse0;
        }
    }
}
