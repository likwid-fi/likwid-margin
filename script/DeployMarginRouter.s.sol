// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {LikwidMarginRouter} from "../test/utils/LikwidMarginRouter.sol";

contract DeployMarginRouterScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    address constant VAULT = address(0x065d449ec9D139740343990B7E1CF05fA830e4Ba);

    error ControllerNotSet();

    LikwidMarginRouter router;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address sender = msg.sender;
        console.log("sender:", sender);

        IVault vault = IVault(VAULT);
        console.log("vault:", address(vault));

        // The router caches `manager = vault.marginController()` as an immutable, so the vault must already
        // have its margin controller set; deploy this AFTER the margin position manager is wired up.
        address controller = vault.marginController();
        console.log("marginController:", controller);
        if (controller == address(0)) revert ControllerNotSet();

        router = new LikwidMarginRouter(vault);
        console.log("marginRouter:", address(router));

        vm.stopBroadcast();
    }
}
