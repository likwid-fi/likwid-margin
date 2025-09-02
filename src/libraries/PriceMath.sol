// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {UQ112x112} from "./UQ112x112.sol";
import {PerLibrary} from "./PerLibrary.sol";
import {Reserves, toReserves} from "../types/Reserves.sol";

library PriceMath {
    using SafeCast for *;
    using UQ112x112 for *;
    using PerLibrary for *;

    function getReserves(uint112 reserve0, uint112 reserve1) internal pure returns (uint224 reserves) {
        reserves = (uint224(reserve0) << 112) + uint224(reserve1);
    }

    function getReserve0(uint224 reserves) internal pure returns (uint112 reserve0) {
        reserve0 = uint112(reserves >> 112);
    }

    function getReserve1(uint224 reserves) internal pure returns (uint112 reserve1) {
        reserve1 = uint112(reserves);
    }

    function getPrice0X112(uint224 reserves) internal pure returns (uint224 price0X112) {
        price0X112 = getReserve1(reserves).encode().div(getReserve0(reserves));
    }

    function getPrice1X112(uint224 reserves) internal pure returns (uint224 price1X112) {
        price1X112 = getReserve0(reserves).encode().div(getReserve1(reserves));
    }

    function truncated(uint224 price1X112, uint112 reverse0, uint112 reverse1, uint32 moved)
        internal
        pure
        returns (uint112 reverse0Result)
    {
        uint112 reverse0Min;
        if (moved < PerLibrary.ONE_MILLION) {
            reverse0Min = Math.mulDiv(reverse1, price1X112 * (PerLibrary.ONE_MILLION - moved), PerLibrary.ONE_MILLION)
                .toUint224().decode();
        }
        uint112 reverse0Max = Math.mulDiv(
            reverse1, price1X112 * (PerLibrary.ONE_MILLION + moved), PerLibrary.ONE_MILLION
        ).toUint224().decode();
        if (reverse0 < reverse0Min) {
            reverse0Result = reverse0Min;
        } else if (reverse0 > reverse0Max) {
            reverse0Result = reverse0Max;
        } else {
            reverse0Result = reverse0;
        }
    }

    function transferReserves(
        Reserves originReserves,
        Reserves destReserves,
        uint256 timeElapsed,
        uint24 maxPriceMovePerSecond
    ) internal pure returns (Reserves result) {
        if (destReserves.bothPositive()) {
            if (!originReserves.bothPositive()) {
                result = destReserves;
            } else {
                (uint256 truncatedReserve0, uint256 truncatedReserve1) = originReserves.reserves();
                uint256 priceMoved = maxPriceMovePerSecond * (timeElapsed ** 2);
                uint128 newTruncatedReserve0 = 0;
                uint128 newTruncatedReserve1 = destReserves.reserve1();
                uint256 _reserve0 = destReserves.reserve0();

                uint256 reserve0Min =
                    Math.mulDiv(newTruncatedReserve1, truncatedReserve0.lowerMillion(priceMoved), truncatedReserve1);
                uint256 reserve0Max =
                    Math.mulDiv(newTruncatedReserve1, truncatedReserve0.upperMillion(priceMoved), truncatedReserve1);
                if (_reserve0 < reserve0Min) {
                    newTruncatedReserve0 = reserve0Min.toUint128();
                } else if (_reserve0 > reserve0Max) {
                    newTruncatedReserve0 = reserve0Max.toUint128();
                } else {
                    newTruncatedReserve0 = _reserve0.toUint128();
                }
                result = toReserves(newTruncatedReserve0, newTruncatedReserve1);
            }
        } else {
            result = destReserves;
        }
    }
}
