// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.26;

import {Math} from "./Math.sol";
import {PerLibrary} from "./PerLibrary.sol";
import {FixedPoint96} from "./FixedPoint96.sol";
import {Reserves, toReserves} from "../types/Reserves.sol";

library PriceMath {
    using PerLibrary for *;

    /// @dev Past a million-fold allowed move the clamp means nothing, so the truncated reserves just follow the
    /// pair. This also keeps every product below 2^256 however long the pool has been idle.
    uint256 private constant MAX_PRICE_MOVED = 1e12;

    /// @notice Moves the truncated (slow) reserves towards the pair reserves by at most the allowed price move
    /// @dev Never reverts on long idle periods or extreme ratios: the bounds are compared in uint256 and only the
    /// chosen value is narrowed. Wherever the clamp cannot be represented the pair reserves are followed instead,
    /// and reserve0 is kept at least 1 so the result never reads as uninitialised.
    function transferReserves(
        Reserves originReserves,
        Reserves destReserves,
        uint256 timeElapsed,
        uint24 priceMoveSpeedPPM
    ) internal pure returns (Reserves result) {
        if (!destReserves.bothPositive() || !originReserves.bothPositive()) return destReserves;
        uint256 priceMoved = priceMoveSpeedPPM * (timeElapsed ** 2);
        if (priceMoved >= MAX_PRICE_MOVED) return destReserves;

        (uint256 truncatedReserve0, uint256 truncatedReserve1) = originReserves.reserves();
        uint256 price0X96 = Math.mulDiv(truncatedReserve1, FixedPoint96.Q96, truncatedReserve0);
        uint256 price1X96 = Math.mulDiv(truncatedReserve0, FixedPoint96.Q96, truncatedReserve1);
        if (price0X96 == 0 || price1X96 == 0) return destReserves;

        uint256 newTruncatedReserve1 = destReserves.reserve1();
        uint256 minTruncatedReserve0 =
            Math.mulDiv(newTruncatedReserve1, FixedPoint96.Q96, price0X96.upperMillion(priceMoved));
        uint256 maxTruncatedReserve0 =
            Math.mulDiv(newTruncatedReserve1, price1X96.upperMillion(priceMoved), FixedPoint96.Q96);

        uint256 newTruncatedReserve0 = destReserves.reserve0();
        if (newTruncatedReserve0 < minTruncatedReserve0) {
            newTruncatedReserve0 = minTruncatedReserve0;
        } else if (newTruncatedReserve0 > maxTruncatedReserve0) {
            newTruncatedReserve0 = maxTruncatedReserve0;
        }
        if (newTruncatedReserve0 > type(uint128).max) return destReserves;
        if (newTruncatedReserve0 == 0) newTruncatedReserve0 = 1;
        result = toReserves(uint128(newTruncatedReserve0), uint128(newTruncatedReserve1));
    }
}
