// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "likwid-v2-core/types/PoolId.sol";

import {IERC6909} from "../interfaces/external/IERC6909.sol";
import {PoolStatus} from "../types/PoolStatus.sol";

interface IMarginLiquidity is IERC6909 {
    function getPoolId(PoolId poolId) external pure returns (uint256 uPoolId);

    function addLiquidity(address sender, PoolId poolId, uint256 amount) external;

    function removeLiquidity(address sender, PoolId poolId, uint256 amount)
        external
        returns (uint256 totalSupply, uint256 liquidityRemoved);

    function getTotalSupply(PoolId poolId) external view returns (uint256);
}
