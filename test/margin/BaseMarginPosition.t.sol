// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {LikwidVault} from "../../src/LikwidVault.sol";
import {LikwidMarginPosition} from "../../src/LikwidMarginPosition.sol";
import {LikwidPairPosition} from "../../src/LikwidPairPosition.sol";
import {LikwidHelper} from "../utils/LikwidHelper.sol";
import {IMarginPositionManager} from "../../src/interfaces/IMarginPositionManager.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {IUnlockCallback} from "../../src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../../src/types/PoolId.sol";
import {MarginPosition} from "../../src/libraries/MarginPosition.sol";
import {BalanceDelta} from "../../src/types/BalanceDelta.sol";
import {MarginLevels, MarginLevelsLibrary} from "../../src/types/MarginLevels.sol";

abstract contract BaseMarginPositionTest is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using MarginLevelsLibrary for MarginLevels;

    event MarginLevelChanged(bytes32 oldMarginLevel, bytes32 newMarginLevel);

    LikwidVault vault;
    LikwidMarginPosition marginPositionManager;
    LikwidPairPosition pairPositionManager;
    LikwidHelper helper;
    PoolKey key;
    PoolKey keyNative;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    uint256 amount0;
    uint256 amount1;
    uint8 leverage = 2;

    function _createTokens() internal virtual returns (address tokenA, address tokenB) {
        tokenA = address(new MockERC20("TokenA", "TKA", 18));
        tokenB = address(new MockERC20("TokenB", "TKB", 18));
    }

    function _amount0ToAdd() internal virtual returns (uint256) {
        return 10e18;
    }

    function _amount1ToAdd() internal virtual returns (uint256) {
        return 20e18;
    }

    function _marginAmount(PoolKey memory poolKey, bool marginForOne) internal virtual returns (uint256) {
        PoolId id = poolKey.toId();
        LikwidHelper.PoolStateInfo memory poolState = helper.getPoolStateInfo(id);
        return (marginForOne ? poolState.pairReserve1 : poolState.pairReserve0) / 180;
    }

    function setUp() public {
        vault = new LikwidVault(address(this));
        marginPositionManager = new LikwidMarginPosition(address(this), vault);
        pairPositionManager = new LikwidPairPosition(address(this), vault);
        helper = new LikwidHelper(address(this), vault);

        (address tokenA, address tokenB) = _createTokens();

        if (tokenA < tokenB) {
            token0 = MockERC20(tokenA);
            token1 = MockERC20(tokenB);
        } else {
            token0 = MockERC20(tokenB);
            token1 = MockERC20(tokenA);
        }

        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        vault.setMarginController(address(marginPositionManager));

        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        token0.approve(address(marginPositionManager), type(uint256).max);
        token1.approve(address(marginPositionManager), type(uint256).max);
        token0.approve(address(pairPositionManager), type(uint256).max);
        token1.approve(address(pairPositionManager), type(uint256).max);

        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, marginFee: 3000});
        vault.initialize(key);

        amount0 = _amount0ToAdd();
        amount1 = _amount1ToAdd();

        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
        pairPositionManager.addLiquidity(key, address(this), amount0, amount1, 0, 0, 10000);

        // Native currency setup
        keyNative = PoolKey({currency0: CurrencyLibrary.ADDRESS_ZERO, currency1: currency1, fee: 3000, marginFee: 3000});
        vault.initialize(keyNative);
        token1.mint(address(this), amount1); // Mint extra token1 for native liquidity
        pairPositionManager.addLiquidity{value: amount0}(keyNative, address(this), amount0, amount1, 0, 0, 10000);
    }

    function _createPosition(bool marginForOne) internal returns (uint256 tokenId, uint256 borrowAmount) {
        uint256 marginAmount = _marginAmount(key, marginForOne);
        if (marginForOne) {
            token1.mint(address(this), marginAmount);
        } else {
            token0.mint(address(this), marginAmount);
        }

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: marginForOne,
            leverage: leverage,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (tokenId, borrowAmount,) = marginPositionManager.addMargin(key, params);
    }

    function testAddMargin() public {
        // Test marginForOne = false
        uint256 tokenId0;
        uint256 borrowAmount0;
        uint256 marginAmount = _marginAmount(key, false);
        {
            token0.mint(address(this), marginAmount);
            IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
                marginForOne: false,
                leverage: leverage,
                marginAmount: uint128(marginAmount),
                borrowAmount: 0,
                borrowAmountMax: 0,
                recipient: address(this),
                deadline: block.timestamp
            });
            (tokenId0, borrowAmount0,) = marginPositionManager.addMargin(key, params);

            assertTrue(tokenId0 > 0);
            assertTrue(borrowAmount0 > 0);

            MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId0);
            assertEq(position.marginAmount, marginAmount);
            assertEq(position.debtAmount, borrowAmount0);
        }
        skip(1000);
        // Test marginForOne = true
        uint256 tokenId1;
        uint256 borrowAmount1;
        marginAmount = _marginAmount(key, true);
        {
            token1.mint(address(this), marginAmount);
            IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
                marginForOne: true,
                leverage: leverage,
                marginAmount: uint128(marginAmount),
                borrowAmount: 0,
                borrowAmountMax: 0,
                recipient: address(this),
                deadline: block.timestamp
            });

            (tokenId1, borrowAmount1,) = marginPositionManager.addMargin(key, params);

            assertTrue(tokenId1 > 0);
            assertTrue(borrowAmount1 > 0);

            MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId1);
            assertEq(position.marginAmount, marginAmount);
            assertEq(position.debtAmount, borrowAmount1);
        }
    }

    function testRepay() public {
        // Test marginForOne = false
        {
            (uint256 tokenId, uint256 borrowAmount) = _createPosition(false);
            uint256 repayAmount = borrowAmount / 2;
            token1.mint(address(this), repayAmount);

            MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);
            marginPositionManager.repay(tokenId, repayAmount, block.timestamp);
            MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);
            assertTrue(positionAfter.debtAmount < positionBefore.debtAmount);

            skip(100);
            positionBefore = marginPositionManager.getPositionState(tokenId);
            repayAmount = positionBefore.debtAmount;
            token1.mint(address(this), repayAmount);
            marginPositionManager.repay(tokenId, repayAmount, block.timestamp);
            positionAfter = marginPositionManager.getPositionState(tokenId);
            assertApproxEqAbs(positionAfter.debtAmount, 0, 1, "Debt should be 0 after full repay");
        }
        skip(1000);
        // Test marginForOne = true
        {
            (uint256 tokenId, uint256 borrowAmount) = _createPosition(true);
            uint256 repayAmount = borrowAmount / 2;
            token0.mint(address(this), repayAmount);

            MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);
            marginPositionManager.repay(tokenId, repayAmount, block.timestamp);
            MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);
            assertTrue(positionAfter.debtAmount < positionBefore.debtAmount);

            skip(100);
            positionBefore = marginPositionManager.getPositionState(tokenId);
            repayAmount = positionBefore.debtAmount;
            token0.mint(address(this), repayAmount);
            marginPositionManager.repay(tokenId, repayAmount, block.timestamp);
            positionAfter = marginPositionManager.getPositionState(tokenId);
            assertApproxEqAbs(positionAfter.debtAmount, 0, 1, "Debt should be 0 after full repay");
        }
    }

    function testClose() public {
        // Test marginForOne = false
        {
            (uint256 tokenId,) = _createPosition(false);
            marginPositionManager.close(tokenId, 500_000, 0, block.timestamp); // close 50%
            MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
            assertGt(position.marginAmount, 0);
            assertGt(position.debtAmount, 0);

            skip(100);
            marginPositionManager.close(tokenId, 1_000_000, 0, block.timestamp); // close remaining
            position = marginPositionManager.getPositionState(tokenId);
            assertEq(position.marginAmount, 0, "Margin amount should be 0 after full close");
            assertEq(position.debtAmount, 0, "Debt amount should be 0 after full close");
        }
        skip(1000);
        // Test marginForOne = true
        {
            (uint256 tokenId,) = _createPosition(true);
            marginPositionManager.close(tokenId, 500_000, 0, block.timestamp); // close 50%
            MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
            assertGt(position.marginAmount, 0);
            assertGt(position.debtAmount, 0);

            skip(100);
            marginPositionManager.close(tokenId, 1_000_000, 0, block.timestamp); // close remaining
            position = marginPositionManager.getPositionState(tokenId);
            assertEq(position.marginAmount, 0, "Margin amount should be 0 after full close");
            assertEq(position.debtAmount, 0, "Debt amount should be 0 after full close");
        }
    }

    function testModify() public {
        // Test marginForOne = false
        uint256 marginAmount = _marginAmount(key, false);
        {
            (uint256 tokenId,) = _createPosition(false);
            MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

            // Add collateral
            uint256 modifyAmount = marginAmount / 2;
            token0.mint(address(this), modifyAmount);
            marginPositionManager.modify(tokenId, int128(int256(modifyAmount)), block.timestamp);
            MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);
            assertEq(positionAfter.marginAmount, positionBefore.marginAmount + modifyAmount);

            // Remove collateral
            positionBefore = positionAfter;
            marginPositionManager.modify(tokenId, -int128(int256(modifyAmount)), block.timestamp);
            positionAfter = marginPositionManager.getPositionState(tokenId);
            assertEq(positionAfter.marginAmount, positionBefore.marginAmount - modifyAmount);
        }
        skip(1000);
        // Test marginForOne = true
        marginAmount = _marginAmount(key, true);
        {
            (uint256 tokenId,) = _createPosition(true);
            MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

            // Add collateral
            uint256 modifyAmount = marginAmount / 2;
            token1.mint(address(this), modifyAmount);
            marginPositionManager.modify(tokenId, int128(int256(modifyAmount)), block.timestamp);
            MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);
            assertEq(positionAfter.marginAmount, positionBefore.marginAmount + modifyAmount);

            // Remove collateral
            positionBefore = positionAfter;
            marginPositionManager.modify(tokenId, -int128(int256(modifyAmount)), block.timestamp);
            positionAfter = marginPositionManager.getPositionState(tokenId);
            assertEq(positionAfter.marginAmount, positionBefore.marginAmount - modifyAmount);
        }
    }

    function _makeLiquidatable(bool marginForOne, bool isNative) private {
        uint256 swapAmount = marginForOne ? amount1 / 10 : amount0 / 10; // Swap enough to cause a significant price change
        PoolKey memory _key = isNative ? keyNative : key;

        IVault.SwapParams memory swapParams;

        if (marginForOne) {
            token1.mint(address(this), swapAmount);
            swapParams = IVault.SwapParams({
                zeroForOne: false, amountSpecified: -int256(swapAmount), useMirror: false, salt: bytes32(0)
            });
        } else {
            // zeroForOne = true
            swapParams = IVault.SwapParams({
                zeroForOne: true, amountSpecified: -int256(swapAmount), useMirror: false, salt: bytes32(0)
            });
            if (isNative) {
                // Fund the test contract with ETH for the upcoming swap settlement
                deal(address(this), address(this).balance + swapAmount);
            } else {
                token0.mint(address(this), swapAmount);
            }
        }

        bytes memory innerParamsSwap = abi.encode(_key, swapParams);
        bytes memory dataSwap = abi.encode(this.swap_callback.selector, innerParamsSwap);
        vault.unlock(dataSwap);
        skip(1000);
    }

    function testLiquidateCall() public {
        leverage = 4;
        // Test marginForOne = false
        {
            (uint256 tokenId,) = _createPosition(false);
            while (!helper.checkMarginPositionLiquidate(tokenId)) {
                _makeLiquidatable(false, false);
            }
            assertTrue(helper.checkMarginPositionLiquidate(tokenId), "Position should be liquidatable");

            address liquidator = makeAddr("liquidator");
            vm.startPrank(liquidator);
            token1.mint(liquidator, 100e18);
            token1.approve(address(marginPositionManager), 100e18);
            (uint256 profit,) = marginPositionManager.liquidateCall(tokenId, 0);
            vm.stopPrank();

            assertTrue(profit > 0, "Liquidator should profit");
            MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
            assertEq(position.debtAmount, 0, "Debt should be 0 after liquidation");
            assertEq(position.marginAmount, 0, "Margin should be 0 after liquidation");
        }
        skip(1000);
        // Test marginForOne = true
        {
            (uint256 tokenId,) = _createPosition(true);
            while (!helper.checkMarginPositionLiquidate(tokenId)) {
                _makeLiquidatable(true, false);
            }
            assertTrue(helper.checkMarginPositionLiquidate(tokenId), "Position should be liquidatable");

            address liquidator = makeAddr("liquidator");
            vm.startPrank(liquidator);
            token0.mint(liquidator, 100e18);
            token0.approve(address(marginPositionManager), 100e18);
            (uint256 profit,) = marginPositionManager.liquidateCall(tokenId, 0);
            vm.stopPrank();

            assertTrue(profit > 0, "Liquidator should profit");
            MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
            assertEq(position.debtAmount, 0, "Debt should be 0 after liquidation");
            assertEq(position.marginAmount, 0, "Margin should be 0 after liquidation");
        }
    }

    function testLiquidateBurn() public {
        leverage = 4;
        // Test marginForOne = false
        {
            (uint256 tokenId,) = _createPosition(false);
            while (!helper.checkMarginPositionLiquidate(tokenId)) {
                _makeLiquidatable(false, false);
            }
            assertTrue(helper.checkMarginPositionLiquidate(tokenId), "Position should be liquidatable");

            address liquidator = makeAddr("liquidator");
            vm.startPrank(liquidator);
            uint256 profit = marginPositionManager.liquidateBurn(tokenId, 0);
            vm.stopPrank();

            assertTrue(profit > 0, "Liquidator should profit from burn");
            MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
            assertEq(position.debtAmount, 0, "Debt should be 0 after liquidation burn");
            assertEq(position.marginAmount, 0, "Margin should be 0 after liquidation burn");
        }
        skip(1000);
        // Test marginForOne = true
        {
            (uint256 tokenId,) = _createPosition(true);
            while (!helper.checkMarginPositionLiquidate(tokenId)) {
                _makeLiquidatable(true, false);
            }
            assertTrue(helper.checkMarginPositionLiquidate(tokenId), "Position should be liquidatable");

            address liquidator = makeAddr("liquidator");
            vm.startPrank(liquidator);
            uint256 profit = marginPositionManager.liquidateBurn(tokenId, 0);
            vm.stopPrank();

            assertTrue(profit > 0, "Liquidator should profit from burn");
            MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
            assertEq(position.debtAmount, 0, "Debt should be 0 after liquidation burn");
            assertEq(position.marginAmount, 0, "Margin should be 0 after liquidation burn");
        }
    }

    function testSetMarginLevel() public {
        MarginLevels oldLevels = marginPositionManager.marginLevels();
        MarginLevels newMarginLevels;
        newMarginLevels = newMarginLevels.setMinMarginLevel(1200000);
        newMarginLevels = newMarginLevels.setMinBorrowLevel(1500000);
        newMarginLevels = newMarginLevels.setLiquidateLevel(1150000);
        newMarginLevels = newMarginLevels.setLiquidationRatio(900000);
        newMarginLevels = newMarginLevels.setCallerProfit(20000);

        vm.expectEmit(true, true, true, true);
        emit MarginLevelChanged(MarginLevels.unwrap(oldLevels), MarginLevels.unwrap(newMarginLevels));
        marginPositionManager.setMarginLevel(MarginLevels.unwrap(newMarginLevels));

        assertEq(
            MarginLevels.unwrap(marginPositionManager.marginLevels()),
            MarginLevels.unwrap(newMarginLevels),
            "Margin levels should be updated"
        );
    }

    function _createPositionNative(bool marginForOne) internal returns (uint256 tokenId, uint256 borrowAmount) {
        uint256 marginAmount = _marginAmount(keyNative, marginForOne);
        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: marginForOne,
            leverage: leverage,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        if (marginForOne) {
            token1.mint(address(this), marginAmount);
            (tokenId, borrowAmount,) = marginPositionManager.addMargin(keyNative, params);
        } else {
            (tokenId, borrowAmount,) = marginPositionManager.addMargin{value: marginAmount}(keyNative, params);
        }
    }

    // --- NATIVE CURRENCY TESTS ---

    function testAddMargin_Native() public {
        // Test margin with native, borrow token1
        uint256 marginAmount = _marginAmount(keyNative, false);
        {
            IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
                marginForOne: false,
                leverage: leverage,
                marginAmount: uint128(marginAmount),
                borrowAmount: 0,
                borrowAmountMax: 0,
                recipient: address(this),
                deadline: block.timestamp
            });
            (uint256 tokenId, uint256 borrowAmount,) =
                marginPositionManager.addMargin{value: marginAmount}(keyNative, params);

            assertTrue(tokenId > 0);
            assertTrue(borrowAmount > 0);
            MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
            assertEq(position.marginAmount, marginAmount);
            assertEq(position.debtAmount, borrowAmount);
        }

        // Test margin with token1, borrow native
        marginAmount = _marginAmount(keyNative, true);
        {
            token1.mint(address(this), marginAmount);
            IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
                marginForOne: true,
                leverage: leverage,
                marginAmount: uint128(marginAmount),
                borrowAmount: 0,
                borrowAmountMax: 0,
                recipient: address(this),
                deadline: block.timestamp
            });
            (uint256 tokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(keyNative, params);

            assertTrue(tokenId > 0);
            assertTrue(borrowAmount > 0);
            MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
            assertEq(position.marginAmount, marginAmount);
            assertEq(position.debtAmount, borrowAmount);
        }
    }

    function testRepay_Native() public {
        // Test margin with native, repay with token1
        {
            (uint256 tokenId, uint256 borrowAmount) = _createPositionNative(false);
            uint256 repayAmount = borrowAmount / 2;
            token1.mint(address(this), repayAmount);
            marginPositionManager.repay(tokenId, repayAmount, block.timestamp);
            MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
            assertLt(position.debtAmount, borrowAmount);
        }

        // Test margin with token1, repay with native
        {
            (uint256 tokenId, uint256 borrowAmount) = _createPositionNative(true);
            uint256 repayAmount = borrowAmount / 2;
            marginPositionManager.repay{value: repayAmount}(tokenId, repayAmount, block.timestamp);
            MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
            assertLt(position.debtAmount, borrowAmount);
        }
    }

    function testClose_Native() public {
        // Test margin with native, close to receive native
        {
            (uint256 tokenId,) = _createPositionNative(false);
            uint256 balanceBefore = address(this).balance;
            marginPositionManager.close(tokenId, 1_000_000, 0, block.timestamp);
            uint256 balanceAfter = address(this).balance;
            assertGt(balanceAfter, balanceBefore, "Should receive native currency back");
        }

        // Test margin with token1, close to receive token1
        {
            (uint256 tokenId,) = _createPositionNative(true);
            uint256 balanceBefore = token1.balanceOf(address(this));
            marginPositionManager.close(tokenId, 1_000_000, 0, block.timestamp);
            uint256 balanceAfter = token1.balanceOf(address(this));
            assertGt(balanceAfter, balanceBefore, "Should receive token1 back");
        }
    }

    function testModify_Native() public {
        // Test marginForOne = false
        uint256 marginAmount = _marginAmount(keyNative, false);
        {
            (uint256 tokenId,) = _createPositionNative(false);
            // Add collateral
            uint256 modifyAmount = marginAmount / 2;
            marginPositionManager.modify{value: modifyAmount}(tokenId, int128(int256(modifyAmount)), block.timestamp);
            MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
            assertEq(position.marginAmount, marginAmount + modifyAmount);

            // Remove collateral
            uint256 balanceBefore = address(this).balance;
            marginPositionManager.modify(tokenId, -int128(int256(modifyAmount)), block.timestamp);
            uint256 balanceAfter = address(this).balance;
            assertGt(balanceAfter, balanceBefore, "Should receive native currency back");
        }
        skip(1000);
        // Test marginForOne = true
        marginAmount = _marginAmount(keyNative, true);
        {
            (uint256 tokenId,) = _createPositionNative(true);
            // Add collateral
            uint256 modifyAmount = marginAmount / 2;
            token1.mint(address(this), modifyAmount);
            marginPositionManager.modify(tokenId, int128(int256(modifyAmount)), block.timestamp);
            MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
            assertEq(position.marginAmount, marginAmount + modifyAmount);

            // Remove collateral
            uint256 balanceBefore = token1.balanceOf(address(this));
            marginPositionManager.modify(tokenId, -int128(int256(modifyAmount)), block.timestamp);
            uint256 balanceAfter = token1.balanceOf(address(this));
            assertGt(balanceAfter, balanceBefore, "Should receive token1 back");
        }
    }

    // --- Callbacks and utilities ---

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bytes4 selector, bytes memory params) = abi.decode(data, (bytes4, bytes));

        if (selector == this.swap_callback.selector) {
            (PoolKey memory _key, IVault.SwapParams memory swapParams) =
                abi.decode(params, (PoolKey, IVault.SwapParams));

            (BalanceDelta delta,,) = vault.swap(_key, swapParams);
            int256 amount0Delta = delta.amount0();
            int256 amount1Delta = delta.amount1();

            // Settle balances
            if (amount0Delta < 0) {
                uint256 payAmount = uint256(-amount0Delta);
                vault.sync(_key.currency0);
                if (_key.currency0.isAddressZero()) {
                    vault.settle{value: payAmount}();
                } else {
                    IERC20(Currency.unwrap(_key.currency0)).transfer(address(vault), payAmount);
                    vault.settle();
                }
            } else if (amount0Delta > 0) {
                vault.take(_key.currency0, address(this), uint256(amount0Delta));
            }

            if (amount1Delta < 0) {
                uint256 payAmount = uint256(-amount1Delta);
                vault.sync(_key.currency1);
                IERC20(Currency.unwrap(_key.currency1)).transfer(address(vault), payAmount);
                vault.settle();
            } else if (amount1Delta > 0) {
                vault.take(_key.currency1, address(this), uint256(amount1Delta));
            }
        }
        return "";
    }

    fallback() external payable {}
    receive() external payable {}

    function swap_callback(PoolKey memory, IVault.SwapParams memory) external pure {}
}
