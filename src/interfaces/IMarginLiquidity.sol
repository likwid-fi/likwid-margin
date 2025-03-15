// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

import {IERC6909Accrues} from "../interfaces/external/IERC6909Accrues.sol";
import {PoolStatus} from "../types/PoolStatus.sol";

interface IMarginLiquidity is IERC6909Accrues {
    function addLiquidity(address receiver, uint256 id, uint8 level, uint256 amount)
        external
        returns (uint256 liquidity);

    function removeLiquidity(address sender, uint256 id, uint8 level, uint256 amount)
        external
        returns (uint256 liquidity);

    function addInterests(PoolId poolId, uint256 _reserve0, uint256 _reserve1, uint256 interest0, uint256 interest1)
        external
        returns (uint256 liquidity);

    function getMaxSliding() external view returns (uint24);

    function getPoolId(PoolId poolId) external pure returns (uint256 uPoolId);

    function getSupplies(uint256 uPoolId)
        external
        view
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1);

    function getFlowReserves(address pairPoolManager, PoolId poolId, PoolStatus memory status)
        external
        view
        returns (uint256 reserve0, uint256 reserve1);

    function getPoolSupplies(address pool, PoolId poolId)
        external
        view
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1);
}
