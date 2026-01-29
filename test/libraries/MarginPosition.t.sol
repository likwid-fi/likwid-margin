// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarginPosition} from "../../src/libraries/MarginPosition.sol";
import {Reserves, toReserves} from "../../src/types/Reserves.sol";
import {PerLibrary} from "../../src/libraries/PerLibrary.sol";

// Wrapper contract to test reverts
contract MarginPositionWrapper {
    using MarginPosition for MarginPosition.State;

    MarginPosition.State public position;

    function marginLevel(Reserves pairReserves) external view returns (uint256) {
        return position.marginLevel(pairReserves);
    }

    function update(
        uint256 borrowCumulativeLast,
        uint256 depositCumulativeLast,
        int128 marginChangeAmount,
        uint256 marginWithoutFee,
        uint256 borrowAmount,
        uint256 repayAmount
    ) external returns (uint256, uint256) {
        return position.update(
            borrowCumulativeLast, depositCumulativeLast, marginChangeAmount, marginWithoutFee, borrowAmount, repayAmount
        );
    }

    function close(
        Reserves pairReserves,
        Reserves truncatedReserves,
        uint24 lpFee,
        uint256 borrowCumulativeLast,
        uint256 depositCumulativeLast,
        uint256 rewardAmount,
        uint24 closeMillionth
    ) external returns (uint256, uint256, uint256, uint256, uint256) {
        return position.close(
            pairReserves,
            truncatedReserves,
            lpFee,
            borrowCumulativeLast,
            depositCumulativeLast,
            rewardAmount,
            closeMillionth
        );
    }

    function setMarginForOne(bool _marginForOne) external {
        position.marginForOne = _marginForOne;
    }
}

