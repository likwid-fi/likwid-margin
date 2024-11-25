// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";

contract DeployHookScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    address manager = payable(vm.envAddress("POOL_MANAGER_ADDR"));
    address owner = 0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1;

    function setUp() public {}

    function run() public {
        MirrorTokenManager mirrorTokenManager = new MirrorTokenManager(owner);
        MarginPositionManager marginPositionManager = new MarginPositionManager(owner);
        bytes memory constructorArgs =
            abi.encode(owner, manager, address(mirrorTokenManager), address(marginPositionManager));

        // hook contracts must have specific flags encoded in the address
        // ------------------------------ //
        // --- Set your flags in .env --- //
        // ------------------------------ //
        uint160 flags =
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        console2.logBytes32(bytes32(uint256(flags)));

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory creationCode = vm.getCode(vm.envString("MarginHookManager.sol:MarginHookManager"));
        (address hookAddress, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        vm.startBroadcast();
        address deployedHook;
        assembly {
            deployedHook := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        vm.stopBroadcast();

        // verify proper create2 usage
        require(deployedHook == hookAddress, "DeployScript: hook address mismatch");
    }
}
