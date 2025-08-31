// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.0;

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

    function update(
        State storage self,
        bool marginForOne,
        uint256 borrowCumulativeLast,
        uint256 depositCumulativeLast,
        int128 amount,
        uint256 marginWithoutFee,
        uint256 borrowAmount
    ) internal returns (uint256 releaseAmount) {
        if (amount == 0) NoChangeInPosition.selector.revertWith();
        if (amount < 0) {
            // margin or borrow
            if (borrowAmount == 0) InvalidBorrowAmount.selector.revertWith();
        } else {
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
            debtAmount = Math.mulDiv(self.debtAmount, borrowCumulativeLast, self.borrowCumulativeLast);
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
        } else {
            releaseAmount = Math.mulDiv(positionValue, uint128(amount), debtAmount);
            debtAmount -= uint128(amount);
            positionValue -= releaseAmount;
            if (hasLeverage) {
                if (positionValue > marginTotal) {
                    marginAmount = positionValue - marginTotal;
                } else {
                    marginTotal = positionValue;
                    marginAmount = 0;
                }
            } else {
                marginAmount = positionValue;
            }
        }

        self.marginAmount = marginAmount.toUint128();
        self.marginTotal = marginTotal.toUint128();
        self.depositCumulativeLast = depositCumulativeLast;
        self.debtAmount = debtAmount.toUint128();
        self.borrowCumulativeLast = borrowCumulativeLast;
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
            if (releaseAmount > marginAmount) {
                // only margin
                marginAmount = 0;
                marginTotal = positionValue - releaseAmount;
            } else {
                marginAmount -= releaseAmount;
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
