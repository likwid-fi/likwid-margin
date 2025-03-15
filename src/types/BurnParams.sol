// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice The parameters for burning margin positions.
struct BurnParams {
    /// @notice The pool ID of the pool on which the position is open.
    PoolId poolId;
    /// @notice true: currency1 is marginToken, false: currency0 is marginToken
    bool marginForOne;
    /// @notice The ids of the positions to be burned.
    uint256[] positionIds;
}
