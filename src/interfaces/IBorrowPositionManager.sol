// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BorrowPosition} from "../types/BorrowPosition.sol";
import {BorrowParams} from "../types/BorrowParams.sol";

interface IBorrowPositionManager is IERC721 {
    /// @notice Return the address of the hook contract
    function getHook() external view returns (address _hook);

    /// @notice Return the position with the given ID
    /// @param positionId The ID of the position to retrieve
    /// @return _position The position with the given ID
    function getPosition(uint256 positionId) external view returns (BorrowPosition memory _position);

    /// @notice Get the maximum marginAmount for the given pool, leverage
    /// @param poolId The ID of the pool
    /// @param marginForOne If true, currency1 is marginToken, otherwise currency2 is marginToken
    /// @return marginMax The maximum margin amount
    /// @return borrowAmount The borrow amount
    function getMarginMax(PoolId poolId, bool marginForOne)
        external
        view
        returns (uint256 marginMax, uint256 borrowAmount);

    /// @notice Margin a position
    /// @param params The parameters of the margin position
    /// @return positionId The ID of the margin position
    /// @return borrowAmount The borrow amount
    function borrow(BorrowParams memory params) external payable returns (uint256, uint256);

    /// @notice Release the margin position by repaying the debt
    /// @param positionId The id of position
    /// @param repayAmount The amount to repay
    /// @param deadline Deadline for the transaction
    function repay(uint256 positionId, uint256 repayAmount, uint256 deadline) external payable;
}
