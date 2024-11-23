// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {MarginHookManager} from "../src/MarginHookManager.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {HookParams} from "../src/types/HookParams.sol";
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

contract MarginHookManagerTest is Test {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    uint160 public constant SQRT_RATIO_1_1 = 79228162514264337593543950336;
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 public constant ONE_BILLION = 10 ** 9;
    uint256 public constant YEAR_SECONDS = 365 * 24 * 3600;

    MarginHookManager hookManager;

    PoolKey key;
    PoolKey nativeKey;

    MockERC20 tokenB;
    address user;

    Currency currency0;
    Currency currency1;
    PoolManager manager;
    MirrorTokenManager mirrorTokenManager;
    MarginPositionManager marginPositionManager;
    MarginRouter swapRouter;

    function parameters() external view returns (Currency, Currency, IPoolManager) {
        return (currency0, currency1, manager);
    }

    function deployMintAndApprove2Currencies() internal {
        MockERC20 tokenA = new MockERC20("TESTA", "TESTA", 18);
        Currency currencyA = Currency.wrap(address(tokenA));

        tokenB = new MockERC20("TESTB", "TESTB", 18);
        Currency currencyB = Currency.wrap(address(tokenB));

        (currency0, currency1) = address(tokenA) < address(tokenB) ? (currencyA, currencyB) : (currencyB, currencyA);

        // Deploy the hook to an address with the correct flags
        uint160 flags =
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

        bytes memory constructorArgs = abi.encode(user, manager, mirrorTokenManager, marginPositionManager); //Add all the necessary constructor arguments from the hook
        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(MarginHookManager).creationCode, constructorArgs);

        hookManager = new MarginHookManager{salt: salt}(user, manager, mirrorTokenManager, marginPositionManager);
        assertEq(address(hookManager), hookAddress);
        tokenA.mint(address(this), 2 ** 255);
        tokenB.mint(address(this), 2 ** 255);

        tokenB.transfer(user, 10e18);

        tokenA.approve(address(hookManager), type(uint256).max);
        tokenB.approve(address(hookManager), type(uint256).max);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);

        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 1, hooks: hookManager});
        nativeKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: currency1,
            fee: 0,
            tickSpacing: 1,
            hooks: hookManager
        });

        hookManager.initialize(key);
        hookManager.initialize(nativeKey);
    }

    function setUp() public {
        user = vm.addr(2);
        (bool success,) = user.call{value: 10e18}("");
        assertTrue(success);
        manager = new PoolManager(user);
        mirrorTokenManager = new MirrorTokenManager(user);
        marginPositionManager = new MarginPositionManager(user);
        deployMintAndApprove2Currencies();
        vm.prank(user);
        marginPositionManager.setHook(address(hookManager));
        // swapRouter = new MarginRouter(user, manager, factory);
    }

    receive() external payable {}

    function test_hook_liquidity_v2() public {
        AddLiquidityParams memory params = AddLiquidityParams({
            currency0: currency0,
            currency1: currency1,
            amount0: 1e18,
            amount1: 1e18,
            tickLower: 50000,
            tickUpper: 50000,
            to: address(this),
            deadline: type(uint256).max
        });
        hookManager.addLiquidity(params);
        uint256 uPoolId = uint256(PoolId.unwrap(key.toId()));
        uint256 liquidity = hookManager.balanceOf(address(this), uPoolId);
        (uint256 _reserves0, uint256 _reserves1) =
            hookManager.getReserves(Currency.unwrap(currency0), Currency.unwrap(currency1));
        assertEq(_reserves0, _reserves1);
        console.log("_reserves0:%s,_reserves1:%s", _reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
            currency0: currency0,
            currency1: currency1,
            liquidity: liquidity / 2,
            deadline: type(uint256).max
        });
        hookManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = hookManager.balanceOf(address(this), uPoolId);
        assertEq(liquidityHalf, liquidity - liquidity / 2);

        params = AddLiquidityParams({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: currency1,
            amount0: 1e18,
            amount1: 1e18,
            tickLower: 50000,
            tickUpper: 50000,
            to: address(this),
            deadline: type(uint256).max
        });
        hookManager.addLiquidity{value: 1 ether}(params);
        uPoolId = uint256(PoolId.unwrap(nativeKey.toId()));
        liquidity = hookManager.balanceOf(address(this), uPoolId);
        (_reserves0, _reserves1) = hookManager.getReserves(address(0), Currency.unwrap(currency1));
        assertEq(_reserves0, _reserves1);
        console.log("_reserves0:%s,_reserves1:%s", _reserves0, _reserves1);
        removeParams = RemoveLiquidityParams({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: currency1,
            liquidity: liquidity / 2,
            deadline: type(uint256).max
        });
        hookManager.removeLiquidity(removeParams);
        liquidityHalf = hookManager.balanceOf(address(this), uPoolId);
        assertEq(liquidityHalf, liquidity - liquidity / 2);
    }

    function test_hook_swap_native() public {
        test_hook_liquidity_v2();
        uint256 amountIn = 0.01 ether;
        // swap
        address[] memory _path = new address[](2);
        _path[0] = address(0);
        _path[1] = address(tokenB);
        uint256 balance0 = manager.balanceOf(address(hookManager), 0);
        uint256 balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        console.log("before swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            path: _path,
            to: user,
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        swapRouter.exactInput{value: amountIn}(swapParams);
        console.log("swapRouter.balance:%s", manager.balanceOf(address(swapRouter), 0));
        console.log("after swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
    }
}
