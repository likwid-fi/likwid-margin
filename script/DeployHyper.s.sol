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
        if (chainId == 998) {
            manager = 0x6a68019FE642B599af0cab3F35A3AE696b661be4;
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
        address owner = msg.sender;
        console2.log("owner:", owner);

        // mirrorTokenManager = new MirrorTokenManager(owner);
        mirrorTokenManager = MirrorTokenManager(0x9C20C8D337C9f566De112a3d6Ad1CB7a7372B732);
        console2.log("mirrorTokenManager:", address(mirrorTokenManager));

        // marginLiquidity = new MarginLiquidity(owner);
        marginLiquidity = MarginLiquidity(0x3299e02bbCf73aE21E4ac1D3eAE4d2ba50691d79);
        console2.log("marginLiquidity:", address(marginLiquidity));

        // marginChecker = new MarginChecker(owner);
        marginChecker = MarginChecker(0xD761CF412D29C437Ff7c3BF78A849f293f6B2246);
        console2.log("marginChecker:", address(marginChecker));

        // marginFees = new MarginFees(owner);
        marginFees = MarginFees(0xC1Fd1c0C50eD402bA4Cf7866Bb01A19E10d514D4);
        console2.log("marginFees:", address(marginFees));

        // lendingPoolManager = new LendingPoolManager(owner, IPoolManager(manager), mirrorTokenManager);
        lendingPoolManager = LendingPoolManager(0x168768C3eB60070D089F7C8fE7A2224d164C9AC6);
        console2.log("lendingPoolManager:", address(lendingPoolManager));

        // pairPoolManager =
        //     new PairPoolManager(owner, IPoolManager(manager), mirrorTokenManager, lendingPoolManager, marginLiquidity);
        pairPoolManager = PairPoolManager(0x0085dd2dA42ee35B22B90a5C3d3b092D80521A80);
        console2.log("pairPoolManager:", address(pairPoolManager));

        // marginPositionManager = new MarginPositionManager(owner, pairPoolManager, marginChecker);
        marginPositionManager = MarginPositionManager(0x4527dffC2f071420F9e56738bE105bCa53488D22);
        console2.log("marginPositionManager:", address(marginPositionManager));

        // poolStatusManager = new PoolStatusManager(
        //     owner,
        //     IPoolManager(manager),
        //     mirrorTokenManager,
        //     lendingPoolManager,
        //     marginLiquidity,
        //     pairPoolManager,
        //     marginFees
        // );
        poolStatusManager = PoolStatusManager(0xda54E290F2bdDD9b3df7e2f1f23Da8Dbd3e6e597);
        console2.log("poolStatusManager:", address(poolStatusManager));

        // MarginRouter swapRouter = new MarginRouter(owner, IPoolManager(manager), pairPoolManager);
        MarginRouter swapRouter = MarginRouter(0xF0144dB7b05f9BF51481BD1dE3d5C6c9A98a2C76);
        console2.log("swapRouter:", address(swapRouter));

        // bytes memory constructorArgs = abi.encode(owner, manager, address(pairPoolManager));
        // uint160 flags = uint160(
        //     Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        //         | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        // );

        // // Mine a salt that will produce a hook address with the correct flags
        // bytes memory creationCode = vm.getCode("MarginHook.sol:MarginHook");
        // (address hookAddress, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);

        // // Deploy the hook using CREATE2
        // bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);

        // address deployedHook;
        // assembly {
        //     deployedHook := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        // }
        address hookAddress = 0x63Fb5F58b18Feda95ed8dAe188e894845484E888;
        console2.log("hookAddress:", hookAddress);

        // verify proper create2 usage
        // require(deployedHook == hookAddress, "DeployScript: hook address mismatch");

        // config pairPoolManager
        // pairPoolManager.setHooks(MarginHook(hookAddress));
        // pairPoolManager.addPositionManager(address(marginPositionManager));
        // pairPoolManager.setStatusManager(poolStatusManager);
        // config lendingPoolManager
        // lendingPoolManager.setPairPoolManger(pairPoolManager);
        // config marginLiquidity
        // marginLiquidity.addPoolManager(address(pairPoolManager));
        // config mirrorTokenManager
        // mirrorTokenManager.addPoolManager(address(pairPoolManager));
        vm.stopBroadcast();
    }
}
