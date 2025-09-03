// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "../types/PoolId.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PairPosition} from "../libraries/PairPosition.sol";

interface IPairPositionManager is IERC721 {
    event ModifyLiquidity(
        PoolId indexed poolId,
        uint256 indexed tokenId,
        address indexed sender,
        int128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Return the position with the given ID
    /// @param positionId The ID of the position to retrieve
    /// @return _position The position with the given ID
    function getPositionState(uint256 positionId) external view returns (PairPosition.State memory);
}
