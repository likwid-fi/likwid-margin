// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {UQ112x112} from "../libraries/UQ112x112.sol";
import {FeeLibrary} from "../libraries/FeeLibrary.sol";
import {PoolStatus} from "./PoolStatus.sol";

library PoolStatusLibrary {
    using UQ112x112 for uint224;
    using UQ112x112 for uint112;
    using FeeLibrary for uint24;

    function reserve0(PoolStatus memory status) internal pure returns (uint112) {
        return status.realReserve0 + status.mirrorReserve0;
    }

    function reserve1(PoolStatus memory status) internal pure returns (uint112) {
        return status.realReserve1 + status.mirrorReserve1;
    }

    function lendingReserve0(PoolStatus memory status) internal pure returns (uint112) {
        return status.lendingRealReserve0 + status.lendingMirrorReserve0;
    }

    function lendingReserve1(PoolStatus memory status) internal pure returns (uint112) {
        return status.lendingRealReserve1 + status.lendingMirrorReserve1;
    }

    function totalRealReserve0(PoolStatus memory status) internal pure returns (uint112) {
        return status.realReserve0 + status.lendingRealReserve0;
    }

    function totalRealReserve1(PoolStatus memory status) internal pure returns (uint112) {
        return status.realReserve1 + status.lendingRealReserve1;
    }

    function totalMirrorReserve0(PoolStatus memory status) internal pure returns (uint112) {
        return status.mirrorReserve0 + status.lendingMirrorReserve0;
    }

    function totalMirrorReserve1(PoolStatus memory status) internal pure returns (uint112) {
        return status.mirrorReserve1 + status.lendingMirrorReserve1;
    }

    function getReserves(PoolStatus memory status) internal pure returns (uint256 _reserve0, uint256 _reserve1) {
        _reserve0 = reserve0(status);
        _reserve1 = reserve1(status);
    }

    function getPrice0X112(PoolStatus memory status) internal pure returns (uint224) {
        return reserve1(status).encode().div(reserve0(status));
    }

    function getPrice1X112(PoolStatus memory status) internal pure returns (uint224) {
        return reserve0(status).encode().div(reserve1(status));
    }

    function computeLiquidity(
        PoolStatus memory status,
        uint256 totalSupply,
        uint256 amount0,
        uint256 amount1,
        uint24 maxSliding
    ) internal pure returns (uint256 liquidity, uint256 amount0In, uint256 amount1In) {
        (uint256 _reserve0, uint256 _reserve1) = getReserves(status);
        if (_reserve0 > 0 && _reserve1 > 0) {
            uint256 amount1Exactly = Math.mulDiv(amount0, _reserve1, _reserve0);
            (uint256 amount1Lower, uint256 amount1Upper) = maxSliding.bound(amount1Exactly);
            require(amount1 > amount1Lower && amount1 < amount1Upper, "OUT_OF_RANGE");
            if (amount1Exactly > amount1) {
                amount1In = amount1;
                amount0In = Math.mulDiv(amount1In, _reserve0, _reserve1);
            } else {
                amount1In = amount1Exactly;
                amount0In = amount0;
            }
            liquidity =
                Math.min(Math.mulDiv(amount0In, totalSupply, _reserve0), Math.mulDiv(amount1In, totalSupply, _reserve1));
        } else {
            liquidity = Math.sqrt(amount0 * amount1);
            amount0In = amount0;
            amount1In = amount1;
        }
    }

    function refresh(PoolStatus memory status) internal pure {}
}
