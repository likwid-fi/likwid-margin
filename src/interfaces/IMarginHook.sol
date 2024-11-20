// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BorrowParams} from "../types/BorrowParams.sol";

interface IMarginHook {
    function ltvParameters() external view returns (uint24, uint24);

    function getAmountIn(address payToken, uint256 amountOut) external view returns (uint256 amountIn);

    function getAmountOut(address payToken, uint256 amountIn) external view returns (uint256 amountOut);

    function borrow(BorrowParams memory params) external returns (uint256, BorrowParams memory);

    function repay(address payer, address borrowToken, uint256 repayAmount) external payable returns (uint256);
}
