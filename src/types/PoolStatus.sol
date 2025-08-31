// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "./PoolKey.sol";
import {PoolStatusLibrary} from "./PoolStatusLibrary.sol";

using PoolStatusLibrary for PoolStatus global;

struct PoolStatus {
    /// @notice The block timestamp of the last update of the pool.
    uint32 blockTimestampLast;
    /// @notice The real reserve of the first currency in the pool.(x)
    uint112 realReserve0;
    /// @notice The real reserve of the second currency in the pool.(y)
    uint112 realReserve1;
    /// @notice The mirror reserve of the first currency in the pool.(x')
    uint112 mirrorReserve0;
    /// @notice The mirror reserve of the second currency in the pool.(y')
    uint112 mirrorReserve1;
    /// @notice The margin fee of the pool.
    uint24 marginFee;
    /// @notice The real reserve of the first currency in the lending pool.
    uint112 lendingRealReserve0;
    /// @notice The real reserve of the second currency in the lending pool.
    uint112 lendingRealReserve1;
    /// @notice The mirror reserve of the first currency in the lending pool.
    uint112 lendingMirrorReserve0;
    /// @notice The mirror reserve of the second currency in the lending pool.
    uint112 lendingMirrorReserve1;
    /// @notice The truncated reserve of the first currency in the lending pool.
    uint112 truncatedReserve0;
    /// @notice The truncated reserve of the second currency in the lending pool.
    uint112 truncatedReserve1;
    /// @notice The cumulative borrow rate of the first currency in the pool.
    uint256 rate0CumulativeLast;
    /// @notice The cumulative borrow rate of the second currency in the pool.
    uint256 rate1CumulativeLast;
    PoolKey key;
}
