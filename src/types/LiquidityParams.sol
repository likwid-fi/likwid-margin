// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Liquidity parameters for addLiquidity
struct AddLiquidityParams {
    /// @notice The id of the pool
    PoolId poolId;
    /// @notice The token0 amount to add
    uint256 amount0;
    /// @notice The token1 amount to add
    uint256 amount1;
    /// @notice LP level 1: x*y, 2: (x+x')*y, 3: x*(y+y'), 4: (x+x')*(y+y')
    uint8 level;
    /// @notice LP token recipient
    address to;
    /// @notice Deadline for the transaction
    uint256 deadline;
}

/// @notice Liquidity parameters for removeLiquidity
struct RemoveLiquidityParams {
    /// @notice The id of the pool
    PoolId poolId;
    /// @notice LP level
    uint8 level;
    /// @notice LP amount to remove
    uint256 liquidity;
    /// @notice Deadline for the transaction
    uint256 deadline;
}
