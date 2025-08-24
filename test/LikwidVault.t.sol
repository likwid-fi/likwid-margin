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
import {Reserves} from "../src/types/Reserves.sol";
import {StateLibrary} from "../src/libraries/StateLibrary.sol";
import {SwapMath} from "../src/libraries/SwapMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract LikwidVaultTest is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SwapMath for *;

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

            BalanceDelta delta = vault.modifyLiquidity(key, mlParams);

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
            (PoolKey memory key, IVault.SwapParams memory swapParams) = abi.decode(params, (PoolKey, IVault.SwapParams));

            BalanceDelta delta = vault.swap(key, swapParams);

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
        } else if (selector == this.lending_callback.selector) {
            (PoolKey memory key, IVault.LendingParams memory lendingParams) =
                abi.decode(params, (PoolKey, IVault.LendingParams));

            BalanceDelta delta = vault.lending(key, lendingParams);

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

    function lending_callback(PoolKey memory, IVault.LendingParams memory) external pure {}

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

        Reserves _pairReserves = StateLibrary.getPairReserves(vault, key.toId());
        assertEq(_pairReserves.reserve0(), initialLiquidity0, "Initial reserve0 should match");
        assertEq(_pairReserves.reserve1(), initialLiquidity1, "Initial reserve1 should match");

        // Mint tokens for swap
        token0.mint(address(this), amountToSwap);

        // 2. Action
        bool zeroForOne = true; // token0 for token1
        IVault.SwapParams memory swapParams =
            IVault.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountToSwap), useMirror: false});

        uint256 initialVaultBalance1 = token1.balanceOf(address(vault));

        bytes memory inner_params_swap = abi.encode(key, swapParams);
        bytes memory data_swap = abi.encode(this.swap_callback.selector, inner_params_swap);

        vault.unlock(data_swap);

        // 3. Assertions
        uint256 finalVaultBalance1 = token1.balanceOf(address(vault));
        uint256 actualAmountOut = initialVaultBalance1 - finalVaultBalance1;

        assertEq(token0.balanceOf(address(this)), 0, "User token0 balance should be 0");
        assertEq(token1.balanceOf(address(this)), actualAmountOut, "User token1 balance should be amount out");
        assertEq(token0.balanceOf(address(vault)), initialLiquidity0 + amountToSwap, "Vault token0 balance");
        assertEq(token1.balanceOf(address(vault)), initialLiquidity1 - actualAmountOut, "Vault token1 balance");

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

        Reserves _pairReserves = StateLibrary.getPairReserves(vault, key.toId());
        assertEq(_pairReserves.reserve0(), initialLiquidity0, "Initial reserve0 should match");
        assertEq(_pairReserves.reserve1(), initialLiquidity1, "Initial reserve1 should match");

        // Calculate expected amount in
        bool zeroForOne = false; // token1 for token0
        Reserves _truncatedReserves = StateLibrary.getTruncatedReserves(vault, key.toId());
        uint256 degree = _pairReserves.getPriceDegree(_truncatedReserves, zeroForOne, 0, amountToReceive);
        fee = fee.dynamicFee(degree);
        console.log("Dynamic fee (in ppm): ", fee);
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
            amountSpecified: int256(amountToReceive),
            useMirror: false
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

        Reserves _pairReserves = StateLibrary.getPairReserves(vault, key.toId());
        assertEq(_pairReserves.reserve0(), initialLiquidity0, "Initial reserve0 should match");
        assertEq(_pairReserves.reserve1(), initialLiquidity1, "Initial reserve1 should match");

        // Mint tokens for swap
        token0.mint(address(this), amountToSwap);

        // 2. Action
        bool zeroForOne = true;
        IVault.SwapParams memory swapParams =
            IVault.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountToSwap), useMirror: false});

        bytes memory inner_params_swap = abi.encode(key, swapParams);
        bytes memory data_swap = abi.encode(this.swap_callback.selector, inner_params_swap);

        vault.unlock(data_swap);

        // 3. Assertions
        Reserves _truncatedReserves = StateLibrary.getTruncatedReserves(vault, key.toId());
        uint256 degree = _pairReserves.getPriceDegree(_truncatedReserves, zeroForOne, amountToSwap, 0);
        fee = fee.dynamicFee(degree);
        console.log("Dynamic fee (in ppm): ", fee);
        uint256 totalFeeAmount = amountToSwap * fee / 1_000_000;
        uint256 expectedProtocolFee = totalFeeAmount * protocolFee / 200;
        console.log("Total fee amount: ", totalFeeAmount);
        console.log("Expected protocol fee: ", expectedProtocolFee);
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

    function testLending() public {
        // 1. Setup
        uint256 initialLiquidity0 = 10e18;
        uint256 initialLiquidity1 = 10e18;
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

        int128 amountToLend = -1e18; // Deposit 1 token0
        token0.mint(address(this), uint256(int256(-amountToLend)));

        // 2. Action
        IVault.LendingParams memory lendingParams = IVault.LendingParams({
            lendingForOne: false, // lending token0
            lendingAmount: amountToLend,
            salt: bytes32(0)
        });

        bytes memory inner_params_lending = abi.encode(key, lendingParams);
        bytes memory data_lending = abi.encode(this.lending_callback.selector, inner_params_lending);

        vault.unlock(data_lending);

        // 3. Assertions
        assertEq(token0.balanceOf(address(this)), 0, "User token0 balance should be 0");
        assertEq(token0.balanceOf(address(vault)), initialLiquidity0 + uint256(int256(-amountToLend)), "Vault token0 balance");
    }

    function testLendingWithdraw() public {
        // 1. Setup
        uint256 initialLiquidity0 = 10e18;
        uint256 initialLiquidity1 = 10e18;
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

        int128 amountToDeposit = -1e18; // Deposit 1 token0
        token0.mint(address(this), uint256(int256(-amountToDeposit)));

        // Deposit
        IVault.LendingParams memory depositParams = IVault.LendingParams({
            lendingForOne: false, // lending token0
            lendingAmount: amountToDeposit,
            salt: bytes32(0)
        });
        bytes memory inner_params_deposit = abi.encode(key, depositParams);
        bytes memory data_deposit = abi.encode(this.lending_callback.selector, inner_params_deposit);
        vault.unlock(data_deposit);

        assertEq(token0.balanceOf(address(vault)), initialLiquidity0 + uint256(int256(-amountToDeposit)), "Vault token0 balance after deposit");

        // Withdraw
        int128 amountToWithdraw = 5e17; // Withdraw 0.5 token0
        IVault.LendingParams memory withdrawParams = IVault.LendingParams({
            lendingForOne: false, // lending token0
            lendingAmount: amountToWithdraw,
            salt: bytes32(0)
        });

        bytes memory inner_params_withdraw = abi.encode(key, withdrawParams);
        bytes memory data_withdraw = abi.encode(this.lending_callback.selector, inner_params_withdraw);

        vault.unlock(data_withdraw);

        // 3. Assertions
        assertEq(token0.balanceOf(address(this)), uint256(int256(amountToWithdraw)), "User token0 balance should be withdrawn amount");
        assertEq(token0.balanceOf(address(vault)), initialLiquidity0 + uint256(int256(-amountToDeposit)) - uint256(int256(amountToWithdraw)), "Vault token0 balance after withdraw");
    }
}
