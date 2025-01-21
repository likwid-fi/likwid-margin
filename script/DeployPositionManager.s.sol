// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import {MarginChecker} from "../src/MarginChecker.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {IMarginChecker} from "../src/interfaces/IMarginChecker.sol";
import {IMarginHookManager} from "../src/interfaces/IMarginHookManager.sol";

contract DeployPositionManagerScript is Script {
    MarginPositionManager marginPositionManager;
    address owner = 0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1;
    // address checker = 0x095a62236c2A1cc685a9B2be6658a6F3CB3fcaA3;
    MarginChecker marginChecker;
    address hookAddress = 0x59036D328EFF4dAb2E33E04a60A5D810Df90C888;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        marginChecker = new MarginChecker(owner);
        console2.log("marginChecker:", address(marginChecker));
        marginPositionManager = new MarginPositionManager(owner, IMarginChecker(address(marginChecker)));
        console2.log("marginPositionManager:", address(marginPositionManager));
        marginPositionManager.setHook(hookAddress);
        IMarginHookManager(hookAddress).addPositionManager(address(marginPositionManager));
        vm.stopBroadcast();
    }
}
