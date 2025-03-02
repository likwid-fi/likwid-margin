// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {UQ112x112} from "../libraries/UQ112x112.sol";

using HookStatusLibrary for HookStatus global;

/// @notice Returns the status of a hook.
struct HookStatus {
    /// @notice The real reserve of the first currency in the pool.(x)
    uint112 realReserve0;
    /// @notice The real reserve of the second currency in the pool.(y)
    uint112 realReserve1;
    /// @notice The mirror reserve of the first currency in the pool.(x')
    uint112 mirrorReserve0;
    /// @notice The mirror reserve of the second currency in the pool.(y')
    uint112 mirrorReserve1;
    /// @notice The margin fee of the pool.defined as 1.5% of the borrowed amount.
    uint24 marginFee; // 15000 = 1.5%
    /// @notice The block timestamp of the last update of the pool.
    uint32 blockTimestampLast;
    /// @notice The interest ratio of the first currency in the pool.
    uint112 interestRatio0X112;
    /// @notice The interest ratio of the second currency in the pool.
    uint112 interestRatio1X112;
    /// @notice The cumulative borrow rate of the first currency in the pool.
    uint256 rate0CumulativeLast;
    /// @notice The cumulative borrow rate of the second currency in the pool.
    uint256 rate1CumulativeLast;
    /// @notice The last timestamp of margin trading.
    uint32 marginTimestampLast;
    /// @notice The last price of the second currency in the pool.
    uint224 lastPrice1X112;
    /// @notice The the key for identifying a pool
    PoolKey key;
}

library HookStatusLibrary {
    using UQ112x112 for uint224;
    using UQ112x112 for uint112;

    function reserve0(HookStatus memory status) internal pure returns (uint112) {
        return status.realReserve0 + status.mirrorReserve0;
    }

    function reserve1(HookStatus memory status) internal pure returns (uint112) {
        return status.realReserve1 + status.mirrorReserve1;
    }

    function getReserves(HookStatus memory status) internal pure returns (uint224 reserves) {
        reserves = (uint224(reserve0(status)) << 112) + uint224(reserve1(status));
    }

    function getPrice0X112(HookStatus memory status) internal pure returns (uint224) {
        return reserve1(status).encode().div(reserve0(status));
    }

    function getPrice1X112(HookStatus memory status) internal pure returns (uint224) {
        return reserve0(status).encode().div(reserve1(status));
    }
}
