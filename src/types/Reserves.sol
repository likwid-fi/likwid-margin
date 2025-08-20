// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev Two `uint128` values packed into a single `uint256` where the upper 128 bits represent reserve0
/// and the lower 128 bits represent reserve1.
type Reserves is uint256;

using ReservesLibrary for Reserves global;

/// @notice Creates a Reserves object from two uint128 values.
/// @param _reserve0 The value for the upper 128 bits.
/// @param _reserve1 The value for the lower 128 bits.
/// @return A Reserves object.
function toReserves(uint128 _reserve0, uint128 _reserve1) pure returns (Reserves) {
    return Reserves.wrap((uint256(_reserve0) << 128) | _reserve1);
}

/// @notice A library for handling the Reserves type, which packs two uint128 values into a single uint256.
library ReservesLibrary {
    /// @notice Retrieves the reserve0 value from a Reserves object.
    /// @param self The Reserves object.
    /// @return The reserve0 value (upper 128 bits).
    function reserve0(Reserves self) internal pure returns (uint128) {
        return uint128(Reserves.unwrap(self) >> 128);
    }

    /// @notice Retrieves the reserve1 value from a Reserves object.
    /// @param self The Reserves object.
    /// @return The reserve1 value (lower 128 bits).
    function reserve1(Reserves self) internal pure returns (uint128) {
        return uint128(Reserves.unwrap(self));
    }

    function reserves(Reserves self) internal pure returns (uint128 _reserve0, uint128 _reserve1) {
        _reserve0 = self.reserve0();
        _reserve1 = self.reserve1();
    }

    /// @notice Updates the reserve0 value in a Reserves object.
    /// @param self The Reserves object to update.
    /// @param newReserve0 The new value for reserve0.
    /// @return The updated Reserves object.
    function updateReserve0(Reserves self, uint128 newReserve0) internal pure returns (Reserves) {
        return toReserves(newReserve0, self.reserve1());
    }

    /// @notice Updates the reserve1 value in a Reserves object.
    /// @param self The Reserves object to update.
    /// @param newReserve1 The new value for reserve1.
    /// @return The updated Reserves object.
    function updateReserve1(Reserves self, uint128 newReserve1) internal pure returns (Reserves) {
        return toReserves(self.reserve0(), newReserve1);
    }
}
