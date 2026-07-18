// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {LikwidVault} from "../src/core/LikwidVault.sol";
import {LikwidMarginCore} from "../src/core/LikwidMarginCore.sol";
import {LikwidLendPosition} from "../src/LikwidLendPosition.sol";
import {LikwidMarginPosition} from "../src/LikwidMarginPosition.sol";
import {LikwidPairPosition} from "../src/LikwidPairPosition.sol";
import {LikwidHelper} from "../test/utils/LikwidHelper.sol";

contract DeployAllScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    error ManagerNotExist();

    LikwidVault vault;
    LikwidMarginCore marginCore;
    LikwidLendPosition lendPosition;
    LikwidMarginPosition marginPosition;
    LikwidPairPosition pairPosition;
    LikwidHelper helper;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address owner = msg.sender;
        console.log("owner:", owner);
        address sender = msg.sender;
        console.log("sender:", sender);
        address protocolFeeController = msg.sender;

        vault = new LikwidVault(sender);
        console.log("vault:", address(vault));
        marginCore = new LikwidMarginCore(owner, vault);
        console.log("marginCore:", address(marginCore));
        lendPosition = new LikwidLendPosition(owner, vault);
        console.log("lendPosition:", address(lendPosition));
        marginPosition = new LikwidMarginPosition(owner, vault, marginCore);
        console.log("marginPosition:", address(marginPosition));
        pairPosition = new LikwidPairPosition(owner, vault);
        console.log("pairPosition:", address(pairPosition));

        vault.setMarginController(address(marginCore));
        vault.setProtocolFeeController(protocolFeeController);
        if (owner != sender) {
            vault.transferOwnership(owner);
        }

        helper = new LikwidHelper(owner, vault);
        console.log("helper:", address(helper));

        vm.stopBroadcast();
    }
}
