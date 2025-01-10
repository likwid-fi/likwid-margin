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
import {IMarginHookManager} from "../src/interfaces/IMarginHookManager.sol";
import {IMarginChecker} from "../src/interfaces/IMarginChecker.sol";

contract DeployHookScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    address manager = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address owner = 0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1;
    address mirrorTokenManager = 0x59F8A8B628020030Ab1565526BA0a030751f4D18;
    address marginLiquidity = 0xd1fd8b2db8afB4594Fad5571218d367CFec1A940;
    address marginChecker = 0x095a62236c2A1cc685a9B2be6658a6F3CB3fcaA3;
    address marginOracle = 0xf3220c5c4e95B025511Ceae99bcD645DbA46D895;
    address marginFees = 0x73591f031219B91bCc3e0AB72C1EE3c0612F25B2;

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
        marginPositionManager.setMarginOracle(marginOracle);
        IMarginHookManager(hookAddress).addPositionManager(address(marginPositionManager));
        IMarginHookManager(hookAddress).setMarginOracle(marginOracle);
        console2.log("hookAddress:", hookAddress);
        MarginLiquidity(marginLiquidity).addHooks(hookAddress);
        MarginRouter swapRouter = new MarginRouter(owner, IPoolManager(manager), IMarginHookManager(hookAddress));
        console2.log("swapRouter:", address(swapRouter));
        vm.stopBroadcast();
    }
}
