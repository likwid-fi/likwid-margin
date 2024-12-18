// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {MarginFees} from "../src/MarginFees.sol";
import {MarginHookManager} from "../src/MarginHookManager.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {HookParams} from "../src/types/HookParams.sol";
import {HookStatus} from "../src/types/HookStatus.sol";
import {RateStatus} from "../src/types/RateStatus.sol";
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

contract MarginFeesTest is Test {
    MarginFees marginFees;
    uint256 public constant ONE_MILLION = 10 ** 6;

    function setUp() public {
        marginFees = new MarginFees(address(this));
    }

    function test_get_borrow_rate() public view {
        uint256 realReserve = 0.6 ether;
        uint256 mirrorReserve = 0;
        uint256 rate = marginFees.getBorrowRateByReserves(realReserve, mirrorReserve);
        (uint24 rateBase, uint24 useMiddleLevel, uint24 useHighLevel, uint24 mLow, uint24 mMiddle, uint24 mHigh) =
            marginFees.rateStatus();
        assertEq(rate, uint256(rateBase));
        mirrorReserve = 0.4 ether;
        rate = marginFees.getBorrowRateByReserves(realReserve, mirrorReserve);
        assertEq(rate, rateBase + useMiddleLevel * mLow);
        realReserve = 0;
        rate = marginFees.getBorrowRateByReserves(realReserve, mirrorReserve);
        assertEq(
            rate,
            rateBase + uint256(useMiddleLevel) * mLow + uint256(useHighLevel - useMiddleLevel) * mMiddle
                + (ONE_MILLION - useHighLevel) * mHigh
        );
        uint256 test = UINT256_MAX;
        uint24 test24 = uint24(test);
        assertEq(test24, type(uint24).max);
    }
}
