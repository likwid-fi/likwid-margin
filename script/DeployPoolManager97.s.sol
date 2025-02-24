// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {PoolManager} from "v4-core/PoolManager.sol";

contract DeployPoolManagerScript is Script {
    PoolManager poolManager;
    address owner = 0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        poolManager = new PoolManager(owner);
        console2.log("poolManager", address(poolManager));
        vm.stopBroadcast();
    }
}
