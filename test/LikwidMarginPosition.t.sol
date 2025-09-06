// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LikwidVault} from "../src/LikwidVault.sol";
import {LikwidMarginPosition} from "../src/LikwidMarginPosition.sol";
import {LikwidPairPosition} from "../src/LikwidPairPosition.sol";
import {IMarginPositionManager} from "../src/interfaces/IMarginPositionManager.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";
import {StateLibrary} from "../src/libraries/StateLibrary.sol";
import {Reserves} from "../src/types/Reserves.sol";
import {MarginPosition} from "../src/libraries/MarginPosition.sol";

error ERC721NonexistentToken(uint256 tokenId);

contract LikwidMarginPositionTest is Test {
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

    function testAddMargin() public {
        // 1. Arrange
        uint256 marginAmount = 1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            recipient: address(this),
            marginForOne: false,
            leverage: 2,
            marginAmount: marginAmount,
            borrowAmount: 0,
            borrowAmountMax: 2e18,
            deadline: block.timestamp + 1
        });

        // 2. Act
        (uint256 tokenId, uint256 borrowAmount) = marginPositionManager.addMargin(key, params);

        // 3. Assert
        assertEq(tokenId, 1, "First token minted should have ID 1");
        assertEq(marginPositionManager.ownerOf(tokenId), address(this), "Owner of new token should be the caller");
        assertTrue(borrowAmount > 0, "Borrow amount should be greater than zero");

        (bool marginForOne, bool isBorrow) = marginPositionManager.positionInfos(tokenId);
        assertEq(marginForOne, false, "marginForOne should be false");
        assertFalse(isBorrow, "isBorrow should be false");
    }

    function testAddMarginInsufficientBorrowReceived() public {
        // 1. Arrange
        uint256 marginAmount = 1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            recipient: address(this),
            marginForOne: false,
            leverage: 2,
            marginAmount: marginAmount,
            borrowAmount: 0,
            borrowAmountMax: 1e18,
            deadline: block.timestamp + 1
        });

        vm.expectRevert(abi.encodeWithSelector(IMarginPositionManager.InsufficientBorrowReceived.selector));
        marginPositionManager.addMargin(key, params);
    }

    function testAddMarginBorrow() public {
        // 1. Arrange
        uint256 marginAmount = 1e18;
        uint256 borrowAmount = 0.5e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            recipient: address(this),
            marginForOne: false,
            leverage: 0,
            marginAmount: marginAmount,
            borrowAmount: borrowAmount,
            borrowAmountMax: borrowAmount,
            deadline: block.timestamp + 1
        });

        // 2. Act
        (uint256 tokenId,) = marginPositionManager.addMargin(key, params);

        // 3. Assert
        assertEq(tokenId, 1, "First token minted should have ID 1");
        assertEq(marginPositionManager.ownerOf(tokenId), address(this), "Owner of new token should be the caller");

        (bool marginForOne, bool isBorrow) = marginPositionManager.positionInfos(tokenId);
        assertEq(marginForOne, false, "marginForOne should be false");
        assertTrue(isBorrow, "isBorrow should be true");
    }

    function testRepay() public {
        // 1. Arrange
        uint256 marginAmount = 1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            recipient: address(this),
            marginForOne: false,
            leverage: 2, // Using leverage
            marginAmount: marginAmount,
            borrowAmount: 0,
            borrowAmountMax: 2e18,
            deadline: block.timestamp + 1
        });
        (uint256 tokenId, uint256 borrowAmount) = marginPositionManager.addMargin(key, params);
        assertEq(token0.balanceOf(address(this)), 0, "Cost all token0");

        // 2. Act
        uint256 repayAmount = borrowAmount / 2;
        token1.mint(address(this), repayAmount);
        marginPositionManager.repay(tokenId, repayAmount, block.timestamp + 1);

        // 3. Assert
        MarginPosition.State memory positionState = marginPositionManager.getPositionState(tokenId);
        assertTrue(positionState.debtAmount < borrowAmount, "Debt should be reduced");
        assertTrue(positionState.debtAmount == uint128(borrowAmount - repayAmount), "Debt should be reduced");
        skip(1000);
        positionState = marginPositionManager.getPositionState(tokenId);
        assertTrue(positionState.debtAmount > uint128(borrowAmount - repayAmount), "Interests added.");
    }

    function testClose() public {
        // 1. Arrange
        uint256 marginAmount = 1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            recipient: address(this),
            marginForOne: false,
            leverage: 2, // Using leverage
            marginAmount: marginAmount,
            borrowAmount: 0,
            borrowAmountMax: 2e18,
            deadline: block.timestamp + 1
        });
        (uint256 tokenId,) = marginPositionManager.addMargin(key, params);
        uint256 balanceBefore = token0.balanceOf(address(this));

        // 2. Act
        marginPositionManager.close(tokenId, 1_000_000, 0, block.timestamp + 1);

        // 3. Assert
        uint256 balanceAfter = token0.balanceOf(address(this));
        assertTrue(balanceAfter > balanceBefore, "Collateral should be returned");
        vm.expectRevert(abi.encodeWithSelector(ERC721NonexistentToken.selector, tokenId));
        marginPositionManager.ownerOf(tokenId);
    }
}
