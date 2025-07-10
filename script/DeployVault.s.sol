// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {LikwidVault} from "likwid-v2-core/LikwidVault.sol";

contract DeployVaultScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        address owner = msg.sender;
        console2.log("owner:", owner);
        LikwidVault vault = new LikwidVault(owner);
        console2.log("vault:", address(vault));
        vm.stopBroadcast();
    }
}
