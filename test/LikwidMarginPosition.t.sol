// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Test, console} from "forge-std/Test.sol";
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

    uint24 constant DEFAULT_FEE = 3000;
    uint24 constant LOW_FEE = 1000;
    uint24 constant DEFAULT_MARGIN_FEE = 3000;
    uint128 constant DEFAULT_MARGIN_AMOUNT = 0.1e18;
    uint256 constant DEFAULT_SWAP_AMOUNT = 5e18;

    function setUp() public {
        vault = new LikwidVault(address(this));
        marginPositionManager = new LikwidMarginPosition(address(this), vault);
        pairPositionManager = new LikwidPairPosition(address(this), vault);
        helper = new LikwidHelper(address(this), vault);

        address tokenA = address(new MockERC20("TokenA", "TKNA", 18));
        address tokenB = address(new MockERC20("TokenB", "TKNB", 18));

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

        key = PoolKey({currency0: currency0, currency1: currency1, fee: DEFAULT_FEE, marginFee: DEFAULT_MARGIN_FEE});
        vault.initialize(key);

        keyLowFee = PoolKey({currency0: currency0, currency1: currency1, fee: LOW_FEE, marginFee: DEFAULT_MARGIN_FEE});
        vault.initialize(keyLowFee);

        keyNative = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: currency1,
            fee: DEFAULT_FEE,
            marginFee: DEFAULT_MARGIN_FEE
        });
        vault.initialize(keyNative);

        _addInitialLiquidity();
    }

    function _addInitialLiquidity() internal {
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

    // ==================== Helper Functions ====================

    function _createDefaultParams(bool marginForOne, uint24 leverage, uint128 marginAmount)
        internal
        view
        returns (IMarginPositionManager.CreateParams memory)
    {
        return IMarginPositionManager.CreateParams({
            marginForOne: marginForOne,
            leverage: leverage,
            marginAmount: marginAmount,
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });
    }

    function _createPosition(bool marginForOne, uint24 leverage, uint128 marginAmount)
        internal
        returns (uint256 tokenId, uint256 borrowAmount)
    {
        _mintMarginToken(marginForOne, marginAmount);
        IMarginPositionManager.CreateParams memory params = _createDefaultParams(marginForOne, leverage, marginAmount);
        (tokenId, borrowAmount,) = marginPositionManager.addMargin(key, params);
    }

    function _createNativePosition(bool marginForOne, uint24 leverage, uint128 marginAmount)
        internal
        returns (uint256 tokenId, uint256 borrowAmount)
    {
        if (marginForOne) {
            token1.mint(address(this), marginAmount);
        }
        IMarginPositionManager.CreateParams memory params = _createDefaultParams(marginForOne, leverage, marginAmount);
        (tokenId, borrowAmount,) =
            marginPositionManager.addMargin{value: marginForOne ? 0 : marginAmount}(keyNative, params);
    }

    function _mintMarginToken(bool marginForOne, uint256 amount) internal {
        if (marginForOne) {
            token1.mint(address(this), amount);
        } else {
            token0.mint(address(this), amount);
        }
    }

    function _mintBorrowToken(bool marginForOne, uint256 amount) internal {
        if (marginForOne) {
            token0.mint(address(this), amount);
        } else {
            token1.mint(address(this), amount);
        }
    }

    function _manipulatePrice(bool zeroForOne, uint256 swapAmount) internal {
        if (zeroForOne) {
            token0.mint(address(this), swapAmount);
        } else {
            token1.mint(address(this), swapAmount);
        }

        IVault.SwapParams memory swapParams = IVault.SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -int256(swapAmount), useMirror: false, salt: bytes32(0)
        });
        bytes memory innerParams = abi.encode(key, swapParams);
        bytes memory data = abi.encode(this.swap_callback.selector, innerParams);
        vault.unlock(data);
        skip(1000);
    }

    function _createLiquidator() internal {
        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        token0.mint(liquidator, 100e18);
        token1.mint(liquidator, 100e18);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        token0.approve(address(marginPositionManager), type(uint256).max);
        token1.approve(address(marginPositionManager), type(uint256).max);
    }

    function _createNativeLiquidator() internal {
        address liquidator = makeAddr("nativeLiquidator");
        vm.startPrank(liquidator);
        token1.mint(liquidator, 100e18);
        token1.approve(address(vault), type(uint256).max);
        token1.approve(address(marginPositionManager), type(uint256).max);
    }

    function _liquidateAndVerify(uint256 tokenId, bool useBurn) internal returns (uint256 profit) {
        _createLiquidator();

        if (useBurn) {
            profit = marginPositionManager.liquidateBurn(tokenId, 0);
        } else {
            (profit,) = marginPositionManager.liquidateCall(tokenId, 0);
        }
        vm.stopPrank();

        assertTrue(profit > 0, "Liquidator should make profit");

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.debtAmount, 0, "Debt should be 0 after liquidation");
        assertEq(position.marginAmount, 0, "Margin should be 0 after liquidation");
        assertEq(position.marginTotal, 0, "MarginTotal should be 0 after liquidation");
    }

    function _getLiquidateBurnValues() internal returns (uint256 lostAmount, uint256 fundAmount) {
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 eventSignature = keccak256(
            "LiquidateBurn(bytes32,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSignature) {
                (,,,,,,,,, lostAmount, fundAmount) = abi.decode(
                    entries[i].data,
                    (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
                );

                return (lostAmount, fundAmount);
            }
        }
        revert("LiquidateBurn event not found");
    }

    function _getLiquidateCallValues() internal returns (uint256 lostAmount, uint256 fundAmount) {
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 eventSignature = keccak256(
            "LiquidateCall(bytes32,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSignature) {
                (,,,,,,,,, lostAmount, fundAmount) = abi.decode(
                    entries[i].data,
                    (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
                );

                return (lostAmount, fundAmount);
            }
        }
        revert("LiquidateCall event not found");
    }

    // ==================== Callback Functions ====================

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bytes4 selector, bytes memory params) = abi.decode(data, (bytes4, bytes));

        if (selector == this.swap_callback.selector) {
            (PoolKey memory _key, IVault.SwapParams memory swapParams) =
                abi.decode(params, (PoolKey, IVault.SwapParams));

            (BalanceDelta delta,,) = vault.swap(_key, swapParams);

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

    // ==================== Basic Margin Tests ====================

    function testAddMargin() public {
        (uint256 tokenId, uint256 borrowAmount) = _createPosition(false, 2, DEFAULT_MARGIN_AMOUNT);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.marginAmount, DEFAULT_MARGIN_AMOUNT);
        assertEq(position.debtAmount, borrowAmount);
        assertTrue(vault.protocolFeesAccrued(key.currency0) > 0);
        assertTrue(vault.protocolFeesAccrued(key.currency1) > 0);
    }

    function testAddMargin_MarginForOne() public {
        (uint256 tokenId, uint256 borrowAmount) = _createPosition(true, 2, DEFAULT_MARGIN_AMOUNT);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.marginAmount, DEFAULT_MARGIN_AMOUNT);
        assertTrue(position.marginForOne);
    }

    function testAddMarginNative() public {
        (uint256 tokenId, uint256 borrowAmount) = _createNativePosition(false, 2, DEFAULT_MARGIN_AMOUNT);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.marginAmount, DEFAULT_MARGIN_AMOUNT);
    }

    function testAddMarginNative_MarginForOne() public {
        (uint256 tokenId, uint256 borrowAmount) = _createNativePosition(true, 2, DEFAULT_MARGIN_AMOUNT);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.marginAmount, DEFAULT_MARGIN_AMOUNT);
        assertTrue(position.marginForOne);
    }

    // ==================== Repay Tests ====================

    function testRepay() public {
        (uint256 tokenId, uint256 borrowAmount) = _createPosition(false, 2, DEFAULT_MARGIN_AMOUNT);

        uint256 repayAmount = borrowAmount / 2;
        _mintBorrowToken(false, repayAmount);

        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);
        marginPositionManager.repay(tokenId, repayAmount, block.timestamp);
        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertTrue(positionAfter.debtAmount < positionBefore.debtAmount);

        skip(1000);

        positionBefore = marginPositionManager.getPositionState(tokenId);
        repayAmount = positionBefore.debtAmount + 100;
        _mintBorrowToken(false, repayAmount);
        marginPositionManager.repay(tokenId, repayAmount, block.timestamp);
        positionAfter = marginPositionManager.getPositionState(tokenId);

        assertEq(positionAfter.debtAmount, 0);
        assertEq(token1.balanceOf(address(this)), repayAmount - positionBefore.debtAmount);
    }

    function testRepay_Full() public {
        (uint256 tokenId, uint256 borrowAmount) = _createPosition(false, 2, DEFAULT_MARGIN_AMOUNT);

        _mintBorrowToken(false, borrowAmount);
        marginPositionManager.repay(tokenId, borrowAmount, block.timestamp);

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        assertTrue(position.debtAmount < 10);
    }

    function testRepayNative() public {
        (uint256 tokenId, uint256 borrowAmount) = _createNativePosition(false, 2, DEFAULT_MARGIN_AMOUNT);

        uint256 repayAmount = borrowAmount / 2;
        token1.mint(address(this), repayAmount);

        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);
        marginPositionManager.repay(tokenId, repayAmount, block.timestamp);
        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertTrue(positionAfter.debtAmount < positionBefore.debtAmount);
    }

    function testRepayNative_RepayWithNative() public {
        (uint256 tokenId, uint256 borrowAmount) = _createNativePosition(true, 2, DEFAULT_MARGIN_AMOUNT);

        uint256 repayAmount = borrowAmount / 2;
        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);
        marginPositionManager.repay{value: repayAmount}(tokenId, repayAmount, block.timestamp);
        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertTrue(positionAfter.debtAmount < positionBefore.debtAmount);
    }

    // ==================== Close Tests ====================

    function testClose() public {
        (uint256 tokenId,) = _createPosition(false, 2, DEFAULT_MARGIN_AMOUNT);

        marginPositionManager.close(tokenId, 500_000, 0, block.timestamp);
        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);

        assertGt(position.marginAmount, 0);
        assertGt(position.debtAmount, 0);

        skip(1000);
        marginPositionManager.close(tokenId, 1_000_000, 0, block.timestamp);
        position = marginPositionManager.getPositionState(tokenId);

        assertEq(position.marginAmount, 0);
        assertEq(position.debtAmount, 0);
    }

    function testClose_Partial() public {
        (uint256 tokenId,) = _createPosition(false, 2, DEFAULT_MARGIN_AMOUNT);
        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

        marginPositionManager.close(tokenId, 500_000, 0, block.timestamp);
        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);

        assertApproxEqAbs(positionAfter.marginAmount, positionBefore.marginAmount / 2, 1);
        assertApproxEqAbs(positionAfter.debtAmount, positionBefore.debtAmount / 2, 1);
    }

    function testCloseNative() public {
        (uint256 tokenId,) = _createNativePosition(false, 2, DEFAULT_MARGIN_AMOUNT);

        uint256 balanceBefore = address(this).balance;
        marginPositionManager.close(tokenId, 1_000_000, 0, block.timestamp);
        uint256 balanceAfter = address(this).balance;

        assertTrue(balanceAfter > balanceBefore);

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.marginAmount, 0);
        assertEq(position.debtAmount, 0);
    }

    // ==================== Modify Tests ====================

    function testModify_Increase() public {
        (uint256 tokenId,) = _createPosition(false, 2, DEFAULT_MARGIN_AMOUNT);
        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

        uint256 modifyAmount = 0.05e18;
        token0.mint(address(this), modifyAmount);
        marginPositionManager.modify(tokenId, int128(int256(modifyAmount)), block.timestamp);

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);
        assertEq(positionAfter.marginAmount, positionBefore.marginAmount + modifyAmount);
    }

    function testModify_Decrease() public {
        (uint256 tokenId,) = _createPosition(false, 2, 0.2e18);
        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

        int128 modifyAmount = -0.01e18;
        marginPositionManager.modify(tokenId, modifyAmount, block.timestamp);

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);
        assertEq(
            int256(uint256(positionAfter.marginAmount)), int256(uint256(positionBefore.marginAmount)) + modifyAmount
        );
    }

    function testModifyNative_Increase() public {
        (uint256 tokenId,) = _createNativePosition(false, 2, DEFAULT_MARGIN_AMOUNT);
        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

        uint256 modifyAmount = 0.05e18;
        marginPositionManager.modify{value: modifyAmount}(tokenId, int128(int256(modifyAmount)), block.timestamp);

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);
        assertEq(positionAfter.marginAmount, positionBefore.marginAmount + modifyAmount);
    }

    function testModifyNative_Decrease() public {
        (uint256 tokenId,) = _createNativePosition(false, 2, 0.2e18);
        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);

        int128 modifyAmount = -0.01e18;
        uint256 balanceBefore = address(this).balance;
        marginPositionManager.modify(tokenId, modifyAmount, block.timestamp);
        uint256 balanceAfter = address(this).balance;

        assertTrue(balanceAfter > balanceBefore);

        MarginPosition.State memory positionAfter = marginPositionManager.getPositionState(tokenId);
        assertEq(
            int256(uint256(positionAfter.marginAmount)), int256(uint256(positionBefore.marginAmount)) + modifyAmount
        );
    }

    // ==================== Liquidation Tests ====================

    function _liquidateCallMarginForZero(uint256 swapAmount) public returns (uint256 lostAmount, uint256 fundAmount) {
        InsuranceFunds insuranceFundsBefore = StateLibrary.getInsuranceFunds(vault, key.toId());

        (uint256 tokenId,) = _createPosition(false, 4, DEFAULT_MARGIN_AMOUNT);
        skip(1000);

        _manipulatePrice(true, swapAmount);
        assertTrue(helper.checkMarginPositionLiquidate(tokenId));

        vm.recordLogs();
        _liquidateAndVerify(tokenId, false);
        (lostAmount, fundAmount) = _getLiquidateCallValues();

        InsuranceFunds insuranceFundsAfter = StateLibrary.getInsuranceFunds(vault, key.toId());
        if (lostAmount > 0) {
            assertLt(insuranceFundsAfter.amount1(), insuranceFundsBefore.amount1());
            assertEq(fundAmount, 0);
            assertApproxEqAbs(lostAmount, uint128(insuranceFundsBefore.amount1() - insuranceFundsAfter.amount1()), 1);
        }
        if (fundAmount > 0) {
            assertGt(insuranceFundsAfter.amount1(), insuranceFundsBefore.amount1());
            assertEq(lostAmount, 0);
            assertApproxEqAbs(fundAmount, uint128(insuranceFundsAfter.amount1() - insuranceFundsBefore.amount1()), 1);
        }
        LikwidHelper.PoolStateInfo memory poolState = helper.getPoolStateInfo(key.toId());
        assertEq(poolState.insuranceFund0, insuranceFundsAfter.amount0());
        assertEq(poolState.insuranceFund1, insuranceFundsAfter.amount1());
    }

    function testLiquidateCall_MarginForZero() public {
        (uint256 lostAmount, uint256 fundAmount) = _liquidateCallMarginForZero(DEFAULT_SWAP_AMOUNT);
        assertGt(lostAmount, 0);
        assertEq(fundAmount, 0);
    }

    function testLiquidateCall_WithFundAmount_MarginForZero() public {
        (uint256 lostAmount, uint256 fundAmount) = _liquidateCallMarginForZero(1e18);
        assertEq(lostAmount, 0);
        assertGt(fundAmount, 0);
    }

    function _liquidateCallMarginForOne(uint256 swapAmount) public returns (uint256 lostAmount, uint256 fundAmount) {
        InsuranceFunds insuranceFundsBefore = StateLibrary.getInsuranceFunds(vault, key.toId());
        assertEq(insuranceFundsBefore.amount0(), 0);
        assertEq(insuranceFundsBefore.amount1(), 0);

        (uint256 tokenId,) = _createPosition(true, 4, DEFAULT_MARGIN_AMOUNT);
        skip(1000);

        _manipulatePrice(false, swapAmount);
        assertTrue(helper.checkMarginPositionLiquidate(tokenId));

        _createLiquidator();
        vm.recordLogs();
        (uint256 profit,) = marginPositionManager.liquidateCall(tokenId, 0);
        (lostAmount, fundAmount) = _getLiquidateCallValues();
        vm.stopPrank();

        assertTrue(profit > 0);
        InsuranceFunds insuranceFundsAfter = StateLibrary.getInsuranceFunds(vault, key.toId());
        if (lostAmount > 0) {
            assertLt(insuranceFundsAfter.amount0(), insuranceFundsBefore.amount0());
            assertEq(fundAmount, 0);
            assertApproxEqAbs(lostAmount, uint128(insuranceFundsBefore.amount0() - insuranceFundsAfter.amount0()), 1);
        }
        if (fundAmount > 0) {
            assertGt(insuranceFundsAfter.amount0(), insuranceFundsBefore.amount0());
            assertEq(lostAmount, 0);
            assertApproxEqAbs(fundAmount, uint128(insuranceFundsAfter.amount0() - insuranceFundsBefore.amount0()), 1);
        }

        // Test modify after liquidation
        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.debtAmount, 0);
        assertEq(position.marginAmount, 0);
        assertEq(position.marginTotal, 0);

        int128 modifyAmount = 0.01e18;
        token1.mint(address(this), uint256(uint128(modifyAmount)));
        marginPositionManager.modify(tokenId, modifyAmount, block.timestamp);

        modifyAmount = -0.01e18;
        marginPositionManager.modify(tokenId, modifyAmount, block.timestamp);

        position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.debtAmount, 0);
        assertEq(position.marginAmount, 0);
        assertEq(position.marginTotal, 0);

        LikwidHelper.PoolStateInfo memory poolState = helper.getPoolStateInfo(key.toId());
        assertEq(poolState.insuranceFund0, insuranceFundsAfter.amount0());
        assertEq(poolState.insuranceFund1, insuranceFundsAfter.amount1());
    }

    function testLiquidateCall_MarginForOne() public {
        (uint256 lostAmount, uint256 fundAmount) = _liquidateCallMarginForOne(DEFAULT_SWAP_AMOUNT);
        assertGt(lostAmount, 0);
        assertEq(fundAmount, 0);
    }

    function testLiquidateCall_WithFundAmount_MarginForOne() public {
        (uint256 lostAmount, uint256 fundAmount) = _liquidateCallMarginForOne(1.5e18);
        assertEq(lostAmount, 0);
        assertGt(fundAmount, 0);
    }

    function testLiquidateBurn() public {
        InsuranceFunds insuranceFundsBefore = StateLibrary.getInsuranceFunds(vault, key.toId());

        (uint256 tokenId,) = _createPosition(false, 4, DEFAULT_MARGIN_AMOUNT);
        skip(1000);

        _manipulatePrice(true, DEFAULT_SWAP_AMOUNT);
        assertTrue(helper.checkMarginPositionLiquidate(tokenId));

        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);
        LikwidHelper.PoolStateInfo memory poolStateBefore = helper.getPoolStateInfo(key.toId());
        uint256 protocolFeesBefore = vault.protocolFeesAccrued(key.currency1);

        vm.recordLogs();
        _liquidateAndVerify(tokenId, true);
        (uint256 lostAmount, uint256 fundAmount) = _getLiquidateBurnValues();

        InsuranceFunds insuranceFundsAfter = StateLibrary.getInsuranceFunds(vault, key.toId());
        assertLt(insuranceFundsAfter.amount1(), insuranceFundsBefore.amount1());
        assertEq(fundAmount, 0);
        assertApproxEqAbs(lostAmount, uint128(insuranceFundsBefore.amount1() - insuranceFundsAfter.amount1()), 1);

        LikwidHelper.PoolStateInfo memory poolStateAfter = helper.getPoolStateInfo(key.toId());
        uint256 protocolFeesAfter = vault.protocolFeesAccrued(key.currency1);

        assertEq(
            poolStateBefore.lendReserve0 - poolStateAfter.lendReserve0,
            positionBefore.marginAmount + positionBefore.marginTotal
        );
        assertLt(protocolFeesBefore, protocolFeesAfter);

        LikwidHelper.PoolStateInfo memory poolState = helper.getPoolStateInfo(key.toId());
        assertEq(poolState.insuranceFund0, insuranceFundsAfter.amount0());
        assertEq(poolState.insuranceFund1, insuranceFundsAfter.amount1());
    }

    function testLiquidateBurn_Batch() public {
        for (uint256 i = 0; i < 2; i++) {
            testLiquidateBurn();
        }
    }

    function testLiquidateBurn_WithCloseAmount_MarginForZero() public {
        InsuranceFunds insuranceFundsBefore = StateLibrary.getInsuranceFunds(vault, key.toId());
        assertEq(insuranceFundsBefore.amount0(), 0);
        assertEq(insuranceFundsBefore.amount1(), 0);

        (uint256 tokenId,) = _createPosition(false, 4, DEFAULT_MARGIN_AMOUNT);
        skip(1000);

        _manipulatePrice(true, 1e18);
        assertTrue(helper.checkMarginPositionLiquidate(tokenId));

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        LikwidHelper.PoolStateInfo memory poolStateBefore = helper.getPoolStateInfo(key.toId());

        _createLiquidator();
        vm.recordLogs();
        uint256 profit = marginPositionManager.liquidateBurn(tokenId, 0);
        (uint256 lostAmount, uint256 fundAmount) = _getLiquidateBurnValues();
        vm.stopPrank();

        assertTrue(profit > 0);

        LikwidHelper.PoolStateInfo memory poolStateAfter = helper.getPoolStateInfo(key.toId());

        uint256 totalMarginAmount = position.marginAmount + position.marginTotal;
        assertEq(poolStateBefore.lendReserve0 - poolStateAfter.lendReserve0, totalMarginAmount);

        InsuranceFunds insuranceFundsAfter = StateLibrary.getInsuranceFunds(vault, key.toId());
        assertGt(insuranceFundsAfter.amount0(), insuranceFundsBefore.amount0());
        assertEq(lostAmount, 0);
        assertEq(fundAmount, uint128(insuranceFundsAfter.amount0() - insuranceFundsBefore.amount0()));

        PoolId poolId = key.toId();
        (,,,,, uint8 insuranceFundPercentage) = StateLibrary.getSlot0(vault, poolId);
        Reserves insuranceFundUpperLimit = StateLibrary.getInsuranceFundUpperLimit(vault, poolId);
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        Reserves totalReserves = state.realReserves + state.mirrorReserves;
        (uint256 r0, uint256 r1) = totalReserves.reserves();
        (uint256 limit0, uint256 limit1) = insuranceFundUpperLimit.reserves();

        assertLe((insuranceFundPercentage * r0) / 100, limit0);
        assertLe((insuranceFundPercentage * r1) / 100, limit1);

        LikwidHelper.PoolStateInfo memory poolState = helper.getPoolStateInfo(key.toId());
        assertEq(poolState.insuranceFund0, insuranceFundsAfter.amount0());
        assertEq(poolState.insuranceFund1, insuranceFundsAfter.amount1());
    }

    function testLiquidateBurn_WithCloseAmount_MarginForOne() public {
        InsuranceFunds insuranceFundsBefore = StateLibrary.getInsuranceFunds(vault, key.toId());

        (uint256 tokenId,) = _createPosition(true, 4, DEFAULT_MARGIN_AMOUNT);
        skip(1000);

        _manipulatePrice(false, 2e18);
        assertTrue(helper.checkMarginPositionLiquidate(tokenId));

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        LikwidHelper.PoolStateInfo memory poolStateBefore = helper.getPoolStateInfo(key.toId());

        _createLiquidator();
        vm.recordLogs();
        uint256 profit = marginPositionManager.liquidateBurn(tokenId, 0);
        (uint256 lostAmount, uint256 fundAmount) = _getLiquidateBurnValues();
        vm.stopPrank();

        assertTrue(profit > 0);

        LikwidHelper.PoolStateInfo memory poolStateAfter = helper.getPoolStateInfo(key.toId());
        assertEq(
            poolStateBefore.lendReserve1 - poolStateAfter.lendReserve1, position.marginAmount + position.marginTotal
        );

        InsuranceFunds insuranceFundsAfter = StateLibrary.getInsuranceFunds(vault, key.toId());
        assertGt(insuranceFundsAfter.amount1(), insuranceFundsBefore.amount1());
        assertEq(lostAmount, 0);
        assertEq(fundAmount, uint128(insuranceFundsAfter.amount1() - insuranceFundsBefore.amount1()));

        LikwidHelper.PoolStateInfo memory poolState = helper.getPoolStateInfo(key.toId());
        assertEq(poolState.insuranceFund0, insuranceFundsAfter.amount0());
        assertEq(poolState.insuranceFund1, insuranceFundsAfter.amount1());
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
        assertEq(uint128(insuranceFunds.amount0()), donationAmount0);
        assertEq(uint128(insuranceFunds.amount1()), donationAmount1);

        (uint256 tokenId,) = _createPosition(false, 4, DEFAULT_MARGIN_AMOUNT);
        skip(1000);

        _manipulatePrice(true, DEFAULT_SWAP_AMOUNT);
        assertTrue(helper.checkMarginPositionLiquidate(tokenId));

        _createLiquidator();
        uint256 profit = marginPositionManager.liquidateBurn(tokenId, 0);
        vm.stopPrank();

        assertTrue(profit > 0);

        insuranceFunds = StateLibrary.getInsuranceFunds(vault, key.toId());
        assertEq(uint128(insuranceFunds.amount0()), donationAmount0);
        assertLt(uint128(insuranceFunds.amount1()), donationAmount1);

        InsuranceFunds insuranceFundsAfter = StateLibrary.getInsuranceFunds(vault, key.toId());
        LikwidHelper.PoolStateInfo memory poolState = helper.getPoolStateInfo(key.toId());
        assertEq(poolState.insuranceFund0, insuranceFundsAfter.amount0());
        assertEq(poolState.insuranceFund1, insuranceFundsAfter.amount1());
    }

    function testLiquidate_NotLiquidatable() public {
        (uint256 tokenId,) = _createPosition(false, 2, DEFAULT_MARGIN_AMOUNT);

        assertFalse(helper.checkMarginPositionLiquidate(tokenId));

        vm.expectRevert(IMarginPositionManager.PositionNotLiquidated.selector);
        marginPositionManager.liquidateCall(tokenId, 0);

        vm.expectRevert(IMarginPositionManager.PositionNotLiquidated.selector);
        marginPositionManager.liquidateBurn(tokenId, 0);
    }

    // ==================== Parameter and Fuzz Tests ====================

    function testFuzz_AddMargin_NoLeverage(uint256 marginAmount) public {
        marginAmount = bound(marginAmount, 0.0001 ether, 1 ether);
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 0,
            marginAmount: uint128(marginAmount),
            borrowAmount: 1000,
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
            leverage: 0,
            marginAmount: uint128(marginAmount),
            borrowAmount: type(uint256).max,
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

        (uint256 tokenId, uint256 borrowAmount) = _createPosition(false, 5, DEFAULT_MARGIN_AMOUNT);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);
    }

    // ==================== Error Scenario Tests ====================

    function testAddMargin_Fail_ExpiredDeadline() public {
        token0.mint(address(this), DEFAULT_MARGIN_AMOUNT);
        skip(10);

        IMarginPositionManager.CreateParams memory params = _createDefaultParams(false, 2, DEFAULT_MARGIN_AMOUNT);
        params.deadline = 1;

        vm.expectRevert("EXPIRED");
        marginPositionManager.addMargin(key, params);
    }

    function testAddMargin_Fail_ReservesNotEnough() public {
        uint256 marginAmount = 10000e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = _createDefaultParams(false, 5, uint128(marginAmount));

        vm.expectRevert(IMarginPositionManager.ReservesNotEnough.selector);
        marginPositionManager.addMargin(key, params);
    }

    function testAddMargin_Fail_BorrowTooMuch() public {
        token0.mint(address(this), DEFAULT_MARGIN_AMOUNT);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 0,
            marginAmount: DEFAULT_MARGIN_AMOUNT,
            borrowAmount: 1e18,
            borrowAmountMax: 1e18,
            recipient: address(this),
            deadline: block.timestamp
        });

        vm.expectRevert(IMarginPositionManager.BorrowTooMuch.selector);
        marginPositionManager.addMargin(key, params);
    }

    function testAddMargin_Fail_LowFeePool() public {
        token0.mint(address(this), DEFAULT_MARGIN_AMOUNT);

        IMarginPositionManager.CreateParams memory params = _createDefaultParams(false, 2, DEFAULT_MARGIN_AMOUNT);

        vm.expectRevert(IMarginPositionManager.LowFeePoolMarginBanned.selector);
        marginPositionManager.addMargin(keyLowFee, params);
    }

    function testAddMargin_Fail_ChangeMarginAction_BorrowToMargin() public {
        token0.mint(address(this), DEFAULT_MARGIN_AMOUNT);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 0,
            marginAmount: DEFAULT_MARGIN_AMOUNT,
            borrowAmount: DEFAULT_MARGIN_AMOUNT,
            borrowAmountMax: DEFAULT_MARGIN_AMOUNT,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId,,) = marginPositionManager.addMargin(key, params);

        IMarginPositionManager.MarginParams memory marginParams = IMarginPositionManager.MarginParams({
            tokenId: tokenId,
            leverage: 1,
            marginAmount: DEFAULT_MARGIN_AMOUNT,
            borrowAmount: DEFAULT_MARGIN_AMOUNT,
            borrowAmountMax: DEFAULT_MARGIN_AMOUNT,
            deadline: block.timestamp
        });

        vm.expectRevert(MarginPosition.ChangeMarginAction.selector);
        marginPositionManager.margin(marginParams);
    }

    function testAddMargin_Fail_ChangeMarginAction_MarginToBorrow() public {
        (uint256 tokenId,) = _createPosition(false, 2, DEFAULT_MARGIN_AMOUNT);

        IMarginPositionManager.MarginParams memory marginParams = IMarginPositionManager.MarginParams({
            tokenId: tokenId,
            leverage: 0,
            marginAmount: DEFAULT_MARGIN_AMOUNT,
            borrowAmount: DEFAULT_MARGIN_AMOUNT,
            borrowAmountMax: DEFAULT_MARGIN_AMOUNT,
            deadline: block.timestamp
        });

        vm.expectRevert(MarginPosition.ChangeMarginAction.selector);
        marginPositionManager.margin(marginParams);
    }

    function testClose_Fail_InsufficientCloseReceived() public {
        (uint256 tokenId,) = _createPosition(false, 2, DEFAULT_MARGIN_AMOUNT);

        vm.expectRevert(IMarginPositionManager.InsufficientCloseReceived.selector);
        marginPositionManager.close(tokenId, 1_000_000, 1e18, block.timestamp);
    }

    function testModify_Fail_BelowMinBorrowLevel() public {
        (uint256 tokenId,) = _createPosition(false, 4, DEFAULT_MARGIN_AMOUNT);

        int128 modifyAmount = -0.08e18;
        vm.expectRevert(IMarginPositionManager.InvalidLevel.selector);
        marginPositionManager.modify(tokenId, modifyAmount, block.timestamp);
    }

    function testModify_Fail_InvalidLevel() public {
        (uint256 tokenId,) = _createPosition(false, 2, 0.2e18);

        int128 modifyAmount = -0.05e18;
        vm.expectRevert(IMarginPositionManager.InvalidLevel.selector);
        marginPositionManager.modify(tokenId, modifyAmount, block.timestamp);

        skip(1000);
        modifyAmount = -0.01e18;
        marginPositionManager.modify(tokenId, modifyAmount, block.timestamp);
    }

    // ==================== Admin Function Tests ====================

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

        assertEq(MarginLevels.unwrap(marginPositionManager.marginLevels()), MarginLevels.unwrap(newMarginLevels));
    }

    function testSetMarginLevel_Fail_NotOwner() public {
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

    function testSetMarginLevel_Fail_InvalidLevels() public {
        MarginLevels newMarginLevels;
        newMarginLevels = newMarginLevels.setMinMarginLevel(1100000);
        newMarginLevels = newMarginLevels.setLiquidateLevel(1200000);

        vm.expectRevert(IMarginPositionManager.InvalidLevel.selector);
        marginPositionManager.setMarginLevel(MarginLevels.unwrap(newMarginLevels));
    }

    // ==================== Additional Edge Case Tests ====================

    function testRepayAndClose() public {
        (uint256 tokenId,) = _createPosition(false, 2, DEFAULT_MARGIN_AMOUNT);

        marginPositionManager.close(tokenId, 500_000, 0, block.timestamp);
        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        assertGt(position.marginAmount, 0);
        assertGt(position.debtAmount, 0);

        skip(1000);

        MarginPosition.State memory positionBefore = marginPositionManager.getPositionState(tokenId);
        uint256 repayAmount = positionBefore.debtAmount / 2;
        _mintBorrowToken(false, repayAmount);
        marginPositionManager.repay(tokenId, repayAmount, block.timestamp);

        skip(1000);

        marginPositionManager.close(tokenId, 1_000_000, 0, block.timestamp);
        position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.marginAmount, 0);
        assertEq(position.debtAmount, 0);
    }

    function testAddMargin_DeadlineIsZero() public {
        token0.mint(address(this), 0.01e18);
        skip(10);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 2,
            marginAmount: 0.01e18,
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: 0
        });

        marginPositionManager.addMargin(key, params);
    }

    function testPositionInterestAccrual() public {
        (uint256 tokenId, uint256 initialBorrowAmount) = _createPosition(false, 2, DEFAULT_MARGIN_AMOUNT);

        skip(1000);

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        assertGt(position.debtAmount, initialBorrowAmount, "Debt should increase due to interest");
    }
}
