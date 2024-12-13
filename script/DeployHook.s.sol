// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {IMarginHookManager} from "../src/interfaces/IMarginHookManager.sol";

contract DeployHookScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    address manager = payable(vm.envAddress("POOL_MANAGER_ADDR"));
    address owner = 0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1;
    address mirrorTokenManager = 0xc708fD75Ed6B3525E1FC1817959D414eEa84C628;
    address marginOracle = 0xaf1b2E78F24902210Ea0D66A4DE8489e342Bc735;
    address marginFees = 0x3B33E866eAfdb5e9676FAA9aC06EaB9299Bb4C59;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        console2.log("mirrorTokenManager", mirrorTokenManager);
        MarginPositionManager marginPositionManager = new MarginPositionManager(owner);
        console2.log("marginPositionManager", address(marginPositionManager));
        bytes memory constructorArgs = abi.encode(owner, manager, mirrorTokenManager, marginFees);

        // hook contracts must have specific flags encoded in the address
        // ------------------------------ //
        // --- Set your flags in .env --- //
        // ------------------------------ //
        uint160 flags =
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        // console2.logBytes32(bytes32(uint256(flags)));

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory creationCode = vm.getCode("MarginHookManager.sol:MarginHookManager");
        (address hookAddress, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);

        address deployedHook;
        assembly {
            deployedHook := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }

        // verify proper create2 usage
        require(deployedHook == hookAddress, "DeployScript: hook address mismatch");
        marginPositionManager.setHook(hookAddress);
        marginPositionManager.setMarginOracle(marginOracle);
        IMarginHookManager(hookAddress).addPositionManager(address(marginPositionManager));
        IMarginHookManager(hookAddress).setMarginOracle(marginOracle);
        console2.log("hookAddress", hookAddress);
        MarginRouter swapRouter = new MarginRouter(owner, IPoolManager(manager), IMarginHookManager(hookAddress));
        console2.log("swapRouter", address(swapRouter));
        vm.stopBroadcast();
    }
}
