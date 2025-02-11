// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Returns the current rate status of the system.
struct RateStatus {
    /// @notice The current rate base(ppm).
    uint24 rateBase;
    /// @notice The middle level of the rate(ppm).
    uint24 useMiddleLevel;
    /// @notice The high level of the rate(ppm).
    uint24 useHighLevel;
    /// @notice The low level Increase multiple.
    uint24 mLow;
    /// @notice The middle level Increase multiple.
    uint24 mMiddle;
    /// @notice The high level Increase multiple.
    uint24 mHigh;
}
