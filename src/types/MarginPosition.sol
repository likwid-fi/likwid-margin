// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

struct MarginPosition {
    uint256 nonce;
    address operator;
    uint256 marginSell;
    uint24 initialLTV;
    uint24 liquidationLTV;
    uint256 totalAmount;
    uint256 borrowAmount;
}
