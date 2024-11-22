// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {MarginParams} from "../types/MarginParams.sol";

interface IMarginHook {
    function ltvParameters() external view returns (uint24, uint24);

    function getBorrowRateCumulativeLast(address borrowAddress) external view returns (uint256);

    function getAmountIn(address tokenIn, uint256 amountOut) external view returns (uint256 amountIn);

    function getAmountOut(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut);

    function borrow(MarginParams memory params) external returns (MarginParams memory);

    function repay(address payer, address borrowToken, uint256 borrowAmount, uint256 repayAmount)
        external
        payable
        returns (uint256);

    function liquidate(address marginToken, uint256 releaseAmount) external payable returns (uint256);
}
