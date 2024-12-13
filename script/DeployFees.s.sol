// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import {MarginFees} from "../src/MarginFees.sol";

contract DeployFeesScript is Script {
    MarginFees marginFees;
    address owner = 0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        marginFees = new MarginFees(owner);
        console2.log("marginFees", address(marginFees));
        vm.stopBroadcast();
    }
}
