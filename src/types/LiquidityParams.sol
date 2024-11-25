// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

struct AddLiquidityParams {
    PoolId poolId;
    uint256 amount0;
    uint256 amount1;
    uint256 tickLower;
    uint256 tickUpper;
    address to;
    uint256 deadline;
}

struct RemoveLiquidityParams {
    PoolId poolId;
    uint256 liquidity;
    uint256 deadline;
}
