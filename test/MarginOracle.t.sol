// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {MarginHookManager} from "../src/MarginHookManager.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {HookStatus} from "../src/types/HookStatus.sol";
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
import {EIP20NonStandardThrowHarness} from "./mocks/EIP20NonStandardThrowHarness.sol";

contract MarginOracleTest is Test {}
