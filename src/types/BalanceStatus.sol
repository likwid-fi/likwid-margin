// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Returns the balances of a pool.
struct BalanceStatus {
    /// @notice The balance of token0 in the pool.
    uint256 balance0;
    /// @notice The balance of token1 in the pool.
    uint256 balance1;
    /// @notice The mirror balance of token0 in the pool.
    uint256 mirrorBalance0;
    /// @notice The mirror balance of token1 in the pool.
    uint256 mirrorBalance1;
}
