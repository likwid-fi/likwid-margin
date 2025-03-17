// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {PairPoolManager} from "../src/PairPoolManager.sol";
import {CurrencyPoolLibrary} from "../src/libraries/CurrencyPoolLibrary.sol";
import {TruncatedOracle} from "../src/libraries/TruncatedOracle.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {PoolStatus} from "../src/types/PoolStatus.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition} from "../src/types/MarginPosition.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "../src/types/LiquidityParams.sol";
// Solmate
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
// Forge
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
// V4
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

import {HookMiner} from "./utils/HookMiner.sol";
import {DeployHelper} from "./utils/DeployHelper.sol";

contract MarginOracleTest is DeployHelper {
    using CurrencyPoolLibrary for *;

    function setUp() public {
        deployHookAndRouter();
        initPoolLiquidity();
    }

    function testObserve() public {
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 1000;
        vm.expectPartialRevert(TruncatedOracle.TargetPredatesOldestObservation.selector);
        marginOracle.observe(pairPoolManager, nativeKey.toId(), secondsAgos);
    }
}
