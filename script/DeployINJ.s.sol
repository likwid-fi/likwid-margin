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
        mirrorTokenManager = MirrorTokenManager(0xEfF75DFAd68d6bBe8eA9E7f68ad988baBeaDe89A);
        console2.log("mirrorTokenManager:", address(mirrorTokenManager));

        // marginLiquidity = new MarginLiquidity(owner);
        marginLiquidity = MarginLiquidity(0x68d11fBa74CD35F3C063905fF1e659Efb16E1928);
        console2.log("marginLiquidity:", address(marginLiquidity));

        // marginChecker = new MarginChecker(owner);
        marginChecker = MarginChecker(0xd6641A7503017b47CAB166AF7eFE8581d8eDc636);
        console2.log("marginChecker:", address(marginChecker));

        // marginFees = new MarginFees(owner);
        marginFees = MarginFees(0x6eEb455aE85F4165FD8d31Fa3A24A6fC60492Ce9);
        console2.log("marginFees:", address(marginFees));

        // lendingPoolManager = new LendingPoolManager(owner, IPoolManager(manager), mirrorTokenManager);
        lendingPoolManager = LendingPoolManager(0x8cc183F3018990D42C2075Bd50aFBB8407D8BFed);
        console2.log("lendingPoolManager:", address(lendingPoolManager));

        // pairPoolManager =
        //     new PairPoolManager(owner, IPoolManager(manager), mirrorTokenManager, lendingPoolManager, marginLiquidity);
        pairPoolManager = PairPoolManager(0xd19a0cF912202cE28eb791f3dbD84048C3FE5EBa);
        console2.log("pairPoolManager:", address(pairPoolManager));

        // marginPositionManager = new MarginPositionManager(owner, pairPoolManager, marginChecker);
        marginPositionManager = MarginPositionManager(0x9C20C8D337C9f566De112a3d6Ad1CB7a7372B732);
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
        poolStatusManager = PoolStatusManager(0x3299e02bbCf73aE21E4ac1D3eAE4d2ba50691d79);
        console2.log("poolStatusManager:", address(poolStatusManager));

        // MarginRouter swapRouter = new MarginRouter(owner, IPoolManager(manager), pairPoolManager);
        MarginRouter swapRouter = MarginRouter(0xD761CF412D29C437Ff7c3BF78A849f293f6B2246);
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

        // // verify proper create2 usage
        // require(deployedHook == hookAddress, "DeployScript: hook address mismatch");
        address hookAddress = 0x5884c246Ee6125760fe59e83C9B68318081de888;
        console2.log("hookAddress:", hookAddress);

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
