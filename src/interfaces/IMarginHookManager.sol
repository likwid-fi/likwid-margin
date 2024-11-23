// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {MarginParams, RepayParams, LiquidateParams} from "../types/MarginParams.sol";

interface IMarginHookManager {
    function ltvParameters(address tokenA, address tokenB) external view returns (uint24, uint24);

    function getBorrowRateCumulativeLast(address marginAddress, address borrowAddress)
        external
        view
        returns (uint256);

    function getAmountIn(address tokenIn, address tokenOut, uint256 amountOut)
        external
        view
        returns (uint256 amountIn);

    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut);

    function margin(MarginParams memory params) external returns (MarginParams memory);

    function repay(RepayParams memory params) external payable returns (uint256);

    function liquidate(LiquidateParams memory params) external payable returns (uint256);
}