contract MarginPositionTest is Test {
    using MarginPosition for MarginPosition.State;

    MarginPosition.State position;
    Reserves pairReserves;
    MarginPositionWrapper wrapper;

    function setUp() public {
        pairReserves = toReserves(1000e18, 1000e18);
        wrapper = new MarginPositionWrapper();
    }

    function testMarginLevelNoDebt() public pure {
        MarginPosition.State memory pos = MarginPosition.State({
            marginForOne: false,
            marginAmount: 100e18,
            marginTotal: 0,
            depositCumulativeLast: 1e18,
            debtAmount: 0,
            borrowCumulativeLast: 1e18
        });

        Reserves reserves = toReserves(1000e18, 1000e18);
        uint256 level = pos.marginLevel(reserves);

        assertEq(level, type(uint256).max, "Margin level should be max when no debt");
    }

    function testMarginLevelWithDebt() public pure {
        MarginPosition.State memory pos = MarginPosition.State({
            marginForOne: false,
            marginAmount: 100e18,
            marginTotal: 0,
            depositCumulativeLast: 1e18,
            debtAmount: 50e18,
            borrowCumulativeLast: 1e18
        });

        Reserves reserves = toReserves(1000e18, 1000e18);
        uint256 level = pos.marginLevel(reserves);

        assertLt(level, type(uint256).max, "Margin level should be finite with debt");
        assertGt(level, 0, "Margin level should be positive");
    }

    function testMarginLevelReservesNotPositive() public {
        // Setup position with debt
        wrapper.update(1e18, 1e18, 100e18, 0, 50e18, 0);

        Reserves zeroReserves = toReserves(0, 0);

        vm.expectRevert(MarginPosition.ReservesNotPositive.selector);
        wrapper.marginLevel(zeroReserves);
    }

    function testUpdateAddMargin() public {
        uint256 borrowCumulativeLast = 1e18;
        uint256 depositCumulativeLast = 1e18;
        int128 marginChangeAmount = 100e18;
        uint256 marginWithoutFee = 0;
        uint256 borrowAmount = 0;
        uint256 repayAmount = 0;

        (uint256 releaseAmount, uint256 realRepayAmount) = position.update(
            borrowCumulativeLast, depositCumulativeLast, marginChangeAmount, marginWithoutFee, borrowAmount, repayAmount
        );

        assertEq(releaseAmount, 0, "No release on add");
        assertEq(realRepayAmount, 0, "No repay on add");
        assertEq(position.marginAmount, uint128(marginChangeAmount), "Margin amount should be updated");
    }

    function testUpdateRemoveMargin() public {
        // First add margin
        uint256 borrowCumulativeLast = 1e18;
        uint256 depositCumulativeLast = 1e18;

        position.update(borrowCumulativeLast, depositCumulativeLast, 100e18, 0, 0, 0);

        // Then remove margin
        int128 marginChangeAmount = -50e18;
        (uint256 releaseAmount, uint256 realRepayAmount) =
            position.update(borrowCumulativeLast, depositCumulativeLast, marginChangeAmount, 0, 0, 0);

        assertEq(position.marginAmount, 50e18, "Margin amount should be reduced");
    }

    function testUpdateWithBorrow() public {
        uint256 borrowCumulativeLast = 1e18;
        uint256 depositCumulativeLast = 1e18;
        int128 marginChangeAmount = 100e18;
        uint256 marginWithoutFee = 100e18;
        uint256 borrowAmount = 200e18;
        uint256 repayAmount = 0;

        (uint256 releaseAmount, uint256 realRepayAmount) = position.update(
            borrowCumulativeLast, depositCumulativeLast, marginChangeAmount, marginWithoutFee, borrowAmount, repayAmount
        );

        assertEq(position.marginTotal, marginWithoutFee, "Margin total should be set");
        assertEq(position.debtAmount, borrowAmount, "Debt amount should be set");
    }

    function testUpdateRepay() public {
        // Setup position with debt
        uint256 borrowCumulativeLast = 1e18;
        uint256 depositCumulativeLast = 1e18;

        position.update(borrowCumulativeLast, depositCumulativeLast, 100e18, 100e18, 200e18, 0);

        // Repay
        uint256 repayAmount = 100e18;
        (uint256 releaseAmount, uint256 realRepayAmount) =
            position.update(borrowCumulativeLast, depositCumulativeLast, 0, 0, 0, repayAmount);

        assertEq(realRepayAmount, repayAmount, "Repay amount should match");
        assertEq(position.debtAmount, 100e18, "Debt should be reduced");
    }

    function testClosePartial() public {
        // Setup position with debt - this test verifies the close function works
        // Note: In a real scenario, the swap math would determine if position is liquidated
        // For this test, we just verify the function executes without revert when conditions are met
        uint256 borrowCumulativeLast = 1e18;
        uint256 depositCumulativeLast = 1e18;

        // Setup a position that won't be liquidated when closing fully
        // marginAmount = 200e18, marginTotal = 0 (borrow mode), debt = 100e18
        wrapper.update(borrowCumulativeLast, depositCumulativeLast, 200e18, 0, 100e18, 0);
        wrapper.setMarginForOne(false);

        // Close 100% - this should work since positionValue (200e18) > debt (100e18)
        uint24 closeMillionth = 1000000; // 100%
        uint256 rewardAmount = 0;
        uint24 lpFee = 3000;
        Reserves truncatedReserves = pairReserves;

        (uint256 releaseAmount, uint256 repayAmount, uint256 closeAmount, uint256 lostAmount, uint256 swapFeeAmount) = wrapper.close(
            pairReserves,
            truncatedReserves,
            lpFee,
            borrowCumulativeLast,
            depositCumulativeLast,
            rewardAmount,
            closeMillionth
        );

        assertGt(releaseAmount, 0, "Should release some amount");
        assertGt(repayAmount, 0, "Should repay some amount");
    }

    function testCloseInvalidMillionth() public {
        uint24 invalidMillionth = 0;

        vm.expectRevert(PerLibrary.InvalidMillionth.selector);
        wrapper.close(pairReserves, pairReserves, 3000, 1e18, 1e18, 0, invalidMillionth);
    }

    function testCloseMillionthTooHigh() public {
        uint24 invalidMillionth = uint24(PerLibrary.ONE_MILLION + 1);

        vm.expectRevert(PerLibrary.InvalidMillionth.selector);
        wrapper.close(pairReserves, pairReserves, 3000, 1e18, 1e18, 0, invalidMillionth);
    }

    function testChangeMarginActionRevert() public {
        // Setup position with marginTotal > 0 (margin mode)
        uint256 borrowCumulativeLast = 1e18;
        uint256 depositCumulativeLast = 1e18;

        wrapper.update(borrowCumulativeLast, depositCumulativeLast, 100e18, 100e18, 200e18, 0);

        // Try to borrow (marginWithoutFee = 0) on margin position
        vm.expectRevert(MarginPosition.ChangeMarginAction.selector);
        wrapper.update(
            borrowCumulativeLast,
            depositCumulativeLast,
            0,
            0, // marginWithoutFee = 0 means borrow
            100e18,
            0
        );
    }

    function testMarginLevelWithCumulative() public pure {
        MarginPosition.State memory pos = MarginPosition.State({
            marginForOne: false,
            marginAmount: 100e18,
            marginTotal: 0,
            depositCumulativeLast: 1e18,
            debtAmount: 50e18,
            borrowCumulativeLast: 1e18
        });

        Reserves reserves = toReserves(1000e18, 1000e18);
        uint256 borrowCumulativeLast = 1.5e18;
        uint256 depositCumulativeLast = 1.2e18;

        uint256 level = pos.marginLevel(reserves, borrowCumulativeLast, depositCumulativeLast);

        assertLt(level, type(uint256).max, "Margin level should be finite");
    }

    function testFullRepay() public {
        // Setup position with debt
        uint256 borrowCumulativeLast = 1e18;
        uint256 depositCumulativeLast = 1e18;

        position.update(borrowCumulativeLast, depositCumulativeLast, 100e18, 100e18, 200e18, 0);

        // Repay more than debt
        uint256 repayAmount = 300e18;
        (uint256 releaseAmount, uint256 realRepayAmount) =
            position.update(borrowCumulativeLast, depositCumulativeLast, 0, 0, 0, repayAmount);

        assertEq(realRepayAmount, 200e18, "Should only repay actual debt");
        assertEq(position.debtAmount, 0, "Debt should be zero");
    }

    function testPositionLiquidated() public {
        // Setup position that would be liquidated
        uint256 borrowCumulativeLast = 1e18;
        uint256 depositCumulativeLast = 1e18;

        wrapper.update(borrowCumulativeLast, depositCumulativeLast, 10e18, 0, 100e18, 0);
        wrapper.setMarginForOne(false);

        // Try to close with insufficient value
        uint24 closeMillionth = 100000; // 10%

        // This should revert if position is liquidated
        vm.expectRevert(MarginPosition.PositionLiquidated.selector);
        wrapper.close(pairReserves, pairReserves, 3000, borrowCumulativeLast, depositCumulativeLast, 0, closeMillionth);
    }
}
