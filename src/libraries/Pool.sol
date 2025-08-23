// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";

import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "../types/BalanceDelta.sol";
import {FeeType} from "../types/FeeType.sol";
import {Reserves, toReserves} from "../types/Reserves.sol";
import {Slot0} from "../types/Slot0.sol";
import {CustomRevert} from "./CustomRevert.sol";
import {FeeLibrary} from "./FeeLibrary.sol";
import {FixedPoint96} from "./FixedPoint96.sol";
import {Math} from "./Math.sol";
import {PairPosition} from "./PairPosition.sol";
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

    /// @notice Thrown when trying to initialize an already initialized pool
    error PoolAlreadyInitialized();

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();

    /// @notice Thrown when trying to remove more liquidity than available in the pool
    error InsufficientLiquidity();

    uint256 constant MAX_PRICE_MOVE_PER_SECOND = 3000; // 0.3%/second

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
        Reserves lendingReserves;
        /// @notice The positions in the pool, mapped by a hash of the owner's address and a salt.
        mapping(bytes32 positionKey => PairPosition.State) positions;
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
        if (self.slot0.lastUpdated() != 0) PoolAlreadyInitialized.selector.revertWith();

        // the initial protocolFee is 0 so doesn't need to be set
        self.slot0 = Slot0.wrap(bytes32(0)).setLastUpdated(uint32(block.timestamp)).setLpFee(lpFee);
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
        self.updateReserves(delta, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA);

        self.positions.get(params.owner, params.salt).update(finalLiquidityDelta, delta);
    }

    /// @notice Swaps tokens in the pool
    /// @param self The pool state
    /// @param zeroForOne Whether to swap token0 for token1
    /// @param amountSpecified The amount to swap, negative for exact input, positive for exact output
    /// @return swapDelta The change in balances
    /// @return amountToProtocol The amount of fees to be sent to the protocol
    /// @return swapFee The fee for the swap
    function swap(State storage self, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta swapDelta, uint256 amountToProtocol, uint24 swapFee)
    {
        Slot0 _slot0 = self.slot0;

        bool exactIn = amountSpecified < 0;

        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;

        if (exactIn) {
            amountIn = uint256(-amountSpecified);
            (amountOut, swapFee, feeAmount) = self.getAmountOut(zeroForOne, amountIn);
        } else {
            amountOut = uint256(amountSpecified);
            (amountIn, swapFee, feeAmount) = self.getAmountIn(zeroForOne, amountOut);
        }

        (uint256 protocolFeeAmount,) = ProtocolFeeLibrary.splitFee(_slot0.protocolFee(), FeeType.SWAP, feeAmount);
        amountToProtocol = protocolFeeAmount;

        int128 amount0Delta;
        int128 amount1Delta;

        if (zeroForOne) {
            amount0Delta = -amountIn.toInt128();
            amount1Delta = amountOut.toInt128();
        } else {
            amount0Delta = amountOut.toInt128();
            amount1Delta = -amountIn.toInt128();
        }
        console.log("amount0Delta", amount0Delta);
        console.log("amount1Delta", amount1Delta);
        console.log("amountIn", amountIn);
        console.log("amountOut", amountOut);
        swapDelta = toBalanceDelta(amount0Delta, amount1Delta);

        self.updateReserves(swapDelta, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA);
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
        if (self.slot0.lastUpdated() == 0) PoolNotInitialized.selector.revertWith();
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

    function updateReserves(
        State storage self,
        BalanceDelta pairDelta,
        BalanceDelta lendingDelta,
        BalanceDelta marginDelta
    ) internal {
        if (pairDelta != BalanceDeltaLibrary.ZERO_DELTA) {
            self.realReserves = self.realReserves.applyDelta(pairDelta);
            self.pairReserves = self.pairReserves.applyDelta(pairDelta);
        } else if (lendingDelta != BalanceDeltaLibrary.ZERO_DELTA) {
            self.realReserves = self.lendingReserves.applyDelta(lendingDelta);
            self.mirrorReserves = self.lendingReserves.applyDelta(lendingDelta);
            self.lendingReserves = self.lendingReserves.applyDelta(lendingDelta);
        } else if (marginDelta != BalanceDeltaLibrary.ZERO_DELTA) {
            BalanceDelta realDelta;
            (int128 marginAmount, int128 mirrorAmount) = (marginDelta.amount0(), marginDelta.amount1());
            if (mirrorAmount >= 0) {
                // margin:
                // realReserves add marginAmount
                // lendReserves add marginAmount,mirrorAmount
                // mirrorReserves add marginAmount,mirrorAmount
                // pairReserves reduce mirrorAmount
                if (marginAmount >= 0) {
                    // margin token is token0
                    realDelta = toBalanceDelta(-marginAmount, 0);
                    pairDelta = toBalanceDelta(0, mirrorAmount);
                    lendingDelta = toBalanceDelta(-marginAmount, -mirrorAmount);
                } else {
                    // margin token is token1
                    realDelta = toBalanceDelta(0, marginAmount);
                    pairDelta = toBalanceDelta(mirrorAmount, 0);
                    lendingDelta = toBalanceDelta(-mirrorAmount, marginAmount);
                }
            } else {
                // release:
                // realReserves reduce marginAmount
                // lendReserves reduce marginAmount,pairReserves
                // mirrorReserves reduce marginAmount,pairReserves
                // pairReserves add mirrorAmount
                if (marginAmount >= 0) {
                    // margin token is token0
                    realDelta = toBalanceDelta(marginAmount, 0);
                    pairDelta = toBalanceDelta(0, mirrorAmount);
                    lendingDelta = toBalanceDelta(marginAmount, -mirrorAmount);
                } else {
                    // margin token is token1
                    realDelta = toBalanceDelta(0, -marginAmount);
                    pairDelta = toBalanceDelta(mirrorAmount, 0);
                    lendingDelta = toBalanceDelta(-mirrorAmount, -marginAmount);
                }
            }

            self.realReserves = self.realReserves.applyDelta(realDelta);
            self.mirrorReserves = self.mirrorReserves.applyDelta(lendingDelta);
            self.pairReserves = self.lendingReserves.applyDelta(pairDelta);
            self.lendingReserves = self.lendingReserves.applyDelta(lendingDelta);
        }
        self.transformTruncated();
    }
}
