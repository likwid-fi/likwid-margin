// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct HookParams {
    bytes32 salt;
    string name;
    string symbol;
    address tokenA;
    address tokenB;
    uint24 fee;
    uint24 marginFee;
}
