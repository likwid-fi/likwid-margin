// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";
import {MarginPosition, MarginPositionVo, BurnParams} from "../types/MarginPosition.sol";

interface IMarginChecker {
    function checkLiquidate(address sender, uint256 positionId, bytes calldata signature)
        external
        view
        returns (bool);

    function getMaxDecrease(MarginPosition memory _position, address hook) external view returns (uint256 maxAmount);

    function getReserves(PoolId poolId, bool marginForOne, address hook)
        external
        view
        returns (uint256 reserveBorrow, uint256 reserveMargin);

    function checkLiquidate(address manager, uint256 positionId) external view returns (bool liquidated);

    function checkLiquidate(MarginPosition memory _position, address hook) external view returns (bool liquidated);

    function checkLiquidate(PoolId poolId, bool marginForOne, address hook, MarginPosition[] memory inPositions)
        external
        view
        returns (bool[] memory liquidatedList, uint256[] memory borrowAmountList);
}
