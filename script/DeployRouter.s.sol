// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {IPairPoolManager} from "../src/interfaces/IPairPoolManager.sol";

contract DeployAllScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    error ManagerNotExist();

    function setUp() public {}

    function _getManager(uint256 chainId) internal pure returns (address manager) {
        if (chainId == 11155111) {
            manager = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
        } else if (chainId == 97) {
            manager = 0x7cAf3F63D481555361Ad3b17703Ac95f7a320D0c;
        } else if (chainId == 56) {
            manager = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;
        }
    }

    function run(uint256 chainId) public {
        vm.startBroadcast();
        console.log(chainId);
        address manager = _getManager(chainId);
        if (manager == address(0)) {
            revert ManagerNotExist();
        }
        console2.log("poolManager:", manager);

        address owner = 0x1c01Da3d1FE1990C617fE47FF662265930c359F9;
        address pairPoolManager = 0x4C136fc2DCE4CaBDd9a5BABFF48BA06bEfA356DC;

        MarginRouter swapRouter = new MarginRouter(owner, IPoolManager(manager), IPairPoolManager(pairPoolManager));
        console2.log("swapRouter:", address(swapRouter));

        vm.stopBroadcast();
    }
}
