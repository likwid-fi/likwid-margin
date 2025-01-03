// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import {MarginOracle} from "../src/MarginOracle.sol";
import {MarginLiquidity} from "../src/MarginLiquidity.sol";

contract TestsScript is Script {
    address marginLiquidity = 0xDD0AebD45cd5c339e366fB7DEF71143C78585a6f;
    address hookAddress = 0x41e1C0cd59d538893dF9960373330585Dc3e8888;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        // MarginLiquidity(marginLiquidity).addHooks(hookAddress);
        vm.stopBroadcast();
    }
}
