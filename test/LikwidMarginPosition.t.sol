// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LikwidVault} from "../src/LikwidVault.sol";
import {LikwidMarginPosition} from "../src/LikwidMarginPosition.sol";
import {LikwidPairPosition} from "../src/LikwidPairPosition.sol";
import {IMarginPositionManager} from "../src/interfaces/IMarginPositionManager.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IUnlockCallback} from "../src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";
import {StateLibrary} from "../src/libraries/StateLibrary.sol";
import {Reserves} from "../src/types/Reserves.sol";
import {MarginPosition} from "../src/libraries/MarginPosition.sol";
import {BalanceDelta} from "../src/types/BalanceDelta.sol";

contract LikwidMarginPositionTest is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    LikwidVault vault;
    LikwidMarginPosition marginPositionManager;
    LikwidPairPosition pairPositionManager;
    PoolKey key;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;

    function setUp() public {
        // Deploy Vault and Position Manager
        vault = new LikwidVault(address(this));
        marginPositionManager = new LikwidMarginPosition(address(this), vault);
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
        vault.setMarginController(address(marginPositionManager));

        // Approve the vault to pull funds from this test contract
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        token0.approve(address(marginPositionManager), type(uint256).max);
        token1.approve(address(marginPositionManager), type(uint256).max);
        token0.approve(address(pairPositionManager), type(uint256).max);
        token1.approve(address(pairPositionManager), type(uint256).max);

        uint24 fee = 3000; // 0.3%
        key = PoolKey({currency0: currency0, currency1: currency1, fee: fee});
        vault.initialize(key);

        uint256 amount0ToAdd = 10e18;
        uint256 amount1ToAdd = 20e18;
        token0.mint(address(this), amount0ToAdd);
        token1.mint(address(this), amount1ToAdd);
        pairPositionManager.addLiquidity(key, amount0ToAdd, amount1ToAdd, 0, 0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bytes4 selector, bytes memory params) = abi.decode(data, (bytes4, bytes));

        if (selector == this.swap_callback.selector) {
            (PoolKey memory _key, IVault.SwapParams memory swapParams) =
                abi.decode(params, (PoolKey, IVault.SwapParams));

            (BalanceDelta delta,,) = vault.swap(_key, swapParams);

            // Settle the balances
            if (delta.amount0() < 0) {
                vault.sync(_key.currency0);
                token0.transfer(address(vault), uint256(-int256(delta.amount0())));
                vault.settle();
            } else if (delta.amount0() > 0) {
                vault.take(_key.currency0, address(this), uint256(int256(delta.amount0())));
            }

            if (delta.amount1() < 0) {
                vault.sync(_key.currency1);
                token1.transfer(address(vault), uint256(-int256(delta.amount1())));
                vault.settle();
            } else if (delta.amount1() > 0) {
                vault.take(_key.currency1, address(this), uint256(int256(delta.amount1())));
            }
        }
        return "";
    }

    function swap_callback(PoolKey memory, IVault.SwapParams memory) external pure {}

    function testAddMargin() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with token0, borrow token1
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint256 borrowAmount) = marginPositionManager.addMargin(key, params);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);

        assertEq(position.marginAmount, marginAmount, "position.marginAmount==marginAmount");
        assertEq(position.debtAmount, borrowAmount, "position.debtAmount==borrowAmount");
    }

    function testRepay() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with token0, borrow token1
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint256 borrowAmount) = marginPositionManager.addMargin(key, params);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);

        uint256 repayAmount = borrowAmount / 2;
        token1.mint(address(this), repayAmount);

        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

        marginPositionManager.repay(tokenId, repayAmount, block.timestamp);

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertTrue(
            positionAfter.debtAmount < positionBefore.debtAmount, "position.debtAmount should be less after repay"
        );
    }

    function testClose() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with token0, borrow token1
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,) = marginPositionManager.addMargin(key, params);

        marginPositionManager.close(tokenId, 1_000_000, 0, block.timestamp); // close 100%

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);

        assertEq(position.marginAmount, 0, "position.marginAmount should be 0 after close");
        assertEq(position.debtAmount, 0, "position.debtAmount should be 0 after close");
    }

    function testModify() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with token0, borrow token1
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,) = marginPositionManager.addMargin(key, params);

        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

        uint256 modifyAmount = 0.05e18;
        token0.mint(address(this), modifyAmount);
        marginPositionManager.modify(tokenId, int128(int256(modifyAmount)));

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertEq(
            positionAfter.marginAmount,
            positionBefore.marginAmount + modifyAmount,
            "position.marginAmount should be increased"
        );
    }

    function testLiquidateCall() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with token0, borrow token1
            leverage: 4,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,) = marginPositionManager.addMargin(key, params);

        // Manipulate price to make position liquidatable
        // Swap a large amount of token0 for token1 to drive the price of token0 down
        uint256 swapAmount = 5e18;
        token0.mint(address(this), swapAmount);

        // Perform swap on the vault
        IVault.SwapParams memory swapParams = IVault.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            useMirror: false,
            salt: bytes32(0)
        });
        bytes memory inner_params_swap = abi.encode(key, swapParams);
        bytes memory data_swap = abi.encode(this.swap_callback.selector, inner_params_swap);
        vault.unlock(data_swap);

        (bool liquidated,,) = marginPositionManager.checkLiquidate(tokenId);
        assertTrue(liquidated, "Position should be liquidatable");

        // Liquidate
        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        token1.mint(liquidator, 100e18); // give liquidator funds to repay debt
        token1.approve(address(vault), 100e18);
        token1.approve(address(marginPositionManager), 100e18);

        (uint256 profit,) = marginPositionManager.liquidateCall(tokenId);
        vm.stopPrank();

        assertTrue(profit > 0, "Liquidator should make a profit");

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.debtAmount, 0, "position.debtAmount should be 0 after liquidation");
    }

    function testLiquidateBurn() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with token0, borrow token1
            leverage: 4,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,) = marginPositionManager.addMargin(key, params);

        // Manipulate price to make position liquidatable
        // Swap a large amount of token0 for token1 to drive the price of token0 down
        uint256 swapAmount = 5e18;
        token0.mint(address(this), swapAmount);

        // Perform swap on the vault
        IVault.SwapParams memory swapParams = IVault.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            useMirror: false,
            salt: bytes32(0)
        });
        bytes memory inner_params_swap = abi.encode(key, swapParams);
        bytes memory data_swap = abi.encode(this.swap_callback.selector, inner_params_swap);
        vault.unlock(data_swap);

        (bool liquidated,,) = marginPositionManager.checkLiquidate(tokenId);
        assertTrue(liquidated, "Position should be liquidatable");

        // Liquidate
        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);

        uint256 profit = marginPositionManager.liquidateBurn(tokenId);
        vm.stopPrank();

        assertTrue(profit > 0, "Liquidator should make a profit");

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.debtAmount, 0, "position.debtAmount should be 0 after liquidation");
        assertEq(position.marginAmount, 0, "position.marginAmount should be 0 after liquidation");
    }
}
