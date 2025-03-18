// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct InterestStatus {
    /// @notice The pair cumulative interest of the first currency in the pool.
    uint256 pairCumulativeInterest0;
    /// @notice The lending cumulative interest of the first currency in the pool.
    uint256 lendingCumulativeInterest0;
    /// @notice The pair cumulative interest of the second currency in the pool.
    uint256 pairCumulativeInterest1;
    /// @notice The lending cumulative interest of the second currency in the pool.
    uint256 lendingCumulativeInterest1;
}
