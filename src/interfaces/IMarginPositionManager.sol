// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "../types/PoolId.sol";
import {PoolKey} from "../types/PoolKey.sol";

interface IMarginPositionManager {
    error InvalidLevel();

    event MarginLevelChanged(bytes32 oldLevel, bytes32 newLevel);
    event MarginFeeChanged(uint24 oldFee, uint24 newFee);

    error InsufficientBorrowReceived();

    error InsufficientCloseReceived();

    error InsufficientReceived();

    error PositionNotLiquidated();

    error MirrorTooMuch();

    error BorrowTooMuch();

    error ReservesNotEnough();

    event Margin(
        PoolId indexed poolId,
        address indexed owner,
        uint256 tokenId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount,
        bool marginForOne
    );
    event Repay(
        PoolId indexed poolId,
        address indexed sender,
        uint256 tokenId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount,
        uint256 repayAmount
    );
    event Close(
        PoolId indexed poolId,
        address indexed sender,
        uint256 tokenId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount,
        uint256 profitAmount
    );
    event Modify(
        PoolId indexed poolId,
        address indexed sender,
        uint256 tokenId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount,
        int256 changeAmount
    );
    event LiquidateBurn(
        PoolId indexed poolId,
        address indexed sender,
        uint256 tokenId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount,
        uint256 truncatedReserves,
        uint256 pairReserves,
        uint256 profitAmount
    );
    event LiquidateCall(
        PoolId indexed poolId,
        address indexed sender,
        uint256 tokenId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount,
        uint256 truncatedReserves,
        uint256 pairReserves,
        uint256 repayAmount
    );

    struct CreateParams {
        /// @notice true: currency1 is marginToken, false: currency0 is marginToken
        bool marginForOne;
        /// @notice Leverage factor of the margin position.
        uint24 leverage;
        /// @notice The amount of margin
        uint256 marginAmount;
        /// @notice The borrow amount of the margin position.When the parameter is passed in, it is 0.
        uint256 borrowAmount;
        /// @notice The maximum borrow amount of the margin position.
        uint256 borrowAmountMax;
        /// @notice The address of recipient
        address recipient;
        /// @notice Deadline for the transaction
        uint256 deadline;
    }

    /// @notice Create/Add a position
    /// @param key The key of pool
    /// @param params The parameters of the margin position
    /// @return tokenId The id of position
    /// @return borrowAmount The borrow amount
    function addMargin(PoolKey memory key, IMarginPositionManager.CreateParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint256 borrowAmount);

    struct MarginParams {
        uint256 tokenId;
        /// @notice Leverage factor of the margin position.
        uint24 leverage;
        /// @notice The amount of margin
        uint256 marginAmount;
        /// @notice The borrow amount of the margin position.When the parameter is passed in, it is 0.
        uint256 borrowAmount;
        /// @notice The maximum borrow amount of the margin position.
        uint256 borrowAmountMax;
        /// @notice Deadline for the transaction
        uint256 deadline;
    }

    /// @notice Margin a position
    /// @param params The parameters of the margin position
    /// @return borrowAmount The borrow amount
    function margin(IMarginPositionManager.MarginParams memory params)
        external
        payable
        returns (uint256 borrowAmount);

    /// @notice Release the margin position by repaying the debt
    /// @param tokenId The id of position
    /// @param repayAmount The amount to repay
    /// @param deadline Deadline for the transaction
    function repay(uint256 tokenId, uint256 repayAmount, uint256 deadline) external payable;

    /// @notice Close the margin position
    /// @param tokenId The id of position
    /// @param closeMillionth The repayment ratio is calculated as one millionth
    /// @param profitAmountMin The minimum profit amount to be received after closing the position
    /// @param deadline Deadline for the transaction
    function close(uint256 tokenId, uint24 closeMillionth, uint256 profitAmountMin, uint256 deadline) external;

    /// @notice Liquidates a position by burning the position token.
    /// @param tokenId The ID of the position to liquidate.
    /// @return profit The profit from the liquidation.
    function liquidateBurn(uint256 tokenId) external returns (uint256 profit);

    /// @notice Liquidates a position by making a call.
    /// @param tokenId The ID of the position to liquidate.
    /// @return profit The profit from the liquidation.
    /// @return repayAmount The amount repaid.
    function liquidateCall(uint256 tokenId) external payable returns (uint256 profit, uint256 repayAmount);

    /// @notice Modify the margin position
    /// @param tokenId The id of position
    /// @param changeAmount The amount to modify
    function modify(uint256 tokenId, int128 changeAmount) external payable;

    function defaultMarginFee() external view returns (uint24 defaultMarginFee);
}
