// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginLiquidity} from "../src/MarginLiquidity.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {MarginHookManager} from "../src/MarginHookManager.sol";
import {IMarginHookManager} from "../src/interfaces/IMarginHookManager.sol";
import {IMarginChecker} from "../src/interfaces/IMarginChecker.sol";

contract DeployHookScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    address manager = 0x7cAf3F63D481555361Ad3b17703Ac95f7a320D0c;
    address owner = 0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1;
    address mirrorTokenManager = 0xd1AD2d7D4E5C3Ea02476D70494130772f4449A2B;
    address marginLiquidity = 0x8c1ac7Ac3077fC19F6D1f6aBd01900b5F7C064B1;
    address marginChecker = 0xB927d6eCaC55F956bD7E1dD2Cd5De46185E0aE64;
    address marginOracle = 0xFC62570B59861F8E0DE767956FA521F8403F8b1c;
    address marginFees = 0x828eF24e1c4c877E16B393666Ea0355a0F8082B9;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        console2.log("mirrorTokenManager:", mirrorTokenManager);
        MarginPositionManager marginPositionManager = new MarginPositionManager(owner, IMarginChecker(marginChecker));
        console2.log("marginPositionManager:", address(marginPositionManager));
        bytes memory constructorArgs = abi.encode(owner, manager, mirrorTokenManager, marginLiquidity, marginFees);

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
        MarginHookManager(hookAddress).addPositionManager(address(marginPositionManager));
        MarginHookManager(hookAddress).setMarginOracle(marginOracle);
        console2.log("hookAddress:", hookAddress);
        MarginLiquidity(marginLiquidity).addHooks(hookAddress);
        MirrorTokenManager(mirrorTokenManager).addHooks(hookAddress);
        MarginRouter swapRouter = new MarginRouter(owner, IPoolManager(manager), IMarginHookManager(hookAddress));
        console2.log("swapRouter:", address(swapRouter));
        vm.stopBroadcast();
    }
}
