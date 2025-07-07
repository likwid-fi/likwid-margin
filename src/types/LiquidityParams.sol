// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "likwid-v2-core/types/Currency.sol";
import {PoolId} from "likwid-v2-core/types/PoolId.sol";

/// @notice Liquidity parameters for addLiquidity
struct AddLiquidityParams {
    /// @notice The id of the pool
    PoolId poolId;
    /// @notice The token0 amount to add
    uint256 amount0;
    /// @notice The token1 amount to add
    uint256 amount1;
    /// @notice The token0 min amount to get
    uint256 amount0Min;
    /// @notice The token1 min amount to get
    uint256 amount1Min;
    /// @notice The address of source
    address source;
    /// @notice Deadline for the transaction
    uint256 deadline;
}

/// @notice Liquidity parameters for removeLiquidity
struct RemoveLiquidityParams {
    /// @notice The id of the pool
    PoolId poolId;
    /// @notice LP amount to remove
    uint256 liquidity;
    /// @notice The token0 min amount to get
    uint256 amount0Min;
    /// @notice The token1 min amount to get
    uint256 amount1Min;
    /// @notice Deadline for the transaction
    uint256 deadline;
}
