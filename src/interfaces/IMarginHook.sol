// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BorrowParams} from "../types/BorrowParams.sol";

interface IMarginHook {
    function ltvParameters() external view returns (uint24, uint24);

    function borrowToken(BorrowParams memory params) external payable returns (BorrowParams memory);

    function returnToken(address payer, uint256 positionId, uint256 returnAmount)
        external
        payable
        returns (uint256, uint256);
}
