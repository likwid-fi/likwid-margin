// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LikwidVault} from "../src/LikwidVault.sol";
import {LikwidMarginPosition} from "../src/LikwidMarginPosition.sol";
import {LikwidPairPosition} from "../src/LikwidPairPosition.sol";
import {LikwidHelper} from "./utils/LikwidHelper.sol";
import {IMarginPositionManager} from "../src/interfaces/IMarginPositionManager.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IUnlockCallback} from "../src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";
import {MarginPosition} from "../src/libraries/MarginPosition.sol";
import {BalanceDelta} from "../src/types/BalanceDelta.sol";
import {MarginLevels, MarginLevelsLibrary} from "../src/types/MarginLevels.sol";
import {PoolState} from "../src/types/PoolState.sol";
import {Reserves} from "../src/types/Reserves.sol";
import {InsuranceFunds} from "../src/types/InsuranceFunds.sol";
import {StateLibrary} from "../src/libraries/StateLibrary.sol";
import {CurrentStateLibrary} from "../src/libraries/CurrentStateLibrary.sol";

contract LikwidMarginPositionTest is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using MarginLevelsLibrary for MarginLevels;

    event MarginLevelChanged(bytes32 oldMarginLevel, bytes32 newMarginLevel);
    event MarginFeeChanged(uint24 oldMarginFee, uint24 newMarginFee);

    LikwidVault vault;
    LikwidMarginPosition marginPositionManager;
    LikwidPairPosition pairPositionManager;
    LikwidHelper helper;
    PoolKey key;
    PoolKey keyNative;
    PoolKey keyLowFee;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;

    function setUp() public {
        // Deploy Vault and Position Manager
        vault = new LikwidVault(address(this));
        marginPositionManager = new LikwidMarginPosition(address(this), vault);
        pairPositionManager = new LikwidPairPosition(address(this), vault);
        helper = new LikwidHelper(address(this), vault);

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
        key = PoolKey({currency0: currency0, currency1: currency1, fee: fee, marginFee: 3000});
        vault.initialize(key);

        keyLowFee = PoolKey({currency0: currency0, currency1: currency1, fee: 1000, marginFee: 3000});
        vault.initialize(keyLowFee);

        keyNative = PoolKey({currency0: CurrencyLibrary.ADDRESS_ZERO, currency1: currency1, fee: fee, marginFee: 3000});
        vault.initialize(keyNative);

        uint256 amount0ToAdd = 10e18;
        uint256 amount1ToAdd = 20e18;
        token0.mint(address(this), amount0ToAdd);
        token1.mint(address(this), amount1ToAdd);
        pairPositionManager.addLiquidity(key, address(this), amount0ToAdd, amount1ToAdd, 0, 0, 10000);

        token1.mint(address(this), amount1ToAdd);
        pairPositionManager.addLiquidity{value: amount0ToAdd}(
            keyNative, address(this), amount0ToAdd, amount1ToAdd, 0, 0, 10000
        );
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

    fallback() external payable {}
    receive() external payable {}

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

        (uint256 tokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, params);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);

        assertEq(position.marginAmount, marginAmount, "position.marginAmount==marginAmount");
        assertEq(position.debtAmount, borrowAmount, "position.debtAmount==borrowAmount");
        uint256 protocolMarginFees = vault.protocolFeesAccrued(key.currency0);
        assertTrue(protocolMarginFees > 0, "protocolMarginFees should be accrued");
        uint256 protocolMarginSwapFees = vault.protocolFeesAccrued(key.currency1);
        assertTrue(protocolMarginSwapFees > 0, "protocolMarginSwapFees should be accrued");
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

        (uint256 tokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, params);

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

        skip(1000);

        positionBefore = marginPositionManager.getPositionState(tokenId);

        repayAmount = positionBefore.debtAmount + 100;
        assertTrue(repayAmount > borrowAmount / 2, "repayAmount should be greater than borrowAmount / 2");
        token1.mint(address(this), repayAmount);
        marginPositionManager.repay(tokenId, repayAmount, block.timestamp);
        positionAfter = marginPositionManager.getPositionState(tokenId);
        assertTrue(positionAfter.debtAmount == 0, "position.debtAmount should be zero after full repay");
        assertEq(
            token1.balanceOf(address(this)), repayAmount - positionBefore.debtAmount, "excess repay should be returned"
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

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);

        marginPositionManager.close(tokenId, 500_000, 0, block.timestamp);
        // close 50%
        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);

        assertGt(position.marginAmount, 0, "position.marginAmount should not be 0 after close");
        assertGt(position.debtAmount, 0, "position.debtAmount should not be 0 after close");

        skip(1000);

        marginPositionManager.close(tokenId, 1_000_000, 0, block.timestamp); // close remaining

        position = marginPositionManager.getPositionState(tokenId);

        assertEq(position.marginAmount, 0, "position.marginAmount should be 0 after close");
        assertEq(position.debtAmount, 0, "position.debtAmount should be 0 after close");
    }

    function testRepayAndClose() public {
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

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);

        marginPositionManager.close(tokenId, 500_000, 0, block.timestamp);
        // close 50%
        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);

        assertGt(position.marginAmount, 0, "position.marginAmount should not be 0 after close");
        assertGt(position.debtAmount, 0, "position.debtAmount should not be 0 after close");

        skip(1000);

        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);
        uint256 repayAmount = positionBefore.debtAmount / 2;
        token1.mint(address(this), repayAmount);
        marginPositionManager.repay(tokenId, repayAmount, block.timestamp);

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertTrue(
            positionAfter.debtAmount < positionBefore.debtAmount, "position.debtAmount should be less after repay"
        );

        skip(1000);

        marginPositionManager.close(tokenId, 1_000_000, 0, block.timestamp); // close remaining

        position = marginPositionManager.getPositionState(tokenId);

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

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);

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

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);
        skip(1000);
        // Manipulate price to make position liquidatable
        // Swap a large amount of token0 for token1 to drive the price of token0 down
        uint256 swapAmount = 5e18;
        token0.mint(address(this), swapAmount);

        // Perform swap on the vault
        IVault.SwapParams memory swapParams = IVault.SwapParams({
            zeroForOne: true, amountSpecified: -int256(swapAmount), useMirror: false, salt: bytes32(0)
        });
        bytes memory innerParamsSwap = abi.encode(key, swapParams);
        bytes memory dataSwap = abi.encode(this.swap_callback.selector, innerParamsSwap);
        vault.unlock(dataSwap);
        skip(1000);
        bool liquidated = helper.checkMarginPositionLiquidate(tokenId);
        assertTrue(liquidated, "Position should be liquidatable");

        // Liquidate
        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        token1.mint(liquidator, 100e18); // give liquidator funds to repay debt
        token1.approve(address(vault), 100e18);
        token1.approve(address(marginPositionManager), 100e18);

        (uint256 profit,) = marginPositionManager.liquidateCall(tokenId, 0);
        vm.stopPrank();

        assertTrue(profit > 0, "Liquidator should make a profit");

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.debtAmount, 0, "position.debtAmount should be 0 after liquidation");
        assertEq(position.marginAmount, 0, "position.marginAmount should be 0 after liquidation");
        assertEq(position.marginTotal, 0, "position.marginTotal should be 0 after liquidation");
    }

    function testLiquidateBurn() public {
        uint256 marginAmount = 0.1 ether;
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

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);
        skip(1000);
        // Manipulate price to make position liquidatable
        // Swap a large amount of token0 for token1 to drive the price of token0 down
        uint256 swapAmount = 5 ether;
        token0.mint(address(this), swapAmount);

        // Perform swap on the vault
        IVault.SwapParams memory swapParams = IVault.SwapParams({
            zeroForOne: true, amountSpecified: -int256(swapAmount), useMirror: false, salt: bytes32(0)
        });
        bytes memory innerParamsSwap = abi.encode(key, swapParams);
        bytes memory dataSwap = abi.encode(this.swap_callback.selector, innerParamsSwap);
        vault.unlock(dataSwap);
        skip(1000);
        bool liquidated = helper.checkMarginPositionLiquidate(tokenId);
        assertTrue(liquidated, "Position should be liquidatable");
        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        // Liquidate
        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        LikwidHelper.PoolStateInfo memory poolStateBefore = helper.getPoolStateInfo(key.toId());
        uint256 protocolFeesBefore = vault.protocolFeesAccrued(key.currency1);
        uint256 profit = marginPositionManager.liquidateBurn(tokenId, 0);
        vm.stopPrank();

        assertTrue(profit > 0, "Liquidator should make a profit");
        LikwidHelper.PoolStateInfo memory poolStateAfter = helper.getPoolStateInfo(key.toId());
        uint256 protocolFeesAfter = vault.protocolFeesAccrued(key.currency1);
        assertEq(
            poolStateBefore.lendReserve0 - poolStateAfter.lendReserve0,
            position.marginAmount + position.marginTotal,
            "Pool lendReserve0 should decrease by position.marginAmount + position.marginTotal"
        );
        assertLt(protocolFeesBefore, protocolFeesAfter, "Protocol fees should increase after liquidation");
        assertApproxEqAbs(
            poolStateBefore.mirrorReserve1 + poolStateBefore.realReserve1
                - (poolStateAfter.mirrorReserve1 + poolStateAfter.realReserve1),
            position.debtAmount,
            10,
            "Pool reserve1 decrease should be approx position.debtAmount"
        );
        assertLt(
            poolStateAfter.pairReserve0 - poolStateBefore.pairReserve0,
            position.marginAmount + position.marginTotal - profit,
            "Pool pairReserve0 should increase by position.marginAmount + position.marginTotal- profit"
        );
        position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.debtAmount, 0, "position.debtAmount should be 0 after liquidation");
        assertEq(position.marginAmount, 0, "position.marginAmount should be 0 after liquidation");
        assertEq(position.marginTotal, 0, "position.marginTotal should be 0 after liquidation");

        swapAmount = token1.balanceOf(address(this));
        swapParams = IVault.SwapParams({
            zeroForOne: false, amountSpecified: -int256(swapAmount), useMirror: false, salt: bytes32(0)
        });
        innerParamsSwap = abi.encode(key, swapParams);
        dataSwap = abi.encode(this.swap_callback.selector, innerParamsSwap);
        vault.unlock(dataSwap);
        assertEq(token1.balanceOf(address(this)), 0, "All token1 should be swapped out");
    }

    function testLiquidateBurn_Batch() public {
        for (uint256 i = 0; i < 2; i++) {
            testLiquidateBurn();
        }
    }

    function testLiquidateBurn_HasCloseAmount() public {
        InsuranceFunds insuranceFundsBefore = StateLibrary.getInsuranceFunds(vault, key.toId());
        assertEq(insuranceFundsBefore.amount0(), 0, "insuranceFundsBefore.amount0==0");
        assertEq(insuranceFundsBefore.amount1(), 0, "insuranceFundsBefore.amount1==0");
        uint256 marginAmount = 0.1 ether;
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

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);
        skip(1000);
        // Manipulate price to make position liquidatable
        // Swap a large amount of token0 for token1 to drive the price of token0 down
        uint256 swapAmount = 1.0 ether;
        token0.mint(address(this), swapAmount);

        // Perform swap on the vault
        IVault.SwapParams memory swapParams = IVault.SwapParams({
            zeroForOne: true, amountSpecified: -int256(swapAmount), useMirror: false, salt: bytes32(0)
        });
        bytes memory innerParamsSwap = abi.encode(key, swapParams);
        bytes memory dataSwap = abi.encode(this.swap_callback.selector, innerParamsSwap);
        vault.unlock(dataSwap);
        skip(1000);
        bool liquidated = helper.checkMarginPositionLiquidate(tokenId);
        assertTrue(liquidated, "Position should be liquidatable");
        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        // Liquidate
        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        LikwidHelper.PoolStateInfo memory poolStateBefore = helper.getPoolStateInfo(key.toId());
        uint256 protocolFeesBefore0 = vault.protocolFeesAccrued(key.currency0);
        uint256 protocolFeesBefore1 = vault.protocolFeesAccrued(key.currency1);
        uint256 profit = marginPositionManager.liquidateBurn(tokenId, 0);
        vm.stopPrank();

        assertTrue(profit > 0, "Liquidator should make a profit");
        LikwidHelper.PoolStateInfo memory poolStateAfter = helper.getPoolStateInfo(key.toId());
        uint256 protocolFeesAfter0 = vault.protocolFeesAccrued(key.currency0);
        uint256 protocolFeesAfter1 = vault.protocolFeesAccrued(key.currency1);
        assertEq(
            poolStateBefore.lendReserve0 - poolStateAfter.lendReserve0,
            position.marginAmount + position.marginTotal,
            "Pool lendReserve0 should decrease by position.marginAmount + position.marginTotal"
        );
        assertLt(protocolFeesBefore1, protocolFeesAfter1, "Protocol fees should increase after liquidation");
        assertApproxEqAbs(
            poolStateBefore.mirrorReserve1 + poolStateBefore.realReserve1
                - (poolStateAfter.mirrorReserve1 + poolStateAfter.realReserve1),
            position.debtAmount,
            10,
            "Pool reserve1 decrease should be approx position.debtAmount"
        );
        uint256 totalMarginAmount = position.marginAmount + position.marginTotal;
        assertLt(
            poolStateAfter.pairReserve0 - poolStateBefore.pairReserve0,
            totalMarginAmount - profit,
            "Pool pairReserve0 should increase by position.marginAmount + position.marginTotal- profit"
        );
        position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.debtAmount, 0, "position.debtAmount should be 0 after liquidation");
        assertEq(position.marginAmount, 0, "position.marginAmount should be 0 after liquidation");
        assertEq(position.marginTotal, 0, "position.marginTotal should be 0 after liquidation");

        swapAmount = token1.balanceOf(address(this));
        swapParams = IVault.SwapParams({
            zeroForOne: false, amountSpecified: -int256(swapAmount), useMirror: false, salt: bytes32(0)
        });
        innerParamsSwap = abi.encode(key, swapParams);
        dataSwap = abi.encode(this.swap_callback.selector, innerParamsSwap);
        vault.unlock(dataSwap);
        assertEq(token1.balanceOf(address(this)), 0, "All token1 should be swapped out");

        InsuranceFunds insuranceFundsAfter = StateLibrary.getInsuranceFunds(vault, key.toId());
        assertGt(insuranceFundsAfter.amount0(), insuranceFundsBefore.amount0(), "insuranceFundsAfter.amount0>before");
        assertApproxEqAbs(
            insuranceFundsAfter.amount1(), insuranceFundsBefore.amount1(), 10, "insuranceFundsAfter.amount1 ~= before"
        );
        assertEq(
            poolStateAfter.pairReserve0 - poolStateBefore.pairReserve0 + protocolFeesAfter0 - protocolFeesBefore0,
            totalMarginAmount - profit - uint128(insuranceFundsAfter.amount0() - insuranceFundsBefore.amount0()),
            "pairReserve0Changed + protocolFees0Changed == totalMarginAmount - profit - insuranceFunds0Changed"
        );
        assertEq(
            poolStateBefore.realReserve0 - poolStateAfter.realReserve0 + protocolFeesBefore0 - protocolFeesAfter0,
            profit,
            "realReserve0 decrease + protocolFees0Changed should equal profit"
        );

        PoolId poolId = key.toId();
        (,,,,, uint8 insuranceFundPercentage) = StateLibrary.getSlot0(vault, poolId);
        Reserves insuranceFundUpperLimit = StateLibrary.getInsuranceFundUpperLimit(vault, poolId);
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        Reserves realReserves = state.realReserves;
        Reserves mirrorReserves = state.mirrorReserves;
        Reserves totalReserves = realReserves + mirrorReserves;
        (uint256 r0, uint256 r1) = totalReserves.reserves();
        uint256 rLimit0 = (insuranceFundPercentage * r0) / 100;
        uint256 rLimit1 = (insuranceFundPercentage * r1) / 100;
        (uint256 limit0, uint256 limit1) = insuranceFundUpperLimit.reserves();

        assertLe(rLimit0, limit0, "Total reserve0 should be within insurance fund upper limit");
        assertLe(rLimit1, limit1, "Total reserve1 should be within insurance fund upper limit");
    }

    function testLiquidateBurn_AfterDonate() public {
        uint256 donationAmount0 = 10e18;
        uint256 donationAmount1 = 11e18;
        token0.mint(address(this), donationAmount0);
        token1.mint(address(this), donationAmount1);

        token0.approve(address(vault), donationAmount0);
        token1.approve(address(vault), donationAmount1);
        pairPositionManager.donate(key.toId(), donationAmount0, donationAmount1, 10000);

        InsuranceFunds insuranceFunds = StateLibrary.getInsuranceFunds(vault, key.toId());
        assertEq(
            uint128(insuranceFunds.amount0()),
            donationAmount0,
            "Insurance funds for currency0 should reflect the donation"
        );
        assertEq(
            uint128(insuranceFunds.amount1()),
            donationAmount1,
            "Insurance funds for currency1 should reflect the donation"
        );

        uint256 marginAmount = 0.1 ether;
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

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);
        skip(1000);

        uint256 swapAmount = 5 ether;
        token0.mint(address(this), swapAmount);

        // Perform swap on the vault
        IVault.SwapParams memory swapParams = IVault.SwapParams({
            zeroForOne: true, amountSpecified: -int256(swapAmount), useMirror: false, salt: bytes32(0)
        });
        bytes memory innerParamsSwap = abi.encode(key, swapParams);
        bytes memory dataSwap = abi.encode(this.swap_callback.selector, innerParamsSwap);
        vault.unlock(dataSwap);
        skip(1000);
        bool liquidated = helper.checkMarginPositionLiquidate(tokenId);
        assertTrue(liquidated, "Position should be liquidatable");
        // Liquidate
        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        uint256 profit = marginPositionManager.liquidateBurn(tokenId, 0);
        vm.stopPrank();

        assertTrue(profit > 0, "Liquidator should make a profit");

        insuranceFunds = StateLibrary.getInsuranceFunds(vault, key.toId());
        assertEq(
            uint128(insuranceFunds.amount0()),
            donationAmount0,
            "Insurance funds for currency0 should reflect the donation"
        );
        assertLt(
            uint128(insuranceFunds.amount1()),
            donationAmount1,
            "Insurance funds for currency1 should decrease after liquidation"
        );
    }

    function testAddMargin_MarginForOneTrue() public {
        uint256 marginAmount = 0.1e18;
        token1.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: true, // margin with token1, borrow token0
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, params);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);

        assertEq(position.marginAmount, marginAmount, "position.marginAmount==marginAmount");
        assertEq(position.debtAmount, borrowAmount, "position.debtAmount==borrowAmount");
        assertTrue(position.marginForOne, "position.marginForOne should be true");

        skip(1000);

        position = marginPositionManager.getPositionState(tokenId);

        assertEq(position.marginAmount, marginAmount, "position.marginAmount==marginAmount");
        assertGt(position.debtAmount, borrowAmount, "position.debtAmount>borrowAmount");
        assertTrue(position.marginForOne, "position.marginForOne should be true");
    }

    function testFuzz_AddMargin_NoLeverage(uint256 marginAmount) public {
        marginAmount = bound(marginAmount, 0.0001 ether, 1 ether);

        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 0, // No leverage, just add collateral and borrow
            marginAmount: uint128(marginAmount),
            borrowAmount: 1000, // borrow a small amount
            borrowAmountMax: 1000,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, params);
        assertTrue(tokenId > 0);
        assertEq(borrowAmount, 1000);
    }

    function testFuzz_AddMargin_MaxBorrowAmount(uint256 marginAmount) public {
        marginAmount = bound(marginAmount, 0.0001 ether, 1 ether);

        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 0, // No leverage, just add collateral and borrow
            marginAmount: uint128(marginAmount),
            borrowAmount: uint256(type(uint256).max), // borrow max
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, params);
        assertTrue(tokenId > 0);
        assertGt(borrowAmount, 1000);
    }

    function testAddMargin_MaxLeverage() public {
        MarginLevels newMarginLevels;
        newMarginLevels = newMarginLevels.setMinMarginLevel(1100000);
        newMarginLevels = newMarginLevels.setMinBorrowLevel(1200000);
        newMarginLevels = newMarginLevels.setLiquidateLevel(1050000);
        newMarginLevels = newMarginLevels.setLiquidationRatio(950000);
        newMarginLevels = newMarginLevels.setCallerProfit(10000);
        marginPositionManager.setMarginLevel(MarginLevels.unwrap(newMarginLevels));

        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 5, // MAX_LEVERAGE
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, params);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);
    }

    function testRepay_Full() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, params);

        token1.mint(address(this), borrowAmount);
        marginPositionManager.repay(tokenId, borrowAmount, block.timestamp);

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertTrue(positionAfter.debtAmount < 10, "position.debtAmount should be close to 0 after full repay");
    }

    function testClose_Partial() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);
        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

        marginPositionManager.close(tokenId, 500_000, 0, block.timestamp); // close 50%

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertApproxEqAbs(
            positionAfter.marginAmount, positionBefore.marginAmount / 2, 1, "marginAmount should be halved"
        );
        assertApproxEqAbs(positionAfter.debtAmount, positionBefore.debtAmount / 2, 1, "debtAmount should be halved");
    }

    function testModify_DecreaseCollateral() public {
        uint256 marginAmount = 0.2 ether;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);
        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

        int128 modifyAmount = -0.01 ether;
        marginPositionManager.modify(tokenId, modifyAmount);

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertEq(
            int256(uint256(positionAfter.marginAmount)),
            int256(uint256(positionBefore.marginAmount)) + modifyAmount,
            "position.marginAmount should be decreased"
        );
    }

    function testModify_DecreaseCollateral_InvalidLevel() public {
        uint256 marginAmount = 0.2 ether;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);
        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

        int128 modifyAmount = -0.05 ether;
        vm.expectRevert(IMarginPositionManager.InvalidLevel.selector);
        marginPositionManager.modify(tokenId, modifyAmount);

        skip(1000);
        modifyAmount = -0.01 ether;
        marginPositionManager.modify(tokenId, modifyAmount);

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertEq(
            int256(uint256(positionAfter.marginAmount)),
            int256(uint256(positionBefore.marginAmount)) + modifyAmount,
            "position.marginAmount should be decreased"
        );
    }

    function testModify_Fail_BelowMinBorrowLevel() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 4,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);

        int128 modifyAmount = -0.08e18; // Decrease collateral significantly
        vm.expectRevert(bytes4(keccak256("InvalidLevel()")));
        marginPositionManager.modify(tokenId, modifyAmount);
    }

    function testLiquidate_NotLiquidatable() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);

        bool liquidated = helper.checkMarginPositionLiquidate(tokenId);
        assertFalse(liquidated, "Position should not be liquidatable");

        vm.expectRevert(bytes4(keccak256("PositionNotLiquidated()")));
        marginPositionManager.liquidateCall(tokenId, 0);

        vm.expectRevert(bytes4(keccak256("PositionNotLiquidated()")));
        marginPositionManager.liquidateBurn(tokenId, 0);
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

    function testSetMarginLevel_NotOwner() public {
        bytes32 newLevels = keccak256(
            abi.encodePacked(
                uint24(1200000), uint24(1500000), uint24(1150000), uint24(900000), uint24(20000), uint24(10000)
            )
        );
        address notOwner = makeAddr("notOwner");
        vm.startPrank(notOwner);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        marginPositionManager.setMarginLevel(newLevels);
        vm.stopPrank();
    }

    function testAddMarginNative() public {
        uint256 marginAmount = 0.1e18;

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with native, borrow token1
            leverage: 2,
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

        assertEq(position.marginAmount, marginAmount, "position.marginAmount==marginAmount");
        assertEq(position.debtAmount, borrowAmount, "position.debtAmount==borrowAmount");
    }

    function testAddMarginNative_MarginForOneTrue() public {
        uint256 marginAmount = 0.1e18;
        token1.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: true, // margin with token1, borrow native
            leverage: 2,
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

        assertEq(position.marginAmount, marginAmount, "position.marginAmount==marginAmount");
        assertEq(position.debtAmount, borrowAmount, "position.debtAmount==borrowAmount");
        assertTrue(position.marginForOne, "position.marginForOne should be true");
    }

    function testRepayNative() public {
        uint256 marginAmount = 0.1e18;

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with native, borrow token1
            leverage: 2,
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

        uint256 repayAmount = borrowAmount / 2;
        token1.mint(address(this), repayAmount);

        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

        marginPositionManager.repay(tokenId, repayAmount, block.timestamp);

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertTrue(
            positionAfter.debtAmount < positionBefore.debtAmount, "position.debtAmount should be less after repay"
        );
    }

    function testRepayNative_RepayNative() public {
        uint256 marginAmount = 0.1e18;
        token1.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: true, // margin with token1, borrow native
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(keyNative, params);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);

        uint256 repayAmount = borrowAmount / 2;

        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

        marginPositionManager.repay{value: repayAmount}(tokenId, repayAmount, block.timestamp);

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertTrue(
            positionAfter.debtAmount < positionBefore.debtAmount, "position.debtAmount should be less after repay"
        );
    }

    function testCloseNative() public {
        uint256 marginAmount = 0.1e18;

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with native, borrow token1
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,,) = marginPositionManager.addMargin{value: marginAmount}(keyNative, params);

        uint256 balanceBefore = address(this).balance;
        marginPositionManager.close(tokenId, 1_000_000, 0, block.timestamp); // close 100%
        uint256 balanceAfter = address(this).balance;

        assertTrue(balanceAfter > balanceBefore, "should receive native currency back");

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);

        assertEq(position.marginAmount, 0, "position.marginAmount should be 0 after close");
        assertEq(position.debtAmount, 0, "position.debtAmount should be 0 after close");
    }

    function testModifyNative() public {
        uint256 marginAmount = 0.1e18;

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with native, borrow token1
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,,) = marginPositionManager.addMargin{value: marginAmount}(keyNative, params);

        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

        uint256 modifyAmount = 0.05e18;
        marginPositionManager.modify{value: modifyAmount}(tokenId, int128(int256(modifyAmount)));

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertEq(
            positionAfter.marginAmount,
            positionBefore.marginAmount + modifyAmount,
            "position.marginAmount should be increased"
        );
    }

    function testModifyNative_DecreaseCollateral() public {
        uint256 marginAmount = 0.2 ether;

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with native, borrow token1
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,,) = marginPositionManager.addMargin{value: marginAmount}(keyNative, params);
        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

        int128 modifyAmount = -0.01 ether;

        uint256 balanceBefore = address(this).balance;
        marginPositionManager.modify(tokenId, modifyAmount);
        uint256 balanceAfter = address(this).balance;

        assertTrue(balanceAfter > balanceBefore, "should receive native currency back");

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertEq(
            int256(uint256(positionAfter.marginAmount)),
            int256(uint256(positionBefore.marginAmount)) + modifyAmount,
            "position.marginAmount should be decreased"
        );
    }

    function testAddMargin_LowFeePoolMarginBanned() public {
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

        vm.expectRevert(IMarginPositionManager.LowFeePoolMarginBanned.selector);
        marginPositionManager.addMargin(keyLowFee, params);
    }

    function testAddMargin_Success_DeadlineIsZero() public {
        uint256 marginAmount = 0.01 ether;
        token0.mint(address(this), marginAmount);
        skip(10);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: 0
        });

        marginPositionManager.addMargin(key, params);
    }

    function testAddMargin_Fail_ExpiredDeadline() public {
        uint256 marginAmount = 0.01 ether;
        token0.mint(address(this), marginAmount);
        skip(10);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: 1
        });

        vm.expectRevert(bytes("EXPIRED"));
        marginPositionManager.addMargin(key, params);
    }

    function testAddMargin_Fail_ReservesNotEnough() public {
        uint256 marginAmount = 10000e18; // A very large amount
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 5,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        vm.expectRevert(IMarginPositionManager.ReservesNotEnough.selector);
        marginPositionManager.addMargin(key, params);
    }

    function testAddMargin_Fail_BorrowTooMuch() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 0, // No leverage
            marginAmount: uint128(marginAmount),
            borrowAmount: 1e18, // Borrow a large amount
            borrowAmountMax: 1e18,
            recipient: address(this),
            deadline: block.timestamp
        });

        vm.expectRevert(IMarginPositionManager.BorrowTooMuch.selector);
        marginPositionManager.addMargin(key, params);
    }

    function testAddMargin_Fail_ChangeMarginAction_Borrow2Margin() public {
        uint256 marginAmount = 0.1 ether;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 0, // No leverage
            marginAmount: uint128(marginAmount),
            borrowAmount: marginAmount,
            borrowAmountMax: marginAmount,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);

        IMarginPositionManager.MarginParams memory marginParams = IMarginPositionManager.MarginParams({
            tokenId: tokenId,
            leverage: 1,
            marginAmount: uint128(marginAmount),
            borrowAmount: marginAmount,
            borrowAmountMax: marginAmount,
            deadline: block.timestamp
        });

        vm.expectRevert(MarginPosition.ChangeMarginAction.selector);
        marginPositionManager.margin(marginParams);
    }

    function testAddMargin_Fail_ChangeMarginAction_Margin2Borrow() public {
        uint256 marginAmount = 0.1 ether;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);

        IMarginPositionManager.MarginParams memory marginParams = IMarginPositionManager.MarginParams({
            tokenId: tokenId,
            leverage: 0,
            marginAmount: uint128(marginAmount),
            borrowAmount: marginAmount,
            borrowAmountMax: marginAmount,
            deadline: block.timestamp
        });

        vm.expectRevert(MarginPosition.ChangeMarginAction.selector);
        marginPositionManager.margin(marginParams);
    }

    function testClose_Fail_InsufficientCloseReceived() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);

        // Try to close with a very high min amount to receive
        vm.expectRevert(IMarginPositionManager.InsufficientCloseReceived.selector);
        marginPositionManager.close(tokenId, 1_000_000, 1e18, block.timestamp);
    }

    function testSetMarginLevel_Fail_InvalidLevels() public {
        // An invalid level, e.g., liquidateLevel > minMarginLevel
        MarginLevels newMarginLevels;
        newMarginLevels = newMarginLevels.setMinMarginLevel(1100000);
        newMarginLevels = newMarginLevels.setLiquidateLevel(1200000); // Invalid

        vm.expectRevert(IMarginPositionManager.InvalidLevel.selector);
        marginPositionManager.setMarginLevel(MarginLevels.unwrap(newMarginLevels));
    }
}
