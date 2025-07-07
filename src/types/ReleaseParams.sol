// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "likwid-v2-core/types/PoolId.sol";

/// @notice ReleaseParams is a struct that contains all the parameters needed to release margin position.
struct ReleaseParams {
    /// @notice The poolId of the pool.
    PoolId poolId;
    /// @notice true: currency1 is marginToken, false: currency0 is marginToken
    bool marginForOne;
    /// @notice Payment address.
    address payer;
    /// @notice Debt amount.
    uint256 debtAmount;
    /// @notice Repay amount.
    uint256 repayAmount;
    /// @notice Release amount.
    uint256 releaseAmount;
    /// @notice The raw amount of borrowed tokens.
    uint256 rawBorrowAmount;
    /// @notice Deadline for the transaction
    uint256 deadline;
}
