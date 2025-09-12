// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {MarginState} from "../../src/types/MarginState.sol";
import {Reserves} from "../../src/types/Reserves.sol";
import {PoolState} from "../../src/types/PoolState.sol";
import {PoolId} from "../../src/types/PoolId.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {StateLibrary} from "../../src/libraries/StateLibrary.sol";
import {SwapMath} from "../../src/libraries/SwapMath.sol";

contract LikwidHelper {
    struct PoolStateInfo {
        uint32 lastUpdated;
        uint24 lpFee;
        uint24 marginFee;
        uint24 protocolFee;
        uint128 realReserve0;
        uint128 realReserve1;
        uint128 mirrorReserve0;
        uint128 mirrorReserve1;
        uint128 pairReserve0;
        uint128 pairReserve1;
        uint128 truncatedReserve0;
        uint128 truncatedReserve1;
        uint128 lendReserve0;
        uint128 lendReserve1;
        uint128 interestReserve0;
        uint128 interestReserve1;
    }

    function getPoolStateInfo(IVault vault, PoolId poolId) internal view returns (PoolStateInfo memory stateInfo) {
        PoolState memory state = StateLibrary.getCurrentState(vault, poolId);
        stateInfo.lastUpdated = state.lastUpdated;
        stateInfo.lpFee = state.lpFee;
        stateInfo.marginFee = state.marginFee;
        stateInfo.protocolFee = state.protocolFee;
        (uint128 realReserve0, uint128 realReserve1) = state.realReserves.reserves();
        stateInfo.realReserve0 = realReserve0;
        stateInfo.realReserve1 = realReserve1;
        (uint128 mirrorReserve0, uint128 mirrorReserve1) = state.mirrorReserves.reserves();
        stateInfo.mirrorReserve0 = mirrorReserve0;
        stateInfo.mirrorReserve1 = mirrorReserve1;
        (uint128 pairReserve0, uint128 pairReserve1) = state.pairReserves.reserves();
        stateInfo.pairReserve0 = pairReserve0;
        stateInfo.pairReserve1 = pairReserve1;
        (uint128 truncatedReserve0, uint128 truncatedReserve1) = state.truncatedReserves.reserves();
        stateInfo.truncatedReserve0 = truncatedReserve0;
        stateInfo.truncatedReserve1 = truncatedReserve1;
        (uint128 lendReserve0, uint128 lendReserve1) = state.lendReserves.reserves();
        stateInfo.lendReserve0 = lendReserve0;
        stateInfo.lendReserve1 = lendReserve1;
        (uint128 interestReserve0, uint128 interestReserve1) = state.interestReserves.reserves();
        stateInfo.interestReserve0 = interestReserve0;
        stateInfo.interestReserve1 = interestReserve1;
    }

    function getStageLiquidities(IVault vault, PoolId poolId) external view returns (uint128[][] memory liquidities) {
        liquidities = StateLibrary.getStageLiquidities(vault, poolId);
    }

    function getAmountOut(IVault vault, PoolId poolId, bool zeroForOne, uint256 amountIn, bool dynamicFee)
        external
        view
        returns (uint256 amountOut, uint24 fee, uint256 feeAmount)
    {
        PoolState memory state = StateLibrary.getCurrentState(vault, poolId);
        fee = state.lpFee;
        if (!dynamicFee) {
            (amountOut, feeAmount) = SwapMath.getAmountOut(state.pairReserves, fee, zeroForOne, amountIn);
        } else {
            (amountOut, fee, feeAmount) =
                SwapMath.getAmountOut(state.pairReserves, state.truncatedReserves, fee, zeroForOne, amountIn);
        }
    }

    function getAmountIn(IVault vault, PoolId poolId, bool zeroForOne, uint256 amountOut, bool dynamicFee)
        external
        view
        returns (uint256 amountIn, uint24 fee, uint256 feeAmount)
    {
        PoolState memory state = StateLibrary.getCurrentState(vault, poolId);
        fee = state.lpFee;
        if (!dynamicFee) {
            (amountIn, feeAmount) = SwapMath.getAmountIn(state.pairReserves, fee, zeroForOne, amountOut);
        } else {
            (amountIn, fee, feeAmount) =
                SwapMath.getAmountIn(state.pairReserves, state.truncatedReserves, fee, zeroForOne, amountOut);
        }
    }
}
