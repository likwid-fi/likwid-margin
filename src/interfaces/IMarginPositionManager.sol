// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "../types/PoolKey.sol";
import {IBasePositionManager} from "./IBasePositionManager.sol";
import {IMarginCore} from "./IMarginCore.sol";
import {MarginPosition} from "../libraries/MarginPosition.sol";

/// @title IMarginPositionManager
/// @notice Thin NFT wrapper around the margin core: each tokenId maps to a core position
/// owned by this contract with salt = bytes32(tokenId). Risk parameters and liquidation
/// live on the margin core.
interface IMarginPositionManager is IBasePositionManager {
    /// @notice Gets the margin core this manager forwards to
    function marginCore() external view returns (IMarginCore);

    /// @notice Gets the state of a position
    /// @param tokenId The ID of the position token
    /// @return position The state of the position
    function getPositionState(uint256 tokenId) external view returns (MarginPosition.State memory position);

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
    /// @return swapFeeAmount The swap amount in margin
    function addMargin(PoolKey memory key, IMarginPositionManager.CreateParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint256 borrowAmount, uint256 swapFeeAmount);

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
    /// @return swapFeeAmount The swap amount in margin
    function margin(IMarginPositionManager.MarginParams memory params)
        external
        payable
        returns (uint256 borrowAmount, uint256 swapFeeAmount);

    /// @notice Release the margin position by repaying the debt
    /// @param tokenId The id of position
    /// @param repayAmount The amount to repay
    /// @param deadline Deadline for the transaction
    function repay(uint256 tokenId, uint256 repayAmount, uint256 deadline) external payable;

    /// @notice Close the margin position
    /// @param tokenId The id of position
    /// @param closeMillionth The repayment ratio is calculated as one millionth
    /// @param closeAmountMin The minimum close amount (margin) to be received after closing the position
    /// @param deadline Deadline for the transaction
    function close(uint256 tokenId, uint24 closeMillionth, uint256 closeAmountMin, uint256 deadline) external;

    /// @notice Modify the margin position
    /// @param tokenId The id of position
    /// @param changeAmount The amount to modify
    /// @param deadline Deadline for the transaction
    function modify(uint256 tokenId, int128 changeAmount, uint256 deadline) external payable;
}
