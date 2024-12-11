// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import {MarginOracle} from "../src/MarginOracle.sol";

contract DeployOracleScript is Script {
    MarginOracle marginOracle;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        marginOracle = new MarginOracle();
        console2.log("marginOracle", address(marginOracle));
        vm.stopBroadcast();
    }
}
