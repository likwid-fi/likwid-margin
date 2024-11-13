// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

struct MintParams {
    address token0; //组成池子的token0
    address token1; //组成池子的token1
    uint24 fee; //组成池子的费率
    int24 tickLower; //价格区间的下限对应的tick序号
    int24 tickUpper; //价格区间的上限对应的tick序号
    uint256 amount0Desired; //要添加作为流动性的token0数量（预估值）
    uint256 amount1Desired; //要添加作为流动性的token1数量（预估值）
    uint256 amount0Min; //作为流动性的token0最小数量
    uint256 amount1Min; //作为流动性的tokne1最小数量
    address recipient; //接收头寸的地址
    uint256 deadline; //过期时间
}
