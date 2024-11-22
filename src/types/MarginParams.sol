// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

struct MarginParams {
    address marginToken;
    address borrowToken;
    uint24 leverage;
    uint256 marginAmount;
    uint256 marginTotal;
    uint256 borrowAmount;
    uint256 borrowMinAmount;
    address recipient;
    uint256 deadline;
}

struct RepayParams {
    address marginToken;
    address borrowToken;
    address payer;
    uint256 borrowAmount;
    uint256 repayAmount;
    uint256 deadline;
}

struct LiquidateParams {
    address marginToken;
    address borrowToken;
    uint256 releaseAmount;
}
