// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {MarginHookFactory} from "../../src/MarginHookFactory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract MarginHookFactoryMock is MarginHookFactory {
    constructor(IPoolManager _poolManager) MarginHookFactory(_poolManager) {}

    function setPair(address token0, address token1, address pair) external {
        _pairs[token0][token1] = pair;
    }
}
