// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {MarginHook} from "../src/MarginHook.sol";
import {MarginHookFactory} from "../src/MarginHookFactory.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
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
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

import {HookMiner} from "./utils/HookMiner.sol";

contract MarginHookTest is Test {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    uint160 public constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    MarginHook hook;
    MarginHook nativeHook;

    // PoolKey key;
    // PoolKey nativeKey;

    MockERC20 tokenB;
    address user;

    Currency currency0;
    Currency currency1;
    PoolManager manager;
    MarginHookFactory factory;
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

        bytes memory constructorArgs = abi.encode(manager, "TEST HOOK", "TH"); //Add all the necessary constructor arguments from the hook
        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(factory), flags, type(MarginHook).creationCode, constructorArgs);
        IHooks createHookAddress = factory.createHook(salt, "TEST HOOK", "TH", address(tokenA), address(tokenB));
        // deployCodeTo("MarginHook.sol:MarginHook", constructorArgs, hookAddress);
        assertEq(address(createHookAddress), hookAddress);
        console.log("createHookAddress:%s, hookAddress:%s", address(createHookAddress), hookAddress);
        hook = MarginHook(hookAddress);

        constructorArgs = abi.encode(manager, "TEST NATIVE", "TH");
        (hookAddress, salt) = HookMiner.find(address(factory), flags, type(MarginHook).creationCode, constructorArgs);
        createHookAddress = factory.createHook(salt, "TEST NATIVE", "TH", address(0), address(tokenB));
        assertEq(address(createHookAddress), hookAddress);
        console.log("native createHookAddress:%s, hookAddress:%s", address(createHookAddress), hookAddress);
        nativeHook = MarginHook(hookAddress);

        tokenA.mint(address(this), 2 ** 255);
        tokenB.mint(address(this), 2 ** 255);

        tokenB.transfer(user, 10e18);

        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);
        tokenB.approve(address(nativeHook), type(uint256).max);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
    }

    function setUp() public {
        user = vm.addr(2);
        (bool success,) = user.call{value: 10e18}("");
        assertTrue(success);
        manager = new PoolManager(vm.addr(1));
        mirrorTokenManager = new MirrorTokenManager(vm.addr(1));
        marginPositionManager = new MarginPositionManager(vm.addr(1));
        factory = new MarginHookFactory(manager, mirrorTokenManager, marginPositionManager);

        deployMintAndApprove2Currencies();

        swapRouter = new MarginRouter(manager, nativeHook);
    }

    function test_hook_liquidity() public {
        hook.addLiquidity(1e18, 1e18);
        uint256 liquidity = hook.balanceOf(address(this));
        (uint256 _reserves0, uint256 _reserves1) = hook.getReserves();
        assertEq(_reserves0, _reserves1);
        hook.removeLiquidity(liquidity / 2);
        uint256 liquidityHelf = hook.balanceOf(address(this));
        assertEq(liquidityHelf, liquidity - liquidity / 2);
    }

    function test_hook_native_liquidity() public {
        // address(this) could not receive native.
        vm.startPrank(user);
        tokenB.approve(address(nativeHook), 1e18);
        uint256 balanceBBefore = tokenB.balanceOf(user);
        nativeHook.addLiquidity{value: 1e18}(1e18, 1e18);
        uint256 balanceBAfter = tokenB.balanceOf(user);
        assertEq(balanceBBefore - balanceBAfter, 1e18);
        uint256 liquidity = nativeHook.balanceOf(user);
        console.log(
            "addLiquidity user.balance:%s,liquidity:%s,this.liquidity:%s",
            user.balance,
            liquidity,
            nativeHook.balanceOf(address(this))
        );
        (uint256 _reserves0, uint256 _reserves1) = nativeHook.getReserves();
        assertEq(_reserves0, _reserves1);
        nativeHook.removeLiquidity(liquidity / 2);
        uint256 liquidityHelf = nativeHook.balanceOf(user);
        assertEq(liquidityHelf, liquidity - liquidity / 2);
        vm.stopPrank();
    }

    function _getAmountOut(bool zeroForOne, uint256 amountIn, uint256 reserves0, uint256 reserves1)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "MarginHook: INSUFFICIENT_INPUT_AMOUNT");

        (uint256 reservesIn, uint256 reservesOut) = zeroForOne ? (reserves0, reserves1) : (reserves1, reserves0);
        require(reserves0 > 0 && reserves1 > 0, "MarginHook: INSUFFICIENT_LIQUIDITY");

        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reservesOut;
        uint256 denominator = (reservesIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function test_hook_swap() public {
        vm.startPrank(user);
        tokenB.approve(address(nativeHook), 1e18);
        nativeHook.addLiquidity{value: 1e18}(1e18, 1e18);
        (uint256 _reserves0, uint256 _reserves1) = nativeHook.getReserves();
        assertEq(_reserves0, _reserves1);
        uint256 amountOut = _getAmountOut(true, 100, _reserves0, _reserves1);
        console.log("_reserves0:%s, _reserves1:%s, _reserves1:%s", _reserves0, _reserves1, amountOut);
        // swap
        address[] memory _path = new address[](2);
        _path[0] = address(0);
        _path[1] = address(tokenB);
        uint256 balance1 = manager.balanceOf(address(nativeHook), CurrencyLibrary.toId(currency1));
        console.log("before swap user.balance:%s,tokenB:%s,balance1:%s", user.balance, tokenB.balanceOf(user), balance1);
        swapRouter.swapExactETHForTokens{value: 100}(_path, user, 0, type(uint256).max);
        console.log("after swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        vm.stopPrank();
    }
}
