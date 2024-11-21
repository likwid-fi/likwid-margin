// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

struct LiquidityParams {
    uint256 amount0;
    uint256 amount1;
    uint256 tickLower;
    uint256 tickUpper;
    address recipient;
    uint256 deadline;
}
