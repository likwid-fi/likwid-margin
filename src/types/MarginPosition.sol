// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

struct MarginPosition {
    uint256 nonce;
    address operator;
    address marginToken;
    uint256 marginSell;
    uint256 marginTotal;
    address borrowToken;
    uint256 borrowAmount;
    // (marginSell1 * liquidationLTV1 + marginTotal1) + ... +  (marginSelln * liquidationLTVn + marginTotaln)
    uint256 liquidationAmount;
}
