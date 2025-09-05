// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {LikwidVault} from "../src/LikwidVault.sol";

contract DeployAllScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    error ManagerNotExist();

    LikwidVault vault;

    function setUp() public {}

    function _getManager(uint256 chainId) internal pure returns (address manager) {
        if (chainId == 11155111) {
            manager = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
        } else if (chainId == 97) {
            manager = 0x7cAf3F63D481555361Ad3b17703Ac95f7a320D0c;
        } else if (chainId == 10143) {
            manager = 0x029C5eC244a73cC54c0731c2F3184bCA6C60eF2D;
        } else if (chainId == 130) {
            manager = 0x1F98400000000000000000000000000000000004;
        } else if (chainId == 1439) {
            manager = 0x029C5eC244a73cC54c0731c2F3184bCA6C60eF2D;
        } else if (chainId == 998) {
            manager = 0x6a68019FE642B599af0cab3F35A3AE696b661be4;
        }
    }

    function run() public {
        vm.startBroadcast();
        vault = new LikwidVault(msg.sender);
        console.log("Vault deployed at:", address(vault));
        vm.stopBroadcast();
    }
}
