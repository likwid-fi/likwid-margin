// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

struct LiquidateStatus {
    PoolId poolId;
    Currency marginCurrency;
    Currency borrowCurrency;
    bool marginForOne;
    uint256 oracleReserves;
    uint256 statusReserves;
}
