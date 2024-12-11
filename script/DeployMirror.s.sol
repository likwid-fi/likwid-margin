// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";

contract DeployMirrorScript is Script {
    MirrorTokenManager mirrorTokenManager;
    address owner = 0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        mirrorTokenManager = new MirrorTokenManager(owner);
        console2.log("mirrorTokenManager", address(mirrorTokenManager));
        vm.stopBroadcast();
    }
}
