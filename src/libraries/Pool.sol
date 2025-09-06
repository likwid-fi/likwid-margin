// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";

import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "../types/BalanceDelta.sol";
import {FeeType} from "../types/FeeType.sol";
import {MarginState} from "../types/MarginState.sol";
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
import {PriceMath} from "./PriceMath.sol";

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

    uint8 constant MAX_LEVERAGE = 5; // 5x

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
        returns (BalanceDelta delta, int128 finalLiquidityDelta)
    {
        if (params.liquidityDelta == 0 && params.amount0 == 0 && params.amount1 == 0) {
            return (BalanceDelta.wrap(0), 0);
        }

        Slot0 _slot0 = self.slot0;
        Reserves _pairReserves = self.pairReserves;

        (uint128 _reserve0, uint128 _reserve1) = _pairReserves.reserves();
        uint128 totalSupply = _slot0.totalSupply();

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
        bytes32 salt;
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

        ReservesLibrary.UpdateParam[] memory deltaParams;
        swapDelta = toBalanceDelta(amount0Delta, amount1Delta);
        if (!params.useMirror) {
            deltaParams = new ReservesLibrary.UpdateParam[](2);
            deltaParams[0] = ReservesLibrary.UpdateParam(ReservesType.REAL, swapDelta);
            deltaParams[1] = ReservesLibrary.UpdateParam(ReservesType.PAIR, swapDelta);
        } else {
            deltaParams = new ReservesLibrary.UpdateParam[](3);
            BalanceDelta realDelta;
            BalanceDelta lendDelta;
            if (params.zeroForOne) {
                realDelta = toBalanceDelta(amount0Delta, 0);
                lendDelta = toBalanceDelta(0, -amount1Delta);
            } else {
                realDelta = toBalanceDelta(0, amount1Delta);
                lendDelta = toBalanceDelta(-amount0Delta, 0);
            }
            deltaParams[0] = ReservesLibrary.UpdateParam(ReservesType.REAL, realDelta);
            // pair MIRROR<=>lend MIRROR
            deltaParams[1] = ReservesLibrary.UpdateParam(ReservesType.LEND, lendDelta);
            deltaParams[2] = ReservesLibrary.UpdateParam(ReservesType.PAIR, swapDelta);
            uint256 depositCumulativeLast;
            if (params.zeroForOne) {
                depositCumulativeLast = self.deposit1CumulativeLast;
            } else {
                depositCumulativeLast = self.deposit0CumulativeLast;
            }
            self.lendPositions.get(params.sender, params.zeroForOne, params.salt).update(
                depositCumulativeLast, lendDelta
            );
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
        /// The amount to change, negative for margin amount, positive for repay amount,zero for modify
        int128 amount;
        // margin
        uint128 marginTotal;
        // borrow
        uint128 borrowAmount;
        // modify
        int128 changeAmount;
        uint24 minMarginLevel;
        bytes32 salt;
    }

    /// @notice Opens or modifies a margin position.
    /// @param self The pool state.
    /// @param params The parameters for the margin operation.
    /// @return marginDelta The change in the user's balance.
    /// @return assetAmount The amount of asset involved in the margin operation.
    /// @return amountToProtocol The amount of fees to be sent to the protocol.
    /// @return feeAmount The total fee amount for the margin operation.
    function margin(State storage self, MarginParams memory params)
        internal
        returns (BalanceDelta marginDelta, uint256 assetAmount, uint256 amountToProtocol, uint256 feeAmount)
    {
        if (params.amount == 0 && params.changeAmount == 0) {
            return (BalanceDelta.wrap(0), 0, 0, 0);
        }
        if (params.minMarginLevel < PerLibrary.ONE_MILLION) {
            params.minMarginLevel = uint24(PerLibrary.ONE_MILLION);
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
            } else {
                // --- Borrow ---
                uint256 borrowMAXAmount = _pairReserves.getAmountOut(!params.marginForOne, marginAmount);
                borrowMAXAmount = Math.min(borrowMAXAmount, borrowRealReserves * 20 / 100);
                if (params.borrowAmount > borrowMAXAmount) BorrowTooMuch.selector.revertWith();
                if (params.borrowAmount == 0) params.borrowAmount = borrowMAXAmount.toUint128();
                borrowAmount = params.borrowAmount;
            }

            int128 lendAmount = params.amount - marginWithoutFee.toInt128();

            if (params.marginTotal == 0) {
                // borrow
                if (params.marginForOne) {
                    // margin token1, borrow token0
                    amount1Delta = params.amount;
                    amount0Delta = borrowAmount.toInt128();
                    // pairDelta = 0
                    lendDelta = toBalanceDelta(0, lendAmount);
                    mirrorDelta = toBalanceDelta(-borrowAmount.toInt128(), 0);
                } else {
                    // margin token0, borrow token1
                    amount0Delta = params.amount;
                    amount1Delta = borrowAmount.toInt128();
                    // pairDelta = 0
                    lendDelta = toBalanceDelta(lendAmount, 0);
                    mirrorDelta = toBalanceDelta(0, -borrowAmount.toInt128());
                }
            } else {
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
                assetAmount = borrowAmount;
            }
        } else if (params.amount == 0) {
            // --- Modify Margin ---
            int128 changeAmount = params.changeAmount;
            if (changeAmount == 0) {
                return (BalanceDelta.wrap(0), 0, 0, 0);
            }
            if (params.marginForOne) {
                amount1Delta = -changeAmount;
                lendDelta = toBalanceDelta(0, amount1Delta);
            } else {
                amount0Delta = -changeAmount;
                lendDelta = toBalanceDelta(amount0Delta, 0);
            }
        }

        MarginPosition.State storage position =
            self.marginPositions.get(params.sender, params.marginForOne, params.salt);

        (uint256 releaseAmount, uint256 repayAmount) = position.update(
            params.marginForOne,
            borrowCumulativeLast,
            depositCumulativeLast,
            params.amount,
            marginWithoutFee,
            params.borrowAmount,
            params.changeAmount
        );

        if (position.marginLevel(_pairReserves, borrowCumulativeLast, depositCumulativeLast) < params.minMarginLevel) {
            MarginLevelError.selector.revertWith();
        }

        if (releaseAmount > 0) {
            // transfer from pair reserves to user
            if (params.marginForOne) {
                amount1Delta = releaseAmount.toInt128();
                lendDelta = toBalanceDelta(0, amount1Delta);
            } else {
                amount0Delta = releaseAmount.toInt128();
                lendDelta = toBalanceDelta(amount0Delta, 0);
            }
            assetAmount = releaseAmount;
        }
        if (repayAmount > 0) {
            // --- Repay Debt ---
            if (params.marginForOne) {
                amount0Delta = -repayAmount.toInt128();
                mirrorDelta = toBalanceDelta(repayAmount.toInt128(), 0);
            } else {
                amount1Delta = -repayAmount.toInt128();
                mirrorDelta = toBalanceDelta(0, repayAmount.toInt128());
            }
        }
        console.log("amount0Delta", amount0Delta);
        console.log("amount1Delta", amount1Delta);
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
    /// @return profitAmount The profit from closing the position.
    function close(State storage self, CloseParams memory params)
        internal
        returns (BalanceDelta closeDelta, uint256 profitAmount)
    {
        uint256 releaseAmount;
        uint256 repayAmount;
        uint256 lossAmount;
        MarginPosition.State storage position = self.marginPositions.get(params.sender, params.positionKey, params.salt);
        (releaseAmount, repayAmount, profitAmount, lossAmount) = position.close(
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

    struct InterestUpdateParams {
        uint256 mirrorReserve;
        uint256 rateCumulativeLast;
        uint256 borrowCumulativeBefore;
        uint256 interestReserve;
        uint256 pairReserve;
        uint256 lendReserve;
        uint256 depositCumulativeLast;
        uint24 protocolFee;
    }

    struct InterestUpdateResult {
        uint256 newMirrorReserve;
        uint256 newPairReserve;
        uint256 newLendReserve;
        uint256 newInterestReserve;
        uint256 newDepositCumulativeLast;
        uint256 pairInterest;
        bool changed;
    }

    function _updateInterestForOne(InterestUpdateParams memory params)
        internal
        pure
        returns (InterestUpdateResult memory result)
    {
        result.newMirrorReserve = params.mirrorReserve;
        result.newPairReserve = params.pairReserve;
        result.newLendReserve = params.lendReserve;
        result.newInterestReserve = params.interestReserve;
        result.newDepositCumulativeLast = params.depositCumulativeLast;

        if (params.mirrorReserve > 0 && params.rateCumulativeLast > params.borrowCumulativeBefore) {
            uint256 allInterest = Math.mulDiv(
                params.mirrorReserve * FixedPoint96.Q96, params.rateCumulativeLast, params.borrowCumulativeBefore
            ) - params.mirrorReserve * FixedPoint96.Q96 + params.interestReserve;

            (uint256 protocolInterest,) =
                ProtocolFeeLibrary.splitFee(params.protocolFee, FeeType.INTERESTS, allInterest);

            if (protocolInterest == 0 || protocolInterest > FixedPoint96.Q96) {
                uint256 allInterestNoQ96 = allInterest / FixedPoint96.Q96;
                allInterestNoQ96 -= protocolInterest / FixedPoint96.Q96;

                result.pairInterest =
                    Math.mulDiv(allInterestNoQ96, params.pairReserve, params.pairReserve + params.lendReserve);

                if (allInterestNoQ96 > result.pairInterest) {
                    uint256 lendingInterest = allInterestNoQ96 - result.pairInterest;
                    result.newDepositCumulativeLast = Math.mulDiv(
                        params.depositCumulativeLast, params.lendReserve + lendingInterest, params.lendReserve
                    );
                    result.newLendReserve += lendingInterest;
                }

                result.newMirrorReserve += allInterestNoQ96;
                result.newPairReserve += result.pairInterest;
                result.changed = true;
                result.newInterestReserve = 0;
            } else {
                result.newInterestReserve = allInterest;
            }
        }
    }

    /// @notice Updates the interest rates for the pool.
    /// @param self The pool state.
    /// @param marginState The current rate state.
    /// @return pairInterest0 The interest earned by the pair for token0.
    /// @return pairInterest1 The interest earned by the pair for token1.
    function updateInterests(State storage self, MarginState marginState)
        internal
        returns (uint256 pairInterest0, uint256 pairInterest1)
    {
        Slot0 _slot0 = self.slot0;
        uint256 timeElapsedMicrosecond = _slot0.lastUpdated().getTimeElapsedMicrosecond();
        if (timeElapsedMicrosecond == 0) return (0, 0);

        Reserves _realReserves = self.realReserves;
        Reserves _mirrorReserves = self.mirrorReserves;
        Reserves _interestReserves = self.interestReserves;
        Reserves _pairReserves = self.pairReserves;
        Reserves _lendReserves = self.lendReserves;

        uint256 borrow0CumulativeBefore = self.borrow0CumulativeLast;
        uint256 borrow1CumulativeBefore = self.borrow1CumulativeLast;

        (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast) = InterestMath.getBorrowRateCumulativeLast(
            timeElapsedMicrosecond,
            borrow0CumulativeBefore,
            borrow1CumulativeBefore,
            marginState,
            _realReserves,
            _mirrorReserves
        );

        (uint256 pairReserve0, uint256 pairReserve1) = _pairReserves.reserves();
        (uint256 lendReserve0, uint256 lendReserve1) = _lendReserves.reserves();
        (uint256 mirrorReserve0, uint256 mirrorReserve1) = _mirrorReserves.reserves();
        (uint256 interestReserve0, uint256 interestReserve1) = _interestReserves.reserves();

        InterestUpdateResult memory result0 = _updateInterestForOne(
            InterestUpdateParams({
                mirrorReserve: mirrorReserve0,
                rateCumulativeLast: rate0CumulativeLast,
                borrowCumulativeBefore: borrow0CumulativeBefore,
                interestReserve: interestReserve0,
                pairReserve: pairReserve0,
                lendReserve: lendReserve0,
                depositCumulativeLast: self.deposit0CumulativeLast,
                protocolFee: _slot0.protocolFee()
            })
        );

        if (result0.changed) {
            mirrorReserve0 = result0.newMirrorReserve;
            pairReserve0 = result0.newPairReserve;
            lendReserve0 = result0.newLendReserve;
            interestReserve0 = result0.newInterestReserve;
            self.deposit0CumulativeLast = result0.newDepositCumulativeLast;
            pairInterest0 = result0.pairInterest;
            self.borrow0CumulativeLast = rate0CumulativeLast;
        }

        InterestUpdateResult memory result1 = _updateInterestForOne(
            InterestUpdateParams({
                mirrorReserve: mirrorReserve1,
                rateCumulativeLast: rate1CumulativeLast,
                borrowCumulativeBefore: borrow1CumulativeBefore,
                interestReserve: interestReserve1,
                pairReserve: pairReserve1,
                lendReserve: lendReserve1,
                depositCumulativeLast: self.deposit1CumulativeLast,
                protocolFee: _slot0.protocolFee()
            })
        );

        if (result1.changed) {
            mirrorReserve1 = result1.newMirrorReserve;
            pairReserve1 = result1.newPairReserve;
            lendReserve1 = result1.newLendReserve;
            interestReserve1 = result1.newInterestReserve;
            self.deposit1CumulativeLast = result1.newDepositCumulativeLast;
            pairInterest1 = result1.pairInterest;
            self.borrow1CumulativeLast = rate1CumulativeLast;
        }

        if (result0.changed || result1.changed) {
            self.mirrorReserves = toReserves(mirrorReserve0.toUint128(), mirrorReserve1.toUint128());
            self.pairReserves = toReserves(pairReserve0.toUint128(), pairReserve1.toUint128());
            self.lendReserves = toReserves(lendReserve0.toUint128(), lendReserve1.toUint128());
            Reserves _truncatedReserves = self.truncatedReserves;
            self.truncatedReserves = PriceMath.transferReserves(
                _truncatedReserves,
                _pairReserves,
                _slot0.lastUpdated().getTimeElapsed(),
                marginState.maxPriceMovePerSecond()
            );
        } else {
            self.truncatedReserves = _pairReserves;
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
                console.log("REAL");
                _realReserves = _realReserves.applyDelta(delta);
            } else if (_type == ReservesType.MIRROR) {
                console.log("MIRROR");
                _mirrorReserves = _mirrorReserves.applyDelta(delta);
            } else if (_type == ReservesType.PAIR) {
                console.log("PAIR");
                _pairReserves = _pairReserves.applyDelta(delta);
            } else if (_type == ReservesType.LEND) {
                console.log("LEND");
                _lendReserves = _lendReserves.applyDelta(delta);
            }
        }
        self.realReserves = _realReserves;
        self.mirrorReserves = _mirrorReserves;
        self.pairReserves = _pairReserves;
        self.lendReserves = _lendReserves;
    }
}
