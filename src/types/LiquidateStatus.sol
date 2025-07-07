// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "likwid-v2-core/types/PoolId.sol";
import {Currency} from "likwid-v2-core/types/Currency.sol";

struct LiquidateStatus {
    PoolId poolId;
    Currency marginCurrency;
    Currency borrowCurrency;
    bool marginForOne;
    uint256 oracleReserves;
    uint256 statusReserves;
}
