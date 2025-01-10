// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {IMarginChecker} from "../src/interfaces/IMarginChecker.sol";
import {IMarginHookManager} from "../src/interfaces/IMarginHookManager.sol";

contract DeployPositionManagerScript is Script {
    MarginPositionManager marginPositionManager;
    address owner = 0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1;
    address checker = 0x4ADb006B9385340EDC67df6E110416CB3fB7dbc5;
    address hookAddress = 0xF184EB360ad249048e248630f3C6217997278888;
    address marginOracle = 0x93EE4A9C8Ea86A6C90C6bc1B7B1e9D1BfA2d77b5;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        marginPositionManager = new MarginPositionManager(owner, IMarginChecker(checker));
        console2.log("marginPositionManager", address(marginPositionManager));
        marginPositionManager.setHook(hookAddress);
        marginPositionManager.setMarginOracle(marginOracle);
        IMarginHookManager(hookAddress).addPositionManager(address(marginPositionManager));
        vm.stopBroadcast();
    }
}
