// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

import {IERC6909} from "../interfaces/external/IERC6909.sol";
import {PoolStatus} from "../types/PoolStatus.sol";

interface IMarginLiquidity is IERC6909 {
    function addLiquidity(address sender, uint256 id, uint256 amount) external;

    function removeLiquidity(address sender, uint256 id, uint256 amount) external returns (uint256);

    function changeLiquidity(PoolId poolId, uint256 _reserve0, uint256 _reserve1, int256 interest0, int256 interest1)
        external
        returns (uint256 liquidity);

    function addInterests(PoolId poolId, uint256 _reserve0, uint256 _reserve1, uint256 interest0, uint256 interest1)
        external
        returns (uint256 liquidity);

    function getPoolId(PoolId poolId) external pure returns (uint256 uPoolId);

    function getTotalSupply(uint256 uPoolId) external view returns (uint256 totalSupply);

    /// Get the totalSupply of pool status
    /// @param poolManager The address of pool manager
    /// @param poolId The pool id
    /// @return totalSupply The total supply
    function getPoolTotalSupply(address poolManager, PoolId poolId) external view returns (uint256 totalSupply);
}
