// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC6909Claims} from "v4-core/interfaces/external/IERC6909Claims.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {HookStatus} from "../types/HookStatus.sol";

interface IMarginLiquidity is IERC6909Claims {
    function mint(address receiver, uint256 id, uint256 amount) external;

    function burn(address sender, uint256 id, uint256 amount) external;

    function addLiquidity(address receiver, uint256 id, uint8 level, uint256 amount) external;

    function removeLiquidity(address sender, uint256 id, uint8 level, uint256 amount) external;

    function getPoolId(PoolId poolId) external pure returns (uint256 uPoolId);

    function getSupplies(uint256 uPoolId)
        external
        view
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1);

    function getFlowReserves(PoolId poolId, HookStatus memory status)
        external
        view
        returns (uint256 reserve0, uint256 reserve1);

    function getPoolSupplies(address hook, PoolId poolId)
        external
        view
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1);
}
