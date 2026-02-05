// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.26;

import {Math} from "./Math.sol";
import {SafeCast} from "./SafeCast.sol";
import {PerLibrary} from "./PerLibrary.sol";
import {FixedPoint96} from "./FixedPoint96.sol";
import {Reserves, toReserves} from "../types/Reserves.sol";

library PriceMath {
    using SafeCast for *;
    using PerLibrary for *;

    function transferReserves(
        Reserves originReserves,
        Reserves destReserves,
        uint256 timeElapsed,
        uint24 priceMoveSpeedPPM
    ) internal pure returns (Reserves result) {
        if (destReserves.bothPositive()) {
            if (!originReserves.bothPositive()) {
                result = destReserves;
            } else {
                uint256 priceMoved = priceMoveSpeedPPM * (timeElapsed ** 2);
                (uint256 truncatedReserve0, uint256 truncatedReserve1) = originReserves.reserves();
                uint256 price0X96 = Math.mulDiv(truncatedReserve1, FixedPoint96.Q96, truncatedReserve0);
                uint256 price1X96 = Math.mulDiv(truncatedReserve0, FixedPoint96.Q96, truncatedReserve1);
                uint256 maxPrice0X96 = price0X96.upperMillion(priceMoved);
                uint256 maxPrice1X96 = price1X96.upperMillion(priceMoved);
                uint128 newTruncatedReserve0 = 0;
                uint128 newTruncatedReserve1 = destReserves.reserve1();
                uint128 minTruncatedReserve0 =
                    Math.mulDiv(newTruncatedReserve1, FixedPoint96.Q96, maxPrice0X96).toUint128();
                uint128 maxTruncatedReserve0 =
                    Math.mulDiv(newTruncatedReserve1, maxPrice1X96, FixedPoint96.Q96).toUint128();

                uint256 _reserve0 = destReserves.reserve0();
                if (_reserve0 < minTruncatedReserve0) {
                    newTruncatedReserve0 = minTruncatedReserve0;
                } else if (_reserve0 > maxTruncatedReserve0) {
                    newTruncatedReserve0 = maxTruncatedReserve0;
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
