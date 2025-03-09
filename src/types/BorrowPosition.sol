// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice A margin position is a position that is open on a pool.
struct BorrowPosition {
    /// @notice The pool ID of the pool on which the position is open.
    PoolId poolId;
    /// @notice true: currency1 is marginToken, false: currency0 is marginToken
    bool marginForOne;
    /// @notice marginAmount1 + ... + marginAmountN
    uint128 marginAmount;
    /// @notice The borrow amount of the borrow position including interest.
    uint128 borrowAmount;
    /// @notice The raw amount of borrowed tokens.
    uint128 rawBorrowAmount;
    /// @notice Last cumulative interest was accrued.
    uint256 rateCumulativeLast;
}

/// @notice A margin position with PnL.
struct BorrowPositionVo {
    /// @notice The margin position.
    BorrowPosition position;
    /// @notice The PnL of the position.
    int256 pnl;
}
