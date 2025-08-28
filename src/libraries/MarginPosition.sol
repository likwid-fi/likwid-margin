// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.0;

import {Math} from "./Math.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../types/BalanceDelta.sol";
import {CustomRevert} from "./CustomRevert.sol";
import {PositionLibrary} from "./PositionLibrary.sol";
import {SafeCast} from "./SafeCast.sol";

/// @title MarginPosition
/// @notice Positions represent an owner address' margin positions
library MarginPosition {
    using CustomRevert for bytes4;
    using PositionLibrary for address;
    using SafeCast for *;

    error CannotUpdateEmptyPosition();

    error InsufficientBorrowAmount();

    error NoChangeInPosition();

    struct State {
        bool marginForOne;
        uint128 marginAmount;
        uint128 marginTotal;
        uint128 debtAmount;
        uint256 borrowCumulativeLast;
        uint256 depositCumulativeLast;
    }

    function get(
        mapping(bytes32 => State) storage self,
        address owner,
        bool marginForOne,
        uint128 marginTotal,
        bytes32 salt
    ) internal view returns (State storage position) {
        bytes32 positionKey = owner.calculatePositionKey(marginForOne, marginTotal > 0, salt);
        position = self[positionKey];
    }

    function update(
        State storage self,
        uint256 borrowCumulativeLast,
        uint256 depositCumulativeLast,
        int128 amount,
        uint256 marginWithoutFee,
        uint256 borrowAmount
    ) internal returns (State memory _stage, uint256 releaseAmount) {
        if (amount == 0) NoChangeInPosition.selector.revertWith();
        if (amount < 0) {
            // margin or borrow
            if (borrowAmount == 0) InsufficientBorrowAmount.selector.revertWith();
        } else {
            // repay debt
            if (self.debtAmount == 0) CannotUpdateEmptyPosition.selector.revertWith();
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

        if (amount < 0) {
            marginAmount += uint128(-amount);
            marginTotal += marginWithoutFee;
            debtAmount += borrowAmount;
        } else {
            releaseAmount = Math.mulDiv(positionValue, uint128(amount), debtAmount);
            debtAmount -= uint128(amount);
            positionValue -= releaseAmount;
        }
        if (marginTotal > 0) {
            if (positionValue > marginTotal) {
                marginAmount = positionValue - marginTotal;
            } else {
                marginTotal = positionValue;
                marginAmount = 0;
            }
            marginTotal += marginWithoutFee;
        } else {
            marginAmount = positionValue;
        }
        self.marginAmount = marginAmount.toUint128();
        self.marginTotal = marginTotal.toUint128();
        self.depositCumulativeLast = depositCumulativeLast;
        self.debtAmount = debtAmount.toUint128();
        self.borrowCumulativeLast = borrowCumulativeLast;
        _stage = self;
    }
}
