// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {MarginHook} from "../src/MarginHook.sol";
import {MarginHookFactoryMock} from "./mocks/MarginHookFactoryMock.sol";
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

import {HookMiner} from "./utils/HookMiner.sol";

contract MarginHookTest is Test {
    uint160 public constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    MarginHook hook;

    // PoolKey key;
    // PoolKey nativeKey;

    Currency currency0;
    Currency currency1;
    PoolManager manager;
    MarginHookFactoryMock factory;

    function parameters() external view returns (Currency, Currency, IPoolManager) {
        return (currency0, currency1, manager);
    }

    function deployMintAndApprove2Currencies() internal {
        MockERC20 tokenA = new MockERC20("TESTA", "TESTA", 18);
        Currency currencyA = Currency.wrap(address(tokenA));

        MockERC20 tokenB = new MockERC20("TESTB", "TESTB", 18);
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
        tokenA.mint(address(this), 2 ** 255);
        tokenB.mint(address(this), 2 ** 255);

        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);
    }

    function setUp() public {
        manager = new PoolManager(vm.addr(1));
        factory = new MarginHookFactoryMock(manager);

        deployMintAndApprove2Currencies();

        // key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 1, hooks: hook});
    }

    function test_hook_liquidity() public {
        // manager.initialize(key, SQRT_RATIO_1_1);
        hook.addLiquidity(1e18, 1e18);
        console.logAddress(address(hook));
        uint256 liquidity = hook.balanceOf(address(this));
        console.logUint(liquidity);
        (uint128 _reserves0, uint128 _reserves1) = hook.getReserves();
        console.logUint(_reserves0);
        console.logUint(_reserves1);
        hook.removeLiquidity(liquidity / 2);
        liquidity = hook.balanceOf(address(this));
        console.logUint(liquidity);
    }
}
