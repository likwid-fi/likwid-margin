// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {IMirrorTokenManager} from "./IMirrorTokenManager.sol";
import {IMarginPositionManager} from "./IMarginPositionManager.sol";
import {HookParams} from "../types/HookParams.sol";

interface IMarginHookFactory {
    error PairExists();
    error PairNotExists();

    event HookCreated(address indexed token0, address indexed token1, address pair);

    function feeTo() external view returns (address);

    function createHook(HookParams calldata params) external returns (IHooks hook);
    function getHookPair(address tokenA, address tokenB) external view returns (address hook);
    function parameters()
        external
        view
        returns (
            Currency currency0,
            Currency currency1,
            uint24 fee,
            uint24 marginFee,
            IMirrorTokenManager _mirrorTokenManager,
            IMarginPositionManager _marginPositionManager
        );
}
