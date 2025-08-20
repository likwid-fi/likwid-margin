// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Slot0} from "../types/Slot0.sol";
import {BalanceDelta, toBalanceDelta} from "../types/BalanceDelta.sol";
import {Reserves, toReserves} from "../types/Reserves.sol";
import {Math} from "./Math.sol";
import {CustomRevert} from "./CustomRevert.sol";
import {PairPosition} from "./PairPosition.sol";
import {SafeCast} from "./SafeCast.sol";

/// @notice a library with all actions that can be performed on a pool
library Pool {
    using CustomRevert for bytes4;
    using SafeCast for *;
    using Pool for State;
    using PairPosition for PairPosition.State;
    using PairPosition for mapping(bytes32 => PairPosition.State);
    /// @notice Thrown when trying to initialize an already initialized pool

    error PoolAlreadyInitialized();

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();

    error InsufficientLiquidity();

    error NotEnoughReserves();

    struct State {
        Slot0 slot0;
        /// @notice The cumulative borrow rate of the first currency in the pool.
        uint256 rate0CumulativeLast;
        /// @notice The cumulative borrow rate of the second currency in the pool.
        uint256 rate1CumulativeLast;
        mapping(bytes32 positionKey => PairPosition.State) positions;
        Reserves realReserves;
        Reserves mirrorReserves;
        Reserves swapReserves;
        Reserves lendingReserves;
    }

    /// @notice Reverts if the given pool has not been initialized
    function checkPoolInitialized(State storage self) internal view {
        if (self.slot0.lastUpdated() == 0) PoolNotInitialized.selector.revertWith();
    }

    function initialize(State storage self, uint24 lpFee) internal {
        if (self.slot0.lastUpdated() != 0) PoolAlreadyInitialized.selector.revertWith();

        // the initial protocolFee is 0 so doesn't need to be set
        self.slot0 = Slot0.wrap(bytes32(0)).setLastUpdated(uint32(block.timestamp)).setLpFee(lpFee);
    }

    function setProtocolFee(State storage self, uint24 protocolFee) internal {
        self.checkPoolInitialized();
        self.slot0 = self.slot0.setProtocolFee(protocolFee);
    }

    function setMarginFee(State storage self, uint24 marginFee) internal {
        self.checkPoolInitialized();
        self.slot0 = self.slot0.setMarginFee(marginFee);
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

    function modifyLiquidity(State storage self, ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        if (params.liquidityDelta == 0 && params.amount0 == 0 && params.amount1 == 0) {
            return BalanceDelta.wrap(0);
        }

        (uint128 _reserve0, uint128 _reserve1) = self.swapReserves.reserves();
        (uint128 _realReserve0, uint128 _realReserve1) = self.realReserves.reserves();
        uint128 totalSupply = self.slot0.totalSupply();
        PairPosition.State storage position = self.positions.get(params.owner, params.salt);

        int128 finalLiquidityDelta;

        if (params.liquidityDelta < 0) {
            // --- Remove Liquidity ---
            uint256 liquidityToRemove = uint256(-int256(params.liquidityDelta));
            if (liquidityToRemove > totalSupply) InsufficientLiquidity.selector.revertWith();

            uint256 amount0Out = Math.mulDiv(liquidityToRemove, _reserve0, totalSupply);
            uint256 amount1Out = Math.mulDiv(liquidityToRemove, _reserve1, totalSupply);

            if (amount0Out > _realReserve0 || amount1Out > _realReserve1) {
                NotEnoughReserves.selector.revertWith();
            }

            delta = toBalanceDelta(amount0Out.toInt128(), amount1Out.toInt128());

            self.slot0 = self.slot0.setTotalSupply(totalSupply - liquidityToRemove.toUint128());
            self.swapReserves = toReserves(_reserve0 - amount0Out.toUint128(), _reserve1 - amount1Out.toUint128());
            self.realReserves =
                toReserves(_realReserve0 - amount0Out.toUint128(), _realReserve1 - amount1Out.toUint128());
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

            self.slot0 = self.slot0.setTotalSupply(totalSupply + liquidityAdded.toUint128());
            self.swapReserves = toReserves(_reserve0 + amount0In.toUint128(), _reserve1 + amount1In.toUint128());
            self.realReserves = toReserves(_realReserve0 + amount0In.toUint128(), _realReserve1 + amount1In.toUint128());
            finalLiquidityDelta = liquidityAdded.toInt128();
        }

        PairPosition.update(position, finalLiquidityDelta, delta);
    }
}
