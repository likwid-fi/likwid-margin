// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LikwidVault} from "../src/LikwidVault.sol";
import {LikwidPairPosition} from "../src/LikwidPairPosition.sol";
import {IPairPositionManager} from "../src/interfaces/IPairPositionManager.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";
import {StateLibrary} from "../src/libraries/StateLibrary.sol";
import {Reserves} from "../src/types/Reserves.sol";

contract LikwidPairPositionTest is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    LikwidVault vault;
    LikwidPairPosition pairPositionManager;
    PoolKey key;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;

    function setUp() public {
        skip(1); // Ensure block.timestamp is not zero

        // Deploy Vault and Position Manager
        vault = new LikwidVault(address(this));
        pairPositionManager = new LikwidPairPosition(address(this), vault);

        // Deploy mock tokens
        address tokenA = address(new MockERC20("TokenA", "TKNA", 18));
        address tokenB = address(new MockERC20("TokenB", "TKNB", 18));

        // Ensure currency order
        if (tokenA < tokenB) {
            token0 = MockERC20(tokenA);
            token1 = MockERC20(tokenB);
        } else {
            token0 = MockERC20(tokenB);
            token1 = MockERC20(tokenA);
        }

        // Wrap tokens into Currency type
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // The test contract is the vault's controller to settle balances
        vault.setMarginController(address(this));

        // Approve the vault to pull funds from this test contract
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        token0.approve(address(pairPositionManager), type(uint256).max);
        token1.approve(address(pairPositionManager), type(uint256).max);
        uint24 fee = 3000; // 0.3%
        key = PoolKey({currency0: currency0, currency1: currency1, fee: fee});
        vault.initialize(key);
    }

    function testAddLiquidityCreatesPositionAndAddsLiquidity() public {
        // 1. Arrange
        uint256 amount0ToAdd = 10e18;
        uint256 amount1ToAdd = 20e18;
        PoolId id = key.toId();

        // Mint tokens to this test contract
        token0.mint(address(this), amount0ToAdd);
        token1.mint(address(this), amount1ToAdd);

        assertEq(token0.balanceOf(address(this)), amount0ToAdd, "Initial user balance of token0 should be correct");
        assertEq(token1.balanceOf(address(this)), amount1ToAdd, "Initial user balance of token1 should be correct");

        // 2. Act
        (uint256 tokenId, uint128 liquidity) = pairPositionManager.addLiquidity(key, amount0ToAdd, amount1ToAdd, 0, 0);

        // 3. Assert
        // Check NFT ownership and position data
        assertEq(tokenId, 1, "First token minted should have ID 1");
        assertEq(pairPositionManager.ownerOf(tokenId), address(this), "Owner of new token should be the caller");
        (Currency c0, Currency c1, uint24 storedFee) =
            pairPositionManager.poolKeys(pairPositionManager.poolIds(tokenId));
        PoolKey memory storedKey = PoolKey(c0, c1, storedFee);
        assertEq(PoolId.unwrap(storedKey.toId()), PoolId.unwrap(id), "Stored PoolKey should be correct");
        assertTrue(liquidity > 0, "Liquidity should be greater than zero");

        // Check user's token balances (should be zero)
        assertEq(token0.balanceOf(address(this)), 0, "User should have spent all token0");
        assertEq(token1.balanceOf(address(this)), 0, "User should have spent all token1");

        // Check vault's token balances
        assertEq(token0.balanceOf(address(vault)), amount0ToAdd, "Vault should have received token0");
        assertEq(token1.balanceOf(address(vault)), amount1ToAdd, "Vault should have received token1");

        // Check vault's internal reserves for the pool
        Reserves reserves = StateLibrary.getPairReserves(vault, id);
        assertEq(reserves.reserve0(), amount0ToAdd, "Vault internal reserve0 should match");
        assertEq(reserves.reserve1(), amount1ToAdd, "Vault internal reserve1 should match");
    }

    function testRemoveLiquidity() public {
        // 1. Arrange: Add liquidity first to create a position
        uint256 amount0ToAdd = 10e18;
        uint256 amount1ToAdd = 10e18; // Use 1:1 ratio for simplicity

        token0.mint(address(this), amount0ToAdd);
        token1.mint(address(this), amount1ToAdd);

        (uint256 tokenId, uint128 liquidityAdded) =
            pairPositionManager.addLiquidity(key, amount0ToAdd, amount1ToAdd, 0, 0);

        assertEq(token0.balanceOf(address(this)), 0, "User token0 balance should be 0 after adding liquidity");
        assertEq(token1.balanceOf(address(this)), 0, "User token1 balance should be 0 after adding liquidity");

        // 2. Act: Remove the entire liquidity
        uint128 liquidityRemoved = liquidityAdded / 6;
        (uint256 amount0Removed, uint256 amount1Removed) =
            pairPositionManager.removeLiquidity(tokenId, liquidityRemoved, 0, 0);

        // 3. Assert
        // Check amounts returned
        assertEq(amount0Removed, amount0ToAdd / 6, "Amount of token0 removed should equal 1/6 amount added");
        assertEq(amount1Removed, amount1ToAdd / 6, "Amount of token1 removed should equal 1/6 amount added");

        // Check user's final token balances
        assertEq(token0.balanceOf(address(this)), amount0Removed, "User should have received back 1/6 token0");
        assertEq(token1.balanceOf(address(this)), amount1Removed, "User should have received back 1/6 token1");

        // Check vault's final token balances (should be zero)
        assertEq(token0.balanceOf(address(vault)), amount0ToAdd - amount0Removed, "Vault should have sent 1/6 token0");
        assertEq(token1.balanceOf(address(vault)), amount1ToAdd - amount1Removed, "Vault should have sent 1/6 token1");

        // Check vault's internal reserves (should be zero)
        Reserves reserves = StateLibrary.getPairReserves(vault, key.toId());
        assertEq(
            reserves.reserve0(),
            amount0ToAdd - amount0Removed,
            "Vault internal reserve0 should be amount0ToAdd - amount0Removed"
        );
        assertEq(
            reserves.reserve1(),
            amount1ToAdd - amount1Removed,
            "Vault internal reserve1 should be amount1ToAdd-amount1Removed"
        );
    }

    function testExactInputSwap() public {
        // 1. Arrange: Add liquidity
        uint256 amount0ToAdd = 100e18;
        uint256 amount1ToAdd = 100e18;
        token0.mint(address(this), amount0ToAdd);
        token1.mint(address(this), amount1ToAdd);
        pairPositionManager.addLiquidity(key, amount0ToAdd, amount1ToAdd, 0, 0);

        // 2. Arrange: Prepare for swap
        uint256 amountIn = 10e18;
        token0.mint(address(this), amountIn); // Mint token0 to swap for token1
        PoolId poolId = key.toId();
        bool zeroForOne = true; // Swapping token0 for token1

        IPairPositionManager.SwapInputParams memory params = IPairPositionManager.SwapInputParams({
            poolId: poolId,
            zeroForOne: zeroForOne,
            to: address(this),
            amountIn: amountIn,
            amountOutMin: 0,
            deadline: block.timestamp + 1
        });

        // 3. Act
        (,, uint256 amountOut) = pairPositionManager.exactInput(params);

        // 4. Assert
        assertTrue(amountOut > 0, "Amount out should be greater than 0");

        // Check balances
        assertEq(token0.balanceOf(address(this)), 0, "User should have spent all token0 for swap");
        assertEq(token1.balanceOf(address(this)), amountOut, "User should have received token1");

        // Check vault reserves
        Reserves reserves = StateLibrary.getPairReserves(vault, poolId);
        assertEq(reserves.reserve0(), amount0ToAdd + amountIn, "Vault reserve0 should have increased by amountIn");
        assertEq(reserves.reserve1(), amount1ToAdd - amountOut, "Vault reserve1 should have decreased by amountOut");
    }

    function testExactOutputSwap() public {
        // 1. Arrange: Add liquidity
        uint256 amount0ToAdd = 100e18;
        uint256 amount1ToAdd = 100e18;
        token0.mint(address(this), amount0ToAdd);
        token1.mint(address(this), amount1ToAdd);
        pairPositionManager.addLiquidity(key, amount0ToAdd, amount1ToAdd, 0, 0);

        // 2. Arrange: Prepare for swap
        uint256 amountOut = 10e18;
        token0.mint(address(this), 20e18); // Mint extra token0 to cover input
        PoolId poolId = key.toId();
        bool zeroForOne = true; // Swapping token0 for token1

        IPairPositionManager.SwapOutputParams memory params = IPairPositionManager.SwapOutputParams({
            poolId: poolId,
            zeroForOne: zeroForOne,
            to: address(this),
            amountInMax: 20e18,
            amountOut: amountOut,
            deadline: block.timestamp + 1
        });

        // 3. Act
        (,, uint256 amountIn) = pairPositionManager.exactOutput(params);

        // 4. Assert
        assertTrue(amountIn > 0, "Amount in should be greater than 0");
        assertTrue(amountIn < 20e18, "Amount in should be less than max");

        // Check balances
        assertEq(token0.balanceOf(address(this)), 20e18 - amountIn, "User should have spent amountIn of token0");
        assertEq(token1.balanceOf(address(this)), amountOut, "User should have received amountOut of token1");

        // Check vault reserves
        Reserves reserves = StateLibrary.getPairReserves(vault, poolId);
        assertEq(reserves.reserve0(), amount0ToAdd + amountIn, "Vault reserve0 should have increased by amountIn");
        assertEq(reserves.reserve1(), amount1ToAdd - amountOut, "Vault reserve1 should have decreased by amountOut");
    }
}