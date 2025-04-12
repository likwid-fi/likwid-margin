// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";

import {IPairMarginManager} from "./IPairMarginManager.sol";
import {IMarginPositionManager} from "./IMarginPositionManager.sol";
import {MarginPosition, MarginPositionVo} from "../types/MarginPosition.sol";
import {PoolStatus} from "../types/PoolStatus.sol";
import {MarginParams, MarginParamsVo} from "../types/MarginParams.sol";
import {LiquidateStatus} from "../types/LiquidateStatus.sol";

interface IMarginChecker {
    /// @notice Get the liquidation margin level
    /// @return liquidationMarginLevel The liquidation margin level
    function liquidationMarginLevel() external view returns (uint24);

    /// @notice Get the min margin level
    /// @return minMarginLevel The min margin level
    function minMarginLevel() external view returns (uint24);

    /// @notice Get the min borrow level
    /// @return minMarginLevel The min margin level
    function minBorrowLevel() external view returns (uint24);

    /// @notice Get the profit millionth of the caller and the protocol
    /// @return callerProfitMillion The profit of the caller in millions
    /// @return protocolProfitMillion The profit of the protocol in millions
    function getProfitMillions() external view returns (uint24 callerProfitMillion, uint24 protocolProfitMillion);

    /// @notice Get the leverage thousandths
    /// @return leverageThousandths The leverage thousandths
    function getThousandthsByLeverage() external view returns (uint24[] memory leverageThousandths);

    /// @notice Check the validity of the signature
    /// @param sender The address of the sender
    /// @param positionId The id of the position
    /// @return valid The validity of the signature
    function checkValidity(address sender, uint256 positionId) external view returns (bool valid);

    function estimatePNL(
        IPairMarginManager poolManager,
        PoolStatus memory _status,
        MarginPosition memory _position,
        uint256 closeMillionth
    ) external view returns (int256 pnlAmount);

    /// @notice Return the PNL amount of the position with the given ID and repayment ratio
    /// @param positionManager The address of manager
    /// @param positionId The ID of the position to retrieve
    /// @param closeMillionth   The repayment ratio is calculated as one millionth
    /// @return pnlAmount The PNL amount of the position
    function estimatePNL(IMarginPositionManager positionManager, uint256 positionId, uint256 closeMillionth)
        external
        view
        returns (int256 pnlAmount);

    function updatePosition(IMarginPositionManager positionManager, MarginPosition memory _position)
        external
        view
        returns (MarginPosition memory);

    function checkMinMarginLevel(MarginParamsVo memory paramsVo, PoolStatus memory _status)
        external
        view
        returns (bool valid);

    /// @notice Get the marginTotal amount and borrow amount for the given pool, leverage, and marginAmount
    /// @param poolManager The manager of the pool
    /// @param poolId The ID of the pool
    /// @param marginForOne If true, currency1 is marginToken, otherwise currency2 is marginToken
    /// @param leverage The leverage ratio
    /// @param marginAmount The amount of margin
    /// @return marginWithoutFee The marginTotal amount without fee
    /// @return borrowAmount The borrow amount
    function getMarginTotal(
        address poolManager,
        PoolId poolId,
        bool marginForOne,
        uint24 leverage,
        uint256 marginAmount
    ) external view returns (uint256 marginWithoutFee, uint256 borrowAmount);

    /// @notice Get the maximum marginAmount for the given pool, leverage
    /// @param poolManager The manager of the pool
    /// @param poolId The ID of the pool
    /// @param marginForOne If true, currency1 is marginToken, otherwise currency2 is marginToken
    /// @param leverage The leverage ratio
    /// @return marginMax The maximum margin amount
    /// @return borrowAmount The borrow amount
    function getMarginMax(address poolManager, PoolId poolId, bool marginForOne, uint24 leverage)
        external
        view
        returns (uint256 marginMax, uint256 borrowAmount);

    /// @notice Get the maximum decrease amount of the position
    /// @param poolManager The manager of the pool
    /// @param _status The status of the margin pool
    /// @param _position The position to check
    /// @return maxAmount The maximum decrease amount
    function getMaxDecrease(address poolManager, PoolStatus memory _status, MarginPosition memory _position)
        external
        view
        returns (uint256 maxAmount);

    /// @notice Get the reserve amount of the pool
    /// @param poolManager The manager of the pool
    /// @param poolId  The pool id
    /// @param marginForOne  If it is margin for one
    /// @return reserveBorrow The reserve amount of the borrow token
    /// @return reserveMargin The reserve amount of the margin token
    function getReserves(address poolManager, PoolId poolId, bool marginForOne)
        external
        view
        returns (uint256 reserveBorrow, uint256 reserveMargin);

    /// @notice Check if the position is liquidated
    /// @param manager The position manager address
    /// @param positionId The position id
    /// @return liquidated  If the position is liquidated
    /// @return borrowAmount  The borrow amount of the position
    function checkLiquidate(address manager, uint256 positionId)
        external
        view
        returns (bool liquidated, uint256 borrowAmount);

    /// @notice Check if the position is liquidated
    /// @param poolManager The manager of the pool
    /// @param _status The status of the margin pool
    /// @param _position The position to check
    /// @return liquidated  If the position is liquidated
    /// @return borrowAmount  The borrow amount of the position
    function checkLiquidate(IPairMarginManager poolManager, PoolStatus memory _status, MarginPosition memory _position)
        external
        view
        returns (bool liquidated, uint256 borrowAmount);

    /// @notice Check if the position is liquidated
    /// @param manager The position manager address
    /// @param positionIds The position ids
    /// @return liquidatedList The liquidated list
    /// @return borrowAmountList  The borrow amount list
    function checkLiquidate(address manager, uint256[] calldata positionIds)
        external
        view
        returns (bool[] memory liquidatedList, uint256[] memory borrowAmountList);
}
