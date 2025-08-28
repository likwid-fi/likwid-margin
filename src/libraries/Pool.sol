// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";

import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "../types/BalanceDelta.sol";
import {FeeType} from "../types/FeeType.sol";
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

/// @notice a library with all actions that can be performed on a pool
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
    function swap(State storage self, SwapParams memory params)
        internal
        returns (BalanceDelta swapDelta, uint256 amountToProtocol, uint24 swapFee)
    {
        Slot0 _slot0 = self.slot0;

        bool exactIn = params.amountSpecified < 0;

        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;

        if (exactIn) {
            amountIn = uint256(-params.amountSpecified);
            (amountOut, swapFee, feeAmount) = self.getAmountOut(params.zeroForOne, amountIn);
        } else {
            amountOut = uint256(params.amountSpecified);
            (amountIn, swapFee, feeAmount) = self.getAmountIn(params.zeroForOne, amountOut);
        }

        (amountToProtocol,) = ProtocolFeeLibrary.splitFee(_slot0.protocolFee(), FeeType.SWAP, feeAmount);

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

    function margin(State storage self, MarginParams memory params)
        internal
        returns (BalanceDelta marginDelta, MarginPosition.State memory position)
    {
        if (params.amount == 0) {
            return (BalanceDelta.wrap(0), position);
        }

        uint256 releaseAmount;
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
                (marginWithoutFee,) = marginFee.deduct(params.marginTotal);
                (borrowAmount,,) = self.getAmountIn(params.marginForOne, params.marginTotal);
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
                lendDelta = toBalanceDelta(0, lendAmount);
                mirrorDelta = toBalanceDelta(-borrowAmount.toInt128(), 0);
            } else {
                amount0Delta = params.amount;
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
            } else {
                pairDelta = mirrorDelta;
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

        (position, releaseAmount) = self.marginPositions.get(
            params.sender, params.marginForOne, params.marginTotal, params.salt
        ).update(borrowCumulativeLast, depositCumulativeLast, params.amount, marginWithoutFee, params.borrowAmount);

        if (releaseAmount > 0) {
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

    /// @notice Calculates the amount of tokens to be received for a given input amount
    /// @param self The pool state
    /// @param zeroForOne Whether to swap token0 for token1
    /// @param amountIn The amount of tokens to swap
    /// @return amountOut The amount of tokens to be received
    /// @return fee The fee for the swap
    /// @return feeAmount The amount of fees to be paid
    function getAmountOut(State storage self, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut, uint24 fee, uint256 feeAmount)
    {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        Reserves _pairReserves = self.pairReserves;
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne
            ? (_pairReserves.reserve0(), _pairReserves.reserve1())
            : (_pairReserves.reserve1(), _pairReserves.reserve0());
        require(reserveIn > 0 && reserveOut > 0, " INSUFFICIENT_LIQUIDITY");
        fee = self.slot0.lpFee();
        uint256 degree = _pairReserves.getPriceDegree(self.truncatedReserves, zeroForOne, amountIn, 0);
        fee = fee.dynamicFee(degree);
        uint256 amountInWithoutFee;
        (amountInWithoutFee, feeAmount) = fee.deduct(amountIn);
        uint256 numerator = amountInWithoutFee * reserveOut;
        uint256 denominator = reserveIn + amountInWithoutFee;
        amountOut = numerator / denominator;
    }

    /// @notice Calculates the amount of tokens to be paid for a given output amount
    /// @param self The pool state
    /// @param zeroForOne Whether to swap token0 for token1
    /// @param amountOut The amount of tokens to receive
    /// @return amountIn The amount of tokens to be paid
    /// @return fee The fee for the swap
    /// @return feeAmount The amount of fees to be paid
    function getAmountIn(State storage self, bool zeroForOne, uint256 amountOut)
        internal
        view
        returns (uint256 amountIn, uint24 fee, uint256 feeAmount)
    {
        require(amountOut > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        Reserves _pairReserves = self.pairReserves;
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne
            ? (_pairReserves.reserve0(), _pairReserves.reserve1())
            : (_pairReserves.reserve1(), _pairReserves.reserve0());
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        require(amountOut < reserveOut, "OUTPUT_AMOUNT_OVERFLOW");
        fee = self.slot0.lpFee();
        uint256 degree = _pairReserves.getPriceDegree(self.truncatedReserves, zeroForOne, 0, amountOut);
        fee = fee.dynamicFee(degree);
        uint256 numerator = reserveIn * amountOut;
        uint256 denominator = (reserveOut - amountOut);
        uint256 amountInWithoutFee = (numerator / denominator) + 1;
        (amountIn, feeAmount) = fee.attach(amountInWithoutFee);
    }

    /// @notice Reverts if the given pool has not been initialized
    function checkPoolInitialized(State storage self) internal view {
        if (self.borrow0CumulativeLast == 0) PoolNotInitialized.selector.revertWith();
    }

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
        // if (marginDelta != BalanceDeltaLibrary.ZERO_DELTA) {
        //     BalanceDelta realDelta;
        //     (int128 marginAmount, int128 mirrorAmount) = (marginDelta.amount0(), marginDelta.amount1());
        //     if (mirrorAmount >= 0) {
        //         // margin:
        //         // realReserves add marginAmount
        //         // lendReserves add marginAmount,mirrorAmount
        //         // mirrorReserves add marginAmount,mirrorAmount
        //         // pairReserves reduce mirrorAmount
        //         if (marginAmount >= 0) {
        //             // margin token is token0
        //             realDelta = toBalanceDelta(-marginAmount, 0);
        //             pairDelta = toBalanceDelta(0, mirrorAmount);
        //             lendDelta = toBalanceDelta(-marginAmount, -mirrorAmount);
        //         } else {
        //             // margin token is token1
        //             realDelta = toBalanceDelta(0, marginAmount);
        //             pairDelta = toBalanceDelta(mirrorAmount, 0);
        //             lendDelta = toBalanceDelta(-mirrorAmount, marginAmount);
        //         }
        //     } else {
        //         // release:
        //         // realReserves reduce marginAmount
        //         // lendReserves reduce marginAmount,pairReserves
        //         // mirrorReserves reduce marginAmount,pairReserves
        //         // pairReserves add mirrorAmount
        //         if (marginAmount >= 0) {
        //             // margin token is token0
        //             realDelta = toBalanceDelta(marginAmount, 0);
        //             pairDelta = toBalanceDelta(0, mirrorAmount);
        //             lendDelta = toBalanceDelta(marginAmount, -mirrorAmount);
        //         } else {
        //             // margin token is token1
        //             realDelta = toBalanceDelta(0, -marginAmount);
        //             pairDelta = toBalanceDelta(mirrorAmount, 0);
        //             lendDelta = toBalanceDelta(-mirrorAmount, -marginAmount);
        //         }
        //     }

        //     self.realReserves = self.realReserves.applyDelta(realDelta);
        //     self.mirrorReserves = self.mirrorReserves.applyDelta(lendDelta);
        //     self.pairReserves = self.lendReserves.applyDelta(pairDelta);
        //     self.lendReserves = self.lendReserves.applyDelta(lendDelta);
        // }
        self.transformTruncated();
    }
}
