// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "../types/PoolId.sol";
import {Currency} from "../types/Currency.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LendPosition} from "../libraries/LendPosition.sol";

interface ILendPositionManager is IERC721 {
    error InvalidCurrency();

    event Deposit(
        PoolId indexed poolId,
        Currency indexed currency,
        address indexed sender,
        uint256 tokeId,
        address recipient,
        uint256 amount
    );

    event Withdraw(
        PoolId indexed poolId,
        Currency indexed currency,
        address indexed sender,
        uint256 tokeId,
        address recipient,
        uint256 amount
    );

    /// @notice Return the position with the given ID
    /// @param positionId The ID of the position to retrieve
    /// @return _position The position with the given ID
    function getPositionState(uint256 positionId) external view returns (LendPosition.State memory);
}
