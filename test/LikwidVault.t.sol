// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {LikwidVault} from "../src/LikwidVault.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IUnlockCallback} from "../src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";
import {Pool} from "../src/libraries/Pool.sol";
import {BalanceDelta, toBalanceDelta} from "../src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract LikwidVaultTest is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    LikwidVault vault;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey private poolKey;

    function setUp() public {
        skip(1); // Skip the first block to ensure block.timestamp is not zero
        vault = new LikwidVault(address(this));
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bytes4 selector, bytes memory params) = abi.decode(data, (bytes4, bytes));

        if (selector == this.modifyLiquidity_callback.selector) {
            (PoolKey memory key, IVault.ModifyLiquidityParams memory mlParams) =
                abi.decode(params, (PoolKey, IVault.ModifyLiquidityParams));

            BalanceDelta delta = vault.modifyLiquidity(key, mlParams, "");

            // Settle the balances
            if (delta.amount0() < 0) {
                vault.sync(key.currency0);
                token0.transfer(address(vault), uint256(-int256(delta.amount0())));
                vault.settle();
            }

            if (delta.amount1() < 0) {
                vault.sync(key.currency1);
                token1.transfer(address(vault), uint256(-int256(delta.amount1())));
                vault.settle();
            }
        }
        return "";
    }

    function modifyLiquidity_callback(PoolKey memory, IVault.ModifyLiquidityParams memory) external pure {}

    function testModifyLiquidity_Add_Callback() public {
        // 1. Setup
        uint256 amount0ToAdd = 1e18;
        uint256 amount1ToAdd = 4e18;
        PoolKey memory key = PoolKey({currency0: currency0, currency1: currency1, fee: 25});
        vault.initialize(key);
        token0.mint(address(this), amount0ToAdd);
        token1.mint(address(this), amount1ToAdd);

        IVault.ModifyLiquidityParams memory mlParams = IVault.ModifyLiquidityParams({
            amount0: amount0ToAdd,
            amount1: amount1ToAdd,
            liquidityDelta: 0,
            salt: bytes32(0)
        });

        // 2. Action
        bytes memory inner_params = abi.encode(key, mlParams);
        bytes memory data = abi.encode(this.modifyLiquidity_callback.selector, inner_params);
        vault.unlock(data);

        // 3. Assertions
        assertEq(token0.balanceOf(address(this)), 0, "User token0 balance should be 0");
        assertEq(token1.balanceOf(address(this)), 0, "User token1 balance should be 0");
        assertEq(token0.balanceOf(address(vault)), amount0ToAdd, "Vault token0 balance should be amount added");
        assertEq(token1.balanceOf(address(vault)), amount1ToAdd, "Vault token1 balance should be amount added");
    }

    function testInitializeRevertsIfCurrenciesOutOfOrder() public {
        PoolKey memory key = PoolKey({currency0: currency1, currency1: currency0, fee: 25});

        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.CurrenciesOutOfOrderOrEqual.selector,
                Currency.unwrap(key.currency0),
                Currency.unwrap(key.currency1)
            )
        );
        vault.initialize(key);
    }

    function testInitializeRevertsIfCurrenciesEqual() public {
        PoolKey memory key = PoolKey({currency0: currency0, currency1: currency0, fee: 25});

        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.CurrenciesOutOfOrderOrEqual.selector,
                Currency.unwrap(key.currency0),
                Currency.unwrap(key.currency1)
            )
        );
        vault.initialize(key);
    }

    function testInitializeRevertsIfPoolAlreadyInitialized() public {
        PoolKey memory key = PoolKey({currency0: currency0, currency1: currency1, fee: 25});
        vault.initialize(key);
        vm.expectRevert(abi.encodeWithSelector(Pool.PoolAlreadyInitialized.selector));
        vault.initialize(key);
    }
}
