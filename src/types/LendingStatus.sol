// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Returns the status of a lending pool.
struct LendingStatus {
    /// @notice The accrues ratio of the first currency in the pool.(x)
    uint256 accruesRatio0X112;
    /// @notice The accrues ratio of the second currency in the pool.(y)
    uint256 accruesRatio1X112;
}
