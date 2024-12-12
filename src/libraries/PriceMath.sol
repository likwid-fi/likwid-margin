// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {UQ112x112} from "./UQ112x112.sol";

library PriceMath {
    using UQ112x112 for uint224;

    uint32 constant ONE_MILLION = 10 ** 6;

    function getReverses(uint112 reserve0, uint112 reserve1) internal pure returns (uint224 reserves) {
        reserves = (uint224(reserve0) << 112) + uint224(reserve1);
    }

    function getReverse0(uint224 reserves) internal pure returns (uint112 reserve0) {
        reserve0 = uint112(reserves >> 112);
    }

    function getReverse1(uint224 reserves) internal pure returns (uint112 reserve1) {
        reserve1 = uint112(reserves);
    }

    function getPrice0X112(uint224 reserves) internal pure returns (uint224 price0X112) {
        price0X112 = UQ112x112.encode(getReverse1(reserves)).div(getReverse0(reserves));
    }

    function getPrice1X112(uint224 reserves) internal pure returns (uint224 price1X112) {
        price1X112 = UQ112x112.encode(getReverse0(reserves)).div(getReverse1(reserves));
    }

    function truncated(uint224 price1X112, uint112 reverse0, uint112 reverse1, uint32 moved)
        internal
        pure
        returns (uint112 reverse0Result)
    {
        uint112 reverse0Min;
        if (moved < ONE_MILLION) {
            reverse0Min = UQ112x112.decode(uint224(reverse1) * price1X112 * (ONE_MILLION - moved) / ONE_MILLION);
        }
        uint112 reverse0Max = UQ112x112.decode(uint224(reverse1) * price1X112 * (ONE_MILLION + moved) / ONE_MILLION);
        if (reverse0 < reverse0Min) {
            reverse0Result = reverse0Min;
        } else if (reverse0 > reverse0Max) {
            reverse0Result = reverse0Max;
        } else {
            reverse0Result = reverse0;
        }
    }
}
