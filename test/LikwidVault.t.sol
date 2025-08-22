// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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
        } else if (selector == this.swap_callback.selector) {
            (PoolKey memory key, IVault.SwapParams memory swapParams) = 
                abi.decode(params, (PoolKey, IVault.SwapParams));

            BalanceDelta delta = vault.swap(key, swapParams, "");

            // Settle the balances
            if (delta.amount0() < 0) {
                vault.sync(key.currency0);
                token0.transfer(address(vault), uint256(-int256(delta.amount0())));
                vault.settle();
            } else if (delta.amount0() > 0) {
                vault.take(key.currency0, address(this), uint256(int256(delta.amount0())));
            }

            if (delta.amount1() < 0) {
                vault.sync(key.currency1);
                token1.transfer(address(vault), uint256(-int256(delta.amount1())));
                vault.settle();
            } else if (delta.amount1() > 0) {
                vault.take(key.currency1, address(this), uint256(int256(delta.amount1())));
            }
        }
        return "";
    }

    function modifyLiquidity_callback(PoolKey memory, IVault.ModifyLiquidityParams memory) external pure {}

    function swap_callback(PoolKey memory, IVault.SwapParams memory) external pure {}

    function testSwapExactInputToken0ForToken1() public {
        // 1. Setup
        uint256 initialLiquidity0 = 10e18;
        uint256 initialLiquidity1 = 10e18;
        uint256 amountToSwap = 1e18;
        uint24 fee = 3000; // 0.3%
        PoolKey memory key = PoolKey({currency0: currency0, currency1: currency1, fee: fee});
        vault.initialize(key);

        // Add liquidity
        token0.mint(address(this), initialLiquidity0);
        token1.mint(address(this), initialLiquidity1);
        IVault.ModifyLiquidityParams memory mlParams = IVault.ModifyLiquidityParams({
            amount0: initialLiquidity0,
            amount1: initialLiquidity1,
            liquidityDelta: 0,
            salt: bytes32(0)
        });
        bytes memory inner_params_liq = abi.encode(key, mlParams);
        bytes memory data_liq = abi.encode(this.modifyLiquidity_callback.selector, inner_params_liq);
        vault.unlock(data_liq);

        // Mint tokens for swap
        token0.mint(address(this), amountToSwap);

        // 2. Action
        IVault.SwapParams memory swapParams = IVault.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountToSwap)
        });

        // Calculate expected amount out
        uint256 amountInAfterFee = amountToSwap - (amountToSwap * fee / 1_000_000);
        uint256 expectedAmountOut = (amountInAfterFee * initialLiquidity1) / (initialLiquidity0 + amountInAfterFee);

        bytes memory inner_params_swap = abi.encode(key, swapParams);
        bytes memory data_swap = abi.encode(this.swap_callback.selector, inner_params_swap);
        
        vault.unlock(data_swap);

        // 3. Assertions
        assertEq(token0.balanceOf(address(this)), 0, "User token0 balance should be 0");
        assertEq(token1.balanceOf(address(this)), expectedAmountOut, "User token1 balance should be amount out");
        assertEq(token0.balanceOf(address(vault)), initialLiquidity0 + amountToSwap, "Vault token0 balance");
        assertEq(token1.balanceOf(address(vault)), initialLiquidity1 - expectedAmountOut, "Vault token1 balance");
        
        // Protocol fee is 0 by default
        assertEq(vault.protocolFeesAccrued(currency0), 0, "Protocol fee for token0 should be 0");
        assertEq(vault.protocolFeesAccrued(currency1), 0, "Protocol fee for token1 should be 0");
    }

    function testSwapExactOutputToken1ForToken0() public {
        // 1. Setup
        uint256 initialLiquidity0 = 10e18;
        uint256 initialLiquidity1 = 10e18;
        uint256 amountToReceive = 5e17; // 0.5 token0
        uint24 fee = 3000; // 0.3%
        PoolKey memory key = PoolKey({currency0: currency0, currency1: currency1, fee: fee});
        vault.initialize(key);

        // Add liquidity
        token0.mint(address(this), initialLiquidity0);
        token1.mint(address(this), initialLiquidity1);
        IVault.ModifyLiquidityParams memory mlParams = IVault.ModifyLiquidityParams({
            amount0: initialLiquidity0,
            amount1: initialLiquidity1,
            liquidityDelta: 0,
            salt: bytes32(0)
        });
        bytes memory inner_params_liq = abi.encode(key, mlParams);
        bytes memory data_liq = abi.encode(this.modifyLiquidity_callback.selector, inner_params_liq);
        vault.unlock(data_liq);

        // Calculate expected amount in
        uint256 numerator = initialLiquidity1 * amountToReceive;
        uint256 denominator = initialLiquidity0 - amountToReceive;
        uint256 amountInWithoutFee = (numerator / denominator) + 1;
        // Reverse fee calculation: amountIn = amountInWithoutFee * 1e6 / (1e6 - fee)
        uint256 expectedAmountIn = (amountInWithoutFee * 1_000_000) / (1_000_000 - fee);

        // Mint tokens for swap
        token1.mint(address(this), expectedAmountIn);

        // 2. Action
        IVault.SwapParams memory swapParams = IVault.SwapParams({
            zeroForOne: false, // we want token0, so we swap token1 for token0
            amountSpecified: int256(amountToReceive)
        });

        bytes memory inner_params_swap = abi.encode(key, swapParams);
        bytes memory data_swap = abi.encode(this.swap_callback.selector, inner_params_swap);
        
        vault.unlock(data_swap);

        // 3. Assertions
        assertEq(token1.balanceOf(address(this)), 0, "User token1 balance should be 0");
        assertEq(token0.balanceOf(address(this)), amountToReceive, "User token0 balance should be amount received");
        assertEq(token1.balanceOf(address(vault)), initialLiquidity1 + expectedAmountIn, "Vault token1 balance");
        assertEq(token0.balanceOf(address(vault)), initialLiquidity0 - amountToReceive, "Vault token0 balance");
    }

    function testSwapWithProtocolFee() public {
        // 1. Setup
        uint256 initialLiquidity0 = 10e18;
        uint256 initialLiquidity1 = 10e18;
        uint256 amountToSwap = 1e18;
        uint24 fee = 3000; // 0.3% LP fee
        uint24 protocolFee = 50; // Represents 25% of the LP fee (50/200)
        PoolKey memory key = PoolKey({currency0: currency0, currency1: currency1, fee: fee});
        vault.initialize(key);

        // Set protocol fee
        vault.setProtocolFeeController(address(this));
        vault.setProtocolFee(key, protocolFee);

        // Add liquidity
        token0.mint(address(this), initialLiquidity0);
        token1.mint(address(this), initialLiquidity1);
        IVault.ModifyLiquidityParams memory mlParams = IVault.ModifyLiquidityParams({
            amount0: initialLiquidity0,
            amount1: initialLiquidity1,
            liquidityDelta: 0,
            salt: bytes32(0)
        });
        bytes memory inner_params_liq = abi.encode(key, mlParams);
        bytes memory data_liq = abi.encode(this.modifyLiquidity_callback.selector, inner_params_liq);
        vault.unlock(data_liq);

        // Mint tokens for swap
        token0.mint(address(this), amountToSwap);

        // 2. Action
        IVault.SwapParams memory swapParams = IVault.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountToSwap)
        });

        bytes memory inner_params_swap = abi.encode(key, swapParams);
        bytes memory data_swap = abi.encode(this.swap_callback.selector, inner_params_swap);
        
        vault.unlock(data_swap);

        // 3. Assertions
        uint256 totalFeeAmount = amountToSwap * fee / 1_000_000;
        uint256 expectedProtocolFee = totalFeeAmount * protocolFee / 200;
        assertEq(vault.protocolFeesAccrued(currency0), expectedProtocolFee, "Protocol fee accrued should be correct");
        assertEq(vault.protocolFeesAccrued(currency1), 0, "Protocol fee for token1 should be 0");
    }

    function testModifyLiquidityAddCallback() public {
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
