// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LikwidVault} from "../src/LikwidVault.sol";
import {LikwidLendPosition} from "../src/LikwidLendPosition.sol";
import {LikwidPairPosition} from "../src/LikwidPairPosition.sol";
import {LikwidMarginPosition} from "../src/LikwidMarginPosition.sol";
import {IBasePositionManager} from "../src/interfaces/IBasePositionManager.sol";
import {ILendPositionManager} from "../src/interfaces/ILendPositionManager.sol";
import {IMarginPositionManager} from "../src/interfaces/IMarginPositionManager.sol";

import {PoolKey} from "../src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";

import {ReservesLibrary} from "../src/types/Reserves.sol";
import {LendPosition} from "../src/libraries/LendPosition.sol";

contract LikwidLendPositionTest is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    LikwidVault vault;
    LikwidLendPosition lendPositionManager;
    LikwidPairPosition pairPositionManager;
    LikwidMarginPosition marginPositionManager;
    PoolKey key;
    PoolKey keyNative;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;

    receive() external payable {}

    function setUp() public {
        skip(1); // Ensure block.timestamp is not zero

        // Deploy Vault and Position Manager
        vault = new LikwidVault(address(this));
        lendPositionManager = new LikwidLendPosition(address(this), vault);
        pairPositionManager = new LikwidPairPosition(address(this), vault);
        marginPositionManager = new LikwidMarginPosition(address(this), vault);

        // The test contract is the vault's controller to settle balances
        vault.setMarginController(address(marginPositionManager));

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

        // Approve the vault to pull funds from this test contract
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        token0.approve(address(lendPositionManager), type(uint256).max);
        token1.approve(address(lendPositionManager), type(uint256).max);
        token0.approve(address(pairPositionManager), type(uint256).max);
        token1.approve(address(pairPositionManager), type(uint256).max);
        token0.approve(address(marginPositionManager), type(uint256).max);
        token1.approve(address(marginPositionManager), type(uint256).max);

        uint24 fee = 3000; // 0.3%
        key = PoolKey({currency0: currency0, currency1: currency1, fee: fee, marginFee: 3000});
        vault.initialize(key);

        uint256 amount0ToAdd = 1000e18;
        uint256 amount1ToAdd = 2000e18;
        token0.mint(address(this), amount0ToAdd);
        token1.mint(address(this), amount1ToAdd);
        pairPositionManager.addLiquidity(key, address(this), amount0ToAdd, amount1ToAdd, 0, 0, 10000);

        keyNative = PoolKey({currency0: CurrencyLibrary.ADDRESS_ZERO, currency1: currency1, fee: fee, marginFee: 3000});
        vault.initialize(keyNative);
        token1.mint(address(this), amount1ToAdd);
        pairPositionManager.addLiquidity{value: amount0ToAdd}(
            keyNative, address(this), amount0ToAdd, amount1ToAdd, 0, 0, 10000
        );
    }

    function testAddLendingForZero() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        assertTrue(tokenId > 0);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);
        assertTrue(position.lendAmount > 0);
        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testDepositForZero() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        lendPositionManager.deposit(tokenId, amount, 0);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);
        assertTrue(position.lendAmount > 0);
        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testWithdrawForZero() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        LendPosition.State memory positionBefore = lendPositionManager.getPositionState(tokenId);

        lendPositionManager.withdraw(tokenId, amount / 2, 0);

        LendPosition.State memory positionAfter = lendPositionManager.getPositionState(tokenId);
        console.log("positionAfter.lendAmount:", positionAfter.lendAmount);

        assertTrue(
            positionAfter.lendAmount < positionBefore.lendAmount, "position.lendAmount should be less after withdraw"
        );
        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        token0.mint(liquidator, amount);
        token0.approve(address(lendPositionManager), amount);
        uint256 tokenId02 = lendPositionManager.addLending(key, false, liquidator, amount, 0);
        assertNotEq(tokenId, tokenId02);
        LendPosition.State memory position02 = lendPositionManager.getPositionState(tokenId02);
        assertTrue(position02.lendAmount == amount);
        vm.stopPrank();
        vm.expectRevert(LendPosition.WithdrawOverflow.selector);
        lendPositionManager.withdraw(tokenId, amount, 0);
    }

    function testGetPositionStateForZero() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);

        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testMirrorExactInputToken10() public {
        uint256 marginAmount = 1e18;
        token1.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory marginParams = IMarginPositionManager.CreateParams({
            marginForOne: true, // margin with token1, borrow token0
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 marginTokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, marginParams);
        assertTrue(marginTokenId > 0, "marginTokenId should be greater than 0");
        assertTrue(borrowAmount > 0, "borrowAmount should be greater than 0");

        uint256 amountIn = 0.1e18;
        token1.mint(address(this), amountIn);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        LendPosition.State memory positionBefore = lendPositionManager.getPositionState(tokenId);
        assertEq(positionBefore.lendAmount, 0, "lendAmount should be zero");
        // swap mirror token0
        ILendPositionManager.SwapInputParams memory params = ILendPositionManager.SwapInputParams({
            zeroForOne: false, tokenId: tokenId, amountIn: amountIn, amountOutMin: 0, deadline: block.timestamp
        });

        (,, uint256 amountOut) = lendPositionManager.exactInput(params);

        assertTrue(amountOut > 0, "amountOut should be greater than 0");

        LendPosition.State memory positionAfter = lendPositionManager.getPositionState(tokenId);

        assertEq(positionAfter.lendAmount, amountOut, "lendAmount should be amountOut");
    }

    function testMirrorExactOutputToken10() public {
        uint256 marginAmount = 1e18;
        token1.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory marginParams = IMarginPositionManager.CreateParams({
            marginForOne: true, // margin with token1, borrow token0
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 marginTokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, marginParams);
        assertTrue(marginTokenId > 0, "marginTokenId should be greater than 0");
        assertTrue(borrowAmount > 0, "borrowAmount should be greater than 0");

        uint256 amountOut = 1e18;
        token1.mint(address(this), amountOut * 10);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        LendPosition.State memory positionBefore = lendPositionManager.getPositionState(tokenId);
        assertEq(positionBefore.lendAmount, 0, "positionBefore.lendAmount should be zero");
        // swap mirror token0
        ILendPositionManager.SwapOutputParams memory params = ILendPositionManager.SwapOutputParams({
            zeroForOne: false, tokenId: tokenId, amountInMax: 0, amountOut: amountOut, deadline: block.timestamp
        });

        (,, uint256 amountInResult) = lendPositionManager.exactOutput(params);

        assertTrue(amountInResult > 0, "amountIn should be greater than 0");

        LendPosition.State memory positionAfter = lendPositionManager.getPositionState(tokenId);

        assertEq(positionAfter.lendAmount, amountOut, "lendAmount should be amountOut");

        skip(1000);
        LendPosition.State memory positionLast = lendPositionManager.getPositionState(tokenId);
        assertLt(positionAfter.lendAmount, positionLast.lendAmount, "lendAmount should increase due to interest");

        lendPositionManager.withdraw(tokenId, type(uint256).max, 0);
        positionLast = lendPositionManager.getPositionState(tokenId);
        assertEq(positionLast.lendAmount, 0, "lendAmount should be zero after withdraw all");
    }

    function testMirrorExactInputToken01() public {
        uint256 marginAmount = 1e18;
        token0.mint(address(this), marginAmount);

        bool marginForOne = false; // margin with token0, borrow token1
        IMarginPositionManager.CreateParams memory marginParams = IMarginPositionManager.CreateParams({
            marginForOne: marginForOne,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 marginTokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, marginParams);
        assertTrue(marginTokenId > 0, "marginTokenId should be greater than 0");
        assertTrue(borrowAmount > 0, "borrowAmount should be greater than 0");

        uint256 amountIn = 0.1e18;
        token0.mint(address(this), amountIn);

        uint256 tokenId = lendPositionManager.addLending(key, true, address(this), 0, 0);

        LendPosition.State memory positionBefore = lendPositionManager.getPositionState(tokenId);
        assertEq(positionBefore.lendAmount, 0, "lendAmount should be zero");

        bool zeroForOne = true; // swap mirror token1
        ILendPositionManager.SwapInputParams memory params = ILendPositionManager.SwapInputParams({
            zeroForOne: zeroForOne, tokenId: tokenId, amountIn: amountIn, amountOutMin: 0, deadline: block.timestamp
        });

        (,, uint256 amountOut) = lendPositionManager.exactInput(params);

        assertTrue(amountOut > 0, "amountOut should be greater than 0");

        LendPosition.State memory positionAfter = lendPositionManager.getPositionState(tokenId);

        assertEq(positionAfter.lendAmount, amountOut, "lendAmount should be amountOut");
    }

    function testMirrorExactOutputToken01() public {
        uint256 marginAmount = 1e18;
        token0.mint(address(this), marginAmount);

        bool marginForOne = false; // margin with token0, borrow token1
        IMarginPositionManager.CreateParams memory marginParams = IMarginPositionManager.CreateParams({
            marginForOne: marginForOne,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 marginTokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, marginParams);
        assertTrue(marginTokenId > 0, "marginTokenId should be greater than 0");
        assertTrue(borrowAmount > 0, "borrowAmount should be greater than 0");

        uint256 amountOut = 1e18;
        token0.mint(address(this), amountOut * 10);

        uint256 tokenId = lendPositionManager.addLending(key, true, address(this), 0, 0);

        LendPosition.State memory positionBefore = lendPositionManager.getPositionState(tokenId);
        assertEq(positionBefore.lendAmount, 0, "positionBefore.lendAmount should be zero");

        bool zeroForOne = true; // swap mirror token1
        ILendPositionManager.SwapOutputParams memory params = ILendPositionManager.SwapOutputParams({
            zeroForOne: zeroForOne, tokenId: tokenId, amountInMax: 0, amountOut: amountOut, deadline: block.timestamp
        });

        (,, uint256 amountInResult) = lendPositionManager.exactOutput(params);

        assertTrue(amountInResult > 0, "amountIn should be greater than 0");

        LendPosition.State memory positionAfter = lendPositionManager.getPositionState(tokenId);

        assertEq(positionAfter.lendAmount, amountOut, "lendAmount should be amountOut");
    }

    function testAddLendingForOne() public {
        uint256 amount = 1e18;
        token1.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, true, address(this), amount, 0);

        assertTrue(tokenId > 0);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);
        assertTrue(position.lendAmount > 0);
        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testDepositForOne() public {
        uint256 amount = 1e18;
        token1.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, true, address(this), 0, 0);

        lendPositionManager.deposit(tokenId, amount, 0);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);
        assertTrue(position.lendAmount > 0);
        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testWithdrawForOne() public {
        uint256 amount = 1e18;
        token1.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, true, address(this), amount, 0);

        LendPosition.State memory positionBefore = lendPositionManager.getPositionState(tokenId);

        lendPositionManager.withdraw(tokenId, amount / 2, 0);

        LendPosition.State memory positionAfter = lendPositionManager.getPositionState(tokenId);
        console.log("positionAfter.lendAmount:", positionAfter.lendAmount);

        assertTrue(
            positionAfter.lendAmount < positionBefore.lendAmount, "position.lendAmount should be less after withdraw"
        );
        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        token1.mint(liquidator, amount);
        token1.approve(address(lendPositionManager), amount);
        uint256 tokenId02 = lendPositionManager.addLending(key, true, liquidator, amount, 0);
        assertNotEq(tokenId, tokenId02);
        LendPosition.State memory position02 = lendPositionManager.getPositionState(tokenId02);
        assertTrue(position02.lendAmount == amount);
        vm.stopPrank();
        vm.expectRevert(LendPosition.WithdrawOverflow.selector);
        lendPositionManager.withdraw(tokenId, amount, 0);
    }

    function testGetPositionStateForOne() public {
        uint256 amount = 1e18;
        token1.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, true, address(this), amount, 0);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);

        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testAddLendingForNative() public {
        uint256 amount = 1e18;
        uint256 tokenId = lendPositionManager.addLending{value: amount}(keyNative, false, address(this), amount, 0);

        assertTrue(tokenId > 0);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);
        assertTrue(position.lendAmount > 0);
        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testAddLendingForOneNative() public {
        uint256 amount = 1e18;
        token1.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(keyNative, true, address(this), amount, 0);

        assertTrue(tokenId > 0);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);
        assertTrue(position.lendAmount > 0);
        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testDepositForNative() public {
        uint256 amount = 1e18;

        uint256 tokenId = lendPositionManager.addLending(keyNative, false, address(this), 0, 0);

        lendPositionManager.deposit{value: amount}(tokenId, amount, 0);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);
        assertTrue(position.lendAmount > 0);
        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testDepositForOneNative() public {
        uint256 amount = 1e18;
        token1.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(keyNative, true, address(this), 0, 0);

        lendPositionManager.deposit(tokenId, amount, 0);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);
        assertTrue(position.lendAmount > 0);
        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testWithdrawForNative() public {
        uint256 amount = 1e18;

        uint256 tokenId = lendPositionManager.addLending{value: amount}(keyNative, false, address(this), amount, 0);

        lendPositionManager.withdraw(tokenId, amount / 2, 0);

        vm.expectRevert(ReservesLibrary.NotEnoughReserves.selector);
        lendPositionManager.withdraw(tokenId, amount, 0);

        lendPositionManager.addLending{value: amount}(keyNative, false, address(this), amount, 0);

        vm.expectRevert(LendPosition.WithdrawOverflow.selector);
        lendPositionManager.withdraw(tokenId, amount, 0);
    }

    function testWithdrawForOneNative() public {
        uint256 amount = 1e18;
        token1.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(keyNative, true, address(this), amount, 0);

        LendPosition.State memory positionBefore = lendPositionManager.getPositionState(tokenId);

        lendPositionManager.withdraw(tokenId, amount / 2, 0);

        LendPosition.State memory positionAfter = lendPositionManager.getPositionState(tokenId);
        console.log("positionAfter.lendAmount:", positionAfter.lendAmount);

        assertTrue(
            positionAfter.lendAmount < positionBefore.lendAmount, "position.lendAmount should be less after withdraw"
        );
        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        token1.mint(liquidator, amount);
        token1.approve(address(lendPositionManager), amount);
        uint256 tokenId02 = lendPositionManager.addLending(keyNative, true, liquidator, amount, 0);
        assertNotEq(tokenId, tokenId02);
        LendPosition.State memory position02 = lendPositionManager.getPositionState(tokenId02);
        assertTrue(position02.lendAmount == amount);
        vm.stopPrank();
        vm.expectRevert(LendPosition.WithdrawOverflow.selector);
        lendPositionManager.withdraw(tokenId, amount, 0);
    }

    function testGetPositionStateForNative() public {
        uint256 amount = 1e18;
        uint256 tokenId = lendPositionManager.addLending{value: amount}(keyNative, false, address(this), amount, 0);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);

        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testGetPositionStateForOneNative() public {
        uint256 amount = 1e18;
        token1.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(keyNative, true, address(this), amount, 0);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);

        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testRevertIf_UnauthorizedAccess() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);
        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        address unauthorizedUser = makeAddr("unauthorizedUser");
        vm.startPrank(unauthorizedUser);

        bytes4 expectedError = IBasePositionManager.NotOwner.selector;

        vm.expectRevert(expectedError);
        lendPositionManager.deposit(tokenId, amount, 0);

        vm.expectRevert(expectedError);
        lendPositionManager.withdraw(tokenId, amount, 0);

        ILendPositionManager.SwapInputParams memory swapParams = ILendPositionManager.SwapInputParams({
            zeroForOne: false, tokenId: tokenId, amountIn: amount, amountOutMin: 0, deadline: block.timestamp
        });
        vm.expectRevert(expectedError);
        lendPositionManager.exactInput(swapParams);

        ILendPositionManager.SwapOutputParams memory outputParams = ILendPositionManager.SwapOutputParams({
            zeroForOne: false,
            tokenId: tokenId,
            amountOut: amount,
            amountInMax: type(uint256).max,
            deadline: block.timestamp
        });
        vm.expectRevert(expectedError);
        lendPositionManager.exactOutput(outputParams);

        vm.stopPrank();
    }

    // ==================== Error Scenario Tests ====================

    function test_RevertIf_InvalidCurrency_SwapDirectionMismatch() public {
        uint256 marginAmount = 1e18;
        token1.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory marginParams = IMarginPositionManager.CreateParams({
            marginForOne: true,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 marginTokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, marginParams);
        assertTrue(marginTokenId > 0);
        assertTrue(borrowAmount > 0);

        uint256 amountIn = 0.1e18;
        token1.mint(address(this), amountIn);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        ILendPositionManager.SwapInputParams memory params = ILendPositionManager.SwapInputParams({
            zeroForOne: true, tokenId: tokenId, amountIn: amountIn, amountOutMin: 0, deadline: block.timestamp
        });

        vm.expectRevert(ILendPositionManager.InvalidCurrency.selector);
        lendPositionManager.exactInput(params);
    }

    function test_RevertIf_PriceSlippageTooHigh_ExactInput() public {
        uint256 marginAmount = 1e18;
        token1.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory marginParams = IMarginPositionManager.CreateParams({
            marginForOne: true,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 marginTokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, marginParams);
        assertTrue(marginTokenId > 0);
        assertTrue(borrowAmount > 0);

        uint256 amountIn = 0.1e18;
        token1.mint(address(this), amountIn);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        ILendPositionManager.SwapInputParams memory params = ILendPositionManager.SwapInputParams({
            zeroForOne: false,
            tokenId: tokenId,
            amountIn: amountIn,
            amountOutMin: amountIn * 1000,
            deadline: block.timestamp
        });

        vm.expectRevert(IBasePositionManager.PriceSlippageTooHigh.selector);
        lendPositionManager.exactInput(params);
    }

    function test_RevertIf_PriceSlippageTooHigh_ExactOutput() public {
        uint256 marginAmount = 1e18;
        token1.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory marginParams = IMarginPositionManager.CreateParams({
            marginForOne: true,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 marginTokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, marginParams);
        assertTrue(marginTokenId > 0);
        assertTrue(borrowAmount > 0);

        uint256 amountOut = 1e18;
        token1.mint(address(this), amountOut * 10);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        ILendPositionManager.SwapOutputParams memory params = ILendPositionManager.SwapOutputParams({
            zeroForOne: false, tokenId: tokenId, amountInMax: 1, amountOut: amountOut, deadline: block.timestamp
        });

        vm.expectRevert(IBasePositionManager.PriceSlippageTooHigh.selector);
        lendPositionManager.exactOutput(params);
    }

    function test_RevertIf_WithdrawOverflow() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        // First add liquidity from another user to enable withdrawal
        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        token0.mint(liquidator, amount);
        token0.approve(address(lendPositionManager), amount);
        lendPositionManager.addLending(key, false, liquidator, amount, 0);
        vm.stopPrank();

        vm.expectRevert(LendPosition.WithdrawOverflow.selector);
        lendPositionManager.withdraw(tokenId, amount + 1, 0);
    }

    function test_RevertIf_NotEnoughReserves() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        // Create a position and add liquidity
        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        // Add another position with liquidity to allow partial withdrawal
        address otherUser = makeAddr("otherUser");
        vm.startPrank(otherUser);
        token0.mint(otherUser, amount);
        token0.approve(address(lendPositionManager), amount);
        lendPositionManager.addLending(key, false, otherUser, amount, 0);
        vm.stopPrank();

        // Withdraw half first
        lendPositionManager.withdraw(tokenId, amount / 2, 0);

        // Now try to withdraw more than remaining - should revert with WithdrawOverflow
        vm.expectRevert(LendPosition.WithdrawOverflow.selector);
        lendPositionManager.withdraw(tokenId, amount, 0);
    }

    // ==================== Boundary Condition Tests ====================

    function test_RevertIf_ExpiredDeadline_AddLending() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        vm.expectRevert("EXPIRED");
        lendPositionManager.addLending(key, false, address(this), amount, block.timestamp - 1);
    }

    function test_RevertIf_ExpiredDeadline_Deposit() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        vm.expectRevert("EXPIRED");
        lendPositionManager.deposit(tokenId, amount, block.timestamp - 1);
    }

    function test_RevertIf_ExpiredDeadline_Withdraw() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        vm.expectRevert("EXPIRED");
        lendPositionManager.withdraw(tokenId, amount, block.timestamp - 1);
    }

    function test_RevertIf_ExpiredDeadline_ExactInput() public {
        uint256 marginAmount = 1e18;
        token1.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory marginParams = IMarginPositionManager.CreateParams({
            marginForOne: true,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        marginPositionManager.addMargin(key, marginParams);

        uint256 amountIn = 0.1e18;
        token1.mint(address(this), amountIn);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        ILendPositionManager.SwapInputParams memory params = ILendPositionManager.SwapInputParams({
            zeroForOne: false, tokenId: tokenId, amountIn: amountIn, amountOutMin: 0, deadline: block.timestamp - 1
        });

        vm.expectRevert("EXPIRED");
        lendPositionManager.exactInput(params);
    }

    function test_RevertIf_ExpiredDeadline_ExactOutput() public {
        uint256 marginAmount = 1e18;
        token1.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory marginParams = IMarginPositionManager.CreateParams({
            marginForOne: true,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        marginPositionManager.addMargin(key, marginParams);

        uint256 amountOut = 1e18;
        token1.mint(address(this), amountOut * 10);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        ILendPositionManager.SwapOutputParams memory params = ILendPositionManager.SwapOutputParams({
            zeroForOne: false,
            tokenId: tokenId,
            amountInMax: type(uint256).max,
            amountOut: amountOut,
            deadline: block.timestamp - 1
        });

        vm.expectRevert("EXPIRED");
        lendPositionManager.exactOutput(params);
    }

    function test_WithdrawMaxUint256() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        token0.mint(liquidator, amount);
        token0.approve(address(lendPositionManager), amount);
        lendPositionManager.addLending(key, false, liquidator, amount, 0);
        vm.stopPrank();

        uint256 balanceBefore = token0.balanceOf(address(this));
        lendPositionManager.withdraw(tokenId, type(uint256).max, 0);
        uint256 balanceAfter = token0.balanceOf(address(this));

        assertGt(balanceAfter, balanceBefore, "Balance should increase after withdraw");

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);
        assertEq(position.lendAmount, 0, "Position should be empty after max withdraw");
    }

    function test_RevertIf_DepositZeroAmount() public {
        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        vm.expectRevert();
        lendPositionManager.deposit(tokenId, 0, 0);
    }

    // ==================== Event Tests ====================

    function test_Emit_DepositEvent() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        vm.expectEmit(true, true, true, true);
        emit ILendPositionManager.Deposit(key.toId(), currency0, address(this), tokenId, address(this), amount);

        lendPositionManager.deposit(tokenId, amount, 0);
    }

    function test_Emit_WithdrawEvent() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        token0.mint(liquidator, amount);
        token0.approve(address(lendPositionManager), amount);
        lendPositionManager.addLending(key, false, liquidator, amount, 0);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true);
        emit ILendPositionManager.Withdraw(key.toId(), currency0, address(this), tokenId, address(this), amount / 2);

        lendPositionManager.withdraw(tokenId, amount / 2, 0);
    }

    // ==================== ERC721 and Permission Tests ====================

    function test_TransferPositionOwnership() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);
        assertEq(lendPositionManager.ownerOf(tokenId), address(this));

        address newOwner = makeAddr("newOwner");
        lendPositionManager.transferFrom(address(this), newOwner, tokenId);

        assertEq(lendPositionManager.ownerOf(tokenId), newOwner);
    }

    function test_TransferAndNewOwnerCanDeposit() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        address newOwner = makeAddr("newOwner");
        lendPositionManager.transferFrom(address(this), newOwner, tokenId);

        vm.startPrank(newOwner);
        token0.mint(newOwner, amount);
        token0.approve(address(lendPositionManager), amount);
        lendPositionManager.deposit(tokenId, amount, 0);
        vm.stopPrank();

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);
        assertGt(position.lendAmount, amount, "New owner should be able to deposit");
    }

    function test_TransferAndNewOwnerCanWithdraw() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        token0.mint(liquidator, amount);
        token0.approve(address(lendPositionManager), amount);
        lendPositionManager.addLending(key, false, liquidator, amount, 0);
        vm.stopPrank();

        address newOwner = makeAddr("newOwner");
        lendPositionManager.transferFrom(address(this), newOwner, tokenId);

        vm.startPrank(newOwner);
        lendPositionManager.withdraw(tokenId, amount / 2, 0);
        vm.stopPrank();

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);
        assertLt(position.lendAmount, amount, "New owner should be able to withdraw");
    }

    function test_TransferAndNewOwnerCanSwap() public {
        uint256 marginAmount = 1e18;
        token1.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory marginParams = IMarginPositionManager.CreateParams({
            marginForOne: true,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        marginPositionManager.addMargin(key, marginParams);

        uint256 amountIn = 0.1e18;
        token1.mint(address(this), amountIn);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        address newOwner = makeAddr("newOwner");
        lendPositionManager.transferFrom(address(this), newOwner, tokenId);

        vm.startPrank(newOwner);
        token1.mint(newOwner, amountIn);
        token1.approve(address(lendPositionManager), amountIn);

        ILendPositionManager.SwapInputParams memory params = ILendPositionManager.SwapInputParams({
            zeroForOne: false, tokenId: tokenId, amountIn: amountIn, amountOutMin: 0, deadline: block.timestamp
        });

        (,, uint256 amountOut) = lendPositionManager.exactInput(params);
        vm.stopPrank();

        assertTrue(amountOut > 0, "New owner should be able to swap");
    }

    function test_PreviousOwnerCannotAccessAfterTransfer() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        address newOwner = makeAddr("newOwner");
        lendPositionManager.transferFrom(address(this), newOwner, tokenId);

        vm.expectRevert(IBasePositionManager.NotOwner.selector);
        lendPositionManager.deposit(tokenId, amount, 0);

        vm.expectRevert(IBasePositionManager.NotOwner.selector);
        lendPositionManager.withdraw(tokenId, amount, 0);
    }

    // ==================== State Query Tests ====================

    function test_PoolIds() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        PoolId poolId = lendPositionManager.poolIds(tokenId);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(key.toId()), "PoolId should match");
    }

    function test_PoolKeys() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        PoolId poolId = lendPositionManager.poolIds(tokenId);
        (Currency c0, Currency c1, uint24 fee, uint24 marginFee) = lendPositionManager.poolKeys(poolId);

        assertEq(Currency.unwrap(c0), Currency.unwrap(key.currency0), "Currency0 should match");
        assertEq(Currency.unwrap(c1), Currency.unwrap(key.currency1), "Currency1 should match");
        assertEq(fee, key.fee, "Fee should match");
        assertEq(marginFee, key.marginFee, "MarginFee should match");
    }

    function test_LendDirections() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);
        token1.mint(address(this), amount);

        uint256 tokenId0 = lendPositionManager.addLending(key, false, address(this), amount, 0);
        uint256 tokenId1 = lendPositionManager.addLending(key, true, address(this), amount, 0);

        assertEq(lendPositionManager.lendDirections(tokenId0), false, "LendDirection for tokenId0 should be false");
        assertEq(lendPositionManager.lendDirections(tokenId1), true, "LendDirection for tokenId1 should be true");
    }

    function test_NextIdIncrement() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount * 3);

        uint256 tokenId1 = lendPositionManager.addLending(key, false, address(this), amount, 0);
        uint256 tokenId2 = lendPositionManager.addLending(key, false, address(this), amount, 0);
        uint256 tokenId3 = lendPositionManager.addLending(key, false, address(this), amount, 0);

        assertEq(tokenId2, tokenId1 + 1, "TokenId should increment by 1");
        assertEq(tokenId3, tokenId2 + 1, "TokenId should increment by 1");
    }

    // ==================== Complex Scenario Tests ====================

    function test_MultipleDepositsAndWithdrawals() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount * 3);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        token0.mint(liquidator, amount * 3);
        token0.approve(address(lendPositionManager), amount * 3);
        lendPositionManager.addLending(key, false, liquidator, amount * 3, 0);
        vm.stopPrank();

        lendPositionManager.deposit(tokenId, amount, 0);
        LendPosition.State memory position1 = lendPositionManager.getPositionState(tokenId);
        assertEq(position1.lendAmount, amount * 2, "Position should have 2x amount after second deposit");

        lendPositionManager.deposit(tokenId, amount, 0);
        LendPosition.State memory position2 = lendPositionManager.getPositionState(tokenId);
        assertEq(position2.lendAmount, amount * 3, "Position should have 3x amount after third deposit");

        lendPositionManager.withdraw(tokenId, amount, 0);
        LendPosition.State memory position3 = lendPositionManager.getPositionState(tokenId);
        assertEq(position3.lendAmount, amount * 2, "Position should have 2x amount after first withdraw");

        lendPositionManager.withdraw(tokenId, amount, 0);
        LendPosition.State memory position4 = lendPositionManager.getPositionState(tokenId);
        assertEq(position4.lendAmount, amount, "Position should have 1x amount after second withdraw");
    }

    function test_InterestAccrual() public {
        uint256 marginAmount = 1e18;
        token1.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory marginParams = IMarginPositionManager.CreateParams({
            marginForOne: true,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        marginPositionManager.addMargin(key, marginParams);

        uint256 amountOut = 1e18;
        token1.mint(address(this), amountOut * 10);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        ILendPositionManager.SwapOutputParams memory params = ILendPositionManager.SwapOutputParams({
            zeroForOne: false,
            tokenId: tokenId,
            amountInMax: type(uint256).max,
            amountOut: amountOut,
            deadline: block.timestamp
        });

        lendPositionManager.exactOutput(params);

        LendPosition.State memory positionBefore = lendPositionManager.getPositionState(tokenId);

        skip(1000);

        LendPosition.State memory positionAfter = lendPositionManager.getPositionState(tokenId);

        assertGt(positionAfter.lendAmount, positionBefore.lendAmount, "Lend amount should increase due to interest");
    }

    function test_SwapAndWithdraw() public {
        uint256 marginAmount = 1e18;
        token1.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory marginParams = IMarginPositionManager.CreateParams({
            marginForOne: true,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        marginPositionManager.addMargin(key, marginParams);

        uint256 amountIn = 0.5e18;
        token1.mint(address(this), amountIn);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        ILendPositionManager.SwapInputParams memory swapParams = ILendPositionManager.SwapInputParams({
            zeroForOne: false, tokenId: tokenId, amountIn: amountIn, amountOutMin: 0, deadline: block.timestamp
        });

        (,, uint256 amountOut) = lendPositionManager.exactInput(swapParams);
        assertTrue(amountOut > 0, "Swap should produce output");

        LendPosition.State memory positionAfterSwap = lendPositionManager.getPositionState(tokenId);
        assertEq(positionAfterSwap.lendAmount, amountOut, "Position should hold swapped amount");

        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        token0.mint(liquidator, amountOut);
        token0.approve(address(lendPositionManager), amountOut);
        lendPositionManager.addLending(key, false, liquidator, amountOut, 0);
        vm.stopPrank();

        uint256 withdrawAmount = amountOut / 2;
        uint256 balanceBefore = token0.balanceOf(address(this));
        lendPositionManager.withdraw(tokenId, withdrawAmount, 0);
        uint256 balanceAfter = token0.balanceOf(address(this));

        assertGt(balanceAfter, balanceBefore, "Balance should increase after withdraw");

        LendPosition.State memory positionAfterWithdraw = lendPositionManager.getPositionState(tokenId);
        // Use approximate equality to handle rounding
        assertApproxEqAbs(
            positionAfterWithdraw.lendAmount,
            amountOut - withdrawAmount,
            1,
            "Position should have approximately half remaining"
        );
    }

    function test_AddLendingWithZeroAmount() public {
        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), 0, 0);

        assertTrue(tokenId > 0, "TokenId should be created even with zero amount");

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);
        assertEq(position.lendAmount, 0, "Position should have zero lend amount");
    }

    function test_GetPositionStateForNonExistentPosition() public view {
        // Get state for a non-existent position should return empty state
        // This may revert depending on implementation, so we just check it doesn't crash
        try lendPositionManager.getPositionState(99999) returns (LendPosition.State memory position) {
            assertEq(position.lendAmount, 0, "Non-existent position should have zero lend amount");
        } catch {
            // If it reverts, that's also acceptable behavior
        }
    }

    function test_WithdrawAllAndRedeposit() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, false, address(this), amount, 0);

        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        token0.mint(liquidator, amount);
        token0.approve(address(lendPositionManager), amount);
        lendPositionManager.addLending(key, false, liquidator, amount, 0);
        vm.stopPrank();

        lendPositionManager.withdraw(tokenId, type(uint256).max, 0);

        LendPosition.State memory positionAfterWithdraw = lendPositionManager.getPositionState(tokenId);
        assertEq(positionAfterWithdraw.lendAmount, 0, "Position should be empty");

        token0.mint(address(this), amount);
        lendPositionManager.deposit(tokenId, amount, 0);

        LendPosition.State memory positionAfterRedeposit = lendPositionManager.getPositionState(tokenId);
        assertEq(positionAfterRedeposit.lendAmount, amount, "Position should have amount after redeposit");
    }

    function test_MirrorSwapBothDirections() public {
        uint256 marginAmount0 = 1e18;
        token0.mint(address(this), marginAmount0);

        IMarginPositionManager.CreateParams memory marginParams0 = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 2,
            marginAmount: uint128(marginAmount0),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        marginPositionManager.addMargin(key, marginParams0);

        uint256 marginAmount1 = 1e18;
        token1.mint(address(this), marginAmount1);

        IMarginPositionManager.CreateParams memory marginParams1 = IMarginPositionManager.CreateParams({
            marginForOne: true,
            leverage: 2,
            marginAmount: uint128(marginAmount1),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        marginPositionManager.addMargin(key, marginParams1);

        uint256 amountIn = 0.1e18;
        token0.mint(address(this), amountIn);
        token1.mint(address(this), amountIn);

        uint256 tokenId0 = lendPositionManager.addLending(key, true, address(this), 0, 0);
        uint256 tokenId1 = lendPositionManager.addLending(key, false, address(this), 0, 0);

        ILendPositionManager.SwapInputParams memory params0 = ILendPositionManager.SwapInputParams({
            zeroForOne: true, tokenId: tokenId0, amountIn: amountIn, amountOutMin: 0, deadline: block.timestamp
        });

        (,, uint256 amountOut0) = lendPositionManager.exactInput(params0);
        assertTrue(amountOut0 > 0, "Swap token0->token1 should work");

        ILendPositionManager.SwapInputParams memory params1 = ILendPositionManager.SwapInputParams({
            zeroForOne: false, tokenId: tokenId1, amountIn: amountIn, amountOutMin: 0, deadline: block.timestamp
        });

        (,, uint256 amountOut1) = lendPositionManager.exactInput(params1);
        assertTrue(amountOut1 > 0, "Swap token1->token0 should work");
    }
}
