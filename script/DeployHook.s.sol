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
    address manager = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address owner = 0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1;
    address mirrorTokenManager = 0x80D114409057Da5314ac0D322dd5c6190ECbEE22;
    address marginLiquidity = 0xc69a7DE04633809d0C08B8793788bB2888A83c02;
    address marginChecker = 0xcE2822eDCe6b68CD7c9396Dd0f90e9B6b2e6a77E;
    address marginOracle = 0x045305CC43e04A03baCdB38FaF4582255a774AA3;
    address marginFees = 0xE3AD2e063c9702De5f7147b359E2d43499a7b9E9;

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
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
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
