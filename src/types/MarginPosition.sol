// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "likwid-v2-core/types/PoolId.sol";

import {UQ112x112} from "../libraries/UQ112x112.sol";

/// @notice A margin position is a position that is open on a pool.
struct MarginPosition {
    /// @notice The pool ID of the pool on which the position is open.
    PoolId poolId;
    /// @notice true: currency1 is marginToken, false: currency0 is marginToken
    bool marginForOne;
    /// @notice marginAmount1 + ... + marginAmountN
    uint128 marginAmount;
    /// @notice marginTotal1 + ... + marginTotalN
    uint128 marginTotal;
    /// @notice The borrow amount of the margin position including interest.
    uint128 borrowAmount;
    /// @notice The raw amount of borrowed tokens.
    uint128 rawBorrowAmount;
    /// @notice Last cumulative interest was accrued.
    uint256 rateCumulativeLast;
}

/// @notice A margin position with PnL.
struct MarginPositionVo {
    /// @notice The margin position.
    MarginPosition position;
    /// @notice The PnL of the position.
    int256 pnl;
}

using MarginPositionLibrary for MarginPosition global;

library MarginPositionLibrary {
    using UQ112x112 for *;

    function update(MarginPosition storage position, uint256 rateCumulativeLast) internal {
        if (position.rateCumulativeLast > 0) {
            position.borrowAmount =
                position.borrowAmount.increaseInterestCeil(position.rateCumulativeLast, rateCumulativeLast);
        }
        position.rateCumulativeLast = rateCumulativeLast;
    }
}
