// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Reserves, toReserves} from "../types/Reserves.sol";
import {Math} from "./Math.sol";
import {FeeLibrary} from "./FeeLibrary.sol";
import {PerLibrary} from "./PerLibrary.sol";
import {FixedPoint96} from "./FixedPoint96.sol";
import {CustomRevert} from "./CustomRevert.sol";

library SwapMath {
    using CustomRevert for bytes4;
    using FeeLibrary for uint24;
    using PerLibrary for uint256;

    /// @notice the swap fee is represented in hundredths of a bip, so the max is 100%
    /// @dev the swap fee is the total fee on a swap, including both LP and Protocol fee
    uint256 internal constant MAX_SWAP_FEE = 1e6;

    error InsufficientLiquidity();

    function differencePrice(uint256 price, uint256 lastPrice) internal pure returns (uint256 priceDiff) {
        priceDiff = price > lastPrice ? price - lastPrice : lastPrice - price;
    }

    function getPriceDegree(
        Reserves pairReserves,
        Reserves truncatedReserves,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    ) internal pure returns (uint256 degree) {
        if (truncatedReserves.bothPositive()) {
            uint256 lastPrice0X96 = truncatedReserves.getPrice0X96();
            uint256 lastPrice1X96 = truncatedReserves.getPrice1X96();
            (uint256 _reserve0, uint256 _reserve1) = pairReserves.reserves();
            if (_reserve0 == 0 || _reserve1 == 0) {
                return degree;
            }
            if (amountIn > 0) {
                amountOut = getAmountOut(pairReserves, zeroForOne, amountIn);
            } else if (amountOut > 0) {
                amountIn = getAmountIn(pairReserves, zeroForOne, amountOut);
            }
            unchecked {
                if (zeroForOne) {
                    _reserve1 -= amountOut;
                    _reserve0 += amountIn;
                } else {
                    _reserve0 -= amountOut;
                    _reserve1 += amountIn;
                }
            }
            uint256 price0X96 = Math.mulDiv(_reserve1, FixedPoint96.Q96, _reserve0);
            uint256 price1X96 = Math.mulDiv(_reserve0, FixedPoint96.Q96, _reserve1);
            uint256 degree0 = differencePrice(price0X96, lastPrice0X96).mulMillionDiv(lastPrice0X96);
            uint256 degree1 = differencePrice(price1X96, lastPrice1X96).mulMillionDiv(lastPrice1X96);
            degree = Math.max(degree0, degree1);
        }
    }

    function dynamicFee(uint24 swapFee, uint256 degree) internal pure returns (uint24 _fee) {
        _fee = swapFee;
        if (degree > MAX_SWAP_FEE) {
            _fee = uint24(MAX_SWAP_FEE) - 10000;
        } else if (degree > 100000) {
            uint256 dFee = Math.mulDiv((degree * 10) ** 3, _fee, MAX_SWAP_FEE ** 3);
            if (dFee >= MAX_SWAP_FEE) {
                _fee = uint24(MAX_SWAP_FEE) - 10000;
            } else {
                _fee = uint24(dFee);
            }
        }
    }

    function getAmountOut(Reserves pairReserves, bool zeroForOne, uint256 amountIn)
        internal
        pure
        returns (uint256 amountOut)
    {
        (uint128 _reserve0, uint128 _reserve1) = pairReserves.reserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        uint256 amountInWithoutFee = amountIn;
        uint256 numerator = amountInWithoutFee * reserveOut;
        uint256 denominator = reserveIn + amountInWithoutFee;
        amountOut = numerator / denominator;
    }

    function getAmountIn(Reserves pairReserves, bool zeroForOne, uint256 amountOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        (uint128 _reserve0, uint128 _reserve1) = pairReserves.reserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        uint256 numerator = reserveIn * amountOut;
        uint256 denominator = (reserveOut - amountOut);
        uint256 amountInWithoutFee = (numerator / denominator) + 1;
        amountIn = amountInWithoutFee;
    }
}
