// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MarginPosition} from "../types/MarginPosition.sol";
import {MarginParams} from "../types/MarginParams.sol";
import {ReleaseParams} from "../types/ReleaseParams.sol";

interface IMarginPositionManager is IERC721 {
    /// @notice Return the address of the hook contract
    function getPairPool() external view returns (address _pairPool);

    /// @notice Return the position with the given ID
    /// @param positionId The ID of the position to retrieve
    /// @return _position The position with the given ID
    function getPosition(uint256 positionId) external view returns (MarginPosition memory _position);

    /// @notice Return the PNL amount of the position with the given ID and repayment ratio
    /// @param positionId The ID of the position to retrieve
    /// @param closeMillionth   The repayment ratio is calculated as one millionth
    /// @return pnlAmount The PNL amount of the position
    function estimatePNL(uint256 positionId, uint256 closeMillionth) external view returns (int256 pnlAmount);

    /// @notice Margin a position
    /// @param params The parameters of the margin position
    /// @return positionId The ID of the margin position
    /// @return borrowAmount The borrow amount
    function margin(MarginParams memory params) external payable returns (uint256, uint256);

    /// @notice Release the margin position by repaying the debt
    /// @param positionId The id of position
    /// @param repayAmount The amount to repay
    /// @param deadline Deadline for the transaction
    function repay(uint256 positionId, uint256 repayAmount, uint256 deadline) external payable;

    /// @notice Close the margin position
    /// @param positionId The id of position
    /// @param closeMillionth The repayment ratio is calculated as one millionth
    /// @param pnlMinAmount The minimum PNL amount to close the position
    /// @param deadline Deadline for the transaction
    function close(uint256 positionId, uint256 closeMillionth, int256 pnlMinAmount, uint256 deadline) external;

    /// @notice Modify the margin position
    /// @param positionId The id of position
    /// @param changeAmount The amount to modify
    function modify(uint256 positionId, int256 changeAmount) external payable;
}
