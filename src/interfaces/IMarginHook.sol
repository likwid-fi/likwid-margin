// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BorrowParams} from "../types/BorrowParams.sol";

interface IMarginHook {
    function ltvParameters() external view returns (uint24, uint24);

    function borrow(BorrowParams memory params) external payable returns (BorrowParams memory);

    function repay(address payer, address borrowToken, uint256 repayAmount) external payable returns (uint256);
}
