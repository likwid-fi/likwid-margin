// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";

import {Math} from "./Math.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../types/BalanceDelta.sol";
import {Reserves} from "../types/Reserves.sol";
import {CustomRevert} from "./CustomRevert.sol";
import {SwapMath} from "./SwapMath.sol";
import {PerLibrary} from "./PerLibrary.sol";
import {PositionLibrary} from "./PositionLibrary.sol";
import {SafeCast} from "./SafeCast.sol";

/// @title MarginPosition
/// @notice Positions represent an owner address' margin positions
library MarginPosition {
    using CustomRevert for bytes4;
    using PositionLibrary for address;
    using SafeCast for *;

    error CannotUpdateEmptyPosition();

    error InvalidBorrowAmount();

    error ChangeMarginAction(); // margin or borrow

    error InvalidPositionKey();

    error NoChangeInPosition();

    error PositionLiquidated();

    struct State {
        bool marginForOne;
        uint128 marginAmount;
        uint128 marginTotal;
        uint128 debtAmount;
        uint256 borrowCumulativeLast;
        uint256 depositCumulativeLast;
    }

    function get(mapping(bytes32 => State) storage self, address owner, bytes32 positionKey, bytes32 salt)
        internal
        view
        returns (State storage position)
    {
        position = self[positionKey];
        bytes32 _positionKey = owner.calculatePositionKey(position.marginForOne, salt);
        if (positionKey != _positionKey) {
            InvalidPositionKey.selector.revertWith();
        }
    }

    function get(mapping(bytes32 => State) storage self, address owner, bool marginForOne, bytes32 salt)
        internal
        view
        returns (State storage position)
    {
        bytes32 positionKey = owner.calculatePositionKey(marginForOne, salt);
        position = self[positionKey];
    }

    function marginLevel(
        State memory self,
        Reserves pairReserves,
        uint256 borrowCumulativeLast,
        uint256 depositCumulativeLast
    ) internal pure returns (uint256 level) {
        if (self.debtAmount == 0 || !pairReserves.bothPositive()) {
            level = type(uint256).max;
        } else {
            uint256 marginAmount;
            uint256 marginTotal;
            uint256 positionValue;
            uint256 debtAmount;
            uint256 repayAmount;
            (uint128 reserve0, uint128 reserve1) = pairReserves.reserves();
            (uint256 reserveBorrow, uint256 reserveMargin) =
                self.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
            if (self.depositCumulativeLast != 0) {
                marginAmount = Math.mulDiv(self.marginAmount, depositCumulativeLast, self.depositCumulativeLast);
                marginTotal = Math.mulDiv(self.marginTotal, depositCumulativeLast, self.depositCumulativeLast);
                positionValue = marginAmount + marginTotal;
            }
            if (self.borrowCumulativeLast != 0) {
                debtAmount = Math.mulDiv(self.debtAmount, borrowCumulativeLast, self.borrowCumulativeLast);
            }
            if (marginTotal > 0) {
                repayAmount = Math.mulDiv(reserveBorrow, positionValue, reserveMargin);
            } else {
                uint256 numerator = positionValue * reserveBorrow;
                uint256 denominator = reserveMargin + positionValue;
                repayAmount = numerator / denominator;
            }
            level = Math.mulDiv(repayAmount, PerLibrary.ONE_MILLION, debtAmount);
        }
    }

    function update(
        State storage self,
        bool marginForOne,
        uint256 borrowCumulativeLast,
        uint256 depositCumulativeLast,
        int128 amount,
        uint256 marginWithoutFee,
        uint256 borrowAmount,
        int128 changeAmount
    ) internal returns (uint256 releaseAmount, uint256 repayAmount) {
        if (amount < 0) {
            // margin or borrow
            if (borrowAmount == 0) InvalidBorrowAmount.selector.revertWith();
        } else if (amount > 0) {
            // repay debt
            if (self.debtAmount == 0) CannotUpdateEmptyPosition.selector.revertWith();
        }
        if (self.debtAmount == 0) {
            self.marginForOne = marginForOne;
        } else {
            if (self.marginForOne != marginForOne) {
                // once opened, marginForOne cannot be changed
                ChangeMarginAction.selector.revertWith();
            }
        }
        uint256 marginAmount;
        uint256 marginTotal;
        uint256 positionValue;
        uint256 debtAmount;
        if (self.depositCumulativeLast != 0) {
            marginAmount = Math.mulDiv(self.marginAmount, depositCumulativeLast, self.depositCumulativeLast);
            marginTotal = Math.mulDiv(self.marginTotal, depositCumulativeLast, self.depositCumulativeLast);
            positionValue = marginAmount + marginTotal;
        }
        if (self.borrowCumulativeLast != 0) {
            console.log("self.debtAmount:", self.debtAmount);
            console.log(
                "now:%s,borrowCumulativeLast:%s,self.borrowCumulativeLast:%s",
                block.timestamp,
                borrowCumulativeLast,
                self.borrowCumulativeLast
            );
            debtAmount = Math.mulDiv(self.debtAmount, borrowCumulativeLast, self.borrowCumulativeLast);
            console.log("after.debtAmount:", debtAmount);
        }
        bool hasLeverage = marginTotal > 0 || marginWithoutFee > 0;
        if (amount < 0) {
            if (hasLeverage && marginWithoutFee == 0) {
                // when margin, marginWithoutFee should >0
                ChangeMarginAction.selector.revertWith();
            }
            marginAmount += uint128(-amount);
            marginTotal += marginWithoutFee;
            debtAmount += borrowAmount;
        } else if (amount > 0) {
            if (changeAmount > 0) {
                repayAmount = Math.min(uint128(changeAmount), debtAmount);
            } else {
                repayAmount = Math.min(uint128(amount), debtAmount);
            }
            releaseAmount = Math.mulDiv(positionValue, repayAmount.toUint128(), debtAmount);
            debtAmount -= uint128(repayAmount);
            if (marginTotal > 0) {
                uint256 marginAmountReleased = Math.mulDiv(releaseAmount, marginAmount, positionValue);
                marginAmount = marginAmount - marginAmountReleased;
                if (releaseAmount > marginAmountReleased) {
                    uint256 marginTotalReleased = releaseAmount - marginAmountReleased;
                    marginTotal = marginTotal - marginTotalReleased;
                }
            } else {
                marginAmount = marginAmount - releaseAmount;
            }
        } else {
            if (changeAmount == 0) {
                NoChangeInPosition.selector.revertWith();
            }
            if (changeAmount > 0) marginAmount += uint128(changeAmount);
            else marginAmount -= uint128(-changeAmount);
        }

        self.marginAmount = marginAmount.toUint128();
        self.marginTotal = marginTotal.toUint128();
        self.depositCumulativeLast = depositCumulativeLast;
        self.debtAmount = debtAmount.toUint128();
        self.borrowCumulativeLast = borrowCumulativeLast;
        console.log("self.marginAmount", self.marginAmount);
        console.log("self.marginTotal", self.marginTotal);
        console.log("self.debtAmount", self.debtAmount);
    }

    function close(
        State storage self,
        Reserves pairReserves,
        uint256 borrowCumulativeLast,
        uint256 depositCumulativeLast,
        uint256 rewardAmount,
        uint24 closeMillionth
    ) internal returns (uint256 releaseAmount, uint256 repayAmount, uint256 profitAmount, uint256 lossAmount) {
        if (closeMillionth == 0 || closeMillionth > PerLibrary.ONE_MILLION) {
            PerLibrary.InvalidMillionth.selector.revertWith();
        }
        if (self.debtAmount > 0) {
            uint256 marginAmount;
            uint256 marginTotal;
            uint256 positionValue;
            uint256 debtAmount;
            if (self.depositCumulativeLast != 0) {
                marginAmount = Math.mulDiv(self.marginAmount, depositCumulativeLast, self.depositCumulativeLast);
                marginTotal = Math.mulDiv(self.marginTotal, depositCumulativeLast, self.depositCumulativeLast);
                positionValue = marginAmount + marginTotal;
            }
            if (self.borrowCumulativeLast != 0) {
                debtAmount = Math.mulDiv(self.debtAmount, borrowCumulativeLast, self.borrowCumulativeLast);
            }
            positionValue -= rewardAmount;
            releaseAmount = Math.mulDiv(positionValue, closeMillionth, PerLibrary.ONE_MILLION);
            repayAmount = Math.mulDiv(debtAmount, closeMillionth, PerLibrary.ONE_MILLION);
            uint256 payedAmount = SwapMath.getAmountOut(pairReserves, !self.marginForOne, releaseAmount);
            if (releaseAmount < positionValue && repayAmount > payedAmount) {
                PositionLiquidated.selector.revertWith();
            } else {
                // releaseAmount == positionValue or repayAmount <= payedAmount
                uint256 costAmount = SwapMath.getAmountIn(pairReserves, !self.marginForOne, repayAmount);
                if (releaseAmount > costAmount) {
                    profitAmount = releaseAmount - costAmount;
                } else if (repayAmount > payedAmount) {
                    lossAmount = repayAmount - payedAmount;
                }
            }

            if (marginTotal > 0) {
                uint256 marginAmountReleased = Math.mulDiv(marginAmount, closeMillionth, PerLibrary.ONE_MILLION);
                marginAmount = marginAmount - marginAmountReleased;
                if (releaseAmount > marginAmountReleased) {
                    uint256 marginTotalReleased = releaseAmount - marginAmountReleased;
                    marginTotal = marginTotal - marginTotalReleased;
                }
            } else {
                marginAmount =
                    Math.mulDiv(marginAmount, PerLibrary.ONE_MILLION - closeMillionth, PerLibrary.ONE_MILLION);
            }
            debtAmount -= repayAmount;
            self.marginAmount = marginAmount.toUint128();
            self.marginTotal = marginTotal.toUint128();
            self.depositCumulativeLast = depositCumulativeLast;
            self.debtAmount = debtAmount.toUint128();
            self.borrowCumulativeLast = borrowCumulativeLast;
        }
    }
}
