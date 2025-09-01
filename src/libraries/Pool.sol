// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "../types/BalanceDelta.sol";
import {FeeType} from "../types/FeeType.sol";
import {RateState} from "../types/RateState.sol";
import {ReservesType, Reserves, toReserves, ReservesLibrary} from "../types/Reserves.sol";
import {Slot0} from "../types/Slot0.sol";
import {CustomRevert} from "./CustomRevert.sol";
import {FeeLibrary} from "./FeeLibrary.sol";
import {FixedPoint96} from "./FixedPoint96.sol";
import {Math} from "./Math.sol";
import {PairPosition} from "./PairPosition.sol";
import {LendPosition} from "./LendPosition.sol";
import {MarginPosition} from "./MarginPosition.sol";
import {PerLibrary} from "./PerLibrary.sol";
import {ProtocolFeeLibrary} from "./ProtocolFeeLibrary.sol";
import {TimeLibrary} from "./TimeLibrary.sol";
import {SafeCast} from "./SafeCast.sol";
import {SwapMath} from "./SwapMath.sol";
import {InterestMath} from "./InterestMath.sol";

/// @title A library for managing Likwid pools.
/// @notice This library contains all the functions for interacting with a Likwid pool.
library Pool {
    using CustomRevert for bytes4;
    using SafeCast for *;
    using SwapMath for *;
    using FeeLibrary for uint24;
    using PerLibrary for uint256;
    using TimeLibrary for uint32;
    using Pool for State;
    using PairPosition for PairPosition.State;
    using PairPosition for mapping(bytes32 => PairPosition.State);
    using LendPosition for LendPosition.State;
    using LendPosition for mapping(bytes32 => LendPosition.State);
    using MarginPosition for MarginPosition.State;
    using MarginPosition for mapping(bytes32 => MarginPosition.State);

    /// @notice Thrown when trying to initialize an already initialized pool
    error PoolAlreadyInitialized();

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();

    /// @notice Thrown when trying to remove more liquidity than available in the pool
    error InsufficientLiquidity();

    error LeverageOverflow();

    error ReservesNotEnough();

    error MirrorTooMuch();

    error BorrowTooMuch();

    error MarginLevelError();

    uint256 constant MAX_PRICE_MOVE_PER_SECOND = 3000; // 0.3%/second
    uint8 constant MAX_LEVERAGE = 5; // 5x
    uint24 constant MIN_MARGIN_LEVEL = 1170000; // 117%
    uint24 constant MIN_BORROW_LEVEL = 1400000; // 140%

    struct State {
        Slot0 slot0;
        /// @notice The cumulative borrow rate of the first currency in the pool.
        uint256 borrow0CumulativeLast;
        /// @notice The cumulative borrow rate of the second currency in the pool.
        uint256 borrow1CumulativeLast;
        /// @notice The cumulative deposit rate of the first currency in the pool.
        uint256 deposit0CumulativeLast;
        /// @notice The cumulative deposit rate of the second currency in the pool.
        uint256 deposit1CumulativeLast;
        Reserves realReserves;
        Reserves mirrorReserves;
        Reserves pairReserves;
        Reserves truncatedReserves;
        Reserves lendReserves;
        Reserves interestReserves;
        /// @notice The positions in the pool, mapped by a hash of the owner's address and a salt.
        mapping(bytes32 positionKey => PairPosition.State) positions;
        mapping(bytes32 positionKey => LendPosition.State) lendPositions;
        mapping(bytes32 positionKey => MarginPosition.State) marginPositions;
    }

    struct ModifyLiquidityParams {
        // the address that owns the position
        address owner;
        uint256 amount0;
        uint256 amount1;
        // any change in liquidity
        int128 liquidityDelta;
        // used to distinguish positions of the same owner, at the same tick range
        bytes32 salt;
    }

    /// @notice Initializes the pool with a given fee
    /// @param self The pool state
    /// @param lpFee The initial fee for the pool
    function initialize(State storage self, uint24 lpFee) internal {
        if (self.borrow0CumulativeLast != 0) PoolAlreadyInitialized.selector.revertWith();

        // the initial protocolFee is 0 so doesn't need to be set
        self.slot0 = Slot0.wrap(bytes32(0)).setLastUpdated(uint32(block.timestamp)).setLpFee(lpFee);
        self.borrow0CumulativeLast = FixedPoint96.Q96;
        self.borrow1CumulativeLast = FixedPoint96.Q96;
        self.deposit0CumulativeLast = FixedPoint96.Q96;
        self.deposit1CumulativeLast = FixedPoint96.Q96;
    }

    /// @notice Sets the protocol fee for the pool
    /// @param self The pool state
    /// @param protocolFee The new protocol fee
    function setProtocolFee(State storage self, uint24 protocolFee) internal {
        self.checkPoolInitialized();
        self.slot0 = self.slot0.setProtocolFee(protocolFee);
    }

    /// @notice Sets the margin fee for the pool
    /// @param self The pool state
    /// @param marginFee The new margin fee
    function setMarginFee(State storage self, uint24 marginFee) internal {
        self.checkPoolInitialized();
        self.slot0 = self.slot0.setMarginFee(marginFee);
    }

    /// @notice Adds or removes liquidity from the pool
    /// @param self The pool state
    /// @param params The parameters for modifying liquidity
    /// @return delta The change in balances
    function modifyLiquidity(State storage self, ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        if (params.liquidityDelta == 0 && params.amount0 == 0 && params.amount1 == 0) {
            return BalanceDelta.wrap(0);
        }

        Slot0 _slot0 = self.slot0;
        Reserves _pairReserves = self.pairReserves;

        (uint128 _reserve0, uint128 _reserve1) = _pairReserves.reserves();
        uint128 totalSupply = _slot0.totalSupply();

        int128 finalLiquidityDelta;

        if (params.liquidityDelta < 0) {
            // --- Remove Liquidity ---
            uint256 liquidityToRemove = uint256(-int256(params.liquidityDelta));
            if (liquidityToRemove > totalSupply) InsufficientLiquidity.selector.revertWith();

            uint256 amount0Out = Math.mulDiv(liquidityToRemove, _reserve0, totalSupply);
            uint256 amount1Out = Math.mulDiv(liquidityToRemove, _reserve1, totalSupply);

            delta = toBalanceDelta(amount0Out.toInt128(), amount1Out.toInt128());
            self.slot0 = _slot0.setTotalSupply(totalSupply - liquidityToRemove.toUint128());
            finalLiquidityDelta = params.liquidityDelta;
        } else {
            // --- Add Liquidity ---
            uint256 amount0In;
            uint256 amount1In;
            uint256 liquidityAdded;

            if (totalSupply == 0) {
                amount0In = params.amount0;
                amount1In = params.amount1;
                liquidityAdded = Math.sqrt(amount0In * amount1In);
            } else {
                uint256 amount1FromAmount0 = Math.mulDiv(params.amount0, _reserve1, _reserve0);
                if (amount1FromAmount0 <= params.amount1) {
                    amount0In = params.amount0;
                    amount1In = amount1FromAmount0;
                } else {
                    amount0In = Math.mulDiv(params.amount1, _reserve0, _reserve1);
                    amount1In = params.amount1;
                }
                liquidityAdded = Math.min(
                    Math.mulDiv(amount0In, totalSupply, _reserve0), Math.mulDiv(amount1In, totalSupply, _reserve1)
                );
            }

            delta = toBalanceDelta(-amount0In.toInt128(), -amount1In.toInt128());

            self.slot0 = _slot0.setTotalSupply(totalSupply + liquidityAdded.toUint128());
            finalLiquidityDelta = liquidityAdded.toInt128();
        }
        ReservesLibrary.UpdateParam[] memory deltaParams = new ReservesLibrary.UpdateParam[](2);
        deltaParams[0] = ReservesLibrary.UpdateParam(ReservesType.REAL, delta);
        deltaParams[1] = ReservesLibrary.UpdateParam(ReservesType.PAIR, delta);
        self.updateReserves(deltaParams);

        self.positions.get(params.owner, params.salt).update(finalLiquidityDelta, delta);
    }

    struct SwapParams {
        address sender;
        // zeroForOne Whether to swap token0 for token1
        bool zeroForOne;
        // The amount to swap, negative for exact input, positive for exact output
        int256 amountSpecified;
        // Whether to use the mirror reserves for the swap
        bool useMirror;
    }

    /// @notice Swaps tokens in the pool
    /// @param self The pool state
    /// @param params The parameters for the swap
    /// @return swapDelta The change in balances
    /// @return amountToProtocol The amount of fees to be sent to the protocol
    /// @return swapFee The fee for the swap
    /// @return feeAmount The total fee amount for the swap.
    function swap(State storage self, SwapParams memory params)
        internal
        returns (BalanceDelta swapDelta, uint256 amountToProtocol, uint24 swapFee, uint256 feeAmount)
    {
        Reserves _pairReserves = self.pairReserves;
        Reserves _truncatedReserves = self.truncatedReserves;
        Slot0 _slot0 = self.slot0;
        uint24 _lpFee = _slot0.lpFee();

        bool exactIn = params.amountSpecified < 0;

        uint256 amountIn;
        uint256 amountOut;

        if (exactIn) {
            amountIn = uint256(-params.amountSpecified);
            (amountOut, swapFee, feeAmount) =
                SwapMath.getAmountOut(_pairReserves, _truncatedReserves, _lpFee, params.zeroForOne, amountIn);
        } else {
            amountOut = uint256(params.amountSpecified);
            (amountIn, swapFee, feeAmount) =
                SwapMath.getAmountIn(_pairReserves, _truncatedReserves, _lpFee, params.zeroForOne, amountOut);
        }

        (amountToProtocol, feeAmount) = ProtocolFeeLibrary.splitFee(_slot0.protocolFee(), FeeType.SWAP, feeAmount);

        int128 amount0Delta;
        int128 amount1Delta;

        if (params.zeroForOne) {
            amount0Delta = -amountIn.toInt128();
            amount1Delta = amountOut.toInt128();
        } else {
            amount0Delta = amountOut.toInt128();
            amount1Delta = -amountIn.toInt128();
        }

        swapDelta = toBalanceDelta(amount0Delta, amount1Delta);
        ReservesLibrary.UpdateParam[] memory deltaParams;
        if (!params.useMirror) {
            deltaParams = new ReservesLibrary.UpdateParam[](2);
            deltaParams[0] = ReservesLibrary.UpdateParam(ReservesType.REAL, swapDelta);
            deltaParams[1] = ReservesLibrary.UpdateParam(ReservesType.PAIR, swapDelta);
        } else {
            deltaParams = new ReservesLibrary.UpdateParam[](3);
            BalanceDelta realDelta;
            BalanceDelta mirrorDelta;
            if (params.zeroForOne) {
                realDelta = toBalanceDelta(amount0Delta, 0);
                mirrorDelta = toBalanceDelta(0, amount1Delta);
            } else {
                realDelta = toBalanceDelta(0, amount1Delta);
                mirrorDelta = toBalanceDelta(amount0Delta, 0);
            }
            deltaParams[0] = ReservesLibrary.UpdateParam(ReservesType.REAL, realDelta);
            deltaParams[1] = ReservesLibrary.UpdateParam(ReservesType.MIRROR, mirrorDelta);
            deltaParams[2] = ReservesLibrary.UpdateParam(ReservesType.PAIR, swapDelta);
        }
        self.updateReserves(deltaParams);
    }

    struct LendParams {
        address sender;
        /// False if lend token0,true if lend token1
        bool lendForOne;
        /// The amount to lend, negative for deposit, positive for withdraw
        int128 lendAmount;
        bytes32 salt;
    }

    /// @notice Lends tokens to the pool.
    /// @param self The pool state.
    /// @param params The parameters for the lending operation.
    /// @return lendDelta The change in the lender's balance.
    /// @return depositCumulativeLast The last cumulative deposit rate.
    function lend(State storage self, LendParams memory params)
        internal
        returns (BalanceDelta lendDelta, uint256 depositCumulativeLast)
    {
        int128 amount0Delta;
        int128 amount1Delta;

        if (params.lendForOne) {
            amount1Delta = params.lendAmount;
            depositCumulativeLast = self.deposit1CumulativeLast;
        } else {
            amount0Delta = params.lendAmount;
            depositCumulativeLast = self.deposit0CumulativeLast;
        }

        lendDelta = toBalanceDelta(amount0Delta, amount1Delta);
        ReservesLibrary.UpdateParam[] memory deltaParams = new ReservesLibrary.UpdateParam[](2);
        deltaParams[0] = ReservesLibrary.UpdateParam(ReservesType.REAL, lendDelta);
        deltaParams[1] = ReservesLibrary.UpdateParam(ReservesType.LEND, lendDelta);
        self.updateReserves(deltaParams);

        self.lendPositions.get(params.sender, params.lendForOne, params.salt).update(depositCumulativeLast, lendDelta);
    }

    struct MarginParams {
        address sender;
        /// False if margin token0,true if margin token1
        bool marginForOne;
        /// The amount to change, negative for margin amount, positive for repay amount
        int128 amount;
        // margin
        uint128 marginTotal;
        // borrow
        uint128 borrowAmount;
        bytes32 salt;
    }

    /// @notice Opens or modifies a margin position.
    /// @param self The pool state.
    /// @param params The parameters for the margin operation.
    /// @return marginDelta The change in the user's balance.
    /// @return amountToProtocol The amount of fees to be sent to the protocol.
    /// @return feeAmount The total fee amount for the margin operation.
    function margin(State storage self, MarginParams memory params)
        internal
        returns (BalanceDelta marginDelta, uint256 amountToProtocol, uint256 feeAmount)
    {
        if (params.amount == 0) {
            return (BalanceDelta.wrap(0), 0, 0);
        }

        uint256 marginWithoutFee;
        int128 amount0Delta;
        int128 amount1Delta;
        BalanceDelta pairDelta;
        BalanceDelta lendDelta;
        BalanceDelta mirrorDelta;

        // --- Load storage vars into stack to reduce SLOADs ---
        Reserves _realReserves = self.realReserves;
        Reserves _mirrorReserves = self.mirrorReserves;
        Reserves _pairReserves = self.pairReserves;
        Reserves _truncatedReserves = self.truncatedReserves;
        Slot0 _slot0 = self.slot0;

        uint256 borrowCumulativeLast;
        uint256 depositCumulativeLast;
        if (params.marginForOne) {
            borrowCumulativeLast = self.borrow0CumulativeLast;
            depositCumulativeLast = self.deposit1CumulativeLast;
        } else {
            borrowCumulativeLast = self.borrow1CumulativeLast;
            depositCumulativeLast = self.deposit0CumulativeLast;
        }

        if (params.amount < 0) {
            // --- Margin or Borrow ---
            uint128 marginAmount = uint128(-params.amount);
            if (params.marginTotal > marginAmount * MAX_LEVERAGE) LeverageOverflow.selector.revertWith();

            uint256 borrowRealReserves = _realReserves.reserve01(!params.marginForOne);
            uint256 borrowAmount;

            if (params.marginTotal > 0) {
                // --- Margin ---
                uint256 borrowMirrorReserves = _mirrorReserves.reserve01(!params.marginForOne);
                if (Math.mulDiv(borrowMirrorReserves, 100, borrowRealReserves + borrowMirrorReserves) > 90) {
                    MirrorTooMuch.selector.revertWith();
                }

                uint256 marginReserves = _realReserves.reserve01(params.marginForOne);
                if (params.marginTotal > marginReserves) ReservesNotEnough.selector.revertWith();

                uint24 marginFee = _slot0.marginFee();
                (marginWithoutFee, feeAmount) = marginFee.deduct(params.marginTotal);
                (amountToProtocol,) = ProtocolFeeLibrary.splitFee(_slot0.protocolFee(), FeeType.MARGIN, feeAmount);
                uint24 swapFee;
                (borrowAmount, swapFee, feeAmount) = SwapMath.getAmountIn(
                    _pairReserves, _truncatedReserves, _slot0.lpFee(), !params.marginForOne, params.marginTotal
                );
                params.borrowAmount = borrowAmount.toUint128();

                (uint128 reserve0, uint128 reserve1) = _pairReserves.reserves();
                (uint256 reserveBorrow, uint256 reserveMargin) =
                    params.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);

                uint256 positionValue = Math.mulDiv(reserveBorrow, marginAmount + params.marginTotal, reserveMargin);
                uint256 marginLevel = Math.mulDiv(positionValue, PerLibrary.ONE_MILLION, borrowAmount);
                if (marginLevel < MIN_MARGIN_LEVEL) MarginLevelError.selector.revertWith();
            } else {
                // --- Borrow ---
                uint256 borrowMAXAmount =
                    _pairReserves.getAmountOut(!params.marginForOne, marginAmount).mulMillionDiv(MIN_BORROW_LEVEL);
                borrowMAXAmount = Math.min(borrowMAXAmount, borrowRealReserves * 20 / 100);
                if (params.borrowAmount > borrowMAXAmount) BorrowTooMuch.selector.revertWith();
                if (params.borrowAmount == 0) params.borrowAmount = borrowMAXAmount.toUint128();
                borrowAmount = params.borrowAmount;
            }

            int128 lendAmount = params.amount - marginWithoutFee.toInt128();
            if (params.marginForOne) {
                amount1Delta = params.amount;
                pairDelta = toBalanceDelta(-borrowAmount.toInt128(), marginWithoutFee.toInt128());
                lendDelta = toBalanceDelta(0, lendAmount);
                mirrorDelta = toBalanceDelta(-borrowAmount.toInt128(), 0);
            } else {
                amount0Delta = params.amount;
                pairDelta = toBalanceDelta(marginWithoutFee.toInt128(), -borrowAmount.toInt128());
                lendDelta = toBalanceDelta(lendAmount, 0);
                mirrorDelta = toBalanceDelta(0, -borrowAmount.toInt128());
            }

            if (params.marginTotal == 0) {
                if (params.marginForOne) {
                    // Borrowed token0
                    amount0Delta = borrowAmount.toInt128();
                } else {
                    // Borrowed token1
                    amount1Delta = borrowAmount.toInt128();
                }
            }
        } else {
            // --- Repay Debt ---
            uint128 repayAmount = uint128(params.amount);
            if (params.marginForOne) {
                amount0Delta = -params.amount;
                mirrorDelta = toBalanceDelta(repayAmount.toInt128(), 0);
            } else {
                amount1Delta = -params.amount;
                mirrorDelta = toBalanceDelta(0, repayAmount.toInt128());
            }
        }

        uint256 releaseAmount = self.marginPositions.get(params.sender, params.marginForOne, params.salt).update(
            params.marginForOne,
            borrowCumulativeLast,
            depositCumulativeLast,
            params.amount,
            marginWithoutFee,
            params.borrowAmount
        );

        if (releaseAmount > 0) {
            // transfer from pair reserves to user
            if (params.marginForOne) {
                amount1Delta = releaseAmount.toInt128();
                lendDelta = toBalanceDelta(0, amount1Delta);
            } else {
                amount0Delta = releaseAmount.toInt128();
                lendDelta = toBalanceDelta(amount0Delta, 0);
            }
        }

        marginDelta = toBalanceDelta(amount0Delta, amount1Delta);
        ReservesLibrary.UpdateParam[] memory deltaParams = new ReservesLibrary.UpdateParam[](4);
        deltaParams[0] = ReservesLibrary.UpdateParam(ReservesType.REAL, marginDelta);
        deltaParams[1] = ReservesLibrary.UpdateParam(ReservesType.PAIR, pairDelta);
        deltaParams[2] = ReservesLibrary.UpdateParam(ReservesType.LEND, lendDelta);
        deltaParams[3] = ReservesLibrary.UpdateParam(ReservesType.MIRROR, mirrorDelta);
        self.updateReserves(deltaParams);
    }

    struct CloseParams {
        address sender;
        bytes32 positionKey;
        bytes32 salt;
        uint256 rewardAmount;
        uint24 closeMillionth;
    }

    /// @notice Handles the closing of a normal (non-liquidated) margin position.
    /// @param position The margin position to close.
    /// @param releaseAmount The amount of collateral to release.
    /// @param repayAmount The amount of debt to repay.
    /// @param profitAmount The profit from the position.
    /// @return closeDelta The change in the user's balance.
    /// @return pairDelta The change in the pair reserves.
    /// @return lendDelta The change in the lending reserves.
    /// @return mirrorDelta The change in the mirror reserves.
    function _handleNormalClose(
        MarginPosition.State storage position,
        uint256 releaseAmount,
        uint256 repayAmount,
        uint256 profitAmount
    )
        internal
        view
        returns (BalanceDelta closeDelta, BalanceDelta pairDelta, BalanceDelta lendDelta, BalanceDelta mirrorDelta)
    {
        // close (profit or break-even)
        if (position.marginForOne) {
            closeDelta = toBalanceDelta(0, profitAmount.toInt128());
            pairDelta = toBalanceDelta(repayAmount.toInt128(), -(releaseAmount - profitAmount).toInt128());
            lendDelta = toBalanceDelta(0, releaseAmount.toInt128());
            mirrorDelta = toBalanceDelta(repayAmount.toInt128(), 0);
        } else {
            closeDelta = toBalanceDelta(profitAmount.toInt128(), 0);
            pairDelta = toBalanceDelta(-(releaseAmount - profitAmount).toInt128(), repayAmount.toInt128());
            lendDelta = toBalanceDelta(releaseAmount.toInt128(), 0);
            mirrorDelta = toBalanceDelta(0, repayAmount.toInt128());
        }
    }

    /// @notice Handles the liquidation of a margin position.
    /// @param self The pool state.
    /// @param position The margin position to liquidate.
    /// @param releaseAmount The amount of collateral to release.
    /// @param repayAmount The amount of debt to repay.
    /// @param profitAmount The profit from the position.
    /// @param lossAmount The loss from the position.
    /// @param rewardAmount The reward for the liquidator.
    /// @return closeDelta The change in the liquidator's balance.
    /// @return pairDelta The change in the pair reserves.
    /// @return lendDelta The change in the lending reserves.
    /// @return mirrorDelta The change in the mirror reserves.
    function _handleLiquidation(
        State storage self,
        MarginPosition.State storage position,
        uint256 releaseAmount,
        uint256 repayAmount,
        uint256 profitAmount,
        uint256 lossAmount,
        uint256 rewardAmount
    )
        internal
        returns (BalanceDelta closeDelta, BalanceDelta pairDelta, BalanceDelta lendDelta, BalanceDelta mirrorDelta)
    {
        if (position.marginForOne) {
            closeDelta = toBalanceDelta(0, rewardAmount.toInt128());
        } else {
            closeDelta = toBalanceDelta(rewardAmount.toInt128(), 0);
        }
        (uint256 pairReserve0, uint256 pairReserve1) = self.pairReserves.reserves();
        (uint256 lendReserve0, uint256 lendReserve1) = self.lendReserves.reserves();
        if (position.marginForOne) {
            uint256 pairLostAmount = Math.mulDiv(lossAmount, pairReserve0, pairReserve0 + lendReserve0);
            pairDelta =
                toBalanceDelta((repayAmount - pairLostAmount).toInt128(), -(releaseAmount - profitAmount).toInt128());
            lendDelta = toBalanceDelta(0, releaseAmount.toInt128());
            mirrorDelta = toBalanceDelta(repayAmount.toInt128(), 0);
            uint256 lendLostAmount = lossAmount - pairLostAmount;
            self.deposit0CumulativeLast =
                Math.mulDiv(self.deposit0CumulativeLast, lendReserve0 - lendLostAmount, lendReserve0);
        } else {
            uint256 pairLostAmount = Math.mulDiv(lossAmount, pairReserve1, pairReserve1 + lendReserve1);
            pairDelta =
                toBalanceDelta(-(releaseAmount - profitAmount).toInt128(), (repayAmount - pairLostAmount).toInt128());
            lendDelta = toBalanceDelta(releaseAmount.toInt128(), 0);
            mirrorDelta = toBalanceDelta(0, repayAmount.toInt128());
            uint256 lendLostAmount = lossAmount - pairLostAmount;
            self.deposit1CumulativeLast =
                Math.mulDiv(self.deposit1CumulativeLast, lendReserve1 - lendLostAmount, lendReserve1);
        }
    }

    /// @notice Closes a margin position.
    /// @param self The pool state.
    /// @param params The parameters for closing the position.
    /// @return closeDelta The change in the user's balance.
    function close(State storage self, CloseParams memory params) internal returns (BalanceDelta closeDelta) {
        MarginPosition.State storage position = self.marginPositions.get(params.sender, params.positionKey, params.salt);
        (uint256 releaseAmount, uint256 repayAmount, uint256 profitAmount, uint256 lossAmount) = position.close(
            self.pairReserves,
            position.marginForOne ? self.borrow0CumulativeLast : self.borrow1CumulativeLast,
            position.marginForOne ? self.deposit1CumulativeLast : self.deposit0CumulativeLast,
            params.rewardAmount,
            params.closeMillionth
        );

        BalanceDelta pairDelta;
        BalanceDelta lendDelta;
        BalanceDelta mirrorDelta;

        if (params.rewardAmount == 0) {
            (closeDelta, pairDelta, lendDelta, mirrorDelta) =
                _handleNormalClose(position, releaseAmount, repayAmount, profitAmount);
        } else {
            (closeDelta, pairDelta, lendDelta, mirrorDelta) = _handleLiquidation(
                self, position, releaseAmount, repayAmount, profitAmount, lossAmount, params.rewardAmount
            );
        }

        ReservesLibrary.UpdateParam[] memory deltaParams = new ReservesLibrary.UpdateParam[](4);
        deltaParams[0] = ReservesLibrary.UpdateParam(ReservesType.REAL, closeDelta);
        deltaParams[1] = ReservesLibrary.UpdateParam(ReservesType.PAIR, pairDelta);
        deltaParams[2] = ReservesLibrary.UpdateParam(ReservesType.LEND, lendDelta);
        deltaParams[3] = ReservesLibrary.UpdateParam(ReservesType.MIRROR, mirrorDelta);
        self.updateReserves(deltaParams);
    }

    /// @notice Reverts if the given pool has not been initialized
    /// @param self The pool state
    function checkPoolInitialized(State storage self) internal view {
        if (self.borrow0CumulativeLast == 0) PoolNotInitialized.selector.revertWith();
    }

    /// @notice Transforms the truncated reserves based on the current pair reserves.
    /// @param self The pool state.
    function transformTruncated(State storage self) internal {
        Reserves _pairReserves = self.pairReserves;
        Reserves _truncatedReserves = self.truncatedReserves;
        Slot0 _slot0 = self.slot0;
        if (_pairReserves.bothPositive()) {
            if (!_truncatedReserves.bothPositive()) {
                self.truncatedReserves = _pairReserves;
            } else {
                (uint256 truncatedReserve0, uint256 truncatedReserve1) = _truncatedReserves.reserves();
                uint256 delta = _slot0.lastUpdated().getTimeElapsed();
                uint256 priceMoved = MAX_PRICE_MOVE_PER_SECOND * (delta ** 2);
                uint128 newTruncatedReserve0 = 0;
                uint128 newTruncatedReserve1 = _pairReserves.reserve1();
                uint256 _reserve0 = _pairReserves.reserve0();

                uint256 reserve0Min =
                    Math.mulDiv(newTruncatedReserve1, truncatedReserve0.lowerMillion(priceMoved), truncatedReserve1);
                uint256 reserve0Max =
                    Math.mulDiv(newTruncatedReserve1, truncatedReserve0.upperMillion(priceMoved), truncatedReserve1);
                if (_reserve0 < reserve0Min) {
                    newTruncatedReserve0 = reserve0Min.toUint128();
                } else if (_reserve0 > reserve0Max) {
                    newTruncatedReserve0 = reserve0Max.toUint128();
                } else {
                    newTruncatedReserve0 = _reserve0.toUint128();
                }
                self.truncatedReserves = toReserves(newTruncatedReserve0, newTruncatedReserve1);
            }
        }
        self.slot0 = _slot0.setLastUpdated(uint32(block.timestamp));
    }

    /// @notice Updates the interest rates for the pool.
    /// @param self The pool state.
    /// @param rateState The current rate state.
    /// @return pairInterest0 The interest earned by the pair for token0.
    /// @return pairInterest1 The interest earned by the pair for token1.
    function updateInterests(State storage self, RateState rateState)
        internal
        returns (uint256 pairInterest0, uint256 pairInterest1)
    {
        Slot0 _slot0 = self.slot0;
        uint256 timeElapsed = _slot0.lastUpdated().getTimeElapsedMicrosecond();
        if (timeElapsed == 0) return (0, 0);
        Reserves _realReserves = self.realReserves;
        Reserves _mirrorReserves = self.mirrorReserves;
        Reserves _interestReserves = self.interestReserves;
        Reserves _pairReserves = self.pairReserves;
        Reserves _lendReserves = self.lendReserves;
        uint256 borrow0CumulativeBefore = self.borrow0CumulativeLast;
        uint256 borrow1CumulativeBefore = self.borrow1CumulativeLast;
        (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast) = InterestMath.getBorrowRateCumulativeLast(
            timeElapsed, borrow0CumulativeBefore, borrow1CumulativeBefore, rateState, _realReserves, _mirrorReserves
        );
        (uint256 pairReserve0, uint256 pairReserve1) = _pairReserves.reserves();
        (uint256 lendReserve0, uint256 lendReserve1) = _lendReserves.reserves();
        (uint256 mirrorReserve0, uint256 mirrorReserve1) = _mirrorReserves.reserves();
        (uint256 interestReserve0, uint256 interestReserve1) = _interestReserves.reserves();
        bool reserve0Changed;
        bool reserve1Changed;
        if (mirrorReserve0 > 0 && rate0CumulativeLast > borrow0CumulativeBefore) {
            self.borrow0CumulativeLast = rate0CumulativeLast;
            uint256 allInterest0 = Math.mulDiv(
                mirrorReserve0 * FixedPoint96.Q96, rate0CumulativeLast, borrow0CumulativeBefore
            ) - mirrorReserve0 * FixedPoint96.Q96 + interestReserve0 * FixedPoint96.Q96;
            (uint256 protocolInterest,) =
                ProtocolFeeLibrary.splitFee(_slot0.protocolFee(), FeeType.INTERESTS, allInterest0);
            allInterest0 = allInterest0 / FixedPoint96.Q96;
            if (protocolInterest == 0 || protocolInterest > FixedPoint96.Q96) {
                protocolInterest = protocolInterest / FixedPoint96.Q96;
                allInterest0 -= protocolInterest;
                pairInterest0 = Math.mulDiv(allInterest0, pairReserve0, pairReserve0 + lendReserve0);
                if (allInterest0 > pairInterest0) {
                    uint256 lendingInterest = allInterest0 - pairInterest0;
                    self.deposit0CumulativeLast =
                        Math.mulDiv(self.deposit0CumulativeLast, lendReserve0 + lendingInterest, lendReserve0);
                    lendReserve0 += lendingInterest;
                }
                mirrorReserve0 += allInterest0;
                pairReserve0 += pairInterest0;
                reserve0Changed = true;
                interestReserve0 = 0;
            } else {
                interestReserve0 = allInterest0;
            }
        }
        if (mirrorReserve1 > 0 && rate1CumulativeLast > borrow1CumulativeBefore) {
            self.borrow1CumulativeLast = rate1CumulativeLast;
            uint256 allInterest1 = Math.mulDiv(
                mirrorReserve1 * FixedPoint96.Q96, rate1CumulativeLast, borrow1CumulativeBefore
            ) - mirrorReserve1 * FixedPoint96.Q96 + interestReserve1 * FixedPoint96.Q96;
            (uint256 protocolInterest,) =
                ProtocolFeeLibrary.splitFee(_slot0.protocolFee(), FeeType.INTERESTS, allInterest1);
            allInterest1 = allInterest1 / FixedPoint96.Q96;
            if (protocolInterest == 0 || protocolInterest > FixedPoint96.Q96) {
                protocolInterest = protocolInterest / FixedPoint96.Q96;
                allInterest1 -= protocolInterest;
                pairInterest1 = Math.mulDiv(allInterest1, pairReserve1, pairReserve1 + lendReserve1);
                if (allInterest1 > pairInterest1) {
                    uint256 lendingInterest = allInterest1 - pairInterest1;
                    self.deposit1CumulativeLast =
                        Math.mulDiv(self.deposit1CumulativeLast, lendReserve1 + lendingInterest, lendReserve1);
                    lendReserve1 += lendingInterest;
                }
                mirrorReserve1 += allInterest1;
                pairReserve1 += pairInterest1;
                reserve1Changed = true;
                interestReserve1 = 0;
            } else {
                interestReserve1 = allInterest1;
            }
        }
        if (reserve0Changed || reserve1Changed) {
            self.mirrorReserves = toReserves(mirrorReserve0.toUint128(), mirrorReserve1.toUint128());
            self.pairReserves = toReserves(pairReserve0.toUint128(), pairReserve1.toUint128());
            self.lendReserves = toReserves(lendReserve0.toUint128(), lendReserve1.toUint128());
        }

        self.interestReserves = toReserves(interestReserve0.toUint128(), interestReserve1.toUint128());
        self.slot0 = self.slot0.setLastUpdated(uint32(block.timestamp));
    }

    /// @notice Updates the reserves of the pool.
    /// @param self The pool state.
    /// @param params An array of parameters for updating the reserves.
    function updateReserves(State storage self, ReservesLibrary.UpdateParam[] memory params) internal {
        if (params.length == 0) return;
        Reserves _realReserves = self.realReserves;
        Reserves _mirrorReserves = self.mirrorReserves;
        Reserves _pairReserves = self.pairReserves;
        Reserves _lendReserves = self.lendReserves;
        for (uint256 i = 0; i < params.length; i++) {
            ReservesType _type = params[i]._type;
            BalanceDelta delta = params[i].delta;
            if (_type == ReservesType.REAL) {
                _realReserves = _realReserves.applyDelta(delta);
            } else if (_type == ReservesType.MIRROR) {
                _mirrorReserves = _mirrorReserves.applyDelta(delta);
            } else if (_type == ReservesType.PAIR) {
                _pairReserves = _pairReserves.applyDelta(delta);
            } else if (_type == ReservesType.LEND) {
                _lendReserves = _lendReserves.applyDelta(delta);
            }
        }
        self.realReserves = _realReserves;
        self.mirrorReserves = _mirrorReserves;
        self.pairReserves = _pairReserves;
        self.lendReserves = _lendReserves;
        self.transformTruncated();
    }
}
