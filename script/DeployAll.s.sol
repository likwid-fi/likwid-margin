// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {IPoolManager} from "likwid-v2-core/interfaces/IPoolManager.sol";
import {Hooks} from "likwid-v2-core/libraries/Hooks.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {MarginHook} from "../src/MarginHook.sol";
import {PairPoolManager} from "../src/PairPoolManager.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {LendingPoolManager} from "../src/LendingPoolManager.sol";
import {MarginLiquidity} from "../src/MarginLiquidity.sol";
import {MarginChecker} from "../src/MarginChecker.sol";
import {MarginFees} from "../src/MarginFees.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {PoolStatusManager} from "../src/PoolStatusManager.sol";

contract DeployAllScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    address owner = 0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1;
    MirrorTokenManager mirrorTokenManager;
    LendingPoolManager lendingPoolManager;
    MarginLiquidity marginLiquidity;
    MarginChecker marginChecker;
    MarginFees marginFees;
    PairPoolManager pairPoolManager;
    MarginPositionManager marginPositionManager;
    PoolStatusManager poolStatusManager;

    error ManagerNotExist();

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

        mirrorTokenManager = new MirrorTokenManager(owner);
        console2.log("mirrorTokenManager:", address(mirrorTokenManager));

        marginLiquidity = new MarginLiquidity(owner);
        console2.log("marginLiquidity:", address(marginLiquidity));

        marginChecker = new MarginChecker(owner);
        console2.log("marginChecker:", address(marginChecker));

        marginFees = new MarginFees(owner);
        console2.log("marginFees:", address(marginFees));

        lendingPoolManager = new LendingPoolManager(owner, IPoolManager(manager), mirrorTokenManager);
        console2.log("lendingPoolManager:", address(lendingPoolManager));

        pairPoolManager =
            new PairPoolManager(owner, IPoolManager(manager), mirrorTokenManager, lendingPoolManager, marginLiquidity);
        console2.log("pairPoolManager:", address(pairPoolManager));

        marginPositionManager = new MarginPositionManager(owner, pairPoolManager, marginChecker);
        console2.log("marginPositionManager:", address(marginPositionManager));

        poolStatusManager = new PoolStatusManager(
            owner,
            IPoolManager(manager),
            mirrorTokenManager,
            lendingPoolManager,
            marginLiquidity,
            pairPoolManager,
            marginFees
        );
        console2.log("poolStatusManager:", address(poolStatusManager));

        MarginRouter swapRouter = new MarginRouter(owner, IPoolManager(manager), pairPoolManager);
        console2.log("swapRouter:", address(swapRouter));

        bytes memory constructorArgs = abi.encode(owner, manager, address(pairPoolManager));
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory creationCode = vm.getCode("MarginHook.sol:MarginHook");
        (address hookAddress, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);

        address deployedHook;
        assembly {
            deployedHook := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }

        // verify proper create2 usage
        require(deployedHook == hookAddress, "DeployScript: hook address mismatch");
        console2.log("hookAddress:", hookAddress);

        // config pairPoolManager
        pairPoolManager.addPositionManager(address(marginPositionManager));
        pairPoolManager.setHooks(MarginHook(hookAddress));
        pairPoolManager.setStatusManager(poolStatusManager);
        // config lendingPoolManager
        lendingPoolManager.setPairPoolManger(pairPoolManager);
        // config marginLiquidity
        marginLiquidity.addPoolManager(address(pairPoolManager));
        // config mirrorTokenManager
        mirrorTokenManager.addPoolManager(address(pairPoolManager));
        vm.stopBroadcast();
    }
}
