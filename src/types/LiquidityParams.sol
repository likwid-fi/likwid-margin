// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";

struct LiquidityParams {
    uint256 amount0;
    uint256 amount1;
    uint256 tickLower;
    uint256 tickUpper;
    address recipient;
    uint256 deadline;
}

struct AddLiquidityParams {
    Currency currency0;
    Currency currency1;
    uint256 amount0;
    uint256 amount1;
    uint256 tickLower;
    uint256 tickUpper;
    address to;
    uint256 deadline;
}

struct RemoveLiquidityParams {
    Currency currency0;
    Currency currency1;
    uint256 liquidity;
    uint256 deadline;
}
