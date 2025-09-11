// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LikwidVault} from "../src/LikwidVault.sol";
import {LikwidLendPosition} from "../src/LikwidLendPosition.sol";
import {LikwidPairPosition} from "../src/LikwidPairPosition.sol";
import {LikwidMarginPosition} from "../src/LikwidMarginPosition.sol";
import {ILendPositionManager} from "../src/interfaces/ILendPositionManager.sol";
import {IMarginPositionManager} from "../src/interfaces/IMarginPositionManager.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IUnlockCallback} from "../src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";
import {StateLibrary} from "../src/libraries/StateLibrary.sol";
import {Reserves} from "../src/types/Reserves.sol";
import {LendPosition} from "../src/libraries/LendPosition.sol";
import {BalanceDelta} from "../src/types/BalanceDelta.sol";

contract LikwidLendPositionTest is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    LikwidVault vault;
    LikwidLendPosition lendPositionManager;
    LikwidPairPosition pairPositionManager;
    LikwidMarginPosition marginPositionManager;
    PoolKey key;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;

    function setUp() public {
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
        key = PoolKey({currency0: currency0, currency1: currency1, fee: fee});
        vault.initialize(key);

        uint256 amount0ToAdd = 1000e18;
        uint256 amount1ToAdd = 2000e18;
        token0.mint(address(this), amount0ToAdd);
        token1.mint(address(this), amount1ToAdd);
        pairPositionManager.addLiquidity(key, amount0ToAdd, amount1ToAdd, 0, 0);
    }

    function testAddLending() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, currency0, address(this), amount);

        assertTrue(tokenId > 0);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);

        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testDeposit() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, currency0, address(this), 0);

        lendPositionManager.deposit(tokenId, amount);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);

        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testWithdraw() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, currency0, address(this), amount);

        LendPosition.State memory positionBefore = lendPositionManager.getPositionState(tokenId);

        lendPositionManager.withdraw(tokenId, amount / 2);

        LendPosition.State memory positionAfter = lendPositionManager.getPositionState(tokenId);

        assertTrue(
            positionAfter.lendAmount < positionBefore.lendAmount, "position.lendAmount should be less after withdraw"
        );
    }

    function testGetPositionState() public {
        uint256 amount = 1e18;
        token0.mint(address(this), amount);

        uint256 tokenId = lendPositionManager.addLending(key, currency0, address(this), amount);

        LendPosition.State memory position = lendPositionManager.getPositionState(tokenId);

        assertEq(position.lendAmount, amount, "position.lendAmount==amount");
    }

    function testMirrorExactInput() public {
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

        (uint256 marginTokenId, uint256 borrowAmount) = marginPositionManager.addMargin(key, marginParams);
        console.log("marginTokenId:%s,borrowAmount:%s", marginTokenId, borrowAmount);
        assertTrue(marginTokenId > 0, "marginTokenId should be greater than 0");
        assertTrue(borrowAmount > 0, "borrowAmount should be greater than 0");

        uint256 amountIn = 0.1e18;
        token1.mint(address(this), amountIn);

        uint256 tokenId = lendPositionManager.addLending(key, currency0, address(this), 0);

        LendPosition.State memory positionBefore = lendPositionManager.getPositionState(tokenId);
        assertEq(positionBefore.lendAmount, 0, "lendAmount should be zero");
        // swap mirror token0
        LikwidLendPosition.SwapInputParams memory params = LikwidLendPosition.SwapInputParams({
            poolId: key.toId(),
            zeroForOne: false,
            tokenId: tokenId,
            amountIn: amountIn,
            amountOutMin: 0,
            deadline: block.timestamp
        });

        (,, uint256 amountOut) = lendPositionManager.exactInput(params);

        assertTrue(amountOut > 0, "amountOut should be greater than 0");

        LendPosition.State memory positionAfter = lendPositionManager.getPositionState(tokenId);

        assertEq(positionAfter.lendAmount, amountOut, "lendAmount should be amountOut");
    }

    function testMirrorExactOutput() public {
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

        (uint256 marginTokenId, uint256 borrowAmount) = marginPositionManager.addMargin(key, marginParams);
        console.log("marginTokenId:%s,borrowAmount:%s", marginTokenId, borrowAmount);
        assertTrue(marginTokenId > 0, "marginTokenId should be greater than 0");
        assertTrue(borrowAmount > 0, "borrowAmount should be greater than 0");

        uint256 amountOut = 1e18;
        token1.mint(address(this), amountOut * 10);

        uint256 tokenId = lendPositionManager.addLending(key, currency0, address(this), 0);

        LendPosition.State memory positionBefore = lendPositionManager.getPositionState(tokenId);
        assertEq(positionBefore.lendAmount, 0, "positionBefore.lendAmount should be zero");
        // swap mirror token0
        LikwidLendPosition.SwapOutputParams memory params = LikwidLendPosition.SwapOutputParams({
            poolId: key.toId(),
            zeroForOne: false,
            tokenId: tokenId,
            amountInMax: 0,
            amountOut: amountOut,
            deadline: block.timestamp
        });

        (,, uint256 amountInResult) = lendPositionManager.exactOutput(params);

        assertTrue(amountInResult > 0, "amountIn should be greater than 0");

        LendPosition.State memory positionAfter = lendPositionManager.getPositionState(tokenId);

        assertEq(positionAfter.lendAmount, amountOut, "lendAmount should be amountOut");
    }
}
