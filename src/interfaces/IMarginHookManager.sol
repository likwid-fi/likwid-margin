// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {MarginParams, RepayParams, LiquidateParams} from "../types/MarginParams.sol";
import {HookStatus} from "../types/HookStatus.sol";

interface IMarginHookManager is IHooks {
    function ltvParameters(PoolId poolId) external view returns (uint24, uint24);

    function getStatus(PoolId poolId) external view returns (HookStatus memory);

    function getBorrowRateCumulativeLast(PoolId poolId, bool marginForOne) external view returns (uint256);

    function getAmountIn(PoolId poolId, bool zeroForOne, uint256 amountOut) external view returns (uint256 amountIn);

    function getAmountOut(PoolId poolId, bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut);

    function margin(MarginParams memory params) external returns (MarginParams memory);

    function repay(RepayParams memory params) external payable returns (uint256);

    function liquidate(LiquidateParams memory params) external payable returns (uint256);
}
