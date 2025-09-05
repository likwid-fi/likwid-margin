// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "../types/PoolId.sol";

interface IMarginPositionManager {
    error InvalidMinLevel();

    event MinMarginLevelChanged(uint24 oldLevel, uint24 newLevel);

    event MinBorrowLevelChanged(uint24 oldLevel, uint24 newLevel);

    event LiquidateLevelChanged(uint24 oldLevel, uint24 newLevel);

    error InsufficientBorrowReceived();

    error InsufficientCloseReceived();

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

    /// @notice Modify the margin position
    /// @param tokenId The id of position
    /// @param changeAmount The amount to modify
    function modify(uint256 tokenId, int128 changeAmount) external payable;
}
