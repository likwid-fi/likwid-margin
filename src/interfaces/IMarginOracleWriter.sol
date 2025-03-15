// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/types/PoolKey.sol";

interface IMarginOracleWriter {
    function write(PoolKey calldata key, uint112 reserve0, uint112 reserve1) external;
}
