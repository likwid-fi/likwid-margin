// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";
import {MarginPosition, MarginPositionVo, BurnParams} from "../types/MarginPosition.sol";

interface IMarginChecker {
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
    /// @param signature The signature of the position
    /// @return valid The validity of the signature
    function checkValidity(address sender, uint256 positionId, bytes calldata signature)
        external
        view
        returns (bool valid);

    /// @notice Get the marginTotal amount and borrow amount for the given pool, leverage, and marginAmount
    /// @param hook The address of the hook
    /// @param poolId The ID of the pool
    /// @param marginForOne If true, currency1 is marginToken, otherwise currency2 is marginToken
    /// @param leverage The leverage ratio
    /// @param marginAmount The amount of margin
    /// @return marginWithoutFee The marginTotal amount without fee
    /// @return borrowAmount The borrow amount
    function getMarginTotal(address hook, PoolId poolId, bool marginForOne, uint24 leverage, uint256 marginAmount)
        external
        view
        returns (uint256 marginWithoutFee, uint256 borrowAmount);

    /// @notice Get the maximum marginAmount for the given pool, leverage
    /// @param hook The address of the hook
    /// @param poolId The ID of the pool
    /// @param marginForOne If true, currency1 is marginToken, otherwise currency2 is marginToken
    /// @param leverage The leverage ratio
    /// @return marginMax The maximum margin amount
    /// @return borrowAmount The borrow amount
    function getMarginMax(address hook, PoolId poolId, bool marginForOne, uint24 leverage)
        external
        view
        returns (uint256 marginMax, uint256 borrowAmount);

    /// @notice Get the maximum decrease amount of the position
    /// @param _position The position to check
    /// @param hook The hook address
    /// @return maxAmount The maximum decrease amount
    function getMaxDecrease(MarginPosition memory _position, address hook) external view returns (uint256 maxAmount);

    /// @notice Get the oracle reserve amount of the pool
    /// @param poolId  The pool id
    /// @param hook The hook address
    /// @return reserves The oracle reserve amount of the pool
    function getOracleReserves(PoolId poolId, address hook) external view returns (uint224 reserves);

    /// @notice Get the reserve amount of the pool
    /// @param poolId  The pool id
    /// @param marginForOne  If it is margin for one
    /// @param hook The hook address
    /// @return reserveBorrow The reserve amount of the borrow token
    /// @return reserveMargin The reserve amount of the margin token
    function getReserves(PoolId poolId, bool marginForOne, address hook)
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
    /// @param _position The position to check
    /// @param hook The hook address
    /// @return liquidated  If the position is liquidated
    /// @return borrowAmount  The borrow amount of the position
    function checkLiquidate(MarginPosition memory _position, address hook)
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

    /// @notice Check if the position is liquidated
    /// @param poolId The pool id
    /// @param marginForOne If the margin is for one
    /// @param hook The hook address
    /// @param inPositions The input positions
    /// @return liquidatedList  The liquidated list
    /// @return borrowAmountList  The borrow amount list
    function checkLiquidate(PoolId poolId, bool marginForOne, address hook, MarginPosition[] memory inPositions)
        external
        view
        returns (bool[] memory liquidatedList, uint256[] memory borrowAmountList);
}
