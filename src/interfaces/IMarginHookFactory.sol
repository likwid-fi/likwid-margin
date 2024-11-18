// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IMirrorTokenManager} from "./IMirrorTokenManager.sol";
import {IMarginPositionManager} from "./IMarginPositionManager.sol";
import {HookParams} from "../types/HookParams.sol";

interface IMarginHookFactory {
    error PairExists();
    error PairNotExists();

    event HookCreated(address indexed token0, address indexed token1, address pair);

    function feeTo() external view returns (address);

    function feeParameters() external view returns (address, uint24);

    function createHook(HookParams calldata params) external returns (IHooks hook);
    function getHookPair(address tokenA, address tokenB) external returns (address hook);
    function parameters()
        external
        view
        returns (
            Currency currency0,
            Currency currency1,
            uint24 fee,
            IMirrorTokenManager _mirrorTokenManager,
            IMarginPositionManager _marginPositionManager
        );
}
