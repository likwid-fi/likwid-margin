// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

struct MarginPosition {
    address marginToken;
    // marginAmount1 + ... + marginAmountn
    uint256 marginAmount;
    // marginTotal1 + ... + marginTotaln
    uint256 marginTotal;
    address borrowToken;
    uint256 borrowAmount;
    // marginAmount * liquidationLTV + marginTotal
    // uint256 liquidationAmount;
    uint256 rateCumulativeLast;
}
