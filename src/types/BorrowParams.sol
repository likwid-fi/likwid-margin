// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

struct BorrowParams {
    address marginToken;
    address borrowToken;
    uint24 leverage;
    uint256 marginSell;
    uint256 marginTotal;
    uint256 borrowAmount;
    uint256 borrowMinAmount;
    uint256 deadline;
}
