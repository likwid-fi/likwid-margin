// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IImmutableState} from "v4-periphery/src/interfaces/IImmutableState.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {MarginParams, ReleaseParams} from "../types/MarginParams.sol";
import {HookStatus} from "../types/HookStatus.sol";
import {IMarginFees} from "../interfaces/IMarginFees.sol";
import {IMarginLiquidity} from "../interfaces/IMarginLiquidity.sol";

interface IMarginHookManager is IImmutableState {
    function marginOracle() external view returns (address);

    function marginFees() external view returns (IMarginFees);

    function marginLiquidity() external view returns (IMarginLiquidity);

    function getStatus(PoolId poolId) external view returns (HookStatus memory);

    function getReserves(PoolId poolId) external view returns (uint256 _reserve0, uint256 _reserve1);

    function getAmountIn(PoolId poolId, bool zeroForOne, uint256 amountOut) external view returns (uint256 amountIn);

    function getAmountOut(PoolId poolId, bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut);

    function addPositionManager(address _marginPositionManager) external;

    function setMarginOracle(address _oracle) external;

    function margin(MarginParams memory params) external returns (MarginParams memory);

    function release(ReleaseParams memory params) external payable returns (uint256);
}
