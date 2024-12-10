// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {MarginParams, ReleaseParams} from "../types/MarginParams.sol";
import {HookStatus} from "../types/HookStatus.sol";

interface IMarginHookManager {
    function ltvParameters(PoolId poolId) external view returns (uint24, uint24);

    function getStatus(PoolId poolId) external view returns (HookStatus memory);

    function getReserves(PoolId poolId) external view returns (uint256 _reserve0, uint256 _reserve1);

    function getBorrowRateCumulativeLast(PoolId poolId, bool marginForOne) external view returns (uint256);

    function getAmountIn(PoolId poolId, bool zeroForOne, uint256 amountOut) external view returns (uint256 amountIn);

    function getAmountOut(PoolId poolId, bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut);

    function addPositionManager(address _marginPositionManager) external;

    function margin(MarginParams memory params) external returns (MarginParams memory);

    function release(ReleaseParams memory params) external payable returns (uint256);
}
