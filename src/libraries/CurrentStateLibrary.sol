// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "../types/PoolId.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IMarginBase} from "../interfaces/IMarginBase.sol";
import {Slot0, Slot0Library} from "../types/Slot0.sol";
import {Reserves, ReservesLibrary, toReserves} from "../types/Reserves.sol";
import {PoolState} from "../types/PoolState.sol";
import {TimeLibrary} from "./TimeLibrary.sol";
import {InterestMath} from "./InterestMath.sol";
import {PriceMath} from "./PriceMath.sol";
import {SafeCast} from "./SafeCast.sol";

/// @notice Library for fetching the current state of a pool from the vault
library CurrentStateLibrary {
    using SafeCast for *;
    using Slot0Library for Slot0;
    using ReservesLibrary for Reserves;
    using TimeLibrary for uint32;

    /// @notice The storage slot of the `defaultProtocolFee` in the LikwidVault contract.
    bytes32 public constant DEFAULT_PROTOCOL_FEE_SLOT = bytes32(uint256(6));

    /// @notice The storage slot of the `_pools` mapping in the LikwidVault contract.
    bytes32 public constant POOLS_SLOT = bytes32(uint256(10));

    function getState(IVault vault, PoolId poolId) internal view returns (PoolState memory state) {
        bytes32 poolStateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));

        // 1. Get slot0 and defaultProtocolFee
        Slot0 slot0 = Slot0.wrap(vault.extsload(poolStateSlot));
        state.totalSupply = slot0.totalSupply();
        state.lastUpdated = slot0.lastUpdated();
        state.protocolFee = slot0.protocolFee();
        state.lpFee = slot0.lpFee();
        state.marginFee = slot0.marginFee();

        if (state.protocolFee == 0) {
            uint256 value = uint256(vault.extsload(DEFAULT_PROTOCOL_FEE_SLOT));
            state.protocolFee = uint24(value >> 160);
        }

        // 2. Get all other data in one call
        bytes32 startSlot = bytes32(uint256(poolStateSlot) + 1); // BORROW_0_CUMULATIVE_LAST_OFFSET
        bytes32[] memory data = vault.extsload(startSlot, 10); // read 10 slots

        uint256 borrow0CumulativeBefore = uint256(data[0]);
        uint256 borrow1CumulativeBefore = uint256(data[1]);
        uint256 deposit0CumulativeBefore = uint256(data[2]);
        uint256 deposit1CumulativeBefore = uint256(data[3]);
        state.realReserves = Reserves.wrap(uint256(data[4]));
        state.mirrorReserves = Reserves.wrap(uint256(data[5]));
        state.pairReserves = Reserves.wrap(uint256(data[6]));
        Reserves _truncatedReserves = Reserves.wrap(uint256(data[7]));
        state.lendReserves = Reserves.wrap(uint256(data[8]));
        state.interestReserves = Reserves.wrap(uint256(data[9]));

        // 3. Get marginState
        state.marginState = IMarginBase(address(vault)).marginState();

        // 4. Get timeElapsed
        uint256 timeElapsed = state.lastUpdated.getTimeElapsed();

        (uint256 mirrorReserve0, uint256 mirrorReserve1) = state.mirrorReserves.reserves();
        (uint256 pairReserve0, uint256 pairReserve1) = state.pairReserves.reserves();
        (uint256 lendReserve0, uint256 lendReserve1) = state.lendReserves.reserves();
        (uint256 interestReserve0, uint256 interestReserve1) = state.interestReserves.reserves();

        (uint256 borrow0CumulativeLast, uint256 borrow1CumulativeLast) = InterestMath.getBorrowRateCumulativeLast(
            timeElapsed,
            borrow0CumulativeBefore,
            borrow1CumulativeBefore,
            state.marginState,
            state.realReserves,
            state.mirrorReserves
        );

        InterestMath.InterestUpdateParams memory params0 = InterestMath.InterestUpdateParams({
            mirrorReserve: mirrorReserve0,
            borrowCumulativeLast: borrow0CumulativeLast,
            borrowCumulativeBefore: borrow0CumulativeBefore,
            interestReserve: interestReserve0,
            pairReserve: pairReserve0,
            lendReserve: lendReserve0,
            depositCumulativeLast: deposit0CumulativeBefore,
            protocolFee: state.protocolFee
        });

        InterestMath.InterestUpdateResult memory result0 = InterestMath.updateInterestForOne(params0);
        if (result0.changed) {
            mirrorReserve0 = result0.newMirrorReserve;
            pairReserve0 = result0.newPairReserve;
            lendReserve0 = result0.newLendReserve;
        }
        interestReserve0 = result0.newInterestReserve;
        state.deposit0CumulativeLast = result0.newDepositCumulativeLast;
        state.borrow0CumulativeLast = borrow0CumulativeLast;

        InterestMath.InterestUpdateParams memory params1 = InterestMath.InterestUpdateParams({
            mirrorReserve: mirrorReserve1,
            borrowCumulativeLast: borrow1CumulativeLast,
            borrowCumulativeBefore: borrow1CumulativeBefore,
            interestReserve: interestReserve1,
            pairReserve: pairReserve1,
            lendReserve: lendReserve1,
            depositCumulativeLast: deposit1CumulativeBefore,
            protocolFee: state.protocolFee
        });

        InterestMath.InterestUpdateResult memory result1 = InterestMath.updateInterestForOne(params1);
        if (result1.changed) {
            mirrorReserve1 = result1.newMirrorReserve;
            pairReserve1 = result1.newPairReserve;
            lendReserve1 = result1.newLendReserve;
        }
        interestReserve1 = result1.newInterestReserve;
        state.borrow1CumulativeLast = borrow1CumulativeLast;
        state.deposit1CumulativeLast = result1.newDepositCumulativeLast;

        if (result0.changed || result1.changed) {
            state.mirrorReserves = toReserves(mirrorReserve0.toUint128(), mirrorReserve1.toUint128());
            state.pairReserves = toReserves(pairReserve0.toUint128(), pairReserve1.toUint128());
            state.lendReserves = toReserves(lendReserve0.toUint128(), lendReserve1.toUint128());
        }
        state.truncatedReserves = PriceMath.transferReserves(
            _truncatedReserves, state.pairReserves, timeElapsed, state.marginState.maxPriceMovePerSecond()
        );

        state.interestReserves = toReserves(interestReserve0.toUint128(), interestReserve1.toUint128());
        state.lastUpdated = uint32(block.timestamp);
    }
}
